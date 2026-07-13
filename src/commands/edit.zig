//! `holt edit <project>`: opens the project's docs directory in `$EDITOR`.
//! `holt edit <project>/<repo>` opens that repo's real clone path instead.
//! Errors cleanly when `$EDITOR` isn't set rather than guessing an editor.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const workspace = @import("../workspace.zig");
const common = @import("common.zig");
const path = @import("path.zig");
const editor = @import("../editor.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    project: cli.spec.Pos([]const u8, .{ .complete = app.cat(.project_repo), .help = "the project or project/repo to open" }),
};

pub const command = app.command(Spec, .{
    .name = "edit",
    .summary = "Open a project's docs directory (or a repo's clone) in $EDITOR",
    .usage = "holt edit <project>|<project>/<repo>",
    .group = .maintain,
    .needs_context = true,
    .details =
    \\A bare <project> opens its docs directory; <project>/<repo> opens that
    \\member repo's real clone path under code_root.
    \\
    \\Example:
    \\  holt edit myproj
    \\  holt edit myproj/backend
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const query = a.project;

    const ws = ctx.context.?.ws;

    const target = (try resolveTarget(ctx, ws, query)) orelse return 1;

    // The editor opens in the target directory itself, so relative paths a
    // user types inside it resolve against the docs dir / clone.
    return editor.open(ctx, target, target);
}

/// The path `edit` should open: a bare project resolves to its docs dir
/// (created if absent), a `<project>/<repo>` query to the repo's real clone
/// path. Null (after reporting why on ctx.err) when nothing resolves. The
/// whole query is tried as a project first, so an "org/name" project opens
/// its docs and only a genuine project/repo pair reaches the repo branch.
fn resolveTarget(ctx: *app.Ctx, ws: workspace.Workspace, query: []const u8) !?[]const u8 {
    const alloc = ctx.alloc;

    const whole = try ws.find(alloc, query);
    switch (whole) {
        .one => |p| {
            const docs_path = try std.fs.path.join(alloc, &.{ p.content_path, "docs" });
            try fsutil.ensureDir(docs_path);
            return docs_path;
        },
        .none, .ambiguous => {},
    }

    if (std.mem.lastIndexOfScalar(u8, query, '/')) |slash| {
        const project_query = query[0..slash];
        const repo_query = query[slash + 1 ..];
        if (project_query.len > 0 and repo_query.len > 0) {
            return path.resolveRepoPath(ctx, ws, project_query, repo_query);
        }
    }

    _ = try common.reportProjectFailure(ctx, query, whole);
    return null;
}

test "run: spawns $EDITOR with the docs path as both argv[1] and cwd" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const marker_path = try std.fs.path.join(arena, &.{ root, "editor-invocation.txt" });
    const script_path = try testutil.writeFakeEditor(arena, root, marker_path, .{ .args = 1, .cwd = true });

    const override = try testutil.EnvScope.install(arena, &.{.{ "EDITOR", script_path }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const docs_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", "docs" });
    try testing.expect(fsutil.exists(docs_path));

    const recorded = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), marker_path, arena, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, recorded, "\r\n"), '\n');
    try testing.expectEqualStrings(docs_path, std.mem.trimEnd(u8, lines.next().?, "\r"));
    try testing.expectEqualStrings(docs_path, std.mem.trimEnd(u8, lines.next().?, "\r"));
}

test "run: <project>/<repo> opens the repo's real clone path, not the docs dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = repos });

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "backend" });
    try fsutil.ensureDir(clone_path);

    const marker_path = try std.fs.path.join(arena, &.{ root, "editor-invocation.txt" });
    const script_path = try testutil.writeFakeEditor(arena, root, marker_path, .{ .args = 1, .cwd = true });

    const override = try testutil.EnvScope.install(arena, &.{.{ "EDITOR", script_path }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{"widget/backend"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const recorded = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), marker_path, arena, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, recorded, "\r\n"), '\n');
    try testing.expectEqualStrings(clone_path, std.mem.trimEnd(u8, lines.next().?, "\r"));

    const docs_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget", "docs" });
    try testing.expect(std.mem.indexOf(u8, recorded, docs_path) == null);
}

test "run: a project with no docs dir yet still gets one created for the editor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const docs_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", "docs" });
    try testing.expect(!fsutil.exists(docs_path));

    const marker_path = try std.fs.path.join(arena, &.{ root, "editor-invocation.txt" });
    const script_path = try testutil.writeFakeEditor(arena, root, marker_path, .{ .args = 1, .cwd = true });

    const override = try testutil.EnvScope.install(arena, &.{.{ "EDITOR", script_path }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(fsutil.exists(docs_path));
}

test "run: missing $EDITOR errors cleanly, without ever spawning anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const override = try testutil.EnvScope.without(arena, &.{"EDITOR"});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "EDITOR") != null);
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{"nope"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}
