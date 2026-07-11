//! `holt promote <repo> [--force]`: moves a local repo (recorded in markers
//! as `local:<repo>`) to its real remote identity, once its clone has grown
//! an origin. The single most destructive operation in holt - it relocates
//! the clone on disk and rewrites every marker referencing it - so the
//! `recover.check` gate (uncommitted changes, stashes, unpushed commits) is
//! mandatory unless `--force` overrides it, and a destination that already
//! exists is never merged into or overwritten.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const git = @import("../git.zig");
const recover = @import("../recover.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const ui = @import("../ui.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    repo: cli.spec.Pos([]const u8, .{ .complete = app.cat(.local_repo), .help = "the short name of a local repo that has since gained a remote" }),
    dry_run: cli.spec.Flag(.{ .help = "print the planned move and affected projects, then exit" }),
    yes: cli.spec.Flag(.{ .short = 'y', .help = "skip the confirmation prompt" }),
    force: cli.spec.Flag(.{ .short = 'f', .help = "promote even if the clone has unrecoverable local state (also skips the confirmation prompt)" }),
};

pub const command = app.command(Spec, .{
    .name = "promote",
    .summary = "Move a local repo to its real remote identity once it has an origin",
    .usage = "holt promote <repo> [--dry-run] [--yes] [--force]",
    .group = .maintain,
    .needs_context = true,
    .details =
    \\<repo> is the short name of a local (unpushed) repo that has since gained
    \\a remote, as recorded in markers by "local:<repo>" - not a project
    \\selector.
    \\
    \\Example:
    \\  holt promote widget --dry-run
    ,
}, run);

const Referencing = struct {
    project: project_mod.Project,
    repo_key: []const u8,
};

/// Every (project, repo key) pair whose marker value is the pseudo-URL
/// `local:<name>`.
fn findReferencing(alloc: std.mem.Allocator, ws: *const workspace.Workspace, name: []const u8) ![]Referencing {
    const all = try ws.list(alloc);
    const pseudo = try std.fmt.allocPrint(alloc, "local:{s}", .{name});

    var out: std.ArrayList(Referencing) = .empty;
    for (all) |p| {
        for (p.marker.repos.keys()) |key| {
            const val = p.marker.repos.get(key).?;
            if (std.mem.eql(u8, val, pseudo)) try out.append(alloc, .{ .project = p, .repo_key = key });
        }
    }
    return out.toOwnedSlice(alloc);
}

const Resolution = struct {
    origin: []const u8,
    new_id: identity.Identity,
    new_path: []const u8,
    /// False when a prior, interrupted promote already relocated the clone
    /// to `new_path` - the rename step is then skipped entirely.
    move_needed: bool,
};

const Resumed = struct { origin: []const u8, id: identity.Identity, path: []const u8 };

/// Points one referencing project's `repo_key` at the promoted repo's real
/// `origin`, under that project's lock with a fresh re-read, so a concurrent
/// holt mutating the same project neither loses this rewrite nor is lost by
/// it. The lock is scoped to this one project and released on return, so
/// promoting across many projects never holds two locks at once (no deadlock
/// against another promote acquiring them in a different order).
fn rewriteMemberOrigin(alloc: std.mem.Allocator, ref: Referencing, origin: []const u8) !void {
    var lock = try projectlock.acquire(alloc, ref.project.content_path);
    defer lock.release();

    var p = ref.project;
    const marker_path = try p.markerPath(alloc);
    p.marker = try marker.load(alloc, marker_path, null);
    try p.marker.repos.put(alloc, ref.repo_key, origin);
    try marker.save(&p.marker, marker_path);
}

/// A local repo's clone is gone from `old_path`. This is either an already
/// fully-promoted repo (nothing here to do - caught by `move_needed` being
/// moot) or a promote interrupted after the rename but before every marker
/// was rewritten: a sibling project sharing `ref.repo_key` already holds
/// the real origin instead of the "local:<name>" pseudo-URL, and the clone
/// now lives at that origin's identity clonePath.
fn alreadyMovedOrigin(alloc: std.mem.Allocator, ws: *const workspace.Workspace, referencing: []const Referencing) !?Resumed {
    const all = try ws.list(alloc);
    for (referencing) |ref| {
        for (all) |p| {
            const val = p.marker.repos.get(ref.repo_key) orelse continue;
            if (std.mem.startsWith(u8, val, "local:")) continue;

            const id = identity.fromUrl(alloc, val) catch continue;
            const path = try id.clonePath(alloc, ws.cfg.code_root);
            if (!fsutil.exists(path)) continue;
            if (try git.remoteUrl(alloc, path) == null) continue;

            return .{ .origin = val, .id = id, .path = path };
        }
    }
    return null;
}

/// Walks `code_root` (skipping the reserved "local" subtree) for a directory
/// named `name` that is a git clone with an `origin` remote configured - the
/// shape a promoted clone takes once moved to its real identity path. This
/// is the last-resort way to resume a promote interrupted before its very
/// first marker write, when no sibling marker survives to name the origin
/// either. Never descends into a clone's own `.git` internals.
fn findMovedClone(alloc: std.mem.Allocator, code_root: []const u8, name: []const u8) !?Resumed {
    var root_dir = std.Io.Dir.cwd().openDir(fsutil.io(), code_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer root_dir.close(fsutil.io());

    var walker = try root_dir.walkSelectively(alloc);
    defer walker.deinit();

    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.path, "local")) continue;

        const abs_path = try std.fs.path.join(alloc, &.{ code_root, entry.path });
        const git_dir = try std.fs.path.join(alloc, &.{ abs_path, ".git" });
        if (!fsutil.exists(git_dir)) {
            try walker.enter(fsutil.io(), entry);
            continue;
        }
        if (!std.mem.eql(u8, entry.basename, name)) continue;

        const origin = try git.remoteUrl(alloc, abs_path) orelse continue;
        const id = identity.fromUrl(alloc, origin) catch continue;
        return .{ .origin = origin, .id = id, .path = abs_path };
    }
    return null;
}

/// Resolves the origin URL and move state for `name`. Returns null after
/// printing the appropriate error to `ctx.err` - the caller should then
/// exit 1.
fn resolveOrigin(
    ctx: *app.Ctx,
    alloc: std.mem.Allocator,
    ws: *const workspace.Workspace,
    name: []const u8,
    old_path: []const u8,
    referencing: []const Referencing,
) !?Resolution {
    if (fsutil.exists(old_path)) {
        const origin = try git.remoteUrl(alloc, old_path) orelse {
            try ctx.err.print("holt: no remote configured for {s}\n", .{name});
            return null;
        };
        const new_id = identity.fromUrl(alloc, origin) catch |err| switch (err) {
            error.UnrecognizedUrl => {
                try ctx.err.print("holt: origin \"{s}\" for {s} is not a recognized git url\n", .{ origin, name });
                return null;
            },
            else => return err,
        };
        const new_path = try new_id.clonePath(alloc, ws.cfg.code_root);
        return .{ .origin = origin, .new_id = new_id, .new_path = new_path, .move_needed = true };
    }

    const resumed = (try alreadyMovedOrigin(alloc, ws, referencing)) orelse
        (try findMovedClone(alloc, ws.cfg.code_root, name));
    if (resumed) |r| {
        return .{ .origin = r.origin, .new_id = r.id, .new_path = r.path, .move_needed = false };
    }

    try ctx.err.print("holt: local clone for {s} not found at {s}\n", .{ name, old_path });
    return null;
}

/// Reports which projects were already rewritten before an error hit, so a
/// partial failure is diagnosable instead of a silent crash. Safe to call
/// with an empty `done`. `new_path` is where the clone sits right now (the
/// move already happened by the time this is called); when `done` is empty,
/// a re-run can only find it again via `findMovedClone`'s basename match, so
/// the "re-run to finish" hint is only printed when that would succeed.
fn printResumeHint(ctx: *app.Ctx, alloc: std.mem.Allocator, done: []const Referencing, name: []const u8, new_path: []const u8) !void {
    if (done.len == 0) {
        if (std.mem.eql(u8, std.fs.path.basename(new_path), name)) {
            try ctx.err.print("holt: promote failed before updating any project; re-run \"holt promote {s}\" to finish\n", .{name});
        } else {
            try ctx.err.print("holt: promote failed before updating any project; the clone now lives at {s} and cannot be found automatically - update a project's marker or move it back to resume\n", .{new_path});
        }
        return;
    }
    try ctx.err.writeAll("holt: promote updated ");
    for (done, 0..) |ref, i| {
        if (i != 0) try ctx.err.writeAll(", ");
        try ctx.err.print("{s}", .{try ref.project.qualified(alloc)});
    }
    try ctx.err.print(" before failing; re-run \"holt promote {s}\" to finish\n", .{name});
}

/// Prints the pending relocation and every project marker that will be
/// rewritten - the shared preview for both `--dry-run` and the interactive
/// confirmation.
fn printPlan(ctx: *app.Ctx, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, move_needed: bool, referencing: []const Referencing) !void {
    if (move_needed) {
        try ctx.out.print("move {s} -> {s}\n", .{ old_path, new_path });
    } else {
        try ctx.out.print("clone already at {s}\n", .{new_path});
    }
    try ctx.out.print("rewrite {d} marker(s):\n", .{referencing.len});
    for (referencing) |ref| {
        try ctx.out.print("  {s}\n", .{try ref.project.qualified(alloc)});
    }
}

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const name = a.repo;
    const dry_run = a.dry_run;
    const yes = a.yes;
    const force = a.force;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const referencing = try findReferencing(alloc, &ws, name);
    if (referencing.len == 0) {
        try ctx.err.print("holt: no project references a local repo named \"{s}\"\n", .{name});
        return 1;
    }

    const old_path = try identity.local(name).clonePath(alloc, ws.cfg.code_root);
    const resolved = try resolveOrigin(ctx, alloc, &ws, name, old_path, referencing) orelse return 1;
    const origin = resolved.origin;
    const new_path = resolved.new_path;

    if (resolved.move_needed and fsutil.exists(new_path)) {
        const dest_origin = try git.remoteUrl(alloc, new_path);
        const same_remote = if (dest_origin) |d| std.mem.eql(u8, d, origin) else false;
        if (same_remote) {
            try ctx.err.print("holt: destination {s} already cloned; resolve manually\n", .{new_path});
        } else {
            try ctx.err.print("holt: destination {s} already exists and is a different repo\n", .{new_path});
        }
        return 1;
    }

    if (dry_run) {
        try printPlan(ctx, alloc, old_path, new_path, resolved.move_needed, referencing);
        return 0;
    }

    if (resolved.move_needed) {
        var verdict = try recover.check(alloc, old_path);
        if (!verdict.safe() and !force) {
            try ctx.err.print("holt: {s} has unrecoverable local state, refusing to promote (use --force to override):\n", .{name});
            try verdict.render(ctx.err);
            return 1;
        }
    }

    if (!force and !yes) {
        try printPlan(ctx, alloc, old_path, new_path, resolved.move_needed, referencing);
        const prompt = try std.fmt.allocPrint(alloc, "Promote {s}? this moves the clone and rewrites {d} marker(s)", .{ name, referencing.len });
        if (!try ui.confirm(ctx.out, prompt)) {
            try ctx.out.writeAll("promote cancelled\n");
            return 0;
        }
    }

    // No clone-path lock here, deliberately. It is unnecessary: `archive
    // --prune` can never target this move. The source is a `local:` clone,
    // which prune always keeps (no upstream -> recover.check fails); the
    // destination, if it already exists, makes promote refuse above, and if it
    // does not, prune skips it as missing. A concurrent clone of the same
    // remote onto `new_path` is made non-corrupting by git.clone's atomic
    // temp-then-rename (this move would just fail cleanly with DirNotEmpty).
    // Taking a clone lock here WOULD deadlock: promote locks content per
    // referenced project below, so a clone-then-content order here inverts the
    // content-then-clone order add/adopt use.
    if (resolved.move_needed) {
        common.moveClone(ctx, old_path, new_path) catch return 1;
        if (std.fs.path.dirname(old_path)) |old_local_dir| fsutil.rmdirIfEmpty(old_local_dir);
    }

    var progress: std.ArrayList(Referencing) = .empty;
    for (referencing) |ref| {
        rewriteMemberOrigin(alloc, ref, origin) catch |err| {
            try printResumeHint(ctx, alloc, progress.items, name, new_path);
            return err;
        };
        try progress.append(alloc, ref);
    }

    const affected = try ws.projectsUsing(alloc, resolved.new_id);
    for (affected) |p| {
        _ = hub.reconcile(alloc, &ws, &p, false) catch |err| {
            try printResumeHint(ctx, alloc, progress.items, name, new_path);
            return err;
        };
    }

    try ctx.out.print("moved {s} -> {s}\n", .{ old_path, new_path });
    try ctx.out.print("{d} marker(s) updated, hub(s) rebuilt\n", .{referencing.len});
    return 0;
}

/// Clones `bare` directly to `dest` (rather than testutil.makeWorkClone's
/// auto-named path) so the clone lands at the `<code_root>/local/<name>`
/// path a real local repo would occupy, then repoints origin at
/// `fake_origin` - a URL `identity.fromUrl` can parse, standing in for the
/// real remote the user added to what started as a local-only repo.
fn cloneAsLocalRepo(sb: *testutil.Sandbox, bare: []const u8, dest: []const u8, fake_origin: []const u8) !void {
    try fsutil.ensureDir(std.fs.path.dirname(dest).?);
    try testutil.runGit(sb, null, &.{ "clone", bare, dest });
    try testutil.runGit(sb, dest, &.{ "remote", "set-url", "origin", fake_origin });
}

test "command: presents its argument as a local repo, not a project selector" {
    try testing.expect(std.mem.indexOf(u8, command.usage, "<project>") == null);
    try testing.expect(std.mem.indexOf(u8, command.usage, "<repo>") != null);
    try testing.expect(std.mem.indexOf(u8, command.details, "local") != null);
    try testing.expect(std.mem.indexOf(u8, command.details, "not a project") != null);
}

test "run: promotes a local repo shared by two projects, rewriting both markers and both hubs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos_a });

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = repos_b });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, local_clone_path, fake_origin);

    const first_before = switch (try ws.find(arena, "first")) {
        .one => |p| p,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &first_before, false);
    const second_before = switch (try ws.find(arena, "second")) {
        .one => |p| p,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &second_before, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "2 marker(s) updated") != null);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    try testing.expect(!fsutil.exists(local_clone_path));
    try testing.expect(fsutil.exists(new_clone_path));

    for ([_][]const u8{ "first", "second" }) |proj_name| {
        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", proj_name, marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings(fake_origin, loaded.repos.get("scratch").?);

        const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", proj_name, "code", "scratch" });
        switch (try fsutil.linkState(arena, code_link)) {
            .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "run: promote carries a repo's worktrees along and keeps them working" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, local_clone_path, fake_origin);

    // A worktree on the local clone, at its sibling `@worktrees` dir.
    const wt_old = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{local_clone_path}), "feature" });
    try testutil.runGit(&sb, local_clone_path, &.{ "branch", "feature" });
    try testutil.runGit(&sb, local_clone_path, &.{ "worktree", "add", wt_old, "feature" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const new_clone_path = try (try identity.fromUrl(arena, fake_origin)).clonePath(arena, ws.cfg.code_root);
    const wt_new = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{new_clone_path}), "feature" });

    // The worktrees dir moved with the clone, and the worktree still works -
    // currentBranch only succeeds if git's admin links were repaired.
    try testing.expect(!fsutil.exists(wt_old));
    try testing.expect(fsutil.exists(wt_new));
    try testing.expectEqualStrings("feature", (try git.currentBranch(arena, wt_new)).?);
}

test "run: --dry-run prints the planned move and affected projects, changing nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos_a });

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = repos_b });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, local_clone_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "scratch", "--dry-run" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, local_clone_path) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, new_clone_path) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/first") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/second") != null);

    try testing.expect(fsutil.exists(local_clone_path));
    try testing.expect(!fsutil.exists(new_clone_path));

    for ([_][]const u8{ "first", "second" }) |proj_name| {
        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", proj_name, marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings("local:scratch", loaded.repos.get("scratch").?);
    }
}

test "run: a dirty clone refuses without --force, then proceeds with --force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, local_clone_path, fake_origin);

    var clone_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), local_clone_path, .{});
    defer clone_dir.close(fsutil.io());
    try clone_dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });

    const refused = try testutil.runCmd(arena, command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "uncommitted changes present") != null);
    try testing.expect(fsutil.exists(local_clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded_after_refusal = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:scratch", loaded_after_refusal.repos.get("scratch").?);

    const forced = try testutil.runCmd(arena, command.run, ws, &.{ "scratch", "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(local_clone_path));

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(fsutil.exists(new_clone_path));

    const loaded_after_force = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings(fake_origin, loaded_after_force.repos.get("scratch").?);
}

test "run: a destination already cloned from the same remote stops without changing anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, local_clone_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, new_clone_path, fake_origin);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already cloned; resolve manually") != null);

    try testing.expect(fsutil.exists(local_clone_path));
    try testing.expect(fsutil.exists(new_clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:scratch", loaded.repos.get("scratch").?);
}

test "run: a destination occupied by a different repo is a hard error" {
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
    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const other_fake_origin = "https://holt-test.invalid/other/thing";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, local_clone_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, other_bare, new_clone_path, other_fake_origin);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "different repo") != null);
    try testing.expect(fsutil.exists(local_clone_path));
}

test "run: no project referencing the local repo is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"nope"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "run: no remote configured on the local clone is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(local_clone_path);
    try testutil.runGit(&sb, local_clone_path, &.{ "init", "-b", "main" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "no remote configured for scratch") != null);
}

test "run: resumes an interrupted promote, finishing the leftover marker and hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    // "first" already got its marker rewritten by a prior run; "second" is
    // the leftover this run must finish.
    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "scratch", fake_origin);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos_a });

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = repos_b });

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, new_clone_path, fake_origin);

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(local_clone_path));

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "1 marker(s) updated") != null);

    for ([_][]const u8{ "first", "second" }) |proj_name| {
        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", proj_name, marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings(fake_origin, loaded.repos.get("scratch").?);

        const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", proj_name, "code", "scratch" });
        switch (try fsutil.linkState(arena, code_link)) {
            .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
            else => return error.TestUnexpectedResult,
        }
    }

    try testing.expect(!fsutil.exists(local_clone_path));
    try testing.expect(fsutil.exists(new_clone_path));
}

test "run: resumes a promote whose clone moved before any marker was written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    // Both projects are still on the "local:scratch" pseudo-URL, as if the
    // prior run's rename succeeded but failed before its very first marker
    // write - no sibling marker survives to name the origin.
    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos_a });

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = repos_b });

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, new_clone_path, fake_origin);

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(local_clone_path));

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "2 marker(s) updated") != null);

    for ([_][]const u8{ "first", "second" }) |proj_name| {
        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", proj_name, marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings(fake_origin, loaded.repos.get("scratch").?);

        const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", proj_name, "code", "scratch" });
        switch (try fsutil.linkState(arena, code_link)) {
            .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
            else => return error.TestUnexpectedResult,
        }
    }

    try testing.expect(!fsutil.exists(local_clone_path));
    try testing.expect(fsutil.exists(new_clone_path));
}

test "run: promoting the last local repo prunes the emptied code_root/local/ dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, local_clone_path, fake_origin);

    const local_dir = std.fs.path.dirname(local_clone_path).?;
    try testing.expect(fsutil.exists(local_dir));

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(!fsutil.exists(local_dir));
}

test "run: promoting one of two local repos leaves code_root/local/ in place for the other" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try cloneAsLocalRepo(&sb, bare, local_clone_path, fake_origin);

    const other_local_path = try identity.local("other").clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(other_local_path);

    const local_dir = std.fs.path.dirname(local_clone_path).?;

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(fsutil.exists(local_dir));
    try testing.expect(fsutil.exists(other_local_path));
}

test "run: a local clone missing from both the old and new path is a hard error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(local_clone_path));

    const got = try testutil.runCmd(arena, command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not found at") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, local_clone_path) != null);
}
