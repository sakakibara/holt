//! A single workspace project: its org/name identity, the two paths that
//! shadow it (synced content and hub symlink target), and the marker that
//! was loaded to produce it.

const std = @import("std");
const marker = @import("marker.zig");
const identity = @import("identity.zig");
const testing = std.testing;

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

    /// Resolves one of the project's marker repo entries to an Identity.
    /// A marker value of "local:<name>" has no remote yet and is not a URL
    /// identity.fromUrl understands, so it is special-cased into
    /// `identity.local`.
    pub fn repoIdentity(self: Project, alloc: std.mem.Allocator, repo_name: []const u8) !identity.Identity {
        const url = self.marker.repos.get(repo_name) orelse return error.UnknownRepo;
        if (std.mem.startsWith(u8, url, "local:")) return identity.local(url["local:".len..]);
        return identity.fromUrl(alloc, url);
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
        .marker = .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty },
    };
    try testing.expectEqualStrings("acme/widget", try p.qualified(arena));
}

test "repoIdentity: resolves a remote URL and a local: pseudo-URL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://github.com/acme/widget");
    try repos.put(arena, "scratch", "local:scratch");

    const p: Project = .{
        .org = "acme",
        .name = "proj",
        .content_path = try arena.dupe(u8, "/synced/projects/acme/proj"),
        .hub_path = try arena.dupe(u8, "/hub/acme/proj"),
        .marker = .{ .version = 1, .org = "acme", .name = "proj", .repos = repos },
    };

    const remote_id = try p.repoIdentity(arena, "widget");
    try testing.expectEqualStrings("github.com", remote_id.host);
    try testing.expectEqualStrings("acme", remote_id.owner);
    try testing.expectEqualStrings("widget", remote_id.repo);

    const local_id = try p.repoIdentity(arena, "scratch");
    try testing.expect(local_id.isLocal());
    try testing.expectEqualStrings("scratch", local_id.repo);
}

test "repoIdentity: unknown repo name errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p: Project = .{
        .org = "acme",
        .name = "proj",
        .content_path = try arena.dupe(u8, "/synced/projects/acme/proj"),
        .hub_path = try arena.dupe(u8, "/hub/acme/proj"),
        .marker = .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty },
    };
    try testing.expectError(error.UnknownRepo, p.repoIdentity(arena, "nope"));
}
