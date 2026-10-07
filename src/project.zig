//! A single workspace project: its org/name identity, the two paths that
//! shadow it (synced content and hub symlink target), and the marker that
//! was loaded to produce it.

const std = @import("std");
const marker = @import("marker.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

/// The directories `project new` creates in a project's synced content.
pub const content_dirs = [_][]const u8{ "docs", "assets", "links" };

pub const Project = struct {
    org: []const u8,
    name: []const u8,
    content_path: []u8,
    hub_path: []u8,
    marker: marker.Marker,

    /// "org/name". Caller-owned memory in `alloc`.
    pub fn qualified(self: Project, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ self.org, self.name });
    }

    /// Path to this project's on-disk marker file. Caller-owned memory in
    /// `alloc`.
    pub fn markerPath(self: Project, alloc: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.content_path, marker.marker_basename });
    }
};

test "qualified: joins org and name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p: Project = .{
        .org = "acme",
        .name = "widget",
        .content_path = try arena.dupe(u8, "/synced/projects/acme/widget"),
        .hub_path = try arena.dupe(u8, "/hub/acme/widget"),
        .marker = .init("acme", "widget"),
    };
    try testing.expectEqualStrings("acme/widget", try p.qualified(arena));
}

test "a member entry resolves a remote URL and a local: pseudo-URL to an identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m: marker.Marker = .init("acme", "proj");
    try m.upsert(arena, "widget", "https://github.com/acme/widget");
    try m.upsert(arena, "scratch", "local:scratch");

    const remote_id = m.findRepo("widget").?.source.?.id();
    try testing.expectEqualStrings("github.com", remote_id.host);
    try testing.expectEqualStrings("acme", remote_id.owner);
    try testing.expectEqualStrings("widget", remote_id.repo);

    const local_id = m.findRepo("scratch").?.source.?.id();
    try testing.expect(local_id.isLocal());
    try testing.expectEqualStrings("scratch", local_id.repo);
}

test "a local: value that escapes the local bucket faults its entry at load" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const p = try testutil.testProjectFromRaw(arena, &ws, "acme", "proj",
        \\{
        \\  "version": 1,
        \\  "org": "acme",
        \\  "name": "proj",
        \\  "repos": {
        \\    "escape": "local:../../outside/victim",
        \\    "dotdot": "local:.."
        \\  }
        \\}
    );

    for ([_][]const u8{ "escape", "dotdot" }) |name| {
        const e = p.marker.findRepo(name).?;
        try testing.expect(e.source == null);
        try testing.expectEqual(marker.Fault.unsafe_segment, e.source_fault.?);
    }
}

test "a url that git would read as an option faults its entry at load" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const p = try testutil.testProjectFromRaw(arena, &ws, "acme", "proj",
        \\{
        \\  "version": 1,
        \\  "org": "acme",
        \\  "name": "proj",
        \\  "repos": {
        \\    "widget": "--upload-pack=touch /tmp/pwned",
        \\    "gadget": "-dashy://github.com/acme/gadget"
        \\  }
        \\}
    );

    for ([_][]const u8{ "widget", "gadget" }) |name| {
        const e = p.marker.findRepo(name).?;
        try testing.expect(e.source == null);
        try testing.expectEqual(marker.Fault.unrecognized_url, e.source_fault.?);
    }
}

test "findRepo: an unknown repo name resolves to null" {
    const m: marker.Marker = .init("acme", "proj");
    try testing.expect(m.findRepo("nope") == null);
}
