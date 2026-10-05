//! Reads and writes the per-project marker file `.holt.json`: the
//! authoritative record of a project's org/name and its repo membership.
//! `load` classifies every member and alias at this boundary into typed
//! `Entry` values; consumers read parsed sources, never raw strings. A repo
//! with no remote yet is recorded with the pseudo-URL "local:<name>"
//! (portable across machines).

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

/// True when the project in `content_dir` is real but its marker is not on
/// this machine: iCloud's eviction placeholder stands in for it, or it is a
/// cloud placeholder (`fsutil.isOnlineOnly`) the cloud could not download
/// for holt to read. Any allocation failure conservatively answers false.
pub fn markerEvicted(alloc: std.mem.Allocator, content_dir: []const u8) bool {
    const placeholder = std.fs.path.join(alloc, &.{ content_dir, evicted_marker_basename }) catch return false;
    if (fsutil.exists(placeholder)) return true;
    const path = std.fs.path.join(alloc, &.{ content_dir, marker_basename }) catch return false;
    if (!fsutil.isOnlineOnly(alloc, path)) return false;
    _ = load(alloc, path, null) catch return true;
    return false;
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

pub const Source = union(enum) {
    remote: Remote,
    local: fsutil.SafeSegment,

    /// The identity a member resolves to, whichever form it took.
    pub fn id(s: Source) identity.Identity {
        return switch (s) {
            .remote => |r| r.id,
            .local => |seg| identity.local(seg),
        };
    }
};

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
    /// One entry per `repos` or `aliases` key, in file order: members first,
    /// then alias-only names. What `save` writes.
    entries: []Entry,
    /// Unknown top-level keys, verbatim, re-emitted by `save`.
    extra: json.ObjectMap,

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

    /// Number of members - entries the file listed under `repos`.
    pub fn memberCount(m: *const Marker) usize {
        var n: usize = 0;
        for (m.entries) |*e| {
            if (e.raw_source != null) n += 1;
        }
        return n;
    }

    /// Number of entries carrying an alias value, usable or not.
    pub fn aliasCount(m: *const Marker) usize {
        var n: usize = 0;
        for (m.entries) |*e| {
            if (e.raw_alias != null) n += 1;
        }
        return n;
    }

    /// A marker with no members yet; grow it through the mutation API.
    pub fn init(org: []const u8, name: []const u8) Marker {
        return .{
            .version = marker_version,
            .org = org,
            .name = name,
            .entries = &.{},
            .extra = .empty,
        };
    }

    /// Inserts or replaces the member `name` with `raw_value`, classified
    /// exactly as `load` classifies it. A value that fails its predicate is
    /// stored faulted rather than rejected - the caller chose to write it,
    /// and `save` must not lose it.
    pub fn upsert(m: *Marker, alloc: std.mem.Allocator, name: []const u8, raw_value: []const u8) !void {
        const parsed = try sourceEntry(alloc, name, .{ .string = raw_value });
        if (m.findEntry(name)) |e| {
            e.raw_source = parsed.raw_source;
            e.source = parsed.source;
            e.source_fault = parsed.source_fault;
        } else {
            try m.appendEntry(alloc, parsed);
        }
    }

    /// Sets (`alias_value != null`) or clears (`null`) the alias on `name`.
    /// Returns whether `name` carried an alias value before the call - the
    /// clear path's callers branch on it. Clearing the alias of an entry
    /// that exists only for its alias removes the entry.
    pub fn setAlias(m: *Marker, alloc: std.mem.Allocator, name: []const u8, alias_value: ?[]const u8) !bool {
        const existing = m.findEntry(name);
        const had = if (existing) |e| e.raw_alias != null else false;
        if (alias_value) |v| {
            const e = existing orelse blk: {
                try m.appendEntry(alloc, .{
                    .name = name,
                    .raw_source = null,
                    .source = null,
                    .source_fault = null,
                    .raw_alias = null,
                    .alias = null,
                    .alias_fault = null,
                });
                break :blk &m.entries[m.entries.len - 1];
            };
            e.raw_alias = .{ .string = v };
            if (fsutil.SafeSegment.parse(v)) |seg| {
                e.alias = seg;
                e.alias_fault = null;
            } else {
                e.alias = null;
                e.alias_fault = .unsafe_segment;
            }
        } else if (existing) |e| {
            e.raw_alias = null;
            e.alias = null;
            e.alias_fault = null;
            if (e.raw_source == null) _ = m.remove(name);
        }
        return had;
    }

    /// Removes the whole entry `name` - member, alias, or both, faulted or
    /// not. Returns whether an entry existed, so an unusable or alias-only
    /// name stays deletable.
    pub fn remove(m: *Marker, name: []const u8) bool {
        for (m.entries, 0..) |*e, i| {
            if (std.mem.eql(u8, e.name, name)) {
                std.mem.copyForwards(Entry, m.entries[i .. m.entries.len - 1], m.entries[i + 1 ..]);
                m.entries = m.entries[0 .. m.entries.len - 1];
                return true;
            }
        }
        return false;
    }

    fn appendEntry(m: *Marker, alloc: std.mem.Allocator, e: Entry) !void {
        const grown = try alloc.alloc(Entry, m.entries.len + 1);
        @memcpy(grown[0..m.entries.len], m.entries);
        grown[m.entries.len] = e;
        m.entries = grown;
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
    // for the required fields are reproduced below. Anything else is a
    // future holt's data: carried in `extra` and re-emitted by `save`.
    var extra: json.ObjectMap = .empty;
    var kit = obj.iterator();
    outer: while (kit.next()) |kv| {
        inline for ([_][]const u8{ "version", "org", "name", "repos", "aliases" }) |known| {
            if (std.mem.eql(u8, kv.key_ptr.*, known)) continue :outer;
        }
        try extra.put(alloc, kv.key_ptr.*, kv.value_ptr.*);
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

    var entries: std.ArrayList(Entry) = .empty;
    var it = raw_repos.object.iterator();
    while (it.next()) |entry| {
        try entries.append(alloc, try sourceEntry(alloc, entry.key_ptr.*, entry.value_ptr.*));
    }

    if (obj.get("aliases")) |av| {
        if (av != .object) {
            if (diag) |d| d.set(alloc, "\"aliases\" must be an object", .{});
            return error.MalformedMarker;
        }
        var ait = av.object.iterator();
        while (ait.next()) |entry| {
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
        .entries = try entries.toOwnedSlice(alloc),
        .extra = extra,
    };
}

/// Writes `m` to `path` as sorted-key, 2-space pretty JSON with a trailing
/// newline. Atomic via `fsutil.writeFileAtomic`, so a crash never leaves a
/// half-written marker and two concurrent savers never collide on the temp.
/// Emission reads `entries` and `extra`: every raw value - faulted members
/// and aliases included - and every unknown top-level key goes back out
/// verbatim, so a save never destroys what load could not parse.
pub fn save(m: *const Marker, path: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var repos_obj: json.ObjectMap = .empty;
    for (m.entries) |e| {
        if (e.raw_source) |rv| try repos_obj.put(arena, e.name, rv);
    }

    var root: json.ObjectMap = .empty;
    try root.put(arena, "name", .{ .string = m.name });
    try root.put(arena, "org", .{ .string = m.org });
    try root.put(arena, "repos", .{ .object = repos_obj });
    try root.put(arena, "version", .{ .integer = m.version });

    // Omit the key entirely when empty so markers without aliases stay
    // byte-identical to their pre-alias form.
    var aliases_obj: json.ObjectMap = .empty;
    for (m.entries) |e| {
        if (e.raw_alias) |rv| try aliases_obj.put(arena, e.name, rv);
    }
    if (aliases_obj.count() > 0) try root.put(arena, "aliases", .{ .object = aliases_obj });

    var xit = m.extra.iterator();
    while (xit.next()) |kv| try root.put(arena, kv.key_ptr.*, kv.value_ptr.*);

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

    var m: Marker = .init("acme", "proj");
    try m.upsert(arena, "b", "local:b");
    try m.upsert(arena, "a", "https://github.com/acme/a");
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

    const m: Marker = .init("o", "n");
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

    var original: Marker = .init("acme", "proj");
    try original.upsert(arena, "widget", "https://github.com/acme/widget");
    try original.upsert(arena, "scratch", "local:scratch");
    try save(&original, path);

    const loaded = try load(arena, path, null);
    try testing.expectEqual(@as(u32, 1), loaded.version);
    try testing.expectEqualStrings("acme", loaded.org);
    try testing.expectEqualStrings("proj", loaded.name);
    try testing.expectEqual(@as(usize, 2), loaded.memberCount());
    try testing.expectEqualStrings("https://github.com/acme/widget", loaded.findRepo("widget").?.raw_source.?.string);
    try testing.expectEqualStrings("local:scratch", loaded.findRepo("scratch").?.raw_source.?.string);
}

test "save: an aliases object appears only when non-empty, sorted after the other keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var m: Marker = .init("acme", "proj");
    try m.upsert(arena, "widget", "https://github.com/acme/widget");
    _ = try m.setAlias(arena, "widget", "gadget");
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

    var m: Marker = .init("acme", "proj");
    try m.upsert(arena, "widget", "https://github.com/acme/widget");
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

    var original: Marker = .init("acme", "proj");
    try original.upsert(arena, "widget", "https://github.com/acme/widget");
    _ = try original.setAlias(arena, "widget", "gadget");
    try save(&original, path);

    const loaded = try load(arena, path, null);
    try testing.expectEqual(@as(usize, 1), loaded.aliasCount());
    try testing.expectEqualStrings("gadget", loaded.findEntry("widget").?.raw_alias.?.string);
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
    try testing.expectEqual(@as(usize, 0), loaded.aliasCount());
}

test "load: a non-string aliases entry is kept faulted, not fatal" {
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

    const m = try load(arena, path, null);
    const e = m.findEntry("a").?;
    try testing.expectEqual(Fault.not_a_string, e.alias_fault.?);
    try testing.expectEqual(@as(i128, 7), e.raw_alias.?.integer);
    try testing.expect(m.findEntry("a").?.alias == null);

    // save re-emits the value it could not parse.
    try save(&m, path);
    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, got, "\"a\": 7") != null);
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

test "load: an unknown top-level field is carried and re-emitted by save" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"acme\",\"name\":\"proj\",\"repos\":{},\"future\":true}\n",
    });
    const path = try markerPath(&tmp);
    defer testing.allocator.free(path);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = try load(arena, path, null);
    try testing.expect(m.extra.get("future").?.bool);

    try save(&m, path);
    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, got, "\"future\": true") != null);
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

test "load: a non-string repos entry is kept faulted, not fatal" {
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

    const m = try load(arena, path, null);
    const e = m.findRepo("a").?;
    try testing.expectEqual(Fault.not_a_string, e.source_fault.?);
    try testing.expectEqual(@as(i128, 42), e.raw_source.?.integer);
    try testing.expect(m.findRepo("a").?.source == null);

    // The member stays removable even though its value never parsed.
    var mm = m;
    try testing.expect(mm.remove("a"));
    try testing.expect(mm.findEntry("a") == null);
}

fn encodedValue(arena: std.mem.Allocator, v: json.Value) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try json.encode(&aw.writer, v, .{});
    return aw.written();
}

fn expectSameRaw(arena: std.mem.Allocator, a: ?json.Value, b: ?json.Value) !void {
    if (a == null or b == null) {
        try testing.expect(a == null and b == null);
        return;
    }
    try testing.expectEqualStrings(try encodedValue(arena, a.?), try encodedValue(arena, b.?));
}

test "round-trip: entry preservation and idempotence across the marker corpus" {
    const corpus = [_][]const u8{
        // scp-form remote
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"w\":\"git@github.com:acme/widget.git\"}}",
        // ssh:// remote
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"w\":\"ssh://git@github.com/acme/widget.git\"}}",
        // local: member
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"s\":\"local:scratch\"}}",
        // aliases present
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"w\":\"https://github.com/acme/w\"},\"aliases\":{\"w\":\"x\"}}",
        // aliases absent
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"w\":\"https://github.com/acme/w\"}}",
        // aliases empty: save omits the key, so entry preservation and byte
        // preservation visibly diverge on this input
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"w\":\"https://github.com/acme/w\"},\"aliases\":{}}",
        // unusable source
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"e\":\"local:../../evil\"}}",
        // unusable alias on a valid member
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"w\":\"https://github.com/acme/w\"},\"aliases\":{\"w\":\"../evil\"}}",
        // orphan alias
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{},\"aliases\":{\"ghost\":\"x\"}}",
        // non-string member value
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"b\":{\"url\":\"future\"}}}",
        // non-string alias value
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"w\":\"https://github.com/acme/w\"},\"aliases\":{\"w\":[1,2]}}",
        // unknown top-level key
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{},\"future\":{\"deep\":[1,null]}}",
        // unsorted input keys
        "{\"repos\":{\"b\":\"local:b\",\"a\":\"local:a\"},\"name\":\"n\",\"org\":\"o\",\"version\":1}",
        // \uXXXX-escaped value
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{\"u\":\"local:\\u0065scaped\"}}",
        // zero members
        "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{}}",
    };

    for (corpus) |input| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = marker_basename, .data = input });
        const path = try markerPath(&tmp);
        defer testing.allocator.free(path);

        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const m1 = try load(arena, path, null);
        try save(&m1, path);
        const first = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 20));

        // Entry preservation: same names, raw values, and unknown keys.
        // Compared by name, not index - save sorts keys.
        const m2 = try load(arena, path, null);
        try testing.expectEqual(m1.entries.len, m2.entries.len);
        for (m1.entries) |*e1| {
            const e2 = m2.findEntry(e1.name) orelse return error.TestUnexpectedResult;
            try expectSameRaw(arena, e1.raw_source, e2.raw_source);
            try expectSameRaw(arena, e1.raw_alias, e2.raw_alias);
            try testing.expectEqual(e1.source_fault, e2.source_fault);
            try testing.expectEqual(e1.alias_fault, e2.alias_fault);
            try testing.expectEqual(e1.source == null, e2.source == null);
        }
        try testing.expectEqual(m1.extra.count(), m2.extra.count());
        var xit = m1.extra.iterator();
        while (xit.next()) |kv| {
            const other = m2.extra.get(kv.key_ptr.*) orelse return error.TestUnexpectedResult;
            try expectSameRaw(arena, kv.value_ptr.*, other);
        }

        // Idempotence: the second save emits the first save's bytes.
        try save(&m2, path);
        const second = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(1 << 20));
        try testing.expectEqualStrings(first, second);
    }
}

test "load: a non-object aliases container stays fatal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = marker_basename,
        .data = "{\"version\":1,\"org\":\"o\",\"name\":\"n\",\"repos\":{},\"aliases\":7}\n",
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
