//! `holt info <project>`: read-only summary of a project - its org/name,
//! content/hub paths, and per-member-repo identity, clone path, and
//! cloned-or-missing state.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const marker = @import("../marker.zig");
const git = @import("../git.zig");
const ui = @import("../ui.zig");
const fsutil = @import("../fsutil.zig");
const json = @import("json");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const color_red = "31";
const color_green = "32";

const Spec = struct {
    project: cli.spec.Pos([]const u8, .{ .complete = app.cat(.project), .help = "the project to inspect" }),
    json: cli.spec.Flag(.{ .help = "emit a JSON object instead of human-readable text" }),
};

pub const command = app.command(Spec, .{
    .name = "info",
    .summary = "Show a project's paths and member repos",
    .usage = "holt info <project>",
    .group = .inspect,
    .needs_context = true,
    .details =
    \\Example:
    \\  holt info myproj
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const project_query = a.project;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const p = (try common.resolveOne(ctx, project_query)) orelse return 1;

    if (a.json) return runJson(ctx, &ws, &p);

    try ctx.out.print("{s}/{s}\n", .{ p.org, p.name });
    try ctx.out.print("content: {s}\n", .{try fsutil.contractTilde(alloc, app.envOf(ctx), p.content_path)});
    try ctx.out.print("hub: {s}\n", .{try fsutil.contractTilde(alloc, app.envOf(ctx), p.hub_path)});

    for (p.marker.repos.keys()) |repo_name| {
        const id = try p.repoIdentity(alloc, repo_name);
        const rel = try id.relPath(alloc);
        const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
        try ctx.out.print("  {s}: {s} ({s}) [", .{ repo_name, rel, try fsutil.contractTilde(alloc, app.envOf(ctx), clone_path) });
        if (!fsutil.exists(clone_path)) {
            try ui.color(ctx.context.?.color, ctx.out, color_red, "missing");
        } else if (!try git.inspectable(alloc, clone_path)) {
            try ui.color(ctx.context.?.color, ctx.out, color_red, "cloned, unreadable");
        } else {
            try ui.color(ctx.context.?.color, ctx.out, color_green, "cloned");
        }
        try ctx.out.writeAll("]\n");
    }

    return 0;
}

/// Emits the project as a single JSON object: org, name, content/hub paths,
/// and a `repos` array of {name, identity, clone_path, state}, where `state`
/// is "missing", "unreadable", or "cloned".
fn runJson(ctx: *app.Ctx, ws: *const workspace.Workspace, p: *const project_mod.Project) anyerror!u8 {
    const alloc = ctx.alloc;

    var repo_items: std.ArrayList(json.Value) = .empty;
    for (p.marker.repos.keys()) |repo_name| {
        const id = try p.repoIdentity(alloc, repo_name);
        const rel = try id.relPath(alloc);
        const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
        const state: []const u8 = if (!fsutil.exists(clone_path))
            "missing"
        else if (!try git.inspectable(alloc, clone_path))
            "unreadable"
        else
            "cloned";

        var ro: json.ObjectMap = .empty;
        try ro.put(alloc, "name", .{ .string = repo_name });
        try ro.put(alloc, "identity", .{ .string = rel });
        try ro.put(alloc, "clone_path", .{ .string = clone_path });
        try ro.put(alloc, "state", .{ .string = state });
        try repo_items.append(alloc, .{ .object = ro });
    }

    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "org", .{ .string = p.org });
    try obj.put(alloc, "name", .{ .string = p.name });
    try obj.put(alloc, "content_path", .{ .string = p.content_path });
    try obj.put(alloc, "hub_path", .{ .string = p.hub_path });
    try obj.put(alloc, "repos", .{ .array = try repo_items.toOwnedSlice(alloc) });

    try json.encode(ctx.out, .{ .object = obj }, .{});
    try ctx.out.writeByte('\n');
    return 0;
}

test "run: golden output over a project with one present clone and one missing clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "absent", "https://github.com/acme/absent");
    try repos.put(arena, "present", "https://github.com/acme/present");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const present_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme", "present" });
    try fsutil.ensureDir(present_path);
    const init_res = try git.run(arena, &.{ "git", "init", "-q", "-b", "main", present_path }, null);
    try testing.expectEqual(@as(u8, 0), init_res.status);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);

    // info renders paths for humans, so each is tilde-abbreviated on display.
    const content_path = try fsutil.contractTilde(arena, app.envOf_current(), try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj" }));
    const hub_path = try fsutil.contractTilde(arena, app.envOf_current(), try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj" }));
    const absent_clone = try fsutil.contractTilde(arena, app.envOf_current(), try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme", "absent" }));
    const present_clone = try fsutil.contractTilde(arena, app.envOf_current(), try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme", "present" }));
    const want = try std.fmt.allocPrint(arena,
        \\acme/proj
        \\content: {s}
        \\hub: {s}
        \\  absent: github.com/acme/absent ({s}) [missing]
        \\  present: github.com/acme/present ({s}) [cloned]
        \\
    , .{ content_path, hub_path, absent_clone, present_clone });
    try testing.expectEqualStrings(want, got.out);
}

test "run: --json emits a parseable object with per-repo identity, path, and state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "absent", "https://github.com/acme/absent");
    try repos.put(arena, "present", "https://github.com/acme/present");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const present_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme", "present" });
    try fsutil.ensureDir(present_path);
    const init_res = try git.run(arena, &.{ "git", "init", "-q", "-b", "main", present_path }, null);
    try testing.expectEqual(@as(u8, 0), init_res.status);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--json" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "\x1b[") == null);

    const Repo = struct { name: []const u8, identity: []const u8, clone_path: []const u8, state: []const u8 };
    const Obj = struct { org: []const u8, name: []const u8, content_path: []const u8, hub_path: []const u8, repos: []Repo };
    const parsed = try json.parseInto(Obj, arena, got.out, .{});
    try testing.expectEqualStrings("acme", parsed.org);
    try testing.expectEqualStrings("proj", parsed.name);
    try testing.expectEqual(@as(usize, 2), parsed.repos.len);
    for (parsed.repos) |r| {
        if (std.mem.eql(u8, r.name, "absent")) {
            try testing.expectEqualStrings("missing", r.state);
            try testing.expectEqualStrings("github.com/acme/absent", r.identity);
        } else if (std.mem.eql(u8, r.name, "present")) {
            try testing.expectEqualStrings("cloned", r.state);
        } else return error.TestUnexpectedResult;
    }
}

test "run: a clone that exists but is not a readable git repo is reported as such" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "broken", "https://github.com/acme/broken");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    // A plain directory, no .git at all: exists on disk but isn't a repo.
    const broken_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme", "broken" });
    try fsutil.ensureDir(broken_path);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "[cloned, unreadable]") != null);
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

test "run: a corrupt marker reports a malformed-marker hint, not \"no project matches\"" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const broken_dir = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "broken" });
    try fsutil.ensureDir(broken_dir);
    const broken_marker = try std.fs.path.join(arena, &.{ broken_dir, marker.marker_basename });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = broken_marker, .data = "not json" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/broken"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "has a malformed marker") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt doctor") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "no project matches") == null);
}
