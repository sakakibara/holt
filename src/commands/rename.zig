//! `holt rename <old> <new-org>/<new-name>`: moves a project's CONTENT dir
//! to a new org/name, rewrites its marker, and moves its hub to match. The
//! clone under code_root never moves - only the synced-tree location and
//! marker change.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const common = @import("common.zig");
const marker = @import("../marker.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const projectlock = @import("../projectlock.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    old: args.Pos([]const u8, .{ .complete = comp.cat(.project), .help = "the project to rename" }),
    new_name: args.Pos([]const u8, .{ .help = "the new <org>/<name>" }),
};

pub const command = args.command(Spec, .{
    .name = "rename",
    .about = "Rename a project, moving its content and rebuilding its hub",
    .usage = "holt rename <old> <new-org>/<new-name>",
    .group = .maintain,
    .details =
    \\Example:
    \\  holt rename acme/widget acme/widget-core
    ,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const old_query = a.old;
    const new_spec = a.new_name;

    const ws = ctx.ws.?;
    const alloc = ctx.alloc;

    const p = (try common.resolveOne(ctx, old_query)) orelse return 1;

    // Serialize the content move against concurrent per-project mutators.
    var lock = try projectlock.acquire(alloc, p.content_path);
    defer lock.release();

    const target = common.parseOrgName(new_spec) orelse {
        ctx.args.message = try common.parseOrgNameMessage(alloc, new_spec);
        return error.UsageError;
    };

    const projects_root = try ws.projectsRoot(alloc);
    const dest_path = try std.fs.path.join(alloc, &.{ projects_root, target.org, target.name });

    if (std.mem.eql(u8, p.content_path, dest_path)) {
        try ctx.err_w.writeAll("holt: source and target are the same project\n");
        return 1;
    }
    if (fsutil.exists(dest_path)) {
        try ctx.err_w.print("holt: {s}/{s} already exists in projects\n", .{ target.org, target.name });
        return 1;
    }

    const old_org_dir = std.fs.path.dirname(p.content_path).?;

    common.moveProject(ctx, &ws, &p, target.org, target.name) catch return 1;
    fsutil.rmdirIfEmpty(old_org_dir);

    try ctx.out.print("renamed {s}/{s} -> {s}/{s}\n", .{ p.org, p.name, target.org, target.name });
    return 0;
}

test "run: moves content, rewrites the marker, and rebuilds the hub at the new name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget", "docs" }));
    const old_p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &old_p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "corp/gadget" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "renamed acme/widget -> corp/gadget") != null);

    const old_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(!fsutil.exists(old_content));
    const new_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "corp", "gadget" });
    try testing.expect(fsutil.exists(new_content));

    const marker_path = try std.fs.path.join(arena, &.{ new_content, marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("corp", loaded.org);
    try testing.expectEqualStrings("gadget", loaded.name);

    try testing.expect(!fsutil.exists(old_p.hub_path));
    const new_hub_docs = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "corp", "gadget", "docs" });
    switch (try fsutil.linkState(arena, new_hub_docs)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: a hub rebuild failure after the content move points the user at holt sync, content already moved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    // A read-only hub_root makes creating the new hub dir fail, after the
    // content has already moved to its new home. Mode bits don't gate
    // access on Windows, so this whole simulation is POSIX-only.
    if (builtin.os.tag != .windows) {
        try tmp.dir.setFilePermissions(testing.io, "hub", std.Io.File.Permissions.fromMode(0o555), .{});
        defer tmp.dir.setFilePermissions(testing.io, "hub", std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "corp/gadget" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "holt sync") != null);

        const new_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "corp", "gadget" });
        try testing.expect(fsutil.exists(new_content));
    }
}

test "run: refuses when the target project already exists, leaving the source in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "corp", "gadget", .{ .version = 1, .org = "corp", .name = "gadget", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "corp/gadget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists") != null);

    const old_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(old_content));
}

test "run: source and target are the same project reports the clearer message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "acme/widget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expectStringEndsWith(got.err, "holt: source and target are the same project\n");

    const content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(content));
}

test "run: renaming the last project out of an org prunes the emptied org's content and hub dirs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    const old_p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &old_p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "corp/gadget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(!fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(!fsutil.exists(old_org_hub));
}

test "run: renaming one of two projects out of an org leaves the org's content and hub dirs in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "gizmo", .{ .version = 1, .org = "acme", .name = "gizmo", .repos = .empty });
    const widget_p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &widget_p, false);
    const gizmo_p = switch (try ws.find(arena, "acme/gizmo")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &gizmo_p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "corp/gadget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(fsutil.exists(old_org_hub));
    const remaining_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "gizmo" });
    try testing.expect(fsutil.exists(remaining_content));
}

test "run: a malformed <new-org>/<new-name> spec is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    var cli_args = try cli.Args.init(arena, &.{ "acme/widget", "no-slash" });
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = ws, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };
    try testing.expectError(error.UsageError, command.run(&ctx));
}

test "run: a target that traverses out of the roots is rejected, leaving the source in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    try testing.expectError(error.UsageError, testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "acme/../x" }));

    const source = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(source));
    const escape = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "..", "x" });
    try testing.expect(!fsutil.exists(escape));
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "nope", "corp/gadget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}
