//! The kept-file work every command that touches clones shares: whether
//! the store is set up, reconciling clones (in parallel, each working tree
//! of a clone in turn), listing candidates with auto-keep, and the lines
//! that report what was done and what is left, each hint a complete
//! command.

const std = @import("std");
const app = @import("../app.zig");
const kept = @import("../kept.zig");
const fsutil = @import("../fsutil.zig");
const parallel = @import("../parallel.zig");
const marker = @import("../marker.zig");
const workspace = @import("../workspace.zig");
const ui = @import("../ui.zig");
const kept_cmd = @import("../kept_cmd.zig");
const kept_hints = @import("kept_hints.zig");
const util = @import("kept_util.zig");

const reconcile = kept.reconcile;
const Report = reconcile.Report;
const Item = reconcile.Item;

/// Present in the synced root when the user declined kept files.
pub const off_basename = ".holt-kept-off";

/// The first-use line, printed while `kept/` is absent.
pub const not_set_up = "kept files are not set up - run: holt keep --review --all\n";

/// What the synced root holds of the kept store.
pub const Store = union(enum) {
    ready,
    /// `kept/` is absent and the user declined kept files.
    off,
    absent,
    /// `kept/` is absent, and a working tree has holt links into a `kept/`
    /// under this other synced root: the backend was switched without
    /// copying it.
    elsewhere: []const u8,
    /// `kept/` is there but cannot be read.
    unreadable,
};

/// The store's state for the clones at `clones`, whose working trees are
/// searched for holt links into another synced root only while `kept/` is
/// absent.
pub fn storeState(ctx: *app.Ctx, clones: []const []const u8) !Store {
    const ws = ctx.context.?.ws;
    const a = ctx.alloc;
    const dir = try std.fs.path.join(a, &.{ ws.cfg.synced_root, "kept" });
    switch (try kept.content.entryAt(dir)) {
        .dir => {
            var d = std.Io.Dir.cwd().openDir(fsutil.io(), dir, .{ .iterate = true }) catch return .unreadable;
            d.close(fsutil.io());
            return .ready;
        },
        .absent => {},
        else => return .unreadable,
    }
    for (clones) |p| if (try linkedRoot(a, ws.cfg.synced_root, ws.cfg.code_root, p)) |root| return .{ .elsewhere = root };
    if (try kept.content.entryAt(try std.fs.path.join(a, &.{ ws.cfg.synced_root, off_basename })) != .absent) return .off;
    return .absent;
}

/// The other synced root a holt link in any working tree of the clone at
/// `clone_path` points into, found through the block's lines.
fn linkedRoot(a: std.mem.Allocator, synced_root: []const u8, code_root: []const u8, clone_path: []const u8) !?[]const u8 {
    const c = kept.clone.inspect(a, clone_path, code_root) catch return null;
    const key = c.key orelse return null;
    const rels = if (kept.block.read(a, c.common_dir)) |p| p.rels else |_| blk: {
        const text = kept.content.readSmall(a, try kept.block.excludePath(a, c.common_dir)) catch return null;
        break :blk (kept.block.salvage(a, text) catch return null).rels;
    };
    if (rels.len == 0) return null;
    const trees = kept.clone.worktrees(a, c) catch return null;
    for (trees) |t| {
        if (!t.readable()) continue;
        for (rels) |rel| {
            const lp = try fsutil.joinSlashy(a, t.path, rel);
            const raw = (kept.content.readLink(a, lp) catch null) orelse continue;
            const root = kept.link.shapeRoot(a, lp, raw, &.{key}, rel) orelse continue;
            if (!kept.link.sameRoot(a, root, synced_root) and try kept.store.recordsRoot(a, root)) return root;
        }
    }
    return null;
}

/// Prints what the store's state asks of the user about the clones at
/// `clones`, once: the first-use line (only when one of them holds a file
/// not kept, `anyNotKept`), the backend-switch copy hint, or that `kept/`
/// cannot be read.
pub fn printStore(ctx: *app.Ctx, w: *std.Io.Writer, st: Store, clones: []const []const u8) !void {
    const ws = ctx.context.?.ws;
    switch (st) {
        .ready, .off => {},
        .absent => if (try anyNotKept(ctx, clones)) try w.writeAll(try absentLine(ctx)),
        .elsewhere => |root| try w.writeAll(try elsewhereLine(ctx, root)),
        .unreadable => try w.print("kept/ cannot be read: {s}\n", .{try quotedPath(ctx, try std.fs.path.join(ctx.alloc, &.{ ws.cfg.synced_root, "kept" }))}),
    }
}

/// The line naming `root`, the synced root holt's links point into while
/// `kept/` is absent here, and where to copy its `kept/`.
pub fn elsewhereLine(ctx: *app.Ctx, root: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "kept/ is at {s}: copy it to {s}\n", .{ try quotedPath(ctx, root), try quotedPath(ctx, ctx.context.?.ws.cfg.synced_root) });
}

/// Whether a working tree of a clone at `clones` holds a file not kept,
/// judged, while `kept/` is absent, by the seed patterns, writing nothing
/// in holt's machine-local state. A clone that cannot be listed counts as
/// holding one.
pub fn anyNotKept(ctx: *app.Ctx, clones: []const []const u8) !bool {
    if (clones.len == 0) return false;
    var scratch: kept.RunScratch = undefined;
    const kc = planCtx(ctx, &scratch) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return true,
    };
    defer scratch.deinit();
    const index = kept.store.loadIndex(ctx.alloc, kc.layout) catch return true;
    for (clones) |p| {
        const c = kept.clone.inspect(ctx.alloc, p, kc.code_root) catch continue;
        const all = kept.candidates.listAll(kc, &index, c, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return true,
        };
        if (all.unlisted.len > 0) return true;
        for (all.listings) |l| if (l.notKept() > 0 or l.submodules_failed.len > 0) return true;
    }
    return false;
}

/// Whether the synced folder holds projects, so that another machine may
/// keep files whose `kept/` has not downloaded here yet.
pub fn holdsProjects(ctx: *app.Ctx) bool {
    const projects = ctx.context.?.ws.list(ctx.alloc) catch return false;
    return projects.len > 0;
}

/// The line for a synced folder with no `kept/`: the first use of kept
/// files (`not_set_up`), or, when it holds projects (`holdsProjects`), a
/// `kept/` another machine made that may still be downloading.
pub fn absentLine(ctx: *app.Ctx) ![]const u8 {
    if (!holdsProjects(ctx)) return not_set_up;
    return std.fmt.allocPrint(ctx.alloc, "no kept/ here yet: if another machine keeps files, wait for {s} to download it, then run holt sync; otherwise run holt keep --review --all\n", .{util.backendName(ctx)});
}

/// The kept store's context for this command, with this machine's id.
pub fn keptCtx(ctx: *app.Ctx) !kept.Ctx {
    const ws = ctx.context.?.ws;
    const env = app.envOf(ctx);
    return .{
        .alloc = ctx.alloc,
        .env = env,
        .layout = .{ .synced_root = ws.cfg.synced_root },
        .code_root = ws.cfg.code_root,
        .machine_id = try kept.machine.load(ctx.alloc, env),
        .retired_notice = util.retiredNotice(ctx),
    };
}

/// The context a plan runs against, which writes nothing in holt's
/// machine-local state (`kept_cmd.reportCtx`), with `scratch` made here and
/// removed by its `deinit`. Plan-mode reconcile takes no lock.
pub fn planCtx(ctx: *app.Ctx, scratch: *kept.RunScratch) !kept.Ctx {
    const ws = ctx.context.?.ws;
    scratch.* = try kept.RunScratch.init(ctx.alloc, ws.env);
    errdefer scratch.deinit();
    return kept_cmd.reportCtx(ctx.alloc, &ws, scratch);
}

/// What to reconcile: every working tree of the clone at `path`, or only
/// the working tree at `path`.
pub const Target = struct { path: []const u8, whole: bool = true };

/// Whether to list candidates: not at all, listing only, listing and
/// naming what the auto patterns would keep (`plan`), or listing and
/// keeping it (`auto`).
pub const Candidates = enum { none, list, plan, auto };

pub const Options = struct {
    mode: reconcile.Mode = .apply,
    /// Whether to list candidates after reconciling, and keep what the auto
    /// patterns name (`kept.candidates.Options.auto`).
    candidates: Candidates = .none,
    jobs: ?usize = null,
    /// Print only the actions done, never what is left unsettled.
    actions_only: bool = false,
};

const TreeRun = struct { worktree: []const u8, report: ?Report = null, err: ?anyerror = null };

const CloneRun = struct {
    path: []const u8,
    clone: ?kept.clone.Clone = null,
    trees: []const TreeRun = &.{},
    listing: ?kept.candidates.AllListing = null,
    list_err: ?anyerror = null,
    /// Why the patterns could not be matched, when `list_err` is
    /// `MatcherFailed` and the matcher said.
    list_why: []const u8 = "",
    err: ?anyerror = null,
};

/// What `run` did and found, over every target.
pub const Summary = struct {
    linked: usize = 0,
    retargeted: usize = 0,
    auto_kept: usize = 0,
    unsettled: usize = 0,
    /// Repos in which something was linked or retargeted.
    linked_repos: usize = 0,
    /// Repos in which something was linked, retargeted, or kept
    /// automatically, or left unsettled.
    counted_repos: usize = 0,
    candidates: usize = 0,
    candidate_repos: usize = 0,
    /// Every key a reconciled clone files under or resolves to.
    keys: []const []const u8 = &.{},
};

const Task = struct { kc: kept.Ctx, index: *const kept.store.KeyIndex, opts: Options };

/// Reconciles `targets` in parallel with a store index loaded once, then
/// prints, in target order, one line per action and per unsettled state
/// to `w`, and returns the counts. Call only when the store is `ready`.
pub fn run(ctx: *app.Ctx, w: *std.Io.Writer, targets: []const Target, opts: Options) !Summary {
    const a = ctx.alloc;
    var scratch: kept.RunScratch = undefined;
    const kc = if (opts.mode == .plan) try planCtx(ctx, &scratch) else try keptCtx(ctx);
    defer if (opts.mode == .plan) scratch.deinit();
    const index = try kept.store.loadIndex(a, kc.layout);
    const task: Task = .{ .kc = kc, .index = &index, .opts = opts };
    const results = try a.alloc(CloneRun, targets.len);
    var arenas = try parallel.map(*const Task, Target, CloneRun, runTask, a, opts.jobs, &task, targets, results);
    defer arenas.deinit();
    var r: Renderer = .{ .ctx = ctx, .w = w, .opts = opts };
    for (results) |res| try r.cloneRun(res);
    r.summary.keys = r.keys.keys();
    return r.summary;
}

fn runTask(t: *const Task, arena: std.mem.Allocator, target: Target) CloneRun {
    var kc = t.kc;
    kc.alloc = arena;
    return runOne(kc, t.index, t.opts, target) catch |err| .{ .path = target.path, .err = err };
}

fn runOne(kc: kept.Ctx, index: *const kept.store.KeyIndex, opts: Options, target: Target) !CloneRun {
    const a = kc.alloc;
    var out: CloneRun = .{ .path = target.path };
    try kept.clone.requireGit(a);
    const c = try kept.clone.inspect(a, target.path, kc.code_root);
    out.clone = c;
    var paths_: std.ArrayList([]const u8) = .empty;
    if (target.whole) {
        if (kept.clone.worktrees(a, c)) |trees| {
            for (trees) |t| if (t.readable()) try paths_.append(a, t.path);
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => try paths_.append(a, c.worktree),
        }
    } else try paths_.append(a, c.worktree);

    const trees = try a.alloc(TreeRun, paths_.items.len);
    for (paths_.items, trees) |p, *t| t.* = reconcileTree(kc, index, p, opts.mode);
    out.trees = trees;
    if (opts.candidates == .none) return out;

    var listing_kc = kc;
    listing_kc.matcher_why = &out.list_why;
    out.listing = kept.candidates.listAll(listing_kc, index, c, .{ .auto = opts.candidates == .auto, .auto_plan = opts.candidates == .plan }) catch |err| {
        if (err == error.OutOfMemory) return err;
        out.list_err = err;
        return out;
    };
    var auto_kept = false;
    for (out.listing.?.listings) |l| if (l.auto_kept.len > 0) {
        auto_kept = true;
    };
    if (!auto_kept) return out;
    for (trees) |*t| {
        const first = t.*;
        const again = reconcileTree(kc, index, t.worktree, opts.mode);
        const prev = first.report orelse {
            t.* = again;
            continue;
        };
        const next = again.report orelse continue;
        var items: std.ArrayList(Item) = .empty;
        for (prev.items) |i| if (i.done and isAction(i.outcome)) try items.append(a, i);
        try items.appendSlice(a, next.items);
        var merged = next;
        merged.items = items.items;
        t.report = merged;
    }
    return out;
}

fn reconcileTree(kc: kept.Ctx, index: *const kept.store.KeyIndex, path: []const u8, mode: reconcile.Mode) TreeRun {
    const report = reconcile.reconcile(kc, index, path, mode) catch |err| return .{ .worktree = path, .err = err };
    return .{ .worktree = path, .report = report };
}

fn isAction(o: reconcile.Outcome) bool {
    return switch (o) {
        .linked, .relinked, .retargeted, .old_differs, .dangling_removed, .tracked_link_removed, .released_converted, .purged_link_removed, .purged_restored, .temp_settled, .mismatch_link_removed => true,
        else => false,
    };
}

const Renderer = struct {
    ctx: *app.Ctx,
    w: *std.Io.Writer,
    opts: Options,
    summary: Summary = .{},
    keys: std.StringArrayHashMapUnmanaged(void) = .empty,
    git_reported: bool = false,
    /// The key the working tree being rendered resolves to.
    resolved: ?[]const u8 = null,

    fn q(r: *Renderer, path: []const u8) ![]const u8 {
        return quotedPath(r.ctx, path);
    }

    fn counted(r: *const Renderer) usize {
        return r.summary.linked + r.summary.retargeted + r.summary.auto_kept + r.summary.unsettled;
    }

    fn dry(r: *Renderer) bool {
        return r.opts.mode == .plan;
    }

    fn backend(r: *Renderer) []const u8 {
        return util.backendName(r.ctx);
    }

    fn cloneRun(r: *Renderer, res: CloneRun) !void {
        const before_counts = r.counted();
        defer if (r.counted() > before_counts) {
            r.summary.counted_repos += 1;
        };
        const a = r.ctx.alloc;
        if (res.err) |err| {
            if (try pathKey(a, r.ctx.context.?.ws.cfg.code_root, res.path)) |k| try r.keys.put(a, k, {});
            return r.cloneError(res.path, err);
        }
        const c = res.clone.?;
        if (c.key) |k| try r.keys.put(a, try a.dupe(u8, k), {});
        const before = r.summary.linked + r.summary.retargeted;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (res.trees) |t| {
            if (t.err) |err| {
                try r.cloneError(t.worktree, err);
                continue;
            }
            const report = t.report.?;
            if (report.resolved) |k| try r.keys.put(a, try a.dupe(u8, k), {});
            r.resolved = report.resolved;
            try r.stopLine(t.worktree, report);
            for (report.items) |item| {
                const tree = item.worktree orelse t.worktree;
                const id = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ @tagName(item.outcome), tree, item.rel });
                if ((try seen.getOrPut(a, id)).found_existing) continue;
                try r.itemLine(c, tree, item);
            }
        }
        if (res.listing) |l| try r.listingLines(c, l);
        if (res.list_err) |err| {
            if (!r.opts.actions_only) {
                try r.w.print("could not list files not kept in {s}: {s}", .{ try r.q(c.worktree), @errorName(err) });
                if (res.list_why.len > 0) try r.w.print(": {s}", .{try ui.printable(r.ctx.alloc, res.list_why)});
                try r.w.writeByte('\n');
            }
        }
        if (r.summary.linked + r.summary.retargeted > before) r.summary.linked_repos += 1;
    }

    fn cloneError(r: *Renderer, path: []const u8, err: anyerror) !void {
        r.summary.unsettled += 1;
        if (r.opts.actions_only) return;
        switch (err) {
            error.GitTooOld => {
                if (r.git_reported) return;
                r.git_reported = true;
                try r.w.print("{s}\n", .{try kept.clone.gitTooOld(r.ctx.alloc)});
            },
            error.CloneStateUnwritable => try r.w.print("not linked: {s}: holt cannot write its state in the clone's git directory\n", .{try r.q(path)}),
            else => try r.w.print("not linked: {s}: {s}\n", .{ try r.q(path), @errorName(err) }),
        }
    }

    fn stopLine(r: *Renderer, tree: []const u8, report: Report) !void {
        switch (report.stop) {
            .none, .store_absent, .no_key => return,
            .worktree_elsewhere => {
                if (!r.opts.actions_only) try r.w.print("note: {s}: git finds this clone's files elsewhere (core.worktree), so it keeps no files\n", .{try r.q(tree)});
                return;
            },
            else => {},
        }
        r.summary.unsettled += 1;
        if (r.opts.actions_only) return;
        const h = try kept_hints.forStop(r.ctx, tree, report.stop, report.key);
        try r.w.print("not linked: {s}: {s}\n", .{ try r.q(tree), try kept_hints.renderDash(r.ctx.alloc, h) });
    }

    fn itemLine(r: *Renderer, c: kept.clone.Clone, tree: []const u8, it: Item) !void {
        const a = r.ctx.alloc;
        const p = if (std.mem.eql(u8, it.rel, ".")) tree else try fsutil.joinSlashy(a, tree, it.rel);
        const qp = try r.q(p);
        const w = r.w;
        if (it.unsettled) r.summary.unsettled += 1;
        switch (it.outcome) {
            .ok, .tracked, .outside_sparse, .released_local, .fold_unknown => return,
            .linked, .relinked => {
                if (!it.done and !r.dry()) return r.unsettledLine(qp, "linking failed", "run: holt sync", it);
                r.summary.linked += 1;
                const extra: []const u8 = if (it.outcome == .relinked) (if (r.dry()) " (replacing an identical copy)" else " (replaced an identical copy)") else "";
                return w.print("{s} {s}{s}\n", .{ if (r.dry()) "would link" else "linked", qp, extra });
            },
            .retargeted => {
                if (!it.done and !r.dry()) return;
                r.summary.retargeted += 1;
                return w.print("{s} {s}\n", .{ if (r.dry()) "would retarget" else "retargeted", qp });
            },
            .old_differs => {
                if (it.done) r.summary.retargeted += 1;
                if (r.opts.actions_only and !it.done) return;
                const entry = it.entry orelse "";
                if (r.dry()) return w.print("would retarget {s}; its old location holds different content, which would be set aside\n", .{qp});
                if (!it.done) return r.unsettledLine(qp, "its old location holds different content, set aside; retargeting failed", "run: holt sync", it);
                return w.print("retargeted {s}; its old location held different content, set aside - to use it instead, run: holt keep --take-aside {s}\n", .{ qp, try ui.shellQuote(a, entry) });
            },
            .dangling_removed => {
                if (!it.done and !r.dry()) return;
                return w.print("{s} {s} (its kept copy is gone and no record names it)\n", .{ if (r.dry()) "would remove the dangling link" else "removed the dangling link", qp });
            },
            .tracked_link_removed => return w.print("{s} holt's link at {s}, which is tracked on this branch - run: git -C {s} restore -- {s}\n", .{ if (r.dry()) "would remove" else "removed", qp, try r.q(tree), try ui.shellQuote(a, it.rel) }),
            .purged_link_removed => {
                if (!it.done and !r.dry()) return;
                const verb = if (r.dry()) "would remove link" else "removed link";
                if (it.entry != null) return w.print("{s}: {s} (purged on another machine; its content was pruned from aside)\n", .{ verb, qp });
                return w.print("{s}: {s} (purged on another machine)\n", .{ verb, qp });
            },
            .purged_restored => {
                if (!it.done and !r.dry()) return;
                if (r.dry()) return w.print("would restore {s} (purged on another machine) from aside entry {s}\n", .{ qp, it.entry.? });
                return w.print("{s}: purged on another machine; restored a local copy from aside entry {s}\n", .{ qp, it.entry.? });
            },
            .released_converted => {
                if (!it.done and !r.dry()) return;
                return w.print("{s} {s} with a copy of its kept file (released)\n", .{ if (r.dry()) "would replace the link at" else "replaced the link at", qp });
            },
            .temp_settled => {
                if (it.entry) |e| return w.print("settled an interrupted write at {s} ({s}); its content is in aside entry {s}\n", .{ qp, it.detail orelse "", e });
                return w.print("settled an interrupted write at {s} ({s})\n", .{ qp, it.detail orelse "" });
            },
            .mismatch_link_removed => return w.print("{s} holt's link at {s}: this clone is not the repo its kept files belong to\n", .{ if (r.dry()) "would remove" else "removed", qp }),
            .tree_unrecorded => {
                if (r.opts.actions_only) return;
                return w.print("note: {s}: {s}\n", .{ qp, try kept_hints.renderDash(a, try kept_hints.unrecordedTree(r.ctx, tree, it.detail)) });
            },
            .half_created_record => {
                if (r.opts.actions_only) return;
                return w.print("note: {s}: {s}\n", .{ try r.q(it.detail orelse p), try kept_hints.renderDash(a, try kept_hints.forItem(r.ctx, tree, null, r.layout().synced_root, it)) });
            },
            .not_present, .online_only, .no_symlink_privilege, .temp_stuck, .temp_stuck_local, .purged_pending, .purged_unrestorable => return r.hintLine(c, tree, qp, it),
            else => {},
        }
        if (!it.unsettled) return;
        try r.hintLine(c, tree, qp, it);
    }

    /// The line for an item reconcile could not settle, with the hint every
    /// command gives for it (`kept_hints.forItem`); for a working tree that
    /// cannot be read, `tree` being that tree, weighed through the clone
    /// `c`'s records.
    fn hintLine(r: *Renderer, c: kept.clone.Clone, tree: []const u8, qp: []const u8, it: Item) !void {
        if (r.opts.actions_only) return;
        const a = r.ctx.alloc;
        var of = it;
        if (it.outcome == .tree_unreadable and it.worktree == null) of.worktree = tree;
        const h = try kept_hints.forItem(r.ctx, if (it.outcome == .tree_unreadable) c.main else tree, r.resolved orelse c.key, r.layout().synced_root, of);
        try r.w.print("not linked: {s}: {s}", .{ qp, h.what });
        if (it.entry) |e| if (it.outcome != .two_machines and it.outcome != .temp_stuck and it.outcome != .temp_stuck_local and it.outcome != .purged_pending and it.outcome != .purged_unrestorable and it.outcome != .purged_restored and it.outcome != .not_arrived) try r.w.print("; set aside in aside entry {s}", .{e});
        if (it.skipped.len > 0) try r.w.print("; {d} entries could not be copied", .{it.skipped.len});
        if (try kept_hints.runText(a, h)) |run_text| try r.w.print(" - {s}", .{run_text});
        try r.w.writeByte('\n');
    }

    fn unsettledLine(r: *Renderer, qp: []const u8, why: []const u8, hint: ?[]const u8, it: Item) !void {
        if (r.opts.actions_only) return;
        try r.w.print("not linked: {s}: {s}", .{ qp, why });
        if (it.entry) |e| if (it.outcome != .two_machines) try r.w.print("; set aside in aside entry {s}", .{e});
        if (it.skipped.len > 0) try r.w.print("; {d} entries could not be copied", .{it.skipped.len});
        if (hint) |h| try r.w.print(" - {s}", .{h});
        try r.w.writeByte('\n');
    }

    fn layout(r: *Renderer) kept.store.Layout {
        return .{ .synced_root = r.ctx.context.?.ws.cfg.synced_root };
    }

    fn listingLines(r: *Renderer, c: kept.clone.Clone, all: kept.candidates.AllListing) !void {
        const a = r.ctx.alloc;
        var n: usize = 0;
        for (all.listings) |l| {
            for (l.auto_kept) |k| {
                if (k.outcome.status != .kept) continue;
                r.summary.auto_kept += 1;
                try r.w.print("kept automatically: {s} (matches '{s}')\n", .{ try r.q(try fsutil.joinSlashy(a, l.worktree, k.rel)), k.pattern });
            }
            for (l.would_auto) |k| {
                r.summary.auto_kept += 1;
                try r.w.print("would keep automatically: {s} (matches '{s}')\n", .{ try r.q(try fsutil.joinSlashy(a, l.worktree, k.rel)), k.pattern });
            }
            n += l.notKept();
            if (r.opts.actions_only) continue;
            for (l.candidates) |cand| {
                const miss = cand.auto orelse continue;
                const qp = try r.q(try fsutil.joinSlashy(a, l.worktree, cand.rel));
                switch (miss.why) {
                    .too_large => try r.w.print("not kept automatically: {s} (matches '{s}'): larger than 10 MiB - run: holt keep {s}\n", .{ qp, miss.pattern, qp }),
                    .failed => try r.w.print("not kept automatically: {s} (matches '{s}'): {s}\n", .{ qp, miss.pattern, miss.detail orelse "failed" }),
                    .store_absent, .has_fact, .released, .git_reads_unlinked => {},
                }
            }
        }
        if (!r.opts.actions_only) for (all.unlisted) |u| {
            try r.w.print("could not list files not kept in {s}: {s}\n", .{ try r.q(u.worktree), try kept_hints.renderDash(a, try kept_hints.unlisted(r.ctx, c.main, u.worktree, u.problem, u.detail)) });
        };
        r.summary.candidates += n;
        if (n > 0) r.summary.candidate_repos += 1;
    }
};

/// The key a clone at `path` files under: its `/`-joined path below
/// `code_root`, or null when it is not below it.
fn pathKey(a: std.mem.Allocator, code_root: []const u8, path: []const u8) !?[]const u8 {
    if (!fsutil.pathIsInside(path, code_root) or path.len <= code_root.len + 1) return null;
    const rel = try a.dupe(u8, std.mem.trimStart(u8, path[code_root.len..], "/\\"));
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
    return rel;
}

/// The candidates line, when there are any.
pub fn printCandidates(w: *std.Io.Writer, s: Summary) !void {
    if (s.candidates == 0) return;
    try w.print("{d} {s} not kept in {d} {s} - run: holt keep --review --all\n", .{
        s.candidates,      if (s.candidates == 1) "file" else "files",
        s.candidate_repos, if (s.candidate_repos == 1) "repo" else "repos",
    });
}

/// Every key a marker under `projects/` or `archive/` names, as the path
/// its clone files under.
pub fn markerKeys(ctx: *app.Ctx) ![]const []const u8 {
    const ws = ctx.context.?.ws;
    const a = ctx.alloc;
    var out: std.ArrayList([]const u8) = .empty;
    for (try ws.list(a)) |p| try appendKeys(a, &out, p.marker);
    const root = try ws.archiveRoot(a);
    var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.items,
        else => return err,
    };
    defer root_dir.close(fsutil.io());
    var org_it = root_dir.iterate();
    while (try org_it.next(fsutil.io())) |org| {
        if (org.kind != .directory) continue;
        var org_dir = root_dir.openDir(fsutil.io(), org.name, .{ .iterate = true }) catch continue;
        defer org_dir.close(fsutil.io());
        var it = org_dir.iterate();
        while (try it.next(fsutil.io())) |name| {
            if (name.kind != .directory) continue;
            const path = try std.fs.path.join(a, &.{ root, org.name, name.name, marker.marker_basename });
            const m = marker.load(a, path, null) catch continue;
            try appendKeys(a, &out, m);
        }
    }
    return out.items;
}

fn appendKeys(a: std.mem.Allocator, out: *std.ArrayList([]const u8), m: marker.Marker) !void {
    for (m.entries) |e| {
        const src = e.source orelse continue;
        try out.append(a, try src.id().relPath(a));
    }
}

/// For `restore` with no project: one line per key in the store with kept
/// files, no clone here (neither in `reached` nor on disk at its path under
/// the code root), and no marker naming it, saying how to bring its clone
/// back or give its files up.
pub fn printOrphanKeys(ctx: *app.Ctx, w: *std.Io.Writer, reached: []const []const u8) !void {
    const a = ctx.alloc;
    const ws = ctx.context.?.ws;
    const layout: kept.store.Layout = .{ .synced_root = ws.cfg.synced_root };
    const index = try kept.store.loadIndex(a, layout);
    const named = try markerKeys(ctx);
    for (index.keys) |key| {
        if (kept.paths.contains(reached, key) or contains(named, key)) continue;
        if (fsutil.exists(try fsutil.joinSlashy(a, ws.cfg.code_root, key))) continue;
        const st = try kept.store.loadKeyState(a, layout, key);
        if ((try st.keptSet(a)).len == 0) continue;
        if (kept.store.isLocalKey(key)) {
            const dest = try fsutil.joinSlashy(a, ws.cfg.code_root, key);
            try w.print("kept/{s} has no clone here and no remote: copy the clone to {s}, then run: holt repo adopt {s}\n", .{ key, try quotedPath(ctx, dest), try quotedPath(ctx, dest) });
        } else {
            const origin = if (st.record) |rec| rec.origin orelse key else key;
            try w.print("kept/{s} has no clone here - run: holt repo get {s}\n", .{ key, try ui.shellQuote(a, origin) });
        }
        try w.print("  or, if the repo is no longer wanted, run: holt unkeep --repo {s}\n", .{try ui.shellQuote(a, key)});
    }
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// For a command that has just made or moved one clone or working tree:
/// reconciles `target`, a working tree of the clone at `clone_path`, and
/// prints to `w` what was done and what is left, or what the store's state
/// asks of the user. The command's own work is already done, so a failure
/// of the kept work is printed, not returned.
pub fn hook(ctx: *app.Ctx, w: *std.Io.Writer, clone_path: []const u8, target: Target) !void {
    hookRun(ctx, w, clone_path, target) catch |err| {
        if (err == error.OutOfMemory) return err;
        try w.print("kept files not linked in {s}: {s} - once that is fixed, run: holt sync\n", .{ try quotedPath(ctx, target.path), @errorName(err) });
    };
}

fn hookRun(ctx: *app.Ctx, w: *std.Io.Writer, clone_path: []const u8, target: Target) !void {
    const st = try storeState(ctx, &.{clone_path});
    if (st != .ready) return printStore(ctx, w, st, &.{clone_path});
    _ = try run(ctx, w, &.{target}, .{});
}

/// The locks of every key a kept move involves, held from before the move
/// until the clone itself has moved; empty when there was nothing to move.
pub const MoveLocks = struct {
    set: ?kept.KeySet = null,

    pub fn release(self: MoveLocks) void {
        if (self.set) |s| s.release();
    }
};

/// The key of the clone at `path`, or null when it has none (it is not
/// under the code root).
pub fn keyOf(ctx: *app.Ctx, path: []const u8) !?[]const u8 {
    const c = kept.clone.inspect(ctx.alloc, path, ctx.context.?.ws.cfg.code_root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    return c.key;
}

/// Whether a kept move can go ahead: true when `kept/` is ready, false
/// when there is nothing to move (`kept/` is absent), and null, after
/// printing why, when it cannot be read.
fn moveReady(ctx: *app.Ctx, w: *std.Io.Writer, rerun: []const u8) !?bool {
    const st = storeState(ctx, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => .unreadable,
    };
    switch (st) {
        .ready => return true,
        .unreadable => {
            const dir = try std.fs.path.join(ctx.alloc, &.{ ctx.context.?.ws.cfg.synced_root, "kept" });
            try w.print("holt: kept/ cannot be read: {s}; the clone was not moved - make it readable, then run: {s}\n", .{ try quotedPath(ctx, dir), rerun });
            return null;
        },
        else => return false,
    }
}

/// Moves the kept files of the clone at `clone_path` from its key `old` to
/// `new`, as `repo adopt` and `repo promote` must before moving the clone:
/// takes the locks of every key the move involves (`kept.rekey.involved`),
/// in order, and runs `kept.rekey.moveKey`, printing to `w` what moved and
/// what was set aside, and, when it did not complete, what stayed, what the
/// user must do about each, and `rerun`, the command that finishes the job.
/// Returns the locks held, for the caller to release once the clone has
/// moved; null, after printing why, when the move did not complete, and
/// the clone must then stay where it is. Nothing is moved while `kept/` is
/// absent or when `old` is null (a clone from outside the code root).
pub fn moveKept(ctx: *app.Ctx, w: *std.Io.Writer, old: ?[]const u8, new: []const u8, clone_path: []const u8, rerun: []const u8) !?MoveLocks {
    const from = old orelse return .{};
    if (std.mem.eql(u8, from, new)) return .{};
    if (!((try moveReady(ctx, w, rerun)) orelse return null)) return .{};
    const kc = try keptCtx(ctx);
    const index = try kept.store.loadIndex(ctx.alloc, kc.layout);
    const set = try lockMove(ctx, w, kc, &index, from, new, clone_path, rerun) orelse return null;
    if (!try runMove(ctx, w, kc, &index, from, new, clone_path, rerun, true)) {
        set.release();
        return null;
    }
    return .{ .set = set };
}

/// For a clone already at its identity path, whose key is `key`: moves what
/// any earlier identity its `.holt-from/` markers name still holds, as
/// `moveKept` does, each under its own locks. False, after printing what
/// stayed, when a move did not complete.
pub fn finishMoves(ctx: *app.Ctx, w: *std.Io.Writer, key: []const u8, clone_path: []const u8, rerun: []const u8) !bool {
    if (!((try moveReady(ctx, w, rerun)) orelse return false)) return true;
    const kc = try keptCtx(ctx);
    const index = try kept.store.loadIndex(ctx.alloc, kc.layout);
    var bad: std.ArrayList(kept.store.Bad) = .empty;
    var ok = true;
    for (try kept.store.readFrom(ctx.alloc, kc.layout, key, &bad)) |old| {
        if (std.mem.eql(u8, old, key) or !try kept.rekey.holds(ctx.alloc, kc.layout, old)) continue;
        const set = try lockMove(ctx, w, kc, &index, old, key, clone_path, rerun) orelse {
            ok = false;
            continue;
        };
        defer set.release();
        if (!try runMove(ctx, w, kc, &index, old, key, clone_path, rerun, false)) ok = false;
    }
    return ok;
}

fn lockMove(ctx: *app.Ctx, w: *std.Io.Writer, kc: kept.Ctx, index: *const kept.store.KeyIndex, from: []const u8, new: []const u8, clone_path: []const u8, rerun: []const u8) !?kept.KeySet {
    const keys = kept.rekey.involved(kc, index, from, new, clone_path) catch |err| {
        if (err == error.OutOfMemory) return err;
        try moveError(ctx, w, from, new, err, rerun);
        return null;
    };
    return kept.lockAll(kc, keys) catch |err| {
        if (err == error.OutOfMemory) return err;
        try moveError(ctx, w, from, new, err, rerun);
        return null;
    };
}

/// Runs one move under the locks the caller holds and prints its outcome,
/// saying the clone was not moved when `clone_moves`. True when it
/// completed.
fn runMove(ctx: *app.Ctx, w: *std.Io.Writer, kc: kept.Ctx, index: *const kept.store.KeyIndex, from: []const u8, new: []const u8, clone_path: []const u8, rerun: []const u8, clone_moves: bool) !bool {
    const a = ctx.alloc;
    const moved = kept.rekey.moveKey(kc, index, from, new, clone_path) catch |err| {
        if (err == error.OutOfMemory) return err;
        try moveError(ctx, w, from, new, err, rerun);
        return false;
    };
    for (moved.differs) |d| try w.print("kept/{s}/{s} already held different content; the copy from kept/{s} is set aside - to use it instead, run: holt keep --take-aside {s}\n", .{ new, d.rel, d.key, try ui.shellQuote(a, d.entry) });
    for (moved.strays) |st| try w.print("kept/{s}/{s} held a file no record names; it is set aside and the kept copy moved in - to use it instead, run: holt keep --take-aside {s}\n", .{ new, st.rel, try ui.shellQuote(a, st.entry) });
    for (moved.left) |l| try leftLine(ctx, w, kc, new, clone_path, l);
    if (moved.left.len > 0) {
        if (clone_moves) {
            try w.print("holt: the clone was not moved - once the paths above are settled, run: {s}\n", .{rerun});
        } else try w.print("holt: kept/{s} still holds kept files of this repo - once the paths above are settled, run: {s}\n", .{ from, rerun });
        return false;
    }
    if (moved.moved > 0) try w.print("moved {d} kept {s} from kept/{s} to kept/{s}\n", .{ moved.moved, if (moved.moved == 1) "path" else "paths", from, new });
    return true;
}

/// What stayed in an old key, and what the user must do about it.
fn leftLine(ctx: *app.Ctx, w: *std.Io.Writer, kc: kept.Ctx, new: []const u8, clone_path: []const u8, l: kept.rekey.Left) !void {
    const a = ctx.alloc;
    const q = quotedPath;
    switch (l.why) {
        .not_arrived => {
            const backend = util.backendName(ctx);
            try w.print("holt: {s} has not arrived yet (not downloaded, or deleted elsewhere) - wait for {s} to finish downloading it, or if it was deleted, run: holt unkeep {s}\n", .{ try q(ctx, try kc.layout.copyPath(a, l.key, l.rel)), backend, try q(ctx, try fsutil.joinSlashy(a, clone_path, l.rel)) });
        },
        .failed => {
            const at = try q(ctx, try kc.layout.copyPath(a, l.key, l.rel));
            const err = l.detail orelse "";
            if (std.mem.eql(u8, err, "NotRegular")) {
                try w.print("holt: {s} is a link or a special file, which holt does not move - replace it with a regular file, or remove it\n", .{at});
            } else if (std.mem.eql(u8, err, "ParentNotDirectory")) {
                try w.print("holt: a parent directory of {s}, or of {s}, is a link or a file - make it a real directory\n", .{ at, try q(ctx, try kc.layout.copyPath(a, new, l.rel)) });
            } else if (std.mem.eql(u8, err, "InvalidPath")) {
                try w.print("holt: kept/{s} names {s}, which is not a valid kept path - rename or remove it\n", .{ l.key, try ui.shellQuote(a, l.rel) });
            } else if (std.mem.eql(u8, err, "ContentChanged")) {
                try w.print("holt: {s} changed while it was being moved\n", .{at});
            } else {
                try w.print("holt: {s} could not be moved to kept/{s} ({s})\n", .{ at, new, err });
            }
        },
        .staging => try w.print("holt: {s}, this machine's staging for kept/{s}, could not be cleared ({s}) - look at what it holds and remove it\n", .{ try q(ctx, l.rel), l.key, l.detail orelse "" }),
        .reserved => try w.print("holt: {s} is not a file holt knows in kept/{s} (a cloud conflict copy?) - take what you need from it and remove it\n", .{ try q(ctx, l.rel), l.key }),
        .bad_marker => try w.print("holt: {s} cannot be read as one of holt's markers ({s}) - look at it and remove it\n", .{ try q(ctx, l.rel), l.detail orelse "unreadable" }),
        .changed => try w.print("holt: {s} changed while the kept files were being moved\n", .{try q(ctx, l.rel)}),
    }
}

/// Why a kept move could not start or failed as a whole, and what the user
/// must do.
fn moveError(ctx: *app.Ctx, w: *std.Io.Writer, from: []const u8, new: []const u8, err: anyerror, rerun: []const u8) !void {
    const layout: kept.store.Layout = .{ .synced_root = ctx.context.?.ws.cfg.synced_root };
    switch (err) {
        error.RootRequired => try w.print("holt: kept/{s} needs the repo's first commit, and this clone has none; the clone was not moved - commit once, then run: {s}\n", .{ new, rerun }),
        error.LocalMismatch => try w.print("holt: kept/{s} holds the kept files of another repo (different history); the clone was not moved - give this clone another directory name, then adopt it from there\n", .{new}),
        error.KeyDirNotEmpty => try w.print("holt: {s} already holds files but no record, so holt will not file this repo's kept files there; the clone was not moved - move those files out of it, then run: {s}\n", .{ try quotedPath(ctx, try layout.keyDir(ctx.alloc, new)), rerun }),
        error.UnknownRecordVersion => try w.print("holt: a record under kept/{s} or kept/{s} is from a newer holt; the clone was not moved - run: holt upgrade, then {s}\n", .{ from, new, rerun }),
        error.KeysNested => try w.print("holt: kept/{s} and kept/{s} lie one inside the other, so holt cannot move one into the other; the clone was not moved - move the kept files out of the inner one by hand\n", .{ from, new }),
        error.KeySuperseded => try w.print("holt: kept/{s} is an earlier identity of another repo key; the clone was not moved - adopt the clone under its current identity\n", .{new}),
        else => try w.print("holt: cannot move the kept files of kept/{s} to kept/{s}: {s}; the clone was not moved - run: {s}\n", .{ from, new, @errorName(err), rerun }),
    }
}

/// One kept path of a repo, for `info`.
pub const KeptPath = struct {
    rel: []const u8,
    kind: []const u8,
    /// `linked` when holt's link to the kept copy is in place,
    /// `not_linked` when `holt sync` would link it, `not_cloned` when the
    /// repo has no clone here, and otherwise the reconcile outcome that
    /// holds it (`kept.reconcile.Outcome`) or why reconcile stopped
    /// (`kept.reconcile.Stop`).
    state: []const u8,
};

/// The kept paths of the repo whose clone is, or would be, at
/// `clone_path` under `key`, each with its state as reconcile would find
/// it in the clone's main working tree, changing nothing. Empty when
/// `kept/` is not set up and readable.
pub fn keptPaths(ctx: *app.Ctx, clone_path: []const u8, key: []const u8, cloned: bool) ![]const KeptPath {
    const a = ctx.alloc;
    if (try storeState(ctx, &.{}) != .ready) return &.{};
    const layout: kept.store.Layout = .{ .synced_root = ctx.context.?.ws.cfg.synced_root };
    var report: ?Report = null;
    var rk = key;
    if (cloned) {
        var scratch: kept.RunScratch = undefined;
        const kc = try planCtx(ctx, &scratch);
        defer scratch.deinit();
        const index = try kept.store.loadIndex(a, layout);
        if (reconcile.reconcile(kc, &index, clone_path, .plan)) |got| {
            report = got;
            if (got.resolved) |k| rk = k;
        } else |err| if (err == error.OutOfMemory) return err;
    }
    const st = try kept.store.loadKeyState(a, layout, rk);
    var out: std.ArrayList(KeptPath) = .empty;
    for (try st.keptSet(a)) |rel| {
        const facts = st.factsFor(rel);
        const kind: []const u8 = if (facts.len > 0) @tagName(facts[0].kind) else "file";
        const state: []const u8 = if (!cloned) "not_cloned" else if (report) |r| stateIn(r, rel) else "unknown";
        try out.append(a, .{ .rel = rel, .kind = kind, .state = state });
    }
    return out.items;
}

fn stateIn(r: Report, rel: []const u8) []const u8 {
    if (r.stop != .none) return @tagName(r.stop);
    for (r.items) |i| {
        if (i.worktree != null or !std.mem.eql(u8, i.rel, rel)) continue;
        return switch (i.outcome) {
            .ok => "linked",
            .linked, .relinked, .retargeted, .dangling_removed, .purged_link_removed, .purged_restored => "not_linked",
            .temp_settled => continue,
            else => @tagName(i.outcome),
        };
    }
    return "unknown";
}

const testing = std.testing;
const testutil = @import("../testutil.zig");

/// Test-only: a workspace under a sandbox whose holt state lives in the
/// sandbox too, with clones of one bare repo and a kept store.
pub const TestBed = struct {
    a: std.mem.Allocator,
    sb: *testutil.Sandbox,
    ws: workspace.Workspace,
    scope: testutil.EnvScope,
    bare: []const u8,

    /// A workspace at `<sb.root>/<name>` (`name` empty for the root itself)
    /// with its own state directory.
    pub fn init(a: std.mem.Allocator, sb: *testutil.Sandbox, name: []const u8) !TestBed {
        const root = try std.fs.path.join(a, &.{ sb.root, name });
        const scope = try testutil.EnvScope.install(a, &.{.{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ root, "state" }) }});
        const ws = try testutil.testWorkspace(a, root);
        try fsutil.ensureDir(ws.cfg.synced_root);
        const bare_owned = try testutil.makeBareRepo(sb, try std.fmt.allocPrint(a, "{s}bare.git", .{name}));
        defer sb.alloc.free(bare_owned);
        return .{ .a = a, .sb = sb, .ws = ws, .scope = scope, .bare = try a.dupe(u8, bare_owned) };
    }

    pub fn deinit(t: *TestBed) void {
        t.scope.restore();
    }

    /// Makes this bed's environment the one commands read, as `init` did.
    pub fn use(t: *TestBed) !void {
        t.scope = try testutil.EnvScope.install(t.a, &.{.{ "XDG_STATE_HOME", try std.fs.path.join(t.a, &.{ std.fs.path.dirname(t.ws.cfg.synced_root).?, "state" }) }});
    }

    pub fn kc(t: *TestBed) !kept.Ctx {
        const env = app.envOf_current();
        return .{
            .alloc = t.a,
            .env = env,
            .layout = .{ .synced_root = t.ws.cfg.synced_root },
            .code_root = t.ws.cfg.code_root,
            .machine_id = try kept.machine.load(t.a, env),
        };
    }

    pub fn createStore(t: *TestBed) !void {
        _ = try kept.patterns.createStore(t.a, .{ .synced_root = t.ws.cfg.synced_root });
    }

    /// Clones the bare repo to `<code_root>/<key>` and returns its path.
    pub fn clone(t: *TestBed, key: []const u8) ![]const u8 {
        const path = try fsutil.joinSlashy(t.a, t.ws.cfg.code_root, key);
        try testutil.runGit(t.sb, null, &.{ "clone", "-q", t.bare, path });
        return fsutil.realPathOrSelf(t.a, path);
    }

    pub fn write(t: *TestBed, dir: []const u8, rel: []const u8, data: []const u8) !void {
        const p = try fsutil.joinSlashy(t.a, dir, rel);
        try fsutil.ensureDir(std.fs.path.dirname(p).?);
        try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = p, .data = data });
    }

    pub fn keep(t: *TestBed, dir: []const u8, rel: []const u8) !void {
        const k = try t.kc();
        const index = try kept.store.loadIndex(t.a, k.layout);
        _ = try kept.place.keepPath(k, &index, dir, rel, .{});
    }

    /// True when `<dir>/<rel>` is a link to the kept copy of `rel` in `key`.
    pub fn linked(t: *TestBed, dir: []const u8, key: []const u8, rel: []const u8) !bool {
        const raw = (try kept.content.readLink(t.a, try fsutil.joinSlashy(t.a, dir, rel))) orelse return false;
        const want = try (kept.store.Layout{ .synced_root = t.ws.cfg.synced_root }).copyPath(t.a, key, rel);
        return std.mem.eql(u8, raw, want);
    }

    pub fn read(t: *TestBed, dir: []const u8, rel: []const u8) ![]const u8 {
        return kept.content.readSmall(t.a, try fsutil.joinSlashy(t.a, dir, rel));
    }

    pub fn remove(t: *TestBed, dir: []const u8, rel: []const u8) !void {
        try fsutil.removePath(try fsutil.joinSlashy(t.a, dir, rel));
    }

    pub fn shown(t: *TestBed, path: []const u8) ![]const u8 {
        return ui.quotePath(t.a, app.envOf_current(), path);
    }
};

/// Test-only: every file under `root` with its bytes (its size alone while
/// another handle holds it locked on Windows), and every link with its
/// target, skipping `skip` (a path under `root`).
pub fn snapshot(a: std.mem.Allocator, root: []const u8, skip: ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var d = std.Io.Dir.cwd().openDir(fsutil.io(), root, .{ .iterate = true }) catch return out.items;
    defer d.close(fsutil.io());
    var walker = try d.walk(a);
    defer walker.deinit();
    var lines: std.ArrayList([]const u8) = .empty;
    while (try walker.next(fsutil.io())) |e| {
        const full = try std.fs.path.join(a, &.{ root, e.path });
        if (skip) |s| if (fsutil.pathIsInside(full, s)) continue;
        const line = switch (e.kind) {
            .file => if (kept.content.hashFile(a, full)) |h| try std.fmt.allocPrint(a, "f {s} {s}", .{ e.path, &h }) else |err| switch (err) {
                // Windows refuses to read a file another handle holds locked.
                error.LockViolation => try std.fmt.allocPrint(a, "f {s} locked, {d} bytes", .{ e.path, (try std.Io.Dir.cwd().statFile(fsutil.io(), full, .{})).size }),
                else => return err,
            },
            .sym_link => try std.fmt.allocPrint(a, "l {s} {s}", .{ e.path, (try kept.content.readLink(a, full)) orelse "" }),
            .directory => try std.fmt.allocPrint(a, "d {s}", .{e.path}),
            else => try std.fmt.allocPrint(a, "o {s}", .{e.path}),
        };
        try lines.append(a, line);
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (lines.items) |l| {
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    return out.items;
}

/// `path` as every hint prints it (`ui.quotePath`).
pub fn quotedPath(ctx: *app.Ctx, path: []const u8) ![]const u8 {
    return ui.quotePath(ctx.alloc, app.envOf(ctx), path);
}
