//! Enumerates every project in the workspace, one "org/name" per line.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const fsutil = @import("../fsutil.zig");
const json = @import("json");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    paths: args.Flag(.{ .help = "show each project's hub path instead of just its name" }),
    org: args.Opt([]const u8, .{ .value_name = "org", .complete = comp.cat(.org), .help = "only list projects under this org" }),
    json: args.Flag(.{ .help = "emit a JSON array instead of plain text (ignores --paths)" }),
};

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const with_paths = a.paths;
    const json_flag = a.json;
    const org_filter = a.org;

    const ws = ctx.ws.?;
    const all = try ws.list(ctx.alloc);

    if (json_flag) return runJson(ctx, all, org_filter);

    if (all.len == 0) {
        try ctx.err_w.writeAll("no projects yet - create one with \"holt new <org>/<name>\"\n");
        return 0;
    }

    for (all) |p| {
        if (org_filter) |org| {
            if (!std.mem.eql(u8, p.org, org)) continue;
        }
        const qualified = try p.qualified(ctx.alloc);
        if (with_paths) {
            try ctx.out.print("{s}\t{s}\n", .{ qualified, p.hub_path });
        } else {
            try ctx.out.print("{s}\n", .{qualified});
        }
    }
    return 0;
}

pub const command = args.command(Spec, .{
    .name = "list",
    .about = "List every project in the workspace",
    .usage = "holt list [--paths] [--org <org>] [--json]",
    .group = .navigate,
    .details =
    \\Example:
    \\  holt list --org acme --paths
    ,
}, run);

/// Emits `all` (after `org_filter`) as a compact JSON array, one object per
/// project: org, name, hub_path, content_path, and its member repo names.
/// Never prints the human empty-state message - an empty result is `[]`.
fn runJson(ctx: *cli.Ctx, all: []const project_mod.Project, org_filter: ?[]const u8) anyerror!u8 {
    const alloc = ctx.alloc;
    var items: std.ArrayList(json.Value) = .empty;

    for (all) |p| {
        if (org_filter) |org| {
            if (!std.mem.eql(u8, p.org, org)) continue;
        }

        var repo_items: std.ArrayList(json.Value) = .empty;
        for (p.marker.repos.keys()) |name| try repo_items.append(alloc, .{ .string = name });

        var obj: json.ObjectMap = .empty;
        try obj.put(alloc, "org", .{ .string = p.org });
        try obj.put(alloc, "name", .{ .string = p.name });
        try obj.put(alloc, "hub_path", .{ .string = p.hub_path });
        try obj.put(alloc, "content_path", .{ .string = p.content_path });
        try obj.put(alloc, "repos", .{ .array = try repo_items.toOwnedSlice(alloc) });
        try items.append(alloc, .{ .object = obj });
    }

    try json.encode(ctx.out, .{ .array = try items.toOwnedSlice(alloc) }, .{});
    try ctx.out.writeByte('\n');
    return 0;
}

fn testWorkspace(arena: std.mem.Allocator, root: []const u8) workspace.Workspace {
    return .{ .cfg = .{
        .backend = null,
        .presets = &.{},
        .synced_root = @constCast(root),
        .code_root = @constCast(@as([]const u8, "/code")),
        .hub_root = std.fs.path.join(arena, &.{ root, "hub" }) catch unreachable,
    } };
}

fn threeProjectSandbox(arena: std.mem.Allocator, tmp: *testing.TmpDir) !workspace.Workspace {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "zebra", "aardvark", .{ .version = 1, .org = "zebra", .name = "aardvark", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "gadget", .{ .version = 1, .org = "acme", .name = "gadget", .repos = .empty });

    return ws;
}

test "run: golden output over a 3-project sandbox, sorted by org/name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try threeProjectSandbox(arena, &tmp);
    const got = try testutil.runCmd(arena, command.run, ws, &.{});

    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("acme/gadget\nacme/widget\nzebra/aardvark\n", got.out);
}

test "run: --paths appends a tab and the hub path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try threeProjectSandbox(arena, &tmp);
    const got = try testutil.runCmd(arena, command.run, ws, &.{"--paths"});

    try testing.expectEqual(@as(u8, 0), got.code);
    const gadget_hub = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "hub", "acme", "gadget" });
    const widget_hub = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "hub", "acme", "widget" });
    const aardvark_hub = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "hub", "zebra", "aardvark" });
    const want = try std.fmt.allocPrint(arena, "acme/gadget\t{s}\nacme/widget\t{s}\nzebra/aardvark\t{s}\n", .{ gadget_hub, widget_hub, aardvark_hub });
    try testing.expectEqualStrings(want, got.out);
}

test "run: --org filters to a single org" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try threeProjectSandbox(arena, &tmp);
    const got = try testutil.runCmd(arena, command.run, ws, &.{ "--org", "acme" });

    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("acme/gadget\nacme/widget\n", got.out);
}

test "run: an empty workspace prints a helpful hint on stderr, stdout stays clean, exit 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("", got.out);
    try testing.expect(std.mem.indexOf(u8, got.err, "no projects yet") != null);
}

test "run: --json emits a parseable array with the right orgs, names, and repos" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = testWorkspace(arena, root);

    var repos_widget: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_widget.put(arena, "widget-repo", "https://holt-test.invalid/acme/widget-repo");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = repos_widget });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "zebra", "aardvark", .{ .version = 1, .org = "zebra", .name = "aardvark", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--json"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "\x1b[") == null);

    const Entry = struct { org: []const u8, name: []const u8, hub_path: []const u8, content_path: []const u8, repos: [][]const u8 };
    const parsed = try json.parseInto([]Entry, arena, got.out, .{});
    try testing.expectEqual(@as(usize, 2), parsed.len);
    try testing.expectEqualStrings("acme", parsed[0].org);
    try testing.expectEqualStrings("widget", parsed[0].name);
    try testing.expectEqual(@as(usize, 1), parsed[0].repos.len);
    try testing.expectEqualStrings("widget-repo", parsed[0].repos[0]);
    try testing.expectEqualStrings("zebra", parsed[1].org);
    try testing.expectEqual(@as(usize, 0), parsed[1].repos.len);
}

test "run: --json on an empty workspace emits [] on stdout, not the human hint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--json"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("[]\n", got.out);
    try testing.expectEqualStrings("", got.err);
}
