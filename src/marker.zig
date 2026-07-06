//! Reads and writes the per-project marker file `.holt.json`: the
//! authoritative record of a project's org/name and its repo membership
//! (short name -> remote URL). A repo with no remote yet is recorded with
//! the pseudo-URL "local:<name>" (portable across machines - marker
//! consumers check that prefix and build `identity.local(name)` instead of
//! calling `identity.fromUrl`, which rejects it).

const std = @import("std");
const json = @import("json");
const fsutil = @import("fsutil.zig");
const diagnostic = @import("diag.zig");
const testing = std.testing;

pub const marker_basename = ".holt.json";

/// The placeholder iCloud leaves when it evicts a file's contents to free
/// local storage: a hidden sibling named "." + original + ".icloud". For the
/// marker that is "..holt.json.icloud". Its presence means the project exists
/// but its marker bytes are not downloaded, so holt cannot read it yet.
pub const evicted_marker_basename = "." ++ marker_basename ++ ".icloud";

pub const marker_version = 1;

/// True when `content_dir` holds an iCloud eviction placeholder for its
/// marker but not the marker itself - the project is real, its marker is just
/// not downloaded. Any allocation failure conservatively answers false.
pub fn markerEvicted(alloc: std.mem.Allocator, content_dir: []const u8) bool {
    const placeholder = std.fs.path.join(alloc, &.{ content_dir, evicted_marker_basename }) catch return false;
    return fsutil.exists(placeholder);
}

pub const Marker = struct {
    version: u32,
    /// Portable self-description only - the on-disk directory a marker is
    /// loaded from is authoritative, and a workspace derives a project's
    /// real org/name from that path rather than from these fields.
    org: []const u8,
    name: []const u8,
    repos: std.StringArrayHashMapUnmanaged([]const u8),
    /// Optional per-repo hub link name override, keyed by repo short name.
    /// Absent from the on-disk marker until a user runs `holt alias`.
    aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
};

// Mirrors the on-disk shape before validation. `repos` and `aliases` stay
// dynamic `Value`s here: a StringArrayHashMapUnmanaged has no typed-decode
// support, and `version` needs a range check before it becomes load's
// UnsupportedMarkerVersion, so all three get custom handling below rather
// than decoding straight into `Marker`. `aliases` defaults to null so a
// marker without the key loads as an empty map.
const Raw = struct {
    version: u32,
    org: []const u8,
    name: []const u8,
    repos: json.Value,
    aliases: ?json.Value = null,
};

/// Loads and validates the marker at `path`. All returned memory lives in
/// `alloc` (the caller's per-command arena); nothing is individually freed.
pub fn load(alloc: std.mem.Allocator, path: []const u8, diag: ?*diagnostic.Diagnostic) !Marker {
    const src = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), path, alloc, .limited(1 << 20));

    var errs: std.ArrayList(json.Diagnostic) = .empty;
    const raw = json.parseInto(Raw, alloc, src, .{ .errors = &errs }) catch |err| {
        if (diag) |d| {
            if (errs.items.len > 0) {
                d.set(alloc, "malformed marker at {s}: {s}", .{ path, errs.items[0].message });
            } else {
                d.set(alloc, "malformed marker at {s}: {s}", .{ path, @errorName(err) });
            }
        }
        return err;
    };

    if (raw.version != marker_version) {
        if (diag) |d| d.set(alloc, "unsupported marker version {d} at {s} (want {d})", .{ raw.version, path, marker_version });
        return error.UnsupportedMarkerVersion;
    }
    if (raw.repos != .object) {
        if (diag) |d| d.set(alloc, "malformed marker at {s}: \"repos\" must be an object", .{path});
        return error.MalformedMarker;
    }

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var it = raw.repos.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) {
            if (diag) |d| d.set(alloc, "malformed marker at {s}: repos.{s} must be a string", .{ path, entry.key_ptr.* });
            return error.MalformedMarker;
        }
        try repos.put(alloc, entry.key_ptr.*, entry.value_ptr.*.string);
    }

    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    if (raw.aliases) |av| {
        if (av != .object) {
            if (diag) |d| d.set(alloc, "malformed marker at {s}: \"aliases\" must be an object", .{path});
            return error.MalformedMarker;
        }
        var ait = av.object.iterator();
        while (ait.next()) |entry| {
            if (entry.value_ptr.* != .string) {
                if (diag) |d| d.set(alloc, "malformed marker at {s}: aliases.{s} must be a string", .{ path, entry.key_ptr.* });
                return error.MalformedMarker;
            }
            try aliases.put(alloc, entry.key_ptr.*, entry.value_ptr.*.string);
        }
    }

    return .{ .version = raw.version, .org = raw.org, .name = raw.name, .repos = repos, .aliases = aliases };
}

/// Writes `m` to `path` as sorted-key, 2-space pretty JSON with a trailing
/// newline. Atomic via `fsutil.writeFileAtomic`, so a crash never leaves a
/// half-written marker and two concurrent savers never collide on the temp.
pub fn save(m: *const Marker, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repos_obj: json.ObjectMap = .empty;
    for (m.repos.keys()) |k| try repos_obj.put(arena, k, .{ .string = m.repos.get(k).? });

    var root: json.ObjectMap = .empty;
    try root.put(arena, "name", .{ .string = m.name });
    try root.put(arena, "org", .{ .string = m.org });
    try root.put(arena, "repos", .{ .object = repos_obj });
    try root.put(arena, "version", .{ .integer = m.version });

    // Omit the key entirely when empty so markers without aliases stay
    // byte-identical to their pre-alias form.
    if (m.aliases.count() > 0) {
        var aliases_obj: json.ObjectMap = .empty;
        for (m.aliases.keys()) |k| try aliases_obj.put(arena, k, .{ .string = m.aliases.get(k).? });
        try root.put(arena, "aliases", .{ .object = aliases_obj });
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    try json.encode(&aw.writer, .{ .object = root }, .{ .indent = 2, .sort_keys = true });
    try aw.writer.writeByte('\n');

    try fsutil.writeFileAtomic(arena, path, aw.written());
}

fn markerPath(tmp: *testing.TmpDir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    return std.fs.path.join(testing.allocator, &.{ root, marker_basename });
}

test "save writes a sorted-key, 2-space pretty golden document" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "b", "local:b");
    try repos.put(arena, "a", "https://github.com/acme/a");

    const m: Marker = .{ .version = 1, .org = "acme", .name = "proj", .repos = repos };
    try save(&m, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 20));
    const want =
        "{\n" ++
        "  \"name\": \"proj\",\n" ++
        "  \"org\": \"acme\",\n" ++
        "  \"repos\": {\n" ++
        "    \"a\": \"https://github.com/acme/a\",\n" ++
        "    \"b\": \"local:b\"\n" ++
        "  },\n" ++
        "  \"version\": 1\n" ++
        "}\n";
    try testing.expectEqualStrings(want, got);
}

test "save is atomic: no leftover .tmp file after a successful write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    const m: Marker = .{ .version = 1, .org = "o", .name = "n", .repos = .empty };
    try save(&m, path);

    const tmp_path = try std.fmt.allocPrint(testing.allocator, "{s}.tmp", .{path});
    defer testing.allocator.free(tmp_path);
    try testing.expect(!fsutil.exists(tmp_path));
    try testing.expect(fsutil.exists(path));
}

test "round-trip: load(save(m)) equals m" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://github.com/acme/widget");
    try repos.put(arena, "scratch", "local:scratch");

    const original: Marker = .{ .version = 1, .org = "acme", .name = "proj", .repos = repos };
    try save(&original, path);

    const loaded = try load(arena, path, null);
    try testing.expectEqual(@as(u32, 1), loaded.version);
    try testing.expectEqualStrings("acme", loaded.org);
    try testing.expectEqualStrings("proj", loaded.name);
    try testing.expectEqual(@as(usize, 2), loaded.repos.count());
    try testing.expectEqualStrings("https://github.com/acme/widget", loaded.repos.get("widget").?);
    try testing.expectEqualStrings("local:scratch", loaded.repos.get("scratch").?);
}

test "save: an aliases object appears only when non-empty, sorted after the other keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://github.com/acme/widget");
    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try aliases.put(arena, "widget", "gadget");

    const m: Marker = .{ .version = 1, .org = "acme", .name = "proj", .repos = repos, .aliases = aliases };
    try save(&m, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 20));
    const want =
        "{\n" ++
        "  \"aliases\": {\n" ++
        "    \"widget\": \"gadget\"\n" ++
        "  },\n" ++
        "  \"name\": \"proj\",\n" ++
        "  \"org\": \"acme\",\n" ++
        "  \"repos\": {\n" ++
        "    \"widget\": \"https://github.com/acme/widget\"\n" ++
        "  },\n" ++
        "  \"version\": 1\n" ++
        "}\n";
    try testing.expectEqualStrings(want, got);
}

test "save: a marker without aliases is byte-identical to the pre-alias form" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://github.com/acme/widget");

    const m: Marker = .{ .version = 1, .org = "acme", .name = "proj", .repos = repos };
    try save(&m, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, got, "aliases") == null);
}

test "round-trip: load(save(m)) preserves aliases" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://github.com/acme/widget");
    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try aliases.put(arena, "widget", "gadget");

    const original: Marker = .{ .version = 1, .org = "acme", .name = "proj", .repos = repos, .aliases = aliases };
    try save(&original, path);

    const loaded = try load(arena, path, null);
    try testing.expectEqual(@as(usize, 1), loaded.aliases.count());
    try testing.expectEqualStrings("gadget", loaded.aliases.get("widget").?);
}

test "load: a marker without an aliases key loads with an empty aliases map" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"acme\",\"name\":\"proj\",\"repos\":{}}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try load(arena, path, null);
    try testing.expectEqual(@as(usize, 0), loaded.aliases.count());
}

test "load: rejects a non-string aliases entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"acme\",\"name\":\"proj\",\"repos\":{},\"aliases\":{\"a\":7}}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.MalformedMarker, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "aliases") != null);
}

test "load: rejects an unsupported marker version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":2,\"org\":\"acme\",\"name\":\"proj\",\"repos\":{}}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.UnsupportedMarkerVersion, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "2") != null);
}

test "load: rejects a missing required field" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"acme\",\"repos\":{}}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.MissingField, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "name") != null);
}

test "load: rejects an unknown top-level field" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"acme\",\"name\":\"proj\",\"repos\":{},\"extra\":true}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.UnknownField, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "extra") != null);
}

test "load: rejects a non-object repos value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"acme\",\"name\":\"proj\",\"repos\":\"nope\"}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.MalformedMarker, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "repos") != null);
}

test "load: rejects a non-string repos entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"acme\",\"name\":\"proj\",\"repos\":{\"a\":42}}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.MalformedMarker, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "a") != null);
}
