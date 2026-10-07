//! Writes into a key and into a working tree. Content bound for a key is
//! staged in `kept/.holt-tmp/<machine>/<id>/` and placed with a no-replace
//! rename; an existing kept copy is replaced only after it is set aside.
//! In a working tree, every temporary holt makes beside a path is named
//! `paths.tempRel`, has a block line and a `pending` record before it
//! exists, and is settled by `settleTemp` after an interruption.
//! `keepPath` runs the resumable sequence that turns a clone's file or
//! directory into a kept path.

const std = @import("std");
const json = @import("json");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const aside = @import("aside.zig");
const block = @import("block.zig");
const clone = @import("clone.zig");
const link = @import("link.zig");
const sweep = @import("sweep.zig");
const ctx_mod = @import("ctx.zig");
const interrupt = @import("interrupt.zig");
const testing = std.testing;

const io = fsutil.io;
const Layout = store.Layout;
const Ctx = ctx_mod.Ctx;

/// A verified copy waiting in staging.
pub const Staged = struct { path: []const u8, hash: content.Hash };

/// Copies `source` into a fresh slot of the key's staging area and checks
/// the copy hashes the same as the source.
pub fn stage(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: []const u8, source: []const u8) !Staged {
    const before = try content.hashPath(alloc, source);
    const suffix = content.randomSuffix();
    const slot = try std.fs.path.join(alloc, &.{ try layout.stagingDir(alloc, machine_id, key), &suffix });
    try fsutil.ensureDir(slot);
    const dest = try std.fs.path.join(alloc, &.{ slot, "content" });
    try content.copyRegular(alloc, source, dest);
    try interrupt.check(.stage_copied);
    const after = try content.hashPath(alloc, dest);
    if (after.kind != before.kind or !std.mem.eql(u8, &after.hex, &before.hex)) return error.StagingVerifyFailed;
    return .{ .path = dest, .hash = before };
}

/// A staging slot `clearStaging` left in place, and why.
pub const Left = struct { slot: []const u8, reason: []const u8 };

/// Empties the key's staging area. Only under the key's lock: a staged copy
/// always has its source elsewhere, but another writer may be using it. A
/// slot `replaceKept` marked as holding a swapped-out kept copy is removed
/// only once that copy is held by a verified aside entry (`dropSwapOut`). A
/// slot whose mark cannot be read, or whose copy cannot be set aside or
/// removed, is left in place and returned; the other slots are still
/// cleared.
pub fn clearStaging(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: []const u8) ![]const Left {
    const cwd = std.Io.Dir.cwd();
    const dir = try layout.stagingDir(alloc, machine_id, key);
    var slots: std.ArrayList([]const u8) = .empty;
    {
        var d = cwd.openDir(io(), dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return &.{},
            else => return err,
        };
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| try slots.append(alloc, try alloc.dupe(u8, e.name));
    }
    var left: std.ArrayList(Left) = .empty;
    for (slots.items) |name| {
        const slot = try std.fs.path.join(alloc, &.{ dir, name });
        const mark = try std.fs.path.join(alloc, &.{ slot, swap_mark });
        if (try content.entryAt(mark) != .absent) {
            const sw = (try readSwapOut(alloc, mark)) orelse {
                try left.append(alloc, .{ .slot = slot, .reason = "unreadable mark" });
                continue;
            };
            dropSwapOut(alloc, layout, machine_id, key, sw.rel, try std.fs.path.join(alloc, &.{ slot, sw.name }), sw.entry) catch |err| {
                if (err == error.OutOfMemory) return err;
                try left.append(alloc, .{ .slot = slot, .reason = @errorName(err) });
                continue;
            };
        }
        cwd.deleteTree(io(), slot) catch |err| try left.append(alloc, .{ .slot = slot, .reason = @errorName(err) });
    }
    if (left.items.len == 0) try cwd.deleteTree(io(), dir);
    return left.items;
}

/// The name, in a staging slot, of the mark saying which entry of the slot
/// holds a kept copy swapped out by `replaceKept`.
const swap_mark = "swapped-out";

/// A swap mark: the path, the slot entry holding the copy, and the aside
/// entry the mark says holds it, null when the mark records none that can
/// be read, so nothing verifies it yet.
const SwapOut = struct { rel: []const u8, name: []const u8, entry: ?aside.Entry };

/// Marks `name` in the slot holding `staged` as the swapped-out kept copy
/// of `rel`, set aside as `e`.
fn markSwapOut(alloc: std.mem.Allocator, staged: Staged, rel: []const u8, name: []const u8, e: aside.Entry) !void {
    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "kind", .{ .string = @tagName(e.hash.kind) });
    try obj.put(alloc, "name", .{ .string = name });
    try obj.put(alloc, "rel", .{ .string = rel });
    try obj.put(alloc, "sha256", .{ .string = &e.hash.hex });
    try obj.put(alloc, "stamp", .{ .string = e.stamp });
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try json.encode(&aw.writer, .{ .object = obj }, .{ .sort_keys = true });
    try fsutil.writeFileAtomic(alloc, try std.fs.path.join(alloc, &.{ std.fs.path.dirname(staged.path).?, swap_mark }), aw.written());
}

/// The mark at `mark`, or null when it does not say which path and slot
/// entry it is about; a mark that names no readable aside entry reads with
/// none.
fn readSwapOut(alloc: std.mem.Allocator, mark: []const u8) !?SwapOut {
    const v = json.parse(alloc, try content.readSmall(alloc, mark), .{}) catch return null;
    if (v != .object) return null;
    const field = struct {
        fn get(obj: json.ObjectMap, name: []const u8) ?[]const u8 {
            const fv = obj.get(name) orelse return null;
            return if (fv == .string) fv.string else null;
        }
    }.get;
    const name = field(v.object, "name") orelse return null;
    const rel = field(v.object, "rel") orelse return null;
    if (!std.mem.eql(u8, name, "content") and !std.mem.eql(u8, name, "old")) return null;
    if (!paths.contained(rel)) return null;
    const out: SwapOut = .{ .rel = rel, .name = name, .entry = null };
    const kind = std.meta.stringToEnum(content.Kind, field(v.object, "kind") orelse return out) orelse return out;
    const sha = field(v.object, "sha256") orelse return out;
    const stamp = field(v.object, "stamp") orelse return out;
    if (sha.len != 64 or !paths.contained(stamp) or std.mem.indexOfAny(u8, stamp, "/\\") != null) return out;
    var hash: content.Hash = .{ .kind = kind, .hex = undefined };
    @memcpy(&hash.hex, sha);
    return .{ .rel = rel, .name = name, .entry = .{ .stamp = stamp, .hash = hash } };
}

/// Removes the swapped-out kept copy of `rel` at `path` once an aside entry
/// holds it: `recorded` at first, trusted only while it verifies against
/// its manifest (`aside.verify`) and the manifest names `key`, `rel`, and
/// the recorded hash; with none recorded, the copy is set aside first. The
/// copy is hashed again immediately before removal; while no verified
/// entry holds what it hashes to, it is set aside again first. After a few
/// rounds of changes it is left in place and `SwapOutChanging` returned.
fn dropSwapOut(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: []const u8, rel: []const u8, path: []const u8, recorded: ?aside.Entry) !void {
    var e = recorded;
    for (0..4) |_| {
        if (try content.entryAt(path) == .absent) return;
        if (e) |got| if (try holds(alloc, layout, key, rel, got) and try deleteIfHash(alloc, path, got.hash)) return;
        e = try aside.setAside(alloc, layout, machine_id, key, rel, path, .replaced);
    }
    return error.SwapOutChanging;
}

/// Whether the aside entry `e` verifies and its manifest describes `rel` of
/// `key` with `e`'s hash.
fn holds(alloc: std.mem.Allocator, layout: Layout, key: []const u8, rel: []const u8, e: aside.Entry) !bool {
    if (try aside.verify(alloc, layout, e.stamp) != .ok) return false;
    const m = (try aside.readManifest(alloc, layout, e.stamp)) orelse return false;
    if (!std.mem.eql(u8, m.key, key) or !std.mem.eql(u8, m.rel, rel)) return false;
    const h = m.hash(alloc) catch return false;
    return equalHash(h, e.hash);
}

/// Creates the real directories between the key's directory and `rel`,
/// refusing any component that exists and is not a directory.
fn ensureKeptParents(alloc: std.mem.Allocator, layout: Layout, key: []const u8, rel: []const u8) !void {
    const key_dir = try layout.keyDir(alloc, key);
    try fsutil.ensureDir(key_dir);
    if (!try link.parentsReal(alloc, key_dir, rel)) return error.ParentNotDir;
    const dest = try layout.copyPath(alloc, key, rel);
    try fsutil.ensureDir(std.fs.path.dirname(dest).?);
}

/// Places `staged` as the kept copy of `rel`. Something already there is
/// `PathAlreadyExists`, and nothing moves.
pub fn placeNew(alloc: std.mem.Allocator, layout: Layout, key: []const u8, rel: []const u8, staged: Staged) !void {
    try ensureKeptParents(alloc, layout, key, rel);
    try interrupt.check(.place_parents);
    try content.renameNoReplace(alloc, staged.path, try layout.copyPath(alloc, key, rel));
}

/// True when the content at `a` and at `b` hash the same. Content that
/// cannot be hashed (absent, online-only, not regular) is never the same.
fn sameContent(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const ha = (try hashOrNull(alloc, a)) orelse return false;
    const hb = (try hashOrNull(alloc, b)) orelse return false;
    return equalHash(ha, hb);
}

pub fn hashOrNull(alloc: std.mem.Allocator, path: []const u8) !?content.Hash {
    return content.hashPath(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}

pub fn equalHash(a: content.Hash, b: content.Hash) bool {
    return a.kind == b.kind and std.mem.eql(u8, &a.hex, &b.hex);
}

/// Deletes the content at `path` only if it still hashes to `expect`,
/// hashed immediately before. Returns whether it did.
pub fn deleteIfHash(alloc: std.mem.Allocator, path: []const u8, expect: content.Hash) !bool {
    const now = (try hashOrNull(alloc, path)) orelse return false;
    if (!equalHash(now, expect)) return false;
    try std.Io.Dir.cwd().deleteTree(io(), path);
    return true;
}

/// Makes `staged` the kept copy of `rel`. The existing copy is set aside and
/// verified before it is touched. The two then trade places in one exchange
/// rename where the platform has one, and the old copy, now in staging and
/// marked there as swapped out, is removed by `dropSwapOut`. Without an
/// exchange rename, a file replacing a file is renamed over it, so a write
/// landing between the check and the rename is lost; anything else moves
/// the old copy into staging, marked the same way, and the new one in,
/// leaving the path briefly absent. Returns the aside entry, or null when
/// there was no copy to replace.
pub fn replaceKept(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: []const u8, rel: []const u8, staged: Staged) !?aside.Entry {
    const dest = try layout.copyPath(alloc, key, rel);
    const old_kind: content.Kind = switch (try content.entryAt(dest)) {
        .absent => {
            try placeNew(alloc, layout, key, rel, staged);
            return null;
        },
        .file => .file,
        .dir => .dir,
        .symlink, .other => return error.NotRegular,
    };
    const e = try aside.setAside(alloc, layout, machine_id, key, rel, dest, .replaced);
    try interrupt.check(.replace_aside);
    const now = (try hashOrNull(alloc, dest)) orelse return error.KeptChanged;
    if (!equalHash(now, e.hash)) return error.KeptChanged;
    try interrupt.check(.replace_checked);

    const cwd = std.Io.Dir.cwd();
    var old = staged.path;
    try markSwapOut(alloc, staged, rel, "content", e);
    if (content.renameExchange(alloc, staged.path, dest)) {} else |err| switch (err) {
        error.Unsupported => {
            if (old_kind == .file and staged.hash.kind == .file) {
                try cwd.rename(staged.path, cwd, dest, io());
                return e;
            }
            old = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(staged.path).?, "old" });
            try markSwapOut(alloc, staged, rel, "old", e);
            try content.renameNoReplace(alloc, dest, old);
            try interrupt.check(.replace_moved_out);
            try content.renameNoReplace(alloc, staged.path, dest);
        },
        else => return err,
    }
    try interrupt.check(.replace_swapped);
    try dropSwapOut(alloc, layout, machine_id, key, rel, old, e);
    return e;
}

/// Where a write into a working tree happens: the clone, the key holding
/// its kept copies, and the keys and synced roots whose links count as
/// holt's (`link.isHolt`).
pub const Tree = struct {
    ctx: Ctx,
    c: clone.Clone,
    key: []const u8,
    chain: []const []const u8,
    roots: []const []const u8,

    fn at(t: Tree, rel: []const u8) ![]u8 {
        return fsutil.joinSlashy(t.ctx.alloc, t.c.worktree, rel);
    }

    /// The temporary beside `<worktree>/<rel>`.
    pub fn tempPath(t: Tree, rel: []const u8) ![]u8 {
        return t.at(try paths.tempRel(t.ctx.alloc, rel));
    }

    fn setAside(t: Tree, rel: []const u8, path: []const u8, reason: aside.Reason) !aside.Entry {
        return aside.ensureAside(t.ctx.alloc, t.ctx.layout, t.c.common_dir, t.ctx.machine_id, t.key, rel, path, reason, .whole);
    }
};

pub const Settled = struct {
    how: How,
    /// The aside entry holding the temporary's content, when it was set
    /// aside before being removed.
    entry: ?[]const u8 = null,

    pub const How = enum {
        /// No temporary was there.
        none,
        /// The temporary's content went back to the path.
        restored,
        /// The temporary held content that is safe elsewhere, or only a
        /// link, and was removed.
        removed,
        /// The interrupted write was finished: for a release the temporary
        /// took the link's place; for a keep or relink the link stays and
        /// the temporary, set aside first, was removed.
        finished,
        /// For a keep or relink, local content has replaced the link since:
        /// the temporary, set aside first, was removed, and what is at the
        /// path is left to be judged as local content.
        set_aside,
        /// Something unexpected is at the path; the temporary was left.
        stuck,
    };
};

/// Settles the temporary an interrupted write left beside `<worktree>/<rel>`.
/// For a release (`op`) the temporary is a copy of the link's target meant
/// to replace the link: it is put in place when it matches that target, and
/// set aside and removed when it does not. Once local content has replaced
/// the link, it is removed when it matches the kept copy and set aside and
/// removed otherwise, never left in place. For any other write it is the
/// path's own content, moved beside it while a link replaced it: it is
/// removed when the link's target holds the same content. Otherwise, for a
/// keep or relink, whose link may since have carried edits into the kept
/// copy, it is set aside and removed and the link kept, or, when local
/// content has replaced the link since, set aside and removed and that
/// content left to be judged; for any other write it is moved back. A
/// temporary that is only holt's link is removed, and so is a directory
/// holding only holt's links to the kept files below `rel`
/// (`link.onlyHoltLinks`) once holt's link is at the path; with nothing at
/// the path, that directory is moved back.
pub fn settleTemp(t: Tree, rel: []const u8, op: ?clone.Op) !Settled {
    const a = t.ctx.alloc;
    const cp = try t.at(rel);
    const tmp = try t.tempPath(rel);
    switch (try content.entryAt(tmp)) {
        .absent => return .{ .how = .none },
        .other => return .{ .how = .stuck },
        .symlink => {
            const raw = (try content.readLink(a, tmp)) orelse return .{ .how = .none };
            if (!link.isHolt(a, tmp, raw, t.chain, t.roots, rel)) return .{ .how = .stuck };
            return .{ .how = if (try content.removeLinkIf(a, tmp, raw)) .removed else .stuck };
        },
        .file, .dir => {},
    }
    const ce = try content.entryAt(cp);
    const raw: ?[]const u8 = if (ce == .symlink) try content.readLink(a, cp) else null;
    if (raw) |r| if (!link.isHolt(a, cp, r, t.chain, t.roots, rel)) return .{ .how = .stuck };
    if (op != .release and try content.entryAt(tmp) == .dir and try link.onlyHoltLinks(a, tmp, t.chain, t.roots, rel)) {
        if (ce == .absent) {
            try content.renameNoReplace(a, tmp, cp);
            return .{ .how = .restored };
        }
        if (raw != null) {
            try std.Io.Dir.cwd().deleteTree(io(), tmp);
            return .{ .how = .removed };
        }
    }

    if (op == .release) {
        if (raw) |r| {
            if (try sameContent(a, tmp, try link.resolveTarget(a, cp, r))) {
                try putInPlace(a, cp, tmp, r);
                return .{ .how = .finished };
            }
        } else if (ce == .absent) {
            const kc = try t.ctx.layout.copyPath(a, t.key, rel);
            if (try content.entryAt(kc) == .absent or try sameContent(a, tmp, kc)) {
                try content.renameNoReplace(a, tmp, cp);
                return .{ .how = .finished };
            }
        } else if (try hashOrNull(a, try t.ctx.layout.copyPath(a, t.key, rel))) |h| {
            if (try deleteIfHash(a, tmp, h)) return .{ .how = .removed };
        }
        return removeSetAside(t, rel, tmp, .removed);
    }

    if (ce == .absent) {
        try content.renameNoReplace(a, tmp, cp);
        return .{ .how = .restored };
    }
    const keeping = op == .keep or op == .relink;
    const r = raw orelse {
        if (keeping and (ce == .file or ce == .dir)) return removeSetAside(t, rel, tmp, .set_aside);
        return .{ .how = .stuck };
    };
    if ((try hashOrNull(a, try link.resolveTarget(a, cp, r)))) |h| {
        if (try deleteIfHash(a, tmp, h)) return .{ .how = .removed };
    }
    if (keeping) return removeSetAside(t, rel, tmp, .finished);
    if (!try content.removeLinkIf(a, cp, r)) return .{ .how = .stuck };
    try content.renameNoReplace(a, tmp, cp);
    return .{ .how = .restored };
}

/// Sets the temporary `tmp` of `rel` aside and removes it once it still
/// hashes as the entry does: `how`, or `stuck` when it changed meanwhile.
fn removeSetAside(t: Tree, rel: []const u8, tmp: []const u8, how: Settled.How) !Settled {
    const e = try t.setAside(rel, tmp, .interrupted);
    return .{ .how = if (try deleteIfHash(t.ctx.alloc, tmp, e.hash)) how else .stuck, .entry = e.stamp };
}

/// Puts the copy at `tmp` where the link `cp` (raw target `raw`) is: a
/// file is renamed over it; a directory trades places with it in one
/// exchange rename, and the link, now at `tmp`, is removed; without an
/// exchange rename the link is removed first.
fn putInPlace(alloc: std.mem.Allocator, cp: []const u8, tmp: []const u8, raw: []const u8) !void {
    if (!try content.isLinkTo(alloc, cp, raw)) return error.LinkChanged;
    if (try content.entryAt(tmp) == .file) {
        return std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), cp, io());
    }
    if (content.renameExchange(alloc, tmp, cp)) {
        try interrupt.check(.convert_swapped);
        if (!try content.removeLinkIf(alloc, tmp, raw)) return error.LinkChanged;
    } else |err| switch (err) {
        error.Unsupported => {
            if (!try content.removeLinkIf(alloc, cp, raw)) return error.LinkChanged;
            try interrupt.check(.convert_swapped);
            try content.renameNoReplace(alloc, tmp, cp);
        },
        else => return err,
    }
}

/// Replaces holt's link at `<worktree>/<rel>` (raw target `raw`) with a
/// regular copy of `target`, whose content hashes to `expect`. The copy is
/// assembled at the path's temporary, recorded in `pending` and the block
/// first, verified, and then put in the link's place.
pub fn convertLink(t: Tree, rel: []const u8, raw: []const u8, target: []const u8, expect: content.Hash) !void {
    const a = t.ctx.alloc;
    const tmp = try t.tempPath(rel);
    try clone.addPending(a, t.c.common_dir, .{ .tree = t.c.tree, .rel = rel, .op = .release, .worktree = t.c.worktree });
    try block.add(a, t.c.common_dir, &.{try paths.tempRel(a, rel)});
    try content.copyRegular(a, target, tmp);
    try interrupt.check(.convert_copied);
    const got = try content.hashPath(a, tmp);
    if (!equalHash(got, expect)) return error.CopyVerifyFailed;
    try putInPlace(a, try t.at(rel), tmp, raw);
    try clone.clearPending(a, t.c.common_dir, t.c.tree, rel);
}

/// Swaps the content at `<worktree>/<rel>` for a link to `target`, which
/// must exist and hold the same content. The caller has recorded `pending`
/// and the temporary's block line. The kept copy first gains any
/// executable bit the content has, where its filesystem lets it; the
/// result is false when one could not be given, and the link is made
/// regardless. Empty directories carry no content, so one the kept copy
/// lacks is not kept. The content moves to the path's
/// temporary, the link is created and read back, and the temporary is
/// deleted only if it still hashes to `expect`; otherwise the link, while
/// it still reads back the same, is removed, the content moves back, and
/// `ChangedDuringLink` is returned. `SymlinkPrivilege` is found by a probe
/// before anything moves; content that cannot be moved back is
/// `TempStranded`, left in the temporary.
pub fn replaceWithLink(t: Tree, rel: []const u8, target: []const u8, expect: content.Hash) !bool {
    return swapInLink(t, rel, target, expect, expect.kind, true);
}

/// `replaceWithLink` for a target that may hold other content than the
/// local content it replaces, hashing to `expect`: the link is of
/// `link_kind`, the target's own kind, and the target gains the content's
/// executable bits only when `carry_exec`. Returns false when a bit could
/// not be given; true otherwise.
pub fn swapInLink(t: Tree, rel: []const u8, target: []const u8, expect: content.Hash, link_kind: content.Kind, carry_exec: bool) !bool {
    const a = t.ctx.alloc;
    switch (try content.entryAt(target)) {
        .file, .dir => {},
        else => return error.TargetAbsent,
    }
    try content.probeLink(a, try clone.stateDir(a, t.c.common_dir), link_kind);
    try store.recordRoot(a, t.ctx.layout);
    const path = try t.at(rel);
    const tmp = try t.tempPath(rel);
    const exec_kept = if (carry_exec) try content.carryExecutable(a, path, target) else true;
    content.renameNoReplace(a, path, tmp) catch |err| switch (err) {
        error.PathAlreadyExists => return error.TempExists,
        else => return err,
    };
    try interrupt.check(.link_moved);
    content.createLink(target, path, link_kind) catch |err| {
        content.renameNoReplace(a, tmp, path) catch return error.TempStranded;
        return err;
    };
    const made = (try content.readLink(a, path)) orelse return error.TempStranded;
    try interrupt.check(.link_created);
    if (try deleteIfHash(a, tmp, expect)) return exec_kept;
    if (!try content.removeLinkIf(a, path, made)) return error.TempStranded;
    content.renameNoReplace(a, tmp, path) catch return error.TempStranded;
    return error.ChangedDuringLink;
}

/// Swaps the directory at `<worktree>/<rel>`, holding only holt's links to
/// the kept files below `rel` (`link.onlyHoltLinks`), for a link to the kept
/// directory `target`, as `swapInLink` does: the directory moves to the
/// path's temporary, the link is made, and the temporary is deleted only
/// while it still holds only those links; otherwise the link is removed,
/// the directory moves back, and `ChangedDuringLink` is returned.
pub fn replaceLinksWithLink(t: Tree, rel: []const u8, target: []const u8) !void {
    const a = t.ctx.alloc;
    if (try content.entryAt(target) != .dir) return error.TargetAbsent;
    try content.probeLink(a, try clone.stateDir(a, t.c.common_dir), .dir);
    try store.recordRoot(a, t.ctx.layout);
    const path = try t.at(rel);
    const tmp = try t.tempPath(rel);
    content.renameNoReplace(a, path, tmp) catch |err| switch (err) {
        error.PathAlreadyExists => return error.TempExists,
        else => return err,
    };
    try interrupt.check(.link_moved);
    content.createLink(target, path, .dir) catch |err| {
        content.renameNoReplace(a, tmp, path) catch return error.TempStranded;
        return err;
    };
    const made = (try content.readLink(a, path)) orelse return error.TempStranded;
    try interrupt.check(.link_created);
    if (try link.onlyHoltLinks(a, tmp, t.chain, t.roots, rel)) {
        try std.Io.Dir.cwd().deleteTree(io(), tmp);
        return;
    }
    if (!try content.removeLinkIf(a, path, made)) return error.TempStranded;
    content.renameNoReplace(a, tmp, path) catch return error.TempStranded;
    return error.ChangedDuringLink;
}

pub const KeepOptions = struct {
    /// Set, when keep refuses a directory with `InvalidName`, to the
    /// entries below it (`/`-joined) whose names a kept path may not hold.
    invalid_names: ?*[]const []const u8 = null,
    /// Set, when keep refuses with `WouldHide`, to each place its new block
    /// lines would hide, in any working tree but the path itself, that
    /// cannot be set aside whole, with why (`sweep.Found.why`; `failed`
    /// with the error as its detail for an aside that failed or would leave
    /// something out).
    would_hide: ?*[]const Hidden = null,
    /// The clone's and the key's locks, when the caller already holds
    /// them; keep then takes neither. `LocksNotHeld` when their lock files
    /// are not the ones keep would take for this clone and key
    /// (`ctx.Held.covers`).
    held: ?ctx_mod.Held = null,
    /// Set, when keep of a directory into an existing kept directory
    /// refuses with `KeptCopyDiffers`, to each path (`/`-joined, the kept
    /// path's own included) whose local file differs from what the kept
    /// directory holds there.
    differs: ?*[]const []const u8 = null,
    /// Set, when keep refuses with `Negated`, to the line that makes git
    /// see the path (`clone.negation`).
    negation: ?*clone.Negation = null,
};

pub const KeepOutcome = struct {
    status: enum {
        /// The path is now kept.
        kept,
        /// A healthy link to the kept copy was already there.
        already_kept,
    },
    /// For `kept`: the original's aside entry; null when holt's link to the
    /// kept copy was already there and only a fact naming the path was
    /// missing.
    entry: ?[]const u8 = null,
    /// The aside entry holding a temporary an earlier interrupted keep left
    /// beside the path, set aside and removed first.
    temp_entry: ?[]const u8 = null,
    /// For `kept`: an executable bit of the content could not be given to
    /// the kept copy, whose filesystem refused it. Information only.
    exec_not_kept: bool = false,
    /// For `kept`: staging slots of the key that could not be cleared once
    /// the link was made (`clearStaging`), each left in place. The keep
    /// itself is done.
    staging_left: []const Left = &.{},
    /// What keep found the block hiding, in any working tree but the path
    /// itself: first what the path's new block lines would newly hide, set
    /// aside whole before they were written (`guardLines`); then what the
    /// closing sweep, once the path was linked, found the whole block
    /// hiding that no entry here holds yet (`closingSweep`), set aside as
    /// far as it can be copied, or, for a place that cannot be, reported
    /// with why; a closing sweep that failed is one `failed` place of the
    /// working tree itself. Each place whose entry is null, or that left
    /// something out (`skipped`), is holt's only word on content git may
    /// destroy.
    hidden: []const Hidden = &.{},
};

/// Content a block line hides: the place, and the aside entry holding it
/// (null for a place never copied, `found.why` saying why), with what the
/// entry left out.
pub const Hidden = struct { found: sweep.Found, entry: ?[]const u8 = null, skipped: []const content.Skipped = &.{} };

/// Keeps `rel` of the working tree at `worktree_path`, with `index` the
/// store's keys as loaded at the start of the command, holding the clone's
/// lock (`ctx.lockClone`) and then the key's, or under the locks the
/// caller holds (`opts.held`): records `pending`,
/// creates the key and its record if absent, writes the block, sets the
/// original aside, writes this machine's fact, stages and places the
/// content, replaces the original with the link, and clears `pending`.
/// When holt's link to the kept copy is already there but no fact names
/// the path, this machine's fact for the kept copy is written instead.
/// Every step can be repeated, so rerunning after an interruption finishes
/// the job, settling any temporary the interruption left first. A
/// directory whose kept copy is already a directory (kept whole, or
/// holding kept files below it) is merged into it (`planMerge`): only the
/// files the kept directory lacks are placed, each with a no-replace
/// rename, holt's links inside it to their kept paths are absorbed, and the
/// facts and released markers of paths below it are removed once its own
/// fact covers them; this machine's fact for the merged content then
/// replaces the directory's other facts, whose content it holds. A local
/// file that differs from the kept directory's is `KeptCopyDiffers`,
/// naming each in `opts.differs`, and another machine's content for the
/// directory that may not have arrived (`pendingDownload`) is
/// `KeptElsewhere`. Refuses
/// before writing anything when git is older than `clone.min_git`
/// (`GitTooOld`), when the clone's lock cannot be made
/// (`CloneStateUnwritable`), when `opts.held` holds other lock files than
/// this clone's and key's (`LocksNotHeld`), when the path is invalid or a
/// file git reads only as a regular file (`GitReadsUnlinked`,
/// `paths.keepable`), collides with a kept path, enters or contains a
/// nested key, or is tracked; when a negated
/// gitignore line that outranks the block makes git see it (`Negated`,
/// naming the line in `opts.negation`); when it is a directory holding
/// a name a kept path may not have (a `.holt-` name, a nested repository, a
/// backslash, a control character; `InvalidName`); when the key's record
/// cannot be used; when the clone does not match its `local/` key; when
/// this machine cannot create symlinks; when another machine's fact names
/// the path but no kept copy is here yet (`KeptElsewhere`, which nothing
/// but retiring that machine overrides, `store.factRetired`); when the
/// kept copy holds different content, which also clears an interrupted
/// keep's `pending` so reconcile reports the difference; when git finds
/// the main working tree's files in another directory than the one holding
/// the common directory (`WorktreeElsewhere`); when the clone's working
/// trees cannot be read (`WorktreeListFailed`); and when the path's new
/// block lines would hide, in any working tree but the path itself, a
/// place that cannot be set aside whole, or a working tree git records
/// cannot be swept (`WouldHide`, naming each in `opts.would_hide`).
/// Otherwise what the new lines would hide there is set aside first, and
/// only then are they written. Once the link is made, under the same locks,
/// keep runs reconcile's closing sweep over every working tree
/// (`closingSweep`), and returns what both set aside or reported
/// (`hidden`). Once linked, keep fails only when memory runs out or at
/// clearing `pending`: a staging slot that cannot be cleared is reported in
/// `staging_left`, and a closing sweep that fails in `hidden` as a
/// `failed` place of the working tree itself, the error its detail.
pub fn keepPath(ctx: Ctx, index: *const store.KeyIndex, worktree_path: []const u8, rel: []const u8, opts: KeepOptions) !KeepOutcome {
    const a = ctx.alloc;
    try clone.requireGit(a);
    if (paths.keepable(rel)) |inv| return if (inv == .git_reads_unlinked) error.GitReadsUnlinked else error.InvalidPath;
    const c = try clone.inspect(a, worktree_path, ctx.code_root);
    const key = c.key orelse return if (c.worktreeElsewhere()) error.WorktreeElsewhere else error.NotUnderCodeRoot;

    const roots = try clone.rootCommits(a, c.main);
    switch (try store.resolve(a, ctx.layout, index, key, roots)) {
        .own => {},
        .successor => return error.KeySuperseded,
        .awaiting_promote => return error.AwaitingPromote,
    }
    if (try store.nestedKeyAt(a, index, key, rel) != null) return error.NestedKey;

    if (opts.held) |h| if (!try h.covers(ctx, c.common_dir, key)) return error.LocksNotHeld;
    const clone_lock = if (opts.held == null) try ctx_mod.lockClone(ctx, c.common_dir) else null;
    defer if (clone_lock) |l| l.release();
    const lock = if (opts.held == null) try ctx_mod.lockKey(ctx, key) else null;
    defer if (lock) |l| l.release();

    const default_root = try clone.defaultRoot(a, c.main);
    if (store.isLocalKey(key)) {
        if (try store.readRecord(a, ctx.layout, key)) |rec| {
            if (rec.root) |r| if (!paths.contains(roots, r)) return error.LocalMismatch;
        } else if (default_root == null) return error.RootRequired;
    }
    const ks = try store.loadKeyState(a, ctx.layout, key);
    {
        var set: std.ArrayList([]const u8) = .empty;
        try set.appendSlice(a, try ks.keptSet(a));
        if (!paths.contains(set.items, rel)) try set.append(a, rel);
        if (paths.contains(try paths.collisions(a, set.items), rel)) return error.Collision;
    }

    const t: Tree = .{ .ctx = ctx, .c = c, .key = key, .chain = &.{key}, .roots = try store.syncedRoots(a, ctx.layout) };
    const src = try t.at(rel);
    const target = try ctx.layout.copyPath(a, key, rel);
    if (!try link.parentsReal(a, c.worktree, rel)) return error.ParentNotDir;
    if ((try clone.tracked(a, c.worktree, &.{rel}))[0] != .none) return error.Tracked;
    if (try clone.negation(a, c, rel)) |n| {
        if (opts.negation) |out| out.* = n;
        return error.Negated;
    }

    const pending = clone.findPending(try clone.readPending(a, c.common_dir), c.tree, rel);
    const settled = try settleTemp(t, rel, if (pending) |p| p.op else null);
    if (settled.how == .stuck) return error.TempStranded;
    const local_dir = switch (try link.classify(a, src, target, &.{key}, t.roots, rel)) {
        .right => {
            if (pending != null) try clone.clearPending(a, c.common_dir, c.tree, rel);
            if (ks.factsFor(rel).len > 0 or ks.isReleased(rel)) return .{ .status = .already_kept, .temp_entry = settled.entry };
            const h = try content.hashPath(a, target);
            try ctx_mod.writeOwnFact(ctx, key, rel, h.kind, &h.hex);
            return .{ .status = .kept, .temp_entry = settled.entry };
        },
        .holt => return error.LinkedElsewhere,
        .foreign => return error.SymlinkNotHolts,
        .absent => return error.FileNotFound,
        .local => |e| switch (e) {
            .other => return error.NotRegular,
            .dir => blk: {
                const bad = try content.invalidNames(a, src);
                if (bad.len > 0) {
                    if (opts.invalid_names) |out| out.* = bad;
                    return error.InvalidName;
                }
                break :blk true;
            },
            else => false,
        },
    };

    const merge: ?Merge = if (local_dir and try content.entryAt(target) == .dir) try planMerge(t, rel, src, target) else null;
    if (merge) |m| {
        if (m.differs.len > 0) {
            if (opts.differs) |out| out.* = m.differs;
            return abandon(t, rel, pending != null);
        }
        if (try pendingDownload(ctx, key, ks.factsFor(rel), m.kept_hash)) return error.KeptElsewhere;
    }
    const src_hash = if (merge) |m| m.src_hash else try content.hashPath(a, src);
    if (merge != null) {} else if (try content.entryAt(target) != .absent) {
        if (!equalHash(try content.hashPath(a, target), src_hash)) return abandon(t, rel, pending != null);
    } else if (pending == null) {
        if (try pendingDownload(ctx, key, ks.factsFor(rel), null)) return error.KeptElsewhere;
    }
    content.probeLink(a, try clone.stateDir(a, c.common_dir), src_hash.kind) catch |err| switch (err) {
        error.SymlinkPrivilege => return error.NoSymlinkPrivilege,
        else => return err,
    };
    _ = try store.checkKey(a, ctx.layout, index, key, default_root, roots);
    _ = clone.worktrees(a, c) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.WorktreeListFailed,
    };
    const temp_line = try paths.tempRel(a, rel);
    const guarded = try guardLines(ctx, c, key, rel, temp_line, opts);

    // Writing the fact can fail once the fact is on disk, so the rollback
    // covers only what comes before it; a later failure is an interrupted
    // keep, finished by keeping again.
    const entry = window: {
        var added: Added = .{ .pending = pending == null };
        errdefer |err| if (err != error.Interrupted and err != error.OutOfMemory) rollBack(a, c, rel, temp_line, added);
        try clone.addPending(a, c.common_dir, .{ .tree = c.tree, .rel = rel, .op = .keep, .worktree = c.worktree });
        try interrupt.check(.keep_pending);

        _ = try store.ensureKey(a, ctx.layout, index, key, try clone.originUrl(a, c.main), default_root, roots);
        try interrupt.check(.keep_key);

        const before = try block.read(a, c.common_dir);
        added.line = !paths.contains(before.rels, rel);
        added.temp = !paths.contains(before.temps, temp_line);
        try block.add(a, c.common_dir, &.{ rel, temp_line });
        try interrupt.check(.keep_block);

        if (merge) |m| for (m.absorbed) |l| {
            _ = try content.removeLinkIf(a, try fsutil.joinSlashy(a, src, l.sub), l.raw);
        };
        const got = try aside.ensureAside(a, ctx.layout, c.common_dir, ctx.machine_id, key, rel, src, .keep, .whole);
        try interrupt.check(.keep_aside);
        break :window got;
    };

    if (merge) |m| {
        if (equalHash(m.merged_hash, m.kept_hash)) {
            try ctx_mod.writeOwnFact(ctx, key, rel, .dir, &m.merged_hash.hex);
        } else try ctx_mod.replaceOwnFacts(ctx, key, rel, .dir, &m.merged_hash.hex);
    } else try ctx_mod.writeOwnFact(ctx, key, rel, src_hash.kind, &src_hash.hex);
    try store.removeReleased(a, ctx.layout, key, rel);
    try interrupt.check(.keep_fact);

    if (merge) |m| {
        for (m.place) |f| {
            const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, f.path });
            const staged = try stage(a, ctx.layout, ctx.machine_id, key, try fsutil.joinSlashy(a, src, f.path));
            placeNew(a, ctx.layout, key, full, staged) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    const now = (try hashOrNull(a, try ctx.layout.copyPath(a, key, full))) orelse return abandon(t, rel, true);
                    if (now.kind != .file or !std.mem.eql(u8, &now.hex, &f.hex)) return abandon(t, rel, true);
                },
                else => return err,
            };
            try interrupt.check(.keep_merged);
        }
        const below = try std.mem.concat(a, u8, &.{ rel, "/" });
        for (try ks.namedPaths(a)) |named| {
            if (!std.mem.startsWith(u8, named, below)) continue;
            try store.removeFacts(a, ctx.layout, key, named);
            try store.removeReleased(a, ctx.layout, key, named);
        }
    } else if (try content.entryAt(target) == .absent) {
        const staged = try stage(a, ctx.layout, ctx.machine_id, key, src);
        placeNew(a, ctx.layout, key, rel, staged) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (!equalHash(try content.hashPath(a, target), src_hash)) return abandon(t, rel, true);
            },
            else => return err,
        };
    }
    try interrupt.check(.keep_place);

    const exec_kept = replaceWithLink(t, rel, target, src_hash) catch |err| switch (err) {
        error.SymlinkPrivilege => return error.NoSymlinkPrivilege,
        else => return err,
    };
    try interrupt.check(.keep_link);

    try clone.clearPending(a, c.common_dir, c.tree, rel);
    const left = clearStaging(a, ctx.layout, ctx.machine_id, key) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try a.dupe(Left, &.{.{ .slot = try ctx.layout.stagingDir(a, ctx.machine_id, key), .reason = @errorName(err) }}),
    };
    dropTempLine(a, c, temp_line) catch |err| if (err == error.OutOfMemory) return err;
    const hidden = closingSweep(ctx, c, key, rel, temp_line, guarded) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try std.mem.concat(a, Hidden, &.{ guarded, &.{.{ .found = .{ .worktree = c.worktree, .rel = ".", .entry = .other, .why = .failed, .detail = @errorName(err) } }} }),
    };
    try interrupt.check(.keep_clear);
    return .{ .status = .kept, .entry = entry.stamp, .temp_entry = settled.entry, .exec_not_kept = !exec_kept, .staging_left = left, .hidden = hidden };
}

/// Whether another machine's content for a path, named by one of `facts`,
/// may not have reached this machine yet: the kept copy (hashing to
/// `kc_hash`, null when absent) is absent while another machine's fact
/// names the path, or holds other content than such a fact records and no
/// aside entry here verifies with that content. A fact its machine's
/// retirement covers (`store.factRetired`) stands for nothing still on its
/// way.
pub fn pendingDownload(ctx: Ctx, key: []const u8, facts: []const store.Fact, kc_hash: ?content.Hash) !bool {
    return try awaitedFact(ctx, key, facts, kc_hash) != null;
}

/// The first of `facts` whose content may not have reached this machine
/// yet, as `pendingDownload` judges it; null when none.
pub fn awaitedFact(ctx: Ctx, key: []const u8, facts: []const store.Fact, kc_hash: ?content.Hash) !?store.Fact {
    const a = ctx.alloc;
    for (facts) |f| {
        if (std.mem.eql(u8, f.machine, ctx.machine_id)) continue;
        if (try store.factRetired(a, ctx.layout, key, f)) continue;
        const kh = kc_hash orelse return f;
        if (kh.kind == f.kind and std.mem.eql(u8, &kh.hex, f.sha256)) continue;
        const held = for (try aside.findEntries(a, ctx.layout, key, f.rel, f.sha256)) |stamp| {
            if (try aside.verify(a, ctx.layout, stamp) == .ok) break true;
        } else false;
        if (!held) return f;
    }
    return null;
}

/// A keep of a local directory into an existing kept directory, as
/// `planMerge` finds it.
const Merge = struct {
    /// The local directory's content once the links in `absorbed` are
    /// gone.
    src_hash: content.Hash,
    /// The kept directory's content as it is.
    kept_hash: content.Hash,
    /// The kept directory's content once `place` is in it.
    merged_hash: content.Hash,
    /// The local files the kept directory lacks, under the directory.
    place: []const content.FileHash,
    /// holt's links inside the local directory to kept paths below it.
    absorbed: []const Absorbed,
    /// Paths, the kept path's own included, whose local file differs from
    /// what the kept directory holds there, or where one side holds a file
    /// and the other a directory.
    differs: []const []const u8,

    const Absorbed = struct { sub: []const u8, raw: []const u8 };
};

/// How keeping the local directory `src` merges it into the kept directory
/// `target` of `rel`: each local file the kept directory lacks is placed,
/// a file both hold alike stays, and one they hold differently is listed
/// in `differs`. A link inside `src` is absorbed when it is holt's link to
/// the kept copy of the path it stands at, inside `target`: it holds no
/// content, and another machine's merge may already have removed that
/// path's facts. Any other link or special file is `NotRegular`, an
/// online-only file `OnlineOnly`, and a kept directory holding such an
/// entry `KeptNotRegular` or `KeptOnlineOnly`.
fn planMerge(t: Tree, rel: []const u8, src: []const u8, target: []const u8) !Merge {
    const a = t.ctx.alloc;
    const part = try content.treeFilesPartial(a, src, false, try clone.ignoresCase(a, t.c.worktree));
    var absorbed: std.ArrayList(Merge.Absorbed) = .empty;
    for (part.skipped) |sk| switch (sk.why) {
        .symlink => {
            const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, sk.path });
            switch (try link.classify(a, try fsutil.joinSlashy(a, src, sk.path), try t.ctx.layout.copyPath(a, t.key, full), t.chain, t.roots, full)) {
                .right => |raw| try absorbed.append(a, .{ .sub = sk.path, .raw = raw }),
                else => return error.NotRegular,
            }
        },
        .online_only => return error.OnlineOnly,
        else => return error.NotRegular,
    };
    const kept_files = content.treeFiles(a, target) catch |err| switch (err) {
        error.NotRegular => return error.KeptNotRegular,
        error.OnlineOnly => return error.KeptOnlineOnly,
        else => return err,
    };
    var kept_map: std.StringHashMapUnmanaged([64]u8) = .empty;
    for (kept_files) |kf| try kept_map.put(a, kf.path, kf.hex);

    var place_list: std.ArrayList(content.FileHash) = .empty;
    var differs: std.ArrayList([]const u8) = .empty;
    next: for (part.files) |f| {
        if (kept_map.get(f.path)) |hex| {
            if (!std.mem.eql(u8, &hex, &f.hex)) try differs.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, f.path }));
            continue;
        }
        var end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, f.path, end, '/')) |slash| : (end = slash + 1) {
            if (kept_map.contains(f.path[0..slash])) {
                try differs.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, f.path }));
                continue :next;
            }
        }
        if (try content.entryAt(try fsutil.joinSlashy(a, target, f.path)) != .absent) {
            try differs.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, f.path }));
            continue;
        }
        try place_list.append(a, f);
    }
    const merged = try std.mem.concat(a, content.FileHash, &.{ kept_files, place_list.items });
    std.mem.sort(content.FileHash, merged, {}, content.fileLess);
    return .{
        .src_hash = .{ .kind = .dir, .hex = content.treeHash(part.files) },
        .kept_hash = .{ .kind = .dir, .hex = content.treeHash(kept_files) },
        .merged_hash = .{ .kind = .dir, .hex = content.treeHash(merged) },
        .place = place_list.items,
        .absorbed = absorbed.items,
        .differs = differs.items,
    };
}

/// Drops the block line of the temporary `temp` a keep or a take used,
/// unless it is still in use (`clone.tempInUse`). A line that cannot be
/// judged or dropped stays for reconcile's upkeep, since it hides nothing
/// while no temporary is there.
pub fn dropTempLine(a: std.mem.Allocator, c: clone.Clone, temp: []const u8) !void {
    const trees = clone.worktrees(a, c) catch null;
    if (!try clone.tempInUse(a, trees, try clone.readPending(a, c.common_dir), temp)) try block.drop(a, c.common_dir, temp);
}

/// What a keep added before writing its fact.
const Added = struct { pending: bool, line: bool = false, temp: bool = false };

/// Undoes what a keep that failed before writing its fact `added`: `rel`'s
/// block line, then its pending record, then its temporary's line. When
/// the line cannot be dropped it stops, leaving the pending record, so the
/// path stays a keep that keeping again finishes.
fn rollBack(a: std.mem.Allocator, c: clone.Clone, rel: []const u8, temp: []const u8, added: Added) void {
    if (added.line) block.drop(a, c.common_dir, rel) catch return;
    if (added.pending) clone.clearPending(a, c.common_dir, c.tree, rel) catch {};
    if (added.temp) dropTempLine(a, c, temp) catch {};
}

/// Whether `f` is the unit keep itself sets aside: `rel`, spelled as keep
/// was given it, or its temporary `temp`, in `c`'s own working tree.
fn ownUnit(c: clone.Clone, f: sweep.Found, rel: []const u8, temp: []const u8) bool {
    if (!std.mem.eql(u8, f.worktree, c.worktree)) return false;
    if (f.temp) |t| return std.mem.eql(u8, t, temp);
    return f.line == null and std.mem.eql(u8, f.rel, rel);
}

/// Whether `list` already reports the place `f` names: with the aside entry
/// `entry`, or, for a null `entry`, at all.
fn reported(list: []const Hidden, f: sweep.Found, entry: ?[]const u8) bool {
    for (list) |h| {
        if (!std.mem.eql(u8, h.found.worktree, f.worktree) or !std.mem.eql(u8, h.found.rel, f.rel)) continue;
        if (!std.mem.eql(u8, h.found.temp orelse "", f.temp orelse "")) continue;
        const e = entry orelse return true;
        if (h.entry != null and std.mem.eql(u8, h.entry.?, e)) return true;
    }
    return false;
}

/// Reconcile's closing sweep (`sweep.Scope.hiddenByBlock`), run by keep
/// and the takes once `rel` is linked, under the key's lock they hold: what the whole
/// block hides in every working tree of the clone, but the unit keep itself
/// set aside (`ownUnit`), is set aside as far as it can be copied, and a
/// place that cannot be (`sweep.Found.why`; `failed` with the error for an
/// aside that fails) is reported. Returns `guarded` followed by each place
/// it does not already report with the same entry.
pub fn closingSweep(ctx: Ctx, c: clone.Clone, key: []const u8, rel: []const u8, temp: []const u8, guarded: []const Hidden) ![]const Hidden {
    const a = ctx.alloc;
    const scope = try sweep.Scope.load(ctx, c, key, key, true);
    var out: std.ArrayList(Hidden) = .empty;
    try out.appendSlice(a, guarded);
    for (try scope.hiddenByBlock(null)) |f| {
        if (ownUnit(c, f, rel, temp)) continue;
        if (f.why != null) {
            if (!reported(out.items, f, null)) try out.append(a, .{ .found = f });
            continue;
        }
        const how: aside.Coverage = .{ .partial = .{ .ignore_case = try clone.ignoresCase(a, f.worktree) } };
        const e = aside.ensureAside(a, ctx.layout, c.common_dir, ctx.machine_id, key, f.rel, try f.path(a), .hidden, how) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                var g = f;
                g.why = if (err == error.NestedRepository) .nested_repository else .failed;
                g.detail = @errorName(err);
                if (!reported(out.items, g, null)) try out.append(a, .{ .found = g });
                continue;
            },
        };
        if (!reported(out.items, f, e.stamp)) try out.append(a, .{ .found = f, .entry = e.stamp, .skipped = e.skipped });
    }
    return out.items;
}

/// What adding the block lines for `rel` and its temporary `temp` would
/// newly hide in every working tree of the clone
/// (`sweep.Scope.newlyHiddenAll`), but the unit keep itself sets aside
/// (`ownUnit`), set aside whole before either is written, so no line keep
/// adds hides an only copy, even for a moment: in another working tree, or
/// in this one under another spelling git's `core.ignorecase` folds onto
/// `rel`. Each place is returned with its entry. A directory is set aside
/// but for holt's own links in it, which hold no content, as another
/// working tree holds kept files of a directory kept since file by file.
/// When a place cannot be set aside whole (a place never copied,
/// `sweep.Why`; an aside that fails or would leave anything else out),
/// nothing more is set aside, the places are
/// given in `opts.would_hide`, and `WouldHide` returned. Lines already in
/// the block are not asked about.
pub fn guardLines(ctx: Ctx, c: clone.Clone, key: []const u8, rel: []const u8, temp: []const u8, opts: KeepOptions) ![]const Hidden {
    const a = ctx.alloc;
    const before = try block.read(a, c.common_dir);
    var new_rels: std.ArrayList([]const u8) = .empty;
    var new_temps: std.ArrayList([]const u8) = .empty;
    if (!paths.contains(before.rels, rel)) try new_rels.append(a, rel);
    if (!paths.contains(before.temps, temp)) try new_temps.append(a, temp);
    if (new_rels.items.len + new_temps.items.len == 0) return &.{};
    const scope = try sweep.Scope.load(ctx, c, key, key, true);
    var found: std.ArrayList(sweep.Found) = .empty;
    for (try scope.newlyHiddenAll(.{ .rels = before.rels, .temps = before.temps, .foreign = before.foreign }, .{ .rels = new_rels.items, .temps = new_temps.items }, null)) |f| {
        if (!ownUnit(c, f, rel, temp)) try found.append(a, f);
    }

    var blocked: std.ArrayList(Hidden) = .empty;
    for (found.items) |f| if (f.why != null) try blocked.append(a, .{ .found = f });
    var out: std.ArrayList(Hidden) = .empty;
    if (blocked.items.len == 0) for (found.items) |f| {
        if (f.entry != .file and f.entry != .dir) continue;
        const how: aside.Coverage = if (f.entry == .dir and f.temp == null) .{ .partial = .{ .ignore_case = try clone.ignoresCase(a, f.worktree) } } else .whole;
        const e = aside.ensureAside(a, ctx.layout, c.common_dir, ctx.machine_id, key, f.rel, try f.path(a), .hidden, how) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                var g = f;
                g.why = if (err == error.NestedRepository) .nested_repository else .failed;
                g.detail = @errorName(err);
                try blocked.append(a, .{ .found = g });
                break;
            },
        };
        for (e.skipped) |sk| {
            const at = try fsutil.joinSlashy(a, f.worktree, sk.path);
            if (sk.why == .symlink) if (try content.readLink(a, at)) |raw| if (link.isHolt(a, at, raw, scope.chain, scope.roots, sk.path)) continue;
            var g = f;
            g.rel = sk.path;
            g.temp = null;
            g.entry = try content.entryAt(at);
            g.why = switch (sk.why) {
                .symlink, .not_regular => .not_copyable,
                .nested_repository => .nested_repository,
                else => .failed,
            };
            g.detail = @tagName(sk.why);
            try blocked.append(a, .{ .found = g });
        }
        if (blocked.items.len > 0) break;
        try out.append(a, .{ .found = f, .entry = e.stamp });
    };
    if (blocked.items.len > 0) {
        if (opts.would_hide) |w| w.* = blocked.items;
        return error.WouldHide;
    }
    return out.items;
}

/// Gives up a keep whose kept copy holds different content: the keep's
/// `pending` is cleared, so reconcile evaluates the path and names the
/// `--take-*` commands, and `KeptCopyDiffers` returned.
fn abandon(t: Tree, rel: []const u8, had_pending: bool) !KeepOutcome {
    if (had_pending) {
        try clone.clearPending(t.ctx.alloc, t.c.common_dir, t.c.tree, rel);
        _ = try clearStaging(t.ctx.alloc, t.ctx.layout, t.ctx.machine_id, t.key);
    }
    return error.KeptCopyDiffers;
}

const Fixture = @import("harness.zig").Fixture;

const mid = "0123456789abcdef";
const test_key = "github.com/acme/widget";

test "stage and placeNew: a new path lands whole; an occupied one is a conflict and nothing moves" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };

    const src = try f.write("clone/.clasp.json", "mine");
    const staged = try stage(a, layout, mid, test_key, src);
    try placeNew(a, layout, test_key, "sub/.clasp.json", staged);
    try testing.expectEqualStrings("mine", try content.readSmall(a, try layout.copyPath(a, test_key, "sub/.clasp.json")));

    const again = try stage(a, layout, mid, test_key, try f.write("clone/other", "theirs"));
    try testing.expectError(error.PathAlreadyExists, placeNew(a, layout, test_key, "sub/.clasp.json", again));
    try testing.expectEqualStrings("mine", try content.readSmall(a, try layout.copyPath(a, test_key, "sub/.clasp.json")));
    try testing.expectEqualStrings("theirs", try content.readSmall(a, again.path));

    try testing.expectEqual(@as(usize, 0), (try clearStaging(a, layout, mid, test_key)).len);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.stagingDir(a, mid, test_key)));
}

test "placeNew: refuses a kept parent that is not a real directory" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    _ = try f.write("synced/kept/github.com/acme/widget/sub", "a file");
    const staged = try stage(a, layout, mid, test_key, try f.write("clone/x", "x"));
    try testing.expectError(error.ParentNotDir, placeNew(a, layout, test_key, "sub/x", staged));
}

test "replaceKept: the old file and the old directory go to aside and the new content takes their place" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };

    _ = try f.write("synced/kept/github.com/acme/widget/.env", "old");
    const fe = (try replaceKept(a, layout, mid, test_key, ".env", try stage(a, layout, mid, test_key, try f.write("clone/.env", "new")))).?;
    try testing.expectEqualStrings("new", try content.readSmall(a, try layout.copyPath(a, test_key, ".env")));
    try testing.expectEqualStrings("old", try content.readSmall(a, try aside.dataPath(a, layout, fe.stamp, ".env")));

    _ = try f.write("synced/kept/github.com/acme/widget/.superpowers/a", "old-a");
    _ = try f.write("clone/.superpowers/a", "new-a");
    _ = try f.write("clone/.superpowers/b", "new-b");
    const de = (try replaceKept(a, layout, mid, test_key, ".superpowers", try stage(a, layout, mid, test_key, try fsutil.joinSlashy(a, f.root, "clone/.superpowers")))).?;
    try testing.expectEqualStrings("new-b", try content.readSmall(a, try layout.copyPath(a, test_key, ".superpowers/b")));
    try testing.expectEqualStrings("old-a", try content.readSmall(a, try aside.dataPath(a, layout, de.stamp, ".superpowers/a")));
    try testing.expectEqual(aside.Check.ok, try aside.verify(a, layout, de.stamp));
}

test "replaceKept: without an exchange rename the old directory still ends in aside, verified" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    content.no_exchange_for_test = true;
    defer content.no_exchange_for_test = false;

    _ = try f.write("synced/kept/github.com/acme/widget/.superpowers/a", "old-a");
    _ = try f.write("clone/.superpowers/b", "new-b");
    const e = (try replaceKept(a, layout, mid, test_key, ".superpowers", try stage(a, layout, mid, test_key, try f.path("clone/.superpowers")))).?;
    try testing.expectEqualStrings("new-b", try content.readSmall(a, try layout.copyPath(a, test_key, ".superpowers/b")));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.copyPath(a, test_key, ".superpowers/a")));
    try testing.expectEqual(aside.Check.ok, try aside.verify(a, layout, e.stamp));

    _ = try f.write("clone/.env/inner", "now a directory");
    _ = try f.write("synced/kept/github.com/acme/widget/.env", "was a file");
    const fe = (try replaceKept(a, layout, mid, test_key, ".env", try stage(a, layout, mid, test_key, try f.path("clone/.env")))).?;
    try testing.expectEqualStrings("now a directory", try content.readSmall(a, try layout.copyPath(a, test_key, ".env/inner")));
    try testing.expectEqualStrings("was a file", try content.readSmall(a, try aside.dataPath(a, layout, fe.stamp, ".env")));
}

test "replaceKept interrupted at every point: the old copy is always in kept or in a verified aside entry" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    defer interrupt.at = null;
    defer content.no_exchange_for_test = false;

    const points = [_]interrupt.Point{ .aside_copied, .aside_manifest, .replace_aside, .replace_checked, .replace_moved_out, .replace_swapped };
    for ([_]bool{ false, true }) |no_exchange| {
        for (points, 0..) |point, i| {
            if (point == .replace_moved_out and !no_exchange) continue;
            const synced = try std.fmt.allocPrint(a, "synced-{d}-{}", .{ i, no_exchange });
            const layout: Layout = .{ .synced_root = try f.path(synced) };
            _ = try f.write(try std.fmt.allocPrint(a, "{s}/kept/{s}/d/old", .{ synced, test_key }), "old");
            _ = try f.write(try std.fmt.allocPrint(a, "{s}-clone/d/new", .{synced}), "new");
            const staged = try stage(a, layout, mid, test_key, try f.path(try std.fmt.allocPrint(a, "{s}-clone/d", .{synced})));

            content.no_exchange_for_test = no_exchange;
            interrupt.at = point;
            try testing.expectError(error.Interrupted, replaceKept(a, layout, mid, test_key, "d", staged));
            interrupt.at = null;
            content.no_exchange_for_test = false;

            const in_kept = if (content.readSmall(a, try layout.copyPath(a, test_key, "d/old"))) |got| std.mem.eql(u8, got, "old") else |_| false;
            var in_aside = false;
            var d = std.Io.Dir.cwd().openDir(io(), try layout.asideDir(a), .{ .iterate = true }) catch null;
            if (d) |*dir| {
                defer dir.close(io());
                var it = dir.iterate();
                while (try it.next(io())) |entry| {
                    if (try aside.verify(a, layout, entry.name) == .ok) in_aside = true;
                }
            }
            try testing.expect(in_kept or in_aside);
        }
    }
}

/// A working tree at `<root>/clone` whose common directory is
/// `<root>/clone/.git`, under a synced root at `<root>/synced`; enough for
/// the working-tree writes, which read nothing from git.
fn testTree(f: *Fixture) !Tree {
    const a = f.alloc();
    const worktree = try f.path("clone");
    const common = try f.path("clone/.git");
    try fsutil.ensureDir(common);
    const map = try a.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(a);
    try map.put("HOME", f.root);
    try map.put("XDG_STATE_HOME", try f.path("state"));
    return .{
        .ctx = .{ .alloc = a, .env = .{ .map = map }, .layout = .{ .synced_root = try f.path("synced") }, .code_root = f.root, .machine_id = mid },
        .c = .{ .worktree = worktree, .git_dir = common, .common_dir = common, .tree = ".", .main = worktree, .main_toplevel = worktree, .key = test_key },
        .key = test_key,
        .chain = &.{test_key},
        .roots = &.{try f.path("synced")},
    };
}

test "replaceWithLink: content that changed after it was hashed is moved back, not deleted" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const t = try testTree(&f);
    const p = try f.write("clone/f", "before");
    const target = try f.write("synced/kept/k/r/f", "before");
    const stale = try content.hashPath(a, try f.write("elsewhere", "different"));
    try testing.expectError(error.ChangedDuringLink, replaceWithLink(t, "f", target, stale));
    try testing.expectEqual(content.Entry.file, try content.entryAt(p));
    try testing.expectEqualStrings("before", try content.readSmall(a, p));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try t.tempPath("f")));

    _ = try replaceWithLink(t, "f", target, try content.hashPath(a, p));
    try testing.expectEqualStrings(target, (try content.readLink(a, p)).?);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try t.tempPath("f")));
}

test "replaceWithLink: the link is judged by what it reads back, so content that changed is still moved back when the link is stored in another spelling" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const t = try testTree(&f);
    const p = try f.write("clone/f", "before");
    const target = try f.write("synced/kept/k/r/f", "before");
    const stale = try content.hashPath(a, try f.write("elsewhere", "different"));
    content.respell_links_for_test = true;
    defer content.respell_links_for_test = false;
    try testing.expectError(error.ChangedDuringLink, replaceWithLink(t, "f", target, stale));
    try testing.expectEqual(content.Entry.file, try content.entryAt(p));
    try testing.expectEqualStrings("before", try content.readSmall(a, p));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try t.tempPath("f")));
}

test "replaceWithLink: the kept copy gains the executable bits of the content it replaces" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const t = try testTree(&f);
    const cwd = std.Io.Dir.cwd();
    const p = try f.write("clone/run.sh", "#!/bin/sh\n");
    const d = try f.write("clone/bin/tool", "tool");
    const target = try f.write("synced/kept/k/r/run.sh", "#!/bin/sh\n");
    const dtarget = try f.write("synced/kept/k/r/bin/tool", "tool");
    for ([_][]const u8{ p, d }) |x| try cwd.setFilePermissions(io(), x, @enumFromInt(0o755), .{});
    for ([_][]const u8{ target, dtarget }) |x| try cwd.setFilePermissions(io(), x, @enumFromInt(0o644), .{});

    try testing.expect(try replaceWithLink(t, "run.sh", target, try content.hashPath(a, p)));
    try testing.expect(try replaceWithLink(t, "bin", std.fs.path.dirname(dtarget).?, try content.hashPath(a, try f.path("clone/bin"))));
    for ([_][]const u8{ target, dtarget }) |x| {
        const mode = @intFromEnum((try cwd.statFile(io(), x, .{})).permissions);
        try testing.expectEqual(@as(@TypeOf(mode), 0o755), mode & 0o777);
    }
}

var cloud_write_path: []const u8 = "";

fn cloudWrite(p: interrupt.Point) void {
    if (p != .replace_checked) return;
    std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = cloud_write_path, .data = "cloud edit" }) catch unreachable;
}

test "replaceKept: a write reaching the old file after it was set aside is set aside too" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    const p1 = try f.write("probe/one", "1");
    const p2 = try f.write("probe/two", "2");
    content.renameExchange(a, p1, p2) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };

    const dest = try f.write("synced/kept/github.com/acme/widget/.env", "old");
    cloud_write_path = dest;
    interrupt.hook = cloudWrite;
    defer interrupt.hook = null;
    _ = (try replaceKept(a, layout, mid, test_key, ".env", try stage(a, layout, mid, test_key, try f.write("clone/.env", "new")))).?;
    interrupt.hook = null;
    try testing.expectEqualStrings("new", try content.readSmall(a, dest));

    var found = false;
    var dir = try std.Io.Dir.cwd().openDir(io(), try layout.asideDir(a), .{ .iterate = true });
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |entry| {
        if (try aside.verify(a, layout, entry.name) != .ok) continue;
        if (std.mem.eql(u8, try content.readSmall(a, try aside.dataPath(a, layout, entry.name, ".env")), "cloud edit")) found = true;
    }
    try testing.expect(found);
}

var late_write_path: []const u8 = "";
var late_written = false;

fn lateWrite(p: interrupt.Point) void {
    if (p == .replace_checked) {
        std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = cloud_write_path, .data = "cloud edit" }) catch unreachable;
        return;
    }
    if (p != .aside_manifest or late_written) return;
    var buf: [64]u8 = undefined;
    const got = std.Io.Dir.cwd().readFile(io(), late_write_path, &buf) catch return;
    if (!std.mem.eql(u8, got, "cloud edit")) return;
    std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = late_write_path, .data = "late edit" }) catch unreachable;
    late_written = true;
}

/// True when a verified aside entry for `rel` holds `data` at `probe`.
fn asideHolds(alloc: std.mem.Allocator, layout: Layout, rel: []const u8, probe: []const u8, data: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io(), try layout.asideDir(alloc), .{ .iterate = true }) catch return false;
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |entry| {
        const m = (try aside.readManifest(alloc, layout, entry.name)) orelse continue;
        if (!std.mem.eql(u8, m.rel, rel) or try aside.verify(alloc, layout, entry.name) != .ok) continue;
        const got = content.readSmall(alloc, try aside.dataPath(alloc, layout, entry.name, probe)) catch continue;
        if (std.mem.eql(u8, got, data)) return true;
    }
    return false;
}

test "replaceKept: the swapped-out copy is hashed again right before it is removed, and set aside again while it keeps changing" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const layout: Layout = .{ .synced_root = try f.path("synced") };
    const p1 = try f.write("probe/one", "1");
    const p2 = try f.write("probe/two", "2");
    content.renameExchange(a, p1, p2) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };

    const dest = try f.write("synced/kept/github.com/acme/widget/.env", "old");
    const staged = try stage(a, layout, mid, test_key, try f.write("clone/.env", "new"));
    cloud_write_path = dest;
    late_write_path = staged.path;
    late_written = false;
    interrupt.hook = lateWrite;
    defer interrupt.hook = null;
    _ = (try replaceKept(a, layout, mid, test_key, ".env", staged)).?;
    interrupt.hook = null;
    try testing.expect(late_written);
    try testing.expectEqualStrings("new", try content.readSmall(a, dest));
    try testing.expect(try asideHolds(a, layout, ".env", ".env", "cloud edit"));
    try testing.expect(try asideHolds(a, layout, ".env", ".env", "late edit"));
}

test "clearStaging: a swapped-out copy an interruption left in staging is set aside before it is removed" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    defer interrupt.at = null;
    defer interrupt.hook = null;
    defer content.no_exchange_for_test = false;
    const p1 = try f.write("probe/one", "1");
    const p2 = try f.write("probe/two", "2");
    const has_exchange = if (content.renameExchange(a, p1, p2)) true else |err| switch (err) {
        error.Unsupported => false,
        else => return err,
    };

    for ([_]bool{ false, true }) |no_exchange| {
        if (!no_exchange and !has_exchange) continue;
        const synced = try std.fmt.allocPrint(a, "synced-{}", .{no_exchange});
        const layout: Layout = .{ .synced_root = try f.path(synced) };
        cloud_write_path = try f.write(try std.fmt.allocPrint(a, "{s}/kept/{s}/d/old", .{ synced, test_key }), "old");
        _ = try f.write(try std.fmt.allocPrint(a, "{s}-clone/d/new", .{synced}), "new");
        const staged = try stage(a, layout, mid, test_key, try f.path(try std.fmt.allocPrint(a, "{s}-clone/d", .{synced})));

        content.no_exchange_for_test = no_exchange;
        interrupt.hook = cloudWrite;
        interrupt.at = if (no_exchange) .replace_moved_out else .replace_swapped;
        try testing.expectError(error.Interrupted, replaceKept(a, layout, mid, test_key, "d", staged));
        interrupt.at = null;
        interrupt.hook = null;
        content.no_exchange_for_test = false;

        try testing.expect(!try asideHolds(a, layout, "d", "d/old", "cloud edit"));
        try testing.expectEqual(@as(usize, 0), (try clearStaging(a, layout, mid, test_key)).len);
        try testing.expect(try asideHolds(a, layout, "d", "d/old", "cloud edit"));
        try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.stagingDir(a, mid, test_key)));
    }
}

test "clearStaging: a swapped-out copy whose aside entry no longer verifies is set aside again before it is removed" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    defer interrupt.at = null;
    defer content.no_exchange_for_test = false;

    for ([_]bool{ false, true }) |pruned| {
        const synced = try std.fmt.allocPrint(a, "synced-{}", .{pruned});
        const layout: Layout = .{ .synced_root = try f.path(synced) };
        _ = try f.write(try std.fmt.allocPrint(a, "{s}/kept/{s}/d/old", .{ synced, test_key }), "old");
        _ = try f.write(try std.fmt.allocPrint(a, "{s}-clone/d/new", .{synced}), "new");
        const staged = try stage(a, layout, mid, test_key, try f.path(try std.fmt.allocPrint(a, "{s}-clone/d", .{synced})));

        content.no_exchange_for_test = true;
        interrupt.at = .replace_moved_out;
        try testing.expectError(error.Interrupted, replaceKept(a, layout, mid, test_key, "d", staged));
        interrupt.at = null;
        content.no_exchange_for_test = false;

        var dir = try std.Io.Dir.cwd().openDir(io(), try layout.asideDir(a), .{ .iterate = true });
        var it = dir.iterate();
        const stamp = try a.dupe(u8, (try it.next(io())).?.name);
        dir.close(io());
        if (pruned) {
            try std.Io.Dir.cwd().deleteTree(io(), try std.fs.path.join(a, &.{ try layout.asideDir(a), stamp }));
        } else {
            try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try aside.dataPath(a, layout, stamp, "d/old"), .data = "damaged" });
        }
        try testing.expect(!try asideHolds(a, layout, "d", "d/old", "old"));

        try testing.expectEqual(@as(usize, 0), (try clearStaging(a, layout, mid, test_key)).len);
        try testing.expect(try asideHolds(a, layout, "d", "d/old", "old"));
        try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.stagingDir(a, mid, test_key)));
    }
}

test "clearStaging: a swap mark that names no aside entry is taken as unverified, so the copy is set aside again before the slot is cleared" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    defer interrupt.at = null;
    defer content.no_exchange_for_test = false;
    const layout: Layout = .{ .synced_root = try f.path("synced") };

    _ = try f.write("synced/kept/" ++ test_key ++ "/d/old", "old");
    _ = try f.write("clone/d/new", "new");
    const staged = try stage(a, layout, mid, test_key, try f.path("clone/d"));
    content.no_exchange_for_test = true;
    interrupt.at = .replace_moved_out;
    try testing.expectError(error.Interrupted, replaceKept(a, layout, mid, test_key, "d", staged));
    interrupt.at = null;
    content.no_exchange_for_test = false;
    try std.Io.Dir.cwd().deleteTree(io(), try layout.asideDir(a));
    const mark = try std.fs.path.join(a, &.{ std.fs.path.dirname(staged.path).?, swap_mark });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = mark, .data = "{\"name\": \"old\", \"rel\": \"d\"}" });

    try testing.expectEqual(@as(usize, 0), (try clearStaging(a, layout, mid, test_key)).len);
    try testing.expect(try asideHolds(a, layout, "d", "d/old", "old"));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try layout.stagingDir(a, mid, test_key)));
}

test "clearStaging: a slot whose swapped-out copy cannot be set aside is left in place and returned, and the other slots are cleared" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    defer interrupt.at = null;
    defer content.no_exchange_for_test = false;
    const layout: Layout = .{ .synced_root = try f.path("synced") };

    _ = try f.write("synced/kept/" ++ test_key ++ "/d/old", "old");
    _ = try f.write("clone/d/new", "new");
    const staged = try stage(a, layout, mid, test_key, try f.path("clone/d"));
    content.no_exchange_for_test = true;
    interrupt.at = .replace_moved_out;
    try testing.expectError(error.Interrupted, replaceKept(a, layout, mid, test_key, "d", staged));
    interrupt.at = null;
    content.no_exchange_for_test = false;
    try std.Io.Dir.cwd().deleteTree(io(), try layout.asideDir(a));
    const other = try stage(a, layout, mid, test_key, try f.write("clone/other", "other"));

    try fsutil.ensureDir(try layout.asideDir(a));
    const asides = try layout.asideDir(a);
    try std.Io.Dir.cwd().setFilePermissions(io(), asides, @enumFromInt(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io(), asides, @enumFromInt(0o755), .{}) catch {};
    const left = try clearStaging(a, layout, mid, test_key);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings(std.fs.path.dirname(staged.path).?, left[0].slot);
    try testing.expectEqualStrings("old", try content.readSmall(a, try std.fs.path.join(a, &.{ left[0].slot, "old", "old" })));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(std.fs.path.dirname(other.path).?));

    try std.Io.Dir.cwd().setFilePermissions(io(), asides, @enumFromInt(0o755), .{});
    try testing.expectEqual(@as(usize, 0), (try clearStaging(a, layout, mid, test_key)).len);
    try testing.expect(try asideHolds(a, layout, "d", "d/old", "old"));
}

const World = @import("harness.zig").World;
const testutil = @import("../testutil.zig");

test "keepPath: a directory holding holt's link to a kept file merges into it: the link is absorbed, the rest placed, and the file's fact gives way to the directory's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write("notes/a", "A");
    _ = try m.keep("notes/a");
    try testing.expect(try m.linked("notes/a"));
    try m.write("notes/sub/b", "B");

    const got = try m.keep("notes");
    try testing.expectEqual(.kept, got.status);
    try testing.expect(try m.linked("notes"));
    try testing.expectEqualStrings("A", try content.readSmall(a, try m.keptPath("notes/a")));
    try testing.expectEqualStrings("B", try content.readSmall(a, try m.keptPath("notes/sub/b")));
    try testing.expectEqualStrings("A", try m.read("notes/a"));
    const ks = try store.loadKeyState(a, m.ctx.layout, test_key);
    try testing.expectEqual(@as(usize, 0), ks.factsFor("notes/a").len);
    try testing.expectEqual(content.Kind.dir, ks.factsFor("notes")[0].kind);
    try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
    try testing.expectEqual(@as(usize, 0), (try clone.readPending(a, try std.fs.path.join(a, &.{ m.clone, ".git" }))).len);
}

test "keepPath: on another machine, holt's link to a file a merge took in gives way to the directory's link, and keeping the directory there too finds it kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write("notes/a", "A");
    _ = try ma.keep("notes/a");
    try w.sync();
    _ = try mb.reconcile();
    try testing.expect(try mb.linked("notes/a"));
    try ma.write("notes/b", "B");
    _ = try ma.keep("notes");
    try w.sync();

    _ = try mb.reconcile();
    try testing.expect(try mb.linked("notes"));
    try testing.expectEqual(.already_kept, (try mb.keep("notes")).status);
    try testing.expectEqualStrings("A", try mb.read("notes/a"));
    try testing.expectEqualStrings("B", try mb.read("notes/b"));
    try testing.expectEqual(@as(usize, 0), (try mb.reconcile()).unsettledCount());
    try w.sync();
    try testing.expectEqual(@as(usize, 0), (try ma.reconcile()).unsettledCount());
}

test "keepPath: a directory whose kept copy came from another machine merges: missing files are placed, alike ones stay, and a differing one refuses naming it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write("notes/x", "x");
    _ = try ma.keep("notes");
    try w.sync();
    try mb.write("notes/x", "x");
    try mb.write("notes/y", "only on b");

    const got = try mb.keep("notes");
    try testing.expectEqual(.kept, got.status);
    try testing.expectEqualStrings("only on b", try content.readSmall(a, try mb.keptPath("notes/y")));
    try testing.expectEqual(@as(usize, 1), (try store.loadKeyState(a, mb.ctx.layout, test_key)).factsFor("notes").len);
    try w.sync();
    try testing.expectEqual(@as(usize, 0), (try ma.reconcile()).unsettledCount());
    try testing.expectEqualStrings("only on b", try ma.read("notes/y"));
    try testing.expectEqual(@as(usize, 0), (try mb.reconcile()).unsettledCount());

    try fsutil.removePath(try mb.path("notes"));
    try mb.write("notes/x", "changed on b");
    try mb.write("notes/z", "new");
    var differs: []const []const u8 = &.{};
    const idx = try store.loadIndex(a, mb.ctx.layout);
    try testing.expectError(error.KeptCopyDiffers, keepPath(mb.ctx, &idx, mb.clone, "notes", .{ .differs = &differs }));
    try testing.expectEqual(@as(usize, 1), differs.len);
    try testing.expectEqualStrings("notes/x", differs[0]);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try mb.keptPath("notes/z")));
    try testing.expectEqualStrings("x", try content.readSmall(a, try mb.keptPath("notes/x")));
}

test "keepPath: a merge into a kept directory whose newer content from another machine has not arrived is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write("notes/x", "x");
    _ = try ma.keep("notes");
    try w.sync();
    const newer = content.treeHash(&.{.{ .path = "x", .hex = try content.hashFile(a, try writeProbe(a, sb.root, "edited on a")) }});
    try store.replaceFacts(a, ma.ctx.layout, test_key, ma.ctx.machine_id, "notes", .dir, &newer);
    try w.deliverPath(0, 1, test_key ++ "/.holt-paths");
    try mb.write("notes/y", "on b");

    const idx = try store.loadIndex(a, mb.ctx.layout);
    try testing.expectError(error.KeptElsewhere, keepPath(mb.ctx, &idx, mb.clone, "notes", .{}));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try mb.keptPath("notes/y")));
}

test "keepPath interrupted at every point of a merge: content stays in place, in kept, or in aside, and rerunning finishes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer interrupt.at = null;
    const points = [_]interrupt.Point{ .keep_pending, .keep_key, .keep_block, .keep_aside, .keep_fact, .stage_copied, .keep_merged, .keep_place, .link_moved, .link_created, .keep_link };
    for (points) |point| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try World.init(a, &sb, 1);
        const m = w.m(0);
        try m.write("notes/a", "A");
        _ = try m.keep("notes/a");
        try m.write("notes/b", "B");
        interrupt.at = point;
        try testing.expectError(error.Interrupted, m.keep("notes"));
        interrupt.at = null;

        const b_local = if (content.readSmall(a, try m.path("notes/b"))) |got| std.mem.eql(u8, got, "B") else |_| false;
        const b_kept = if (content.readSmall(a, try m.keptPath("notes/b"))) |got| std.mem.eql(u8, got, "B") else |_| false;
        const b_temp = if (content.readSmall(a, try fsutil.joinSlashy(a, try m.path(try paths.tempRel(a, "notes")), "b"))) |got| std.mem.eql(u8, got, "B") else |_| false;
        testing.expect(b_local or b_kept or b_temp) catch |err| {
            std.debug.print("lost at {s}\n", .{@tagName(point)});
            return err;
        };
        _ = try m.reconcile();
        _ = try m.keep("notes");
        testing.expect(try m.linked("notes")) catch |err| {
            std.debug.print("not linked after rerun at {s}\n", .{@tagName(point)});
            return err;
        };
        try testing.expectEqualStrings("A", try m.read("notes/a"));
        try testing.expectEqualStrings("B", try m.read("notes/b"));
        try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
    }
}

fn writeProbe(a: std.mem.Allocator, root: []const u8, data: []const u8) ![]const u8 {
    const p = try std.fs.path.join(a, &.{ root, "probe" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = data });
    return p;
}
