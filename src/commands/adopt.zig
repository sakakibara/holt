//! `holt adopt <project> <path>`: registers an existing clone at `<path>`
//! into `<project>`. The clone's origin (if any) determines its identity;
//! an unset origin becomes a `local:<basename>` pseudo-URL, the same intake
//! path `promote` later moves off of once a real remote is added. Like
//! `promote`, relocating the clone to its identity path is gated by
//! `recover.check` and a destination that already exists is never
//! overwritten.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const project_mod = @import("../project.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const git = @import("../git.zig");
const recover = @import("../recover.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    // Interpreted by count in run(): two positionals -> <project> <path>;
    // one positional -> <path> (standalone). Hence the generic roles here.
    first: cli.spec.Pos([]const u8, .{ .complete = app.cat(.project), .help = "the clone path, or the project to adopt into when a path follows" }),
    second: cli.spec.Pos([]const u8, .{ .complete = .files, .optional = true, .help = "the clone path (when a project is given first)" }),
    force: cli.spec.Flag(.{ .short = 'f', .help = "adopt even if the clone has unrecoverable local state" }),
};

pub const command = app.command(Spec, .{
    .name = "adopt",
    .summary = "Register an existing clone into a project, moving it to its identity path",
    .usage = "holt adopt [<project>] <path> [--force]",
    .group = .create,
    .needs_context = true,
    .details =
    \\Example:
    \\  holt adopt myproj ~/Code/github.com/acme/widget
    ,
}, run);

/// The final path segment of `path`, ignoring any trailing slashes.
fn basenameOf(path: []const u8) []const u8 {
    var trimmed = path;
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    return std.fs.path.basename(trimmed);
}

/// Compares two paths by their resolved (symlink-free) form so a clone
/// already sitting at its identity path - reached via a different-but-equal
/// route - isn't mistaken for out-of-place. `clone_path` may not exist yet,
/// in which case its resolution falls back to the literal path.
fn samePath(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const ra = try fsutil.realPathOrSelf(alloc, a);
    const rb = try fsutil.realPathOrSelf(alloc, b);
    return std.mem.eql(u8, ra, rb);
}

/// `recover.check` restricted to dirty/stash blockers, for a clone with no
/// origin: unpushed/no_upstream are meaningless when there is no remote to
/// have pushed to in the first place.
fn localSafetyCheck(alloc: std.mem.Allocator, repo_path: []const u8) !recover.Verdict {
    var blockers: std.ArrayListUnmanaged(recover.Blocker) = .empty;
    if (try git.isDirty(alloc, repo_path)) try blockers.append(alloc, .dirty);
    if (try git.hasStashes(alloc, repo_path)) try blockers.append(alloc, .stashes);
    return .{ .blockers = blockers };
}

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    // Two positionals -> (project, path); one -> (path), standalone.
    const project_query: ?[]const u8 = if (a.second != null) a.first else null;
    const path_arg: []const u8 = a.second orelse a.first;
    const force = a.force;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    // Project setup (project mode only): resolve, lock, re-read the marker.
    var p: project_mod.Project = undefined;
    var content_lock: ?projectlock.Handle = null;
    defer if (content_lock) |l| l.release();
    if (project_query) |q| {
        p = (try common.resolveOne(ctx, q)) orelse return 1;
        content_lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
        p.marker = try marker.load(alloc, try p.markerPath(alloc), null);
    }

    const abs_path = try fsutil.toAbsolute(alloc, path_arg);

    if (!fsutil.exists(abs_path)) {
        try ctx.err.print("holt: no clone found at {s}\n", .{abs_path});
        return 1;
    }

    if (!try git.inspectable(alloc, abs_path)) {
        try ctx.err.print("holt: {s} is not a readable git repository\n", .{abs_path});
        return 1;
    }

    const origin = try git.remoteUrl(alloc, abs_path);
    const basename = basenameOf(abs_path);

    var id: identity.Identity = undefined;
    var marker_value: []const u8 = undefined;
    if (origin) |o| {
        id = identity.fromUrl(alloc, o) catch |err| switch (err) {
            error.UnrecognizedUrl => {
                try ctx.err.print("holt: origin \"{s}\" is not a recognized git url\n", .{o});
                return 1;
            },
            else => return err,
        };
        marker_value = o;
    } else {
        id = identity.local(basename);
        marker_value = try std.fmt.allocPrint(alloc, "local:{s}", .{basename});
    }

    if (project_query != null and p.marker.repos.contains(id.repo)) {
        try ctx.err.print("holt: \"{s}\" is already a member of {s}/{s}\n", .{ id.repo, p.org, p.name });
        return 1;
    }

    const clone_path = try id.clonePath(alloc, ws.cfg.code_root);

    // Hold the clone-path lock through the relocate and the marker write (after
    // the content lock, a fixed order), so a concurrent `archive --prune`
    // cannot delete the destination clone between the move and the reference
    // to it landing on disk.
    var clone_lock = try projectlock.acquire(alloc, app.envOf(ctx), clone_path);
    defer clone_lock.release();

    var final_path: []const u8 = abs_path;
    var moved = false;

    if (!try samePath(alloc, abs_path, clone_path)) {
        if (fsutil.exists(clone_path)) {
            try ctx.err.print("holt: destination {s} already exists; refusing to overwrite\n", .{clone_path});
            return 1;
        }

        // A repo with no origin at all has no upstream by definition, so
        // recover.check's unpushed/no_upstream blockers would always fire
        // regardless of how safe the repo actually is - meaningless noise
        // for a local-only intake. Only dirty/stash state (real, avoidable
        // data-loss risk from the move) gates a local adopt.
        var verdict = if (origin != null) try recover.check(alloc, abs_path) else try localSafetyCheck(alloc, abs_path);
        if (!verdict.safe() and !force) {
            try ctx.err.print("holt: {s} has unrecoverable local state, refusing to adopt (use --force to override):\n", .{abs_path});
            try verdict.render(ctx.err);
            return 1;
        }

        common.moveClone(ctx, abs_path, clone_path) catch return 1;
        final_path = clone_path;
        moved = true;
    }

    // Standalone: no marker, no hub. Print the clone path (cd-friendly), like `get`.
    if (project_query == null) {
        try ctx.out.print("{s}\n", .{final_path});
        try ctx.err.print("{s}\n", .{if (moved) "adopted (standalone)" else "already there"});
        return 0;
    }

    // Project mode: record + reconcile, then report.
    try p.marker.repos.put(alloc, id.repo, marker_value);
    const marker_path = try p.markerPath(alloc);
    // Once the clone has been relocated, a marker or hub failure leaves the
    // move done but the project not yet updated. Name where the clone landed
    // and the idempotent re-run that finishes it, rather than leaking a bare
    // internal error that hides both.
    marker.save(&p.marker, marker_path) catch |err| {
        if (moved) {
            try reportUnfinishedAdopt(ctx, p.org, p.name, clone_path, err);
            return 1;
        }
        return err;
    };

    _ = hub.reconcile(alloc, &ws, &p, false) catch |err| {
        if (moved) {
            try reportUnfinishedAdopt(ctx, p.org, p.name, clone_path, err);
            return 1;
        }
        return err;
    };

    const rel = try id.relPath(alloc);
    try ctx.out.print("{s}\n", .{final_path});
    try ctx.err.print("adopted {s} -> {s}\n", .{ rel, try fsutil.contractTilde(alloc, app.envOf(ctx), final_path) });
    return 0;
}

fn reportUnfinishedAdopt(ctx: *app.Ctx, org: []const u8, name: []const u8, clone_path: []const u8, err: anyerror) !void {
    try ctx.err.print("holt: the clone was moved to {s} but updating {s}/{s} failed: {s}; re-run \"holt adopt {s}/{s} {s}\" to finish\n", .{ clone_path, org, name, @errorName(err), org, name, clone_path });
}

/// Clones `bare` to `dest` and repoints origin at `fake_origin` - a URL
/// `identity.fromUrl` can parse - standing in for the real remote of a
/// clone the user made by hand somewhere outside `code_root`.
fn cloneWithOrigin(sb: *testutil.Sandbox, bare: []const u8, dest: []const u8, fake_origin: []const u8) !void {
    try testutil.runGit(sb, null, &.{ "clone", bare, dest });
    try testutil.runGit(sb, dest, &.{ "remote", "set-url", "origin", fake_origin });
}

test "run: adopts an out-of-place clone with an origin, moving it to the identity path and updating marker + hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", stray_path });
    try testing.expectEqual(@as(u8, 0), got.code);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    try testing.expect(!fsutil.exists(stray_path));
    try testing.expect(fsutil.exists(new_clone_path));
    try testing.expect(std.mem.indexOf(u8, got.out, new_clone_path) != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings(fake_origin, loaded.repos.get("scratch").?);

    const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "scratch" });
    switch (try fsutil.linkState(arena, code_link)) {
        .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
        else => return error.TestUnexpectedResult,
    }
}

test "run: adopts a no-remote dir into local/<basename> with a local: marker value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "myrepo" });
    try fsutil.ensureDir(stray_path);
    try testutil.runGit(&sb, stray_path, &.{ "init", "-b", "main" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", stray_path });
    try testing.expectEqual(@as(u8, 0), got.code);

    const want_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "myrepo" });
    try testing.expect(!fsutil.exists(stray_path));
    try testing.expect(fsutil.exists(want_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:myrepo", loaded.repos.get("myrepo").?);
}

test "run: a dirty out-of-place clone refuses without --force, then proceeds with --force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);
    {
        var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), stray_path, .{});
        defer dir.close(fsutil.io());
        try dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });
    }

    const refused = try testutil.runCmd(arena, command.run, ws, &.{ "proj", stray_path });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "uncommitted changes present") != null);
    try testing.expect(fsutil.exists(stray_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const before = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), before.repos.count());

    const forced = try testutil.runCmd(arena, command.run, ws, &.{ "proj", stray_path, "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(stray_path));

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(fsutil.exists(new_clone_path));
}

test "run: a destination already occupied refuses to overwrite" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const other_bare = try testutil.makeBareRepo(&sb, "other.git");
    defer testing.allocator.free(other_bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(std.fs.path.dirname(new_clone_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", other_bare, new_clone_path });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", stray_path });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists") != null);
    try testing.expect(fsutil.exists(stray_path));
    try testing.expect(fsutil.exists(new_clone_path));
}

test "run: a repo short name already a member of the project is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "https://holt-test.invalid/other/scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", stray_path });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already a member") != null);
}

test "run: no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "nope", "/somewhere" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "run: a marker-save failure after the move names the new clone path and re-run command, and re-running finishes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    // A read-only content dir makes marker.save (writing .holt.json.tmp) fail
    // after the clone has already been relocated. Mode bits don't gate
    // access on Windows, so this whole simulation is POSIX-only.
    if (builtin.os.tag != .windows) {
        const content_rel = "synced/projects/acme/proj";
        try sb.tmp.dir.setFilePermissions(testing.io, content_rel, std.Io.File.Permissions.fromMode(0o555), .{});
        defer sb.tmp.dir.setFilePermissions(testing.io, content_rel, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", stray_path });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, new_clone_path) != null);
        try testing.expect(std.mem.indexOf(u8, got.err, "re-run") != null);
        try testing.expect(std.mem.indexOf(u8, got.err, "holt adopt acme/proj") != null);

        try testing.expect(!fsutil.exists(stray_path));
        try testing.expect(fsutil.exists(new_clone_path));

        // Restore perms and re-run with the new path: the idempotent move
        // short-circuits and the adopt completes.
        try sb.tmp.dir.setFilePermissions(testing.io, content_rel, std.Io.File.Permissions.fromMode(0o755), .{});
        const again = try testutil.runCmd(arena, command.run, ws, &.{ "proj", new_clone_path });
        try testing.expectEqual(@as(u8, 0), again.code);

        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings(fake_origin, loaded.repos.get("scratch").?);
    }
}

test "run: a plain directory with no .git is refused as unreadable, nothing moved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const plain_path = try std.fs.path.join(arena, &.{ sb.root, "plain-dir" });
    try fsutil.ensureDir(plain_path);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", plain_path });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not a readable git repository") != null);
    try testing.expect(fsutil.exists(plain_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.repos.count());
}

test "run: a nonexistent path is a hard error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const missing_path = try std.fs.path.join(arena, &.{ root, "does-not-exist" });
    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", missing_path });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, missing_path) != null);
}

test "run: one-arg standalone adopt moves a clone to its ghq path with no marker and no hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/widget";

    // An existing local checkout at a NON-ghq path, with origin = fake_origin.
    const src = try std.fs.path.join(arena, &.{ sb.root, "checkout", "widget" });
    try cloneWithOrigin(&sb, bare, src, fake_origin);

    // Standalone adopt: ONE positional (the path).
    const got = try testutil.runCmd(arena, command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 0), got.code);

    const id = try identity.fromUrl(arena, fake_origin);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(fsutil.exists(clone_path)); // moved to ghq
    try testing.expect(!fsutil.exists(src)); // source gone
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{clone_path}), got.out); // path on stdout
    // Standalone: no marker, no hub.
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ clone_path, ".holt.json" })));
    try testing.expect(!fsutil.exists(ws.cfg.synced_root));
    try testing.expect(!fsutil.exists(ws.cfg.hub_root));
}

test "run: a relative path argument resolves against the cwd instead of crashing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    // cwd is process-global and shared by every test in this binary, so a
    // missing restore here would corrupt every test that runs afterward.
    try std.process.setCurrentPath(fsutil.io(), sb.root);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "stray-clone" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    try testing.expect(!fsutil.exists(stray_path));
    try testing.expect(fsutil.exists(new_clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings(fake_origin, loaded.repos.get("scratch").?);

    const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "scratch" });
    switch (try fsutil.linkState(arena, code_link)) {
        .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
        else => return error.TestUnexpectedResult,
    }
}

test "run: standalone adopt of a repo with no remote lands under code/local" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // A local repo with NO origin.
    const src = try std.fs.path.join(arena, &.{ sb.root, "scratch", "thing" });
    try fsutil.ensureDir(src);
    try testutil.runGit(&sb, src, &.{ "init", "-q" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "f" }), .data = "x\n" });
    try testutil.runGit(&sb, src, &.{ "add", "f" });
    try testutil.runGit(&sb, src, &.{ "commit", "-m", "c" });

    const got2 = try testutil.runCmd(arena, command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 0), got2.code);
    const dest = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "thing" });
    try testing.expect(fsutil.exists(dest));
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{dest}), got2.out);
}

test "run: standalone adopt of a clone already at its ghq path is a no-op" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const src = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "thing" });
    try fsutil.ensureDir(src);
    try testutil.runGit(&sb, src, &.{ "init", "-q" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "f" }), .data = "x\n" });
    try testutil.runGit(&sb, src, &.{ "add", "f" });
    try testutil.runGit(&sb, src, &.{ "commit", "-m", "c" });
    const inode_before = (try std.Io.Dir.cwd().statFile(fsutil.io(), src, .{})).inode;

    const got2 = try testutil.runCmd(arena, command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 0), got2.code);
    try testing.expect(std.mem.indexOf(u8, got2.err, "already there") != null);
    try testing.expectEqual(inode_before, (try std.Io.Dir.cwd().statFile(fsutil.io(), src, .{})).inode);
}

test "run: standalone adopt refuses when the ghq destination is occupied by another clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin2 = "https://holt-test.invalid/acme/widget";

    const id = try identity.fromUrl(arena, fake_origin2);
    const occupied_dest = try id.clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(occupied_dest);
    try testutil.runGit(&sb, occupied_dest, &.{ "init", "-q" }); // a DIFFERENT clone already there

    // Sandbox.init freezes GIT_CONFIG_GLOBAL=/dev/null into its git env
    // snapshot, so an insteadOf rewrite via a second gitconfig is invisible
    // to runGit; cloneWithOrigin (clone the bare repo directly, then
    // set-url) is the only way to get a real clone with fake_origin2 set.
    const bare2 = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare2);
    const src = try std.fs.path.join(arena, &.{ sb.root, "checkout", "widget" });
    try cloneWithOrigin(&sb, bare2, src, fake_origin2);

    const got2 = try testutil.runCmd(arena, command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 1), got2.code);
    try testing.expect(std.mem.indexOf(u8, got2.err, "already exists") != null);
    try testing.expect(fsutil.exists(src)); // source untouched
}

test "run: standalone adopt of a non-git path errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const dir = try std.fs.path.join(arena, &.{ sb.root, "plain" });
    try fsutil.ensureDir(dir);

    const got2 = try testutil.runCmd(arena, command.run, ws, &.{dir});
    try testing.expectEqual(@as(u8, 1), got2.code);
    try testing.expect(std.mem.indexOf(u8, got2.err, "not a readable git repository") != null);
}

test "run: standalone adopt of a dirty repo needs --force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const src = try std.fs.path.join(arena, &.{ sb.root, "scratch", "thing" });
    try fsutil.ensureDir(src);
    try testutil.runGit(&sb, src, &.{ "init", "-q" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "f" }), .data = "x\n" });
    try testutil.runGit(&sb, src, &.{ "add", "f" });
    try testutil.runGit(&sb, src, &.{ "commit", "-m", "c" });
    // Make it dirty: an uncommitted change.
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "f" }), .data = "changed\n" });

    const refused = try testutil.runCmd(arena, command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "unrecoverable local state") != null);
    try testing.expect(fsutil.exists(src)); // not moved

    const forced = try testutil.runCmd(arena, command.run, ws, &.{ src, "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    const dest = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "thing" });
    try testing.expect(fsutil.exists(dest));
}
