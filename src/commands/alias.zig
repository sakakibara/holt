//! `holt alias <project> <repo> [name]`: sets or clears the hub link name a
//! repo browses under. With a name, the member's `code/<repo>` link becomes
//! `code/<name>`; without one, the alias is dropped and the derived name
//! returns. Either way the hub is reconciled so the on-disk symlink follows.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    project: cli.spec.Pos([]const u8, .{ .complete = app.cat(.project), .help = "the project owning the repo" }),
    repo: cli.spec.Pos([]const u8, .{ .complete = app.cat(.repo), .help = "the member repo to alias" }),
    name: cli.spec.Pos([]const u8, .{ .optional = true, .help = "the hub link name (omit to clear the alias)" }),
};

pub const command = app.command(Spec, .{
    .name = "alias",
    .summary = "Name the hub link a repo browses under (omit the name to clear)",
    .usage = "holt alias <project> <repo> [name]",
    .group = .maintain,
    .needs_context = true,
    .details =
    \\Sets the hub link name for a member repo, overriding the derived
    \\name. Omit <name> to clear the alias and revert to the derived name.
    \\
    \\Example:
    \\  holt alias myproj widget gadget
    \\  holt alias myproj widget
    ,
}, run);

const reserved_link_names = [_][]const u8{ "docs", "assets", "links" };

/// A hub link name must be a single path segment: non-empty, no "/", and
/// not a "."/".." directory reference.
fn isValidLinkName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

fn isReserved(name: []const u8) bool {
    for (reserved_link_names) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

/// True if `links` contains two entries sharing a rel-path.
fn hasDuplicateRel(links: []const hub.Link) bool {
    for (links, 0..) |a, i| {
        for (links[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.rel, b.rel)) return true;
        }
    }
    return false;
}

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const project_query = a.project;
    const repo_name = a.repo;
    const new_name = a.name;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    var p = (try common.resolveOne(ctx, project_query)) orelse return 1;

    // Lock and re-read so a concurrent holt mutating this project cannot make
    // this alias change clobber (or be clobbered by) its edit.
    var lock = try projectlock.acquire(alloc, p.content_path);
    defer lock.release();
    p.marker = try marker.load(alloc, try p.markerPath(alloc), null);

    if (!p.marker.repos.contains(repo_name)) {
        try ctx.err.print("holt: \"{s}\" is not a member of {s}/{s}\n", .{ repo_name, p.org, p.name });
        return 1;
    }

    if (new_name) |name| {
        if (!isValidLinkName(name)) {
            try ctx.err.print("holt: \"{s}\" is not a valid link name (must be a single path segment)\n", .{name});
            return 1;
        }
        if (isReserved(name)) {
            try ctx.err.print("holt: \"{s}\" is a reserved hub link name\n", .{name});
            return 1;
        }

        try p.marker.aliases.put(alloc, repo_name, name);
        const links = try hub.desiredLinks(alloc, &ws, &p);
        if (hasDuplicateRel(links)) {
            try ctx.err.print("holt: alias \"{s}\" collides with another hub link in {s}/{s}\n", .{ name, p.org, p.name });
            return 1;
        }

        const marker_path = try p.markerPath(alloc);
        try marker.save(&p.marker, marker_path);
        _ = try hub.reconcile(alloc, &ws, &p, false);

        try ctx.out.print("aliased {s} -> code/{s}\n", .{ repo_name, name });
        return 0;
    }

    if (p.marker.aliases.orderedRemove(repo_name)) {
        const marker_path = try p.markerPath(alloc);
        try marker.save(&p.marker, marker_path);
        _ = try hub.reconcile(alloc, &ws, &p, false);
        try ctx.out.print("cleared alias for {s}\n", .{repo_name});
    } else {
        try ctx.out.print("{s} has no alias in {s}/{s}\n", .{ repo_name, p.org, p.name });
    }
    return 0;
}

test "run: setting an alias records it and reconciles the hub link" {
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

    // Build the hub first so the derived code/widget link exists to be swept.
    const p0 = switch (try ws.find(arena, "proj")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p0, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "widget", "gadget" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "code/gadget") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("gadget", loaded.aliases.get("widget").?);

    const alias_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "gadget" });
    switch (try fsutil.linkState(arena, alias_link)) {
        .symlink => |t| try testing.expectEqualStrings(
            try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" }),
            t,
        ),
        else => return error.TestUnexpectedResult,
    }
    const old_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "widget" });
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, old_link));
}

test "run: clearing an alias reverts the hub link to the derived name" {
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

    const p0 = switch (try ws.find(arena, "proj")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p0, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "widget" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "cleared alias") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.aliases.count());

    const derived_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "widget" });
    switch (try fsutil.linkState(arena, derived_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
    const alias_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "gadget" });
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, alias_link));
}

test "run: an alias colliding with a reserved link name errors and changes nothing" {
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "widget", "docs" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "reserved") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.aliases.count());
}

test "run: an alias colliding with another member's link errors and changes nothing" {
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
    try repos.put(arena, "gadget", "https://holt-test.invalid/acme/gadget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "widget", "gadget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "collides") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.aliases.count());
}

test "run: aliasing a non-member repo is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "widget", "gadget" });
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "nope", "widget", "gadget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}
