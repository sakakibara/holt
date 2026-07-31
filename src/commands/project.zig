//! `holt project`: groups project lifecycle commands under the noun they
//! act on. `new <org>/<name>` creates a project's content dirs (docs/,
//! assets/, links/), its marker, and its hub - nothing else. A new project
//! has no repo members; populating it is a separate operation (`holt repo
//! get`).

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const marker = @import("../marker.zig");
const fsutil = @import("../fsutil.zig");
const project_mod = @import("../project.zig");
const common = @import("common.zig");
const hub = @import("../hub.zig");
const projectlock = @import("../projectlock.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    org_name: cli.Pos([]const u8, .{ .complete = app.cat(.org), .help = "the org/name to create" }),
};

pub const new_command = app.command(Spec, .{
    .name = "new",
    .summary = "Create a new project",
    .usage = "holt project new <org>/<name>",
    .group = .create,
    .needs_context = true,
    .details =
    \\Creates the project's content dirs, marker, and hub. The hub path is the
    \\sole line on stdout, so `cd $(holt project new acme/widget)` drops you
    \\into it. A new project has no repos; add one with `holt repo get`.
    \\
    \\Example:
    \\  holt project new acme/widget
    ,
}, runNew);

pub const command: app.Command = .{
    .name = "project",
    .summary = "Create, remove, rename, and archive projects",
    .usage = "holt project <new|remove|rename|archive|unarchive> ...",
    .group = .create,
    .subcommands = &.{new_command},
    .needs_context = true,
    .run = runFallback,
};

fn runFallback(ctx: *app.Ctx) anyerror!u8 {
    return app.usageError(ctx, "usage: holt project <new|remove|rename|archive|unarchive> ...", .{});
}

fn runNew(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const spec = a.org_name;

    const on = common.parseOrgName(spec) orelse {
        return app.usageError(ctx, "{s}", .{try common.parseOrgNameMessage(ctx.alloc, spec)});
    };

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const content_path = try std.fs.path.join(alloc, &.{ ws.cfg.synced_root, "projects", on.org, on.name });
    const marker_path = try std.fs.path.join(alloc, &.{ content_path, marker.marker_basename });
    if (fsutil.exists(marker_path)) {
        try ctx.err.print("holt: project \"{s}/{s}\" already exists\n", .{ on.org, on.name });
        return 1;
    }

    const archive_root = try ws.archiveRoot(alloc);
    const archive_marker = try std.fs.path.join(alloc, &.{ archive_root, on.org, on.name, marker.marker_basename });
    if (fsutil.exists(archive_marker)) {
        try ctx.err.print("holt: {s}/{s} already exists in archive (restore or delete it first)\n", .{ on.org, on.name });
        return 1;
    }

    var lock = try projectlock.acquire(alloc, app.envOf(ctx), content_path);
    defer lock.release();

    for ([_][]const u8{ "docs", "assets", "links" }) |sub| {
        try fsutil.ensureDir(try std.fs.path.join(alloc, &.{ content_path, sub }));
    }

    var m: marker.Marker = .{ .version = marker.marker_version, .org = on.org, .name = on.name, .repos = .empty };
    try marker.save(&m, marker_path);

    const hub_path = try std.fs.path.join(alloc, &.{ ws.cfg.hub_root, on.org, on.name });
    const p: project_mod.Project = .{
        .org = on.org,
        .name = on.name,
        .content_path = content_path,
        .hub_path = hub_path,
        .marker = m,
    };
    _ = try hub.reconcile(alloc, &ws, &p, false);

    // stdout is the hub path alone (cd-friendly); human status goes to stderr,
    // where its tilde-abbreviated paths cannot leak into a substitution.
    try ctx.out.print("{s}\n", .{hub_path});
    try ctx.err.print("created {s}/{s}\n", .{ on.org, on.name });
    try ctx.err.print("no repos yet - add one with `holt repo get <url> -p {s}/{s}`\n", .{ on.org, on.name });
    return 0;
}

test "new: creates content dirs and marker, and names the next step on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "widget" });
    try testing.expectEqualStrings(hub_path, std.mem.trim(u8, got.out, " \t\r\n"));
    try testing.expect(std.mem.indexOf(u8, got.err, "created acme/widget") != null);
    // A memberless project has no code/ dir; say how to add one.
    try testing.expect(std.mem.indexOf(u8, got.err, "holt repo get") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "-p acme/widget") != null);

    for ([_][]const u8{ "docs", "assets", "links" }) |sub| {
        const dir_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget", sub });
        try testing.expect(fsutil.exists(dir_path));
    }
}

test "new: a url argument is rejected - populating a project is repo get's job" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{ "acme/widget", "https://example.invalid/a/b" });
    try testing.expectEqual(@as(u8, 2), got.code);
}
