//! `holt delete <project> [--yes]`: deletes a project's CONTENT dir and its
//! hub. Clones under code_root always stay - after deleting, every clone
//! left with no remaining project reference is reported so the caller can
//! prune it manually. Requires interactive confirmation unless `--yes` is
//! passed.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const hub = @import("../hub.zig");
const ui = @import("../ui.zig");
const fsutil = @import("../fsutil.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    project: cli.spec.Pos([]const u8, .{ .complete = app.cat(.project), .help = "the project to delete" }),
    yes: cli.spec.Flag(.{ .short = 'y', .help = "skip the confirmation prompt" }),
};

pub const command = app.command(Spec, .{
    .name = "delete",
    .summary = "Delete a project's content and hub (clones are kept)",
    .usage = "holt delete <project> [--yes]",
    .group = .system,
    .needs_context = true,
    .details =
    \\Danger: permanently deletes the project's content dir and hub. Clones
    \\under Code/ are always kept; requires typed confirmation unless --yes.
    \\
    \\Example:
    \\  holt delete myproj --yes
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const project_query = a.project;
    const yes = a.yes;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const p = (try common.resolveOne(ctx, project_query)) orelse return 1;
    const qualified = try p.qualified(alloc);

    if (!yes) {
        const prompt = try std.fmt.allocPrint(alloc, "delete {s} (content + hub; clones are kept). Type {s} to confirm:", .{ qualified, qualified });
        if (!try ui.confirmTyped(ctx.out, prompt, qualified)) {
            try ctx.out.print("aborted: {s} not deleted\n", .{qualified});
            return 0;
        }
    }

    // Take the lock only now (not across the confirmation prompt), then
    // serialize the destructive removal against concurrent per-project edits.
    var lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
    defer lock.release();

    // Remove the hub first, then the content with the marker deleted LAST: a
    // content-delete failure then leaves the marker in place, so the project
    // stays listable and this command stays re-runnable rather than stranding
    // an invisible half-deleted project.
    try hub.removeHub(&p);

    var failed_path: []const u8 = p.content_path;
    removeContentMarkerLast(alloc, p.content_path, &failed_path) catch |err| {
        try ctx.err.print("holt: failed to delete {s}: {s} (run \"holt delete {s}\" again)\n", .{ failed_path, @errorName(err), qualified });
        return 1;
    };

    if (std.fs.path.dirname(p.content_path)) |old_org_dir| fsutil.rmdirIfEmpty(old_org_dir);
    try ctx.out.print("deleted {s}\n", .{qualified});

    for (p.marker.repos.keys()) |repo_name| {
        const id = p.repoIdentity(alloc, repo_name) catch continue;
        const others = try ws.projectsUsing(alloc, id);
        if (others.len == 0) {
            const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
            try ctx.out.print("clone at {s} is now unreferenced; remove it manually if no longer needed\n", .{try fsutil.contractTilde(alloc, app.envOf(ctx), clone_path)});
        }
    }

    return 0;
}

/// Deletes everything under `content_path`, removing the marker file LAST so a
/// partial failure leaves the marker present (project still listable, delete
/// still re-runnable). `failed` names the entry that could not be removed when
/// an error is returned.
fn removeContentMarkerLast(alloc: std.mem.Allocator, content_path: []const u8, failed: *[]const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const dio = fsutil.io();
    failed.* = content_path;

    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = cwd.openDir(dio, content_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer dir.close(dio);
        var it = dir.iterate();
        while (try it.next(dio)) |entry| {
            if (std.mem.eql(u8, entry.name, marker.marker_basename)) continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }

    for (names.items) |name| {
        const entry_path = try std.fs.path.join(alloc, &.{ content_path, name });
        cwd.deleteTree(dio, entry_path) catch |err| {
            failed.* = entry_path;
            return err;
        };
    }

    const marker_path = try std.fs.path.join(alloc, &.{ content_path, marker.marker_basename });
    cwd.deleteFile(dio, marker_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            failed.* = marker_path;
            return err;
        },
    };

    fsutil.rmdirIfEmpty(content_path);
}

// This test always passes --yes: ui.confirm blocks on real stdin, and a test
// run has no interactive stdin to feed it.
test "run: --yes deletes content and hub, keeps the clone, and reports it unreferenced" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = repos });

    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try fsutil.ensureDir(clone_path);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "deleted acme/widget") != null);
    // The unreferenced-clone note tilde-abbreviates the path for display.
    try testing.expect(std.mem.indexOf(u8, got.out, try fsutil.contractTilde(arena, app.envOf_current(), clone_path)) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "unreferenced") != null);

    try testing.expect(!fsutil.exists(p.content_path));
    try testing.expect(!fsutil.exists(p.hub_path));
    try testing.expect(fsutil.exists(clone_path));
}

test "run: --yes deleting the last project in an org prunes the emptied org's content and hub dirs" {
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(!fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(!fsutil.exists(old_org_hub));
}

test "run: --yes deleting one of two projects in an org leaves the org's content and hub dirs in place" {
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
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);
    const gizmo_p = switch (try ws.find(arena, "acme/gizmo")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &gizmo_p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(fsutil.exists(old_org_hub));
    const remaining_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "gizmo" });
    try testing.expect(fsutil.exists(remaining_content));
}

test "run: --yes on a project with no repos deletes cleanly with no orphan report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .{ .version = 1, .org = "acme", .name = "empty", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/empty", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "deleted acme/empty") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "unreferenced") == null);
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "nope", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "run: a partial content-delete failure keeps the marker, so the project stays listable and delete is re-runnable" {
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

    // A child inside a read-only dir cannot be removed, so deleteTree of
    // "locked" fails and the marker (deleted last) survives. Mode bits don't
    // gate access on Windows, so this whole simulation is POSIX-only.
    const locked_rel = "synced/projects/acme/widget/locked";
    try tmp.dir.createDirPath(testing.io, locked_rel ++ "/nested");
    if (builtin.os.tag != .windows) {
        try tmp.dir.setFilePermissions(testing.io, locked_rel, std.Io.File.Permissions.fromMode(0o555), .{});
        defer tmp.dir.setFilePermissions(testing.io, locked_rel, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "--yes" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "failed to delete") != null);
        try testing.expect(std.mem.indexOf(u8, got.err, "holt delete acme/widget") != null);

        const marker_path = try p.markerPath(arena);
        try testing.expect(fsutil.exists(marker_path));
        switch (try ws.find(arena, "acme/widget")) {
            .one => {},
            else => return error.TestUnexpectedResult,
        }

        // Restore perms and re-run: delete now completes fully.
        try tmp.dir.setFilePermissions(testing.io, locked_rel, std.Io.File.Permissions.fromMode(0o755), .{});
        const again = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "--yes" });
        try testing.expectEqual(@as(u8, 0), again.code);
        try testing.expect(!fsutil.exists(p.content_path));
    }
}
