//! `holt org rename <old-org> <new-org> [--yes]`: moves every project
//! currently in <old-org> to <new-org>, keeping each project's name. Refuses
//! atomically (moving nothing) if any destination would collide with an
//! existing project - including a same-name project already in <new-org>,
//! which makes merging into an org that has unrelated projects safe as long
//! as no name collides. Clones under code_root are never touched.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const ui = @import("../ui.zig");
const fsutil = @import("../fsutil.zig");
const projectlock = @import("../projectlock.zig");
const marker = @import("../marker.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");
const hub = @import("../hub.zig");

const RenameSpec = struct {
    old_org: cli.spec.Pos([]const u8, .{ .complete = app.cat(.org), .help = "the org to rename" }),
    new_org: cli.spec.Pos([]const u8, .{ .complete = app.cat(.org), .help = "the new org name (may already exist, if no project name collides)" }),
    yes: cli.spec.Flag(.{ .short = 'y', .help = "skip the confirmation prompt" }),
};

const rename_command = app.command(RenameSpec, .{
    .name = "rename",
    .summary = "Rename an org, moving every project in it",
    .usage = "holt org rename <old-org> <new-org> [--yes]",
    .group = .maintain,
    .details =
    \\Moves every project in <old-org> to <new-org>, keeping each project's
    \\name. Refuses atomically, moving nothing, if any destination project
    \\would collide with an existing one. Merging into an org that already
    \\has other projects works as long as no name collides. Clones under
    \\Code/ are never touched.
    \\
    \\Example:
    \\  holt org rename acme corp
    ,
}, runRename);

pub const command: app.Command = .{
    .name = "org",
    .summary = "Manage orgs (rename an org, moving every project in it)",
    .usage = "holt org rename <old-org> <new-org> [--yes]",
    .group = .maintain,
    .subcommands = &.{rename_command},
    .needs_context = true,
    .run = runFallback,
};

/// `holt org` with no known subcommand: there is only `rename`, so guide the
/// user to it rather than doing nothing.
fn runFallback(ctx: *app.Ctx) anyerror!u8 {
    return app.usageError(ctx, "usage: holt org rename <old-org> <new-org>", .{});
}

fn runRename(ctx: *app.Ctx, a: cli.args.Args(RenameSpec)) anyerror!u8 {
    const old_org = a.old_org;
    const new_org = a.new_org;
    const yes = a.yes;

    if (std.mem.eql(u8, old_org, new_org)) {
        try ctx.err.writeAll("holt: the source and target org are the same\n");
        return 1;
    }

    for ([_][]const u8{ old_org, new_org }) |org| {
        if (common.validateSegment(.org, org)) |why| {
            try ctx.err.print("holt: invalid org name \"{s}\": {s}\n", .{ org, why });
            return 1;
        }
    }

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const projects_root = try ws.projectsRoot(alloc);
    const archive_root = try ws.archiveRoot(alloc);

    const all = try ws.list(alloc);
    var members: std.ArrayList(project_mod.Project) = .empty;
    for (all) |p| {
        if (std.mem.eql(u8, p.org, old_org)) try members.append(alloc, p);
    }

    const archived = try archivedNames(alloc, archive_root, old_org);

    if (members.items.len == 0 and archived.len == 0) {
        try ctx.err.print("holt: no projects in org \"{s}\"\n", .{old_org});
        return 1;
    }

    // A destination collides if either tree already holds that name under the
    // new org; check both before moving anything so a refusal is atomic.
    var collisions: std.ArrayList([]const u8) = .empty;
    for (members.items) |p| {
        if (try destCollides(alloc, projects_root, archive_root, new_org, p.name)) try collisions.append(alloc, p.name);
    }
    for (archived) |name| {
        if (try destCollides(alloc, projects_root, archive_root, new_org, name)) try collisions.append(alloc, name);
    }
    if (collisions.items.len > 0) {
        for (collisions.items) |name| {
            try ctx.err.print("holt: cannot rename org: {s}/{s} already exists\n", .{ new_org, name });
        }
        return 1;
    }

    if (!yes) {
        var names: std.ArrayList(u8) = .empty;
        var first = true;
        for (members.items) |p| {
            if (!first) try names.appendSlice(alloc, ", ");
            try names.appendSlice(alloc, p.name);
            first = false;
        }
        for (archived) |name| {
            if (!first) try names.appendSlice(alloc, ", ");
            try names.appendSlice(alloc, name);
            try names.appendSlice(alloc, " (archived)");
            first = false;
        }
        const total = members.items.len + archived.len;
        const message = try std.fmt.allocPrint(alloc, "rename org {s} -> {s} ({d} projects: {s})?", .{ old_org, new_org, total, names.items });
        if (!try ui.confirm(ctx.out, message)) {
            try ctx.out.writeAll("org rename cancelled\n");
            return 0;
        }
    }

    // No rollback: this loop moves projects one at a time. A mid-loop failure
    // reports what got moved, what failed, and what was skipped, then stops -
    // re-running the identical command converges, since already-moved projects
    // drop out of the old org.
    var moved_names: std.ArrayList([]const u8) = .empty;

    for (members.items, 0..) |p, idx| {
        // Lock each project across its own move; the org rename is a sequence
        // of per-project moves, each serialized against that project's editors.
        var lock = try projectlock.acquire(alloc, p.content_path);
        defer lock.release();
        common.moveProject(ctx, &ws, &p, new_org, p.name) catch {
            var rest: std.ArrayList([]const u8) = .empty;
            for (members.items[idx + 1 ..]) |q| try rest.append(alloc, q.name);
            for (archived) |nm| try rest.append(alloc, nm);
            try reportRenameProgress(ctx, old_org, new_org, moved_names.items, p.name, rest.items);
            return 1;
        };
        try moved_names.append(alloc, p.name);
    }

    // Archived projects have no hub; move the content dir and rewrite the
    // marker's self-description, nothing more.
    for (archived, 0..) |name, idx| {
        const from = try std.fs.path.join(alloc, &.{ archive_root, old_org, name });
        const to = try std.fs.path.join(alloc, &.{ archive_root, new_org, name });
        common.moveDir(ctx, from, to) catch {
            var rest: std.ArrayList([]const u8) = .empty;
            for (archived[idx + 1 ..]) |nm| try rest.append(alloc, nm);
            try reportRenameProgress(ctx, old_org, new_org, moved_names.items, name, rest.items);
            return 1;
        };

        const marker_path = try std.fs.path.join(alloc, &.{ to, marker.marker_basename });
        var m = try marker.load(alloc, marker_path, null);
        m.org = new_org;
        try marker.save(&m, marker_path);
        try moved_names.append(alloc, name);
    }

    const old_org_content = try std.fs.path.join(alloc, &.{ projects_root, old_org });
    fsutil.rmdirIfEmpty(old_org_content);
    const old_org_archive = try std.fs.path.join(alloc, &.{ archive_root, old_org });
    fsutil.rmdirIfEmpty(old_org_archive);
    const old_org_hub = try std.fs.path.join(alloc, &.{ ws.cfg.hub_root, old_org });
    fsutil.rmdirIfEmpty(old_org_hub);

    try ctx.out.print("renamed org {s} -> {s} ({d} projects, {d} archived)\n", .{ old_org, new_org, members.items.len, archived.len });
    return 0;
}

/// Renders which projects were moved to the new org, which one failed, and
/// which were not attempted when an org rename stops partway, plus the re-run
/// that converges.
fn reportRenameProgress(ctx: *app.Ctx, old_org: []const u8, new_org: []const u8, moved: []const []const u8, failed: []const u8, not_attempted: []const []const u8) !void {
    try ctx.err.print("holt: org rename {s} -> {s} stopped partway\n", .{ old_org, new_org });
    try ctx.err.print("  moved to {s}: ", .{new_org});
    try writeNameList(ctx, moved);
    try ctx.err.print("\n  failed: {s}\n  not attempted: ", .{failed});
    try writeNameList(ctx, not_attempted);
    try ctx.err.print("\nre-run \"holt org rename {s} {s}\" to finish\n", .{ old_org, new_org });
}

fn writeNameList(ctx: *app.Ctx, names: []const []const u8) !void {
    if (names.len == 0) {
        try ctx.err.writeAll("(none)");
        return;
    }
    for (names, 0..) |name, i| {
        if (i != 0) try ctx.err.writeAll(", ");
        try ctx.err.writeAll(name);
    }
}

/// Names of the archived projects under `<archive_root>/<org>` (dirs holding
/// a marker file). Empty when the org has no archive dir at all.
fn archivedNames(alloc: std.mem.Allocator, archive_root: []const u8, org: []const u8) ![][]const u8 {
    const org_dir = try std.fs.path.join(alloc, &.{ archive_root, org });
    var names: std.ArrayList([]const u8) = .empty;

    var dir: ?std.Io.Dir = std.Io.Dir.openDirAbsolute(fsutil.io(), org_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => null,
        else => return err,
    };
    if (dir) |*d| {
        defer d.close(fsutil.io());
        var it = d.iterate();
        while (try it.next(fsutil.io())) |entry| {
            if (entry.kind != .directory) continue;
            const marker_path = try std.fs.path.join(alloc, &.{ org_dir, entry.name, marker.marker_basename });
            if (!fsutil.exists(marker_path)) continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }
    return names.toOwnedSlice(alloc);
}

/// True if either tree already holds `<new_org>/<name>`.
fn destCollides(alloc: std.mem.Allocator, projects_root: []const u8, archive_root: []const u8, new_org: []const u8, name: []const u8) !bool {
    const in_projects = try std.fs.path.join(alloc, &.{ projects_root, new_org, name });
    if (fsutil.exists(in_projects)) return true;
    const in_archive = try std.fs.path.join(alloc, &.{ archive_root, new_org, name });
    return fsutil.exists(in_archive);
}

test "run: rename moves every project in the org, rebuilds hubs, and leaves an unrelated org untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "a", .{ .version = 1, .org = "acme", .name = "a", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "b", .{ .version = 1, .org = "acme", .name = "b", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "work", "c", .{ .version = 1, .org = "work", .name = "c", .repos = .empty });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "a", "docs" }));
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "b", "docs" }));
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "work", "c", "docs" }));

    for (&[_][]const u8{ "acme/a", "acme/b", "work/c" }) |query| {
        const p = switch (try ws.find(arena, query)) {
            .one => |proj| proj,
            else => return error.TestUnexpectedResult,
        };
        _ = try hub.reconcile(arena, &ws, &p, false);
    }

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "me", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "renamed org acme -> me (2 projects, 0 archived)") != null);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(!fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(!fsutil.exists(old_org_hub));

    for ([_][]const u8{ "a", "b" }) |name| {
        const new_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "me", name });
        try testing.expect(fsutil.exists(new_content));

        const marker_path = try std.fs.path.join(arena, &.{ new_content, marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings("me", loaded.org);
        try testing.expectEqualStrings(name, loaded.name);

        const new_hub_docs = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "me", name, "docs" });
        switch (try fsutil.linkState(arena, new_hub_docs)) {
            .symlink => {},
            else => return error.TestUnexpectedResult,
        }
    }

    const work_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "work", "c" });
    try testing.expect(fsutil.exists(work_content));
    const work_hub_docs = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "work", "c", "docs" });
    switch (try fsutil.linkState(arena, work_hub_docs)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: rename moves an org's active and archived projects, clearing the old org from every tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "live", .{ .version = 1, .org = "acme", .name = "live", .repos = .empty });
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "old", .{ .version = 1, .org = "acme", .name = "old", .repos = .empty });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "live", "docs" }));

    const p = switch (try ws.find(arena, "acme/live")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "corp", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "renamed org acme -> corp (1 projects, 1 archived)") != null);

    const live_marker_path = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "corp", "live", marker.marker_basename });
    try testing.expect(fsutil.exists(live_marker_path));
    try testing.expectEqualStrings("corp", (try marker.load(arena, live_marker_path, null)).org);

    const arch_marker_path = try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "corp", "old", marker.marker_basename });
    try testing.expect(fsutil.exists(arch_marker_path));
    try testing.expectEqualStrings("corp", (try marker.load(arena, arch_marker_path, null)).org);

    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" })));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme" })));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" })));

    const new_hub_docs = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "corp", "live", "docs" });
    switch (try fsutil.linkState(arena, new_hub_docs)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: rename an org that has only archived projects moves them and reports the archived count" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "old", .{ .version = 1, .org = "acme", .name = "old", .repos = .empty });

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "corp", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "renamed org acme -> corp (0 projects, 1 archived)") != null);

    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "corp", "old", marker.marker_basename })));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme" })));
}

test "run: rename refuses atomically on an archive-side collision, moving nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "old", .{ .version = 1, .org = "acme", .name = "old", .repos = .empty });
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "corp", "old", .{ .version = 1, .org = "corp", .name = "old", .repos = .empty });

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "corp", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "corp/old already exists") != null);

    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" })));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme", "old" })));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "corp", "widget" })));
}

test "run: a mid-loop move failure reports progress and the rename converges on re-run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    for ([_][]const u8{ "a", "b", "c" }) |name| {
        try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", name, .{ .version = 1, .org = "acme", .name = name, .repos = .empty });
        const query = try std.fmt.allocPrint(arena, "acme/{s}", .{name});
        const p = switch (try ws.find(arena, query)) {
            .one => |proj| proj,
            else => return error.TestUnexpectedResult,
        };
        _ = try hub.reconcile(arena, &ws, &p, false);
    }

    // Block the hub rebuild for the 2nd project (sorted a, b, c) with a real
    // file where its new hub dir must be created: its move fails after a and
    // before c.
    const new_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "corp" });
    try fsutil.ensureDir(new_org_hub);
    const blocker = try std.fs.path.join(arena, &.{ new_org_hub, "b" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = blocker, .data = "x" });

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "corp", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "stopped partway") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "moved to corp: a") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "failed: b") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "not attempted: c") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "re-run \"holt org rename acme corp\"") != null);

    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "corp", "a" })));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "c" })));

    try std.Io.Dir.cwd().deleteFile(fsutil.io(), blocker);
    const again = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "corp", "--yes" });
    try testing.expectEqual(@as(u8, 0), again.code);

    for ([_][]const u8{ "a", "b", "c" }) |name| {
        try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "corp", name })));
    }
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" })));
}

test "run: rename merges into an existing org when no project name collides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "a", .{ .version = 1, .org = "acme", .name = "a", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "b", .{ .version = 1, .org = "acme", .name = "b", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "me", "x", .{ .version = 1, .org = "me", .name = "x", .repos = .empty });

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "me", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    for ([_][]const u8{ "a", "b", "x" }) |name| {
        const content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "me", name });
        try testing.expect(fsutil.exists(content));
    }
}

test "run: refuses atomically when a destination name collides, moving nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "a", .{ .version = 1, .org = "acme", .name = "a", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "b", .{ .version = 1, .org = "acme", .name = "b", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "me", "a", .{ .version = 1, .org = "me", .name = "a", .repos = .empty });

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "me", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "me/a already exists") != null);

    const acme_a = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "a" });
    try testing.expect(fsutil.exists(acme_a));
    const acme_b = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "b" });
    try testing.expect(fsutil.exists(acme_b));
}

test "run: renaming an org to itself reports the clearer message instead of false collisions, moving nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "a", .{ .version = 1, .org = "acme", .name = "a", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "b", .{ .version = 1, .org = "acme", .name = "b", .repos = .empty });

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "acme", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expectStringEndsWith(got.err, "holt: the source and target org are the same\n");

    const acme_a = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "a" });
    try testing.expect(fsutil.exists(acme_a));
    const acme_b = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "b" });
    try testing.expect(fsutil.exists(acme_b));
}

test "run: renaming an org with no projects reports no projects and exits 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "other", "proj", .{ .version = 1, .org = "other", .name = "proj", .repos = .empty });

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", "me", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "no projects in org \"acme\"") != null);
}

test "run: a new org that traverses or contains a slash is rejected, moving nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "a", .{ .version = 1, .org = "acme", .name = "a", .repos = .empty });

    for ([_][]const u8{ "..", "x/y" }) |bad| {
        const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme", bad, "--yes" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "invalid org name") != null);
    }

    const source = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "a" });
    try testing.expect(fsutil.exists(source));
    const escape = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "..", "a" });
    try testing.expect(!fsutil.exists(escape));
}

test "run: an old org that traverses is rejected before scanning projects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "..", "corp", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "invalid org name") != null);
}

test "run: an unrecognized subcommand is a usage error naming the accepted form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try testutil.runCmd(arena, command.run, null, &.{});
    try testing.expectEqual(@as(u8, 2), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt org rename <old-org> <new-org>") != null);
}

test "run: rename with missing old-org/new-org args is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try testutil.runCmd(arena, rename_command.run, null, &.{});
    try testing.expectEqual(@as(u8, 2), got.code);
}
