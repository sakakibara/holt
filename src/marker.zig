//! Reads and writes the per-project marker file `.holt.json`: the
//! authoritative record of a project's org/name and its repo membership
//! (short name -> remote URL). A repo with no remote yet is recorded with
//! the pseudo-URL "local:<name>" (portable across machines - marker
//! consumers check that prefix and build `identity.local(name)` instead of
//! calling `identity.fromUrl`, which rejects it).

const std = @import("std");
const json = @import("json");
const fsutil = @import("fsutil.zig");
const identity = @import("identity.zig");
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

/// Why a member's source or alias value did not parse. Faulted values keep
/// their raw form and survive load/save; only their parsed field is null.
pub const Fault = enum { not_a_string, unsafe_segment, unrecognized_url };

/// A remote member: the URL exactly as the marker spelled it, plus the
/// identity parsed from it. `url` is used at exactly two kinds of site - the
/// bytes `save` writes and the bytes git receives; `id` everywhere else.
/// Storing only the identity would rewrite `git@...` remotes as `https://...`
/// on the next save, since the parse is lossy.
pub const Remote = struct {
    url: []const u8,
    id: identity.Identity,
};

pub const Source = union(enum) { remote: Remote, local: fsutil.SafeSegment };

pub const Entry = struct {
    /// Marker key, verbatim. Never joined into a path; a lookup handle and a
    /// display string.
    name: []const u8,

    /// The `repos` value exactly as the file held it - any JSON value, so a
    /// future holt's richer member survives. Null when this entry exists only
    /// because `aliases` named it.
    raw_source: ?json.Value,
    source: ?Source,
    source_fault: ?Fault,

    /// The `aliases` value exactly as the file held it - also any JSON value,
    /// for the same reason.
    raw_alias: ?json.Value,
    alias: ?fsutil.SafeSegment,
    alias_fault: ?Fault,
};

pub const Marker = struct {
    version: u32,
    /// Portable self-description only - the on-disk directory a marker is
    /// loaded from is authoritative, and a workspace derives a project's
    /// real org/name from that path rather than from these fields.
    org: []const u8,
    name: []const u8,
    repos: std.StringArrayHashMapUnmanaged([]const u8),
    /// Optional per-repo hub link name override, keyed by repo short name.
    /// Absent from the on-disk marker until a user runs `holt repo alias`.
    aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// One entry per `repos` or `aliases` key, in file order: members first,
    /// then alias-only names.
    entries: []Entry = &.{},
    /// Unknown top-level keys, verbatim, re-emitted by `save`.
    extra: json.ObjectMap = .empty,

    /// Every entry, faulted or not - addressing and removal.
    pub fn findEntry(m: *const Marker, name: []const u8) ?*Entry {
        return findIn(m.entries, name);
    }

    /// Entries the file listed under `repos` - repo queries and membership.
    /// Excludes alias-only names, so a fuzzy repo query cannot match one.
    pub fn findRepo(m: *const Marker, name: []const u8) ?*Entry {
        const e = findIn(m.entries, name) orelse return null;
        return if (e.raw_source != null) e else null;
    }

    fn findIn(entries: []Entry, name: []const u8) ?*Entry {
        for (entries) |*e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};

/// Required string field lookup with the decoder's diagnostics reproduced.
fn getString(alloc: std.mem.Allocator, obj: json.ObjectMap, key: []const u8, diag: ?*diagnostic.Diagnostic) ![]const u8 {
    const v = obj.get(key) orelse {
        if (diag) |d| d.set(alloc, "missing required field `{s}`", .{key});
        return error.MissingField;
    };
    if (v != .string) {
        if (diag) |d| d.set(alloc, "expected string, got {s}", .{@tagName(v)});
        return error.TypeMismatch;
    }
    return v.string;
}

/// Classifies one member's raw `repos` value into an `Entry`. A value that
/// does not parse keeps its raw form and gets a fault instead of an error.
fn sourceEntry(alloc: std.mem.Allocator, name: []const u8, raw: json.Value) error{OutOfMemory}!Entry {
    var e: Entry = .{
        .name = name,
        .raw_source = raw,
        .source = null,
        .source_fault = null,
        .raw_alias = null,
        .alias = null,
        .alias_fault = null,
    };
    if (raw != .string) {
        e.source_fault = .not_a_string;
        return e;
    }
    const s = raw.string;
    if (std.mem.startsWith(u8, s, "local:")) {
        if (fsutil.SafeSegment.parse(s["local:".len..])) |seg| {
            e.source = .{ .local = seg };
        } else {
            e.source_fault = .unsafe_segment;
        }
        return e;
    }
    if (identity.fromUrl(alloc, s)) |id| {
        e.source = .{ .remote = .{ .url = s, .id = id } };
    } else |err| switch (err) {
        error.UnrecognizedUrl => e.source_fault = .unrecognized_url,
        error.OutOfMemory => return error.OutOfMemory,
    }
    return e;
}

/// Loads and validates the marker at `path`. All returned memory lives in
/// `alloc` (the caller's per-command arena); nothing is individually freed.
/// `entries` classifies each member and alias at this boundary; a value that
/// fails its predicate is kept raw and marked with a fault, never dropped.
///
/// A diagnostic names only what is wrong, never the path it was read from:
/// the caller already holds `path` and is the one that knows how to show it
/// (contracted for a person, absolute for a machine).
pub fn load(alloc: std.mem.Allocator, path: []const u8, diag: ?*diagnostic.Diagnostic) !Marker {
    const src = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), path, alloc, .limited(1 << 20));

    var errs: std.ArrayList(json.Diagnostic) = .empty;
    const root = json.parse(alloc, src, .{ .errors = &errs }) catch |err| {
        if (diag) |d| {
            if (errs.items.len > 0) {
                d.set(alloc, "{s}", .{errs.items[0].message});
            } else {
                d.set(alloc, "{s}", .{@errorName(err)});
            }
        }
        return err;
    };
    if (root != .object) {
        if (diag) |d| d.set(alloc, "expected object, got {s}", .{@tagName(root)});
        return error.TypeMismatch;
    }
    const obj = root.object;

    // Known keys are lifted out by hand rather than through the decoder, so
    // the top level stays a `json.Value` object; the decoder's diagnostics
    // for the required fields are reproduced below.
    var kit = obj.iterator();
    outer: while (kit.next()) |kv| {
        inline for ([_][]const u8{ "version", "org", "name", "repos", "aliases" }) |known| {
            if (std.mem.eql(u8, kv.key_ptr.*, known)) continue :outer;
        }
        if (diag) |d| d.set(alloc, "unknown field `{s}`", .{kv.key_ptr.*});
        return error.UnknownField;
    }

    const version_val = obj.get("version") orelse {
        if (diag) |d| d.set(alloc, "missing required field `version`", .{});
        return error.MissingField;
    };
    const version: u32 = switch (version_val) {
        .integer => |n| std.math.cast(u32, n) orelse {
            if (diag) |d| d.set(alloc, "integer {d} out of range for u32", .{n});
            return error.Overflow;
        },
        else => {
            if (diag) |d| d.set(alloc, "expected integer, got {s}", .{@tagName(version_val)});
            return error.TypeMismatch;
        },
    };
    const org = try getString(alloc, obj, "org", diag);
    const name = try getString(alloc, obj, "name", diag);
    const raw_repos = obj.get("repos") orelse {
        if (diag) |d| d.set(alloc, "missing required field `repos`", .{});
        return error.MissingField;
    };

    if (version != marker_version) {
        if (diag) |d| d.set(alloc, "unsupported marker version {d} (want {d})", .{ version, marker_version });
        return error.UnsupportedMarkerVersion;
    }
    if (raw_repos != .object) {
        if (diag) |d| d.set(alloc, "\"repos\" must be an object", .{});
        return error.MalformedMarker;
    }

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var entries: std.ArrayList(Entry) = .empty;
    var it = raw_repos.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) {
            if (diag) |d| d.set(alloc, "repos.{s} must be a string", .{entry.key_ptr.*});
            return error.MalformedMarker;
        }
        try repos.put(alloc, entry.key_ptr.*, entry.value_ptr.*.string);
        try entries.append(alloc, try sourceEntry(alloc, entry.key_ptr.*, entry.value_ptr.*));
    }

    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    if (obj.get("aliases")) |av| {
        if (av != .object) {
            if (diag) |d| d.set(alloc, "\"aliases\" must be an object", .{});
            return error.MalformedMarker;
        }
        var ait = av.object.iterator();
        while (ait.next()) |entry| {
            if (entry.value_ptr.* != .string) {
                if (diag) |d| d.set(alloc, "aliases.{s} must be a string", .{entry.key_ptr.*});
                return error.MalformedMarker;
            }
            try aliases.put(alloc, entry.key_ptr.*, entry.value_ptr.*.string);

            const target = Marker.findIn(entries.items, entry.key_ptr.*) orelse blk: {
                try entries.append(alloc, .{
                    .name = entry.key_ptr.*,
                    .raw_source = null,
                    .source = null,
                    .source_fault = null,
                    .raw_alias = null,
                    .alias = null,
                    .alias_fault = null,
                });
                break :blk &entries.items[entries.items.len - 1];
            };
            target.raw_alias = entry.value_ptr.*;
            if (entry.value_ptr.* != .string) {
                target.alias_fault = .not_a_string;
            } else if (fsutil.SafeSegment.parse(entry.value_ptr.*.string)) |seg| {
                target.alias = seg;
            } else {
                target.alias_fault = .unsafe_segment;
            }
        }
    }

    return .{
        .version = version,
        .org = org,
        .name = name,
        .repos = repos,
        .aliases = aliases,
        .entries = try entries.toOwnedSlice(alloc),
        .extra = .empty,
    };
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

test "load: entries classify remote, local, and faulted sources, keeping raw values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"acme\",\"name\":\"proj\",\"repos\":{" ++
            "\"widget\":\"git@github.com:acme/widget.git\"," ++
            "\"scratch\":\"local:scratch\"," ++
            "\"evil\":\"local:../../evil\"," ++
            "\"dashy\":\"-dashy://github.com/acme/gadget\"}}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = try load(arena, path, null);
    try testing.expectEqual(@as(usize, 4), m.entries.len);

    const widget = m.findRepo("widget").?;
    try testing.expectEqualStrings("git@github.com:acme/widget.git", widget.source.?.remote.url);
    try testing.expectEqualStrings("github.com", widget.source.?.remote.id.host);
    try testing.expectEqualStrings("acme", widget.source.?.remote.id.owner);
    try testing.expectEqualStrings("widget", widget.source.?.remote.id.repo);
    try testing.expect(widget.source_fault == null);

    const scratch = m.findRepo("scratch").?;
    try testing.expectEqualStrings("scratch", scratch.source.?.local.bytes);

    const evil = m.findRepo("evil").?;
    try testing.expect(evil.source == null);
    try testing.expectEqual(Fault.unsafe_segment, evil.source_fault.?);
    try testing.expectEqualStrings("local:../../evil", evil.raw_source.?.string);

    const dashy = m.findRepo("dashy").?;
    try testing.expect(dashy.source == null);
    try testing.expectEqual(Fault.unrecognized_url, dashy.source_fault.?);
    try testing.expectEqualStrings("-dashy://github.com/acme/gadget", dashy.raw_source.?.string);
}

test "load: aliases attach to their member, fault on unsafe values, and orphan into their own entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"acme\",\"name\":\"proj\"," ++
            "\"repos\":{\"widget\":\"https://github.com/acme/widget\",\"gizmo\":\"https://github.com/acme/gizmo\"}," ++
            "\"aliases\":{\"widget\":\"gadget\",\"gizmo\":\"../evil\",\"ghost\":\"x\"}}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = try load(arena, path, null);
    try testing.expectEqual(@as(usize, 3), m.entries.len);

    const widget = m.findEntry("widget").?;
    try testing.expectEqualStrings("gadget", widget.alias.?.bytes);
    try testing.expect(widget.alias_fault == null);

    // Unusable alias on a valid member: only the alias is lost.
    const gizmo = m.findEntry("gizmo").?;
    try testing.expect(gizmo.source != null);
    try testing.expect(gizmo.alias == null);
    try testing.expectEqual(Fault.unsafe_segment, gizmo.alias_fault.?);
    try testing.expectEqualStrings("../evil", gizmo.raw_alias.?.string);

    // Orphan alias: addressable, but never a repo-query match.
    const ghost = m.findEntry("ghost").?;
    try testing.expect(ghost.raw_source == null);
    try testing.expectEqualStrings("x", ghost.alias.?.bytes);
    try testing.expect(m.findRepo("ghost") == null);
    try testing.expect(m.findRepo("widget") != null);
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
