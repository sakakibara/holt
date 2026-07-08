//! `holt add <project> <url>`: clones a repo (if not already cloned
//! elsewhere) and records it as a new member of an existing project's
//! marker, then reconciles the hub. A `local:<name>` argument is rejected -
//! local repos are adopted (via `holt adopt`), never created by `add`.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const common = @import("common.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const git = @import("../git.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    project: args.Pos([]const u8, .{ .complete = comp.cat(.project), .help = "the project to add the repo to" }),
    url: args.Pos([]const u8, .{ .complete = .files, .help = "a git url, or owner/repo (host/owner/repo) shorthand" }),
};

pub const command = args.command(Spec, .{
    .name = "add",
    .about = "Add a repo to a project, cloning it if not already present",
    .usage = "holt add <project> <url>",
    .group = .create,
    .details =
    \\Example:
    \\  holt add myproj https://github.com/acme/widget.git
    ,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const project_query = a.project;
    const raw = a.url;

    const ws = ctx.ws.?;
    const alloc = ctx.alloc;

    var p = (try common.resolveOne(ctx, project_query)) orelse return 1;

    // Serialize with any other holt mutating this same project, and re-read
    // the marker under the lock so the load-modify-save below acts on the
    // current state rather than a snapshot that a concurrent run may have
    // already superseded (which would silently drop that run's edit).
    var lock = try projectlock.acquire(alloc, p.content_path);
    defer lock.release();
    p.marker = try marker.load(alloc, try p.markerPath(alloc), null);

    if (std.mem.startsWith(u8, raw, "local:")) {
        try ctx.err_w.print("holt: \"{s}\" is a local repo; local repos are adopted, not created - use `holt adopt` instead\n", .{raw});
        return 1;
    }

    // Expand "owner/repo" / "host/owner/repo" shorthand to a real URL, so the
    // clone succeeds and the marker records a URL a later restore can re-clone.
    const url = identity.expand(alloc, raw) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err_w.print("holt: \"{s}\" is not a recognized git url\n", .{raw});
            return 1;
        },
        else => return err,
    };

    const id = identity.fromUrl(alloc, url) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err_w.print("holt: \"{s}\" is not a recognized git url\n", .{raw});
            return 1;
        },
        else => return err,
    };

    if (p.marker.repos.contains(id.repo)) {
        try ctx.err_w.print("holt: \"{s}\" is already a member of {s}/{s}\n", .{ id.repo, p.org, p.name });
        return 1;
    }

    const clone_path = try id.clonePath(alloc, ws.cfg.code_root);

    // Hold the clone-path lock across the clone and the marker write (after the
    // content lock, a fixed order that prevents any deadlock), so a concurrent
    // `archive --prune` cannot delete this clone between the clone landing and
    // our reference to it landing on disk.
    var clone_lock = try projectlock.acquire(alloc, clone_path);
    defer clone_lock.release();

    const cloned = common.cloneIfAbsent(ctx, url, clone_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return 1,
    };

    try p.marker.repos.put(alloc, id.repo, url);
    const marker_path = try p.markerPath(alloc);
    try marker.save(&p.marker, marker_path);

    _ = try hub.reconcile(alloc, &ws, &p, false);

    try ctx.out.print("added {s} to {s}/{s}\n", .{ id.repo, p.org, p.name });
    if (cloned) {
        try ctx.out.print("cloned {s} -> {s}\n", .{ url, clone_path });
    } else {
        try ctx.out.print("using existing clone at {s}\n", .{clone_path});
    }
    return 0;
}

test "run: adding a fresh repo clones it and records it in the marker + hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const url = "https://holt-test.invalid/acme/widget";
    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "widget", url });
    try testing.expectEqual(@as(u8, 0), got.code);

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    const branch = try git.currentBranch(arena, clone_path);
    try testing.expect(branch != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings(url, loaded.repos.get("widget").?);
}

test "run: adding the same repo to a second project shares the one clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = .empty });

    const url = "https://holt-test.invalid/acme/widget";
    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);

    // Simulates a clone that already happened (via a prior `new`/`add`): a real,
    // complete clone at the identity path. Fresh clone success itself is covered
    // elsewhere, so this test only proves the shared-clone skip and marker/hub
    // wiring - but the clone must be genuine now that the skip path rejects an
    // incomplete one.
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    try git.clone(arena, bare, clone_path, null);
    const stat_before = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_path, .{});

    const first = try testutil.runCmd(arena, command.run, ws, &.{ "first", url });
    try testing.expectEqual(@as(u8, 0), first.code);

    const second = try testutil.runCmd(arena, command.run, ws, &.{ "second", url });
    try testing.expectEqual(@as(u8, 0), second.code);

    const stat_after = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_path, .{});
    try testing.expectEqual(stat_before.inode, stat_after.inode);
    try testing.expect(std.mem.indexOf(u8, second.out, "using existing clone") != null);

    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "second", "code", "widget" });
    switch (try fsutil.linkState(arena, hub_path)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: a repo already a member of the project is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "https://holt-test.invalid/acme/widget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already a member") != null);
}

test "run: a local: url is rejected with adopt guidance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "local:scratch" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "adopt") != null);
}

test "run: a parseable but unreachable url surfaces git's cause, not a bare error name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    // Loopback with nothing listening: connection refused immediately, no
    // DNS or network dependency, so the failure is fast and deterministic.
    const url = "git://127.0.0.1:1/acme/widget";
    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", url });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "failed to clone") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, url) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "GitCloneFailed") == null);

    const id = try identity.fromUrl(arena, url);
    const owner_dir = try std.fs.path.join(arena, &.{ ws.cfg.code_root, id.host, id.owner });
    try testing.expect(!fsutil.exists(owner_dir));
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "nope", "https://holt-test.invalid/acme/widget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}
