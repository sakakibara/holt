//! What the block hides from git in each working tree of a clone, as git
//! itself lists it (`clone.blockHides`), and which of it holt holds nowhere
//! else. Reconcile's closing sweep sets that aside, `unprotected` lists it
//! for the deleters, and every write that adds a block line first asks
//! what the line would newly hide in every working tree of the clone, so
//! the one rule serves all of them.

const std = @import("std");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const block = @import("block.zig");
const clone = @import("clone.zig");
const link = @import("link.zig");
const ctx_mod = @import("ctx.zig");
const machine = @import("machine.zig");

const Ctx = ctx_mod.Ctx;

/// Why a place the block hides is reported and never copied.
pub const Why = enum {
    /// A nested repository (`content.isNestedRepo`).
    nested_repository,
    /// A parent component in the working tree is not a real directory.
    parent_not_dir,
    /// A component that is a `.git` as git's walk finds one.
    dot_git,
    /// A symlink holt did not make, or a special file: git deletes it like
    /// any file it ignores, and aside holds only regular files and
    /// directories.
    not_copyable,
    /// A working tree git records that cannot be swept
    /// (`clone.TreeProblem`, the detail), so what the block hides in it is
    /// unknown.
    tree_unreadable,
    /// Reading the place failed; the detail is the error.
    failed,
};

/// Local content the block hides from git that holt holds nowhere else, or
/// a place the block hides that could not be judged.
pub const Found = struct {
    /// The working tree it is in.
    worktree: []const u8,
    /// Where it is under `worktree`, `/`-joined: the block line's path,
    /// spelled as git lists it (a line matches every spelling git's
    /// `core.ignorecase` folds together); for a temporary, the visited path
    /// it sits beside, when one does; for a nested repository inside a
    /// unit, its own path; `.` for the working tree itself.
    rel: []const u8,
    /// The block line's path, when git listed it under another spelling.
    line: ?[]const u8 = null,
    /// The temporary (`paths.tempRel`) holding the content, when it is one.
    temp: ?[]const u8 = null,
    /// The block line (a path or a temporary) the place is under, when it
    /// is under one of holt's lines; null for a place of the working tree
    /// itself or under a foreign line.
    by: ?[]const u8 = null,
    entry: content.Entry,
    why: ?Why = null,
    /// For `Why.failed`, the error.
    detail: ?[]const u8 = null,

    /// Where the content is.
    pub fn path(f: Found, alloc: std.mem.Allocator) ![]const u8 {
        return fsutil.joinSlashy(alloc, f.worktree, f.temp orelse f.rel);
    }
};

/// What a clone's visited paths are, read from the store, the block, and
/// `pending`.
pub const Scope = struct {
    ctx: Ctx,
    c: clone.Clone,
    /// The key whose kept copies count, or null for a clone with none.
    key: ?[]const u8,
    /// The keys whose links are holt's.
    chain: []const []const u8,
    /// The synced roots holt's links may lie under (`store.syncedRoots`).
    roots: []const []const u8,
    /// The key's state, or null when the store cannot be read or there is
    /// no key.
    ks: ?store.KeyState,
    /// The block's paths, temporaries, and other lines; for an unbalanced
    /// block, the paths and temporaries `block.salvage` finds.
    block_rels: []const []const u8,
    block_temps: []const []const u8,
    block_foreign: []const []const u8,
    parsed: ?block.Parsed,
    pending: []const clone.Pending,
    visited: []const []const u8,
    /// Every working tree of the clone (`clone.worktrees`), each as its
    /// real path; none when they cannot be read.
    worktrees: []const []const u8 = &.{},
    /// `core.ignorecase` of `c.worktree`, once `ignoresCase` asked git.
    own_case: *?bool,

    pub fn load(ctx: Ctx, c: clone.Clone, key: ?[]const u8, own: ?[]const u8, store_ok: bool) !Scope {
        const a = ctx.alloc;
        const ks: ?store.KeyState = if (key != null and store_ok) try store.loadKeyState(a, ctx.layout, key.?) else null;
        var chain: std.ArrayList([]const u8) = .empty;
        if (key) |k| {
            try chain.append(a, k);
            if (own != null and !std.mem.eql(u8, own.?, k)) try chain.append(a, own.?);
            if (store_ok) {
                var ignored: std.ArrayList(store.Bad) = .empty;
                for (try store.readFrom(a, ctx.layout, k, &ignored)) |old| try chain.append(a, old);
            }
        }
        const roots: []const []const u8 = if (store_ok) try store.syncedRoots(a, ctx.layout) else try a.dupe([]const u8, &.{ctx.layout.synced_root});
        var scope: Scope = .{ .ctx = ctx, .c = c, .key = key, .chain = chain.items, .roots = roots, .ks = ks, .block_rels = &.{}, .block_temps = &.{}, .block_foreign = &.{}, .parsed = null, .pending = try clone.readPending(a, c.common_dir), .visited = &.{}, .worktrees = try realTrees(a, c), .own_case = try a.create(?bool) };
        scope.own_case.* = null;
        if (block.read(a, c.common_dir)) |p| {
            scope.parsed = p;
            scope.block_rels = p.rels;
            scope.block_temps = p.temps;
            scope.block_foreign = p.foreign;
        } else |err| switch (err) {
            error.UnbalancedBlock => {
                const got = try block.salvage(a, try content.readSmall(a, try block.excludePath(a, c.common_dir)));
                scope.block_rels = got.rels;
                scope.block_temps = got.temps;
            },
            else => return err,
        }
        var pending_rels: std.ArrayList([]const u8) = .empty;
        for (scope.pending) |p| try pending_rels.append(a, p.rel);
        var fact_rels: std.ArrayList([]const u8) = .empty;
        var kept_set: []const []const u8 = &.{};
        var released: []const []const u8 = &.{};
        if (ks) |st| {
            for (st.facts) |f| try fact_rels.append(a, f.rel);
            kept_set = try st.keptSet(a);
            released = st.released;
        }
        scope.visited = try sortedUnique(a, &.{ kept_set, scope.block_rels, released, fact_rels.items, pending_rels.items });
        return scope;
    }

    /// Whether git in the working tree at `tree` matches names in any ASCII
    /// case (`clone.ignoresCase`), asked once per scope for the clone's own
    /// working tree.
    pub fn ignoresCase(s: Scope, tree: []const u8) !bool {
        if (!std.mem.eql(u8, tree, s.c.worktree)) return clone.ignoresCase(s.ctx.alloc, tree);
        if (s.own_case.*) |v| return v;
        const v = try clone.ignoresCase(s.ctx.alloc, tree);
        s.own_case.* = v;
        return v;
    }

    /// The other working trees of the clone at or below the working tree at
    /// `tree`, each `/`-joined relative to it. Each is listed and swept on
    /// its own, so none is a nested repository of `tree` or content of it.
    pub fn worktreesIn(s: Scope, tree: []const u8) ![]const []const u8 {
        const a = s.ctx.alloc;
        const top = try fsutil.realPathOrSelf(a, tree);
        var out: std.ArrayList([]const u8) = .empty;
        for (s.worktrees) |w| {
            if (w.len <= top.len + 1 or !std.mem.startsWith(u8, w, top) or !std.fs.path.isSep(w[top.len])) continue;
            try out.append(a, try fsutil.forwardSlashed(a, w[top.len + 1 ..]));
        }
        return out.items;
    }

    /// Where `clone.blockHides` may put the file it hands git, in order: the
    /// clone's state directory when it exists (it is never created for
    /// this), then `scratchDir`. A run that only reports (`Ctx.scratch`)
    /// never uses the clone's state directory.
    pub fn excludeDirs(s: Scope) ![]const []const u8 {
        const a = s.ctx.alloc;
        var out: std.ArrayList([]const u8) = .empty;
        const state = try clone.stateDir(a, s.c.common_dir);
        if (s.ctx.scratch == null and (content.entryAt(state) catch content.Entry.absent) == .dir) try out.append(a, state);
        const scratch = try scratchDir(a, s.ctx);
        if (fsutil.ensureDir(scratch)) try out.append(a, scratch) else |_| {}
        return out.items;
    }

    /// What the block's whole current content hides in every working tree
    /// (`hiddenAll`).
    pub fn hiddenByBlock(s: Scope, skip: ?[]const u8) ![]const Found {
        return s.hiddenAll(s.block_rels, s.block_temps, s.block_foreign, skip);
    }

    /// `hiddenIn` for every working tree of the clone but `skip`. A working
    /// tree git records that cannot be swept, wherever it is and whatever
    /// its lock, is one `tree_unreadable` place whose detail says why
    /// (`clone.TreeProblem`). When the working trees cannot be read from
    /// the common directory, that is a `failed` place of the clone's own
    /// working tree, and only that one is judged.
    pub fn hiddenAll(s: Scope, rels: []const []const u8, temps: []const []const u8, foreign: []const []const u8, skip: ?[]const u8) ![]const Found {
        return s.acrossTrees(.{ .rels = rels, .temps = temps, .foreign = foreign }, .{}, skip);
    }

    /// What adding the lines `new` to a block holding `current` would newly
    /// hide in every working tree of the clone but `skip`, asked of git
    /// before the lines are written: git lists what `current` and `new`
    /// hide together, and only the units under a line of `new` count (with
    /// each such line's own path, as in `hiddenIn`), since what `current`
    /// hides already is the closing sweep's. Places are reported as by
    /// `hiddenAll`; when the working trees cannot be read, the one `failed`
    /// place is all there is.
    pub fn newlyHiddenAll(s: Scope, current: Lines, new: Lines, skip: ?[]const u8) ![]const Found {
        return s.acrossTrees(current, new, skip);
    }

    fn acrossTrees(s: Scope, current: Lines, new: Lines, skip: ?[]const u8) ![]const Found {
        const a = s.ctx.alloc;
        var out: std.ArrayList(Found) = .empty;
        const only_new = new.rels.len + new.temps.len > 0;
        const trees = clone.worktrees(a, s.c) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => blk: {
                try out.append(a, .{ .worktree = s.c.worktree, .rel = ".", .entry = .other, .why = .failed, .detail = @errorName(err) });
                if (only_new) return out.items;
                break :blk try a.dupe(clone.Worktree, &.{.{ .path = s.c.worktree }});
            },
        };
        for (trees) |t| {
            if (skip) |sk| if (std.mem.eql(u8, sk, t.path)) continue;
            if (t.problem) |p| {
                try out.append(a, .{ .worktree = t.path, .rel = ".", .entry = .other, .why = .tree_unreadable, .detail = @tagName(p) });
                continue;
            }
            try out.appendSlice(a, try s.hiddenWith(t.path, current, new));
        }
        return out.items;
    }

    /// What the block lines naming `rels` and `temps`, with `foreign`
    /// verbatim, hide from git in the working tree at `tree` and holt holds
    /// nowhere else, as git lists it (`clone.blockHides`) and, so that a
    /// listing that leaves a place out never hides it, at each line's own
    /// path judged directly unless git tracks it there. Each listed place
    /// is grouped under the line it is at or below, and the line's path, in
    /// git's spelling, is the unit judged and set aside whole, tracked
    /// content below it included (a harmless over-copy); a listed directory
    /// above lines is dropped when git also listed something below it,
    /// since git lists what it hides there on its own, and is otherwise its
    /// own unit (a foreign line hides it whole), dropped when it holds
    /// nothing but what the lines below it would drop and empty
    /// directories; a place under no line (a foreign line's) is its own
    /// unit; a unit inside another is judged with it. A unit is
    /// dropped when it is absent, an empty directory, holt's link (of its
    /// line, or of a kept path equal to it under case folding and
    /// normalization), a link at a temporary, an empty file at a probe's
    /// name (`paths.isProbeRel`), or content identical to its kept copy
    /// (`identical`); it is reported and never copied when a
    /// parent is not a real directory (a line's own path under such a
    /// parent holds nothing the block hides, and is dropped), a component
    /// is a `.git` as git's walk finds one (`dotGitComponent`), it is a
    /// nested repository (`content.isNestedRepo`), or it is a
    /// symlink holt did not make or a special file. A directory unit judged
    /// otherwise that holds nested repositories below it is followed by a
    /// `nested_repository` place for each (`content.nestedRepos`), while the
    /// rest of it is judged as usual. Another working tree of the clone
    /// (`worktreesIn`) is neither a unit nor a nested repository: it is
    /// swept on its own. A failure to read one
    /// unit becomes that unit's `failed` place, and a listing git cannot
    /// make is a `failed` place of the working tree itself.
    ///
    /// Limits: content identical to its kept copy is not set aside, since
    /// the kept copy holds it; if the kept copy later changes, another
    /// working tree's copy of the old version is its only copy until the
    /// next closing sweep sets it aside.
    pub fn hiddenIn(s: Scope, tree: []const u8, rels: []const []const u8, temps: []const []const u8, foreign: []const []const u8) ![]const Found {
        return s.hiddenWith(tree, .{ .rels = rels, .temps = temps, .foreign = foreign }, .{});
    }

    /// `hiddenIn` for the lines `current` and `new` together; when `new`
    /// names any line, only what is under one of its lines.
    fn hiddenWith(s: Scope, tree: []const u8, current: Lines, new: Lines) ![]const Found {
        const a = s.ctx.alloc;
        const only_new = new.rels.len + new.temps.len > 0;
        var lines: std.ArrayList(Line) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for ([_]Lines{ current, new }, [_]bool{ false, true }) |set, is_new| {
            for (set.rels) |r| {
                try lines.append(a, .{ .path = r, .temp = false, .fold = try foldOrSelf(a, r), .new = is_new });
                try names.append(a, r);
            }
            for (set.temps) |t| {
                try lines.append(a, .{ .path = t, .temp = true, .fold = try foldOrSelf(a, t), .new = is_new });
                try names.append(a, t);
            }
        }
        const foreign = try std.mem.concat(a, []const u8, &.{ current.foreign, new.foreign });
        if (lines.items.len + foreign.len == 0) return &.{};
        const ignore_case = try s.ignoresCase(tree);
        const trees = try s.worktreesIn(tree);
        const listed = clone.blockHides(a, tree, try s.excludeDirs(), s.ctx.machine_id, try block.patternText(a, names.items, foreign)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };

        var out: std.ArrayList(Found) = .empty;
        var units: std.ArrayList(Unit) = .empty;
        if (listed) |ls| {
            for (ls) |p| {
                const u = (try group(a, lines.items, ls, p)) orelse continue;
                if (only_new and !(if (u.line) |l| l.new else false)) continue;
                for (units.items) |seen| {
                    if (std.mem.eql(u8, seen.at, u.at)) break;
                } else try units.append(a, u);
            }
        } else try out.append(a, .{ .worktree = tree, .rel = ".", .entry = .other, .why = .failed, .detail = "ListingFailed" });
        var own: std.ArrayList(Line) = .empty;
        for (lines.items) |l| if (!only_new or l.new) try own.append(a, l);
        try s.addOwnPaths(tree, own.items, &units);

        for (units.items) |u| {
            const inside = for (units.items) |o| {
                if (below(u.at, o.at)) break true;
            } else false;
            if (inside) continue;
            if (paths.contains(trees, u.at)) continue;
            const got = s.judge(tree, u, lines.items, ignore_case) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => Found{ .worktree = tree, .rel = u.at, .entry = .other, .why = .failed, .detail = @errorName(err) },
            };
            const f = got orelse continue;
            try out.append(a, f);
            if (f.why != null or f.entry != .dir) continue;
            const inner = try content.nestedRepos(a, try f.path(a), ignore_case, std.math.maxInt(usize));
            for (inner) |r| {
                const at = try std.mem.concat(a, u8, &.{ f.temp orelse f.rel, "/", r });
                if (paths.contains(trees, at)) continue;
                try out.append(a, .{ .worktree = tree, .rel = at, .by = f.by, .entry = .dir, .why = .nested_repository });
            }
        }
        return out.items;
    }

    /// Adds to `units` each line's own path that something is at in `tree`,
    /// unless a unit already names it (byte for byte, or under the line in
    /// another spelling naming the same file) or git tracks it there. When
    /// git cannot say what it tracks, or the path cannot be read, it is
    /// added, so judging it reports the failure.
    fn addOwnPaths(s: Scope, tree: []const u8, lines: []const Line, units: *std.ArrayList(Unit)) !void {
        const a = s.ctx.alloc;
        var todo: std.ArrayList(Line) = .empty;
        for (lines) |l| {
            if (try covered(a, tree, units.items, l)) continue;
            const e = content.entryAt(try fsutil.joinSlashy(a, tree, l.path)) catch content.Entry.other;
            if (e == .absent) continue;
            try todo.append(a, l);
        }
        if (todo.items.len == 0) return;
        var rels: std.ArrayList([]const u8) = .empty;
        for (todo.items) |l| try rels.append(a, l.path);
        const how = clone.tracked(a, tree, rels.items) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        for (todo.items, 0..) |l, i| {
            if (how) |h| {
                const is = h[i].isTracked(a, tree, l.path, .all) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => false,
                };
                if (is) continue;
            }
            try units.append(a, .{ .at = l.path, .line = l, .own = true });
        }
    }

    /// Judges the unit `u` of `tree`, with `lines` every line the listing
    /// was asked about and `ignore_case` the tree's `core.ignorecase`.
    fn judge(s: Scope, tree: []const u8, u: Unit, lines: []const Line, ignore_case: bool) !?Found {
        const a = s.ctx.alloc;
        const line = u.line;
        const is_temp = if (line) |l| l.temp else false;
        const owner: ?[]const u8 = if (is_temp) try s.tempOwner(a, line.?.path) else null;
        var f: Found = .{ .worktree = tree, .rel = u.at, .entry = .other, .by = if (line) |l| l.path else null };
        if (is_temp) {
            f.rel = owner orelse u.at;
            f.temp = u.at;
        } else if (line) |l| {
            if (!std.mem.eql(u8, l.path, u.at)) f.line = l.path;
        }
        if (try dotGitComponent(a, tree, u.at, ignore_case)) {
            f.why = .dot_git;
            return f;
        }
        if (!try link.parentsReal(a, tree, u.at)) {
            if (u.own) return null;
            f.why = .parent_not_dir;
            return f;
        }
        const at = try fsutil.joinSlashy(a, tree, u.at);
        f.entry = try content.entryAt(at);
        switch (f.entry) {
            .absent => return null,
            .symlink => {
                if (is_temp) return null;
                const raw = (try content.readLink(a, at)) orelse return null;
                if (try s.holtLink(a, at, raw, u.at)) return null;
                if (line) |l| if (try s.holtLink(a, at, raw, l.path)) return null;
                f.why = .not_copyable;
            },
            .file, .dir => {
                if (is_temp and paths.isProbeRel(u.at) and try content.isEmptyFile(at)) return null;
                if (f.entry == .dir) {
                    if (!try content.holdsAnything(a, at)) return null;
                    if (try link.onlyHoltLinks(a, at, s.chain, s.roots, u.at)) return null;
                    if (try content.isNestedRepo(a, at, ignore_case)) {
                        f.why = .nested_repository;
                        return f;
                    }
                    if (u.above and !try s.aboveHolds(tree, u.at, lines, ignore_case)) return null;
                }
                const kept_rel: ?[]const u8 = if (is_temp) owner else if (line) |l| l.path else null;
                if (kept_rel) |k| if (try s.identical(at, k)) return null;
            },
            .other => f.why = .not_copyable,
        }
        return f;
    }

    /// Whether the directory `at` of `tree`, which lies above some of
    /// `lines`, holds content holt holds nowhere else: a line below it
    /// whose own path is not dropped when judged, or anything outside those
    /// lines' paths other than empty directories.
    fn aboveHolds(s: Scope, tree: []const u8, at: []const u8, lines: []const Line, ignore_case: bool) anyerror!bool {
        const a = s.ctx.alloc;
        const at_fold = try foldOrSelf(a, at);
        const n = std.mem.count(u8, at, "/") + 1;
        var subs: std.ArrayList([]const u8) = .empty;
        for (lines) |l| {
            const sub = if (below(l.path, at)) l.path else if (below(l.fold, at_fold)) blk: {
                const lead = clone.leading(l.path, n) orelse continue;
                break :blk try std.mem.concat(a, u8, &.{ at, l.path[lead.len..] });
            } else continue;
            if (try s.judge(tree, .{ .at = sub, .line = l, .own = true }, lines, ignore_case) != null) return true;
            try subs.append(a, sub);
        }
        return holdsOutside(a, tree, at, subs.items);
    }

    /// The visited path the temporary `temp` sits beside, when one does.
    fn tempOwner(s: Scope, alloc: std.mem.Allocator, temp: []const u8) !?[]const u8 {
        for (s.visited) |v| {
            if (paths.check(v) == null and std.mem.eql(u8, try paths.tempRel(alloc, v), temp)) return v;
        }
        return null;
    }

    /// Whether the link at `link_path`, with target `raw`, at `rel` is
    /// holt's link of `rel`, or of a kept path equal to `rel` under case
    /// folding and normalization, which a folding filesystem finds under
    /// both spellings.
    fn holtLink(s: Scope, alloc: std.mem.Allocator, link_path: []const u8, raw: []const u8, rel: []const u8) !bool {
        if (link.isHolt(alloc, link_path, raw, s.chain, s.roots, rel)) return true;
        const ks = s.ks orelse return false;
        const want = paths.foldKey(alloc, rel) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        for (try ks.keptSet(alloc)) |k| {
            if (std.mem.eql(u8, k, rel)) continue;
            const kk = paths.foldKey(alloc, k) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            if (std.mem.eql(u8, kk, want) and link.isHolt(alloc, link_path, raw, s.chain, s.roots, k)) return true;
        }
        return false;
    }

    /// Whether the content at `path` is byte-identical to the kept copy of
    /// `rel`, and every executable bit it has is on the kept copy too.
    /// Content that cannot be hashed, online-only content included, is not.
    /// Relinking needs only equal bytes, since a relink whose chmod the kept
    /// copy's filesystem refused still leaves holt's link; until then, an
    /// executable bit the kept copy lacks exists only here.
    pub fn identical(s: Scope, path: []const u8, rel: []const u8) !bool {
        const a = s.ctx.alloc;
        const key = s.key orelse return false;
        if (paths.check(rel) != null) return false;
        if (!try link.parentsReal(a, try s.ctx.layout.keyDir(a, key), rel)) return false;
        const kept = try s.ctx.layout.copyPath(a, key, rel);
        const hl = (try hashOrNull(a, path)) orelse return false;
        const hk = (try hashOrNull(a, kept)) orelse return false;
        if (hl.kind != hk.kind or !std.mem.eql(u8, &hl.hex, &hk.hex)) return false;
        return content.executableCarried(a, path, kept);
    }
};

const Line = struct { path: []const u8, temp: bool, fold: []const u8, new: bool = false };

/// Block lines: the paths and temporaries they name, and lines kept
/// verbatim.
pub const Lines = struct {
    rels: []const []const u8 = &.{},
    temps: []const []const u8 = &.{},
    foreign: []const []const u8 = &.{},
};

/// A place judged as one: `at` in the working tree, under the block line
/// `line` (null for a place under no line of `rels` or `temps`); `own` when
/// it is the line's own path rather than a place git listed.
/// `above` when it is a directory git listed whole that lies above lines.
const Unit = struct { at: []const u8, line: ?Line, own: bool = false, above: bool = false };

/// Whether the directory `at` of `tree` holds anything but empty
/// directories outside the places `skip` (`at`-prefixed, `/`-joined). An
/// entry that cannot be read counts as held.
fn holdsOutside(alloc: std.mem.Allocator, tree: []const u8, at: []const u8, skip: []const []const u8) !bool {
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(alloc, at);
    while (pending.pop()) |here| {
        var dir = std.Io.Dir.cwd().openDir(fsutil.io(), try fsutil.joinSlashy(alloc, tree, here), .{ .iterate = true }) catch return true;
        defer dir.close(fsutil.io());
        var it = dir.iterate();
        while (it.next(fsutil.io()) catch return true) |e| {
            const rel = try std.mem.concat(alloc, u8, &.{ here, "/", e.name });
            if (paths.contains(skip, rel)) continue;
            if (e.kind != .directory) return true;
            for (skip) |sk| {
                if (below(sk, rel)) break;
            } else {
                if (try content.holdsAnything(alloc, try fsutil.joinSlashy(alloc, tree, rel))) return true;
                continue;
            }
            try pending.append(alloc, rel);
        }
    }
    return false;
}

/// Whether a component of `rel` in `tree` is a `.git` as git's walk finds
/// one: a name the walk skips as `.git` under `core.ignorecase`
/// (`ignore_case`, `paths.isWalkDotGit`), or the entry the filesystem finds
/// at `.git` in its directory under another spelling
/// (`content.knownSameFile`). Any other name is content git lists.
fn dotGitComponent(alloc: std.mem.Allocator, tree: []const u8, rel: []const u8, ignore_case: bool) !bool {
    var start: usize = 0;
    while (start <= rel.len) {
        const end = std.mem.indexOfScalarPos(u8, rel, start, '/') orelse rel.len;
        const comp = rel[start..end];
        if (paths.isWalkDotGit(comp, ignore_case)) return true;
        const parent = if (start == 0) tree else try fsutil.joinSlashy(alloc, tree, rel[0 .. start - 1]);
        const same = content.knownSameFile(alloc, try std.fs.path.join(alloc, &.{ parent, comp }), try std.fs.path.join(alloc, &.{ parent, ".git" })) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => false,
        };
        if (same) return true;
        start = end + 1;
    }
    return false;
}

/// Whether a unit of `units` already names the line `l`'s own path in
/// `tree`: byte for byte, or as a place grouped under `l` that is the same
/// file.
fn covered(alloc: std.mem.Allocator, tree: []const u8, units: []const Unit, l: Line) !bool {
    for (units) |u| {
        if (std.mem.eql(u8, u.at, l.path)) return true;
        const ul = u.line orelse continue;
        if (!std.mem.eql(u8, ul.path, l.path)) continue;
        const same = content.sameFile(alloc, try fsutil.joinSlashy(alloc, tree, u.at), try fsutil.joinSlashy(alloc, tree, l.path)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => false,
        };
        if (same) return true;
    }
    return false;
}

/// Where a file git reads goes when the clone's own state directory cannot
/// take it: `scratch` in holt's machine-local state directory, or the run's
/// own directory for a command that only reports (`Ctx.scratch`).
pub fn scratchDir(alloc: std.mem.Allocator, ctx: Ctx) ![]const u8 {
    if (ctx.scratch) |s| return s.dir;
    return std.fs.path.join(alloc, &.{ try machine.stateDir(alloc, ctx.env), "scratch" });
}

/// The real path of every working tree of `c`; none when they cannot be
/// read.
fn realTrees(alloc: std.mem.Allocator, c: clone.Clone) ![]const []const u8 {
    const trees = clone.worktrees(alloc, c) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (trees) |t| if (t.problem == null) try out.append(alloc, try fsutil.realPathOrSelf(alloc, t.path));
    return out.items;
}

fn foldOrSelf(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    return paths.foldKey(alloc, s) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => s,
    };
}

fn below(child: []const u8, parent: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

/// The unit a place git lists as hidden, `p`, belongs to: the outermost
/// line it is at or below, byte for byte, else under case folding and
/// normalization (as git's `core.ignorecase` matches), spelled as `p`
/// spells the line's components; for a directory above lines, null when
/// `listed` also has a place below it, and otherwise `p` itself as a
/// directory above lines (a pattern hides it whole, so git lists nothing
/// below it); otherwise `p` itself.
fn group(alloc: std.mem.Allocator, lines: []const Line, listed: []const []const u8, p: []const u8) !?Unit {
    var best: ?Unit = null;
    for (lines) |l| {
        if (!std.mem.eql(u8, l.path, p) and !below(p, l.path)) continue;
        if (best == null or l.path.len < best.?.at.len) best = .{ .at = l.path, .line = l };
    }
    if (best) |b| return b;
    const pf = try foldOrSelf(alloc, p);
    var best_n: usize = std.math.maxInt(usize);
    for (lines) |l| {
        const n = std.mem.count(u8, l.path, "/") + 1;
        const lead = clone.leading(p, n) orelse continue;
        if (!std.mem.eql(u8, try foldOrSelf(alloc, lead), l.fold)) continue;
        if (n < best_n) {
            best_n = n;
            best = .{ .at = lead, .line = l };
        }
    }
    if (best) |b| return b;
    for (lines) |l| {
        if (!below(l.path, p) and !below(l.fold, pf)) continue;
        for (listed) |q| {
            if (below(q, p) or below(try foldOrSelf(alloc, q), pf)) return null;
        }
        return .{ .at = p, .line = null, .above = true };
    }
    return .{ .at = p, .line = null };
}

fn hashOrNull(alloc: std.mem.Allocator, path: []const u8) !?content.Hash {
    return content.hashPath(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}

pub fn sortedUnique(alloc: std.mem.Allocator, lists: []const []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lists) |l| try out.appendSlice(alloc, l);
    std.mem.sort([]const u8, out.items, {}, paths.lessThan);
    var n: usize = 0;
    for (out.items, 0..) |s, i| {
        if (i > 0 and std.mem.eql(u8, out.items[n - 1], s)) continue;
        out.items[n] = s;
        n += 1;
    }
    return out.items[0..n];
}

const testing = std.testing;

test "group: a place goes to the outermost line it is at or below, by bytes, then as git folds names; a directory above lines is dropped only when git listed something below it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    for ([_][]const u8{ "Dir", "Dir/inner", "config.json", "a/b/.env" }) |l| try lines.append(a, .{ .path = l, .temp = false, .fold = try foldOrSelf(a, l) });

    const listed = [_][]const u8{ "a/b", "a/b/.env" };
    try testing.expectEqualStrings("Dir", (try group(a, lines.items, &listed, "Dir/inner/x")).?.at);
    const folded = (try group(a, lines.items, &listed, "dir/new.md")).?;
    try testing.expectEqualStrings("dir", folded.at);
    try testing.expectEqualStrings("Dir", folded.line.?.path);
    try testing.expectEqualStrings("Config.json", (try group(a, lines.items, &listed, "Config.json")).?.at);
    try testing.expect((try group(a, lines.items, &listed, "a/b")) == null);
    try testing.expect((try group(a, lines.items, &listed, "A")) == null);
    const loose = (try group(a, lines.items, &listed, "elsewhere")).?;
    try testing.expectEqualStrings("elsewhere", loose.at);
    try testing.expect(loose.line == null and !loose.above);
    const whole = (try group(a, lines.items, &.{"a/b"}, "a/b")).?;
    try testing.expectEqualStrings("a/b", whole.at);
    try testing.expect(whole.line == null and whole.above);
}
