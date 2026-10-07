//! Brings one working tree's links in line with the kept set, under the
//! clone's lock and the key's. Every visited path gets the first state that
//! matches it, a closing sweep sets aside whatever the block still hides
//! from git in any working tree of the clone that no state set aside, and
//! the result is a report of what was done or would be done and of every
//! state left unsettled. Nothing here prints.

const std = @import("std");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const aside = @import("aside.zig");
const block = @import("block.zig");
const clone = @import("clone.zig");
const link = @import("link.zig");
const place = @import("place.zig");
const sweep_mod = @import("sweep.zig");
const ctx_mod = @import("ctx.zig");
const machine = @import("machine.zig");
const testing = std.testing;

const io = fsutil.io;
const Ctx = ctx_mod.Ctx;

pub const Mode = enum {
    /// Act on every state.
    apply,
    /// Act only where no content changes: create links (5), remove a
    /// dangling link no fact names (6), retarget when the old target is gone
    /// or identical (8), replace identical local content (10), and remove
    /// holt's links from a clone its `local/` key does not match. Only links
    /// are removed, never content. Like `apply`, it may probe how the
    /// filesystem compares names (`clone.folding`).
    fix,
    /// Decide every action and write nothing but a file removed at once:
    /// the one probing how the filesystem compares names, only inside the
    /// clone's state directory when that already exists, and the one git
    /// reads the block's lines from, there or in holt's machine-local
    /// state directory (`sweep.Scope.excludeDirs`).
    plan,
};

/// What reconcile found or did at one path. Each variant names the state
/// (1 to 10, in the order they are evaluated) it belongs to.
pub const Outcome = enum {
    /// No state: the path fails validation, collides with another kept
    /// path, or enters or contains a nested key; the detail says which.
    /// Local content at a path inside the working tree (`paths.contained`)
    /// is set aside and left unsettled, unless it is the very file of the
    /// kept path it collides with; a path outside it is never touched.
    invalid,
    /// No state: a parent component in the working tree is not a real
    /// directory. Local content reached there is set aside and left
    /// unsettled.
    parent_not_dir,
    /// 1: tracked in this working tree's HEAD or index.
    tracked,
    /// 1: tracked, and holt's link there was removed.
    tracked_link_removed,
    /// 2: an interrupted keep or `--take-*` of the path; or, outside
    /// `apply`, a temporary an interrupted write left beside it.
    interrupted,
    /// 2: a temporary an interrupted write left beside the path was settled;
    /// the detail is how (`place.Settled.How`), and `entry` holds its
    /// content when it was set aside before being removed. The path is then
    /// judged as usual.
    temp_settled,
    /// 2: a temporary an interrupted write left beside the path cannot be
    /// settled, since what is at the path now is not what the write left
    /// (it may be tracked); rerunning the write will not help. Its content
    /// is set aside (`entry`) and it stays in place (the detail). The hint
    /// names the aside entry and `git status`.
    temp_stuck,
    /// 2: the local content at a path whose temporary is stuck; set aside
    /// and left in place.
    temp_stuck_local,
    /// 3: released, and holt's link replaced by a regular copy.
    released_converted,
    /// 3: released, with local content there, left alone.
    released_local,
    /// 3: released, and holt's link has no target to copy, here or in the
    /// current kept copy.
    released_missing,
    /// 3: released and purged on another machine (its released marker is
    /// marked purged, no fact names it, and its kept copy is gone), and the
    /// purge recorded no aside entry, or the entry was pruned
    /// (`store.isPruned`) and no whole copy of it is here: holt's link, which points at
    /// nothing, was removed, and its block line goes with it. `entry` names
    /// the aside entry the purge recorded, if any.
    purged_link_removed,
    /// 3: released and purged on another machine: holt's link was replaced
    /// by a verified copy of the purge's aside entry, `entry`.
    purged_restored,
    /// 3: released and purged on another machine, and the purge's aside
    /// entry, `entry`, not pruned, is absent, partly here, or online-only:
    /// it may still be arriving. holt's link is left.
    purged_pending,
    /// 3: released and purged on another machine, and the purge's aside
    /// entry, `entry`, not pruned, is here but does not hold a whole
    /// verified copy of the path, so holt's link is left.
    purged_unrestorable,
    /// 4: facts from two machines name different content.
    two_machines,
    /// 5: a link to the kept copy was created.
    linked,
    /// 5: outside the sparse checkout, so not linked.
    outside_sparse,
    /// 3, 5, or 8: the copy the action needs is online-only, so it is
    /// neither read nor linked to.
    online_only,
    /// 5, 8, or 10: this machine cannot create symlinks; nothing moved.
    no_symlink_privilege,
    /// 6: holt's link to an absent kept copy no fact names was removed.
    dangling_removed,
    /// 6: the clone's `local/` key was promoted; the detail is the new key.
    awaiting_promote,
    /// 6: holt's link points into another synced root that still has the
    /// copy; the detail is that root. The link is left.
    in_old_root,
    /// 6: holt's link points into another key of the chain that still has
    /// the copy. The link is left.
    pending_move,
    /// 6: holt's link, and no kept copy to point it at.
    missing,
    /// 6: local content, and no kept copy.
    missing_local,
    /// 6 or 10: another machine's fact names the path, and the kept copy is
    /// absent or holds other content than that fact, which no aside entry
    /// here holds (`place.awaitedFact`): the content may still be on its way.
    /// Local content is set aside and left in place, and holt's link is
    /// left. The detail is that machine's id.
    not_arrived,
    /// 6: nothing on either side yet, though this machine's fact names the
    /// path.
    not_present,
    /// 6: nothing on either side, and only facts a retirement covers name
    /// the path: no machine that still keeps it will deliver the copy.
    /// `entries` are the aside entries holding a copy those facts name.
    retired_gone,
    /// 7: holt's link to the kept copy is in place.
    ok,
    /// 8: holt's link was pointed at the current kept copy.
    retargeted,
    /// 8: holt's link points somewhere that cannot be read.
    old_unreadable,
    /// 8: the old location holds different content, set aside first.
    old_differs,
    /// 9: the kept copy is a symlink or not a regular file or directory.
    kept_not_regular,
    /// 9: the kept copy's kind differs from its facts'.
    kind_mismatch,
    /// 9: the kept directory holds a name holt reserves; the detail is its
    /// path there.
    kept_reserved,
    /// 9, also at a released path: a link holt did not make; the detail is
    /// its target.
    foreign_link,
    /// 10: local content identical to the kept copy was replaced by a link.
    relinked,
    /// 10: local content differs from the kept copy.
    local_differs,
    /// 10: local content that is not a regular file or directory, or a
    /// directory holding such an entry; what such a directory holds that
    /// can be copied is set aside, and the rest listed (`Item.skipped`).
    local_not_regular,
    /// 10: local content that cannot be compared, one side being
    /// online-only; set aside as far as it can be copied.
    cannot_compare,
    /// 10: local content at a path no fact names while a kept copy
    /// exists; set aside.
    stray,
    /// No state: holt's link to the kept copy of a path no fact names; the
    /// link is left, and keeping the path records it.
    unrecorded_link,
    /// Any state: setting local content aside failed, so nothing that
    /// depended on it was done.
    aside_failed,
    /// Any state: the action failed; the detail is the error.
    failed,
    /// No state: reconcile stopped because the clone does not match its
    /// `local/` key, and holt's link here was removed, since a link holds
    /// no content.
    mismatch_link_removed,
    /// No state: local content the block hides from git that no state set
    /// aside, found by the closing sweep in any working tree of the clone,
    /// or in another working tree before reconcile added a line that would
    /// hide it; set aside in `apply` (whole, for a line to be added) and
    /// left in place. The detail is the temporary holding it, when it is
    /// one, or why it could not be copied (`sweep.Why`).
    hidden,
    /// Any state, or none: a nested repository the block hides from git,
    /// where local content was to be set aside or the closing sweep found
    /// it; reported, never copied.
    nested_repository,
    /// No state: a working tree git records for the clone that cannot be
    /// swept, wherever it is and whatever its lock, so what the block hides
    /// in it is unknown (`Item.worktree`; for one whose record cannot be
    /// read, the record's directory). It holds every block line and refuses
    /// new ones. The detail says why (`clone.TreeProblem`); the hint names
    /// commands reaching that one working tree or record alone.
    tree_unreadable,
    /// No state: git records the working tree reconciled under no path of
    /// its own, as for a copy of a linked working tree or one moved with
    /// plain `mv`: the detail is the path git's record for it holds, which
    /// it shares, or null when git records it nowhere. It is swept like any
    /// other working tree. Information only; for one whose record names a
    /// path that is gone, the hint points that one record here.
    tree_unrecorded,
    /// No state: a directory of the common directory's `worktrees/` that
    /// holds no `gitdir`, left half made by `git worktree add`
    /// (`clone.halfCreated`; the detail). It names no working tree, so it
    /// holds no block line and refuses none. Information only; the hint
    /// removes that directory alone.
    half_created_record,
    /// No state: a symlink holt did not make, or a special file, that the
    /// block hides in another working tree of the clone (or, with no state
    /// reporting it, in this one), or that a block line to be added would
    /// hide there, which is then refused. git deletes it like any ignored
    /// file, and aside cannot hold it; reported, never copied.
    hidden_not_copyable,
    /// No state: probing how the working tree's filesystem compares names
    /// failed (the detail), so it is taken to fold names both ways, the
    /// answer that never tells two spellings apart. Information only.
    fold_unknown,
    /// No state: a temporary named by a `pending` record of a linked
    /// working tree git no longer lists; set aside and the record cleared
    /// in `apply`, and the temporary left where it is; unsettled outside
    /// `apply`, since nothing was done. The detail is where it is.
    orphan_temp,
    /// Any state: a block line the action needed would hide, in another
    /// working tree of the clone, a place that cannot be set aside whole
    /// (reported on its own item), so the line was not written and nothing
    /// that needed it was done. The detail is the line.
    line_refused,
    /// No state: reconcile stopped (`Report.stop`) with local content here
    /// that holt holds nowhere else; set aside when the store can take it.
    /// For a temporary beside the path, the detail is the temporary.
    stopped,
};

pub const Item = struct {
    rel: []const u8,
    /// The reconcile state that matched, 1 to 10; null for a path that
    /// reached no state.
    state: ?u8 = null,
    outcome: Outcome,
    /// Whether the deleters and `--retire` must treat the path as unsettled.
    unsettled: bool,
    /// Whether the outcome's action was carried out; false when only
    /// planned, or when the outcome is a report with no action.
    done: bool = false,
    /// The aside entry holding content this item set aside.
    entry: ?[]const u8 = null,
    /// What `entry` left out, when the content held entries that cannot be
    /// copied (`content.treeFilesPartial`): the content is not all held, so
    /// the item is unsettled.
    skipped: []const content.Skipped = &.{},
    /// For two machines keeping different content: the aside entries
    /// holding each version found so far.
    entries: []const []const u8 = &.{},
    /// Outcome-specific detail: the successor key to promote to, the other
    /// synced root, the invalid reason, a temporary left beside the path,
    /// how a temporary was settled, or an error name.
    detail: ?[]const u8 = null,
    /// For an interrupted write: which one.
    op: ?clone.Op = null,
    /// The working tree the item is about when it is another working tree
    /// of the clone than the one reconciled; the closing sweep and the
    /// block's upkeep look at every one.
    worktree: ?[]const u8 = null,
    /// For `relinked`: an executable bit of the local content could not be
    /// given to the kept copy, whose filesystem refused it. Information
    /// only.
    exec_not_kept: bool = false,
    /// For `invalid`: why the path cannot be kept, when a `paths.Invalid`
    /// says it.
    invalid: ?paths.Invalid = null,
};

/// Why a working tree could not be evaluated. Every stop but `none` lists
/// the local content at the visited paths as `stopped` items.
pub const Stop = enum {
    none,
    store_absent,
    store_unreadable,
    no_key,
    unknown_version,
    /// The clone's `local/` key has a directory in the store whose record
    /// is missing or names another repo's root commit. A `local/` key with
    /// no directory keeps nothing, and is no mismatch.
    local_mismatch,
    block_unbalanced,
    /// git could not list the working tree's index or HEAD, so nothing is
    /// known to be tracked; nothing was acted on.
    git_failed,
    /// The clone's working trees could not be read from its common
    /// directory, so what a block line hides in them is unknown; no line
    /// was added or dropped.
    worktrees_unknown,
    /// git finds the main working tree's files in another directory than
    /// the one holding the clone's common directory (`core.worktree`), so
    /// the clone has no key (`clone.Clone.worktreeElsewhere`).
    worktree_elsewhere,
};

pub const Report = struct {
    stop: Stop = .none,
    key: ?[]const u8 = null,
    /// The key the clone's files live in: its own, or a successor.
    resolved: ?[]const u8 = null,
    items: []const Item = &.{},
    /// Files and directories in the resolved key that no fact names.
    unknown: []const []const u8 = &.{},
    /// Markers of the clone's own and resolved keys holt could not use.
    bad: []const store.Bad = &.{},
    block_written: bool = false,

    /// The unsettled items, plus one when reconcile stopped: a working tree
    /// that could not be evaluated is never settled.
    pub fn unsettledCount(self: Report) usize {
        var n: usize = @intFromBool(self.stop != .none);
        for (self.items) |i| {
            if (i.unsettled) n += 1;
        }
        return n;
    }

    /// The first item for `rel` with `outcome`, if any.
    pub fn find(self: Report, rel: []const u8, outcome: Outcome) ?Item {
        for (self.items) |i| {
            if (i.outcome == outcome and std.mem.eql(u8, i.rel, rel)) return i;
        }
        return null;
    }
};

const KeptSide = enum { absent, placeholder, file, dir, symlink, other };

fn keptSide(alloc: std.mem.Allocator, path: []const u8) !KeptSide {
    return switch (try content.entryAt(path)) {
        .absent => if (fsutil.hasIcloudPlaceholder(alloc, path)) .placeholder else .absent,
        .file => .file,
        .dir => .dir,
        .symlink => .symlink,
        .other => .other,
    };
}

const Run = struct {
    ctx: Ctx,
    a: std.mem.Allocator,
    mode: Mode,
    c: clone.Clone,
    rk: []const u8,
    res: store.Resolution,
    ks: store.KeyState,
    index: *const store.KeyIndex,
    tree: place.Tree,
    pending: []const clone.Pending,
    /// How git lists each of `tracked_rels`.
    tracked: []const clone.Tracked,
    tracked_rels: []const []const u8,
    /// How the working tree's filesystem compares names.
    fold: paths.Folding,
    sparse: clone.Sparse,
    kept_set: []const []const u8,
    /// Kept paths equal to another kept path under case folding or Unicode
    /// normalization.
    collisions: []const []const u8,
    /// The valid kept paths, and `paths.foldKey` of each.
    kept_valid: []const []const u8,
    kept_keys: []const []const u8,
    /// For a clone awaiting promote: the promoted key's state, whose facts
    /// name the paths moved out of the clone's key.
    promoted: ?store.KeyState,
    /// The clone's visited paths and block as reconcile found them.
    scope: Scope,
    /// Whether this machine can create links, once probed.
    can_link: ?bool = null,
    /// Whether the current synced root is recorded (`store.recordRoot`).
    root_recorded: bool = false,
    /// Whether `addLines` changed the block.
    block_changed: bool = false,
    /// The lines `addLines` refused to write.
    refused: std.ArrayList([]const u8) = .empty,
    items: std.ArrayList(Item) = .empty,

    fn acts(r: *const Run) bool {
        return r.mode == .apply;
    }

    fn repairs(r: *const Run) bool {
        return r.mode != .plan;
    }

    fn add(r: *Run, item: Item) !void {
        try r.items.append(r.a, item);
    }

    /// Reports `err` reading `rel` (in the working tree `worktree`, when it
    /// is another one) as a `failed` item, unless an unsettled item already
    /// reports that place.
    fn failedAt(r: *Run, rel: []const u8, worktree: ?[]const u8, err: anyerror) !void {
        for (r.items.items) |i| {
            if (!i.unsettled or !std.mem.eql(u8, i.rel, rel)) continue;
            const same = if (i.worktree) |w| worktree != null and std.mem.eql(u8, w, worktree.?) else worktree == null;
            if (same) return;
        }
        try r.add(.{ .rel = rel, .outcome = .failed, .unsettled = true, .detail = @errorName(err), .worktree = worktree });
    }

    /// Whether the working tree at `tree` needs the block line of `rel`: a
    /// parent component there is not a real directory, or something is at
    /// it, which for a released path counts only while it is holt's link.
    fn holdsLine(r: *Run, tree: []const u8, rel: []const u8, released: bool) !bool {
        const a = r.a;
        if (!try link.parentsReal(a, tree, rel)) return true;
        const p = try fsutil.joinSlashy(a, tree, rel);
        const e = try content.entryAt(p);
        if (e == .absent) return false;
        if (!released) return true;
        if (e != .symlink) return false;
        const raw = (try content.readLink(a, p)) orelse return false;
        return link.isHolt(a, p, raw, r.tree.chain, r.tree.roots, rel);
    }

    /// Sets the local content at `path` aside, recording the entry or the
    /// failure in `item`. Only in `apply`.
    fn setAside(r: *Run, item: *Item, rel: []const u8, path: []const u8, reason: aside.Reason) !void {
        return r.setAsideIn(r.c.worktree, item, rel, path, reason);
    }

    /// `setAside` for content at `path` in the working tree `tree`.
    fn setAsideIn(r: *Run, tree: []const u8, item: *Item, rel: []const u8, path: []const u8, reason: aside.Reason) !void {
        if (!r.acts()) return;
        try asideInto(r.ctx, r.c, tree, r.rk, item, rel, path, reason);
    }

    fn isTracked(r: *Run, rel: []const u8) !bool {
        for (r.tracked_rels, r.tracked) |t, how| {
            if (std.mem.eql(u8, t, rel)) return how.isTracked(r.a, r.c.worktree, rel, r.fold);
        }
        return false;
    }

    /// Records the current synced root before the run's first link under it
    /// (`store.recordRoot`).
    fn recordRoot(r: *Run) !void {
        if (r.root_recorded) return;
        try store.recordRoot(r.a, r.ctx.layout);
        r.root_recorded = true;
    }

    /// Whether this machine can create a link of `kind`, probed once: in
    /// the clone's state directory, or, in plan mode, which writes nothing
    /// in the clone, in `sweep.scratchDir`.
    fn linkable(r: *Run, kind: content.Kind) !bool {
        if (r.can_link) |ok| return ok;
        const dir = if (r.mode == .plan) try sweep_mod.scratchDir(r.a, r.ctx) else try clone.stateDir(r.a, r.c.common_dir);
        const ok = if (content.probeLink(r.a, dir, kind)) true else |err| switch (err) {
            error.SymlinkPrivilege => false,
            else => return err,
        };
        r.can_link = ok;
        return ok;
    }

    /// The kept path `rel` equals under case folding and normalization,
    /// when `rel` is not itself kept.
    fn keptAlias(r: *Run, rel: []const u8) !?[]const u8 {
        if (paths.contains(r.kept_set, rel)) return null;
        const k = try paths.foldKey(r.a, rel);
        for (r.kept_valid, r.kept_keys) |kept, kk| {
            if (std.mem.eql(u8, kk, k)) return kept;
        }
        return null;
    }

    /// A path that reaches no state. Local content at `cp`, when given, is
    /// set aside and the item left unsettled, but only where every parent
    /// component of `rel` in the working tree is a real directory and no
    /// component is one git treats as `.git`: content reached through a
    /// symlinked parent, or inside a git directory, is only reported.
    fn noState(r: *Run, rel: []const u8, cp: ?[]const u8, outcome: Outcome, detail: ?[]const u8, invalid: ?paths.Invalid) !void {
        var item: Item = .{ .rel = rel, .outcome = outcome, .unsettled = false, .detail = detail, .invalid = invalid };
        if (cp) |p| if (!paths.hasDotGit(rel) and try link.parentsReal(r.a, r.c.worktree, rel)) switch (try content.entryAt(p)) {
            .file, .dir => {
                item.unsettled = true;
                try r.setAside(&item, rel, p, .blocked);
            },
            else => {},
        };
        try r.add(item);
    }

    fn visit(r: *Run, rel: []const u8) !void {
        const a = r.a;
        // A released path git reads only unlinked still takes the released
        // rule, which turns an older holt's link into a regular copy.
        if (paths.keepable(rel)) |inv| if (inv != .git_reads_unlinked or !r.ks.isReleased(rel)) {
            const at = if (paths.contained(rel)) try fsutil.joinSlashy(a, r.c.worktree, rel) else null;
            return r.noState(rel, at, .invalid, inv.describe(), inv);
        };
        const cp = try fsutil.joinSlashy(a, r.c.worktree, rel);
        const collision = paths.Invalid.collision.describe();
        if (paths.contains(r.collisions, rel)) return r.noState(rel, cp, .invalid, collision, .collision);
        if (try r.keptAlias(rel)) |alias| {
            const own_content = try link.parentsReal(a, r.c.worktree, rel) and !try content.sameFile(a, cp, try fsutil.joinSlashy(a, r.c.worktree, alias));
            return r.noState(rel, if (own_content) cp else null, .invalid, collision, .collision);
        }
        if (try store.nestedKeyAt(a, r.index, r.rk, rel)) |nk| {
            const how = if (nk.contains) "contains" else "inside";
            return r.noState(rel, cp, .invalid, try std.fmt.allocPrint(a, "{s} the nested key {s}", .{ how, nk.key }), null);
        }
        if (!try link.parentsReal(a, r.c.worktree, rel)) return r.noState(rel, cp, .parent_not_dir, null, null);

        const kc_path = try r.ctx.layout.copyPath(a, r.rk, rel);
        const pend = clone.findPending(r.pending, r.c.tree, rel);
        if (try r.stateTemporary(rel, cp, pend)) return;
        var side = try link.classify(a, cp, kc_path, r.tree.chain, r.tree.roots, rel);
        if (try r.isTracked(rel)) return r.stateTracked(rel, cp, side);
        if (try r.stateInterrupted(rel, cp, kc_path, pend)) return;
        side = try link.classify(a, cp, kc_path, r.tree.chain, r.tree.roots, rel);
        if (r.ks.isReleased(rel)) return r.stateReleased(rel, cp, kc_path, side);

        const facts = r.ks.factsFor(rel);
        if (distinctHashes(facts) > 1) {
            const live = try r.liveFacts(facts);
            if (distinctHashes(live) > 1) try r.stateTwoMachines(rel, live);
        }

        const kc: KeptSide = if (try link.parentsReal(a, try r.ctx.layout.keyDir(a, r.rk), rel)) try keptSide(a, kc_path) else .other;
        if (side == .foreign) return r.stateBlocked(rel, cp, side, .foreign_link);
        if (kc == .symlink or kc == .other) return r.stateBlocked(rel, cp, side, .kept_not_regular);
        if (kc == .file or kc == .dir) {
            const kk: content.Kind = if (kc == .file) .file else .dir;
            for (facts) |f| if (f.kind != kk) return r.stateBlocked(rel, cp, side, .kind_mismatch);
        }
        if (kc == .dir and side != .right) {
            if (try content.findReserved(a, kc_path)) |name| {
                try r.stateBlocked(rel, cp, side, .kept_reserved);
                r.items.items[r.items.items.len - 1].detail = name;
                return;
            }
        }
        if (kc == .absent) return r.stateMissing(rel, cp, side, facts);

        if (facts.len == 0) {
            switch (side) {
                .local => |e| {
                    var item: Item = .{ .rel = rel, .state = 10, .outcome = .stray, .unsettled = true };
                    if (e == .file or e == .dir) try r.setAside(&item, rel, cp, .local_differs);
                    try r.add(item);
                },
                .right => try r.add(.{ .rel = rel, .outcome = .unrecorded_link, .unsettled = true }),
                .holt => try r.stateMissing(rel, cp, side, facts),
                .absent, .foreign => {},
            }
            return;
        }
        const kind: content.Kind = switch (kc) {
            .file => .file,
            .dir => .dir,
            else => facts[0].kind,
        };
        if (r.lineRefused(rel)) switch (side) {
            .absent => return r.add(refusedItem(rel, 5, rel)),
            .right => return r.add(refusedItem(rel, 7, rel)),
            .holt => return r.add(refusedItem(rel, 8, rel)),
            else => {},
        };
        switch (side) {
            .absent => try r.stateLink(rel, cp, kc_path, kc, kind),
            .right => try r.add(.{ .rel = rel, .state = 7, .outcome = .ok, .unsettled = false }),
            .holt => |raw| try r.stateRetarget(rel, cp, kc_path, kc, kind, raw),
            .local => |e| try r.stateLocal(rel, cp, kc_path, kc, e),
            .foreign => unreachable,
        }
    }

    fn stateTracked(r: *Run, rel: []const u8, cp: []const u8, side: link.Side) !void {
        const raw = switch (side) {
            .right, .holt => |raw| raw,
            else => return r.add(.{ .rel = rel, .state = 1, .outcome = .tracked, .unsettled = false }),
        };
        var item: Item = .{ .rel = rel, .state = 1, .outcome = .tracked_link_removed, .unsettled = false };
        if (r.acts()) {
            if (try content.removeLinkIf(r.a, cp, raw)) {
                item.done = true;
            } else {
                item.outcome = .failed;
                item.detail = "the link changed";
                item.unsettled = true;
            }
        }
        try r.add(item);
    }

    fn interruptedItem(rel: []const u8, pend: ?clone.Pending) Item {
        return .{ .rel = rel, .state = 2, .outcome = .interrupted, .unsettled = true, .op = if (pend) |p| p.op else null, .entry = if (pend) |p| p.entry else null };
    }

    /// State 2, judged before every other state: a temporary an interrupted
    /// write of this working tree left beside the path, other than a
    /// `--take-*`'s, is settled (only in `apply`; otherwise it is reported).
    /// One that cannot be settled is set aside, and so is any local content
    /// at the path, and both are reported. Returns whether the path is done.
    fn stateTemporary(r: *Run, rel: []const u8, cp: []const u8, pend: ?clone.Pending) !bool {
        const op: ?clone.Op = if (pend) |p| p.op else null;
        if (op) |o| switch (o) {
            .take_local, .take_kept, .take_aside => return false,
            else => {},
        };
        const tmp = try r.tree.tempPath(rel);
        if (try content.entryAt(tmp) == .absent) return false;
        const temp_rel = try paths.tempRel(r.a, rel);
        if (!r.acts()) {
            var item = interruptedItem(rel, pend);
            item.detail = temp_rel;
            try r.add(item);
            return true;
        }
        const settled = try place.settleTemp(r.tree, rel, op);
        if (settled.how != .stuck) {
            try r.add(.{ .rel = rel, .state = 2, .outcome = .temp_settled, .unsettled = false, .done = true, .entry = settled.entry, .detail = @tagName(settled.how) });
            return false;
        }
        var item: Item = .{ .rel = rel, .state = 2, .outcome = .temp_stuck, .unsettled = true, .op = op, .detail = temp_rel };
        try r.setAside(&item, rel, tmp, .interrupted);
        try r.add(item);
        switch (try content.entryAt(cp)) {
            .file, .dir => {
                var local: Item = .{ .rel = rel, .state = 2, .outcome = .temp_stuck_local, .unsettled = true };
                try r.setAside(&local, rel, cp, .interrupted);
                try r.add(local);
            },
            else => {},
        }
        return true;
    }

    /// State 2: resolves this working tree's `pending` record for the path
    /// once any temporary is settled. A keep whose kept copy has not been
    /// placed stays interrupted, as does a `--take-*`; any other record is
    /// cleared and the path evaluated from what is there. Returns whether
    /// the path is done.
    fn stateInterrupted(r: *Run, rel: []const u8, cp: []const u8, kc_path: []const u8, pend: ?clone.Pending) !bool {
        const a = r.a;
        const op: ?clone.Op = if (pend) |p| p.op else null;
        const item = interruptedItem(rel, pend);
        if (op) |o| switch (o) {
            .take_local, .take_kept, .take_aside => {
                try r.add(item);
                return true;
            },
            else => {},
        };
        if (op == null) return false;
        if (op == .keep) {
            const linked = try link.classify(a, cp, kc_path, r.tree.chain, r.tree.roots, rel) == .right;
            const kc = try keptSide(a, kc_path);
            if (!linked and (kc == .absent or kc == .placeholder)) {
                try r.add(item);
                return true;
            }
        }
        if (r.repairs()) try clone.clearPending(a, r.c.common_dir, r.c.tree, rel);
        return false;
    }

    fn stateReleased(r: *Run, rel: []const u8, cp: []const u8, kc_path: []const u8, side: link.Side) !void {
        const a = r.a;
        var raw = switch (side) {
            .absent => return,
            .local => return r.add(.{ .rel = rel, .state = 3, .outcome = .released_local, .unsettled = false }),
            .foreign => |t| return r.add(.{ .rel = rel, .state = 9, .outcome = .foreign_link, .unsettled = true, .detail = t }),
            .right, .holt => |raw| raw,
        };
        var item: Item = .{ .rel = rel, .state = 3, .outcome = .released_converted, .unsettled = false };
        var target = try link.resolveTarget(a, cp, raw);
        var ts = try keptSide(a, target);
        if (ts == .absent) {
            const kc = try keptSide(a, kc_path);
            if (kc != .file and kc != .dir) {
                if (kc != .placeholder and r.ks.factsFor(rel).len == 0) if (r.ks.purgeOf(rel)) |mark| return r.statePurged(rel, cp, raw, mark);
                item.outcome = if (kc == .placeholder) .online_only else .released_missing;
                return r.add(item);
            }
            if (!r.acts()) return r.add(item);
            const kind: content.Kind = if (kc == .file) .file else .dir;
            const temp = try paths.tempRel(a, rel);
            try r.addLines(&.{}, &.{temp});
            if (r.lineRefused(temp)) return r.add(refusedItem(rel, 3, temp));
            try r.recordRoot();
            content.retargetLink(a, kc_path, cp, try r.tree.tempPath(rel), kind, raw) catch |err| {
                if (err == error.OutOfMemory) return err;
                item.outcome = .failed;
                item.detail = @errorName(err);
                item.unsettled = true;
                return r.add(item);
            };
            raw = kc_path;
            target = kc_path;
            ts = kc;
        }
        switch (ts) {
            .file, .dir => {},
            .placeholder => {
                item.outcome = .online_only;
                return r.add(item);
            },
            else => {
                item.outcome = .released_missing;
                item.detail = "not a regular file or directory";
                return r.add(item);
            },
        }
        const h = content.hashPath(a, target) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.OnlineOnly => {
                item.outcome = .online_only;
                return r.add(item);
            },
            else => {
                item.outcome = .failed;
                item.detail = @errorName(err);
                item.unsettled = true;
                return r.add(item);
            },
        };
        if (!r.acts()) return r.add(item);
        const temp = try paths.tempRel(a, rel);
        try r.addLines(&.{}, &.{temp});
        if (r.lineRefused(temp)) return r.add(refusedItem(rel, 3, temp));
        if (place.convertLink(r.tree, rel, raw, target, h)) {
            item.done = true;
        } else |err| {
            if (err == error.OutOfMemory) return err;
            item.outcome = .failed;
            item.detail = @errorName(err);
            item.unsettled = true;
        }
        try r.add(item);
    }

    /// A released path purged elsewhere (`mark`): holt's link at it points
    /// at nothing. Outside plan and fix mode, the link is replaced by a
    /// verified copy of the purge's aside entry. The link is removed,
    /// outside plan mode, with nothing to set aside, only when the purge
    /// recorded no entry, or the entry was pruned (`store.isPruned`) and no
    /// whole copy of it is here; an entry not pruned that is not here whole leaves
    /// the link, unsettled.
    fn statePurged(r: *Run, rel: []const u8, cp: []const u8, raw: []const u8, mark: store.Purge) !void {
        const a = r.a;
        if (mark.entry) |stamp| {
            const why: Outcome = blk: {
                const m = (try aside.readManifest(a, r.ctx.layout, stamp)) orelse break :blk .purged_pending;
                if (!std.mem.eql(u8, m.key, r.rk) or !std.mem.eql(u8, m.rel, rel)) break :blk .purged_unrestorable;
                switch (try aside.verify(a, r.ctx.layout, stamp)) {
                    .ok => {},
                    .missing, .online_only => break :blk .purged_pending,
                    else => break :blk .purged_unrestorable,
                }
                if (aside.unplaceable(m) != null or m.skipped.len > 0 or m.files.len == 0) break :blk .purged_unrestorable;
                return r.restorePurged(rel, raw, stamp, m);
            };
            if (!try store.isPruned(a, r.ctx.layout, stamp)) return r.add(.{ .rel = rel, .state = 3, .outcome = why, .unsettled = true, .entry = stamp });
        }
        var item: Item = .{ .rel = rel, .state = 3, .outcome = .purged_link_removed, .unsettled = false, .entry = mark.entry };
        if (r.repairs()) {
            if (content.removeLinkIf(a, cp, raw)) |removed| {
                item.done = removed;
            } else |err| {
                if (err == error.OutOfMemory) return err;
                item.outcome = .failed;
                item.detail = @errorName(err);
                item.unsettled = true;
            }
        }
        try r.add(item);
    }

    /// Replaces holt's link at the purged path `rel` with a copy of the
    /// aside entry `stamp`, whose manifest `m` names the path and which
    /// holds a whole verified copy of it.
    fn restorePurged(r: *Run, rel: []const u8, raw: []const u8, stamp: []const u8, m: aside.Manifest) !void {
        const a = r.a;
        const item: Item = .{ .rel = rel, .state = 3, .outcome = .purged_restored, .unsettled = false, .entry = stamp };
        if (!r.acts()) return r.add(item);
        const temp = try paths.tempRel(a, rel);
        try r.addLines(&.{}, &.{temp});
        if (r.lineRefused(temp)) return r.add(refusedItem(rel, 3, temp));
        var done = item;
        if (place.convertLink(r.tree, rel, raw, try aside.dataPath(a, r.ctx.layout, stamp, rel), try m.hash(a))) {
            done.done = true;
        } else |err| {
            if (err == error.OutOfMemory) return err;
            done.outcome = .failed;
            done.detail = @errorName(err);
            done.unsettled = true;
        }
        try r.add(done);
    }

    /// `facts` but those their machine's retirement covers
    /// (`store.factRetired`), which stand for no machine that still keeps
    /// the path.
    fn liveFacts(r: *Run, facts: []const store.Fact) ![]const store.Fact {
        var out: std.ArrayList(store.Fact) = .empty;
        for (facts) |f| {
            if (!try store.factRetired(r.a, r.ctx.layout, r.rk, f)) try out.append(r.a, f);
        }
        return out.items;
    }

    /// The aside entries holding a whole verified copy of the content one
    /// of `facts` names, sorted.
    fn heldAside(r: *Run, rel: []const u8, facts: []const store.Fact) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (facts) |f| {
            for (try aside.findEntries(r.a, r.ctx.layout, r.rk, rel, f.sha256)) |stamp| {
                if (paths.contains(out.items, stamp)) continue;
                if (try aside.verify(r.a, r.ctx.layout, stamp) == .ok) try out.append(r.a, stamp);
            }
        }
        std.mem.sort([]const u8, out.items, {}, paths.lessThan);
        return out.items;
    }

    fn stateTwoMachines(r: *Run, rel: []const u8, facts: []const store.Fact) !void {
        var entries: std.ArrayList([]const u8) = .empty;
        for (facts, 0..) |f, i| {
            var seen = false;
            for (facts[0..i]) |g| {
                if (std.mem.eql(u8, g.sha256, f.sha256)) seen = true;
            }
            if (seen) continue;
            try entries.appendSlice(r.a, try aside.findEntries(r.a, r.ctx.layout, r.rk, rel, f.sha256));
        }
        try r.add(.{ .rel = rel, .state = 4, .outcome = .two_machines, .unsettled = true, .entries = entries.items });
    }

    fn stateBlocked(r: *Run, rel: []const u8, cp: []const u8, side: link.Side, outcome: Outcome) !void {
        var item: Item = .{ .rel = rel, .state = 9, .outcome = outcome, .unsettled = true };
        switch (side) {
            .local => |e| if (e == .file or e == .dir) try r.setAside(&item, rel, cp, .blocked),
            .foreign => |t| item.detail = t,
            else => {},
        }
        try r.add(item);
    }

    fn stateMissing(r: *Run, rel: []const u8, cp: []const u8, side: link.Side, facts: []const store.Fact) !void {
        const a = r.a;
        const succ: ?[]const u8 = switch (r.res) {
            .awaiting_promote => |s| s,
            else => null,
        };
        switch (side) {
            .absent => if (facts.len > 0) {
                if (try place.awaitedFact(r.ctx, r.rk, facts, null)) |f| return r.add(.{ .rel = rel, .state = 6, .outcome = .not_arrived, .unsettled = true, .detail = f.machine });
                if ((try r.liveFacts(facts)).len == 0) return r.add(.{ .rel = rel, .state = 6, .outcome = .retired_gone, .unsettled = true, .entries = try r.heldAside(rel, facts) });
                try r.add(.{ .rel = rel, .state = 6, .outcome = .not_present, .unsettled = false, .detail = succ });
            },
            .right, .holt => |raw| {
                const promoted_names = if (r.promoted) |p| p.factsFor(rel).len > 0 else false;
                if (succ != null and (facts.len > 0 or promoted_names)) {
                    return r.add(.{ .rel = rel, .state = 6, .outcome = .awaiting_promote, .unsettled = true, .detail = succ });
                }
                const target = try link.resolveTarget(a, cp, raw);
                if (try keptSide(a, target) != .absent) {
                    const root = link.rootOf(a, cp, raw, r.tree.chain, r.tree.roots, rel);
                    if (root != null and !link.sameRoot(a, root.?, r.ctx.layout.synced_root)) {
                        return r.add(.{ .rel = rel, .state = 6, .outcome = .in_old_root, .unsettled = true, .detail = root });
                    }
                    return r.add(.{ .rel = rel, .state = 6, .outcome = .pending_move, .unsettled = true });
                }
                if (try place.awaitedFact(r.ctx, r.rk, facts, null)) |f| return r.add(.{ .rel = rel, .state = 6, .outcome = .not_arrived, .unsettled = true, .detail = f.machine });
                if (facts.len > 0) return r.add(.{ .rel = rel, .state = 6, .outcome = .missing, .unsettled = true });
                var item: Item = .{ .rel = rel, .state = 6, .outcome = .dangling_removed, .unsettled = false };
                if (r.repairs()) {
                    if (try content.removeLinkIf(a, cp, raw)) {
                        item.done = true;
                    } else {
                        item.outcome = .failed;
                        item.detail = "the link changed";
                        item.unsettled = true;
                    }
                }
                try r.add(item);
            },
            .local => |e| {
                var item: Item = .{ .rel = rel, .state = 6, .outcome = .missing_local, .unsettled = true };
                if (try place.awaitedFact(r.ctx, r.rk, facts, null)) |f| {
                    item.outcome = .not_arrived;
                    item.detail = f.machine;
                }
                if (e == .file or e == .dir) try r.setAside(&item, rel, cp, .kept_missing);
                try r.add(item);
            },
            .foreign => unreachable,
        }
    }

    fn stateLink(r: *Run, rel: []const u8, cp: []const u8, kc_path: []const u8, kc: KeptSide, kind: content.Kind) !void {
        if (!try r.sparse.includes(r.a, r.c.worktree, rel, kind)) {
            return r.add(.{ .rel = rel, .state = 5, .outcome = .outside_sparse, .unsettled = false });
        }
        if (kc == .placeholder) {
            return r.add(.{ .rel = rel, .state = 5, .outcome = .online_only, .unsettled = false });
        }
        var item: Item = .{ .rel = rel, .state = 5, .outcome = .linked, .unsettled = false };
        if (r.repairs()) {
            if (!try r.linkable(kind)) {
                item.outcome = .no_symlink_privilege;
                return r.add(item);
            }
            try fsutil.ensureDir(std.fs.path.dirname(cp).?);
            try r.recordRoot();
            if (content.createLink(kc_path, cp, kind)) {
                item.done = true;
            } else |err| switch (err) {
                error.SymlinkPrivilege => item.outcome = .no_symlink_privilege,
                else => {
                    item.outcome = .failed;
                    item.detail = @errorName(err);
                    item.unsettled = true;
                },
            }
        }
        try r.add(item);
    }

    fn stateRetarget(r: *Run, rel: []const u8, cp: []const u8, kc_path: []const u8, kc: KeptSide, kind: content.Kind, raw: []const u8) !void {
        const a = r.a;
        if (kc == .placeholder) return r.add(.{ .rel = rel, .state = 8, .outcome = .online_only, .unsettled = false });
        const old = try link.resolveTarget(a, cp, raw);
        var item: Item = .{ .rel = rel, .state = 8, .outcome = .retargeted, .unsettled = false };
        const oe = content.entryAt(old) catch |err| {
            return r.add(.{ .rel = rel, .state = 8, .outcome = .old_unreadable, .unsettled = true, .detail = @errorName(err) });
        };
        var differs = false;
        switch (oe) {
            .absent => if (fsutil.hasIcloudPlaceholder(a, old)) {
                return r.add(.{ .rel = rel, .state = 8, .outcome = .old_unreadable, .unsettled = true, .detail = "online-only" });
            },
            .symlink, .other => return r.add(.{ .rel = rel, .state = 8, .outcome = .old_unreadable, .unsettled = true, .detail = "not a regular file or directory" }),
            .file, .dir => {
                const ho = content.hashPath(a, old) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return r.add(.{ .rel = rel, .state = 8, .outcome = .old_unreadable, .unsettled = true, .detail = if (err == error.OnlineOnly) "online-only" else @errorName(err) }),
                };
                const hk = content.hashPath(a, kc_path) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.OnlineOnly => return r.add(.{ .rel = rel, .state = 8, .outcome = .online_only, .unsettled = false }),
                    else => return r.add(.{ .rel = rel, .state = 8, .outcome = .failed, .unsettled = true, .detail = @errorName(err) }),
                };
                differs = ho.kind != hk.kind or !std.mem.eql(u8, &ho.hex, &hk.hex);
            },
        }
        if (differs) {
            item.outcome = .old_differs;
            item.unsettled = true;
            if (!r.acts()) return r.add(item);
            try r.setAside(&item, rel, old, .old_location);
            if (item.outcome == .aside_failed) return r.add(item);
        } else if (!r.repairs()) return r.add(item);
        if (!try r.linkable(kind)) {
            item.outcome = .no_symlink_privilege;
            return r.add(item);
        }
        const temp = try paths.tempRel(a, rel);
        try r.addLines(&.{}, &.{temp});
        if (r.lineRefused(temp)) return r.add(refusedItem(rel, 8, temp));
        try r.recordRoot();
        content.retargetLink(a, kc_path, cp, try r.tree.tempPath(rel), kind, raw) catch |err| {
            if (err == error.OutOfMemory) return err;
            item.outcome = .failed;
            item.detail = @errorName(err);
            item.unsettled = true;
            item.done = false;
            return r.add(item);
        };
        item.done = true;
        try r.add(item);
    }

    /// State 10. Local content whose bytes equal the kept copy's is
    /// replaced by the link, and the kept copy given its executable bits
    /// where its filesystem allows; when it refuses, the link is still made,
    /// since it is holt's link either way, and the item says
    /// `exec_not_kept`. This is why `Scope.identical`, which asks whether
    /// local content is held anywhere else, also requires the bits.
    fn stateLocal(r: *Run, rel: []const u8, cp: []const u8, kc_path: []const u8, kc: KeptSide, e: content.Entry) !void {
        const a = r.a;
        if (e == .other) return r.add(.{ .rel = rel, .state = 10, .outcome = .local_not_regular, .unsettled = true });
        if (e == .dir and kc == .dir and try link.onlyHoltLinks(a, cp, r.tree.chain, r.tree.roots, rel)) return r.stateLinksOnly(rel, cp, kc_path);
        var item: Item = .{ .rel = rel, .state = 10, .outcome = .local_differs, .unsettled = true };
        const hl = content.hashPath(a, cp) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.OnlineOnly => {
                item.outcome = .cannot_compare;
                if (e == .dir) try r.setAside(&item, rel, cp, .cannot_compare);
                return r.add(item);
            },
            error.NotRegular => {
                item.outcome = .local_not_regular;
                if (e == .dir) try r.setAside(&item, rel, cp, .local_differs);
                return r.add(item);
            },
            else => {
                item.outcome = .failed;
                item.detail = @errorName(err);
                if (e == .dir) try r.setAside(&item, rel, cp, .local_differs);
                return r.add(item);
            },
        };
        const hk: ?content.Hash = if (kc == .placeholder) null else content.hashPath(a, kc_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.OnlineOnly => null,
            else => {
                item.outcome = .failed;
                item.detail = @errorName(err);
                return r.add(item);
            },
        };
        if (hk == null) {
            item.outcome = .cannot_compare;
            try r.setAside(&item, rel, cp, .cannot_compare);
            return r.add(item);
        }
        if (hl.kind == hk.?.kind and std.mem.eql(u8, &hl.hex, &hk.?.hex)) {
            var same: Item = .{ .rel = rel, .state = 10, .outcome = .relinked, .unsettled = false };
            if (!r.repairs()) return r.add(same);
            if (!try r.linkable(hl.kind)) {
                same.outcome = .no_symlink_privilege;
                return r.add(same);
            }
            if (r.lineRefused(rel)) return r.add(refusedItem(rel, 10, rel));
            const temp = try paths.tempRel(a, rel);
            try r.addLines(&.{}, &.{temp});
            if (r.lineRefused(temp)) return r.add(refusedItem(rel, 10, temp));
            try clone.addPending(a, r.c.common_dir, .{ .tree = r.c.tree, .rel = rel, .op = .relink, .worktree = r.c.worktree });
            if (place.replaceWithLink(r.tree, rel, kc_path, hl)) |exec_kept| {
                try clone.clearPending(a, r.c.common_dir, r.c.tree, rel);
                same.done = true;
                same.exec_not_kept = !exec_kept;
                return r.add(same);
            } else |err| switch (err) {
                error.OutOfMemory, error.Interrupted => return err,
                error.TempStranded => return r.add(.{ .rel = rel, .state = 10, .outcome = .failed, .unsettled = true, .detail = @errorName(err) }),
                else => {
                    try clone.clearPending(a, r.c.common_dir, r.c.tree, rel);
                    switch (err) {
                        error.ChangedDuringLink => {},
                        error.SymlinkPrivilege => {
                            same.outcome = .no_symlink_privilege;
                            return r.add(same);
                        },
                        else => return r.add(.{ .rel = rel, .state = 10, .outcome = .failed, .unsettled = true, .detail = @errorName(err) }),
                    }
                },
            }
        }
        if (try place.awaitedFact(r.ctx, r.rk, r.ks.factsFor(rel), hk.?)) |f| {
            item.outcome = .not_arrived;
            item.detail = f.machine;
        }
        try r.setAside(&item, rel, cp, .local_differs);
        try r.add(item);
    }

    /// State 10 for a kept directory whose local directory holds only
    /// holt's links to the kept files below it, as a machine or working
    /// tree that linked them file by file holds it once the directory is
    /// kept whole: the links, which hold no content, are set aside, recorded
    /// by their targets, and the directory replaced by the kept
    /// directory's link (`relinked`).
    fn stateLinksOnly(r: *Run, rel: []const u8, cp: []const u8, kc_path: []const u8) !void {
        const a = r.a;
        var same: Item = .{ .rel = rel, .state = 10, .outcome = .relinked, .unsettled = false };
        if (!r.repairs()) return r.add(same);
        if (!try r.linkable(.dir)) {
            same.outcome = .no_symlink_privilege;
            return r.add(same);
        }
        if (r.lineRefused(rel)) return r.add(refusedItem(rel, 10, rel));
        const temp = try paths.tempRel(a, rel);
        try r.addLines(&.{}, &.{temp});
        if (r.lineRefused(temp)) return r.add(refusedItem(rel, 10, temp));
        var held = same;
        try r.setAside(&held, rel, cp, .local_differs);
        if (held.outcome != .relinked) return r.add(held);
        same.entry = held.entry;
        try clone.addPending(a, r.c.common_dir, .{ .tree = r.c.tree, .rel = rel, .op = .relink, .worktree = r.c.worktree });
        if (place.replaceLinksWithLink(r.tree, rel, kc_path)) {
            try clone.clearPending(a, r.c.common_dir, r.c.tree, rel);
            same.done = true;
            return r.add(same);
        } else |err| switch (err) {
            error.OutOfMemory, error.Interrupted => return err,
            error.TempStranded => return r.add(.{ .rel = rel, .state = 10, .outcome = .failed, .unsettled = true, .detail = @errorName(err) }),
            else => {
                try clone.clearPending(a, r.c.common_dir, r.c.tree, rel);
                return r.add(.{ .rel = rel, .state = 10, .outcome = if (err == error.SymlinkPrivilege) .no_symlink_privilege else .failed, .unsettled = err != error.SymlinkPrivilege, .detail = @errorName(err) });
            },
        }
    }

    /// Sets aside, in `apply`, each place of `found` holding a file or
    /// directory, whole (content git tracks inside a directory included, a
    /// harmless over-copy), and reports it unsettled as `hidden`, unless an
    /// unsettled item for the same place already reports it: with the same
    /// aside entry, or with none, in which case that item is given the
    /// entry (outside `apply`, reports it at all). A place `found` says is
    /// never copied, a symlink holt did not make or a special file among
    /// them, is reported with its reason unless an unsettled item already
    /// reports it. This is what keeps git from destroying the only copy of
    /// content the block hides, in any working tree, whatever state the
    /// path reached, without saying so.
    fn sweep(r: *Run, found: []const sweep_mod.Found) !void {
        for (found) |u| {
            const wt: ?[]const u8 = if (std.mem.eql(u8, u.worktree, r.c.worktree)) null else u.worktree;
            const held = try r.existing(u);
            if (u.why) |why| {
                if (held != null) continue;
                const outcome = whyOutcome(why);
                try r.add(.{ .rel = u.rel, .outcome = outcome, .unsettled = true, .worktree = wt, .detail = u.detail orelse if (outcome == .hidden) @tagName(why) else u.temp });
                continue;
            }
            if (u.entry != .file and u.entry != .dir) continue;
            if (held != null and !r.acts()) continue;
            var item: Item = .{ .rel = u.rel, .outcome = .hidden, .unsettled = true, .detail = u.temp, .worktree = wt };
            try r.setAsideIn(u.worktree, &item, u.rel, try u.path(r.a), .hidden);
            if (held) |idx| {
                const h = &r.items.items[idx];
                if (h.entry == null) {
                    if (item.entry != null) {
                        h.entry = item.entry;
                        h.skipped = item.skipped;
                    }
                    continue;
                }
                if (item.entry != null and std.mem.eql(u8, h.entry.?, item.entry.?)) continue;
            }
            try r.add(item);
        }
    }

    /// The index of an unsettled item about the place `u` names: the same
    /// working tree, the same temporary or none, and the same path or, for
    /// a place git lists under another spelling of a line, the line's path
    /// when both name one file.
    fn existing(r: *const Run, u: sweep_mod.Found) !?usize {
        for (r.items.items, 0..) |i, idx| {
            if (!i.unsettled) continue;
            const same_tree = if (i.worktree) |w| std.mem.eql(u8, w, u.worktree) else std.mem.eql(u8, r.c.worktree, u.worktree);
            if (!same_tree) continue;
            const i_temp: ?[]const u8 = if (i.detail) |d| (if (paths.isTempRel(d)) d else null) else null;
            if (!std.mem.eql(u8, i_temp orelse "", u.temp orelse "")) continue;
            if (std.mem.eql(u8, i.rel, u.rel)) return idx;
            if (u.line) |l| if (std.mem.eql(u8, i.rel, l)) {
                const here = try fsutil.joinSlashy(r.a, u.worktree, u.rel);
                if (try content.sameFile(r.a, here, try fsutil.joinSlashy(r.a, u.worktree, l))) return idx;
            };
        }
        return null;
    }

    /// Adds `rels` and `temps` (paths or temporaries) to the block, having
    /// first asked git what the lines not there yet would newly hide in
    /// every working tree of the clone (`Scope.newlyHiddenAll`), this one
    /// included but for the unit a state handles itself (a new path line's
    /// own path, spelled as the line spells it, here), so no line holt adds
    /// hides an only copy, even for a moment.
    /// Content there is set aside whole first, in `apply`, and reported
    /// unsettled as `hidden`. A line under which some place cannot be set
    /// aside whole (a place never copied, `sweep.Why`; content in `fix`,
    /// which sets nothing aside; an aside that fails or would leave
    /// something out) is refused: it is not written, each such place is
    /// reported, and it joins `refused`, so nothing that needs it is done
    /// and the block's upkeep does not write it either. A failure about no
    /// one line (the working trees cannot be read, or one cannot be swept
    /// or listed) refuses every new line. `plan`
    /// writes and sets aside nothing, and refuses only what `apply` would.
    fn addLines(r: *Run, rels: []const []const u8, temps: []const []const u8) !void {
        const a = r.a;
        const before = try block.read(a, r.c.common_dir);
        var new_rels: std.ArrayList([]const u8) = .empty;
        var new_temps: std.ArrayList([]const u8) = .empty;
        for (rels) |l| if (!paths.contains(before.rels, l) and !paths.contains(r.refused.items, l)) try new_rels.append(a, l);
        for (temps) |l| if (!paths.contains(before.temps, l) and !paths.contains(r.refused.items, l)) try new_temps.append(a, l);
        if (new_rels.items.len + new_temps.items.len == 0) return;
        const found = try r.scope.newlyHiddenAll(.{ .rels = before.rels, .temps = before.temps, .foreign = before.foreign }, .{ .rels = new_rels.items, .temps = new_temps.items }, null);
        var refuse_all = false;
        var refused: std.ArrayList([]const u8) = .empty;
        for (found) |f| {
            const own = std.mem.eql(u8, f.worktree, r.c.worktree) and f.temp == null and f.line == null and paths.contains(new_rels.items, f.rel);
            if (own) continue;
            if (f.why == null and f.entry != .file and f.entry != .dir) continue;
            const wt: ?[]const u8 = if (std.mem.eql(u8, f.worktree, r.c.worktree)) null else f.worktree;
            var item: Item = .{ .rel = f.rel, .outcome = .hidden, .unsettled = true, .detail = f.temp, .worktree = wt };
            var refuse = true;
            if (f.why) |why| {
                item.outcome = whyOutcome(why);
                item.detail = f.detail orelse if (item.outcome == .hidden) @tagName(why) else f.temp;
            } else if (r.mode == .plan) {
                refuse = false;
            } else if (r.acts()) {
                if (aside.ensureAside(a, r.ctx.layout, r.c.common_dir, r.ctx.machine_id, r.rk, f.rel, try f.path(a), .hidden, .whole)) |e| {
                    item.entry = e.stamp;
                    item.done = true;
                    refuse = false;
                } else |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.NestedRepository => item.outcome = .nested_repository,
                    else => {
                        item.outcome = .aside_failed;
                        item.detail = @errorName(err);
                    },
                }
            }
            if (refuse) {
                if (f.by) |b| try refused.append(a, b) else refuse_all = true;
            }
            if (try r.existing(f)) |idx| {
                const h = &r.items.items[idx];
                if (h.entry == null and item.entry != null) h.entry = item.entry;
                continue;
            }
            try r.add(item);
        }
        var all: std.ArrayList([]const u8) = .empty;
        try all.appendSlice(a, before.rels);
        try all.appendSlice(a, before.temps);
        for ([_][]const []const u8{ new_rels.items, new_temps.items }) |list| {
            for (list) |l| {
                if (refuse_all or paths.contains(refused.items, l)) {
                    try r.refused.append(a, l);
                } else try all.append(a, l);
            }
        }
        if (r.mode == .plan) return;
        if (try block.write(a, r.c.common_dir, all.items)) r.block_changed = true;
    }

    /// Removes, in `apply`, each empty file at a probe's name
    /// (`paths.isProbeRel`) that the block names, in every readable working
    /// tree: holt's own, left by a probe interrupted before it could remove
    /// it, since probes run only under the key's lock this run holds. Its
    /// line then goes with the block's upkeep, and it is never set aside. A
    /// probe's name holding content is left to the closing sweep, like any
    /// other content the block hides.
    fn clearProbes(r: *Run) !void {
        if (!r.acts()) return;
        const a = r.a;
        const now = try block.read(a, r.c.common_dir);
        const trees = clone.worktrees(a, r.c) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        for (now.temps) |t| {
            if (!paths.isProbeRel(t)) continue;
            for (trees) |tree| {
                if (!tree.readable()) continue;
                if (!(link.parentsReal(a, tree.path, t) catch false)) continue;
                const p = try fsutil.joinSlashy(a, tree.path, t);
                if (content.isEmptyFile(p) catch false) fsutil.removePath(p) catch {};
            }
        }
    }

    fn lineRefused(r: *const Run, line: []const u8) bool {
        return paths.contains(r.refused.items, line);
    }

    fn refusedItem(rel: []const u8, state: ?u8, line: []const u8) Item {
        return .{ .rel = rel, .state = state, .outcome = .line_refused, .unsettled = true, .detail = line };
    }

    /// Settles `pending` records of linked working trees git no longer
    /// lists (`clone.treeListed`), which no working tree would otherwise
    /// ever settle: the temporary each names, where its tree was, is set
    /// aside and reported as `orphan_temp`, and the record is cleared
    /// unless setting the temporary aside failed or left part of it out.
    /// Only in `apply`; otherwise the temporaries are reported, unsettled.
    /// A failure at one record becomes that record's `failed` item.
    fn orphanPending(r: *Run) !void {
        for (r.pending) |p| r.orphanRecord(p) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try r.add(.{ .rel = p.rel, .outcome = .failed, .unsettled = true, .detail = @errorName(err), .worktree = p.worktree }),
        };
    }

    fn orphanRecord(r: *Run, p: clone.Pending) !void {
        const a = r.a;
        if (std.mem.eql(u8, p.tree, r.c.tree) or try clone.treeListed(a, r.c.common_dir, p.tree)) return;
        var item: Item = .{ .rel = p.rel, .outcome = .orphan_temp, .unsettled = !r.acts(), .op = p.op };
        var found = false;
        if (p.worktree) |wt| if (paths.check(p.rel) == null) {
            const temp = try paths.tempRel(a, p.rel);
            if (try link.parentsReal(a, wt, temp)) {
                const tp = try fsutil.joinSlashy(a, wt, temp);
                switch (try content.entryAt(tp)) {
                    .file, .dir => {
                        found = true;
                        item.detail = tp;
                        try r.setAside(&item, p.rel, tp, .interrupted);
                    },
                    else => {},
                }
            }
        };
        if (found) try r.add(item);
        if (r.acts() and item.outcome != .aside_failed and item.skipped.len == 0) try clone.clearPending(a, r.c.common_dir, p.tree, p.rel);
    }
};

/// How a place the block hides that is never copied is reported.
fn whyOutcome(why: sweep_mod.Why) Outcome {
    return switch (why) {
        .nested_repository => .nested_repository,
        .tree_unreadable => .tree_unreadable,
        .failed => .failed,
        .parent_not_dir, .dot_git => .hidden,
        .not_copyable => .hidden_not_copyable,
    };
}

fn distinctHashes(facts: []const store.Fact) usize {
    var n: usize = 0;
    for (facts, 0..) |f, i| {
        for (facts[0..i]) |g| {
            if (std.mem.eql(u8, g.sha256, f.sha256)) break;
        } else n += 1;
    }
    return n;
}

const sortedUnique = sweep_mod.sortedUnique;

/// For a clone its `local/` key does not match: every holt link into that
/// key among `rels` in this working tree is removed (unless `mode` is
/// `plan`) and reported, since a link holds no content.
fn removeUnmatchedLinks(ctx: Ctx, c: clone.Clone, key: []const u8, rels: []const []const u8, mode: Mode) ![]const Item {
    const a = ctx.alloc;
    const roots = try store.syncedRoots(a, ctx.layout);
    var out: std.ArrayList(Item) = .empty;
    for (rels) |rel| {
        if (paths.check(rel) != null) continue;
        const got = removeUnmatchedLink(a, c, key, roots, rel, mode) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => Item{ .rel = rel, .outcome = .failed, .unsettled = true, .detail = @errorName(err) },
        };
        if (got) |item| try out.append(a, item);
    }
    return out.items;
}

fn removeUnmatchedLink(a: std.mem.Allocator, c: clone.Clone, key: []const u8, roots: []const []const u8, rel: []const u8, mode: Mode) !?Item {
    const cp = try fsutil.joinSlashy(a, c.worktree, rel);
    const raw = (try content.readLink(a, cp)) orelse return null;
    if (!link.isHolt(a, cp, raw, &.{key}, roots, rel)) return null;
    var item: Item = .{ .rel = rel, .outcome = .mismatch_link_removed, .unsettled = false };
    if (mode != .plan) {
        if (try content.removeLinkIf(a, cp, raw)) {
            item.done = true;
        } else {
            item.outcome = .failed;
            item.detail = "the link changed";
            item.unsettled = true;
        }
    }
    return item;
}

/// Sets the local content at `path`, in the working tree `tree`, aside for
/// `rel` of `key`, as much of it as can be copied, recording the entry or
/// the failure in `item`. What could not be copied is listed in the item,
/// which is then unsettled.
fn asideInto(ctx: Ctx, c: clone.Clone, tree: []const u8, key: []const u8, item: *Item, rel: []const u8, path: []const u8, reason: aside.Reason) !void {
    const how: aside.Coverage = .{ .partial = .{ .ignore_case = try clone.ignoresCase(ctx.alloc, tree) } };
    if (aside.ensureAside(ctx.alloc, ctx.layout, c.common_dir, ctx.machine_id, key, rel, path, reason, how)) |e| {
        item.entry = e.stamp;
        item.done = true;
        item.skipped = e.skipped;
        if (e.skipped.len > 0) item.unsettled = true;
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        error.NestedRepository => {
            item.outcome = .nested_repository;
            item.unsettled = true;
        },
        else => {
            item.outcome = .aside_failed;
            item.detail = @errorName(err);
            item.unsettled = true;
        },
    }
}

/// Local content the block hides from git that holt holds nowhere else, or
/// a place the block hides that could not be judged (`sweep.Found`).
pub const Unprotected = sweep_mod.Found;

const Scope = sweep_mod.Scope;

/// Records `stop` in `report` with a `stopped` item for each place the
/// block hides in this working tree holding content holt holds nowhere
/// else (`Scope.hiddenIn`), set aside in `apply` when `writable`.
fn stopped(s: Scope, report: *Report, stop: Stop, mode: Mode, writable: bool) !void {
    const a = s.ctx.alloc;
    report.stop = stop;
    var items: std.ArrayList(Item) = .empty;
    try items.appendSlice(a, report.items);
    for (try s.hiddenIn(s.c.worktree, s.block_rels, s.block_temps, s.block_foreign)) |u| {
        var item: Item = .{ .rel = u.rel, .outcome = .stopped, .unsettled = true, .detail = u.detail orelse u.temp };
        if (u.why == null and mode == .apply and writable and s.key != null and (u.entry == .file or u.entry == .dir)) {
            try asideInto(s.ctx, s.c, u.worktree, s.key.?, &item, u.rel, try u.path(a), .stopped);
        }
        try items.append(a, item);
    }
    report.items = items.items;
}

/// Every place the block hides from git in any working tree of the clone
/// containing `path`, with `index` the store's keys as loaded at the start
/// of the command, that holds content holt holds nowhere else or could not
/// be judged (`Scope.hiddenAll`): what a deleter must set aside or refuse
/// over, whatever state reconcile reports. Reconcile's closing sweep judges
/// the block by the same rule. An unbalanced block's lines are salvaged;
/// with no readable store nothing is identical to a kept copy. Takes no
/// lock and writes nothing but the temporary file git reads the block's
/// lines from. `GitTooOld` when git is older than `clone.min_git`.
pub fn unprotected(ctx: Ctx, index: *const store.KeyIndex, path: []const u8) ![]const Unprotected {
    try clone.requireGit(ctx.alloc);
    const c = try clone.inspect(ctx.alloc, path, ctx.code_root);
    return (try scopeOf(ctx, index, c)).hiddenByBlock(null);
}

/// The visited paths of the clone `c` as `unprotected` judges them: under
/// its resolved key when the store can be read, under its own key with no
/// kept copies when it cannot, and with no key for a clone that has none.
pub fn scopeOf(ctx: Ctx, index: *const store.KeyIndex, c: clone.Clone) !Scope {
    const own = c.key orelse return Scope.load(ctx, c, null, null, false);
    if (!try storeReadable(ctx)) return Scope.load(ctx, c, own, own, false);
    const rk = try resolvedKey(ctx, index, c, own, false);
    return Scope.load(ctx, c, rk.key, own, true);
}

fn storeReadable(ctx: Ctx) !bool {
    const kept_dir = try ctx.layout.keptDir(ctx.alloc);
    if (std.Io.Dir.cwd().openDir(io(), kept_dir, .{ .iterate = true })) |d| {
        d.close(io());
        return true;
    } else |_| return false;
}

/// The key `c`, whose own key is `own`, keeps its files under, with the
/// clone's root commits when they were needed: to follow `own`'s successors,
/// or, with `local_roots`, to match a `local/` key's record. git is asked
/// for them only then.
fn resolvedKey(ctx: Ctx, index: *const store.KeyIndex, c: clone.Clone, own: []const u8, local_roots: bool) !struct { key: []const u8, res: store.Resolution, roots: []const []const u8 } {
    const need = index.successorsOf(own).len > 0 or (local_roots and store.isLocalKey(own));
    const roots: []const []const u8 = if (need) try clone.rootCommits(ctx.alloc, c.main) else &.{};
    const res = try store.resolve(ctx.alloc, ctx.layout, index, own, roots);
    return .{ .key = switch (res) {
        .own, .awaiting_promote => own,
        .successor => |s| s,
    }, .res = res, .roots = roots };
}

/// Reconciles the working tree containing `path`, with `index` the store's
/// keys as loaded at the start of the command, holding the clone's lock
/// (`ctx.lockClone`) and then the key's, but in `plan`, which writes
/// nothing of the clone's or the store's and takes neither, so it never
/// waits on a writer. A failure at one path, in
/// any working tree, becomes that path's `failed` item, its block line
/// stays, and the other paths are still evaluated. What each block line
/// reconcile adds would newly hide in every working tree of the clone, its
/// own included but for the line's own path as spelled there, is set
/// aside before it is written, or the line refused (`Run.addLines`), and
/// the closing sweep (`Run.sweep`) then covers every line of the block as
/// it ends in every working tree. When the working trees cannot be read,
/// reconcile stops (`worktrees_unknown`). In `apply`, files git read that
/// an interrupted run left (`clone.clearStaleExcludes`) and holt's own
/// empty probe files (`Run.clearProbes`) are removed. A stop acts on
/// nothing but setting local content aside, and lists it. `GitTooOld`,
/// before anything is read, when git is older than `clone.min_git`;
/// `CloneStateUnwritable` when the clone's lock cannot be made.
pub fn reconcile(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, mode: Mode) !Report {
    return reconcileHeld(ctx, index, path, mode, null);
}

/// `reconcile` under the clone's lock and the resolved key's lock that the
/// caller already holds (`held`, `ctx.Held.of`), taking neither, or taking
/// both as `reconcile` does when `held` is null. `LocksNotHeld`, before
/// anything is written, when their lock files are not this clone's and
/// the resolved key's (`ctx.Held.covers`).
pub fn reconcileHeld(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, mode: Mode, held: ?ctx_mod.Held) !Report {
    const a = ctx.alloc;
    const started = std.Io.Clock.real.now(io()).nanoseconds;
    try clone.requireGit(a);
    const c = try clone.inspect(a, path, ctx.code_root);
    const kept_dir = try ctx.layout.keptDir(a);
    if (std.Io.Dir.cwd().openDir(io(), kept_dir, .{ .iterate = true })) |d| {
        d.close(io());
    } else |err| {
        var report: Report = .{ .key = c.key };
        const stop: Stop = switch (err) {
            error.FileNotFound, error.NotDir => .store_absent,
            else => .store_unreadable,
        };
        try stopped(try Scope.load(ctx, c, c.key, c.key, false), &report, stop, mode, false);
        return report;
    }

    const own = c.key orelse {
        var report: Report = .{};
        try stopped(try Scope.load(ctx, c, null, null, false), &report, if (c.worktreeElsewhere()) .worktree_elsewhere else .no_key, mode, false);
        return report;
    };
    const resolved = try resolvedKey(ctx, index, c, own, true);
    const roots = resolved.roots;
    const res = resolved.res;
    const rk = resolved.key;
    var report: Report = .{ .key = own, .resolved = rk };

    if (held) |h| if (!try h.covers(ctx, c.common_dir, rk)) return error.LocksNotHeld;
    const clone_lock = if (mode == .plan or held != null) null else try ctx_mod.lockClone(ctx, c.common_dir);
    defer if (clone_lock) |l| l.release();
    const lock = if (mode == .plan or held != null) null else try ctx_mod.lockKey(ctx, rk);
    defer if (lock) |l| l.release();

    const scope = try Scope.load(ctx, c, rk, own, true);
    if (mode == .apply) {
        var host_buf: [machine.host_name_max]u8 = undefined;
        const host = machine.hostName(&host_buf);
        try clone.clearStaleExcludes(a, try clone.stateDir(a, c.common_dir), ctx.machine_id, host, started);
        try clone.clearStaleExcludes(a, try sweep_mod.scratchDir(a, ctx), ctx.machine_id, host, started);
    }
    const ks = scope.ks.?;
    var bad: std.ArrayList(store.Bad) = .empty;
    try bad.appendSlice(a, ks.bad);
    for (index.bad) |b| {
        for ([_][]const u8{ own, rk }) |k| {
            if (fsutil.pathIsInside(b.path, try ctx.layout.keyDir(a, k))) {
                try bad.append(a, b);
                break;
            }
        }
    }
    report.bad = bad.items;

    const parsed = scope.parsed orelse {
        try stopped(scope, &report, .block_unbalanced, mode, true);
        return report;
    };
    if (ks.record) |rec| {
        if (!rec.known()) {
            try stopped(scope, &report, .unknown_version, mode, true);
            return report;
        }
    }
    if (store.isLocalKey(rk)) {
        const rec = switch (res) {
            .awaiting_promote => |s| try store.readRecord(a, ctx.layout, s),
            else => ks.record,
        };
        const root: ?[]const u8 = if (rec) |r| r.root else null;
        const nothing_kept = rec == null and res != .awaiting_promote and try content.entryAt(try ctx.layout.keyDir(a, rk)) == .absent;
        if (!nothing_kept and (root == null or !paths.contains(roots, root.?))) {
            report.items = try removeUnmatchedLinks(ctx, c, rk, scope.visited, mode);
            try stopped(scope, &report, .local_mismatch, mode, true);
            return report;
        }
    }

    const kept_set = try ks.keptSet(a);
    const visited = scope.visited;
    var valid: std.ArrayList([]const u8) = .empty;
    for (visited) |rel| if (paths.check(rel) == null) try valid.append(a, rel);
    var valid_kept: std.ArrayList([]const u8) = .empty;
    var kept_keys: std.ArrayList([]const u8) = .empty;
    for (kept_set) |rel| if (paths.check(rel) == null) {
        try valid_kept.append(a, rel);
        try kept_keys.append(a, try paths.foldKey(a, rel));
    };

    const trees = clone.worktrees(a, c) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try stopped(scope, &report, .worktrees_unknown, mode, true);
            return report;
        },
    };

    const how_tracked = clone.tracked(a, c.worktree, valid.items) catch |err| switch (err) {
        error.GitFailed => {
            try stopped(scope, &report, .git_failed, mode, true);
            return report;
        },
        else => return err,
    };
    const probed = try clone.folding(a, c, mode != .plan);

    var run: Run = .{
        .ctx = ctx,
        .a = a,
        .mode = mode,
        .c = c,
        .rk = rk,
        .res = res,
        .ks = ks,
        .index = index,
        .tree = .{ .ctx = ctx, .c = c, .key = rk, .chain = scope.chain, .roots = scope.roots },
        .scope = scope,
        .pending = scope.pending,
        .tracked = how_tracked,
        .tracked_rels = valid.items,
        .fold = probed.fold,
        .sparse = try clone.sparse(a, c.worktree),
        .kept_set = kept_set,
        .collisions = try paths.collisions(a, valid_kept.items),
        .kept_valid = valid_kept.items,
        .kept_keys = kept_keys.items,
        .promoted = switch (res) {
            .awaiting_promote => |s| try store.loadKeyState(a, ctx.layout, s),
            else => null,
        },
    };

    if (probed.failure) |err| if (mode != .plan) try run.add(.{ .rel = ".", .outcome = .fold_unknown, .unsettled = false, .detail = @errorName(err) });
    for (trees) |t| if (!t.recorded) try run.add(.{ .rel = ".", .outcome = .tree_unrecorded, .unsettled = false, .detail = t.shares });
    for (try clone.halfCreated(a, c)) |record| try run.add(.{ .rel = ".", .outcome = .half_created_record, .unsettled = false, .detail = record });
    try run.addLines(valid_kept.items, &.{});
    report.block_written = run.block_changed;

    try run.orphanPending();
    for (visited) |rel| run.visit(rel) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try run.add(.{ .rel = rel, .outcome = .failed, .unsettled = true, .detail = @errorName(err) }),
    };

    try run.clearProbes();
    if (mode != .plan) {
        const now = try block.read(a, c.common_dir);
        var kept_lines: std.ArrayList([]const u8) = .empty;
        for (valid_kept.items) |rel| if (!run.lineRefused(rel)) try kept_lines.append(a, rel);
        const lines = try heldLines(&run, try sortedUnique(a, &.{ parsed.rels, kept_lines.items }), try sortedUnique(a, &.{ parsed.temps, now.temps }));
        if (try block.write(a, c.common_dir, lines)) report.block_written = true;
    }
    var final = scope;
    const now = try block.read(a, c.common_dir);
    final.block_rels = now.rels;
    final.block_temps = now.temps;
    final.block_foreign = now.foreign;
    try run.sweep(try final.hiddenByBlock(null));

    report.items = run.items.items;
    report.unknown = try store.unknownFiles(a, ctx.layout, rk, try ks.namedPaths(a));
    return report;
}

/// The block lines that must stay: kept paths; every line while the key's
/// directory or any working tree cannot be read; a released path while a
/// holt link is at it in any working tree; any other path while a working
/// tree has a link or content at it; a temporary while it exists in any
/// working tree or a `pending` record of any working tree names its path.
/// A line whose place in some working tree cannot be read stays, and the
/// failure is that line's `failed` item. Before any line is dropped, git
/// must be able to list what the block hides in every working tree; a
/// working tree it cannot list is a `failed` item and holds every line.
fn heldLines(r: *Run, candidates: []const []const u8, temps: []const []const u8) ![]const []const u8 {
    const a = r.a;
    const key_dir_ok = if (content.entryAt(try r.ctx.layout.keyDir(a, r.rk))) |e| e == .dir else |_| false;
    const trees = clone.worktrees(a, r.c) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    var all_readable = trees != null;
    if (trees) |ts| {
        for (ts) |t| {
            if (!t.readable()) all_readable = false;
        }
    }

    var out: std.ArrayList([]const u8) = .empty;
    const pending = try clone.readPending(a, r.c.common_dir);
    for (temps) |temp| {
        const in_use = !key_dir_ok or clone.tempInUse(a, trees, pending, temp) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => blk: {
                try r.failedAt(temp, null, err);
                break :blk true;
            },
        };
        if (in_use) try out.append(a, temp);
    }
    for (candidates) |rel| {
        if (paths.contains(r.kept_set, rel) or !key_dir_ok or !all_readable or paths.check(rel) != null or paths.contains(r.collisions, rel)) {
            try out.append(a, rel);
            continue;
        }
        const released = r.ks.isReleased(rel);
        for (trees.?) |t| {
            const held = r.holdsLine(t.path, rel, released) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => blk: {
                    try r.failedAt(rel, if (std.mem.eql(u8, t.path, r.c.worktree)) null else t.path, err);
                    break :blk true;
                },
            };
            if (held) {
                try out.append(a, rel);
                break;
            }
        }
    }
    if (out.items.len == candidates.len + temps.len) return out.items;
    const now = try block.read(a, r.c.common_dir);
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(a, now.rels);
    try names.appendSlice(a, now.temps);
    const patterns = try block.patternText(a, names.items, now.foreign);
    const dirs = try r.scope.excludeDirs();
    var listable = true;
    for (trees.?) |t| {
        const got = clone.blockHides(a, t.path, dirs, r.ctx.machine_id, patterns) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (got == null) {
            listable = false;
            try r.failedAt(".", if (std.mem.eql(u8, t.path, r.c.worktree)) null else t.path, error.ListingFailed);
        }
    }
    if (listable) return out.items;
    return std.mem.concat(a, []const u8, &.{ temps, candidates });
}
