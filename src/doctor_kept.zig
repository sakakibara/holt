//! Doctor's kept-file checks, report-only: every kept path settled and
//! linked where git ignores it, the kept store valid, no kept path tracked
//! upstream; and notes that never fail (candidates, auto-pattern matches git
//! does not ignore, aside size, released paths still holding content, keys a
//! clone here shares history with). Reconcile runs in plan mode, so nothing
//! of a clone's or of the store's is written but plan mode's transient
//! files. Nothing here prints.

const std = @import("std");
const kept = @import("kept.zig");
const kept_cmd = @import("kept_cmd.zig");
const workspace = @import("workspace.zig");
const project_mod = @import("project.zig");
const git = @import("git.zig");
const fsutil = @import("fsutil.zig");
const doctor = @import("doctor.zig");

const io = fsutil.io;
const store = kept.store;
const reconcile = kept.reconcile;
const candidates = kept.candidates;
const aside = kept.aside;
const content = kept.content;
const paths = kept.paths;

/// A reconcile item that fails `kept files linked`, and the working tree
/// reconciled when it was found.
pub const Place = struct { tree: []const u8, key: ?[]const u8, item: reconcile.Item };
/// A working tree reconcile stopped at.
pub const Stopped = struct { tree: []const u8, key: ?[]const u8, stop: reconcile.Stop };
/// A place doctor could not check, and why.
pub const Failure = struct { path: []const u8, detail: []const u8 };
/// A path of a working tree.
pub const Rel = struct { tree: []const u8, rel: []const u8, detail: ?[]const u8 = null };
/// A path of a key, and why it is reported.
pub const KeyRel = struct { key: []const u8, rel: []const u8, reason: []const u8 };
/// A cloud conflict copy of a name holt reserves, and whether it is a
/// directory (a copy of `.holt-paths`, say, holding facts).
pub const Copy = struct { path: []const u8, dir: bool };
/// An aside entry, and what verifying it found.
pub const AsideCheck = struct { stamp: []const u8, check: aside.Check };
/// What might exist only in one working tree or hub root.
pub const Candidates = struct {
    /// The working tree, or the hub root when `hub`.
    place: []const u8,
    hub: bool = false,
    /// Candidate paths, relative to `place`.
    rels: []const []const u8 = &.{},
    /// Nested repositories, relative to `place`.
    nested: []const []const u8 = &.{},
    /// Initialized submodules git could not list.
    submodules_failed: []const []const u8 = &.{},
};
pub const AutoUnignored = struct { tree: []const u8, rel: []const u8, pattern: []const u8, negation: ?kept.clone.Negation = null };
/// A released path whose kept copy is still in the store, with the machines
/// whose facts name it, a clone here that uses its key, and, for a key with
/// no clone here, the origin its record names.
pub const Released = struct { key: []const u8, rel: []const u8, machines: []const []const u8, clone: ?[]const u8, origin: ?[]const u8 = null };
/// A key no clone here uses whose `root` a clone here matches.
pub const Orphan = struct { key: []const u8, clone: []const u8 };

pub const Report = struct {
    setup: kept_cmd.Setup,
    /// This machine's id, when one is recorded (`machine.peek`).
    machine_id: ?[]const u8 = null,
    /// Why kept files cannot be checked at all with the git on PATH.
    git_too_old: ?[]const u8 = null,
    /// A synced root whose `kept/` links here point into, when `kept/` is
    /// not under the current one.
    old_root: ?[]const u8 = null,

    unlinked: []const Place = &.{},
    stops: []const Stopped = &.{},
    /// Working trees with no key, which hold no kept files: information.
    keyless: []const Stopped = &.{},
    not_ignored: []const Rel = &.{},
    failures: []const Failure = &.{},

    invalid: []const KeyRel = &.{},
    bad_markers: []const store.Bad = &.{},
    unknown_versions: []const []const u8 = &.{},
    unknown_files: []const []const u8 = &.{},
    /// Directories in a key that no fact names; never to be deleted, since
    /// facts naming what they hold may not have synced yet.
    unknown_dirs: []const []const u8 = &.{},
    /// Directories that hold a key's markers or kept content but no record:
    /// a key whose record has not synced here, or was lost.
    unrecorded: []const []const u8 = &.{},
    conflict_copies: []const Copy = &.{},
    placeholders: []const []const u8 = &.{},
    local_mismatch: []const Stopped = &.{},
    tracked_links: []const Rel = &.{},
    aside_bad: []const AsideCheck = &.{},

    tracked_upstream: []const Rel = &.{},

    candidates: []const Candidates = &.{},
    candidate_failures: []const Failure = &.{},
    auto_unignored: []const AutoUnignored = &.{},
    aside_entries: usize = 0,
    /// Bytes of content the aside entries hold, their manifests aside.
    aside_bytes: u64 = 0,
    /// The aside entries `holt keep --prune-aside` would remove.
    aside_prunable: usize = 0,
    aside_unchecked: []const AsideCheck = &.{},
    released: []const Released = &.{},
    orphans: []const Orphan = &.{},
    suspected_conflicts: []const []const u8 = &.{},

    pub fn linkedOk(r: Report) bool {
        return r.git_too_old == null and r.old_root == null and r.unlinked.len == 0 and r.stops.len == 0 and r.not_ignored.len == 0 and r.failures.len == 0;
    }

    pub fn storeOk(r: Report) bool {
        return r.invalid.len == 0 and r.bad_markers.len == 0 and r.unknown_versions.len == 0 and r.unknown_files.len == 0 and
            r.unknown_dirs.len == 0 and r.unrecorded.len == 0 and r.conflict_copies.len == 0 and r.placeholders.len == 0 and r.local_mismatch.len == 0 and r.tracked_links.len == 0 and
            r.aside_bad.len == 0;
    }

    pub fn trackedOk(r: Report) bool {
        return r.tracked_upstream.len == 0;
    }

    pub fn ok(r: Report) bool {
        return r.linkedOk() and r.storeOk() and r.trackedOk();
    }
};

/// Whether a planned or reported item leaves the path unsettled or not
/// yet linked: the unsettled states, the link-only actions `sync` (or
/// `doctor --fix`) would take, and a parent in the way of the link.
fn failsLinked(i: reconcile.Item) bool {
    if (i.unsettled) return true;
    return switch (i.outcome) {
        .linked, .retargeted, .relinked, .dangling_removed, .purged_link_removed, .purged_restored, .tracked_link_removed, .mismatch_link_removed, .parent_not_dir => true,
        else => false,
    };
}

/// Outcomes at which holt's own link is in the working tree.
fn atHoltLink(o: reconcile.Outcome) bool {
    return switch (o) {
        .ok, .retargeted, .old_differs, .old_unreadable, .in_old_root, .pending_move, .missing, .awaiting_promote, .dangling_removed => true,
        else => false,
    };
}

const Builder = struct {
    a: std.mem.Allocator,
    unlinked: std.ArrayList(Place) = .empty,
    /// Each place in `unlinked`, by working tree and path: its index, and
    /// whether the working tree's own reconcile reported it.
    seen: std.StringHashMapUnmanaged(struct { at: usize, own: bool }) = .empty,
    stops: std.ArrayList(Stopped) = .empty,
    keyless: std.ArrayList(Stopped) = .empty,
    local_mismatch: std.ArrayList(Stopped) = .empty,
    /// The aside entries unsettled items name (`kept.ops.unsettledEntries`).
    referenced: kept.ops.Referenced = .{},
    not_ignored: std.ArrayList(Rel) = .empty,
    failures: std.ArrayList(Failure) = .empty,
    tracked_links: std.ArrayList(Rel) = .empty,
    tracked_upstream: std.ArrayList(Rel) = .empty,
    candidates: std.ArrayList(Candidates) = .empty,
    candidate_failures: std.ArrayList(Failure) = .empty,
    auto_unignored: std.ArrayList(AutoUnignored) = .empty,

    /// Drops each `tracked_link_removed` place a tracked symlink into
    /// `kept/` (`tracked_links`) already reports, so one link is reported
    /// once, with `git rm --cached`.
    fn dropTrackedLinks(b: *Builder) !void {
        var kept_places: std.ArrayList(Place) = .empty;
        for (b.unlinked.items) |p| {
            if (p.item.outcome == .tracked_link_removed) {
                const where = p.item.worktree orelse p.tree;
                const dup = for (b.tracked_links.items) |t| {
                    if (std.mem.eql(u8, t.tree, where) and std.mem.eql(u8, t.rel, p.item.rel)) break true;
                } else false;
                if (dup) continue;
            }
            try kept_places.append(b.a, p);
        }
        b.unlinked = kept_places;
    }

    fn fail(b: *Builder, path: []const u8, err: anyerror) !void {
        try b.failures.append(b.a, .{ .path = path, .detail = @errorName(err) });
    }

    /// Adds the failing items of `rep`, reconciled at `tree`, once per
    /// place across every working tree reconciled: what a working tree's
    /// own reconcile says of a place replaces what another's sweep said.
    fn addReport(b: *Builder, tree: []const u8, rep: reconcile.Report) !void {
        try kept.ops.unsettledEntries(b.a, rep, &b.referenced);
        switch (rep.stop) {
            .none => {},
            .local_mismatch => try b.local_mismatch.append(b.a, .{ .tree = tree, .key = rep.key, .stop = rep.stop }),
            .no_key, .worktree_elsewhere => try b.keyless.append(b.a, .{ .tree = tree, .key = null, .stop = rep.stop }),
            else => try b.stops.append(b.a, .{ .tree = tree, .key = rep.key orelse rep.resolved, .stop = rep.stop }),
        }
        for (rep.items) |i| {
            if (!failsLinked(i)) continue;
            const own = i.worktree == null;
            const place: Place = .{ .tree = tree, .key = rep.key, .item = i };
            const id = try std.fmt.allocPrint(b.a, "{s}\x00{s}", .{ i.worktree orelse tree, i.rel });
            const gop = try b.seen.getOrPut(b.a, id);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .at = b.unlinked.items.len, .own = own };
                try b.unlinked.append(b.a, place);
                continue;
            }
            const prev = gop.value_ptr.*;
            if (own and !prev.own) {
                b.unlinked.items[prev.at] = place;
                gop.value_ptr.own = true;
            } else if (own and prev.own) {
                try b.unlinked.append(b.a, place);
            }
        }
    }
};

/// The kept-file context of `ws` for this run, its files for git in
/// `scratch`, made here.
fn reportCtx(alloc: std.mem.Allocator, ws: *const workspace.Workspace, scratch: *?kept.RunScratch) !kept.Ctx {
    scratch.* = try kept.RunScratch.init(alloc, ws.env);
    return kept_cmd.reportCtx(alloc, ws, &scratch.*.?);
}

/// A clone of the code tree as doctor found it.
const CloneInfo = struct {
    path: []const u8,
    c: kept.clone.Clone,
    /// The key its files live in, once its main working tree reconciled.
    resolved: ?[]const u8 = null,
    roots: ?[]const []const u8 = null,
};

/// Whether the clone at `path` has holt's block in its `info/exclude`,
/// read directly for a main working tree.
fn hasBlock(alloc: std.mem.Allocator, path: []const u8) !bool {
    const exclude = try std.fs.path.join(alloc, &.{ path, ".git", "info", "exclude" });
    const text = content.readSmall(alloc, exclude) catch return false;
    return std.mem.indexOf(u8, text, kept.block.begin_line) != null;
}

/// Runs every kept-file check over the clones of the code tree and the hub
/// roots of `projects`, writing nothing in holt's machine-local state
/// (`kept_cmd.reportCtx`) and taking no lock.
pub fn run(alloc: std.mem.Allocator, ws: *const workspace.Workspace, projects: []const project_mod.Project, progress: ?*doctor.Progress) !Report {
    defer if (progress) |pr| pr.endWalk();
    const synced = ws.cfg.synced_root;
    var report: Report = .{ .setup = try kept_cmd.setup(alloc, synced) };
    const clones = try ws.listClones(alloc);
    var b: Builder = .{ .a = alloc };
    var scratch: ?kept.RunScratch = null;
    defer if (scratch) |*sc| sc.deinit();

    if (report.setup != .present) {
        var with_block: std.ArrayList([]const u8) = .empty;
        for (clones) |p| if (try hasBlock(alloc, p)) try with_block.append(alloc, p);
        if (with_block.items.len == 0) return report;
        kept.clone.requireGit(alloc) catch |err| switch (err) {
            error.GitTooOld => {
                report.git_too_old = try kept.clone.gitTooOld(alloc);
                return report;
            },
            else => return err,
        };
        const ctx = reportCtx(alloc, ws, &scratch) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try b.fail(synced, err);
                report.failures = b.failures.items;
                return report;
            },
        };
        const index = try store.loadIndex(alloc, ctx.layout);
        for (with_block.items) |p| {
            if (report.old_root == null) report.old_root = try kept_cmd.oldRoot(alloc, synced, ws.cfg.code_root, p);
            const rep = reconcile.reconcile(ctx, &index, p, .plan) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try b.fail(p, err);
                    continue;
                },
            };
            try b.addReport(p, rep);
        }
        if (report.old_root != null) {
            var kept_stops: std.ArrayList(Stopped) = .empty;
            for (b.stops.items) |s| if (s.stop != .store_absent) try kept_stops.append(alloc, s);
            b.stops = kept_stops;
        }
        report.unlinked = b.unlinked.items;
        report.stops = b.stops.items;
        report.keyless = b.keyless.items;
        report.failures = b.failures.items;
        return report;
    }

    const ctx = reportCtx(alloc, ws, &scratch) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try b.fail(synced, err);
            report.failures = b.failures.items;
            return report;
        },
    };
    report.machine_id = kept.machine.peek(alloc, ws.env) catch null;
    const index = store.loadIndex(alloc, ctx.layout) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try b.fail(try ctx.layout.keptDir(alloc), err);
            report.failures = b.failures.items;
            return report;
        },
    };
    try checkStore(alloc, ctx, &index, &report, progress);

    const git_ok = if (kept.clone.requireGit(alloc)) true else |err| switch (err) {
        error.GitTooOld => false,
        else => return err,
    };
    if (!git_ok) {
        report.git_too_old = try kept.clone.gitTooOld(alloc);
        return report;
    }

    var infos: std.ArrayList(CloneInfo) = .empty;
    for (clones) |p| {
        if (progress) |pr| pr.enter(p);
        const c = kept.clone.inspect(alloc, p, ctx.code_root) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try b.fail(p, err);
                continue;
            },
        };
        var info: CloneInfo = .{ .path = p, .c = c };
        try checkClone(ctx, &index, &b, &info);
        try infos.append(alloc, info);
    }
    if (progress) |pr| pr.endWalk();

    for (projects) |p| {
        const loose = try kept_cmd.hubLoose(alloc, p.hub_path, ctx);
        if (loose.len > 0) try b.candidates.append(alloc, .{ .place = p.hub_path, .hub = true, .rels = loose });
    }

    const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms));
    for (try kept.ops.asideEntries(ctx, &index, now_ms, &b.referenced, .present)) |e| {
        report.aside_bytes += e.bytes;
        if (e.held == null) report.aside_prunable += 1;
    }

    report.orphans = try findOrphans(ctx, &index, infos.items);
    report.released = try findReleased(ctx, &index, infos.items);

    try b.dropTrackedLinks();
    report.unlinked = b.unlinked.items;
    report.stops = b.stops.items;
    report.keyless = b.keyless.items;
    report.local_mismatch = b.local_mismatch.items;
    report.not_ignored = b.not_ignored.items;
    report.failures = b.failures.items;
    report.tracked_links = b.tracked_links.items;
    report.tracked_upstream = b.tracked_upstream.items;
    report.candidates = b.candidates.items;
    report.candidate_failures = b.candidate_failures.items;
    report.auto_unignored = b.auto_unignored.items;
    return report;
}

/// Reconciles, planning only, every working tree of one clone, and checks
/// its tracked links, its upstream, and its candidates. A clone whose
/// `core.worktree` points elsewhere has no key and so no kept files: it is
/// only reported as such.
fn checkClone(ctx: kept.Ctx, index: *const store.KeyIndex, b: *Builder, info: *CloneInfo) !void {
    const a = ctx.alloc;
    const c = info.c;
    if (c.worktreeElsewhere()) {
        const rep = reconcile.reconcile(ctx, index, info.path, .plan) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return b.fail(info.path, err),
        };
        return b.addReport(info.path, rep);
    }
    var trees: std.ArrayList([]const u8) = .empty;
    try trees.append(a, c.worktree);
    if (kept.clone.worktrees(a, c)) |all| {
        for (all) |t| {
            if (!t.readable() or paths.contains(trees.items, t.path)) continue;
            try trees.append(a, t.path);
        }
    } else |err| if (err == error.OutOfMemory) return err;

    for (trees.items, 0..) |t, n| {
        const rep = reconcile.reconcile(ctx, index, t, .plan) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try b.fail(t, err);
                continue;
            },
        };
        if (n == 0) info.resolved = rep.resolved;
        try b.addReport(t, rep);

        var linked_rels: std.ArrayList([]const u8) = .empty;
        for (rep.items) |i| {
            if (i.worktree == null and atHoltLink(i.outcome) and !paths.contains(linked_rels.items, i.rel)) try linked_rels.append(a, i.rel);
        }
        for (try kept.clone.notIgnored(a, t, linked_rels.items)) |rel| try b.not_ignored.append(a, .{ .tree = t, .rel = rel });

        var chain: std.ArrayList([]const u8) = .empty;
        if (rep.key) |k| try chain.append(a, k);
        if (rep.resolved) |k| try chain.append(a, k);
        try trackedLinks(ctx, t, chain.items, try store.syncedRoots(a, ctx.layout), b);
    }

    if (info.resolved) |rk| try trackedUpstream(ctx, c.worktree, rk, b);

    const listing = candidates.listAll(ctx, index, c, .{ .deep_nested = true, .tracked_edits = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try b.candidate_failures.append(a, .{ .path = c.worktree, .detail = @errorName(err) });
            return;
        },
    };
    for (listing.unlisted) |u| {
        try b.candidate_failures.append(a, .{ .path = u.worktree, .detail = u.detail orelse if (u.problem) |p| @tagName(p) else "unlisted" });
    }
    for (listing.listings) |l| {
        var rels: std.ArrayList([]const u8) = .empty;
        for (l.candidates) |cand| if (!cand.at_kept_path) try rels.append(a, cand.rel);
        var nested: std.ArrayList([]const u8) = .empty;
        for (l.nested) |nr| try nested.append(a, nr.repo);
        if (rels.items.len + nested.items.len + l.submodules_failed.len > 0) {
            try b.candidates.append(a, .{ .place = l.worktree, .rels = rels.items, .nested = nested.items, .submodules_failed = l.submodules_failed });
        }
        for (l.auto_unignored) |u| try b.auto_unignored.append(a, .{ .tree = l.worktree, .rel = u.rel, .pattern = u.pattern, .negation = u.negation });
    }
}

/// Every symlink the working tree at `tree` tracks whose target is under
/// `kept/`: holt's own link committed by mistake (`link.isHolt` for a key
/// of `chain` under a synced root of `roots`), or any link into the
/// current store.
fn trackedLinks(ctx: kept.Ctx, tree: []const u8, chain: []const []const u8, roots: []const []const u8, b: *Builder) !void {
    const a = ctx.alloc;
    const res = try git.runInRepoScoped(a, &.{ "ls-files", "-s", "-z" }, tree);
    if (res.status != 0) return b.failures.append(a, .{ .path = tree, .detail = "git could not list what it tracks" });
    const kept_dir = try ctx.layout.keptDir(a);
    var it = std.mem.splitScalar(u8, res.stdout, 0);
    while (it.next()) |rec| {
        if (!std.mem.startsWith(u8, rec, "120000 ")) continue;
        const tab = std.mem.indexOfScalar(u8, rec, '\t') orelse continue;
        const rel = rec[tab + 1 ..];
        const lp = try fsutil.joinSlashy(a, tree, rel);
        const raw = (try content.readLink(a, lp)) orelse continue;
        const target = try kept.link.resolveTarget(a, lp, raw);
        if (kept.link.isHolt(a, lp, raw, chain, roots, rel) or try fsutil.pathIsInsideNormalized(a, target, kept_dir)) {
            try b.tracked_links.append(a, .{ .tree = tree, .rel = try a.dupe(u8, rel), .detail = raw });
        }
    }
}

/// Every kept path of `key` that the upstream default branch
/// (`origin/HEAD`) tracks: a path listed there byte for byte, or in any
/// ASCII case where the clone's git matches names so (`core.ignorecase`),
/// or for a directory a path below it. Nothing when `origin/HEAD` is unset.
fn trackedUpstream(ctx: kept.Ctx, tree: []const u8, key: []const u8, b: *Builder) !void {
    const a = ctx.alloc;
    const ks = try store.loadKeyState(a, ctx.layout, key);
    var rels: std.ArrayList([]const u8) = .empty;
    for (try ks.keptSet(a)) |rel| if (paths.check(rel) == null) try rels.append(a, rel);
    if (rels.items.len == 0) return;
    const head = try git.runInRepoScoped(a, &.{ "rev-parse", "-q", "--verify", "refs/remotes/origin/HEAD^{commit}" }, tree);
    if (head.status != 0) return;
    const list = try git.runInRepoScoped(a, &.{ "ls-tree", "-r", "-z", "--name-only", "--full-tree", "refs/remotes/origin/HEAD" }, tree);
    if (list.status != 0) return b.failures.append(a, .{ .path = tree, .detail = "git could not list origin/HEAD" });
    const icase = try kept.clone.ignoresCase(a, tree);
    for (rels.items) |rel| {
        var it = std.mem.splitScalar(u8, list.stdout, 0);
        while (it.next()) |p| {
            if (p.len < rel.len) continue;
            const head_part = p[0..rel.len];
            const same = if (icase) std.ascii.eqlIgnoreCase(head_part, rel) else std.mem.eql(u8, head_part, rel);
            if (same and (p.len == rel.len or p[rel.len] == '/')) {
                try b.tracked_upstream.append(a, .{ .tree = tree, .rel = rel });
                break;
            }
        }
    }
}

const top_reserved = [_][]const u8{ ".holt-skip", ".holt-auto", ".holt-skip.d", ".holt-auto.d", ".holt-aside", ".holt-tmp", store.pruned_basename, store.machines_basename, store.roots_basename };
const key_reserved = [_][]const u8{ store.record_basename, ".holt-skip", ".holt-skip.d", ".holt-paths", ".holt-released", ".holt-from" };

fn isTemp(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".tmp") or std.mem.startsWith(u8, name, ".holt-tmp-");
}

/// A `.holt-` name at a level of the store that is none of the names holt
/// writes there: a cloud conflict copy of one (`.holt-skip (1)`,
/// `.holt-kept.sync-conflict-...json`).
fn isReservedCopy(name: []const u8, known: []const []const u8) bool {
    if (!paths.isReserved(name) or isTemp(name)) return false;
    for (known) |k| if (std.mem.eql(u8, name, k)) return false;
    return true;
}

/// The store checks: each key's record, markers, paths, unknown and
/// online-only files, conflict copies, and the aside entries.
fn checkStore(alloc: std.mem.Allocator, ctx: kept.Ctx, index: *const store.KeyIndex, report: *Report, progress: ?*doctor.Progress) !void {
    const layout = ctx.layout;
    const kept_dir = try layout.keptDir(alloc);
    var invalid: std.ArrayList(KeyRel) = .empty;
    var bad: std.ArrayList(store.Bad) = .empty;
    var versions: std.ArrayList([]const u8) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    var unknown_dirs: std.ArrayList([]const u8) = .empty;
    var unrecorded: std.ArrayList([]const u8) = .empty;
    var copies: std.ArrayList(Copy) = .empty;
    var placeholders: std.ArrayList([]const u8) = .empty;
    var suspected: std.ArrayList([]const u8) = .empty;
    try bad.appendSlice(alloc, index.bad);

    var host_buf: [kept.machine.host_name_max]u8 = undefined;
    const host = kept.machine.hostName(&host_buf);

    for (index.keys) |key| {
        if (progress) |pr| pr.enter(try fsutil.joinSlashy(alloc, kept_dir, key));
        const ks = try store.loadKeyState(alloc, layout, key);
        try bad.appendSlice(alloc, ks.bad);
        if (ks.record) |rec| if (!rec.known()) try versions.append(alloc, key);
        const named = try ks.namedPaths(alloc);
        for (named) |rel| if (paths.check(rel)) |why| try invalid.append(alloc, .{ .key = key, .rel = rel, .reason = why.describe() });
        const kept_set = try ks.keptSet(alloc);
        for (try paths.collisions(alloc, kept_set)) |rel| try invalid.append(alloc, .{ .key = key, .rel = rel, .reason = paths.Invalid.collision.describe() });

        const key_dir = try layout.keyDir(alloc, key);
        for (try store.unknownFiles(alloc, layout, key, named)) |rel| {
            if (icloudStandIn(named, rel)) continue;
            const p = try fsutil.joinSlashy(alloc, key_dir, rel);
            if (try content.entryAt(p) != .dir) {
                try unknown.append(alloc, p);
            } else if (try holdsReserved(alloc, p)) {
                try unrecorded.append(alloc, p);
            } else try unknown_dirs.append(alloc, p);
        }
        try reservedCopiesIn(alloc, key_dir, &key_reserved, &copies);
        try reservedStandIns(alloc, key_dir, &placeholders);

        for (kept_set) |rel| {
            if (paths.check(rel) != null) continue;
            const cp = try layout.copyPath(alloc, key, rel);
            switch (try content.entryAt(cp)) {
                .file => if (fsutil.isOnlineOnly(alloc, cp)) try placeholders.append(alloc, cp),
                .dir => try scanDir(alloc, cp, host, &placeholders, &suspected),
                .absent => if (fsutil.hasIcloudPlaceholder(alloc, cp)) try placeholders.append(alloc, cp),
                else => {},
            }
        }
    }
    if (progress) |pr| pr.endWalk();
    try reservedCopiesIn(alloc, kept_dir, &top_reserved, &copies);
    try reservedStandIns(alloc, kept_dir, &placeholders);
    try strayOutsideKeys(alloc, kept_dir, index.keys, &unknown, &unrecorded, &placeholders);

    const aside_dir = try layout.asideDir(alloc);
    var aside_bad: std.ArrayList(AsideCheck) = .empty;
    var unchecked: std.ArrayList(AsideCheck) = .empty;
    if (std.Io.Dir.cwd().openDir(io(), aside_dir, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(io());
        var stamps: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io())) |e| {
            if (e.kind != .directory) {
                if (!isTemp(e.name) and !store.isMetadata(e.name)) try unknown.append(alloc, try std.fs.path.join(alloc, &.{ aside_dir, e.name }));
                continue;
            }
            if (store.isMetadata(e.name)) continue;
            try stamps.append(alloc, try alloc.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, stamps.items, {}, paths.lessThan);
        for (stamps.items) |s| {
            report.aside_entries += 1;
            const check = aside.verify(alloc, layout, s) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => aside.Check.missing,
            };
            switch (check) {
                .ok => {},
                .missing, .mismatch => try aside_bad.append(alloc, .{ .stamp = s, .check = check }),
                .online_only, .unverifiable => try unchecked.append(alloc, .{ .stamp = s, .check = check }),
            }
        }
    } else |_| {}

    report.invalid = invalid.items;
    report.bad_markers = bad.items;
    report.unknown_versions = versions.items;
    report.unknown_files = unknown.items;
    report.unknown_dirs = unknown_dirs.items;
    report.unrecorded = unrecorded.items;
    report.conflict_copies = copies.items;
    report.placeholders = placeholders.items;
    report.suspected_conflicts = suspected.items;
    report.aside_bad = aside_bad.items;
    report.aside_unchecked = unchecked.items;
}

/// Whether `rel`, an unknown file of a key, is iCloud's `.<name>.icloud`
/// stand-in for a path the key names: reported as a placeholder instead.
fn icloudStandIn(named: []const []const u8, rel: []const u8) bool {
    const base = std.fs.path.basename(rel);
    if (!std.mem.startsWith(u8, base, ".") or !std.mem.endsWith(u8, base, ".icloud")) return false;
    const dir = rel[0 .. rel.len - base.len];
    const name = base[1 .. base.len - ".icloud".len];
    for (named) |n| {
        if (n.len == dir.len + name.len and std.mem.startsWith(u8, n, dir) and std.mem.eql(u8, n[dir.len..], name)) return true;
    }
    return false;
}

/// Adds to `out` each `.holt-` entry directly in `dir` that is a conflict
/// copy of a reserved name (`isReservedCopy`).
fn reservedCopiesIn(alloc: std.mem.Allocator, dir: []const u8, known: []const []const u8, out: *std.ArrayList(Copy)) !void {
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch return;
    defer d.close(io());
    var found: std.ArrayList(Copy) = .empty;
    var it = d.iterate();
    while (try it.next(io())) |e| {
        if (!isReservedCopy(e.name, known)) continue;
        try found.append(alloc, .{ .path = try std.fs.path.join(alloc, &.{ dir, e.name }), .dir = e.kind == .directory });
    }
    std.mem.sort(Copy, found.items, {}, struct {
        fn lt(_: void, x: Copy, y: Copy) bool {
            return paths.lessThan({}, x.path, y.path);
        }
    }.lt);
    try out.appendSlice(alloc, found.items);
}

/// Adds to `out` the reserved name each of iCloud's `.<name>.icloud`
/// stand-ins directly in `dir` stands in for (`store.reservedStandIn`):
/// holt's own file, online-only on this machine.
fn reservedStandIns(alloc: std.mem.Allocator, dir: []const u8, out: *std.ArrayList([]const u8)) !void {
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch return;
    defer d.close(io());
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io())) |e| if (store.reservedStandIn(e.name)) |r| try names.append(alloc, try alloc.dupe(u8, r));
    std.mem.sort([]const u8, names.items, {}, paths.lessThan);
    for (names.items) |n| try out.append(alloc, try std.fs.path.join(alloc, &.{ dir, n }));
}

/// Whether the directory `dir` directly holds a name holt reserves, or
/// iCloud's stand-in for one: a key's markers.
fn holdsReserved(alloc: std.mem.Allocator, dir: []const u8) !bool {
    _ = alloc;
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch return false;
    defer d.close(io());
    var it = d.iterate();
    while (it.next(io()) catch return false) |e| {
        if (paths.isReserved(e.name) or store.reservedStandIn(e.name) != null) return true;
    }
    return false;
}

/// Adds what `kept/` holds outside every key: each stray file to
/// `unknown`; and, for each directory above no key, the directories in it
/// that directly hold a key's markers (`holdsReserved`), or the directory
/// itself when none does and it holds anything, to `unrecorded`, since
/// each may be a key whose record has not synced here yet, or was lost,
/// and deleting it could wipe another machine's kept files. A record that
/// is online-only goes to `placeholders` instead. Reserved names, what
/// folders gather on their own (`store.isMetadata`), and a cloud client's
/// or a NAS's own directories (`doctor.isSystemDir`) are left out.
fn strayOutsideKeys(alloc: std.mem.Allocator, kept_dir: []const u8, keys: []const []const u8, unknown: *std.ArrayList([]const u8), unrecorded: *std.ArrayList([]const u8), placeholders: *std.ArrayList([]const u8)) !void {
    var d = std.Io.Dir.cwd().openDir(io(), kept_dir, .{ .iterate = true }) catch return;
    defer d.close(io());
    var walker = try d.walkSelectively(alloc);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io())) |entry| {
        if (paths.isReserved(entry.basename) or store.reservedStandIn(entry.basename) != null or store.isMetadata(entry.basename)) continue;
        const rel = try alloc.dupe(u8, entry.path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        if (paths.contains(keys, rel)) continue;
        if (entry.kind != .directory) {
            try files.append(alloc, try fsutil.joinSlashy(alloc, kept_dir, rel));
            continue;
        }
        var above = false;
        for (keys) |k| {
            if (k.len > rel.len and std.mem.startsWith(u8, k, rel) and k[rel.len] == '/') above = true;
        }
        if (above) {
            try walker.enter(io(), entry);
            continue;
        }
        if (doctor.isSystemDir(entry.basename)) continue;
        try dirs.append(alloc, try fsutil.joinSlashy(alloc, kept_dir, rel));
    }
    for (dirs.items) |dir| {
        const marked = try markedDirs(alloc, dir);
        if (marked.len == 0) {
            if (!try store.holdsNothing(alloc, dir)) try unrecorded.append(alloc, dir);
            continue;
        }
        for (marked) |m| {
            const record_stand_in = try std.fs.path.join(alloc, &.{ m, "." ++ store.record_basename ++ ".icloud" });
            if (try content.entryAt(record_stand_in) != .absent) {
                try placeholders.append(alloc, try std.fs.path.join(alloc, &.{ m, store.record_basename }));
            } else try unrecorded.append(alloc, m);
        }
    }
    std.mem.sort([]const u8, files.items, {}, paths.lessThan);
    std.mem.sort([]const u8, unrecorded.items, {}, paths.lessThan);
    try unknown.appendSlice(alloc, files.items);
}

/// The directories at or below `root`, links not followed, that directly
/// hold a key's markers (`holdsReserved`), not looking inside one.
fn markedDirs(alloc: std.mem.Allocator, root: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (try holdsReserved(alloc, root)) {
        try out.append(alloc, root);
        return out.items;
    }
    var d = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch return out.items;
    defer d.close(io());
    var walker = try d.walkSelectively(alloc);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (entry.kind != .directory or store.isMetadata(entry.basename) or paths.isReserved(entry.basename)) continue;
        const full = try std.fs.path.join(alloc, &.{ root, entry.path });
        if (try holdsReserved(alloc, full)) {
            try out.append(alloc, full);
            continue;
        }
        try walker.enter(io(), entry);
    }
    std.mem.sort([]const u8, out.items, {}, paths.lessThan);
    return out.items;
}

/// Walks the kept directory at `root`, links not followed, adding each
/// online-only file to `placeholders` and each name shaped like a cloud
/// conflict copy (`suspectedConflict`) to `suspected`.
fn scanDir(alloc: std.mem.Allocator, root: []const u8, host: []const u8, placeholders: *std.ArrayList([]const u8), suspected: *std.ArrayList([]const u8)) !void {
    var d = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch return;
    defer d.close(io());
    var walker = try d.walkSelectively(alloc);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        const full = try std.fs.path.join(alloc, &.{ root, entry.path });
        const parent = std.fs.path.dirname(full) orelse root;
        if (try suspectedConflict(alloc, parent, entry.basename, host)) try suspected.append(alloc, full);
        switch (entry.kind) {
            .directory => try walker.enter(io(), entry),
            .file => if (fsutil.isOnlineOnly(alloc, full)) try placeholders.append(alloc, full),
            else => {},
        }
        if (std.mem.startsWith(u8, entry.basename, ".") and std.mem.endsWith(u8, entry.basename, ".icloud")) try placeholders.append(alloc, full);
    }
}

/// Whether `name`, in the directory `dir`, looks like a cloud client's
/// conflict copy: Dropbox's "conflicted copy" and Syncthing's
/// ".sync-conflict-" anywhere; Drive's "<stem> (<n>)<ext>", iCloud's
/// "<stem> <n><ext>", and OneDrive's "<stem>-<this host><ext>" only while
/// "<stem><ext>" is beside it.
fn suspectedConflict(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, host: []const u8) !bool {
    if (containsIgnoreCase(name, "conflicted copy") or std.mem.indexOf(u8, name, ".sync-conflict-") != null) return true;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const split = if (dot) |i| (if (i == 0) name.len else i) else name.len;
    const stem = name[0..split];
    const ext = name[split..];
    const original: ?[]const u8 = blk: {
        if (std.mem.endsWith(u8, stem, ")")) {
            if (std.mem.lastIndexOf(u8, stem, " (")) |open| {
                if (allDigits(stem[open + 2 .. stem.len - 1]) and open > 0) break :blk stem[0..open];
            }
        }
        if (std.mem.lastIndexOfScalar(u8, stem, ' ')) |sp| {
            if (sp > 0 and allDigits(stem[sp + 1 ..])) break :blk stem[0..sp];
        }
        if (host.len > 0 and stem.len > host.len + 1 and stem[stem.len - host.len - 1] == '-' and std.ascii.eqlIgnoreCase(stem[stem.len - host.len ..], host)) {
            break :blk stem[0 .. stem.len - host.len - 1];
        }
        break :blk null;
    };
    const o = original orelse return false;
    const sibling = try std.fs.path.join(alloc, &.{ dir, try std.mem.concat(alloc, u8, &.{ o, ext }) });
    return try content.entryAt(sibling) != .absent;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Whether the clone `info` files under `key`: its own key or the one its
/// files resolve to.
fn usesKey(info: CloneInfo, key: []const u8) bool {
    if (info.c.key) |k| if (std.mem.eql(u8, k, key)) return true;
    if (info.resolved) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// Keys with kept files that no clone here uses, that no `.holt-from/`
/// marker names, whose record's `root` a clone here matches, and whose kept
/// set that clone's key does not already hold by hash: the same history,
/// renamed, transferred, or a fork.
fn findOrphans(ctx: kept.Ctx, index: *const store.KeyIndex, infos: []CloneInfo) ![]const Orphan {
    const a = ctx.alloc;
    var out: std.ArrayList(Orphan) = .empty;
    keys: for (index.keys) |k| {
        for (infos) |info| if (usesKey(info, k)) continue :keys;
        if (index.successorsOf(k).len > 0) continue;
        const rec = (try store.readRecord(a, ctx.layout, k)) orelse continue;
        const root = rec.root orelse continue;
        const ks = try store.loadKeyState(a, ctx.layout, k);
        const set = try ks.keptSet(a);
        if (set.len == 0) continue;
        for (infos) |*info| {
            const target = info.resolved orelse info.c.key orelse continue;
            if (info.roots == null) info.roots = kept.clone.rootCommits(a, info.c.main) catch &.{};
            if (!paths.contains(info.roots.?, root)) continue;
            const ts = try store.loadKeyState(a, ctx.layout, target);
            var all_there = true;
            for (set) |rel| {
                var here = false;
                for (ks.factsFor(rel)) |f| {
                    for (ts.factsFor(rel)) |g| {
                        if (std.mem.eql(u8, f.sha256, g.sha256)) here = true;
                    }
                }
                if (!here) all_there = false;
            }
            if (!all_there) try out.append(a, .{ .key = k, .clone = info.c.worktree });
        }
    }
    return out.items;
}

/// Released paths whose kept copy is still in the store, with the machines
/// whose facts name them and a clone here that uses the key.
fn findReleased(ctx: kept.Ctx, index: *const store.KeyIndex, infos: []const CloneInfo) ![]const Released {
    const a = ctx.alloc;
    var out: std.ArrayList(Released) = .empty;
    for (index.keys) |k| {
        const ks = try store.loadKeyState(a, ctx.layout, k);
        for (ks.released) |rel| {
            if (paths.check(rel) != null) continue;
            const cp = try ctx.layout.copyPath(a, k, rel);
            if (try content.entryAt(cp) == .absent and !fsutil.hasIcloudPlaceholder(a, cp)) continue;
            var machines: std.ArrayList([]const u8) = .empty;
            for (ks.factsFor(rel)) |f| if (!paths.contains(machines.items, f.machine)) try machines.append(a, f.machine);
            var clone_path: ?[]const u8 = null;
            for (infos) |info| if (usesKey(info, k)) {
                clone_path = info.c.worktree;
                break;
            };
            const origin: ?[]const u8 = if (clone_path == null) (if (try store.readRecord(a, ctx.layout, k)) |rec| rec.origin else null) else null;
            try out.append(a, .{ .key = k, .rel = rel, .machines = machines.items, .clone = clone_path, .origin = origin });
        }
    }
    return out.items;
}

test "suspectedConflict: each client's form, the numbered ones only beside their original" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try a.dupe(u8, buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ dir, "notes.md" }), .data = "" });

    try std.testing.expect(try suspectedConflict(a, dir, "notes (host's conflicted copy 2024-01-01).md", "h"));
    try std.testing.expect(try suspectedConflict(a, dir, "notes.sync-conflict-20240101-000000-ABC.md", "h"));
    try std.testing.expect(try suspectedConflict(a, dir, "notes (1).md", "h"));
    try std.testing.expect(try suspectedConflict(a, dir, "notes 2.md", "h"));
    try std.testing.expect(try suspectedConflict(a, dir, "notes-MYHOST.md", "myhost"));
    try std.testing.expect(!try suspectedConflict(a, dir, "other (1).md", "h"));
    try std.testing.expect(!try suspectedConflict(a, dir, "chapter 2.md", "h"));
    try std.testing.expect(!try suspectedConflict(a, dir, "notes.md", "h"));
}

test "isReservedCopy: a conflict copy of a reserved name, never a name holt writes or a temporary" {
    try std.testing.expect(isReservedCopy(".holt-skip (1)", &top_reserved));
    try std.testing.expect(isReservedCopy(".holt-kept.sync-conflict-2024.json", &key_reserved));
    try std.testing.expect(!isReservedCopy(".holt-skip", &top_reserved));
    try std.testing.expect(!isReservedCopy(".holt-tmp-0123", &key_reserved));
    try std.testing.expect(!isReservedCopy(".holt-kept.json.abc.tmp", &key_reserved));
    try std.testing.expect(!isReservedCopy("notes", &key_reserved));
}
