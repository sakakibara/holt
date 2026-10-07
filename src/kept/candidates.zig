//! Candidates: what git does not carry in a working tree that holt thinks
//! may exist only there. git lists the ignored paths of the working tree
//! and of each initialized submodule; what the block hides that holt holds
//! nowhere else stays; holt's own links, content identical to its kept
//! copy, directories holding only directories that hold nothing, and what
//! the skip patterns name drop out; nested repositories are reported
//! beside them; and auto-keep keeps what the auto patterns name.

const std = @import("std");
const builtin = @import("builtin");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const clone = @import("clone.zig");
const link = @import("link.zig");
const place = @import("place.zig");
const sweep = @import("sweep.zig");
const reconcile = @import("reconcile.zig");
const patterns = @import("patterns.zig");
const ctx_mod = @import("ctx.zig");

const io = fsutil.io;
const Ctx = ctx_mod.Ctx;

/// The most an auto pattern keeps without asking, per path.
pub const auto_max_bytes: u64 = 10 * 1024 * 1024;

pub const Options = struct {
    /// Keep each ignored path outside a submodule that an auto pattern
    /// matches (`sync`, bare `restore`, `--review`, and the deleters).
    auto: bool = false,
    /// Without `auto`, find what it would keep, keeping nothing: each such
    /// path is in `Listing.would_auto`, not among the candidates (`sync
    /// --dry-run`).
    auto_plan: bool = false,
    /// Set, when a pattern list file is too large to read
    /// (`MatcherFailed`), to its path.
    list_too_large: ?*[]const u8 = null,
    /// The clone's and the key's locks, when the caller already holds them
    /// (a deleter that auto-keeps before deleting, `ctx.Held.of`); auto-keep
    /// then takes neither, and refuses each path with `LocksNotHeld` when
    /// their lock files are not this clone's and key's
    /// (`place.KeepOptions.held`).
    held: ?ctx_mod.Held = null,
    /// Also walk the whole working tree, links not followed, for every
    /// nested repository that is not a working tree's own `.git`
    /// (`Nested.walked`): git lists nothing there, so a broken `.git`, or a
    /// case spelling of it under `core.ignorecase`, would otherwise appear
    /// nowhere. Ignored directories, those the skip patterns match
    /// included, are walked too; the repository's own `.git`, another
    /// working tree of the clone, a nested repository already reported,
    /// and a mount point of another filesystem (`Listing.other_filesystems`)
    /// are not, and a directory the walk cannot look into is a candidate
    /// (`Candidate.walk`). Where `core.ignorecase` is true on a filesystem
    /// that tells cases apart (or that cannot be probed without writing),
    /// what git lists only with it false is a candidate too
    /// (`Candidate.case_hidden`). For the deleters, `doctor --retire`, and
    /// doctor.
    deep_nested: bool = false,
    /// Also list each tracked file marked skip-worktree or assume-unchanged
    /// whose content differs from the index (`Candidate.hidden_tracked_edit`),
    /// in the working tree and each initialized submodule. Wherever
    /// `deep_nested` is set.
    tracked_edits: bool = false,
};

/// A path that may exist only in this working tree.
pub const Candidate = struct {
    /// `/`-joined, relative to the top of the working tree, the
    /// superproject's for a path inside a submodule; `.` for a place of the
    /// working tree itself that the block hides and could not be judged.
    rel: []const u8,
    entry: content.Entry,
    /// The submodule the path is inside, relative to the working tree.
    submodule: ?[]const u8 = null,
    /// For content the block hides that holt holds nowhere else, what the
    /// closing sweep's rule found (`sweep.Found`): such a place stays a
    /// candidate whatever the skip and auto patterns say.
    hidden: ?sweep.Found = null,
    /// For `hidden`, the place is a kept path itself (a fact names it), whose
    /// state reconcile reports: it is one of the kept paths not linked, not
    /// a file not kept (`Listing.notKept`).
    at_kept_path: bool = false,
    /// Why an auto pattern that matches the path did not keep it.
    auto: ?AutoMiss = null,
    /// The path is the directory of a submodule git records that holds
    /// entries but no `.git`: git lists nothing inside it, so all of it may
    /// exist only here. Never matched against the skip patterns nor kept
    /// automatically.
    submodule_uninitialized: bool = false,
    /// The path is a tracked file marked skip-worktree or assume-unchanged
    /// whose content differs from the index: git shows the edit nowhere.
    /// Never matched against the skip patterns nor kept automatically.
    hidden_tracked_edit: bool = false,
    /// The path is one git lists only with `core.ignorecase` false, found
    /// where it is true on a filesystem that tells cases apart: git takes
    /// it for a tracked or listed path of another case, so it shows it
    /// nowhere. Never matched against the skip patterns nor kept
    /// automatically.
    case_hidden: bool = false,
    /// The path is a file git reads only as a regular file, never through
    /// a link (`paths.keepable`), so keep refuses it. Matched against the
    /// skip patterns like any candidate, but never kept automatically.
    git_reads_unlinked: bool = false,
    /// The path is a directory the walk `Options.deep_nested` asks for did
    /// not look into, so what it holds is unknown. Never matched against
    /// the skip patterns nor kept automatically.
    walk: ?WalkMiss = null,
};

/// Why the walk did not look into a directory.
pub const WalkMiss = enum {
    /// It cannot be opened or read.
    unreadable_dir,
    /// It lies `walk_depth_max` levels below the working tree.
    too_deep,
};

pub const AutoMiss = struct {
    /// The auto pattern that matched, as its file spells it.
    pattern: []const u8,
    why: enum {
        /// More than `auto_max_bytes`.
        too_large,
        /// `kept/` is absent: the pattern is the seed's, and nothing is
        /// kept until the store is set up.
        store_absent,
        /// A fact already names the path.
        has_fact,
        /// `unkeep` released the path or a directory above it: the user
        /// gave it up, and only `holt keep` takes it back.
        released,
        /// Sizing or keeping it failed; `detail` is the error.
        failed,
        /// git reads the file only as a regular file, never through a
        /// link (`Candidate.git_reads_unlinked`).
        git_reads_unlinked,
    },
    detail: ?[]const u8 = null,
};

/// A nested repository in a directory git listed.
pub const Nested = struct {
    /// The directory git listed, relative to the working tree.
    listed: []const u8,
    /// The repository: the directory at or below `listed` that is a nested
    /// repository as git's walk decides (`content.isNestedRepo`, under the
    /// working tree's `core.ignorecase`).
    repo: []const u8,
    submodule: ?[]const u8 = null,
    /// Whether git listed it as ignored rather than untracked.
    ignored: bool,
    /// Whether git takes `repo` for a repository of its own (`git
    /// rev-parse` there succeeds without looking above it, whoever owns
    /// it); false for a directory whose `.git` git cannot open, or that
    /// holds only a spelling of `.git` git skips under `core.ignorecase`.
    valid: bool = true,
    /// Found by the walk `Options.deep_nested` asks for, where git lists
    /// nothing: `listed` is then `repo`, and `ignored` false. `.` for the
    /// working tree itself.
    walked: bool = false,
};

/// A path auto-keep kept.
pub const AutoKept = struct {
    rel: []const u8,
    /// The auto pattern that matched, as its file spells it.
    pattern: []const u8,
    outcome: place.KeepOutcome,
};

/// An untracked path git does not ignore that an auto pattern matches: it
/// may be meant for a commit, so it is reported, never kept. `negation`
/// is the negated gitignore line that un-ignores it, past which keeping it
/// cannot hide it (`clone.negation`), when git names one.
pub const AutoUnignored = struct { rel: []const u8, pattern: []const u8, negation: ?clone.Negation = null };

pub const Listing = struct {
    worktree: []const u8,
    /// In path order.
    candidates: []const Candidate = &.{},

    nested: []const Nested = &.{},
    auto_kept: []const AutoKept = &.{},
    /// With `Options.auto_plan`, what auto-keep would keep, in the order it
    /// would.
    would_auto: []const AutoUnignored = &.{},
    /// In path order.
    auto_unignored: []const AutoUnignored = &.{},
    /// Initialized submodules git could not list, relative to the working
    /// tree: what they hold is unknown.
    submodules_failed: []const []const u8 = &.{},
    /// Directories below the working tree on another filesystem than its
    /// own, relative to it, that the walk `Options.deep_nested` asks for
    /// did not enter; information.
    other_filesystems: []const []const u8 = &.{},
    /// Every initialized submodule, at any depth, relative to the working
    /// tree, in path order.
    submodules: []const []const u8 = &.{},
    /// How many of the candidates are files not kept: all but the content
    /// at a kept path (`Candidate.at_kept_path`).
    pub fn notKept(l: Listing) usize {
        var n: usize = 0;
        for (l.candidates) |c| n += @intFromBool(!c.at_kept_path);
        return n;
    }
};

/// The candidates of the working tree containing `path`, with `index` the
/// store's keys as loaded at the start of the command.
///
/// git lists the working tree with `git status --porcelain=v1 -z
/// --ignored=matching --untracked-files=normal`, and each initialized
/// submodule, at any depth, the same way; an ignored directory git listed
/// whole that lies above a kept path or a block line is listed again file
/// by file (`--ignored=traditional --untracked-files=all`). A listing
/// during which git warns that it could not open a directory fails, since
/// what that holds is unlisted. Only ignored entries are candidates, each
/// path once, and the directory of each submodule git records that holds
/// entries but no `.git` (`Candidate.submodule_uninitialized`, never
/// matched against the skip or auto patterns). A listed directory that is a
/// nested repository as git's walk decides (`content.isNestedRepo`, under
/// that working tree's `core.ignorecase`) is reported before skip matching;
/// one holding such a directory deeper is listed again file by file, so
/// what lies beside the nested repository stays a candidate. No path git
/// lists is dropped for its name. A nested repository the block hides is
/// reported the same way. What the block hides that holt holds nowhere
/// else, judged by the closing sweep's rule (`reconcile.unprotected`'s, for
/// this working tree), is a candidate, and everything else at or under a
/// block line (byte for byte, or in any ASCII case where git's
/// `core.ignorecase` is true) or such a place is left to that rule; of the
/// rest, holt's own links and content identical to its kept copy drop out,
/// then whatever the skip patterns (`patterns.globalText`,
/// `patterns.repoSkipText`) match. With `opts.auto`, each remaining ignored
/// path outside a submodule that an auto pattern matches is kept through
/// `place.keepPath` when `kept/` exists, no fact names it, and it holds at
/// most `auto_max_bytes`; otherwise it stays with the reason, as a file git
/// reads only as a regular file (`Candidate.git_reads_unlinked`) always
/// does. A pattern ending in `/` keeps the shallowest directory it matches
/// at or above the path, once for every path git listed below it, unless
/// something below that directory is tracked, or untracked and not ignored,
/// or it holds what keep refuses (`autoUnits`); then each path is kept on
/// its own. Untracked paths git does not ignore that an auto pattern
/// matches, no skip pattern does, and no fact names are listed apart, the
/// files inside untracked directories included (`--untracked-files=all`),
/// those beside a `.git` git cannot open too. With `opts.deep_nested`, what
/// the walk finds (`walkNested`) is reported as nested repositories and
/// unwalked directories, and what `core.ignorecase` hides on a filesystem
/// that tells cases apart as candidates (`caseHidden`); with
/// `opts.tracked_edits`, the edits git hides in tracked files
/// (`trackedEdits`) are candidates, never matched against the skip or auto
/// patterns. Each nested repository says whether git can open it
/// (`Nested.valid`).
///
/// Covers the one working tree containing `path`; `listAll` covers every
/// working tree of a clone. Takes no lock but what auto-keep takes, and
/// none under `opts.held`. `GitTooOld` when git is older
/// than `clone.min_git`; `ListingFailed` when git cannot list the working
/// tree; `MatcherFailed` when the patterns cannot be matched or a list file
/// is too large to read (`opts.list_too_large`).
pub fn list(ctx: Ctx, index: *const store.KeyIndex, path: []const u8, opts: Options) !Listing {
    try clone.requireGit(ctx.alloc);
    return listIn(ctx, index, try clone.inspect(ctx.alloc, path, ctx.code_root), opts);
}

/// `list` for the working tree `c` as `clone.inspect` read it.
fn listIn(ctx: Ctx, index: *const store.KeyIndex, c: clone.Clone, opts: Options) !Listing {
    const a = ctx.alloc;
    const tree = c.worktree;
    const scope = try reconcile.scopeOf(ctx, index, c);

    var cands: std.ArrayList(Candidate) = .empty;
    var nested: std.ArrayList(Nested) = .empty;
    var untracked: std.ArrayList(Listed) = .empty;
    var hidden_count: usize = 0;

    const kept_set: []const []const u8 = if (scope.ks) |ks| try ks.keptSet(a) else &.{};
    const found = try scope.hiddenIn(tree, scope.block_rels, scope.block_temps, scope.block_foreign);
    for (found) |f| {
        if (f.why == .nested_repository) {
            try nested.append(a, .{ .listed = f.rel, .repo = f.rel, .ignored = true });
            continue;
        }
        try cands.append(a, .{ .rel = f.temp orelse f.rel, .entry = f.entry, .hidden = f, .at_kept_path = f.temp == null and paths.contains(kept_set, f.rel) });
        hidden_count += 1;
    }

    const lines = try std.mem.concat(a, []const u8, &.{ scope.block_rels, scope.block_temps });
    const ignore_case = try scope.ignoresCase(tree);
    const above_of = try std.mem.concat(a, []const u8, &.{ kept_set, lines });
    const above_folded = try a.alloc([]const u8, above_of.len);
    for (above_of, above_folded) |r, *f| f.* = try foldOrSelf(a, r);

    var entries: std.ArrayList(Listed) = .empty;
    const first = (try status(a, tree, .first, &.{})) orelse return error.ListingFailed;
    for (first) |e| {
        if (e.ignored and e.dir and try aboveAny(a, e.rel, above_of, above_folded)) {
            try entries.appendSlice(a, (try status(a, tree, .again, &.{e.rel})) orelse return error.ListingFailed);
        } else try entries.append(a, e);
    }
    const trees = try scope.worktreesIn(tree);
    var relisted: std.ArrayList([]const u8) = .empty;
    var beside_nested: std.ArrayList(Listed) = .empty;
    var at: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    while (at < entries.items.len) : (at += 1) {
        const e = entries.items[at];
        if ((try seen.getOrPut(a, e.rel)).found_existing) continue;
        if (underBlock(e.rel, lines, ignore_case, found)) continue;
        if (try expandNested(a, tree, tree, "", null, e, ignore_case, trees, &relisted, &entries, &nested)) |how| {
            if (how == .nested and !e.ignored) try beside_nested.append(a, e);
            continue;
        }
        if (!e.ignored) {
            try untracked.append(a, e);
            continue;
        }
        const entry = entryOf(a, tree, e.rel);
        if (try holtsOwn(scope, tree, e.rel, entry)) continue;
        if (entry == .dir and try holdsNothing(a, try fsutil.joinSlashy(a, tree, e.rel))) continue;
        try cands.append(a, .{ .rel = e.rel, .entry = entry, .git_reads_unlinked = paths.keepable(e.rel) == .git_reads_unlinked });
    }

    var failed: std.ArrayList([]const u8) = .empty;
    const subs = submodules(a, tree, "") catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.ListingFailed,
    };
    var exempt: std.ArrayList(Candidate) = .empty;
    for (subs.uninitialized) |u| {
        try exempt.append(a, .{ .rel = u.rel, .entry = .dir, .submodule = u.submodule, .submodule_uninitialized = true });
    }
    for (subs.ok) |s| {
        const sub_tree = try fsutil.joinSlashy(a, tree, s);
        var listed: std.ArrayList(Listed) = .empty;
        try listed.appendSlice(a, (try status(a, sub_tree, .first, &.{})) orelse {
            try failed.append(a, s);
            continue;
        });
        var sub_relisted: std.ArrayList([]const u8) = .empty;
        const sub_ignore_case = try clone.ignoresCase(a, sub_tree);
        var sub_seen: std.StringHashMapUnmanaged(void) = .empty;
        var j: usize = 0;
        while (j < listed.items.len) : (j += 1) {
            const e = listed.items[j];
            if ((try sub_seen.getOrPut(a, e.rel)).found_existing) continue;
            const rel = try std.mem.concat(a, u8, &.{ s, "/", e.rel });
            const consumed = expandNested(a, tree, sub_tree, s, s, e, sub_ignore_case, trees, &sub_relisted, &listed, &nested) catch |err| switch (err) {
                error.ListingFailed => {
                    try failed.append(a, s);
                    break;
                },
                else => return err,
            };
            if (consumed != null) continue;
            if (!e.ignored) continue;
            const entry = entryOf(a, tree, rel);
            if (entry == .dir and try holdsNothing(a, try fsutil.joinSlashy(a, tree, rel))) continue;
            try cands.append(a, .{ .rel = rel, .entry = entry, .submodule = s, .git_reads_unlinked = paths.keepable(rel) == .git_reads_unlinked });
        }
    }
    try failed.appendSlice(a, subs.failed);

    if (opts.tracked_edits) {
        const dirs = try scope.excludeDirs();
        for ((try trackedEdits(a, tree, dirs, ctx.machine_id)) orelse return error.ListingFailed) |r| {
            try exempt.append(a, .{ .rel = r, .entry = entryOf(a, tree, r), .hidden_tracked_edit = true });
        }
        for (subs.ok) |s| {
            const got = (try trackedEdits(a, try fsutil.joinSlashy(a, tree, s), dirs, ctx.machine_id)) orelse {
                if (!paths.contains(failed.items, s)) try failed.append(a, s);
                continue;
            };
            for (got) |r| {
                const rel = try std.mem.concat(a, u8, &.{ s, "/", r });
                try exempt.append(a, .{ .rel = rel, .entry = entryOf(a, tree, rel), .submodule = s, .hidden_tracked_edit = true });
            }
        }
    }
    var other_filesystems: []const []const u8 = &.{};
    if (opts.deep_nested) {
        const probed = try clone.folding(a, c, false);
        const tells_cases = !probed.fold.case or probed.failure != null;
        if (tells_cases and ignore_case) {
            try caseHidden(a, tree, tree, "", null, found, lines, trees, first, &exempt, &nested);
        }
        for (subs.ok) |s| {
            if (!tells_cases) break;
            const sub_tree = try fsutil.joinSlashy(a, tree, s);
            if (!try clone.ignoresCase(a, sub_tree)) continue;
            const sub_first = (try status(a, sub_tree, .first, &.{})) orelse {
                if (!paths.contains(failed.items, s)) try failed.append(a, s);
                continue;
            };
            caseHidden(a, tree, sub_tree, s, s, &.{}, &.{}, trees, sub_first, &exempt, &nested) catch |err| switch (err) {
                error.ListingFailed => if (!paths.contains(failed.items, s)) try failed.append(a, s),
                else => return err,
            };
        }
        var known: std.ArrayList([]const u8) = .empty;
        for (nested.items) |n| try known.append(a, n.repo);
        const walked = try walkNested(a, tree, ignore_case, subs.ok, trees, known.items);
        try nested.appendSlice(a, walked.nested);
        try exempt.appendSlice(a, walked.unwalked);
        other_filesystems = walked.other_filesystems;
    }
    for (nested.items) |*n| {
        if (!n.walked) n.valid = try isRepo(a, try fsutil.joinSlashy(a, tree, n.repo));
    }

    const auto_text = try patterns.globalText(a, ctx.layout, .auto, opts.list_too_large);
    if (patterns.hasPattern(auto_text)) {
        try untracked.appendSlice(a, try untrackedFiles(a, tree, untracked.items));
        try untracked.appendSlice(a, try untrackedFiles(a, tree, beside_nested.items));
    }

    const skip_text = if (scope.key) |k|
        try std.mem.concat(a, u8, &.{ try patterns.globalText(a, ctx.layout, .skip, opts.list_too_large), try patterns.repoSkipText(a, ctx.layout, k, opts.list_too_large) })
    else
        try patterns.globalText(a, ctx.layout, .skip, opts.list_too_large);
    const judged = cands.items[hidden_count..];
    var queries: std.ArrayList(patterns.Query) = .empty;
    for (judged) |cand| try queries.append(a, .{ .path = cand.rel, .dir = cand.entry == .dir });
    for (untracked.items) |u| try queries.append(a, .{ .path = u.rel, .dir = u.dir });
    const skipped = try patterns.match(ctx, skip_text, queries.items);

    var kept_cands: std.ArrayList(Candidate) = .empty;
    try kept_cands.appendSlice(a, cands.items[0..hidden_count]);
    var auto_q: std.ArrayList(patterns.Query) = .empty;
    var auto_at: std.ArrayList(usize) = .empty;
    var unlinked_at: std.ArrayList(usize) = .empty;
    for (judged, skipped[0..judged.len]) |cand, sk| {
        if (sk != null) continue;
        if ((opts.auto or opts.auto_plan) and cand.submodule == null) {
            if (cand.git_reads_unlinked) {
                try unlinked_at.append(a, kept_cands.items.len);
            } else {
                try auto_q.append(a, .{ .path = cand.rel, .dir = cand.entry == .dir });
                try auto_at.append(a, kept_cands.items.len);
            }
        }
        try kept_cands.append(a, cand);
    }
    try kept_cands.appendSlice(a, exempt.items);
    const auto_candidates = auto_q.items.len;
    var unignored_at: std.ArrayList(Listed) = .empty;
    for (untracked.items, skipped[judged.len..]) |u, sk| {
        if (sk != null) continue;
        try auto_q.append(a, .{ .path = u.rel, .dir = u.dir });
        try unignored_at.append(a, u);
    }
    const unignored_end = auto_q.items.len;
    for (unlinked_at.items) |i| try auto_q.append(a, .{ .path = kept_cands.items[i].rel, .dir = kept_cands.items[i].entry == .dir });
    const auto_hits = try patterns.match(ctx, auto_text, auto_q.items);
    const unignored_hits = auto_hits[auto_candidates..unignored_end];
    for (unlinked_at.items, auto_hits[unignored_end..]) |i, hit| {
        if (hit) |p| kept_cands.items[i].auto = .{ .pattern = p, .why = .git_reads_unlinked };
    }

    var unignored: std.ArrayList(AutoUnignored) = .empty;
    var unignored_dirs: std.ArrayList([]const u8) = .empty;
    for (unignored_at.items, unignored_hits) |u, hit| {
        if (hit != null and u.dir) try unignored_dirs.append(a, u.rel);
    }
    for (unignored_at.items, unignored_hits) |u, hit| {
        const p = hit orelse continue;
        if (!u.dir and underAny(u.rel, unignored_dirs.items)) continue;
        if (paths.contains(kept_set, u.rel)) continue;
        if (paths.keepable(u.rel) == .git_reads_unlinked) continue;
        const neg = clone.negation(a, c, u.rel) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        try unignored.append(a, .{ .rel = u.rel, .pattern = p, .negation = neg });
    }
    std.mem.sort(AutoUnignored, unignored.items, {}, struct {
        fn less(_: void, x: AutoUnignored, y: AutoUnignored) bool {
            return paths.lessThan({}, x.rel, y.rel);
        }
    }.less);

    var auto_kept: std.ArrayList(AutoKept) = .empty;
    var would_auto: std.ArrayList(AutoUnignored) = .empty;
    const drop = try a.alloc(bool, kept_cands.items.len);
    @memset(drop, false);
    const store_here = try content.entryAt(try ctx.layout.keptDir(a)) == .dir;
    const hits = auto_hits[0..auto_candidates];
    const units = try autoUnits(ctx, tree, ignore_case, auto_text, skip_text, .{ .rels = above_of, .folded = above_folded }, kept_cands.items, auto_at.items, hits);
    var kept_dirs: std.ArrayList([]const u8) = .empty;
    for (units) |u| {
        const refusal = autoRefusal(ctx, scope, tree, u.rel, u.pattern, store_here) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => AutoMiss{ .pattern = u.pattern, .why = .failed, .detail = @errorName(err) },
        };
        const miss: ?AutoMiss = refusal orelse blk: {
            if (!opts.auto) {
                try would_auto.append(a, .{ .rel = u.rel, .pattern = u.pattern });
                if (u.whole) try kept_dirs.append(a, u.rel);
                break :blk null;
            }
            const outcome = place.keepPath(ctx, index, tree, u.rel, .{ .held = opts.held }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => break :blk AutoMiss{ .pattern = u.pattern, .why = .failed, .detail = @errorName(err) },
            };
            try auto_kept.append(a, .{ .rel = u.rel, .pattern = u.pattern, .outcome = outcome });
            if (u.whole) try kept_dirs.append(a, u.rel);
            break :blk null;
        };
        for (u.members) |i| {
            if (miss) |m| kept_cands.items[i].auto = m else drop[i] = true;
        }
    }
    for (kept_cands.items[hidden_count..], drop[hidden_count..]) |cand, *d| {
        if (underAny(cand.rel, kept_dirs.items)) d.* = true;
    }

    var out: std.ArrayList(Candidate) = .empty;
    for (kept_cands.items, drop) |cand, d| if (!d) try out.append(a, cand);
    std.mem.sort(Candidate, out.items, {}, struct {
        fn less(_: void, x: Candidate, y: Candidate) bool {
            return paths.lessThan({}, x.rel, y.rel);
        }
    }.less);
    return .{
        .worktree = tree,
        .candidates = out.items,
        .nested = nested.items,
        .auto_kept = auto_kept.items,
        .would_auto = would_auto.items,
        .auto_unignored = unignored.items,
        .submodules_failed = failed.items,
        .other_filesystems = other_filesystems,
        .submodules = subs.ok,
    };
}

/// What auto-keep keeps as one: `rel`, for the candidates at `members`
/// (indexes of the candidates), which the auto pattern `pattern` matched.
/// `whole` for a directory kept for candidates git listed below it.
const AutoUnit = struct { rel: []const u8, pattern: []const u8, members: []const usize, whole: bool = false };

/// The units auto-keep keeps for the candidates at `at` (indexes into
/// `cands`) that the auto patterns `auto_text` matched (`hits`, in order).
/// A candidate a pattern ending in `/` matched is kept with the shallowest
/// directory at or above it that the same pattern matches as a directory,
/// once for every candidate below it, unless something below that
/// directory is tracked, or untracked and not ignored, since keep would
/// hide it or refuse the directory; unless the directory is at or above a
/// member of `above` (a kept path, a block line, or a temporary), which
/// keep refuses to hold inside a directory it keeps; unless it holds a
/// nested repository or a name keep refuses (`holdsUnkeepable`, under the
/// working tree's `core.ignorecase`, `ignore_case`); and unless the skip
/// patterns `skip_text` match anything below it, since skip wins. Each
/// other candidate is its own unit. Directory units come first.
fn autoUnits(ctx: Ctx, tree: []const u8, ignore_case: bool, auto_text: []const u8, skip_text: []const u8, above: Above, cands: []const Candidate, at: []const usize, hits: []const ?[]const u8) ![]const AutoUnit {
    const a = ctx.alloc;
    var asks: std.ArrayList(patterns.Query) = .empty;
    var asked_for: std.ArrayList(usize) = .empty;
    for (at, hits, 0..) |i, hit, k| {
        const p = hit orelse continue;
        if (!std.mem.endsWith(u8, p, "/")) continue;
        const rel = cands[i].rel;
        var n: usize = 1;
        while (clone.leading(rel, n)) |lead| : (n += 1) {
            if (lead.len == rel.len and cands[i].entry != .dir) break;
            try asks.append(a, .{ .path = lead, .dir = true });
            try asked_for.append(a, k);
            if (lead.len == rel.len) break;
        }
    }
    const answers = try patterns.match(ctx, auto_text, asks.items);

    var dirs: std.ArrayList(AutoUnit) = .empty;
    var members: std.ArrayList(std.ArrayList(usize)) = .empty;
    const grouped = try a.alloc(bool, at.len);
    @memset(grouped, false);
    var q: usize = 0;
    while (q < asks.items.len) {
        const k = asked_for.items[q];
        const p = hits[k].?;
        var dir: ?[]const u8 = null;
        while (q < asks.items.len and asked_for.items[q] == k) : (q += 1) {
            if (dir == null) if (answers[q]) |ans| if (std.mem.eql(u8, ans, p)) {
                dir = asks.items[q].path;
            };
        }
        const d = dir orelse continue;
        for (dirs.items, members.items) |u, *ms| {
            if (std.mem.eql(u8, u.rel, d)) {
                try ms.append(a, at[k]);
                break;
            }
        } else {
            try dirs.append(a, .{ .rel = d, .pattern = p, .members = &.{}, .whole = !std.mem.eql(u8, d, cands[at[k]].rel) });
            var ms: std.ArrayList(usize) = .empty;
            try ms.append(a, at[k]);
            try members.append(a, ms);
        }
        grouped[k] = true;
    }

    var whole: std.ArrayList([]const u8) = .empty;
    for (dirs.items) |u| if (u.whole) try whole.append(a, u.rel);
    const skip_below = try skipsBelow(ctx, tree, skip_text, whole.items);
    var out: std.ArrayList(AutoUnit) = .empty;
    var w: usize = 0;
    for (dirs.items, members.items) |u, ms| {
        const apart = u.whole and (skip_below[w] or try atOrAbove(a, u.rel, above) or try holdsVisible(a, tree, u.rel) or try holdsUnkeepable(a, tree, u.rel, ignore_case));
        if (u.whole) w += 1;
        if (apart) {
            for (ms.items) |i| {
                const k = std.mem.indexOfScalar(usize, at, i).?;
                grouped[k] = false;
            }
            continue;
        }
        var unit = u;
        unit.members = ms.items;
        try out.append(a, unit);
    }
    for (at, hits, grouped) |i, hit, g| {
        const p = hit orelse continue;
        if (g) continue;
        try out.append(a, .{ .rel = cands[i].rel, .pattern = p, .members = try a.dupe(usize, &.{i}) });
    }
    return out.items;
}

/// Paths, with each one's `paths.foldKey` beside it.
const Above = struct { rels: []const []const u8, folded: []const []const u8 };

/// Whether the directory `rel` is a member of `above`, or lies above one,
/// byte for byte or under case folding and normalization.
fn atOrAbove(alloc: std.mem.Allocator, rel: []const u8, above: Above) !bool {
    if (paths.contains(above.rels, rel)) return true;
    const rf = try foldOrSelf(alloc, rel);
    if (paths.contains(above.folded, rf)) return true;
    return aboveAny(alloc, rel, above.rels, above.folded);
}

/// For each directory of `dirs` in `tree`, whether the skip patterns
/// `skip_text` match any entry below it, links not followed and not looked
/// into. A directory that cannot be read counts as matched.
fn skipsBelow(ctx: Ctx, tree: []const u8, skip_text: []const u8, dirs: []const []const u8) ![]const bool {
    const a = ctx.alloc;
    const out = try a.alloc(bool, dirs.len);
    @memset(out, false);
    if (dirs.len == 0 or !patterns.hasPattern(skip_text)) return out;
    var queries: std.ArrayList(patterns.Query) = .empty;
    var owner: std.ArrayList(usize) = .empty;
    for (dirs, 0..) |d, i| {
        var pending: std.ArrayList([]const u8) = .empty;
        try pending.append(a, d);
        while (pending.pop()) |here| {
            var dir = std.Io.Dir.cwd().openDir(io(), try fsutil.joinSlashy(a, tree, here), .{ .iterate = true }) catch {
                out[i] = true;
                break;
            };
            defer dir.close(io());
            var it = dir.iterate();
            while (it.next(io()) catch blk: {
                out[i] = true;
                break :blk null;
            }) |e| {
                const rel = try std.mem.concat(a, u8, &.{ here, "/", e.name });
                const kind = if (e.kind == .unknown) (dir.statFile(io(), e.name, .{ .follow_symlinks = false }) catch {
                    out[i] = true;
                    continue;
                }).kind else e.kind;
                try queries.append(a, .{ .path = rel, .dir = kind == .directory });
                try owner.append(a, i);
                if (kind == .directory) try pending.append(a, rel);
            }
        }
    }
    const got = try patterns.match(ctx, skip_text, queries.items);
    for (got, owner.items) |hit, i| if (hit != null) {
        out[i] = true;
    };
    return out;
}

/// Whether the directory `rel` of `tree` holds what keep refuses inside a
/// directory it keeps: a nested repository (`content.nestedRepos`, under
/// `ignore_case`), or a name a kept path may not hold
/// (`content.invalidNames`: a `.holt-` name, a name any filesystem treats
/// as `.git`, a name equal to a sibling's under folding, and the like).
/// True when it cannot be read.
fn holdsUnkeepable(a: std.mem.Allocator, tree: []const u8, rel: []const u8, ignore_case: bool) !bool {
    const dir = try fsutil.joinSlashy(a, tree, rel);
    const bad = content.invalidNames(a, dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return true,
    };
    if (bad.len > 0) return true;
    return (try content.nestedRepos(a, dir, ignore_case, 1)).len > 0;
}

/// Whether git tracks something at or below the directory `rel` of `tree`,
/// or lists something below it as untracked and not ignored; true when git
/// cannot say.
fn holdsVisible(a: std.mem.Allocator, tree: []const u8, rel: []const u8) !bool {
    const how = clone.tracked(a, tree, &.{rel}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return true,
    };
    if (how[0] != .none) return true;
    const res = try git.runInRepoScoped(a, &.{ "--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--", rel }, tree);
    return res.status != 0 or res.stdout.len > 0;
}

/// The untracked files git lists below each directory of `listed` (entries
/// git listed as untracked), for matching against the auto patterns; none
/// when git fails.
fn untrackedFiles(a: std.mem.Allocator, tree: []const u8, listed: []const Listed) ![]const Listed {
    var dirs: std.ArrayList([]const u8) = .empty;
    for (listed) |u| if (u.dir) try dirs.append(a, u.rel);
    if (dirs.items.len == 0) return &.{};
    var out: std.ArrayList(Listed) = .empty;
    for ((try status(a, tree, .untracked, dirs.items)) orelse return &.{}) |e| {
        if (!e.dir and !e.ignored) try out.append(a, e);
    }
    return out.items;
}

fn underAny(rel: []const u8, dirs: []const []const u8) bool {
    for (dirs) |d| if (std.mem.eql(u8, rel, d) or below(rel, d)) return true;
    return false;
}

/// A working tree of the clone that `listAll` could not list.
pub const Unlisted = struct {
    worktree: []const u8,
    /// Why git's record of it cannot be swept, when that is why.
    problem: ?clone.TreeProblem = null,
    /// Otherwise, the error listing it failed with.
    detail: ?[]const u8 = null,
};

pub const AllListing = struct {
    /// One per working tree listed, in `clone.worktrees` order.
    listings: []const Listing = &.{},
    unlisted: []const Unlisted = &.{},
};

/// `list` for every working tree of the clone `c` (`clone.worktrees`),
/// with the same options, so a caller covering a clone cannot leave a
/// working tree out: a working tree whose record cannot be swept, that git
/// cannot list (`ListingFailed`, `NotAClone`), or where git finds another
/// clone than `c` (`clone.TreeProblem.foreign_repository`) is reported in
/// `unlisted` and the others are still listed. `WorktreeListFailed` when
/// the working trees cannot be read; otherwise the errors of `list`.
pub fn listAll(ctx: Ctx, index: *const store.KeyIndex, c: clone.Clone, opts: Options) !AllListing {
    const a = ctx.alloc;
    try clone.requireGit(a);
    const trees = clone.worktrees(a, c) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.WorktreeListFailed,
    };
    var listings: std.ArrayList(Listing) = .empty;
    var unlisted: std.ArrayList(Unlisted) = .empty;
    for (trees) |t| {
        if (t.problem) |p| {
            try unlisted.append(a, .{ .worktree = t.path, .problem = p });
            continue;
        }
        const own = std.mem.eql(u8, t.path, c.worktree);
        const here = if (own) c else clone.inspect(a, t.path, ctx.code_root) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try unlisted.append(a, .{ .worktree = t.path, .detail = @errorName(err) });
                continue;
            },
        };
        if (!std.mem.eql(u8, here.common_dir, c.common_dir)) {
            try unlisted.append(a, .{ .worktree = t.path, .problem = .foreign_repository });
            continue;
        }
        const got = listIn(ctx, index, here, opts) catch |err| switch (err) {
            error.ListingFailed, error.NotAClone => {
                try unlisted.append(a, .{ .worktree = t.path, .detail = @errorName(err) });
                continue;
            },
            else => return err,
        };
        try listings.append(a, got);
    }
    return .{ .listings = listings.items, .unlisted = unlisted.items };
}

/// Why the auto pattern `pattern`'s match `rel` of `tree` must not be
/// kept, or null when it may.
fn autoRefusal(ctx: Ctx, scope: sweep.Scope, tree: []const u8, rel: []const u8, pattern: []const u8, store_here: bool) !?AutoMiss {
    if (!store_here) return .{ .pattern = pattern, .why = .store_absent };
    if (scope.ks) |ks| {
        if (ks.factsFor(rel).len > 0) return .{ .pattern = pattern, .why = .has_fact };
        var end: usize = rel.len;
        while (true) {
            if (ks.isReleased(rel[0..end])) return .{ .pattern = pattern, .why = .released };
            end = std.mem.lastIndexOfScalar(u8, rel[0..end], '/') orelse break;
        }
    }
    if (try sizeOver(ctx.alloc, try fsutil.joinSlashy(ctx.alloc, tree, rel), auto_max_bytes)) return .{ .pattern = pattern, .why = .too_large };
    return null;
}

/// One entry of `git status --porcelain=v1`: its path, `/`-joined without
/// a trailing `/`, whether git listed it as a directory, and whether as
/// ignored (`!!`) rather than untracked (`??`).
/// With `from`, the directory git first listed whole that it lies in,
/// when it was listed again.
const Listed = struct { rel: []const u8, dir: bool, ignored: bool, from: ?[]const u8 = null };

/// How `status` asks git.
const Pass = enum {
    /// `--ignored=matching --untracked-files=normal`: the whole working
    /// tree, a directory whose content git treats alike listed whole.
    first,
    /// `--ignored=traditional --untracked-files=all` under the given
    /// directories: each file on its own.
    again,
    /// `--untracked-files=all` under the given directories: each untracked
    /// file on its own, nothing ignored.
    untracked,
};

/// The ignored and untracked entries git lists in the working tree at
/// `tree` as `pass` asks, under `dirs` (taken literally) for the passes
/// that name them; null when git fails, or when it warns that it could not
/// open a directory, since what that holds is then unlisted.
fn status(alloc: std.mem.Allocator, tree: []const u8, pass: Pass, dirs: []const []const u8) !?[]const Listed {
    return statusWith(alloc, tree, pass, dirs, &.{});
}

/// `status`, with `config` (`-c` and its value, in pairs) before the
/// command.
fn statusWith(alloc: std.mem.Allocator, tree: []const u8, pass: Pass, dirs: []const []const u8, config: []const []const u8) !?[]const Listed {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(alloc, config);
    try args.appendSlice(alloc, switch (pass) {
        .first => &.{ "--no-optional-locks", "status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=normal" },
        .again => &.{ "--no-optional-locks", "--literal-pathspecs", "status", "--porcelain=v1", "-z", "--ignored=traditional", "--untracked-files=all", "--" },
        .untracked => &.{ "--no-optional-locks", "--literal-pathspecs", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--" },
    });
    if (pass != .first) try args.appendSlice(alloc, dirs);
    const res = try git.runInRepoScopedWith(alloc, args.items, tree, .{ .set = &.{ .{ "LC_ALL", "C" }, .{ "LANGUAGE", "C" } } });
    if (res.status != 0 or std.mem.indexOf(u8, res.stderr, "could not open directory") != null) return null;
    var out: std.ArrayList(Listed) = .empty;
    var it = std.mem.splitScalar(u8, res.stdout, 0);
    while (it.next()) |rec| {
        if (rec.len < 4) continue;
        const xy = rec[0..2];
        if (xy[0] == 'R' or xy[0] == 'C') {
            _ = it.next();
            continue;
        }
        const ignored = std.mem.eql(u8, xy, "!!");
        if (!ignored and !std.mem.eql(u8, xy, "??")) continue;
        const p = rec[3..];
        const rel = std.mem.trimEnd(u8, p, "/");
        if (rel.len == 0) continue;
        try out.append(alloc, .{ .rel = rel, .dir = rel.len != p.len, .ignored = ignored });
    }
    return out.items;
}

/// Adds to `out` what git lists in the working tree at `git_tree` (`tree`
/// itself, or its submodule `prefix`, which `submodule` names) once
/// `core.ignorecase` is false (`-c core.ignorecase=false`) beyond what its
/// listing under the user's configuration, `listed`, holds or lies below:
/// each a `case_hidden` candidate, and a directory that is or holds a
/// nested repository (`content.nestedRepos`, names compared byte for byte)
/// reported in `nested` as well, the directory staying a candidate unless
/// it is one itself. What lies at or under a line of `lines` or a place of
/// `found` is left to the closing sweep's rule, and another working tree of
/// the clone (`trees`) is listed on its own. `ListingFailed` when git
/// cannot make the listing.
fn caseHidden(
    a: std.mem.Allocator,
    tree: []const u8,
    git_tree: []const u8,
    prefix: []const u8,
    submodule: ?[]const u8,
    found: []const sweep.Found,
    lines: []const []const u8,
    trees: []const []const u8,
    listed: []const Listed,
    out: *std.ArrayList(Candidate),
    nested: *std.ArrayList(Nested),
) !void {
    const again = (try statusWith(a, git_tree, .first, &.{}, &.{ "-c", "core.ignorecase=false" })) orelse return error.ListingFailed;
    for (again) |e| {
        const seen = for (listed) |l| {
            if (std.mem.eql(u8, l.rel, e.rel) or (l.dir and below(e.rel, l.rel))) break true;
        } else false;
        if (seen) continue;
        const rel = if (prefix.len == 0) e.rel else try std.mem.concat(a, u8, &.{ prefix, "/", e.rel });
        if (underBlock(rel, lines, false, found) or paths.contains(trees, rel)) continue;
        if (e.dir) {
            const repos = try content.nestedRepos(a, try fsutil.joinSlashy(a, tree, rel), false, std.math.maxInt(usize));
            for (repos) |r| {
                const at = if (r.len == 0) rel else try std.mem.concat(a, u8, &.{ rel, "/", r });
                if (!paths.contains(trees, at)) try nested.append(a, .{ .listed = rel, .repo = at, .submodule = submodule, .ignored = e.ignored });
            }
            if (repos.len > 0 and repos[0].len == 0) continue;
        }
        try out.append(a, .{ .rel = rel, .entry = entryOf(a, tree, rel), .submodule = submodule, .case_hidden = true });
    }
}

/// A submodule git records whose directory holds entries but no `.git`
/// (never initialized, or deinitialized): git lists nothing inside it.
const Uninitialized = struct {
    /// Relative to the working tree.
    rel: []const u8,
    /// The initialized submodule it is recorded in, or null for the
    /// working tree itself.
    submodule: ?[]const u8,
};

/// The initialized submodules of the working tree at `root`, at any depth,
/// each relative to `root` (`prefix` names the working tree being read);
/// `failed` those whose own submodules git could not list; `uninitialized`
/// those recorded whose directory holds entries but no `.git`. An error
/// when git cannot list the working tree at `root` itself.
fn submodules(alloc: std.mem.Allocator, root: []const u8, prefix: []const u8) !struct { ok: []const []const u8, failed: []const []const u8, uninitialized: []const Uninitialized } {
    var ok: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList([]const u8) = .empty;
    var uninit: std.ArrayList(Uninitialized) = .empty;
    var todo: std.ArrayList([]const u8) = .empty;
    try todo.append(alloc, prefix);
    var first = true;
    while (todo.pop()) |here| {
        const res = try git.runInRepoScoped(alloc, &.{ "ls-files", "--stage", "-z" }, if (here.len == 0) root else try fsutil.joinSlashy(alloc, root, here));
        if (res.status != 0) {
            if (first) return error.GitFailed;
            try failed.append(alloc, here);
            continue;
        }
        first = false;
        var it = std.mem.splitScalar(u8, res.stdout, 0);
        while (it.next()) |rec| {
            if (!std.mem.startsWith(u8, rec, "160000 ")) continue;
            const tab = std.mem.indexOfScalar(u8, rec, '\t') orelse continue;
            const sub = rec[tab + 1 ..];
            const rel = if (here.len == 0) sub else try std.mem.concat(alloc, u8, &.{ here, "/", sub });
            if (paths.contains(ok.items, rel)) continue;
            const dir = try fsutil.joinSlashy(alloc, root, rel);
            const dot_git = content.entryAt(try std.mem.concat(alloc, u8, &.{ dir, "/.git" })) catch content.Entry.absent;
            if (dot_git == .absent) {
                if (try holdsEntries(dir)) {
                    for (uninit.items) |u| {
                        if (std.mem.eql(u8, u.rel, rel)) break;
                    } else try uninit.append(alloc, .{ .rel = rel, .submodule = if (here.len == 0) null else here });
                }
                continue;
            }
            try ok.append(alloc, rel);
            try todo.append(alloc, rel);
        }
    }
    std.mem.sort([]const u8, ok.items, {}, paths.lessThan);
    return .{ .ok = ok.items, .failed = failed.items, .uninitialized = uninit.items };
}

/// Whether `path` is a directory holding any entry, not followed if it is
/// a link. A directory that cannot be read holds entries.
fn holdsEntries(path: []const u8) !bool {
    if (try content.entryAt(path) != .dir) return false;
    var d = std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true }) catch return true;
    defer d.close(io());
    var it = d.iterate();
    return (it.next(io()) catch return true) != null;
}

/// Whether the directory `rel` lies above a member of `rels`, byte for
/// byte or under case folding and normalization (`folded`, each member's
/// `paths.foldKey`).
fn aboveAny(alloc: std.mem.Allocator, rel: []const u8, rels: []const []const u8, folded: []const []const u8) !bool {
    for (rels) |r| if (below(r, rel)) return true;
    const rf = try foldOrSelf(alloc, rel);
    for (folded) |f| if (below(f, rf)) return true;
    return false;
}

/// Whether `rel` is at or under a block line (a path or a temporary), byte
/// for byte or, where git matches names in any ASCII case (`ignore_case`,
/// `clone.ignoresCase`), in any case, or at or under a place `found`
/// names: the closing sweep's rule judges it. Any other spelling of a line
/// git hides is a place `found` names in git's own spelling.
fn underBlock(rel: []const u8, lines: []const []const u8, ignore_case: bool, found: []const sweep.Found) bool {
    for (lines) |l| {
        if (rel.len < l.len or (rel.len > l.len and rel[l.len] != '/')) continue;
        const head = rel[0..l.len];
        if (std.mem.eql(u8, head, l) or (ignore_case and std.ascii.eqlIgnoreCase(head, l))) return true;
    }
    for (found) |f| {
        const at = f.temp orelse f.rel;
        if (std.mem.eql(u8, rel, at) or below(rel, at)) return true;
    }
    return false;
}

/// Whether the ignored entry `rel` of `tree`, which is `entry`, is holt's:
/// its link, or content identical to the kept copy of a path the store
/// visits.
fn holtsOwn(scope: sweep.Scope, tree: []const u8, rel: []const u8, entry: content.Entry) !bool {
    const a = scope.ctx.alloc;
    const at = try fsutil.joinSlashy(a, tree, rel);
    if (scope.key != null and entry == .symlink) if (try content.readLink(a, at)) |raw| {
        if (link.isHolt(a, at, raw, scope.chain, scope.roots, rel)) return true;
    };
    if (!paths.contains(scope.visited, rel)) return false;
    return scope.identical(at, rel) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
}

/// The tracked files of the working tree at `tree` (`/`-joined, relative
/// to it) that the index marks skip-worktree or assume-unchanged (`git
/// ls-files -v` tags `S` and lowercase) and whose content differs from the
/// index, since git shows the edit nowhere: a regular file whose `git
/// hash-object --no-filters` differs from the index entry's (so no clean
/// filter runs and nothing is written), or whose executable bit differs
/// from the index mode where `core.fileMode` is true; a link whose target
/// differs from the blob's; and anything of another kind than the index
/// entry, a directory included, each directory followed by the untracked
/// files git lists below it once asked for that path. Where
/// `core.symlinks` is false, a link entry checked out as a regular file is
/// compared as a file. An absent path and a submodule are not edits. The
/// paths reach git on its standard input, through a file
/// `clone.writeRunFile` makes in the first of `dirs` that can take one
/// (`machine_id` names it), removed again. Null when git fails or no such
/// file can be made.
fn trackedEdits(a: std.mem.Allocator, tree: []const u8, dirs: []const []const u8, machine_id: []const u8) !?[]const []const u8 {
    const res = try git.runInRepoScoped(a, &.{ "ls-files", "-s", "-v", "-z" }, tree);
    if (res.status != 0) return null;
    const file_mode = (try configBool(a, tree, "core.filemode")) orelse return null;
    const symlinks = (try configBool(a, tree, "core.symlinks")) orelse return null;
    const exec_bits = file_mode and std.Io.File.Permissions.has_executable_bit;
    var out: std.ArrayList([]const u8) = .empty;
    var replaced: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var want: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, res.stdout, 0);
    while (it.next()) |rec| {
        if (rec.len < 2 or rec[1] != ' ' or !(rec[0] == 'S' or std.ascii.isLower(rec[0]))) continue;
        const tab = std.mem.indexOfScalar(u8, rec, '\t') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, rec[2..tab], ' ');
        const mode = fields.next() orelse continue;
        const hash = fields.next() orelse continue;
        const rel = rec[tab + 1 ..];
        if (std.mem.eql(u8, mode, "160000")) continue;
        const at = try fsutil.joinSlashy(a, tree, rel);
        const entry = content.entryAt(at) catch content.Entry.other;
        const is_link = std.mem.eql(u8, mode, "120000");
        switch (entry) {
            .absent => {},
            .dir => {
                try out.append(a, rel);
                try replaced.append(a, rel);
            },
            .file => if (is_link and symlinks) try out.append(a, rel) else {
                if (exec_bits and !is_link and ((try content.modeOf(at)) & 0o100 != 0) != std.mem.eql(u8, mode, "100755")) {
                    try out.append(a, rel);
                    continue;
                }
                try files.append(a, rel);
                try want.append(a, hash);
            },
            .symlink => if (!is_link) try out.append(a, rel) else {
                const raw = (try content.readLink(a, at)) orelse continue;
                const blob = try git.runInRepoScoped(a, &.{ "cat-file", "blob", hash }, tree);
                if (blob.status != 0) return null;
                if (!std.mem.eql(u8, blob.stdout, raw)) try out.append(a, rel);
            },
            .other => try out.append(a, rel),
        }
    }
    if (files.items.len > 0) {
        var input: std.ArrayList(u8) = .empty;
        for (files.items) |rel| {
            try appendStdinPath(a, &input, rel);
            try input.append(a, '\n');
        }
        const file = (try clone.writeRunFile(a, dirs, machine_id, input.items)) orelse return null;
        defer fsutil.removePath(file) catch {};
        const got = try git.runInRepoScopedWith(a, &.{ "hash-object", "--no-filters", "--stdin-paths" }, tree, .{ .stdin_path = file });
        if (got.status != 0) return null;
        var lines = std.mem.tokenizeAny(u8, got.stdout, "\r\n");
        for (files.items, want.items) |rel, h| {
            const line = lines.next() orelse return null;
            if (!std.mem.eql(u8, line, h)) try out.append(a, rel);
        }
    }
    if (replaced.items.len > 0) {
        for ((try status(a, tree, .untracked, replaced.items)) orelse return null) |e| {
            if (!e.dir and !paths.contains(out.items, e.rel)) try out.append(a, e.rel);
        }
    }
    std.mem.sort([]const u8, out.items, {}, paths.lessThan);
    return out.items;
}

/// The boolean git configuration `name` in the working tree at `tree`:
/// true when unset, as git defaults `core.fileMode` and `core.symlinks`;
/// null when git cannot say.
fn configBool(a: std.mem.Allocator, tree: []const u8, name: []const u8) !?bool {
    const res = try git.runInRepoScoped(a, &.{ "config", "--type=bool", name }, tree);
    if (res.status == 1) return true;
    if (res.status != 0) return null;
    return std.mem.startsWith(u8, res.stdout, "true");
}

/// Appends `rel` to `buf` as `git hash-object --stdin-paths` reads a line:
/// as it is, unless it starts with `"` or holds a control character, then
/// quoted in C style, which git unquotes.
fn appendStdinPath(a: std.mem.Allocator, buf: *std.ArrayList(u8), rel: []const u8) !void {
    const quote = (rel.len > 0 and rel[0] == '"') or for (rel) |c| {
        if (c < 0x20 or c == 0x7f) break true;
    } else false;
    if (!quote) return buf.appendSlice(a, rel);
    try buf.append(a, '"');
    for (rel) |c| {
        if (c == '"' or c == '\\') {
            try buf.appendSlice(a, &.{ '\\', c });
        } else if (c < 0x20 or c == 0x7f) {
            try buf.print(a, "\\{o:0>3}", .{c});
        } else try buf.append(a, c);
    }
    try buf.append(a, '"');
}

/// Whether git takes the directory at `dir` for a repository of its own:
/// `git rev-parse --git-dir` there succeeds without looking above it. Who
/// owns it does not count (`safe.directory`): a repository git would
/// refuse to open for its owner is a repository all the same.
fn isRepo(a: std.mem.Allocator, dir: []const u8) !bool {
    const res = try clone.gitAsOwner(a, &.{ "rev-parse", "--git-dir" }, dir);
    return res.status == 0 or clone.refusedForOwner(res);
}

/// How deep the walk `Options.deep_nested` asks for goes below a working
/// tree before it reports a directory `too_deep` and stops there.
pub const walk_depth_max: usize = 512;

/// Test seam: `walk_depth_max` for the next walks.
pub var walk_depth_for_test: ?usize = null;

/// Test seam: the directory, relative to the working tree, the walk takes
/// for a mount point of another filesystem.
pub var other_filesystem_for_test: ?[]const u8 = null;

/// What `walkNested` found.
const Walk = struct {
    nested: []const Nested,
    /// The directories it could not look into (`Candidate.walk`).
    unwalked: []const Candidate,
    /// Mount points of another filesystem it did not enter.
    other_filesystems: []const []const u8,
};

/// The directories of the working tree at `tree`, links not followed, that
/// are nested repositories as git's walk decides (`paths.isWalkDotGit`
/// under the `core.ignorecase` of the working tree or of the initialized
/// submodule `subs` it lies in, `ignore_case` for `tree` itself, or a
/// `.git` the filesystem finds there, `content.dotGitResolves`), other than
/// by the own `.git` of `tree` or of a submodule: each is a walked
/// `Nested`, `.` for `tree` itself. Not searched for nested repositories:
/// such an entry, a `.git`, another working tree of the clone (`trees`), a
/// directory of `known` (reported already, and not reported again), and a
/// directory git takes for a repository of its own (`isRepo`); each is
/// still walked for mount points. Never entered: a mount point of another
/// filesystem than `tree`'s, wherever it lies, even inside one of those
/// (`Walk.other_filesystems`), and anything more than `walk_depth_max`
/// levels down (the directory at that depth is a `too_deep` candidate). A
/// directory that cannot be opened or read, for any reason but its being
/// gone, is an `unreadable_dir` candidate. On Windows, a directory whose
/// reparse point is not a link (`content.isPlainReparseDir`) is walked as
/// a directory.
fn walkNested(a: std.mem.Allocator, tree: []const u8, ignore_case: bool, subs: []const []const u8, trees: []const []const u8, known: []const []const u8) !Walk {
    const sub_case = try a.alloc(bool, subs.len);
    for (subs, sub_case) |sub, *ic| ic.* = try clone.ignoresCase(a, try fsutil.joinSlashy(a, tree, sub));
    const depth_max = (if (builtin.is_test) walk_depth_for_test else null) orelse walk_depth_max;
    const top_dev = content.deviceOf(a, tree) catch null;
    var out: std.ArrayList(Nested) = .empty;
    var unwalked: std.ArrayList(Candidate) = .empty;
    var mounts: std.ArrayList([]const u8) = .empty;
    const Dir = struct { rel: []const u8, mounts_only: bool };
    var queue: std.ArrayList(Dir) = .empty;
    try queue.append(a, .{ .rel = "", .mounts_only = false });
    var q: usize = 0;
    while (q < queue.items.len) : (q += 1) {
        const here = queue.items[q].rel;
        const mounts_only = queue.items[q].mounts_only;
        const shown = if (here.len == 0) "." else here;
        const dir_path = if (here.len == 0) tree else try fsutil.joinSlashy(a, tree, here);
        var inner: ?[]const u8 = null;
        var ic = ignore_case;
        for (subs, sub_case) |sub, c| {
            if (!std.mem.eql(u8, here, sub) and !below(here, sub)) continue;
            if (inner == null or sub.len > inner.?.len) {
                inner = sub;
                ic = c;
            }
        }
        const top = here.len == 0 or (inner != null and std.mem.eql(u8, inner.?, here));
        var d = std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => {
                try unwalked.append(a, .{ .rel = shown, .entry = .dir, .walk = .unreadable_dir });
                continue;
            },
        };
        defer d.close(io());
        var children: std.ArrayList(Dir) = .empty;
        const resolves = if (mounts_only) false else content.dotGitResolves(a, dir_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => true,
        };
        var hit = !mounts_only and !top and resolves;
        var it = d.iterate();
        while (it.next(io()) catch |err| blk: {
            if (err != error.FileNotFound and err != error.NotDir) try unwalked.append(a, .{ .rel = shown, .entry = .dir, .walk = .unreadable_dir });
            break :blk null;
        }) |e| {
            const dot_git = !mounts_only and paths.isWalkDotGit(e.name, ic);
            if (dot_git and !(top and try isOwnDotGit(a, dir_path, e.name))) hit = true;
            var kind = if (e.kind == .unknown) (d.statFile(io(), e.name, .{ .follow_symlinks = false }) catch continue).kind else e.kind;
            if (kind == .sym_link and try content.isPlainReparseDir(a, try std.fs.path.join(a, &.{ dir_path, e.name }))) kind = .directory;
            if (kind != .directory) continue;
            const child = if (here.len == 0) try a.dupe(u8, e.name) else try std.mem.concat(a, u8, &.{ here, "/", e.name });
            if (mounts_only or dot_git) {
                try children.append(a, .{ .rel = child, .mounts_only = true });
                continue;
            }
            const is_dot_git = resolves and (content.knownSameFile(a, try std.fs.path.join(a, &.{ dir_path, e.name }), try std.fs.path.join(a, &.{ dir_path, ".git" })) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => false,
            });
            if (is_dot_git) continue;
            const other = paths.contains(trees, child) or paths.contains(known, child);
            try children.append(a, .{ .rel = child, .mounts_only = other });
        }
        if (hit) {
            const valid = try isRepo(a, dir_path);
            try out.append(a, .{ .listed = shown, .repo = shown, .submodule = inner, .ignored = false, .valid = valid, .walked = true });
            if (valid and !top) for (children.items) |*ch| {
                ch.mounts_only = true;
            };
        }
        std.mem.sort(Dir, children.items, {}, struct {
            fn lt(_: void, x: Dir, y: Dir) bool {
                return paths.lessThan({}, x.rel, y.rel);
            }
        }.lt);
        const depth = if (here.len == 0) 0 else std.mem.count(u8, here, "/") + 1;
        if (children.items.len > 0 and depth >= depth_max) {
            try unwalked.append(a, .{ .rel = shown, .entry = .dir, .walk = .too_deep });
            continue;
        }
        for (children.items) |child| {
            if (try otherFilesystem(a, tree, child.rel, top_dev)) {
                try mounts.append(a, child.rel);
                continue;
            }
            try queue.append(a, child);
        }
    }
    return .{ .nested = out.items, .unwalked = unwalked.items, .other_filesystems = mounts.items };
}

/// Whether the directory `rel` of `tree` is on another filesystem than
/// `tree` itself, which is on `top_dev` (`content.deviceOf`; null when
/// that cannot be read, and then no directory is).
fn otherFilesystem(a: std.mem.Allocator, tree: []const u8, rel: []const u8, top_dev: ?u64) !bool {
    if (builtin.is_test) if (other_filesystem_for_test) |o| if (std.mem.eql(u8, o, rel)) return true;
    const want = top_dev orelse return false;
    const dev = (content.deviceOf(a, try fsutil.joinSlashy(a, tree, rel)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    }) orelse return false;
    return dev != want;
}

/// Whether the entry `name` of the directory `dir`, the top of a working
/// tree, is its own `.git`: `.git` itself, or the entry git finds at
/// `.git` there.
fn isOwnDotGit(a: std.mem.Allocator, dir: []const u8, name: []const u8) !bool {
    if (std.mem.eql(u8, name, ".git")) return true;
    return content.sameFile(a, try std.fs.path.join(a, &.{ dir, name }), try std.fs.path.join(a, &.{ dir, ".git" })) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
}

/// How `expandNested` handled a listed directory.
const Consumed = enum {
    /// Reported in `nested`.
    nested,
    /// Listed again file by file.
    relisted,
    /// Another working tree of the clone, dropped.
    tree,
};

/// Handles the entry `e` git listed in the working tree at `git_tree`
/// (`tree` itself, or its submodule `prefix`, which `submodule` names) when
/// it is a directory holding a nested repository (`content.nestedRepos`,
/// under `ignore_case`, that working tree's `core.ignorecase`), returning
/// how it did, or null when it did not: a directory that is one is reported in `nested`, under
/// the directory git first listed; any other is listed again file by file
/// into `entries`, once, so what lies beside the repository is judged like
/// anything else; a directory git lists whole even then is reported with
/// the first repository below it. Another working tree of the clone,
/// `trees` (relative to `tree`), is no nested repository: a directory
/// that is one is dropped, since it is listed on its own, and one holding
/// one deeper is listed again file by file like any other.
/// `ListingFailed` when git cannot list it again.
fn expandNested(
    a: std.mem.Allocator,
    tree: []const u8,
    git_tree: []const u8,
    prefix: []const u8,
    submodule: ?[]const u8,
    e: Listed,
    ignore_case: bool,
    trees: []const []const u8,
    relisted: *std.ArrayList([]const u8),
    entries: *std.ArrayList(Listed),
    nested: *std.ArrayList(Nested),
) !?Consumed {
    if (!e.dir) return null;
    const rel = if (prefix.len == 0) e.rel else try std.mem.concat(a, u8, &.{ prefix, "/", e.rel });
    if (paths.contains(trees, rel)) return .tree;
    const found = try content.nestedRepos(a, try fsutil.joinSlashy(a, tree, rel), ignore_case, std.math.maxInt(usize));
    if (found.len == 0) return null;
    const listed = if (e.from) |f| (if (prefix.len == 0) f else try std.mem.concat(a, u8, &.{ prefix, "/", f })) else rel;
    if (found[0].len == 0 or paths.contains(relisted.items, e.rel)) {
        const repo = for (found) |r| {
            const at = if (r.len == 0) rel else try std.mem.concat(a, u8, &.{ rel, "/", r });
            if (!paths.contains(trees, at)) break at;
        } else return null;
        try nested.append(a, .{ .listed = listed, .repo = repo, .submodule = submodule, .ignored = e.ignored });
        return .nested;
    }
    try relisted.append(a, e.rel);
    for ((try status(a, git_tree, .again, &.{e.rel})) orelse return error.ListingFailed) |sub| {
        var again = sub;
        again.from = e.from orelse e.rel;
        try entries.append(a, again);
    }
    return .relisted;
}

/// Whether the regular files at or below `path`, links not followed, hold
/// more than `limit` bytes together.
fn sizeOver(alloc: std.mem.Allocator, path: []const u8, limit: u64) !bool {
    const cwd = std.Io.Dir.cwd();
    const top = try cwd.statFile(io(), path, .{ .follow_symlinks = false });
    if (top.kind != .directory) return top.size > limit;
    var total: u64 = 0;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(alloc, path);
    while (pending.pop()) |here| {
        var d = try cwd.openDir(io(), here, .{ .iterate = true });
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| switch (e.kind) {
            .directory => try pending.append(alloc, try std.fs.path.join(alloc, &.{ here, e.name })),
            .file => {
                total += (try d.statFile(io(), e.name, .{ .follow_symlinks = false })).size;
                if (total > limit) return true;
            },
            else => {},
        };
    }
    return false;
}

/// Whether the directory at `path` holds nothing but directories that hold
/// nothing, links not followed: no content is there to lose. False when a
/// directory below it cannot be read, and when one `walk_depth_max` levels
/// below it holds anything, which is not looked into.
fn holdsNothing(alloc: std.mem.Allocator, path: []const u8) !bool {
    const depth_max = (if (builtin.is_test) walk_depth_for_test else null) orelse walk_depth_max;
    const cwd = std.Io.Dir.cwd();
    const Dir = struct { path: []const u8, depth: usize };
    var pending: std.ArrayList(Dir) = .empty;
    try pending.append(alloc, .{ .path = path, .depth = 0 });
    while (pending.pop()) |here| {
        var d = cwd.openDir(io(), here.path, .{ .iterate = true }) catch return false;
        defer d.close(io());
        var it = d.iterate();
        while (it.next(io()) catch return false) |e| {
            if (here.depth >= depth_max) return false;
            const kind = if (e.kind == .unknown) (d.statFile(io(), e.name, .{ .follow_symlinks = false }) catch return false).kind else e.kind;
            if (kind != .directory) return false;
            try pending.append(alloc, .{ .path = try std.fs.path.join(alloc, &.{ here.path, e.name }), .depth = here.depth + 1 });
        }
    }
    return true;
}

fn entryOf(alloc: std.mem.Allocator, tree: []const u8, rel: []const u8) content.Entry {
    const at = fsutil.joinSlashy(alloc, tree, rel) catch return .other;
    return content.entryAt(at) catch .other;
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

const testing = std.testing;
const testutil = @import("../testutil.zig");
const harness = @import("harness.zig");
const block = @import("block.zig");
const Machine = harness.Machine;

/// Points the git holt runs at a global configuration of the test's own
/// whose ignore file holds `ignore`, so no developer's configuration
/// changes what git lists.
fn globalIgnore(a: std.mem.Allocator, sb: *testutil.Sandbox, ignore: []const u8) !testutil.EnvOverride {
    const file = try std.fs.path.join(a, &.{ sb.root, "global.ignore" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = file, .data = ignore });
    const cfg = try std.fs.path.join(a, &.{ sb.root, "global.gitconfig" });
    const text = try std.fmt.allocPrint(a, "[core]\n\texcludesFile = {s}\n", .{try fsutil.forwardSlashed(a, file)});
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = cfg, .data = text });
    return testutil.EnvOverride.install(a, "GIT_CONFIG_GLOBAL", cfg);
}

fn listOf(m: *const Machine, opts: Options) !Listing {
    const index = try store.loadIndex(m.ctx.alloc, m.ctx.layout);
    return list(m.ctx, &index, m.clone, opts);
}

fn find(l: Listing, rel: []const u8) ?Candidate {
    for (l.candidates) |cand| if (std.mem.eql(u8, cand.rel, rel)) return cand;
    return null;
}

fn expectRels(l: Listing, want: []const []const u8) !void {
    var ok = l.candidates.len == want.len;
    if (ok) for (l.candidates, want) |cand, w| {
        if (!std.mem.eql(u8, cand.rel, w)) ok = false;
    };
    if (ok) return;
    std.debug.print("candidates:\n", .{});
    for (l.candidates) |cand| std.debug.print("  {s}\n", .{cand.rel});
    return error.TestUnexpectedResult;
}

fn writeKept(m: *const Machine, rel: []const u8, data: []const u8) !void {
    const p = try fsutil.joinSlashy(m.ctx.alloc, try m.ctx.layout.keptDir(m.ctx.alloc), rel);
    try fsutil.ensureDir(std.fs.path.dirname(p).?);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = data });
}

test "list: a globally ignored file, an ignored file in an untracked directory, and one in a directory of only ignored files are candidates; untracked work never is, and the global ignore file is never a skip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "gasworks.local.json\n.env\n*.local\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);

    try m.write("gasworks.local.json", "{}");
    try m.write("newdir/.env", "SECRET=1");
    try m.write("newdir/work.txt", "in progress");
    try m.write("onlyignored/a.local", "a");
    try m.write("onlyignored/b.local", "b");
    try m.write("draft.txt", "untracked");

    const l = try listOf(m, .{});
    try expectRels(l, &.{ "gasworks.local.json", "newdir/.env", "onlyignored/a.local", "onlyignored/b.local" });
    try testing.expectEqual(content.Entry.file, find(l, "newdir/.env").?.entry);
    try testing.expectEqual(@as(usize, 0), l.nested.len);
}

test "list: an ignored directory holding nothing, or only directories holding nothing, is no candidate, in the working tree and in a submodule; one holding an empty file or a link is" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "empty/\nhollow/\nnote/\nlinked/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);

    const lib = try testutil.makeBareRepo(&sb, "lib.git");
    defer sb.alloc.free(lib);
    try m.git(&sb, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", lib, "sub" });

    const at = struct {
        fn dir(mm: *const Machine, rel: []const u8) !void {
            try fsutil.ensureDir(try fsutil.joinSlashy(mm.ctx.alloc, mm.clone, rel));
        }
    };
    try at.dir(m, "empty");
    try at.dir(m, "hollow/a/b");
    try at.dir(m, "hollow/c");
    try m.write("note/a/empty.txt", "");
    try at.dir(m, "linked");
    try std.Io.Dir.cwd().symLink(io(), "nowhere", try fsutil.joinSlashy(a, m.clone, "linked/l"), .{});
    try at.dir(m, "sub/empty");
    try at.dir(m, "sub/hollow/a");
    try m.write("sub/note/n", "");

    const l = try listOf(m, .{});
    try expectRels(l, &.{ "linked", "note", "sub/note" });
}

test "list: an ignored directory above a kept path is listed again file by file, and the kept path is left to the block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "config/\nwhole/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);

    try m.write("config/app.json", "kept");
    _ = try m.keep("config/app.json");
    try m.write("config/other.json", "only here");
    try m.write("config/sub/deep.json", "only here too");
    try m.write("whole/x", "collapsed");

    const l = try listOf(m, .{});
    try expectRels(l, &.{ "config/other.json", "config/sub/deep.json", "whole" });
    try testing.expectEqual(content.Entry.dir, find(l, "whole").?.entry);
}

test "list: what the block hides that holt holds nowhere else stays a candidate, skip or not; holt's link and content identical to its kept copy drop out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);

    try m.write(".clasp.json", "kept");
    _ = try m.keep(".clasp.json");
    try m.write("same.json", "same");
    _ = try m.keep("same.json");
    try m.write("linked.json", "linked");
    _ = try m.keep("linked.json");
    try writeKept(m, harness.repo_key ++ "/.holt-skip", ".clasp.json\n");
    try m.saveByRename(".clasp.json", "edited, only here");
    try m.saveByRename("same.json", "same");

    const l = try listOf(m, .{ .auto = true });
    try expectRels(l, &.{".clasp.json"});
    const c = find(l, ".clasp.json").?;
    try testing.expect(c.hidden != null and c.hidden.?.why == null);
    try testing.expect(c.auto == null);
    try testing.expectEqual(@as(usize, 0), l.auto_kept.len);
}

test "list: an ignored file in a submodule is a candidate relative to the superproject, and never kept automatically" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "*.local\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", "*.local\n");

    const lib = try testutil.makeBareRepo(&sb, "lib.git");
    defer sb.alloc.free(lib);
    try m.git(&sb, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", lib, "vendor/lib" });
    try m.write("vendor/lib/settings.local", "only here");
    try m.write("vendor/lib/draft.txt", "untracked in the submodule");

    const l = try listOf(m, .{ .auto = true });
    try expectRels(l, &.{"vendor/lib/settings.local"});
    const c = find(l, "vendor/lib/settings.local").?;
    try testing.expectEqualStrings("vendor/lib", c.submodule.?);
    try testing.expect(c.auto == null);
    try testing.expectEqual(@as(usize, 0), l.auto_kept.len);
    try testing.expectEqual(@as(usize, 0), l.auto_unignored.len);
    try testing.expectEqual(@as(usize, 0), l.submodules_failed.len);
    try testing.expectEqual(@as(usize, 1), l.submodules.len);
    try testing.expectEqualStrings("vendor/lib", l.submodules[0]);
    try testing.expectEqual(content.Entry.file, try m.entry("vendor/lib/settings.local"));
}

test "list: nested repositories, ignored or untracked, are reported before skip matching and are never candidates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "node_modules/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);

    try m.write("node_modules/pkg/index.js", "x");
    try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path("node_modules/pkg/inner") });
    try m.write("node_modules/other/index.js", "y");
    try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path("vendor/a/b/repo") });
    try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path("vendor/a/c") });

    const l = try listOf(m, .{});
    try expectRels(l, &.{});
    try expectNested(l, &.{ .{ "node_modules", "node_modules/pkg/inner" }, .{ "vendor", "vendor/a/b/repo" }, .{ "vendor", "vendor/a/c" } });
    for (l.nested) |n| try testing.expectEqual(std.mem.eql(u8, n.listed, "node_modules"), n.ignored);
}

fn expectNested(l: Listing, want: []const [2][]const u8) !void {
    var ok = l.nested.len == want.len;
    if (ok) for (want) |w| {
        for (l.nested) |n| {
            if (std.mem.eql(u8, n.listed, w[0]) and std.mem.eql(u8, n.repo, w[1])) break;
        } else ok = false;
    };
    if (ok) return;
    std.debug.print("nested:\n", .{});
    for (l.nested) |n| std.debug.print("  {s} {s}\n", .{ n.listed, n.repo });
    return error.TestUnexpectedResult;
}

test "list: what lies beside a nested repository in a directory git lists whole stays a candidate, in the working tree and in a submodule" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "tools/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);

    const lib = try testutil.makeBareRepo(&sb, "lib.git");
    defer sb.alloc.free(lib);
    try m.git(&sb, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", lib, "vendor/lib" });
    for ([_][]const u8{ "", "vendor/lib/" }) |at| {
        try m.write(try std.mem.concat(a, u8, &.{ at, "tools/secret.env" }), "only here");
        try m.write(try std.mem.concat(a, u8, &.{ at, "tools/deep/x" }), "only here too");
        try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path(try std.mem.concat(a, u8, &.{ at, "tools/repo" })) });
    }

    const l = try listOf(m, .{});
    try expectRels(l, &.{ "tools/deep/x", "tools/secret.env", "vendor/lib/tools/deep/x", "vendor/lib/tools/secret.env" });
    try expectNested(l, &.{ .{ "tools", "tools/repo" }, .{ "vendor/lib/tools", "vendor/lib/tools/repo" } });
    try testing.expectEqualStrings("vendor/lib", find(l, "vendor/lib/tools/secret.env").?.submodule.?);
    try testing.expectEqual(@as(usize, 0), l.submodules_failed.len);
}

test "list: an entry git lists is judged whatever its name: a spelling of `.git` with a code point HFS+ ignores, or git's NTFS alias, is a candidate and makes no nested repository" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, ".g\u{200c}it\ntools/\nalias/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try m.write(".g\u{200c}it", "a file of its own");
    try m.write("tools/.g\u{200c}it/HEAD", "a directory of its own");
    try m.write("alias/git~1/HEAD", "git's NTFS alias of .git");

    const l = try listOf(m, .{});
    try expectRels(l, &.{ ".g\u{200c}it", "alias", "tools" });
    try testing.expectEqual(@as(usize, 0), l.nested.len);
}

test "list: where core.ignorecase is false, a case spelling of `.git` is listed and judged like any name where the filesystem tells cases apart, and makes a nested repository where the filesystem finds it at `.git`" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const sensitive = try harness.caseSensitive(a, m.clone);
    const env = try globalIgnore(a, &sb, ".GIT\n.Git/\ncache/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try m.git(&sb, &.{ "config", "core.ignorecase", "false" });
    try m.write("cache/.GIT/stuff", "only here");
    try m.write("blocked/.GIT/stuff", "only here, hidden by the block");
    try block.add(a, (try clone.inspect(a, m.clone, m.ctx.code_root)).common_dir, &.{"blocked"});
    if (sensitive) {
        try m.write(".GIT", "a file beside .git");
        try m.write(".Git/x", "a directory beside .git");
    }

    const l = try listOf(m, .{});
    if (!sensitive) {
        try expectRels(l, &.{});
        try expectNested(l, &.{ .{ "blocked", "blocked" }, .{ "cache", "cache" } });
        for (l.nested) |n| try testing.expect(!n.valid);
        return;
    }
    try expectRels(l, &.{ ".GIT", ".Git", "blocked", "cache" });
    try testing.expect(find(l, "blocked").?.hidden != null);
    try testing.expectEqual(@as(usize, 0), l.nested.len);
}

test "list: a working tree of the same clone inside this one is no nested repository, untracked, ignored, or hidden by the block, and what lies beside it stays a candidate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "ign/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "inner", try m.path("wt") });
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "ignored", try m.path("ign/wt") });
    try m.write("ign/secret.env", "only here");
    try block.add(a, (try clone.inspect(a, m.clone, m.ctx.code_root)).common_dir, &.{"blocked"});
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "hidden", try m.path("blocked/wt") });
    try m.write("blocked/notes.md", "only here, hidden by the block");

    const l = try listOf(m, .{});
    try expectRels(l, &.{ "blocked", "ign/secret.env" });
    try testing.expect(find(l, "blocked").?.hidden != null);
    try expectNested(l, &.{});
}

test "list: the walk reports what git skips as `.git` where git lists nothing: a broken `.git` in a tracked directory, a case spelling of it under core.ignorecase, and one under a skip pattern, but never a working tree's own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "node_modules/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try m.git(&sb, &.{ "config", "core.ignorecase", "true" });
    const lib = try testutil.makeBareRepo(&sb, "lib.git");
    defer sb.alloc.free(lib);
    try m.git(&sb, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", lib, "vendor/lib" });
    for ([_][]const u8{ "src/main.c", "docs/README" }) |rel| {
        try m.write(rel, "committed");
        try m.git(&sb, &.{ "add", rel });
    }
    try m.git(&sb, &.{ "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "tracked" });
    try m.write("src/.git/notes.txt", "a broken .git, only here");
    try m.write("docs/.GIT/notes.txt", "skipped under core.ignorecase, only here");
    try m.write("node_modules/pkg/.git/notes.txt", "under a skip pattern, only here");
    try m.write("vendor/lib/deep/.git/notes.txt", "in a submodule, only here");
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "inner", try m.path("wt") });

    try expectNested(try listOf(m, .{}), &.{});
    const l = try listOf(m, .{ .deep_nested = true });
    try expectNested(l, &.{ .{ "node_modules/pkg", "node_modules/pkg" }, .{ "src", "src" }, .{ "docs", "docs" }, .{ "vendor/lib/deep", "vendor/lib/deep" } });
    for (l.nested) |n| try testing.expect(!n.valid and n.walked and !n.ignored);
    for (l.nested) |n| if (std.mem.eql(u8, n.repo, "vendor/lib/deep")) try testing.expectEqualStrings("vendor/lib", n.submodule.?);
}

test "list: the walk reports a nested repository git can open where git lists nothing, and does not walk into it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try block.add(a, (try clone.inspect(a, m.clone, m.ctx.code_root)).common_dir, &.{"blocked"});
    try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path("blocked/repo") });
    try m.write("blocked/repo/inner/.git/x", "inside the nested repository");

    const l = try listOf(m, .{ .deep_nested = true });
    try expectNested(l, &.{.{ "blocked/repo", "blocked/repo" }});
    try testing.expect(l.nested[0].valid);
}

test "list: a skip-worktree or assume-unchanged file whose content differs from the index is a candidate whatever the skip patterns say" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-skip.d/1", "*.cfg\n");
    for ([_][]const u8{ "sw.cfg", "au.cfg", "same.cfg", "gone.cfg", "plain.cfg" }) |rel| {
        try m.write(rel, "committed");
        try m.git(&sb, &.{ "add", rel });
    }
    try m.git(&sb, &.{ "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "tracked" });
    try m.git(&sb, &.{ "update-index", "--skip-worktree", "sw.cfg", "same.cfg", "gone.cfg" });
    try m.git(&sb, &.{ "update-index", "--assume-unchanged", "au.cfg" });
    try m.write("sw.cfg", "edited, only here");
    try m.write("au.cfg", "edited, only here");
    try m.write("plain.cfg", "edited, and git shows it");
    try fsutil.removePath(try m.path("gone.cfg"));

    try expectRels(try listOf(m, .{}), &.{});
    const l = try listOf(m, .{ .tracked_edits = true });
    try expectRels(l, &.{ "au.cfg", "sw.cfg" });
    for (l.candidates) |cand| try testing.expect(cand.hidden_tracked_edit and cand.entry == .file);
}

test "list: skip patterns from the user's list, its added lines, the repo's list, and the repo's added lines each drop their matches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "*.cfg\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-skip", "a.cfg\n");
    try writeKept(m, ".holt-skip.d/1", "b.cfg\n");
    try writeKept(m, harness.repo_key ++ "/.holt-skip", "c.cfg\n");
    try writeKept(m, harness.repo_key ++ "/.holt-skip.d/1", "/sub/d.cfg\n");

    for ([_][]const u8{ "a.cfg", "b.cfg", "c.cfg", "sub/d.cfg", "d.cfg", "e.cfg" }) |rel| try m.write(rel, rel);
    try expectRels(try listOf(m, .{}), &.{ "d.cfg", "e.cfg" });
}

test "auto-keep: an ignored match with no fact is kept, a directory pattern keeps the directory whole, skip wins, and a match over 10 MiB or with a fact stays a candidate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, ".clasp.json\n.superpowers/\n*.cfg\n*.bin\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", ".superpowers/\n");
    try writeKept(m, ".holt-auto.d/2", "*.cfg\n");
    try writeKept(m, ".holt-auto.d/3", "*.bin\n");
    try writeKept(m, ".holt-auto.d/4", "notes.txt\n");
    try writeKept(m, ".holt-skip.d/1", "skipped.cfg\n");

    try m.write(".clasp.json", "{\"scriptId\": \"abc\"}");
    try m.write(".superpowers/plan.md", "plan");
    try m.write(".superpowers/deep/more.md", "more");
    try m.write("skipped.cfg", "skip wins");
    try m.write("first.json", "kept by hand, so the key exists");
    _ = try m.keep("first.json");
    try m.write("other.cfg", "another machine kept this path");
    try store.writeFact(a, m.ctx.layout, harness.repo_key, "000000000000000b", "other.cfg", .file, &@as([64]u8, @splat('0')));
    try m.write("notes.txt", "untracked, not ignored");
    const big = try a.alloc(u8, auto_max_bytes + 1);
    @memset(big, 'x');
    try m.write("big.bin", big);
    try m.write("small.bin", "small");

    const quiet = try listOf(m, .{});
    try testing.expectEqual(@as(usize, 0), quiet.auto_kept.len);
    for (quiet.candidates) |cand| try testing.expect(cand.auto == null);
    try testing.expectEqual(content.Entry.file, try m.entry(".clasp.json"));

    const l = try listOf(m, .{ .auto = true });
    try testing.expectEqual(@as(usize, 3), l.auto_kept.len);
    const want = [_][2][]const u8{ .{ ".clasp.json", ".clasp.json" }, .{ ".superpowers", ".superpowers/" }, .{ "small.bin", "*.bin" } };
    for (want) |pair| {
        for (l.auto_kept) |k| {
            if (std.mem.eql(u8, k.rel, pair[0])) {
                try testing.expectEqualStrings(pair[1], k.pattern);
                try testing.expect(k.outcome.status == .kept);
                break;
            }
        } else return error.TestUnexpectedResult;
        try testing.expect(try m.linked(pair[0]));
    }
    try testing.expectEqualStrings("more", try m.read(".superpowers/deep/more.md"));
    try expectRels(l, &.{ "big.bin", "other.cfg" });
    const b = find(l, "big.bin").?.auto.?;
    try testing.expectEqualStrings("*.bin", b.pattern);
    try testing.expect(b.why == .too_large);
    try testing.expect(find(l, "other.cfg").?.auto.?.why == .has_fact);
    try testing.expectEqual(@as(usize, 1), l.auto_unignored.len);
    try testing.expectEqualStrings("notes.txt", l.auto_unignored[0].rel);
    try testing.expectEqualStrings("notes.txt", l.auto_unignored[0].pattern);
    try testing.expectEqual(content.Entry.file, try m.entry("skipped.cfg"));
}

test "auto-keep: without kept/, the seed's auto patterns keep nothing and create no store" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, ".clasp.json\nnode_modules/\n");
    defer env.restore();

    try m.write(".clasp.json", "{}");
    try m.write("node_modules/x.js", "seed skip");
    const l = try listOf(m, .{ .auto = true });
    try expectRels(l, &.{".clasp.json"});
    const miss = find(l, ".clasp.json").?.auto.?;
    try testing.expect(miss.why == .store_absent);
    try testing.expectEqualStrings(".clasp.json", miss.pattern);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try m.ctx.layout.keptDir(a)));
}

test "auto-keep: a file git reads only as a regular file is never kept, but listed with its flag and counted not kept; a directory holding one is kept whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, ".gitattributes\nd/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", ".gitattributes\nd/\n");

    try m.write(".gitattributes", "* text=auto\n");
    try m.write("d/.gitignore", "*.tmp\n");
    try m.write("d/conf.json", "{}");

    const plan = try listOf(m, .{ .auto_plan = true });
    try testing.expectEqual(@as(usize, 1), plan.would_auto.len);
    try testing.expectEqualStrings("d", plan.would_auto[0].rel);

    const l = try listOf(m, .{ .auto = true });
    try testing.expectEqual(@as(usize, 1), l.auto_kept.len);
    try testing.expectEqualStrings("d", l.auto_kept[0].rel);
    try testing.expect(try m.linked("d"));
    try expectRels(l, &.{".gitattributes"});
    const cand = find(l, ".gitattributes").?;
    try testing.expect(cand.git_reads_unlinked);
    const miss = cand.auto.?;
    try testing.expect(miss.why == .git_reads_unlinked);
    try testing.expectEqualStrings(".gitattributes", miss.pattern);
    try testing.expectEqual(@as(usize, 1), l.notKept());
    try testing.expectEqual(content.Entry.file, try m.entry(".gitattributes"));
}

test "list: where git matches names byte for byte, a case variant of a kept path is a candidate of its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;
    const env = try globalIgnore(a, &sb, "local.json\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try m.git(&sb, &.{ "config", "core.ignorecase", "false" });

    try m.write("config/local.json", "kept");
    _ = try m.keep("config/local.json");
    try m.write("Config/local.json", "a separate file, only here");

    const l = try listOf(m, .{});
    try expectRels(l, &.{"Config/local.json"});
    try testing.expect(find(l, "Config/local.json").?.hidden == null);
}

test "list: the directory of a submodule that is not initialized but holds entries is a candidate whatever the skip patterns say; an empty one is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", "vendor/\n");

    const lib = try testutil.makeBareRepo(&sb, "lib.git");
    defer sb.alloc.free(lib);
    for ([_][]const u8{ "vendor/lib", "vendor/empty", "vendor/skipped" }) |at| {
        try m.git(&sb, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", lib, at });
        try m.git(&sb, &.{ "submodule", "deinit", "-q", "-f", at });
    }
    try m.write("vendor/lib/notes.txt", "written after deinit, only here");
    try m.write("vendor/skipped/x", "skipped");
    try writeKept(m, ".holt-skip.d/1", "/vendor/skipped/\n");

    const l = try listOf(m, .{ .auto = true });
    try expectRels(l, &.{ "vendor/lib", "vendor/skipped" });
    try testing.expect(find(l, "vendor/skipped").?.submodule_uninitialized);
    const c = find(l, "vendor/lib").?;
    try testing.expect(c.submodule_uninitialized);
    try testing.expectEqual(content.Entry.dir, c.entry);
    try testing.expect(c.submodule == null and c.auto == null);
    try testing.expectEqual(@as(usize, 0), l.auto_kept.len);
}

test "auto-keep: a directory pattern keeps the directory once when git lists its files one by one, and file by file when something below it is tracked or visible to git" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "*.md\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", ".superpowers/\ntracked/\nvisible/\n");

    try m.write(".superpowers/plan.md", "plan");
    try m.write(".superpowers/deep/more.md", "more");
    try m.write("tracked/README", "committed");
    try m.git(&sb, &.{ "add", "tracked/README" });
    try m.git(&sb, &.{ "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "tracked" });
    try m.write("tracked/notes.md", "tracked dir's notes");
    try m.write("visible/wip.txt", "untracked, not ignored");
    try m.write("visible/notes.md", "visible dir's notes");

    const l = try listOf(m, .{ .auto = true });
    var rels: std.ArrayList([]const u8) = .empty;
    for (l.auto_kept) |k| {
        try rels.append(a, k.rel);
        try testing.expect(k.outcome.status == .kept);
    }
    std.mem.sort([]const u8, rels.items, {}, paths.lessThan);
    try testing.expectEqual(@as(usize, 3), rels.items.len);
    try testing.expectEqualStrings(".superpowers", rels.items[0]);
    try testing.expectEqualStrings("tracked/notes.md", rels.items[1]);
    try testing.expectEqualStrings("visible/notes.md", rels.items[2]);
    try testing.expect(try m.linked(".superpowers"));
    try testing.expectEqualStrings("more", try m.read(".superpowers/deep/more.md"));
    try expectRels(l, &.{});
}

test "auto-keep: a directory pattern keeps file by file a directory at or above a kept path or a block line, and one holding anything a skip pattern matches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "*.md\n*.tmp\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", ".superpowers/\ntools/\nnotes/\n");
    try writeKept(m, ".holt-skip.d/1", "*.tmp\n");

    try m.write(".superpowers/keep.md", "kept by hand");
    _ = try m.keep(".superpowers/keep.md");
    try m.write(".superpowers/a.md", "a");
    try m.write(".superpowers/deep/b.md", "b");
    try block.add(a, (try clone.inspect(a, m.clone, m.ctx.code_root)).common_dir, &.{"tools/line"});
    try m.write("tools/x.md", "x");
    try m.write("tools/sub/y.md", "y");
    try m.write("notes/plan.md", "plan");
    try m.write("notes/scratch.tmp", "skip wins");

    const l = try listOf(m, .{ .auto = true });
    var rels: std.ArrayList([]const u8) = .empty;
    for (l.auto_kept) |k| {
        try rels.append(a, k.rel);
        try testing.expect(k.outcome.status == .kept);
    }
    std.mem.sort([]const u8, rels.items, {}, paths.lessThan);
    const want = [_][]const u8{ ".superpowers/a.md", ".superpowers/deep/b.md", "notes/plan.md", "tools/sub/y.md", "tools/x.md" };
    try testing.expectEqual(want.len, rels.items.len);
    for (want, rels.items) |x, y| try testing.expectEqualStrings(x, y);
    try expectRels(l, &.{});
    try testing.expectEqual(content.Entry.file, try m.entry("notes/scratch.tmp"));
    try testing.expectEqual(content.Entry.dir, try m.entry("notes"));
}

test "list: a file an auto pattern matches inside an untracked directory is reported as not ignored, and a directory it matches once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", "tools/\n");

    try m.write("gas/.clasp.json", "{}");
    try m.write("gas/code.js", "work");
    try m.write("tools/a/x", "dir pattern");
    try m.write("tools/b", "dir pattern");

    const l = try listOf(m, .{});
    try testing.expectEqual(@as(usize, 2), l.auto_unignored.len);
    try testing.expectEqualStrings("gas/.clasp.json", l.auto_unignored[0].rel);
    try testing.expectEqualStrings(".clasp.json", l.auto_unignored[0].pattern);
    try testing.expectEqualStrings("tools", l.auto_unignored[1].rel);
}

test "auto-keep: under the clone's and the key's locks the caller holds, keep takes neither again, and only the lock files keep would take count as held" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, ".clasp.json\n*.local\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", "*.local\n");
    try m.write(".clasp.json", "{}");

    ctx_mod.lock_nonblocking_for_test = true;
    defer ctx_mod.lock_nonblocking_for_test = false;
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const clone_lock = try ctx_mod.lockClone(m.ctx, c.common_dir);
    defer clone_lock.release();
    {
        const key_lock = try ctx_mod.lockKey(m.ctx, c.key.?);
        defer key_lock.release();
        const other_lock = try ctx_mod.lockKey(m.ctx, "github.com/acme/other");
        defer other_lock.release();

        const unheld = try listOf(m, .{ .auto = true });
        try testing.expectEqualStrings("WouldBlock", find(unheld, ".clasp.json").?.auto.?.detail.?);

        const other = try listOf(m, .{ .auto = true, .held = .of(clone_lock, other_lock) });
        try testing.expectEqualStrings("LocksNotHeld", find(other, ".clasp.json").?.auto.?.detail.?);

        const l = try listOf(m, .{ .auto = true, .held = .of(clone_lock, key_lock) });
        try testing.expectEqual(@as(usize, 1), l.auto_kept.len);
        try testing.expectEqualStrings(".clasp.json", l.auto_kept[0].rel);
        try testing.expect(try m.linked(".clasp.json"));
    }

    try m.write("x.local", "x");
    const spelled = try ctx_mod.lockKey(m.ctx, "github.com/ACME/widget");
    defer spelled.release();
    const l = try listOf(m, .{ .auto = true, .held = .of(clone_lock, spelled) });
    try testing.expectEqual(@as(usize, 1), l.auto_kept.len);
    try testing.expectEqualStrings("x.local", l.auto_kept[0].rel);
}

test "listAll: every working tree of the clone is listed, and one whose record cannot be swept is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "*.local\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);

    const base = std.fs.path.dirname(m.clone).?;
    const feature = try std.fs.path.join(a, &.{ base, "widget@feature" });
    const gone = try std.fs.path.join(a, &.{ base, "widget@gone" });
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "feature", feature });
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "gone", gone });
    try std.Io.Dir.cwd().deleteTree(io(), gone);
    try m.write("main.local", "main");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ feature, "feature.local" }), .data = "feature" });

    const index = try store.loadIndex(a, m.ctx.layout);
    const all = try listAll(m.ctx, &index, try clone.inspect(a, m.clone, m.ctx.code_root), .{});
    try testing.expectEqual(@as(usize, 2), all.listings.len);
    try testing.expectEqualStrings(m.clone, all.listings[0].worktree);
    try expectRels(all.listings[0], &.{"main.local"});
    try testing.expectEqualStrings(try fsutil.realPathOrSelf(a, feature), all.listings[1].worktree);
    try expectRels(all.listings[1], &.{"feature.local"});
    try testing.expectEqual(@as(usize, 1), all.unlisted.len);
    try testing.expectEqual(@as(?clone.TreeProblem, .absent), all.unlisted[0].problem);
}

test "listAll: a foreign repository at a recorded working tree's path is no working tree of the clone: it is reported unlisted, and the main tree reports it as a nested repository" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", ".clasp.json\n");
    for ([_][]const u8{ "foreign", "broken" }) |name| {
        try m.git(&sb, &.{ "worktree", "add", "-q", "-b", name, try m.path(name) });
        try std.Io.Dir.cwd().deleteTree(io(), try m.path(name));
    }
    try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path("foreign") });
    try m.write("foreign/notes.md", "another repository's work");
    try m.write("broken/.git/junk", "not a repository");
    try m.write("broken/.clasp.json", "{}");

    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const index = try store.loadIndex(a, m.ctx.layout);
    const all = try listAll(m.ctx, &index, c, .{});
    try testing.expectEqual(@as(usize, 1), all.listings.len);
    try testing.expectEqual(@as(usize, 2), all.unlisted.len);
    for (all.unlisted) |u| try testing.expectEqual(@as(?clone.TreeProblem, .foreign_repository), u.problem);
    const l = all.listings[0];
    try expectNested(l, &.{ .{ "broken", "broken" }, .{ "foreign", "foreign" } });
    try testing.expectEqual(@as(usize, 1), l.auto_unignored.len);
    try testing.expectEqualStrings("broken/.clasp.json", l.auto_unignored[0].rel);

    const scope = try sweep.Scope.load(m.ctx, c, c.key, c.key, true);
    var unreadable: usize = 0;
    for (try scope.hiddenAll(&.{"x"}, &.{}, &.{}, null)) |f| {
        if (f.why == .tree_unreadable and std.mem.eql(u8, f.detail.?, "foreign_repository")) unreadable += 1;
    }
    try testing.expectEqual(@as(usize, 2), unreadable);
}

/// Makes the directory at `path` unreadable, or returns false when this
/// process can open it all the same (a superuser, or a platform without
/// such permissions).
fn makeUnreadable(path: []const u8) !bool {
    if (builtin.os.tag == .windows) return false;
    try std.Io.Dir.cwd().setFilePermissions(io(), path, @enumFromInt(0o000), .{});
    var d = std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true }) catch return true;
    d.close(io());
    try std.Io.Dir.cwd().setFilePermissions(io(), path, @enumFromInt(0o755), .{});
    return false;
}

test "list: a directory git warns it cannot open fails the listing, and the walk reports each directory it cannot open as unreadable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "node_modules/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);

    try m.write("node_modules/pkg/index.js", "only here");
    const pkg = try m.path("node_modules/pkg");
    if (!try makeUnreadable(pkg)) return error.SkipZigTest;
    defer std.Io.Dir.cwd().setFilePermissions(io(), pkg, @enumFromInt(0o755), .{}) catch {};
    const l = try listOf(m, .{ .deep_nested = true });
    const c = find(l, "node_modules/pkg").?;
    try testing.expectEqual(@as(?WalkMiss, .unreadable_dir), c.walk);
    try testing.expectEqual(content.Entry.dir, c.entry);

    try m.write("work/draft.txt", "untracked work");
    const work = try m.path("work");
    try testing.expect(try makeUnreadable(work));
    defer std.Io.Dir.cwd().setFilePermissions(io(), work, @enumFromInt(0o755), .{}) catch {};
    try testing.expectError(error.ListingFailed, listOf(m, .{}));
    const index = try store.loadIndex(a, m.ctx.layout);
    const all = try listAll(m.ctx, &index, try clone.inspect(a, m.clone, m.ctx.code_root), .{});
    try testing.expectEqual(@as(usize, 0), all.listings.len);
    try testing.expectEqualStrings("ListingFailed", all.unlisted[0].detail.?);
}

test "list: a skip-worktree or assume-unchanged path replaced by a directory is an edit, and what git lists inside it is too" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    for ([_][]const u8{ "sw.cfg", "au.cfg" }) |rel| {
        try m.write(rel, "committed");
        try m.git(&sb, &.{ "add", rel });
    }
    try m.git(&sb, &.{ "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "tracked" });
    try m.git(&sb, &.{ "update-index", "--skip-worktree", "sw.cfg" });
    try m.git(&sb, &.{ "update-index", "--assume-unchanged", "au.cfg" });
    for ([_][]const u8{ "sw.cfg", "au.cfg" }) |rel| try fsutil.removePath(try m.path(rel));
    try m.write("sw.cfg/x", "only here");
    try m.write("sw.cfg/sub/y", "only here too");
    try m.write("au.cfg/z", "only here");

    try expectRels(try listOf(m, .{}), &.{});
    const l = try listOf(m, .{ .tracked_edits = true });
    try expectRels(l, &.{ "au.cfg", "au.cfg/z", "sw.cfg", "sw.cfg/sub/y", "sw.cfg/x" });
    for (l.candidates) |cand| try testing.expect(cand.hidden_tracked_edit);
    try testing.expectEqual(content.Entry.dir, find(l, "sw.cfg").?.entry);
}

test "list: a flagged file whose executable bit differs from the index is an edit where core.fileMode is true, and a flagged link checked out as a file is compared as one where core.symlinks is false" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try m.git(&sb, &.{ "config", "core.fileMode", "true" });
    try m.write("run.sh", "#!/bin/sh\n");
    try content.createLink("target", try m.path("same-link"), .file);
    try content.createLink("target", try m.path("other-link"), .file);
    try m.git(&sb, &.{ "add", "run.sh", "same-link", "other-link" });
    try m.git(&sb, &.{ "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "tracked" });
    try m.git(&sb, &.{ "update-index", "--skip-worktree", "run.sh", "same-link", "other-link" });
    try std.Io.Dir.cwd().setFilePermissions(io(), try m.path("run.sh"), @enumFromInt(0o755), .{});
    for ([_][]const u8{ "same-link", "other-link" }) |rel| try fsutil.removePath(try m.path(rel));
    try m.write("same-link", "target");
    try m.write("other-link", "an edit, only here");
    try m.git(&sb, &.{ "config", "core.symlinks", "false" });

    try expectRels(try listOf(m, .{ .tracked_edits = true }), &.{ "other-link", "run.sh" });
    try m.git(&sb, &.{ "config", "core.fileMode", "false" });
    try expectRels(try listOf(m, .{ .tracked_edits = true }), &.{"other-link"});
}

test "list: flagged files are hashed without running a clean filter, whatever their names" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    const names = [_][]const u8{ "\"quoted.cfg", "new\nline.cfg", "back\\slash.cfg", "plain.cfg" };
    for (names) |rel| try m.write(rel, "committed");
    try m.git(&sb, &.{ "add", "--", names[0], names[1], names[2], names[3] });
    try m.git(&sb, &.{ "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "tracked" });
    try m.git(&sb, &.{ "update-index", "--skip-worktree", "--", names[0], names[1], names[2], names[3] });
    for (names[0..3]) |rel| try m.write(rel, "edited, only here");
    const marker = try std.fs.path.join(a, &.{ sb.root, "filter-ran" });
    try m.write(".gitattributes", "*.cfg filter=mark\n");
    try m.git(&sb, &.{ "config", "filter.mark.clean", try std.fmt.allocPrint(a, "touch '{s}'; cat", .{marker}) });

    try expectRels(try listOf(m, .{ .tracked_edits = true }), &.{ "\"quoted.cfg", "back\\slash.cfg", "new\nline.cfg" });
    try testing.expectEqual(content.Entry.absent, try content.entryAt(marker));
}

test "list: where core.ignorecase is true on a filesystem that tells cases apart, the walk lists what git takes for a path of another case" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try m.write("Vendor", "a tracked file");
    try m.git(&sb, &.{ "add", "Vendor" });
    try m.git(&sb, &.{ "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "tracked" });
    try m.git(&sb, &.{ "config", "core.ignorecase", "true" });
    try m.write("readme", "a separate file, only here");
    try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path("vendor") });

    try expectRels(try listOf(m, .{}), &.{});
    const l = try listOf(m, .{ .deep_nested = true });
    try expectRels(l, &.{"readme"});
    try testing.expect(find(l, "readme").?.case_hidden);
    try expectNested(l, &.{.{ "vendor", "vendor" }});
}

test "isRepo: a repository git refuses to open for its owner is a repository" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const repo = try std.fs.path.join(a, &.{ sb.root, "repo" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", repo });
    const env = try testutil.EnvOverride.install(a, "GIT_TEST_ASSUME_DIFFERENT_OWNER", "1");
    defer env.restore();
    try testing.expect(try isRepo(a, repo));
}

test "list: the walk stays on the working tree's filesystem and stops at its depth bound, reporting both" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "mnt/\ndeep/\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try m.write("mnt/sub/.git/x", "on another filesystem");
    try m.write("deep/a/b/c/.git/x", "past the bound");
    try m.write("deep/a/.git/x", "within the bound");
    other_filesystem_for_test = "mnt";
    defer other_filesystem_for_test = null;
    walk_depth_for_test = 2;
    defer walk_depth_for_test = null;

    const l = try listOf(m, .{ .deep_nested = true });
    try expectNested(l, &.{.{ "deep/a", "deep/a" }});
    try testing.expectEqual(@as(usize, 1), l.other_filesystems.len);
    try testing.expectEqualStrings("mnt", l.other_filesystems[0]);
    const c = find(l, "deep/a").?;
    try testing.expectEqual(@as(?WalkMiss, .too_deep), c.walk);
}

test "holdsNothing: empty directories down to the depth bound hold nothing, and one past it is taken to hold something" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(testing.io, "within/a/b");
    try tmp.dir.createDirPath(testing.io, "past/a/b/c");
    walk_depth_for_test = 2;
    defer walk_depth_for_test = null;
    try testing.expect(try holdsNothing(arena, try std.fs.path.join(arena, &.{ root, "within" })));
    try testing.expect(!try holdsNothing(arena, try std.fs.path.join(arena, &.{ root, "past" })));
}

test "auto-keep: a directory pattern keeps file by file a directory holding a nested repository, a reserved name, or a name a kept path may not hold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "*.md\n.holt-*\n");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try writeKept(m, ".holt-auto.d/1", "tools/\nnotes/\n");
    try m.write("tools/x.md", "x");
    try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path("tools/repo") });
    try m.write("notes/plan.md", "plan");
    try m.write("notes/.holt-mine", "a reserved name");

    const l = try listOf(m, .{ .auto = true });
    var rels: std.ArrayList([]const u8) = .empty;
    for (l.auto_kept) |k| try rels.append(a, k.rel);
    std.mem.sort([]const u8, rels.items, {}, paths.lessThan);
    try testing.expectEqual(@as(usize, 2), rels.items.len);
    try testing.expectEqualStrings("notes/plan.md", rels.items[0]);
    try testing.expectEqualStrings("tools/x.md", rels.items[1]);
    try testing.expectEqual(content.Entry.dir, try m.entry("tools"));
    try testing.expectEqual(content.Entry.dir, try m.entry("notes"));
    try testing.expect(find(l, "notes/.holt-mine").?.auto.?.why == .failed);
}

test "list: under a block line naming `git~1`, where git lists it as any name, the place is judged and set aside like any other" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    const env = try globalIgnore(a, &sb, "");
    defer env.restore();
    _ = try patterns.createStore(a, m.ctx.layout);
    try block.add(a, (try clone.inspect(a, m.clone, m.ctx.code_root)).common_dir, &.{"alias/git~1"});
    try m.write("alias/git~1/HEAD", "only here");
    try m.write("alias/draft.txt", "untracked work beside it");

    const l = try listOf(m, .{});
    const c = find(l, "alias/git~1").?;
    try testing.expect(c.hidden != null and c.hidden.?.why == null);
}

test "list: a nested repository that is itself a mount point is reported as another filesystem" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    _ = try patterns.createStore(a, m.ctx.layout);
    try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path("vend") });
    try m.write("vend/f", "on another filesystem");
    other_filesystem_for_test = "vend";
    defer other_filesystem_for_test = null;
    const l = try listOf(m, .{ .deep_nested = true });
    try testing.expectEqual(@as(usize, 1), l.other_filesystems.len);
    try testing.expectEqualStrings("vend", l.other_filesystems[0]);
}

test "list: a mount point inside a nested repository, or inside its .git, is reported as another filesystem" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try harness.World.init(a, &sb, 1);
    const m = w.m(0);
    _ = try patterns.createStore(a, m.ctx.layout);
    try testutil.runGit(&sb, null, &.{ "init", "-q", try m.path("vend") });
    try m.write("vend/mnt/f", "on another filesystem");
    for ([_][]const u8{ "vend/mnt", "vend/.git/objects" }) |mount| {
        other_filesystem_for_test = mount;
        defer other_filesystem_for_test = null;
        const l = try listOf(m, .{ .deep_nested = true });
        try testing.expectEqual(@as(usize, 1), l.other_filesystems.len);
        try testing.expectEqualStrings(mount, l.other_filesystems[0]);
        try testing.expectEqual(@as(usize, 1), l.nested.len);
    }
}
