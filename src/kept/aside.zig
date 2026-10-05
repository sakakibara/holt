//! Aside entries: verified copies of content holt is about to act on, kept
//! in `kept/.holt-aside/<stamp>/` with a manifest of every file's hash, and
//! the per-clone `aside-done` record that lets repeated reconciles reuse an
//! entry instead of copying the same content again.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("json");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const interrupt = @import("interrupt.zig");
const testing = std.testing;

const io = fsutil.io;
const Layout = store.Layout;

pub const Reason = enum {
    keep,
    replaced,
    local_differs,
    kept_missing,
    old_location,
    blocked,
    cannot_compare,
    /// A temporary an interrupted write left in a working tree.
    interrupted,
    /// Content at a path of a working tree reconcile could not evaluate.
    stopped,
    /// Content the block hides from git that no state set aside.
    hidden,
    /// The kept content of a released path, removed by `unkeep --purge`.
    purged,
    /// Content a deleter set aside before deleting the working tree
    /// holding it.
    deleting,
};

/// A verified aside entry and the hash of the content it holds. A partial
/// entry (`Coverage.partial`) holds only what could be copied, and
/// `skipped` names the rest; `links` records each symlink among them by
/// its target.
pub const Entry = struct { stamp: []const u8, hash: content.Hash, skipped: []const content.Skipped = &.{}, links: []const Link = &.{} };

/// A symlink an entry records by its target instead of copying: its path,
/// `/`-joined as in `Manifest.files`, and the target as the link spells it.
pub const Link = struct { path: []const u8, target: []const u8 };

/// How much of a directory an entry must hold.
pub const Coverage = union(enum) {
    /// Every entry, or the aside fails: for content holt then acts on.
    whole,
    /// Every regular file that can be copied; what cannot be
    /// (`content.treeFilesPartial`, under the `core.ignorecase` of the
    /// working tree the content is in) is named in the manifest instead.
    /// For content holt only reports.
    partial: struct { ignore_case: bool },
};

/// The permission bits of one file of an entry, `/`-joined as in `files`.
pub const FileMode = struct { path: []const u8, mode: u32 };

pub const Manifest = struct {
    key: []const u8,
    rel: []const u8,
    reason: []const u8,
    /// Paths under the entry's `data/`, `/`-joined, with their hashes.
    files: []const content.FileHash,
    /// Each file's permission bits, recorded where the machine that made
    /// the entry has executable bits; null otherwise.
    modes: ?[]const FileMode = null,
    /// For a partial entry, what was left out, `/`-joined like `files`.
    skipped: []const content.Skipped = &.{},
    /// The symlinks among what was left out, or the one symlink an entry
    /// made by `recordLink` holds instead of data, by their targets.
    links: []const Link = &.{},
    /// The version of `rel` git's index staged, which an entry made by
    /// `setAsideStaged` holds under its `index/` instead of `data/`, with
    /// its hash.
    index: []const content.FileHash = &.{},

    /// The kind and content hash of `rel` as the manifest records it; for
    /// an entry holding only the link at `rel`, the hash of its target.
    pub fn hash(self: Manifest, alloc: std.mem.Allocator) !content.Hash {
        if (self.files.len == 0 and self.links.len == 1 and std.mem.eql(u8, self.links[0].path, self.rel)) {
            return .{ .kind = .file, .hex = linkHash(self.links[0].target) };
        }
        if (self.files.len == 1 and self.skipped.len == 0 and std.mem.eql(u8, self.files[0].path, self.rel)) {
            return .{ .kind = .file, .hex = self.files[0].hex };
        }
        var inner: std.ArrayList(content.FileHash) = .empty;
        for (self.files) |f| {
            if (f.path.len > self.rel.len and std.mem.startsWith(u8, f.path, self.rel) and f.path[self.rel.len] == '/') {
                try inner.append(alloc, .{ .path = f.path[self.rel.len + 1 ..], .hex = f.hex });
            } else return error.MalformedManifest;
        }
        return .{ .kind = .dir, .hex = content.treeHash(inner.items) };
    }
};

fn linkHash(target: []const u8) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("symlink\x00");
    h.update(target);
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// UTC time to the millisecond, the machine, and a random suffix.
pub fn newStamp(alloc: std.mem.Allocator, machine_id: []const u8) ![]u8 {
    const ns = std.Io.Clock.real.now(io()).nanoseconds;
    const ms: u64 = @intCast(@divFloor(ns, std.time.ns_per_ms));
    const secs = std.time.epoch.EpochSeconds{ .secs = ms / 1000 };
    const day = secs.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = secs.getDaySeconds();
    var rand: [4]u8 = undefined;
    io().random(&rand);
    return std.fmt.allocPrint(alloc, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}.{d:0>3}Z-{s}-{s}", .{
        day.year,             md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        ms % 1000,            machine_id,              &std.fmt.bytesToHex(rand, .lower),
    });
}

fn entryDir(alloc: std.mem.Allocator, layout: Layout, stamp: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ try layout.asideDir(alloc), stamp });
}

/// Where an entry holds `rel`.
pub fn dataPath(alloc: std.mem.Allocator, layout: Layout, stamp: []const u8, rel: []const u8) ![]u8 {
    return fsutil.joinSlashy(alloc, try std.fs.path.join(alloc, &.{ try entryDir(alloc, layout, stamp), "data" }), rel);
}

/// What an entry for `rel` made from `source` records.
const Source = struct {
    hash: content.Hash,
    files: []const content.FileHash,
    modes: ?[]const FileMode,
    skipped: []const content.Skipped,
    links: []const Link = &.{},
};

/// The hashes, and where the platform has executable bits the modes, of
/// the content at `source`, as manifest entries for `rel`; for a directory
/// taken `partial`ly, only what can be copied, with the rest in `skipped`.
fn sourceFiles(alloc: std.mem.Allocator, source: []const u8, rel: []const u8, how: Coverage) !Source {
    var src: Source = switch (try content.entryAt(source)) {
        .file => blk: {
            const hex = try content.hashFile(alloc, source);
            const files = try alloc.alloc(content.FileHash, 1);
            files[0] = .{ .path = rel, .hex = hex };
            break :blk .{ .hash = .{ .kind = .file, .hex = hex }, .files = files, .modes = null, .skipped = &.{} };
        },
        .dir => blk: {
            var skipped: []const content.Skipped = &.{};
            var links: std.ArrayList(Link) = .empty;
            const inner: []const content.FileHash = switch (how) {
                .whole => try content.treeFiles(alloc, source),
                .partial => |how_partial| got: {
                    const p = try content.treeFilesPartial(alloc, source, windowsNames(), how_partial.ignore_case);
                    skipped = try prefixSkipped(alloc, rel, p.skipped);
                    for (skipped) |sk| {
                        if (sk.why != .symlink) continue;
                        const target = (try content.readLink(alloc, try sourcePath(alloc, source, rel, sk.path))) orelse continue;
                        try links.append(alloc, .{ .path = sk.path, .target = target });
                    }
                    break :got p.files;
                },
            };
            const files = try alloc.alloc(content.FileHash, inner.len);
            for (inner, 0..) |f, i| files[i] = .{ .path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel, f.path }), .hex = f.hex };
            break :blk .{ .hash = .{ .kind = .dir, .hex = content.treeHash(inner) }, .files = files, .modes = null, .skipped = skipped, .links = links.items };
        },
        .absent => return error.FileNotFound,
        .symlink, .other => return error.NotRegular,
    };
    if (std.Io.File.Permissions.has_executable_bit) {
        const modes = try alloc.alloc(FileMode, src.files.len);
        for (src.files, modes) |f, *m| m.* = .{ .path = f.path, .mode = try content.modeOf(try sourcePath(alloc, source, rel, f.path)) };
        src.modes = modes;
    }
    return src;
}

fn prefixSkipped(alloc: std.mem.Allocator, rel: []const u8, skipped: []const content.Skipped) ![]const content.Skipped {
    const out = try alloc.alloc(content.Skipped, skipped.len);
    for (skipped, out) |sk, *o| o.* = .{ .path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ rel, sk.path }), .why = sk.why };
    return out;
}

/// Where the file a manifest names as `path` (`rel` or below it) is under
/// the content at `root`, which is `rel`.
fn sourcePath(alloc: std.mem.Allocator, root: []const u8, rel: []const u8, path: []const u8) ![]const u8 {
    if (path.len == rel.len) return root;
    return fsutil.joinSlashy(alloc, root, path[rel.len + 1 ..]);
}

/// Creates the entry directory under a fresh stamp, exclusively.
fn createEntry(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8) ![]u8 {
    try fsutil.ensureDir(try layout.asideDir(alloc));
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const stamp = try newStamp(alloc, machine_id);
        std.Io.Dir.cwd().createDir(io(), try entryDir(alloc, layout, stamp), .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => if (tries < 8) continue else return err,
            else => return err,
        };
        return stamp;
    }
}

fn writeManifest(alloc: std.mem.Allocator, layout: Layout, stamp: []const u8, m: Manifest) !void {
    var files: json.ObjectMap = .empty;
    for (m.files) |f| try files.put(alloc, f.path, .{ .string = try alloc.dupe(u8, &f.hex) });
    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "files", .{ .object = files });
    try obj.put(alloc, "key", .{ .string = m.key });
    if (m.modes) |modes| {
        var mo: json.ObjectMap = .empty;
        for (modes) |md| try mo.put(alloc, md.path, .{ .string = try std.fmt.allocPrint(alloc, "{o:0>3}", .{md.mode}) });
        try obj.put(alloc, "modes", .{ .object = mo });
    }
    try obj.put(alloc, "reason", .{ .string = m.reason });
    try obj.put(alloc, "rel", .{ .string = m.rel });
    if (m.skipped.len > 0) {
        var sk: json.ObjectMap = .empty;
        for (m.skipped) |x| try sk.put(alloc, x.path, .{ .string = @tagName(x.why) });
        try obj.put(alloc, "skipped", .{ .object = sk });
    }
    if (m.links.len > 0) {
        var lk: json.ObjectMap = .empty;
        for (m.links) |x| try lk.put(alloc, x.path, .{ .string = x.target });
        try obj.put(alloc, "links", .{ .object = lk });
    }
    if (m.index.len > 0) {
        var ix: json.ObjectMap = .empty;
        for (m.index) |f| try ix.put(alloc, f.path, .{ .string = try alloc.dupe(u8, &f.hex) });
        try obj.put(alloc, "index", .{ .object = ix });
    }
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try json.encode(&aw.writer, .{ .object = obj }, .{ .indent = 2, .sort_keys = true });
    try aw.writer.writeByte('\n');
    try fsutil.writeFileAtomic(alloc, try std.fs.path.join(alloc, &.{ try entryDir(alloc, layout, stamp), "manifest" }), aw.written());
}

/// Copies the content at `source` into a new entry for `rel` of `key`,
/// writes its manifest, and verifies every copied file against it. On any
/// failure the partial entry is removed and the error returned; `source` is
/// never touched. The entry holds all of `source` or the aside fails.
pub fn setAside(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: []const u8, rel: []const u8, source: []const u8, reason: Reason) !Entry {
    return create(alloc, layout, machine_id, key, rel, source, reason, try sourceFiles(alloc, source, rel, .whole));
}

fn create(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: []const u8, rel: []const u8, source: []const u8, reason: Reason, src: Source) !Entry {
    const stamp = try createEntry(alloc, layout, machine_id);
    const edir = try entryDir(alloc, layout, stamp);
    errdefer |err| if (err != error.Interrupted) std.Io.Dir.cwd().deleteTree(io(), edir) catch {};

    const dest = try dataPath(alloc, layout, stamp, rel);
    try fsutil.ensureDir(std.fs.path.dirname(dest).?);
    if (src.skipped.len == 0) {
        try content.copyRegular(alloc, source, dest);
    } else {
        const cwd = std.Io.Dir.cwd();
        try fsutil.ensureDir(dest);
        for (src.files) |f| {
            const to = try fsutil.joinSlashy(alloc, dest, f.path[rel.len + 1 ..]);
            try fsutil.ensureDir(std.fs.path.dirname(to).?);
            try cwd.copyFile(try sourcePath(alloc, source, rel, f.path), cwd, to, io(), .{});
        }
    }
    try interrupt.check(.aside_copied);
    try writeManifest(alloc, layout, stamp, .{ .key = key, .rel = rel, .reason = @tagName(reason), .files = src.files, .modes = src.modes, .skipped = src.skipped, .links = src.links });
    try interrupt.check(.aside_manifest);
    switch (try verify(alloc, layout, stamp)) {
        .ok => {},
        else => return error.AsideVerifyFailed,
    }
    return .{ .stamp = stamp, .hash = src.hash, .skipped = src.skipped, .links = src.links };
}

/// A new entry for `rel` of `key` holding, as `index/<rel>`, the file at
/// `staged`: the version of `rel` git's index stages where neither the
/// working tree nor HEAD holds it. Its manifest names no data (`index`).
pub fn setAsideStaged(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: []const u8, rel: []const u8, staged: []const u8, reason: Reason) !Entry {
    const hex = try content.hashFile(alloc, staged);
    const stamp = try createEntry(alloc, layout, machine_id);
    const edir = try entryDir(alloc, layout, stamp);
    errdefer |err| if (err != error.Interrupted) std.Io.Dir.cwd().deleteTree(io(), edir) catch {};
    const dest = try fsutil.joinSlashy(alloc, try std.fs.path.join(alloc, &.{ edir, "index" }), rel);
    try fsutil.ensureDir(std.fs.path.dirname(dest).?);
    try content.copyRegular(alloc, staged, dest);
    const index = try alloc.dupe(content.FileHash, &.{.{ .path = rel, .hex = hex }});
    try writeManifest(alloc, layout, stamp, .{ .key = key, .rel = rel, .reason = @tagName(reason), .files = &.{}, .index = index });
    switch (try verify(alloc, layout, stamp)) {
        .ok => {},
        else => return error.AsideVerifyFailed,
    }
    return .{ .stamp = stamp, .hash = .{ .kind = .file, .hex = hex } };
}

/// A new entry for `rel` of `key` recording the symlink at `source` by its
/// target (`Manifest.links`) and holding no data, since a link's target is
/// all there is to keep of it. `NotALink` when `source` is not a symlink.
pub fn recordLink(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: []const u8, rel: []const u8, source: []const u8, reason: Reason) !Entry {
    const target = (try content.readLink(alloc, source)) orelse return error.NotALink;
    const stamp = try createEntry(alloc, layout, machine_id);
    const edir = try entryDir(alloc, layout, stamp);
    errdefer std.Io.Dir.cwd().deleteTree(io(), edir) catch {};
    const links = try alloc.dupe(Link, &.{.{ .path = rel, .target = target }});
    try writeManifest(alloc, layout, stamp, .{ .key = key, .rel = rel, .reason = @tagName(reason), .files = &.{}, .links = links });
    switch (try verify(alloc, layout, stamp)) {
        .ok => {},
        else => return error.AsideVerifyFailed,
    }
    return .{ .stamp = stamp, .hash = .{ .kind = .file, .hex = linkHash(target) }, .links = links };
}

/// Moves the content at `source` into a new entry for `rel` of `key`
/// instead of copying it. The manifest is written first, so the entry never
/// holds content it does not describe; if the move fails, the entry is
/// removed. `source` must be on the kept store's filesystem. A failed
/// verification after the move leaves the content in the entry.
pub fn moveAside(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: []const u8, rel: []const u8, source: []const u8, reason: Reason) !Entry {
    const src = try sourceFiles(alloc, source, rel, .whole);
    const stamp = try createEntry(alloc, layout, machine_id);
    const edir = try entryDir(alloc, layout, stamp);
    const dest = try dataPath(alloc, layout, stamp, rel);
    {
        errdefer |err| if (err != error.Interrupted) std.Io.Dir.cwd().deleteTree(io(), edir) catch {};
        try writeManifest(alloc, layout, stamp, .{ .key = key, .rel = rel, .reason = @tagName(reason), .files = src.files, .modes = src.modes });
        try interrupt.check(.move_manifest);
        try fsutil.ensureDir(std.fs.path.dirname(dest).?);
        try content.renameNoReplace(alloc, source, dest);
    }
    switch (try verify(alloc, layout, stamp)) {
        .ok => {},
        else => return error.AsideVerifyFailed,
    }
    return .{ .stamp = stamp, .hash = src.hash };
}

/// The manifest of `stamp`, or null when the entry or its manifest is gone
/// or unreadable, or names a path that would leave the entry
/// (`paths.contained`) or a file outside its `rel`. Any other name, and any
/// key, is accepted, so content under names a kept path may not have can
/// still be set aside; placing it back takes `unplaceable` first.
pub fn readManifest(alloc: std.mem.Allocator, layout: Layout, stamp: []const u8) !?Manifest {
    const bytes = content.readSmall(alloc, try std.fs.path.join(alloc, &.{ try entryDir(alloc, layout, stamp), "manifest" })) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    const v = json.parse(alloc, bytes, .{}) catch return null;
    if (v != .object) return null;
    const obj = v.object;
    const key = obj.get("key") orelse return null;
    const rel = obj.get("rel") orelse return null;
    const reason = obj.get("reason") orelse return null;
    const files_v = obj.get("files") orelse return null;
    if (key != .string or rel != .string or reason != .string or files_v != .object) return null;
    if (!paths.contained(rel.string)) return null;
    var files: std.ArrayList(content.FileHash) = .empty;
    var it = files_v.object.iterator();
    while (it.next()) |kv| {
        const p = kv.key_ptr.*;
        const inside = std.mem.eql(u8, p, rel.string) or (p.len > rel.string.len and std.mem.startsWith(u8, p, rel.string) and p[rel.string.len] == '/');
        if (!inside or !paths.contained(p)) return null;
        if (kv.value_ptr.* != .string or kv.value_ptr.string.len != 64) return null;
        var hex: [64]u8 = undefined;
        @memcpy(&hex, kv.value_ptr.string);
        try files.append(alloc, .{ .path = kv.key_ptr.*, .hex = hex });
    }
    var m: Manifest = .{ .key = key.string, .rel = rel.string, .reason = reason.string, .files = files.items };
    if (obj.get("modes")) |modes_v| {
        if (modes_v != .object) return null;
        var modes: std.ArrayList(FileMode) = .empty;
        var mit = modes_v.object.iterator();
        while (mit.next()) |kv| {
            const known = for (files.items) |f| {
                if (std.mem.eql(u8, f.path, kv.key_ptr.*)) break true;
            } else false;
            if (!known or kv.value_ptr.* != .string) return null;
            const mode = std.fmt.parseInt(u32, kv.value_ptr.string, 8) catch return null;
            if (mode > 0o777) return null;
            try modes.append(alloc, .{ .path = kv.key_ptr.*, .mode = mode });
        }
        if (modes.items.len != files.items.len) return null;
        m.modes = modes.items;
    }
    if (obj.get("skipped")) |skipped_v| {
        if (skipped_v != .object) return null;
        var skipped: std.ArrayList(content.Skipped) = .empty;
        var sit = skipped_v.object.iterator();
        while (sit.next()) |kv| {
            const p = kv.key_ptr.*;
            if (!(p.len > rel.string.len and std.mem.startsWith(u8, p, rel.string) and p[rel.string.len] == '/') or !paths.contained(p)) return null;
            if (kv.value_ptr.* != .string) return null;
            const why = std.meta.stringToEnum(content.Skip, kv.value_ptr.string) orelse return null;
            try skipped.append(alloc, .{ .path = p, .why = why });
        }
        std.mem.sort(content.Skipped, skipped.items, {}, skippedLess);
        m.skipped = skipped.items;
    }
    if (obj.get("links")) |links_v| {
        if (links_v != .object) return null;
        var links: std.ArrayList(Link) = .empty;
        var lit = links_v.object.iterator();
        while (lit.next()) |kv| {
            const p = kv.key_ptr.*;
            const inside = std.mem.eql(u8, p, rel.string) or (p.len > rel.string.len and std.mem.startsWith(u8, p, rel.string) and p[rel.string.len] == '/');
            if (!inside or !paths.contained(p)) return null;
            if (kv.value_ptr.* != .string or kv.value_ptr.string.len == 0) return null;
            try links.append(alloc, .{ .path = p, .target = kv.value_ptr.string });
        }
        std.mem.sort(Link, links.items, {}, linkLess);
        m.links = links.items;
    }
    if (obj.get("index")) |index_v| {
        if (index_v != .object) return null;
        var index: std.ArrayList(content.FileHash) = .empty;
        var iit = index_v.object.iterator();
        while (iit.next()) |kv| {
            if (!std.mem.eql(u8, kv.key_ptr.*, rel.string)) return null;
            if (kv.value_ptr.* != .string or kv.value_ptr.string.len != 64) return null;
            var hex: [64]u8 = undefined;
            @memcpy(&hex, kv.value_ptr.string);
            try index.append(alloc, .{ .path = kv.key_ptr.*, .hex = hex });
        }
        m.index = index.items;
    }
    return m;
}

fn linkLess(_: void, x: Link, y: Link) bool {
    return std.mem.order(u8, x.path, y.path) == .lt;
}

fn skippedLess(_: void, x: content.Skipped, y: content.Skipped) bool {
    return std.mem.order(u8, x.path, y.path) == .lt;
}

/// Why an entry could not be placed back into a kept store or a working
/// tree (`unplaceable`).
pub const Unplaceable = enum {
    /// The manifest's key is not a valid key (`store.validKey`).
    key,
    /// Its rel, or a file's path, is not a valid kept path (`paths.check`).
    path,
    /// On Windows, a component names a device or a stream
    /// (`paths.windowsUnsafe`).
    windows_name,
};

/// Test seam: Windows' name rules apply on every platform.
pub var windows_names_for_test = false;

fn windowsNames() bool {
    return builtin.os.tag == .windows or (builtin.is_test and windows_names_for_test);
}

fn windowsUnsafeManifest(m: Manifest) bool {
    if (paths.windowsUnsafe(m.rel)) return true;
    for (m.files) |f| if (paths.windowsUnsafe(f.path)) return true;
    return false;
}

/// Why `m`'s content may not be placed back into a kept store or a working
/// tree, or null when it may. Aside accepts any name that stays inside its
/// entry, so every caller placing aside content back checks this first.
pub fn unplaceable(m: Manifest) ?Unplaceable {
    if (!store.validKey(m.key)) return .key;
    if (paths.check(m.rel) != null) return .path;
    for (m.files) |f| if (paths.check(f.path) != null) return .path;
    if (windowsNames() and windowsUnsafeManifest(m)) return .windows_name;
    return null;
}

/// Whether every file the manifest `m` of `stamp` records, under its
/// `data/` and its `index/`, is here as a regular file, none read: what
/// `verify` checks, but for their content. False on Windows for a manifest
/// `verify` would not open.
pub fn present(alloc: std.mem.Allocator, layout: Layout, stamp: []const u8, m: Manifest) !bool {
    if (windowsNames() and windowsUnsafeManifest(m)) return false;
    const dir = try entryDir(alloc, layout, stamp);
    const Side = struct { sub: []const u8, files: []const content.FileHash };
    for ([_]Side{ .{ .sub = "index", .files = m.index }, .{ .sub = "data", .files = m.files } }) |side| {
        const root = try std.fs.path.join(alloc, &.{ dir, side.sub });
        for (side.files) |f| {
            if (try content.entryAt(try fsutil.joinSlashy(alloc, root, f.path)) != .file) return false;
        }
    }
    return true;
}

pub const Check = enum {
    ok,
    missing,
    mismatch,
    online_only,
    /// On Windows, the manifest names a device or a stream
    /// (`paths.windowsUnsafe`), so its data is never opened to check.
    unverifiable,
};

/// Whether the data of `stamp`, and the index version it holds, still
/// match its manifest file for file. Online-only data is not downloaded to
/// check.
pub fn verify(alloc: std.mem.Allocator, layout: Layout, stamp: []const u8) !Check {
    const m = (try readManifest(alloc, layout, stamp)) orelse return .missing;
    if (windowsNames() and windowsUnsafeManifest(m)) return .unverifiable;
    for (m.index) |f| {
        const at = try fsutil.joinSlashy(alloc, try std.fs.path.join(alloc, &.{ try entryDir(alloc, layout, stamp), "index" }), f.path);
        if (try content.entryAt(at) != .file) return if (fsutil.hasIcloudPlaceholder(alloc, at)) .online_only else .missing;
        const hex = content.hashFile(alloc, at) catch |err| switch (err) {
            error.OnlineOnly => return .online_only,
            else => return err,
        };
        if (!std.mem.eql(u8, &hex, &f.hex)) return .mismatch;
    }
    const data = try std.fs.path.join(alloc, &.{ try entryDir(alloc, layout, stamp), "data" });
    const want = try alloc.dupe(content.FileHash, m.files);
    std.mem.sort(content.FileHash, want, {}, content.fileLess);
    const rel_root = try fsutil.joinSlashy(alloc, data, m.rel);
    const got: []const content.FileHash = switch (try content.entryAt(rel_root)) {
        .file => blk: {
            const hex = content.hashFile(alloc, rel_root) catch |err| switch (err) {
                error.OnlineOnly => return .online_only,
                else => return err,
            };
            const one = try alloc.alloc(content.FileHash, 1);
            one[0] = .{ .path = m.rel, .hex = hex };
            break :blk one;
        },
        .dir => blk: {
            const inner = content.treeFiles(alloc, rel_root) catch |err| switch (err) {
                error.OnlineOnly => return .online_only,
                error.NotRegular => return .mismatch,
                else => return err,
            };
            const prefixed = try alloc.alloc(content.FileHash, inner.len);
            for (inner, 0..) |f, i| prefixed[i] = .{ .path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ m.rel, f.path }), .hex = f.hex };
            break :blk prefixed;
        },
        .absent => {
            if (m.files.len == 0 and (m.links.len > 0 or m.index.len > 0)) return .ok;
            return if (fsutil.hasIcloudPlaceholder(alloc, rel_root)) .online_only else .missing;
        },
        .symlink, .other => return .mismatch,
    };
    if (got.len != want.len) return .mismatch;
    for (got, want) |g, w| {
        if (!std.mem.eql(u8, g.path, w.path) or !std.mem.eql(u8, &g.hex, &w.hex)) return .mismatch;
    }
    if (std.Io.File.Permissions.has_executable_bit) if (m.modes) |modes| {
        for (modes) |md| {
            const now = try content.modeOf(try fsutil.joinSlashy(alloc, data, md.path));
            if (now & 0o111 != md.mode & 0o111) return .mismatch;
        }
    };
    return .ok;
}

/// Whether the executable bits `a` and `b` record for each file agree; two
/// records where either has none agree only when both have none.
fn sameExecutable(a: ?[]const FileMode, b: ?[]const FileMode) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x.len != y.len) return false;
    for (x) |mx| {
        const my = for (y) |c| {
            if (std.mem.eql(u8, c.path, mx.path)) break c;
        } else return false;
        if (mx.mode & 0o111 != my.mode & 0o111) return false;
    }
    return true;
}

fn sameLinks(a: []const Link, b: []const Link) bool {
    if (a.len != b.len) return false;
    for (a) |x| {
        for (b) |y| {
            if (std.mem.eql(u8, x.path, y.path) and std.mem.eql(u8, x.target, y.target)) break;
        } else return false;
    }
    return true;
}

fn sameSkipped(a: []const content.Skipped, b: []const content.Skipped) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.why != y.why or !std.mem.eql(u8, x.path, y.path)) return false;
    }
    return true;
}

/// Stamps of every entry, in no order; none when `kept/.holt-aside/` is
/// not there.
pub fn stamps(alloc: std.mem.Allocator, layout: Layout) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = std.Io.Dir.cwd().openDir(io(), try layout.asideDir(alloc), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.items,
        else => return err,
    };
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        if (e.kind == .directory) try out.append(alloc, try alloc.dupe(u8, e.name));
    }
    return out.items;
}

/// Stamps of the entries holding `rel` of `key` with content hash `hex`,
/// or with any content when `hex` is null, sorted; an entry holding a
/// staged version (`setAsideStaged`) holds no content of `rel` and is never
/// one.
pub fn findEntries(alloc: std.mem.Allocator, layout: Layout, key: []const u8, rel: []const u8, hex: ?[]const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = std.Io.Dir.cwd().openDir(io(), try layout.asideDir(alloc), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.items,
        else => return err,
    };
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        if (e.kind != .directory) continue;
        const m = (try readManifest(alloc, layout, e.name)) orelse continue;
        if (!std.mem.eql(u8, m.key, key) or !std.mem.eql(u8, m.rel, rel)) continue;
        if (m.index.len > 0) continue;
        if (hex) |want| {
            const h = m.hash(alloc) catch continue;
            if (!std.mem.eql(u8, &h.hex, want)) continue;
        }
        try out.append(alloc, try alloc.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, out.items, {}, paths.lessThan);
    return out.items;
}

const taken_basename = "took-kept";

/// Records, in the entry `stamp`, that `--take-kept` set the local content
/// it holds aside at `now_ms` (milliseconds since the epoch), so pruning
/// spares it for a while (`takenMs`).
pub fn markTaken(alloc: std.mem.Allocator, layout: Layout, stamp: []const u8, now_ms: i64) !void {
    const text = try std.fmt.allocPrint(alloc, "{d}\n", .{now_ms});
    try fsutil.writeFileAtomic(alloc, try std.fs.path.join(alloc, &.{ try entryDir(alloc, layout, stamp), taken_basename }), text);
}

/// When `--take-kept` last set content aside into the entry `stamp`
/// (`markTaken`), or null when it never did.
pub fn takenMs(alloc: std.mem.Allocator, layout: Layout, stamp: []const u8) !?i64 {
    const bytes = content.readSmall(alloc, try std.fs.path.join(alloc, &.{ try entryDir(alloc, layout, stamp), taken_basename })) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return std.fmt.parseInt(i64, std.mem.trim(u8, bytes, " \t\r\n"), 10) catch null;
}

/// One `aside-done` line: content with hash `sha256` at `rel` was set
/// aside as `stamp` under `synced_root`.
pub const Done = struct { rel: []const u8, sha256: []const u8, synced_root: []const u8, stamp: []const u8 };

fn donePath(alloc: std.mem.Allocator, common_dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ common_dir, "holt", "aside-done" });
}

pub fn readDone(alloc: std.mem.Allocator, common_dir: []const u8) ![]const Done {
    var out: std.ArrayList(Done) = .empty;
    const bytes = content.readSmall(alloc, try donePath(alloc, common_dir)) catch |err| switch (err) {
        error.FileNotFound => return out.items,
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = json.parse(alloc, line, .{}) catch continue;
        if (v != .object) continue;
        const fields = [_][]const u8{ "rel", "sha256", "synced_root", "stamp" };
        var vals: [4][]const u8 = undefined;
        for (fields, 0..) |f, i| {
            const fv = v.object.get(f) orelse break;
            if (fv != .string) break;
            vals[i] = fv.string;
        } else try out.append(alloc, .{ .rel = vals[0], .sha256 = vals[1], .synced_root = vals[2], .stamp = vals[3] });
    }
    return out.items;
}

fn appendDone(alloc: std.mem.Allocator, common_dir: []const u8, d: Done) !void {
    var buf: std.ArrayList(u8) = .empty;
    for (try readDone(alloc, common_dir)) |old| try appendDoneLine(alloc, &buf, old);
    try appendDoneLine(alloc, &buf, d);
    const path = try donePath(alloc, common_dir);
    try fsutil.ensureDir(std.fs.path.dirname(path).?);
    try fsutil.writeFileAtomic(alloc, path, buf.items);
}

fn appendDoneLine(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), d: Done) !void {
    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "rel", .{ .string = d.rel });
    try obj.put(alloc, "sha256", .{ .string = d.sha256 });
    try obj.put(alloc, "stamp", .{ .string = d.stamp });
    try obj.put(alloc, "synced_root", .{ .string = d.synced_root });
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try json.encode(&aw.writer, .{ .object = obj }, .{ .sort_keys = true });
    try buf.appendSlice(alloc, aw.written());
    try buf.append(alloc, '\n');
}

/// An aside entry holding the current content at `source`, as much of it
/// as `how` asks: one recorded in the clone's `aside-done` when its
/// manifest, under the current synced root, has the same hash, executable
/// bits, and left-out entries, and its data verifies against it (data held
/// online-only does not), otherwise a new one, recorded.
pub fn ensureAside(alloc: std.mem.Allocator, layout: Layout, common_dir: []const u8, machine_id: []const u8, key: []const u8, rel: []const u8, source: []const u8, reason: Reason, how: Coverage) !Entry {
    const src = try sourceFiles(alloc, source, rel, how);
    const h = src.hash;
    for (try readDone(alloc, common_dir)) |d| {
        if (!std.mem.eql(u8, d.rel, rel) or !std.mem.eql(u8, d.sha256, &h.hex) or !std.mem.eql(u8, d.synced_root, layout.synced_root)) continue;
        const m = (try readManifest(alloc, layout, d.stamp)) orelse continue;
        if (!std.mem.eql(u8, m.key, key) or !std.mem.eql(u8, m.rel, rel)) continue;
        const mh = m.hash(alloc) catch continue;
        if (mh.kind != h.kind or !std.mem.eql(u8, &mh.hex, &h.hex)) continue;
        if (!sameExecutable(m.modes, src.modes) or !sameSkipped(m.skipped, src.skipped) or !sameLinks(m.links, src.links)) continue;
        if (try verify(alloc, layout, d.stamp) == .ok) return .{ .stamp = d.stamp, .hash = h, .skipped = src.skipped, .links = src.links };
    }
    const e = try create(alloc, layout, machine_id, key, rel, source, reason, src);
    try appendDone(alloc, common_dir, .{ .rel = rel, .sha256 = &e.hash.hex, .synced_root = layout.synced_root, .stamp = e.stamp });
    return e;
}

const Fixture = @import("harness.zig").Fixture;

const mid = "0123456789abcdef";

test "newStamp: UTC to the millisecond, then the machine and a suffix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try newStamp(arena_state.allocator(), mid);
    try testing.expectEqual(@as(usize, "20260927T010203.456Z-".len + mid.len + 1 + 8), s.len);
    try testing.expectEqual(@as(u8, 'T'), s[8]);
    try testing.expectEqualStrings("Z-" ++ mid ++ "-", s[19 .. 21 + mid.len + 1]);
}

test "setAside: copies a file and a tree, and the manifest verifies" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };

    _ = try f.write("clone/.clasp.json", "{\"scriptId\": \"x\"}");
    _ = try f.write("clone/.superpowers/a.md", "a");
    _ = try f.write("clone/.superpowers/sub/b.md", "b");

    const fe = try setAside(a, layout, mid, "k/r", ".clasp.json", try f.path("clone/.clasp.json"), .keep);
    try testing.expectEqual(Check.ok, try verify(a, layout, fe.stamp));
    try testing.expectEqualStrings("{\"scriptId\": \"x\"}", try content.readSmall(a, try dataPath(a, layout, fe.stamp, ".clasp.json")));
    const m = (try readManifest(a, layout, fe.stamp)).?;
    try testing.expectEqualStrings(&fe.hash.hex, &(try m.hash(a)).hex);

    const de = try setAside(a, layout, mid, "k/r", ".superpowers", try f.path("clone/.superpowers"), .keep);
    try testing.expectEqual(content.Kind.dir, de.hash.kind);
    try testing.expectEqual(Check.ok, try verify(a, layout, de.stamp));
    const dm = (try readManifest(a, layout, de.stamp)).?;
    try testing.expectEqualStrings(&(try content.hashPath(a, try f.path("clone/.superpowers"))).hex, &(try dm.hash(a)).hex);

    try testing.expectEqual(@as(usize, 1), (try findEntries(a, layout, "k/r", ".clasp.json", &fe.hash.hex)).len);
    try testing.expectEqual(@as(usize, 0), (try findEntries(a, layout, "k/other", ".clasp.json", &fe.hash.hex)).len);

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try dataPath(a, layout, de.stamp, ".superpowers/a.md"), .data = "tampered" });
    try testing.expectEqual(Check.mismatch, try verify(a, layout, de.stamp));
}

test "readManifest: a path that escapes the entry, or a file outside rel, makes the manifest unreadable" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    const h = "a" ** 64;
    for ([_][]const u8{
        "{\"files\": {\"../x\": \"" ++ h ++ "\"}, \"key\": \"k/r\", \"reason\": \"keep\", \"rel\": \"../x\"}",
        "{\"files\": {\"d/../../y\": \"" ++ h ++ "\"}, \"key\": \"k/r\", \"reason\": \"keep\", \"rel\": \"d\"}",
        "{\"files\": {\"other\": \"" ++ h ++ "\"}, \"key\": \"k/r\", \"reason\": \"keep\", \"rel\": \"d\"}",
    }, 0..) |bytes, i| {
        const stamp = try std.fmt.allocPrint(a, "s{d}", .{i});
        _ = try f.write(try std.fmt.allocPrint(a, "synced/kept/.holt-aside/{s}/manifest", .{stamp}), bytes);
        try testing.expect((try readManifest(a, layout, stamp)) == null);
        try testing.expectEqual(Check.missing, try verify(a, layout, stamp));
    }
    _ = try f.write("synced/kept/.holt-aside/ok/manifest", "{\"files\": {\"d/x\": \"" ++ h ++ "\"}, \"key\": \"k/r\", \"reason\": \"keep\", \"rel\": \"d\"}");
    try testing.expect((try readManifest(a, layout, "ok")) != null);
}

test "setAside: names a kept path may not have are set aside and verify" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    _ = try f.write("clone/d/Icon\r", "icon");
    _ = try f.write("clone/d/a\\b", "backslash");
    _ = try f.write("clone/d/sub/.git/config", "nested");
    _ = try f.write("clone/d/.holt-x", "reserved");
    const e = try setAside(a, layout, mid, "k/r", "d", try f.path("clone/d"), .blocked);
    try testing.expectEqual(Check.ok, try verify(a, layout, e.stamp));
    try testing.expectEqual(@as(usize, 4), (try readManifest(a, layout, e.stamp)).?.files.len);
}

test "setAside: a tree holding a symlink fails and leaves no entry" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    _ = try f.write("clone/d/a", "a");
    try content.createLink("/elsewhere", try f.path("clone/d/l"), .file);
    try testing.expectError(error.NotRegular, setAside(a, layout, mid, "k/r", "d", try f.path("clone/d"), .keep));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.asideDir(a)));
}

test "a partial aside holds every file it can copy and names the rest; a whole one refuses" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    const common = try f.path("clone/.git");
    _ = try f.write("clone/d/a", "a");
    _ = try f.write("clone/d/sub/b", "b");
    _ = try f.write("clone/d/repo/.git/HEAD", "ref: refs/heads/main");
    _ = try f.write("clone/d/repo/tracked", "in a nested repository");
    _ = try f.write("clone/d/.x.icloud", "placeholder");
    try content.createLink("/elsewhere", try f.path("clone/d/link"), .file);
    const src = try f.path("clone/d");
    if (ensureAside(a, layout, common, mid, "k/r", "d", src, .blocked, .whole)) |_| return error.TestUnexpectedResult else |_| {}

    const e = try ensureAside(a, layout, common, mid, "k/r", "d", src, .blocked, .{ .partial = .{ .ignore_case = false } });
    try testing.expectEqual(Check.ok, try verify(a, layout, e.stamp));
    try testing.expectEqualStrings("b", try content.readSmall(a, try dataPath(a, layout, e.stamp, "d/sub/b")));
    const m = (try readManifest(a, layout, e.stamp)).?;
    try testing.expectEqual(@as(usize, 2), m.files.len);
    const want = [_]content.Skipped{
        .{ .path = "d/.x.icloud", .why = .online_only },
        .{ .path = "d/link", .why = .symlink },
        .{ .path = "d/repo", .why = .nested_repository },
    };
    try testing.expectEqual(want.len, m.skipped.len);
    for (want, m.skipped, e.skipped) |w, got, ret| {
        try testing.expectEqualStrings(w.path, got.path);
        try testing.expectEqual(w.why, got.why);
        try testing.expectEqualStrings(w.path, ret.path);
    }
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try dataPath(a, layout, e.stamp, "d/repo")));
    try testing.expectEqualStrings(e.stamp, (try ensureAside(a, layout, common, mid, "k/r", "d", src, .blocked, .{ .partial = .{ .ignore_case = false } })).stamp);

    const unreadable = try f.write("clone/d/secret", "secret");
    try std.Io.Dir.cwd().setFilePermissions(io(), unreadable, @enumFromInt(0o000), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io(), unreadable, @enumFromInt(0o644), .{}) catch {};
    if (std.Io.Dir.cwd().openFile(io(), unreadable, .{})) |file| {
        file.close(io());
        return;
    } else |_| {}
    const e2 = try ensureAside(a, layout, common, mid, "k/r", "d", src, .blocked, .{ .partial = .{ .ignore_case = false } });
    try testing.expect(!std.mem.eql(u8, e.stamp, e2.stamp));
    try testing.expectEqual(content.Skip.unreadable, (try readManifest(a, layout, e2.stamp)).?.skipped[3].why);
}

test "a partial aside records each symlink it leaves out by its target, and is reused only while the targets match" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    const common = try f.path("clone/.git");
    _ = try f.write("clone/d/a", "a");
    const link_path = try f.path("clone/d/sub/link");
    try fsutil.ensureDir(std.fs.path.dirname(link_path).?);
    try content.createLink("/nix/store/abc", link_path, .file);
    const src = try f.path("clone/d");

    const e = try ensureAside(a, layout, common, mid, "k/r", "d", src, .deleting, .{ .partial = .{ .ignore_case = false } });
    try testing.expectEqual(@as(usize, 1), e.links.len);
    const m = (try readManifest(a, layout, e.stamp)).?;
    try testing.expectEqual(@as(usize, 1), m.links.len);
    try testing.expectEqualStrings("d/sub/link", m.links[0].path);
    try testing.expectEqualStrings("/nix/store/abc", m.links[0].target);
    try testing.expectEqualStrings(e.stamp, (try ensureAside(a, layout, common, mid, "k/r", "d", src, .deleting, .{ .partial = .{ .ignore_case = false } })).stamp);

    try std.Io.Dir.cwd().deleteFile(io(), link_path);
    try content.createLink("/nix/store/def", link_path, .file);
    const e2 = try ensureAside(a, layout, common, mid, "k/r", "d", src, .deleting, .{ .partial = .{ .ignore_case = false } });
    try testing.expect(!std.mem.eql(u8, e.stamp, e2.stamp));
    try testing.expectEqualStrings("/nix/store/def", (try readManifest(a, layout, e2.stamp)).?.links[0].target);
}

test "recordLink: an entry holding only a link's target verifies, and refuses what is not a link" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    _ = try f.write("clone/file", "x");
    try content.createLink("../elsewhere", try f.path("clone/result"), .file);

    const e = try recordLink(a, layout, mid, "k/r", "result", try f.path("clone/result"), .deleting);
    try testing.expectEqual(Check.ok, try verify(a, layout, e.stamp));
    const m = (try readManifest(a, layout, e.stamp)).?;
    try testing.expectEqual(@as(usize, 0), m.files.len);
    try testing.expectEqualStrings("result", m.links[0].path);
    try testing.expectEqualStrings("../elsewhere", m.links[0].target);
    try testing.expectEqualStrings(&e.hash.hex, &(try m.hash(a)).hex);
    try testing.expectError(error.NotALink, recordLink(a, layout, mid, "k/r", "file", try f.path("clone/file"), .deleting));
}

test "an entry records each file's executable bits: verify checks them, and an entry is reused only while they match" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    const common = try f.path("clone/.git");
    const cwd = std.Io.Dir.cwd();
    const src = try f.write("clone/d/run.sh", "#!/bin/sh\n");
    _ = try f.write("clone/d/plain", "plain");
    try cwd.setFilePermissions(io(), src, @enumFromInt(0o755), .{});
    const dir = try f.path("clone/d");

    const e1 = try ensureAside(a, layout, common, mid, "k/r", "d", dir, .blocked, .{ .partial = .{ .ignore_case = false } });
    const m = (try readManifest(a, layout, e1.stamp)).?;
    for (m.modes.?) |md| try testing.expectEqual(@as(u32, if (std.mem.eql(u8, md.path, "d/run.sh")) 0o111 else 0), md.mode & 0o111);
    try testing.expectEqualStrings(e1.stamp, (try ensureAside(a, layout, common, mid, "k/r", "d", dir, .blocked, .{ .partial = .{ .ignore_case = false } })).stamp);

    try cwd.setFilePermissions(io(), src, @enumFromInt(0o644), .{});
    const e2 = try ensureAside(a, layout, common, mid, "k/r", "d", dir, .blocked, .{ .partial = .{ .ignore_case = false } });
    try testing.expect(!std.mem.eql(u8, e1.stamp, e2.stamp));
    try testing.expectEqual(Check.ok, try verify(a, layout, e2.stamp));

    try cwd.setFilePermissions(io(), try dataPath(a, layout, e1.stamp, "d/run.sh"), @enumFromInt(0o644), .{});
    try testing.expectEqual(Check.mismatch, try verify(a, layout, e1.stamp));
}

test "ensureAside: reuses a recorded entry, copies again once its data or the entry is gone, the content changes, or the synced root moves" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    const common = try f.path("clone/.git");
    _ = try f.write("clone/.env", "one");
    const src = try f.path("clone/.env");

    const e1 = try ensureAside(a, layout, common, mid, "k/r", ".env", src, .local_differs, .whole);
    const e2 = try ensureAside(a, layout, common, mid, "k/r", ".env", src, .local_differs, .whole);
    try testing.expectEqualStrings(e1.stamp, e2.stamp);

    try std.Io.Dir.cwd().deleteTree(io(), try std.fs.path.join(a, &.{ try layout.asideDir(a), e1.stamp, "data" }));
    const e2b = try ensureAside(a, layout, common, mid, "k/r", ".env", src, .local_differs, .whole);
    try testing.expect(!std.mem.eql(u8, e1.stamp, e2b.stamp));
    try testing.expectEqual(Check.ok, try verify(a, layout, e2b.stamp));

    try std.Io.Dir.cwd().deleteTree(io(), try std.fs.path.join(a, &.{ try layout.asideDir(a), e2b.stamp }));
    const e3 = try ensureAside(a, layout, common, mid, "k/r", ".env", src, .local_differs, .whole);
    try testing.expect(!std.mem.eql(u8, e2b.stamp, e3.stamp));
    try testing.expectEqual(Check.ok, try verify(a, layout, e3.stamp));

    _ = try f.write("clone/.env", "two");
    const e4 = try ensureAside(a, layout, common, mid, "k/r", ".env", src, .local_differs, .whole);
    try testing.expect(!std.mem.eql(u8, e3.stamp, e4.stamp));

    const moved: Layout = .{ .synced_root = try f.path("synced2") };
    const e5 = try ensureAside(a, moved, common, mid, "k/r", ".env", src, .local_differs, .whole);
    try testing.expectEqual(Check.ok, try verify(a, moved, e5.stamp));
    try testing.expectEqual(@as(usize, 5), (try readDone(a, common)).len);
}

test "moveAside: moves a directory into an entry and verifies it" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    _ = try f.write("synced/kept/k/r/dir/x", "x");
    const src = try f.path("synced/kept/k/r/dir");
    const e = try moveAside(a, layout, mid, "k/r", "dir", src, .replaced);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(src));
    try testing.expectEqual(Check.ok, try verify(a, layout, e.stamp));
}

test "moveAside: the manifest is written before the content moves" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    _ = try f.write("synced/kept/k/r/dir/x", "x");
    const src = try f.path("synced/kept/k/r/dir");

    defer interrupt.at = null;
    interrupt.at = .move_manifest;
    try testing.expectError(error.Interrupted, moveAside(a, layout, mid, "k/r", "dir", src, .replaced));
    interrupt.at = null;
    try testing.expectEqualStrings("x", try content.readSmall(a, try f.path("synced/kept/k/r/dir/x")));
    var d = try std.Io.Dir.cwd().openDir(io(), try layout.asideDir(a), .{ .iterate = true });
    defer d.close(io());
    var it = d.iterate();
    const stamp = (try it.next(io())).?.name;
    try testing.expect((try readManifest(a, layout, stamp)) != null);
    try testing.expectEqual(Check.missing, try verify(a, layout, stamp));
}

test "verify: with Windows' rules, an entry naming a device or a stream is not verifiable and is never opened" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    _ = try f.write("clone/d/CON.txt", "a device name elsewhere");
    _ = try f.write("clone/s/a:b", "a stream name elsewhere");
    const dev = try setAside(a, layout, mid, "k/r", "d", try f.path("clone/d"), .blocked);
    const stream = try setAside(a, layout, mid, "k/r", "s", try f.path("clone/s"), .blocked);
    const plain = try setAside(a, layout, mid, "k/r", "p", try f.write("clone/p", "plain"), .blocked);

    windows_names_for_test = true;
    defer windows_names_for_test = false;
    try testing.expectEqual(Check.unverifiable, try verify(a, layout, dev.stamp));
    try testing.expectEqual(Check.unverifiable, try verify(a, layout, stream.stamp));
    try testing.expectEqual(Check.ok, try verify(a, layout, plain.stamp));
}

test "unplaceable: a manifest is placed back only with a valid key, valid paths, and on Windows no device or stream name" {
    const h = "a" ** 64;
    const good: Manifest = .{ .key = "github.com/acme/widget", .rel = "d", .reason = "keep", .files = &.{.{ .path = "d/x", .hex = h.* }} };
    try testing.expect(unplaceable(good) == null);
    var bad = good;
    bad.key = "../acme";
    try testing.expectEqual(Unplaceable.key, unplaceable(bad).?);
    bad = good;
    bad.rel = "a\\b";
    try testing.expectEqual(Unplaceable.path, unplaceable(bad).?);
    bad = good;
    bad.files = &.{.{ .path = "d/.holt-x", .hex = h.* }};
    try testing.expectEqual(Unplaceable.path, unplaceable(bad).?);
    bad = good;
    bad.files = &.{.{ .path = "d/nul.txt", .hex = h.* }};
    try testing.expectEqual(@as(?Unplaceable, if (@import("builtin").os.tag == .windows) .windows_name else null), unplaceable(bad));
    windows_names_for_test = true;
    defer windows_names_for_test = false;
    try testing.expectEqual(Unplaceable.windows_name, unplaceable(bad).?);
}
