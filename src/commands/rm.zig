//! `holt rm <project> <repo>`: drops a repo from a project's marker and
//! reconciles the hub (the stale `code/<repo>` link is swept). The shared
//! clone under code_root is never deleted - other projects may still
//! reference it, so removal reports whether any still do.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const workspace = @import("../workspace.zig");
const common = @import("common.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    project: cli.spec.Pos([]const u8, .{ .complete = app.cat(.project), .help = "the project to remove the repo from" }),
    repo: cli.spec.Pos([]const u8, .{ .complete = app.cat(.repo), .help = "the member repo to remove" }),
};

pub const command = app.command(Spec, .{
    .name = "rm",
    .summary = "Remove a repo from a project (the shared clone stays on disk)",
    .usage = "holt rm <project> <repo>",
    .group = .create,
    .needs_context = true,
    .details =
    \\Example:
    \\  holt rm myproj widget
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const project_query = a.project;
    const repo_name = a.repo;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    var p = (try common.resolveOne(ctx, project_query)) orelse return 1;

    // Lock and re-read so a concurrent holt mutating this project cannot make
    // this remove clobber (or be clobbered by) its edit.
    var lock = try projectlock.acquire(alloc, p.content_path);
    defer lock.release();
    p.marker = try marker.load(alloc, try p.markerPath(alloc), null);

    if (!p.marker.repos.contains(repo_name)) {
        try ctx.err.print("holt: \"{s}\" is not a member of {s}/{s}\n", .{ repo_name, p.org, p.name });
        return 1;
    }

    const id = try p.repoIdentity(alloc, repo_name);
    const clone_path = try id.clonePath(alloc, ws.cfg.code_root);

    _ = p.marker.repos.orderedRemove(repo_name);
    _ = p.marker.aliases.orderedRemove(repo_name);
    const marker_path = try p.markerPath(alloc);
    try marker.save(&p.marker, marker_path);

    _ = try hub.reconcile(alloc, &ws, &p, false);

    const others = try ws.projectsUsing(alloc, id);
    try ctx.out.print("removed {s} from {s}/{s}\n", .{ repo_name, p.org, p.name });
    if (others.len > 0) {
        try ctx.out.print("clone at {s} still used by:", .{clone_path});
        for (others) |o| {
            const qualified = try o.qualified(alloc);
            try ctx.out.print(" {s}", .{qualified});
        }
        try ctx.out.writeByte('\n');
    } else {
        try ctx.out.print("no project references {s}; clone kept\n", .{clone_path});
    }
    return 0;
}

/// A project sharing one identity (`widget`) between two projects, plus a
/// (never-fetched: rm never touches the clone) placeholder clone directory
/// standing in for what a real `new`/`add` would have cloned.
fn twoProjectsSharingOneRepo(arena: std.mem.Allocator, root: []const u8) !struct { ws: workspace.Workspace, clone_path: []const u8 } {
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos });

    var repos2: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos2.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = repos2 });

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try fsutil.ensureDir(clone_path);

    return .{ .ws = ws, .clone_path = clone_path };
}

test "run: removing from one of two referencing projects keeps the clone and names the other" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const setup = try twoProjectsSharingOneRepo(arena, root);

    // Build the hub so the stale code/ link exists to be swept.
    const first_p = switch (try setup.ws.find(arena, "first")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &setup.ws, &first_p, false);
    const second_p = switch (try setup.ws.find(arena, "second")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &setup.ws, &second_p, false);

    const got = try testutil.runCmd(arena, command.run, setup.ws, &.{ "first", "widget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(fsutil.exists(setup.clone_path));
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/second") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "still used by") != null);

    const marker_path = try std.fs.path.join(arena, &.{ setup.ws.cfg.synced_root, "projects", "acme", "first", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.repos.count());

    const code_link = try std.fs.path.join(arena, &.{ setup.ws.cfg.hub_root, "acme", "first", "code", "widget" });
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, code_link));
}

test "run: removing the last reference reports the clone as kept, still on disk" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "only", .{ .version = 1, .org = "acme", .name = "only", .repos = repos });

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try fsutil.ensureDir(clone_path);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "only", "widget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(fsutil.exists(clone_path));
    try testing.expect(std.mem.indexOf(u8, got.out, "no project references") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "clone kept") != null);
}

test "run: removing a repo drops its stale alias from the marker" {
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
    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try aliases.put(arena, "widget", "gadget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos, .aliases = aliases });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "widget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expect(!loaded.aliases.contains("widget"));
    try testing.expectEqual(@as(usize, 0), loaded.repos.count());
}

test "run: a repo not a member of the project is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "widget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not a member") != null);
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "nope", "widget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}
