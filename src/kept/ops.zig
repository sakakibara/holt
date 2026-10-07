//! The explicit commands beside keeping a path: making the local content,
//! the kept copy, or an aside entry the kept copy of a path (`takeLocal`,
//! `takeKept`, `takeAside`), copying the kept set of a key a repo left
//! behind (`takeFrom`), releasing paths (`unkeep`, `unkeepRepo`), removing
//! a released path's kept content (`purge`), listing and removing aside
//! entries (`asideEntries`, `pruneEntry`), and creating a clone's key
//! (`ensureCloneKey`). Each writer of a working tree holds the clone's lock
//! and then the key's, as `place.keepPath` does, records `pending` before
//! the working tree changes, and sets content aside, verified, before it
//! acts on it. Nothing here prints.

const std = @import("std");
const builtin = @import("builtin");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const aside = @import("aside.zig");
const block = @import("block.zig");
const clone = @import("clone.zig");
const link = @import("link.zig");
const place = @import("place.zig");
const patterns = @import("patterns.zig");
const ctx_mod = @import("ctx.zig");
const interrupt = @import("interrupt.zig");
const testing = std.testing;

const io = fsutil.io;
const Ctx = ctx_mod.Ctx;

const Opened = struct {
    c: clone.Clone,
    /// The key the clone's files live in: its own, or with
    /// `allow_successor` a successor it resolves to.
    key: []const u8,
    roots: []const []const u8,
};

/// The clone containing `path` and the key its files live in, refusing as
/// `place.keepPath` does: `GitTooOld`, `WorktreeElsewhere`,
/// `NotUnderCodeRoot`, `AwaitingPromote`, and, unless `allow_successor`,
/// `KeySuperseded`.
fn openClone(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, allow_successor: bool) !Opened {
    const a = ctx.alloc;
    try clone.requireGit(a);
    const c = try clone.inspect(a, path, ctx.code_root);
    const own = c.key orelse return if (c.worktreeElsewhere()) error.WorktreeElsewhere else error.NotUnderCodeRoot;
    const roots = try clone.rootCommits(a, c.main);
    const key = switch (try store.resolve(a, ctx.layout, index, own, roots)) {
        .own => own,
        .successor => |s| if (allow_successor) s else return error.KeySuperseded,
        .awaiting_promote => return error.AwaitingPromote,
    };
    return .{ .c = c, .key = key, .roots = roots };
}

/// The record of `key`, refusing a key holt must not write to:
/// `NotKept` without one, `UnknownRecordVersion`, and `LocalMismatch` for a
/// `local/` key whose `root` the clone with root commits `roots` lacks.
fn usableRecord(a: std.mem.Allocator, layout: store.Layout, key: []const u8, roots: ?[]const []const u8) !store.Record {
    const rec = (try store.readRecord(a, layout, key)) orelse return error.NotKept;
    if (!rec.known()) return error.UnknownRecordVersion;
    if (roots) |r| if (store.isLocalKey(key)) {
        if (rec.root == null or !paths.contains(r, rec.root.?)) return error.LocalMismatch;
    };
    return rec;
}

/// The kept directory path `rel` lies below, if any.
pub fn keptDirAbove(ks: store.KeyState, rel: []const u8) ?[]const u8 {
    var end: usize = rel.len;
    while (std.mem.lastIndexOfScalar(u8, rel[0..end], '/')) |slash| {
        end = slash;
        const up = rel[0..end];
        const facts = ks.factsFor(up);
        if (facts.len > 0 and !ks.isReleased(up) and facts[0].kind == .dir) return up;
    }
    return null;
}

fn keptHash(a: std.mem.Allocator, target: []const u8) !?content.Hash {
    return switch (try content.entryAt(target)) {
        .absent => if (fsutil.hasIcloudPlaceholder(a, target)) error.KeptOnlineOnly else null,
        .file, .dir => content.hashPath(a, target) catch |err| switch (err) {
            error.OnlineOnly => error.KeptOnlineOnly,
            error.NotRegular => error.KeptNotRegular,
            else => err,
        },
        .symlink, .other => error.KeptNotRegular,
    };
}

pub const TakeOptions = struct {
    /// As `place.KeepOptions.would_hide`.
    would_hide: ?*[]const place.Hidden = null,
    /// As `place.KeepOptions.invalid_names`.
    invalid_names: ?*[]const []const u8 = null,
    /// As `place.KeepOptions.held`.
    held: ?ctx_mod.Held = null,
};

pub const TakeOutcome = struct {
    status: enum {
        /// The path is linked to its kept copy, which now holds what the
        /// command asked for.
        taken,
        /// A healthy link to the kept copy was already there: there was no
        /// local content to take or replace.
        already_linked,
    },
    /// The aside entry holding the local content replaced by the link.
    local_entry: ?[]const u8 = null,
    /// The aside entry holding the kept copy `--take-local` replaced; null
    /// when the kept copy already held the result or was absent.
    kept_entry: ?[]const u8 = null,
    /// As `place.KeepOutcome.temp_entry`.
    temp_entry: ?[]const u8 = null,
    /// As `place.KeepOutcome.exec_not_kept`.
    exec_not_kept: bool = false,
    /// As `place.KeepOutcome.staging_left`.
    staging_left: []const place.Left = &.{},
    /// As `place.KeepOutcome.hidden`.
    hidden: []const place.Hidden = &.{},
};

/// `holt keep --take-local`: makes the local content at `rel` of the
/// working tree containing `path` the kept copy, then links it. A file, or
/// content of another kind than the kept copy, replaces the kept copy
/// whole; a directory replaces each kept file it also holds and leaves the
/// kept-only files in place. The kept copy it replaces is set aside first
/// (`place.replaceKept`), the path's facts become this machine's one fact
/// for the result (`store.replaceFacts`), and the local content is set
/// aside before the link takes its place. Refuses as `takeKept` does, and
/// with `KeptElsewhere` while another machine's content for the path may
/// not have arrived: the kept copy is absent while another machine's fact
/// names the path, or holds other content than such a fact records and no
/// aside entry here holds that content. Nothing overrides it; once the
/// backend delivers, the take goes ahead.
pub fn takeLocal(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, rel: []const u8, opts: TakeOptions) !TakeOutcome {
    return takeHere(ctx, index, path, rel, .take_local, opts);
}

/// `holt keep --take-kept`: sets the local content at `rel` of the working
/// tree containing `path` aside, verified, and puts a link to the
/// unchanged kept copy in its place. Holds the clone's lock and then the
/// key's; records `pending` before the working tree changes, so an
/// interruption is reported and rerunning finishes it. Refuses with
/// `NotKept` for a path outside the kept set, `GitReadsUnlinked` for a
/// file git reads only as a regular file (`paths.keepable`), `KeptMissing`
/// when the kept copy is not here (`KeptOnlineOnly`, `KeptNotRegular`),
/// `FileNotFound` when there is no local content, `Tracked`, `ParentNotDir`,
/// `SymlinkNotHolts`, `LinkedElsewhere`, `NotRegular`, `Collision`,
/// `NestedKey`, `InvalidName` for a directory holding a name a kept path
/// may not have, a nested repository's `.git` included (the names in
/// `opts.invalid_names`), `NoSymlinkPrivilege`, `WorktreeListFailed`,
/// `WouldHide` (as `place.keepPath`), `OtherWritePending` while another
/// interrupted write of the path is recorded, and the refusals of
/// `openClone`. A refusal that gives the path up (`gaveUp`) clears an
/// interrupted take's `pending` record, so it is never reported forever.
/// Once linked it fails only as `place.keepPath` does.
pub fn takeKept(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, rel: []const u8, opts: TakeOptions) !TakeOutcome {
    return takeHere(ctx, index, path, rel, .take_kept, opts);
}

fn takeHere(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, rel: []const u8, op: clone.Op, opts: TakeOptions) !TakeOutcome {
    const a = ctx.alloc;
    if (paths.keepable(rel)) |inv| return if (inv == .git_reads_unlinked) error.GitReadsUnlinked else error.InvalidPath;
    const o = try openClone(ctx, index, path, false);
    const c = o.c;
    const key = o.key;
    if (try store.nestedKeyAt(a, index, key, rel) != null) return error.NestedKey;

    if (opts.held) |h| if (!try h.covers(ctx, c.common_dir, key)) return error.LocksNotHeld;
    const clone_lock = if (opts.held == null) try ctx_mod.lockClone(ctx, c.common_dir) else null;
    defer if (clone_lock) |l| l.release();
    const lock = if (opts.held == null) try ctx_mod.lockKey(ctx, key) else null;
    defer if (lock) |l| l.release();

    _ = try usableRecord(a, ctx.layout, key, o.roots);
    const ks = try store.loadKeyState(a, ctx.layout, key);
    const t: place.Tree = .{ .ctx = ctx, .c = c, .key = key, .chain = &.{key}, .roots = try store.syncedRoots(a, ctx.layout) };
    const src = try fsutil.joinSlashy(a, c.worktree, rel);
    const target = try ctx.layout.copyPath(a, key, rel);

    const pending = clone.findPending(try clone.readPending(a, c.common_dir), c.tree, rel);
    if (pending) |p| if (p.op != op) return error.OtherWritePending;
    const pre = precheck(t, ks, rel, op, opts) catch |err| {
        if (pending != null and gaveUp(err)) try clone.clearPending(a, c.common_dir, c.tree, rel);
        return err;
    };
    if (pre.linked) {
        if (pending != null) try clone.clearPending(a, c.common_dir, c.tree, rel);
        return .{ .status = .already_linked, .temp_entry = pre.settled.entry };
    }
    const settled = pre.settled;
    const src_hash = pre.src_hash;
    const kc_hash = pre.kc_hash;
    const link_kind = pre.link_kind;
    content.probeLink(a, try clone.stateDir(a, c.common_dir), link_kind) catch |err| switch (err) {
        error.SymlinkPrivilege => return error.NoSymlinkPrivilege,
        else => return err,
    };
    _ = clone.worktrees(a, c) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.WorktreeListFailed,
    };
    const temp_line = try paths.tempRel(a, rel);
    const guarded = try place.guardLines(ctx, c, key, rel, temp_line, .{ .would_hide = opts.would_hide });

    try clone.addPending(a, c.common_dir, .{ .tree = c.tree, .rel = rel, .op = op, .worktree = c.worktree });
    try interrupt.check(.take_pending);
    try block.add(a, c.common_dir, &.{ rel, temp_line });

    const local = try aside.ensureAside(a, ctx.layout, c.common_dir, ctx.machine_id, key, rel, src, if (op == .take_local) .keep else .local_differs, .whole);
    if (try aside.verify(a, ctx.layout, local.stamp) != .ok) return error.AsideVerifyFailed;
    if (op == .take_kept) try aside.markTaken(a, ctx.layout, local.stamp, @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms)));
    try interrupt.check(.take_aside);

    var kept_entry: ?[]const u8 = null;
    if (op == .take_local) {
        const staged = try stageMerged(ctx, key, src, src_hash, target, kc_hash);
        if (kc_hash == null or !place.equalHash(kc_hash.?, staged.hash)) {
            if (try place.replaceKept(a, ctx.layout, ctx.machine_id, key, rel, staged)) |e| kept_entry = e.stamp;
        }
        try ctx_mod.replaceOwnFacts(ctx, key, rel, staged.hash.kind, &staged.hash.hex);
        try interrupt.check(.take_facts);
    }

    const exec_kept = place.swapInLink(t, rel, target, src_hash, link_kind, op == .take_local) catch |err| switch (err) {
        error.SymlinkPrivilege => return error.NoSymlinkPrivilege,
        else => return err,
    };
    try interrupt.check(.take_link);

    try clone.clearPending(a, c.common_dir, c.tree, rel);
    const left = place.clearStaging(a, ctx.layout, ctx.machine_id, key) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try a.dupe(place.Left, &.{.{ .slot = try ctx.layout.stagingDir(a, ctx.machine_id, key), .reason = @errorName(err) }}),
    };
    place.dropTempLine(a, c, temp_line) catch |err| if (err == error.OutOfMemory) return err;
    const hidden = place.closingSweep(ctx, c, key, rel, temp_line, guarded) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try std.mem.concat(a, place.Hidden, &.{ guarded, &.{.{ .found = .{ .worktree = c.worktree, .rel = ".", .entry = .other, .why = .failed, .detail = @errorName(err) } }} }),
    };
    return .{ .status = .taken, .local_entry = local.stamp, .kept_entry = kept_entry, .temp_entry = settled.entry, .exec_not_kept = !exec_kept, .staging_left = left, .hidden = hidden };
}

const Pre = struct {
    settled: place.Settled,
    /// A healthy link to the kept copy is already there.
    linked: bool = false,
    src_hash: content.Hash = undefined,
    kc_hash: ?content.Hash = null,
    link_kind: content.Kind = .file,
};

/// Whether a take refused with `err` before changing anything gives up
/// the path, so a `pending` record of an interrupted take of it is
/// cleared: the path is no longer kept, or its local content is gone or
/// is no longer something a take can act on. Reconcile then judges the
/// path as it is, and what a temporary still holds is swept.
fn gaveUp(err: anyerror) bool {
    return switch (err) {
        error.NotKept, error.Collision, error.ParentNotDir, error.KeptNotRegular, error.Tracked, error.LinkedElsewhere, error.SymlinkNotHolts, error.FileNotFound, error.NotRegular, error.InvalidName, error.KeptMissing => true,
        else => false,
    };
}

/// The checks of a take, after settling a temporary an interrupted take
/// of `rel` left.
fn precheck(t: place.Tree, ks: store.KeyState, rel: []const u8, op: clone.Op, opts: TakeOptions) !Pre {
    const a = t.ctx.alloc;
    const c = t.c;
    if (ks.factsFor(rel).len == 0 or ks.isReleased(rel)) return error.NotKept;
    if (paths.contains(try paths.collisions(a, try ks.keptSet(a)), rel)) return error.Collision;
    const src = try fsutil.joinSlashy(a, c.worktree, rel);
    const target = try t.ctx.layout.copyPath(a, t.key, rel);
    if (!try link.parentsReal(a, c.worktree, rel)) return error.ParentNotDir;
    if (!try link.parentsReal(a, try t.ctx.layout.keyDir(a, t.key), rel)) return error.KeptNotRegular;
    if ((try clone.tracked(a, c.worktree, &.{rel}))[0] != .none) return error.Tracked;

    const settled = try place.settleTemp(t, rel, op);
    if (settled.how == .stuck) return error.TempStranded;
    switch (try link.classify(a, src, target, &.{t.key}, t.roots, rel)) {
        .right => return .{ .settled = settled, .linked = true },
        .holt => return error.LinkedElsewhere,
        .foreign => return error.SymlinkNotHolts,
        .absent => return error.FileNotFound,
        .local => |e| switch (e) {
            .other => return error.NotRegular,
            .dir => {
                const bad = try content.invalidNames(a, src);
                if (bad.len > 0) {
                    if (opts.invalid_names) |out| out.* = bad;
                    return error.InvalidName;
                }
            },
            else => {},
        },
    }
    const src_hash = try content.hashPath(a, src);
    const kc_hash = try keptHash(a, target);
    if (op == .take_kept and kc_hash == null) return error.KeptMissing;
    if (op == .take_local and try place.pendingDownload(t.ctx, t.key, ks.factsFor(rel), kc_hash)) return error.KeptElsewhere;
    return .{ .settled = settled, .src_hash = src_hash, .kc_hash = kc_hash, .link_kind = if (op == .take_kept) kc_hash.?.kind else src_hash.kind };
}

/// Stages the result of `--take-local`: a copy of the local content at
/// `src`, and, when both it and the kept copy at `target` are directories,
/// every kept file the local directory neither holds nor shadows (a local
/// file where a parent of it would be).
fn stageMerged(ctx: Ctx, key: []const u8, src: []const u8, src_hash: content.Hash, target: []const u8, kc_hash: ?content.Hash) !place.Staged {
    const a = ctx.alloc;
    const staged = try place.stage(a, ctx.layout, ctx.machine_id, key, src);
    const kh = kc_hash orelse return staged;
    if (src_hash.kind != .dir or kh.kind != .dir) return staged;
    var added = false;
    next: for (try content.treeFiles(a, target)) |kf| {
        var end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, kf.path, end, '/')) |slash| : (end = slash + 1) {
            const up = try fsutil.joinSlashy(a, staged.path, kf.path[0..slash]);
            if (try content.entryAt(up) == .file) continue :next;
        }
        const to = try fsutil.joinSlashy(a, staged.path, kf.path);
        if (try content.entryAt(to) != .absent) continue;
        try fsutil.ensureDir(std.fs.path.dirname(to).?);
        try content.copyRegular(a, try fsutil.joinSlashy(a, target, kf.path), to);
        if (!try content.executableCarried(a, try fsutil.joinSlashy(a, target, kf.path), to)) _ = try content.carryExecutable(a, try fsutil.joinSlashy(a, target, kf.path), to);
        added = true;
    }
    if (!added) return staged;
    return .{ .path = staged.path, .hash = try content.hashPath(a, staged.path) };
}

pub const AsideTaken = struct {
    key: []const u8,
    rel: []const u8,
    /// The aside entry holding the kept copy it replaced; null when the
    /// kept copy already held the entry's content or was absent.
    kept_entry: ?[]const u8 = null,
    staging_left: []const place.Left = &.{},
};

/// Whether `stamp` can name an aside entry: one path component that is
/// neither empty, `.`, nor `..`, nor reserved.
/// `holt keep --take-aside`: makes the aside entry `stamp` the kept copy
/// of the path its manifest names, in the key it names, replacing the
/// path's facts with this machine's one fact for it and removing any
/// released marker. The kept copy it replaces is set aside first. When
/// `worktree_path` is inside a clone whose files live in that key, the
/// write is recorded in its `pending` under the clone's lock, so an
/// interruption is reported there; the working tree is left for reconcile
/// to link. Refuses with `NoSuchEntry`, `AsideUnverified` or
/// `AsideOnlineOnly` when the entry does not verify, `Unplaceable`,
/// `AsidePartial` for an entry that left something out, `NotKept` for a
/// key with no record, `UnknownRecordVersion`, `LocalMismatch`,
/// `NestedKey`, `Collision`, `NestsInKept` when the path would lie inside
/// a kept directory or hold a kept path, `KeptNotRegular`, and
/// `OtherWritePending`. An entry that cannot be taken clears the record of
/// an interrupted take of it in the working tree's `pending`.
pub fn takeAside(ctx: Ctx, index: *const store.KeyIndex, stamp: []const u8, worktree_path: ?[]const u8) !AsideTaken {
    const a = ctx.alloc;
    var opened: ?Opened = null;
    if (worktree_path) |p| {
        if (openClone(ctx, index, p, false)) |o| {
            opened = o;
        } else |err| switch (err) {
            error.OutOfMemory, error.GitTooOld => return err,
            else => {},
        }
    }
    const m = entryToTake(a, ctx.layout, stamp) catch |err| {
        if (opened) |o| if (err != error.OutOfMemory) try dropAsidePending(ctx, o.c, stamp);
        return err;
    };
    const key = m.key;
    const rel = m.rel;
    const want = try m.hash(a);
    const here: ?Opened = if (opened) |o| (if (std.mem.eql(u8, o.key, key)) o else null) else null;
    if (try store.nestedKeyAt(a, index, key, rel) != null) return error.NestedKey;

    const clone_lock = if (here) |o| try ctx_mod.lockClone(ctx, o.c.common_dir) else null;
    defer if (clone_lock) |l| l.release();
    const lock = try ctx_mod.lockKey(ctx, key);
    defer lock.release();

    _ = try usableRecord(a, ctx.layout, key, if (here) |o| o.roots else null);
    const ks = try store.loadKeyState(a, ctx.layout, key);
    {
        var set: std.ArrayList([]const u8) = .empty;
        try set.appendSlice(a, try ks.keptSet(a));
        if (!paths.contains(set.items, rel)) try set.append(a, rel);
        if (paths.contains(try paths.collisions(a, set.items), rel)) return error.Collision;
    }
    if (try nestsInKept(a, ks, rel)) return error.NestsInKept;
    if (!try link.parentsReal(a, try ctx.layout.keyDir(a, key), rel)) return error.KeptNotRegular;
    const target = try ctx.layout.copyPath(a, key, rel);
    const kc_hash = try keptHash(a, target);

    if (here) |o| {
        if (clone.findPending(try clone.readPending(a, o.c.common_dir), o.c.tree, rel)) |p| {
            if (p.op != .take_aside) return error.OtherWritePending;
        }
        try clone.addPending(a, o.c.common_dir, .{ .tree = o.c.tree, .rel = rel, .op = .take_aside, .entry = stamp, .worktree = o.c.worktree });
    }
    try interrupt.check(.take_pending);

    var out: AsideTaken = .{ .key = key, .rel = rel };
    if (kc_hash == null or !place.equalHash(kc_hash.?, want)) {
        const staged = try place.stage(a, ctx.layout, ctx.machine_id, key, try aside.dataPath(a, ctx.layout, stamp, rel));
        if (!place.equalHash(staged.hash, want)) return error.AsideUnverified;
        if (try place.replaceKept(a, ctx.layout, ctx.machine_id, key, rel, staged)) |e| out.kept_entry = e.stamp;
    }
    try ctx_mod.replaceOwnFacts(ctx, key, rel, want.kind, &want.hex);
    try store.removeReleased(a, ctx.layout, key, rel);
    try interrupt.check(.take_facts);

    if (here) |o| try clone.clearPending(a, o.c.common_dir, o.c.tree, rel);
    out.staging_left = place.clearStaging(a, ctx.layout, ctx.machine_id, key) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try a.dupe(place.Left, &.{.{ .slot = try ctx.layout.stagingDir(a, ctx.machine_id, key), .reason = @errorName(err) }}),
    };
    return out;
}

/// The manifest of the aside entry `stamp`, when it can become a kept
/// copy: `NoSuchEntry`, `AsideOnlineOnly`, `AsideUnverified`,
/// `Unplaceable`, or `AsidePartial` otherwise.
fn entryToTake(a: std.mem.Allocator, layout: store.Layout, stamp: []const u8) !aside.Manifest {
    if (!store.validEntryName(stamp)) return error.NoSuchEntry;
    const m = (try aside.readManifest(a, layout, stamp)) orelse return error.NoSuchEntry;
    switch (try aside.verify(a, layout, stamp)) {
        .ok => {},
        .online_only => return error.AsideOnlineOnly,
        else => return error.AsideUnverified,
    }
    if (aside.unplaceable(m) != null) return error.Unplaceable;
    if (m.skipped.len > 0) return error.AsidePartial;
    if (m.index.len > 0) return error.AsideStaged;
    return m;
}

/// Clears, under the clone's lock, every `pending` record of `c`'s working
/// tree for an interrupted `--take-aside` of the entry `stamp`, which can
/// no longer be taken, so reconcile stops naming a command that fails.
fn dropAsidePending(ctx: Ctx, c: clone.Clone, stamp: []const u8) !void {
    const a = ctx.alloc;
    const lock = try ctx_mod.lockClone(ctx, c.common_dir);
    defer lock.release();
    for (try clone.readPending(a, c.common_dir)) |p| {
        if (p.op != .take_aside or !std.mem.eql(u8, p.tree, c.tree)) continue;
        if (p.entry != null and std.mem.eql(u8, p.entry.?, stamp)) try clone.clearPending(a, c.common_dir, c.tree, p.rel);
    }
}

/// Whether `rel` would lie inside a kept directory of `ks`, or hold a kept
/// path below it.
fn nestsInKept(a: std.mem.Allocator, ks: store.KeyState, rel: []const u8) !bool {
    if (keptDirAbove(ks, rel) != null) return true;
    const prefix = try std.mem.concat(a, u8, &.{ rel, "/" });
    for (try ks.keptSet(a)) |k| if (std.mem.startsWith(u8, k, prefix)) return true;
    return false;
}

pub const FromOptions = struct {
    /// Set, when `takeFrom` refuses with `Conflict`, to each path in both
    /// keys whose content differs or cannot be compared here.
    conflicts: ?*[]const []const u8 = null,
    /// Set, when it refuses with `OldCopyMissing`, to each path of the old
    /// key whose kept copy is not here.
    missing: ?*[]const []const u8 = null,
};

pub const FromOutcome = struct {
    /// The paths copied into the clone's key.
    copied: []const []const u8 = &.{},
    /// The paths the clone's key already held with the same content.
    present: []const []const u8 = &.{},
};

/// `holt keep --from`: copies the kept set of `old_key`, a key a repo left
/// behind (an upstream rename or transfer), into the key of the clone
/// containing `path`, creating it with its record when absent, and writes
/// this machine's fact for each path copied. The old key is left as it
/// is, with no `.holt-from/` marker, since a fork shares history with the
/// repo it came from. Holds the clone's lock and both keys' locks. Checks
/// everything before writing anything: refuses with `NoSuchKey` when
/// `old_key` holds no record, `SameKey`, `UnknownRecordVersion`,
/// `OldKeyNoRoot` when the old key records no `root` to match, `RootMismatch`
/// when the clone's history lacks the old key's `root`,
/// `OldCopyMissing` (paths in `opts.missing`), `Conflict` when a path is in
/// both keys with different content or with none here to compare (paths in
/// `opts.conflicts`), `NestsInKept` when a path would lie inside a kept
/// directory of the clone's key or hold one of its kept paths (paths in
/// `opts.conflicts`), `NestedKey`, `Collision`, `InvalidPath`, and the
/// refusals of `openClone` and `store.ensureKey`. Rerunning after an
/// interruption copies what is left, and writes the fact of a path whose
/// copy was placed before its fact was.
pub fn takeFrom(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, old_key: []const u8, opts: FromOptions) !FromOutcome {
    const a = ctx.alloc;
    if (!store.validKey(old_key)) return error.NoSuchKey;
    const o = try openClone(ctx, index, path, false);
    const key = o.key;
    if (std.mem.eql(u8, key, old_key)) return error.SameKey;

    const clone_lock = try ctx_mod.lockClone(ctx, o.c.common_dir);
    defer clone_lock.release();
    const locks = try ctx_mod.lockKeys(ctx, key, old_key);
    defer locks.release();

    const old_rec = (try store.readRecord(a, ctx.layout, old_key)) orelse return error.NoSuchKey;
    if (!old_rec.known()) return error.UnknownRecordVersion;
    const old_root = old_rec.root orelse return error.OldKeyNoRoot;
    if (!paths.contains(o.roots, old_root)) return error.RootMismatch;
    const default_root = try clone.defaultRoot(a, o.c.main);
    _ = try store.checkKey(a, ctx.layout, index, key, default_root, o.roots);

    const old = try store.loadKeyState(a, ctx.layout, old_key);
    const new = try store.loadKeyState(a, ctx.layout, key);
    const rels = try old.keptSet(a);
    var missing: std.ArrayList([]const u8) = .empty;
    var conflicts: std.ArrayList([]const u8) = .empty;
    var todo: std.ArrayList([]const u8) = .empty;
    var present: std.ArrayList([]const u8) = .empty;
    var hashes: std.ArrayList(content.Hash) = .empty;
    var unfacted: std.ArrayList([]const u8) = .empty;
    var unfacted_hashes: std.ArrayList(content.Hash) = .empty;
    for (rels) |rel| {
        if (paths.check(rel) != null) return error.InvalidPath;
        if (try store.nestedKeyAt(a, index, key, rel) != null) return error.NestedKey;
        const oh = (keptHash(a, try ctx.layout.copyPath(a, old_key, rel)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        }) orelse {
            try missing.append(a, rel);
            continue;
        };
        const in_new = new.factsFor(rel).len > 0 or new.isReleased(rel);
        const nh = keptHash(a, try ctx.layout.copyPath(a, key, rel)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try conflicts.append(a, rel);
                continue;
            },
        };
        if (nh) |h| {
            if (!place.equalHash(h, oh)) {
                try conflicts.append(a, rel);
                continue;
            }
            try present.append(a, rel);
            if (!in_new) {
                try unfacted.append(a, rel);
                try unfacted_hashes.append(a, h);
            }
            continue;
        }
        if (in_new) {
            try conflicts.append(a, rel);
            continue;
        }
        try todo.append(a, rel);
        try hashes.append(a, oh);
    }
    if (missing.items.len > 0) {
        if (opts.missing) |m| m.* = missing.items;
        return error.OldCopyMissing;
    }
    if (conflicts.items.len > 0) {
        if (opts.conflicts) |x| x.* = conflicts.items;
        return error.Conflict;
    }
    {
        var set: std.ArrayList([]const u8) = .empty;
        try set.appendSlice(a, try new.keptSet(a));
        for (todo.items) |rel| if (!paths.contains(set.items, rel)) try set.append(a, rel);
        const colliding = try paths.collisions(a, set.items);
        for (todo.items) |rel| if (paths.contains(colliding, rel)) return error.Collision;
        var nested: std.ArrayList([]const u8) = .empty;
        for (todo.items) |rel| {
            if (keptDirAbove(new, rel) != null) {
                try nested.append(a, rel);
                continue;
            }
            for (set.items) |other| {
                if (other.len > rel.len and std.mem.startsWith(u8, other, rel) and other[rel.len] == '/') {
                    try nested.append(a, rel);
                    break;
                }
            }
        }
        if (nested.items.len > 0) {
            if (opts.conflicts) |x| x.* = nested.items;
            return error.NestsInKept;
        }
    }

    _ = try store.ensureKey(a, ctx.layout, index, key, try clone.originUrl(a, o.c.main), default_root, o.roots);
    for (unfacted.items, unfacted_hashes.items) |rel, h| try ctx_mod.writeOwnFact(ctx, key, rel, h.kind, &h.hex);
    for (todo.items, hashes.items) |rel, h| {
        const staged = try place.stage(a, ctx.layout, ctx.machine_id, key, try ctx.layout.copyPath(a, old_key, rel));
        if (!place.equalHash(staged.hash, h)) return error.OldCopyChanged;
        place.placeNew(a, ctx.layout, key, rel, staged) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const now = (try keptHash(a, try ctx.layout.copyPath(a, key, rel))) orelse return err;
                if (!place.equalHash(now, h)) return error.Conflict;
            },
            else => return err,
        };
        try ctx_mod.writeOwnFact(ctx, key, rel, h.kind, &h.hex);
        try interrupt.check(.from_copied);
    }
    _ = place.clearStaging(a, ctx.layout, ctx.machine_id, key) catch |err| if (err == error.OutOfMemory) return err;
    return .{ .copied = todo.items, .present = present.items };
}

pub const UnkeepOptions = struct {
    /// A line to add to the repo's skip list (`patterns.anchoredLine`)
    /// before the path is released, so an auto pattern that matches it
    /// never keeps it again.
    skip_line: ?[]const u8 = null,
    /// Set, when `unkeep` refuses with `InsideKeptDir`, to the kept
    /// directory the path lies in.
    inside: ?*[]const u8 = null,
};

pub const UnkeepOutcome = struct {
    status: enum {
        /// The released marker is written; reconcile turns every link into
        /// a regular copy.
        released,
        /// The path was already released.
        already_released,
        /// The kept copy was gone: this working tree's link and the path's
        /// facts are removed instead.
        gone,
    },
    /// The key the path is filed in.
    key: []const u8,
    /// With `gone`: whether holt's link in this working tree was removed.
    link_removed: bool = false,
    /// The file `opts.skip_line` was added in; null when the line was
    /// already there or none was asked for.
    skip_file: ?[]const u8 = null,
};

/// `holt unkeep`: releases `rel` of the working tree containing `path`.
/// Adds `opts.skip_line` to the repo's skip list first, then writes the
/// released marker (`store.writeReleased`), leaving the kept content where
/// it is; the caller reconciles, which turns the link into a regular copy
/// on this machine as on every other. When the kept copy is already gone
/// and every fact of the path is this machine's or one a retirement covers
/// (`store.factRetired`), this working tree's holt link and the path's
/// facts are removed instead; when another machine's fact names it, its
/// kept copy may not have arrived yet, and unkeep refuses with
/// `KeptElsewhere` before writing anything.
/// Holds the clone's lock and then the key's. Refuses with `NotKept`,
/// `InsideKeptDir` (the directory in `opts.inside`), `InvalidPath`,
/// `UnknownRecordVersion`, and the refusals of `openClone` but
/// `KeySuperseded`: a clone whose key has a successor releases the path
/// there.
pub fn unkeep(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, rel: []const u8, opts: UnkeepOptions) !UnkeepOutcome {
    const a = ctx.alloc;
    if (paths.check(rel) != null) return error.InvalidPath;
    const o = try openClone(ctx, index, path, true);
    const key = o.key;
    const clone_lock = try ctx_mod.lockClone(ctx, o.c.common_dir);
    defer clone_lock.release();
    const lock = try ctx_mod.lockKey(ctx, key);
    defer lock.release();

    _ = try usableRecord(a, ctx.layout, key, o.roots);
    const ks = try store.loadKeyState(a, ctx.layout, key);
    if (ks.isReleased(rel)) return .{ .status = .already_released, .key = key };
    if (ks.factsFor(rel).len == 0) {
        if (keptDirAbove(ks, rel)) |dir| {
            if (opts.inside) |out| out.* = dir;
            return error.InsideKeptDir;
        }
        return error.NotKept;
    }

    const target = try ctx.layout.copyPath(a, key, rel);
    const gone = try content.entryAt(target) == .absent and !fsutil.hasIcloudPlaceholder(a, target);
    if (gone) for (ks.factsFor(rel)) |f| {
        if (!std.mem.eql(u8, f.machine, ctx.machine_id) and !try store.factRetired(a, ctx.layout, key, f)) return error.KeptElsewhere;
    };

    var out: UnkeepOutcome = .{ .status = .released, .key = key };
    if (opts.skip_line) |line| out.skip_file = try patterns.addLine(a, ctx.layout, ctx.machine_id, key, .skip, line);

    if (gone) {
        const cp = try fsutil.joinSlashy(a, o.c.worktree, rel);
        if (try link.parentsReal(a, o.c.worktree, rel)) {
            var chain: std.ArrayList([]const u8) = .empty;
            try chain.append(a, key);
            if (o.c.key) |own| if (!std.mem.eql(u8, own, key)) try chain.append(a, own);
            switch (try link.classify(a, cp, target, chain.items, try store.syncedRoots(a, ctx.layout), rel)) {
                .right, .holt => |raw| out.link_removed = try content.removeLinkIf(a, cp, raw),
                else => {},
            }
        }
        try store.removeFacts(a, ctx.layout, key, rel);
        try ctx_mod.noteOwnWrite(ctx);
        out.status = .gone;
        return out;
    }
    try store.writeReleased(a, ctx.layout, key, rel);
    try ctx_mod.noteOwnWrite(ctx);
    return out;
}

pub const Purged = struct {
    key: []const u8,
    /// The aside entry holding the kept content removed; null when there
    /// was none here to remove.
    entry: ?[]const u8 = null,
    /// The machines whose facts named the path.
    machines: []const []const u8 = &.{},
};

pub const PurgeOptions = struct {
    /// The user confirmed the purge, having been shown the machines whose
    /// facts name the path; without it purge refuses with `NotConfirmed`
    /// once every other check passes.
    confirmed: bool = false,
    /// Set, when purge refuses with `NotConfirmed`, to the machines whose
    /// facts name the path.
    machines: ?*[]const []const u8 = null,
};

/// `holt unkeep --purge`: removes the kept content of the released path
/// `rel` of the clone containing `path`, set aside and verified first, and
/// the path's facts; the released marker stays, marked purged with the
/// aside entry that holds the content (`store.writePurged`), so a machine
/// that still links the path restores a copy from that entry. Whether
/// another machine still links the path is unknowable here, so purge needs
/// `opts.confirmed`. Holds the key's lock. Refuses with `NotReleased` for a
/// kept path, `NotKept` for a path the key does not name, `StillLinked`
/// while any working tree of the clone holds holt's link at the path
/// (reconcile first), `WorktreeListFailed`, `NotConfirmed` (the machines in
/// `opts.machines`), `KeptOnlineOnly`, `KeptNotRegular`, and `KeptChanged`
/// when the kept content changed while it was set aside.
pub fn purge(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, rel: []const u8, opts: PurgeOptions) !Purged {
    const a = ctx.alloc;
    if (paths.check(rel) != null) return error.InvalidPath;
    const o = try openClone(ctx, index, path, true);
    const key = o.key;
    const lock = try ctx_mod.lockKey(ctx, key);
    defer lock.release();

    _ = try usableRecord(a, ctx.layout, key, o.roots);
    const ks = try store.loadKeyState(a, ctx.layout, key);
    if (!ks.isReleased(rel)) return if (ks.factsFor(rel).len > 0) error.NotReleased else error.NotKept;

    const target = try ctx.layout.copyPath(a, key, rel);
    var chain: std.ArrayList([]const u8) = .empty;
    try chain.append(a, key);
    if (o.c.key) |own| if (!std.mem.eql(u8, own, key)) try chain.append(a, own);
    const roots = try store.syncedRoots(a, ctx.layout);
    const trees = clone.worktrees(a, o.c) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.WorktreeListFailed,
    };
    for (trees) |t| {
        if (!t.readable()) return error.WorktreeListFailed;
        if (!try link.parentsReal(a, t.path, rel)) continue;
        switch (try link.classify(a, try fsutil.joinSlashy(a, t.path, rel), target, chain.items, roots, rel)) {
            .right, .holt => return error.StillLinked,
            else => {},
        }
    }

    var machines: std.ArrayList([]const u8) = .empty;
    for (ks.factsFor(rel)) |f| try machines.append(a, f.machine);
    if (!opts.confirmed) {
        if (opts.machines) |m| m.* = machines.items;
        return error.NotConfirmed;
    }
    var out: Purged = .{ .key = key, .machines = machines.items };
    if (try keptHash(a, target)) |h| {
        const e = try aside.setAside(a, ctx.layout, ctx.machine_id, key, rel, target, .purged);
        if (!place.equalHash(e.hash, h)) return error.KeptChanged;
        out.entry = e.stamp;
        try store.writePurged(a, ctx.layout, key, .{ .rel = rel, .entry = e.stamp });
        if (!try place.deleteIfHash(a, target, e.hash)) return error.KeptChanged;
    } else try store.writePurged(a, ctx.layout, key, ks.purgeOf(rel) orelse .{ .rel = rel, .entry = null });
    try store.removeFacts(a, ctx.layout, key, rel);
    try ctx_mod.noteOwnWrite(ctx);
    return out;
}

/// `holt unkeep --repo`: writes a released marker for every kept path of
/// `key`, under its lock, and returns them. Refuses with `NoSuchKey` when
/// the key holds no record, and `UnknownRecordVersion`.
pub fn unkeepRepo(ctx: Ctx, key: []const u8) ![]const []const u8 {
    const a = ctx.alloc;
    if (!store.validKey(key)) return error.NoSuchKey;
    const lock = try ctx_mod.lockKey(ctx, key);
    defer lock.release();
    _ = usableRecord(a, ctx.layout, key, null) catch |err| switch (err) {
        error.NotKept => return error.NoSuchKey,
        else => return err,
    };
    const ks = try store.loadKeyState(a, ctx.layout, key);
    const set = try ks.keptSet(a);
    for (set) |rel| try store.writeReleased(a, ctx.layout, key, rel);
    if (set.len > 0) try ctx_mod.noteOwnWrite(ctx);
    return set;
}

/// The key of the clone containing `path`, created with its record when
/// absent, after the checks `place.keepPath` makes before creating one:
/// the refusals of `openClone`, `RootRequired` for a `local/` key with no
/// commit, `LocalMismatch`, and those of `store.ensureKey`. Under the
/// key's lock, or the locks the caller holds (`held`; `LocksNotHeld` when
/// they are not the clone's and the key's).
pub fn ensureCloneKey(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, held: ?ctx_mod.Held) ![]const u8 {
    const a = ctx.alloc;
    const o = try openClone(ctx, index, path, false);
    if (held) |h| if (!try h.covers(ctx, o.c.common_dir, o.key)) return error.LocksNotHeld;
    const lock = if (held == null) try ctx_mod.lockKey(ctx, o.key) else null;
    defer if (lock) |l| l.release();
    const default_root = try clone.defaultRoot(a, o.c.main);
    _ = try store.ensureKey(a, ctx.layout, index, o.key, try clone.originUrl(a, o.c.main), default_root, o.roots);
    return o.key;
}

pub const AsideInfo = struct {
    stamp: []const u8,
    /// Null when the manifest is gone or unreadable.
    manifest: ?aside.Manifest,
    /// The UTC time the stamp names, in milliseconds since the epoch, or for
    /// a name that is not a stamp when the entry was last modified; null
    /// when neither can be read.
    time_ms: ?i64,
    /// Bytes of content the entry holds, its manifest aside.
    bytes: u64,
    /// Why the entry must not be removed, or null when it may be.
    held: ?Held,
    /// A purge mark names it, or its manifest records it as a purge's
    /// aside (`aside.Reason.purged`) before the mark has synced here, and
    /// it is not pruned (`store.isPruned`): a machine that still links the
    /// purged path restores a copy from it.
    purge: bool = false,

    pub const Held = enum {
        /// Its content is one side of a path two machines kept with
        /// different content, not yet settled: facts no retirement covers
        /// (`store.factRetired`) differ, as reconcile judges it.
        two_machines,
        /// Its manifest cannot be read, and its stamp's time, or the
        /// newest modification of anything in it, is less than a day
        /// old, so it may still be arriving or being written.
        recent,
        /// A kept path reconcile could not settle names it: it may hold
        /// the only copy of what that path is waiting on.
        unsettled,
        /// `--take-kept` set local content aside into it less than
        /// `taken_days` days ago (`aside.markTaken`).
        taken,
        /// Its time (`time_ms`), or the time it arrived here (its
        /// directory's modification time), is less than `young_days` days
        /// ago, or cannot be read: another machine's unsettled path, a
        /// working tree that could not be read, or an operation that just
        /// finished may still need it. The arrival covers a stamp written
        /// by a machine whose clock is behind.
        young,
        /// Its manifest cannot be read, or its content is not here whole
        /// (`WholeCheck`), or cannot be read to tell: it may still be
        /// arriving, whatever its stamp and directory times say, which a
        /// sync tool may carry over from the machine that wrote it.
        partial,

        /// Whether naming the entry to `--prune-aside` removes it anyway.
        pub fn yields(h: Held) bool {
            return h == .unsettled or h == .taken or h == .young or h == .partial;
        }
    };
};

/// How long an entry `--take-kept` set content aside into is spared.
pub const taken_days = 30;

/// How long every entry is spared unless named (`AsideInfo.Held.young`).
pub const young_days = 30;

/// The milliseconds since the epoch `stamp` (`aside.newStamp`) names, or
/// null when it does not start as one does.
pub fn stampTime(stamp: []const u8) ?i64 {
    if (stamp.len < 20 or stamp[8] != 'T' or stamp[15] != '.' or stamp[19] != 'Z') return null;
    const n = struct {
        fn f(s: []const u8) ?u32 {
            return std.fmt.parseInt(u32, s, 10) catch null;
        }
    }.f;
    const year = n(stamp[0..4]) orelse return null;
    const month = n(stamp[4..6]) orelse return null;
    const day = n(stamp[6..8]) orelse return null;
    const hour = n(stamp[9..11]) orelse return null;
    const min = n(stamp[11..13]) orelse return null;
    const sec = n(stamp[13..15]) orelse return null;
    const ms = n(stamp[16..19]) orelse return null;
    if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or min > 59 or sec > 60) return null;
    var days: i64 = 0;
    var y: u32 = 1970;
    while (y < year) : (y += 1) days += if (std.time.epoch.isLeapYear(@intCast(y))) 366 else 365;
    var mo: u4 = 1;
    while (mo < month) : (mo += 1) days += std.time.epoch.getDaysInMonth(@intCast(year), @enumFromInt(mo));
    days += day - 1;
    return ((days * 24 + hour) * 60 + min) * 60 * 1000 + @as(i64, sec) * 1000 + ms;
}

/// What unsettled kept paths may still need of the aside entries
/// (`unsettledEntries`): the entries they name, and each path itself, as
/// `<key>\x00<rel>`, whose every entry they may need.
pub const Referenced = struct {
    entries: std.ArrayList([]const u8) = .empty,
    paths: std.ArrayList([]const u8) = .empty,
};

/// How `asideEntries` judges whether an entry is here whole
/// (`AsideInfo.Held.partial`).
pub const WholeCheck = enum {
    /// Its manifest reads, and every file it records is here
    /// (`aside.present`), no content read: for counting.
    present,
    /// Its content verifies against its manifest (`aside.verify`): before
    /// removing it.
    verified,
};

/// Every entry under `kept/.holt-aside/`, in name order, with what
/// `--prune-aside` needs to judge it (`AsideInfo.held`), judged whole as
/// `whole` says. `referenced` is what unsettled kept paths may need
/// (`unsettledEntries`). `now_ms` is the current UTC time in milliseconds
/// since the epoch.
pub fn asideEntries(ctx: Ctx, index: *const store.KeyIndex, now_ms: i64, referenced: *const Referenced, whole: WholeCheck) ![]const AsideInfo {
    const a = ctx.alloc;
    var names: std.ArrayList([]const u8) = .empty;
    {
        var d = std.Io.Dir.cwd().openDir(io(), try ctx.layout.asideDir(a), .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return &.{},
            else => return err,
        };
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| {
            if (e.kind == .directory) try names.append(a, try a.dupe(u8, e.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, paths.lessThan);

    const Held = struct { key: []const u8, rel: []const u8, hex: []const u8 };
    var held: std.ArrayList(Held) = .empty;
    for (index.keys) |k| {
        const ks = try store.loadKeyState(a, ctx.layout, k);
        for (ks.facts, 0..) |f, i| {
            if (i > 0 and std.mem.eql(u8, ks.facts[i - 1].rel, f.rel)) continue;
            var live: std.ArrayList(store.Fact) = .empty;
            for (ks.factsFor(f.rel)) |g| {
                if (!try store.factRetired(a, ctx.layout, k, g)) try live.append(a, g);
            }
            const facts = live.items;
            if (facts.len == 0) continue;
            const differ = for (facts[1..]) |g| {
                if (!std.mem.eql(u8, g.sha256, facts[0].sha256)) break true;
            } else false;
            if (!differ) continue;
            for (facts) |g| try held.append(a, .{ .key = k, .rel = f.rel, .hex = g.sha256 });
        }
    }

    var purged: std.ArrayList([]const u8) = .empty;
    for (index.keys) |k| {
        for (try store.readPurged(a, ctx.layout, k)) |p| if (p.entry) |e| try purged.append(a, e);
    }

    var out: std.ArrayList(AsideInfo) = .empty;
    for (names.items) |name| {
        const m = try aside.readManifest(a, ctx.layout, name);
        const dir = try std.fs.path.join(a, &.{ try ctx.layout.asideDir(a), name });
        const time = stampTime(name) orelse modifiedMs(dir);
        const bytes = try treeBytes(a, try std.fs.path.join(a, &.{ dir, "data" })) + try treeBytes(a, try std.fs.path.join(a, &.{ dir, "index" }));
        var info: AsideInfo = .{ .stamp = name, .manifest = m, .time_ms = time, .bytes = bytes, .held = null };
        if (m) |man| {
            if (man.hash(a)) |h| {
                for (held.items) |x| {
                    if (std.mem.eql(u8, x.key, man.key) and std.mem.eql(u8, x.rel, man.rel) and std.mem.eql(u8, x.hex, &h.hex)) info.held = .two_machines;
                }
            } else |_| {}
        } else if (try arriving(a, name, dir, now_ms)) info.held = .recent;
        if (info.held == null and paths.contains(referenced.entries.items, name)) info.held = .unsettled;
        if (info.held == null) if (m) |man| {
            if (paths.contains(referenced.paths.items, try std.mem.concat(a, u8, &.{ man.key, "\x00", man.rel }))) info.held = .unsettled;
        };
        if (info.held == null) if (try aside.takenMs(a, ctx.layout, name)) |t| {
            if (now_ms - t < taken_days * std.time.ms_per_day) info.held = .taken;
        };
        if (info.held == null) {
            const t = time orelse now_ms;
            const arrived = modifiedMs(dir) orelse now_ms;
            const young_ms = young_days * std.time.ms_per_day;
            if (now_ms - t < young_ms or now_ms - arrived < young_ms) info.held = .young;
        }
        if (info.held == null and !try isWhole(a, ctx, name, m, whole)) info.held = .partial;
        info.purge = (paths.contains(purged.items, name) or purgedAside(m)) and !try store.isPruned(a, ctx.layout, name);
        try out.append(a, info);
    }
    return out.items;
}

/// Whether the aside entry `name`, whose manifest is `m`, is here whole as
/// `whole` judges it; a check that fails but for lack of memory says it is
/// not.
fn isWhole(a: std.mem.Allocator, ctx: Ctx, name: []const u8, m: ?aside.Manifest, whole: WholeCheck) !bool {
    const man = m orelse return false;
    return switch (whole) {
        .present => aside.present(a, ctx.layout, name, man) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => false,
        },
        .verified => (aside.verify(a, ctx.layout, name) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        }) == .ok,
    };
}

/// Whether the manifest `m` records its entry as the content a purge set
/// aside, whether or not the purge's mark has reached this machine.
fn purgedAside(m: ?aside.Manifest) bool {
    const man = m orelse return false;
    return std.mem.eql(u8, man.reason, @tagName(aside.Reason.purged));
}

/// Adds to `out` what the unsettled items of `report` may need of the
/// aside entries: the entries they name, and their paths in the key the
/// working tree resolves to, since a plan names no entry it would set
/// aside into and an earlier run may have.
pub fn unsettledEntries(alloc: std.mem.Allocator, report: reconcile_mod.Report, out: *Referenced) !void {
    const key = report.resolved orelse report.key;
    for (report.items) |i| {
        if (!i.unsettled) continue;
        if (i.entry) |e| if (!paths.contains(out.entries.items, e)) try out.entries.append(alloc, e);
        for (i.entries) |e| if (!paths.contains(out.entries.items, e)) try out.entries.append(alloc, e);
        if (key) |k| {
            const kr = try std.mem.concat(alloc, u8, &.{ k, "\x00", i.rel });
            if (!paths.contains(out.paths.items, kr)) try out.paths.append(alloc, kr);
        }
    }
}

/// Whether the aside entry `name` at `dir`, whose manifest cannot be read,
/// may still be arriving from another machine or being written here: its
/// stamp names a time less than a day before `now_ms`, or the newest
/// modification of the entry or anything in it is, or cannot be read.
fn arriving(a: std.mem.Allocator, name: []const u8, dir: []const u8, now_ms: i64) !bool {
    if (stampTime(name)) |t| if (now_ms - t < std.time.ms_per_day) return true;
    const newest = (try newestMs(a, dir)) orelse return true;
    return now_ms - newest < std.time.ms_per_day;
}

/// The newest modification time, in milliseconds since the epoch, of `root`
/// and everything below it, links not followed; null when one cannot be
/// read.
fn newestMs(a: std.mem.Allocator, root: []const u8) !?i64 {
    var newest = modifiedMs(root) orelse return null;
    var d = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch return null;
    defer d.close(io());
    var walker = try d.walk(a);
    defer walker.deinit();
    while (walker.next(io()) catch return null) |e| {
        const st = d.statFile(io(), e.path, .{ .follow_symlinks = false }) catch return null;
        newest = @max(newest, @as(i64, @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms))));
    }
    return newest;
}

fn modifiedMs(path: []const u8) ?i64 {
    const st = std.Io.Dir.cwd().statFile(io(), path, .{}) catch return null;
    return @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms));
}

fn treeBytes(a: std.mem.Allocator, root: []const u8) !u64 {
    var total: u64 = 0;
    var d = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch return 0;
    defer d.close(io());
    var walker = try d.walk(a);
    defer walker.deinit();
    while (walker.next(io()) catch null) |e| {
        if (e.kind != .file) continue;
        const st = d.statFile(io(), e.path, .{}) catch continue;
        total += st.size;
    }
    return total;
}

/// Removes the aside entry `info` names, under the locks of its
/// manifest's key, when valid, and of every key whose purge mark names the
/// entry, after reading the manifest again: an entry whose manifest changed
/// since `info` was made is left, and false returned. When a purge mark
/// names the entry, or its manifest records it as a purge's aside, it is
/// recorded pruned first (`store.writePruned`), so a machine that sees the
/// entry gone knows it was pruned, not still arriving; no purge mark is
/// edited. The data goes before the manifest, so an interrupted removal
/// leaves an entry that still says what it was, not one that looks like an
/// entry still arriving.
pub fn pruneEntry(ctx: Ctx, info: AsideInfo) !bool {
    const a = ctx.alloc;
    const index = try store.loadIndex(a, ctx.layout);
    var keys: std.ArrayList([]const u8) = .empty;
    if (info.manifest) |m| if (store.validKey(m.key)) try keys.append(a, m.key);
    for (index.keys) |k| {
        for (try store.readPurged(a, ctx.layout, k)) |p| if (namesEntry(p, info.stamp)) {
            try keys.append(a, k);
            break;
        };
    }
    const locks = try ctx_mod.lockAll(ctx, keys.items);
    defer locks.release();
    const now = try aside.readManifest(a, ctx.layout, info.stamp);
    if ((now == null) != (info.manifest == null)) return false;
    if (now) |m| {
        const was = info.manifest.?;
        if (!std.mem.eql(u8, m.key, was.key) or !std.mem.eql(u8, m.rel, was.rel)) return false;
        const hn = m.hash(a) catch return false;
        const hw = was.hash(a) catch return false;
        if (!place.equalHash(hn, hw)) return false;
    }
    const purged = blk: {
        if (purgedAside(now)) break :blk true;
        for (keys.items) |k| {
            for (try store.readPurged(a, ctx.layout, k)) |p| if (namesEntry(p, info.stamp)) break :blk true;
        }
        break :blk false;
    };
    if (purged) try store.writePruned(a, ctx.layout, info.stamp);
    try interrupt.check(.prune_marked);
    const dir = try std.fs.path.join(a, &.{ try ctx.layout.asideDir(a), info.stamp });
    try std.Io.Dir.cwd().deleteTree(io(), try std.fs.path.join(a, &.{ dir, "data" }));
    try interrupt.check(.prune_data);
    try std.Io.Dir.cwd().deleteTree(io(), dir);
    return true;
}

fn namesEntry(mark: store.Purge, stamp: []const u8) bool {
    return if (mark.entry) |e| std.mem.eql(u8, e, stamp) else false;
}

const harness = @import("harness.zig");
const testutil = @import("../testutil.zig");
const reconcile_mod = @import("reconcile.zig");
const World = harness.World;
const test_key = harness.repo_key;

fn indexOf(m: *const harness.Machine) !store.KeyIndex {
    return store.loadIndex(m.ctx.alloc, m.ctx.layout);
}

fn keptBytes(m: *const harness.Machine, rel: []const u8) ![]u8 {
    return content.readSmall(m.ctx.alloc, try m.keptPath(rel));
}

test "takeLocal: a file replaces the kept copy, which is set aside, and becomes this machine's one fact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);

    try ma.write(".env", "from a");
    _ = try ma.keep(".env");
    try w.sync();
    try mb.write(".env", "from b");
    _ = try mb.reconcile();
    try testing.expect(!try mb.linked(".env"));

    var idx = try indexOf(mb);
    const got = try takeLocal(mb.ctx, &idx, mb.clone, ".env", .{});
    try testing.expectEqual(.taken, got.status);
    try testing.expect(try mb.linked(".env"));
    try testing.expectEqualStrings("from b", try keptBytes(mb, ".env"));
    try testing.expectEqualStrings("from a", try content.readSmall(a, try aside.dataPath(a, mb.ctx.layout, got.kept_entry.?, ".env")));
    try testing.expectEqualStrings("from b", try content.readSmall(a, try aside.dataPath(a, mb.ctx.layout, got.local_entry.?, ".env")));
    const ks = try store.loadKeyState(a, mb.ctx.layout, test_key);
    try testing.expectEqual(@as(usize, 1), ks.factsFor(".env").len);
    try testing.expectEqualStrings(mb.ctx.machine_id, ks.factsFor(".env")[0].machine);

    const again = try takeLocal(mb.ctx, &idx, mb.clone, ".env", .{});
    try testing.expectEqual(.already_linked, again.status);
    try testing.expectEqual(@as(usize, 0), (try mb.reconcile()).unsettledCount());
}

test "takeLocal: a directory replaces the kept files it holds and keeps the kept-only ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("notes/a.md", "old a");
    try m.write("notes/only-kept.md", "kept only");
    try m.write("notes/sub", "kept file where local has a directory");
    _ = try m.keep("notes");
    try fsutil.removePath(try m.path("notes"));
    try m.write("notes/a.md", "new a");
    try m.write("notes/local.md", "local only");
    try m.write("notes/sub/inner.md", "inner");

    var idx = try indexOf(m);
    const got = try takeLocal(m.ctx, &idx, m.clone, "notes", .{});
    try testing.expectEqual(.taken, got.status);
    try testing.expect(try m.linked("notes"));
    try testing.expectEqualStrings("new a", try keptBytes(m, "notes/a.md"));
    try testing.expectEqualStrings("kept only", try keptBytes(m, "notes/only-kept.md"));
    try testing.expectEqualStrings("local only", try keptBytes(m, "notes/local.md"));
    try testing.expectEqualStrings("inner", try keptBytes(m, "notes/sub/inner.md"));
    try testing.expectEqual(aside.Check.ok, try aside.verify(a, m.ctx.layout, got.kept_entry.?));
    try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
}

test "takeKept: the local copy is set aside and the unchanged kept copy linked; facts stay" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try m.saveByRename(".env", "local edit");
    var idx = try indexOf(m);
    const got = try takeKept(m.ctx, &idx, m.clone, ".env", .{});
    try testing.expect(try m.linked(".env"));
    try testing.expectEqualStrings("kept", try m.read(".env"));
    try testing.expectEqualStrings("local edit", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, got.local_entry.?, ".env")));
    try testing.expect(got.kept_entry == null);
    try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
}

test "takeKept and takeLocal: refuse a path that is not kept, a missing kept copy, and a path with no local content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try m.write("other", "x");
    var idx = try indexOf(m);
    try testing.expectError(error.NotKept, takeKept(m.ctx, &idx, m.clone, "other", .{}));
    try std.Io.Dir.cwd().deleteFile(io(), try m.path(".env"));
    try testing.expectError(error.FileNotFound, takeLocal(m.ctx, &idx, m.clone, ".env", .{}));
    try m.write(".env", "local");
    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath(".env"));
    try testing.expectError(error.KeptMissing, takeKept(m.ctx, &idx, m.clone, ".env", .{}));
    try testing.expectEqualStrings("local", try m.read(".env"));
}

test "takeLocal interrupted at every point: content stays in place, in kept, or in aside; reconcile reports it; rerunning finishes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer interrupt.at = null;
    const points = [_]interrupt.Point{ .take_pending, .aside_copied, .take_aside, .stage_copied, .replace_aside, .replace_swapped, .take_facts, .link_moved, .link_created, .take_link };
    for (points) |point| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try World.init(a, &sb, 1);
        const m = w.m(0);
        try m.write("d/a", "old a");
        try m.write("d/k", "kept only");
        _ = try m.keep("d");
        try fsutil.removePath(try m.path("d"));
        try m.write("d/a", "new a");

        var idx = try indexOf(m);
        interrupt.at = point;
        try testing.expectError(error.Interrupted, takeLocal(m.ctx, &idx, m.clone, "d", .{}));
        interrupt.at = null;

        const local_new = if (content.readSmall(a, try m.path("d/a"))) |b| std.mem.eql(u8, b, "new a") else |_| false;
        const kept_new = if (keptBytes(m, "d/a")) |b| std.mem.eql(u8, b, "new a") else |_| false;
        const temp_new = if (content.readSmall(a, try fsutil.joinSlashy(a, try m.path(try paths.tempRel(a, "d")), "a"))) |b| std.mem.eql(u8, b, "new a") else |_| false;
        testing.expect(local_new or kept_new or temp_new) catch |err| {
            std.debug.print("lost at {s}\n", .{@tagName(point)});
            return err;
        };
        const report = try m.reconcile();
        if (report.find("d", .interrupted) == null and report.find("d", .ok) == null) {
            std.debug.print("at {s}: not reported\n", .{@tagName(point)});
            return error.TestUnexpectedResult;
        }

        idx = try indexOf(m);
        _ = try takeLocal(m.ctx, &idx, m.clone, "d", .{});
        try testing.expect(try m.linked("d"));
        try testing.expectEqualStrings("new a", try keptBytes(m, "d/a"));
        try testing.expectEqualStrings("kept only", try keptBytes(m, "d/k"));
        try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
    }
}

test "takeKept interrupted at every point: rerunning finishes and the local copy is in aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer interrupt.at = null;
    const points = [_]interrupt.Point{ .take_pending, .aside_copied, .take_aside, .link_moved, .link_created, .take_link };
    for (points) |point| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try World.init(a, &sb, 1);
        const m = w.m(0);
        try m.write(".env", "kept");
        _ = try m.keep(".env");
        try m.saveByRename(".env", "local");

        var idx = try indexOf(m);
        interrupt.at = point;
        try testing.expectError(error.Interrupted, takeKept(m.ctx, &idx, m.clone, ".env", .{}));
        interrupt.at = null;
        _ = try m.reconcile();
        idx = try indexOf(m);
        const got = try takeKept(m.ctx, &idx, m.clone, ".env", .{});
        try testing.expect(try m.linked(".env"));
        try testing.expectEqualStrings("kept", try m.read(".env"));
        if (got.local_entry) |e| try testing.expectEqualStrings("local", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, e, ".env")));
        try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
        const hits = try aside.findEntries(a, m.ctx.layout, test_key, ".env", &(try content.hashPath(a, try writeProbe(a, sb.root, "local"))).hex);
        try testing.expect(hits.len > 0);
    }
}

fn writeProbe(a: std.mem.Allocator, root: []const u8, data: []const u8) ![]const u8 {
    const p = try std.fs.path.join(a, &.{ root, "probe" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = data });
    return p;
}

test "takeAside: settles two machines' different keeps; every machine links the chosen content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);

    try ma.write(".clasp.json", "A");
    try mb.write(".clasp.json", "B");
    _ = try ma.keep(".clasp.json");
    _ = try mb.keep(".clasp.json");
    try w.deliverPath(1, 0, try std.fmt.allocPrint(a, "{s}/.holt-paths", .{test_key}));
    try w.deliverPath(1, 0, ".holt-aside");
    const report = try ma.reconcile();
    const two = report.find(".clasp.json", .two_machines).?;
    var chosen: ?[]const u8 = null;
    for (two.entries) |e| {
        if (std.mem.eql(u8, try content.readSmall(a, try aside.dataPath(a, ma.ctx.layout, e, ".clasp.json")), "B")) chosen = e;
    }

    var idx = try indexOf(ma);
    const got = try takeAside(ma.ctx, &idx, chosen.?, ma.clone);
    try testing.expectEqualStrings(".clasp.json", got.rel);
    try testing.expectEqualStrings("A", try content.readSmall(a, try aside.dataPath(a, ma.ctx.layout, got.kept_entry.?, ".clasp.json")));
    try testing.expectEqualStrings("B", try ma.read(".clasp.json"));
    try testing.expectEqual(@as(usize, 0), (try ma.reconcile()).unsettledCount());
    try w.sync();
    try testing.expectEqual(@as(usize, 0), (try mb.reconcile()).unsettledCount());
    try testing.expectEqualStrings("B", try mb.read(".clasp.json"));

    try testing.expectError(error.NoSuchEntry, takeAside(ma.ctx, &idx, "../x", ma.clone));
    try testing.expectError(error.NoSuchEntry, takeAside(ma.ctx, &idx, "20260101T000000.000Z-none", ma.clone));
}

test "takeAside: an entry that does not verify, left something out, or names an unusable path is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "x");
    const got = try m.keep(".env");
    var idx = try indexOf(m);

    const data = try aside.dataPath(a, m.ctx.layout, got.entry.?, ".env");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = data, .data = "tampered" });
    try testing.expectError(error.AsideUnverified, takeAside(m.ctx, &idx, got.entry.?, m.clone));

    const bad = try aside.setAside(a, m.ctx.layout, m.ctx.machine_id, test_key, ".holt-x", try m.path("README"), .hidden);
    try testing.expectError(error.Unplaceable, takeAside(m.ctx, &idx, bad.stamp, m.clone));
    try testing.expectEqualStrings("x", try keptBytes(m, ".env"));
}

test "takeAside interrupted: reconcile reports the take, and rerunning finishes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer interrupt.at = null;
    for ([_]interrupt.Point{ .take_pending, .stage_copied, .replace_aside, .replace_swapped, .take_facts }) |point| {
        // Windows has no exchange rename, so a file replaces a file in one
        // rename, before that point.
        if (builtin.os.tag == .windows and point == .replace_swapped) continue;
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try World.init(a, &sb, 1);
        const m = w.m(0);
        try m.write(".env", "first");
        const first = try m.keep(".env");
        try m.write(".env", "second");
        var idx = try indexOf(m);
        interrupt.at = point;
        try testing.expectError(error.Interrupted, takeAside(m.ctx, &idx, first.entry.?, m.clone));
        interrupt.at = null;
        const report = try m.reconcile();
        const item = report.find(".env", .interrupted) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(clone.Op.take_aside, item.op.?);
        try testing.expectEqualStrings(first.entry.?, item.entry.?);
        idx = try indexOf(m);
        _ = try takeAside(m.ctx, &idx, first.entry.?, m.clone);
        _ = try m.reconcile();
        try testing.expectEqualStrings("first", try m.read(".env"));
    }
}

test "takeFrom: copies an old key's kept set into the clone's key, refusing a different history or different content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    const old_key = "github.com/old/widget";
    const root = (try clone.defaultRoot(a, m.clone)).?;

    var idx = try indexOf(m);
    _ = try store.ensureKey(a, m.ctx.layout, &idx, old_key, null, "0000000000000000000000000000000000000000", &.{});
    const old_copy = try m.ctx.layout.copyPath(a, old_key, ".env");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = old_copy, .data = "old env" });
    const h = try content.hashPath(a, old_copy);
    try store.writeFact(a, m.ctx.layout, old_key, "000000000000000f", ".env", .file, &h.hex);
    idx = try indexOf(m);
    try testing.expectError(error.RootMismatch, takeFrom(m.ctx, &idx, m.clone, old_key, .{}));

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.ctx.layout.reserved(a, old_key, store.record_basename), .data = try std.fmt.allocPrint(a, "{{\"version\": 1, \"root\": \"{s}\"}}", .{root}) });
    try m.write("keep.me", "mine");
    _ = try m.keep("keep.me");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.ctx.layout.copyPath(a, old_key, "keep.me"), .data = "theirs" });
    const h2 = try content.hashPath(a, try m.ctx.layout.copyPath(a, old_key, "keep.me"));
    try store.writeFact(a, m.ctx.layout, old_key, "000000000000000f", "keep.me", .file, &h2.hex);
    idx = try indexOf(m);
    var conflicts: []const []const u8 = &.{};
    try testing.expectError(error.Conflict, takeFrom(m.ctx, &idx, m.clone, old_key, .{ .conflicts = &conflicts }));
    try testing.expectEqualStrings("keep.me", conflicts[0]);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try m.keptPath(".env")));

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.ctx.layout.copyPath(a, old_key, "keep.me"), .data = "mine" });
    const h3 = try content.hashPath(a, try m.keptPath("keep.me"));
    try store.writeFact(a, m.ctx.layout, old_key, "000000000000000f", "keep.me", .file, &h3.hex);
    const got = try takeFrom(m.ctx, &idx, m.clone, old_key, .{});
    try testing.expectEqual(@as(usize, 1), got.copied.len);
    try testing.expectEqualStrings(".env", got.copied[0]);
    try testing.expectEqualStrings("keep.me", got.present[0]);
    try testing.expectEqualStrings("old env", try keptBytes(m, ".env"));
    try testing.expect(try store.readRecord(a, m.ctx.layout, old_key) != null);
    _ = try m.reconcile();
    try testing.expect(try m.linked(".env"));
    try testing.expectError(error.SameKey, takeFrom(m.ctx, &idx, m.clone, test_key, .{}));
    try testing.expectError(error.NoSuchKey, takeFrom(m.ctx, &idx, m.clone, "github.com/none/here", .{}));
}

test "unkeep: releases the path, and reconcile turns the link into a regular copy; a gone copy drops the link and facts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".env", "x");
    try m.write("gone", "y");
    try m.write("d/f", "z");
    _ = try m.keep(".env");
    _ = try m.keep("gone");
    _ = try m.keep("d");
    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath("gone"));
    var idx = try indexOf(m);

    const line = try patterns.anchoredLine(a, ".env");
    const got = try unkeep(m.ctx, &idx, m.clone, ".env", .{ .skip_line = line });
    try testing.expectEqual(.released, got.status);
    try testing.expectEqualStrings("/.env\n", try content.readSmall(a, got.skip_file.?));
    _ = try m.reconcile();
    try testing.expectEqual(content.Entry.file, try m.entry(".env"));
    try testing.expectEqualStrings("x", try m.read(".env"));
    try testing.expectEqual(.already_released, (try unkeep(m.ctx, &idx, m.clone, ".env", .{})).status);

    try testing.expectEqual(.gone, (try unkeep(m.ctx, &idx, m.clone, "gone", .{})).status);
    try testing.expectEqual(content.Entry.absent, try m.entry("gone"));
    try testing.expectEqual(@as(usize, 0), (try store.loadKeyState(a, m.ctx.layout, test_key)).factsFor("gone").len);

    var inside: []const u8 = "";
    try testing.expectError(error.InsideKeptDir, unkeep(m.ctx, &idx, m.clone, "d/f", .{ .inside = &inside }));
    try testing.expectEqualStrings("d", inside);
    try testing.expectError(error.NotKept, unkeep(m.ctx, &idx, m.clone, "never", .{}));
    try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
}

/// Delivers to machine `to` the store's lists, `key`'s record, and its
/// facts from machine `from`, but no kept copy: a backend partway through.
fn deliverFactsOnly(w: *World, from: usize, to: usize) !void {
    try w.deliverPath(from, to, ".holt-skip");
    try w.deliverPath(from, to, ".holt-auto");
    try w.deliverPath(from, to, test_key ++ "/.holt-kept.json");
    try w.deliverPath(from, to, test_key ++ "/.holt-paths");
}

test "reconcile: a path another machine kept whose copy has not arrived is not_arrived, naming that machine; retired, it is missing, but one kept after the retirement is not_arrived" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "from a");
    _ = try ma.keep(".env");
    try ma.write(".clasp.json", "{}");
    _ = try ma.keep(".clasp.json");
    try deliverFactsOnly(&w, 0, 1);
    try mb.write(".env", "from b");

    const report = try mb.reconcile();
    const env = report.find(".env", .not_arrived).?;
    try testing.expect(env.unsettled);
    try testing.expectEqualStrings(ma.ctx.machine_id, env.detail.?);
    try testing.expectEqualStrings("from b", try mb.read(".env"));
    try testing.expect(report.find(".env", .missing_local) == null);

    try store.writeRetired(a, mb.ctx.layout, &(try indexOf(mb)), ma.ctx.machine_id, "2026-01-01", "b", "00000000000000bb");
    const retired = try mb.reconcile();
    try testing.expect(retired.find(".env", .missing_local) != null);
    try testing.expect(retired.find(".env", .not_arrived) == null);

    try ma.write(".secret", "kept after the retirement");
    _ = try ma.keep(".secret");
    try deliverFactsOnly(&w, 0, 1);
    try mb.write(".secret", "from b");
    const later = try mb.reconcile();
    const secret = later.find(".secret", .not_arrived).?;
    try testing.expectEqualStrings(ma.ctx.machine_id, secret.detail.?);
    try testing.expect(later.find(".secret", .missing_local) == null);
    try testing.expect(later.find(".env", .missing_local) != null);
}

test "reconcile: a path another machine kept, with no copy here and nothing in the working tree, is not_arrived; retired, it is retired_gone, and unkeep settles it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "from a");
    _ = try ma.keep(".env");
    try deliverFactsOnly(&w, 0, 1);

    const waiting = (try mb.reconcile()).find(".env", .not_arrived).?;
    try testing.expect(waiting.unsettled);
    try testing.expectEqualStrings(ma.ctx.machine_id, waiting.detail.?);

    var index = try indexOf(mb);
    try store.writeRetired(a, mb.ctx.layout, &index, ma.ctx.machine_id, "2026-01-01", "b", "00000000000000bb");
    const gone = (try mb.reconcile()).find(".env", .retired_gone).?;
    try testing.expect(gone.unsettled);

    _ = try unkeep(mb.ctx, &index, mb.clone, ".env", .{});
    const after = try mb.reconcile();
    for (after.items) |i| try testing.expect(!i.unsettled);
}

test "takeLocal: while another machine's kept copy has not arrived it refuses and leaves every fact; once delivered, the take sets that copy aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "from a");
    _ = try ma.keep(".env");
    try deliverFactsOnly(&w, 0, 1);
    try mb.write(".env", "from b");

    var idx = try indexOf(mb);
    try testing.expectError(error.KeptElsewhere, takeLocal(mb.ctx, &idx, mb.clone, ".env", .{}));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try mb.keptPath(".env")));
    try testing.expectEqualStrings("from b", try mb.read(".env"));
    try w.sync();
    try testing.expectEqualStrings(ma.ctx.machine_id, (try store.loadKeyState(a, ma.ctx.layout, test_key)).factsFor(".env")[0].machine);
    try testing.expect(try ma.linked(".env"));
    try testing.expectEqualStrings("from a", try ma.read(".env"));

    idx = try indexOf(mb);
    const got = try takeLocal(mb.ctx, &idx, mb.clone, ".env", .{});
    try testing.expectEqualStrings("from a", try content.readSmall(a, try aside.dataPath(a, mb.ctx.layout, got.kept_entry.?, ".env")));
    try testing.expectEqualStrings("from b", try keptBytes(mb, ".env"));
    try w.sync();
    try testing.expectEqual(@as(usize, 0), (try ma.reconcile()).unsettledCount());
    try testing.expectEqualStrings("from b", try ma.read(".env"));
}

test "keep after --retire-machine: a fact the retirement covers is no second machine, so keeping the local copy settles the path, as --take-local does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "from a");
    _ = try ma.keep(".env");
    try ma.write(".other", "from a");
    _ = try ma.keep(".other");
    try deliverFactsOnly(&w, 0, 1);
    try mb.write(".env", "from b");
    try mb.write(".other", "from b");
    try store.writeRetired(a, mb.ctx.layout, &(try indexOf(mb)), ma.ctx.machine_id, "2026-09-28", "b-host", "00000000000000bb");
    const before = try mb.reconcile();
    try testing.expect(before.find(".env", .missing_local) != null);

    _ = try mb.keep(".env");
    var idx = try indexOf(mb);
    _ = try takeLocal(mb.ctx, &idx, mb.clone, ".other", .{});
    const after = try mb.reconcile();
    try testing.expectEqual(@as(usize, 0), after.unsettledCount());
    try testing.expect(after.find(".env", .two_machines) == null);
    try testing.expect(try mb.linked(".env"));
    try testing.expect(try mb.linked(".other"));
    try testing.expectEqualStrings("from b", try keptBytes(mb, ".env"));
}

test "takeLocal: another machine's different content that aside holds here is no pending download, so two machines' keeps can be settled by a take" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "A");
    try mb.write(".env", "B");
    _ = try ma.keep(".env");
    _ = try mb.keep(".env");
    try w.deliverPath(1, 0, test_key ++ "/.holt-paths");
    try testing.expect((try ma.reconcile()).find(".env", .two_machines) != null);
    try ma.saveByRename(".env", "settled on a");

    var idx = try indexOf(ma);
    try testing.expectError(error.KeptElsewhere, takeLocal(ma.ctx, &idx, ma.clone, ".env", .{}));
    try w.deliverPath(1, 0, ".holt-aside");
    _ = try takeLocal(ma.ctx, &idx, ma.clone, ".env", .{});
    try testing.expectEqualStrings("settled on a", try keptBytes(ma, ".env"));
    try testing.expectEqual(@as(usize, 1), (try store.loadKeyState(a, ma.ctx.layout, test_key)).factsFor(".env").len);
}

test "unkeep: while another machine's kept copy has not arrived it refuses and writes nothing, so that machine keeps its facts and link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "only on a");
    _ = try ma.keep(".env");
    try deliverFactsOnly(&w, 0, 1);

    var idx = try indexOf(mb);
    try testing.expectError(error.KeptElsewhere, unkeep(mb.ctx, &idx, mb.clone, ".env", .{ .skip_line = try patterns.anchoredLine(a, ".env") }));
    const ks = try store.loadKeyState(a, mb.ctx.layout, test_key);
    try testing.expectEqual(@as(usize, 1), ks.factsFor(".env").len);
    try testing.expect(!ks.isReleased(".env"));
    try testing.expectEqualStrings("", try patterns.repoSkipText(a, mb.ctx.layout, test_key, null));

    try w.sync();
    try testing.expectEqual(@as(usize, 0), (try ma.reconcile()).unsettledCount());
    try testing.expect(try ma.linked(".env"));
    try testing.expectEqualStrings("only on a", try ma.read(".env"));
    _ = try mb.reconcile();
    try testing.expect(try mb.linked(".env"));
    try testing.expectEqualStrings("only on a", try mb.read(".env"));
}

test "purge: refuses while a working tree links the path, then sets the kept content aside and removes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "secret");
    _ = try m.keep(".env");
    const wt = try std.fs.path.join(a, &.{ sb.root, "linked-tree" });
    try m.git(&sb, &.{ "worktree", "add", "-q", wt, "-b", "side" });
    _ = try harness.reconcileIn(m.ctx, wt, .apply);
    var idx = try indexOf(m);

    try testing.expectError(error.NotReleased, purge(m.ctx, &idx, m.clone, ".env", .{ .confirmed = true }));
    _ = try unkeep(m.ctx, &idx, m.clone, ".env", .{});
    _ = try m.reconcile();
    try testing.expectError(error.StillLinked, purge(m.ctx, &idx, m.clone, ".env", .{ .confirmed = true }));
    _ = try harness.reconcileIn(m.ctx, wt, .apply);
    const got = try purge(m.ctx, &idx, m.clone, ".env", .{ .confirmed = true });
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try m.keptPath(".env")));
    try testing.expectEqualStrings("secret", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, got.entry.?, ".env")));
    try testing.expectEqualStrings(m.ctx.machine_id, got.machines[0]);
    try testing.expectEqualStrings("secret", try m.read(".env"));
    try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
}

test "unkeepRepo: every kept path is released" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "x");
    try m.write("b", "y");
    _ = try m.keep(".env");
    _ = try m.keep("b");
    const got = try unkeepRepo(m.ctx, test_key);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(usize, 0), (try (try store.loadKeyState(a, m.ctx.layout, test_key)).keptSet(a)).len);
    try testing.expectError(error.NoSuchKey, unkeepRepo(m.ctx, "github.com/none/here"));
}

test "unkeepRepo then purge: no auto pattern keeps the released path again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    const candidates = @import("candidates.zig");
    try m.write(".gitignore", ".clasp.json\n*.clasp.json\n");
    try m.git(&sb, &.{ "add", ".gitignore" });
    try m.git(&sb, &.{ "commit", "-q", "-m", "ignore" });
    try m.write(".clasp.json", "{}");
    try m.write("notes/a.clasp.json", "{}");
    _ = try patterns.createStore(a, m.ctx.layout);
    _ = try m.keep("notes");
    var idx = try indexOf(m);
    try testing.expectEqual(@as(usize, 1), (try candidates.list(m.ctx, &idx, m.clone, .{ .auto = true })).auto_kept.len);
    _ = try patterns.addLine(a, m.ctx.layout, m.ctx.machine_id, null, .auto, "*.clasp.json");

    _ = try unkeepRepo(m.ctx, test_key);
    _ = try m.reconcile();
    idx = try indexOf(m);
    _ = try purge(m.ctx, &idx, m.clone, ".clasp.json", .{ .confirmed = true });
    _ = try purge(m.ctx, &idx, m.clone, "notes", .{ .confirmed = true });
    _ = try m.reconcile();
    idx = try indexOf(m);
    const again = try candidates.list(m.ctx, &idx, m.clone, .{ .auto = true });
    try testing.expectEqual(@as(usize, 0), again.auto_kept.len);
    for ([_][]const u8{ ".clasp.json", "notes/a.clasp.json" }) |rel| {
        const cand = for (again.candidates) |cand| {
            if (std.mem.eql(u8, cand.rel, rel)) break cand;
        } else return error.TestUnexpectedResult;
        try testing.expect(cand.auto.?.why == .released);
    }
    try testing.expect(!try m.linked(".clasp.json"));
    try testing.expectEqual(content.Entry.file, try m.entry(".clasp.json"));
}

test "purge: needs confirmation, naming every machine whose fact names the path; another machine still linking it restores a copy from the purge's aside entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "v1");
    _ = try ma.keep(".env");
    try w.sync();
    _ = try mb.reconcile();
    try testing.expect(try mb.linked(".env"));

    var idx = try indexOf(mb);
    _ = try unkeep(mb.ctx, &idx, mb.clone, ".env", .{});
    _ = try mb.reconcile();
    var machines: []const []const u8 = &.{};
    try testing.expectError(error.NotConfirmed, purge(mb.ctx, &idx, mb.clone, ".env", .{ .machines = &machines }));
    try testing.expectEqual(@as(usize, 1), machines.len);
    try testing.expectEqualStrings(ma.ctx.machine_id, machines[0]);
    try testing.expectEqualStrings("v1", try keptBytes(mb, ".env"));

    const got = try purge(mb.ctx, &idx, mb.clone, ".env", .{ .confirmed = true });
    try testing.expectEqualStrings("v1", try content.readSmall(a, try aside.dataPath(a, mb.ctx.layout, got.entry.?, ".env")));
    try testing.expectEqualStrings("v1", try mb.read(".env"));

    try testing.expect(try ma.linked(".env"));
    try w.sync();
    const plan = try harness.reconcileIn(ma.ctx, ma.clone, .plan);
    try testing.expect(!plan.find(".env", .purged_restored).?.done);
    try testing.expectEqual(content.Entry.symlink, try content.entryAt(try ma.path(".env")));
    const ra = try ma.reconcile();
    const restored = ra.find(".env", .purged_restored).?;
    try testing.expect(restored.done and !restored.unsettled);
    try testing.expectEqualStrings(got.entry.?, restored.entry.?);
    try testing.expectEqual(content.Entry.file, try content.entryAt(try ma.path(".env")));
    try testing.expectEqualStrings("v1", try ma.read(".env"));
    for ((try ma.reconcile()).items) |i| try testing.expect(!i.unsettled);
    try testing.expectEqualStrings("v1", try content.readSmall(a, try aside.dataPath(a, ma.ctx.layout, got.entry.?, ".env")));
}

test "purge: another machine's restore from the purge's aside entry resumes after an interruption, and runs in each working tree that links the path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    defer interrupt.at = null;
    try ma.write(".env", "v1");
    _ = try ma.keep(".env");
    const wt_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(ma.clone).?, "widget@worktrees", "feature" });
    try ma.git(&sb, &.{ "worktree", "add", "-q", "-b", "feature", wt_path });
    const wt = try fsutil.realPathOrSelf(a, try std.fs.path.resolve(a, &.{wt_path}));
    try testing.expect((try harness.reconcileIn(ma.ctx, wt, .apply)).find(".env", .linked).?.done);
    try w.sync();
    _ = try mb.reconcile();

    var idx = try indexOf(mb);
    _ = try unkeep(mb.ctx, &idx, mb.clone, ".env", .{});
    _ = try mb.reconcile();
    const got = try purge(mb.ctx, &idx, mb.clone, ".env", .{ .confirmed = true });
    try w.sync();

    interrupt.at = .convert_copied;
    _ = (try ma.reconcile()).find(".env", .failed).?;
    interrupt.at = null;
    try testing.expectEqual(content.Entry.symlink, try content.entryAt(try ma.path(".env")));
    const resumed = (try ma.reconcile()).find(".env", .purged_restored).?;
    try testing.expect(resumed.done);
    try testing.expectEqualStrings(got.entry.?, resumed.entry.?);
    try testing.expectEqualStrings("v1", try ma.read(".env"));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try fsutil.joinSlashy(a, ma.clone, try paths.tempRel(a, ".env"))));

    try testing.expect((try harness.reconcileIn(ma.ctx, wt, .apply)).find(".env", .purged_restored).?.done);
    try testing.expectEqualStrings("v1", try content.readSmall(a, try fsutil.joinSlashy(a, wt, ".env")));
    for ((try ma.reconcile()).items) |i| try testing.expect(!i.unsettled);
    for ((try harness.reconcileIn(ma.ctx, wt, .apply)).items) |i| try testing.expect(!i.unsettled);
}

test "purge: with the purge's aside entry pruned, another machine's link is removed; a released marker with no purge mark leaves the link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "v1");
    _ = try ma.keep(".env");
    try ma.write(".clasp.json", "{}");
    _ = try ma.keep(".clasp.json");
    try w.sync();
    _ = try mb.reconcile();

    try store.writeReleased(a, ma.ctx.layout, test_key, ".clasp.json");
    try store.removeFacts(a, ma.ctx.layout, test_key, ".clasp.json");
    try fsutil.removePath(try ma.ctx.layout.copyPath(a, test_key, ".clasp.json"));
    const early = try ma.reconcile();
    try testing.expect(early.find(".clasp.json", .purged_link_removed) == null);
    try testing.expect(early.find(".clasp.json", .released_missing) != null);
    try testing.expectEqual(content.Entry.symlink, try content.entryAt(try ma.path(".clasp.json")));

    var idx = try indexOf(mb);
    _ = try unkeep(mb.ctx, &idx, mb.clone, ".env", .{});
    _ = try mb.reconcile();
    const got = try purge(mb.ctx, &idx, mb.clone, ".env", .{ .confirmed = true });
    var bidx = try indexOf(mb);
    const now_ms: i64 = @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms))) + (young_days + 1) * std.time.ms_per_day;
    const info = for (try asideEntries(mb.ctx, &bidx, now_ms, &Referenced{}, .verified)) |e| {
        if (std.mem.eql(u8, e.stamp, got.entry.?)) break e;
    } else return error.TestUnexpectedResult;
    try testing.expect(try pruneEntry(mb.ctx, info));
    try testing.expect(try store.isPruned(a, mb.ctx.layout, got.entry.?));
    try w.sync();
    const ra = try ma.reconcile();
    const removed = ra.find(".env", .purged_link_removed).?;
    try testing.expect(removed.done and !removed.unsettled);
    try testing.expectEqualStrings(got.entry.?, removed.entry.?);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try ma.path(".env")));
    try testing.expect(!paths.contains((try block.read(a, try std.fs.path.join(a, &.{ ma.clone, ".git" }))).rels, ".env"));
}

test "purge: a purge mark that arrives before its aside entry leaves the link unsettled, and the entry arriving later restores the copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "v1");
    _ = try ma.keep(".env");
    try w.sync();
    _ = try mb.reconcile();

    var idx = try indexOf(mb);
    _ = try unkeep(mb.ctx, &idx, mb.clone, ".env", .{});
    _ = try mb.reconcile();
    const got = try purge(mb.ctx, &idx, mb.clone, ".env", .{ .confirmed = true });
    try w.deliverPath(1, 0, test_key);
    const early = (try ma.reconcile()).find(".env", .purged_pending).?;
    try testing.expect(early.unsettled and !early.done);
    try testing.expectEqualStrings(got.entry.?, early.entry.?);
    try testing.expectEqual(content.Entry.symlink, try content.entryAt(try ma.path(".env")));

    try w.deliverPath(1, 0, ".holt-aside");
    try testing.expect((try ma.reconcile()).find(".env", .purged_restored).?.done);
    try testing.expectEqualStrings("v1", try ma.read(".env"));
}

test "purge: an aside entry the purge names that arrives partly leaves the link unsettled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "v1");
    _ = try ma.keep(".env");
    try w.sync();
    _ = try mb.reconcile();

    var idx = try indexOf(mb);
    _ = try unkeep(mb.ctx, &idx, mb.clone, ".env", .{});
    _ = try mb.reconcile();
    const got = try purge(mb.ctx, &idx, mb.clone, ".env", .{ .confirmed = true });
    try w.sync();
    try fsutil.removePath(try aside.dataPath(a, ma.ctx.layout, got.entry.?, ".env"));
    const partial = (try ma.reconcile()).find(".env", .purged_pending).?;
    try testing.expect(partial.unsettled and !partial.done);
    try testing.expectEqual(content.Entry.symlink, try content.entryAt(try ma.path(".env")));
}

test "purge: an aside entry the purge names that holds other content leaves the link unsettled for the user to look at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "v1");
    _ = try ma.keep(".env");
    try w.sync();
    _ = try mb.reconcile();

    var idx = try indexOf(mb);
    _ = try unkeep(mb.ctx, &idx, mb.clone, ".env", .{});
    _ = try mb.reconcile();
    const got = try purge(mb.ctx, &idx, mb.clone, ".env", .{ .confirmed = true });
    try w.sync();
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try aside.dataPath(a, ma.ctx.layout, got.entry.?, ".env"), .data = "changed" });
    const item = (try ma.reconcile()).find(".env", .purged_unrestorable).?;
    try testing.expect(item.unsettled and !item.done);
    try testing.expectEqual(content.Entry.symlink, try content.entryAt(try ma.path(".env")));
}

test "pruneEntry: interrupted once the entry is recorded pruned, the entry is still whole, another machine restores from it, and the prune can run again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    defer interrupt.at = null;
    try ma.write(".env", "v1");
    _ = try ma.keep(".env");
    try w.sync();
    _ = try mb.reconcile();

    var idx = try indexOf(mb);
    _ = try unkeep(mb.ctx, &idx, mb.clone, ".env", .{});
    _ = try mb.reconcile();
    const got = try purge(mb.ctx, &idx, mb.clone, ".env", .{ .confirmed = true });
    const now_ms: i64 = @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms))) + (young_days + 1) * std.time.ms_per_day;
    const info = for (try asideEntries(mb.ctx, &idx, now_ms, &Referenced{}, .verified)) |e| {
        if (std.mem.eql(u8, e.stamp, got.entry.?)) break e;
    } else return error.TestUnexpectedResult;
    interrupt.at = .prune_marked;
    try testing.expectError(error.Interrupted, pruneEntry(mb.ctx, info));
    interrupt.at = null;
    try testing.expect(try store.isPruned(a, mb.ctx.layout, got.entry.?));
    try testing.expectEqual(aside.Check.ok, try aside.verify(a, mb.ctx.layout, got.entry.?));

    try w.sync();
    try testing.expect((try ma.reconcile()).find(".env", .purged_restored).?.done);
    try testing.expectEqualStrings("v1", try ma.read(".env"));
    try testing.expect(try pruneEntry(mb.ctx, info));
    try testing.expectEqual(aside.Check.missing, try aside.verify(a, mb.ctx.layout, got.entry.?));
}

test "pruneEntry: records the prune in a file of its own and leaves the released marker as it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "v1");
    _ = try ma.keep(".env");
    try w.sync();
    _ = try mb.reconcile();

    var idx = try indexOf(mb);
    _ = try unkeep(mb.ctx, &idx, mb.clone, ".env", .{});
    _ = try mb.reconcile();
    const got = try purge(mb.ctx, &idx, mb.clone, ".env", .{ .confirmed = true });
    const sid = paths.id(".env");
    const marker = try std.fs.path.join(a, &.{ try mb.ctx.layout.reserved(a, test_key, ".holt-released"), &sid });
    const before = try content.readSmall(a, marker);
    const now_ms: i64 = @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms))) + (young_days + 1) * std.time.ms_per_day;
    const info = for (try asideEntries(mb.ctx, &idx, now_ms, &Referenced{}, .verified)) |e| {
        if (std.mem.eql(u8, e.stamp, got.entry.?)) break e;
    } else return error.TestUnexpectedResult;
    try testing.expect(info.purge);
    try testing.expect(try pruneEntry(mb.ctx, info));
    try testing.expectEqualStrings(before, try content.readSmall(a, marker));
    try testing.expect(try store.isPruned(a, mb.ctx.layout, got.entry.?));
    try testing.expectEqual(content.Entry.file, try content.entryAt(try std.fs.path.join(a, &.{ try mb.ctx.layout.keptDir(a), store.pruned_basename, got.entry.? })));

    try w.sync();
    try testing.expect((try ma.reconcile()).find(".env", .purged_link_removed).?.done);
}

test "asideEntries: an entry with no manifest yet is held as recent while its stamp or its newest content is less than a day old, and then as not here whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    const entry = try std.fs.path.join(a, &.{ try m.ctx.layout.asideDir(a), "20000101T000000.000Z-000000000000000b-arriving" });
    try fsutil.ensureDir(try std.fs.path.join(a, &.{ entry, "data" }));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ entry, "data", ".env" }), .data = "downloading" });
    const idx = try indexOf(m);
    const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms));

    const now = try asideEntries(m.ctx, &idx, now_ms, &Referenced{}, .verified);
    try testing.expectEqual(@as(usize, 1), now.len);
    try testing.expect(now[0].held == .recent);
    const later = try asideEntries(m.ctx, &idx, now_ms + 2 * std.time.ms_per_day, &Referenced{}, .verified);
    try testing.expect(later[0].held == .young);
    const old = try asideEntries(m.ctx, &idx, now_ms + (young_days + 1) * std.time.ms_per_day, &Referenced{}, .verified);
    try testing.expect(old[0].held == .partial);
}

test "pruneEntry: the data goes before the manifest, so an interrupted prune leaves an entry that says what it was, held as not here whole, which can be pruned again" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "x");
    const kept_ = try m.keep(".env");
    const idx = try indexOf(m);
    const now_ms: i64 = @as(i64, @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms))) + (young_days + 1) * std.time.ms_per_day;
    const info = for (try asideEntries(m.ctx, &idx, now_ms, &Referenced{}, .verified)) |e| {
        if (std.mem.eql(u8, e.stamp, kept_.entry.?)) break e;
    } else return error.TestUnexpectedResult;

    interrupt.at = .prune_data;
    defer interrupt.at = null;
    try testing.expectError(error.Interrupted, pruneEntry(m.ctx, info));
    interrupt.at = null;
    const left = (try asideEntries(m.ctx, &idx, now_ms, &Referenced{}, .verified))[0];
    try testing.expect(left.manifest != null);
    try testing.expect(left.held == .partial);
    try testing.expect(try pruneEntry(m.ctx, left));
    try testing.expectEqual(@as(usize, 0), (try asideEntries(m.ctx, &idx, now_ms, &Referenced{}, .verified)).len);
}

test "asideEntries and pruneEntry: an unsettled two-machine side is held, an unreadable entry is held, an entry less than 30 days old is held, the rest go" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".clasp.json", "A");
    try mb.write(".clasp.json", "B");
    try ma.write("other", "o");
    _ = try ma.keep(".clasp.json");
    _ = try ma.keep("other");
    _ = try mb.keep(".clasp.json");
    try w.sync();
    try fsutil.ensureDir(try std.fs.path.join(a, &.{ try ma.ctx.layout.asideDir(a), "half-made" }));

    var idx = try indexOf(ma);
    const now = std.Io.Clock.real.now(io()).nanoseconds;
    const now_ms: i64 = @intCast(@divFloor(now, std.time.ns_per_ms));
    var two: usize = 0;
    var recent: usize = 0;
    var young: usize = 0;
    for (try asideEntries(ma.ctx, &idx, now_ms, &Referenced{}, .verified)) |e| switch (e.held orelse return error.TestUnexpectedResult) {
        .two_machines => two += 1,
        .recent => recent += 1,
        .young => young += 1,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), two);
    try testing.expectEqual(@as(usize, 1), recent);
    try testing.expectEqual(@as(usize, 1), young);

    var held: usize = 0;
    var pruned: usize = 0;
    for (try asideEntries(ma.ctx, &idx, now_ms + (young_days + 1) * std.time.ms_per_day, &Referenced{}, .verified)) |e| {
        if (e.manifest == null) {
            try testing.expect(e.held == .partial);
            continue;
        }
        if (e.held != null) {
            held += 1;
            continue;
        }
        if (try pruneEntry(ma.ctx, e)) pruned += 1;
    }
    try testing.expectEqual(@as(usize, 2), held);
    try testing.expectEqual(@as(usize, 1), pruned);
}

test "asideEntries: an entry whose stamp names a time long past is young while it arrived here less than 30 days ago" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "x");
    const kept_ = try m.keep(".env");
    const dir = try m.ctx.layout.asideDir(a);
    const old = "20000101T000000.000Z-000000000000000b-slowclock";
    try std.Io.Dir.renameAbsolute(try std.fs.path.join(a, &.{ dir, kept_.entry.? }), try std.fs.path.join(a, &.{ dir, old }), io());
    const idx = try indexOf(m);
    const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms));

    const now = try asideEntries(m.ctx, &idx, now_ms, &Referenced{}, .verified);
    try testing.expectEqual(@as(usize, 1), now.len);
    try testing.expectEqualStrings(old, now[0].stamp);
    try testing.expect(now[0].held == .young);
    const later = try asideEntries(m.ctx, &idx, now_ms + (young_days + 1) * std.time.ms_per_day, &Referenced{}, .verified);
    try testing.expect(later[0].held == null);
}

test "stampTime: reads a stamp's UTC time and refuses anything else" {
    try testing.expectEqual(@as(?i64, 0), stampTime("19700101T000000.000Z-x"));
    try testing.expectEqual(@as(?i64, 951782400123), stampTime("20000229T000000.123Z-m-r"));
    try testing.expect(stampTime("half-made") == null);
    try testing.expect(stampTime("20001301T000000.000Z-x") == null);
}

test "ensureCloneKey: creates the key and its record once, with keep's checks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    var idx = try indexOf(m);
    try testing.expectEqualStrings(test_key, try ensureCloneKey(m.ctx, &idx, m.clone, null));
    const rec = (try store.readRecord(a, m.ctx.layout, test_key)).?;
    try testing.expect(rec.root != null);
    try testing.expectEqualStrings(test_key, try ensureCloneKey(m.ctx, &idx, m.clone, null));
    _ = reconcile_mod;
}

test "takeLocal: what the block hides in another working tree is set aside by the closing sweep, and a take in a linked tree records its own pending" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "kept");
    _ = try m.keep(".env");
    const wt = try std.fs.path.join(a, &.{ sb.root, "other-tree" });
    try m.git(&sb, &.{ "worktree", "add", "-q", wt, "-b", "side" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ wt, ".env" }), .data = "only in the other tree" });

    try m.saveByRename(".env", "new");
    var idx = try indexOf(m);
    const got = try takeLocal(m.ctx, &idx, m.clone, ".env", .{});
    var found = false;
    for (got.hidden) |h| {
        if (!std.mem.eql(u8, h.found.worktree, try fsutil.realPathOrSelf(a, wt))) continue;
        const e = h.entry orelse continue;
        if (std.mem.eql(u8, try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, e, ".env")), "only in the other tree")) found = true;
    }
    try testing.expect(found);
    try testing.expectEqualStrings("only in the other tree", try content.readSmall(a, try std.fs.path.join(a, &.{ wt, ".env" })));

    interrupt.at = .take_pending;
    defer interrupt.at = null;
    try std.Io.Dir.cwd().deleteFile(io(), try std.fs.path.join(a, &.{ wt, ".env" }));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ wt, ".env" }), .data = "tree edit" });
    try testing.expectError(error.Interrupted, takeKept(m.ctx, &idx, wt, ".env", .{}));
    interrupt.at = null;
    const c = try clone.inspect(a, wt, m.ctx.code_root);
    const rec = clone.findPending(try clone.readPending(a, c.common_dir), c.tree, ".env").?;
    try testing.expect(std.mem.startsWith(u8, rec.tree, "worktrees/"));
    try testing.expect(clone.findPending(try clone.readPending(a, c.common_dir), ".", ".env") == null);
    _ = try takeKept(m.ctx, &idx, wt, ".env", .{});
    try testing.expectEqualStrings("new", try content.readSmall(a, try std.fs.path.join(a, &.{ wt, ".env" })));
    try testing.expectEqualStrings("new", try m.read(".env"));
}

test "takeLocal and takeKept: a path git tracks is refused and left alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write("cfg.local", "kept");
    _ = try m.keep("cfg.local");
    try m.saveByRename("cfg.local", "local");
    try m.git(&sb, &.{ "add", "-f", "cfg.local" });
    var idx = try indexOf(m);
    try testing.expectError(error.Tracked, takeLocal(m.ctx, &idx, m.clone, "cfg.local", .{}));
    try testing.expectError(error.Tracked, takeKept(m.ctx, &idx, m.clone, "cfg.local", .{}));
    try testing.expectEqualStrings("local", try m.read("cfg.local"));
    try testing.expectEqualStrings("kept", try keptBytes(m, "cfg.local"));
}

test "takeFrom interrupted between paths: rerunning copies the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    const old_key = "github.com/old/widget";
    const root = (try clone.defaultRoot(a, m.clone)).?;
    var idx = try indexOf(m);
    _ = try store.ensureKey(a, m.ctx.layout, &idx, old_key, null, root, &.{root});
    for ([_][]const u8{ "a.env", "b.env" }) |rel| {
        const p = try m.ctx.layout.copyPath(a, old_key, rel);
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = rel });
        const h = try content.hashPath(a, p);
        try store.writeFact(a, m.ctx.layout, old_key, "000000000000000f", rel, .file, &h.hex);
    }
    idx = try indexOf(m);
    interrupt.at = .from_copied;
    defer interrupt.at = null;
    try testing.expectError(error.Interrupted, takeFrom(m.ctx, &idx, m.clone, old_key, .{}));
    interrupt.at = null;
    idx = try indexOf(m);
    const got = try takeFrom(m.ctx, &idx, m.clone, old_key, .{});
    try testing.expectEqual(@as(usize, 1), got.copied.len);
    try testing.expectEqual(@as(usize, 1), got.present.len);
    try testing.expectEqualStrings("a.env", try keptBytes(m, "a.env"));
    try testing.expectEqualStrings("b.env", try keptBytes(m, "b.env"));
}

test "purge interrupted while setting aside: the kept content stays, and rerunning removes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    defer interrupt.at = null;
    for ([_]interrupt.Point{ .aside_copied, .aside_manifest }) |point| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try World.init(a, &sb, 1);
        const m = w.m(0);
        try m.write(".env", "x");
        _ = try m.keep(".env");
        var idx = try indexOf(m);
        _ = try unkeep(m.ctx, &idx, m.clone, ".env", .{});
        _ = try m.reconcile();
        interrupt.at = point;
        try testing.expectError(error.Interrupted, purge(m.ctx, &idx, m.clone, ".env", .{ .confirmed = true }));
        interrupt.at = null;
        try testing.expectEqualStrings("x", try keptBytes(m, ".env"));
        const got = try purge(m.ctx, &idx, m.clone, ".env", .{ .confirmed = true });
        try testing.expectEqual(aside.Check.ok, try aside.verify(a, m.ctx.layout, got.entry.?));
        try testing.expectEqual(content.Entry.absent, try content.entryAt(try m.keptPath(".env")));
    }
}

test "an interrupted take whose path is then given up clears its pending record, and reconcile stops naming it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "kept");
    const first = try m.keep(".env");
    try m.saveByRename(".env", "local");
    var idx = try indexOf(m);
    interrupt.at = .take_aside;
    defer interrupt.at = null;
    try testing.expectError(error.Interrupted, takeKept(m.ctx, &idx, m.clone, ".env", .{}));
    interrupt.at = null;
    try std.Io.Dir.cwd().deleteFile(io(), try m.path(".env"));
    try testing.expectError(error.FileNotFound, takeKept(m.ctx, &idx, m.clone, ".env", .{}));
    const report = try m.reconcile();
    try testing.expect(report.find(".env", .interrupted) == null);
    try testing.expect(try m.linked(".env"));

    interrupt.at = .take_pending;
    try testing.expectError(error.Interrupted, takeAside(m.ctx, &idx, first.entry.?, m.clone));
    interrupt.at = null;
    try std.Io.Dir.cwd().deleteTree(io(), try std.fs.path.join(a, &.{ try m.ctx.layout.asideDir(a), first.entry.? }));
    try testing.expectError(error.NoSuchEntry, takeAside(m.ctx, &idx, first.entry.?, m.clone));
    try testing.expect((try m.reconcile()).find(".env", .interrupted) == null);
}

test "takeFrom: a copy placed before its fact gets the fact on rerun, and a path inside a kept directory is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    const old_key = "github.com/old/widget";
    const root = (try clone.defaultRoot(a, m.clone)).?;
    var idx = try indexOf(m);
    _ = try store.ensureKey(a, m.ctx.layout, &idx, old_key, null, root, &.{root});
    _ = try ensureCloneKey(m.ctx, &idx, m.clone, null);
    for ([_][]const u8{ try m.ctx.layout.copyPath(a, old_key, "a.env"), try m.keptPath("a.env") }) |p| try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = "a" });
    const h = try content.hashPath(a, try m.ctx.layout.copyPath(a, old_key, "a.env"));
    try store.writeFact(a, m.ctx.layout, old_key, "000000000000000f", "a.env", .file, &h.hex);
    idx = try indexOf(m);
    const got = try takeFrom(m.ctx, &idx, m.clone, old_key, .{});
    try testing.expectEqual(@as(usize, 1), got.present.len);
    try testing.expectEqual(@as(usize, 1), (try store.loadKeyState(a, m.ctx.layout, test_key)).factsFor("a.env").len);

    try m.write("notes/x", "x");
    _ = try m.keep("notes");
    const op = try m.ctx.layout.copyPath(a, old_key, "notes/y");
    try fsutil.ensureDir(std.fs.path.dirname(op).?);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = op, .data = "y" });
    const hy = try content.hashPath(a, op);
    try store.writeFact(a, m.ctx.layout, old_key, "000000000000000f", "notes/y", .file, &hy.hex);
    idx = try indexOf(m);
    var nested: []const []const u8 = &.{};
    try testing.expectError(error.NestsInKept, takeFrom(m.ctx, &idx, m.clone, old_key, .{ .conflicts = &nested }));
    try testing.expectEqualStrings("notes/y", nested[0]);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try m.keptPath("notes/y")));
}

test "a retired machine's facts never block: keep, takeLocal, and unkeep go ahead where its kept copy never arrived" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "only on a, which died");
    try ma.write("kept.txt", "also only on a");
    try ma.write("gone.txt", "a's too");
    _ = try ma.keep(".env");
    _ = try ma.keep("kept.txt");
    _ = try ma.keep("gone.txt");
    try deliverFactsOnly(&w, 0, 1);
    try mb.write(".env", "b's own");
    try mb.write("kept.txt", "b's own too");

    var idx = try indexOf(mb);
    try testing.expectError(error.KeptElsewhere, takeLocal(mb.ctx, &idx, mb.clone, ".env", .{}));
    try testing.expectError(error.KeptElsewhere, place.keepPath(mb.ctx, &idx, mb.clone, "kept.txt", .{}));
    try testing.expectError(error.KeptElsewhere, unkeep(mb.ctx, &idx, mb.clone, "gone.txt", .{}));

    try store.writeRetired(a, mb.ctx.layout, &idx, ma.ctx.machine_id, "2026-09-28", "b-host", "00000000000000bb");
    try testing.expectEqualStrings("2026-09-28", (try store.readRetired(a, mb.ctx.layout, ma.ctx.machine_id)).?.date);
    idx = try indexOf(mb);
    _ = try takeLocal(mb.ctx, &idx, mb.clone, ".env", .{});
    try testing.expectEqualStrings("b's own", try keptBytes(mb, ".env"));
    try testing.expect((try place.keepPath(mb.ctx, &idx, mb.clone, "kept.txt", .{})).status == .kept);
    try testing.expectEqualStrings("b's own too", try keptBytes(mb, "kept.txt"));
    try testing.expect((try unkeep(mb.ctx, &idx, mb.clone, "gone.txt", .{})).status == .gone);
}

test "machines: every machine with a fact, its host label, the date of its newest fact, and its retirement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "a");
    _ = try ma.keep(".env");
    try w.sync();
    try store.writeHost(a, mb.ctx.layout, ma.ctx.machine_id, "old-laptop");
    const idx = try indexOf(mb);
    try store.writeRetired(a, mb.ctx.layout, &idx, "00000000000000ff", "2026-01-02", "b-host", "00000000000000bb");

    const list = try store.machines(a, mb.ctx.layout, &idx);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings(ma.ctx.machine_id, list[0].id);
    try testing.expectEqualStrings("old-laptop", list[0].host.?);
    try testing.expect(list[0].last_fact != null);
    try testing.expect(list[0].retired == null);
    try testing.expectEqualStrings("00000000000000ff", list[1].id);
    try testing.expect(list[1].last_fact == null);
    try testing.expectEqualStrings("2026-01-02", list[1].retired.?.date);
    try testing.expectError(error.InvalidMachineId, store.writeRetired(a, mb.ctx.layout, &idx, "not-an-id", "2026-01-02", "b", "00000000000000bb"));
}

test "a retirement covers the facts the machine had then: one it writes later blocks keep until its content arrives, and retiring again covers it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "a");
    _ = try ma.keep(".env");
    try store.writeRetired(a, ma.ctx.layout, &(try indexOf(ma)), ma.ctx.machine_id, "2026-09-28", "a-host", "00000000000000bb");
    try w.sync();
    try ma.write("late.txt", "a's new only copy");
    _ = try ma.keep("late.txt");
    try deliverFactsOnly(&w, 0, 1);
    try mb.write("late.txt", "b's");
    var idx = try indexOf(mb);
    try testing.expectError(error.KeptElsewhere, place.keepPath(mb.ctx, &idx, mb.clone, "late.txt", .{}));
    try testing.expectError(error.KeptElsewhere, takeLocal(mb.ctx, &idx, mb.clone, "late.txt", .{}));

    var list = try store.machines(a, mb.ctx.layout, &idx);
    try testing.expect(list[0].retired != null and list[0].active_again);

    try store.writeRetired(a, mb.ctx.layout, &idx, ma.ctx.machine_id, "2026-09-29", "b-host", "00000000000000bb");
    list = try store.machines(a, mb.ctx.layout, &idx);
    try testing.expect(!list[0].active_again);
    try testing.expect((try place.keepPath(mb.ctx, &idx, mb.clone, "late.txt", .{})).status == .kept);
}

test "a retired machine's fact rewritten with other bytes is not covered by the retirement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "first");
    _ = try ma.keep(".env");
    try deliverFactsOnly(&w, 0, 1);
    var idx = try indexOf(mb);
    try store.writeRetired(a, mb.ctx.layout, &idx, ma.ctx.machine_id, "2026-09-28", "b-host", "00000000000000bb");
    const ks = try store.loadKeyState(a, mb.ctx.layout, test_key);
    try testing.expect(try store.factRetired(a, mb.ctx.layout, test_key, ks.factsFor(".env")[0]));

    try store.writeFact(a, ma.ctx.layout, test_key, ma.ctx.machine_id, ".env", .file, &(try content.hashFile(a, try writeProbe(a, sb.root, "second"))));
    try deliverFactsOnly(&w, 0, 1);
    const later = try store.loadKeyState(a, mb.ctx.layout, test_key);
    try testing.expect(!try store.factRetired(a, mb.ctx.layout, test_key, later.factsFor(".env")[0]));
    try mb.write(".env", "b's");
    idx = try indexOf(mb);
    try testing.expectError(error.KeptElsewhere, takeLocal(mb.ctx, &idx, mb.clone, ".env", .{}));
}

test "takeLocal: a retired machine's fact rewritten back to the bytes its retirement listed still stands, and its copy, in no aside entry here, blocks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "X");
    _ = try ma.keep(".env");
    try w.sync();
    _ = try mb.reconcile();

    var idx = try indexOf(mb);
    try store.writeRetired(a, mb.ctx.layout, &idx, ma.ctx.machine_id, "2026-09-28", "b-host", mb.ctx.machine_id);

    try fsutil.removePath(try ma.path(".env"));
    try ma.write(".env", "Y");
    var ia = try indexOf(ma);
    _ = try takeLocal(ma.ctx, &ia, ma.clone, ".env", .{});
    try w.sync();
    try testing.expectEqualStrings("Y", try keptBytes(mb, ".env"));

    try fsutil.removePath(try ma.path(".env"));
    try ma.write(".env", "X");
    ia = try indexOf(ma);
    _ = try takeLocal(ma.ctx, &ia, ma.clone, ".env", .{});
    try deliverFactsOnly(&w, 0, 1);
    try testing.expectEqualStrings("Y", try keptBytes(mb, ".env"));
    const x_hex = (try store.loadKeyState(a, mb.ctx.layout, test_key)).factsFor(".env")[0].sha256;
    for (try aside.findEntries(a, mb.ctx.layout, test_key, ".env", x_hex)) |stamp| {
        try std.Io.Dir.cwd().deleteTree(fsutil.io(), try std.fs.path.join(a, &.{ try mb.ctx.layout.asideDir(a), stamp }));
    }

    try fsutil.removePath(try mb.path(".env"));
    try mb.write(".env", "Z");
    idx = try indexOf(mb);
    const ks = try store.loadKeyState(a, mb.ctx.layout, test_key);
    try testing.expect(!try store.factRetired(a, mb.ctx.layout, test_key, ks.factsFor(".env")[0]));
    try testing.expectError(error.KeptElsewhere, takeLocal(mb.ctx, &idx, mb.clone, ".env", .{}));
}

test "asideEntries: once one of two machines that kept different content is retired, neither side's entry is held as a conflict reconcile no longer reports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    try ma.write(".env", "A");
    try mb.write(".env", "B");
    _ = try ma.keep(".env");
    _ = try mb.keep(".env");
    try w.deliverPath(1, 0, test_key ++ "/.holt-paths");
    try w.deliverPath(1, 0, ".holt-aside");
    try testing.expect((try ma.reconcile()).find(".env", .two_machines) != null);
    const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms));
    var idx = try indexOf(ma);
    var held: usize = 0;
    for (try asideEntries(ma.ctx, &idx, now_ms, &.{}, .verified)) |e| {
        if (e.held == .two_machines) held += 1;
    }
    try testing.expect(held > 0);

    try store.writeRetired(a, ma.ctx.layout, &idx, mb.ctx.machine_id, "2026-09-28", "a-host", ma.ctx.machine_id);
    try testing.expect((try ma.reconcile()).find(".env", .two_machines) == null);
    idx = try indexOf(ma);
    for (try asideEntries(ma.ctx, &idx, now_ms, &.{}, .verified)) |e| try testing.expect(e.held != .two_machines);
}
