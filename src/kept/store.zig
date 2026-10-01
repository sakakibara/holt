//! The kept store under `<synced_root>/kept/`: its layout, the per-key
//! record, the one-file-per-fact markers (path facts, released paths,
//! earlier identities), key enumeration and resolution, and the checks that
//! surface files no fact names. All returned memory lives in the caller's
//! allocator, meant to be a per-command arena.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("json");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const machine = @import("machine.zig");
const link = @import("link.zig");
const ui = @import("../ui.zig");
const testing = std.testing;

const io = fsutil.io;
pub const Kind = content.Kind;

pub const record_basename = ".holt-kept.json";
pub const record_version = 1;

/// Where everything in the kept store lives, derived from the current
/// `synced_root` and never stored.
pub const Layout = struct {
    synced_root: []const u8,

    pub fn keptDir(self: Layout, alloc: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.synced_root, "kept" });
    }

    pub fn keyDir(self: Layout, alloc: std.mem.Allocator, key: []const u8) ![]u8 {
        return fsutil.joinSlashy(alloc, try self.keptDir(alloc), key);
    }

    /// The kept copy of `rel` in `key`: the target every link to it names.
    pub fn copyPath(self: Layout, alloc: std.mem.Allocator, key: []const u8, rel: []const u8) ![]u8 {
        return fsutil.joinSlashy(alloc, try self.keyDir(alloc, key), rel);
    }

    pub fn reserved(self: Layout, alloc: std.mem.Allocator, key: []const u8, name: []const u8) ![]u8 {
        return std.fs.path.join(alloc, &.{ try self.keyDir(alloc, key), name });
    }

    pub fn asideDir(self: Layout, alloc: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(alloc, &.{ try self.keptDir(alloc), ".holt-aside" });
    }

    /// Staging for writes into `key` from `machine_id`.
    pub fn stagingDir(self: Layout, alloc: std.mem.Allocator, machine_id: []const u8, key: []const u8) ![]u8 {
        const kid = paths.id(key);
        return std.fs.path.join(alloc, &.{ try self.keptDir(alloc), ".holt-tmp", machine_id, &kid });
    }
};

/// True for a `/`-joined key: at least two components, each safe to join
/// and none reserved or treated by git as `.git`.
pub fn validKey(key: []const u8) bool {
    if (fsutil.SafeRel.parse(key) == null) return false;
    if (paths.check(key) != null) return false;
    return std.mem.indexOfScalar(u8, key, '/') != null;
}

pub fn isLocalKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "local/");
}

fn parseObject(alloc: std.mem.Allocator, bytes: []const u8) ?json.ObjectMap {
    const v = json.parse(alloc, bytes, .{}) catch return null;
    return if (v == .object) v.object else null;
}

fn getString(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn encode(alloc: std.mem.Allocator, obj: json.ObjectMap) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try json.encode(&aw.writer, .{ .object = obj }, .{ .indent = 2, .sort_keys = true });
    try aw.writer.writeByte('\n');
    return aw.written();
}

/// Writes `data` to `path` only if nothing is there yet, atomically.
pub fn createExclusive(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try fsutil.ensureDir(d);
    const tmp = try content.tempSibling(alloc, path);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = tmp, .data = data });
    content.renameNoReplace(alloc, tmp, path) catch |err| {
        fsutil.removePath(tmp) catch {};
        return err;
    };
}

/// A key's `.holt-kept.json`. `version` is null when missing or not an
/// integer; `obj` keeps every field, known or not, for rewriting.
pub const Record = struct {
    version: ?i128,
    origin: ?[]const u8,
    root: ?[]const u8,
    obj: json.ObjectMap,

    /// holt writes to a key only when it understands its record.
    pub fn known(self: Record) bool {
        return self.version != null and self.version.? == record_version;
    }
};

/// The record of `key`, or null when the key has none. Unparseable bytes
/// read as a record of unknown version.
pub fn readRecord(alloc: std.mem.Allocator, layout: Layout, key: []const u8) !?Record {
    const path = try layout.reserved(alloc, key, record_basename);
    const bytes = content.readSmall(alloc, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    const obj = parseObject(alloc, bytes) orelse return .{ .version = null, .origin = null, .root = null, .obj = .empty };
    const version: ?i128 = if (obj.get("version")) |v| (if (v == .integer) v.integer else null) else null;
    return .{ .version = version, .origin = getString(obj, "origin"), .root = getString(obj, "root"), .obj = obj };
}

/// What `ensureKey` would find for `key`, writing nothing: the existing
/// record, or null when the key would be created. Refuses exactly as
/// `ensureKey` does.
pub fn checkKey(alloc: std.mem.Allocator, layout: Layout, index: *const KeyIndex, key: []const u8, root: ?[]const u8, clone_roots: []const []const u8) !?Record {
    if (!validKey(key)) return error.InvalidKey;
    if (try readRecord(alloc, layout, key)) |rec| {
        if (!rec.known()) return error.UnknownRecordVersion;
        if (rec.root) |r| if (isLocalKey(key) and !paths.contains(clone_roots, r)) return error.LocalMismatch;
        return rec;
    }
    if (isLocalKey(key) and root == null) return error.RootRequired;
    if (index.successorsOf(key).len > 0) return error.KeySuperseded;
    const dir = try layout.keyDir(alloc, key);
    if (std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true })) |d| {
        var opened = d;
        defer opened.close(io());
        var it = opened.iterate();
        if (try it.next(io()) != null) return error.KeyDirNotEmpty;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    return null;
}

/// The record of `key` for a clone whose root commits are `clone_roots`,
/// creating the key and its record when absent. A key is never created in a
/// directory that already holds files, or when a `.holt-from/` marker of
/// another key names it. A `local/` key needs `root`, and an existing one
/// whose `root` is not among `clone_roots` belongs to another repo:
/// `LocalMismatch`. An existing record missing `root` has it filled.
pub fn ensureKey(alloc: std.mem.Allocator, layout: Layout, index: *const KeyIndex, key: []const u8, origin: ?[]const u8, root: ?[]const u8, clone_roots: []const []const u8) !Record {
    if (try checkKey(alloc, layout, index, key, root, clone_roots)) |rec| {
        if (rec.root == null) if (root) |r| return fillRoot(alloc, layout, key, rec, r);
        return rec;
    }

    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "version", .{ .integer = record_version });
    if (origin) |o| try obj.put(alloc, "origin", .{ .string = o });
    if (root) |r| try obj.put(alloc, "root", .{ .string = r });
    createExclusive(alloc, try layout.reserved(alloc, key, record_basename), try encode(alloc, obj)) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const rec = (try readRecord(alloc, layout, key)) orelse return err;
            if (!rec.known()) return error.UnknownRecordVersion;
            return rec;
        },
        else => return err,
    };
    return .{ .version = record_version, .origin = origin, .root = root, .obj = obj };
}

fn fillRoot(alloc: std.mem.Allocator, layout: Layout, key: []const u8, rec: Record, root: []const u8) !Record {
    var obj = try rec.obj.clone(alloc);
    try obj.put(alloc, "root", .{ .string = root });
    try fsutil.writeFileAtomic(alloc, try layout.reserved(alloc, key, record_basename), try encode(alloc, obj));
    return .{ .version = rec.version, .origin = rec.origin, .root = root, .obj = obj };
}

/// A marker holt could not use: where it is and why.
pub const Bad = struct { path: []const u8, reason: []const u8 };

/// One machine's statement that it kept `rel` with content `sha256`.
pub const Fact = struct {
    rel: []const u8,
    kind: Kind,
    sha256: []const u8,
    machine: []const u8,
    /// The sha256 of the fact file's bytes, as a retirement lists it
    /// (`factRetired`).
    file_sha256: [64]u8,
};

/// Where `machine_id`'s fact for `rel` of `key` is filed, `/`-joined under
/// `kept/`: the name a retirement lists it by.
pub fn factFile(alloc: std.mem.Allocator, key: []const u8, rel: []const u8, machine_id: []const u8) ![]u8 {
    const sid = paths.id(rel);
    return std.mem.concat(alloc, u8, &.{ key, "/.holt-paths/", &sid, "/", machine_id });
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return std.fmt.bytesToHex(out, .lower);
}

fn markerDir(alloc: std.mem.Allocator, layout: Layout, key: []const u8, family: []const u8, s: []const u8) ![]u8 {
    const sid = paths.id(s);
    return std.fs.path.join(alloc, &.{ try layout.keyDir(alloc, key), family, &sid });
}

/// Writes `machine_id`'s fact for `rel`, and, when absent or naming another
/// host, the machine's host label (`writeHost`), so a machine that is gone
/// can be named by the host it ran on. Each write carries a fresh random
/// `nonce`, which readers ignore, so no rewrite reproduces bytes a
/// retirement lists (`factRetired`).
pub fn writeFact(alloc: std.mem.Allocator, layout: Layout, key: []const u8, machine_id: []const u8, rel: []const u8, kind: Kind, sha256: []const u8) !void {
    var obj: json.ObjectMap = .empty;
    const nonce = content.randomSuffix();
    try obj.put(alloc, "kind", .{ .string = @tagName(kind) });
    try obj.put(alloc, "nonce", .{ .string = &nonce });
    try obj.put(alloc, "rel", .{ .string = rel });
    try obj.put(alloc, "sha256", .{ .string = sha256 });
    const dir = try markerDir(alloc, layout, key, ".holt-paths", rel);
    try fsutil.ensureDir(dir);
    try fsutil.writeFileAtomic(alloc, try std.fs.path.join(alloc, &.{ dir, machine_id }), try encode(alloc, obj));
    var buf: [machine.host_name_max]u8 = undefined;
    const host = machine.hostName(&buf);
    if (!std.mem.eql(u8, (try readHost(alloc, layout, machine_id)) orelse "", host)) try writeHost(alloc, layout, machine_id, host);
}

/// `kept/.holt-machines/<machine_id>/`: what the store records of one
/// machine, one file per fact: `host`, the host label it last wrote a fact
/// from, and `retired`, once it is retired (`writeRetired`).
pub fn machineDir(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ try layout.keptDir(alloc), machines_basename, machine_id });
}

pub const machines_basename = ".holt-machines";

/// Records `host` as the host label of `machine_id`.
pub fn writeHost(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, host: []const u8) !void {
    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "host", .{ .string = host });
    const dir = try machineDir(alloc, layout, machine_id);
    try fsutil.ensureDir(dir);
    try fsutil.writeFileAtomic(alloc, try std.fs.path.join(alloc, &.{ dir, "host" }), try encode(alloc, obj));
}

/// The host label recorded for `machine_id`, or null when none is.
pub fn readHost(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8) !?[]const u8 {
    const bytes = content.readSmall(alloc, try std.fs.path.join(alloc, &.{ try machineDir(alloc, layout, machine_id), "host" })) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return getString(parseObject(alloc, bytes) orelse return null, "host");
}

pub const Retired = struct {
    /// The UTC date it was retired, `YYYY-MM-DD`.
    date: []const u8,
    /// The host label of the machine that retired it.
    by_host: []const u8,
    /// The id of the machine that retired it; null when the record names
    /// none.
    by_machine: ?[]const u8 = null,
    /// Every fact file of the machine when it was retired (`factFile`),
    /// each to the sha256 of its bytes then.
    covers: json.ObjectMap,

    /// Whether the fact filed at `file` (`factFile`) is one the retirement
    /// covers, holding the bytes it held then.
    pub fn covered(self: Retired, file: []const u8, file_sha256: []const u8) bool {
        const v = self.covers.get(file) orelse return false;
        return v == .string and std.mem.eql(u8, v.string, file_sha256);
    }
};

/// One fact file of a machine: where it is filed (`factFile`) and the
/// sha256 of its bytes.
pub const FactFile = struct { path: []const u8, sha256: [64]u8 };

/// Every fact file `machine_id` has in any key of `index`, sorted by path.
pub fn machineFactFiles(alloc: std.mem.Allocator, layout: Layout, index: *const KeyIndex, machine_id: []const u8) ![]const FactFile {
    var out: std.ArrayList(FactFile) = .empty;
    for (index.keys) |key| {
        const root = try layout.reserved(alloc, key, ".holt-paths");
        var d = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |idir| {
            if (idir.kind != .directory) continue;
            const file = try std.fs.path.join(alloc, &.{ root, idir.name, machine_id });
            const bytes = content.readSmall(alloc, file) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.IsDir => continue,
                else => return err,
            };
            try out.append(alloc, .{ .path = try std.mem.concat(alloc, u8, &.{ key, "/.holt-paths/", idir.name, "/", machine_id }), .sha256 = sha256Hex(bytes) });
        }
    }
    std.mem.sort(FactFile, out.items, {}, struct {
        fn lt(_: void, x: FactFile, y: FactFile) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.lt);
    return out.items;
}

/// Records `machine_id` as retired on `date` (`YYYY-MM-DD`), by the
/// machine `by_machine` of the host `by_host`, covering every fact it has in `index` as its bytes are now
/// (`machineFactFiles`): those facts no longer stand for content that may
/// not have arrived (`factRetired`); a fact it writes or rewrites later
/// does. Writing it again replaces the record, covering the facts then.
pub fn writeRetired(alloc: std.mem.Allocator, layout: Layout, index: *const KeyIndex, machine_id: []const u8, date: []const u8, by_host: []const u8, by_machine: []const u8) !void {
    if (!machine.valid(machine_id)) return error.InvalidMachineId;
    var covers: json.ObjectMap = .empty;
    for (try machineFactFiles(alloc, layout, index, machine_id)) |f| try covers.put(alloc, f.path, .{ .string = try alloc.dupe(u8, &f.sha256) });
    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "date", .{ .string = date });
    try obj.put(alloc, "host", .{ .string = by_host });
    try obj.put(alloc, "by", .{ .string = by_machine });
    try obj.put(alloc, "facts", .{ .object = covers });
    const dir = try machineDir(alloc, layout, machine_id);
    try fsutil.ensureDir(dir);
    try fsutil.writeFileAtomic(alloc, try std.fs.path.join(alloc, &.{ dir, "retired" }), try encode(alloc, obj));
}

/// Removes `machine_id`'s retirement record: every fact of it stands again.
/// False when it was not retired.
pub fn removeRetired(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8) !bool {
    if (!machine.valid(machine_id)) return error.InvalidMachineId;
    const file = try std.fs.path.join(alloc, &.{ try machineDir(alloc, layout, machine_id), "retired" });
    if (try content.entryAt(file) == .absent) return false;
    try fsutil.removePath(file);
    return true;
}

/// The retirement record of `machine_id`, or null when it is not retired.
/// A record that cannot be parsed is dated `?` and covers no fact.
pub fn readRetired(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8) !?Retired {
    if (!machine.valid(machine_id)) return null;
    const bytes = content.readSmall(alloc, try std.fs.path.join(alloc, &.{ try machineDir(alloc, layout, machine_id), "retired" })) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    const obj = parseObject(alloc, bytes) orelse return .{ .date = "?", .by_host = "?", .covers = .empty };
    const covers: json.ObjectMap = if (obj.get("facts")) |v| (if (v == .object) v.object else .empty) else .empty;
    return .{ .date = getString(obj, "date") orelse "?", .by_host = getString(obj, "host") orelse "?", .by_machine = getString(obj, "by"), .covers = covers };
}

/// Whether `f`, a fact of `key`, is one its machine's retirement covers
/// (`Retired.covered`), so it stands for no content still on its way. A
/// fact written or rewritten after the retirement is not.
pub fn factRetired(alloc: std.mem.Allocator, layout: Layout, key: []const u8, f: Fact) !bool {
    const ret = (try readRetired(alloc, layout, f.machine)) orelse return false;
    return ret.covered(try factFile(alloc, key, f.rel, f.machine), &f.file_sha256);
}

/// Whether `machine_id` is retired and has a fact in `index` its
/// retirement does not cover: it wrote kept changes since.
pub fn activeAgain(alloc: std.mem.Allocator, layout: Layout, index: *const KeyIndex, machine_id: []const u8) !bool {
    const ret = (try readRetired(alloc, layout, machine_id)) orelse return false;
    for (try machineFactFiles(alloc, layout, index, machine_id)) |f| {
        if (!ret.covered(f.path, &f.sha256)) return true;
    }
    return false;
}

/// The latest instant `utcDate` names a day of: the end of year 9999.
const date_secs_max: i64 = 253402300799;

/// The UTC date of `secs`, seconds since the epoch, as `YYYY-MM-DD`: that
/// of 1970-01-01 for an earlier instant, and of 9999-12-31 for a later one.
pub fn utcDate(alloc: std.mem.Allocator, secs: i64) ![]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(std.math.clamp(secs, 0, date_secs_max)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1 });
}

/// Today's UTC date as `YYYY-MM-DD`.
pub fn today(alloc: std.mem.Allocator) ![]u8 {
    return utcDate(alloc, @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_s)));
}

/// `date`, a UTC date `utcDate` wrote, as holt prints it:
/// `YYYY-MM-DD UTC`; `?`, for a record that cannot be read, as it is. A
/// date read from the synced store is shown as `ui.printable` shows it.
pub fn shownDate(alloc: std.mem.Allocator, date: []const u8) ![]const u8 {
    if (std.mem.eql(u8, date, "?")) return date;
    return std.mem.concat(alloc, u8, &.{ try ui.printable(alloc, date), " UTC" });
}

/// A machine that wrote facts in the store: its id, its host label when
/// recorded, when its newest fact was written, and its retirement when it
/// is retired.
pub const MachineInfo = struct {
    id: []const u8,
    host: ?[]const u8,
    /// The modification time of its newest fact, in seconds since the
    /// epoch; null when it has none, or when one's time cannot be read or
    /// lies before the epoch (`last_unknown`).
    last_fact: ?i64,
    last_unknown: bool = false,
    retired: ?Retired,
    /// Retired, with a fact written since (`activeAgain`).
    active_again: bool,
};

/// Every machine with a fact in any key of `index`, and every retired one,
/// sorted by id.
pub fn machines(alloc: std.mem.Allocator, layout: Layout, index: *const KeyIndex) ![]const MachineInfo {
    var newest: std.StringArrayHashMapUnmanaged(i128) = .empty;
    var unknown: std.StringHashMapUnmanaged(void) = .empty;
    for (index.keys) |key| {
        const root = try layout.reserved(alloc, key, ".holt-paths");
        var d = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch continue;
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |idir| {
            if (idir.kind != .directory) continue;
            var sub = d.openDir(io(), idir.name, .{ .iterate = true }) catch continue;
            defer sub.close(io());
            var sit = sub.iterate();
            while (try sit.next(io())) |f| {
                if (!machine.valid(f.name)) continue;
                const gop = try newest.getOrPut(alloc, try alloc.dupe(u8, f.name));
                if (!gop.found_existing) gop.value_ptr.* = -1;
                const st = sub.statFile(io(), f.name, .{ .follow_symlinks = false }) catch {
                    try unknown.put(alloc, gop.key_ptr.*, {});
                    continue;
                };
                if (st.mtime.nanoseconds < 0) try unknown.put(alloc, gop.key_ptr.*, {});
                if (st.mtime.nanoseconds > gop.value_ptr.*) gop.value_ptr.* = st.mtime.nanoseconds;
            }
        }
    }
    if (std.Io.Dir.cwd().openDir(io(), try std.fs.path.join(alloc, &.{ try layout.keptDir(alloc), machines_basename }), .{ .iterate = true })) |dd| {
        var d = dd;
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| {
            if (!machine.valid(e.name)) continue;
            const gop = try newest.getOrPut(alloc, try alloc.dupe(u8, e.name));
            if (!gop.found_existing) gop.value_ptr.* = -1;
        }
    } else |_| {}
    var out: std.ArrayList(MachineInfo) = .empty;
    for (newest.keys(), newest.values()) |id, ns| {
        const lost = unknown.contains(id);
        const last: ?i64 = if (ns < 0 or lost) null else @intCast(@divFloor(ns, std.time.ns_per_s));
        try out.append(alloc, .{ .id = id, .host = try readHost(alloc, layout, id), .last_fact = last, .last_unknown = lost, .retired = try readRetired(alloc, layout, id), .active_again = try activeAgain(alloc, layout, index, id) });
    }
    std.mem.sort(MachineInfo, out.items, {}, struct {
        fn lt(_: void, x: MachineInfo, y: MachineInfo) bool {
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.lt);
    return out.items;
}

/// Removes every machine's fact for `rel`.
pub fn removeFacts(alloc: std.mem.Allocator, layout: Layout, key: []const u8, rel: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io(), try markerDir(alloc, layout, key, ".holt-paths", rel));
}

/// Makes this machine's fact for `rel` the only one: it is written first
/// and every other machine's then removed, so `rel` is never without a
/// fact.
pub fn replaceFacts(alloc: std.mem.Allocator, layout: Layout, key: []const u8, machine_id: []const u8, rel: []const u8, kind: Kind, sha256: []const u8) !void {
    try writeFact(alloc, layout, key, machine_id, rel, kind, sha256);
    const dir = try markerDir(alloc, layout, key, ".holt-paths", rel);
    var others: std.ArrayList([]const u8) = .empty;
    {
        var d = try std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true });
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| {
            if (!std.mem.eql(u8, e.name, machine_id)) try others.append(alloc, try std.fs.path.join(alloc, &.{ dir, e.name }));
        }
    }
    for (others.items) |o| try std.Io.Dir.cwd().deleteTree(io(), o);
}

fn validHex(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn isTemp(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".tmp") or std.mem.startsWith(u8, name, ".holt-tmp-");
}

/// Every fact of `key`, sorted by rel then machine. A fact whose name,
/// content, or id does not check out goes to `bad` instead.
pub fn readFacts(alloc: std.mem.Allocator, layout: Layout, key: []const u8, bad: *std.ArrayList(Bad)) ![]Fact {
    const root = try layout.reserved(alloc, key, ".holt-paths");
    var out: std.ArrayList(Fact) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.items,
        else => return err,
    };
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |idir| {
        const idir_path = try std.fs.path.join(alloc, &.{ root, idir.name });
        if (idir.kind != .directory) {
            try bad.append(alloc, .{ .path = idir_path, .reason = "not a record directory" });
            continue;
        }
        var sub = try std.Io.Dir.cwd().openDir(io(), idir_path, .{ .iterate = true });
        defer sub.close(io());
        var sit = sub.iterate();
        while (try sit.next(io())) |f| {
            const fpath = try std.fs.path.join(alloc, &.{ idir_path, f.name });
            if (isTemp(f.name)) continue;
            if (!machine.valid(f.name) or f.kind != .file) {
                try bad.append(alloc, .{ .path = fpath, .reason = "not a record file" });
                continue;
            }
            const bytes = try content.readSmall(alloc, fpath);
            const obj = parseObject(alloc, bytes) orelse {
                try bad.append(alloc, .{ .path = fpath, .reason = "unreadable record" });
                continue;
            };
            const rel = getString(obj, "rel") orelse "";
            const kind = std.meta.stringToEnum(Kind, getString(obj, "kind") orelse "");
            const sha = getString(obj, "sha256") orelse "";
            if (kind == null or !validHex(sha) or rel.len == 0) {
                try bad.append(alloc, .{ .path = fpath, .reason = "unreadable record" });
                continue;
            }
            if (!std.mem.eql(u8, &paths.id(rel), idir.name)) {
                try bad.append(alloc, .{ .path = fpath, .reason = "record filed under the wrong id" });
                continue;
            }
            try out.append(alloc, .{ .rel = rel, .kind = kind.?, .sha256 = sha, .machine = try alloc.dupe(u8, f.name), .file_sha256 = sha256Hex(bytes) });
        }
    }
    std.mem.sort(Fact, out.items, {}, factLess);
    return out.items;
}

fn factLess(_: void, a: Fact, b: Fact) bool {
    return switch (std.mem.order(u8, a.rel, b.rel)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.machine, b.machine) == .lt,
    };
}

fn writeValueMarker(alloc: std.mem.Allocator, dir: []const u8, s: []const u8, field: []const u8, value: []const u8) !void {
    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, field, .{ .string = value });
    try fsutil.ensureDir(dir);
    const sid = paths.id(s);
    try fsutil.writeFileAtomic(alloc, try std.fs.path.join(alloc, &.{ dir, &sid }), try encode(alloc, obj));
}

/// The values of every `<family>/<id>` marker holding `field`, sorted. A
/// marker whose value does not hash to its name goes to `bad`.
fn readValueMarkers(alloc: std.mem.Allocator, dir: []const u8, field: []const u8, bad: *std.ArrayList(Bad)) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.items,
        else => return err,
    };
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        if (isTemp(e.name)) continue;
        const p = try std.fs.path.join(alloc, &.{ dir, e.name });
        const value: ?[]const u8 = if (e.kind == .file)
            (if (parseObject(alloc, try content.readSmall(alloc, p))) |obj| getString(obj, field) else null)
        else
            null;
        if (value == null or !std.mem.eql(u8, &paths.id(value.?), e.name)) {
            try bad.append(alloc, .{ .path = p, .reason = "unreadable marker" });
            continue;
        }
        try out.append(alloc, value.?);
    }
    std.mem.sort([]const u8, out.items, {}, paths.lessThan);
    return out.items;
}

pub fn writeReleased(alloc: std.mem.Allocator, layout: Layout, key: []const u8, rel: []const u8) !void {
    try writeValueMarker(alloc, try layout.reserved(alloc, key, ".holt-released"), rel, "rel", rel);
}

/// A released path `unkeep --purge` removed from the kept store: `entry`
/// is the aside entry its kept content went to, null when it had none.
pub const Purge = struct { rel: []const u8, entry: ?[]const u8 };

/// Marks the released path `mark.rel` of `key` purged, as `mark` says. The
/// mark is part of the released marker, so a machine that holds the marker
/// holds the mark it was written with.
pub fn writePurged(alloc: std.mem.Allocator, layout: Layout, key: []const u8, mark: Purge) !void {
    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "rel", .{ .string = mark.rel });
    try obj.put(alloc, "purged", .{ .string = mark.entry orelse "" });
    const dir = try layout.reserved(alloc, key, ".holt-released");
    try fsutil.ensureDir(dir);
    const sid = paths.id(mark.rel);
    try fsutil.writeFileAtomic(alloc, try std.fs.path.join(alloc, &.{ dir, &sid }), try encode(alloc, obj));
}

/// Every purge mark of `key` (`writePurged`), sorted by path. A marker
/// `readReleased` takes for bad is left out, and so is an entry name that
/// is not a single name.
pub fn readPurged(alloc: std.mem.Allocator, layout: Layout, key: []const u8) ![]const Purge {
    var out: std.ArrayList(Purge) = .empty;
    const dir = try layout.reserved(alloc, key, ".holt-released");
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.items,
        else => return err,
    };
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        if (isTemp(e.name) or e.kind != .file) continue;
        const obj = parseObject(alloc, try content.readSmall(alloc, try std.fs.path.join(alloc, &.{ dir, e.name }))) orelse continue;
        const rel = getString(obj, "rel") orelse continue;
        if (!std.mem.eql(u8, &paths.id(rel), e.name)) continue;
        const entry = getString(obj, "purged") orelse continue;
        if (entry.len > 0 and !validEntryName(entry)) continue;
        try out.append(alloc, .{ .rel = rel, .entry = if (entry.len == 0) null else entry });
    }
    std.mem.sort(Purge, out.items, {}, struct {
        fn less(_: void, x: Purge, y: Purge) bool {
            return paths.lessThan({}, x.rel, y.rel);
        }
    }.less);
    return out.items;
}

pub const pruned_basename = ".holt-pruned";

/// Records that the aside entry `entry`, which a purge mark names, is
/// pruned: `kept/.holt-pruned/<entry>`, a file of its own that
/// `ops.pruneEntry` writes before it removes the entry and nothing edits,
/// so no machine takes the entry for one still arriving.
pub fn writePruned(alloc: std.mem.Allocator, layout: Layout, entry: []const u8) !void {
    if (!validEntryName(entry)) return error.InvalidEntryName;
    const dir = try std.fs.path.join(alloc, &.{ try layout.keptDir(alloc), pruned_basename });
    try fsutil.ensureDir(dir);
    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "entry", .{ .string = entry });
    try fsutil.writeFileAtomic(alloc, try std.fs.path.join(alloc, &.{ dir, entry }), try encode(alloc, obj));
}

/// Whether the aside entry `entry` is pruned (`writePruned`).
pub fn isPruned(alloc: std.mem.Allocator, layout: Layout, entry: []const u8) !bool {
    if (!validEntryName(entry)) return false;
    return try content.entryAt(try std.fs.path.join(alloc, &.{ try layout.keptDir(alloc), pruned_basename, entry })) != .absent;
}

/// Whether `name` can name an aside entry: one path component, not
/// reserved, and a valid kept path.
pub fn validEntryName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null or paths.isReserved(name)) return false;
    return paths.check(name) == null;
}

pub fn removeReleased(alloc: std.mem.Allocator, layout: Layout, key: []const u8, rel: []const u8) !void {
    const sid = paths.id(rel);
    try fsutil.removePath(try std.fs.path.join(alloc, &.{ try layout.reserved(alloc, key, ".holt-released"), &sid }));
}

pub fn readReleased(alloc: std.mem.Allocator, layout: Layout, key: []const u8, bad: *std.ArrayList(Bad)) ![]const []const u8 {
    return readValueMarkers(alloc, try layout.reserved(alloc, key, ".holt-released"), "rel", bad);
}

/// Records in `key` that `old_key` was an earlier identity of its repo.
pub fn writeFrom(alloc: std.mem.Allocator, layout: Layout, key: []const u8, old_key: []const u8) !void {
    try writeValueMarker(alloc, try layout.reserved(alloc, key, ".holt-from"), old_key, "key", old_key);
}

pub fn readFrom(alloc: std.mem.Allocator, layout: Layout, key: []const u8, bad: *std.ArrayList(Bad)) ![]const []const u8 {
    return readValueMarkers(alloc, try layout.reserved(alloc, key, ".holt-from"), "key", bad);
}

pub const roots_basename = ".holt-roots";

/// Records the current synced root in `kept/.holt-roots/`, once: a link
/// holt makes lies under it, so a link into it stays holt's once the store
/// is copied to another synced root (`syncedRoots`).
pub fn recordRoot(alloc: std.mem.Allocator, layout: Layout) !void {
    const dir = try std.fs.path.join(alloc, &.{ try layout.keptDir(alloc), roots_basename });
    const sid = paths.id(layout.synced_root);
    if (try content.entryAt(try std.fs.path.join(alloc, &.{ dir, &sid })) != .absent) return;
    try writeValueMarker(alloc, dir, layout.synced_root, "root", layout.synced_root);
}

/// Whether the store at the synced root `root` records that it has lived
/// there (`recordRoot`): a link into it is holt's, even while this machine
/// uses another synced root.
pub fn recordsRoot(alloc: std.mem.Allocator, root: []const u8) !bool {
    const all = try syncedRoots(alloc, .{ .synced_root = root });
    for (all[1..]) |r| if (link.sameRoot(alloc, r, root)) return true;
    return false;
}

/// The synced roots a holt link may lie under (`link.isHolt`): the current
/// one, then every one the store records it has lived at (`recordRoot`).
pub fn syncedRoots(alloc: std.mem.Allocator, layout: Layout) ![]const []const u8 {
    var bad: std.ArrayList(Bad) = .empty;
    const recorded = try readValueMarkers(alloc, try std.fs.path.join(alloc, &.{ try layout.keptDir(alloc), roots_basename }), "root", &bad);
    return std.mem.concat(alloc, []const u8, &.{ &.{layout.synced_root}, recorded });
}

/// Every key in the store and the earlier identities each one names.
pub const KeyIndex = struct {
    keys: []const []const u8,
    /// Earlier identity -> the keys whose `.holt-from/` names it, sorted.
    successors: std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
    bad: []const Bad,

    pub fn successorsOf(self: *const KeyIndex, key: []const u8) []const []const u8 {
        return if (self.successors.get(key)) |l| l.items else &.{};
    }
};

/// Walks `kept/` to every directory holding a record. Reserved `.holt-*`
/// entries are never entered, nor is a path a key's facts or released
/// markers name, since that is kept content; the rest of a key's
/// directories are, since a nested key can sit inside another. An absent
/// `kept/` is an empty index. Build it once per command.
pub fn loadIndex(alloc: std.mem.Allocator, layout: Layout) !KeyIndex {
    const kept = try layout.keptDir(alloc);
    var keys: std.ArrayList([]const u8) = .empty;
    var named: std.ArrayList([]const []const u8) = .empty;
    var bad: std.ArrayList(Bad) = .empty;
    var successors: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;

    if (std.Io.Dir.cwd().openDir(io(), kept, .{ .iterate = true })) |d| {
        var root = d;
        defer root.close(io());
        var walker = try root.walkSelectively(alloc);
        defer walker.deinit();
        next: while (try walker.next(io())) |entry| {
            if (entry.kind != .directory) continue;
            if (paths.isReserved(entry.basename)) continue;
            const rel = try alloc.dupe(u8, entry.path);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
            for (keys.items, named.items) |k, n| {
                if (rel.len > k.len and std.mem.startsWith(u8, rel, k) and rel[k.len] == '/' and paths.contains(n, rel[k.len + 1 ..])) continue :next;
            }
            const rec_path = try std.fs.path.join(alloc, &.{ kept, entry.path, record_basename });
            if (try content.entryAt(rec_path) == .file and validKey(rel)) {
                var ignored: std.ArrayList(Bad) = .empty;
                const facts = try readFacts(alloc, layout, rel, &ignored);
                const released = try readReleased(alloc, layout, rel, &ignored);
                const st: KeyState = .{ .key = rel, .record = null, .facts = facts, .released = released, .bad = &.{} };
                try keys.append(alloc, rel);
                try named.append(alloc, try st.namedPaths(alloc));
            }
            try walker.enter(io(), entry);
        }
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }
    std.mem.sort([]const u8, keys.items, {}, paths.lessThan);

    for (keys.items) |k| {
        for (try readFrom(alloc, layout, k, &bad)) |old| {
            const gop = try successors.getOrPut(alloc, old);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, k);
        }
    }
    return .{ .keys = keys.items, .successors = successors, .bad = bad.items };
}

/// A key nested inside another key, and whether a path of the outer key
/// contains it rather than lies inside it.
pub const Nested = struct { key: []const u8, contains: bool };

/// The key nested inside `key` that `rel` of `key` would enter or hold: a
/// key at `<key>/<rel>`, at a directory above it, or below it, compared the
/// way a filesystem resolves names. Null when there is none.
pub fn nestedKeyAt(alloc: std.mem.Allocator, index: *const KeyIndex, key: []const u8, rel: []const u8) !?Nested {
    const want = try paths.foldKey(alloc, rel);
    for (index.keys) |k| {
        if (k.len <= key.len + 1 or !std.mem.startsWith(u8, k, key) or k[key.len] != '/') continue;
        const inner = try paths.foldKey(alloc, k[key.len + 1 ..]);
        if (std.mem.eql(u8, want, inner) or isBelow(want, inner)) return .{ .key = k, .contains = false };
        if (isBelow(inner, want)) return .{ .key = k, .contains = true };
    }
    return null;
}

fn isBelow(child: []const u8, parent: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

pub const Resolution = union(enum) {
    /// The clone's own key.
    own,
    /// A later identity of the repo, which the clone matches.
    successor: []const u8,
    /// A `local/` key whose repo has been promoted elsewhere.
    awaiting_promote: []const u8,
};

/// Where the clone whose disk key is `key` and whose root commits are
/// `clone_roots` keeps its files. A remote key follows `.holt-from/`
/// successors to the last one whose record `root` the clone matches; a
/// `local/` key never resolves.
pub fn resolve(alloc: std.mem.Allocator, layout: Layout, index: *const KeyIndex, key: []const u8, clone_roots: []const []const u8) !Resolution {
    if (isLocalKey(key)) {
        const succ = index.successorsOf(key);
        return if (succ.len > 0) .{ .awaiting_promote = succ[0] } else .own;
    }
    var cur = key;
    var steps: usize = 0;
    outer: while (steps <= index.keys.len) : (steps += 1) {
        for (index.successorsOf(cur)) |s| {
            if (std.mem.eql(u8, s, cur)) continue;
            const rec = (try readRecord(alloc, layout, s)) orelse continue;
            const root = rec.root orelse continue;
            for (clone_roots) |r| {
                if (std.mem.eql(u8, r, root)) {
                    cur = s;
                    continue :outer;
                }
            }
        }
        break;
    }
    return if (std.mem.eql(u8, cur, key)) .own else .{ .successor = cur };
}

/// Everything the store says about one key.
pub const KeyState = struct {
    key: []const u8,
    record: ?Record,
    facts: []const Fact,
    released: []const []const u8,
    /// The purge marks among the released markers, sorted by path.
    purged: []const Purge = &.{},
    bad: []const Bad,

    pub fn factsFor(self: KeyState, rel: []const u8) []const Fact {
        var lo: usize = 0;
        while (lo < self.facts.len and std.mem.order(u8, self.facts[lo].rel, rel) == .lt) lo += 1;
        var hi = lo;
        while (hi < self.facts.len and std.mem.eql(u8, self.facts[hi].rel, rel)) hi += 1;
        return self.facts[lo..hi];
    }

    pub fn isReleased(self: KeyState, rel: []const u8) bool {
        return paths.contains(self.released, rel);
    }

    /// The purge mark of `rel`, when `unkeep --purge` wrote one.
    pub fn purgeOf(self: KeyState, rel: []const u8) ?Purge {
        for (self.purged) |p| if (std.mem.eql(u8, p.rel, rel)) return p;
        return null;
    }

    /// Paths with at least one fact and no released marker, sorted.
    pub fn keptSet(self: KeyState, alloc: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.facts, 0..) |f, i| {
            if (i > 0 and std.mem.eql(u8, self.facts[i - 1].rel, f.rel)) continue;
            if (!self.isReleased(f.rel)) try out.append(alloc, f.rel);
        }
        return out.items;
    }

    /// Every path a fact or released marker names, sorted and unique.
    pub fn namedPaths(self: KeyState, alloc: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.facts, 0..) |f, i| {
            if (i > 0 and std.mem.eql(u8, self.facts[i - 1].rel, f.rel)) continue;
            try out.append(alloc, f.rel);
        }
        for (self.released) |r| {
            if (!paths.contains(out.items, r)) try out.append(alloc, r);
        }
        std.mem.sort([]const u8, out.items, {}, paths.lessThan);
        return out.items;
    }
};

pub fn loadKeyState(alloc: std.mem.Allocator, layout: Layout, key: []const u8) !KeyState {
    var bad: std.ArrayList(Bad) = .empty;
    const record = try readRecord(alloc, layout, key);
    const facts = try readFacts(alloc, layout, key, &bad);
    const released = try readReleased(alloc, layout, key, &bad);
    return .{ .key = key, .record = record, .facts = facts, .released = released, .purged = try readPurged(alloc, layout, key), .bad = bad.items };
}

/// Whether `name` is one an operating system, a desktop, a cloud client,
/// or a NAS writes into any folder it shows: `.DS_Store`, `Icon\r`,
/// `desktop.ini`, `Thumbs.db`, `.directory`, `.Trash-*`, or a name
/// starting with `@` (`@eaDir`). Never content of the kept store.
pub fn isMetadata(name: []const u8) bool {
    for ([_][]const u8{ ".DS_Store", "Icon\r", "desktop.ini", "Thumbs.db", ".directory" }) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return std.mem.startsWith(u8, name, "@") or std.mem.startsWith(u8, name, ".Trash-");
}

/// The reserved name (`paths.isReserved`) that `name` is iCloud's
/// online-only stand-in for (`.<reserved>.icloud`), or null.
pub fn reservedStandIn(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, ".") or !std.mem.endsWith(u8, name, ".icloud")) return null;
    const inner = name[1 .. name.len - ".icloud".len];
    return if (paths.isReserved(inner)) inner else null;
}

/// Files and directories under `key` that no path in `named` accounts for,
/// as `/`-joined paths. Reserved `.holt-*` names, iCloud's stand-ins for
/// them (`reservedStandIn`), the names folders gather on their own
/// (`isMetadata`), and nested keys are not content of this key.
pub fn unknownFiles(alloc: std.mem.Allocator, layout: Layout, key: []const u8, named: []const []const u8) ![]const []const u8 {
    const root = try layout.keyDir(alloc, key);
    var out: std.ArrayList([]const u8) = .empty;
    var d = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.items,
        else => return err,
    };
    defer d.close(io());
    var walker = try d.walkSelectively(alloc);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (paths.isReserved(entry.basename) or reservedStandIn(entry.basename) != null) continue;
        const rel = try alloc.dupe(u8, entry.path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        if (paths.contains(named, rel)) continue;
        if (isMetadata(entry.basename) and !isAncestorOfAny(named, rel)) continue;
        if (entry.kind == .directory) {
            const rec = try std.fs.path.join(alloc, &.{ root, entry.path, record_basename });
            if (try content.entryAt(rec) == .file) continue;
            if (isAncestorOfAny(named, rel)) {
                try walker.enter(io(), entry);
                continue;
            }
            if (try holdsNothing(alloc, try std.fs.path.join(alloc, &.{ root, entry.path }))) continue;
        }
        try out.append(alloc, rel);
    }
    std.mem.sort([]const u8, out.items, {}, paths.lessThan);
    return out.items;
}

/// Whether the directory at `dir` holds nothing but directories and what
/// folders gather on their own (`isMetadata`), links not followed. A name
/// holt reserves, a key's marker, counts as something, and so does a
/// directory that cannot be read.
pub fn holdsNothing(alloc: std.mem.Allocator, dir: []const u8) !bool {
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch return false;
    defer d.close(io());
    var walker = try d.walkSelectively(alloc);
    defer walker.deinit();
    while (walker.next(io()) catch return false) |entry| {
        if (paths.isReserved(entry.basename) or reservedStandIn(entry.basename) != null) return false;
        if (isMetadata(entry.basename)) continue;
        if (entry.kind != .directory) return false;
        try walker.enter(io(), entry);
    }
    return true;
}

fn isAncestorOfAny(list: []const []const u8, dir: []const u8) bool {
    for (list) |x| {
        if (x.len > dir.len and std.mem.startsWith(u8, x, dir) and x[dir.len] == '/') return true;
    }
    return false;
}

const Fixture = @import("harness.zig").Fixture;

const hex_a = "a" ** 64;
const hex_b = "b" ** 64;

test "ensureKey: creates a record once, keeps unknown fields, fills a missing root" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    var index = try loadIndex(a, layout);

    const rec = try ensureKey(a, layout, &index, "github.com/acme/widget", "https://github.com/acme/widget", null, &.{});
    try testing.expect(rec.known());
    try testing.expect(rec.root == null);

    _ = try f.write("kept/github.com/acme/widget/.holt-kept.json", "{\"version\": 1, \"origin\": \"o\", \"future\": [1, 2]}");
    const filled = try ensureKey(a, layout, &index, "github.com/acme/widget", null, "abc", &.{});
    try testing.expectEqualStrings("abc", filled.root.?);
    const back = (try readRecord(a, layout, "github.com/acme/widget")).?;
    try testing.expectEqualStrings("abc", back.root.?);
    try testing.expectEqualStrings("o", back.origin.?);
    try testing.expect(back.obj.get("future") != null);
}

test "ensureKey: refuses an unknown version, a non-empty directory, a superseded key, a rootless local key, and a local key of another repo" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };

    _ = try f.write("kept/example.com/a/future/.holt-kept.json", "{\"version\": 2}");
    _ = try f.write("kept/example.com/a/stray/file", "x");
    _ = try f.write("kept/example.com/a/new/.holt-kept.json", "{\"version\": 1}");
    var index = try loadIndex(a, layout);
    try writeFrom(a, layout, "example.com/a/new", "example.com/a/old");
    index = try loadIndex(a, layout);

    try testing.expectError(error.UnknownRecordVersion, ensureKey(a, layout, &index, "example.com/a/future", null, null, &.{}));
    try testing.expectError(error.KeyDirNotEmpty, ensureKey(a, layout, &index, "example.com/a/stray", null, null, &.{}));
    try testing.expectError(error.KeySuperseded, ensureKey(a, layout, &index, "example.com/a/old", null, null, &.{}));
    try testing.expectError(error.RootRequired, ensureKey(a, layout, &index, "local/scratch", null, null, &.{}));
    try testing.expectError(error.InvalidKey, ensureKey(a, layout, &index, "../escape", null, null, &.{}));

    _ = try ensureKey(a, layout, &index, "local/scratch", null, "r1", &.{"r1"});
    try testing.expectError(error.LocalMismatch, ensureKey(a, layout, &index, "local/scratch", null, "r2", &.{"r2"}));
    try testing.expectEqualStrings("r1", (try ensureKey(a, layout, &index, "local/scratch", null, "r1", &.{ "r0", "r1" })).root.?);
}

test "facts: one file per machine, read back sorted, and a misfiled or foreign file is bad" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    const key = "github.com/acme/widget";

    try writeFact(a, layout, key, "bbbbbbbbbbbbbbbb", ".clasp.json", .file, hex_b);
    try writeFact(a, layout, key, "aaaaaaaaaaaaaaaa", ".clasp.json", .file, hex_a);
    try writeFact(a, layout, key, "aaaaaaaaaaaaaaaa", ".superpowers", .dir, hex_a);
    const wrong_id = paths.id("other");
    _ = try f.write(try std.fmt.allocPrint(a, "kept/{s}/.holt-paths/{s}/aaaaaaaaaaaaaaaa", .{ key, &wrong_id }), "{\"rel\": \".clasp.json\", \"kind\": \"file\", \"sha256\": \"" ++ hex_a ++ "\"}");
    const good_id = paths.id(".clasp.json");
    _ = try f.write(try std.fmt.allocPrint(a, "kept/{s}/.holt-paths/{s}/conflicted copy", .{ key, &good_id }), "{}");

    var bad: std.ArrayList(Bad) = .empty;
    const facts = try readFacts(a, layout, key, &bad);
    try testing.expectEqual(@as(usize, 3), facts.len);
    try testing.expectEqualStrings(".clasp.json", facts[0].rel);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaa", facts[0].machine);
    try testing.expectEqualStrings("bbbbbbbbbbbbbbbb", facts[1].machine);
    try testing.expectEqual(Kind.dir, facts[2].kind);
    try testing.expectEqual(@as(usize, 2), bad.items.len);

    try removeFacts(a, layout, key, ".clasp.json");
    bad.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 1), (try readFacts(a, layout, key, &bad)).len);
}

test "replaceFacts: this machine's fact is the only one left, and the path always has one" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    const key = "github.com/acme/widget";
    try writeFact(a, layout, key, "aaaaaaaaaaaaaaaa", ".env", .file, hex_a);
    try writeFact(a, layout, key, "bbbbbbbbbbbbbbbb", ".env", .file, hex_b);
    try writeFact(a, layout, key, "bbbbbbbbbbbbbbbb", "other", .file, hex_b);

    try replaceFacts(a, layout, key, "cccccccccccccccc", ".env", .dir, hex_b);
    const st = try loadKeyState(a, layout, key);
    const got = st.factsFor(".env");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("cccccccccccccccc", got[0].machine);
    try testing.expectEqual(Kind.dir, got[0].kind);
    try testing.expectEqualStrings(hex_b, got[0].sha256);
    try testing.expectEqual(@as(usize, 1), st.factsFor("other").len);
}

test "keptSet: facts minus released paths" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    const key = "github.com/acme/widget";
    try writeFact(a, layout, key, "aaaaaaaaaaaaaaaa", "a", .file, hex_a);
    try writeFact(a, layout, key, "bbbbbbbbbbbbbbbb", "a", .file, hex_a);
    try writeFact(a, layout, key, "aaaaaaaaaaaaaaaa", "b", .file, hex_a);
    try writeReleased(a, layout, key, "b");
    try writeReleased(a, layout, key, "c");

    const st = try loadKeyState(a, layout, key);
    const set = try st.keptSet(a);
    try testing.expectEqual(@as(usize, 1), set.len);
    try testing.expectEqualStrings("a", set[0]);
    try testing.expectEqual(@as(usize, 2), st.factsFor("a").len);
    try testing.expectEqual(@as(usize, 3), (try st.namedPaths(a)).len);

    try removeReleased(a, layout, key, "b");
    try testing.expectEqual(@as(usize, 2), (try (try loadKeyState(a, layout, key)).keptSet(a)).len);
}

test "loadIndex: finds nested keys, skips reserved directories and keyless ones" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    _ = try f.write("kept/gitlab.com/g/app/.holt-kept.json", "{\"version\": 1}");
    _ = try f.write("kept/gitlab.com/g/app/sub/.holt-kept.json", "{\"version\": 1}");
    _ = try f.write("kept/github.com/acme/widget/.holt-kept.json", "{\"version\": 1}");
    _ = try f.write("kept/.holt-aside/x/data/a/.holt-kept.json", "{\"version\": 1}");
    _ = try f.write("kept/github.com/nobody/file", "x");

    const index = try loadIndex(a, layout);
    try testing.expectEqual(@as(usize, 3), index.keys.len);
    try testing.expectEqualStrings("github.com/acme/widget", index.keys[0]);
    try testing.expectEqualStrings("gitlab.com/g/app", index.keys[1]);
    try testing.expectEqualStrings("gitlab.com/g/app/sub", index.keys[2]);
}

test "loadIndex: a record inside a key's kept directory is content, not a key" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    _ = try f.write("kept/github.com/acme/widget/.holt-kept.json", "{\"version\": 1}");
    try writeFact(a, layout, "github.com/acme/widget", "aaaaaaaaaaaaaaaa", ".superpowers", .dir, hex_a);
    _ = try f.write("kept/github.com/acme/widget/.superpowers/sub/.holt-kept.json", "{\"version\": 1}");
    _ = try f.write("kept/github.com/acme/widget/nested/.holt-kept.json", "{\"version\": 1}");

    const index = try loadIndex(a, layout);
    try testing.expectEqual(@as(usize, 2), index.keys.len);
    try testing.expectEqualStrings("github.com/acme/widget", index.keys[0]);
    try testing.expectEqualStrings("github.com/acme/widget/nested", index.keys[1]);
}

test "nestedKeyAt: a path at, inside, or above a nested key" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    _ = try f.write("kept/gitlab.com/g/app/.holt-kept.json", "{\"version\": 1}");
    _ = try f.write("kept/gitlab.com/g/app/Sub/Inner/.holt-kept.json", "{\"version\": 1}");
    const index = try loadIndex(a, layout);
    const key = "gitlab.com/g/app";
    try testing.expect(!(try nestedKeyAt(a, &index, key, "sub/inner")).?.contains);
    try testing.expect(!(try nestedKeyAt(a, &index, key, "sub/inner/x")).?.contains);
    const above = (try nestedKeyAt(a, &index, key, "sub")).?;
    try testing.expect(above.contains);
    try testing.expectEqualStrings("gitlab.com/g/app/Sub/Inner", above.key);
    try testing.expect((try nestedKeyAt(a, &index, key, "subway")) == null);
    try testing.expect((try nestedKeyAt(a, &index, key, "other")) == null);
}

test "resolve: follows successors the clone matches, never resolves a local key" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    _ = try f.write("kept/github.com/new/widget/.holt-kept.json", "{\"version\": 1, \"root\": \"r1\"}");
    _ = try f.write("kept/github.com/newer/widget/.holt-kept.json", "{\"version\": 1, \"root\": \"r1\"}");
    _ = try f.write("kept/github.com/fork/widget/.holt-kept.json", "{\"version\": 1, \"root\": \"other\"}");
    try writeFrom(a, layout, "github.com/new/widget", "github.com/old/widget");
    try writeFrom(a, layout, "github.com/newer/widget", "github.com/old/widget");
    try writeFrom(a, layout, "github.com/newer/widget", "github.com/new/widget");
    try writeFrom(a, layout, "github.com/fork/widget", "github.com/old/widget");
    try writeFrom(a, layout, "github.com/new/widget", "local/widget");
    const index = try loadIndex(a, layout);

    const r = try resolve(a, layout, &index, "github.com/old/widget", &.{ "r0", "r1" });
    try testing.expectEqualStrings("github.com/newer/widget", r.successor);
    try testing.expectEqual(Resolution.own, try resolve(a, layout, &index, "github.com/old/widget", &.{"unrelated"}));
    try testing.expectEqualStrings("github.com/new/widget", (try resolve(a, layout, &index, "local/widget", &.{"r1"})).awaiting_promote);
    try testing.expectEqual(Resolution.own, try resolve(a, layout, &index, "local/other", &.{"r1"}));
}

test "unknownFiles: reports what no fact names, descends only toward named paths" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    const key = "github.com/acme/widget";
    _ = try f.write("kept/github.com/acme/widget/.holt-kept.json", "{\"version\": 1}");
    _ = try f.write("kept/github.com/acme/widget/.clasp.json", "{}");
    _ = try f.write("kept/github.com/acme/widget/.clasp (conflicted copy).json", "{}");
    _ = try f.write("kept/github.com/acme/widget/android/app/google-services.json", "{}");
    _ = try f.write("kept/github.com/acme/widget/android/app/stray", "x");
    _ = try f.write("kept/github.com/acme/widget/.superpowers/notes.md", "n");
    _ = try f.write("kept/github.com/acme/widget/nested/.holt-kept.json", "{\"version\": 1}");
    _ = try f.write("kept/github.com/acme/widget/other/deep/file", "x");

    const unknown = try unknownFiles(a, layout, key, &.{ ".clasp.json", ".superpowers", "android/app/google-services.json" });
    try testing.expectEqual(@as(usize, 3), unknown.len);
    try testing.expectEqualStrings(".clasp (conflicted copy).json", unknown[0]);
    try testing.expectEqualStrings("android/app/stray", unknown[1]);
    try testing.expectEqualStrings("other", unknown[2]);
}

test "unknownFiles: what folders gather on their own, a directory holding only that, and iCloud's stand-ins for reserved names are never unknown" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = f.root };
    const key = "github.com/acme/widget";
    _ = try f.write("kept/github.com/acme/widget/.holt-kept.json", "{\"version\": 1}");
    _ = try f.write("kept/github.com/acme/widget/.clasp.json", "{}");
    for ([_][]const u8{ ".DS_Store", "Icon\r", "desktop.ini", "Thumbs.db", ".directory", "@eaDir/x", ".Trash-1000/y", "android/.DS_Store", "..holt-paths.icloud" }) |n| {
        // Windows cannot name a file with a control character.
        if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, n, '\r') != null) continue;
        _ = try f.write(try std.fs.path.join(a, &.{ "kept/github.com/acme/widget", n }), "x");
    }
    _ = try f.write("kept/github.com/acme/widget/@kept/notes", "n");
    _ = try f.write("kept/github.com/acme/widget/.DS_Store.bak", "x");

    const unknown = try unknownFiles(a, layout, key, &.{ ".clasp.json", "@kept/notes" });
    try testing.expectEqual(@as(usize, 1), unknown.len);
    try testing.expectEqualStrings(".DS_Store.bak", unknown[0]);
    try testing.expectEqualStrings(".holt-paths", reservedStandIn("..holt-paths.icloud").?);
    try testing.expect(reservedStandIn(".notes.icloud") == null);
}
