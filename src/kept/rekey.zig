//! Moving a repo's kept files to its new identity when `repo adopt` or
//! `repo promote` moves its clone: everything under the old key goes to
//! the new one, which records the old key as an earlier identity so links
//! and other machines still on it resolve through the chain.

const std = @import("std");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const aside = @import("aside.zig");
const clone = @import("clone.zig");
const link = @import("link.zig");
const patterns = @import("patterns.zig");
const place = @import("place.zig");
const interrupt = @import("interrupt.zig");
const ctx_mod = @import("ctx.zig");
const testing = std.testing;

const io = fsutil.io;
const Ctx = ctx_mod.Ctx;

/// A path both keys held with different content: the new key's copy
/// stayed, and the copy from the old key `key` is in the aside entry
/// `entry`.
pub const Differ = struct { key: []const u8, rel: []const u8, entry: []const u8 };

/// A file the new key held at a path none of its facts names, set aside in
/// `entry` so the old key's copy could move in.
pub const Stray = struct { rel: []const u8, entry: []const u8 };

/// What stayed in the old key `key`, which then keeps its record so a
/// later run moves it.
pub const Left = struct {
    key: []const u8,
    /// A kept path of `key`; for `staging`, `reserved`, `bad_marker`, and
    /// `changed`, the absolute path of the slot, file, or marker.
    rel: []const u8,
    why: Why,
    /// For `failed` and `staging`, the error.
    detail: ?[]const u8 = null,

    pub const Why = enum {
        /// A fact names the path, which is not released, but its content
        /// is not in the old key: not downloaded yet, or deleted elsewhere.
        not_arrived,
        /// Moving the path failed.
        failed,
        /// A staging slot this machine has for the old key that
        /// `place.clearStaging` could not clear.
        staging,
        /// A `.holt-` name in the old key's directory that holt does not
        /// know, such as a cloud conflict copy of one of its files.
        reserved,
        /// A marker of the old key that holt cannot read.
        bad_marker,
        /// Markers that arrived in the old key while it was being moved.
        changed,
    };
};

pub const Moved = struct {
    /// No key on the way from the old key to the new one holds anything:
    /// there was nothing to move, or an earlier run moved it all.
    nothing: bool = false,
    /// The old and the new key name one directory, as two spellings that
    /// differ only by case do on a filesystem that folds names, or a
    /// spelling through a link: nothing had to move.
    same: bool = false,
    differs: []const Differ = &.{},
    strays: []const Stray = &.{},
    left: []const Left = &.{},
    /// How many paths moved into the new key.
    moved: usize = 0,
};

/// Every key moving the kept files of the clone at `clone_path` from `old`
/// to `new` involves, with `index` the store's keys as loaded at the start
/// of the command: `old`, each later identity its `.holt-from/` successor
/// chain reaches before `new` (at each step, a successor whose record's
/// `root` the clone matches), and `new` last. The caller locks all of them
/// (`ctx.lockAll`) for `moveKey`.
pub fn involved(ctx: Ctx, index: *const store.KeyIndex, old: []const u8, new: []const u8, clone_path: []const u8) ![]const []const u8 {
    const chain = try chainOf(ctx, index, old, new, try clone.rootCommits(ctx.alloc, clone_path));
    return std.mem.concat(ctx.alloc, []const u8, &.{ chain, &.{new} });
}

/// Moves the kept files of `old` to `new` for the clone at `clone_path`,
/// with `index` the store's keys as loaded at the start of the command.
/// The caller holds the locks of every key `involved` names until the
/// clone itself has moved.
///
/// When `old` and `new` name one directory (compared as the key locks
/// compare them: the nearest existing ancestor by device and inode, and the
/// rest folded), nothing moves: a missing `root` is filled, `new` names
/// `old` as an earlier identity so links spelled with `old` stay holt's,
/// and this machine's staging for `old` is cleared.
///
/// Otherwise every key of the chain `involved` walks that holds anything
/// is a source, record or not. `new` gets a record (the first source
/// record's `root`, or the clone's `clone.defaultRoot`, and the clone's
/// origin), created even when the chain's keys name it as their earlier
/// identity; the `.holt-from/` markers of every key of the chain but the
/// one naming `new`, plus one for each of those keys; and one file under
/// `.holt-skip.d/` per line of each source's skip lists. Then, per source,
/// this machine's staging slots for it are cleared (`place.clearStaging`),
/// and each path a fact or released marker names, and each file no fact
/// names, moves: a path whose facts name content not in the source, and
/// that is not released, has not arrived and stays. A path `new` holds
/// different content at keeps `new`'s copy, facts, and released marker
/// when a fact of `new` names it; the source's copy is set aside and
/// verified, then its facts and released marker are removed, then the
/// copy. When no fact of `new` names it, `new`'s file is set aside
/// (`strays`) and the source's copy moves in. Otherwise the released
/// marker moves unless `new` already names the path, each fact moves
/// unless `new` has that machine's fact, and the copy is renamed in, or,
/// when `new`'s copy is identical, set aside and removed. Last, once
/// nothing of a source is left, its moved marker directories are removed
/// while empty, then its record, then its copied `.holt-from/` and skip
/// lists, and each directory left empty.
///
/// Every step can be repeated, so rerunning after an interruption
/// completes the move. What stays is reported in `left`, and its key keeps
/// its record: a path that has not arrived or could not be moved, a
/// staging slot that could not be cleared, a marker that cannot be read,
/// a `.holt-` name holt does not know, and markers that arrived meanwhile.
/// `KeysNested` when a source's directory holds `new`'s or lies in it;
/// `UnknownRecordVersion` for a record holt does not understand; the
/// errors of `store.ensureKey` for `new`.
pub fn moveKey(ctx: Ctx, index: *const store.KeyIndex, old: []const u8, new: []const u8, clone_path: []const u8) !Moved {
    const a = ctx.alloc;
    if (std.mem.eql(u8, old, new)) return .{ .nothing = true };
    if (try sameDir(ctx, old, new)) return sameKey(ctx, index, old, new, clone_path);

    const roots = try clone.rootCommits(a, clone_path);
    const chain = try chainOf(ctx, index, old, new, roots);
    var sources: std.ArrayList([]const u8) = .empty;
    var root: ?[]const u8 = null;
    for (chain) |k| {
        const rec = try store.readRecord(a, ctx.layout, k);
        if (rec) |r| {
            if (!r.known()) return error.UnknownRecordVersion;
            if (root == null) root = r.root;
        }
        if (rec == null and !try holds(a, ctx.layout, k)) continue;
        if (try below(ctx, new, k) or try below(ctx, k, new)) return error.KeysNested;
        try sources.append(a, k);
    }
    if (sources.items.len == 0) return .{ .nothing = true };
    if (root == null) root = try clone.defaultRoot(a, clone_path);
    const allowed = try allowing(a, index, new, chain);
    _ = try store.ensureKey(a, ctx.layout, &allowed, new, try clone.originUrl(a, clone_path), root, roots);
    try interrupt.check(.rekey_record);

    for (chain) |k| {
        var ignored: std.ArrayList(store.Bad) = .empty;
        for (try store.readFrom(a, ctx.layout, k, &ignored)) |f| {
            if (!std.mem.eql(u8, f, new)) try store.writeFrom(a, ctx.layout, new, f);
        }
        try store.writeFrom(a, ctx.layout, new, k);
    }
    for (sources.items) |k| try copySkipLines(ctx, k, new);
    try interrupt.check(.rekey_from);

    var run: Run = .{ .ctx = ctx, .new = new };
    for (sources.items) |k| try run.moveFrom(k);
    return .{ .differs = run.differs.items, .strays = run.strays.items, .left = run.left.items, .moved = run.moved };
}

/// True when `key`'s directory holds anything but nested keys.
pub fn holds(a: std.mem.Allocator, layout: store.Layout, key: []const u8) !bool {
    const dir = try layout.keyDir(a, key);
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        if (e.kind == .directory) {
            const rec = try std.fs.path.join(a, &.{ dir, e.name, store.record_basename });
            if (try content.entryAt(rec) == .file) continue;
        }
        return true;
    }
    return false;
}

/// `old`, then each successor the chain from it reaches before `new`: at
/// each step the first successor not yet in the chain whose record's `root`
/// is among `roots`, stopping at `new` or a key naming its directory.
fn chainOf(ctx: Ctx, index: *const store.KeyIndex, old: []const u8, new: []const u8, roots: []const []const u8) ![]const []const u8 {
    const a = ctx.alloc;
    var chain: std.ArrayList([]const u8) = .empty;
    try chain.append(a, old);
    var cur = old;
    walk: while (chain.items.len <= index.keys.len) {
        for (index.successorsOf(cur)) |s| {
            if (paths.contains(chain.items, s)) continue;
            if (std.mem.eql(u8, s, new) or try sameDir(ctx, s, new)) break :walk;
            const rec = (try store.readRecord(a, ctx.layout, s)) orelse continue;
            const r = rec.root orelse continue;
            if (!paths.contains(roots, r)) continue;
            try chain.append(a, s);
            cur = s;
            continue :walk;
        }
        break;
    }
    return chain.items;
}

/// `index` with the keys of `chain` no longer counted as later identities
/// of `new`, so moving a repo back to an earlier identity may create it.
fn allowing(a: std.mem.Allocator, index: *const store.KeyIndex, new: []const u8, chain: []const []const u8) !store.KeyIndex {
    var out = index.*;
    out.successors = try index.successors.clone(a);
    if (out.successors.getPtr(new)) |list| {
        var rest: std.ArrayList([]const u8) = .empty;
        for (list.items) |s| if (!paths.contains(chain, s)) try rest.append(a, s);
        list.* = rest;
    }
    return out;
}

/// Where a key's directory is, as the key locks name it: the nearest
/// existing ancestor, and the rest of the path below it, folded.
const DirId = struct { head: []const u8, rest: []const u8 };

fn dirId(ctx: Ctx, key: []const u8) !DirId {
    const a = ctx.alloc;
    const full = try std.fs.path.resolve(a, &.{try ctx.layout.keyDir(a, key)});
    var head: []const u8 = full;
    while (try content.entryAt(head) == .absent) head = std.fs.path.dirname(head) orelse break;
    const rest = paths.Folding.all.key(a, full[head.len..]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => full[head.len..],
    };
    return .{ .head = head, .rest = rest };
}

fn sameId(a: std.mem.Allocator, x: DirId, y: DirId) !bool {
    return std.mem.eql(u8, x.rest, y.rest) and try content.sameFile(a, x.head, y.head);
}

/// True when the directories of keys `x` and `y` are one directory.
fn sameDir(ctx: Ctx, x: []const u8, y: []const u8) !bool {
    return sameId(ctx.alloc, try dirId(ctx, x), try dirId(ctx, y));
}

/// True when the directory of key `child` lies inside the directory of key
/// `parent`.
fn below(ctx: Ctx, child: []const u8, parent: []const u8) !bool {
    const pid = try dirId(ctx, parent);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, child, i, '/')) |j| : (i = j + 1) {
        if (try sameId(ctx.alloc, try dirId(ctx, child[0..j]), pid)) return true;
    }
    return false;
}

fn sameKey(ctx: Ctx, index: *const store.KeyIndex, old: []const u8, new: []const u8, clone_path: []const u8) !Moved {
    const a = ctx.alloc;
    var run: Run = .{ .ctx = ctx, .new = new };
    if (try store.readRecord(a, ctx.layout, new)) |rec| {
        if (!rec.known()) return error.UnknownRecordVersion;
        if (rec.root == null) _ = try store.ensureKey(a, ctx.layout, index, new, null, try clone.defaultRoot(a, clone_path), try clone.rootCommits(a, clone_path));
        try store.writeFrom(a, ctx.layout, new, old);
    }
    try run.clearStaging(old);
    return .{ .same = true, .left = run.left.items };
}

/// Writes each line of `old`'s skip lists, in order, to its own file under
/// `new`'s `.holt-skip.d/`, named by `old` and the line's place so a rerun
/// rewrites the same files, and removes any such file of `old`'s past the
/// last line, which an earlier run wrote from longer lists.
fn copySkipLines(ctx: Ctx, old: []const u8, new: []const u8) !void {
    const a = ctx.alloc;
    const text = try patterns.repoSkipText(a, ctx.layout, old, null);
    const dir = try ctx.layout.reserved(a, new, ".holt-skip.d");
    const oid = paths.id(old);
    const prefix = try std.fmt.allocPrint(a, "from-{s}-", .{oid[0..16]});
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len == 0 or l[0] == '#') continue;
        try fsutil.ensureDir(dir);
        const name = try std.fmt.allocPrint(a, "{s}{d:0>6}", .{ prefix, n });
        try fsutil.writeFileAtomic(a, try std.fs.path.join(a, &.{ dir, name }), try std.mem.concat(a, u8, &.{ l, "\n" }));
        n += 1;
    }
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer d.close(io());
    var stale: std.ArrayList([]const u8) = .empty;
    var dit = d.iterate();
    while (try dit.next(io())) |e| {
        if (!std.mem.startsWith(u8, e.name, prefix)) continue;
        const place_n = std.fmt.parseUnsigned(usize, e.name[prefix.len..], 10) catch continue;
        if (place_n >= n) try stale.append(a, try a.dupe(u8, e.name));
    }
    for (stale.items) |name| try fsutil.removePath(try std.fs.path.join(a, &.{ dir, name }));
}

/// The names holt writes in a key's directory.
const own_names = [_][]const u8{ store.record_basename, ".holt-paths", ".holt-released", ".holt-from", ".holt-skip.d", ".holt-skip" };

/// Whether `name` is one of holt's own unfinished writes: a
/// `fsutil.writeFileAtomic` or `content.tempSibling` temporary.
fn isTemp(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".tmp") or std.mem.startsWith(u8, name, ".holt-tmp-");
}

const PathMove = union(enum) { none, moved, not_arrived, differs: []const u8, stray: []const u8 };

const Run = struct {
    ctx: Ctx,
    new: []const u8,
    differs: std.ArrayList(Differ) = .empty,
    strays: std.ArrayList(Stray) = .empty,
    left: std.ArrayList(Left) = .empty,
    moved: usize = 0,

    fn leave(r: *Run, key: []const u8, rel: []const u8, why: Left.Why, detail: ?[]const u8) !void {
        try r.left.append(r.ctx.alloc, .{ .key = key, .rel = rel, .why = why, .detail = detail });
    }

    fn clearStaging(r: *Run, key: []const u8) !void {
        const ctx = r.ctx;
        const a = ctx.alloc;
        const slots = place.clearStaging(a, ctx.layout, ctx.machine_id, key) catch |err| switch (err) {
            error.OutOfMemory, error.Interrupted => return err,
            else => return r.leave(key, try ctx.layout.stagingDir(a, ctx.machine_id, key), .staging, @errorName(err)),
        };
        for (slots) |s| try r.leave(key, s.slot, .staging, s.reason);
    }

    fn moveFrom(r: *Run, old: []const u8) !void {
        const ctx = r.ctx;
        const a = ctx.alloc;
        const before = r.left.items.len;
        try r.clearStaging(old);

        var bad: std.ArrayList(store.Bad) = .empty;
        _ = try store.readFrom(a, ctx.layout, old, &bad);
        const st = try store.loadKeyState(a, ctx.layout, old);
        try bad.appendSlice(a, st.bad);
        for (bad.items) |b| try r.leave(old, b.path, .bad_marker, b.reason);

        const named = try st.namedPaths(a);
        const rels = try std.mem.concat(a, []const u8, &.{ named, try store.unknownFiles(a, ctx.layout, old, named) });
        for (rels) |rel| {
            const got = r.movePath(old, rel, st) catch |err| switch (err) {
                error.OutOfMemory, error.Interrupted => return err,
                else => {
                    try r.leave(old, rel, .failed, @errorName(err));
                    continue;
                },
            };
            switch (got) {
                .moved => r.moved += 1,
                .none => {},
                .not_arrived => try r.leave(old, rel, .not_arrived, null),
                .differs => |entry| try r.differs.append(a, .{ .key = old, .rel = rel, .entry = entry }),
                .stray => |entry| {
                    r.moved += 1;
                    try r.strays.append(a, .{ .rel = rel, .entry = entry });
                },
            }
        }

        const old_dir = try ctx.layout.keyDir(a, old);
        var names: std.ArrayList([]const u8) = .empty;
        if (std.Io.Dir.cwd().openDir(io(), old_dir, .{ .iterate = true })) |opened| {
            var d = opened;
            defer d.close(io());
            var it = d.iterate();
            while (try it.next(io())) |e| {
                if (paths.isReserved(e.name)) try names.append(a, try a.dupe(u8, e.name));
            }
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => return err,
        }
        for (names.items) |name| {
            if (paths.contains(&own_names, name)) continue;
            const p = try std.fs.path.join(a, &.{ old_dir, name });
            if (isTemp(name)) {
                try std.Io.Dir.cwd().deleteTree(io(), p);
            } else try r.leave(old, p, .reserved, null);
        }
        if (r.left.items.len > before) return;

        for ([_][]const u8{ ".holt-paths", ".holt-released" }) |name| {
            const p = try std.fs.path.join(a, &.{ old_dir, name });
            if (!try pruneMarkers(a, p)) try r.leave(old, p, .changed, null);
        }
        if (r.left.items.len > before) return;
        try fsutil.removePath(try ctx.layout.reserved(a, old, store.record_basename));
        try interrupt.check(.rekey_reserved);
        for ([_][]const u8{ ".holt-from", ".holt-skip.d", ".holt-skip" }) |name| {
            try std.Io.Dir.cwd().deleteTree(io(), try std.fs.path.join(a, &.{ old_dir, name }));
        }
        try removeEmptyDirs(a, try ctx.layout.keptDir(a), old_dir);
    }

    fn movePath(r: *Run, old: []const u8, rel: []const u8, old_st: store.KeyState) !PathMove {
        const ctx = r.ctx;
        const a = ctx.alloc;
        const new = r.new;
        if (paths.check(rel) != null) return error.InvalidPath;
        const new_dir = try ctx.layout.keyDir(a, new);
        const old_dir = try ctx.layout.keyDir(a, old);
        if (!try link.parentsReal(a, old_dir, rel) or !try link.parentsReal(a, new_dir, rel)) return error.ParentNotDirectory;
        const from = try ctx.layout.copyPath(a, old, rel);
        const to = try ctx.layout.copyPath(a, new, rel);
        const oe = try content.entryAt(from);
        var ne = try content.entryAt(to);
        switch (oe) {
            .absent => if (old_st.factsFor(rel).len > 0 and !old_st.isReleased(rel)) return .not_arrived,
            .file, .dir => {},
            .symlink, .other => return error.NotRegular,
        }

        var new_st = try store.loadKeyState(a, ctx.layout, new);
        var stray: ?[]const u8 = null;
        if (oe != .absent and ne != .absent and !try sameContent(a, from, to)) {
            if (new_st.factsFor(rel).len > 0) {
                const e = try aside.setAside(a, ctx.layout, ctx.machine_id, old, rel, from, .old_location);
                try interrupt.check(.rekey_aside);
                try store.removeFacts(a, ctx.layout, old, rel);
                try store.removeReleased(a, ctx.layout, old, rel);
                try removeIfUnchanged(a, from, e.hash);
                try removeEmptyDirs(a, old_dir, std.fs.path.dirname(from).?);
                return .{ .differs = e.stamp };
            }
            const e = try aside.setAside(a, ctx.layout, ctx.machine_id, new, rel, to, .replaced);
            try interrupt.check(.rekey_aside);
            try removeIfUnchanged(a, to, e.hash);
            stray = e.stamp;
            ne = .absent;
            new_st = try store.loadKeyState(a, ctx.layout, new);
        }

        const new_names = new_st.factsFor(rel).len > 0 or new_st.isReleased(rel);
        const sid = paths.id(rel);
        const old_released = try std.fs.path.join(a, &.{ try ctx.layout.reserved(a, old, ".holt-released"), &sid });
        if (try content.entryAt(old_released) != .absent) {
            if (new_names) {
                try fsutil.removePath(old_released);
            } else {
                try moveFile(a, old_released, try std.fs.path.join(a, &.{ try ctx.layout.reserved(a, new, ".holt-released"), &sid }));
            }
        }
        const old_facts = try std.fs.path.join(a, &.{ try ctx.layout.reserved(a, old, ".holt-paths"), &sid });
        const new_facts = try std.fs.path.join(a, &.{ try ctx.layout.reserved(a, new, ".holt-paths"), &sid });
        if (std.Io.Dir.cwd().openDir(io(), old_facts, .{ .iterate = true })) |opened| {
            var d = opened;
            defer d.close(io());
            var names: std.ArrayList([]const u8) = .empty;
            var it = d.iterate();
            while (try it.next(io())) |e| {
                if (!isTemp(e.name)) try names.append(a, try a.dupe(u8, e.name));
            }
            for (names.items) |n| try moveFile(a, try std.fs.path.join(a, &.{ old_facts, n }), try std.fs.path.join(a, &.{ new_facts, n }));
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => return err,
        }
        try interrupt.check(.rekey_facts);

        if (oe == .absent) return .none;
        if (ne == .absent) {
            try fsutil.ensureDir(std.fs.path.dirname(to).?);
            content.renameNoReplace(a, from, to) catch |err| switch (err) {
                error.PathAlreadyExists => return r.movePath(old, rel, old_st),
                else => return err,
            };
            try removeEmptyDirs(a, old_dir, std.fs.path.dirname(from).?);
            try interrupt.check(.rekey_path);
            return if (stray) |s| .{ .stray = s } else .moved;
        }
        const e = try aside.setAside(a, ctx.layout, ctx.machine_id, old, rel, from, .old_location);
        try removeIfUnchanged(a, from, e.hash);
        try removeEmptyDirs(a, old_dir, std.fs.path.dirname(from).?);
        try interrupt.check(.rekey_path);
        return .none;
    }
};

/// Removes what is left under the marker directory `path` once its markers
/// moved: holt's unfinished writes, then each directory while empty. True
/// when nothing is left.
fn pruneMarkers(a: std.mem.Allocator, path: []const u8) !bool {
    switch (try content.entryAt(path)) {
        .absent => return true,
        .dir => {},
        else => {
            if (!isTemp(std.fs.path.basename(path))) return false;
            try fsutil.removePath(path);
            return true;
        },
    }
    var names: std.ArrayList([]const u8) = .empty;
    {
        var d = try std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true });
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| try names.append(a, try a.dupe(u8, e.name));
    }
    var empty = true;
    for (names.items) |n| {
        if (!try pruneMarkers(a, try std.fs.path.join(a, &.{ path, n }))) empty = false;
    }
    if (!empty) return false;
    try std.Io.Dir.cwd().deleteDir(io(), path);
    return true;
}

/// Deletes the content at `path` only while it still hashes to `expect`,
/// hashed immediately before; `ContentChanged` otherwise.
fn removeIfUnchanged(a: std.mem.Allocator, path: []const u8, expect: content.Hash) !void {
    const now = content.hashPath(a, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.ContentChanged,
    };
    if (now.kind != expect.kind or !std.mem.eql(u8, &now.hex, &expect.hex)) return error.ContentChanged;
    try std.Io.Dir.cwd().deleteTree(io(), path);
}

fn sameContent(alloc: std.mem.Allocator, x: []const u8, y: []const u8) !bool {
    const hx = content.hashPath(alloc, x) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    const hy = content.hashPath(alloc, y) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    return hx.kind == hy.kind and std.mem.eql(u8, &hx.hex, &hy.hex) and try content.executableCarried(alloc, x, y);
}

/// Moves the marker file `from` to `to` unless one is there already, in
/// which case `from` is dropped: the marker at `to` wins.
fn moveFile(alloc: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    try fsutil.ensureDir(std.fs.path.dirname(to).?);
    content.renameNoReplace(alloc, from, to) catch |err| switch (err) {
        error.PathAlreadyExists => try fsutil.removePath(from),
        error.FileNotFound => {},
        else => return err,
    };
    if (std.fs.path.dirname(from)) |d| fsutil.rmdirIfEmpty(d);
}

/// Removes `dir` and each parent up to, not including, `stop`, while empty.
fn removeEmptyDirs(alloc: std.mem.Allocator, stop: []const u8, dir: []const u8) !void {
    var cur = try alloc.dupe(u8, dir);
    while (cur.len > stop.len and fsutil.pathIsInside(cur, stop)) {
        std.Io.Dir.cwd().deleteDir(io(), cur) catch return;
        cur = @constCast(std.fs.path.dirname(cur) orelse return);
    }
}

const harness = @import("harness.zig");
const testutil = @import("../testutil.zig");
const reconcile_mod = @import("reconcile.zig");

const renamed = "github.com/acme/renamed";

/// One machine's clone keeping `.clasp.json`, `.superpowers/` and a
/// released `gone.txt`, with a skip line in each of its key's lists.
fn seeded(a: std.mem.Allocator, sb: *testutil.Sandbox) !harness.World {
    var w = try harness.World.init(a, sb, 1);
    const m = w.m(0);
    try m.write(".clasp.json", "{\"scriptId\": \"abc\"}");
    try m.write(".superpowers/notes.md", "notes");
    try m.write("gone.txt", "gone");
    try m.write("same.txt", "same");
    for ([_][]const u8{ ".clasp.json", ".superpowers", "gone.txt", "same.txt" }) |rel| _ = try m.keep(rel);
    try store.writeReleased(a, m.ctx.layout, harness.repo_key, "gone.txt");
    const key_dir = try m.ctx.layout.keyDir(a, harness.repo_key);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ key_dir, ".holt-skip" }), .data = "# mine\n*.tmp\n" });
    try fsutil.ensureDir(try std.fs.path.join(a, &.{ key_dir, ".holt-skip.d" }));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ key_dir, ".holt-skip.d", "0001" }), .data = "/build\n" });
    return w;
}

fn move(m: *const harness.Machine) !Moved {
    return moveTo(m, harness.repo_key, renamed);
}

fn expectMoved(m: *const harness.Machine) !void {
    const a = m.ctx.alloc;
    const layout = m.ctx.layout;
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.keyDir(a, harness.repo_key)));
    const rec = (try store.readRecord(a, layout, renamed)).?;
    try testing.expect(rec.root != null);
    try testing.expect(paths.contains(try clone.rootCommits(a, m.clone), rec.root.?));
    var bad: std.ArrayList(store.Bad) = .empty;
    try testing.expect(paths.contains(try store.readFrom(a, layout, renamed, &bad), harness.repo_key));
    const st = try store.loadKeyState(a, layout, renamed);
    const set = try st.keptSet(a);
    try testing.expectEqual(@as(usize, 3), set.len);
    try testing.expect(st.isReleased("gone.txt"));
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try content.readSmall(a, try layout.copyPath(a, renamed, ".clasp.json")));
    try testing.expectEqualStrings("notes", try content.readSmall(a, try layout.copyPath(a, renamed, ".superpowers/notes.md")));
    try testing.expectEqualStrings("gone", try content.readSmall(a, try layout.copyPath(a, renamed, "gone.txt")));
    try testing.expectEqualStrings("same", try content.readSmall(a, try layout.copyPath(a, renamed, "same.txt")));
    const skip = try patterns.repoSkipText(a, layout, renamed, null);
    try testing.expect(std.mem.indexOf(u8, skip, "*.tmp\n") != null);
    try testing.expect(std.mem.indexOf(u8, skip, "/build\n") != null);
    try testing.expect(std.mem.indexOf(u8, skip, "# mine") == null);
}

test "moveKey: content, facts, released markers, and skip lines move; the old key is named; links retarget through the chain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seeded(a, &sb);
    const m = w.m(0);

    const moved = try move(m);
    try testing.expectEqual(@as(usize, 4), moved.moved);
    try testing.expectEqual(@as(usize, 0), moved.differs.len);
    try expectMoved(m);

    const r = try m.reconcile();
    try testing.expectEqualStrings(renamed, r.resolved.?);
    try testing.expect(r.find(".clasp.json", .retargeted) != null);
    try testing.expect(r.find(".superpowers", .retargeted) != null);
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try m.read(".clasp.json"));
    try testing.expectEqualStrings("notes", try m.read(".superpowers/notes.md"));
    try testing.expectEqual(@as(usize, 0), r.unsettledCount());

    try testing.expect((try move(m)).nothing);
}

test "moveKey: a path the new key holds with different content keeps the new copy and sets the old aside; an identical one merges" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    const index = try store.loadIndex(a, layout);
    _ = try store.ensureKey(a, layout, &index, renamed, null, null, &.{});
    const other = "000000000000000b";
    for ([_][2][]const u8{ .{ ".clasp.json", "{\"scriptId\": \"new\"}" }, .{ "same.txt", "same" } }) |p| {
        const to = try layout.copyPath(a, renamed, p[0]);
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = to, .data = p[1] });
        const h = try content.hashFile(a, to);
        try store.writeFact(a, layout, renamed, other, p[0], .file, &h);
    }

    const moved = try move(m);
    try testing.expectEqual(@as(usize, 1), moved.differs.len);
    try testing.expectEqualStrings(".clasp.json", moved.differs[0].rel);
    try testing.expectEqualStrings("{\"scriptId\": \"new\"}", try content.readSmall(a, try layout.copyPath(a, renamed, ".clasp.json")));
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try content.readSmall(a, try aside.dataPath(a, layout, moved.differs[0].entry, ".clasp.json")));
    const st = try store.loadKeyState(a, layout, renamed);
    try testing.expectEqual(@as(usize, 1), st.factsFor(".clasp.json").len);
    try testing.expectEqualStrings(other, st.factsFor(".clasp.json")[0].machine);
    try testing.expectEqual(@as(usize, 2), st.factsFor("same.txt").len);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.keyDir(a, harness.repo_key)));
    try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
}

test "moveKey interrupted at every step: nothing is lost, and rerunning completes the move" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer interrupt.at = null;
    const points = [_]interrupt.Point{ .rekey_record, .rekey_from, .rekey_facts, .rekey_path, .aside_copied, .aside_manifest, .rekey_reserved };
    for (points) |point| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try seeded(a, &sb);
        const m = w.m(0);
        const layout = m.ctx.layout;
        if (point == .aside_copied or point == .aside_manifest) {
            const index = try store.loadIndex(a, layout);
            _ = try store.ensureKey(a, layout, &index, renamed, null, null, &.{});
            try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try layout.copyPath(a, renamed, "same.txt"), .data = "same" });
        }

        interrupt.at = point;
        try testing.expectError(error.Interrupted, move(m));
        interrupt.at = null;
        for ([_][2][]const u8{ .{ ".clasp.json", "{\"scriptId\": \"abc\"}" }, .{ ".superpowers/notes.md", "notes" }, .{ "same.txt", "same" } }) |p| {
            const at_old = content.readSmall(a, try layout.copyPath(a, harness.repo_key, p[0])) catch "";
            const at_new = content.readSmall(a, try layout.copyPath(a, renamed, p[0])) catch "";
            try testing.expect(std.mem.eql(u8, at_old, p[1]) or std.mem.eql(u8, at_new, p[1]));
        }
        _ = try m.reconcile();
        try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try m.read(".clasp.json"));

        const moved = try move(m);
        try testing.expectEqual(@as(usize, 0), moved.left.len);
        try testing.expectEqual(@as(usize, 0), moved.differs.len);
        try expectMoved(m);
        const r = try m.reconcile();
        try testing.expectEqual(@as(usize, 0), r.unsettledCount());
        try testing.expectEqualStrings("notes", try m.read(".superpowers/notes.md"));
    }
}

test "moveKey: keys one inside the other are refused, and an old key with no record is already moved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const index = try store.loadIndex(a, m.ctx.layout);
    try testing.expectError(error.KeysNested, moveKey(m.ctx, &index, harness.repo_key, harness.repo_key ++ "/sub", m.clone));
    try testing.expect((try moveKey(m.ctx, &index, "github.com/acme/none", renamed, m.clone)).nothing);
}

fn moveTo(m: *const harness.Machine, old: []const u8, new: []const u8) !Moved {
    const index = try store.loadIndex(m.ctx.alloc, m.ctx.layout);
    const locks = try ctx_mod.lockAll(m.ctx, try involved(m.ctx, &index, old, new, m.clone));
    defer locks.release();
    return moveKey(m.ctx, &index, old, new, m.clone);
}

fn expectAllIn(m: *const harness.Machine, key: []const u8) !void {
    const a = m.ctx.alloc;
    const layout = m.ctx.layout;
    try testing.expect(try store.readRecord(a, layout, key) != null);
    const st = try store.loadKeyState(a, layout, key);
    try testing.expectEqual(@as(usize, 3), (try st.keptSet(a)).len);
    try testing.expect(st.isReleased("gone.txt"));
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try content.readSmall(a, try layout.copyPath(a, key, ".clasp.json")));
    try testing.expectEqualStrings("notes", try content.readSmall(a, try layout.copyPath(a, key, ".superpowers/notes.md")));
    try testing.expectEqualStrings("same", try content.readSmall(a, try layout.copyPath(a, key, "same.txt")));
}

test "moveKey: a new key naming the old key's own directory, through a link or by case, moves nothing and loses nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    try content.createLink(try layout.keyDir(a, "github.com/acme"), try layout.keyDir(a, "github.com/alias"), .dir);

    var news: std.ArrayList([]const u8) = .empty;
    try news.append(a, "github.com/alias/widget");
    if (!try harness.caseSensitive(a, m.synced)) try news.append(a, "github.com/acme/Widget");
    for (news.items) |new| {
        const got = try moveTo(m, harness.repo_key, new);
        try testing.expect(got.same);
        try testing.expectEqual(@as(usize, 0), got.moved);
        try expectAllIn(m, harness.repo_key);
        try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
        try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try m.read(".clasp.json"));
    }
}

test "moveKey: a fact whose content has not arrived stops the move with the old record kept, and a rerun once it arrives completes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    const kept_copy = try layout.copyPath(a, harness.repo_key, ".clasp.json");
    try fsutil.removePath(kept_copy);

    const first = try moveTo(m, harness.repo_key, renamed);
    try testing.expectEqual(@as(usize, 1), first.left.len);
    try testing.expectEqualStrings(".clasp.json", first.left[0].rel);
    try testing.expectEqual(Left.Why.not_arrived, first.left[0].why);
    try testing.expect(try store.readRecord(a, layout, harness.repo_key) != null);
    try testing.expectEqual(@as(usize, 1), (try store.loadKeyState(a, layout, harness.repo_key)).factsFor(".clasp.json").len);

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = kept_copy, .data = "{\"scriptId\": \"abc\"}" });
    const again = try moveTo(m, harness.repo_key, renamed);
    try testing.expectEqual(@as(usize, 0), again.left.len);
    try expectMoved(m);
}

test "moveKey: an old key directory with content but no record still moves" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    try fsutil.removePath(try layout.reserved(a, harness.repo_key, store.record_basename));

    const got = try moveTo(m, harness.repo_key, renamed);
    try testing.expect(!got.nothing);
    try expectMoved(m);
}

test "moveKey: moving back to an earlier identity is allowed, and the new key does not name itself" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    _ = try moveTo(m, harness.repo_key, renamed);
    _ = try m.reconcile();

    const back = try moveTo(m, renamed, harness.repo_key);
    try testing.expectEqual(@as(usize, 0), back.left.len);
    try expectAllIn(m, harness.repo_key);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.keyDir(a, renamed)));
    var bad: std.ArrayList(store.Bad) = .empty;
    const from = try store.readFrom(a, layout, harness.repo_key, &bad);
    try testing.expect(paths.contains(from, renamed));
    try testing.expect(!paths.contains(from, harness.repo_key));
    const r = try m.reconcile();
    try testing.expectEqual(@as(usize, 0), r.unsettledCount());
    try testing.expectEqualStrings(harness.repo_key, r.resolved.?);
    try testing.expectEqualStrings("notes", try m.read(".superpowers/notes.md"));
}

test "moveKey: a file no fact names in the new key is set aside, and the old copy moves in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    const index = try store.loadIndex(a, layout);
    _ = try store.ensureKey(a, layout, &index, renamed, null, null, &.{});
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try layout.copyPath(a, renamed, ".clasp.json"), .data = "stray" });

    const got = try moveTo(m, harness.repo_key, renamed);
    try testing.expectEqual(@as(usize, 0), got.left.len);
    try testing.expectEqual(@as(usize, 0), got.differs.len);
    try testing.expectEqual(@as(usize, 1), got.strays.len);
    try testing.expectEqualStrings(".clasp.json", got.strays[0].rel);
    try testing.expectEqualStrings("stray", try content.readSmall(a, try aside.dataPath(a, layout, got.strays[0].entry, ".clasp.json")));
    try expectMoved(m);
    const r = try m.reconcile();
    try testing.expectEqual(@as(usize, 0), r.unsettledCount());
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try m.read(".clasp.json"));
}

test "moveKey: this machine's staging for the old key is cleared, a swapped-out copy set aside first, and a slot it cannot clear stops the move" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    defer interrupt.at = null;
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    const staging = try layout.stagingDir(a, m.ctx.machine_id, harness.repo_key);
    const src = try std.fs.path.join(a, &.{ sb.root, "replacement" });
    try fsutil.ensureDir(src);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ src, "notes.md" }), .data = "notes" });
    const staged = try place.stage(a, layout, m.ctx.machine_id, harness.repo_key, src);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try layout.copyPath(a, harness.repo_key, ".superpowers/notes.md"), .data = "swapped out" });
    interrupt.at = .replace_swapped;
    try testing.expectError(error.Interrupted, place.replaceKept(a, layout, m.ctx.machine_id, harness.repo_key, ".superpowers", staged));
    interrupt.at = null;
    const odd = try std.fs.path.join(a, &.{ staging, "odd" });
    try fsutil.ensureDir(odd);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ odd, "swapped-out" }), .data = "{" });

    const first = try moveTo(m, harness.repo_key, renamed);
    try testing.expectEqual(@as(usize, 1), first.left.len);
    try testing.expectEqual(Left.Why.staging, first.left[0].why);
    try testing.expectEqualStrings(odd, first.left[0].rel);
    try testing.expect(try store.readRecord(a, layout, harness.repo_key) != null);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(std.fs.path.dirname(staged.path).?));

    try std.Io.Dir.cwd().deleteTree(io(), odd);
    const again = try moveTo(m, harness.repo_key, renamed);
    try testing.expectEqual(@as(usize, 0), again.left.len);
    try expectMoved(m);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(staging));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.keyDir(a, harness.repo_key)));
}

var tamper_path: ?[]const u8 = null;

fn tamper(point: interrupt.Point) void {
    if (point != .aside_copied and point != .move_manifest) return;
    const p = tamper_path orelse return;
    tamper_path = null;
    std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = "changed meanwhile" }) catch {};
}

/// `seeded`, plus a new key holding `.clasp.json` with other content and
/// another machine's fact for it.
fn seededDiffering(a: std.mem.Allocator, sb: *testutil.Sandbox) !harness.World {
    var w = try seeded(a, sb);
    const layout = w.m(0).ctx.layout;
    const index = try store.loadIndex(a, layout);
    _ = try store.ensureKey(a, layout, &index, renamed, null, null, &.{});
    const to = try layout.copyPath(a, renamed, ".clasp.json");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = to, .data = "{\"scriptId\": \"new\"}" });
    const h = try content.hashFile(a, to);
    try store.writeFact(a, layout, renamed, "000000000000000b", ".clasp.json", .file, &h);
    return w;
}

test "moveKey: an old copy that changes while it is set aside for a differing path stays where it is, with its facts, until a rerun" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seededDiffering(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    const from = try layout.copyPath(a, harness.repo_key, ".clasp.json");
    tamper_path = from;
    defer tamper_path = null;
    interrupt.hook = tamper;
    defer interrupt.hook = null;

    const first = try moveTo(m, harness.repo_key, renamed);
    interrupt.hook = null;
    try testing.expectEqual(@as(usize, 1), first.left.len);
    try testing.expectEqual(Left.Why.failed, first.left[0].why);
    try testing.expectEqualStrings("ContentChanged", first.left[0].detail.?);
    try testing.expectEqualStrings("changed meanwhile", try content.readSmall(a, from));
    try testing.expect(try store.readRecord(a, layout, harness.repo_key) != null);

    const again = try moveTo(m, harness.repo_key, renamed);
    try testing.expectEqual(@as(usize, 0), again.left.len);
    try testing.expectEqual(@as(usize, 1), again.differs.len);
    try testing.expectEqualStrings("changed meanwhile", try content.readSmall(a, try aside.dataPath(a, layout, again.differs[0].entry, ".clasp.json")));
    try testing.expectEqualStrings("{\"scriptId\": \"new\"}", try content.readSmall(a, try layout.copyPath(a, renamed, ".clasp.json")));
}

test "moveKey interrupted while a differing path is set aside: the old copy and its facts stay until a rerun sets it aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer interrupt.at = null;
    for ([_]interrupt.Point{ .aside_copied, .aside_manifest, .rekey_aside }) |point| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try seededDiffering(a, &sb);
        const m = w.m(0);
        const layout = m.ctx.layout;
        const from = try layout.copyPath(a, harness.repo_key, ".clasp.json");

        interrupt.at = point;
        try testing.expectError(error.Interrupted, moveTo(m, harness.repo_key, renamed));
        interrupt.at = null;
        try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try content.readSmall(a, from));
        try testing.expectEqual(@as(usize, 1), (try store.loadKeyState(a, layout, harness.repo_key)).factsFor(".clasp.json").len);

        const again = try moveTo(m, harness.repo_key, renamed);
        try testing.expectEqual(@as(usize, 0), again.left.len);
        try testing.expectEqual(@as(usize, 1), again.differs.len);
        try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try content.readSmall(a, try aside.dataPath(a, layout, again.differs[0].entry, ".clasp.json")));
        try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.keyDir(a, harness.repo_key)));
    }
}

test "moveKey: an old key already moved on is followed through its successor chain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    _ = try moveTo(m, harness.repo_key, renamed);
    const third = "github.com/acme/third";

    const got = try moveTo(m, harness.repo_key, third);
    try testing.expect(!got.nothing);
    try expectAllIn(m, third);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.keyDir(a, renamed)));
    var bad: std.ArrayList(store.Bad) = .empty;
    const from = try store.readFrom(a, layout, third, &bad);
    try testing.expect(paths.contains(from, renamed));
    try testing.expect(paths.contains(from, harness.repo_key));
    const r = try m.reconcile();
    try testing.expectEqualStrings(third, r.resolved.?);
    try testing.expectEqual(@as(usize, 0), r.unsettledCount());
}

test "moveKey: a rerun after the old skip lists shrank leaves no stale line, and a bad or unknown marker stops the move without being deleted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    defer interrupt.at = null;
    var w = try seeded(a, &sb);
    const m = w.m(0);
    const layout = m.ctx.layout;
    const key_dir = try layout.keyDir(a, harness.repo_key);
    interrupt.at = .rekey_from;
    try testing.expectError(error.Interrupted, moveTo(m, harness.repo_key, renamed));
    interrupt.at = null;
    try fsutil.removePath(try std.fs.path.join(a, &.{ key_dir, ".holt-skip.d", "0001" }));
    const bad_from = try std.fs.path.join(a, &.{ key_dir, ".holt-from", "not-a-marker" });
    try fsutil.ensureDir(std.fs.path.dirname(bad_from).?);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = bad_from, .data = "x" });
    const conflict = try std.fs.path.join(a, &.{ key_dir, ".holt-skip (1)" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = conflict, .data = "/mine\n" });

    const got = try moveTo(m, harness.repo_key, renamed);
    try testing.expectEqual(@as(usize, 2), got.left.len);
    for (got.left) |l| {
        if (l.why == .bad_marker) {
            try testing.expectEqualStrings(bad_from, l.rel);
        } else {
            try testing.expectEqual(Left.Why.reserved, l.why);
            try testing.expectEqualStrings(conflict, l.rel);
        }
    }
    try testing.expect(try store.readRecord(a, layout, harness.repo_key) != null);
    try testing.expectEqualStrings("x", try content.readSmall(a, bad_from));
    try testing.expectEqualStrings("/mine\n", try content.readSmall(a, conflict));
    const skip = try patterns.repoSkipText(a, layout, renamed, null);
    try testing.expect(std.mem.indexOf(u8, skip, "*.tmp\n") != null);
    try testing.expect(std.mem.indexOf(u8, skip, "/build\n") == null);

    try fsutil.removePath(bad_from);
    try fsutil.removePath(conflict);
    const again = try moveTo(m, harness.repo_key, renamed);
    try testing.expectEqual(@as(usize, 0), again.left.len);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(key_dir));
}

test "moveKey interrupted while a file no fact names in the new key is set aside: nothing is lost, and a rerun moves the old copy in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer interrupt.at = null;
    for ([_]interrupt.Point{ .aside_copied, .aside_manifest, .rekey_aside }) |point| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try seeded(a, &sb);
        const m = w.m(0);
        const layout = m.ctx.layout;
        const index = try store.loadIndex(a, layout);
        _ = try store.ensureKey(a, layout, &index, renamed, null, null, &.{});
        const to = try layout.copyPath(a, renamed, ".clasp.json");
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = to, .data = "stray" });

        interrupt.at = point;
        try testing.expectError(error.Interrupted, moveTo(m, harness.repo_key, renamed));
        interrupt.at = null;
        try testing.expectEqualStrings("stray", try content.readSmall(a, to));
        try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try content.readSmall(a, try layout.copyPath(a, harness.repo_key, ".clasp.json")));

        const again = try moveTo(m, harness.repo_key, renamed);
        try testing.expectEqual(@as(usize, 0), again.left.len);
        try testing.expectEqual(@as(usize, 1), again.strays.len);
        try testing.expectEqualStrings("stray", try content.readSmall(a, try aside.dataPath(a, layout, again.strays[0].entry, ".clasp.json")));
        try expectMoved(m);
    }
}
