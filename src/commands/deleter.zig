//! The kept-file steps of every command that deletes a clone or a working
//! tree (`repo remove --clone`, `worktree -r`, `project archive --prune`):
//! `prepare` reconciles and lists what the gates weigh (candidates, nested
//! repositories, unsettled states, uncommitted changes, and git state no
//! remote holds, of submodules and of the main clone deleted whole); once
//! the command has confirmed, `Prepared.clear` weighs them again, sets
//! aside every candidate, uncommitted change, and unsettled local content,
//! and unlinks every holt link, so the delete that follows never reaches
//! `kept/` and never destroys an only copy that is not reported. The
//! clone's and the key's locks are held from `prepare` until
//! `Prepared.release`.

const std = @import("std");
const builtin = @import("builtin");
const app = @import("../app.zig");
const kept = @import("../kept.zig");
const kept_ctx = @import("../kept/ctx.zig");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const remote_url = @import("../remote_url.zig");
const ui = @import("../ui.zig");
const util = @import("kept_util.zig");
const kept_hints = @import("kept_hints.zig");
const kept_hooks = @import("kept_hooks.zig");
const doctor_cmd = @import("doctor.zig");

const io = fsutil.io;
const candidates = kept.candidates;
const reconcile = kept.reconcile;

/// What the command deletes.
pub const Scope = enum {
    /// The whole clone: every working tree of it counts.
    clone,
    /// One linked working tree: only what is in it counts.
    worktree,
};

/// Lets the user settle the gates before a deleter refuses. Called with the
/// locks `prepare` holds (null when there is no store to lock), for the
/// working tree at `path`; `prepare` then reconciles and lists again.
pub const Review = *const fn (ctx: *app.Ctx, kctx: kept.Ctx, index: *const kept.store.KeyIndex, path: []const u8, held: ?kept.Held) anyerror!void;

pub const Options = struct {
    /// Offered when the gates would refuse and `interactive` is set.
    review: ?Review = null,
    /// A terminal is attached and the command was not told `--yes`.
    interactive: bool = false,
    /// What the remotes told an earlier weighing of the run, taken as the
    /// first weighing's answers; null asks them.
    answers: ?*Answers = null,
    /// The command weighs many clones (`archive --prune`): no `asking`
    /// line is printed, and `Prepared.reasons` leaves out each URL a host
    /// skipped earlier in the run kept from being asked, which the command
    /// names once per host (`Prepared.skippedHosts`).
    many: bool = false,
};

pub const Cand = struct { tree: []const u8, cand: candidates.Candidate };
pub const NestedAt = struct { tree: []const u8, nested: candidates.Nested };
pub const Unsettled = struct { tree: []const u8, item: reconcile.Item };

/// A change `git status` shows in a working tree deleted or one of its
/// initialized submodules: an untracked path git does not ignore, or a
/// tracked path whose working-tree content differs from HEAD.
pub const Dirty = struct {
    tree: []const u8,
    /// Relative to `tree`, `/`-joined.
    rel: []const u8,
    /// The repository git shows it in: `tree`, or a submodule of it.
    repo: []const u8,
    /// `rel` relative to `repo`, as git names it there.
    in_repo: []const u8 = "",
    /// The index stages a version of the path that neither HEAD nor the
    /// working tree holds.
    staged: bool = false,
};

/// Git state of one repository that deleting it destroys and no remote
/// holds.
pub const Risk = struct {
    /// `ahead`: a branch whose commits no remote holds (`name` the branch).
    /// `ref_unheld`: another ref to a commit no remote holds, or a
    /// per-worktree one of a linked working tree (`worktree`).
    /// `object_unheld`: a ref naming an object that is not a commit, which
    /// no remote lists. `remote_refs`: the refs under
    /// `refs/remotes/<remote>/` and `refs/prefetch/remotes/<remote>/` of one
    /// remote (`name`) holding commits no remote holds (`refs`), pushed
    /// by one command (`pushes`). `head_unheld`: a HEAD whose commit
    /// (`name`) no ref and no remote holds. `unasked`: `remote` could not
    /// be asked at `url`, one for each such push URL, and `refs` are what
    /// the other risks would name but for it. `local_remote`: `remote`,
    /// whose push URLs all name paths on this machine (`here`), holds
    /// nothing, and no remote survives to hold the refs the other risks
    /// name.
    what: enum { stashes, ahead, ref_unheld, object_unheld, remote_refs, unasked, note, no_target, head_unheld, unreadable },
    /// The branch, for `ahead`; the full ref name, for
    /// `ref_unheld` and `object_unheld`; the remote, for `remote_refs`; the
    /// commit, for `head_unheld`.
    name: []const u8 = "",
    /// What a push names as its source: the full ref name, or, for a
    /// per-worktree ref or a HEAD, the object id.
    src: ?[]const u8 = null,
    /// For a per-worktree ref (`ref_unheld`, `object_unheld`) or a HEAD
    /// (`head_unheld`) of a linked working tree: that working tree's name
    /// (`worktreeName`).
    worktree: ?[]const u8 = null,
    /// Git's type of the object the ref names, for `object_unheld`.
    kind: []const u8 = "",
    /// The target (`Remotes.target`) a push of the ref goes to, when the
    /// repository has one; for `unasked`, the remote that could not be
    /// asked.
    remote: ?[]const u8 = null,
    /// The full ref of `remote` a push of the ref goes to (`destination`).
    dst: ?[]const u8 = null,
    /// For `remote_refs`: each source and destination the push names, one
    /// per distinct object.
    pushes: []const [2][]const u8 = &.{},
    /// For `worktree -r`: the ref the command settling it creates in the
    /// repository, which survives the removal, instead of a push.
    keep: ?[]const u8 = null,
    /// Every counting URL of the repository answered this weighing, so the
    /// line says "no remote has" rather than "no remote that answered has".
    answered: bool = true,
    /// For `unasked`: the push URL that could not be asked, why, as holt
    /// names it (`Unanswered`), the full names of the refs it could not
    /// confirm, the `pushurl` value the URL was read from when
    /// `UrlSource.named` names it, and, when the URL was not asked since its host gave no
    /// answer earlier in the command run, that host.
    url: []const u8 = "",
    why: []const u8 = "",
    refs: []const []const u8 = &.{},
    value: ?Configured = null,
    silent_host: ?[]const u8 = null,
    /// For `unasked`: the class of why (`Class`), the values the URL was
    /// read from and whether they are `pushurl` ones, whether they map one
    /// for one onto the push URLs, and whether the target's other push
    /// URLs all answered (`Unasked`).
    class: Class = .transient,
    values: []const Configured = &.{},
    pushurl: bool = false,
    mapped: bool = false,
    others_answered: bool = false,
    /// For `unasked`: the other push URLs of `remote` of the same skip key
    /// (`skipKey`) that did not answer for a reason of the same class,
    /// holding back the same refs, named on the same line
    /// (`mergeUnasked`).
    more_urls: []const []const u8 = &.{},
    /// For `note`: each URL that did not answer, of no target, with its
    /// remote and why.
    notes: []const Unasked = &.{},
    /// For `no_target`: every remote, none a push target (`Remotes.all_gone`),
    /// and the name `git remote add` would give a new one (`freeRemote`).
    gone: []const GoneRemote = &.{},
    add_name: []const u8 = "origin",
};

/// A remote that holds nothing, and why.
pub const GoneRemote = struct {
    name: []const u8 = "",
    why: enum {
        /// Every push URL names a path on this machine (`onThisMachine`):
        /// what is there is no copy another machine holds.
        local,
        /// Neither `remote.<name>.url` nor `remote.<name>.pushurl` holds a
        /// URL, or git reads one as empty.
        no_url,
        /// git cannot tell its push URLs.
        unreadable,
        /// A push URL takes a transport holt never asks (`counts`): a
        /// remote helper, or a scheme other than ssh, git, http and https.
        unsupported,
        /// A push URL can be read two ways (`remote_url.Url.ambiguous`).
        ambiguous,
        /// `remote.<name>.mirror` is set: a push to it mirrors every ref.
        mirror,
        /// Some push URLs count and some do not, so a push to the remote
        /// reaches a destination holt cannot verify.
        mixed,
    },
    /// The URL was read from `remote.<name>.pushurl`, not
    /// `remote.<name>.url`.
    push: bool = false,
    /// The configured value the URL was read from, when `UrlSource.named`
    /// names it.
    value: ?Configured = null,
    /// For `local`: every URL of it on this machine, each once, its fetch
    /// URLs first unless `push_only`, then its push URLs, each with the
    /// configured value `UrlSource.named` names for it, if any.
    urls: []const []const u8 = &.{},
    values: []const ?Configured = &.{},
    /// For `local`: a fetch URL is on another machine; only its push URLs
    /// are on this one.
    push_only: bool = false,
    /// For `local` with `push`: the files outside the repository holding
    /// its `pushurl` values, each once, and whether its own `config`, and
    /// its own `config.worktree`, holds one too.
    push_files: []const []const u8 = &.{},
    push_own: bool = false,
    push_worktree: bool = false,
    /// The edit its clause's command makes (removing its `pushurl`
    /// values, or its empty values) leaves push URLs that all count and
    /// all answered this weighing, so the command needs no `pushurl` added.
    edit_alone: bool = false,
    /// For `local` with `push`: its `pushurl` values.
    pushurls: []const Configured = &.{},
    /// For `no_url`: git lists an empty URL (git before 2.46), and each
    /// empty value of its `url` and `pushurl` keys, with the key.
    lists_empty: bool = false,
    empties: []const [2][]const u8 = &.{},
    empty_values: []const Configured = &.{},
    /// For `unsupported`: the transport it is reached through; for
    /// `ambiguous`: the URL, as holt shows it.
    transport: []const u8 = "",
    shown: []const u8 = "",
};

/// A risk of the repository at `repo`; `git_dir_only` for a git directory
/// whose `core.worktree` names no directory, which a command reaches with
/// `git --git-dir <repo> --work-tree <repo>`.
pub const RiskAt = struct { repo: []const u8, risk: Risk, git_dir_only: bool = false };

/// What the gates weigh, for the working trees being deleted.
pub const Found = struct {
    candidates: []const Cand = &.{},
    nested: []const NestedAt = &.{},
    /// Unsettled reconcile items not already reported as a candidate or a
    /// nested repository.
    unsettled: []const Unsettled = &.{},
    /// Uncommitted changes not already reported as a candidate or a nested
    /// repository.
    dirty: []const Dirty = &.{},
    /// Git state no remote holds (`gitRisks`): of each initialized
    /// submodule, of the main clone for a clone deleted whole, and, for a
    /// working tree deleted alone, commits only its HEAD holds.
    git: []const RiskAt = &.{},
    /// Why reconcile could not evaluate the working tree, when it could not
    /// and the clone has holt's block: a clone holt never linked in has
    /// nothing a stop leaves unsettled.
    stop: reconcile.Stop = .none,
    /// Working trees and submodules git could not list, so what they hold
    /// is unknown.
    unlisted: []const []const u8 = &.{},
    /// The operations git has in progress in the git directories deleted
    /// (`inProgress`).
    ops: []const InProgress = &.{},

    /// Whether the gates refuse the delete.
    pub fn blocked(f: Found) bool {
        return f.candidates.len + f.nested.len + f.unsettled.len + f.dirty.len + f.git.len + f.unlisted.len + f.ops.len > 0 or f.stop != .none;
    }
};

pub const Outcome = union(enum) {
    ready: Prepared,
    /// Nothing may be deleted, even with `--force`; the reason reads after
    /// the path it is about.
    refused: []const u8,
};

/// Whether `Prepared.clear` asks the remotes again.
pub const Weigh = enum {
    /// No prompt waited on a person since `prepare`: what the remotes told
    /// it still stands, and no URL is asked again.
    reuse,
    /// A prompt waited on a person since `prepare`: each URL is asked
    /// again, so what changed on a remote meanwhile counts.
    fresh,
};

/// How `Prepared.clear` ended.
pub const Cleared = enum {
    /// Everything is set aside and unlinked: the caller may delete.
    done,
    /// Weighed again, the gates refuse (`Prepared.printBlocked`); nothing
    /// was set aside or unlinked.
    blocked,
    /// Something could not be weighed, set aside, or unlinked, and why was
    /// printed: the caller must not delete.
    failed,
};

pub const Prepared = struct {
    kctx: kept.Ctx,
    path: []const u8,
    scope: Scope,
    /// `kept/` exists and can be read.
    store_ready: bool,
    /// Null for a directory git cannot read as a repository.
    c: ?kept.clone.Clone = null,
    /// The key aside entries are filed under: the clone's resolved key.
    key: ?[]const u8 = null,
    /// The keys whose links are holt's.
    chain: []const []const u8 = &.{},
    /// The synced roots holt's links may lie under (`kept.store.syncedRoots`).
    roots: []const []const u8 = &.{},
    /// The working trees deleted, as real paths.
    trees: []const []const u8 = &.{},
    index: kept.store.KeyIndex = .{ .keys = &.{}, .successors = .empty, .bad = &.{} },
    clone_lock: ?kept.Lock = null,
    key_locks: ?kept_ctx.Pair = null,
    /// The locks reconcile runs under (the resolved key's) and auto-keep
    /// runs under (the clone's own key's).
    held_reconcile: ?kept.Held = null,
    held_keep: ?kept.Held = null,
    found: Found = .{},
    auto_kept: []const candidates.AutoKept = &.{},
    /// The `kept automatically` lines already printed, so weighing again
    /// never repeats one.
    shown_auto: std.ArrayList([]const u8) = .empty,
    /// What the remotes told the last weighing, which `clear` reuses with
    /// `Weigh.reuse`; null before any.
    answers: ?*Answers = null,
    /// The checked-out submodules of the working trees deleted, as the last
    /// weighing listed them.
    subs: []const []const u8 = &.{},
    /// The refs, HEADs and git directories the weighing of `clear` saw
    /// (`gitState`), which `unchanged` reads again; null when it could not
    /// read them.
    weighed: ?[]const u8 = null,
    /// `Options.many`.
    many: bool = false,
    /// What this run set aside in an aside entry, holt's links recorded
    /// by their target included, each with where the entry holds it.
    set_aside: std.ArrayList(SetAside) = .empty,
    /// holt's links this run removed with no store to record them in.
    unlinked: std.ArrayList([]const u8) = .empty,

    /// A path set aside, and where its entry holds it, below `kept/`.
    pub const SetAside = struct { path: []const u8, held: []const u8 };

    fn noteAside(p: *Prepared, a: std.mem.Allocator, path: []const u8, held: []const u8) !void {
        for (p.set_aside.items) |x| if (std.mem.eql(u8, x.path, path) and std.mem.eql(u8, x.held, held)) return;
        try p.set_aside.append(a, .{ .path = path, .held = held });
    }

    /// What this run set aside and unlinked, as `; set aside: <path>
    /// (kept/<held>), ...` and `; holt's links removed: <path>, ...`;
    /// empty when it did neither.
    pub fn asideNote(p: *const Prepared, ctx: *app.Ctx) ![]const u8 {
        const a = ctx.alloc;
        var out: std.ArrayList(u8) = .empty;
        for (p.set_aside.items, 0..) |x, i| try out.print(a, "{s}{s} (kept/{s})", .{ if (i == 0) "; set aside: " else ", ", try show(ctx, x.path), x.held });
        for (p.unlinked.items, 0..) |path, i| try out.print(a, "{s}{s}", .{ if (i == 0) "; holt's links removed: " else ", ", try show(ctx, path) });
        return out.items;
    }

    /// How a line saying the delete stopped ends: `nothing was deleted`
    /// when this run set nothing aside and removed none of holt's links;
    /// else that the clone or the worktree was kept, then `asideNote`.
    pub fn stopNote(p: *const Prepared, ctx: *app.Ctx) ![]const u8 {
        const note = try p.asideNote(ctx);
        if (note.len == 0) return "nothing was deleted";
        return std.mem.concat(ctx.alloc, u8, &.{ if (p.scope == .clone) "the clone was kept" else "the worktree was kept", note });
    }

    /// Releases every lock `prepare` took.
    pub fn release(p: *Prepared) void {
        if (p.key_locks) |l| l.release();
        p.key_locks = null;
        if (p.clone_lock) |l| l.release();
        p.clone_lock = null;
    }

    /// Called right before the delete. On Windows a file held open cannot
    /// be deleted, so the clone's lock, which lives inside a clone being
    /// deleted whole, is released first there.
    pub fn beforeDelete(p: *Prepared) void {
        if (builtin.os.tag != .windows or p.scope != .clone) return;
        if (p.clone_lock) |l| l.release();
        p.clone_lock = null;
    }

    /// Reconciles and lists again under the locks `prepare` holds, asking
    /// the remotes again with `Weigh.fresh`, else taking what they told
    /// `prepare`; unless `force`, returns `blocked` when the gates now
    /// refuse. Then sets
    /// aside every candidate, uncommitted change, and unsettled local
    /// content in the working trees deleted (a symlink by its target),
    /// unlinks every holt link at the block's paths and the kept paths
    /// (parents checked without following links), and lists the nested
    /// repositories, the operations in progress, the git state, and,
    /// without a store, the content the delete destroys. A partial aside may leave out only a nested
    /// repository the gates report. Returns `failed`, having printed why,
    /// when anything could not be weighed, set aside, or unlinked.
    pub fn clear(p: *Prepared, ctx: *app.Ctx, force: bool, weigh: Weigh) !Cleared {
        const a = ctx.alloc;
        if (p.c != null) {
            if (p.store_ready) p.index = try kept.store.loadIndex(a, p.kctx.layout);
            if (!force) p.weighed = try p.gitState(a);
            if (try evaluate(ctx, p, if (weigh == .reuse) p.answers else null)) |why| {
                try ctx.err.print("holt: {s}: {s}; {s}\n", .{ try show(ctx, p.path), why, try p.stopNote(ctx) });
                return .failed;
            }
            if (!force and p.found.blocked()) return .blocked;
        }
        var ok = true;
        if (!p.store_ready) {
            for (p.found.candidates) |c| try ctx.out.print("deleting (kept files are not set up): {s}\n", .{try show(ctx, try fsutil.joinSlashy(a, c.tree, c.cand.rel))});
            for (p.found.dirty) |d| try ctx.out.print("deleting (kept files are not set up): {s}\n", .{try show(ctx, try fsutil.joinSlashy(a, d.tree, d.rel))});
        } else {
            for (p.found.candidates) |c| {
                if (!try p.asideCandidate(ctx, c)) ok = false;
            }
            for (p.found.dirty) |d| {
                if (!try p.asidePath(ctx, d.tree, d.rel)) ok = false;
                if (d.staged and !try p.asideStaged(ctx, d)) ok = false;
            }
            for (p.found.unsettled) |u| {
                if (!try p.asideItem(ctx, u)) ok = false;
            }
            for (p.found.unlisted) |t| {
                try ctx.err.print("holt: cannot set aside what {s} holds: git could not list it (run: git -C {s} status)\n", .{ try show(ctx, t), try q(ctx, t) });
                ok = false;
            }
            if (p.found.stop != .none and p.key == null) {
                try ctx.err.print("holt: cannot set aside what {s} holds: it has no key in the kept store ({s})\n", .{ try show(ctx, p.path), @tagName(p.found.stop) });
                ok = false;
            }
        }
        if (!ok) {
            try ctx.err.print("holt: {s}\n", .{try p.stopNote(ctx)});
            return .failed;
        }
        if (builtin.is_test and stop_for_test == .set_aside) return error.Interrupted;
        if (!try p.unlink(ctx)) return .failed;
        if (builtin.is_test and stop_for_test == .unlinked) return error.Interrupted;
        var asker = if (p.answers) |ans| try Asker.reusing(ctx, ans) else try Asker.of(ctx);
        if (p.many) asker.terminal = false;
        for (p.found.nested) |n| try printNestedDeleted(ctx, asker, try fsutil.joinSlashy(a, n.tree, n.nested.repo), n.nested.valid);
        for (p.found.unsettled) |u| if (u.item.outcome == .nested_repository) {
            try printNestedDeleted(ctx, asker, try fsutil.joinSlashy(a, u.tree, u.item.rel), true);
        };
        for (p.found.ops) |x| try ctx.out.print("deleting {s}\n", .{try inProgressLost(ctx, x)});
        for (p.found.git) |r| if (r.risk.what != .note) try ctx.out.print("deleting {s}\n", .{try lostPhrase(ctx, r)});
        if (p.scope == .clone) if (p.c) |c| try printUnkept(ctx, c.common_dir);
        return .done;
    }

    /// Whether the refs, HEADs and git directories `clear` weighed are as
    /// they were (`gitState`), read again right before the delete, which
    /// the caller runs only when this returns true, else saying so
    /// (`changedWhy`). True with `--force`, when `clear` weighed nothing,
    /// and for a directory git could not read as a repository.
    pub fn unchanged(p: *Prepared, ctx: *app.Ctx, force: bool) !bool {
        if (force or p.c == null) return true;
        if (builtin.is_test) if (before_reread_for_test) |seam| seam();
        const now = try p.gitState(ctx.alloc);
        if (p.weighed) |before| if (now) |after| if (std.mem.eql(u8, before, after)) return true;
        return false;
    }

    /// Why the delete stopped when `unchanged` is false, naming what was
    /// kept (`kept_what`: the clone, or the worktree), then what was set
    /// aside and unlinked (`asideNote`).
    pub fn changedWhy(p: *const Prepared, ctx: *app.Ctx, kept_what: []const u8) ![]const u8 {
        return std.fmt.allocPrint(ctx.alloc, "{s} changed while it was being weighed (a ref or HEAD moved, or git could not read them again); {s} was kept{s}", .{ try show(ctx, p.path), kept_what, try p.asideNote(ctx) });
    }

    /// The refs and HEADs of every git directory the delete removes, and
    /// which of those directories exist, as text two reads of the same
    /// state give alike; null when git cannot read them. For a clone
    /// deleted whole: every ref of its common directory (`refs/stash`
    /// included), every per-worktree ref and HEAD of each working tree,
    /// and its worktree records; for one working tree: every ref, those of
    /// the other working trees included, and its own HEAD. For either,
    /// the same of each submodule git directory deleted with it.
    fn gitState(p: *const Prepared, a: std.mem.Allocator) !?[]const u8 {
        const c = p.c.?;
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        const state = inventoryAt(a, .{ .repo = if (p.scope == .clone) c.main else c.worktree }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        const own = try state.current();
        try writeState(w, state, if (p.scope == .clone) null else own);
        const roots = try moduleRoots(a, c, p.scope);
        const found = try moduleDirs(a, roots);
        if (found.unreadable.len > 0) return null;
        var dirs: std.ArrayList([]const u8) = .empty;
        for (found.dirs) |d| try dirs.append(a, try fsutil.realPathOrSelf(a, d));
        for (try weighedDirs(a, p.subs)) |d| if (!kept.paths.contains(dirs.items, d)) try dirs.append(a, d);
        std.mem.sort([]const u8, dirs.items, {}, kept.paths.lessThan);
        for (dirs.items) |d| {
            try w.print("module {s}\n", .{d});
            const sub = inventoryAt(a, .{ .repo = d, .git_dir = d }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return null,
            };
            try writeState(w, sub, null);
        }
        return out.written();
    }

    fn asideCandidate(p: *Prepared, ctx: *app.Ctx, c: Cand) !bool {
        const a = ctx.alloc;
        const path = try fsutil.joinSlashy(a, c.tree, c.cand.rel);
        if (c.cand.hidden) |h| if (h.why) |why| switch (why) {
            .nested_repository => if (p.isNested(c.tree, c.cand.rel)) return true,
            .not_copyable => if (try kept.content.entryAt(path) == .symlink) return p.asidePath(ctx, c.tree, c.cand.rel),
            else => {},
        };
        if (c.cand.hidden) |h| if (h.why) |why| {
            try ctx.err.print("holt: cannot set aside {s}: {s}\n", .{ try show(ctx, path), describeWhy(why) });
            return false;
        };
        return p.asidePath(ctx, c.tree, c.cand.rel);
    }

    fn asideItem(p: *Prepared, ctx: *app.Ctx, u: Unsettled) !bool {
        const a = ctx.alloc;
        const item = u.item;
        if (item.outcome == .nested_repository) return true;
        if (std.mem.eql(u8, item.rel, ".") or !kept.paths.contained(item.rel)) {
            try ctx.err.print("holt: cannot set aside what {s} holds: {s}\n", .{ try show(ctx, u.tree), @tagName(item.outcome) });
            return false;
        }
        if (item.entry != null and item.skipped.len == 0) return true;
        if (!try kept.link.parentsReal(a, u.tree, item.rel)) {
            try ctx.err.print("holt: cannot set aside {s}: a parent directory is a link\n", .{try show(ctx, try fsutil.joinSlashy(a, u.tree, item.rel))});
            return false;
        }
        return p.asidePath(ctx, u.tree, item.rel);
    }

    /// Whether `rel` of the working tree `tree` is a nested repository the
    /// gates report, found by git's own `.git` rule.
    fn isNested(p: *const Prepared, tree: []const u8, rel: []const u8) bool {
        for (p.found.nested) |n| {
            if (std.mem.eql(u8, n.tree, tree) and std.mem.eql(u8, n.nested.repo, rel)) return true;
        }
        for (p.found.unsettled) |u| {
            if (u.item.outcome == .nested_repository and std.mem.eql(u8, u.tree, tree) and std.mem.eql(u8, u.item.rel, rel)) return true;
        }
        return false;
    }

    /// Sets aside the content at `rel` of the working tree `tree`, as far
    /// as it can be copied, a symlink by its target unless it is holt's
    /// link at a path `unlink` removes and records; only a nested
    /// repository the gates report may be left out.
    fn asidePath(p: *Prepared, ctx: *app.Ctx, tree: []const u8, rel: []const u8) !bool {
        const a = ctx.alloc;
        const path = try fsutil.joinSlashy(a, tree, rel);
        const shown = try show(ctx, path);
        const entry = try kept.content.entryAt(path);
        switch (entry) {
            .absent => return true,
            .file, .dir, .symlink => {},
            .other => {
                try ctx.err.print("holt: cannot set aside {s}: a special file (move it out of the working tree first)\n", .{shown});
                return false;
            },
        }
        if (entry == .dir and p.isNested(tree, rel)) return true;
        const key = p.key orelse {
            try ctx.err.print("holt: cannot set aside {s}: the clone has no key in the kept store\n", .{shown});
            return false;
        };
        const c = p.c.?;
        if (entry == .symlink) {
            const raw = (try kept.content.readLink(a, path)) orelse return true;
            if (try p.unlinks(a, path, raw, rel)) return true;
            const e = kept.aside.recordLink(a, p.kctx.layout, p.kctx.machine_id, key, rel, path, .deleting) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try ctx.err.print("holt: cannot record the link {s}: {s}\n", .{ shown, @errorName(err) });
                    return false;
                },
            };
            try ctx.out.print("link recorded {s} -> {s} (kept/.holt-aside/{s})\n", .{ shown, raw, e.stamp });
            try p.noteAside(a, path, try std.fmt.allocPrint(a, ".holt-aside/{s}", .{e.stamp}));
            return true;
        }
        const e = kept.aside.ensureAside(a, p.kctx.layout, c.common_dir, p.kctx.machine_id, key, rel, path, .deleting, .{ .partial = .{ .ignore_case = try kept.clone.ignoresCase(a, tree) } }) catch |err| switch (err) {
            error.OutOfMemory, error.Interrupted => return err,
            error.NestedRepository => {
                try ctx.err.print("holt: cannot set aside {s}: {s}\n", .{ shown, describeSkip(.nested_repository) });
                return false;
            },
            else => {
                try ctx.err.print("holt: cannot set aside {s}: {s}\n", .{ shown, @errorName(err) });
                return false;
            },
        };
        var whole = true;
        for (e.skipped) |s| {
            if (s.why == .nested_repository and p.isNested(tree, s.path)) continue;
            if (s.why == .symlink and recorded(e.links, s.path)) continue;
            try ctx.err.print("holt: cannot set aside {s}: {s}\n", .{ try show(ctx, try fsutil.joinSlashy(a, tree, s.path)), describeSkip(s.why) });
            whole = false;
        }
        if (!whole) return false;
        try ctx.out.print("set aside {s} (kept/.holt-aside/{s})\n", .{ shown, e.stamp });
        try p.noteAside(a, path, try std.fmt.allocPrint(a, ".holt-aside/{s}", .{e.stamp}));
        for (e.links) |l| try ctx.out.print("link recorded {s} -> {s}\n", .{ try show(ctx, try fsutil.joinSlashy(a, tree, l.path)), l.target });
        return true;
    }

    /// Sets aside the version of `d` git's index stages, which neither HEAD
    /// nor the working tree holds (`kept.aside.setAsideStaged`), naming the
    /// entry.
    fn asideStaged(p: *Prepared, ctx: *app.Ctx, d: Dirty) !bool {
        const a = ctx.alloc;
        const shown = try show(ctx, try fsutil.joinSlashy(a, d.tree, d.rel));
        const key = p.key orelse {
            try ctx.err.print("holt: cannot set aside the staged version of {s}: the clone has no key in the kept store\n", .{shown});
            return false;
        };
        const blob = try (At{ .repo = d.repo }).run(a, &.{ "cat-file", "blob", try std.mem.concat(a, u8, &.{ ":", d.in_repo }) });
        if (blob.status != 0) {
            try ctx.err.print("holt: cannot set aside the staged version of {s}: git cannot read it (run: git -C {s} status)\n", .{ shown, try q(ctx, d.repo) });
            return false;
        }
        const scratch = try kept.sweep.scratchDir(a, p.kctx);
        try fsutil.ensureDir(scratch);
        const suffix = kept.content.randomSuffix();
        const tmp = try std.fs.path.join(a, &.{ scratch, try std.mem.concat(a, u8, &.{ "staged-", &suffix }) });
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = tmp, .data = blob.stdout });
        defer fsutil.removePath(tmp) catch {};
        const e = kept.aside.setAsideStaged(a, p.kctx.layout, p.kctx.machine_id, key, d.rel, tmp, .deleting) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try ctx.err.print("holt: cannot set aside the staged version of {s}: {s}\n", .{ shown, @errorName(err) });
                return false;
            },
        };
        try ctx.out.print("set aside the staged version of {s} (kept/.holt-aside/{s}/index/{s})\n", .{ shown, e.stamp, try ui.printable(a, d.rel) });
        try p.noteAside(a, try fsutil.joinSlashy(a, d.tree, d.rel), try std.fmt.allocPrint(a, ".holt-aside/{s}/index/{s}", .{ e.stamp, try ui.printable(a, d.rel) }));
        return true;
    }

    /// The paths `unlink` removes holt's links at: the block's paths and
    /// temporaries and the kept paths, each with the kept path it belongs
    /// to (`owner`, the path itself but for a temporary).
    const LinkRels = struct { at: []const []const u8, owner: []const []const u8 };

    fn linkRels(p: *const Prepared, a: std.mem.Allocator) !LinkRels {
        const c = p.c.?;
        var rels: std.ArrayList([]const u8) = .empty;
        var temps: std.ArrayList([]const u8) = .empty;
        if (kept.block.read(a, c.common_dir)) |parsed| {
            try rels.appendSlice(a, parsed.rels);
            try temps.appendSlice(a, parsed.temps);
        } else |err| switch (err) {
            error.UnbalancedBlock => {
                const text = try kept.content.readSmall(a, try kept.block.excludePath(a, c.common_dir));
                const got = try kept.block.salvage(a, text);
                try rels.appendSlice(a, got.rels);
                try temps.appendSlice(a, got.temps);
            },
            else => return err,
        }
        if (p.store_ready) if (p.key) |k| {
            const ks = try kept.store.loadKeyState(a, p.kctx.layout, k);
            for (try ks.keptSet(a)) |r| if (!kept.paths.contains(rels.items, r)) try rels.append(a, r);
        };
        var at: std.ArrayList([]const u8) = .empty;
        var owner: std.ArrayList([]const u8) = .empty;
        for (rels.items) |rel| {
            if (!kept.paths.contained(rel)) continue;
            try at.append(a, rel);
            try owner.append(a, rel);
            const temp = try kept.paths.tempRel(a, rel);
            if (kept.paths.contains(temps.items, temp)) {
                try at.append(a, temp);
                try owner.append(a, rel);
            }
        }
        return .{ .at = at.items, .owner = owner.items };
    }

    /// Whether `unlink` removes, and records, the link at `path`, `rel` of
    /// a working tree deleted, whose target is `raw`: holt's link at one of
    /// `linkRels`'s paths. False when those cannot be read, so the caller
    /// records it.
    fn unlinks(p: *const Prepared, a: std.mem.Allocator, path: []const u8, raw: []const u8, rel: []const u8) !bool {
        const lr = p.linkRels(a) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return false,
        };
        for (lr.at, lr.owner) |r, owner| {
            if (std.mem.eql(u8, r, rel)) return kept.link.isHolt(a, path, raw, p.chain, p.roots, owner);
        }
        return false;
    }

    /// Removes holt's links (`kept.link.isHolt`) at `linkRels`'s paths, in
    /// every working tree deleted, each first recorded by its target in an
    /// aside entry when there is a store to hold one.
    fn unlink(p: *Prepared, ctx: *app.Ctx) !bool {
        const a = ctx.alloc;
        const c = p.c orelse return true;
        const lr = p.linkRels(a) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try ctx.err.print("holt: cannot read the kept-file block of {s}: {s}; {s}\n", .{ try show(ctx, c.main), @errorName(err), try p.stopNote(ctx) });
                return false;
            },
        };
        for (p.trees) |tree| {
            for (lr.at, lr.owner) |rel, owner| {
                if (!try kept.link.parentsReal(a, tree, rel)) continue;
                const path = try fsutil.joinSlashy(a, tree, rel);
                if (try kept.content.entryAt(path) != .symlink) continue;
                const raw = (try kept.content.readLink(a, path)) orelse continue;
                if (!kept.link.isHolt(a, path, raw, p.chain, p.roots, owner)) continue;
                var held: ?[]const u8 = null;
                if (p.store_ready) if (p.key) |key| {
                    const e = kept.aside.recordLink(a, p.kctx.layout, p.kctx.machine_id, key, rel, path, .deleting) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => {
                            try ctx.err.print("holt: cannot record the link {s}: {s}; {s}\n", .{ try show(ctx, path), @errorName(err), try p.stopNote(ctx) });
                            return false;
                        },
                    };
                    held = try std.fmt.allocPrint(a, ".holt-aside/{s}", .{e.stamp});
                    try p.noteAside(a, path, held.?);
                };
                const removed = kept.content.removeLinkIf(a, path, raw) catch |err| {
                    try ctx.err.print("holt: cannot remove the kept-file link {s}: {s}; {s}\n", .{ try show(ctx, path), @errorName(err), try p.stopNote(ctx) });
                    return false;
                };
                if (removed and held == null) try p.unlinked.append(a, path);
            }
        }
        return true;
    }

    /// Prints why the gates refuse the delete of the working tree at
    /// `path`, each with the command that settles it, and, unless every
    /// line names `--force` already (`namesForce`), `force_cmd`, the
    /// command that deletes anyway.
    pub fn printBlocked(p: *const Prepared, ctx: *app.Ctx, force_cmd: []const u8) !void {
        const a = ctx.alloc;
        const f = p.found;
        try ctx.err.print("holt: refusing to delete {s} (--force sets what it can aside first):\n", .{try show(ctx, p.path)});
        for (f.candidates) |c| try ctx.err.print("  not kept: {s}\n", .{try show(ctx, try fsutil.joinSlashy(a, c.tree, c.cand.rel))});
        for (f.nested) |n| try ctx.err.print("  nested repository (--force deletes it): {s}\n", .{try show(ctx, try fsutil.joinSlashy(a, n.tree, n.nested.repo))});
        for (f.unsettled) |u| {
            const h = try p.hintFor(ctx, u);
            try ctx.err.print("  {s}: {s}\n", .{ try show(ctx, try kept_hints.placeOf(a, u.tree, u.item)), try kept_hints.render(a, h) });
        }
        for (f.unlisted) |t| try ctx.err.print("  could not be listed: {s}\n", .{try show(ctx, t)});
        for (f.dirty) |d| try ctx.err.print("  uncommitted changes: {s}\n", .{try show(ctx, try fsutil.joinSlashy(a, d.tree, d.rel))});
        for (f.ops) |x| try ctx.err.print("  {s}\n", .{try opLine(ctx, x, "--force")});
        for (f.git) |r| try ctx.err.print("  {s}\n", .{try riskLine(ctx, r, "--force")});
        if (f.stop != .none) {
            const h = try kept_hints.forStop(ctx, p.c.?.worktree, f.stop, p.key);
            try ctx.err.print("  {s}: kept files could not be evaluated: {s}\n", .{ try show(ctx, p.c.?.worktree), try kept_hints.render(a, h) });
        }
        if (f.candidates.len + f.nested.len + f.unlisted.len > 0) {
            try ctx.err.print("run: holt keep --review {s}\n", .{try q(ctx, p.path)});
        }
        var repos: std.ArrayList([]const u8) = .empty;
        for (f.dirty) |d| if (!kept.paths.contains(repos.items, d.repo)) try repos.append(a, d.repo);
        for (repos.items) |r| {
            const survives = p.scope == .worktree and std.mem.eql(u8, r, p.c.?.worktree);
            try ctx.err.print("run: git -C {s} {s}\n", .{ try q(ctx, r), if (survives) "stash push -u" else "status" });
        }
        if (!namesForce(f)) try ctx.err.print("or, to set aside what can be and delete the rest: {s}\n", .{force_cmd});
    }

    /// Whether every line `printBlocked` prints for `f` names `--force`
    /// already: a nested repository, and git state for which only a
    /// reconnect or `--force` settles (a URL that did not answer, no push
    /// target, git state that could not be read) or a note beside it.
    fn namesForce(f: Found) bool {
        if (f.candidates.len + f.unsettled.len + f.unlisted.len + f.dirty.len + f.ops.len > 0 or f.stop != .none) return false;
        for (f.git) |r| switch (r.risk.what) {
            .unasked, .no_target, .unreadable, .note => {},
            else => return false,
        };
        return true;
    }

    /// Why the gates refuse, one phrase per gate ending with the command
    /// that settles it, for the `not pruned <repo>` lines: every one of
    /// them, so settling what they name lets the delete through; a phrase
    /// naming how to delete anyway names `force_cmd`, and one settled by a
    /// reconnect or a verified host key names `then`, the command deleting
    /// the clone after (`riskLineThen`).
    pub fn reasons(p: *const Prepared, ctx: *app.Ctx, force_cmd: []const u8, then: []const u8) ![]const []const u8 {
        const a = ctx.alloc;
        const f = p.found;
        var out: std.ArrayList([]const u8) = .empty;
        if (f.candidates.len > 0) try out.append(a, try std.fmt.allocPrint(a, "{s} (run: holt keep --review {s})", .{ try doctor_cmd.counted(a, f.candidates.len, "file not kept", "files not kept"), try q(ctx, p.path) }));
        for (f.unsettled) |u| {
            const h = try p.hintFor(ctx, u);
            try out.append(a, try std.fmt.allocPrint(a, "a kept file unsettled, {s}: {s}", .{ try q(ctx, try kept_hints.placeOf(a, u.tree, u.item)), try kept_hints.render(a, h) }));
        }
        if (f.stop != .none) {
            const h = try kept_hints.forStop(ctx, p.c.?.worktree, f.stop, p.key);
            try out.append(a, try std.fmt.allocPrint(a, "its kept files could not be evaluated: {s}", .{try kept_hints.render(a, h)}));
        }
        for (f.nested) |n| {
            const at = try q(ctx, try fsutil.joinSlashy(a, n.tree, n.nested.repo));
            try out.append(a, try std.fmt.allocPrint(a, "nested repository {s} (run: holt repo adopt {s})", .{ at, at }));
        }
        var repos: std.ArrayList([]const u8) = .empty;
        for (f.dirty) |d| if (!kept.paths.contains(repos.items, d.repo)) try repos.append(a, d.repo);
        for (repos.items) |r| {
            var n: usize = 0;
            for (f.dirty) |d| if (std.mem.eql(u8, d.repo, r)) {
                n += 1;
            };
            try out.append(a, try std.fmt.allocPrint(a, "{s} in {s} (run: git -C {s} status)", .{ try doctor_cmd.counted(a, n, "uncommitted change", "uncommitted changes"), try show(ctx, r), try q(ctx, r) }));
        }
        for (f.ops) |x| try out.append(a, try opLine(ctx, x, force_cmd));
        for (f.git) |r| {
            if (p.many and skippedOf(r) != null) continue;
            if (p.many and r.risk.what == .note and !besideLine(f.git, r.repo)) continue;
            try out.append(a, try riskLineThen(ctx, r, force_cmd, then));
        }
        for (f.unlisted) |t| try out.append(a, try std.fmt.allocPrint(a, "git could not list what {s} holds (run: git -C {s} status)", .{ try show(ctx, t), try q(ctx, t) }));
        return out.items;
    }

    /// The hosts whose skip earlier in the run kept a URL of a line from
    /// being asked, each once with the class of that skip.
    pub fn skippedHosts(p: *const Prepared, a: std.mem.Allocator) ![]const Skipped {
        var out: std.ArrayList(Skipped) = .empty;
        for (p.found.git) |r| if (skippedOf(r)) |sk| {
            const seen = for (out.items) |x| {
                if (x.class == sk.class and std.mem.eql(u8, x.host, sk.host)) break true;
            } else false;
            if (!seen) try out.append(a, sk);
        };
        return out.items;
    }

    /// The hint every command gives for the unsettled item `u`.
    fn hintFor(p: *const Prepared, ctx: *app.Ctx, u: Unsettled) !kept_hints.Hint {
        return kept_hints.forItem(ctx, p.c.?.worktree, p.key, p.kctx.layout.synced_root, u.item);
    }

    /// Says where the deleted clone's kept files remain, when it has any,
    /// and how to release them.
    pub fn printKeptRemain(p: *const Prepared, ctx: *app.Ctx) !void {
        if (!p.store_ready) return;
        const own = (p.c orelse return).key orelse return;
        const a = ctx.alloc;
        const ks = try kept.store.loadKeyState(a, p.kctx.layout, own);
        if ((try ks.keptSet(a)).len == 0) return;
        try ctx.out.print("kept files remain at {s}; to release them: holt unkeep --repo {s}\n", .{ try show(ctx, try p.kctx.layout.keyDir(a, own)), try ui.shellQuote(a, own) });
    }
};

/// A host whose skip earlier in the run kept a URL from being asked, and
/// the class of that skip: `host_key` after a host key that was not
/// verified, else `transient`.
pub const Skipped = struct { host: []const u8, class: Class };

/// The skip that kept the URL of the line `r` from being asked, when one
/// did.
pub fn skippedOf(r: RiskAt) ?Skipped {
    if (r.risk.what != .unasked) return null;
    const host = r.risk.silent_host orelse return null;
    return .{ .host = host, .class = r.risk.class };
}

/// The clones a skipped host kept from being asked, by host and class
/// (`Skipped`), named once each after the last clone (`lines`).
pub const HeldBack = struct {
    hosts: std.ArrayList(Skipped) = .empty,
    clones: std.ArrayList(std.ArrayList([]const u8)) = .empty,

    /// Records that `sk` kept the clone named `clone` from being asked.
    pub fn add(h: *HeldBack, a: std.mem.Allocator, sk: Skipped, clone: []const u8) !void {
        const i = for (h.hosts.items, 0..) |x, n| {
            if (x.class == sk.class and std.mem.eql(u8, x.host, sk.host)) break n;
        } else blk: {
            try h.hosts.append(a, sk);
            try h.clones.append(a, .empty);
            break :blk h.hosts.items.len - 1;
        };
        if (!kept.paths.contains(h.clones.items[i].items, clone)) try h.clones.items[i].append(a, clone);
    }

    /// One line per host: `<host> did not answer, so <N> clones were
    /// <what>: <first 3>[, and <k> more]; reconnect and run again`, or, for
    /// a host whose key was not verified, `the host key of <host> was not
    /// verified, so ...; verify the host key of <host> and run again`, then
    /// `tail`; with `then`, the command deleting each once the way out is
    /// taken, `..., then delete each with: <then>` in place of `and run
    /// again`.
    pub fn lines(h: *const HeldBack, a: std.mem.Allocator, what: []const u8, then: ?[]const u8, tail: []const u8) ![]const []const u8 {
        const after: []const u8 = if (then) |cmd| try std.fmt.allocPrint(a, ", then delete each with: {s}", .{cmd}) else " and run again";
        var out: std.ArrayList([]const u8) = .empty;
        for (h.hosts.items, h.clones.items) |sk, clones| {
            const shown = clones.items[0..@min(clones.items.len, unasked_shown)];
            const more = if (clones.items.len > unasked_shown) try std.fmt.allocPrint(a, ", and {d} more", .{clones.items.len - unasked_shown}) else "";
            const count_words: []const u8 = if (clones.items.len == 1) "clone was" else "clones were";
            const line = switch (sk.class) {
                .host_key => try std.fmt.allocPrint(a, "the host key of {s} was not verified, so {d} {s} {s}: {s}{s}; verify the host key of {s}{s}{s}", .{ sk.host, clones.items.len, count_words, what, try std.mem.join(a, ", ", shown), more, sk.host, after, tail }),
                else => try std.fmt.allocPrint(a, "{s} did not answer, so {d} {s} {s}: {s}{s}; reconnect{s}{s}", .{ sk.host, clones.items.len, count_words, what, try std.mem.join(a, ", ", shown), more, after, tail }),
            };
            try out.append(a, line);
        }
        return out.items;
    }
};

/// Test seam: `Prepared.clear` stops with `Interrupted` at this point.
pub var stop_for_test: ?enum { set_aside, unlinked } = null;

/// Test seam: run by `Prepared.unchanged` before it reads the state again.
pub var before_reread_for_test: ?*const fn () void = null;

/// Writes `state` as `Prepared.gitState` compares it: each git directory
/// and ref, and each HEAD, or, with `only_head`, that working tree's HEAD
/// alone, its records left out.
fn writeState(w: *std.Io.Writer, state: Inventory, only_head: ?[]const u8) !void {
    if (only_head == null) for (state.dirs) |d| try w.print("dir {s}\n", .{d.id});
    for (state.refs) |r| try w.print("ref {s} {s} {s} {s}\n", .{ r.worktree orelse ".", r.ref, r.object, r.symref });
    for (state.heads) |h| {
        if (only_head) |id| if (!std.mem.eql(u8, id, h.worktree)) continue;
        try w.print("head {s} {s} {s}\n", .{ h.worktree, h.object orelse "-", h.target orelse "-" });
    }
}

fn q(ctx: *app.Ctx, path: []const u8) ![]const u8 {
    return util.q(ctx, path);
}

fn show(ctx: *app.Ctx, path: []const u8) ![]const u8 {
    return util.show(ctx, path);
}

fn recorded(links: []const kept.aside.Link, path: []const u8) bool {
    for (links) |l| if (std.mem.eql(u8, l.path, path)) return true;
    return false;
}

fn describeWhy(why: kept.sweep.Why) []const u8 {
    return switch (why) {
        .nested_repository => "a nested repository",
        .parent_not_dir => "a parent directory is a link",
        .dot_git => "a path git treats as .git",
        .not_copyable => "a special file (move it out of the working tree first)",
        .tree_unreadable => "its working tree cannot be read",
        .failed => "it could not be read",
    };
}

fn describeSkip(why: kept.content.Skip) []const u8 {
    return switch (why) {
        .symlink => "a symlink whose target could not be read",
        .not_regular => "a special file (move it out of the working tree first)",
        .online_only => "held online only (download it first)",
        .unreadable => "it cannot be read",
        .windows_name => "a name Windows cannot hold (rename it first)",
        .nested_repository => "a nested repository (move it out of the working tree first)",
    };
}

/// Names what deleting the clone whose common directory is `common_dir`
/// also loses, which holt neither keeps nor weighs: hooks other than git's
/// samples, and configuration keys outside the core, remote, branch, and
/// submodule sections and the `extensions.relativeworktrees` holt's
/// worktrees set.
fn printUnkept(ctx: *app.Ctx, common_dir: []const u8) !void {
    const a = ctx.alloc;
    const hooks = try std.fs.path.join(a, &.{ common_dir, "hooks" });
    var names: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.cwd().openDir(io(), hooks, .{ .iterate = true })) |opened| {
        var d = opened;
        defer d.close(io());
        var it = d.iterate();
        while (it.next(io()) catch null) |e| {
            if (std.mem.endsWith(u8, e.name, ".sample")) continue;
            try names.append(a, try a.dupe(u8, e.name));
        }
    } else |_| {}
    if (names.items.len > 0) {
        std.mem.sort([]const u8, names.items, {}, kept.paths.lessThan);
        try ctx.out.print("deleting custom hooks in {s}: {s}\n", .{ try show(ctx, hooks), try std.mem.join(a, ", ", names.items) });
    }
    const cfg = try std.fs.path.join(a, &.{ common_dir, "config" });
    const listed = try (At{ .repo = common_dir }).run(a, &.{ "config", "--file", cfg, "--name-only", "--list" });
    if (listed.status != 0) return;
    var keys: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, listed.stdout, "\r\n");
    while (it.next()) |name| {
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse continue;
        const section = name[0..dot];
        const clone_own = for ([_][]const u8{ "core", "remote", "branch", "submodule" }) |s| {
            if (std.ascii.eqlIgnoreCase(section, s)) break true;
        } else false;
        if (clone_own or std.ascii.eqlIgnoreCase(name, "extensions.relativeworktrees")) continue;
        if (!kept.paths.contains(keys.items, name)) try keys.append(a, name);
    }
    if (keys.items.len > 0) try ctx.out.print("deleting local git config in {s}: {s}\n", .{ try show(ctx, cfg), try std.mem.join(a, ", ", keys.items) });
}

/// Lists a nested repository the delete destroys, with the commits and
/// stash entries it holds that no remote has, when git can open it.
fn printNestedDeleted(ctx: *app.Ctx, asker: Asker, repo: []const u8, valid: bool) !void {
    try ctx.out.print("deleting nested repository {s}\n", .{try show(ctx, repo)});
    if (!valid) return;
    for (try gitRisks(asker, repo)) |r| {
        if (r.what != .note) try ctx.out.print("  with {s}\n", .{try lostPhrase(ctx, .{ .repo = repo, .risk = r })});
    }
}

/// Whether `risks` holds, for the repository `repo`, a line a note is
/// printed beside when the host skip is named once per host instead: a URL
/// that did not answer and was asked, or no push target.
pub fn besideLine(risks: []const RiskAt, repo: []const u8) bool {
    for (risks) |x| {
        if (!std.mem.eql(u8, x.repo, repo)) continue;
        if (x.risk.what == .no_target or (x.risk.what == .unasked and x.risk.silent_host == null)) return true;
    }
    return false;
}

/// `r` as a phrase naming what is lost and where.
pub fn describeRisk(ctx: *app.Ctx, r: RiskAt) ![]const u8 {
    const a = ctx.alloc;
    const at = try show(ctx, r.repo);
    const name = try ui.shellQuote(a, r.risk.name);
    const none: []const u8 = if (r.risk.answered) "no remote has" else "no remote that answered has";
    const what = try switch (r.risk.what) {
        .stashes => std.fmt.allocPrint(a, "stash entries of {s}", .{at}),
        .ahead => std.fmt.allocPrint(a, "commits of branch {s} {s}, in {s}", .{ name, none, at }),
        .ref_unheld => if (r.risk.worktree) |w|
            std.fmt.allocPrint(a, "commits only {s} of worktree {s} holds, {s}, in {s}", .{ name, try ui.shellQuote(a, w), none, at })
        else
            std.fmt.allocPrint(a, "commits only {s} holds, {s}, in {s}", .{ name, none, at }),
        .object_unheld => if (r.risk.worktree) |w|
            std.fmt.allocPrint(a, "the {s} only {s} of worktree {s} names, {s}, in {s}", .{ r.risk.kind, name, try ui.shellQuote(a, w), none, at })
        else
            std.fmt.allocPrint(a, "the {s} only {s} names, {s}, in {s}", .{ r.risk.kind, name, none, at }),
        .remote_refs => blk: {
            const refs = r.risk.refs;
            var shown: std.ArrayList([]const u8) = .empty;
            for (refs[0..@min(refs.len, unasked_shown)]) |ref| try shown.append(a, try ui.shellQuote(a, ref));
            const more = if (refs.len > unasked_shown) try std.fmt.allocPrint(a, ", and {d} more", .{refs.len - unasked_shown}) else "";
            break :blk std.fmt.allocPrint(a, "commits only {s} of remote {s} {s}, {s}, in {s}: {s}{s}", .{ try doctor_cmd.counted(a, refs.len, "ref", "refs"), name, if (refs.len == 1) "holds" else "hold", none, at, try std.mem.join(a, ", ", shown.items), more });
        },
        .unasked => blk: {
            const refs = r.risk.refs;
            var shown: std.ArrayList([]const u8) = .empty;
            for (refs[0..@min(refs.len, unasked_shown)]) |ref| try shown.append(a, try ui.shellQuote(a, ref));
            const more = if (refs.len > unasked_shown) try std.fmt.allocPrint(a, ", and {d} more", .{refs.len - unasked_shown}) else "";
            const held = try std.fmt.allocPrint(a, "{s} not confirmed held, in {s}: {s}{s}", .{ try doctor_cmd.counted(a, refs.len, "ref", "refs"), at, try std.mem.join(a, ", ", shown.items), more });
            const remote = try ui.shellQuote(a, r.risk.remote orelse "");
            var urls: std.ArrayList([]const u8) = .empty;
            try urls.append(a, try shownUrl(a, r.risk.url));
            for (r.risk.more_urls) |u| try urls.append(a, try shownUrl(a, u));
            break :blk std.fmt.allocPrint(a, "{s} (remote {s} could not be asked at {s}: {s})", .{ held, remote, try std.mem.join(a, ", ", urls.items), r.risk.why });
        },
        .note => blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            for (r.risk.notes) |n| try parts.append(a, try std.fmt.allocPrint(a, "remote {s} at {s} ({s})", .{ try ui.shellQuote(a, n.remote), try shownUrl(a, n.url), n.why.why }));
            break :blk std.fmt.allocPrint(a, "could not be asked, in {s}: {s}", .{ at, try std.mem.join(a, "; ", parts.items) });
        },
        .head_unheld => if (r.risk.worktree) |w|
            std.fmt.allocPrint(a, "commit {s}, which only the HEAD of worktree {s} holds and {s}, in {s}", .{ r.risk.name, try ui.shellQuote(a, w), none, at })
        else
            std.fmt.allocPrint(a, "commit {s}, which only the HEAD of {s} holds and {s}", .{ r.risk.name, at, none }),
        .unreadable => std.fmt.allocPrint(a, "git state of {s} could not be read", .{at}),
        .no_target => blk: {
            var clauses: std.ArrayList([]const u8) = .empty;
            for (r.risk.gone) |g| try clauses.append(a, (try clauseOf(ctx, r, g)).text);
            if (clauses.items.len == 0) try clauses.append(a, "it has no remote");
            break :blk std.fmt.allocPrint(a, "{s}; no remote counts as a copy: {s}", .{ try noTargetHead(ctx, r), try std.mem.join(a, "; ", clauses.items) });
        },
    };
    return what;
}

/// What `r` names as lost when the delete goes ahead: `describeRisk`, but,
/// for the no-target line, only the refs, not why no remote counts, and,
/// for git state that could not be read, that state.
pub fn lostPhrase(ctx: *app.Ctx, r: RiskAt) ![]const u8 {
    return switch (r.risk.what) {
        .no_target => noTargetHead(ctx, r),
        .unreadable => std.fmt.allocPrint(ctx.alloc, "the git state of {s}, which could not be read", .{try show(ctx, r.repo)}),
        else => describeRisk(ctx, r),
    };
}

/// The refs the no-target line names, as it names them.
fn noTargetHead(ctx: *app.Ctx, r: RiskAt) anyerror![]const u8 {
    const a = ctx.alloc;
    const refs = r.risk.refs;
    var shown: std.ArrayList([]const u8) = .empty;
    for (refs[0..@min(refs.len, unasked_shown)]) |ref| try shown.append(a, try ui.shellQuote(a, ref));
    const more = if (refs.len > unasked_shown) try std.fmt.allocPrint(a, ", and {d} more", .{refs.len - unasked_shown}) else "";
    return std.fmt.allocPrint(a, "{s} no remote on another machine {s}holds, in {s}: {s}{s}", .{ try doctor_cmd.counted(a, refs.len, "ref", "refs"), if (r.risk.answered) "" else "that answered ", try show(ctx, r.repo), try std.mem.join(a, ", ", shown.items), more });
}

/// `r` with how it is settled: `<describeRisk> (run: <cmd>)`; for a
/// remote that could not be asked, to reconnect and run again, replace or
/// remove that URL (`unaskedWay`), or delete anyway with `force_cmd`; for
/// the no-target line, what makes a remote count (`noTargetWay`), or
/// delete anyway with `force_cmd`; for git state that could not be read,
/// only `force_cmd`; `describeRisk` alone for the note and a risk no
/// command settles.
pub fn riskLine(ctx: *app.Ctx, r: RiskAt, force_cmd: []const u8) ![]const u8 {
    return riskLineThen(ctx, r, force_cmd, null);
}

/// `riskLine`, with `then`, when set, the command deleting the tree once
/// a reconnect or a verified host key settles a remote that could not be
/// asked: `reconnect, then delete it with: <then>` in place of `reconnect
/// and run again`, for a command that cannot be run again.
pub fn riskLineThen(ctx: *app.Ctx, r: RiskAt, force_cmd: []const u8, then: ?[]const u8) ![]const u8 {
    const a = ctx.alloc;
    const after: []const u8 = if (then) |c| try std.fmt.allocPrint(a, ", then delete it with: {s}", .{c}) else " and run again";
    const what = try describeRisk(ctx, r);
    const cmd = try settleRisk(ctx, r);
    if (r.risk.what == .no_target) {
        const way = try noTargetWay(ctx, r);
        const with: []const u8 = if (std.mem.indexOf(u8, way.cmd, "<url>") != null) ", with <url> a URL on another machine" else "";
        return std.fmt.allocPrint(a, "{s}; {s} (run: {s}{s}){s}, or {s} deletes {s}", .{ what, way.text, way.cmd, with, way.note, force_cmd, if (r.risk.refs.len == 1) "it" else "them" });
    }
    if (r.risk.what == .note) return what;
    if (r.risk.what == .unreadable) return std.fmt.allocPrint(a, "{s}; {s} deletes it", .{ what, force_cmd });
    if (r.risk.what == .unasked) {
        const them: []const u8 = if (r.risk.refs.len == 1) "it" else "them";
        const way = try unaskedWay(ctx, r);
        return switch (way) {
            .reconnect => std.fmt.allocPrint(a, "{s}; reconnect{s}, or {s} deletes {s}", .{ what, after, force_cmd, them }),
            .host_key => |host| std.fmt.allocPrint(a, "{s}; verify the host key of {s}{s}, or {s} deletes {s}", .{ what, host, after, force_cmd, them }),
            .remove => |cmd_| std.fmt.allocPrint(a, "{s}; {s} (run: {s}){s}, or {s} deletes {s}", .{ what, if (cmd_.edit) |key| try std.fmt.allocPrint(a, "edit {s} to remove that URL", .{try ui.shellQuote(a, key)}) else "remove that URL", cmd_.cmd, cmd_.note, force_cmd, them }),
            .replace => |cmd_| std.fmt.allocPrint(a, "{s}; {s} (run: {s}, with <url> a URL on another machine){s}, or {s} deletes {s}", .{ what, if (cmd_.edit) |key| try std.fmt.allocPrint(a, "edit {s} to replace this push URL", .{try ui.shellQuote(a, key)}) else "replace this push URL", cmd_.cmd, cmd_.note, force_cmd, them }),
        };
    }
    if (cmd.len == 0) return what;
    return std.fmt.allocPrint(a, "{s} (run: {s})", .{ what, cmd });
}

/// How a line about a push URL that did not answer settles it: only the
/// ways out, for a reason of the transient class (`reconnect`) or a host
/// whose key was not verified, in this query or earlier in the run
/// (`host_key`, naming the host); for a
/// persistent one, removing the URL's values (`remove`) when the target's
/// other push URLs all answered, else replacing the push URL (`replace`):
/// removing its `pushurl` values, then adding a `pushurl`, or adding one
/// alone for a URL read from `url`.
const UnaskedWay = union(enum) { reconnect, host_key: []const u8, remove: Removal, replace: Removal };

fn unaskedWay(ctx: *app.Ctx, r: RiskAt) !UnaskedWay {
    const a = ctx.alloc;
    switch (r.risk.class) {
        .transient => return .reconnect,
        .host_key => return .{ .host_key = try shownHosts(a, r.risk) },
        .persistent => {},
    }
    const remote = r.risk.remote orelse "";
    const key = try std.fmt.allocPrint(a, "remote.{s}.{s}", .{ remote, if (r.risk.pushurl) "pushurl" else "url" });
    const removal = try removalCmd(ctx, r, key);
    if (r.risk.others_answered) return if (removal) |rm| .{ .remove = rm } else .reconnect;
    const add = try std.fmt.allocPrint(a, "{s} config --local --add {s} <url>", .{ try gitIn(ctx, r), try ui.shellQuote(a, try std.fmt.allocPrint(a, "remote.{s}.pushurl", .{remote})) });
    if (!r.risk.pushurl) return .{ .replace = .{ .cmd = add } };
    const rm = removal orelse return .reconnect;
    return .{ .replace = .{ .cmd = try std.fmt.allocPrint(a, "{s} && {s}", .{ rm.cmd, add }), .edit = rm.edit, .note = rm.note } };
}

/// Every distinct host (`shownHost`) of the URLs the line of `risk` names,
/// its own and `more_urls`, as a line names them: `a`, `a and b`, `a, b
/// and c`.
fn shownHosts(a: std.mem.Allocator, risk: Risk) ![]const u8 {
    var hosts: std.ArrayList([]const u8) = .empty;
    for (try std.mem.concat(a, []const u8, &.{ &.{risk.url}, risk.more_urls })) |u| {
        const h = try shownHost(a, remote_url.parse(u));
        if (!kept.paths.contains(hosts.items, h)) try hosts.append(a, h);
    }
    const n = hosts.items.len;
    if (n == 1) return hosts.items[0];
    return std.fmt.allocPrint(a, "{s} and {s}", .{ try std.mem.join(a, ", ", hosts.items[0 .. n - 1]), hosts.items[n - 1] });
}

/// The command removing, from every file that holds it, each value
/// `r.risk.values` of the key `key` the URL was read from (`valueRemoval`),
/// joined with `&&`; the edit of the repository's own configuration when
/// the URLs do not map onto the values one for one; null when a value's
/// origin is no file.
fn removalCmd(ctx: *app.Ctx, r: RiskAt, key: []const u8) !?Removal {
    const a = ctx.alloc;
    if (!r.risk.mapped or r.risk.values.len == 0) return .{ .cmd = try std.fmt.allocPrint(a, "{s} config --local --edit", .{try gitIn(ctx, r)}), .edit = key };
    var parts: std.ArrayList([]const u8) = .empty;
    var notes: std.ArrayList([]const u8) = .empty;
    var edit: ?[]const u8 = null;
    for (r.risk.values) |v| {
        if (v.no_file) return null;
        const one = try valueRemoval(ctx, r, key, v);
        if (kept.paths.contains(parts.items, one.cmd)) continue;
        try parts.append(a, one.cmd);
        if (one.edit != null) edit = key;
        if (one.note.len > 0) try notes.append(a, one.note);
    }
    return .{ .cmd = try std.mem.join(a, " && ", parts.items), .edit = edit, .note = try std.mem.join(a, "", notes.items) };
}

/// The command removing the value `v` of the key `key` from the file that
/// holds it: the repository's own configuration (`--local`), its own
/// `config.worktree` (`--worktree`), or another file (`--file <F>`), with
/// the note that editing the global or system file changes every
/// repository. The value is matched as given (`--fixed-value`), or, for
/// one with a userinfo split, query or fragment, by `wholeRegex`, so the
/// command names no part of them; the file is opened in an editor
/// (`--edit`) when that expression matches another value of the key there,
/// when the value can be read two ways, or when it holds a control
/// character, which no pasted command can name.
fn valueRemoval(ctx: *app.Ctx, r: RiskAt, key: []const u8, v: Configured) !Removal {
    const a = ctx.alloc;
    const config = if (v.file) |f|
        try std.fmt.allocPrint(a, "git config --file {s}", .{try q(ctx, f)})
    else
        try std.fmt.allocPrint(a, "{s} config {s}", .{ try gitIn(ctx, r), if (v.worktree) "--worktree" else "--local" });
    const scope: []const []const u8 = if (v.file) |f| &.{ "--file", f } else if (v.worktree) &.{"--worktree"} else &.{"--local"};
    const note = if (v.file) |f|
        (if (v.system) try std.fmt.allocPrint(a, " (in {s}, which changes every repository and may need an administrator to change, sudo)", .{try show(ctx, f)}) else if (v.global) try std.fmt.allocPrint(a, " (in {s}, which changes every repository)", .{try show(ctx, f)}) else "")
    else
        "";
    const k = try ui.shellQuote(a, key);
    if (!printable(v.value) or hasControl(v.value)) return .{ .cmd = try std.fmt.allocPrint(a, "{s} --edit", .{config}), .edit = key, .note = note };
    if (!hidesParts(v.value)) return .{ .cmd = try std.fmt.allocPrint(a, "{s} --fixed-value --unset-all {s} {s}", .{ config, k, try ui.shellQuote(a, v.value) }), .note = note };
    const regex = try wholeRegex(a, v.value);
    if (try matchesOther(a, if (r.git_dir_only) .{ .repo = r.repo, .git_dir = r.repo } else .{ .repo = r.repo }, scope, key, regex, v.value)) return .{ .cmd = try std.fmt.allocPrint(a, "{s} --edit", .{config}), .edit = key, .note = note };
    return .{ .cmd = try std.fmt.allocPrint(a, "{s} --unset-all {s} {s}", .{ config, k, try ui.shellQuote(a, regex) }), .note = note };
}

/// The clause of the no-target line (row 11) naming why the remote `g`
/// counts as no copy, and, when a command makes it count, what that
/// command does (`way`) and the command.
const Clause = struct { text: []const u8, way: ?[]const u8 = null, cmd: ?Removal = null };

fn clauseOf(ctx: *app.Ctx, r: RiskAt, g: GoneRemote) !Clause {
    const a = ctx.alloc;
    const name = try ui.shellQuote(a, g.name);
    const git_in = try gitIn(ctx, r);
    const add = try std.fmt.allocPrint(a, "{s} config --local --add {s} <url>", .{ git_in, try ui.shellQuote(a, try std.fmt.allocPrint(a, "remote.{s}.pushurl", .{g.name})) });
    switch (g.why) {
        .local => {
            var listed: std.ArrayList([]const u8) = .empty;
            for (g.urls) |u| try listed.append(a, try shownUrl(a, u));
            const urls = try std.mem.join(a, ", ", listed.items);
            if (!g.push_only) return .{ .text = try std.fmt.allocPrint(a, "remote {s} is on this machine ({s})", .{ name, urls }) };
            if (!g.push) return .{ .text = try std.fmt.allocPrint(a, "remote {s} has its push URLs on this machine ({s}), through a pushInsteadOf rule", .{ name, urls }), .way = "add a push URL", .cmd = .{ .cmd = add } };
            var parts: std.ArrayList([]const u8) = .empty;
            var notes: std.ArrayList([]const u8) = .empty;
            const key = try std.fmt.allocPrint(a, "remote.{s}.pushurl", .{g.name});
            for (g.pushurls) |v| {
                if (v.no_file) return .{ .text = try std.fmt.allocPrint(a, "remote {s} has its push URLs on this machine ({s})", .{ name, urls }) };
                const one = try valueRemoval(ctx, r, key, v);
                if (kept.paths.contains(parts.items, one.cmd)) continue;
                try parts.append(a, one.cmd);
                if (one.note.len > 0 and !kept.paths.contains(notes.items, one.note)) try notes.append(a, one.note);
            }
            if (!g.edit_alone) try parts.append(a, add);
            return .{ .text = try std.fmt.allocPrint(a, "remote {s} has its push URLs on this machine ({s})", .{ name, urls }), .way = "replace its push URLs", .cmd = .{ .cmd = try std.mem.join(a, " && ", parts.items), .note = try std.mem.join(a, "", notes.items) } };
        },
        .no_url => {
            if (g.empties.len == 0) return .{ .text = try std.fmt.allocPrint(a, "remote {s} has no URL", .{name}), .way = "set a URL", .cmd = .{ .cmd = try std.fmt.allocPrint(a, "{s} config --local {s} <url>", .{ git_in, try ui.shellQuote(a, try std.fmt.allocPrint(a, "remote.{s}.url", .{g.name})) }) } };
            const text = if (g.lists_empty) try std.fmt.allocPrint(a, "remote {s} has an empty URL", .{name}) else try std.fmt.allocPrint(a, "remote {s} has no URL", .{name});
            var parts: std.ArrayList([]const u8) = .empty;
            var notes: std.ArrayList([]const u8) = .empty;
            for (g.empties, g.empty_values) |k, v| {
                if (v.no_file) return .{ .text = text };
                const config = if (v.file) |f| try std.fmt.allocPrint(a, "git config --file {s}", .{try q(ctx, f)}) else try std.fmt.allocPrint(a, "{s} config {s}", .{ git_in, if (v.worktree) "--worktree" else "--local" });
                const cmd = try std.fmt.allocPrint(a, "{s} --unset-all {s} '^$'", .{ config, try ui.shellQuote(a, k[0]) });
                if (kept.paths.contains(parts.items, cmd)) continue;
                try parts.append(a, cmd);
                const note = try fileNote(ctx, v);
                if (note.len > 0 and !kept.paths.contains(notes.items, note)) try notes.append(a, note);
            }
            if (!g.edit_alone) try parts.append(a, add);
            return .{ .text = text, .way = "remove the empty URL", .cmd = .{ .cmd = try std.mem.join(a, " && ", parts.items), .note = try std.mem.join(a, "", notes.items) } };
        },
        .unsupported => return .{ .text = try std.fmt.allocPrint(a, "remote {s} is reached through {s}, which holt never asks", .{ name, g.transport }) },
        .mixed => return .{ .text = try std.fmt.allocPrint(a, "remote {s} has push destinations holt cannot verify", .{name}) },
        .mirror => return .{ .text = try std.fmt.allocPrint(a, "remote {s} is configured to mirror", .{name}) },
        .ambiguous => return .{ .text = try std.fmt.allocPrint(a, "remote {s} has a URL holt cannot read safely ({s})", .{ name, g.shown }) },
        .unreadable => return .{ .text = try std.fmt.allocPrint(a, "git cannot read the URLs of remote {s}", .{name}) },
    }
}

/// The note a command editing the global or system file, which holds
/// `v`, carries; empty for any other file.
fn fileNote(ctx: *app.Ctx, v: Configured) ![]const u8 {
    const f = v.file orelse return "";
    if (v.system) return std.fmt.allocPrint(ctx.alloc, " (in {s}, which changes every repository and may need an administrator to change, sudo)", .{try show(ctx, f)});
    if (v.global) return std.fmt.allocPrint(ctx.alloc, " (in {s}, which changes every repository)", .{try show(ctx, f)});
    return "";
}

/// The way and command of the no-target line: those of the first remote,
/// `origin` first, then in `git remote` order, whose clause has a command;
/// else adding a remote on another machine under the name
/// `Risk.add_name`.
pub const NoTargetWay = struct { text: []const u8, cmd: []const u8, note: []const u8 = "" };

fn noTargetWay(ctx: *app.Ctx, r: RiskAt) !NoTargetWay {
    for ([_]bool{ true, false }) |origin_pass| {
        for (r.risk.gone) |g| {
            if (std.mem.eql(u8, g.name, "origin") != origin_pass) continue;
            const c = try clauseOf(ctx, r, g);
            if (c.cmd) |cmd| return .{ .text = c.way.?, .cmd = cmd.cmd, .note = cmd.note };
        }
    }
    return .{ .text = "add a remote on another machine", .cmd = try std.fmt.allocPrint(ctx.alloc, "{s} remote add {s} <url>", .{ try gitIn(ctx, r), try ui.shellQuote(ctx.alloc, r.risk.add_name) }) };
}

/// How a line about a push URL that did not answer settles it
/// (`unaskedWay`), as `doctor --retire` names it: the way, and the command
/// with its note, empty for the ways out.
pub fn unaskedHint(ctx: *app.Ctx, r: RiskAt) !NoTargetWay {
    const a = ctx.alloc;
    return switch (try unaskedWay(ctx, r)) {
        .reconnect => .{ .text = "reconnect and run again", .cmd = "" },
        .host_key => |host| .{ .text = try std.fmt.allocPrint(a, "verify the host key of {s} and run again", .{host}), .cmd = "" },
        .remove => |rm| .{ .text = if (rm.edit) |key| try std.fmt.allocPrint(a, "edit {s} to remove that URL", .{try ui.shellQuote(a, key)}) else "remove that URL", .cmd = rm.cmd, .note = rm.note },
        .replace => |rm| .{ .text = if (rm.edit) |key| try std.fmt.allocPrint(a, "edit {s} to replace this push URL", .{try ui.shellQuote(a, key)}) else "replace this push URL", .cmd = rm.cmd, .note = rm.note },
    };
}

/// The way and command the no-target line gives for `r`
/// (`noTargetWay`).
pub fn noTargetHint(ctx: *app.Ctx, r: RiskAt) !NoTargetWay {
    return noTargetWay(ctx, r);
}

/// The remotes of the repository at `repo` whose every push URL is on
/// this machine (`GoneRemote.local`), as the no-target line names them.
/// `GitFailed` when the remotes cannot be listed.
pub fn localRemotes(asker: Asker, repo: []const u8) ![]const GoneRemote {
    const a = asker.alloc;
    const at: At = .{ .repo = repo };
    const remotes = try remotesOf(a, at);
    const rules = try rewriteRules(a, at);
    var out: std.ArrayList(GoneRemote) = .empty;
    for (remotes.local) |g| {
        var copy = g;
        copy.edit_alone = try editAlone(asker, at, remotes.scope, g, rules);
        try out.append(a, copy);
    }
    return out.items;
}

/// How `doctor --retire` names the remote `g` of `repo`, on this machine,
/// when no no-target line names it: its no-target clause, with that
/// clause's way and command, or, for a remote whose fetch URLs are on this
/// machine too, replacing its URLs: each value of its `url` and `pushurl`
/// keys removed from the file holding it (`valueRemoval`), then its `url`
/// set to `<url>`. No command when a value is in no file.
pub const LocalHint = struct { text: []const u8, way: []const u8 = "", cmd: []const u8 = "", note: []const u8 = "" };

pub fn localHint(ctx: *app.Ctx, repo: []const u8, g: GoneRemote) !LocalHint {
    const a = ctx.alloc;
    const r: RiskAt = .{ .repo = repo, .risk = .{ .what = .no_target } };
    const c = try clauseOf(ctx, r, g);
    if (c.cmd) |cmd| return .{ .text = c.text, .way = c.way.?, .cmd = cmd.cmd, .note = cmd.note };
    if (g.why != .local) return .{ .text = c.text };
    const at: At = .{ .repo = repo };
    var parts: std.ArrayList([]const u8) = .empty;
    var notes: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "url", "pushurl" }) |field| {
        const src = (try sourceAt(a, at, g.name, std.mem.eql(u8, field, "pushurl"), &.{})) orelse return .{ .text = c.text };
        if (!std.mem.eql(u8, field, "url") and !src.pushurl) continue;
        const key = try std.fmt.allocPrint(a, "remote.{s}.{s}", .{ g.name, field });
        for (src.values) |v| {
            if (v.no_file) return .{ .text = c.text };
            const one = try valueRemoval(ctx, r, key, v);
            if (kept.paths.contains(parts.items, one.cmd)) continue;
            try parts.append(a, one.cmd);
            if (one.note.len > 0 and !kept.paths.contains(notes.items, one.note)) try notes.append(a, one.note);
        }
    }
    try parts.append(a, try std.fmt.allocPrint(a, "{s} config --local {s} <url>", .{ try gitIn(ctx, r), try ui.shellQuote(a, try std.fmt.allocPrint(a, "remote.{s}.url", .{g.name})) }));
    return .{ .text = c.text, .way = "replace its URLs", .cmd = try std.mem.join(a, " && ", parts.items), .note = try std.mem.join(a, "", notes.items) };
}

/// How many of the refs an `unasked` risk could not confirm it names.
const unasked_shown = 3;

/// The command that settles `r`; for `unasked`, the one replacing or
/// removing the push URL (`unaskedWay`); for the no-target line, the one
/// `noTargetWay` names; empty when no command settles it.
pub fn settleRisk(ctx: *app.Ctx, r: RiskAt) ![]const u8 {
    const a = ctx.alloc;
    const git_in = try gitIn(ctx, r);
    return switch (r.risk.what) {
        .stashes => std.fmt.allocPrint(a, "{s} stash list", .{git_in}),
        .ahead, .ref_unheld, .object_unheld, .head_unheld, .remote_refs => blk: {
            if (r.risk.keep) |keep| break :blk if (r.risk.what == .head_unheld)
                std.fmt.allocPrint(a, "{s} branch {s} {s}", .{ git_in, try ui.shellQuote(a, keep["refs/heads/".len..]), r.risk.name })
            else
                std.fmt.allocPrint(a, "{s} update-ref {s} {s}", .{ git_in, try ui.shellQuote(a, keep), r.risk.src.? });
            const remote = r.risk.remote orelse break :blk "";
            var specs: std.ArrayList([]const u8) = .empty;
            if (r.risk.what == .remote_refs) {
                for (r.risk.pushes) |p| try specs.append(a, try refspec(a, p[0], p[1]));
            } else try specs.append(a, try refspec(a, r.risk.src.?, r.risk.dst.?));
            break :blk std.fmt.allocPrint(a, "{s} push --recurse-submodules=no -- {s} {s}", .{ git_in, try ui.shellQuote(a, remote), try std.mem.join(a, " ", specs.items) });
        },
        .unasked => switch (try unaskedWay(ctx, r)) {
            .reconnect, .host_key => "",
            .remove, .replace => |cmd| cmd.cmd,
        },
        .note, .unreadable => "",
        .no_target => (try noTargetWay(ctx, r)).cmd,
    };
}

/// `<src>:<dst>`, each quoted for the shell.
fn refspec(a: std.mem.Allocator, src: []const u8, dst: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ try ui.shellQuote(a, src), ":", try ui.shellQuote(a, dst) });
}

/// How a command reaches the repository `r` names: `git -C <repo>`, or
/// `git --git-dir <repo> --work-tree <repo>` for a git directory whose
/// `core.worktree` names no directory.
fn gitIn(ctx: *app.Ctx, r: RiskAt) ![]const u8 {
    const at = try q(ctx, r.repo);
    if (!r.git_dir_only) return std.fmt.allocPrint(ctx.alloc, "git -C {s}", .{at});
    return std.fmt.allocPrint(ctx.alloc, "git --git-dir {s} --work-tree {s}", .{ at, at });
}

/// A command removing a configured value, and, when it opens the
/// configuration holding it in an editor instead, the key to edit there.
pub const Removal = struct { cmd: []const u8, edit: ?[]const u8 = null, note: []const u8 = "" };

/// Whether `regex`, the `wholeRegex` of `value`, a value of the key `key`,
/// matches another value of that key in the configuration `scope` names
/// (`git config <scope>`, read in the repository at `repo`), so removing
/// what it matches there would remove that value too; true when git
/// cannot tell. Never for a value holt prints whole, which its expression
/// matches alone.
fn matchesOther(a: std.mem.Allocator, at: At, scope: []const []const u8, key: []const u8, regex: []const u8, value: []const u8) !bool {
    if (!printable(value)) return true;
    if (!hidesParts(value)) return false;
    const args = try std.mem.concat(a, []const u8, &.{ &.{"config"}, scope, &.{ "-z", "--get-all", key, regex } });
    const res = try at.run(a, args);
    if (res.status == 1) return false;
    if (res.status != 0) return true;
    var it = std.mem.splitScalar(u8, res.stdout, 0);
    while (it.next()) |listed| {
        if (it.peek() == null and listed.len == 0) break;
        if (!std.mem.eql(u8, listed, value)) return true;
    }
    return false;
}

/// A POSIX extended regular expression matching `s` whole, as `git remote
/// set-url --delete` and `git config` read one; for a URL with parts holt
/// never prints (`Hidden`), matching any password after its user name,
/// which it names as given, or, when its userinfo holds no `:`, which a
/// token alone may be, any userinfo, and any query and fragment, so the
/// expression never names a password or token.
pub fn wholeRegex(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (!printable(s)) return error.AmbiguousUrl;
    if (!hidesParts(s)) return std.mem.concat(a, u8, &.{ "^", try ereEscaped(a, s), "$" });
    const h = remote_url.parse(s);
    const info: []const u8 = if (h.info_end == h.info_start) "" else "[^?#]*@";
    const tail: []const u8 = if (h.tail < s.len) "[?#].*" else "";
    return std.mem.concat(a, u8, &.{ "^", try ereEscaped(a, s[0..h.info_start]), info, try ereEscaped(a, s[h.info_end..h.tail]), tail, "$" });
}

/// Whether holt may print `url` in part: a URL `remote_url.shown` shows
/// only by its transport, or one that can be read two ways, it never
/// prints, even as an expression matching it.
fn printable(url: []const u8) bool {
    const parsed = remote_url.parse(url);
    return !parsed.ambiguous and parsed.transport != .unsupported;
}

/// Whether `s` holds a control character (`ui.printable` shows one).
fn hasControl(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

/// Whether `url`, which `printable` allows, has a userinfo split, a query
/// or a fragment, the parts holt never prints.
fn hidesParts(url: []const u8) bool {
    const parsed = remote_url.parse(url);
    return parsed.info_end > parsed.info_start or parsed.tail < url.len;
}

/// The shown URL of `url` (`remote_url.shown`), made printable.
pub fn shownUrl(a: std.mem.Allocator, url: []const u8) ![]const u8 {
    return ui.printable(a, try remote_url.shown(a, url));
}

/// `s` with every character a POSIX extended regular expression gives a
/// meaning escaped.
fn ereEscaped(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, "\\.^$|?*+()[]{}", c) != null) try out.append(a, '\\');
        try out.append(a, c);
    }
    return out.items;
}

/// What deleting the repository at `repo` destroys that no remote holds,
/// uncommitted changes aside: stash entries; each ref (`inventoryAt`), a
/// branch (`ahead`) or any other (`ref_unheld`, `object_unheld`, the refs
/// of one remote grouped as `remote_refs`), per-worktree refs included,
/// naming a commit or other object no remote holds; and each HEAD whose
/// commit no ref and no remote holds (`head_unheld`). A remote holds only
/// what its URLs that count report now, asked as far as needed
/// (`askPlan`), and a commit is held when an object one of them lists is
/// here and reaches it (`heldCommits`); the repository's own refs are
/// never evidence. Nothing is fetched. Refs a target's push URL that did
/// not answer leaves unconfirmed go on that URL's line (`unasked`), and,
/// with no push target, every ref at risk on one line (`no_target`); a
/// read git fails is `unreadable`.
pub fn gitRisks(asker: Asker, repo: []const u8) ![]const Risk {
    return risksOf(asker, .{ .repo = repo });
}

/// What `gitRisks` finds in `git_dir`, the git directory of a submodule
/// that is not checked out (deinitialized, or never updated), read with
/// `--git-dir` since no working tree goes with it.
pub fn gitDirRisks(asker: Asker, git_dir: []const u8) ![]const Risk {
    return risksOf(asker, .{ .repo = git_dir, .git_dir = git_dir });
}

/// A repository git is asked about: its working tree, or, with `git_dir`
/// set, a git directory read with `--git-dir`.
const At = struct {
    repo: []const u8,
    git_dir: ?[]const u8 = null,

    /// Reads the repository with git, seeing only the objects and parents
    /// here: no grafts, and, as for every read `git.runInRepoScoped` runs,
    /// no replace refs and no object fetched from a promisor remote, with
    /// no transport allowed to run (`git.Gate.read`).
    fn run(at: At, a: std.mem.Allocator, args: []const []const u8) !git.RunResult {
        return at.runWithOpts(a, args, .{});
    }

    fn runWithOpts(at: At, a: std.mem.Allocator, args: []const []const u8, opts: git.ScopedOptions) !git.RunResult {
        return at.runGit(a, args, .read, opts);
    }

    /// `git ls-remote -- <arg>`, the query of the remote git reaches at
    /// `url` through `arg` (`url` itself, or a configured value git
    /// rewrites to it), as `run` runs git, with no credential helper that
    /// may wait on a person (`credential.interactive=never`,
    /// `GCM_INTERACTIVE=never`) and no redirect followed
    /// (`http.followRedirects=false`, and, for an http or https `url`,
    /// `redirectKey`, which wins over a key the user sets for any part of
    /// it).
    fn runQuery(at: At, a: std.mem.Allocator, arg: []const u8, url: []const u8, opts: git.ScopedOptions) !git.RunResult {
        var set: std.ArrayList([2][]const u8) = .empty;
        try set.append(a, .{ "GCM_INTERACTIVE", "never" });
        if (try redirectKey(a, url)) |key| try set.appendSlice(a, &.{ .{ "GIT_CONFIG_COUNT", "1" }, .{ "GIT_CONFIG_KEY_0", key }, .{ "GIT_CONFIG_VALUE_0", "false" } });
        try set.appendSlice(a, opts.set);
        var with = opts;
        with.set = set.items;
        return at.runGit(a, &.{ "-c", "credential.interactive=never", "-c", "http.followRedirects=false", "ls-remote", "--symref", "--", arg }, .query, with);
    }

    /// Runs git as `gate` says, with grafts off (`GIT_GRAFT_FILE` the null
    /// device, which no repository file can be); a git directory read alone
    /// is its own working tree too, so a `core.worktree` naming a directory
    /// that is gone does not stop git.
    fn runGit(at: At, a: std.mem.Allocator, args: []const []const u8, gate: git.Gate, opts: git.ScopedOptions) !git.RunResult {
        var set: std.ArrayList([2][]const u8) = .empty;
        try set.append(a, .{ "GIT_GRAFT_FILE", if (builtin.os.tag == .windows) "NUL" else "/dev/null" });
        try set.appendSlice(a, opts.set);
        var with = opts;
        with.set = set.items;
        const gd = at.git_dir orelse return git.runGateWith(a, args, at.repo, gate, with);
        const flag: []const []const u8 = &.{ try std.mem.concat(a, u8, &.{ "--git-dir=", gd }), try std.mem.concat(a, u8, &.{ "--work-tree=", gd }) };
        return git.runGateWith(a, try std.mem.concat(a, []const u8, &.{ flag, args }), gd, gate, with);
    }

    /// The directory git resolves a relative local URL against.
    fn base(at: At) []const u8 {
        return at.git_dir orelse at.repo;
    }
};

/// `http.<u>.followRedirects` for the http or https URL `url`, `<u>` being
/// `url` with the password of its userinfo, its query and its fragment
/// left out: the most specific key git matches for it. Null for a URL of
/// any other scheme.
fn redirectKey(a: std.mem.Allocator, url: []const u8) !?[]const u8 {
    const parsed = remote_url.parse(url);
    if (parsed.transport != .http and parsed.transport != .https) return null;
    const start = parsed.info_start;
    const tail = parsed.tail;
    const info_end = parsed.info_end;
    const info = url[start..info_end];
    const user = if (std.mem.indexOfScalar(u8, info, ':')) |colon| try std.mem.concat(a, u8, &.{ info[0..colon], "@" }) else info;
    return try std.mem.concat(a, u8, &.{ "http.", url[0..start], user, url[info_end..tail], ".followRedirects" });
}

/// The remotes of a repository: those that survive, the one a push goes to
/// among them (`origin`, else the first), those that hold nothing, among
/// them those on this machine, and the one named origin, with why.
const Remotes = struct {
    surviving: []const Surviving = &.{},
    gone: []const []const u8 = &.{},
    local: []const GoneRemote = &.{},
    origin: ?GoneRemote = null,
    /// Every remote that is no push target, in `git remote` order.
    all_gone: []const GoneRemote = &.{},
    /// Whether `git remote` lists any remote.
    any: bool = false,
    /// `remote.pushDefault`, when set.
    push_default: ?[]const u8 = null,
    /// Each `branch.<b>.pushRemote`: the branch and the remote.
    push_remotes: []const [2][]const u8 = &.{},
    /// Every fetch and push URL of a remote that counts (`counts`), each
    /// once; none of a remote with `remote.<name>.vcs` set.
    counting: []const []const u8 = &.{},
    /// The counting URLs of each remote `git remote` lists but those with
    /// `remote.<name>.vcs` set, in that order.
    urls: []const RemoteUrls = &.{},
    /// The git directory the repository was read through (`scopeOf`),
    /// which scopes the answers of its URLs (`Asker.answerOf`).
    scope: []const u8 = "",

    /// The configured values `RemoteUrls` holds for the remote `name`.
    fn valuesOf(r: Remotes, name: []const u8) []const Configured {
        for (r.urls) |u| if (std.mem.eql(u8, u.name, name)) return u.values;
        return &.{};
    }

    /// Whether `name` is a push target (`weighRemote`).
    fn isTarget(r: Remotes, name: []const u8) bool {
        for (r.surviving) |s| if (std.mem.eql(u8, s.name, name)) return true;
        return false;
    }

    /// The target of a ref at risk: the first push target among, for the
    /// branch `branch`, its `branch.<b>.pushRemote`, then
    /// `remote.pushDefault`, then, for a branch, the remote of its
    /// upstream (`upstream`), then `origin`, then the first push target
    /// `git remote` lists; null when there is none.
    fn target(r: Remotes, branch: ?[]const u8, upstream: ?[]const u8) ?[]const u8 {
        const push_remote: ?[]const u8 = if (branch) |b| for (r.push_remotes) |p| {
            if (std.mem.eql(u8, p[0], b)) break p[1];
        } else null else null;
        for ([_]?[]const u8{ push_remote, r.push_default, if (branch != null) upstream else null, "origin" }) |candidate| {
            const name = candidate orelse continue;
            if (r.isTarget(name)) return name;
        }
        return if (r.surviving.len > 0) r.surviving[0].name else null;
    }

    /// The names of every remote, surviving or not.
    fn names(r: Remotes, a: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (r.surviving) |s| try out.append(a, s.name);
        try out.appendSlice(a, r.gone);
        return out.items;
    }
};

/// The counting push and fetch URLs of a remote (`counts`), as `git
/// remote get-url --push --all` and `--all` print them, and every value
/// of its `remote.<name>.url` and `remote.<name>.pushurl` keys, which
/// `Asker.ask` may ask a URL through.
const RemoteUrls = struct { name: []const u8, push: []const []const u8, fetch: []const []const u8, values: []const Configured };

/// A remote that survives: its push URLs on another machine as git reads
/// them, and, when they are read from its `pushurl` values, what
/// `UrlSource.named` names for each, in the same order.
const Surviving = struct {
    name: []const u8,
    urls: []const []const u8,
    values: ?[]const ?Configured = null,
    /// The values its push URLs were read from, in the same order when
    /// `mapped`, from `remote.<name>.pushurl` when `pushurl`.
    configured: []const Configured = &.{},
    pushurl: bool = false,
    mapped: bool = false,
};

/// The remotes of `at`. A remote holds nothing when it has no URL, when git
/// cannot tell its push URLs (`git remote get-url --push --all`, which
/// applies `pushurl`, `pushInsteadOf`, and `insteadOf` as a push does), when
/// one of them is empty, or when every one names a path on this machine
/// (`onThisMachine`). `GitFailed` when the remotes cannot be listed.
fn remotesOf(a: std.mem.Allocator, at: At) !Remotes {
    const listed = try at.run(a, &.{"remote"});
    if (listed.status != 0) return error.GitFailed;
    var out: Remotes = .{ .scope = try scopeOf(a, at) };
    var surviving: std.ArrayList(Surviving) = .empty;
    var gone: std.ArrayList([]const u8) = .empty;
    var local: std.ArrayList(GoneRemote) = .empty;
    var counting: std.ArrayList([]const u8) = .empty;
    var all_urls: std.ArrayList(RemoteUrls) = .empty;
    var all_gone: std.ArrayList(GoneRemote) = .empty;
    var it = std.mem.tokenizeAny(u8, listed.stdout, "\r\n");
    while (it.next()) |name| {
        const vcs = try at.run(a, &.{ "config", "--get", try std.fmt.allocPrint(a, "remote.{s}.vcs", .{name}) });
        if (vcs.status == 1) {
            var lists: [2]std.ArrayList([]const u8) = .{ .empty, .empty };
            for ([_][]const []const u8{ &.{ "remote", "get-url", "--push", "--all", "--", name }, &.{ "remote", "get-url", "--all", "--", name } }, &lists) |args, *list| {
                const got = try at.run(a, args);
                if (got.status != 0) continue;
                for (try urlLines(a, got.stdout)) |u| if (try counts(a, at, u)) {
                    if (!kept.paths.contains(list.items, u)) try list.append(a, u);
                    if (!kept.paths.contains(counting.items, u)) try counting.append(a, u);
                };
            }
            var values: std.ArrayList(Configured) = .empty;
            for ([_][]const u8{ "url", "pushurl" }) |field| {
                const got = try at.run(a, &.{ "config", "-z", "--get-all", try std.fmt.allocPrint(a, "remote.{s}.{s}", .{ name, field }) });
                if (got.status != 0) continue;
                var vit = std.mem.splitScalar(u8, got.stdout, 0);
                while (vit.next()) |v| if (v.len > 0) try values.append(a, .{ .value = v });
            }
            try all_urls.append(a, .{ .name = name, .push = lists[0].items, .fetch = lists[1].items, .values = values.items });
        }
        switch (try weighRemote(a, at, name)) {
            .gone => |g| {
                try gone.append(a, name);
                try all_gone.append(a, g);
                if (g.why == .local) try local.append(a, g);
                if (std.mem.eql(u8, name, "origin")) out.origin = g;
            },
            .surviving => |s| try surviving.append(a, s),
        }
    }
    out.surviving = surviving.items;
    out.gone = gone.items;
    out.local = local.items;
    out.counting = counting.items;
    out.urls = all_urls.items;
    out.all_gone = all_gone.items;
    out.any = surviving.items.len + gone.items.len > 0;
    const default = try at.run(a, &.{ "config", "--get", "remote.pushDefault" });
    if (default.status == 0) out.push_default = std.mem.trimEnd(u8, default.stdout, "\r\n") else if (default.status != 1) return error.GitFailed;
    const pushes = try at.run(a, &.{ "config", "-z", "--get-regexp", "^branch\\..*\\.pushremote$" });
    if (pushes.status != 0 and pushes.status != 1) return error.GitFailed;
    var push_remotes: std.ArrayList([2][]const u8) = .empty;
    var entries = std.mem.splitScalar(u8, pushes.stdout, 0);
    while (entries.next()) |entry| {
        const nl = std.mem.indexOfScalar(u8, entry, '\n') orelse continue;
        const key = entry[0..nl];
        if (!std.mem.startsWith(u8, key, "branch.") or !std.mem.endsWith(u8, key, ".pushremote") or key.len <= "branch.".len + ".pushremote".len) continue;
        try push_remotes.append(a, .{ key["branch.".len .. key.len - ".pushremote".len], entry[nl + 1 ..] });
    }
    out.push_remotes = push_remotes.items;
    return out;
}

/// The real path of the git directory `at` reads, its own and not the
/// common one, which scopes the answers of its URLs: two repositories, or
/// two working trees of one whose `config.worktree` differs, whose
/// configuration (an ssh command, a rewrite rule, a relative path) sends
/// one URL to different remotes never share an answer. `GitFailed` when
/// git cannot name it.
fn scopeOf(a: std.mem.Allocator, at: At) ![]const u8 {
    const res = try at.run(a, &.{ "rev-parse", "--absolute-git-dir" });
    if (res.status != 0) return error.GitFailed;
    return fsutil.realPathOrSelf(a, std.mem.trimEnd(u8, res.stdout, "\r\n"));
}

/// The real path of the common directory of `at`. `GitFailed` when git
/// cannot name it.
pub fn commonDirOf(a: std.mem.Allocator, at: At) ![]const u8 {
    const res = try at.run(a, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
    if (res.status != 0) return error.GitFailed;
    return fsutil.realPathOrSelf(a, std.mem.trimEnd(u8, res.stdout, "\r\n"));
}

const Weighed = union(enum) { gone: GoneRemote, surviving: Surviving };

/// Whether the remote `name` of `at` is a push target (`Weighed.surviving`):
/// git can read its push URLs, which are not empty, and every one counts
/// (`counts`), and neither `remote.<name>.vcs` (a remote helper) nor
/// `remote.<name>.mirror` is set; else why not.
fn weighRemote(a: std.mem.Allocator, at: At, name: []const u8) !Weighed {
    const vcs = try at.run(a, &.{ "config", "--get", try std.fmt.allocPrint(a, "remote.{s}.vcs", .{name}) });
    if (vcs.status == 0) return .{ .gone = .{ .name = name, .why = .unsupported, .transport = try ui.printable(a, std.mem.trimEnd(u8, vcs.stdout, "\r\n")) } };
    if (vcs.status != 1) return .{ .gone = .{ .name = name, .why = .unreadable } };
    const mirror = try at.run(a, &.{ "config", "--bool", "--get", try std.fmt.allocPrint(a, "remote.{s}.mirror", .{name}) });
    if (mirror.status == 0 and std.mem.eql(u8, std.mem.trim(u8, mirror.stdout, "\r\n"), "true")) return .{ .gone = .{ .name = name, .why = .mirror } };
    if (mirror.status != 0 and mirror.status != 1) return .{ .gone = .{ .name = name, .why = .unreadable } };
    const res = try at.run(a, &.{ "remote", "get-url", "--push", "--all", "--", name });
    if (res.status != 0) return .{ .gone = .{ .name = name, .why = .unreadable } };
    const urls = try urlLines(a, res.stdout);
    const src = (try sourceAt(a, at, name, true, urls)) orelse return .{ .gone = .{ .name = name, .why = .unreadable } };
    if (src.values.len == 0 or urls.len == 0) return .{ .gone = try noUrl(a, at, name, false) };
    const named = try src.named(a, urls.len);
    var asked: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(?Configured) = .empty;
    var all_local = true;
    var ambiguous = false;
    for (urls, 0..) |url, n| {
        if (url.len == 0) {
            var gone = try noUrl(a, at, name, true);
            gone.push = src.pushurl;
            gone.value = named[n];
            return .{ .gone = gone };
        }
        ambiguous = ambiguous or remote_url.parse(url).ambiguous;
        const here = try onThisMachine(a, at.base(), url);
        all_local = all_local and here;
        if (here or !try counts(a, at, url)) continue;
        try asked.append(a, url);
        try values.append(a, named[n]);
    }
    if (asked.items.len == 0) {
        if (all_local) return .{ .gone = try localRemote(a, at, name, src, urls, named) };
        if (ambiguous) return .{ .gone = .{ .name = name, .why = .ambiguous, .shown = try firstAmbiguous(a, urls) } };
        return .{ .gone = .{ .name = name, .why = .unsupported, .transport = try transportOf(a, urls) } };
    }
    if (asked.items.len != urls.len) {
        if (ambiguous) return .{ .gone = .{ .name = name, .why = .ambiguous, .shown = try firstAmbiguous(a, urls) } };
        return .{ .gone = .{ .name = name, .why = .mixed } };
    }
    return .{ .surviving = .{ .name = name, .urls = asked.items, .values = if (src.pushurl) values.items else null, .configured = src.values, .pushurl = src.pushurl, .mapped = src.values.len == urls.len } };
}

/// The shown form of the first ambiguous URL of `urls`.
fn firstAmbiguous(a: std.mem.Allocator, urls: []const []const u8) ![]const u8 {
    for (urls) |u| if (remote_url.parse(u).ambiguous) return shownUrl(a, u);
    return "...";
}

/// The transport the first URL of `urls` holt never asks takes, as a
/// line names it: its scheme or helper name.
fn transportOf(a: std.mem.Allocator, urls: []const []const u8) ![]const u8 {
    for (urls) |u| {
        const parsed = remote_url.parse(u);
        if (parsed.transport == .unsupported) return ui.printable(a, parsed.scheme orelse "a remote helper");
    }
    return "a transport holt never asks";
}

/// The remote `name` of `at` with no URL git reads (`no_url`): whether
/// git lists an empty one (`lists_empty`), and each empty value of its
/// `url` and `pushurl` keys, with the key and where it is.
fn noUrl(a: std.mem.Allocator, at: At, name: []const u8, lists_empty: bool) !GoneRemote {
    var out: GoneRemote = .{ .name = name, .why = .no_url, .lists_empty = lists_empty };
    const own = (try ownConfigs(a, at)) orelse return out;
    var keys: std.ArrayList([2][]const u8) = .empty;
    var values: std.ArrayList(Configured) = .empty;
    for ([_][]const u8{ "url", "pushurl" }) |field| {
        const key = try std.fmt.allocPrint(a, "remote.{s}.{s}", .{ name, field });
        const res = try at.run(a, &.{ "config", "--show-scope", "--show-origin", "-z", "--get-all", key });
        if (res.status != 0) continue;
        var it = std.mem.splitScalar(u8, res.stdout, 0);
        while (it.next()) |scope| {
            const origin = it.next() orelse break;
            const v = it.next() orelse break;
            if (v.len > 0) continue;
            const file = try outsideFile(a, at, &own, origin);
            const path = try originPath(a, at, origin);
            try keys.append(a, .{ key, "" });
            try values.append(a, .{ .value = "", .file = file, .system = file != null and std.mem.eql(u8, scope, "system"), .global = file != null and std.mem.eql(u8, scope, "global"), .worktree = file == null and std.mem.eql(u8, path orelse "", own[1]), .no_file = path == null });
        }
    }
    out.empties = keys.items;
    out.empty_values = values.items;
    return out;
}

/// The remote `name` of `at`, whose push URLs `urls`, read from `src`
/// (`UrlSource.named` giving `named`), all name paths on this machine: a
/// `local` `GoneRemote`, `push_only` when one of its fetch URLs (`git
/// remote get-url --all`) is on another machine.
fn localRemote(a: std.mem.Allocator, at: At, name: []const u8, src: UrlSource, urls: []const []const u8, named: []const ?Configured) !GoneRemote {
    var out: GoneRemote = .{ .name = name, .why = .local, .push = src.pushurl };
    var listed: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(?Configured) = .empty;
    const fetch = try at.run(a, &.{ "remote", "get-url", "--all", "--", name });
    const fetch_urls = if (fetch.status == 0) try urlLines(a, fetch.stdout) else &.{};
    for (fetch_urls) |u| {
        if (try counts(a, at, u)) out.push_only = true;
    }
    if (!out.push_only) for (fetch_urls) |u| {
        if (u.len == 0 or kept.paths.contains(listed.items, u)) continue;
        try listed.append(a, u);
        try values.append(a, null);
    };
    for (urls, named) |u, v| {
        if (kept.paths.contains(listed.items, u)) continue;
        try listed.append(a, u);
        try values.append(a, v);
    }
    out.urls = listed.items;
    out.values = values.items;
    if (src.pushurl) out.pushurls = src.values;
    if (src.pushurl) {
        var files: std.ArrayList([]const u8) = .empty;
        for (src.values) |v| {
            if (v.file) |f| {
                if (!kept.paths.contains(files.items, f)) try files.append(a, f);
            } else if (v.worktree) {
                out.push_worktree = true;
            } else out.push_own = true;
        }
        out.push_files = files.items;
    }
    return out;
}

/// The lines of `git remote get-url --all` output, empty ones kept, the
/// last too, as git prints a URL it reads as empty.
pub fn urlLines(a: std.mem.Allocator, out: []const u8) ![]const []const u8 {
    if (out.len == 0) return &.{};
    var lines: std.ArrayList([]const u8) = .empty;
    const body = if (std.mem.endsWith(u8, out, "\n")) out[0 .. out.len - 1] else out;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| try lines.append(a, std.mem.trimEnd(u8, line, "\r"));
    return lines.items;
}

/// A configured URL value, and the file outside the repository holding it
/// (null when the repository's own configuration does, or none can be
/// named), which is the system configuration when `system`; `worktree`
/// when the repository's own `config.worktree` holds it.
pub const Configured = struct {
    value: []const u8,
    file: ?[]const u8 = null,
    system: bool = false,
    worktree: bool = false,
    /// The file is the user's global configuration.
    global: bool = false,
    /// git names an origin for the value that is no file (the command
    /// line, a blob), so no command can remove it.
    no_file: bool = false,
};

/// The configured values a remote's URLs were read from, and whether they
/// are its `pushurl` values.
pub const UrlSource = struct {
    values: []const Configured,
    pushurl: bool,

    /// For each of `n` URLs read from `values`, the value a removal
    /// names: one of several, or one a file outside the
    /// repository or its own `config.worktree` holds; all null when the
    /// URLs do not map onto `values` one for one.
    pub fn named(src: UrlSource, a: std.mem.Allocator, n: usize) ![]const ?Configured {
        const out = try a.alloc(?Configured, n);
        @memset(out, null);
        if (src.values.len != n) return out;
        for (src.values, out) |v, *o| {
            if (src.values.len > 1 or v.file != null or v.worktree) o.* = v;
        }
        return out;
    }
};

/// With `push`, the `remote.<name>.pushurl` values of `at` when any is in
/// effect, else, and without `push`, its `remote.<name>.url` values, each
/// key read as git lists it (`--get-all -z`, with the file each value is
/// in, named unless it is the repository's own `config` or
/// `config.worktree`, and which of those two it is), from its last empty
/// value on when `effective`, the
/// URLs git read, shows that git resets a list there (no URL it read is
/// empty). `values` is empty when neither key holds a URL; null when git
/// cannot read them.
fn sourceAt(a: std.mem.Allocator, at: At, remote: []const u8, push: bool, effective: []const []const u8) !?UrlSource {
    const resets = for (effective) |u| {
        if (u.len == 0) break false;
    } else true;
    const own = (try ownConfigs(a, at)) orelse return null;
    const fields: []const []const u8 = if (push) &.{ "pushurl", "url" } else &.{"url"};
    for (fields) |field| {
        const res = try at.run(a, &.{ "config", "--show-scope", "--show-origin", "-z", "--get-all", try std.fmt.allocPrint(a, "remote.{s}.{s}", .{ remote, field }) });
        if (res.status == 1) continue;
        if (res.status != 0) return null;
        var values: std.ArrayList(Configured) = .empty;
        var it = std.mem.splitScalar(u8, res.stdout, 0);
        while (it.next()) |scope| {
            const origin = it.next() orelse break;
            const v = it.next() orelse break;
            if (v.len == 0 and resets) {
                values.clearRetainingCapacity();
                continue;
            }
            const file = try outsideFile(a, at, &own, origin);
            const path = try originPath(a, at, origin);
            const worktree = file == null and std.mem.eql(u8, path orelse "", own[1]);
            try values.append(a, .{ .value = v, .file = file, .system = file != null and std.mem.eql(u8, scope, "system"), .global = file != null and std.mem.eql(u8, scope, "global"), .worktree = worktree, .no_file = path == null });
        }
        if (values.items.len == 0) continue;
        return .{ .values = values.items, .pushurl = std.mem.eql(u8, field, "pushurl") };
    }
    return .{ .values = &.{}, .pushurl = false };
}

/// The real paths of the configuration files that are the repository's
/// own: its common directory's `config` and its git directory's
/// `config.worktree`; null when git cannot name them.
fn ownConfigs(a: std.mem.Allocator, at: At) !?[2][]const u8 {
    const dirs = try at.run(a, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir" });
    if (dirs.status != 0) return null;
    var dit = std.mem.tokenizeAny(u8, dirs.stdout, "\r\n");
    return .{
        try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ dit.next() orelse return null, "config" })),
        try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ dit.next() orelse return null, "config.worktree" })),
    };
}

/// The real path of the file `origin`, as `git config --show-origin`
/// names one, when it is not one of `own`; null for one of them, or an
/// origin that is no file.
fn outsideFile(a: std.mem.Allocator, at: At, own: *const [2][]const u8, origin: []const u8) !?[]const u8 {
    const abs = (try originPath(a, at, origin)) orelse return null;
    return if (kept.paths.contains(own, abs)) null else abs;
}

/// The real path of the file `origin`, as `git config --show-origin`
/// names one; null for an origin that is no file.
fn originPath(a: std.mem.Allocator, at: At, origin: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, origin, "file:")) return null;
    const f = origin["file:".len..];
    return try fsutil.realPathOrSelf(a, if (std.fs.path.isAbsolute(f)) f else try std.fs.path.join(a, &.{ at.base(), f }));
}

/// Test seam: a loopback URL whose port is one of these stands for
/// another machine's repository (`onThisMachine`).
pub var loopback_elsewhere_for_test: []const u16 = &.{};

/// Whether `host` is this machine (`remote_url.hostIsLocal`, with this
/// machine's name).
pub fn hostIsThisMachine(host: []const u8) bool {
    if (builtin.os.tag == .windows) {
        const win = struct {
            extern "kernel32" fn GetComputerNameW(buf: [*]u16, size: *u32) callconv(.winapi) i32;
        };
        var wide: [256]u16 = undefined;
        var size: u32 = wide.len;
        if (win.GetComputerNameW(&wide, &size) != 0) {
            var name: [1024]u8 = undefined;
            const len = std.unicode.utf16LeToUtf8(&name, wide[0..size]) catch return remote_url.hostIsLocal(host, "");
            return remote_url.hostIsLocal(host, name[0..len]);
        }
    } else {
        var name: [std.posix.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&name)) |got| return remote_url.hostIsLocal(host, got) else |_| {}
    }
    return remote_url.hostIsLocal(host, "");
}

/// Whether the remote URL `url` of a repository whose relative URLs git
/// resolves against `base` is on this machine: a local path
/// (`remote_url.localPath`), whatever repository is there, or a URL of a
/// counting transport, not ambiguous, whose host is this machine
/// (`hostIsThisMachine`). holt reads no ssh configuration: a `Host` alias
/// that reaches this machine is another machine. Under test, a path at or
/// under a directory holding `testutil.elsewhere_mark`, and a loopback
/// URL whose port is in `loopback_elsewhere_for_test`, stand for another
/// machine's repository.
pub fn onThisMachine(a: std.mem.Allocator, base: []const u8, url: []const u8) !bool {
    if (remote_url.localPath(url)) |local| {
        if (!builtin.is_test) return true;
        var dir: ?[]const u8 = if (std.fs.path.isAbsolute(local)) local else try std.fs.path.join(a, &.{ base, local });
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            const mark = kept.content.entryAt(try std.fs.path.join(a, &.{ d, testutil.elsewhere_mark })) catch continue;
            if (mark != .absent) return false;
        }
        return true;
    }
    const parsed = remote_url.parse(url);
    const host = parsed.host orelse return false;
    if (!parsed.countingTransport() or parsed.ambiguous or !hostIsThisMachine(host)) return false;
    if (builtin.is_test and remote_url.hostIsLocal(host, "")) {
        const port = portOf(parsed) orelse return true;
        for (loopback_elsewhere_for_test) |p| if (p == port) return false;
    }
    return true;
}

/// The port a URL of a counting transport reaches: the one it names, else
/// its transport's default (ssh 22, git 9418, http 80, https 443); null
/// for one that names no number.
fn portOf(parsed: remote_url.Url) ?u16 {
    if (parsed.port) |p| return std.fmt.parseInt(u16, p, 10) catch null;
    return switch (parsed.transport) {
        .ssh => 22,
        .git => 9418,
        .http => 80,
        .https => 443,
        .local, .unsupported => null,
    };
}

/// Whether `url`, a URL of a repository whose relative URLs git resolves
/// against `at`, counts: non-empty, of a counting transport
/// (`remote_url.Url.countingTransport`), not ambiguous, and not on this
/// machine (`onThisMachine`). Under test, a local path standing for
/// another machine's repository counts too.
fn counts(a: std.mem.Allocator, at: At, url: []const u8) !bool {
    if (url.len == 0) return false;
    const parsed = remote_url.parse(url);
    if (parsed.ambiguous) return false;
    if (builtin.is_test and parsed.transport == .local) return !try onThisMachine(a, at.base(), url);
    return parsed.countingTransport() and !try onThisMachine(a, at.base(), url);
}

/// A ref a URL lists, and the object it names; for the `ref:` line
/// `--symref` gives, the ref it names (`symref`), with no object.
pub const Listed = struct { ref: []const u8, object: []const u8, symref: ?[]const u8 = null };

/// What the remotes that survive hold, as their push URLs report it now.
const Holdings = struct {
    /// Every object a URL lists.
    listed: std.StringHashMapUnmanaged(void) = .empty,
    /// The same objects, each once, in the order listed.
    tips: []const []const u8 = &.{},
    /// What each push URL that answered lists, of each remote, in
    /// `Remotes.surviving` order.
    listings: []const []const []const Listed = &.{},
    /// The push URLs of targets that could not be asked, in the order asked.
    unasked: []const Unasked = &.{},
    /// The other URLs that were asked and did not answer, but for those
    /// the host skip kept from being asked.
    notes: []const Unasked = &.{},

    /// The listings of the push URLs of the push target `name`.
    fn listingsOf(h: *const Holdings, remotes: Remotes, name: []const u8) []const []const Listed {
        for (remotes.surviving, h.listings) |s, l| {
            if (std.mem.eql(u8, s.name, name)) return l;
        }
        return &.{};
    }
};

/// A push URL that could not be asked, its remote, why (`Unanswered`),
/// and the `pushurl` value `UrlSource.named` names for it.
const Unasked = struct {
    remote: []const u8,
    url: []const u8,
    why: Unanswered,
    value: ?Configured,
    /// Every configured value the URL was read from, one per file that
    /// holds it (`Surviving.configured`); empty when the URLs do not map
    /// onto the values one for one (`mapped` false).
    values: []const Configured = &.{},
    pushurl: bool = false,
    mapped: bool = false,
    /// The target's other push URLs, each counting, all answered this
    /// weighing: the URL can be removed alone.
    others_answered: bool = false,
};

/// What asking a URL gave: the refs it lists, or why it could not be
/// asked.
pub const Answer = union(enum) { listed: []const Listed, unasked: Unanswered };

/// What a line about a URL that did not answer offers: only the ways out
/// (`transient`: reconnect and run again, or `--force`), the removal or
/// repoint of the URL (`persistent`), or verifying the host key of its
/// host (`host_key`).
pub const Class = enum { transient, persistent, host_key };

/// Why a URL could not be asked, as one phrase holt writes (`queryFailure`),
/// never git's text, its class, and, when it was not asked because its skip
/// key was skipped earlier in the command run (`AskRun`), that host as
/// holt prints it.
pub const Unanswered = struct { why: []const u8, class: Class = .transient, host: ?[]const u8 = null };

/// The answers of one weighing pass, by the repository whose
/// configuration asked (`scopeOf`) and the URL asked (`answerKey`).
pub const Answers = std.StringHashMapUnmanaged(Answer);

/// The key of the answer to `url` asked in the repository `scope` names.
fn answerKey(a: std.mem.Allocator, scope: []const u8, url: []const u8) ![]const u8 {
    return std.mem.concat(a, u8, &.{ scope, "\x00", url });
}

/// What asking remotes has shown over one command run, across its weighing
/// passes: the skip keys (`skipKey`) no URL of which is asked again in the
/// run, with the class of the lines naming them (`host_key` after a host
/// key that was not verified, else `transient`); the hosts not found, every
/// skip key of which is skipped; the time the unsuccessful queries of each
/// skip key took together; and the URLs whose `asking` line was printed,
/// each once in the run.
pub const AskRun = struct {
    skipped: std.StringHashMapUnmanaged(Class) = .empty,
    lost: std.StringHashMapUnmanaged(void) = .empty,
    failed_ns: std.StringHashMapUnmanaged(i96) = .empty,
    announced: std.StringHashMapUnmanaged(void) = .empty,

    /// The class of the line of a URL of skip key `key` and host `host` the
    /// run skips; null when it is asked.
    fn skips(run: *const AskRun, key: []const u8, host: []const u8) ?Class {
        if (run.lost.contains(host)) return .transient;
        return run.skipped.get(key);
    }

    /// Records an unsuccessful query of skip key `key` and host `host` that
    /// took `elapsed` and failed with `failure` (null for the kill at the
    /// limit, `budget_ns`): the key is skipped after a host-level failure
    /// or once its unsuccessful queries took `budget_ns` together, and the
    /// host after "host not found".
    fn record(run: *AskRun, a: std.mem.Allocator, key: []const u8, host: []const u8, elapsed: i96, failure: ?Failure, budget_ns: i96) !void {
        const total = (run.failed_ns.get(key) orelse 0) + elapsed;
        try run.failed_ns.put(a, try a.dupe(u8, key), total);
        if (failure) |f| if (f.host_not_found) try run.lost.put(a, try a.dupe(u8, host), {});
        const host_level = if (failure) |f| f.host_level else true;
        if (host_level or total >= budget_ns) {
            const class: Class = if (failure) |f| (if (f.host_key) .host_key else .transient) else .transient;
            try run.skipped.put(a, try a.dupe(u8, key), class);
        }
    }
};

/// How long a query runs, off a terminal, before a line says which host it
/// waits for.
const notice_after_s = 5;

/// How long one URL is waited for before it counts as not asked.
const ask_limit_s = 30;

/// Test seam: the limit `Asker.ask` waits, in seconds, when set.
pub var ask_limit_for_test: ?i64 = null;

/// Test seam: how long, in seconds, the unsuccessful queries of a skip key
/// may take together before the run skips it (`AskRun.record`), when set;
/// else the limit a query waits.
pub var ask_budget_for_test: ?i64 = null;

/// Asks remotes what they hold for one weighing pass, each distinct URL
/// once per repository, however many of its remotes name it.
pub const Asker = struct {
    alloc: std.mem.Allocator,
    answers: *Answers,
    run: *AskRun,
    /// Where the lines about a query go: on a terminal (`terminal`),
    /// `asking <remote> at <url>...` before the first query of each URL in
    /// the command run, else `waiting for <host>...` once a query has run
    /// `notice_after_s` seconds; null prints neither.
    err: ?*std.Io.Writer = null,
    terminal: bool = false,

    /// A new asker for one weighing pass of `ctx`'s command run: its
    /// answers are its own, so nothing asked before is taken as an answer
    /// now; the hosts that gave no answer are the run's
    /// (`app.Context.ask_run`), or its own when there is none. Its lines
    /// about a query go to `ctx.err`.
    pub fn of(ctx: *app.Ctx) !Asker {
        const answers = try ctx.alloc.create(Answers);
        answers.* = .empty;
        return reusing(ctx, answers);
    }

    /// `of`, taking `answers`, what an earlier pass of the run was told,
    /// as its own, so no URL they hold is asked again.
    pub fn reusing(ctx: *app.Ctx, answers: *Answers) !Asker {
        const run = (if (ctx.context) |c| c.ask_run else null) orelse blk: {
            const own = try ctx.alloc.create(AskRun);
            own.* = .{};
            break :blk own;
        };
        return .{ .alloc = ctx.alloc, .answers = answers, .run = run, .err = ctx.err, .terminal = ui.stderrIsTerminal() };
    }

    /// What `url`, a URL of the remote `remote` of `at`, whose git
    /// directory is `scope` (`scopeOf`), lists (`git ls-remote`, every
    /// ref), asked once for the pass in that repository. It is not asked
    /// when git would ask another URL, which an `insteadOf` rule rewriting
    /// it again makes so, nor when the run skips its skip key (`AskRun`): after a
    /// host-level failure of a URL of that key (`queryFailure`, or no
    /// answer in `ask_limit_s` seconds), once its unsuccessful queries took
    /// `ask_limit_s` seconds together, or after its host was not found. git
    /// runs with no terminal prompt, with `git.batch_ssh` unless the user names
    /// an ssh command (`GIT_SSH_COMMAND`, `GIT_SSH`, or `core.sshCommand`),
    /// and is killed after `ask_limit_s` seconds; each failure is
    /// `unasked`, with why. Under test, a URL of another host than this one
    /// is `NetworkInTest`.
    fn ask(asker: Asker, at: At, scope: []const u8, remote: []const u8, url: []const u8, values: []const Configured) !Answer {
        const a = asker.alloc;
        const key = try answerKey(a, scope, url);
        if (asker.answers.get(key)) |known| return known;
        const resolved = try at.run(a, &.{ "ls-remote", "--get-url", "--", url });
        if (resolved.status != 0) return .{ .unasked = .{ .why = try std.fmt.allocPrint(a, "git ls-remote --get-url failed (exit {d})", .{resolved.status}) } };
        const target = std.mem.trimEnd(u8, resolved.stdout, "\r\n");
        var arg = url;
        if (!std.mem.eql(u8, target, url)) {
            arg = for (values) |v| {
                const got = try at.run(a, &.{ "ls-remote", "--get-url", "--", v.value });
                if (got.status == 0 and std.mem.eql(u8, std.mem.trimEnd(u8, got.stdout, "\r\n"), url)) break v.value;
            } else return .{ .unasked = .{ .why = try std.fmt.allocPrint(a, "an insteadOf rule rewrites it again, to {s}", .{try shownUrl(a, target)}), .class = .persistent } };
        }
        const helper = try at.run(a, &.{ "config", "--get", try std.fmt.allocPrint(a, "remote.{s}.vcs", .{arg}) });
        if (helper.status == 0) return .{ .unasked = .{ .why = "a remote helper would answer for it", .class = .persistent } };
        if (helper.status != 1) return .{ .unasked = .{ .why = try std.fmt.allocPrint(a, "git config failed (exit {d})", .{helper.status}) } };
        const answer = try asker.query(at, remote, url, arg);
        try asker.answers.put(a, key, answer);
        return answer;
    }

    /// What `url` told this pass when the repository `scope` names asked
    /// it; null when it was not asked there.
    fn answerOf(asker: Asker, scope: []const u8, url: []const u8) !?Answer {
        return asker.answers.get(try answerKey(asker.alloc, scope, url));
    }

    fn query(asker: Asker, at: At, remote: []const u8, url: []const u8, arg: []const u8) !Answer {
        const a = asker.alloc;
        if (builtin.is_test and !onThisHost(url)) return error.NetworkInTest;
        const parsed = remote_url.parse(url);
        const key = try skipKey(a, parsed);
        const host = try hostKey(a, parsed);
        const shown_host = try shownHost(a, parsed);
        if (asker.run.skips(key, host)) |class| return .{ .unasked = try skippedAnswer(a, shown_host, class) };
        var notice: ?proc.Notice = null;
        if (asker.err) |w| {
            if (!asker.terminal) {
                notice = .{ .after = .fromSeconds(notice_after_s), .w = w, .line = try std.fmt.allocPrint(a, "waiting for {s}...\n", .{shown_host}) };
            } else if (!asker.run.announced.contains(url)) {
                try asker.run.announced.put(a, try a.dupe(u8, url), {});
                try w.print("asking {s} at {s}...\n", .{ try ui.shellQuote(a, remote), try shownUrl(a, url) });
            }
        }
        const limit_s = if (builtin.is_test) ask_limit_for_test orelse ask_limit_s else ask_limit_s;
        var set: std.ArrayList([2][]const u8) = .empty;
        if (!try namesSsh(a, at)) try set.append(a, .{ "GIT_SSH_COMMAND", git.batch_ssh });
        const started = std.Io.Clock.awake.now(io());
        const res = try at.runQuery(a, arg, url, .{ .set = set.items, .limit = .fromSeconds(limit_s), .notice = notice });
        const elapsed = started.durationTo(std.Io.Clock.awake.now(io())).nanoseconds;
        const budget: i96 = @as(i96, if (builtin.is_test) ask_budget_for_test orelse limit_s else limit_s) * std.time.ns_per_s;
        if (res.timed_out) {
            try asker.run.record(a, key, host, elapsed, null, budget);
            return .{ .unasked = .{ .why = try std.fmt.allocPrint(a, "no answer in {d} seconds", .{limit_s}), .class = .transient } };
        }
        if (res.status != 0) {
            const failure = try queryFailure(a, res.stderr, res.status);
            try asker.run.record(a, key, host, elapsed, failure, budget);
            return .{ .unasked = .{ .why = failure.why, .class = failure.class } };
        }
        return .{ .listed = try parseRemoteListing(a, res.stdout) };
    }
};

/// What `git ls-remote --symref` printed: each `<oid>TAB<ref>` line, and
/// each `ref: <target>TAB<ref>` line as the ref it names.
fn parseRemoteListing(a: std.mem.Allocator, stdout: []const u8) ![]const Listed {
    var listed: std.ArrayList(Listed) = .empty;
    var lines = std.mem.tokenizeAny(u8, stdout, "\r\n");
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.startsWith(u8, line, "ref: ")) {
            if (tab <= "ref: ".len) continue;
            try listed.append(a, .{ .ref = line[tab + 1 ..], .object = "", .symref = line["ref: ".len..tab] });
        } else try listed.append(a, .{ .ref = line[tab + 1 ..], .object = line[0..tab] });
    }
    return listed.items;
}

/// Why a query failed, as holt names it (`queryFailure`), its class, and
/// whether its skip key is skipped at once (`host_level`), with its host
/// too (`host_not_found`), and with the host-key wording (`host_key`).
const Failure = struct { why: []const u8, class: Class, host_level: bool = false, host_not_found: bool = false, host_key: bool = false };

/// The reasons `queryFailure` names, each with the phrases of git's error
/// under `LC_ALL=C` that show it, matched ignoring case, in the order they
/// are tried.
const failure_reasons = [_]struct { phrases: []const []const u8, failure: Failure }{
    .{ .phrases = &.{ "could not resolve host", "unable to look up", "name or service not known", "temporary failure in name resolution", "nodename nor servname", "no address associated with hostname" }, .failure = .{ .why = "host not found", .class = .transient, .host_level = true, .host_not_found = true } },
    .{ .phrases = &.{ "connection refused", "couldn't connect to server", "could not connect to server" }, .failure = .{ .why = "connection refused", .class = .transient, .host_level = true } },
    .{ .phrases = &.{"connection reset by peer"}, .failure = .{ .why = "connection reset", .class = .transient, .host_level = true } },
    .{ .phrases = &.{"timed out"}, .failure = .{ .why = "timed out", .class = .transient, .host_level = true } },
    .{ .phrases = &.{"host key verification failed"}, .failure = .{ .why = "host key not verified", .class = .host_key, .host_level = true, .host_key = true } },
    .{ .phrases = &.{ "repository not found", "does not appear to be a git repository", "' not found", "repository not exported", "returned error: 404" }, .failure = .{ .why = "repository not found", .class = .persistent } },
    .{ .phrases = &.{ "permission denied", "terminal prompts disabled", "authentication failed", "access denied", "could not read username", "could not read password", "unable to get password", "returned error: 401", "returned error: 403" }, .failure = .{ .why = "authentication failed", .class = .persistent } },
    .{ .phrases = &.{"returned error: 30"}, .failure = .{ .why = "the server redirects it elsewhere", .class = .persistent } },
    .{ .phrases = &.{"not allowed"}, .failure = .{ .why = "git's protocol policy forbids it", .class = .persistent } },
};

/// Why a query failed, never quoting git, whose error may hold part of a
/// password or token the URL holds: the first of `failure_reasons` whose
/// phrase git's error `stderr` shows, else `git ls-remote failed (exit
/// <status>)`, transient.
fn queryFailure(a: std.mem.Allocator, stderr: []const u8, status: u8) !Failure {
    for (failure_reasons) |r| {
        for (r.phrases) |phrase| if (std.ascii.indexOfIgnoreCase(stderr, phrase) != null) return r.failure;
    }
    return .{ .why = try std.fmt.allocPrint(a, "git ls-remote failed (exit {d})", .{status}), .class = .transient };
}

fn failureReason(a: std.mem.Allocator, stderr: []const u8, status: u8) ![]const u8 {
    return (try queryFailure(a, stderr, status)).why;
}

/// Whether the user names the command git runs for ssh, for `at`:
/// `GIT_SSH_COMMAND` or `GIT_SSH` in the environment git inherits, or
/// `core.sshCommand`.
fn namesSsh(a: std.mem.Allocator, at: At) !bool {
    var map = try std.process.Environ.createMap(std.Io.Threaded.global_single_threaded.environ.process_environ, a);
    defer map.deinit();
    if (git.environNamesSsh(&map)) return true;
    const res = try at.run(a, &.{ "config", "core.sshCommand" });
    return res.status == 0 and std.mem.trim(u8, res.stdout, " \t\r\n").len > 0;
}

/// The skip key of `parsed`, a URL of a counting transport: its transport
/// (every spelling of ssh one), its host (`hostKey`), and its port, the
/// transport's default when it names none (`portOf`), or the text it names
/// when that is no number.
fn skipKey(a: std.mem.Allocator, parsed: remote_url.Url) ![]const u8 {
    const host = try hostKey(a, parsed);
    if (portOf(parsed)) |port| return std.fmt.allocPrint(a, "{s}\x00{s}\x00{d}", .{ @tagName(parsed.transport), host, port });
    return std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ @tagName(parsed.transport), host, parsed.port orelse "" });
}

/// host(u) of `parsed`, lowercased, without a trailing dot.
fn hostKey(a: std.mem.Allocator, parsed: remote_url.Url) ![]const u8 {
    const raw = parsed.host orelse "";
    return std.ascii.allocLowerString(a, if (std.mem.endsWith(u8, raw, ".")) raw[0 .. raw.len - 1] else raw);
}

/// The host of `parsed` as a line names it: host(u), with the port the URL
/// names, printable.
fn shownHost(a: std.mem.Allocator, parsed: remote_url.Url) ![]const u8 {
    const host = parsed.host orelse "";
    if (parsed.port) |port| if (port.len > 0) return ui.printable(a, try std.fmt.allocPrint(a, "{s}:{s}", .{ host, port }));
    return ui.printable(a, host);
}

/// Why a URL whose skip key the run skips is not asked: row 9 of the
/// delete-gate refusals, naming `host`.
fn skippedAnswer(a: std.mem.Allocator, host: []const u8, class: Class) !Unanswered {
    const why = switch (class) {
        .host_key => try std.fmt.allocPrint(a, "not asked: the host key of {s} was not verified earlier in this run", .{host}),
        else => try std.fmt.allocPrint(a, "not asked: {s} did not answer earlier in this run", .{host}),
    };
    return .{ .why = why, .class = class, .host = host };
}

/// Test-only: whether `url` is a local path or names a loopback host,
/// which a test may ask without reaching the network.
fn onThisHost(url: []const u8) bool {
    const parsed = remote_url.parse(url);
    if (parsed.ambiguous or parsed.transport == .unsupported) return false;
    if (parsed.transport == .local) return true;
    return remote_url.hostIsLocal(parsed.host orelse return false, "");
}

/// What a repository weighs (`askPlan`): the commits its weighed refs and
/// HEADs hold, the objects that are not commits its weighed refs name,
/// and the targets of all of them (`Remotes.target`).
const Weighing = struct { commits: []const []const u8, objects: []const []const u8, targets: []const []const u8 };

/// Asks the remotes of `at` what they hold, as far as `weighed` needs:
/// nothing when it weighs nothing or `local` alone holds all of it; else
/// first every counting push URL of each target, then, while a weighed
/// commit is not held (`heldCommits`, with `local` as further evidence) or
/// a weighed object is not listed, each other counting URL, one at a time:
/// the push URLs of the other remotes, then every fetch URL. A URL that
/// answers holds what it lists, whichever remote names it; only a target's
/// push URLs give listings for its pushes, and only they, when they do
/// not answer, are `Holdings.unasked`.
fn askPlan(asker: Asker, at: At, remotes: Remotes, weighed: Weighing, local: ?Holdings) !Holdings {
    const a = asker.alloc;
    var h: Holdings = .{};
    var tips: std.ArrayList([]const u8) = .empty;
    var unasked: std.ArrayList(Unasked) = .empty;
    const listings = try a.alloc([]const []const Listed, remotes.surviving.len);
    @memset(listings, &.{});
    h.listings = listings;
    if ((local != null or weighed.commits.len + weighed.objects.len == 0) and try allHeld(a, at, &h, local, weighed)) return h;
    var asked: std.ArrayList([]const u8) = .empty;
    for (remotes.surviving, listings) |r, *out| {
        var mine: std.ArrayList([]const Listed) = .empty;
        if (kept.paths.contains(weighed.targets, r.name)) for (r.urls, 0..) |url, n| {
            try asked.append(a, url);
            switch (try asker.ask(at, remotes.scope, r.name, url, remotes.valuesOf(r.name))) {
                .unasked => |why| {
                    const again = for (unasked.items) |u| {
                        if (std.mem.eql(u8, u.url, url)) break true;
                    } else false;
                    if (!again) {
                        var values: std.ArrayList(Configured) = .empty;
                        if (r.mapped) for (r.urls, r.configured) |u, v| if (std.mem.eql(u8, u, url)) try values.append(a, v);
                        try unasked.append(a, .{ .remote = r.name, .url = url, .why = why, .value = if (r.values) |v| v[n] else null, .values = values.items, .pushurl = r.pushurl, .mapped = r.mapped });
                    }
                },
                .listed => |listed| {
                    try addListed(a, &h, &tips, listed);
                    try mine.append(a, listed);
                },
            }
        };
        out.* = mine.items;
    }
    h.listings = listings;
    for (unasked.items) |*u| {
        const r = for (remotes.surviving) |r| {
            if (std.mem.eql(u8, r.name, u.remote)) break r;
        } else continue;
        var others: usize = 0;
        u.others_answered = for (r.urls) |other| {
            if (std.mem.eql(u8, other, u.url)) continue;
            others += 1;
            const answer = (try asker.answerOf(remotes.scope, other)) orelse break false;
            if (answer != .listed) break false;
        } else others > 0;
    }
    h.unasked = unasked.items;
    h.tips = tips.items;
    var notes: std.ArrayList(Unasked) = .empty;
    var others: std.ArrayList([2][]const u8) = .empty;
    for (remotes.urls) |r| if (!kept.paths.contains(weighed.targets, r.name)) for (r.push) |u| try others.append(a, .{ r.name, u });
    for (remotes.urls) |r| for (r.fetch) |u| try others.append(a, .{ r.name, u });
    for (others.items) |o| {
        if (try allHeld(a, at, &h, local, weighed)) break;
        if (kept.paths.contains(asked.items, o[1])) continue;
        try asked.append(a, o[1]);
        switch (try asker.ask(at, remotes.scope, o[0], o[1], remotes.valuesOf(o[0]))) {
            .unasked => |why| if (why.host == null) {
                try notes.append(a, .{ .remote = o[0], .url = o[1], .why = why, .value = null });
                h.notes = notes.items;
            },
            .listed => |listed| {
                try addListed(a, &h, &tips, listed);
                h.tips = tips.items;
            },
        }
    }
    return h;
}

/// Adds the objects of `listed` to `h`, each once.
fn addListed(a: std.mem.Allocator, h: *Holdings, tips: *std.ArrayList([]const u8), listed: []const Listed) !void {
    for (listed) |l| {
        if (l.symref != null or h.listed.contains(l.object)) continue;
        try h.listed.put(a, l.object, {});
        try tips.append(a, l.object);
    }
}

/// Whether `h`, with `local`, holds every commit and lists every object
/// `weighed` names.
fn allHeld(a: std.mem.Allocator, at: At, h: *const Holdings, local: ?Holdings, weighed: Weighing) !bool {
    const with = if (local) |l| try combineHoldings(a, h.*, l) else h.*;
    for (weighed.objects) |o| if (!with.listed.contains(o)) return false;
    const held = try heldCommits(a, at, &with, weighed.commits);
    for (weighed.commits) |c| if (!held.contains(c)) return false;
    return true;
}

/// Which of `commits` a remote holds (`Holdings`): each git confirms is a
/// commit here (`commitsHere`) and that is an object a push URL lists, or
/// that one `git rev-list --ignore-missing --stdin`, fed every other such
/// commit and a `^<oid>` line for each listed object, does not print back
/// (so a listed object not here holds nothing). A read that fails, exits
/// nonzero, or is killed holds none of the commits it was fed.
fn heldCommits(a: std.mem.Allocator, at: At, h: *const Holdings, commits: []const []const u8) !std.StringHashMapUnmanaged(void) {
    var held: std.StringHashMapUnmanaged(void) = .empty;
    var left: std.ArrayList([]const u8) = .empty;
    const here = try commitsHere(a, at, commits);
    for (commits) |c| {
        if (!here.contains(c)) continue;
        if (h.listed.contains(c)) {
            try held.put(a, c, {});
        } else if (!kept.paths.contains(left.items, c)) try left.append(a, c);
    }
    if (left.items.len == 0 or h.tips.len == 0) return held;
    const res = revisions(a, at, &.{ "rev-list", "--ignore-missing", "--stdin" }, left.items, h.tips) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return held,
    };
    if (res.status != 0 or res.timed_out) return held;
    var unheld: std.StringHashMapUnmanaged(void) = .empty;
    var it = std.mem.tokenizeAny(u8, res.stdout, "\r\n");
    while (it.next()) |sha| try unheld.put(a, sha, {});
    for (left.items) |c| if (!unheld.contains(c)) try held.put(a, c, {});
    return held;
}

/// Which of `names` git confirms as commits here: those one `git rev-list
/// --no-walk --ignore-missing --stdin` prints back as they were given, so
/// a name git leaves out, a missing object or one that is not a commit, is
/// not one. A read that fails, exits nonzero, or is killed confirms none.
fn commitsHere(a: std.mem.Allocator, at: At, names: []const []const u8) !std.StringHashMapUnmanaged(void) {
    var out: std.StringHashMapUnmanaged(void) = .empty;
    if (names.len == 0) return out;
    const res = revisions(a, at, &.{ "rev-list", "--no-walk", "--ignore-missing", "--stdin" }, names, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return out,
    };
    if (res.status != 0 or res.timed_out) return out;
    var it = std.mem.tokenizeAny(u8, res.stdout, "\r\n");
    while (it.next()) |sha| try out.put(a, sha, {});
    return out;
}

/// Runs `args`, a `git rev-list ... --stdin`, in `at`, its standard input
/// a pipe holt writes a line to for each of `include` and a `^<oid>` line
/// for each of `exclude`.
fn revisions(a: std.mem.Allocator, at: At, args: []const []const u8, include: []const []const u8, exclude: []const []const u8) !git.RunResult {
    var input: std.ArrayList(u8) = .empty;
    for (include) |id| try input.print(a, "{s}\n", .{id});
    for (exclude) |id| try input.print(a, "^{s}\n", .{id});
    return at.runWithOpts(a, args, .{ .stdin_data = input.items });
}

/// Whether the full ref name `name` is a listed ref of `listings`, lies
/// under one, or has one under it, compared ignoring case, as receive-pack
/// on a case-insensitive filesystem refuses them.
fn conflicts(listings: []const []const Listed, name: []const u8) bool {
    for (listings) |listing| for (listing) |l| {
        if (l.symref != null) continue;
        const r = if (std.mem.endsWith(u8, l.ref, "^{}")) l.ref[0 .. l.ref.len - 3] else l.ref;
        if (std.ascii.eqlIgnoreCase(r, name)) return true;
        if (r.len > name.len and std.ascii.startsWithIgnoreCase(r, name) and r[name.len] == '/') return true;
        if (name.len > r.len and std.ascii.startsWithIgnoreCase(name, r) and name[r.len] == '/') return true;
    };
    return false;
}

/// Whether any listing of `listings` names `ref`.
fn anyNames(listings: []const []const Listed, ref: []const u8) bool {
    for (listings) |listing| for (listing) |l| {
        if (l.symref == null and std.mem.eql(u8, l.ref, ref)) return true;
    };
    return false;
}

/// Whether every listing of `listings`, of which there is one, names `ref`
/// with an object that is here and an ancestor of `commit`, so a push of
/// `commit` to it fast-forwards it.
fn everyFastForwards(a: std.mem.Allocator, at: At, listings: []const []const Listed, ref: []const u8, commit: ?[]const u8) !bool {
    const c = commit orelse return false;
    if (listings.len == 0) return false;
    for (listings) |listing| {
        const theirs = for (listing) |l| {
            if (l.symref == null and std.mem.eql(u8, l.ref, ref)) break l.object;
        } else return false;
        const anc = try at.run(a, &.{ "merge-base", "--is-ancestor", theirs, c });
        if (anc.status != 0) return false;
    }
    return true;
}

/// Whether a listing of `listings` has a `ref:` HEAD line (`has_head`), and
/// whether one names the branch `branch` (`is_head`), ignoring case.
const HeadBranch = struct { has_head: bool, is_head: bool };

fn headBranch(listings: []const []const Listed, branch: []const u8) HeadBranch {
    var out: HeadBranch = .{ .has_head = false, .is_head = false };
    for (listings) |listing| for (listing) |l| {
        const target = l.symref orelse continue;
        if (!std.mem.eql(u8, l.ref, "HEAD")) continue;
        out.has_head = true;
        if (std.mem.startsWith(u8, target, "refs/heads/") and std.ascii.eqlIgnoreCase(target["refs/heads/".len..], branch)) out.is_head = true;
    };
    return out;
}

/// The first of `<family>/<name>`, `...-2`, `...-3`, up to one more than
/// the refs `listings` list, then `<family>-2/<name>`, `<family>-3/<name>`,
/// ..., that does not conflict with a listed ref (`conflicts`); the first
/// of them when every one does.
fn freeName(a: std.mem.Allocator, listings: []const []const Listed, family: []const u8, name: []const u8) ![]const u8 {
    var listed: usize = 0;
    for (listings) |l| listed += l.len;
    const base = try std.fmt.allocPrint(a, "{s}/{s}", .{ family, name });
    for (1..listed + 2) |n| {
        const candidate = if (n == 1) base else try std.fmt.allocPrint(a, "{s}-{d}", .{ base, n });
        if (!conflicts(listings, candidate)) return candidate;
    }
    for (2..listed + 3) |k| {
        const candidate = try std.fmt.allocPrint(a, "{s}-{d}/{s}", .{ family, k, name });
        if (!conflicts(listings, candidate)) return candidate;
    }
    return base;
}

/// Where a push of `ref`, naming `commit` when it holds one (else another
/// object), to the target whose push URLs list `listings`, goes: a branch
/// keeps its own name when a listing has a `ref:` HEAD line that names
/// another branch, and no listing names the branch and it does not
/// conflict, or every listing names it at an ancestor of `commit`; a ref
/// outside `refs/heads` and `refs/tags` keeps its name only in that last
/// case; else the first free name (`freeName`) under
/// `refs/heads/holt-kept` for a commit, `refs/tags/holt-kept` for a tag or
/// any other object, named by the ref without `refs/heads/` for a branch
/// and without `refs/` for any other.
fn destination(a: std.mem.Allocator, at: At, listings: []const []const Listed, ref: []const u8, commit: ?[]const u8) ![]const u8 {
    if (std.mem.startsWith(u8, ref, "refs/heads/")) {
        const branch = ref["refs/heads/".len..];
        const head = headBranch(listings, branch);
        if (head.has_head and !head.is_head) {
            if (!anyNames(listings, ref) and !conflicts(listings, ref)) return ref;
            if (try everyFastForwards(a, at, listings, ref, commit)) return ref;
        }
        return freeName(a, listings, "refs/heads/holt-kept", branch);
    }
    const name = if (std.mem.startsWith(u8, ref, "refs/")) ref["refs/".len..] else ref;
    if (std.mem.startsWith(u8, ref, "refs/tags/")) return freeName(a, listings, "refs/tags/holt-kept", name);
    if (try everyFastForwards(a, at, listings, ref, commit)) return ref;
    return freeName(a, listings, if (commit != null) "refs/heads/holt-kept" else "refs/tags/holt-kept", name);
}

/// The first of `refs/heads/holt-kept/<name>` (`branch`) or
/// `refs/holt-kept/<name>`, `...-2`, `...-3`, ... that does not conflict
/// with a ref of `refs`, the refs of the repository.
fn freeLocal(a: std.mem.Allocator, refs: []const Ref, branch: bool, name: []const u8) ![]const u8 {
    var own: std.ArrayList(Listed) = .empty;
    for (refs) |r| try own.append(a, .{ .ref = r.ref, .object = r.object });
    const listings: []const []const Listed = &.{own.items};
    return freeName(a, listings, if (branch) "refs/heads/holt-kept" else "refs/holt-kept", name);
}

/// A ref of the repository weighed: what it names (`object`, of git's type
/// `kind`), the commit it holds (a tag's peeled), when it holds one, and,
/// for a branch, the remote of its upstream, and whether git has no
/// remote-tracking ref of it; the ref a symbolic ref names (`symref`,
/// empty for any other); and, for a per-worktree ref (`privateRef`), the
/// id of the working tree whose ref it is (`GitDir.id`).
const Ref = struct {
    ref: []const u8,
    kind: []const u8,
    object: []const u8,
    commit: ?[]const u8,
    upstream: []const u8,
    upstream_gone: bool,
    symref: []const u8 = "",
    worktree: ?[]const u8 = null,
};

/// A git directory of a repository: `.` for its common directory, else
/// `worktrees/<name>` for a linked working tree's record, and its real
/// path.
const GitDir = struct { id: []const u8, path: []const u8 };

/// The HEAD of a working tree (`GitDir.id`): the commit it names, null when
/// it names none yet, and, when it is symbolic, the ref it names, followed
/// through any symbolic refs.
const Head = struct { worktree: []const u8, object: ?[]const u8, target: ?[]const u8 };

/// Every ref and HEAD of a repository (`inventoryAt`): its common
/// directory, the git directory it was read through, its git directories,
/// every ref of its common directory and every per-worktree ref of each
/// working tree, and each working tree's HEAD.
const Inventory = struct {
    common_dir: []const u8,
    current_dir: []const u8,
    dirs: []const GitDir,
    refs: []const Ref,
    heads: []const Head,

    /// The id of the working tree the inventory was read through.
    fn current(s: Inventory) ![]const u8 {
        for (s.dirs) |dir| if (std.mem.eql(u8, dir.path, s.current_dir)) return dir.id;
        return error.GitFailed;
    }
};

/// Whether `ref` is a working tree's own (`refs/worktree/`, `refs/bisect/`,
/// `refs/rewritten/`), which only its git directory lists.
fn privateRef(ref: []const u8) bool {
    for ([_][]const u8{ "refs/worktree/", "refs/bisect/", "refs/rewritten/" }) |prefix| {
        if (std.mem.startsWith(u8, ref, prefix)) return true;
    }
    return false;
}

/// The inventory of the repository `at` names: its common directory's
/// refs, and, for each working tree git records (its directory gone or
/// not), its HEAD and per-worktree refs, read through its record's git
/// directory (`git --git-dir=<common>/worktrees/<id>`). `GitFailed` when
/// git cannot read any of them, or a record is a link, or does not belong
/// to the same common directory.
fn inventoryAt(a: std.mem.Allocator, at: At) !Inventory {
    const locations = try at.run(a, &.{ "rev-parse", "--path-format=absolute", "--absolute-git-dir", "--git-common-dir" });
    if (locations.status != 0) return error.GitFailed;
    var lines = std.mem.tokenizeAny(u8, locations.stdout, "\r\n");
    const current = try fsutil.realPathOrSelf(a, lines.next() orelse return error.GitFailed);
    const common = try fsutil.realPathOrSelf(a, lines.next() orelse return error.GitFailed);
    if (lines.next() != null) return error.GitFailed;
    const main: At = .{ .repo = common, .git_dir = common };
    const listing = try main.run(a, &.{ "worktree", "list", "--porcelain" });
    if (listing.status != 0) return error.GitFailed;
    var dirs: std.ArrayList(GitDir) = .empty;
    try dirs.append(a, .{ .id = ".", .path = common });
    const records = try std.fs.path.join(a, &.{ common, "worktrees" });
    if (std.Io.Dir.cwd().openDir(io(), records, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io());
        var it = dir.iterate();
        while (it.next(io()) catch return error.GitFailed) |entry| {
            if (entry.kind == .sym_link) return error.GitFailed;
            if (entry.kind != .directory) continue;
            try dirs.append(a, .{ .id = try std.mem.concat(a, u8, &.{ "worktrees/", entry.name }), .path = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ records, entry.name })) });
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.GitFailed,
    }
    std.mem.sort(GitDir, dirs.items, {}, struct {
        fn less(_: void, left: GitDir, right: GitDir) bool {
            return std.mem.lessThan(u8, left.id, right.id);
        }
    }.less);
    var refs: std.ArrayList(Ref) = .empty;
    var heads: std.ArrayList(Head) = .empty;
    var current_found = false;
    for (dirs.items) |dir| {
        const where: At = .{ .repo = dir.path, .git_dir = dir.path };
        const resolved = try where.run(a, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
        if (resolved.status != 0 or !std.mem.eql(u8, common, try fsutil.realPathOrSelf(a, std.mem.trim(u8, resolved.stdout, "\r\n")))) return error.GitFailed;
        if (std.mem.eql(u8, current, dir.path)) current_found = true;
        for (try refsOf(a, where)) |raw| {
            var ref = raw;
            if (privateRef(ref.ref)) {
                ref.worktree = dir.id;
            } else if (!std.mem.eql(u8, dir.id, ".")) continue;
            try refs.append(a, ref);
        }
        try heads.append(a, try readHead(a, where, dir.id));
    }
    if (!current_found) return error.GitFailed;
    return .{ .common_dir = common, .current_dir = current, .dirs = dirs.items, .refs = refs.items, .heads = heads.items };
}

/// The HEAD of the working tree `id` whose git directory `at` reads.
fn readHead(a: std.mem.Allocator, at: At, id: []const u8) !Head {
    const symbolic = try at.run(a, &.{ "symbolic-ref", "-q", "HEAD" });
    if (symbolic.status != 0 and symbolic.status != 1) return error.GitFailed;
    const target: ?[]const u8 = if (symbolic.status == 0) std.mem.trim(u8, symbolic.stdout, "\r\n") else null;
    const value = try at.run(a, &.{ "rev-parse", "-q", "--verify", "HEAD^{commit}" });
    if (value.status == 1 and target != null) return .{ .worktree = id, .object = null, .target = target };
    if (value.status != 0) return error.GitFailed;
    return .{ .worktree = id, .object = std.mem.trim(u8, value.stdout, "\r\n"), .target = target };
}

/// Whether `ref` is weighed: every ref but symbolic ones and `refs/stash`,
/// which has a gate of its own.
fn weighedRef(ref: Ref) bool {
    return ref.symref.len == 0 and !std.mem.eql(u8, ref.ref, "refs/stash");
}

/// The name a line gives the working tree `id` (`GitDir.id`): the name of
/// its record.
fn worktreeName(id: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, id, "worktrees/")) id["worktrees/".len..] else id;
}

/// The refs of one remote under `refs/remotes/<remote>/` and
/// `refs/prefetch/remotes/<remote>/` at risk (`Risk.remote_refs`): their
/// names, and one ref for each distinct object, a `refs/remotes` one
/// before a `refs/prefetch` one.
const Grouped = struct { remote: []const u8, refs: std.ArrayList([]const u8) = .empty, sources: std.ArrayList(Ref) = .empty };

fn addGrouped(a: std.mem.Allocator, grouped: *std.ArrayList(Grouped), remote: []const u8, r: Ref) !void {
    const g = for (grouped.items) |*g| {
        if (std.mem.eql(u8, g.remote, remote)) break g;
    } else blk: {
        try grouped.append(a, .{ .remote = remote });
        break :blk &grouped.items[grouped.items.len - 1];
    };
    try g.refs.append(a, r.ref);
    for (g.sources.items) |*src| if (std.mem.eql(u8, src.object, r.object)) {
        if (std.mem.startsWith(u8, r.ref, "refs/remotes/") and !std.mem.startsWith(u8, src.ref, "refs/remotes/")) src.* = r;
        return;
    };
    try g.sources.append(a, r);
}

/// The listed remote (one of `remotes`) whose `refs/remotes/<remote>/` or
/// `refs/prefetch/remotes/<remote>/` holds `ref`, the longest name when
/// several would.
fn remoteOfRef(ref: []const u8, remotes: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for ([_][]const u8{ "refs/remotes/", "refs/prefetch/remotes/" }) |pre| {
        if (!std.mem.startsWith(u8, ref, pre)) continue;
        const rest = ref[pre.len..];
        for (remotes) |r| {
            if (rest.len > r.len + 1 and std.mem.startsWith(u8, rest, r) and rest[r.len] == '/') {
                if (best == null or r.len > best.?.len) best = r;
            }
        }
    }
    return best;
}

/// Replaces every risk of `out` with no target by one line (`no_target`)
/// naming the refs: each ref's full name, `worktrees/<W>/<ref>` for a
/// per-worktree ref, `HEAD` or `worktrees/<W>/HEAD` for a HEAD.
fn gatherNoTarget(asker: Asker, at: At, remotes: Remotes, answered: bool, out: *std.ArrayList(Risk)) !void {
    const a = asker.alloc;
    var refs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < out.items.len) {
        const x = out.items[i];
        const name: ?[]const []const u8 = switch (x.what) {
            .ahead => &.{x.src.?},
            .ref_unheld, .object_unheld => &.{if (x.worktree) |w| try std.fmt.allocPrint(a, "worktrees/{s}/{s}", .{ w, x.name }) else x.name},
            .head_unheld => &.{if (x.worktree) |w| try std.fmt.allocPrint(a, "worktrees/{s}/HEAD", .{w}) else "HEAD"},
            .remote_refs => x.refs,
            else => null,
        };
        if (name) |n| {
            try refs.appendSlice(a, n);
            _ = out.orderedRemove(i);
        } else i += 1;
    }
    if (refs.items.len == 0) return;
    var gone: std.ArrayList(GoneRemote) = .empty;
    const rules = try rewriteRules(a, at);
    for (remotes.all_gone) |g| {
        var copy = g;
        copy.edit_alone = try editAlone(asker, at, remotes.scope, g, rules);
        try gone.append(a, copy);
    }
    try out.append(a, .{ .what = .no_target, .refs = refs.items, .gone = gone.items, .add_name = try freeRemote(a, at, remotes), .answered = answered });
}

/// The name `git remote add` gives a new remote in the hint: `origin`
/// when no remote has it, else the first of `holt-kept`, `holt-kept-2`,
/// ..., each free only when `git remote` does not list it and `git remote
/// get-url` knows no remote of that name either (exit 2).
fn freeRemote(a: std.mem.Allocator, at: At, remotes: Remotes) ![]const u8 {
    const listed = try remotes.names(a);
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const name = if (n == 0) "origin" else if (n == 1) "holt-kept" else try std.fmt.allocPrint(a, "holt-kept-{d}", .{n});
        if (kept.paths.contains(listed, name)) continue;
        const got = try at.run(a, &.{ "remote", "get-url", "--", name });
        if (got.status == 2) return name;
    }
    return "holt-kept";
}

/// A `url.<base>.insteadOf` or `pushInsteadOf` rule: its prefix and base.
const Rule = struct { prefix: []const u8, base: []const u8, push: bool };

fn rewriteRules(a: std.mem.Allocator, at: At) ![]const Rule {
    const res = try at.run(a, &.{ "config", "-z", "--get-regexp", "^url\\..*\\.(push)?insteadof$" });
    var out: std.ArrayList(Rule) = .empty;
    if (res.status != 0) return out.items;
    var it = std.mem.splitScalar(u8, res.stdout, 0);
    while (it.next()) |entry| {
        const nl = std.mem.indexOfScalar(u8, entry, '\n') orelse continue;
        const key = entry[0..nl];
        const push = std.mem.endsWith(u8, key, ".pushinsteadof");
        const suffix: usize = if (push) ".pushinsteadof".len else ".insteadof".len;
        if (!std.mem.startsWith(u8, key, "url.") or key.len <= "url.".len + suffix) continue;
        try out.append(a, .{ .prefix = entry[nl + 1 ..], .base = key["url.".len .. key.len - suffix], .push = push });
    }
    return out.items;
}

/// `v` rewritten by the longest rule of `rules` of the kind `push` whose
/// prefix it starts with; null when none matches.
fn rewrite(a: std.mem.Allocator, rules: []const Rule, v: []const u8, push: bool) !?[]const u8 {
    var best: ?Rule = null;
    for (rules) |r| {
        if (r.push != push or r.prefix.len == 0 or !std.mem.startsWith(u8, v, r.prefix)) continue;
        if (best == null or r.prefix.len > best.?.prefix.len) best = r;
    }
    const r = best orelse return null;
    return try std.mem.concat(a, u8, &.{ r.base, v[r.prefix.len..] });
}

/// Whether the edit the clause of `g` hints leaves push URLs that all
/// count and all answered this weighing: the push URLs that follow, as
/// git reads them from the values left (B1 of the delete-gate paper): the
/// `pushurl` values left, `insteadOf` applied; else the `url` values a
/// `pushInsteadOf` rule matches, rewritten, when any does; else the `url`
/// values, `insteadOf` applied.
fn editAlone(asker: Asker, at: At, scope: []const u8, g: GoneRemote, rules: []const Rule) !bool {
    const a = asker.alloc;
    var pushurls: std.ArrayList([]const u8) = .empty;
    var urls: std.ArrayList([]const u8) = .empty;
    switch (g.why) {
        .no_url => {
            for ([_][]const u8{ "pushurl", "url" }, [_]*std.ArrayList([]const u8){ &pushurls, &urls }) |field, list| {
                const got = try at.run(a, &.{ "config", "-z", "--get-all", try std.fmt.allocPrint(a, "remote.{s}.{s}", .{ g.name, field }) });
                if (got.status != 0) continue;
                var it = std.mem.splitScalar(u8, got.stdout, 0);
                while (it.next()) |v| if (v.len > 0) try list.append(a, v);
            }
        },
        .local => if (g.push_only and g.push) {
            const got = try at.run(a, &.{ "config", "-z", "--get-all", try std.fmt.allocPrint(a, "remote.{s}.url", .{g.name}) });
            if (got.status == 0) {
                var it = std.mem.splitScalar(u8, got.stdout, 0);
                while (it.next()) |v| if (v.len > 0) try urls.append(a, v);
            }
        } else return false,
        else => return false,
    }
    var follow: std.ArrayList([]const u8) = .empty;
    if (pushurls.items.len > 0) {
        for (pushurls.items) |v| try follow.append(a, (try rewrite(a, rules, v, false)) orelse v);
    } else {
        for (urls.items) |v| if (try rewrite(a, rules, v, true)) |w| try follow.append(a, w);
        if (follow.items.len == 0) for (urls.items) |v| try follow.append(a, (try rewrite(a, rules, v, false)) orelse v);
    }
    if (follow.items.len == 0) return false;
    for (follow.items) |u| {
        if (!try counts(a, at, u)) return false;
        const answer = (try asker.answerOf(scope, u)) orelse return false;
        if (answer != .listed) return false;
    }
    return true;
}

/// The refs at risk whose target has push URLs that did not answer
/// (`Holdings.unasked`): each goes into the line of each such URL, in
/// the same order.
const Unconfirmed = struct {
    unasked: []const Unasked,
    refs: []std.ArrayList([]const u8),

    /// Adds `ref` to the line of each push URL of `target` that did not
    /// answer; whether there is one.
    fn take(u: *Unconfirmed, a: std.mem.Allocator, target: ?[]const u8, ref: []const u8) !bool {
        const t = target orelse return false;
        var taken = false;
        for (u.unasked, u.refs) |x, *list| if (std.mem.eql(u8, x.remote, t)) {
            try list.append(a, ref);
            taken = true;
        };
        return taken;
    }
};

/// Whether every counting URL of the repository's remotes
/// (`Remotes.counting`) answered this weighing.
fn allAnswered(asker: Asker, remotes: Remotes) !bool {
    for (remotes.counting) |u| {
        const answer = (try asker.answerOf(remotes.scope, u)) orelse return false;
        if (answer != .listed) return false;
    }
    return true;
}

fn risksOf(asker: Asker, at: At) ![]const Risk {
    const a = asker.alloc;
    var out: std.ArrayList(Risk) = .empty;
    const remotes = remotesOf(a, at) catch |err| switch (err) {
        error.GitFailed => {
            try out.append(a, .{ .what = .unreadable });
            return out.items;
        },
        else => return err,
    };
    const first_remote = remotes.target(null, null);
    const stash = try at.run(a, &.{ "rev-parse", "-q", "--verify", "refs/stash" });
    switch (stash.status) {
        0 => try out.append(a, .{ .what = .stashes }),
        1 => {},
        else => try out.append(a, .{ .what = .unreadable }),
    }
    if (inventoryAt(a, at)) |state| {
        const refs = state.refs;
        var commits: std.ArrayList([]const u8) = .empty;
        var objects: std.ArrayList([]const u8) = .empty;
        var targets: std.ArrayList([]const u8) = .empty;
        for (refs) |r| if (weighedRef(r)) {
            if (r.commit) |c| try commits.append(a, c);
            if (!std.mem.eql(u8, r.kind, "commit")) try objects.append(a, r.object);
            const branch = if (r.worktree == null and std.mem.startsWith(u8, r.ref, "refs/heads/")) r.ref["refs/heads/".len..] else null;
            if (remotes.target(branch, if (r.upstream.len > 0) r.upstream else null)) |t| if (!kept.paths.contains(targets.items, t)) try targets.append(a, t);
        };
        for (state.heads) |head| if (head.object) |c| try commits.append(a, c);
        if (first_remote) |t| if (state.heads.len > 0 and !kept.paths.contains(targets.items, t)) try targets.append(a, t);
        const h = try askPlan(asker, at, remotes, .{ .commits = commits.items, .objects = objects.items, .targets = targets.items }, null);
        const held = try heldCommits(a, at, &h, commits.items);
        const names = try remotes.names(a);
        const answered = try allAnswered(asker, remotes);
        var unconfirmed: Unconfirmed = .{ .unasked = h.unasked, .refs = try a.alloc(std.ArrayList([]const u8), h.unasked.len) };
        for (unconfirmed.refs) |*l| l.* = .empty;
        var grouped: std.ArrayList(Grouped) = .empty;
        for (refs) |r| {
            if (!weighedRef(r)) continue;
            const lost = if (r.commit) |c| !held.contains(c) else false;
            const exact = !std.mem.eql(u8, r.kind, "commit");
            if (!lost and !(exact and !h.listed.contains(r.object))) continue;
            if (std.mem.startsWith(u8, r.ref, "refs/heads/") and r.worktree == null) {
                const name = r.ref["refs/heads/".len..];
                const tgt = remotes.target(name, if (r.upstream.len > 0) r.upstream else null);
                if (try unconfirmed.take(a, tgt, r.ref)) continue;
                const dst = if (tgt) |remote| try destination(a, at, h.listingsOf(remotes, remote), r.ref, r.commit) else null;
                try out.append(a, .{ .what = .ahead, .name = name, .src = r.ref, .remote = tgt, .dst = dst, .answered = answered });
                continue;
            }
            if (r.worktree) |w| {
                if (try unconfirmed.take(a, first_remote, try std.fmt.allocPrint(a, "worktrees/{s}/{s}", .{ worktreeName(w), r.ref }))) continue;
                const family_name = try std.fmt.allocPrint(a, "{s}/{s}", .{ worktreeName(w), r.ref["refs/".len..] });
                const dst = if (first_remote) |remote| try freeName(a, h.listingsOf(remotes, remote), if (exact) "refs/tags/holt-kept" else "refs/heads/holt-kept", family_name) else null;
                try out.append(a, .{ .what = if (exact) .object_unheld else .ref_unheld, .name = r.ref, .src = r.object, .worktree = worktreeName(w), .remote = first_remote, .kind = r.kind, .dst = dst, .answered = answered });
                continue;
            }
            if (try unconfirmed.take(a, first_remote, r.ref)) continue;
            if (!exact) if (remoteOfRef(r.ref, names)) |owner| {
                try addGrouped(a, &grouped, owner, r);
                continue;
            };
            const dst = if (first_remote) |remote| try destination(a, at, h.listingsOf(remotes, remote), r.ref, if (exact) null else r.commit) else null;
            try out.append(a, .{ .what = if (exact) .object_unheld else .ref_unheld, .name = r.ref, .src = r.ref, .remote = first_remote, .kind = r.kind, .dst = dst, .answered = answered });
        }
        for (grouped.items) |g| {
            var pushes: std.ArrayList([2][]const u8) = .empty;
            if (first_remote) |remote| for (g.sources.items) |ref| {
                try pushes.append(a, .{ ref.ref, try destination(a, at, h.listingsOf(remotes, remote), ref.ref, ref.commit) });
            };
            try out.append(a, .{ .what = .remote_refs, .name = g.remote, .refs = g.refs.items, .pushes = pushes.items, .remote = first_remote, .answered = answered });
        }
        const own = try refsHoldings(a, refs, null);
        const covered = try heldCommits(a, at, &own, commits.items);
        for (state.heads) |head| if (head.object) |object| {
            if (held.contains(object) or covered.contains(object)) continue;
            const linked = !std.mem.eql(u8, head.worktree, ".");
            if (try unconfirmed.take(a, first_remote, if (linked) try std.fmt.allocPrint(a, "worktrees/{s}/HEAD", .{worktreeName(head.worktree)}) else "HEAD")) continue;
            const dst = if (first_remote) |remote| try freeName(a, h.listingsOf(remotes, remote), "refs/heads/holt-kept", try std.fmt.allocPrint(a, "head-{s}", .{object[0..@min(12, object.len)]})) else null;
            try out.append(a, .{ .what = .head_unheld, .name = object, .src = object, .worktree = if (linked) worktreeName(head.worktree) else null, .remote = first_remote, .dst = dst, .answered = answered });
        };
        for (h.unasked, unconfirmed.refs) |u, taken| {
            if (taken.items.len == 0) continue;
            if (try mergeUnasked(a, out.items, u, taken.items)) continue;
            try out.append(a, .{ .what = .unasked, .remote = u.remote, .url = u.url, .why = u.why.why, .refs = taken.items, .value = u.value, .silent_host = u.why.host, .class = u.why.class, .values = u.values, .pushurl = u.pushurl, .mapped = u.mapped, .others_answered = u.others_answered });
        }
        if (first_remote == null) try gatherNoTarget(asker, at, remotes, answered, &out);
        const refused = for (out.items) |x| switch (x.what) {
            .unasked, .no_target => break true,
            else => {},
        } else false;
        if (refused and h.notes.len > 0) try out.append(a, .{ .what = .note, .notes = h.notes });
    } else |err| switch (err) {
        error.GitFailed => try out.append(a, .{ .what = .unreadable }),
        else => return err,
    }
    return out.items;
}

/// Names the push URL `u`, which did not answer and holds back `refs`, on
/// the line in `out` of another push URL of the same remote with the same
/// skip key (`skipKey`: transport, host, and port, so never across ports)
/// that did not answer for a reason of the same class, holding back the
/// same refs, when neither reason is one only a removal or repoint
/// settles (`Class.persistent`) and at most one of them is not the host
/// skip's; the line then gives that reason. Whether it did.
fn mergeUnasked(a: std.mem.Allocator, out: []Risk, u: Unasked, refs: []const []const u8) !bool {
    if (u.why.class == .persistent) return false;
    const key = try skipKey(a, remote_url.parse(u.url));
    for (out) |*x| {
        if (x.what != .unasked or x.class != u.why.class or !std.mem.eql(u8, x.remote orelse "", u.remote)) continue;
        if (!std.mem.eql(u8, try skipKey(a, remote_url.parse(x.url)), key)) continue;
        if (x.refs.len != refs.len) continue;
        const same = for (x.refs, refs) |l, r| {
            if (!std.mem.eql(u8, l, r)) break false;
        } else true;
        if (!same) continue;
        if (x.silent_host == null and u.why.host == null and !std.mem.eql(u8, x.why, u.why.why)) continue;
        x.more_urls = try std.mem.concat(a, []const u8, &.{ x.more_urls, &.{u.url} });
        if (u.why.host == null) {
            x.why = u.why.why;
            x.silent_host = null;
        }
        return true;
    }
    return false;
}

/// Every ref `git for-each-ref` lists in the git directory `at` reads,
/// symbolic ones and `refs/stash` included. `GitFailed` when git cannot
/// list them.
fn refsOf(a: std.mem.Allocator, at: At) ![]const Ref {
    const res = try at.run(a, &.{ "for-each-ref", "--format=%(refname)%00%(objecttype)%00%(objectname)%00%(symref)%00%(*objecttype)%00%(*objectname)%00%(upstream:remotename)%00%(upstream:track)" });
    if (res.status != 0) return error.GitFailed;
    var out: std.ArrayList(Ref) = .empty;
    var it = std.mem.tokenizeAny(u8, res.stdout, "\r\n");
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, 0);
        const ref = f.next() orelse continue;
        const kind = f.next() orelse "";
        const obj = f.next() orelse "";
        const symref = f.next() orelse "";
        const peeled_kind = f.next() orelse "";
        const peeled = f.next() orelse "";
        const upstream = f.next() orelse "";
        const track = f.next() orelse "";
        const commit: ?[]const u8 = if (std.mem.eql(u8, kind, "commit")) obj else if (std.mem.eql(u8, peeled_kind, "commit")) peeled else null;
        try out.append(a, .{ .ref = ref, .kind = kind, .object = obj, .commit = commit, .upstream = upstream, .upstream_gone = std.mem.indexOf(u8, track, "gone") != null, .symref = symref });
    }
    return out.items;
}

/// The objects the refs `refs` name, as `Holdings` of what a remote lists,
/// symbolic refs left out, and, with `removed`, the per-worktree refs of
/// that working tree.
fn refsHoldings(a: std.mem.Allocator, refs: []const Ref, removed: ?[]const u8) !Holdings {
    var out: Holdings = .{};
    var tips: std.ArrayList([]const u8) = .empty;
    for (refs) |ref| {
        if (ref.symref.len > 0) continue;
        if (removed) |id| if (ref.worktree) |tree| {
            if (std.mem.eql(u8, tree, id)) continue;
        };
        if (out.listed.contains(ref.object)) continue;
        try out.listed.put(a, ref.object, {});
        try tips.append(a, ref.object);
    }
    out.tips = tips.items;
    return out;
}

/// `remote` and `local` together.
fn combineHoldings(a: std.mem.Allocator, remote: Holdings, local: Holdings) !Holdings {
    var out: Holdings = .{ .tips = try std.mem.concat(a, []const u8, &.{ remote.tips, local.tips }) };
    var remotes = remote.listed.keyIterator();
    while (remotes.next()) |object| try out.listed.put(a, object.*, {});
    var locals = local.listed.keyIterator();
    while (locals.next()) |object| try out.listed.put(a, object.*, {});
    return out;
}

/// What removing the linked working tree `repo` destroys that no remote
/// holds (`worktree -r`): its HEAD and its per-worktree refs, each held
/// when a remote holds it or a ref that survives the removal does: every
/// ref of the common directory and the per-worktree refs of the other
/// working trees.
/// `GitFailed` when git cannot read them.
pub fn worktreeRisks(asker: Asker, repo: []const u8) ![]const Risk {
    return worktreeRisksAt(asker, .{ .repo = repo });
}

/// `worktreeRisks` of the linked working tree whose git directory `at`
/// reads.
fn worktreeRisksAt(asker: Asker, at: At) ![]const Risk {
    const a = asker.alloc;
    const state = try inventoryAt(a, at);
    const id = try state.current();
    const remotes = try remotesOf(a, at);
    const local = try refsHoldings(a, state.refs, id);
    var commits: std.ArrayList([]const u8) = .empty;
    var objects: std.ArrayList([]const u8) = .empty;
    for (state.refs) |ref| {
        if (!weighedRef(ref) or !std.mem.eql(u8, ref.worktree orelse "", id)) continue;
        if (ref.commit) |c| try commits.append(a, c);
        if (!std.mem.eql(u8, ref.kind, "commit")) try objects.append(a, ref.object);
    }
    for (state.heads) |head| if (std.mem.eql(u8, head.worktree, id)) {
        if (head.object) |c| try commits.append(a, c);
    };
    const targets: []const []const u8 = if (remotes.target(null, null)) |t| &.{t} else &.{};
    const remote = try askPlan(asker, at, remotes, .{ .commits = commits.items, .objects = objects.items, .targets = targets }, local);
    const combined = try combineHoldings(a, remote, local);
    const held = try heldCommits(a, at, &combined, commits.items);
    var out: std.ArrayList(Risk) = .empty;
    for (state.refs) |ref| {
        if (!weighedRef(ref) or !std.mem.eql(u8, ref.worktree orelse "", id)) continue;
        const lost = if (ref.commit) |c| !held.contains(c) else false;
        const exact = !std.mem.eql(u8, ref.kind, "commit");
        if (!lost and !(exact and !combined.listed.contains(ref.object))) continue;
        const keep = try freeLocal(a, state.refs, false, try std.fmt.allocPrint(a, "{s}/{s}", .{ worktreeName(id), ref.ref["refs/".len..] }));
        try out.append(a, .{ .what = if (exact) .object_unheld else .ref_unheld, .name = ref.ref, .src = ref.object, .worktree = worktreeName(id), .kind = ref.kind, .keep = keep, .answered = try allAnswered(asker, remotes) });
    }
    for (state.heads) |head| if (std.mem.eql(u8, head.worktree, id)) {
        if (head.object) |object| if (!held.contains(object)) {
            const keep = try freeLocal(a, state.refs, true, try std.fmt.allocPrint(a, "head-{s}", .{object[0..@min(12, object.len)]}));
            try out.append(a, .{ .what = .head_unheld, .name = object, .src = object, .worktree = worktreeName(id), .keep = keep, .answered = try allAnswered(asker, remotes) });
        };
    };
    return out.items;
}

/// An operation git has in progress in a git directory: what it holds is
/// in no ref (a paused `rebase --autostash` keeps the change only in
/// `rebase-merge/autostash`, `am` its unapplied patches in
/// `rebase-apply/`), so deleting the directory loses it.
pub const InProgress = struct {
    /// The working tree it is in progress in, which a command reaches as
    /// `git -C <tree>`; for one in a git directory with no working tree
    /// (`no_tree`), that git directory.
    tree: []const u8,
    /// It is in progress in a submodule git directory that names no
    /// working tree (no `core.worktree`), where git can neither finish nor
    /// abort it: only deleting the directory settles it.
    no_tree: bool = false,
    op: Op,
    /// The autostash it holds, a commit id; null when it holds none.
    autostash: ?[]const u8 = null,
    /// For a linked working tree, how it stands to its record, `record`
    /// (`linkOf`); for a submodule git directory, how the working tree its
    /// `core.worktree` names stands, `record` being that git directory.
    /// One that is `.absent` is reached again only through `relinkCmd`
    /// (`opLine`). Only a submodule git directory's is `.unresolved`, when
    /// its `core.worktree` names something that is not a directory, a
    /// symlink to nothing, or a path that cannot be read, as `seen` says;
    /// holt leaves that to the user and refuses the delete.
    link: Link = .there,
    record: []const u8 = "",
    seen: ?[]const u8 = null,
    /// `record` is a submodule git directory, not a linked working tree's
    /// record.
    module: bool = false,

    pub const Op = enum { merge, rebase, am, cherry_pick, revert, bisect };

    /// The command git names the operation by.
    pub fn name(x: InProgress) []const u8 {
        return switch (x.op) {
            .cherry_pick => "cherry-pick",
            else => @tagName(x.op),
        };
    }
};

/// The operations in progress in the git directory `dir` of the working
/// tree `tree`, as `git status` tells them: a merge (`MERGE_HEAD`,
/// `MERGE_AUTOSTASH`), else a rebase or `am` (`rebase-merge/`,
/// `rebase-apply/`); a cherry-pick or revert (`CHERRY_PICK_HEAD`,
/// `REVERT_HEAD`, `sequencer/`) unless a rebase is; and a bisect
/// (`BISECT_LOG`). `GitFailed` when `dir` cannot be read.
pub fn inProgress(a: std.mem.Allocator, dir: []const u8, tree: []const u8, no_tree: bool) ![]const InProgress {
    const has = struct {
        fn at(al: std.mem.Allocator, d: []const u8, rel: []const u8) !bool {
            const e = kept.content.entryAt(try std.fs.path.join(al, &.{ d, rel })) catch return error.GitFailed;
            return e != .absent;
        }
        fn stash(al: std.mem.Allocator, d: []const u8, rel: []const u8) !?[]const u8 {
            const text = kept.content.readSmall(al, try std.fs.path.join(al, &.{ d, rel })) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.FileNotFound => return null,
                else => return error.GitFailed,
            };
            const id = std.mem.trim(u8, text, " \t\r\n");
            return if (id.len == 0) null else id;
        }
    };
    var out: std.ArrayList(InProgress) = .empty;
    const base: InProgress = .{ .tree = tree, .no_tree = no_tree, .op = .merge };
    var rebasing = false;
    if (try has.at(a, dir, "MERGE_HEAD") or try has.at(a, dir, "MERGE_AUTOSTASH")) {
        var x = base;
        x.autostash = try has.stash(a, dir, "MERGE_AUTOSTASH");
        try out.append(a, x);
    } else for ([_][]const u8{ "rebase-apply", "rebase-merge" }) |state| if (try has.at(a, dir, state)) {
        rebasing = true;
        var x = base;
        x.op = if (std.mem.eql(u8, state, "rebase-apply") and try has.at(a, dir, "rebase-apply/applying")) .am else .rebase;
        x.autostash = try has.stash(a, dir, try std.mem.concat(a, u8, &.{ state, "/autostash" }));
        try out.append(a, x);
        break;
    };
    if (!rebasing) {
        var pick = try has.at(a, dir, "CHERRY_PICK_HEAD");
        var revert = try has.at(a, dir, "REVERT_HEAD");
        if (!pick and !revert and try has.at(a, dir, "sequencer")) {
            const todo = kept.content.readSmall(a, try std.fs.path.join(a, &.{ dir, "sequencer", "todo" })) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => "",
            };
            const first = std.mem.trimStart(u8, todo, " \t\r\n");
            if (std.mem.startsWith(u8, first, "revert")) revert = true else pick = true;
        }
        if (pick) {
            var x = base;
            x.op = .cherry_pick;
            try out.append(a, x);
        }
        if (revert) {
            var x = base;
            x.op = .revert;
            try out.append(a, x);
        }
    }
    if (try has.at(a, dir, "BISECT_LOG")) {
        var x = base;
        x.op = .bisect;
        try out.append(a, x);
    }
    return out.items;
}

/// `x` as a line names it, with the commands that finish or abort it:
/// `<op> in progress in <tree>; finish it or abort it (run: git -C <tree>
/// <op> --continue, or git -C <tree> <op> --abort)`, `bisect reset` for a
/// bisect. For one in a git directory with no working tree (`no_tree`),
/// no command: `force` names what deletes it.
pub fn inProgressLine(ctx: *app.Ctx, x: InProgress, force: []const u8) ![]const u8 {
    const a = ctx.alloc;
    if (x.no_tree) return std.fmt.allocPrint(a, "{s} in progress in {s}, a submodule git directory with no working tree, where git can neither finish nor abort it; {s} deletes it", .{ x.name(), try show(ctx, x.tree), force });
    const git_in = try std.fmt.allocPrint(a, "git -C {s}", .{try q(ctx, x.tree)});
    const head = try std.fmt.allocPrint(a, "{s} in progress in {s}; finish it or abort it", .{ x.name(), try show(ctx, x.tree) });
    if (x.op == .bisect) return std.fmt.allocPrint(a, "{s} (run: {s} bisect reset)", .{ head, git_in });
    return std.fmt.allocPrint(a, "{s} (run: {s} {s} --continue, or {s} {s} --abort)", .{ head, git_in, x.name(), git_in, x.name() });
}

/// What `--force` names as lost with `x`: the operation, and its
/// autostash when it holds one.
pub fn inProgressLost(ctx: *app.Ctx, x: InProgress) ![]const u8 {
    const with: []const u8 = if (x.autostash) |id| try std.fmt.allocPrint(ctx.alloc, ", with its autostash {s}", .{id}) else "";
    return std.fmt.allocPrint(ctx.alloc, "the {s} in progress in {s}{s}", .{ x.name(), try show(ctx, x.tree), with });
}

/// `x` as a line names it: `inProgressLine` for one in a working tree
/// that is there, or in a git directory with no working tree, `force`
/// naming what deletes it; for one in a working tree that is gone, the
/// command bringing the tree back from its record, or from its git
/// directory for a submodule's (`relinkCmd`), where it is then finished or
/// aborted. For one in a submodule git directory whose `core.worktree`
/// holt leaves to the user (`InProgress.seen`), what is seen there, and no
/// command: `<git dir>: a submodule git directory with a <op> in progress,
/// whose core.worktree names <tree>, <seen>; holt does not change it:
/// resolve it with git (git config --file <git dir>/config
/// core.worktree), then run again`; the config is read as a file, since
/// `git --git-dir` there fails to enter that working tree.
pub fn opLine(ctx: *app.Ctx, x: InProgress, force: []const u8) ![]const u8 {
    if (x.seen) |seen| {
        const gq = try q(ctx, x.record);
        const what = try std.fmt.allocPrint(ctx.alloc, "a submodule git directory with a {s} in progress, whose core.worktree names {s}, {s}", .{ x.name(), try show(ctx, x.tree), seen });
        const config = try q(ctx, try std.fs.path.join(ctx.alloc, &.{ x.record, "config" }));
        return std.fmt.allocPrint(ctx.alloc, "{s}: {s}", .{ gq, try leftWhat(ctx, what, try std.fmt.allocPrint(ctx.alloc, "git config --file {s} core.worktree", .{config})) });
    }
    if (x.link != .absent) return inProgressLine(ctx, x, force);
    return std.fmt.allocPrint(ctx.alloc, "{s} in progress in {s}, which is gone; bring it back from its {s}, then finish it or abort it there (run: {s})", .{ x.name(), try show(ctx, x.tree), if (x.module) "git directory" else "record", try relinkCmd(ctx, x.tree, x.record, true) });
}

/// How a linked working tree stands to its record.
pub const Link = enum {
    /// Its directory is there, and git there finds its record.
    there,
    /// Nothing is at its path, and a directory can be made there.
    absent,
    /// Something is at its path, but git there does not find its record:
    /// it is not a directory, or holds no `.git`, or a `.git` that leads to
    /// no git directory or to another one; or nothing is, but its path lies
    /// under something that is not a directory (`linkSeen`). holt neither
    /// weighs nor changes it, and leaves it to the user (`unresolvedLine`).
    unresolved,
};

/// How the linked working tree at `path`, whose record is `record` in the
/// common directory `common_dir`, stands to its record; a symlink at
/// `path` is followed. What cannot be read there is `.unresolved`.
pub fn linkOf(a: std.mem.Allocator, common_dir: []const u8, record: []const u8, path: []const u8) !Link {
    const dir = switch (kept.content.entryAt(path) catch return .unresolved) {
        .absent => return if (kept.content.underNonDir(path) catch true) .unresolved else .absent,
        .dir => path,
        .symlink => blk: {
            const real = fsutil.realPathOrSelf(a, path) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return .unresolved,
            };
            if ((kept.content.entryAt(real) catch return .unresolved) != .dir) return .unresolved;
            break :blk real;
        },
        else => return .unresolved,
    };
    if ((kept.content.entryAt(try std.fs.path.join(a, &.{ dir, ".git" })) catch return .unresolved) == .absent) return .unresolved;
    return if (try kept.clone.leadsBack(a, dir, common_dir, record)) .there else .unresolved;
}

/// What git and holt see at `path`, the linked working tree whose record
/// is `record` in the common directory `common_dir`, when it is
/// `Link.unresolved`; null when it is `.there` or `.absent`. A `.git` file
/// is read as git reads it, relative to the real path of the directory
/// holding it.
pub fn linkSeen(a: std.mem.Allocator, common_dir: []const u8, record: []const u8, path: []const u8) !?[]const u8 {
    if (try linkOf(a, common_dir, record, path) != .unresolved) return null;
    const unreadable = "a linked working tree whose path cannot be read";
    const not_dir = "a linked working tree whose path holds something that is not a directory";
    const other_dir = "a linked working tree whose .git leads to another git directory than its record";
    switch (kept.content.entryAt(path) catch return unreadable) {
        .dir, .symlink => {},
        .absent => return if (kept.content.underNonDir(path) catch return unreadable) "a linked working tree whose path lies under something that is not a directory" else unreadable,
        else => return not_dir,
    }
    const dir = fsutil.realPathOrSelf(a, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return unreadable,
    };
    switch (kept.content.entryAt(dir) catch return unreadable) {
        .dir => {},
        .absent, .symlink => return "a linked working tree whose path is a symlink to nothing",
        else => return not_dir,
    }
    const dot_git = try std.fs.path.join(a, &.{ dir, ".git" });
    const link = switch (kept.content.entryAt(dot_git) catch return unreadable) {
        .absent => return "a linked working tree whose .git is gone",
        .file => dot_git,
        .dir => return other_dir,
        .symlink => blk: {
            const real = fsutil.realPathOrSelf(a, dot_git) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return unreadable,
            };
            switch (kept.content.entryAt(real) catch return unreadable) {
                .file => break :blk real,
                .dir => return other_dir,
                .absent, .symlink => return "a linked working tree whose .git is a symlink to nothing",
                else => return "a linked working tree whose .git is neither a file nor a directory",
            }
        },
        else => return "a linked working tree whose .git is neither a file nor a directory",
    };
    const text = kept.content.readSmall(a, link) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return "a linked working tree whose .git cannot be read",
    };
    const line = std.mem.trimEnd(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "gitdir: ")) return "a linked working tree whose .git does not read as a link to a git directory";
    const named = try std.fs.path.resolve(a, &.{ dir, line["gitdir: ".len..] });
    if ((kept.content.entryAt(named) catch return unreadable) == .absent) return "a linked working tree whose .git names a git directory that is not there";
    const own = std.mem.eql(u8, resolvedPath(a, named) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return unreadable,
    }, try resolvedPath(a, record));
    return if (own) "a linked working tree whose .git names its record, which git cannot open there" else other_dir;
}

/// What git and holt see at a path more than one record names, as a
/// copied record leaves, where `git worktree remove` may reach any of them.
pub const shared_seen = "a linked working tree whose path more than one worktree record names";

/// What git and holt see at a record holding no `gitdir`, as `git worktree
/// add` leaves one half made.
pub const half_made_seen = "a half-made worktree record, which names no working tree and which git worktree list leaves out";

/// What git and holt see at a record whose `gitdir` cannot be read.
pub const record_unreadable_seen = "a linked working tree whose record git cannot read, which git worktree list leaves out";

/// What git and holt see at the record `u`, which git's worktree list
/// leaves out.
pub fn unlistedSeen(u: kept.clone.Unlisted) []const u8 {
    return switch (u.why) {
        .no_gitdir => half_made_seen,
        .unreadable => record_unreadable_seen,
    };
}

/// The records of the common directory `common` that git's worktree list
/// leaves out (`kept.clone.unlistedRecords`), each of which holt leaves to
/// the user (`unresolvedLine`, naming the record). `GitFailed` when the
/// records cannot be read.
pub fn unlistedRecords(a: std.mem.Allocator, common: []const u8) ![]const kept.clone.Unlisted {
    return kept.clone.unlistedRecords(a, common) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.GitFailed,
    };
}

/// What git and holt see at the path of the record `rec`, one of
/// `records`, all of the common directory `common_dir`, when holt leaves
/// it to the user: another of `records` names its path too
/// (`shared_seen`), or it is `Link.unresolved` (`linkSeen`); null when
/// holt weighs and removes it, and for a record whose path cannot be read.
pub fn unresolvedSeen(a: std.mem.Allocator, common_dir: []const u8, records: []const kept.clone.Record, rec: kept.clone.Record) !?[]const u8 {
    const path = rec.path orelse return null;
    if ((try recordsNaming(a, records, path)).len > 1) return shared_seen;
    return linkSeen(a, common_dir, rec.record, path);
}

/// The line naming the linked working tree, or record, at `path` that holt
/// leaves to the user, `seen` saying what git and holt see there, and
/// `git_in` the git that reaches its repository (`git -C <clone>`):
/// `<path>: <seen>; holt does not change it: resolve it with git (<git_in>
/// worktree list), then run again`. For a record git's worktree list
/// leaves out (`half_made_seen`, `record_unreadable_seen`), `path` being
/// the record, the place named is the record itself (`recordWhat`). holt
/// names no command changing it, with or without `--force`.
pub fn unresolvedLine(ctx: *app.Ctx, path: []const u8, seen: []const u8, git_in: []const u8) ![]const u8 {
    const unlisted = std.mem.eql(u8, seen, half_made_seen) or std.mem.eql(u8, seen, record_unreadable_seen);
    const what = if (unlisted) try recordWhat(ctx, seen, path) else try unresolvedWhat(ctx, seen, git_in);
    return std.fmt.allocPrint(ctx.alloc, "{s}: {s}", .{ try q(ctx, path), what });
}

/// `unresolvedLine` without its path, for a caller that leads with it.
pub fn unresolvedWhat(ctx: *app.Ctx, seen: []const u8, git_in: []const u8) ![]const u8 {
    return leftWhat(ctx, seen, try std.fmt.allocPrint(ctx.alloc, "{s} worktree list", .{git_in}));
}

/// `unresolvedWhat` for the record `record`, which git's worktree list
/// leaves out: `<seen>; holt does not change it: resolve it with git (the
/// record is <record>), then run again`.
pub fn recordWhat(ctx: *app.Ctx, seen: []const u8, record: []const u8) ![]const u8 {
    return leftWhat(ctx, seen, try std.fmt.allocPrint(ctx.alloc, "the record is {s}", .{try q(ctx, record)}));
}

/// What holt says of a state it leaves to the user, `seen`, with `place`
/// the git command or path that shows it.
fn leftWhat(ctx: *app.Ctx, seen: []const u8, place: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "{s}; holt does not change it: resolve it with git ({s}), then run again", .{ seen, place });
}

/// `git -C <main>`, the git `unresolvedLine` names for a linked working
/// tree of the clone at `main`.
pub fn mainGit(ctx: *app.Ctx, main: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "git -C {s}", .{try q(ctx, main)});
}

/// The command that brings the linked working tree at `tree` back to its
/// record `record`: writing its `.git` as `gitdir: <record>`, which
/// reaches that one record alone; with `make`, for one that is gone,
/// making its directory first and checking its index out into it.
pub fn relinkCmd(ctx: *app.Ctx, tree: []const u8, record: []const u8, make: bool) ![]const u8 {
    return relinkCmdFor(ctx, tree, record, make, ui.native_shell);
}

/// `relinkCmd` written for `shell`: under PowerShell, `New-Item` making
/// the directory and `Set-Content -NoNewline` writing the `.git`, which
/// holds the bytes `linkText` gives.
pub fn relinkCmdFor(ctx: *app.Ctx, tree: []const u8, record: []const u8, make: bool, shell: ui.Shell) ![]const u8 {
    const a = ctx.alloc;
    const env = app.envOf(ctx);
    const wq = try ui.quotePathFor(a, env, tree, shell);
    const dot_git = try ui.quotePathFor(a, env, try std.fs.path.join(a, &.{ tree, ".git" }), shell);
    const write = switch (shell) {
        .posix => try std.fmt.allocPrint(a, "printf 'gitdir: %s\\n' {s} > {s}", .{ try ui.quotePathFor(a, env, record, shell), dot_git }),
        .powershell => try std.fmt.allocPrint(a, "Set-Content -NoNewline -LiteralPath {s} -Value ('gitdir: ' + {s} + \"`n\")", .{ dot_git, try psString(a, try fsutil.forwardSlashed(a, record)) }),
    };
    if (!make) return write;
    const mkdir = switch (shell) {
        .posix => try std.fmt.allocPrint(a, "mkdir -p {s}", .{wq}),
        .powershell => try std.fmt.allocPrint(a, "New-Item -ItemType Directory -Force -Path {s}", .{wq}),
    };
    return std.fmt.allocPrint(a, "{s} && {s} && git -C {s} checkout-index -a", .{ mkdir, write, wq });
}

/// The command removing each of `paths`, a directory with all it holds or
/// a file, reaching nothing else: `rm -rf`, under PowerShell `Remove-Item
/// -Recurse -Force -LiteralPath`, which also removes the hidden and
/// read-only files a git directory holds.
pub fn removeCmdFor(ctx: *app.Ctx, paths: []const []const u8, shell: ui.Shell) ![]const u8 {
    const a = ctx.alloc;
    const env = app.envOf(ctx);
    var quoted: std.ArrayList([]const u8) = .empty;
    for (paths) |path| try quoted.append(a, try ui.quotePathFor(a, env, path, shell));
    return switch (shell) {
        .posix => std.fmt.allocPrint(a, "rm -rf {s}", .{try std.mem.join(a, " ", quoted.items)}),
        .powershell => std.fmt.allocPrint(a, "Remove-Item -Recurse -Force -LiteralPath {s}", .{try std.mem.join(a, ", ", quoted.items)}),
    };
}

/// `removeCmdFor` for this platform's shell.
pub fn removeCmd(ctx: *app.Ctx, paths: []const []const u8) ![]const u8 {
    return removeCmdFor(ctx, paths, ui.native_shell);
}

/// The command pointing the record `record` of a linked working tree at
/// `tree`, where it now is: writing `<record>/gitdir` as `recordText`
/// gives it, which reaches that one record alone; under PowerShell with
/// `Set-Content -NoNewline`.
pub fn repointCmdFor(ctx: *app.Ctx, record: []const u8, tree: []const u8, shell: ui.Shell) ![]const u8 {
    const a = ctx.alloc;
    const env = app.envOf(ctx);
    const gitdir = try ui.quotePathFor(a, env, try std.fs.path.join(a, &.{ record, "gitdir" }), shell);
    return switch (shell) {
        .posix => std.fmt.allocPrint(a, "printf '%s/.git\\n' {s} > {s}", .{ try ui.quotePathFor(a, env, tree, shell), gitdir }),
        .powershell => std.fmt.allocPrint(a, "Set-Content -NoNewline -LiteralPath {s} -Value ({s} + \"/.git`n\")", .{ gitdir, try psString(a, try fsutil.forwardSlashed(a, tree)) }),
    };
}

/// `repointCmdFor` for this platform's shell.
pub fn repointCmd(ctx: *app.Ctx, record: []const u8, tree: []const u8) ![]const u8 {
    return repointCmdFor(ctx, record, tree, ui.native_shell);
}

/// `s` as a PowerShell string literal (`ui.powershellQuoted`), each
/// control character shown as `\xHH` (`ui.printable`).
fn psString(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    return ui.printable(a, try ui.powershellQuoted(a, s));
}

/// What the `.git` of a linked working tree whose record is `record`
/// holds, as git writes it: `gitdir: <record>`, `/`-separated, and a
/// newline.
pub fn linkText(a: std.mem.Allocator, record: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "gitdir: {s}\n", .{try fsutil.forwardSlashed(a, record)});
}

/// What the `gitdir` of the record of the linked working tree at `tree`
/// holds, as git writes it: `<tree>/.git`, `/`-separated, and a newline.
pub fn recordText(a: std.mem.Allocator, tree: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/.git\n", .{try fsutil.forwardSlashed(a, tree)});
}

/// Writes the `.git` of the linked working tree at `tree` as `linkText`
/// gives it for `record`, reaching no other working tree or record:
/// created when `old` is null, else replacing the `.git` that held `old`.
/// Then checks that git there finds `record` as its git directory (`git
/// rev-parse --absolute-git-dir`), else puts back what was there
/// (removing a created one) and returns `LinkNotFound`; an error writing
/// is returned as it is, with what was there left in place.
pub fn writeLink(a: std.mem.Allocator, tree: []const u8, record: []const u8, old: ?[]const u8) !void {
    const dot_git = try std.fs.path.join(a, &.{ tree, ".git" });
    const text = try linkText(a, record);
    if (old == null) {
        const file = try std.Io.Dir.cwd().createFile(io(), dot_git, .{ .exclusive = true });
        const written = file.writeStreamingAll(io(), text);
        file.close(io());
        written catch |err| {
            fsutil.removePath(dot_git) catch {};
            return err;
        };
    } else try fsutil.writeFileAtomic(a, dot_git, text);
    if (try findsRecord(a, tree, record)) return;
    if (old) |was| fsutil.writeFileAtomic(a, dot_git, was) catch {} else fsutil.removePath(dot_git) catch {};
    return error.LinkNotFound;
}

/// Whether git at `tree` finds `record` as its git directory (`git
/// rev-parse --absolute-git-dir`); false when git fails there.
pub fn findsRecord(a: std.mem.Allocator, tree: []const u8, record: []const u8) !bool {
    const res = git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, tree) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    if (res.status != 0) return false;
    return std.mem.eql(u8, try fsutil.realPathOrSelf(a, std.mem.trim(u8, res.stdout, " \t\r\n")), try fsutil.realPathOrSelf(a, record));
}

/// A linked working tree of a clone, weighed before the clone is deleted
/// whole (`linkedTrees`).
pub const LinkedTree = struct {
    /// Where its record says it is; the record itself when that cannot be
    /// read.
    path: []const u8,
    /// Its record, the git directory holding its HEAD and its per-worktree
    /// refs.
    record: []const u8,
    /// How it stands to its record; one that is `.absent` is gone, and
    /// weighed through its record alone.
    link: Link = .there,
    /// What git and holt see at its path when holt leaves it to the user
    /// (`unresolvedSeen`); it is then not weighed at all.
    seen: ?[]const u8 = null,
    locked: bool = false,
    /// Its working tree shows uncommitted changes.
    dirty: bool = false,
    /// While it is gone, its record's index differs from its HEAD: staged
    /// changes only the record holds.
    staged: bool = false,
    /// What removing it destroys that no remote holds (`worktreeRisks`),
    /// each naming the main clone, which runs the command settling it, and,
    /// while it is gone, what each submodule git directory under its
    /// record's `modules/` holds (`moduleRisks`), each naming that
    /// directory; the git state that could not be read when git cannot
    /// read it.
    risks: []const RiskAt = &.{},
    /// The operations in progress in it that removing it loses
    /// (`linkedOps`).
    ops: []const InProgress = &.{},
    /// The files holt does not keep in it, which removing it deletes
    /// (`candidates.list`), as paths; none while it is gone.
    not_kept: []const []const u8 = &.{},
    /// The nested repositories in it, which removing it deletes
    /// (`candidates.list`), as paths; none while it is gone.
    nested: []const []const u8 = &.{},
    /// Why what it holds could not be listed, when it could not.
    unlisted: ?Unlisted = null,

    pub const Unlisted = enum {
        /// The skip and auto patterns cannot be matched.
        patterns,
        /// git could not list it.
        git,
    };

    /// Nothing is at `path`, or nothing there leads back to its record.
    pub fn gone(t: LinkedTree) bool {
        return t.link != .there;
    }

    /// Whether removing it destroys something: a risk, an operation in
    /// progress, staged changes only its record holds, a nested
    /// repository, or a file holt does not keep, or what it holds could
    /// not be listed.
    pub fn atRisk(t: LinkedTree) bool {
        return t.risks.len + t.ops.len + t.nested.len + t.not_kept.len > 0 or t.staged or t.unlisted != null;
    }

    /// The lines naming what removing it destroys, each led by its path and
    /// ending with the command settling it, `force_cmd` being the command
    /// removing it anyway: for one that is gone (`Link.absent`) holding an
    /// operation in progress or staged changes, first the command bringing
    /// it back from its record (`relinkCmd`), after which the lines naming
    /// them run there; each risk (`riskLine`), each operation in progress
    /// (`inProgressLine`), the staged changes, with the stash storing them
    /// in the clone's stash, each nested repository, with `holt repo adopt`
    /// of it, and each file not kept, then `holt keep --review` of the
    /// tree. Empty when it is not `atRisk`, and for one holt leaves to the
    /// user (`seen`), which the caller names with `unresolvedLine`.
    pub fn lines(t: LinkedTree, ctx: *app.Ctx, main: []const u8, force_cmd: []const u8) ![]const []const u8 {
        const a = ctx.alloc;
        const shown = try ui.printable(a, try app.tilde(ctx, t.path));
        const wq = try q(ctx, t.path);
        var out: std.ArrayList([]const u8) = .empty;
        if (t.seen != null) return out.items;
        if (t.link == .absent and (t.ops.len > 0 or t.staged)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}: its directory is gone; bring it back from its record first (run: {s})", .{ shown, try relinkCmd(ctx, t.path, t.record, true) }));
        }
        for (t.risks) |r| {
            if (r.risk.what == .unreadable and (std.mem.eql(u8, r.repo, t.path) or std.mem.eql(u8, r.repo, t.record))) {
                try out.append(a, try std.fmt.allocPrint(a, "{s}: its git state could not be read (run: git -C {s} worktree list --porcelain)", .{ shown, try q(ctx, main) }));
            } else try out.append(a, try std.fmt.allocPrint(a, "{s}: {s}", .{ shown, try riskLine(ctx, r, force_cmd) }));
        }
        for (t.ops) |x| try out.append(a, try std.fmt.allocPrint(a, "{s}: {s}", .{ shown, try inProgressLine(ctx, x, force_cmd) }));
        if (t.staged) try out.append(a, try std.fmt.allocPrint(a, "{s}: {s}; commit or stash them there (run: git -C {s} stash push)", .{ shown, try t.stagedPhrase(ctx), wq }));
        for (t.nested) |n| {
            const at = try q(ctx, n);
            try out.append(a, try std.fmt.allocPrint(a, "{s}: nested repository {s} (run: holt repo adopt {s})", .{ shown, at, at }));
        }
        for (t.not_kept) |p| try out.append(a, try std.fmt.allocPrint(a, "{s}: not kept: {s}", .{ shown, try show(ctx, p) }));
        if (t.not_kept.len > 0) try out.append(a, try std.fmt.allocPrint(a, "{s}: keep or skip each first (run: holt keep --review {s})", .{ shown, wq }));
        if (t.unlisted) |u| try out.append(a, switch (u) {
            .patterns => try std.fmt.allocPrint(a, "{s}: the skip and auto patterns cannot be matched (run: holt doctor)", .{shown}),
            .git => try std.fmt.allocPrint(a, "{s}: git could not list what it holds (run: git -C {s} status)", .{ shown, wq }),
        });
        return out.items;
    }

    /// Its staged changes as a line names them.
    pub fn stagedPhrase(t: LinkedTree, ctx: *app.Ctx) ![]const u8 {
        return std.fmt.allocPrint(ctx.alloc, "staged changes only {s}'s record holds", .{try show(ctx, t.path)});
    }

    /// The lines `--force` prints for what removing it deletes, each
    /// `deleting <what>`: each risk (`lostPhrase`), each operation in
    /// progress (`inProgressLost`), and the staged changes.
    pub fn lostLines(t: LinkedTree, ctx: *app.Ctx) ![]const []const u8 {
        const a = ctx.alloc;
        var out: std.ArrayList([]const u8) = .empty;
        for (t.risks) |r| try out.append(a, try std.fmt.allocPrint(a, "deleting {s}", .{try lostPhrase(ctx, r)}));
        for (t.ops) |x| try out.append(a, try std.fmt.allocPrint(a, "deleting {s}", .{try inProgressLost(ctx, x)}));
        if (t.staged) try out.append(a, try std.fmt.allocPrint(a, "deleting the {s}", .{try t.stagedPhrase(ctx)}));
        return out.items;
    }
};

/// The kept store a weighing of linked working trees lists the files holt
/// does not keep against.
pub const KeptView = struct { kctx: kept.Ctx, index: *const kept.store.KeyIndex };

/// Each linked working tree the clone at `main` records, weighed through
/// its record as `worktree -r` weighs it, and, for one that is there, the
/// files holt does not keep in it, listed against `view`; one holt leaves
/// to the user (`unresolvedSeen`) is not weighed, and says why (`seen`),
/// as each record git's worktree list leaves out (`unlistedRecords`),
/// named by the record. `GitFailed` when the records cannot be read.
pub fn linkedTrees(asker: Asker, main: []const u8, view: KeptView) ![]const LinkedTree {
    const a = asker.alloc;
    const common = try commonDirOf(a, .{ .repo = main });
    const records = kept.clone.linkedRecords(a, common) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.GitFailed,
    };
    var out: std.ArrayList(LinkedTree) = .empty;
    for (records) |rec| {
        if (rec.path == null) continue;
        if (try unresolvedSeen(a, common, records, rec)) |seen| {
            try out.append(a, .{ .path = rec.path.?, .record = rec.record, .link = try linkOf(a, common, rec.record, rec.path.?), .seen = seen });
            continue;
        }
        try out.append(a, try weighLinked(asker, main, common, rec, view));
    }
    for (try unlistedRecords(a, common)) |u| try out.append(a, .{ .path = u.record, .record = u.record, .link = .unresolved, .seen = unlistedSeen(u) });
    return out.items;
}

/// Every record the git directory `common` holds that names the linked
/// working tree at `path`, in order of their names; more than one when a
/// record was copied, and then `git worktree remove <path>` may reach any
/// of them. `GitFailed` when the records cannot be read.
pub fn recordsIn(a: std.mem.Allocator, common: []const u8, path: []const u8) ![]const kept.clone.Record {
    const records = kept.clone.linkedRecords(a, common) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.GitFailed,
    };
    return recordsNaming(a, records, path);
}

/// The records of `records` that name the linked working tree at `path`,
/// in their order.
fn recordsNaming(a: std.mem.Allocator, records: []const kept.clone.Record, path: []const u8) ![]const kept.clone.Record {
    const want = try resolvedPath(a, path);
    var out: std.ArrayList(kept.clone.Record) = .empty;
    for (records) |rec| {
        const at = rec.path orelse continue;
        if (std.mem.eql(u8, try resolvedPath(a, at), want)) try out.append(a, rec);
    }
    return out.items;
}

/// The linked working tree `rec` of the clone at `main`, whose directory
/// is gone (`Link.absent`), weighed through its record as `linkedTrees`
/// weighs it; not weighed, and saying why (`LinkedTree.seen`), when it is
/// found `Link.unresolved` instead.
pub fn weighRecord(asker: Asker, main: []const u8, rec: kept.clone.Record) !LinkedTree {
    return weighLinked(asker, main, try commonDirOf(asker.alloc, .{ .repo = main }), rec, null);
}

/// `path` with its deepest ancestor that exists resolved to its real path
/// (`fsutil.realPathOrSelf`), so two spellings of a path that is gone
/// compare alike.
pub fn resolvedPath(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (try kept.content.entryAt(path) != .absent) return fsutil.realPathOrSelf(a, path);
    const parent = std.fs.path.dirname(path) orelse return path;
    return std.fs.path.join(a, &.{ try resolvedPath(a, parent), std.fs.path.basename(path) });
}

/// The linked working tree `rec` of the repository `main`, whose common
/// directory is `common`, weighed through its record, each risk naming
/// `main`; with `view`, the files holt does not keep in it listed. One
/// that is `Link.unresolved` is not weighed, and says why
/// (`LinkedTree.seen`).
fn weighLinked(asker: Asker, main: []const u8, common: []const u8, rec: kept.clone.Record, view: ?KeptView) !LinkedTree {
    const a = asker.alloc;
    const path = rec.path orelse return .{ .path = rec.record, .record = rec.record, .risks = try a.dupe(RiskAt, &.{.{ .repo = rec.record, .risk = .{ .what = .unreadable } }}) };
    var t: LinkedTree = .{ .path = path, .record = rec.record };
    t.link = try linkOf(a, common, rec.record, path);
    if (t.link == .unresolved) {
        t.seen = try linkSeen(a, common, rec.record, path) orelse "a linked working tree that does not lead back to its record";
        return t;
    }
    t.locked = try kept.content.entryAt(try std.fs.path.join(a, &.{ rec.record, "locked" })) != .absent;
    if (!t.gone()) t.dirty = try git.isDirty(a, path);
    const at: At = .{ .repo = rec.record, .git_dir = rec.record };
    if (worktreeRisksAt(asker, at)) |found| {
        var risks: std.ArrayList(RiskAt) = .empty;
        for (found) |r| try risks.append(a, .{ .repo = main, .risk = r });
        t.risks = risks.items;
    } else |err| switch (err) {
        error.GitFailed => t.risks = try a.dupe(RiskAt, &.{.{ .repo = path, .risk = .{ .what = .unreadable } }}),
        else => return err,
    }
    t.ops = linkedOps(a, rec.record, path, t.link) catch |err| switch (err) {
        error.GitFailed => blk: {
            t.risks = try std.mem.concat(a, RiskAt, &.{ t.risks, &.{.{ .repo = path, .risk = .{ .what = .unreadable } }} });
            break :blk &.{};
        },
        else => return err,
    };
    if (t.gone()) {
        if (stagedIn(a, rec.record)) |staged| t.staged = staged else |err| switch (err) {
            error.GitFailed => t.risks = try std.mem.concat(a, RiskAt, &.{ t.risks, &.{.{ .repo = path, .risk = .{ .what = .unreadable } }} }),
            else => return err,
        }
        const roots: []const []const u8 = &.{try std.fs.path.join(a, &.{ rec.record, "modules" })};
        t.risks = try std.mem.concat(a, RiskAt, &.{ t.risks, try moduleRisks(asker, roots, &.{}) });
        return t;
    }
    const v = view orelse return t;
    var not_kept: std.ArrayList([]const u8) = .empty;
    var nested: std.ArrayList([]const u8) = .empty;
    if (candidates.list(v.kctx, v.index, path, .{ .deep_nested = true, .tracked_edits = true })) |l| {
        for (l.candidates) |cand| try not_kept.append(a, try fsutil.joinSlashy(a, l.worktree, cand.rel));
        for (l.nested) |n| try nested.append(a, try fsutil.joinSlashy(a, l.worktree, n.repo));
    } else |err| switch (err) {
        error.OutOfMemory, error.Interrupted => return err,
        error.MatcherFailed => t.unlisted = .patterns,
        else => t.unlisted = .git,
    }
    t.not_kept = not_kept.items;
    t.nested = nested.items;
    return t;
}

/// What removing the record `record` of the linked working tree at `path`
/// destroys, as text two reads of the same state give alike: every ref,
/// those of the other working trees included, the tree's own HEAD, each
/// operation in progress in it with the autostash it holds, whether its
/// index differs from its HEAD, and every ref, HEAD, and operation in
/// progress with its autostash of each submodule git directory under its
/// `modules/` (`moduleDirs`); null when git cannot read them.
pub fn recordState(a: std.mem.Allocator, record: []const u8, path: []const u8) !?[]const u8 {
    const state = inventoryAt(a, .{ .repo = record, .git_dir = record }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    const own = state.current() catch return null;
    const ops = inProgress(a, record, path, false) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    const staged = stagedIn(a, record) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    const modules = try moduleDirs(a, &.{try std.fs.path.join(a, &.{ record, "modules" })});
    if (modules.unreadable.len > 0) return null;
    var out: std.Io.Writer.Allocating = .init(a);
    try writeState(&out.writer, state, own);
    for (ops) |x| try out.writer.print("op {s} {s}\n", .{ x.name(), x.autostash orelse "-" });
    try out.writer.print("staged {}\n", .{staged});
    for (modules.dirs) |dir| {
        const module = inventoryAt(a, .{ .repo = dir, .git_dir = dir }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        const module_ops = inProgress(a, dir, dir, false) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        try out.writer.print("module {s}\n", .{dir});
        try writeState(&out.writer, module, null);
        for (module_ops) |x| try out.writer.print("op {s} {s}\n", .{ x.name(), x.autostash orelse "-" });
    }
    return out.written();
}

/// Whether the index of the git directory `record` differs from its HEAD,
/// read without a working tree (`git diff-index --cached`). `GitFailed`
/// when git cannot tell.
pub fn stagedIn(a: std.mem.Allocator, record: []const u8) !bool {
    const res = try (At{ .repo = record, .git_dir = record }).run(a, &.{ "diff-index", "--cached", "--quiet", "HEAD", "--" });
    return switch (res.status) {
        0 => false,
        1 => true,
        else => error.GitFailed,
    };
}

/// The line saying the record of the linked working tree at `path`
/// changed between its weighing and its removal (`recordUnchanged`), and
/// was kept, then `aside`, what was set aside and unlinked before
/// (`Prepared.asideNote`).
pub fn recordChangedLine(ctx: *app.Ctx, path: []const u8, aside: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "holt: {s} changed while it was being weighed (its HEAD, a ref, an operation in progress, its staged changes, or a submodule git directory in its record changed, or git could not read them again); its record was kept{s}; run the command again\n", .{ try q(ctx, path), aside });
}

/// Whether the record `record` of the linked working tree at `path` is as
/// `before`, its `recordState` when it was weighed, read again right
/// before its removal; false when either read failed.
pub fn recordUnchanged(a: std.mem.Allocator, record: []const u8, path: []const u8, before: ?[]const u8) !bool {
    if (builtin.is_test) if (before_reread_for_test) |seam| seam();
    const then = before orelse return false;
    const now = try recordState(a, record, path) orelse return false;
    return std.mem.eql(u8, then, now);
}

/// The operations in progress (`inProgress`) in the linked working tree at
/// `path`, whose record is `record`, each of which removing it loses,
/// marked with how the tree stands to its record, `link`. `GitFailed`
/// when the record cannot be read.
fn linkedOps(a: std.mem.Allocator, record: []const u8, path: []const u8, link: Link) ![]const InProgress {
    const found = try inProgress(a, record, path, false);
    var out: std.ArrayList(InProgress) = .empty;
    for (found) |x| {
        var g = x;
        g.link = link;
        g.record = record;
        try out.append(a, g);
    }
    return out.items;
}

/// The operations in progress in every git directory a weighing of the
/// whole clone `c` reads: its common directory, each linked working tree's
/// record (`linkedOps`) but those holt leaves to the user
/// (`unresolvedSeen`), and each submodule git directory, those of the
/// checked-out submodules `subs` (their working trees) named by them.
/// `GitFailed` when one cannot be read.
pub fn cloneOps(a: std.mem.Allocator, c: kept.clone.Clone, subs: []const []const u8) ![]const InProgress {
    var out: std.ArrayList(InProgress) = .empty;
    try out.appendSlice(a, try inProgress(a, c.common_dir, c.main, false));
    const records = kept.clone.linkedRecords(a, c.common_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.GitFailed,
    };
    for (records) |rec| {
        const path = rec.path orelse continue;
        if (try unresolvedSeen(a, c.common_dir, records, rec) != null) continue;
        try out.appendSlice(a, try linkedOps(a, rec.record, path, try linkOf(a, c.common_dir, rec.record, path)));
    }
    try out.appendSlice(a, try inProgressAll(a, try moduleGitDirs(a, subs, try moduleRoots(a, c, .clone))));
    return out.items;
}

/// The operations in progress in the git directory of the working tree
/// `tree`. `GitFailed` when git cannot name it, or it cannot be read.
pub fn treeOps(a: std.mem.Allocator, tree: []const u8) ![]const InProgress {
    const res = try (At{ .repo = tree }).run(a, &.{ "rev-parse", "--absolute-git-dir" });
    if (res.status != 0) return error.GitFailed;
    return inProgress(a, std.mem.trim(u8, res.stdout, " \t\r\n"), tree, false);
}

/// The `modules/` directories of the git directories a delete of `c`
/// removes: the common directory's and, for a whole clone, each linked
/// working tree's; for one working tree, its own git directory's.
pub fn moduleRoots(a: std.mem.Allocator, c: kept.clone.Clone, scope: Scope) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (scope == .worktree) {
        if (!std.mem.eql(u8, c.git_dir, c.common_dir)) try out.append(a, try std.fs.path.join(a, &.{ c.git_dir, "modules" }));
        return out.items;
    }
    try out.append(a, try std.fs.path.join(a, &.{ c.common_dir, "modules" }));
    const wts = try std.fs.path.join(a, &.{ c.common_dir, "worktrees" });
    var d = std.Io.Dir.cwd().openDir(io(), wts, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.items,
        else => return err,
    };
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        if (e.kind == .directory) try out.append(a, try std.fs.path.join(a, &.{ wts, e.name, "modules" }));
    }
    return out.items;
}

/// Whether `dir` is a git directory: it holds `HEAD` and `objects`.
fn isGitDir(a: std.mem.Allocator, dir: []const u8) !bool {
    return try kept.content.entryAt(try std.fs.path.join(a, &.{ dir, "HEAD" })) == .file and
        try kept.content.entryAt(try std.fs.path.join(a, &.{ dir, "objects" })) == .dir;
}

/// The submodule git directories under the `modules/` directories
/// `roots`, a submodule whose name holds `/` filed below others and a
/// nested submodule's under its own `modules/`, links not followed, and the
/// directories that could not be read.
const ModuleDirs = struct { dirs: []const []const u8, unreadable: []const []const u8 };

fn moduleDirs(a: std.mem.Allocator, roots: []const []const u8) !ModuleDirs {
    var dirs: std.ArrayList([]const u8) = .empty;
    var unreadable: std.ArrayList([]const u8) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.appendSlice(a, roots);
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const dir = queue.items[i];
        var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => {
                try unreadable.append(a, dir);
                continue;
            },
        };
        defer d.close(io());
        var it = d.iterate();
        while (it.next(io()) catch blk: {
            try unreadable.append(a, dir);
            break :blk null;
        }) |e| {
            if (e.kind != .directory) continue;
            const p = try std.fs.path.join(a, &.{ dir, e.name });
            if (!try isGitDir(a, p)) {
                try queue.append(a, p);
                continue;
            }
            try queue.append(a, try std.fs.path.join(a, &.{ p, "modules" }));
            try dirs.append(a, p);
        }
    }
    return .{ .dirs = dirs.items, .unreadable = unreadable.items };
}

/// The real git directories of the checked-out submodules `weighed` (their
/// working trees) git can name.
fn weighedDirs(a: std.mem.Allocator, weighed: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (weighed) |sub| {
        const res = try (At{ .repo = sub }).run(a, &.{ "rev-parse", "--absolute-git-dir" });
        if (res.status == 0) try out.append(a, try fsutil.realPathOrSelf(a, std.mem.trim(u8, res.stdout, " \t\r\n")));
    }
    return out.items;
}

/// The git state no remote holds (`gitDirRisks`) in every
/// submodule git directory under the `modules/` directories `roots`
/// (`moduleDirs`), but those of the checked-out submodules `weighed`
/// (their working trees), weighed through them already. A directory that
/// cannot be read is `unreadable`.
pub fn moduleRisks(asker: Asker, roots: []const []const u8, weighed: []const []const u8) ![]const RiskAt {
    const a = asker.alloc;
    const skip = try weighedDirs(a, weighed);
    const found = try moduleDirs(a, roots);
    var out: std.ArrayList(RiskAt) = .empty;
    for (found.unreadable) |dir| try out.append(a, .{ .repo = dir, .risk = .{ .what = .unreadable } });
    for (found.dirs) |p| {
        if (kept.paths.contains(skip, try fsutil.realPathOrSelf(a, p))) continue;
        const broken = try worktreeGone(a, p);
        for (try gitDirRisks(asker, p)) |r| try out.append(a, .{ .repo = p, .risk = r, .git_dir_only = broken });
    }
    return out.items;
}

/// Whether the git directory `dir` sets `core.worktree` to a directory
/// that is not there, so `git -C <dir>` fails.
fn worktreeGone(a: std.mem.Allocator, dir: []const u8) !bool {
    const res = try (At{ .repo = dir, .git_dir = dir }).run(a, &.{ "config", "--get", "core.worktree" });
    if (res.status != 0) return false;
    const value = std.mem.trimEnd(u8, res.stdout, "\r\n");
    const path = if (std.fs.path.isAbsolute(value)) value else try std.fs.path.join(a, &.{ dir, value });
    return try kept.content.entryAt(path) != .dir;
}

/// A linked working tree `moduleWorktrees` names, by its path; the
/// submodule git directory recording it, when its record could be read;
/// and what git and holt see at its path when holt leaves it to the user
/// (`unresolvedSeen`).
pub const ModuleTree = struct { path: []const u8, module: ?[]const u8 = null, seen: ?[]const u8 = null };

/// How the command removing the linked working tree `t` reaches the
/// repository recording it: `git -C <tree>` while its directory is there,
/// else through its submodule git directory (`moduleGit`).
fn moduleTreeGit(ctx: *app.Ctx, t: ModuleTree) ![]const u8 {
    const a = ctx.alloc;
    const gd = t.module orelse return std.fmt.allocPrint(a, "git -C {s}", .{try q(ctx, t.path)});
    if (try kept.content.entryAt(t.path) != .absent) return std.fmt.allocPrint(a, "git -C {s}", .{try q(ctx, t.path)});
    return moduleGit(ctx, gd);
}

/// The git reaching the submodule git directory `gd` itself: `git
/// --git-dir <gd>`, with `--work-tree <gd>` when its `core.worktree` names
/// no directory, where git would fail to enter it.
fn moduleGit(ctx: *app.Ctx, gd: []const u8) ![]const u8 {
    const a = ctx.alloc;
    const mq = try q(ctx, gd);
    if (try worktreeGone(a, gd)) return std.fmt.allocPrint(a, "git --git-dir {s} --work-tree {s}", .{ mq, mq });
    return std.fmt.allocPrint(a, "git --git-dir {s}", .{mq});
}

/// The linked working trees of the submodule git directories under the
/// `modules/` directories `roots` (`moduleDirs`) and of the checked-out
/// submodules `weighed`, which deleting those git directories leaves
/// without their repository, each path once; a record or directory that
/// cannot be read is named by its own path.
pub fn moduleWorktrees(a: std.mem.Allocator, roots: []const []const u8, weighed: []const []const u8) ![]const ModuleTree {
    const found = try moduleDirs(a, roots);
    var dirs: std.ArrayList([]const u8) = .empty;
    for (found.dirs) |p| try dirs.append(a, try fsutil.realPathOrSelf(a, p));
    for (try weighedDirs(a, weighed)) |p| if (!kept.paths.contains(dirs.items, p)) try dirs.append(a, p);
    var out: std.ArrayList(ModuleTree) = .empty;
    for (found.unreadable) |dir| try out.append(a, .{ .path = dir });
    for (dirs.items) |gd| {
        const recs = kept.clone.linkedRecords(a, gd) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try out.append(a, .{ .path = try std.fs.path.join(a, &.{ gd, "worktrees" }) });
                continue;
            },
        };
        for (try unlistedRecords(a, gd)) |u| try out.append(a, .{ .path = u.record, .module = gd, .seen = unlistedSeen(u) });
        for (recs) |r| {
            const path = r.path orelse continue;
            const same = try recordsNaming(a, recs, path);
            if (!std.mem.eql(u8, same[0].record, r.record)) continue;
            try out.append(a, .{ .path = path, .module = gd, .seen = try unresolvedSeen(a, gd, recs, r) });
        }
    }
    return out.items;
}

/// Appends what `git status` shows in the repository at `sub` of the
/// working tree `tree` (`""` for the tree itself) to `out`, relative to
/// `tree`, leaving out the initialized submodules `subs`, which are
/// listed on their own and never set aside whole; false when git cannot
/// list it.
fn listDirty(a: std.mem.Allocator, tree: []const u8, sub: []const u8, subs: []const []const u8, out: *std.ArrayList(Dirty)) !bool {
    const repo = if (sub.len == 0) tree else try fsutil.joinSlashy(a, tree, sub);
    const res = try (At{ .repo = repo }).run(a, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none" });
    if (res.status != 0) return false;
    var it = std.mem.splitScalar(u8, res.stdout, 0);
    while (it.next()) |rec| {
        if (rec.len < 4) continue;
        if (rec[0] == 'R' or rec[0] == 'C') _ = it.next();
        if (rec[0] == '!') continue;
        const path = std.mem.trimEnd(u8, rec[3..], "/");
        const rel = if (sub.len == 0) try a.dupe(u8, path) else try std.mem.concat(a, u8, &.{ sub, "/", path });
        if (kept.paths.contains(subs, rel)) continue;
        const staged = std.mem.indexOfScalar(u8, "MARCT", rec[0]) != null and std.mem.indexOfScalar(u8, "MDT", rec[1]) != null;
        try out.append(a, .{ .tree = tree, .rel = rel, .repo = repo, .in_repo = try a.dupe(u8, path), .staged = staged });
    }
    return true;
}

/// The store this machine sees, and this machine's id, for the kept-files
/// library.
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

pub const Store = enum { ready, absent, unreadable };

/// Whether `kept/` exists and can be read.
pub fn storeState(a: std.mem.Allocator, layout: kept.store.Layout) !Store {
    const dir = try layout.keptDir(a);
    if (try kept.content.entryAt(dir) == .absent) return .absent;
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch return .unreadable;
    d.close(io());
    return .ready;
}

/// Whether the clone whose common directory is `common_dir` has holt's
/// block in `info/exclude`; true when the file cannot be read.
pub fn hasBlock(a: std.mem.Allocator, common_dir: []const u8) bool {
    const text = kept.content.readSmall(a, kept.block.excludePath(a, common_dir) catch return true) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    return std.mem.indexOf(u8, text, kept.block.begin_line) != null or std.mem.indexOf(u8, text, kept.block.end_line) != null;
}

/// Reconciles the working tree at `path` and lists what the gates weigh,
/// for a delete of `scope`, and takes the clone's and the key's locks,
/// held until `Prepared.release` (none when `kept/` is absent, which
/// leaves nothing to reconcile and lists candidates under the seed
/// patterns). Refuses, even for `--force`, when git is too old for kept
/// files, when `kept/` exists but cannot be read, when the clone has
/// holt's block but `kept/` is absent (with `kept_hooks.elsewhereLine`
/// when a backend switch left it behind), when reconciling or listing
/// fails, or when a working tree holds a mount point of another
/// filesystem. No directory at all is ready with nothing found; a directory
/// git cannot read as a repository is ready with its git state `unreadable`
/// (which `--force` deletes), unless its `.git/info/exclude` holds holt's
/// block. With `opts.review` on a terminal, a refusal of the
/// gates is offered to it first, and everything is listed again after.
pub fn prepare(ctx: *app.Ctx, path: []const u8, scope: Scope, opts: Options) !Outcome {
    const a = ctx.alloc;
    const kctx = keptCtx(ctx) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .refused = try std.fmt.allocPrint(a, "this machine's id cannot be read or written ({s})", .{@errorName(err)}) },
    };
    kept.clone.requireGit(a) catch |err| switch (err) {
        error.GitTooOld => return .{ .refused = try kept.clone.gitTooOld(a) },
        else => return err,
    };
    const store = try storeState(a, kctx.layout);
    var p: Prepared = .{ .kctx = kctx, .path = path, .scope = scope, .store_ready = store == .ready, .many = opts.many };
    if (try kept.content.entryAt(path) == .absent) return .{ .ready = p };
    const c = kept.clone.inspect(a, path, kctx.code_root) catch |err| switch (err) {
        error.NotAClone => {
            if (hasBlock(a, try std.fs.path.join(a, &.{ path, ".git" }))) return .{ .refused = "git cannot read it, yet it has kept-file links; nothing can be checked (run: holt doctor)" };
            p.found = .{ .git = try a.dupe(RiskAt, &.{.{ .repo = path, .risk = .{ .what = .unreadable } }}) };
            return .{ .ready = p };
        },
        else => return err,
    };
    p.c = c;
    if (scope == .clone) {
        const unlisted = unlistedRecords(a, c.common_dir) catch |err| switch (err) {
            error.GitFailed => &.{},
            else => return err,
        };
        if (unlisted.len > 0) return .{ .refused = try unresolvedLine(ctx, unlisted[0].record, unlistedSeen(unlisted[0]), try mainGit(ctx, c.main)) };
    }
    if (store != .ready and hasBlock(a, c.common_dir)) {
        if (store == .absent) if (try util.keptElsewhere(ctx)) |root| {
            const line = try kept_hooks.elsewhereLine(ctx, root);
            return .{ .refused = line[0 .. line.len - 1] };
        };
        return .{ .refused = try std.fmt.allocPrint(a, "it has kept-file links but kept/ at {s} cannot be reached (mount or download the synced root, then run: holt sync)", .{try show(ctx, try kctx.layout.keptDir(a))}) };
    }
    if (store == .unreadable) {
        return .{ .refused = try std.fmt.allocPrint(a, "kept/ at {s} cannot be read, so nothing can be set aside (run: ls -la {s})", .{ try show(ctx, try kctx.layout.keptDir(a)), try q(ctx, try kctx.layout.keptDir(a)) }) };
    }
    p.trees = try a.dupe([]const u8, &.{c.worktree});
    if (p.store_ready) {
        p.index = try kept.store.loadIndex(a, kctx.layout);
        if (try lockAll(&p)) |why| {
            p.release();
            return .{ .refused = why };
        }
    }
    errdefer p.release();
    if (try evaluate(ctx, &p, opts.answers)) |why| {
        p.release();
        return .{ .refused = why };
    }
    if (p.found.blocked() and opts.interactive and (p.held_keep != null or p.clone_lock == null)) if (opts.review) |review| {
        try review(ctx, kctx, &p.index, path, p.held_keep);
        p.index = try kept.store.loadIndex(a, kctx.layout);
        if (try evaluate(ctx, &p, null)) |why| {
            p.release();
            return .{ .refused = why };
        }
    };
    return .{ .ready = p };
}

/// Takes the clone's lock, then the key locks of the clone's own and
/// resolved keys; a reason to refuse when they cannot be taken.
fn lockAll(p: *Prepared) !?[]const u8 {
    const a = p.kctx.alloc;
    const c = p.c.?;
    p.clone_lock = kept.lockClone(p.kctx, c.common_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return try std.fmt.allocPrint(a, "its kept-file state directory cannot be locked ({s})", .{@errorName(err)}),
    };
    const own = c.key orelse return null;
    const scope = try reconcile.scopeOf(p.kctx, &p.index, c);
    const rk = scope.key orelse own;
    p.key = rk;
    p.chain = scope.chain;
    p.roots = try kept.store.syncedRoots(a, p.kctx.layout);
    const pair = try kept.lockKeys(p.kctx, own, rk);
    p.key_locks = pair;
    const own_path = try kept_ctx.keyLockPath(p.kctx, own);
    const own_lock = if (pair.second) |s| (if (std.mem.eql(u8, s.path, own_path)) s else pair.first) else pair.first;
    const rk_lock = if (pair.second) |s| (if (std.mem.eql(u8, s.path, own_path)) pair.first else s) else pair.first;
    p.held_keep = kept.Held.of(p.clone_lock.?, own_lock);
    p.held_reconcile = kept.Held.of(p.clone_lock.?, rk_lock);
    return null;
}

/// Notes in `p` each aside entry reconcile made, one not among `before`:
/// at the path of the item of `items` naming it, else at its `rel` in
/// the working tree `p` reconciled; none when the entries cannot be read.
fn noteReconciled(a: std.mem.Allocator, p: *Prepared, before: []const []const u8, items: []const reconcile.Item) !void {
    const c = p.c.?;
    const now = kept.aside.stamps(a, p.kctx.layout) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    for (now) |stamp| {
        if (kept.paths.contains(before, stamp)) continue;
        const path = for (items) |i| {
            if (i.entry) |e| if (std.mem.eql(u8, e, stamp)) break try fsutil.joinSlashy(a, i.worktree orelse c.worktree, i.rel);
        } else blk: {
            const m = (kept.aside.readManifest(a, p.kctx.layout, stamp) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            }) orelse continue;
            if (p.key) |k| if (!std.mem.eql(u8, m.key, k)) continue;
            break :blk try fsutil.joinSlashy(a, c.worktree, m.rel);
        };
        try p.noteAside(a, path, try std.fmt.allocPrint(a, ".holt-aside/{s}", .{stamp}));
    }
}

/// Reconciles and lists into `p.found`, the remotes' answers taken from
/// `answers` when set, else asked afresh, and kept in `p.answers`; a
/// reason to refuse when either fails, when a working tree holds a
/// mount point of another filesystem, which the listing does not enter and
/// the delete would, or when an operation is in progress in a submodule
/// git directory whose `core.worktree` holt leaves to the user
/// (`InProgress.seen`).
fn evaluate(ctx: *app.Ctx, p: *Prepared, answers: ?*Answers) !?[]const u8 {
    const a = ctx.alloc;
    const c = p.c.?;
    var report: reconcile.Report = .{};
    if (p.store_ready) {
        const before: ?[]const []const u8 = kept.aside.stamps(a, p.kctx.layout) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        const got = reconcile.reconcileHeld(p.kctx, &p.index, p.path, .apply, if (c.key != null) p.held_reconcile else null);
        if (before) |b| try noteReconciled(a, p, b, if (got) |r| r.items else |_| &.{});
        report = got catch |err| switch (err) {
            error.OutOfMemory, error.Interrupted => return err,
            error.LocksNotHeld => return "the kept store changed while it was being locked (run the command again)",
            else => return try std.fmt.allocPrint(a, "reconciling its kept files failed ({s})", .{@errorName(err)}),
        };
    }
    var too_large: []const u8 = "";
    const opts: candidates.Options = .{
        .auto = p.store_ready and c.key != null,
        .held = if (c.key != null) p.held_keep else null,
        .list_too_large = &too_large,
        .deep_nested = true,
        .tracked_edits = true,
    };
    var listings: std.ArrayList(candidates.Listing) = .empty;
    var unlisted: std.ArrayList([]const u8) = .empty;
    const listed = switch (p.scope) {
        .clone => candidates.listAll(p.kctx, &p.index, c, opts),
        .worktree => if (candidates.list(p.kctx, &p.index, p.path, opts)) |l| candidates.AllListing{ .listings = try a.dupe(candidates.Listing, &.{l}) } else |err| err,
    };
    const all = listed catch |err| switch (err) {
        error.OutOfMemory, error.Interrupted => return err,
        error.MatcherFailed => return try std.fmt.allocPrint(a, "the skip and auto patterns cannot be matched{s}{s} (run: holt doctor)", .{ if (too_large.len > 0) "; too large: " else "", if (too_large.len > 0) try q(ctx, too_large) else "" }),
        error.ListingFailed, error.WorktreeListFailed, error.NotAClone => {
            try unlisted.append(a, c.worktree);
            p.found = .{ .unlisted = unlisted.items, .stop = report.stop };
            return null;
        },
        else => return try std.fmt.allocPrint(a, "listing the files holt does not keep failed ({s})", .{@errorName(err)}),
    };
    try listings.appendSlice(a, all.listings);
    for (all.listings) |l| if (l.other_filesystems.len > 0) {
        const mount = try fsutil.joinSlashy(a, l.worktree, l.other_filesystems[0]);
        return try std.fmt.allocPrint(a, "it holds {s}, a mount point of another filesystem the delete would reach into (unmount it first)", .{try show(ctx, mount)});
    };
    var trees: std.ArrayList([]const u8) = .empty;
    try trees.append(a, c.worktree);
    for (all.listings) |l| if (!kept.paths.contains(trees.items, l.worktree)) try trees.append(a, l.worktree);
    for (all.unlisted) |u| {
        try unlisted.append(a, u.worktree);
        if (!kept.paths.contains(trees.items, u.worktree)) try trees.append(a, u.worktree);
    }
    if (p.scope == .clone) p.trees = trees.items;

    var cands: std.ArrayList(Cand) = .empty;
    var nested: std.ArrayList(NestedAt) = .empty;
    var auto_kept: std.ArrayList(candidates.AutoKept) = .empty;
    for (listings.items) |l| {
        for (l.candidates) |cand| {
            if (cand.at_kept_path and unsettledAt(report, c.worktree, l.worktree, cand.rel)) continue;
            try cands.append(a, .{ .tree = l.worktree, .cand = cand });
        }
        for (l.nested) |n| try nested.append(a, .{ .tree = l.worktree, .nested = n });
        for (l.submodules_failed) |s| try unlisted.append(a, try fsutil.joinSlashy(a, l.worktree, s));
        try auto_kept.appendSlice(a, l.auto_kept);
        for (l.auto_kept) |k| {
            const line = try std.fmt.allocPrint(a, "kept automatically: {s} (matches '{s}')\n", .{ try show(ctx, try fsutil.joinSlashy(a, l.worktree, k.rel)), k.pattern });
            if (kept.paths.contains(p.shown_auto.items, line)) continue;
            try p.shown_auto.append(a, line);
            try ctx.out.writeAll(line);
        }
    }

    var unsettled: std.ArrayList(Unsettled) = .empty;
    for (report.items) |item| {
        if (!item.unsettled) continue;
        const tree = item.worktree orelse c.worktree;
        if (p.scope == .worktree and !std.mem.eql(u8, tree, c.worktree)) continue;
        if (reported(cands.items, nested.items, tree, item.rel)) continue;
        try unsettled.append(a, .{ .tree = tree, .item = item });
    }

    var asker = if (answers) |ans| try Asker.reusing(ctx, ans) else try Asker.of(ctx);
    if (p.many) asker.terminal = false;
    p.answers = asker.answers;
    var dirty: std.ArrayList(Dirty) = .empty;
    var risks: std.ArrayList(RiskAt) = .empty;
    var changes: std.ArrayList(Dirty) = .empty;
    for (listings.items) |l| {
        if (!try listDirty(a, l.worktree, "", l.submodules, &changes)) try risks.append(a, .{ .repo = l.worktree, .risk = .{ .what = .unreadable } });
        for (l.submodules) |s| {
            if (kept.paths.contains(l.submodules_failed, s)) continue;
            const sub = try fsutil.joinSlashy(a, l.worktree, s);
            if (!try listDirty(a, l.worktree, s, l.submodules, &changes)) try risks.append(a, .{ .repo = sub, .risk = .{ .what = .unreadable } });
            for (try gitRisks(asker, sub)) |r| try risks.append(a, .{ .repo = sub, .risk = r });
        }
    }
    for (changes.items) |d| {
        if (reported(cands.items, nested.items, d.tree, d.rel)) continue;
        try dirty.append(a, d);
    }
    var subs: std.ArrayList([]const u8) = .empty;
    for (listings.items) |l| for (l.submodules) |s| try subs.append(a, try fsutil.joinSlashy(a, l.worktree, s));
    p.subs = subs.items;
    const roots = try moduleRoots(a, c, p.scope);
    const sub_trees = try moduleWorktrees(a, roots, subs.items);
    if (sub_trees.len > 0) {
        var named: std.ArrayList([]const u8) = .empty;
        for (sub_trees) |t| try named.append(a, try show(ctx, t.path));
        const first = try q(ctx, sub_trees[0].path);
        const settle = if (sub_trees[0].seen) |seen|
            try unresolvedLine(ctx, sub_trees[0].path, seen, try moduleGit(ctx, sub_trees[0].module.?))
        else
            try std.fmt.allocPrint(a, "remove {s} first (run: {s} worktree remove {s})", .{ if (sub_trees.len == 1) "it" else "each", try moduleTreeGit(ctx, sub_trees[0]), first });
        return try std.fmt.allocPrint(a, "the delete would leave {s} of its submodules without their repository: {s}; {s}", .{ if (sub_trees.len == 1) "a linked working tree" else "linked working trees", try std.mem.join(a, ", ", named.items), settle });
    }
    try risks.appendSlice(a, try moduleRisks(asker, roots, subs.items));
    const ops = inProgressAll(a, try deletedDirs(a, p.scope, c, subs.items, roots)) catch |err| switch (err) {
        error.GitFailed => blk: {
            try risks.append(a, .{ .repo = c.worktree, .risk = .{ .what = .unreadable } });
            break :blk &.{};
        },
        else => return err,
    };
    for (ops) |x| if (x.seen != null) return try opLine(ctx, x, "");
    if (p.scope == .clone) {
        for (try gitRisks(asker, c.main)) |r| try risks.append(a, .{ .repo = c.main, .risk = r });
    }
    if (p.scope == .worktree) {
        if (worktreeRisks(asker, c.worktree)) |found| {
            for (found) |risk| try risks.append(a, .{ .repo = c.worktree, .risk = risk });
        } else |err| switch (err) {
            error.GitFailed => try risks.append(a, .{ .repo = c.worktree, .risk = .{ .what = .unreadable } }),
            else => return err,
        }
    }

    p.auto_kept = auto_kept.items;
    p.found = .{
        .candidates = cands.items,
        .nested = nested.items,
        .unsettled = unsettled.items,
        .dirty = dirty.items,
        .git = risks.items,
        .stop = if (report.stop == .store_absent or !hasBlock(a, c.common_dir)) .none else report.stop,
        .unlisted = unlisted.items,
        .ops = ops,
    };
    return null;
}

/// A git directory a delete removes, and the working tree it is the git
/// directory of: for a submodule git directory, the directory itself,
/// which git reaches through its `core.worktree`, unless that names no
/// directory (`link`, `.absent` when nothing is there, `.unresolved`, with
/// `seen`, when holt leaves what is there to the user), where `tree` is
/// what it names, or it names none at all (`no_tree`).
const DeletedDir = struct { dir: []const u8, tree: []const u8, no_tree: bool = false, link: Link = .there, module: bool = false, seen: ?[]const u8 = null };

/// The git directories a delete of `c` removes: for a clone deleted whole,
/// its common directory and each linked working tree's record; for one
/// working tree, its own git directory; for either, each submodule git
/// directory under the `modules/` directories `roots`, those of the
/// checked-out submodules `subs` (their working trees) named by them.
fn deletedDirs(a: std.mem.Allocator, scope: Scope, c: kept.clone.Clone, subs: []const []const u8, roots: []const []const u8) ![]const DeletedDir {
    var out: std.ArrayList(DeletedDir) = .empty;
    if (scope == .clone) {
        try out.append(a, .{ .dir = c.common_dir, .tree = c.main });
        const records = kept.clone.linkedRecords(a, c.common_dir) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.GitFailed,
        };
        for (records) |rec| try out.append(a, .{ .dir = rec.record, .tree = rec.path orelse rec.record });
    } else try out.append(a, .{ .dir = c.git_dir, .tree = c.worktree });
    try out.appendSlice(a, try moduleGitDirs(a, subs, roots));
    return out.items;
}

/// The submodule git directories under the `modules/` directories
/// `roots`, those of the checked-out submodules `subs` (their working
/// trees) named by them.
fn moduleGitDirs(a: std.mem.Allocator, subs: []const []const u8, roots: []const []const u8) ![]const DeletedDir {
    var out: std.ArrayList(DeletedDir) = .empty;
    var sub_dirs: std.ArrayList([]const u8) = .empty;
    for (subs) |sub| {
        const res = try (At{ .repo = sub }).run(a, &.{ "rev-parse", "--absolute-git-dir" });
        if (res.status != 0) return error.GitFailed;
        const dir = try fsutil.realPathOrSelf(a, std.mem.trim(u8, res.stdout, " \t\r\n"));
        try sub_dirs.append(a, dir);
        try out.append(a, .{ .dir = dir, .tree = sub });
    }
    for ((try moduleDirs(a, roots)).dirs) |dir| {
        if (kept.paths.contains(sub_dirs.items, try fsutil.realPathOrSelf(a, dir))) continue;
        try out.append(a, try moduleDir(a, dir));
    }
    return out.items;
}

/// The operations in progress (`inProgress`) in each of `dirs`.
/// `GitFailed` when one of them cannot be read.
fn inProgressAll(a: std.mem.Allocator, dirs: []const DeletedDir) ![]const InProgress {
    var out: std.ArrayList(InProgress) = .empty;
    for (dirs) |d| for (try inProgress(a, d.dir, d.tree, d.no_tree)) |x| {
        var g = x;
        if (d.link != .there) {
            g.link = d.link;
            g.record = d.dir;
            g.module = d.module;
            g.seen = d.seen;
        }
        try out.append(a, g);
    };
    return out.items;
}

/// The submodule git directory `dir`, not checked out, as `DeletedDir`
/// names it: through the working tree its `core.worktree` names, a
/// symlink followed, which is `.absent` when nothing is there, and
/// `.unresolved` when something is that is not a directory, a symlink to
/// nothing, or what cannot be read, and when it lies under something that
/// is not a directory (`kept.content.underNonDir`); with no
/// `core.worktree`, `no_tree`.
/// `GitFailed` when git cannot read its config.
fn moduleDir(a: std.mem.Allocator, dir: []const u8) !DeletedDir {
    const res = try (At{ .repo = dir, .git_dir = dir }).run(a, &.{ "config", "--get", "core.worktree" });
    switch (res.status) {
        0 => {},
        1 => return .{ .dir = dir, .tree = dir, .no_tree = true },
        else => return error.GitFailed,
    }
    const value = std.mem.trimEnd(u8, res.stdout, "\r\n");
    const tree = try std.fs.path.resolve(a, &.{ dir, value });
    const unreadable = "which cannot be read";
    const not_dir = "which is not a directory";
    const seen = switch (kept.content.entryAt(tree) catch return .{ .dir = dir, .tree = tree, .link = .unresolved, .module = true, .seen = unreadable }) {
        .dir => return .{ .dir = dir, .tree = dir },
        .absent => blk: {
            const under = kept.content.underNonDir(tree) catch break :blk unreadable;
            if (!under) return .{ .dir = dir, .tree = tree, .link = .absent, .module = true };
            break :blk "which lies under something that is not a directory";
        },
        .symlink => blk: {
            const real = fsutil.realPathOrSelf(a, tree) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => break :blk unreadable,
            };
            break :blk switch (kept.content.entryAt(real) catch break :blk unreadable) {
                .dir => return .{ .dir = dir, .tree = dir },
                .absent, .symlink => "a symlink to nothing",
                else => not_dir,
            };
        },
        else => not_dir,
    };
    return .{ .dir = dir, .tree = tree, .link = .unresolved, .module = true, .seen = seen };
}

/// Whether `report`, of the working tree `reconciled`, holds an unsettled
/// item for `rel` of the working tree `tree`.
fn unsettledAt(report: reconcile.Report, reconciled: []const u8, tree: []const u8, rel: []const u8) bool {
    for (report.items) |i| {
        if (i.unsettled and std.mem.eql(u8, i.worktree orelse reconciled, tree) and std.mem.eql(u8, i.rel, rel)) return true;
    }
    return false;
}

/// Whether `rel` of the working tree `tree` is already reported as a
/// candidate or a nested repository.
fn reported(cands: []const Cand, nested: []const NestedAt, tree: []const u8, rel: []const u8) bool {
    for (cands) |x| {
        if (std.mem.eql(u8, x.tree, tree) and std.mem.eql(u8, x.cand.rel, rel)) return true;
    }
    for (nested) |x| {
        if (std.mem.eql(u8, x.tree, tree) and std.mem.eql(u8, x.nested.repo, rel)) return true;
    }
    return false;
}

const testing = std.testing;
const testutil = @import("../testutil.zig");
const workspace = @import("../workspace.zig");
const repo_cmd = @import("repo.zig");
const worktree_cmd = @import("worktree.zig");
const keep_cmd = @import("keep.zig");
const project_cmd = @import("project.zig");
const proc = @import("../proc.zig");

/// Test-only: a sandboxed workspace with one clone at `key` under its code
/// root, and the kept-files context its commands see.
pub const Fixture = struct {
    a: std.mem.Allocator,
    sb: *testutil.Sandbox,
    ws: workspace.Workspace,
    kctx: kept.Ctx,
    bare: []const u8,
    clone: []const u8,

    const key = "holt-test.invalid/acme/widget";
    const url = "https://holt-test.invalid/acme/widget";

    pub fn init(a: std.mem.Allocator, sb: *testutil.Sandbox, with_store: bool) !Fixture {
        const ws = try testutil.testWorkspace(a, sb.root);
        try fsutil.ensureDir(ws.cfg.synced_root);
        const env = app.envOf_current();
        const kctx: kept.Ctx = .{ .alloc = a, .env = env, .layout = .{ .synced_root = ws.cfg.synced_root }, .code_root = ws.cfg.code_root, .machine_id = try kept.machine.load(a, env) };
        if (with_store) _ = try kept.patterns.createStore(a, kctx.layout);
        const bare_owned = try testutil.makeBareRepo(sb, "origin.git");
        defer sb.alloc.free(bare_owned);
        const bare = try a.dupe(u8, bare_owned);
        const clone_path = try fsutil.joinSlashy(a, ws.cfg.code_root, key);
        try fsutil.ensureDir(std.fs.path.dirname(clone_path).?);
        try testutil.runGit(sb, null, &.{ "clone", "-q", bare, clone_path });
        return .{ .a = a, .sb = sb, .ws = ws, .kctx = kctx, .bare = bare, .clone = try fsutil.realPathOrSelf(a, clone_path) };
    }

    pub fn path(f: *const Fixture, rel: []const u8) ![]const u8 {
        return fsutil.joinSlashy(f.a, f.clone, rel);
    }

    pub fn write(f: *const Fixture, tree: []const u8, rel: []const u8, data: []const u8) !void {
        const p = try fsutil.joinSlashy(f.a, tree, rel);
        try fsutil.ensureDir(std.fs.path.dirname(p).?);
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = data });
    }

    /// Adds `line` to the clone's `info/exclude`, outside holt's block.
    pub fn ignore(f: *const Fixture, line: []const u8) !void {
        const p = try std.fs.path.join(f.a, &.{ f.clone, ".git", "info", "exclude" });
        const old = kept.content.readSmall(f.a, p) catch "";
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = try std.mem.concat(f.a, u8, &.{ line, "\n", old }) });
    }

    pub fn keep(f: *const Fixture, tree: []const u8, rel: []const u8) !void {
        const index = try kept.store.loadIndex(f.a, f.kctx.layout);
        _ = try kept.place.keepPath(f.kctx, &index, tree, rel, .{});
    }

    pub fn run(f: *const Fixture, cmd: *const fn (ctx: *app.Ctx) anyerror!u8, argv: []const []const u8) !testutil.RunResult {
        return testutil.runCmd(f.a, cmd, f.ws, argv);
    }

    /// Every file and directory under `kept/`, with each file's hash; the
    /// aside entries left out unless `with_aside`.
    pub fn snapshot(f: *const Fixture, with_aside: bool) ![]const []const u8 {
        const kept_dir = try f.kctx.layout.keptDir(f.a);
        var d = try std.Io.Dir.cwd().openDir(io(), kept_dir, .{ .iterate = true });
        defer d.close(io());
        var walker = try d.walk(f.a);
        defer walker.deinit();
        var out: std.ArrayList([]const u8) = .empty;
        while (try walker.next(io())) |e| {
            const rel = try f.a.dupe(u8, e.path);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
            if (!with_aside and std.mem.startsWith(u8, rel, ".holt-aside")) continue;
            if (std.mem.startsWith(u8, rel, ".holt-tmp")) continue;
            const hex: []const u8 = switch (e.kind) {
                .file => &(try kept.content.hashFile(f.a, try std.fs.path.join(f.a, &.{ kept_dir, e.path }))),
                .directory => "dir",
                else => "other",
            };
            try out.append(f.a, try std.fmt.allocPrint(f.a, "{s} {s}", .{ rel, hex }));
        }
        std.mem.sort([]const u8, out.items, {}, kept.paths.lessThan);
        return out.items;
    }

    /// The content of `file`, at or below `rel`, in the one aside entry
    /// holding `rel`.
    pub fn asideFile(f: *const Fixture, rel: []const u8, file: []const u8) ![]const u8 {
        const dir = try f.kctx.layout.asideDir(f.a);
        var d = try std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true });
        defer d.close(io());
        var found: ?[]const u8 = null;
        var it = d.iterate();
        while (try it.next(io())) |e| {
            const m = (try kept.aside.readManifest(f.a, f.kctx.layout, e.name)) orelse continue;
            if (!std.mem.eql(u8, m.rel, rel)) continue;
            if (found != null) return error.TestUnexpectedResult;
            found = try kept.content.readSmall(f.a, try kept.aside.dataPath(f.a, f.kctx.layout, e.name, file));
        }
        return found orelse error.TestUnexpectedResult;
    }

    /// The data of every aside entry holding `rel`, but those holding a
    /// staged version.
    pub fn asideData(f: *const Fixture, rel: []const u8) ![]const []const u8 {
        const dir = try f.kctx.layout.asideDir(f.a);
        var out: std.ArrayList([]const u8) = .empty;
        var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch return out.items;
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| {
            const m = (try kept.aside.readManifest(f.a, f.kctx.layout, e.name)) orelse continue;
            if (!std.mem.eql(u8, m.rel, rel) or m.index.len > 0) continue;
            try out.append(f.a, try kept.content.readSmall(f.a, try kept.aside.dataPath(f.a, f.kctx.layout, e.name, rel)));
        }
        return out.items;
    }
};

/// `expectSame`, leaving out of `after` the aside entries a delete adds to
/// record, by its target, a link it removed.
fn expectSameButLinkRecords(f: *const Fixture, before: []const []const u8, after: []const []const u8) !void {
    var kept_lines: std.ArrayList([]const u8) = .empty;
    for (after) |line| {
        if (kept.paths.contains(before, line)) {
            try kept_lines.append(f.a, line);
            continue;
        }
        const path = line[0 .. std.mem.lastIndexOfScalar(u8, line, ' ') orelse line.len];
        const prefix = ".holt-aside/";
        if (std.mem.eql(u8, path, ".holt-aside")) continue;
        if (!std.mem.startsWith(u8, path, prefix)) {
            try kept_lines.append(f.a, line);
            continue;
        }
        const rest = path[prefix.len..];
        const stamp = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        const m = (try kept.aside.readManifest(f.a, f.kctx.layout, stamp)) orelse {
            try kept_lines.append(f.a, line);
            continue;
        };
        if (!(m.files.len == 0 and m.links.len == 1 and std.mem.eql(u8, m.reason, "deleting"))) try kept_lines.append(f.a, line);
    }
    try expectSame(before, kept_lines.items);
}

fn expectSame(before: []const []const u8, after: []const []const u8) !void {
    try testing.expectEqual(before.len, after.len);
    for (before, after) |b, x| try testing.expectEqualStrings(b, x);
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// An asker for a test that weighs a repository without a command run.
fn testAsker(a: std.mem.Allocator) !Asker {
    const answers = try a.create(Answers);
    answers.* = .empty;
    const run = try a.create(AskRun);
    run.* = .{};
    return .{ .alloc = a, .answers = answers, .run = run };
}

inline fn skipWithoutLinks() !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
}

test "repo remove --clone: a file holt does not keep refuses the delete and names the review, leaving kept/ as it was" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try f.ignore("/secret.txt");
    try f.write(f.clone, "secret.txt", "only here");
    const before = try f.snapshot(true);

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "not kept: "));
    try testing.expect(contains(got.err, "secret.txt"));
    try testing.expect(contains(got.err, "run: holt keep --review "));
    try testing.expect(fsutil.exists(try f.path("secret.txt")));
    try expectSameButLinkRecords(&f, before, try f.snapshot(true));
}

test "repo remove --clone: an unsettled kept path is named with the command that settles it, and a dangling link is not called content" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try std.Io.Dir.cwd().deleteFile(io(), try f.kctx.layout.copyPath(a, Fixture.key, ".env.kept"));

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    const qp = try q_test(a, try f.path(".env.kept"));
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "  {s}: ", .{qp})));
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "run: holt unkeep {s}", .{qp})));
    try testing.expect(!contains(got.err, "unsettled ("));
    try testing.expect(!contains(got.err, "holt keep --review"));
    try testing.expect(!contains(got.err, "exists nowhere else"));
    try testing.expect(fsutil.exists(f.clone));
}

fn q_test(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return ui.quotePath(a, app.envOf_current(), path);
}

test "repo remove --clone --force: sets every candidate aside, never touches a kept copy, and names unkeep --repo" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try f.write(f.clone, ".superpowers/plan.md", "plan");
    try f.keep(f.clone, ".superpowers");
    try f.ignore("/secret.txt");
    try f.ignore("/cache/");
    try f.write(f.clone, "secret.txt", "only here");
    try f.write(f.clone, "cache/deep/note.txt", "also only here");
    const before = try f.snapshot(false);

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(f.clone));
    try expectSame(before, try f.snapshot(false));
    try testing.expectEqualStrings("kept secret", try kept.content.readSmall(a, try f.kctx.layout.copyPath(a, Fixture.key, ".env.kept")));
    try testing.expectEqualStrings("plan", try kept.content.readSmall(a, try f.kctx.layout.copyPath(a, Fixture.key, ".superpowers/plan.md")));
    const secret = try f.asideData("secret.txt");
    try testing.expectEqual(@as(usize, 1), secret.len);
    try testing.expectEqualStrings("only here", secret[0]);
    try testing.expect(contains(got.out, "set aside "));
    try testing.expect(contains(got.out, "kept files remain at "));
    try testing.expect(contains(got.out, "holt unkeep --repo " ++ Fixture.key));
}

test "repo remove --clone: kept links alone do not refuse, and kept/ is as it was after the delete but for the removed links' records" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.write(f.clone, ".superpowers/plan.md", "plan");
    try f.keep(f.clone, ".superpowers");
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const before = try f.snapshot(true);

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(f.clone));
    try expectSameButLinkRecords(&f, before, try f.snapshot(true));
}

test "repo remove --clone: an interrupted delete leaves kept/ as it was, and the next reconcile links again" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.write(f.clone, ".superpowers/plan.md", "plan");
    try f.keep(f.clone, ".superpowers");
    try f.ignore("/secret.txt");
    try f.write(f.clone, "secret.txt", "only here");
    const before = try f.snapshot(false);

    for ([_]@TypeOf(stop_for_test){ .set_aside, .unlinked }) |at| {
        stop_for_test = at;
        defer stop_for_test = null;
        try testing.expectError(error.Interrupted, f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" }));
        try expectSame(before, try f.snapshot(false));
        try testing.expect(fsutil.exists(try f.path("secret.txt")));
    }
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try f.path(".superpowers")));
    const report = try @import("../kept/harness.zig").reconcileIn(f.kctx, f.clone, .apply);
    try testing.expect(report.find(".superpowers", .linked) != null);
    try testing.expectEqualStrings("plan", try kept.content.readSmall(a, try f.path(".superpowers/plan.md")));
}

test "repo remove --clone --force: the user's own link of holt's shape at a kept path is the user's, recorded by its target" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.ignore("/.env");
    try f.write(f.clone, ".env", "kept");
    try f.keep(f.clone, ".env");
    const mine = try fsutil.joinSlashy(a, sb.root, "notes/kept/" ++ Fixture.key ++ "/.env");
    try fsutil.ensureDir(std.fs.path.dirname(mine).?);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = mine, .data = "mine" });
    try fsutil.removePath(try f.path(".env"));
    try kept.content.createLink(mine, try f.path(".env"), .file);

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(contains(got.out, try std.fmt.allocPrint(a, "link recorded {s} -> {s}", .{ try ui.quotePath(a, app.envOf_current(), try f.path(".env")), mine })));
    try testing.expectEqualStrings("mine", try kept.content.readSmall(a, mine));
}

test "repo remove --clone: holt's links are recorded by their target before they are removed, and a link at a temporary that is not holt's is left" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.ignore("/.env");
    try f.write(f.clone, ".env", "kept");
    try f.keep(f.clone, ".env");
    const temp = try kept.paths.tempRel(a, ".env");
    try kept.block.add(a, try std.fs.path.join(a, &.{ f.clone, ".git" }), &.{temp});
    try kept.content.createLink("/elsewhere", try f.path(temp), .file);

    stop_for_test = .unlinked;
    defer stop_for_test = null;
    try testing.expectError(error.Interrupted, f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" }));
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try f.path(".env")));
    try testing.expectEqualStrings("/elsewhere", (try kept.content.readLink(a, try f.path(temp))).?);

    const want = try f.kctx.layout.copyPath(a, Fixture.key, ".env");
    var found = false;
    var d = try std.Io.Dir.cwd().openDir(io(), try f.kctx.layout.asideDir(a), .{ .iterate = true });
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        const m = (try kept.aside.readManifest(a, f.kctx.layout, e.name)) orelse continue;
        if (!std.mem.eql(u8, m.rel, ".env") or !std.mem.eql(u8, m.reason, "deleting")) continue;
        for (m.links) |l| if (std.mem.eql(u8, l.target, want)) {
            found = true;
        };
    }
    try testing.expect(found);
}

test "repo remove --clone --force: a staged version that differs from the working tree is set aside under index/ and named" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.write(f.clone, "notes.txt", "committed");
    try testutil.runGit(&sb, f.clone, &.{ "add", "notes.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "notes" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });
    try f.write(f.clone, "notes.txt", "staged");
    try testutil.runGit(&sb, f.clone, &.{ "add", "notes.txt" });
    try f.write(f.clone, "notes.txt", "working");
    try f.write(f.clone, "gone.txt", "staged only");
    try testutil.runGit(&sb, f.clone, &.{ "add", "gone.txt" });
    try fsutil.removePath(try f.path("gone.txt"));

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(f.clone));
    for ([_][2][]const u8{ .{ "notes.txt", "staged" }, .{ "gone.txt", "staged only" } }) |want| {
        const dir = try f.kctx.layout.asideDir(a);
        var d = try std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true });
        defer d.close(io());
        var it = d.iterate();
        var stamp: ?[]const u8 = null;
        while (try it.next(io())) |e| {
            const m = (try kept.aside.readManifest(a, f.kctx.layout, e.name)) orelse continue;
            if (std.mem.eql(u8, m.rel, want[0]) and m.index.len == 1) stamp = try a.dupe(u8, e.name);
        }
        const at = try std.fs.path.join(a, &.{ dir, stamp.?, "index", want[0] });
        try testing.expectEqualStrings(want[1], try kept.content.readSmall(a, at));
        try testing.expect(contains(got.out, try std.fmt.allocPrint(a, "set aside the staged version of {s} (kept/.holt-aside/{s}/index/{s})", .{ try ui.quotePath(a, app.envOf_current(), try f.path(want[0])), stamp.?, want[0] })));
    }
    try testing.expectEqualStrings("working", (try f.asideData("notes.txt"))[0]);
}

test "repo remove --clone: the summary names custom hooks and local git config the delete loses" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".git/hooks/pre-commit", "#!/bin/sh\n");
    try testutil.runGit(&sb, f.clone, &.{ "config", "user.name", "someone" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    const hooks = try ui.quotePath(a, app.envOf_current(), try std.fs.path.join(a, &.{ f.clone, ".git", "hooks" }));
    try testing.expect(contains(got.out, try std.fmt.allocPrint(a, "deleting custom hooks in {s}: pre-commit\n", .{hooks})));
    try testing.expect(contains(got.out, "deleting local git config in "));
    try testing.expect(contains(got.out, ": user.name\n"));
    try testing.expect(!contains(got.out, "remote.origin"));
}

test "repo remove --clone: a nested repository refuses; --force lists it as deleted" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.ignore("/vendor/");
    const nested = try f.path("vendor/lib");
    try fsutil.ensureDir(nested);
    try testutil.runGit(&sb, nested, &.{ "init", "-q", "-b", "main" });
    try testutil.runGit(&sb, nested, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, "nested repository"));
    try testing.expect(fsutil.exists(nested));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, "deleting nested repository "));
    try testing.expect(contains(forced.out, "  with 1 ref no remote on another machine holds, in "));
    try testing.expect(!fsutil.exists(f.clone));
}

test "repo remove --clone: a place whose name holds a control character is listed with \\xHH, never raw or shell-quoted" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.ignore("/s\x01.txt");
    try f.write(f.clone, "s\x01.txt", "only here");
    try f.ignore("/v\tdir/");
    const nested = try f.path("v\tdir");
    try fsutil.ensureDir(nested);
    try testutil.runGit(&sb, nested, &.{ "init", "-q", "-b", "main" });
    try testutil.runGit(&sb, nested, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "  not kept: {s}\n", .{try ui.printable(a, try fsutil.contractTilde(a, app.envOf_current(), try f.path("s\x01.txt")))})));
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "  nested repository (--force deletes it): {s}\n", .{try ui.printable(a, try fsutil.contractTilde(a, app.envOf_current(), nested))})));
    try testing.expect(std.mem.indexOfAny(u8, refused.err, "\x01\t") == null);

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, try std.fmt.allocPrint(a, "deleting nested repository {s}\n", .{try ui.printable(a, try fsutil.contractTilde(a, app.envOf_current(), nested))})));
    try testing.expect(std.mem.indexOfAny(u8, forced.out, "\x01\t") == null);
}

test "repo remove --clone: an edit git hides in a tracked file refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try testutil.runGit(&sb, f.clone, &.{ "update-index", "--skip-worktree", "README" });
    try f.write(f.clone, "README", "edited where git does not look");

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, "README"));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    const held = try f.asideData("README");
    try testing.expectEqual(@as(usize, 1), held.len);
    try testing.expectEqualStrings("edited where git does not look", held[0]);
}

test "repo remove --clone: a kept file a tool replaced with different content refuses the delete, and --force deletes it only once it is set aside" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try fsutil.removePath(try f.path(".env.kept"));
    try f.write(f.clone, ".env.kept", "edited by a tool that saves by rename");
    const before = try f.snapshot(false);

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "  {s}: local copy differs from the kept copy (run: holt keep --take-local {s}", .{ try q_test(a, try f.path(".env.kept")), try q_test(a, try f.path(".env.kept")) })));
    try testing.expect(!contains(refused.err, "not kept: "));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try expectSame(before, try f.snapshot(false));
    var found = false;
    for (try f.asideData(".env.kept")) |d| {
        if (std.mem.eql(u8, d, "edited by a tool that saves by rename")) found = true;
    }
    try testing.expect(found);
}

test "repo remove --clone: without kept/, candidates are still listed under the seed patterns before any delete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, false);

    try f.ignore("/secret.txt");
    try f.ignore("/node_modules/");
    try f.write(f.clone, "secret.txt", "only here");
    try f.write(f.clone, "node_modules/x/index.js", "regenerable");

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, "secret.txt"));
    try testing.expect(!contains(refused.err, "node_modules"));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, "deleting (kept files are not set up): "));
    try testing.expect(!fsutil.exists(f.clone));
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try f.kctx.layout.keptDir(a)));
}

test "repo remove --clone: a clone with holt's block refuses even with --force when kept/ cannot be reached" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const kept_dir = try f.kctx.layout.keptDir(a);
    const away = try std.fmt.allocPrint(a, "{s}.away", .{kept_dir});
    try std.Io.Dir.cwd().rename(kept_dir, std.Io.Dir.cwd(), away, io());

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "kept/"));
    try testing.expect(contains(got.err, "cannot be reached"));
    try testing.expect(fsutil.exists(f.clone));
}

test "repo remove --clone --force: a mount point of another filesystem inside the clone refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try f.ignore("/mnt/");
    try f.write(f.clone, "mnt/data/big.bin", "on another filesystem");
    candidates.other_filesystem_for_test = "mnt/data";
    defer candidates.other_filesystem_for_test = null;

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "mnt/data"));
    try testing.expect(contains(got.err, "another filesystem"));
    try testing.expectEqualStrings("on another filesystem", try kept.content.readSmall(a, try f.path("mnt/data/big.bin")));
}

test "repo remove --clone --force: a mount point inside a nested repository, or inside the clone's .git, refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try testutil.runGit(&sb, null, &.{ "init", "-q", try f.path("vend") });
    try f.write(f.clone, "vend/mnt/big.bin", "on another filesystem");
    try fsutil.ensureDir(try f.path(".git/mnt"));
    for ([_][]const u8{ "vend/mnt", ".git/mnt" }) |mount| {
        candidates.other_filesystem_for_test = mount;
        defer candidates.other_filesystem_for_test = null;
        const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(contains(got.err, mount));
        try testing.expect(contains(got.err, "another filesystem"));
        try testing.expectEqualStrings("on another filesystem", try kept.content.readSmall(a, try f.path("vend/mnt/big.bin")));
    }
}

test "repo remove --clone: a commit only a local tag or notes ref holds refuses the delete, naming each ref; --force names each as deleted" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    try f.write(f.clone, "exp.txt", "tagged work");
    try testutil.runGit(&sb, f.clone, &.{ "add", "exp.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "tag only" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "-a", "-m", "exp", "experiment" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "released", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "notes", "add", "-m", "a note", "main" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(fsutil.exists(f.clone));
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "the tag only refs/tags/experiment names, no remote has, in {s} (run: git -C {s} push --recurse-submodules=no -- origin refs/tags/experiment:refs/tags/holt-kept/tags/experiment)", .{ cq, cq })));
    try testing.expect(contains(got.err, "commits only refs/notes/commits holds"));
    try testing.expect(!contains(got.err, "refs/tags/released"));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, "deleting the tag only refs/tags/experiment names"));
    try testing.expect(contains(forced.out, "deleting commits only refs/notes/commits holds"));
    try testing.expect(!fsutil.exists(f.clone));
}

test "repo remove --clone: a tag or notes ref the remote holds, pushed as hinted, no longer refuses; a remote that cannot be asked refuses, naming --force" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);

    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    try f.write(f.clone, "exp.txt", "tagged work");
    try testutil.runGit(&sb, f.clone, &.{ "add", "exp.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "tag only" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "-a", "-m", "exp", "experiment" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "notes", "add", "-m", "a note", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "refs/tags/experiment" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "refs/notes/commits" });

    const gone = try std.fs.path.join(a, &.{ f.bare, "gone.git" });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", gone });
    const unasked = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), unasked.code);
    const lead = try std.fmt.allocPrint(a, "4 refs not confirmed held, in {s}: refs/heads/main, refs/notes/commits, refs/remotes/origin/main, and 1 more (remote origin could not be asked at {s}: repository not found); ", .{ cq, gone });
    try testing.expect(contains(unasked.err, try std.fmt.allocPrint(a, "{s}replace this push URL (run: git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine), or --force deletes them\n", .{ lead, cq })));
    try testing.expect(fsutil.exists(f.clone));
    try runHint(&f, unasked.err, lead, f.bare);

    const old_notes = try git.runInRepoScoped(a, &.{ "rev-parse", "refs/notes/commits" }, f.clone);
    try f.write(f.clone, "more.txt", "more");
    try testutil.runGit(&sb, f.clone, &.{ "add", "more.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "more" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "notes", "add", "-m", "a later note", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "refs/notes/commits" });
    try testutil.runGit(&sb, f.clone, &.{ "update-ref", "refs/notes/commits", std.mem.trim(u8, old_notes.stdout, " \r\n") });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(f.clone));
}

test "repo remove --clone: a deinitialized submodule's unpushed branch, and a nested submodule's, refuse the delete; --force names each" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const sub = try withSubmodule(&f, false);
    try f.write(sub, "work.txt", "unpushed work");
    try testutil.runGit(&sb, sub, &.{ "add", "work.txt" });
    try testutil.runGit(&sb, sub, &.{ "commit", "-q", "-m", "local only" });
    try testutil.runGit(&sb, sub, &.{ "switch", "-q", "-c", "wip" });
    try testutil.runGit(&sb, f.clone, &.{ "submodule", "deinit", "-q", "-f", "sub" });
    const inner = try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub", "modules", "deep" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", inner });
    try testutil.runGit(&sb, inner, &.{ "--git-dir=.", "fetch", "-q", try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }), "wip:refs/heads/deep-wip" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(fsutil.exists(f.clone));
    const gd = try ui.quotePath(a, app.envOf_current(), try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }));
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "branch wip no remote has, in {s}", .{gd})));
    try testing.expect(contains(got.err, ": refs/heads/deep-wip; no remote counts as a copy: it has no remote; add a remote on another machine (run: git -C "));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, try std.fmt.allocPrint(a, "deleting commits of branch wip no remote has, in {s}", .{gd})));
    try testing.expect(contains(forced.out, "deleting 1 ref no remote on another machine holds, in "));
}

test "repo remove --clone: a checked-out submodule is weighed once, through its working tree" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const sub = try withSubmodule(&f, false);
    try testutil.runGit(&sb, sub, &.{ "switch", "-q", "-c", "wip" });
    try testutil.runGit(&sb, sub, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.err, "branch wip no remote has"));
}

test "repo remove --clone: a local branch no remote has in the main clone refuses the delete; --force names it and a stash as deleted" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "-c", "wip" });
    try f.write(f.clone, "wip.txt", "unpushed work");
    try testutil.runGit(&sb, f.clone, &.{ "add", "wip.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "local only" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "commits of branch wip no remote has"));
    try testing.expect(contains(got.err, "push --recurse-submodules=no -- origin refs/heads/wip:refs/heads/wip"));
    try testing.expect(fsutil.exists(f.clone));

    try f.write(f.clone, "stashed.txt", "stashed work");
    try testutil.runGit(&sb, f.clone, &.{ "stash", "-q", "-u" });
    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, "deleting commits of branch wip no remote has"));
    try testing.expect(contains(forced.out, "deleting stash entries of"));
    try testing.expect(!fsutil.exists(f.clone));
}

test "archive --prune: a local branch no remote has in the main clone keeps the clone" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "-c", "wip" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });

    const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(contains(got.out, "not pruned widget: commits of branch wip no remote has"));
    try testing.expect(fsutil.exists(f.clone));
}

test "archive --prune: a clone kept by several gates names each on a line of its own, and settling them all lets the delete through" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try f.ignore("/secret.txt");
    try f.write(f.clone, "secret.txt", "only here");
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "-c", "wip" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });

    const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    const quoted = try ui.quotePath(a, app.envOf_current(), f.clone);
    const want = try std.fmt.allocPrint(a, "not pruned widget:\n  1 file not kept (run: holt keep --review {s})\n  commits of branch wip no remote has, in {s} (run: git -C {s} push --recurse-submodules=no -- origin refs/heads/wip:refs/heads/wip)\n  once settled, delete it with: holt repo remove {s} --clone\n", .{ quoted, try fsutil.contractTilde(a, app.envOf_current(), f.clone), quoted, Fixture.key });
    try testing.expect(contains(got.out, want));
    try testing.expect(fsutil.exists(f.clone));

    try f.keep(f.clone, "secret.txt");
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "-u", "origin", "wip" });
    try testing.expectEqual(@as(u8, 0), (try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" })).code);
    try testing.expect(!fsutil.exists(f.clone));
}

test "repo remove --clone on a terminal offers the review under the held locks: a file kept there no longer refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.ignore("/secret.txt");
    try f.write(f.clone, "secret.txt", "only here");
    kept_ctx.lock_nonblocking_for_test = true;
    defer kept_ctx.lock_nonblocking_for_test = false;
    ui.stdin_terminal_for_test = true;
    defer ui.stdin_terminal_for_test = null;
    ui.stdin_for_test = "k\ny\n";
    defer ui.stdin_for_test = null;

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(contains(got.out, "secret.txt"));
    try testing.expectEqualStrings("only here", try kept.content.readSmall(a, try f.kctx.layout.copyPath(a, Fixture.key, "secret.txt")));
    try testing.expect(!fsutil.exists(f.clone));
}

test "worktree -r on a terminal offers the review; without one it refuses naming the review" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feat" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feat" });
    try testing.expectEqual(@as(u8, 0), made.code);
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try f.ignore("/notes.txt");
    try f.write(wt, "notes.txt", "only in the worktree");
    kept_ctx.lock_nonblocking_for_test = true;
    defer kept_ctx.lock_nonblocking_for_test = false;

    ui.stdin_terminal_for_test = false;
    defer ui.stdin_terminal_for_test = null;
    const refused = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feat", "-r" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, "run: holt keep --review "));

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "k\n";
    defer ui.stdin_for_test = null;
    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feat", "-r" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(wt));
}

/// A project `acme/proj` whose member `widget` is the fixture's clone.
fn withProject(f: *const Fixture) !void {
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(f.a, "widget", Fixture.url);
    try testutil.writeMarker(f.a, try f.ws.projectsRoot(f.a), "acme", "proj", repos, .empty);
}

test "worktree -r: a kept path whose copy differs there, after another tree's keep swept it, is named once, with the command that settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    try testing.expectEqual(@as(u8, 0), made.code);
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try fsutil.removePath(try fsutil.joinSlashy(a, wt, ".env.kept"));
    try f.write(wt, ".env.kept", "the worktree's own");
    try f.write(f.clone, "other.kept", "o");
    try f.keep(f.clone, "other.kept");

    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 1), got.code);
    const qp = try q_test(a, try fsutil.joinSlashy(a, wt, ".env.kept"));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, got.err, qp));
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "  {s}: local copy differs from the kept copy (run: holt keep --take-local {s}, or holt keep --take-kept {s})\n", .{ qp, qp, qp })));
    try testing.expect(fsutil.exists(wt));

    try testing.expectEqual(@as(u8, 0), (try f.run(keep_cmd.command.run, &.{ "--take-local", try fsutil.joinSlashy(a, wt, ".env.kept") })).code);
    try testing.expectEqual(@as(u8, 0), (try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" })).code);
    try testing.expect(!fsutil.exists(wt));
}

test "worktree -r: refuses a candidate; --force sets it aside and passes --force to git; kept/ is as it was but for the removed links' records" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });

    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    try testing.expectEqual(@as(u8, 0), made.code);
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try f.write(wt, ".superpowers/plan.md", "plan");
    try f.keep(wt, ".superpowers");
    try f.ignore("/secret.txt");
    try f.write(wt, "secret.txt", "only in the worktree");
    try f.write(wt, "README", "a tracked edit");
    const before = try f.snapshot(false);

    const refused = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, "secret.txt"));
    try testing.expect(contains(refused.err, "run: holt keep --review "));
    try testing.expect(fsutil.exists(wt));

    const forced = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r", "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(wt));
    try expectSame(before, try f.snapshot(false));
    const held = try f.asideData("secret.txt");
    try testing.expectEqual(@as(usize, 1), held.len);
    try testing.expectEqualStrings("only in the worktree", held[0]);
    try testing.expectEqualStrings("plan", try kept.content.readSmall(a, try f.kctx.layout.copyPath(a, Fixture.key, ".superpowers/plan.md")));
}

test "worktree -r: a worktree holding only kept links is removed with kept/ as it was but for the removed links' records, and a dirty one refuses before anything is unlinked" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });

    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try f.write(wt, ".env.kept", "kept secret");
    try f.keep(wt, ".env.kept");
    try f.write(wt, "README", "a tracked edit");
    const before = try f.snapshot(true);

    const dirty = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 1), dirty.code);
    try testing.expect(contains(dirty.err, "uncommitted changes"));
    try testing.expectEqual(kept.content.Entry.symlink, try kept.content.entryAt(try fsutil.joinSlashy(a, wt, ".env.kept")));

    try testutil.runGit(&sb, wt, &.{ "checkout", "--", "README" });
    const removed = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 0), removed.code);
    try testing.expect(!fsutil.exists(wt));
    try expectSameButLinkRecords(&f, before, try f.snapshot(true));
}

test "worktree: --force without --remove is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, false);
    try withProject(&f);
    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "--force" });
    try testing.expectEqual(@as(u8, 2), got.code);
}

test "archive --prune: a clone holding a file holt does not keep is not pruned, with the review command" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try f.ignore("/secret.txt");
    try f.write(f.clone, "secret.txt", "only here");

    const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    const quoted = try ui.quotePath(a, app.envOf_current(), f.clone);
    const want = try std.fmt.allocPrint(a, "not pruned widget: 1 file not kept (run: holt keep --review {s}); once settled, delete it with: holt repo remove {s} --clone\n", .{ quoted, Fixture.key });
    try testing.expect(contains(got.out, want));
    try testing.expect(fsutil.exists(try f.path("secret.txt")));

    try f.keep(f.clone, "secret.txt");
    try testing.expectEqual(@as(u8, 0), (try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" })).code);
    try testing.expect(!fsutil.exists(f.clone));
}

test "archive --prune: a clone with only kept links is reclaimed, leaving kept/ as it was but for the removed links' records" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try f.write(f.clone, ".superpowers/plan.md", "plan");
    try f.keep(f.clone, ".superpowers");
    const before = try f.snapshot(true);

    const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(contains(got.out, "reclaimed widget"));
    try testing.expect(!fsutil.exists(f.clone));
    try expectSameButLinkRecords(&f, before, try f.snapshot(true));
}

/// A review that keeps every candidate of the working tree at `path` under
/// the locks it is handed.
fn keepEverything(ctx: *app.Ctx, kctx: kept.Ctx, index: *const kept.store.KeyIndex, path: []const u8, held: ?kept.Held) anyerror!void {
    _ = ctx;
    const listing = try candidates.list(kctx, index, path, .{ .held = held });
    for (listing.candidates) |c| _ = try kept.place.keepPath(kctx, index, path, c.rel, .{ .held = held });
}

test "prepare: an inline review runs under the locks prepare holds, and the gates are weighed again after it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.ignore("/secret.txt");
    try f.write(f.clone, "secret.txt", "only here");

    kept_ctx.lock_nonblocking_for_test = true;
    defer kept_ctx.lock_nonblocking_for_test = false;
    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = .{ .ws = f.ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };

    var without = (try prepare(&ctx, f.clone, .clone, .{})).ready;
    try testing.expect(without.found.blocked());
    try testing.expectError(error.WouldBlock, kept.lockClone(f.kctx, without.c.?.common_dir));
    without.release();

    var reviewed = (try prepare(&ctx, f.clone, .clone, .{ .review = keepEverything, .interactive = true })).ready;
    defer reviewed.release();
    try testing.expect(!reviewed.found.blocked());
    try testing.expectEqualStrings("only here", try kept.content.readSmall(a, try f.kctx.layout.copyPath(a, Fixture.key, "secret.txt")));
}

test "reconcileHeld: refuses locks that are not the clone's and the key's, and runs without taking them again when they are" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");

    kept_ctx.lock_nonblocking_for_test = true;
    defer kept_ctx.lock_nonblocking_for_test = false;
    const c = try kept.clone.inspect(a, f.clone, f.kctx.code_root);
    const index = try kept.store.loadIndex(a, f.kctx.layout);
    const clone_lock = try kept.lockClone(f.kctx, c.common_dir);
    defer clone_lock.release();
    const other = try kept.lockKey(f.kctx, "holt-test.invalid/acme/other");
    defer other.release();
    try testing.expectError(error.LocksNotHeld, reconcile.reconcileHeld(f.kctx, &index, f.clone, .apply, kept.Held.of(clone_lock, other)));
    try testing.expectError(error.WouldBlock, reconcile.reconcile(f.kctx, &index, f.clone, .apply));
    const key_lock = try kept.lockKey(f.kctx, Fixture.key);
    defer key_lock.release();
    const report = try reconcile.reconcileHeld(f.kctx, &index, f.clone, .apply, kept.Held.of(clone_lock, key_lock));
    try testing.expect(report.find(".env.kept", .ok) != null);
}

test "prepare: a local/ clone that never kept anything is not held back by reconcile's stop" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const solo = try fsutil.joinSlashy(a, f.ws.cfg.code_root, "local/solo");
    try fsutil.ensureDir(solo);
    try testutil.runGit(&sb, solo, &.{ "init", "-q" });
    try testutil.runGit(&sb, solo, &.{ "commit", "-q", "--allow-empty", "-m", "one" });

    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = .{ .ws = f.ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    var p = (try prepare(&ctx, solo, .clone, .{})).ready;
    defer p.release();
    try testing.expectEqual(reconcile.Stop.none, p.found.stop);
    try testing.expectEqual(@as(usize, 0), p.found.unsettled.len + p.found.candidates.len + p.found.unlisted.len);
    try testing.expectEqual(@as(usize, 1), p.found.git.len);
    try testing.expect(p.found.git[0].risk.what == .no_target);
}

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

/// Adds a submodule `sub` of a fresh remote to the fixture's clone, and
/// commits and pushes the superproject, so only what the test adds to the
/// submodule exists nowhere else.
fn withSubmodule(f: *const Fixture, ignore_all: bool) ![]const u8 {
    const remote_owned = try testutil.makeBareRepo(f.sb, "sub.git");
    defer f.sb.alloc.free(remote_owned);
    try testutil.runGit(f.sb, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "sub" });
    if (ignore_all) {
        try testutil.runGit(f.sb, f.clone, &.{ "config", "-f", ".gitmodules", "submodule.sub.ignore", "all" });
        try testutil.runGit(f.sb, f.clone, &.{ "add", ".gitmodules" });
    }
    try testutil.runGit(f.sb, f.clone, &.{ "commit", "-q", "-m", "add sub" });
    try testutil.runGit(f.sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });
    return f.path("sub");
}

test "repo remove --clone --force: a directory holding a name only some filesystems treat as .git is set aside whole where this one does not" {
    try skipWithoutLinks();
    for ([_][]const u8{ "git~1", ".git " }) |name| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);

        try f.ignore("/cache/");
        try f.write(f.clone, "cache/top.txt", "top");
        try f.write(f.clone, "cache/sub/notes.txt", "only here");
        const alias = try std.fmt.allocPrint(a, "cache/sub/{s}", .{name});
        try f.write(f.clone, alias, "x");
        const nested = try kept.content.isNestedRepo(a, try f.path("cache/sub"), try kept.clone.ignoresCase(a, f.clone));

        const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
        try testing.expectEqual(@as(u8, 0), got.code);
        if (nested) {
            try testing.expect(contains(got.out, "deleting nested repository"));
            continue;
        }
        try testing.expectEqualStrings("only here", try f.asideFile("cache", "cache/sub/notes.txt"));
        try testing.expectEqualStrings("x", try f.asideFile("cache", alias));
    }
}

test "repo remove --clone: a submodule's unpushed commit and stash refuse the delete; --force names them as deleted" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const sub = try withSubmodule(&f, false);

    try f.write(sub, "work.txt", "unpushed work");
    try testutil.runGit(&sb, sub, &.{ "add", "work.txt" });
    try testutil.runGit(&sb, sub, &.{ "commit", "-q", "-m", "local only" });
    try f.write(sub, "stashme", "s");
    try testutil.runGit(&sb, sub, &.{ "stash", "-q", "-u" });
    try testutil.runGit(&sb, f.clone, &.{ "add", "sub" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "bump sub" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, "commits of branch main no remote has"));
    try testing.expect(contains(refused.err, "push --recurse-submodules=no -- origin refs/heads/main:refs/heads/holt-kept/main"));
    try testing.expect(contains(refused.err, "stash entries of "));
    try testing.expect(contains(refused.err, "holt repo remove " ++ Fixture.key ++ " --clone --force"));
    try testing.expect(fsutil.exists(f.clone));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, "deleting commits of branch main no remote has, in "));
    try testing.expect(contains(forced.out, "deleting stash entries of "));
    try testing.expect(!fsutil.exists(f.clone));
}

test "archive --prune: a submodule's unpushed commit keeps the clone" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    const sub = try withSubmodule(&f, false);
    try f.write(sub, "work.txt", "unpushed work");
    try testutil.runGit(&sb, sub, &.{ "add", "work.txt" });
    try testutil.runGit(&sb, sub, &.{ "commit", "-q", "-m", "local only" });
    try testutil.runGit(&sb, f.clone, &.{ "add", "sub" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "bump sub" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });

    const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(contains(got.out, "not pruned widget: commits of branch main no remote has"));
    try testing.expect(fsutil.exists(f.clone));
}

test "repo remove --clone: work a submodule's ignore=all hides refuses the delete; --force sets it aside first" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const sub = try withSubmodule(&f, true);
    try f.write(sub, "draft.md", "only here, untracked in the submodule");
    try f.write(sub, "README", "tracked edit in the submodule");

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(fsutil.exists(try f.path("sub/draft.md")));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(f.clone));
    const draft = try f.asideData("sub/draft.md");
    try testing.expectEqual(@as(usize, 1), draft.len);
    try testing.expectEqualStrings("only here, untracked in the submodule", draft[0]);
    const readme = try f.asideData("sub/README");
    try testing.expectEqual(@as(usize, 1), readme.len);
    try testing.expectEqualStrings("tracked edit in the submodule", readme[0]);
}

test "repo remove --clone: an untracked file status.showUntrackedFiles=no hides refuses the delete; --force sets it aside" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "config", "status.showUntrackedFiles", "no" });
    try f.write(f.clone, "draft.md", "only here");

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(fsutil.exists(try f.path("draft.md")));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    const held = try f.asideData("draft.md");
    try testing.expectEqual(@as(usize, 1), held.len);
    try testing.expectEqualStrings("only here", held[0]);
}

test "repo remove --clone --force: untracked files and tracked edits are set aside before the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, "draft.md", "only here");
    try f.write(f.clone, "notes/deep.txt", "an untracked directory");
    try f.write(f.clone, "README", "a tracked edit");

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(f.clone));
    try testing.expectEqualStrings("only here", (try f.asideData("draft.md"))[0]);
    try testing.expectEqualStrings("a tracked edit", (try f.asideData("README"))[0]);
    try testing.expectEqualStrings("an untracked directory", try f.asideFile("notes", "notes/deep.txt"));
}

test "clear: what appears after prepare is weighed again: it refuses the delete, and --force sets it aside" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try f.ignore("/secret.txt");

    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = .{ .ws = f.ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    var p = (try prepare(&ctx, f.clone, .clone, .{})).ready;
    defer p.release();
    try testing.expect(!p.found.blocked());

    try f.write(f.clone, "secret.txt", "written while the prompt was open");
    try testing.expectEqual(Cleared.blocked, try p.clear(&ctx, false, .reuse));
    try testing.expectEqual(kept.content.Entry.symlink, try kept.content.entryAt(try f.path(".env.kept")));
    try testing.expectEqual(@as(usize, 0), (try f.asideData("secret.txt")).len);

    try testing.expectEqual(Cleared.done, try p.clear(&ctx, true, .reuse));
    try testing.expectEqualStrings("written while the prompt was open", (try f.asideData("secret.txt"))[0]);
}

test "worktree -r: commits only a detached HEAD holds refuse the removal; --force names the commit" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try testutil.runGit(&sb, wt, &.{ "checkout", "-q", "--detach" });
    try f.write(wt, "x.txt", "detached work");
    try testutil.runGit(&sb, wt, &.{ "add", "x.txt" });
    try testutil.runGit(&sb, wt, &.{ "commit", "-q", "-m", "detached" });
    const sha = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "HEAD" }, wt)).stdout, "\r\n");

    const refused = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, sha));
    try testing.expect(contains(refused.err, " branch holt-kept/head-"));
    try testing.expect(fsutil.exists(wt));

    const forced = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r", "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, try std.fmt.allocPrint(a, "deleting commit {s}, which only the HEAD of worktree feature holds", .{sha})));
    try testing.expect(!fsutil.exists(wt));
}

test "repo remove --clone: a symlink holt did not make refuses without --force; --force records its target and deletes" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.ignore("/result");
    try f.ignore("/cache/");
    try kept.content.createLink("/nix/store/abc", try f.path("result"), .file);
    try f.write(f.clone, "cache/a.txt", "a");
    try fsutil.ensureDir(try f.path("cache/sub"));
    try kept.content.createLink("../a.txt", try f.path("cache/sub/link"), .file);

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, "link recorded "));
    try testing.expect(contains(forced.out, " -> /nix/store/abc"));
    try testing.expect(contains(forced.out, " -> ../a.txt"));
    try testing.expect(!fsutil.exists(f.clone));

    var targets: std.ArrayList([]const u8) = .empty;
    var d = try std.Io.Dir.cwd().openDir(io(), try f.kctx.layout.asideDir(a), .{ .iterate = true });
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        const m = (try kept.aside.readManifest(a, f.kctx.layout, e.name)) orelse continue;
        for (m.links) |l| try targets.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ l.path, l.target }));
    }
    try testing.expect(kept.paths.contains(targets.items, "result /nix/store/abc"));
    try testing.expect(kept.paths.contains(targets.items, "cache/sub/link ../a.txt"));
}

test "worktree -r --force: a locked worktree is refused before anything is set aside or unlinked" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try f.write(wt, ".env.kept", "kept secret");
    try f.keep(wt, ".env.kept");
    try f.ignore("/secret.txt");
    try f.write(wt, "secret.txt", "only in the worktree");
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "lock", try fsutil.forwardSlashed(a, wt) });
    const before = try f.snapshot(true);

    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r", "--force" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, " worktree unlock "));
    try testing.expectEqual(kept.content.Entry.symlink, try kept.content.entryAt(try fsutil.joinSlashy(a, wt, ".env.kept")));
    try expectSameButLinkRecords(&f, before, try f.snapshot(true));
}

test "repo remove --clone: an ignored .gitignore an auto pattern matches is not kept automatically, and is named as not kept" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.ignore("/sub/.gitignore");
    try f.write(f.clone, "sub/.gitignore", "*.tmp\n");
    try f.write(try f.kctx.layout.keptDir(a), ".holt-auto.d/1", ".gitignore\n");

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const shown = try fsutil.contractTilde(a, app.envOf_current(), try f.path("sub/.gitignore"));
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "  not kept: {s}\n", .{shown})));
    try testing.expect(!contains(refused.out, "kept automatically"));
    try testing.expectEqual(kept.content.Entry.file, try kept.content.entryAt(try f.path("sub/.gitignore")));
}

test "deleter messages show every place as a line names it, and quote it in each command" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.ignore("/my secret.txt");
    try f.write(f.clone, "my secret.txt", "only here");

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const shown = try fsutil.contractTilde(a, app.envOf_current(), try f.path("my secret.txt"));
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "  not kept: {s}\n", .{shown})));
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "run: holt keep --review {s}\n", .{try q_test(a, f.clone)})));

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, try std.fmt.allocPrint(a, "set aside {s} (kept/.holt-aside/", .{shown})));
}

test "worktree -r: a dirty worktree's refusal names the stash command and the --force command" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try f.write(wt, "README", "a tracked edit");
    const dirty = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 1), dirty.code);
    try testing.expect(contains(dirty.err, " stash push -u"));
    try testing.expect(contains(dirty.err, "holt worktree proj/widget feature -r --force"));
}

test "archive --prune: each kept automatically line is printed once" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try f.ignore("/.clasp.json");
    try f.write(f.clone, ".clasp.json", "{}");

    const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(usize, 1), count(got.out, "kept automatically: "));
    try testing.expect(contains(got.out, "reclaimed widget"));
}

fn setupWithProject(a: std.mem.Allocator, sb: *testutil.Sandbox) !Fixture {
    const f = try Fixture.init(a, sb, true);
    try withProject(&f);
    return f;
}

test "repo remove --clone: a commit only a linked worktree's detached HEAD holds refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try fsutil.removePath(try std.fs.path.join(a, &.{ try f.ws.projectsRoot(a), "acme", "proj", ".holt.json" }));
    try testutil.runGit(&sb, wt, &.{ "checkout", "-q", "--detach" });
    try f.write(wt, "x.txt", "detached work");
    try testutil.runGit(&sb, wt, &.{ "add", "x.txt" });
    try testutil.runGit(&sb, wt, &.{ "commit", "-q", "-m", "detached" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(fsutil.exists(wt));
    try testing.expectEqual(@as(u8, 1), got.code);
}

test "repo remove --clone: a commit only a linked worktree's refs/worktree ref holds refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try fsutil.removePath(try std.fs.path.join(a, &.{ try f.ws.projectsRoot(a), "acme", "proj", ".holt.json" }));
    try testutil.runGit(&sb, wt, &.{ "checkout", "-q", "--detach" });
    try f.write(wt, "x.txt", "wip work");
    try testutil.runGit(&sb, wt, &.{ "add", "x.txt" });
    try testutil.runGit(&sb, wt, &.{ "commit", "-q", "-m", "wip" });
    try testutil.runGit(&sb, wt, &.{ "update-ref", "refs/worktree/wip", "HEAD" });
    try testutil.runGit(&sb, wt, &.{ "checkout", "-q", "feature" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(fsutil.exists(wt));
    try testing.expectEqual(@as(u8, 1), got.code);
}

test "repo remove --clone: a local tag naming a blob no remote holds refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, "key.asc", "only copy of a key");
    const h = try git.runInRepoScoped(a, &.{ "hash-object", "-w", "key.asc" }, f.clone);
    try fsutil.removePath(try f.path("key.asc"));
    try testutil.runGit(&sb, f.clone, &.{ "tag", "-a", "-m", "key", "gpg-key", std.mem.trim(u8, h.stdout, " \r\n") });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(fsutil.exists(f.clone));
    try testing.expectEqual(@as(u8, 1), got.code);
}

test "repo remove --clone: an unpushed annotated tag on a pushed commit refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "tag", "-a", "-m", "release notes written only here", "v1.0", "main" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(fsutil.exists(f.clone));
    try testing.expectEqual(@as(u8, 1), got.code);
}

test "repo remove --clone --force: a link of holt's shape at a path holt does not keep is recorded by its target" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env", "kept");
    try f.keep(f.clone, ".env");
    const target = try f.kctx.layout.copyPath(a, Fixture.key, "mine.cfg");
    try kept.content.createLink(target, try f.path("mine.cfg"), .file);

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(contains(got.out, "mine.cfg"));
}

test "repo remove --clone: a linked working tree of a submodule refuses the delete, even with --force, naming it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const sub = try withSubmodule(&f, false);
    const sub_wt = try std.fs.path.join(a, &.{ sb.root, "sub-wt" });
    try testutil.runGit(&sb, sub, &.{ "worktree", "add", "-q", "-b", "side", sub_wt });
    try f.write(sub_wt, "only.txt", "work only this tree holds");

    for ([_][]const []const u8{ &.{ Fixture.key, "--clone", "--yes" }, &.{ Fixture.key, "--clone", "--force", "--yes" } }) |argv| {
        const got = try f.run(repo_cmd.remove_command.run, argv);
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(contains(got.err, "linked working tree of its submodules"));
        try testing.expect(contains(got.err, try q_test(a, try fsutil.realPathOrSelf(a, sub_wt))));
        try testing.expect(fsutil.exists(f.clone));
    }
}

test "repo remove --clone: a linked working tree of a submodule whose path two records name, as a copied record leaves, is named once with what is seen there and the submodule's git worktree list alone, never a removal, leaving both records as they were; once the user removes the copy, git worktree remove of the one left settles it" {
    try skipWithoutLinks();
    for ([_][]const u8{ "a-copy", "z-copy" }) |copy_id| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const sub = try withSubmodule(&f, false);
        const sub_wt = try std.fs.path.join(a, &.{ sb.root, "sub-wt" });
        try testutil.runGit(&sb, sub, &.{ "worktree", "add", "-q", "--detach", sub_wt });
        const module = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }));
        const records = try std.fs.path.join(a, &.{ module, "worktrees" });
        const own = try std.fs.path.join(a, &.{ records, "sub-wt" });
        const copy = try std.fs.path.join(a, &.{ records, copy_id });
        const cp = try proc.runEnv(a, &.{ "cp", "-R", own, copy }, null, &sb.git_env.map);
        try testing.expectEqual(@as(u8, 0), cp.status);
        const wt = try fsutil.realPathOrSelf(a, sub_wt);
        const wq = try q_test(a, wt);
        const lead = try std.fmt.allocPrint(a, "the delete would leave a linked working tree of its submodules without their repository: {s}; ", .{wq});
        const roots: []const []const u8 = &.{ records, sub_wt };
        const before = try treesState(a, roots);

        for ([_][]const []const u8{ &.{ Fixture.key, "--clone", "--yes" }, &.{ Fixture.key, "--clone", "--force", "--yes" } }) |argv| {
            const refused = try f.run(repo_cmd.remove_command.run, argv);
            try testing.expectEqual(@as(u8, 1), refused.code);
            if (!contains(refused.err, lead)) {
                std.debug.print("{s}: wanted {s} in:\n{s}\n", .{ copy_id, lead, refused.err });
                return error.TestUnexpectedResult;
            }
            try expectUnresolved(&f, refused.err, wt, shared_seen, try std.fmt.allocPrint(a, "git --git-dir {s}", .{try q_test(a, module)}));
            try testing.expectEqualStrings(before, try treesState(a, roots));
            try testing.expect(fsutil.exists(f.clone));
        }

        try std.Io.Dir.cwd().deleteTree(io(), copy);
        const next = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), next.code);
        const one = try std.fmt.allocPrint(a, "without their repository: {s}; remove it first (run: git -C {s} worktree remove {s})", .{ wq, wq, wq });
        if (!contains(next.err, one)) {
            std.debug.print("{s}: wanted {s}\nin:\n{s}\n", .{ copy_id, one, next.err });
            return error.TestUnexpectedResult;
        }
        try runHint(&f, next.err, "without their repository: ", "");
        try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(own));
        try testing.expect(!fsutil.exists(sub_wt));
        const after = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expect(!contains(after.err, "of its submodules"));
        if (after.code != 0) std.debug.print("{s}:\n{s}\n", .{ copy_id, after.err });
        try testing.expectEqual(@as(u8, 0), after.code);
        try testing.expect(!fsutil.exists(f.clone));
    }
}

test "localPath: names a local path as git reads a remote URL, and nothing for another machine's" {
    try testing.expectEqualStrings(".", remote_url.localPath(".").?);
    try testing.expectEqualStrings("/srv/backup.git", remote_url.localPath("file:///srv/backup.git").?);
    try testing.expectEqualStrings("../up.git", remote_url.localPath("../up.git").?);
    try testing.expectEqualStrings("/a:b/c.git", remote_url.localPath("/a:b/c.git").?);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("C:/repos/x.git", remote_url.localPath("C:/repos/x.git").?);
    } else try testing.expect(remote_url.localPath("C:/repos/x.git") == null);
    try testing.expectEqualStrings("/srv/d://e/x.bundle", remote_url.localPath("/srv/d://e/x.bundle").?);
    try testing.expect(remote_url.localPath("git+ssh://host.invalid/x") == null);
    try testing.expect(remote_url.localPath("git@host.invalid:acme/widget") == null);
    try testing.expect(remote_url.localPath("https://host.invalid/acme/widget") == null);
    try testing.expect(remote_url.localPath("ssh://host.invalid/acme/widget") == null);
}

test "repo remove --clone: refs are asked of the remote's push URL alone, whatever its remote-tracking refs say; the hinted pushes reach it, and a push URL that cannot be reached cannot be asked" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    const pushed = try std.fs.path.join(a, &.{ sb.root, "push.git" });
    const unreachable_url = try std.fs.path.join(a, &.{ f.bare, "unreachable.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", pushed });
    try testutil.markElsewhere(pushed);
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", unreachable_url });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "-a", "-m", "v1", "v1" });

    const unasked = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), unasked.code);
    try testing.expect(contains(unasked.err, try std.fmt.allocPrint(a, "1 ref not confirmed held, in {s}: refs/tags/v1 (remote origin could not be asked at {s}: ", .{ cq, unreachable_url })));

    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", pushed });
    const asked = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), asked.code);
    const tag_lead = "the tag only refs/tags/v1 names, no remote has, in ";
    try testing.expect(contains(asked.err, try std.fmt.allocPrint(a, "{s}{s} (run: git -C {s} push --recurse-submodules=no -- origin refs/tags/v1:refs/tags/holt-kept/tags/v1)", .{ tag_lead, cq, cq })));
    try runHint(&f, asked.err, tag_lead, "");

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(f.clone));
}

test "repo remove --clone: a commit only a gone remote's tracking ref holds hints a push to a branch of the surviving remote, which settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    const inner = try std.fs.path.join(a, &.{ f.clone, ".git", "inner.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", inner });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "inner", inner });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "-c", "exp" });
    try f.write(f.clone, "exp.txt", "only on the inner remote");
    try testutil.runGit(&sb, f.clone, &.{ "add", "exp.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "exp" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "inner", "exp" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "branch", "-q", "-D", "exp" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const lead = "commits only 1 ref of remote inner holds, no remote has, in ";
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}{s}: refs/remotes/inner/exp (run: git -C {s} push --recurse-submodules=no -- origin refs/remotes/inner/exp:refs/heads/holt-kept/remotes/inner/exp)", .{ lead, cq, cq })));
    try runHint(&f, refused.err, lead, "");

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(f.clone));
}

/// Runs, as a shell does, the command `text` names after `lead` in
/// `(run: <cmd>)`, `<cmd>` ending at the first `)` that ends the line or
/// comes before `,` or `;`, with `<url>` replaced by `url`; fails when it
/// does.
fn runHint(f: *const Fixture, text: []const u8, lead: []const u8, url: []const u8) !void {
    const at = std.mem.indexOf(u8, text, lead) orelse return error.TestUnexpectedResult;
    const rest = text[at + lead.len ..];
    const open = std.mem.indexOf(u8, rest, "(run: ") orelse return error.TestUnexpectedResult;
    const cmd_start = rest[open + "(run: ".len ..];
    var close: usize = 0;
    while (true) : (close += 1) {
        close = std.mem.indexOfScalarPos(u8, cmd_start, close, ')') orelse return error.TestUnexpectedResult;
        if (close + 1 == cmd_start.len or std.mem.indexOfScalar(u8, "\n,;", cmd_start[close + 1]) != null) break;
        if (std.mem.startsWith(u8, cmd_start[close + 1 ..], " (in ")) break;
    }
    const placeholder = ", with <url> a URL on another machine";
    const bare_cmd = if (std.mem.endsWith(u8, cmd_start[0..close], placeholder)) cmd_start[0 .. close - placeholder.len] else cmd_start[0..close];
    const cmd = try std.mem.replaceOwned(u8, f.a, bare_cmd, "<url>", url);
    const res = try proc.runEnv(f.a, &.{ "sh", "-c", cmd }, null, &f.sb.git_env.map);
    if (res.status != 0) {
        std.debug.print("hint failed: {s}\n{s}\n", .{ cmd, res.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Adds a branch `exp` with one commit only this clone has, leaving
/// `main` checked out.
fn addExp(f: *const Fixture) !void {
    try testutil.runGit(f.sb, f.clone, &.{ "switch", "-q", "-c", "exp" });
    try f.write(f.clone, "exp.txt", "only here");
    try testutil.runGit(f.sb, f.clone, &.{ "add", "exp.txt" });
    try testutil.runGit(f.sb, f.clone, &.{ "commit", "-q", "-m", "exp" });
    try testutil.runGit(f.sb, f.clone, &.{ "switch", "-q", "main" });
}

test "repo remove --clone: a gone remote's tracking ref whose branch the surviving remote has with other commits is pushed to a branch under holt-kept/ and the gone remote's name, which settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "-c", "exp" });
    try f.write(f.clone, "theirs.txt", "on origin's exp");
    try testutil.runGit(&sb, f.clone, &.{ "add", "theirs.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "origin exp" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "exp" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "branch", "-q", "-D", "exp" });
    const inner = try std.fs.path.join(a, &.{ f.clone, ".git", "inner.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", inner });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "inner", inner });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "-c", "other" });
    try f.write(f.clone, "exp.txt", "only on the inner remote");
    try testutil.runGit(&sb, f.clone, &.{ "add", "exp.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "inner exp" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "inner", "other:exp" });
    try testutil.runGit(&sb, f.clone, &.{ "fetch", "-q", "inner" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "branch", "-q", "-D", "other" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const lead = "commits only 1 ref of remote inner holds, no remote has, in ";
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}{s}: refs/remotes/inner/exp (run: git -C {s} push --recurse-submodules=no -- origin refs/remotes/inner/exp:refs/heads/holt-kept/remotes/inner/exp)", .{ lead, cq, cq })));
    try runHint(&f, refused.err, lead, "");

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(f.clone));
}

test "repo remove --clone: a push URL that cannot be asked is named once, with the refs it leaves unconfirmed, and a branch another remote holds is not among them" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    const unreachable_url = try std.fs.path.join(a, &.{ f.bare, "unreachable.git" });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", f.bare });
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", unreachable_url });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "-a", "-m", "v1", "v1" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    try f.write(f.clone, "t.txt", "only the lightweight tag");
    try testutil.runGit(&sb, f.clone, &.{ "add", "t.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "tagged" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "t2" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "  2 refs not confirmed held, in {s}: refs/tags/t2, refs/tags/v1 (remote origin could not be asked at {s}: repository not found); replace this push URL (run: git -C {s} config --local --fixed-value --unset-all remote.origin.pushurl {s} && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine), or --force deletes them\n", .{ cq, unreachable_url, cq, unreachable_url, cq })));
    try testing.expectEqual(@as(usize, 1), count(got.err, "not confirmed held"));
    try testing.expect(!contains(got.err, "refs/heads/main"));
}

test "repo remove --clone: a push URL an insteadOf rule rewrote into one its prefix still matches is asked through its configured value, which git rewrites once to it, and what it lists counts" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    const short = try std.fmt.allocPrint(a, "{s}/", .{sb.root});
    const long = try std.fmt.allocPrint(a, "{s}/real/", .{sb.root});
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", try std.fmt.allocPrint(a, "{s}push.git", .{long}) });
    try testutil.markElsewhere(long);
    try testutil.runGit(&sb, f.clone, &.{ "config", try std.fmt.allocPrint(a, "url.{s}.insteadOf", .{long}), short });
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", try std.fmt.allocPrint(a, "{s}push.git", .{short}) });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "main" });

    _ = cq;
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!contains(got.err, "rewrites it again"));
    try testing.expect(!fsutil.exists(f.clone));
}

test "repo remove --clone and archive --prune: after a backend switch that left kept/ behind, each refuses naming where kept/ is and where to copy it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try @import("../kept_cmd.zig").TestWorld.init(a, &sb, true);
    defer w.deinit();
    for (try w.ws.list(a)) |p| _ = try @import("../hub.zig").reconcile(a, &w.ws, &p, false);
    try w.keep(a, ".clasp.json", "{}\n");
    var moved = w.ws;
    moved.cfg.synced_root = try std.fs.path.join(a, &.{ sb.root, "new-synced" });
    try fsutil.copyTree(a, try std.fs.path.join(a, &.{ w.ws.cfg.synced_root, "projects" }), try std.fs.path.join(a, &.{ moved.cfg.synced_root, "projects" }));
    for (try moved.list(a)) |p| _ = try @import("../hub.zig").reconcile(a, &moved, &p, false);
    const env = app.envOf_current();
    const line = try std.fmt.allocPrint(a, "kept/ is at {s}: copy it to {s}", .{ try ui.quotePath(a, env, w.ws.cfg.synced_root), try ui.quotePath(a, env, moved.cfg.synced_root) });

    const removed = try testutil.runCmd(a, repo_cmd.remove_command.run, moved, &.{ "widget", "-p", "acme/proj", "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), removed.code);
    try testing.expect(contains(removed.err, try std.fmt.allocPrint(a, ": {s}; refusing to delete", .{line})));
    try testing.expect(!contains(removed.err, "cannot be reached"));

    const archived = try testutil.runCmd(a, project_cmd.archive_command.run, moved, &.{ "proj", "--prune", "--yes" });
    try testing.expect(contains(archived.out, try std.fmt.allocPrint(a, "not pruned widget: {s}; once settled, delete it with: holt repo remove {s} --clone\n", .{ line, w.key })));
    try testing.expect(fsutil.exists(w.clone));
}

test "repo remove --clone: a branch another clone force-pushed over, whose remote-tracking ref is stale, refuses the delete, and the hinted push to holt-kept/ settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try addExp(&f);
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "-u", "origin", "exp" });
    const other = try std.fs.path.join(a, &.{ sb.root, "other" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", f.bare, other });
    try testutil.runGit(&sb, other, &.{ "commit", "-q", "--allow-empty", "-m", "rewritten elsewhere" });
    try testutil.runGit(&sb, other, &.{ "push", "-q", "-f", "origin", "HEAD:exp" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const lead = "commits of branch exp no remote has, in ";
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}{s} (run: git -C {s} push --recurse-submodules=no -- origin refs/heads/exp:refs/heads/holt-kept/exp)", .{ lead, cq, cq })));
    try testing.expect(contains(refused.err, "commits only 1 ref of remote origin holds, no remote has, in "));
    try runHint(&f, refused.err, lead, "");

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(f.clone));
}

/// Adds the remote `inner` inside the clone's `.git`, whose branch `exp`
/// holds a commit only it has, fetched as `refs/remotes/inner/exp`.
fn addInnerExp(f: *const Fixture) !void {
    const inner = try std.fs.path.join(f.a, &.{ f.clone, ".git", "inner.git" });
    try testutil.runGit(f.sb, null, &.{ "init", "-q", "--bare", inner });
    try testutil.runGit(f.sb, f.clone, &.{ "remote", "add", "inner", inner });
    try testutil.runGit(f.sb, f.clone, &.{ "switch", "-q", "-c", "other" });
    try f.write(f.clone, "exp.txt", "only on the inner remote");
    try testutil.runGit(f.sb, f.clone, &.{ "add", "exp.txt" });
    try testutil.runGit(f.sb, f.clone, &.{ "commit", "-q", "-m", "inner exp" });
    try testutil.runGit(f.sb, f.clone, &.{ "push", "-q", "inner", "other:exp" });
    try testutil.runGit(f.sb, f.clone, &.{ "fetch", "-q", "inner" });
    try testutil.runGit(f.sb, f.clone, &.{ "switch", "-q", "main" });
    try testutil.runGit(f.sb, f.clone, &.{ "branch", "-q", "-D", "other" });
}

/// Pushes, from a clone of its own, a branch `exp` with a commit this clone
/// lacks to the fixture's origin, which this clone never fetches.
fn pushOtherExp(f: *const Fixture) !void {
    const other = try std.fs.path.join(f.a, &.{ f.sb.root, "other" });
    try testutil.runGit(f.sb, null, &.{ "clone", "-q", f.bare, other });
    try testutil.runGit(f.sb, other, &.{ "commit", "-q", "--allow-empty", "-m", "origin's own exp" });
    try testutil.runGit(f.sb, other, &.{ "push", "-q", "origin", "HEAD:exp" });
}

test "repo remove --clone: a gone remote's tracking ref is hinted to a branch git takes when the surviving remote holds a branch named for the gone remote, or its own branch this clone never fetched" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |df| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
        try pushOtherExp(&f);
        if (df) {
            try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "main:inner" });
            try testutil.runGit(&sb, f.clone, &.{ "fetch", "-q", "origin" });
        }
        try addInnerExp(&f);

        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        const lead = "commits only 1 ref of remote inner holds, no remote has, in ";
        try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}{s}: refs/remotes/inner/exp (run: git -C {s} push --recurse-submodules=no -- origin refs/remotes/inner/exp:refs/heads/holt-kept/remotes/inner/exp)", .{ lead, cq, cq })));
        try runHint(&f, refused.err, lead, "");

        const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 0), got.code);
    }
}

test "repo remove --clone: when the surviving remote has a branch holt-kept itself, a gone remote's tracking ref is hinted to holt-kept-2/, which git takes" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try pushOtherExp(&f);
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "main:holt-kept" });
    try addInnerExp(&f);

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const lead = "commits only 1 ref of remote inner holds, no remote has, in ";
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}{s}: refs/remotes/inner/exp (run: git -C {s} push --recurse-submodules=no -- origin refs/remotes/inner/exp:refs/heads/holt-kept-2/remotes/inner/exp)", .{ lead, cq, cq })));
    try runHint(&f, refused.err, lead, "");

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
}

test "repo remove --clone: refs are asked of the push URL pushInsteadOf rewrites to, where the push goes, not of the configured URL" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    const pushed = try std.fs.path.join(a, &.{ sb.root, "push.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", pushed });
    try testutil.markElsewhere(pushed);
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    try f.write(f.clone, "t.txt", "only the tag");
    try testutil.runGit(&sb, f.clone, &.{ "add", "t.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "tagged" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "t1" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "config", try std.fmt.allocPrint(a, "url.{s}.pushInsteadOf", .{pushed}), f.bare });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const tag_lead = "commits only refs/tags/t1 holds, no remote has, in ";
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}{s} (run: git -C {s} push --recurse-submodules=no -- origin refs/tags/t1:refs/tags/holt-kept/tags/t1)", .{ tag_lead, cq, cq })));
    try runHint(&f, refused.err, tag_lead, "");

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
}

test "repo remove --clone: a pushurl list git resets with an empty value is not asked, and a tag only the repository it named holds refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const inner = try std.fs.path.join(a, &.{ f.clone, ".git", "backup.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", inner });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    try f.write(f.clone, "t.txt", "only the tag and the inner repo");
    try testutil.runGit(&sb, f.clone, &.{ "add", "t.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "tagged" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "t2" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", inner, "refs/tags/t2" });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", inner });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", "" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "refs/tags/t2"));
    try testing.expect(fsutil.exists(f.clone));
}

test "repo remove --clone: origin with no URL is said to have none, and the hinted config, which git accepts, settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try testutil.runGit(&sb, f.clone, &.{ "config", "--unset", "remote.origin.url" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "; no remote counts as a copy: remote origin has no URL; set a URL (run: git -C {s} config --local remote.origin.url <url>, with <url> a URL on another machine), or ", .{cq})));
    try settleWith(&f, &.{"no remote counts as a copy"}, f.bare, 3);
}

test "repo remove --clone: origin git lists but cannot read, defined only outside the clone, is hinted away from where it is defined, and each next hint settles the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try testutil.runGit(&sb, f.clone, &.{ "remote", "remove", "origin" });
    const global = try std.fs.path.join(a, &.{ sb.root, "global.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = global, .data = try std.fmt.allocPrint(a, "[remote \"origin\"]\n\turl = {s}\n", .{f.bare}) });
    const env = try testutil.EnvOverride.install(a, "GIT_CONFIG_GLOBAL", global);
    defer env.restore();

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "; no remote counts as a copy: git cannot read the URLs of remote origin; add a remote on another machine (run: git -C {s} remote add holt-kept <url>, with <url> a URL on another machine), or ", .{cq})));
    try settleWith(&f, &.{"no remote counts as a copy"}, f.bare, 3);
}

test "repo remove --clone: a graft in the clone that makes a listed commit a child of one only the clone holds does not make it held" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    try f.write(f.clone, "t.txt", "only the tag");
    try testutil.runGit(&sb, f.clone, &.{ "add", "t.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "tagged" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "t" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    const tip = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "main" }, f.clone)).stdout, "\n");
    const tagged = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "t" }, f.clone)).stdout, "\n");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ f.clone, ".git", "info", "grafts" }), .data = try std.fmt.allocPrint(a, "{s} {s}\n", .{ tip, tagged }) });
    try f.write(f.clone, "holt-no-grafts/none", try std.fmt.allocPrint(a, "{s} {s}\n", .{ tip, tagged }));

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "commits only refs/tags/t holds, no remote has, in "));
}

test "destination: a branch keeps its name only beside a HEAD line naming another branch, a tag never does, and a free name is found ignoring case" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const at: At = .{ .repo = "." };
    const head = Listed{ .ref = "HEAD", .object = "", .symref = "refs/heads/main" };
    const main = Listed{ .ref = "refs/heads/main", .object = "1111111111111111111111111111111111111111" };
    const cased = Listed{ .ref = "refs/heads/Holt-Kept/main", .object = "1111111111111111111111111111111111111111" };
    const kept_ref = Listed{ .ref = "refs/heads/holt-kept", .object = "1111111111111111111111111111111111111111" };
    const with_head: []const []const Listed = &.{&.{ head, main }};
    const no_head: []const []const Listed = &.{&.{main}};
    try testing.expectEqualStrings("refs/heads/feature", try destination(a, at, with_head, "refs/heads/feature", null));
    try testing.expectEqualStrings("refs/heads/holt-kept/feature", try destination(a, at, no_head, "refs/heads/feature", null));
    try testing.expectEqualStrings("refs/heads/holt-kept/main", try destination(a, at, with_head, "refs/heads/main", null));
    try testing.expectEqualStrings("refs/heads/holt-kept/main-2", try destination(a, at, &.{&.{ head, main, cased }}, "refs/heads/main", null));
    try testing.expectEqualStrings("refs/heads/holt-kept-2/main", try destination(a, at, &.{&.{ head, main, kept_ref }}, "refs/heads/main", null));
    try testing.expectEqualStrings("refs/tags/holt-kept/tags/v1", try destination(a, at, with_head, "refs/tags/v1", "1111111111111111111111111111111111111111"));
    try testing.expectEqualStrings("refs/heads/holt-kept/notes/commits", try destination(a, at, with_head, "refs/notes/commits", "1111111111111111111111111111111111111111"));
    try testing.expectEqualStrings("refs/tags/holt-kept/keys/blob", try destination(a, at, with_head, "refs/keys/blob", null));
}

test "repo remove --clone: a branch that shares its name with a tag is hinted by its full ref, which git takes" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try addExp(&f);
    try testutil.runGit(&sb, f.clone, &.{ "tag", "exp", "main" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const lead = "branch exp no remote has, in ";
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}{s} (run: git -C {s} push --recurse-submodules=no -- origin refs/heads/exp:refs/heads/exp)", .{ lead, cq, cq })));
    try runHint(&f, refused.err, lead, "");

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
}

/// A remote on this machine the local-remote test sets origin to: `make`
/// builds it holding every commit of the clone and points origin's push URL
/// at it, returning the URL `git remote get-url --push` prints.
const LocalRemote = struct { what: []const u8, push_only: bool = false, make: *const fn (f: *const Fixture) anyerror![]const u8 };

/// How a line about a remote on this machine ends.
const local_force = "--force";

fn setOrigin(f: *const Fixture, url: []const u8) ![]const u8 {
    try testutil.runGit(f.sb, f.clone, &.{ "remote", "set-url", "origin", url });
    return url;
}

fn bareCopy(f: *const Fixture, name: []const u8, extra: []const []const u8) ![]const u8 {
    const path = try std.fs.path.join(f.a, &.{ f.sb.root, name });
    try testutil.runGit(f.sb, null, try std.mem.concat(f.a, []const u8, &.{ &.{ "clone", "-q", "--bare" }, extra, &.{ try std.mem.concat(f.a, u8, &.{ "file://", f.clone }), path } }));
    return path;
}

const local_remotes = [_]LocalRemote{
    .{ .what = "a repository beside the clone", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            return setOrigin(f, try bareCopy(f, "copy.git", &.{}));
        }
    }.make },
    .{ .what = "a file:// URL", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            return setOrigin(f, try std.mem.concat(f.a, u8, &.{ "file://", try bareCopy(f, "copy.git", &.{}) }));
        }
    }.make },
    .{ .what = "a path relative to the clone", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            _ = try bareCopy(f, "rel.git", &.{});
            return setOrigin(f, "../../../../rel.git");
        }
    }.make },
    .{ .what = "a URL without the .git git adds", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            _ = try bareCopy(f, "copy.git", &.{});
            return setOrigin(f, try std.fs.path.join(f.a, &.{ f.sb.root, "copy" }));
        }
    }.make },
    .{ .what = "a repository inside the clone's .git", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            const inner = try std.fs.path.join(f.a, &.{ f.clone, ".git", "backup.git" });
            try testutil.runGit(f.sb, null, &.{ "init", "-q", "--bare", inner });
            try testutil.runGit(f.sb, f.clone, &.{ "push", "-q", inner, "main" });
            return setOrigin(f, inner);
        }
    }.make },
    .{ .what = "the clone itself, %-escaped", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            const last = f.clone[f.clone.len - 1];
            return setOrigin(f, try std.fmt.allocPrint(f.a, "file://{s}%{X:0>2}", .{ f.clone[0 .. f.clone.len - 1], last }));
        }
    }.make },
    .{ .what = "a repository borrowing its objects from the clone", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            return setOrigin(f, try bareCopy(f, "shared.git", &.{"--shared"}));
        }
    }.make },
    .{ .what = "a repository whose objects directory is a link into the clone", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            const mirror = try std.fs.path.join(f.a, &.{ f.sb.root, "linked.git" });
            try testutil.runGit(f.sb, null, &.{ "init", "-q", "--bare", mirror });
            const objects = try std.fs.path.join(f.a, &.{ mirror, "objects" });
            try std.Io.Dir.cwd().deleteTree(io(), objects);
            try std.Io.Dir.cwd().symLink(io(), try std.fs.path.join(f.a, &.{ f.clone, ".git", "objects" }), objects, .{ .is_directory = true });
            try testutil.runGit(f.sb, f.clone, &.{ "push", "-q", mirror, "main" });
            return setOrigin(f, mirror);
        }
    }.make },
    .{ .what = "a repository whose objects/pack is a link into the clone", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            try testutil.runGit(f.sb, f.clone, &.{ "repack", "-q", "-a", "-d" });
            const rem = try std.fs.path.join(f.a, &.{ f.sb.root, "pack.git" });
            try testutil.runGit(f.sb, null, &.{ "init", "-q", "--bare", rem });
            const pack = try std.fs.path.join(f.a, &.{ rem, "objects", "pack" });
            try std.Io.Dir.cwd().deleteTree(io(), pack);
            try std.Io.Dir.cwd().symLink(io(), try std.fs.path.join(f.a, &.{ f.clone, ".git", "objects", "pack" }), pack, .{ .is_directory = true });
            const head = std.mem.trim(u8, (try git.runInRepoScoped(f.a, &.{ "rev-parse", "HEAD" }, f.clone)).stdout, "\n");
            try testutil.runGit(f.sb, rem, &.{ "update-ref", "refs/heads/main", head });
            return setOrigin(f, rem);
        }
    }.make },
    .{ .what = "a repository whose alternates file names a path through a symlink loop", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            const mirror = try bareCopy(f, "alt.git", &.{});
            const loop = try std.fs.path.join(f.a, &.{ f.sb.root, "loop" });
            try std.Io.Dir.cwd().symLink(io(), loop, loop, .{});
            try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(f.a, &.{ mirror, "objects", "info", "alternates" }), .data = try std.fmt.allocPrint(f.a, "{s}/objects\n", .{loop}) });
            return setOrigin(f, mirror);
        }
    }.make },
    .{ .what = "a bundle beside a repository of the name git adds .git to", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            const bundle = try std.fs.path.join(f.a, &.{ f.sb.root, "rem" });
            try testutil.runGit(f.sb, f.clone, &.{ "bundle", "create", "-q", bundle, "main" });
            try testutil.runGit(f.sb, null, &.{ "init", "-q", "--bare", try std.mem.concat(f.a, u8, &.{ bundle, ".git" }) });
            return setOrigin(f, bundle);
        }
    }.make },
    .{ .what = "a shallow clone", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            return setOrigin(f, try bareCopy(f, "shallow.git", &.{"--depth=1"}));
        }
    }.make },
    .{ .what = "a partial clone", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            return setOrigin(f, try bareCopy(f, "partial.git", &.{"--filter=blob:none"}));
        }
    }.make },
    .{ .what = "a path that cannot be resolved", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            const loop = try std.fs.path.join(f.a, &.{ f.sb.root, "loop" });
            try std.Io.Dir.cwd().symLink(io(), loop, loop, .{});
            return setOrigin(f, try std.fs.path.join(f.a, &.{ loop, "x.git" }));
        }
    }.make },
    .{ .what = "a path an insteadOf rule rewrites to", .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            const copy = try bareCopy(f, "copy.git", &.{});
            try testutil.runGit(f.sb, f.clone, &.{ "config", try std.mem.concat(f.a, u8, &.{ "url.", copy, ".insteadOf" }), "backup:" });
            _ = try setOrigin(f, "backup:");
            return copy;
        }
    }.make },
    .{ .what = "a push URL a file the clone's config includes holds", .push_only = true, .make = struct {
        fn make(f: *const Fixture) ![]const u8 {
            const copy = try bareCopy(f, "copy.git", &.{});
            const inc = try std.fs.path.join(f.a, &.{ f.sb.root, "inc.gitconfig" });
            try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = inc, .data = try std.fmt.allocPrint(f.a, "[remote \"origin\"]\n\tpushurl = {s}\n", .{copy}) });
            try testutil.runGit(f.sb, f.clone, &.{ "config", "include.path", inc });
            return copy;
        }
    }.make },
};

test "repo remove --clone: a remote on this machine never counts as a copy, whatever repository is there: the delete refuses, naming it once" {
    try skipWithoutLinks();
    for (local_remotes) |lr| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
        const url = try lr.make(&f);

        const got = f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" }) catch |err| {
            std.debug.print("{s}: the delete failed with {s}\n", .{ lr.what, @errorName(err) });
            return err;
        };
        if (lr.push_only) {
            try testing.expectEqual(@as(u8, 0), got.code);
            continue;
        }
        const branch = try std.fmt.allocPrint(a, " no remote on another machine holds, in {s}: refs/heads/main", .{cq});
        const remote = try std.fmt.allocPrint(a, "; no remote counts as a copy: remote origin is on this machine ({s}); add a remote on another machine (run: git -C {s} remote add holt-kept <url>, with <url> a URL on another machine), or {s} deletes ", .{ try shownUrl(a, url), cq, local_force });
        if (got.code != 1 or !contains(got.err, branch) or count(got.err, remote) != 1) {
            std.debug.print("{s}: code {d}, stderr:\n{s}\nwanted:\n{s}{s}\n", .{ lr.what, got.code, got.err, branch, remote });
            return error.TestUnexpectedResult;
        }
        try testing.expect(fsutil.exists(f.clone));
    }
}

test "repo remove --clone --force: with origin on this machine, deletes what only the clone holds, naming it, and not the remote" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    const copy = try bareCopy(&f, "copy.git", &.{});
    try addExp(&f);
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", copy, "exp" });
    _ = try setOrigin(&f, copy);

    const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(contains(forced.out, try std.fmt.allocPrint(a, "deleting 3 refs no remote on another machine holds, in {s}: refs/heads/exp", .{cq})));
    try testing.expect(!contains(forced.out, "on this machine"));
    try testing.expect(!fsutil.exists(f.clone));
}

test "repo remove --clone: a remote whose push also goes to a URL on this machine is no push target, and once that URL is gone the hinted push settles what only the local one held" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    const inner = try std.fs.path.join(a, &.{ f.clone, ".git", "backup.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", inner });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", inner });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", f.bare });
    try f.write(f.clone, "work.txt", "pushed to the local URL only");
    try testutil.runGit(&sb, f.clone, &.{ "add", "work.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "work" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", inner, "main" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, "; no remote counts as a copy: remote origin has push destinations holt cannot verify; add a remote on another machine (run: "));
    try testing.expect(!contains(refused.err, " push origin"));
    try testutil.runGit(&sb, f.clone, &.{ "config", "--fixed-value", "--unset", "remote.origin.pushurl", inner });
    const pushable = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), pushable.code);
    const lead = "commits of branch main no remote has, in ";
    try testing.expect(contains(pushable.err, try std.fmt.allocPrint(a, "{s}{s} (run: git -C {s} push --recurse-submodules=no -- origin refs/heads/main:refs/heads/holt-kept/main)\n", .{ lead, cq, cq })));
    try runHint(&f, pushable.err, lead, "");

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(f.clone));
}

test "repo remove --clone: a remote is asked with no terminal prompt and, unless the user names an ssh command, an ssh that never prompts, never shares its connection as a master, and gives up connecting after 10 seconds; a failure refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const bin = try std.fs.path.join(a, &.{ sb.root, "bin" });
    try fsutil.ensureDir(bin);
    const log = try std.fs.path.join(a, &.{ sb.root, "ssh.log" });
    for ([_][]const u8{ "ssh", "myssh" }) |name| {
        const script = try std.fmt.allocPrint(a, "#!/bin/sh\n{{ printf '{s}:'; for x in \"$@\"; do printf ' %s' \"$x\"; done; printf ' prompt=%s\\n' \"$GIT_TERMINAL_PROMPT\"; }} >> '{s}'\nexit 255\n", .{ name, log });
        const path = try std.fs.path.join(a, &.{ bin, name });
        try testutil.writeExecutable(path, script);
    }
    const old_path = std.process.Environ.getPosix(std.Io.Threaded.global_single_threaded.environ.process_environ, "PATH") orelse "/usr/bin:/bin";
    const path_env = try testutil.EnvOverride.install(a, "PATH", try std.mem.concat(a, u8, &.{ bin, ":", old_path }));
    defer path_env.restore();
    const elsewhere = try Elsewhere.ports(a, &.{22});
    defer elsewhere.restore();
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", "ssh://127.0.0.1/acme/widget.git" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "could not be asked at ssh://127.0.0.1/acme/widget.git"));
    try testing.expect(fsutil.exists(f.clone));
    const batch = try kept.content.readSmall(a, log);
    try testing.expect(contains(batch, "ssh: -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=no "));
    try testing.expect(contains(batch, " prompt=0\n"));

    for ([_]bool{ false, true }) |in_env| {
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = log, .data = "" });
        const mine = try std.fs.path.join(a, &.{ bin, "myssh" });
        const env = if (in_env) try testutil.EnvOverride.install(a, "GIT_SSH_COMMAND", mine) else null;
        defer if (env) |e| e.restore();
        if (!in_env) try testutil.runGit(&sb, f.clone, &.{ "config", "core.sshCommand", mine });
        defer if (!in_env) testutil.runGit(&sb, f.clone, &.{ "config", "--unset", "core.sshCommand" }) catch {};

        const own = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), own.code);
        const used = try kept.content.readSmall(a, log);
        try testing.expect(std.mem.startsWith(u8, used, "myssh: "));
        try testing.expect(!contains(used, "BatchMode"));
    }
}

test "repo remove --clone: on a terminal, each URL asked is named on stderr first, once, however many remotes name it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "mirror", f.bare });

    ui.stderr_terminal_for_test = true;
    defer ui.stderr_terminal_for_test = null;
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(usize, 1), count(got.err, "asking "));
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "asking mirror at {s}...\n", .{f.bare})) or contains(got.err, try std.fmt.allocPrint(a, "asking origin at {s}...\n", .{f.bare})));
}

test "doctor --retire: a URL several clones share is asked once for each clone, and no asking line is printed, on a terminal too" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const second = try fsutil.joinSlashy(a, f.ws.cfg.code_root, "holt-test.invalid/acme/gadget");
    try testutil.runGit(&sb, null, &.{ "clone", "-q", f.bare, second });

    const quiet = try f.run(@import("doctor.zig").command.run, &.{"--retire"});
    try testing.expect(!contains(quiet.err, "asking "));
    ui.stderr_terminal_for_test = true;
    defer ui.stderr_terminal_for_test = null;
    const got = try f.run(@import("doctor.zig").command.run, &.{"--retire"});
    try testing.expect(!contains(got.err, "asking "));
}

test "repo remove --clone: a remote whose server accepts and never answers is given up at the limit and refuses the delete as not asked" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io(), .{ .reuse_address = true });
    defer server.deinit(io());
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{server.socket.address.getPort()});
    const elsewhere = try Elsewhere.ports(a, &.{server.socket.address.getPort()});
    defer elsewhere.restore();
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", url });
    ask_limit_for_test = 2;
    defer ask_limit_for_test = null;

    const started = std.Io.Clock.awake.now(testing.io);
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 20 * std.time.ns_per_s);
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "(remote origin could not be asked at {s}: no answer in 2 seconds)", .{url})));
    try testing.expect(fsutil.exists(f.clone));
}

test "gitRisks: under test, a remote on another host than this one is never asked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try testutil.runGit(&sb, work, &.{ "remote", "set-url", "origin", "https://holt-test.invalid/acme/widget" });
    try testing.expectError(error.NetworkInTest, gitRisks(try testAsker(a), work));
    try testing.expect(onThisHost("http://127.0.0.1:9/x") and onThisHost("ssh://git@localhost/x") and onThisHost("/srv/x.git"));
    try testing.expect(!onThisHost("git@holt-test.invalid:acme/widget") and !onThisHost("https://holt-test.invalid/x"));
    try testing.expect(!onThisHost("ssh://holt-test.invalid/x@localhost/y") and !onThisHost("holt-test.invalid:x@localhost/y"));
}

test "gitRisks: under test, a URL whose authority names another host is never asked, whatever its path holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try failingSsh(a, &sb, work);
    try testutil.runGit(&sb, work, &.{ "remote", "set-url", "origin", "ssh://holt-test.invalid/x@localhost/y" });
    for (try gitRisks(try testAsker(a), work)) |r| if (r.what == .no_target) for (r.gone) |gone| try testing.expect(gone.why == .ambiguous);
}

test "gitRisks: on POSIX, a drive-letter URL is an scp-like host, asked as one, never read as a local path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try failingSsh(a, &sb, work);
    try testutil.runGit(&sb, work, &.{ "remote", "set-url", "origin", "C:/acme/widget.git" });
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    try testing.expectError(error.NetworkInTest, gitRisks(try testAsker(a), work));
    try testing.expect(remote_url.localPath("C:/acme/widget.git") == null);
}

test "gitRisks: a push URL git reads as a local path never counts, even with :// inside its path" {
    // Windows cannot name a directory `d:`, which the path needs.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "--allow-empty", "-m", "only here and in the bundle" });
    const dir = try std.fs.path.join(a, &.{ sb.root, "d:", "e" });
    try fsutil.ensureDir(dir);
    try testutil.runGit(&sb, work, &.{ "bundle", "create", "-q", try std.fs.path.join(a, &.{ dir, "x.bundle" }), "--all" });
    try testutil.runGit(&sb, work, &.{ "remote", "set-url", "--push", "origin", try std.fmt.allocPrint(a, "{s}/d://e/x.bundle", .{sb.root}) });
    const risks = try gitRisks(try testAsker(a), work);
    try testing.expect(risks.len > 0);
}

/// Makes `core.sshCommand` of `work` a command that connects nowhere and
/// fails, so a test that reached ssh never reaches the network.
fn failingSsh(a: std.mem.Allocator, sb: *testutil.Sandbox, work: []const u8) !void {
    const script = try std.fs.path.join(a, &.{ sb.root, "failing-ssh" });
    try testutil.writeExecutable(script, "#!/bin/sh\nexit 255\n");
    try testutil.runGit(sb, work, &.{ "config", "core.sshCommand", script });
}

test "repo remove --clone: each push URL that cannot be asked is one line, naming why, how many refs it leaves unconfirmed and the first few, and each hinted command settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    for ([_][]const u8{ "t1", "t2", "t3", "t4", "t5", "t6" }) |t| try testutil.runGit(&sb, f.clone, &.{ "tag", t });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "--tags" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    const offline = [_][]const u8{ try std.fs.path.join(a, &.{ f.bare, "offline-1.git" }), try std.fs.path.join(a, &.{ f.bare, "offline-2.git" }) };
    for (offline) |u| try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", u });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expectEqual(@as(usize, 2), count(refused.err, "not confirmed held"));
    try testing.expect(!contains(refused.err, " only "));
    for (offline) |u| {
        const lead = try std.fmt.allocPrint(a, "  1 ref not confirmed held, in {s}: refs/heads/main (remote origin could not be asked at {s}: repository not found); ", .{ cq, u });
        try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}replace this push URL (run: git -C {s} config --local --fixed-value --unset-all remote.origin.pushurl {s} && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine), or --force deletes it\n", .{ lead, cq, u, cq })));
    }
    try settleWith(&f, &.{ "(remote origin could not be asked at ", "commits of branch main" }, f.bare, 5);
}

test "repo remove --clone: a replace ref that makes a tag stand for a pushed commit does not make the commit only the tag holds count as held" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    try f.write(f.clone, "t.txt", "only here");
    try testutil.runGit(&sb, f.clone, &.{ "add", "t.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "only here" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "-a", "-m", "t", "t" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    const tag = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "t" }, f.clone)).stdout, "\n");
    try testutil.runGit(&sb, f.clone, &.{ "replace", "-f", tag, "main" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "the tag only refs/tags/t names, no remote has, in "));
    try testing.expect(fsutil.exists(f.clone));
}

test "heldCommits: a commit counts as held only when git confirms it is a commit here, never because git leaves its name out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const head = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "HEAD" }, work)).stdout, "\n");
    const tree = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "HEAD^{tree}" }, work)).stdout, "\n");
    const missing = "0123456789abcdef0123456789abcdef01234567";
    var h: Holdings = .{};
    try h.listed.put(a, "fedcba9876543210fedcba9876543210fedcba98", {});
    h.tips = &.{ "fedcba9876543210fedcba9876543210fedcba98", head };
    const held = try heldCommits(a, .{ .repo = work }, &h, &.{ head, missing, tree });
    try testing.expect(held.contains(head));
    try testing.expect(!held.contains(missing));
    try testing.expect(!held.contains(tree));
}

test "repo remove --clone: a push URL that cannot be asked, listed twice in a file outside the clone, is named once and hinted away there every time it is listed, which settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const offline = try std.fs.path.join(a, &.{ f.bare, "offline.git" });
    const inc = try std.fs.path.join(a, &.{ sb.root, "inc.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = inc, .data = try std.fmt.allocPrint(a, "[remote \"origin\"]\n\tpushurl = {s}\n\tpushurl = {s}\n", .{ offline, offline }) });
    try testutil.runGit(&sb, f.clone, &.{ "config", "include.path", inc });

    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expectEqual(@as(usize, 1), count(refused.err, "not confirmed held"));
    const lead = try std.fmt.allocPrint(a, "(remote origin could not be asked at {s}: ", .{offline});
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "(run: git config --file {s} --fixed-value --unset-all remote.origin.pushurl {s} && git -C ", .{ try q_test(a, try fsutil.realPathOrSelf(a, inc)), offline })));
    try settleWith(&f, &.{ lead, "commits of branch main" }, f.bare, 4);
}

test "riskLine: with no push target, a remote whose key holds an empty value is hinted to remove it where it is set, and one with no value at all to set a URL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = null, .out = &out.writer, .err = &out.writer, .argv = &.{} };
    const repo = "/srv/code/widget";
    const empty: GoneRemote = .{ .name = "origin", .why = .no_url, .empties = &.{.{ "remote.origin.pushurl", "" }}, .empty_values = &.{.{ .value = "", .file = "/etc/gitconfig", .system = true }} };
    const risk: Risk = .{ .what = .no_target, .refs = &.{"refs/heads/main"}, .gone = &.{empty} };
    try testing.expectEqualStrings("1 ref no remote on another machine holds, in /srv/code/widget: refs/heads/main; no remote counts as a copy: remote origin has no URL; remove the empty URL (run: git config --file /etc/gitconfig --unset-all remote.origin.pushurl '^$' && git -C /srv/code/widget config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine) (in /etc/gitconfig, which changes every repository and may need an administrator to change, sudo), or --force deletes it", try riskLine(&ctx, .{ .repo = repo, .risk = risk }, "--force"));
    const none: Risk = .{ .what = .no_target, .refs = &.{ "refs/heads/main", "HEAD" }, .gone = &.{.{ .name = "origin", .why = .no_url }} };
    try testing.expectEqualStrings("2 refs no remote on another machine holds, in /srv/code/widget: refs/heads/main, HEAD; no remote counts as a copy: remote origin has no URL; set a URL (run: git -C /srv/code/widget config --local remote.origin.url <url>, with <url> a URL on another machine), or --force deletes them", try riskLine(&ctx, .{ .repo = repo, .risk = none }, "--force"));
}

test "repo remove --clone: origin git cannot read, defined in several files outside the clone, is hinted away from each, naming the system configuration's need for an administrator, and the hint settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try testutil.runGit(&sb, f.clone, &.{ "remote", "remove", "origin" });
    const global = try std.fs.path.join(a, &.{ sb.root, "global.gitconfig" });
    const system = try std.fs.path.join(a, &.{ sb.root, "system.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = global, .data = try std.fmt.allocPrint(a, "[remote \"origin\"]\n\turl = {s}\n", .{f.bare}) });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = system, .data = "[remote \"origin\"]\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" });
    const env = try testutil.EnvOverride.install(a, "GIT_CONFIG_GLOBAL", global);
    defer env.restore();
    const nosystem = try testutil.EnvOverride.install(a, "GIT_CONFIG_NOSYSTEM", null);
    defer nosystem.restore();
    const sys = try testutil.EnvOverride.install(a, "GIT_CONFIG_SYSTEM", system);
    defer sys.restore();

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "; no remote counts as a copy: git cannot read the URLs of remote origin; add a remote on another machine (run: git -C {s} remote add holt-kept <url>, with <url> a URL on another machine), or ", .{cq})));
    try settleWith(&f, &.{"no remote counts as a copy"}, f.bare, 3);
}

test "repo remove --clone: a push URL that cannot be asked, set in the system configuration, is named with the need for an administrator, and the hint settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const offline = try std.fs.path.join(a, &.{ f.bare, "offline.git" });
    const system = try std.fs.path.join(a, &.{ sb.root, "system.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = system, .data = try std.fmt.allocPrint(a, "[remote \"origin\"]\n\tpushurl = {s}\n", .{offline}) });
    const nosystem = try testutil.EnvOverride.install(a, "GIT_CONFIG_NOSYSTEM", null);
    defer nosystem.restore();
    const sys = try testutil.EnvOverride.install(a, "GIT_CONFIG_SYSTEM", system);
    defer sys.restore();

    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const env_now = app.envOf_current();
    const lead = try std.fmt.allocPrint(a, "(remote origin could not be asked at {s}: repository not found); ", .{offline});
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}replace this push URL (run: git config --file {s} --fixed-value --unset-all remote.origin.pushurl {s} && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine) (in {s}, which changes every repository and may need an administrator to change, sudo), or --force deletes it\n", .{ lead, try ui.quotePath(a, env_now, system), offline, try q_test(a, f.clone), try fsutil.contractTilde(a, env_now, system) })));
    try settleWith(&f, &.{ lead, "commits of branch main" }, f.bare, 4);
}

test "repo remove --clone: clear weighs the remotes again after the prompt, with the run's state shared as a command run shares it, so a branch deleted on the remote meanwhile refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "checkout", "-q", "-b", "feat" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only on feat" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "-u", "origin", "feat" });

    var run: AskRun = .{};
    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = .{ .ws = f.ws, .color = false, .env = app.envOf_current(), .ask_run = &run }, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    var p = (try prepare(&ctx, f.clone, .clone, .{})).ready;
    defer p.release();
    try testing.expect(!p.found.blocked());

    try testutil.runGit(&sb, f.bare, &.{ "branch", "-D", "feat" });
    try testing.expectEqual(Cleared.blocked, try p.clear(&ctx, false, .fresh));
}

test "repo remove --clone: clear weighs the remotes again after the prompt, with no run state shared, so a branch deleted on the remote meanwhile refuses the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "checkout", "-q", "-b", "feat" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only on feat" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "-u", "origin", "feat" });

    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = .{ .ws = f.ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    var p = (try prepare(&ctx, f.clone, .clone, .{})).ready;
    defer p.release();
    try testing.expect(!p.found.blocked());

    try testutil.runGit(&sb, f.bare, &.{ "branch", "-D", "feat" });
    try testing.expectEqual(Cleared.blocked, try p.clear(&ctx, false, .fresh));
}

test "repo remove --clone and doctor --retire: a password or token in a remote URL never appears in their output, and the hints removing that URL match it without naming it and settle the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    var own_server: testutil.LoopbackStub = undefined;
    try missingServer(&own_server);
    defer own_server.stop();
    var other_server: testutil.LoopbackStub = undefined;
    try missingServer(&other_server);
    defer other_server.stop();
    const port = own_server.port();
    const other_port = other_server.port();
    const elsewhere = try Elsewhere.ports(a, &.{ port, other_port, 1 });
    defer elsewhere.restore();
    const secret = "ghp_SECRETTOKEN";
    const own = try std.fmt.allocPrint(a, "http://user:{s}@127.0.0.1:{d}/acme/widget.git", .{ secret, port });
    const shown = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{port});
    const global = try std.fs.path.join(a, &.{ sb.root, "global.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = global, .data = try std.fmt.allocPrint(a, "[remote \"origin\"]\n\tpushurl = http://{s}@127.0.0.1:{d}/acme/other.git\n", .{ secret, other_port }) });
    const env = try testutil.EnvOverride.install(a, "GIT_CONFIG_GLOBAL", global);
    defer env.restore();
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", own });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", f.bare });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "url.http://user:" ++ secret ++ "@127.0.0.1:1/.insteadOf", "http://nowhere.invalid/" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "not pushed yet" });
    ui.stderr_terminal_for_test = true;
    defer ui.stderr_terminal_for_test = null;

    const retired = try f.run(@import("doctor.zig").command.run, &.{"--retire"});
    try testing.expect(contains(retired.out, try std.fmt.allocPrint(a, "could not be asked at {s}: ", .{shown})));
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "asking origin at {s}...\n", .{shown})));
    for ([_][]const u8{ retired.out, retired.err, refused.out, refused.err }) |text| {
        if (contains(text, secret)) {
            std.debug.print("the token appears in:\n{s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
    try runHint(&f, refused.err, try std.fmt.allocPrint(a, "could not be asked at {s}: ", .{shown}), f.bare);
    try settleWith(&f, &.{ "could not be asked at http://127.0.0.1:", "commits of branch main" }, f.bare, 4);
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
    try testing.expect(!contains(got.err, secret) and !contains(got.out, secret));
}

test "shownUrl, wholeRegex: a URL's userinfo, query, and fragment are never shown, a URL read two ways or of a transport holt never asks is never shown at all, and the expression matching the URL keeps no part of them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("https://host.invalid/x.git", try shownUrl(a, "https://user:tok@host.invalid/x.git"));
    try testing.expectEqualStrings("https://host.invalid/x.git", try shownUrl(a, "https://tok@host.invalid/x.git"));
    try testing.expectEqualStrings("https://host.invalid/x.git", try shownUrl(a, "https://host.invalid/x.git?token=tok#frag"));
    try testing.expectEqualStrings("https://...", try shownUrl(a, "https://u:p?x@host.invalid#frag"));
    try testing.expectEqualStrings("persistent-https", try shownUrl(a, "persistent-https::https://user:tok@host.invalid/x.git"));
    try testing.expectError(error.AmbiguousUrl, wholeRegex(a, "https://u:p?x@host.invalid#frag"));
    try testing.expectEqualStrings("host.invalid:x.git", try shownUrl(a, "git@host.invalid:x.git"));
    try testing.expectEqualStrings("/srv/a@b/x.git?y", try shownUrl(a, "/srv/a@b/x.git?y"));
    try testing.expectEqualStrings("^https://[^?#]*@host\\.invalid/x\\.git$", try wholeRegex(a, "https://user:tok@host.invalid/x.git"));
    try testing.expectEqualStrings("^https://[^?#]*@host\\.invalid/x\\.git$", try wholeRegex(a, "https://tok@host.invalid/x.git"));
    try testing.expectEqualStrings("^https://host\\.invalid/x\\.git[?#].*$", try wholeRegex(a, "https://host.invalid/x.git?token=tok"));
    try testing.expectEqualStrings("^/srv/x\\.git$", try wholeRegex(a, "/srv/x.git"));
}

test "failureReason: git's own error is never quoted, even the part of a password it leaves in a URL, and each failure is named as holt names it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const leak = try failureReason(a, "fatal: unable to access 'http://SECRETPART@127.0.0.1:1/x.git/': URL rejected: Bad hostname\n", 128);
    try testing.expectEqualStrings("git ls-remote failed (exit 128)", leak);
    const cases = [_][2][]const u8{
        .{ "fatal: unable to access 'https://host.invalid/x.git/': Could not resolve host: host.invalid", "host not found" },
        .{ "ssh: Could not resolve hostname h.invalid: nodename nor servname provided, or not known\nfatal: Could not read from remote repository.", "host not found" },
        .{ "fatal: unable to access 'http://127.0.0.1:1/x.git/': Failed to connect to 127.0.0.1 port 1 after 0 ms: Couldn't connect to server", "connection refused" },
        .{ "fatal: unable to connect to 127.0.0.1:\n127.0.0.1[0: 127.0.0.1]: errno=Connection refused", "connection refused" },
        .{ "ssh: connect to host 10.0.0.1 port 22: Operation timed out\nfatal: Could not read from remote repository.", "timed out" },
        .{ "fatal: Authentication failed for 'http://127.0.0.1:1/x.git/'", "authentication failed" },
        .{ "git@h: Permission denied (publickey).\nfatal: Could not read from remote repository.", "authentication failed" },
        .{ "fatal: repository 'http://127.0.0.1:1/x.git/' not found", "repository not found" },
        .{ "fatal: '/srv/x.git' does not appear to be a git repository\nfatal: Could not read from remote repository.", "repository not found" },
        .{ "fatal: remote error: access denied or repository not exported: /x.git", "repository not found" },
        .{ "ssh -o BatchMode=yes -o ConnectTimeout=10: line 0: ssh: not found\nfatal: Could not read from remote repository.", "git ls-remote failed (exit 128)" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try failureReason(a, c[0], 128));
}

test "repo remove --clone: a remote whose every URL is on this machine names each of them, and the hinted remote add, then the push it hints, settle the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    const one = try bareCopy(&f, "one.git", &.{});
    const two = try bareCopy(&f, "two.git", &.{});
    const three = try bareCopy(&f, "three.git", &.{});
    _ = try setOrigin(&f, one);
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", two });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", three });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "; no remote counts as a copy: remote origin is on this machine ({s}, {s}, {s}); add a remote on another machine (run: git -C {s} remote add holt-kept <url>, with <url> a URL on another machine), or {s} deletes ", .{ one, two, three, cq, local_force })));
    try settleWith(&f, &.{"no remote counts as a copy"}, f.bare, 3);
}

test "repo remove --clone: a remote whose push URL alone is on this machine says so, and the hinted unset, or set-url for a push URL a pushInsteadOf rule gives, settles the delete" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |rule| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
        const copy = try bareCopy(&f, "copy.git", &.{});
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
        if (rule) {
            try testutil.runGit(&sb, f.clone, &.{ "config", try std.mem.concat(a, u8, &.{ "url.", copy, ".pushInsteadOf" }), f.bare });
        } else try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", copy });

        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        const want = if (rule)
            try std.fmt.allocPrint(a, "; no remote counts as a copy: remote origin has its push URLs on this machine ({s}), through a pushInsteadOf rule; add a push URL (run: git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine), or {s} deletes it\n", .{ copy, cq, local_force })
        else
            try std.fmt.allocPrint(a, "; no remote counts as a copy: remote origin has its push URLs on this machine ({s}); replace its push URLs (run: git -C {s} config --local --fixed-value --unset-all remote.origin.pushurl {s}), or {s} deletes it\n", .{ copy, cq, copy, local_force });
        if (!contains(refused.err, want)) {
            std.debug.print("wanted {s} in:\n{s}\n", .{ want, refused.err });
            return error.TestUnexpectedResult;
        }
        try runHint(&f, refused.err, "no remote counts as a copy", f.bare);

        try settleAll(&f, &.{"commits of branch main"}, 3);
    }
}

test "archive --prune: a clone kept for a remote on this machine, or one that could not be asked, names the repo remove --force that deletes it anyway, which does" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |unasked| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        try withProject(&f);
        if (unasked) {
            try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", try std.fs.path.join(a, &.{ f.bare, "offline.git" }) });
            try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
        } else _ = try setOrigin(&f, try bareCopy(&f, "copy.git", &.{}));

        const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
        try testing.expectEqual(@as(u8, 0), got.code);
        const force = try std.fmt.allocPrint(a, "holt repo remove {s} --clone --force", .{Fixture.key});
        try testing.expect(contains(got.out, if (unasked)
            try std.fmt.allocPrint(a, "), or {s} deletes it", .{force})
        else
            try std.fmt.allocPrint(a, "), or {s} deletes them", .{force})));
        try testing.expect(!contains(got.out, "or --force"));
        try testing.expect(fsutil.exists(f.clone));

        const forced = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--force", "--yes" });
        try testing.expectEqual(@as(u8, 0), forced.code);
        try testing.expect(!fsutil.exists(f.clone));
    }
}

/// Test-only: makes loopback URLs with each of `extra` ports stand for
/// another machine's repository (`loopback_elsewhere_for_test`) until
/// `restore`.
const Elsewhere = struct {
    previous: []const u16,

    fn ports(a: std.mem.Allocator, extra: []const u16) !Elsewhere {
        const previous = loopback_elsewhere_for_test;
        loopback_elsewhere_for_test = try std.mem.concat(a, u16, &.{ previous, extra });
        return .{ .previous = previous };
    }

    fn restore(e: Elsewhere) void {
        loopback_elsewhere_for_test = e.previous;
    }
};

/// A loopback port nothing listens on, so a URL naming it is refused.
fn closedPort() !u16 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io(), .{ .reuse_address = true });
    defer server.deinit(io());
    return server.socket.address.getPort();
}

test "repo remove --clone: no part of a password holding an unencoded @ appears in its output" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const port = try closedPort();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    const own = try std.fmt.allocPrint(a, "http://user:p@SECRETPART@127.0.0.1:{d}/acme/widget.git", .{port});
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", own });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "not pushed yet" });
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    for ([_][]const u8{ refused.out, refused.err }) |text| {
        for ([_][]const u8{ "SECRETPART", "p@S" }) |part| if (contains(text, part)) {
            std.debug.print("leaked {s}:\n{s}\n", .{ part, text });
            return error.TestUnexpectedResult;
        };
    }
}

test "repo remove --clone: why a URL could not be asked is named by holt, not quoted from git, and reads whole for a one-character password" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const port = try closedPort();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", try std.fmt.allocPrint(a, "http://bob:1@127.0.0.1:{d}/acme/widget.git", .{port}) });
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    const want = try std.fmt.allocPrint(a, "(remote origin could not be asked at http://127.0.0.1:{d}/acme/widget.git: connection refused); ", .{port});
    if (!contains(got.err, want)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ want, got.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(!contains(got.err, "fatal"));
}

test "repo remove --clone: a URL's query and fragment never appear in its output, and the hint removing that URL settles the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    var server: testutil.LoopbackStub = undefined;
    try missingServer(&server);
    defer server.stop();
    const port = server.port();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    const own = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git?token=SECRETQUERY#SECRETFRAGMENT", .{port});
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", own });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", f.bare });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "not pushed yet" });
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    for ([_][]const u8{ refused.out, refused.err }) |text| {
        if (contains(text, "SECRET")) {
            std.debug.print("leaked:\n{s}\n", .{text});
            return error.TestUnexpectedResult;
        }
    }
    const lead = try std.fmt.allocPrint(a, "could not be asked at http://127.0.0.1:{d}/acme/widget.git: ", .{port});
    try runHint(&f, refused.err, lead, "");
    const next = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), next.code);
    try testing.expect(!contains(next.err, "could not be asked"));
    try runHint(&f, next.err, "commits of branch main no remote has", "");
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
}

test "repo remove --clone: a push URL whose expression would match a value that differs only in its userinfo is removed by editing, which leaves that value" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    var server: testutil.LoopbackStub = undefined;
    try missingServer(&server);
    defer server.stop();
    const port = server.port();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    const alice = try std.fmt.allocPrint(a, "http://alice:TOKENA@127.0.0.1:{d}/acme/widget.git", .{port});
    const bob = try std.fmt.allocPrint(a, "http://bob:TOKENB@127.0.0.1:{d}/acme/widget.git", .{port});
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", alice });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", f.bare });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", bob });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "not pushed yet" });
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(!contains(refused.err, "TOKEN") and !contains(refused.err, "alice"));
    try testing.expect(contains(refused.err, "edit remote.origin.pushurl to replace this push URL (run: git -C "));
    try runHintEditing(&f, refused.err, try std.fmt.allocPrint(a, "could not be asked at http://127.0.0.1:{d}/acme/widget.git: ", .{port}), f.bare, "TOKENA");
    const left = try git.runInRepoScoped(a, &.{ "config", "--get-all", "remote.origin.pushurl" }, f.clone);
    if (!contains(left.stdout, "TOKENB") or contains(left.stdout, "TOKENA")) {
        std.debug.print("left:\n{s}\nstderr was:\n{s}\n", .{ left.stdout, refused.err });
        return error.TestUnexpectedResult;
    }
}

test "repo remove --clone: when the expression matching a push URL without its password would match another value of the key in that configuration too, the hint edits it, naming the key, and settles the delete" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    var server: testutil.LoopbackStub = undefined;
    try missingServer(&server);
    defer server.stop();
    var other: testutil.LoopbackStub = undefined;
    try missingServer(&other);
    defer other.stop();
    const port = server.port();
    const other_port = other.port();
    const elsewhere = try Elsewhere.ports(a, &.{ port, other_port });
    defer elsewhere.restore();
    const shown = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{port});
    const global = try std.fs.path.join(a, &.{ sb.root, "global.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = global, .data = try std.fmt.allocPrint(a, "[remote \"origin\"]\n\tpushurl = http://TOKENX@127.0.0.1:{d}/acme/other.git\n\tpushurl = http://TOKENY@127.0.0.1:{d}/acme/other.git\n", .{ other_port, other_port }) });
    const env = try testutil.EnvOverride.install(a, "GIT_CONFIG_GLOBAL", global);
    defer env.restore();
    try f.sb.git_env.map.put("GIT_CONFIG_GLOBAL", global);
    defer _ = f.sb.git_env.map.swapRemove("GIT_CONFIG_GLOBAL");
    for ([_][]const u8{ "TOKENA", "TOKENB" }) |t| try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", try std.fmt.allocPrint(a, "http://alice:{s}@127.0.0.1:{d}/acme/widget.git", .{ t, port }) });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", f.bare });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "not pushed yet" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    for ([_][]const u8{ "TOKEN", "alice" }) |part| try testing.expect(!contains(refused.err, part));
    const own_line = try std.fmt.allocPrint(a, "(remote origin could not be asked at {s}: repository not found); edit remote.origin.pushurl to replace this push URL (run: git -C {s} config --local --edit && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine), or --force deletes it\n", .{ shown, cq, cq });
    try testing.expectEqual(@as(usize, 2), count(refused.err, own_line));
    const global_line = try std.fmt.allocPrint(a, "edit remote.origin.pushurl to replace this push URL (run: git config --file {s} --edit && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine) (in {s}, which changes every repository), or --force deletes it\n", .{ try ui.quotePath(a, app.envOf_current(), global), cq, try fsutil.contractTilde(a, app.envOf_current(), global) });
    try testing.expectEqual(@as(usize, 2), count(refused.err, global_line));
}

test "repo remove --clone: a remote-helper push URL is never asked and never a copy, whatever its address names" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const here = try std.fs.path.join(a, &.{ sb.root, "helper-here.git" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", f.bare, here });
    try testutil.markElsewhere(here);
    const url = try std.mem.concat(a, u8, &.{ "testhelper::", here });
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", url });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });

    ui.stderr_terminal_for_test = true;
    defer ui.stderr_terminal_for_test = null;
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, "no remote counts as a copy: remote origin is reached through testhelper, which holt never asks"));
    try testing.expect(!contains(refused.err, "asking origin at testhelper"));
    try testing.expect(!contains(refused.err, here));
    try testutil.runGit(&sb, f.clone, &.{ "config", "--unset", "remote.origin.pushurl" });
    try settleAll(&f, &.{"commits of branch main"}, 3);
}

test "onThisMachine, counts, shownUrl: how the gate reads a URL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const at: At = .{ .repo = sb.root };
    const here = [_][]const u8{
        "ssh://127.1/x",                       "git://127.0.1/x",             "git://2130706433/x",          "git://0x7f000001/x",
        "git://0x7f.1/x",                      "git://0/x",                   "git://0.0.0.0/x",             "git://localhost/x",
        "git://[::1]/x",                       "git://[0:0:0:0:0:0:0:1]/x",   "git://[::ffff:127.0.0.1]/x",  "git://[::ffff:7f00:1]/x",
        "git://[::]/x",                        "git://0177.0.0.1/x",          "git://localhost./x",          "git://LOCALHOST/x",
        "git://sub.localhost/x",               "git://:19561/b.git",          "git://[]:19561/b.git",        "[::1%1]:x",
        "[fe80::1%lo0]:x",                     "git+ssh://u@127.0.0.1/x.git", "ssh+git://u@127.0.0.1/x.git", "http://127.0.0.1:1/x",
        "http://alice:SE@CRET2@127.0.0.1:1/x", "/srv/x.git",                  "file:///srv/x.git",           "x.bundle",
        "ssh://localhost:2222/x",
    };
    for (here) |url| {
        if (!try onThisMachine(a, sb.root, url) or try counts(a, at, url)) {
            std.debug.print("expected on this machine: {s}\n", .{url});
            return error.TestUnexpectedResult;
        }
    }
    const never = [_][]const u8{
        "http://alice:AB/CD+EF@127.0.0.1:18402/x.git",     "http://alice:AB?CD@127.0.0.1:18402/x.git",     "http://alice:AB#CD@127.0.0.1:18402/x.git",
        "git://127.0.0.1:19438/a@elsewhere.invalid/x.git", "http://127.0.0.1:18438/a@elsewhere.invalid/x", "http://127.0.0.1:18438?a@elsewhere.invalid/x",
        "ssh://u@127.0.0.1/p@elsewhere.invalid/x.git",     "ssh://127.0.0.1:2222/p@elsewhere.invalid/x",   "git@127.0.0.1:p@elsewhere.invalid/x.git",
        "u:pw@h.invalid:x.git",                            "git://[::1%1]:19561/b.git",                    "git://[::1%25lo0]:19561/b.git",
        "git://[::1%lo0]:19561/b.git",                     "hg::https://h.invalid/x",                      "ext::ssh h.invalid:p",
        "fd::7",                                           "nohelper::https://alice:SECRET10@h.invalid/x", "custom://h.invalid/x",
        "ssh://-oProxyCommand=x/y",
    };
    for (never) |url| {
        if (try onThisMachine(a, sb.root, url) or try counts(a, at, url)) {
            std.debug.print("expected neither on this machine nor counting: {s}\n", .{url});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "ssh://u:pw@h.invalid:2222/x.git", "https://h.invalid/x", "git://h.invalid/x", "h.invalid:x", "u@[2001:db8::1]:x" }) |url| {
        if (try onThisMachine(a, sb.root, url) or !try counts(a, at, url)) {
            std.debug.print("expected to count: {s}\n", .{url});
            return error.TestUnexpectedResult;
        }
    }
    const shown = [_][2][]const u8{
        .{ "u:pw@h.invalid:x.git", "..." },
        .{ "http://alice:AB/CD+EF@127.0.0.1:18402/x.git", "http://..." },
        .{ "http://127.0.0.1:1/x.git?token=SECRET5#SECRET6", "http://127.0.0.1:1/x.git" },
        .{ "git://alice:SECRET9@127.0.0.1:1/x.git", "git://127.0.0.1:1/x.git" },
        .{ "nohelper::https://alice:SECRET10@127.0.0.1:1/x.git", "nohelper" },
        .{ "http://alice:SE@CRET2@127.0.0.1:1/x.git", "http://127.0.0.1:1/x.git" },
        .{ "alice@h.invalid:x.git", "h.invalid:x.git" },
    };
    for (shown) |c| try testing.expectEqualStrings(c[1], try shownUrl(a, c[0]));
}

test "gitRisks: a loopback URL is on this machine and never asked, a helper URL is never asked, and an ambiguous URL is never shown" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const log = try std.fs.path.join(a, &.{ sb.root, "ssh.log" });
    const script = try std.fs.path.join(a, &.{ sb.root, "logging-ssh" });
    try testutil.writeExecutable(script, try std.fmt.allocPrint(a, "#!/bin/sh\necho called >> '{s}'\nexit 255\n", .{log}));
    try testutil.runGit(&sb, work, &.{ "config", "core.sshCommand", script });
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    for ([_][]const u8{ "ssh://127.1/acme/widget.git", "hg::https://holt-test.invalid/acme/widget" }) |url| {
        try testutil.runGit(&sb, work, &.{ "remote", "set-url", "origin", url });
        const risks = try gitRisks(try testAsker(a), work);
        try testing.expect(risks.len > 0);
        try testing.expect(!fsutil.exists(log));
    }
    try testing.expectEqualStrings("...", try shownUrl(a, "u:pw@h.invalid:x"));
}

test "repo remove --clone: a push URL set in config.worktree is hinted away there, with --worktree, which git accepts and which settles the delete" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |local| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
        var server: testutil.LoopbackStub = undefined;
        try missingServer(&server);
        defer server.stop();
        const port = server.port();
        const elsewhere = try Elsewhere.ports(a, &.{port});
        defer elsewhere.restore();
        const url = if (local) try std.fs.path.join(a, &.{ sb.root, "here.git" }) else try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{port});
        if (local) try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", f.bare, url });
        try testutil.runGit(&sb, f.clone, &.{ "config", "extensions.worktreeConfig", "true" });
        try testutil.runGit(&sb, f.clone, &.{ "config", "--worktree", "remote.origin.pushurl", url });
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });

        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        const cmd = if (local)
            try std.fmt.allocPrint(a, "replace its push URLs (run: git -C {s} config --worktree --fixed-value --unset-all remote.origin.pushurl {s})", .{ cq, url })
        else
            try std.fmt.allocPrint(a, "replace this push URL (run: git -C {s} config --worktree --fixed-value --unset-all remote.origin.pushurl {s} && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine)", .{ cq, try ui.shellQuote(a, url), cq });
        if (!contains(refused.err, cmd)) {
            std.debug.print("wanted {s} in:\n{s}\n", .{ cmd, refused.err });
            return error.TestUnexpectedResult;
        }
        try runHint(&f, refused.err, if (local) "no remote counts as a copy" else "could not be asked at ", f.bare);
        const left = try git.runInRepoScoped(a, &.{ "config", "--worktree", "--get-all", "remote.origin.pushurl" }, f.clone);
        try testing.expectEqual(@as(u8, 1), left.status);
        const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try runHint(&f, got.err, "commits of branch main no remote", "");
        try testing.expectEqual(@as(u8, 0), (try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" })).code);
    }
}

/// Makes `core.sshCommand` of `work` a command that appends a line to
/// `log` for each connection (not for the `-G` probe git makes of an ssh
/// it does not know) and runs, here, what git asks the host to run, with
/// the path `/holt-remote.git` read as `bare`; returns the ssh URL of that
/// path, which answers as `bare` would, with no network, wherever the
/// sandbox is (a path holding `@` would make a URL naming it ambiguous).
fn localSsh(a: std.mem.Allocator, sb: *testutil.Sandbox, work: []const u8, log: []const u8, bare: []const u8) ![]const u8 {
    const script = try std.fs.path.join(a, &.{ sb.root, "local-ssh" });
    try testutil.writeExecutable(script, try std.fmt.allocPrint(a, "#!/bin/sh\n[ \"$1\" = -G ] && exit 1\necho called >> '{s}'\nfor last; do :; done\nexec sh -c \"$(printf '%s' \"$last\" | sed 's|/holt-remote.git|{s}|')\"\n", .{ log, bare }));
    try testutil.runGit(sb, work, &.{ "config", "core.sshCommand", script });
    return "ssh://localhost/holt-remote.git";
}

/// How many lines the file at `path` holds; 0 when there is none.
fn lineCount(a: std.mem.Allocator, path: []const u8) !usize {
    const text = kept.content.readSmall(a, path) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    return count(text, "\n");
}

test "repo remove --clone: once an ssh connection to a host times out, no other URL on that host is asked that run, each named on a line of its own with no command" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const log = try std.fs.path.join(a, &.{ sb.root, "ssh.log" });
    const script = try std.fs.path.join(a, &.{ sb.root, "timing-out-ssh" });
    try testutil.writeExecutable(script, try std.fmt.allocPrint(a, "#!/bin/sh\n[ \"$1\" = -G ] && exit 1\necho called >> '{s}'\necho 'ssh: connect to host 127.0.0.1 port 22: Operation timed out' >&2\nexit 255\n", .{log}));
    try testutil.runGit(&sb, f.clone, &.{ "config", "core.sshCommand", script });
    const elsewhere = try Elsewhere.ports(a, &.{22});
    defer elsewhere.restore();
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", "ssh://127.0.0.1/acme/widget.git" });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "r2", "ssh://127.0.0.1/acme/other.git" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expectEqual(@as(usize, 1), try lineCount(a, log));
    try testing.expect(contains(got.err, "(remote origin could not be asked at ssh://127.0.0.1/acme/widget.git: timed out); reconnect and run again, or --force deletes them\n"));
    try testing.expect(!contains(got.err, "other.git"));
}

test "repo remove --clone: once a host gives no answer in time, no other URL on it is asked that run, each named on a line of its own, and other hosts are still asked" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io(), .{ .reuse_address = true });
    defer server.deinit(io());
    const port = server.socket.address.getPort();
    const elsewhere = try Elsewhere.ports(a, &.{ port, 22 });
    defer elsewhere.restore();
    const log = try std.fs.path.join(a, &.{ sb.root, "ssh.log" });
    const ssh_url = try localSsh(a, &sb, f.clone, log, f.bare);
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/r0.git", .{port}) });
    for (1..3) |n| try testutil.runGit(&sb, f.clone, &.{ "remote", "add", try std.fmt.allocPrint(a, "r{d}", .{n}), try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/r{d}.git", .{ port, n }) });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "zz", ssh_url });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "not pushed yet" });
    ask_limit_for_test = 1;
    defer ask_limit_for_test = null;

    const started = std.Io.Clock.awake.now(testing.io);
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 20 * std.time.ns_per_s);
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expectEqual(@as(usize, 1), count(got.err, ": no answer in 1 seconds); reconnect and run again, or --force deletes "));
    const skipped = try std.fmt.allocPrint(a, " not asked: 127.0.0.1:{d} did not answer earlier in this run; reconnect and run again\n", .{port});
    try testing.expectEqual(@as(usize, 0), count(got.err, skipped));
    try testing.expect(!contains(got.err, "remote zz"));
    try testing.expect((try lineCount(a, log)) > 0);
    try testing.expect(fsutil.exists(f.clone));
}

test "repo remove --clone --yes and archive --prune --yes: with no prompt between the weighings, each URL is asked once" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |archive| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        if (archive) try withProject(&f);
        const log = try std.fs.path.join(a, &.{ sb.root, "ssh.log" });
        const elsewhere = try Elsewhere.ports(a, &.{22});
        defer elsewhere.restore();
        try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", try localSsh(a, &sb, f.clone, log, f.bare) });

        const got = if (archive)
            try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" })
        else
            try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expect(!fsutil.exists(f.clone));
        try testing.expectEqual(@as(usize, 1), try lineCount(a, log));
        try testing.expect(!contains(got.err, "waiting for "));
    }
}

test "repo remove --clone and archive --prune: after a prompt on a terminal, each URL is asked again, and repo remove prints its asking line once, archive --prune none" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |archive| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        if (archive) try withProject(&f);
        const log = try std.fs.path.join(a, &.{ sb.root, "ssh.log" });
        const elsewhere = try Elsewhere.ports(a, &.{22});
        defer elsewhere.restore();
        const url = try localSsh(a, &sb, f.clone, log, f.bare);
        try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", url });
        ui.stdin_terminal_for_test = true;
        defer ui.stdin_terminal_for_test = null;
        ui.stderr_terminal_for_test = true;
        defer ui.stderr_terminal_for_test = null;
        ui.stdin_for_test = "y\n";
        defer ui.stdin_for_test = null;

        const got = if (archive)
            try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune" })
        else
            try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone" });
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expect(!fsutil.exists(f.clone));
        try testing.expectEqual(@as(usize, 2), try lineCount(a, log));
        try testing.expectEqual(@as(usize, if (archive) 0 else 1), count(got.err, try std.fmt.allocPrint(a, "asking origin at {s}...\n", .{url})));
    }
}

test "repo remove --clone: off a terminal, a query that has run 5 seconds says which host it is waiting for" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io(), .{ .reuse_address = true });
    defer server.deinit(io());
    const port = server.socket.address.getPort();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{port}) });
    ask_limit_for_test = 7;
    defer ask_limit_for_test = null;

    const started = std.Io.Clock.awake.now(testing.io);
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 30 * std.time.ns_per_s);
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expectEqual(@as(usize, 1), count(got.err, try std.fmt.allocPrint(a, "waiting for 127.0.0.1:{d}...\n", .{port})));
    try testing.expect(!contains(got.err, "asking "));
}

/// Test-only: installs every pair of `pairs` in the process environment
/// until `restore`.
const EnvPairs = struct {
    overrides: []testutil.EnvOverride,

    fn install(a: std.mem.Allocator, pairs: []const [2]?[]const u8) !EnvPairs {
        const overrides = try a.alloc(testutil.EnvOverride, pairs.len);
        for (pairs, overrides) |p, *o| o.* = try testutil.EnvOverride.install(a, p[0].?, p[1]);
        return .{ .overrides = overrides };
    }

    fn restore(e: EnvPairs) void {
        var i = e.overrides.len;
        while (i > 0) {
            i -= 1;
            e.overrides[i].restore();
        }
    }
};

const prompting_env = [_][2]?[]const u8{
    .{ "GIT_ASKPASS", "must-not-run" },
    .{ "SSH_ASKPASS", "must-not-run" },
    .{ "SSH_ASKPASS_REQUIRE", "force" },
    .{ "GIT_TRACE", "1" },
    .{ "GIT_TRACE_PACKET", "1" },
    .{ "LC_ALL", "C.UTF-8" },
};

/// Whether `env`, `env`'s output, sets a variable to exactly `line`'s value
/// (`NAME=value`).
fn hasEnvLine(env: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, env, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, line)) return true;
    return false;
}

fn setsEnv(env: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, env, '\n');
    while (it.next()) |l| if (l.len > name.len and std.mem.startsWith(u8, l, name) and l[name.len] == '=') return true;
    return false;
}

test "delete gate: reads and queries run with no prompt, no tracing, and git's messages in English" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const log = try std.fs.path.join(a, &.{ sb.root, "query-env" });
    const script = try std.fs.path.join(a, &.{ sb.root, "env-ssh" });
    try testutil.writeExecutable(script, try std.fmt.allocPrint(a, "#!/bin/sh\nenv > '{s}'\nexit 1\n", .{log}));
    try testutil.runGit(&sb, bare, &.{ "config", "core.sshCommand", script });
    const env = try EnvPairs.install(a, &prompting_env);
    defer env.restore();

    const at: At = .{ .repo = bare };
    const read = try at.run(a, &.{ "-c", "alias.holt-env=!env", "holt-env" });
    try testing.expectEqual(@as(u8, 0), read.status);
    _ = try at.runQuery(a, "ssh://holt-test.invalid/x", "ssh://holt-test.invalid/x", .{ .limit = .fromSeconds(20) });
    const query = try kept.content.readSmall(a, log);
    for ([_][]const u8{ read.stdout, query }) |seen| {
        for ([_][]const u8{ "GIT_ASKPASS=", "SSH_ASKPASS_REQUIRE=never", "LC_ALL=C" }) |line| try testing.expect(hasEnvLine(seen, line));
        for ([_][]const u8{ "SSH_ASKPASS", "GIT_TRACE", "GIT_TRACE_PACKET" }) |name| try testing.expect(!setsEnv(seen, name));
    }
    try testing.expect(hasEnvLine(query, "GCM_INTERACTIVE=never"));
}

test "delete gate: a command outside the gate keeps the user's locale and prompts" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const env = try EnvPairs.install(a, &prompting_env);
    defer env.restore();
    const res = try git.runInRepoScoped(a, &.{ "-c", "alias.holt-env=!env", "holt-env" }, bare);
    try testing.expectEqual(@as(u8, 0), res.status);
    for ([_][]const u8{ "GIT_ASKPASS=must-not-run", "SSH_ASKPASS=must-not-run", "SSH_ASKPASS_REQUIRE=force", "LC_ALL=C.UTF-8" }) |line| try testing.expect(hasEnvLine(res.stdout, line));
}

test "delete gate: a query never follows a redirect, even one a user's key for its URL allows" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    var elsewhere: testutil.LoopbackStub = undefined;
    try elsewhere.start("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    defer elsewhere.stop();
    var redirecting: testutil.LoopbackStub = undefined;
    try redirecting.start(try std.fmt.allocPrint(a, "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/moved.git/info/refs?service=git-upload-pack\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{elsewhere.port()}));
    defer redirecting.stop();
    const origin = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{redirecting.port()});
    try testutil.runGit(&sb, bare, &.{ "config", try std.fmt.allocPrint(a, "http.{s}.followRedirects", .{origin}), "true" });

    const url = try std.fmt.allocPrint(a, "{s}/acme/widget.git", .{origin});
    const res = try (At{ .repo = bare }).runQuery(a, url, url, .{ .limit = .fromSeconds(20) });
    try testing.expect(res.status != 0);
    try testing.expect(redirecting.count() >= 1);
    try testing.expectEqual(@as(u32, 0), elsewhere.count());

    try testutil.runGit(&sb, bare, &.{ "config", try std.fmt.allocPrint(a, "url.{s}/.insteadOf", .{origin}), "http://holt-alias.invalid/" });
    const rewritten = try (At{ .repo = bare }).runQuery(a, "http://holt-alias.invalid/acme/widget.git", url, .{ .limit = .fromSeconds(20) });
    try testing.expect(rewritten.status != 0);
    try testing.expect(redirecting.count() >= 2);
    try testing.expectEqual(@as(u32, 0), elsewhere.count());
    try testing.expectEqualStrings("http.https://alice@h:1/x.followRedirects", (try redirectKey(a, "https://alice:secret@h:1/x?token#frag")).?);
    try testing.expect(try redirectKey(a, "ssh://h/x") == null);
}

test "delete gate: a credential helper a query runs is told never to wait on a person" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    var server: testutil.LoopbackStub = undefined;
    try server.start("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"holt\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    defer server.stop();
    const log = try std.fs.path.join(a, &.{ sb.root, "helper-saw" });
    try testutil.runGit(&sb, bare, &.{ "config", "credential.helper", try std.fmt.allocPrint(a, "!f() {{ git config --get credential.interactive >> '{s}'; echo \"${{GCM_INTERACTIVE-unset}}\" >> '{s}'; }}; f", .{ log, log }) });

    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{server.port()});
    const res = try (At{ .repo = bare }).runQuery(a, url, url, .{ .limit = .fromSeconds(20) });
    try testing.expect(res.status != 0);
    const saw = try kept.content.readSmall(a, log);
    try testing.expect(std.mem.startsWith(u8, saw, "never\nnever\n"));
}

test "delete gate: a read runs no transport whatever the user allows, and a query keeps the user's configuration but no inherited allow list" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const other = try testutil.makeBareRepo(&sb, "other.git");
    defer testing.allocator.free(other);
    for ([_][]const u8{ "protocol.allow", "protocol.file.allow", "protocol.git.allow" }) |key| try testutil.runGit(&sb, bare, &.{ "config", key, "always" });
    const allow = try testutil.EnvOverride.install(a, "GIT_ALLOW_PROTOCOL", "file");
    defer allow.restore();
    const at: At = .{ .repo = bare };

    const read = try at.run(a, &.{ "ls-remote", "--", other });
    try testing.expect(read.status != 0);
    try testing.expect(contains(read.stderr, "transport 'file' not allowed"));
    const env = try at.run(a, &.{ "-c", "alias.holt-env=!env", "holt-env" });
    try testing.expect(hasEnvLine(env.stdout, "GIT_ALLOW_PROTOCOL=holt_none"));

    var silent: testutil.LoopbackStub = undefined;
    try silent.start("");
    defer silent.stop();
    const url = try std.fmt.allocPrint(a, "git://127.0.0.1:{d}/acme/widget.git", .{silent.port()});
    const query = try at.runQuery(a, url, url, .{ .limit = .fromSeconds(2) });
    try testing.expect(query.status != 0);
    try testing.expect(silent.count() >= 1);
}

test "delete gate: a read of an object a partial clone lacks never waits on its promisor" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    try testutil.runGit(&sb, bare, &.{ "config", "uploadpack.allowFilter", "true" });
    const partial = try std.fs.path.join(a, &.{ sb.root, "partial" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", "--no-checkout", "--filter=blob:none", try std.mem.concat(a, u8, &.{ "file://", bare }), partial });
    var silent: testutil.LoopbackStub = undefined;
    try silent.start("");
    defer silent.stop();
    try testutil.runGit(&sb, partial, &.{ "config", "remote.origin.url", try std.fmt.allocPrint(a, "git://127.0.0.1:{d}/acme/widget.git", .{silent.port()}) });
    for ([_][]const u8{ "protocol.allow", "protocol.git.allow" }) |key| try testutil.runGit(&sb, partial, &.{ "config", key, "always" });
    const allow = try testutil.EnvOverride.install(a, "GIT_ALLOW_PROTOCOL", "git");
    defer allow.restore();
    const blob = std.mem.trim(u8, (try (At{ .repo = bare }).run(a, &.{ "rev-parse", "HEAD:README" })).stdout, "\r\n");

    const started = std.Io.Clock.awake.now(io());
    const res = try (At{ .repo = partial }).run(a, &.{ "cat-file", "-p", blob });
    try testing.expect(res.status != 0);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(io())).nanoseconds < 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u32, 0), silent.count());
}

test "delete gate: a git directory whose core.worktree is gone is read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "module.git");
    defer testing.allocator.free(bare);
    try testutil.runGit(&sb, bare, &.{ "config", "core.bare", "false" });
    try testutil.runGit(&sb, bare, &.{ "config", "core.worktree", "../holt-missing-worktree" });
    const res = try (At{ .repo = bare, .git_dir = bare }).run(a, &.{ "rev-parse", "--verify", "HEAD" });
    try testing.expectEqual(@as(u8, 0), res.status);
    for (try gitDirRisks(try testAsker(a), bare)) |r| try testing.expect(r.what != .unreadable);
}

test "queryFailure: each failure git and ssh print is named as holt names it, with its class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { text: []const u8, why: []const u8, class: Class, host_level: bool }{
        .{ .text = "ssh: Could not resolve hostname h.invalid: nodename nor servname provided, or not known", .why = "host not found", .class = .transient, .host_level = true },
        .{ .text = "fatal: unable to access 'https://h.invalid/x/': Could not resolve host: h.invalid", .why = "host not found", .class = .transient, .host_level = true },
        .{ .text = "fatal: unable to look up h.invalid (port 9418) (Name or service not known)", .why = "host not found", .class = .transient, .host_level = true },
        .{ .text = "ssh: connect to host 127.0.0.1 port 1: Connection refused", .why = "connection refused", .class = .transient, .host_level = true },
        .{ .text = "fatal: unable to access 'http://127.0.0.1:1/x.git/': Failed to connect to 127.0.0.1 port 1 after 0 ms: Couldn't connect to server", .why = "connection refused", .class = .transient, .host_level = true },
        .{ .text = "kex_exchange_identification: read: Connection reset by peer", .why = "connection reset", .class = .transient, .host_level = true },
        .{ .text = "ssh: connect to host 10.255.255.1 port 22: Operation timed out", .why = "timed out", .class = .transient, .host_level = true },
        .{ .text = "Connection timed out during banner exchange", .why = "timed out", .class = .transient, .host_level = true },
        .{ .text = "Host key verification failed.", .why = "host key not verified", .class = .host_key, .host_level = true },
        .{ .text = "ERROR: Repository not found.", .why = "repository not found", .class = .persistent, .host_level = false },
        .{ .text = "fatal: '/x.git' does not appear to be a git repository", .why = "repository not found", .class = .persistent, .host_level = false },
        .{ .text = "fatal: remote error: access denied or repository not exported: /x.git", .why = "repository not found", .class = .persistent, .host_level = false },
        .{ .text = "fatal: remote error: access denied", .why = "authentication failed", .class = .persistent, .host_level = false },
        .{ .text = "git@h.invalid: Permission denied (publickey).", .why = "authentication failed", .class = .persistent, .host_level = false },
        .{ .text = "fatal: could not read Username for 'https://h.invalid': terminal prompts disabled", .why = "authentication failed", .class = .persistent, .host_level = false },
        .{ .text = "fatal: unable to get password from user", .why = "authentication failed", .class = .persistent, .host_level = false },
        .{ .text = "fatal: unable to access 'http://127.0.0.1:1/x.git/': The requested URL returned error: 403", .why = "authentication failed", .class = .persistent, .host_level = false },
        .{ .text = "fatal: unable to access 'http://127.0.0.1:1/x.git/': The requested URL returned error: 302", .why = "the server redirects it elsewhere", .class = .persistent, .host_level = false },
        .{ .text = "fatal: transport 'git' not allowed", .why = "git's protocol policy forbids it", .class = .persistent, .host_level = false },
        .{ .text = "fatal: SECRET something else", .why = "git ls-remote failed (exit 128)", .class = .transient, .host_level = false },
    };
    for (cases) |c| {
        const got = try queryFailure(a, c.text, 128);
        try testing.expectEqualStrings(c.why, got.why);
        try testing.expectEqual(c.class, got.class);
        try testing.expectEqual(c.host_level, got.host_level);
    }
}

test "AskRun: a skip key is skipped after a host-level failure or once its unsuccessful queries took the limit together, and a host not found skips every key of it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var run: AskRun = .{};
    const budget: i96 = 30 * std.time.ns_per_s;
    const other = try queryFailure(a, "fatal: SECRET", 128);
    try run.record(a, "k1", "h1", 20 * std.time.ns_per_s, other, budget);
    try testing.expect(run.skips("k1", "h1") == null);
    try run.record(a, "k1", "h1", 10 * std.time.ns_per_s, other, budget);
    try testing.expectEqual(Class.transient, run.skips("k1", "h1").?);
    try run.record(a, "k2", "h2", 1, try queryFailure(a, "Host key verification failed.", 255), budget);
    try testing.expectEqual(Class.host_key, run.skips("k2", "h2").?);
    try run.record(a, "k3", "h3", 1, null, budget);
    try testing.expectEqual(Class.transient, run.skips("k3", "h3").?);
    try run.record(a, "k4", "h4", 1, try queryFailure(a, "Could not resolve host: h4", 128), budget);
    try testing.expectEqual(Class.transient, run.skips("k5", "h4").?);
    try testing.expect(run.skips("k5", "h5") == null);
    const first = try skipKey(a, remote_url.parse("ssh://alice@HOST./one"));
    try testing.expectEqualStrings(first, try skipKey(a, remote_url.parse("bob@host:two")));
    try testing.expectEqualStrings(first, try skipKey(a, remote_url.parse("git+ssh://host:00022/three")));
    try testing.expect(!std.mem.eql(u8, first, try skipKey(a, remote_url.parse("https://host:22/four"))));
    try testing.expect(!std.mem.eql(u8, first, try skipKey(a, remote_url.parse("ssh://host:2222/five"))));
}

test "gitRisks: a listener that closes without an answer is queried once for three URLs on it once their failures took the budget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    var slow: testutil.LoopbackStub = undefined;
    try slow.startDelayed("", 2000);
    defer slow.stop();
    const elsewhere = try Elsewhere.ports(a, &.{slow.port()});
    defer elsewhere.restore();
    try testutil.runGit(&sb, work, &.{ "remote", "set-url", "origin", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/r0.git", .{slow.port()}) });
    for (1..3) |n| try testutil.runGit(&sb, work, &.{ "remote", "add", try std.fmt.allocPrint(a, "r{d}", .{n}), try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/r{d}.git", .{ slow.port(), n }) });
    ask_limit_for_test = 10;
    defer ask_limit_for_test = null;
    ask_budget_for_test = 2;
    defer ask_budget_for_test = null;
    const started = std.Io.Clock.awake.now(io());
    _ = try gitRisks(try testAsker(a), work);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(io())).nanoseconds < 15 * std.time.ns_per_s);
    try testing.expectEqual(@as(u32, 1), slow.count());
}

test "gitRisks: a host not found over ssh is not asked over another transport that run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    const script = try std.fs.path.join(a, &.{ sb.root, "lost-ssh" });
    try testutil.writeExecutable(script, "#!/bin/sh\necho 'ssh: Could not resolve hostname 127.0.0.1: nodename nor servname provided, or not known' >&2\nexit 255\n");
    try testutil.runGit(&sb, work, &.{ "config", "core.sshCommand", script });
    var server: testutil.LoopbackStub = undefined;
    try server.start("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    defer server.stop();
    const elsewhere = try Elsewhere.ports(a, &.{ 22, server.port() });
    defer elsewhere.restore();
    try testutil.runGit(&sb, work, &.{ "remote", "set-url", "origin", "ssh://127.0.0.1/acme/widget.git" });
    try testutil.runGit(&sb, work, &.{ "remote", "add", "web", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{server.port()}) });
    const asker = try testAsker(a);
    _ = try gitRisks(asker, work);
    try testing.expectEqual(@as(u32, 0), server.count());
    const web = (try asker.answerOf(try scopeOf(a, .{ .repo = work }), try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{server.port()}))).?;
    try testing.expect(web == .unasked and web.unasked.host != null);
}

const InventoryWork = struct { path: []const u8, object: []const u8 };

/// Test-only: a linked working tree `name` of `f`'s clone, detached, with
/// a commit only it holds.
fn inventoryWork(f: *const Fixture, name: []const u8) !InventoryWork {
    const path = try std.fs.path.join(f.a, &.{ f.sb.root, name });
    try testutil.runGit(f.sb, f.clone, &.{ "worktree", "add", "-q", "--detach", path });
    try f.write(path, "inventory.txt", name);
    try testutil.runGit(f.sb, path, &.{ "add", "inventory.txt" });
    try testutil.runGit(f.sb, path, &.{ "commit", "-q", "-m", "worktree state" });
    const res = try (At{ .repo = path }).run(f.a, &.{ "rev-parse", "HEAD" });
    try testing.expectEqual(@as(u8, 0), res.status);
    return .{ .path = try fsutil.realPathOrSelf(f.a, path), .object = std.mem.trim(u8, res.stdout, "\r\n") };
}

test "git inventory: a commit only a linked worktree's detached HEAD holds is weighed with the clone, and doctor --retire names it" {
    try skipWithoutLinks();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const work = try inventoryWork(&f, "linked-inventory");
    var found = false;
    for (try gitRisks(try testAsker(a), f.clone)) |r| if (r.what == .head_unheld and std.mem.eql(u8, r.name, work.object)) {
        try testing.expectEqualStrings("linked-inventory", r.worktree.?);
        found = true;
    };
    try testing.expect(found);
    const retired = try f.run(@import("doctor.zig").command.run, &.{"--retire"});
    try testing.expectEqual(@as(u8, 1), retired.code);
    try testing.expect(contains(retired.out, try std.fmt.allocPrint(a, "commit {s}, which only the HEAD of worktree linked-inventory holds and no remote has, in ", .{work.object})));
}

test "git inventory: a commit only a linked worktree's refs/bisect/bad holds is weighed, its directory gone or not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const work = try inventoryWork(&f, "bisect-inventory");
    try testutil.runGit(&sb, work.path, &.{ "update-ref", "refs/bisect/bad", work.object });
    try testutil.runGit(&sb, work.path, &.{ "checkout", "-q", "--detach", "origin/main" });
    for ([_]bool{ false, true }) |gone| {
        if (gone) try std.Io.Dir.cwd().rename(work.path, .cwd(), try std.fs.path.join(a, &.{ sb.root, "aside-inventory" }), io());
        var found = false;
        for (try gitRisks(try testAsker(a), f.clone)) |r| if (r.what == .ref_unheld and std.mem.eql(u8, r.name, "refs/bisect/bad")) {
            try testing.expectEqualStrings("bisect-inventory", r.worktree.?);
            found = true;
        };
        try testing.expect(found);
    }
}

test "repo remove --clone: a commit only refs/prefetch holds refuses the delete" {
    try skipWithoutLinks();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only prefetched" });
    try testutil.runGit(&sb, f.clone, &.{ "update-ref", "refs/prefetch/remotes/origin/main", "HEAD" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "commits only 1 ref of remote origin holds, no remote has, in "));
    try testing.expect(fsutil.exists(f.clone));
}

test "worktree -r: a commit only the worktree's refs/bisect/bad holds refuses the removal" {
    try skipWithoutLinks();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    try testing.expectEqual(@as(u8, 0), made.code);
    const path = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try testutil.runGit(&sb, path, &.{ "checkout", "-q", "--detach" });
    try f.write(path, "private.txt", "private ref state");
    try testutil.runGit(&sb, path, &.{ "add", "private.txt" });
    try testutil.runGit(&sb, path, &.{ "commit", "-q", "-m", "private state" });
    try testutil.runGit(&sb, path, &.{ "update-ref", "refs/bisect/bad", "HEAD" });
    try testutil.runGit(&sb, path, &.{ "checkout", "-q", "feature" });
    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, "commits only refs/bisect/bad of worktree "));
    try testing.expect(fsutil.exists(path));
}

test "git inventory: a worktree record git cannot read makes the clone's git state unreadable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try std.Io.Dir.cwd().createDirPath(io(), try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees", "incomplete" }));
    var unreadable = false;
    for (try gitRisks(try testAsker(a), f.clone)) |r| if (r.what == .unreadable) {
        unreadable = true;
    };
    try testing.expect(unreadable);
}

test "git inventory: worktree -r weighs the worktree's own refs and a HEAD on one of them, and no record that is a link" {
    try skipWithoutLinks();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const work = try inventoryWork(&f, "private-inventory");
    try testutil.runGit(&sb, work.path, &.{ "update-ref", "refs/worktree/wip", work.object });
    try testutil.runGit(&sb, work.path, &.{ "checkout", "-q", "--detach", "origin/main" });
    const risks = try worktreeRisks(try testAsker(a), work.path);
    try testing.expectEqual(@as(usize, 1), risks.len);
    try testing.expectEqualStrings("refs/worktree/wip", risks[0].name);
    try testing.expectEqualStrings("private-inventory", risks[0].worktree.?);

    try testutil.runGit(&sb, work.path, &.{ "symbolic-ref", "HEAD", "refs/worktree/wip" });
    const on_ref = try worktreeRisks(try testAsker(a), work.path);
    try testing.expectEqual(@as(usize, 2), on_ref.len);
    try testing.expect(on_ref[1].what == .head_unheld);

    const original = try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees", "private-inventory" });
    try std.Io.Dir.cwd().symLink(io(), original, try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees", "alias" }), .{ .is_directory = true });
    try testing.expectError(error.GitFailed, worktreeRisks(try testAsker(a), work.path));
}

test "heldCommits: 300 candidates against 1000 listed tips take two git reads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const head = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "HEAD" }, work)).stdout, "\n");
    const tips = try a.alloc([]const u8, 1000);
    for (tips, 1..) |*tip, n| tip.* = try std.fmt.allocPrint(a, "{x:0>40}", .{n});
    var import_data: std.Io.Writer.Allocating = .init(a);
    for (0..300) |n| {
        try import_data.writer.print("commit refs/heads/candidate-{d}\ncommitter holt-test <test@holt.invalid> {d} +0000\ndata 0\nfrom {s}\n\n", .{ n, n + 1, head });
    }
    const input = try std.fs.path.join(a, &.{ sb.root, "commits" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = input, .data = import_data.written() });
    const imported = try git.runInRepoScopedWith(a, &.{ "fast-import", "--quiet" }, work, .{ .stdin_path = input });
    try testing.expectEqual(@as(u8, 0), imported.status);
    const listed = try git.runInRepoScoped(a, &.{ "for-each-ref", "--format=%(objectname)", "refs/heads/candidate-*" }, work);
    try testing.expectEqual(@as(u8, 0), listed.status);
    var commits: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, listed.stdout, "\r\n");
    while (lines.next()) |line| try commits.append(a, line);
    try testing.expectEqual(@as(usize, 300), commits.items.len);
    const h: Holdings = .{ .tips = tips };
    const before = proc.spawn_count.load(.monotonic);
    const held = try heldCommits(a, .{ .repo = work }, &h, commits.items);
    const reads = proc.spawn_count.load(.monotonic) - before;
    try testing.expectEqual(@as(u32, 0), held.count());
    try testing.expectEqual(@as(u64, 2), reads);
}

test "heldCommits: a failed local read confirms no candidate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const h: Holdings = .{};
    const held = try heldCommits(a, .{ .repo = sb.root }, &h, &.{"0123456789abcdef0123456789abcdef01234567"});
    try testing.expectEqual(@as(u32, 0), held.count());
}

test "heldCommits: failed ancestry does not erase direct evidence or confirm pending candidates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const head = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "HEAD" }, work)).stdout, "\n");
    const tree = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "HEAD^{tree}" }, work)).stdout, "\n");
    const input = try std.fs.path.join(a, &.{ sb.root, "broken-commit" });
    const data = try std.fmt.allocPrint(a, "tree {s}\nparent 0123456789abcdef0123456789abcdef01234567\nauthor holt-test <test@holt.invalid> 1 +0000\ncommitter holt-test <test@holt.invalid> 1 +0000\n\nbroken parent\n", .{tree});
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = input, .data = data });
    const hashed = try git.runInRepoScopedWith(a, &.{ "hash-object", "-t", "commit", "-w", "--stdin" }, work, .{ .stdin_path = input });
    try testing.expectEqual(@as(u8, 0), hashed.status);
    const broken = std.mem.trim(u8, hashed.stdout, "\r\n");
    var h: Holdings = .{ .tips = &.{head} };
    try h.listed.put(a, head, {});
    const here = try commitsHere(a, .{ .repo = work }, &.{ head, broken });
    try testing.expect(here.contains(broken));
    const held = try heldCommits(a, .{ .repo = work }, &h, &.{ head, broken });
    try testing.expect(held.contains(head));
    try testing.expect(!held.contains(broken));
}

/// Test-only: what `before_reread_for_test` runs (`runSeam`): each command
/// of `seam_steps` with `sh -c`, in the sandbox `seam_sb`'s environment.
var seam_sb: ?*testutil.Sandbox = null;
var seam_steps: []const []const u8 = &.{};

fn runSeam() void {
    const sb = seam_sb orelse return;
    for (seam_steps) |cmd| {
        const res = proc.runEnv(sb.alloc, &.{ "sh", "-c", cmd }, null, &sb.git_env.map) catch continue;
        sb.alloc.free(res.stdout);
        sb.alloc.free(res.stderr);
    }
}

/// Test-only: runs `steps` right before a deleter reads its state again,
/// until `restore`.
const Seam = struct {
    fn install(sb: *testutil.Sandbox, steps: []const []const u8) Seam {
        seam_sb = sb;
        seam_steps = steps;
        before_reread_for_test = runSeam;
        return .{};
    }

    fn restore(_: Seam) void {
        before_reread_for_test = null;
        seam_sb = null;
        seam_steps = &.{};
    }
};

test "repo remove --clone: a ref that moves, a stash made, or a HEAD git cannot read again after the weighing keeps the clone" {
    try skipWithoutLinks();
    const cases = [_][]const u8{
        "git -C '{s}' update-ref refs/heads/moved HEAD",
        "echo more >> '{s}/README' && git -C '{s}' -c user.name=t -c user.email=t@t.invalid stash push -q -- README",
        "echo garbage > '{s}/.git/HEAD'",
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const cmd = try std.mem.replaceOwned(u8, a, case, "{s}", f.clone);
        const seam = Seam.install(&sb, &.{cmd});
        defer seam.restore();

        const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "holt: {s} changed while it was being weighed (a ref or HEAD moved, or git could not read them again); the clone was kept; run the command again\n", .{try q_test(a, f.clone)})));
        try testing.expect(fsutil.exists(try f.path(".git")));
    }
}

test "repo remove --clone: a delete that fails partway says part of the clone may already be gone" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const locked = try f.path("locked");
    const seam = Seam.install(&sb, &.{try std.fmt.allocPrint(a, "mkdir '{s}' && echo x > '{s}/f' && chmod 0500 '{s}'", .{ locked, locked, locked })});
    defer seam.restore();
    defer if (proc.run(a, &.{ "chmod", "0700", locked }, null)) |_| {} else |_| {};

    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "holt: failed to delete {s}: ", .{try fsutil.contractTilde(a, app.envOf_current(), f.clone)})));
    try testing.expect(contains(got.err, "; part of it may already be gone\n"));
}

test "worktree -r: its HEAD moving, or another worktree's per-worktree ref, after the weighing keeps it; another worktree's HEAD moving does not" {
    try skipWithoutLinks();
    const cases = [_]struct { cmd: []const u8, kept: bool }{
        .{ .cmd = "git -C '{w}' -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m moved", .kept = true },
        .{ .cmd = "git -C '{o}' update-ref -d refs/bisect/bad", .kept = true },
        .{ .cmd = "git -C '{o}' checkout -q --detach HEAD~1", .kept = false },
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try setupWithProject(a, &sb);
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "second" });
        try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "main" });
        try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
        try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "feature" });
        const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
        try testing.expectEqual(@as(u8, 0), made.code);
        const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
        const other = try std.fs.path.join(a, &.{ sb.root, "other-worktree" });
        try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", other, "main" });
        try testutil.runGit(&sb, other, &.{ "update-ref", "refs/bisect/bad", "HEAD" });
        const cmd = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, case.cmd, "{w}", wt), "{o}", other);
        const seam = Seam.install(&sb, &.{cmd});
        defer seam.restore();

        const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        if (case.kept) {
            try testing.expectEqual(@as(u8, 1), got.code);
            try testing.expect(contains(got.err, "changed while it was being weighed (a ref or HEAD moved, or git could not read them again); the worktree was kept; run the command again\n"));
            try testing.expect(fsutil.exists(wt));
        } else {
            if (got.code != 0) std.debug.print("{s}\n", .{got.err});
            try testing.expectEqual(@as(u8, 0), got.code);
            try testing.expect(!fsutil.exists(wt));
        }
    }
}

test "repo remove --clone: branch.<b>.pushRemote, then remote.pushDefault, pick the remote a branch's hint pushes to" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |by_default| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const backup = try testutil.makeBareRepo(&sb, "backup.git");
        defer testing.allocator.free(backup);
        try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", backup });
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
        if (by_default) {
            try testutil.runGit(&sb, f.clone, &.{ "config", "remote.pushDefault", "backup" });
        } else try testutil.runGit(&sb, f.clone, &.{ "config", "branch.main.pushRemote", "backup" });

        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "(run: git -C {s} push --recurse-submodules=no -- backup ", .{try q_test(a, f.clone)})));
        try testing.expect(!contains(refused.err, " push origin "));
    }
}

test "repo remove --clone: a remote whose push goes to a URL on this machine, a remote helper, or a mirror too is never a remote a hint pushes to" {
    try skipWithoutLinks();
    const Kind = enum { local, helper, mirror };
    for ([_]Kind{ .local, .helper, .mirror }) |kind| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
        switch (kind) {
            .local, .helper => {
                try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", f.bare });
                try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", if (kind == .local) try bareCopy(&f, "here.git", &.{}) else "testhelper::somewhere" });
            },
            .mirror => try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.mirror", "true" }),
        }

        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        try testing.expect(!contains(refused.err, " push origin"));
        try testing.expect(!contains(refused.err, " push -u origin"));
    }
}

/// Test-only: `settleAll` with `<url>` standing for `url` in each hint.
fn settleWith(f: *const Fixture, leads: []const []const u8, url: []const u8, max: usize) !void {
    var last: []const u8 = "";
    for (0..max) |_| {
        const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        if (got.code == 0) return;
        last = got.err;
        const lead = for (leads) |l| {
            if (contains(got.err, l)) break l;
        } else break;
        try runHint(f, got.err, lead, url);
    }
    std.debug.print("still refused:\n{s}\n", .{last});
    return error.TestUnexpectedResult;
}

/// A loopback listener that answers every request "404 Not Found", so a
/// query of it fails for good.
fn missingServer(stub: *testutil.LoopbackStub) !void {
    try stub.start("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
}

/// Test-only: runs `f`'s clone's `repo remove --clone --yes` until it
/// passes, running each time the hint of the first line naming one of
/// `leads`; fails when a run names none of them, or after `max` runs.
fn settleAll(f: *const Fixture, leads: []const []const u8, max: usize) !void {
    var last: []const u8 = "";
    for (0..max) |_| {
        const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        if (got.code == 0) return;
        last = got.err;
        const lead = for (leads) |l| {
            if (contains(got.err, l)) break l;
        } else {
            std.debug.print("no hint to run in:\n{s}\n", .{got.err});
            return error.TestUnexpectedResult;
        };
        try runHint(f, got.err, lead, "");
    }
    std.debug.print("still refused after {d} runs:\n{s}\n", .{ max, last });
    return error.TestUnexpectedResult;
}

test "repo remove --clone: a new branch keeps its name on the target, the target's HEAD branch and every tag go under holt-kept/, and each hint settles its line" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try q_test(a, f.clone);
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "main ahead" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "-c", "feature" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "feature only" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "light" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "annotated only" });
    try testutil.runGit(&sb, f.clone, &.{ "tag", "-a", "-m", "note", "noted" });
    try testutil.runGit(&sb, f.clone, &.{ "reset", "-q", "--hard", "HEAD~2" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    for ([_][]const u8{
        "commits of branch feature no remote has, in {s} (run: git -C {s} push --recurse-submodules=no -- origin refs/heads/feature:refs/heads/feature)",
        "commits of branch main no remote has, in {s} (run: git -C {s} push --recurse-submodules=no -- origin refs/heads/main:refs/heads/holt-kept/main)",
        "commits only refs/tags/light holds, no remote has, in {s} (run: git -C {s} push --recurse-submodules=no -- origin refs/tags/light:refs/tags/holt-kept/tags/light)",
        "the tag only refs/tags/noted names, no remote has, in {s} (run: git -C {s} push --recurse-submodules=no -- origin refs/tags/noted:refs/tags/holt-kept/tags/noted)",
    }) |want| {
        const line = try std.mem.replaceOwned(u8, a, want, "{s}", cq);
        if (!contains(refused.err, line)) {
            std.debug.print("wanted {s} in:\n{s}\n", .{ line, refused.err });
            return error.TestUnexpectedResult;
        }
    }
    try settleAll(&f, &.{ "commits of branch", "branch feature no remote has", "commits only", "the tag only" }, 6);
}

test "repo remove --clone: with a listed Holt-Kept/main on the target, the ahead main goes to holt-kept/main-2; a listed tag with another commit, and an empty target, go under holt-kept/" {
    try skipWithoutLinks();
    for ([_]u8{ 0, 1, 2 }) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const cq = try q_test(a, f.clone);
        var want: []const u8 = undefined;
        switch (case) {
            0 => {
                try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "main:refs/heads/Holt-Kept/main" });
                try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "main ahead" });
                want = "push --recurse-submodules=no -- origin refs/heads/main:refs/heads/holt-kept/main-2)";
            },
            1 => {
                try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "theirs" });
                try testutil.runGit(&sb, f.clone, &.{ "tag", "v1" });
                try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "v1" });
                try testutil.runGit(&sb, f.clone, &.{ "reset", "-q", "--hard", "HEAD~1" });
                try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "ours" });
                try testutil.runGit(&sb, f.clone, &.{ "tag", "-f", "v1" });
                try testutil.runGit(&sb, f.clone, &.{ "reset", "-q", "--hard", "HEAD~1" });
                want = "push --recurse-submodules=no -- origin refs/tags/v1:refs/tags/holt-kept/tags/v1)";
            },
            else => {
                const empty = try std.fs.path.join(a, &.{ sb.root, "empty.git" });
                try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", empty });
                try testutil.markElsewhere(empty);
                try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", empty });
                want = "push --recurse-submodules=no -- origin refs/heads/main:refs/heads/holt-kept/main)";
            },
        }
        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        const line = try std.fmt.allocPrint(a, "(run: git -C {s} {s}", .{ cq, want });
        if (!contains(refused.err, line)) {
            std.debug.print("wanted {s} in:\n{s}\n", .{ line, refused.err });
            return error.TestUnexpectedResult;
        }
        try settleAll(&f, &.{ "commits of branch", "commits only" }, 4);
    }
}

test "repo remove --clone: a hint pushes to a remote named -x, and a full source and destination land where named whatever remote.<n>.push says" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |dashed| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "-c", "feature" });
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "feature only" });
        if (dashed) {
            try testutil.runGit(&sb, f.clone, &.{ "config", "remote.-x.url", f.bare });
            try testutil.runGit(&sb, f.clone, &.{ "config", "remote.-x.fetch", "+refs/heads/*:refs/remotes/-x/*" });
            try testutil.runGit(&sb, f.clone, &.{ "config", "--unset", "remote.origin.url" });
            try testutil.runGit(&sb, f.clone, &.{ "config", "--remove-section", "remote.origin" });
        } else try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.push", "refs/heads/*:refs/for/*" });
        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        try testing.expect(contains(refused.err, if (dashed) " push --recurse-submodules=no -- -x refs/heads/feature:" else " push --recurse-submodules=no -- origin refs/heads/feature:refs/heads/feature)"));
        try settleAll(&f, &.{ "commits of branch feature", "branch feature no remote has", "branch main no remote has" }, 5);
    }
}

test "repo remove --clone: the stale refs of one remote under refs/remotes are one line, and its one push settles them" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "upstream", try std.fs.path.join(a, &.{ sb.root, "gone.git" }) });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    for (1..6) |n| {
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", try std.fmt.allocPrint(a, "stale {d}", .{n}) });
        try testutil.runGit(&sb, f.clone, &.{ "update-ref", try std.fmt.allocPrint(a, "refs/remotes/upstream/b{d}", .{n}), "HEAD" });
    }
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expectEqual(@as(usize, 1), count(refused.err, "commits only 5 refs of remote upstream hold, no remote has, in "));
    try testing.expect(contains(refused.err, ": refs/remotes/upstream/b1, refs/remotes/upstream/b2, refs/remotes/upstream/b3, and 2 more (run: "));
    try testing.expect(!contains(refused.err, "commits only refs/remotes/"));
    try settleAll(&f, &.{"commits only 5 refs of remote upstream hold"}, 2);
}

test "worktree -r: a HEAD and a per-worktree ref no remote has are kept by refs the removal leaves, whatever the remote says" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    const port = try closedPort();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{port}) });
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    const wq = try q_test(a, wt);
    try testutil.runGit(&sb, wt, &.{ "checkout", "-q", "--detach" });
    try testutil.runGit(&sb, wt, &.{ "commit", "-q", "--allow-empty", "-m", "wip" });
    try testutil.runGit(&sb, wt, &.{ "update-ref", "refs/worktree/wip", "HEAD" });
    try testutil.runGit(&sb, wt, &.{ "commit", "-q", "--allow-empty", "-m", "head" });
    const head = std.mem.trim(u8, (try (At{ .repo = wt }).run(a, &.{ "rev-parse", "HEAD" })).stdout, "\r\n");
    const wip = std.mem.trim(u8, (try (At{ .repo = wt }).run(a, &.{ "rev-parse", "refs/worktree/wip" })).stdout, "\r\n");
    const refused = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "(run: git -C {s} branch holt-kept/head-{s} {s})", .{ wq, head[0..12], head })));
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "(run: git -C {s} update-ref refs/holt-kept/feature/worktree/wip {s})", .{ wq, wip })));
    try runHint(&f, refused.err, "which only the HEAD of worktree", "");
    try runHint(&f, refused.err, "commits only refs/worktree/wip", "");
    const after = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expect(!contains(after.err, "which only the HEAD of worktree"));
}

test "gitRisks: a fetch URL that holds a commit is a witness, though its remote's push URL is on this machine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try testutil.runGit(&sb, work, &.{ "config", "remote.origin.pushurl", try std.fs.path.join(a, &.{ sb.root, "here.git" }) });
    for (try gitRisks(try testAsker(a), work)) |r| switch (r.what) {
        .ahead, .ref_unheld, .object_unheld, .remote_refs, .head_unheld, .unasked => {
            std.debug.print("held by the fetch URL, yet at risk: {s} {s}\n", .{ @tagName(r.what), r.name });
            return error.TestUnexpectedResult;
        },
        else => {},
    };
}

test "repo remove --clone: with origin holding everything, a backup URL is never asked" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    var silent: testutil.LoopbackStub = undefined;
    try silent.start("");
    defer silent.stop();
    const elsewhere = try Elsewhere.ports(a, &.{silent.port()});
    defer elsewhere.restore();
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{silent.port()}) });
    ask_limit_for_test = 3;
    defer ask_limit_for_test = null;
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(u32, 0), silent.count());
}

test "gitRisks: a remote with remote.<name>.vcs set is never asked, and no URL naming a remote that has one runs its helper" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const mark = try std.fs.path.join(a, &.{ sb.root, "helper-ran" });
    const helper = try std.fs.path.join(a, &.{ sb.root, "git-remote-probe" });
    try testutil.writeExecutable(helper, try std.fmt.allocPrint(a, "#!/bin/sh\necho ran >> '{s}'\nexit 1\n", .{mark}));
    const old_path = std.process.Environ.getPosix(std.Io.Threaded.global_single_threaded.environ.process_environ, "PATH") orelse "/usr/bin:/bin";
    const path_scope = try testutil.EnvOverride.install(a, "PATH", try std.mem.concat(a, u8, &.{ sb.root, ":", old_path }));
    defer path_scope.restore();
    var server: testutil.LoopbackStub = undefined;
    try server.start("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    defer server.stop();
    const elsewhere = try Elsewhere.ports(a, &.{server.port()});
    defer elsewhere.restore();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{server.port()});
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    try testutil.runGit(&sb, work, &.{ "remote", "add", "probe", url });
    try testutil.runGit(&sb, work, &.{ "config", "remote.probe.vcs", "probe" });
    _ = try gitRisks(try testAsker(a), work);
    try testing.expect(!fsutil.exists(mark));
    try testing.expectEqual(@as(u32, 0), server.count());

    try testutil.runGit(&sb, work, &.{ "config", try std.fmt.allocPrint(a, "remote.{s}.vcs", .{url}), "probe" });
    try testutil.runGit(&sb, work, &.{ "config", try std.fmt.allocPrint(a, "remote.{s}.url", .{url}), url });
    try testutil.runGit(&sb, work, &.{ "remote", "add", "web", url });
    const answer = try (try testAsker(a)).ask(.{ .repo = work }, try scopeOf(a, .{ .repo = work }), "web", url, &.{});
    try testing.expect(answer == .unasked);
    try testing.expect(!fsutil.exists(mark));
}

test "repo remove --clone: a branch with no upstream whose commit a remote holds does not refuse" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "--no-track", "copy", "main" });
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    if (got.code != 0) std.debug.print("{s}\n", .{got.err});
    try testing.expectEqual(@as(u8, 0), got.code);
}

test "repo remove --clone: a target's push URL that does not answer takes only the refs pushed to that target; another target's push line stays" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const port = try closedPort();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{port}) });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "main only here" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "-c", "side" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "side only here" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "config", "branch.side.pushRemote", "backup" });
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, "commits of branch main no remote that answered has, in "));
    try testing.expect(contains(refused.err, " push --recurse-submodules=no -- origin refs/heads/main:refs/heads/holt-kept/main)"));
    try testing.expect(contains(refused.err, "1 ref not confirmed held, in "));
    try testing.expect(contains(refused.err, ": refs/heads/side (remote backup could not be asked at "));
}

test "worktree -r: a HEAD a tag holds, and a per-worktree ref kept by the hinted update-ref, do not refuse" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try testutil.runGit(&sb, wt, &.{ "checkout", "-q", "--detach" });
    try testutil.runGit(&sb, wt, &.{ "commit", "-q", "--allow-empty", "-m", "wip" });
    try testutil.runGit(&sb, wt, &.{ "update-ref", "refs/worktree/wip", "HEAD" });
    try testutil.runGit(&sb, wt, &.{ "reset", "-q", "--hard", "HEAD~1" });
    try testutil.runGit(&sb, wt, &.{ "commit", "-q", "--allow-empty", "-m", "tagged" });
    try testutil.runGit(&sb, wt, &.{ "tag", "kept-head" });
    const refused = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(!contains(refused.err, "which only the HEAD of worktree"));
    try runHint(&f, refused.err, "commits only refs/worktree/wip", "");
    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    if (got.code != 0) std.debug.print("{s}\n", .{got.err});
    try testing.expectEqual(@as(u8, 0), got.code);
}

/// Test-only: `runHint` with `<url>` standing for `url`, and, when `drop`
/// is set, an editor that deletes each line matching it.
fn runHintEditing(f: *const Fixture, text: []const u8, lead: []const u8, url: []const u8, drop: ?[]const u8) !void {
    if (drop) |d| try f.sb.git_env.map.put("GIT_EDITOR", try std.fmt.allocPrint(f.a, "sed -i.orig '/{s}/d'", .{d}));
    defer if (drop != null) {
        _ = f.sb.git_env.map.swapRemove("GIT_EDITOR");
    };
    try runHint(f, text, lead, url);
}

test "repo remove --clone: a push URL that does not answer for good, with no other, is replaced, its value removed from the file that holds it, and the next weighing names no URL that did not answer" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try q_test(a, f.clone);
    const offline = try std.fs.path.join(a, &.{ f.bare, "offline.git" });
    const inc = try std.fs.path.join(a, &.{ sb.root, "inc.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = inc, .data = try std.fmt.allocPrint(a, "[remote \"origin\"]\n\tpushurl = {s}\n", .{offline}) });
    try testutil.runGit(&sb, f.clone, &.{ "config", "include.path", inc });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    const backup = try testutil.makeBareRepo(&sb, "backup.git");
    defer testing.allocator.free(backup);

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const want = try std.fmt.allocPrint(a, "(remote origin could not be asked at {s}: repository not found); replace this push URL (run: git config --file {s} --fixed-value --unset-all remote.origin.pushurl {s} && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine), or --force deletes it\n", .{ offline, try q_test(a, try fsutil.realPathOrSelf(a, inc)), offline, cq });
    if (!contains(refused.err, want)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ want, refused.err });
        return error.TestUnexpectedResult;
    }
    try runHint(&f, refused.err, "(remote origin could not be asked at ", backup);
    const next = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), next.code);
    try testing.expect(!contains(next.err, "could not be asked"));
    try runHint(&f, next.err, "commits of branch main no remote has", "");
    try testing.expectEqual(@as(u8, 0), (try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" })).code);
}

test "repo remove --clone: a push URL whose value two files hold is removed from each, the global file's with its note, when the target's other push URL answered" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try q_test(a, f.clone);
    const offline = try std.fs.path.join(a, &.{ f.bare, "offline.git" });
    const global = try std.fs.path.join(a, &.{ sb.root, "global.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = global, .data = try std.fmt.allocPrint(a, "[remote \"origin\"]\n\tpushurl = {s}\n", .{offline}) });
    const env = try testutil.EnvOverride.install(a, "GIT_CONFIG_GLOBAL", global);
    defer env.restore();
    try f.sb.git_env.map.put("GIT_CONFIG_GLOBAL", global);
    defer _ = f.sb.git_env.map.swapRemove("GIT_CONFIG_GLOBAL");
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", offline });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", f.bare });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const gq = try q_test(a, try fsutil.realPathOrSelf(a, global));
    const want = try std.fmt.allocPrint(a, "remove that URL (run: git config --file {s} --fixed-value --unset-all remote.origin.pushurl {s} && git -C {s} config --local --fixed-value --unset-all remote.origin.pushurl {s}) (in {s}, which changes every repository), or --force deletes it\n", .{ gq, offline, cq, offline, try fsutil.contractTilde(a, app.envOf_current(), try fsutil.realPathOrSelf(a, global)) });
    if (!contains(refused.err, want)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ want, refused.err });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 1), count(refused.err, "not confirmed held"));
    try settleAll(&f, &.{ "(remote origin could not be asked at ", "commits of branch main" }, 4);
}

test "repo remove --clone: a push URL read from a value that can be read two ways is removed by editing, never printed" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try q_test(a, f.clone);
    const offline = try std.fs.path.join(a, &.{ f.bare, "offline" });
    try testutil.runGit(&sb, f.clone, &.{ "config", try std.fmt.allocPrint(a, "url.{s}/.insteadOf", .{offline}), "http://alice:AB/CD@nowhere.invalid/" });
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", "http://alice:AB/CD@nowhere.invalid/x.git" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(!contains(refused.err, "AB/CD") and !contains(refused.err, "alice"));
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "edit remote.origin.pushurl to replace this push URL (run: git -C {s} config --local --edit && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine)", .{ cq, cq })));
    try runHintEditing(&f, refused.err, "(remote origin could not be asked at ", f.bare, "AB\\/CD");
    try settleAll(&f, &.{"commits of branch main"}, 3);
}

test "repo remove --clone: two push URLs that do not answer for good, beside one that answers or none, are each replaced or removed a step at a time" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |one_answers| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        if (one_answers) try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", f.bare });
        for ([_][]const u8{ "offline-1.git", "offline-2.git" }) |n| try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", try std.fs.path.join(a, &.{ f.bare, n }) });
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });

        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        try testing.expectEqual(@as(usize, 2), count(refused.err, "; replace this push URL (run: "));
        try testing.expect(!contains(refused.err, "remove that URL"));
        try runHint(&f, refused.err, "offline-1.git: repository not found)", f.bare);
        const next = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), next.code);
        try testing.expectEqual(@as(usize, 1), count(next.err, "; remove that URL (run: "));
        try testing.expect(!contains(next.err, "offline-1.git"));
        try settleAll(&f, &.{ "offline-2.git: repository not found)", "commits of branch main" }, 4);
    }
}

test "repo remove --clone: a push URL that gives no answer names only the ways out, and a URL of no target that did not answer is noted beside it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cq = try q_test(a, f.clone);
    const port = try closedPort();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{port});
    const backup = try std.fs.path.join(a, &.{ f.bare, "backup-offline.git" });
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", url });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", backup });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "(remote origin could not be asked at {s}: connection refused); reconnect and run again, or --force deletes it\n", .{url})));
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "  could not be asked, in {s}: remote backup at {s} (repository not found)\n", .{ cq, backup })));
}

/// Test-only: whether git lists the empty URL of origin of `clone` among
/// its push URLs, as git before 2.46 does, rather than taking it to
/// clear the URLs before it.
fn listsEmptyUrl(a: std.mem.Allocator, clone: []const u8) !bool {
    const listed = try git.runInRepoScoped(a, &.{ "remote", "get-url", "--push", "--all", "--", "origin" }, clone);
    if (listed.status != 0) return false;
    for (try urlLines(a, listed.stdout)) |u| if (u.len == 0) return true;
    return false;
}

test "urlLines: every line is a URL, an empty one too, wherever it is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try urlLines(a, "")).len);
    const cases = [_]struct { out: []const u8, want: []const []const u8 }{
        .{ .out = "\n", .want = &.{""} },
        .{ .out = "/srv/o.git\n", .want = &.{"/srv/o.git"} },
        .{ .out = "/srv/o.git\r\n\r\n", .want = &.{ "/srv/o.git", "" } },
        .{ .out = "/srv/o.git\n\n", .want = &.{ "/srv/o.git", "" } },
        .{ .out = "\n/srv/o.git\n", .want = &.{ "", "/srv/o.git" } },
    };
    for (cases) |c| {
        const got = try urlLines(a, c.out);
        try testing.expectEqual(c.want.len, got.len);
        for (c.want, got) |w, g| try testing.expectEqualStrings(w, g);
    }
}

test "repo remove --clone: with no push target, one line names every ref, why each remote counts as no copy, and one command, which settles it" {
    try skipWithoutLinks();
    const Case = enum { lone_empty, url_then_empty, local_pushurl, pushinsteadof_mirror, bundle };
    for ([_]Case{ .lone_empty, .url_then_empty, .local_pushurl, .pushinsteadof_mirror, .bundle }) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const cq = try q_test(a, f.clone);
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
        var way: []const u8 = undefined;
        switch (case) {
            .lone_empty => {
                try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.url", "" });
                way = try std.fmt.allocPrint(a, "remote origin {s}; remove the empty URL (run: git -C {s} config --local --unset-all remote.origin.url '^$' && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine)", .{ if (try listsEmptyUrl(a, f.clone)) "has an empty URL" else "has no URL", cq, cq });
            },
            .url_then_empty => {
                try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.url", "" });
                // Where git lists the empty URL, it keeps the URL before
                // it, which answered, so removing the empty one is enough.
                way = if (try listsEmptyUrl(a, f.clone))
                    try std.fmt.allocPrint(a, "remote origin has an empty URL; remove the empty URL (run: git -C {s} config --local --unset-all remote.origin.url '^$'), or ", .{cq})
                else
                    try std.fmt.allocPrint(a, "remote origin has no URL; remove the empty URL (run: git -C {s} config --local --unset-all remote.origin.url '^$' && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine)", .{ cq, cq });
            },
            .local_pushurl => {
                const here = try bareCopy(&f, "here.git", &.{});
                try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", here });
                way = try std.fmt.allocPrint(a, "remote origin has its push URLs on this machine ({s}); replace its push URLs (run: git -C {s} config --local --fixed-value --unset-all remote.origin.pushurl {s})", .{ here, cq, here });
            },
            .pushinsteadof_mirror => {
                const here = try bareCopy(&f, "here.git", &.{});
                const mirror = try bareCopy(&f, "mirror.git", &.{});
                try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", here });
                try testutil.runGit(&sb, f.clone, &.{ "config", try std.fmt.allocPrint(a, "url.{s}.pushInsteadOf", .{mirror}), f.bare });
                way = try std.fmt.allocPrint(a, "remote origin has its push URLs on this machine ({s}); replace its push URLs (run: git -C {s} config --local --fixed-value --unset-all remote.origin.pushurl {s} && git -C {s} config --local --add remote.origin.pushurl <url>, with <url> a URL on another machine)", .{ here, cq, here, cq });
            },
            .bundle => {
                const bundle = try std.fs.path.join(a, &.{ sb.root, "only.bundle" });
                try testutil.runGit(&sb, f.clone, &.{ "bundle", "create", "-q", bundle, "main" });
                _ = try setOrigin(&f, bundle);
                way = try std.fmt.allocPrint(a, "remote origin is on this machine ({s}); add a remote on another machine (run: git -C {s} remote add holt-kept <url>, with <url> a URL on another machine)", .{ bundle, cq });
            },
        }
        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, " no remote on another machine ", .{})));
        try testing.expect(contains(refused.err, "; no remote counts as a copy: "));
        if (!contains(refused.err, way)) {
            std.debug.print("{s}: wanted {s} in:\n{s}\n", .{ @tagName(case), way, refused.err });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(@as(usize, 1), count(refused.err, "no remote counts as a copy"));
        try settleWith(&f, &.{ "no remote counts as a copy", "commits of branch main no remote has" }, f.bare, 4);
    }
}

test "archive --prune: clones a host that is not found held back are named once, after the last clone, and no asking line is printed" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const names = [_][]const u8{ "widget", "gadget", "gizmo" };
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (names) |n| {
        const url = try std.fmt.allocPrint(a, "https://holt-test.invalid/acme/{s}", .{n});
        try repos.put(a, n, url);
        const path = try fsutil.joinSlashy(a, f.ws.cfg.code_root, try std.fmt.allocPrint(a, "holt-test.invalid/acme/{s}", .{n}));
        if (!std.mem.eql(u8, n, "widget")) try testutil.runGit(&sb, null, &.{ "clone", "-q", f.bare, path });
        try testutil.runGit(&sb, path, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
        try testutil.runGit(&sb, path, &.{ "remote", "set-url", "origin", try std.fmt.allocPrint(a, "ssh://127.0.0.1/acme/{s}.git", .{n}) });
    }
    try testutil.writeMarker(a, try f.ws.projectsRoot(a), "acme", "proj", repos, .empty);
    const script = try std.fs.path.join(a, &.{ sb.root, "lost-ssh" });
    try testutil.writeExecutable(script, "#!/bin/sh\necho 'ssh: Could not resolve hostname 127.0.0.1: nodename nor servname provided, or not known' >&2\nexit 255\n");
    const ssh = try testutil.EnvOverride.install(a, "GIT_SSH_COMMAND", script);
    defer ssh.restore();
    const elsewhere = try Elsewhere.ports(a, &.{22});
    defer elsewhere.restore();
    ui.stderr_terminal_for_test = true;
    defer ui.stderr_terminal_for_test = null;

    const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!contains(got.err, "asking "));
    try testing.expect(!contains(got.out, "not asked: "));
    try testing.expectEqual(@as(usize, 1), count(got.out, "127.0.0.1 did not answer, so 2 clones were not asked and not pruned: "));
    try testing.expectEqual(@as(usize, 1), count(got.out, ": host not found)"));
}

test "counts: a URL whose authority holds a bracket that does not open its host, which git passes to ssh or looks up otherwise than it reads, never counts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const at: At = .{ .repo = "/" };
    for ([_][]const u8{
        "[alice@localhost]:repo",
        "[localhost]@elsewhere.invalid:repo",
        "ssh://[alice@localhost]/repo",
        "ssh://[localhost]@elsewhere.invalid/repo",
        "alice@[localhost]@elsewhere.invalid:repo",
        "git://[localhost]@elsewhere.invalid/repo",
    }) |url| {
        if (try counts(a, at, url)) {
            std.debug.print("counts: {s}\n", .{url});
            return error.TestUnexpectedResult;
        }
        try testing.expect(remote_url.parse(url).ambiguous);
    }
}

test "heldCommits: weighing writes no file, so a temporary directory that cannot be written to changes nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const base = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "HEAD" }, work)).stdout, "\n");
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "--allow-empty", "-m", "on top" });
    const tip = std.mem.trim(u8, (try git.runInRepoScoped(a, &.{ "rev-parse", "HEAD" }, work)).stdout, "\n");
    const tmp = try std.fs.path.join(a, &.{ sb.root, "no-such-tmp" });
    const over = try testutil.EnvOverride.install(a, "TMPDIR", tmp);
    defer over.restore();
    var h: Holdings = .{};
    try h.listed.put(a, tip, {});
    h.tips = &.{tip};
    const held = try heldCommits(a, .{ .repo = work }, &h, &.{base});
    try testing.expect(held.contains(base));
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(tmp));
}

test "gitRisks: two repositories weighed in one pass, whose configuration sends one URL to different remotes, are each answered by their own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_a = try testutil.makeBareRepo(&sb, "a/remote.git");
    defer testing.allocator.free(bare_a);
    const bare_b = try std.fs.path.join(a, &.{ sb.root, "b", "remote.git" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", bare_a, bare_b });
    try testutil.markElsewhere(bare_b);
    const work_a = try std.fs.path.join(a, &.{ sb.root, "a", "work" });
    const work_b = try std.fs.path.join(a, &.{ sb.root, "b", "work" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", bare_a, work_a });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", bare_b, work_b });
    for ([_][]const u8{ work_a, work_b }) |w| try testutil.runGit(&sb, w, &.{ "remote", "set-url", "origin", "../remote.git" });
    try testutil.runGit(&sb, work_b, &.{ "commit", "-q", "--allow-empty", "-m", "only on a" });
    try testutil.runGit(&sb, work_b, &.{ "push", "-q", bare_a, "HEAD:refs/heads/from-b" });
    const asker = try testAsker(a);
    try testing.expectEqual(@as(usize, 0), (try gitRisks(asker, work_a)).len);
    const risks = try gitRisks(asker, work_b);
    try testing.expect(risks.len > 0 and risks[0].what == .ahead);
}

test "worktree -r: with nothing at risk once the refs that survive are counted, no remote is asked" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    var silent: testutil.LoopbackStub = undefined;
    try silent.start("");
    defer silent.stop();
    const elsewhere = try Elsewhere.ports(a, &.{silent.port()});
    defer elsewhere.restore();
    ask_limit_for_test = 3;
    defer ask_limit_for_test = null;
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    try testing.expectEqual(@as(u8, 0), made.code);
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try testutil.runGit(&sb, wt, &.{ "commit", "-q", "--allow-empty", "-m", "on feature only" });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{silent.port()}) });

    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(u32, 0), silent.count());
    try testing.expect(!contains(got.err, "waiting for "));

    const empty = try std.fs.path.join(a, &.{ sb.root, "empty" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", empty });
    try testutil.runGit(&sb, empty, &.{ "remote", "add", "origin", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/empty.git", .{silent.port()}) });
    try testing.expectEqual(@as(usize, 0), (try gitRisks(try testAsker(a), empty)).len);
    try testing.expectEqual(@as(u32, 0), silent.count());
}

test "riskLine: a HEAD of the main working tree names the repository as its holder, and git state that could not be read names only --force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = null, .out = &out.writer, .err = &out.writer, .argv = &.{} };
    const repo = "/srv/code/widget";
    const c = "0123456789abcdef0123456789abcdef01234567";
    const head: Risk = .{ .what = .head_unheld, .name = c, .src = c, .remote = "origin", .dst = "refs/heads/holt-kept/head-0123456789ab" };
    try testing.expectEqualStrings("commit 0123456789abcdef0123456789abcdef01234567, which only the HEAD of /srv/code/widget holds and no remote has (run: git -C /srv/code/widget push --recurse-submodules=no -- origin 0123456789abcdef0123456789abcdef01234567:refs/heads/holt-kept/head-0123456789ab)", try riskLine(&ctx, .{ .repo = repo, .risk = head }, "--force"));
    const unreadable: Risk = .{ .what = .unreadable };
    try testing.expectEqualStrings("git state of /srv/code/widget could not be read; holt repo remove widget --clone --force deletes it", try riskLine(&ctx, .{ .repo = repo, .risk = unreadable }, "holt repo remove widget --clone --force"));
}

test "riskLine: a removal whose value holds a control character opens the file in an editor and never prints the value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = null, .out = &out.writer, .err = &out.writer, .argv = &.{} };
    const value = "git://elsewhere.invalid/a\x1b[2Jb.git";
    const values = [_]Configured{.{ .value = value }};
    const risk: Risk = .{ .what = .unasked, .remote = "origin", .url = value, .why = "repository not found", .refs = &.{"refs/heads/main"}, .class = .persistent, .values = &values, .pushurl = true, .mapped = true, .others_answered = true };
    const line = try riskLine(&ctx, .{ .repo = "/srv/code/widget", .risk = risk }, "--force");
    try testing.expect(std.mem.indexOfScalar(u8, line, 0x1b) == null);
    try testing.expect(contains(line, "; edit remote.origin.pushurl to remove that URL (run: git -C /srv/code/widget config --local --edit), or --force deletes it"));
}

test "riskLine: a host key that was not verified is settled by verifying it, never by replacing the URL, on its first line as on a skipped one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = null, .out = &out.writer, .err = &out.writer, .argv = &.{} };
    const failed = try queryFailure(a, "Host key verification failed.\r\nfatal: Could not read from remote repository.\n", 128);
    try testing.expectEqual(Class.host_key, failed.class);
    const url = "ssh://badkey.invalid:2222/acme/widget.git";
    const values = [_]Configured{.{ .value = url }};
    const risk: Risk = .{ .what = .unasked, .remote = "origin", .url = url, .why = failed.why, .refs = &.{"refs/heads/main"}, .class = failed.class, .values = &values, .mapped = true };
    try testing.expectEqualStrings("1 ref not confirmed held, in /srv/code/widget: refs/heads/main (remote origin could not be asked at ssh://badkey.invalid:2222/acme/widget.git: host key not verified); verify the host key of badkey.invalid:2222 and run again, or --force deletes it", try riskLine(&ctx, .{ .repo = "/srv/code/widget", .risk = risk }, "--force"));
}

test "repo remove --clone: the closing --force line is printed only when some line does not name --force" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const footer = "or, to set aside what can be and delete the rest: ";
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "not pushed yet" });
    const pushable = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), pushable.code);
    try testing.expect(contains(pushable.err, "(run: git -C "));
    try testing.expect(contains(pushable.err, footer));

    const port = try closedPort();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", try std.fmt.allocPrint(a, "git://127.0.0.1:{d}/acme/widget.git", .{port}) });
    const offline = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), offline.code);
    try testing.expect(contains(offline.err, ": connection refused); reconnect and run again, or --force deletes them\n"));
    try testing.expect(!contains(offline.err, footer));
}

test "repo remove --clone: the push URLs of one remote on one host that did not answer, holding back the same refs, are named on one line" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const port = try closedPort();
    const elsewhere = try Elsewhere.ports(a, &.{port});
    defer elsewhere.restore();
    const first = try std.fmt.allocPrint(a, "git://127.0.0.1:{d}/acme/a.git", .{port});
    const second = try std.fmt.allocPrint(a, "git://127.0.0.1:{d}/acme/b.git", .{port});
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", first });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", second });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "not pushed yet" });
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expectEqual(@as(usize, 1), count(got.err, "not confirmed held"));
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "(remote origin could not be asked at {s}, {s}: connection refused); reconnect and run again, or --force deletes it\n", .{ first, second })));
}

test "repo remove --clone: each linked worktree is named with the command that removes it, git worktree remove for one whose directory is gone, which removes that record alone, and running them lets the delete through" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const live = try std.fs.path.join(a, &.{ sb.root, "live-wt" });
    const gone = try std.fs.path.join(a, &.{ sb.root, "gone-wt" });
    const also = try std.fs.path.join(a, &.{ sb.root, "also-gone-wt" });
    for ([_][]const u8{ live, gone, also }) |wt| try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
    try std.Io.Dir.cwd().deleteTree(io(), gone);
    try std.Io.Dir.cwd().deleteTree(io(), also);
    const cq = try q_test(a, f.clone);
    const records = try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees" });

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "(run: git -C {s} worktree remove {s})", .{ cq, try q_test(a, try fsutil.realPathOrSelf(a, live)) })));
    for ([_][]const u8{ gone, also }) |wt| try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, ", which is gone (run: git -C {s} worktree remove {s})", .{ cq, try q_test(a, try resolvedPath(a, wt)) })));
    try testing.expect(!contains(refused.err, "worktree prune"));
    try runHint(&f, refused.err, "/gone-wt, which is gone", "");
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try std.fs.path.join(a, &.{ records, "gone-wt" })));
    for ([_][]const u8{ "live-wt", "also-gone-wt" }) |id| try testing.expectEqual(kept.content.Entry.dir, try kept.content.entryAt(try std.fs.path.join(a, &.{ records, id })));
    try runHint(&f, refused.err, "live-wt", "");
    try runHint(&f, refused.err, "/also-gone-wt, which is gone", "");
    const after = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(!contains(after.err, "other worktree"));
    try testing.expectEqual(@as(u8, 0), after.code);
}

test "repo remove --clone: two records naming one path, as a copied record leaves, are named once with what is seen there and git worktree list alone, never git worktree remove, which may reach either, or a record's removal, leaving both as they were; once the user removes the copy, the one left is named with its removal, which lets the delete through" {
    try skipWithoutLinks();
    const Case = enum { own_first, copy_first, gone };
    for (std.enums.values(Case)) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const wt = try std.fs.path.join(a, &.{ sb.root, "shared-wt" });
        try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
        const records = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees" }));
        const own = try std.fs.path.join(a, &.{ records, "shared-wt" });
        const copy = try std.fs.path.join(a, &.{ records, if (case == .copy_first) "a-copy" else "z-copy" });
        const cp = try proc.runEnv(a, &.{ "cp", "-R", own, copy }, null, &sb.git_env.map);
        try testing.expectEqual(@as(u8, 0), cp.status);
        if (case == .gone) try std.Io.Dir.cwd().deleteTree(io(), wt);
        const cq = try q_test(a, f.clone);
        const roots: []const []const u8 = &.{ records, wt };
        const before = try treesState(a, roots);

        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        try expectUnresolved(&f, refused.err, try resolvedPath(a, wt), shared_seen, try std.fmt.allocPrint(a, "git -C {s}", .{cq}));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, refused.err, shared_seen));
        try testing.expectEqualStrings(before, try treesState(a, roots));

        try std.Io.Dir.cwd().deleteTree(io(), copy);
        const next = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        const line = try std.fmt.allocPrint(a, "/shared-wt{s} (run: git -C {s} worktree remove {s})\n", .{ if (case == .gone) ", which is gone" else "", cq, try q_test(a, try resolvedPath(a, wt)) });
        if (next.code != 1 or !contains(next.err, line)) {
            std.debug.print("{s}: wanted {s} in:\n{s}\n", .{ @tagName(case), line, next.err });
            return error.TestUnexpectedResult;
        }
        try runHint(&f, next.err, line[0..std.mem.indexOf(u8, line, "(run: ").?], "");
        try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(own));
        const after = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expect(!contains(after.err, "other worktree"));
        try testing.expectEqual(@as(u8, 0), after.code);
    }
}

test "worktree -r: two records naming one path, as a copied record leaves, refuse the removal, even with --force, before anything is weighed, set aside, or removed, naming what is seen there and git worktree list alone and leaving both records and the tree as they were; once the user removes the copy, the removal removes the one left" {
    try skipWithoutLinks();
    const Case = struct { copy: []const u8, gone: bool };
    for ([_]Case{
        .{ .copy = "a-copy", .gone = false },
        .{ .copy = "z-copy", .gone = false },
        .{ .copy = "a-copy", .gone = true },
        .{ .copy = "z-copy", .gone = true },
    }) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try setupWithProject(a, &sb);
        try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
        const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
        try testing.expectEqual(@as(u8, 0), made.code);
        const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
        const records = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees" }));
        const own = try std.fs.path.join(a, &.{ records, "feature" });
        const copy = try std.fs.path.join(a, &.{ records, case.copy });
        const cp = try proc.runEnv(a, &.{ "cp", "-R", own, copy }, null, &sb.git_env.map);
        try testing.expectEqual(@as(u8, 0), cp.status);
        if (case.gone) try std.Io.Dir.cwd().deleteTree(io(), wt);
        const before = try f.snapshot(true);
        const roots: []const []const u8 = &.{ records, wt };
        const trees = try treesState(a, roots);
        const want = try std.fmt.allocPrint(a, "holt: {s}: {s}; holt does not change it: resolve it with git (git -C {s} worktree list), then run again\n", .{ try q_test(a, try resolvedPath(a, wt)), shared_seen, try q_test(a, f.clone) });

        for ([_]bool{ false, true }) |force| {
            const argv: []const []const u8 = if (force) &.{ "proj/widget", "feature", "-r", "--force" } else &.{ "proj/widget", "feature", "-r" };
            const refused = try f.run(worktree_cmd.command.run, argv);
            if (refused.code != 1 or refused.out.len != 0 or !std.mem.eql(u8, refused.err, want)) {
                std.debug.print("{s} gone={} force={}: wanted only {s}got {d}:\n{s}{s}\n", .{ case.copy, case.gone, force, want, refused.code, refused.out, refused.err });
                return error.TestUnexpectedResult;
            }
            try expectUnresolved(&f, refused.err, try resolvedPath(a, wt), shared_seen, try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
            try testing.expectEqualStrings(trees, try treesState(a, roots));
            try testing.expectEqualDeep(before, try f.snapshot(true));
        }

        try std.Io.Dir.cwd().deleteTree(io(), copy);
        const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        if (got.code != 0) std.debug.print("{s} gone={}:\n{s}{s}\n", .{ case.copy, case.gone, got.out, got.err });
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(own));
        try testing.expect(!fsutil.exists(wt));
    }
}

test "worktree -r --force: a record that comes to name the worktree's path too after the weighing is refused before anything is set aside, leaving the worktree, its records and kept/ as they were" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    try testing.expectEqual(@as(u8, 0), made.code);
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try f.write(wt, "notes.txt", "only here\n");
    const records = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees" }));
    const own = try std.fs.path.join(a, &.{ records, "feature" });
    const copy = try std.fs.path.join(a, &.{ records, "a-copy" });
    const before = try f.snapshot(true);
    const roots: []const []const u8 = &.{ records, wt };
    const trees = try treesState(a, roots);
    const want = try std.fmt.allocPrint(a, "holt: {s}: {s}; holt does not change it: resolve it with git (git -C {s} worktree list), then run again\n", .{ try q_test(a, try resolvedPath(a, wt)), shared_seen, try q_test(a, f.clone) });

    seam_sb = &sb;
    seam_steps = &.{try std.fmt.allocPrint(a, "cp -R '{s}' '{s}'", .{ own, copy })};
    worktree_cmd.before_recheck_for_test = runSeam;
    defer {
        worktree_cmd.before_recheck_for_test = null;
        seam_sb = null;
        seam_steps = &.{};
    }
    const refused = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r", "--force" });
    if (refused.code != 1 or refused.out.len != 0 or !std.mem.eql(u8, refused.err, want)) {
        std.debug.print("wanted only {s}got {d}:\n{s}{s}\n", .{ want, refused.code, refused.out, refused.err });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("only here\n", try kept.content.readSmall(a, try std.fs.path.join(a, &.{ wt, "notes.txt" })));
    try std.Io.Dir.cwd().deleteTree(io(), copy);
    try testing.expectEqualStrings(trees, try treesState(a, roots));
    try testing.expectEqualDeep(before, try f.snapshot(true));
}

test "archive --prune: a clone that changed after the weighing is kept, naming the repo remove that deletes it once the project is archived" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    const seam = Seam.install(&sb, &.{try std.fmt.allocPrint(a, "git -C '{s}' update-ref refs/heads/moved HEAD", .{f.clone})});
    defer seam.restore();

    const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(contains(got.out, try std.fmt.allocPrint(a, "not pruned widget: {s} changed while it was being weighed (a ref or HEAD moved, or git could not read them again); the clone was kept; delete it with: holt repo remove holt-test.invalid/acme/widget --clone\n", .{try q_test(a, f.clone)})));
    try testing.expect(!contains(got.out, "run the command again"));
    try testing.expect(!contains(got.err, "run the command again"));
    try testing.expect(fsutil.exists(try f.path(".git")));
}

test "archive --prune: a branch with no upstream whose commit origin holds is pruned" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try withProject(&f);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "--unset-upstream" });
    try testutil.runGit(&sb, f.clone, &.{ "branch", "no-upstream" });

    const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!contains(got.out, "not pruned"));
    try testing.expect(contains(got.out, "reclaimed widget"));
    try testing.expect(!fsutil.exists(f.clone));
}

test "archive --prune: clones a host that did not answer, or whose key was not verified, held back are named once with the way out and the repo remove that deletes each after it, never run again, and that repo remove settles each" {
    try skipWithoutLinks();
    for ([_]bool{ true, false }) |host_key| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const names = [_][]const u8{ "widget", "gadget", "gizmo" };
        var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        var paths: [names.len][]const u8 = undefined;
        for (names, &paths) |n, *p| {
            const url = try std.fmt.allocPrint(a, "https://holt-test.invalid/acme/{s}", .{n});
            try repos.put(a, n, url);
            p.* = try fsutil.joinSlashy(a, f.ws.cfg.code_root, try std.fmt.allocPrint(a, "holt-test.invalid/acme/{s}", .{n}));
            if (!std.mem.eql(u8, n, "widget")) try testutil.runGit(&sb, null, &.{ "clone", "-q", f.bare, p.* });
            try testutil.runGit(&sb, p.*, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
            try testutil.runGit(&sb, p.*, &.{ "remote", "set-url", "origin", "ssh://127.0.0.1/holt-remote.git" });
        }
        try testutil.writeMarker(a, try f.ws.projectsRoot(a), "acme", "proj", repos, .empty);
        const script = try std.fs.path.join(a, &.{ sb.root, "failing-ssh" });
        const failure = if (host_key) "Host key verification failed." else "ssh: connect to host 127.0.0.1 port 22: Connection refused";
        try testutil.writeExecutable(script, try std.fmt.allocPrint(a, "#!/bin/sh\necho '{s}' >&2\nexit 255\n", .{failure}));
        const ssh = try testutil.EnvOverride.install(a, "GIT_SSH_COMMAND", script);
        defer ssh.restore();
        const elsewhere = try Elsewhere.ports(a, &.{22});
        defer elsewhere.restore();

        const got = try f.run(project_cmd.archive_command.run, &.{ "acme/proj", "--prune", "--yes" });
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expect(!contains(got.out, "run again"));
        const way = if (host_key) "verify the host key of 127.0.0.1" else "reconnect";
        const first = try std.fmt.allocPrint(a, "; {s}, then delete it with: holt repo remove holt-test.invalid/acme/", .{way});
        const summary = try std.fmt.allocPrint(a, "; {s}, then delete each with: holt repo remove <key> --clone, or holt repo remove <key> --clone --force deletes one\n", .{way});
        if (!contains(got.out, first) or !contains(got.out, summary)) {
            std.debug.print("wanted {s} and {s} in:\n{s}\n", .{ first, summary, got.out });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(@as(usize, 1), count(got.out, first));
        try testing.expectEqual(@as(usize, 1), count(got.out, " --clone --force deletes them\n"));
        try testing.expectEqual(@as(usize, 1), count(got.out, "2 clones were not asked and not pruned: "));
        try testing.expect(!contains(got.out, "once settled"));

        ssh.restore();
        const log = try std.fs.path.join(a, &.{ sb.root, "ssh.log" });
        for (names, paths) |n, p| {
            _ = try localSsh(a, &sb, p, log, f.bare);
            const key = try std.fmt.allocPrint(a, "holt-test.invalid/acme/{s}", .{n});
            const refused = try f.run(repo_cmd.remove_command.run, &.{ key, "--clone", "--yes" });
            try testing.expect(!contains(refused.err, "could not be asked"));
            if (refused.code != 0) {
                try runHint(&f, refused.err, "commits of branch main no remote has", "");
                try testing.expectEqual(@as(u8, 0), (try f.run(repo_cmd.remove_command.run, &.{ key, "--clone", "--yes" })).code);
            }
            try testing.expect(!fsutil.exists(p));
        }
    }
}

/// Runs `script` with `sh -c` in `dir`, as git runs in the sandbox,
/// with an identity to commit as.
fn shIn(f: *const Fixture, dir: []const u8, script: []const u8) !void {
    const who = "export GIT_AUTHOR_NAME=holt-test GIT_AUTHOR_EMAIL=holt-test@example.invalid GIT_COMMITTER_NAME=holt-test GIT_COMMITTER_EMAIL=holt-test@example.invalid; ";
    const res = try proc.runEnv(f.a, &.{ "sh", "-c", try std.mem.concat(f.a, u8, &.{ who, script }) }, dir, &f.sb.git_env.map);
    if (res.status != 0) {
        std.debug.print("script failed: {s}\n{s}\n", .{ script, res.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Runs the `which`-th of the commands the `(run: <a>, or <b>)` after
/// `lead` in `text` names, as `runHint` runs one.
fn runAlternative(f: *const Fixture, text: []const u8, lead: []const u8, which: usize) !void {
    const at = std.mem.indexOf(u8, text, lead) orelse return error.TestUnexpectedResult;
    const rest = text[at + lead.len ..];
    const open = std.mem.indexOf(u8, rest, "(run: ") orelse return error.TestUnexpectedResult;
    const body = rest[open + "(run: ".len ..];
    const close = std.mem.indexOf(u8, body, ")\n") orelse return error.TestUnexpectedResult;
    var parts = std.mem.splitSequence(u8, body[0..close], ", or ");
    var i: usize = 0;
    while (parts.next()) |cmd| : (i += 1) {
        if (i != which) continue;
        return shIn(f, f.clone, cmd);
    }
    return error.TestUnexpectedResult;
}

test "repo remove --clone: each operation git has in progress refuses the delete, naming the commands that finish or abort it, and each of them settles it" {
    try skipWithoutLinks();
    const diverge = "git switch -q -c o && echo o > f && git add f && git commit -q -m o && git switch -q main && echo m > f && git add f && git commit -q -m m";
    const Case = struct { op: []const u8, script: []const u8, continues: bool = false };
    const cases = [_]Case{
        .{ .op = "merge", .script = diverge ++ " && echo dirty >> README && { git merge --autostash o >/dev/null 2>&1 || true; } && test -f .git/MERGE_AUTOSTASH" },
        .{ .op = "rebase", .script = "echo dirty >> README && git -c sequence.editor='sed -i.orig s/^pick/edit/' rebase -i --autostash --root", .continues = true },
        .{ .op = "rebase", .script = diverge ++ " && { git rebase --apply o >/dev/null 2>&1 || true; } && test -d .git/rebase-apply" },
        .{ .op = "am", .script = diverge ++ " && git format-patch -q -1 o --stdout > ../o.patch && { git am ../o.patch >/dev/null 2>&1 || true; } && test -f .git/rebase-apply/applying" },
        .{ .op = "cherry-pick", .script = diverge ++ " && { git cherry-pick o >/dev/null 2>&1 || true; } && test -f .git/CHERRY_PICK_HEAD" },
        .{ .op = "revert", .script = diverge ++ " && echo n > f && git add f && git commit -q -m n && { git revert --no-edit HEAD~1 >/dev/null 2>&1 || true; } && test -f .git/REVERT_HEAD" },
        .{ .op = "cherry-pick", .script = diverge ++ " && git switch -q o && echo p > g && git add g && git commit -q -m p && git switch -q main && { git cherry-pick o~1 o >/dev/null 2>&1 || true; } && echo r > f && git add f && git -c core.editor=true commit -q --no-edit && test -d .git/sequencer && test ! -f .git/CHERRY_PICK_HEAD", .continues = true },
        .{ .op = "bisect", .script = "git bisect start >/dev/null" },
    };
    for (cases) |c| for ([_]usize{ 0, 1 }) |which| {
        const bisect = std.mem.eql(u8, c.op, "bisect");
        if (which == 0 and !c.continues and !bisect) continue;
        if (which == 1 and bisect) continue;
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        try shIn(&f, f.clone, c.script);
        const cq = try q_test(a, f.clone);
        const lead = try std.fmt.allocPrint(a, "  {s} in progress in {s}; finish it or abort it ", .{ c.op, try fsutil.contractTilde(a, app.envOf_current(), f.clone) });
        const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), refused.code);
        const cmds = if (bisect)
            try std.fmt.allocPrint(a, "(run: git -C {s} bisect reset)\n", .{cq})
        else
            try std.fmt.allocPrint(a, "(run: git -C {s} {s} --continue, or git -C {s} {s} --abort)\n", .{ cq, c.op, cq, c.op });
        if (!contains(refused.err, try std.mem.concat(a, u8, &.{ lead, cmds }))) {
            std.debug.print("wanted {s}{s} in:\n{s}\n", .{ lead, cmds, refused.err });
            return error.TestUnexpectedResult;
        }
        try runAlternative(&f, refused.err, lead, which);
        const after = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expect(!contains(after.err, " in progress in "));
    };
}

test "repo remove --clone --force: an operation in progress is named as deleted, with the autostash it holds" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try shIn(&f, f.clone, "echo dirty >> README && git -c sequence.editor='sed -i.orig s/^pick/edit/' rebase -i --autostash --root");
    const id = std.mem.trim(u8, try kept.content.readSmall(a, try f.path(".git/rebase-merge/autostash")), " \r\n");
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes", "--force" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(contains(got.out, try std.fmt.allocPrint(a, "deleting the rebase in progress in {s}, with its autostash {s}\n", .{ try fsutil.contractTilde(a, app.envOf_current(), f.clone), id })));
    try testing.expect(!fsutil.exists(f.clone));
}

test "worktree -r: a worktree whose uncommitted change only a paused rebase --autostash holds refuses the removal, naming the rebase, and aborting it settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    try shIn(&f, wt, "echo dirty >> README && git -c sequence.editor='sed -i.orig s/^pick/edit/' rebase -i --autostash --root");
    const wq = try q_test(a, wt);
    const lead = try std.fmt.allocPrint(a, "  rebase in progress in {s}; finish it or abort it ", .{try fsutil.contractTilde(a, app.envOf_current(), wt)});
    const refused = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(fsutil.exists(wt));
    try testing.expect(contains(refused.err, try std.fmt.allocPrint(a, "{s}(run: git -C {s} rebase --continue, or git -C {s} rebase --abort)\n", .{ lead, wq, wq })));
    try runAlternative(&f, refused.err, lead, 1);
    const after = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    try testing.expect(!contains(after.err, " in progress in "));
    try testing.expect(contains(after.err, "  uncommitted changes: "));
}

/// What a worktree `goneCase` removes holds only in its record: a commit
/// only its HEAD holds, one only its `refs/bisect/bad` holds, or the
/// autostash of a paused rebase.
const GoneHolds = enum { head, ref, autostash };

/// Makes a worktree with `holt worktree` holding `holds`, deletes its
/// directory, and checks that `worktree -r` weighs it through its record:
/// without `force` it refuses naming what it holds, the command named
/// settles it, and the removal then goes through keeping it; with `force`
/// it names it as deleted and removes the record.
fn goneCase(holds: GoneHolds, force: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n");
    switch (holds) {
        .head => try shIn(&f, wt, "git switch -q --detach && git commit -q --allow-empty -m only-in-head"),
        .ref => try shIn(&f, wt, "git switch -q --detach && git commit -q --allow-empty -m only-in-bisect && git update-ref refs/bisect/bad HEAD && git switch -q feature"),
        .autostash => try shIn(&f, wt, "echo dirty >> README && git -c sequence.editor='sed -i.orig s/^pick/edit/' rebase -i --autostash --root"),
    }
    const only = switch (holds) {
        .head => std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "HEAD" }, wt)).stdout, " \r\n"),
        .ref => std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "refs/bisect/bad" }, wt)).stdout, " \r\n"),
        .autostash => std.mem.trim(u8, try kept.content.readSmall(a, try std.fs.path.join(a, &.{ record, "rebase-merge", "autostash" })), " \r\n"),
    };
    try std.Io.Dir.cwd().deleteTree(io(), wt);
    const shown = try fsutil.contractTilde(a, app.envOf_current(), wt);
    const cshown = try fsutil.contractTilde(a, app.envOf_current(), f.clone);
    const wq = try q_test(a, wt);

    if (force) {
        const forced = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r", "--force" });
        const lost = switch (holds) {
            .head => try std.fmt.allocPrint(a, "deleting commit {s}, which only the HEAD of worktree feature holds and no remote has, in {s}\n", .{ only, cshown }),
            .ref => try std.fmt.allocPrint(a, "deleting commits only refs/bisect/bad of worktree feature holds, no remote has, in {s}\n", .{cshown}),
            .autostash => try std.fmt.allocPrint(a, "deleting the rebase in progress in {s}, with its autostash {s}\n", .{ shown, only }),
        };
        if (forced.code != 0 or !contains(forced.out, lost)) {
            std.debug.print("{s}: wanted {s} in:\n{s}{s}\n", .{ @tagName(holds), lost, forced.out, forced.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(!fsutil.exists(record));
        return;
    }

    const refused = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    const line = switch (holds) {
        .head => try std.fmt.allocPrint(a, "  {s}: commit {s}, which only the HEAD of worktree feature holds and no remote has, in {s} (run: ", .{ shown, only, cshown }),
        .ref => try std.fmt.allocPrint(a, "  {s}: commits only refs/bisect/bad of worktree feature holds, no remote has, in {s} (run: ", .{ shown, cshown }),
        .autostash => try std.fmt.allocPrint(a, "  {s}: rebase in progress in {s}; finish it or abort it (run: git -C {s} rebase --continue, or git -C {s} rebase --abort)\n", .{ shown, shown, wq, wq }),
    };
    if (refused.code != 1 or !contains(refused.err, line)) {
        std.debug.print("{s}: wanted {s} in:\n{s}{s}\n", .{ @tagName(holds), line, refused.out, refused.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(fsutil.exists(record));
    if (holds == .autostash) {
        const back = try std.fmt.allocPrint(a, "  {s}: its directory is gone; bring it back from its record first ", .{shown});
        try runHint(&f, refused.err, back, "");
        const there = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        try testing.expectEqual(@as(u8, 1), there.code);
        try runAlternative(&f, there.err, "rebase in progress in ", 1);
        const dirty = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        try testing.expectEqual(@as(u8, 1), dirty.code);
        const run_at = (std.mem.indexOf(u8, dirty.err, "\nrun: ") orelse return error.TestUnexpectedResult) + "\nrun: ".len;
        try shIn(&f, f.clone, dirty.err[run_at .. std.mem.indexOfScalarPos(u8, dirty.err, run_at, '\n') orelse return error.TestUnexpectedResult]);
        const removed = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        if (removed.code != 0) {
            std.debug.print("autostash: the removal after the hints failed:\n{s}\n", .{removed.err});
            return error.TestUnexpectedResult;
        }
        try testing.expect(!fsutil.exists(record));
        const stashed = try git.runInRepo(a, &.{ "show", "refs/stash:README" }, f.clone);
        try testing.expect(std.mem.endsWith(u8, stashed.stdout, "dirty\n"));
        return;
    }
    try runHint(&f, refused.err, line[0..std.mem.indexOf(u8, line, "(run: ").?], "");
    const removed = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    if (removed.code != 0) {
        std.debug.print("{s}: the removal after the hint failed:\n{s}\n", .{ @tagName(holds), removed.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(!fsutil.exists(record));
    const kept_at = try git.runInRepo(a, &.{ "for-each-ref", "--format=%(objectname)", "refs/heads/holt-kept/", "refs/holt-kept/" }, f.clone);
    try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ only, "\n" }), kept_at.stdout);
}

test "worktree -r: a worktree whose directory is gone is weighed through its record: a commit only its HEAD or a per-worktree ref holds, or a paused rebase, refuses the removal, the commands named settle it, and --force names it as deleted" {
    try skipWithoutLinks();
    for (std.enums.values(GoneHolds)) |holds| {
        try goneCase(holds, false);
        try goneCase(holds, true);
    }
}

/// How a linked worktree `linkedCase` weighs is left: there, its directory
/// gone, its `.git` gone, its `.git` naming a git directory that is gone,
/// locked, locked with its directory gone, dirty, made by `holt worktree`,
/// or that with its directory gone.
const LinkedKind = enum { live, gone, unlinked, dangling, locked, locked_gone, dirty, holt, holt_gone };

/// Makes a linked worktree left as `kind`, holding, when `at_risk`, a
/// commit only its HEAD holds; checks that `repo remove --clone` names
/// the branch keeping that commit and no removal, then the command
/// removing the worktree, and that running each command it names, then
/// the push it names, lets the delete through with the commit on the
/// remote. One whose `.git` is gone or leads nowhere is first named with
/// `unresolvedLine` alone, unweighed, and left as it was; once the user
/// puts its `.git` back, it goes as one that is there.
fn linkedCase(kind: LinkedKind, at_risk: bool) !void {
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const holt = kind == .holt or kind == .holt_gone;
        if (holt) try withProject(&f);
        const wt = if (holt) blk: {
            try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
            const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
            break :blk try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
        } else blk: {
            const p = try std.fs.path.join(a, &.{ sb.root, "linked" });
            try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", p });
            break :blk p;
        };
        const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n");
        var only: []const u8 = "";
        if (at_risk) {
            try shIn(&f, wt, "git switch -q --detach && echo w > only.txt && git add only.txt && git commit -q -m only-in-worktree");
            const head = try git.runInRepo(a, &.{ "rev-parse", "HEAD" }, wt);
            only = std.mem.trim(u8, head.stdout, " \r\n");
        }
        switch (kind) {
            .locked, .locked_gone => try testutil.runGit(&sb, f.clone, &.{ "worktree", "lock", wt }),
            .dirty => try f.write(wt, "untracked.txt", "work"),
            else => {},
        }
        const dot_git = try std.fs.path.join(a, &.{ wt, ".git" });
        const link = kept.content.readSmall(a, dot_git) catch "";
        switch (kind) {
            .gone, .locked_gone, .holt_gone => try std.Io.Dir.cwd().deleteTree(io(), wt),
            .unlinked => try fsutil.removePath(dot_git),
            .dangling => try f.write(wt, ".git", try linkText(a, try std.fs.path.join(a, &.{ sb.root, "moved-away", ".git", "worktrees", "linked" }))),
            else => {},
        }
        const remove_args: []const []const u8 = if (holt) &.{ "widget", "-p", "acme/proj", "--clone", "--yes" } else &.{ Fixture.key, "--clone", "--yes" };
        const cq = try q_test(a, f.clone);
        const wq = try q_test(a, wt);
        const shown = try fsutil.contractTilde(a, app.envOf_current(), wt);

        var got = try f.run(repo_cmd.remove_command.run, remove_args);
        if (kind == .unlinked or kind == .dangling) {
            const roots: []const []const u8 = &.{ wt, std.fs.path.dirname(record).? };
            const before = try treesState(a, roots);
            try testing.expectEqual(@as(u8, 1), got.code);
            const seen = if (kind == .unlinked) "a linked working tree whose .git is gone" else "a linked working tree whose .git names a git directory that is not there";
            try expectUnresolved(&f, got.err, wt, seen, try std.fmt.allocPrint(a, "git -C {s}", .{cq}));
            if (at_risk) try testing.expect(!contains(got.err, only));
            try testing.expectEqualStrings(before, try treesState(a, roots));
            try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = dot_git, .data = link });
            got = try f.run(repo_cmd.remove_command.run, remove_args);
        }
        try testing.expectEqual(@as(u8, 1), got.code);
        if (at_risk) {
            const risk = try std.fmt.allocPrint(a, "  {s}: commit {s}, which only the HEAD of worktree ", .{ shown, only });
            if (!contains(got.err, risk)) {
                std.debug.print("{s}/{}: wanted {s} in:\n{s}\n", .{ @tagName(kind), at_risk, risk, got.err });
                return error.TestUnexpectedResult;
            }
            for ([_][]const u8{ " worktree remove ", " worktree prune", "holt worktree ", "commit or discard" }) |removal| try testing.expect(!contains(got.err, removal));
            try runHint(&f, got.err, risk, "");
            got = try f.run(repo_cmd.remove_command.run, remove_args);
            try testing.expectEqual(@as(u8, 1), got.code);
        }
        const removal = switch (kind) {
            .live, .unlinked, .dangling => try std.fmt.allocPrint(a, "  {s} (run: git -C {s} worktree remove {s})\n", .{ shown, cq, wq }),
            .gone => try std.fmt.allocPrint(a, "  {s}, which is gone (run: git -C {s} worktree remove {s})\n", .{ shown, cq, wq }),
            .locked => try std.fmt.allocPrint(a, "  {s}, which is locked (run: git -C {s} worktree unlock {s} && git -C {s} worktree remove {s})\n", .{ shown, cq, wq, cq, wq }),
            .locked_gone => try std.fmt.allocPrint(a, "  {s}, which is gone (run: git -C {s} worktree unlock {s} && git -C {s} worktree remove {s})\n", .{ shown, cq, wq, cq, wq }),
            .dirty => try std.fmt.allocPrint(a, "  commit or discard the changes in {s}, then (run: git -C {s} worktree remove {s})\n", .{ shown, cq, wq }),
            .holt => try std.fmt.allocPrint(a, "  {s} (run: holt worktree acme/proj/widget feature -r)\n", .{shown}),
            .holt_gone => try std.fmt.allocPrint(a, "  {s}, which is gone (run: holt worktree acme/proj/widget feature -r)\n", .{shown}),
        };
        if (!contains(got.err, removal)) {
            std.debug.print("{s}/{}: wanted {s} in:\n{s}\n", .{ @tagName(kind), at_risk, removal, got.err });
            return error.TestUnexpectedResult;
        }
        if (kind == .dirty) try fsutil.removePath(try std.fs.path.join(a, &.{ wt, "untracked.txt" }));
        if (holt) {
            const removed = try f.run(worktree_cmd.command.run, &.{ "acme/proj/widget", "feature", "-r" });
            if (removed.code != 0) {
                std.debug.print("{s}/{}: holt worktree -r failed:\n{s}\n", .{ @tagName(kind), at_risk, removed.err });
                return error.TestUnexpectedResult;
            }
        } else try runHint(&f, got.err, removal[0..std.mem.indexOf(u8, removal, "(run: ").?], "");
        got = try f.run(repo_cmd.remove_command.run, remove_args);
        try testing.expect(!contains(got.err, "other worktree"));
        if (at_risk) {
            try testing.expectEqual(@as(u8, 1), got.code);
            try runHint(&f, got.err, "commits of branch ", "");
            got = try f.run(repo_cmd.remove_command.run, remove_args);
            const held = try git.runInRepo(a, &.{ "cat-file", "-t", only }, f.bare);
            try testing.expectEqualStrings("commit\n", held.stdout);
        }
        if (got.code != 0) {
            std.debug.print("{s}/{}: delete refused:\n{s}\n", .{ @tagName(kind), at_risk, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(!fsutil.exists(f.clone));
    }
}

test "repo remove --clone: each linked worktree is weighed before it is named with the command that removes it: one holding a commit no remote has names the branch that keeps it, never a removal, and following every hint loses no commit; one whose .git is gone or leads nowhere is first named unweighed with what is seen there, and left as it was" {
    try skipWithoutLinks();
    for (std.enums.values(LinkedKind)) |kind| try linkedCase(kind, true);
    for ([_]LinkedKind{ .live, .gone, .unlinked, .dangling }) |kind| try linkedCase(kind, false);
}

test "repo remove --clone: a locked linked worktree is named with the unlock before its removal, and a dirty one with committing or discarding its changes, never with --force" {
    try skipWithoutLinks();
    for ([_]LinkedKind{ .locked, .locked_gone, .dirty }) |kind| try linkedCase(kind, false);
}

test "repo remove -p --clone: a linked worktree holt worktree made is named with the holt worktree -r that removes it" {
    try skipWithoutLinks();
    for ([_]LinkedKind{ .holt, .holt_gone }) |kind| try linkedCase(kind, false);
}

test "repo remove --clone: a linked worktree's per-worktree ref is weighed, whether its directory is there or gone, and the command that keeps it settles it" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |gone| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const wt = try std.fs.path.join(a, &.{ sb.root, "linked" });
        try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
        try shIn(&f, wt, "git switch -q --detach && git commit -q --allow-empty -m only-in-bisect && git update-ref refs/bisect/bad HEAD && git switch -q --detach main");
        const only = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "refs/bisect/bad" }, wt)).stdout, " \r\n");
        if (gone) try std.Io.Dir.cwd().deleteTree(io(), wt);
        const shown = try fsutil.contractTilde(a, app.envOf_current(), wt);
        const risk = try std.fmt.allocPrint(a, "  {s}: commits only refs/bisect/bad of worktree linked holds, no remote has, in ", .{shown});
        var got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        if (!contains(got.err, risk)) {
            std.debug.print("wanted {s} in:\n{s}\n", .{ risk, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(!contains(got.err, " worktree prune") and !contains(got.err, " worktree remove "));
        try runHint(&f, got.err, risk, "");
        got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expect(!contains(got.err, risk));
        try testing.expect(contains(got.err, " worktree remove "));
        const kept_ref = try git.runInRepo(a, &.{ "for-each-ref", "--format=%(objectname)", "refs/holt-kept/" }, f.clone);
        try testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ only, "\n" }), kept_ref.stdout);
    }
}

test "repo remove --clone: a rebase paused in a linked worktree is named with the commands that finish or abort it, and one in a worktree that is gone with the command that brings the worktree back first" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |gone| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const wt = try std.fs.path.join(a, &.{ sb.root, "linked" });
        try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
        try shIn(&f, wt, "echo dirty >> README && git -c sequence.editor='sed -i.orig s/^pick/edit/' rebase -i --autostash --root");
        const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n");
        if (gone) try std.Io.Dir.cwd().deleteTree(io(), wt);
        const shown = try fsutil.contractTilde(a, app.envOf_current(), wt);
        const wq = try q_test(a, wt);
        var got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), got.code);
        const line = try std.fmt.allocPrint(a, "  {s}: rebase in progress in {s}; finish it or abort it (run: git -C {s} rebase --continue, or git -C {s} rebase --abort)\n", .{ shown, shown, wq, wq });
        const back = try std.fmt.allocPrint(a, "  {s}: its directory is gone; bring it back from its record first ", .{shown});
        if (!contains(got.err, line) or contains(got.err, back) != gone) {
            std.debug.print("gone={}: wanted {s} in:\n{s}\n", .{ gone, line, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(!contains(got.err, " worktree prune") and !contains(got.err, " worktree remove "));
        try testing.expect(fsutil.exists(try std.fs.path.join(a, &.{ record, "rebase-merge", "autostash" })));
        if (gone) {
            try runHint(&f, got.err, back, "");
            got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
            if (!contains(got.err, line) or contains(got.err, back)) {
                std.debug.print("wanted {s} once it is back in:\n{s}\n", .{ line, got.err });
                return error.TestUnexpectedResult;
            }
        }
        try runAlternative(&f, got.err, line[0..std.mem.indexOf(u8, line, "(run: ").?], 1);
        got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expect(!contains(got.err, " in progress in "));
        try testing.expect(contains(got.err, "  commit or discard the changes in "));
        const readme = try kept.content.readSmall(a, try std.fs.path.join(a, &.{ wt, "README" }));
        try testing.expect(std.mem.endsWith(u8, readme, "dirty\n"));
    }
}

test "repo remove --clone: a linked worktree holding files holt does not keep is named with holt keep --review, never with a removal, until none remain" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const wt = try std.fs.path.join(a, &.{ sb.root, "linked" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
    try f.ignore("/secret.env");
    try f.write(wt, "secret.env", "only in the worktree");
    const shown = try fsutil.contractTilde(a, app.envOf_current(), wt);
    const cq = try q_test(a, f.clone);
    const wq = try q_test(a, wt);

    var got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    const listed = try std.fmt.allocPrint(a, "  {s}: not kept: {s}/secret.env\n", .{ shown, shown });
    const review = try std.fmt.allocPrint(a, "  {s}: keep or skip each first (run: holt keep --review {s})\n", .{ shown, wq });
    if (!contains(got.err, listed) or !contains(got.err, review)) {
        std.debug.print("wanted {s}{s} in:\n{s}\n", .{ listed, review, got.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(!contains(got.err, " worktree remove ") and !contains(got.err, " worktree prune"));

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "k\n";
    const reviewed = try f.run(keep_cmd.command.run, &.{ "--review", wt });
    ui.stdin_terminal_for_test = null;
    ui.stdin_for_test = null;
    try testing.expectEqual(@as(u8, 0), reviewed.code);

    got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(!contains(got.err, "not kept: "));
    const removal = try std.fmt.allocPrint(a, "  {s} (run: git -C {s} worktree remove {s})\n", .{ shown, cq, wq });
    if (!contains(got.err, removal)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ removal, got.err });
        return error.TestUnexpectedResult;
    }
    try runHint(&f, got.err, removal[0..std.mem.indexOf(u8, removal, "(run: ").?], "");
    got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    if (got.code != 0) {
        std.debug.print("delete refused:\n{s}\n", .{got.err});
        return error.TestUnexpectedResult;
    }
    const kept_copy = try f.kctx.layout.copyPath(a, Fixture.key, "secret.env");
    try testing.expectEqualStrings("only in the worktree", try kept.content.readSmall(a, kept_copy));
}

test "repo remove --clone: two linked worktrees whose config.worktree sends one URL to different remotes never share an answer" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const elsewhere = try Elsewhere.ports(a, &.{22});
    defer elsewhere.restore();
    const has_owned = try testutil.makeBareRepo(&sb, "has.git");
    defer testing.allocator.free(has_owned);
    const has = try a.dupe(u8, has_owned);
    const log = try std.fs.path.join(a, &.{ sb.root, "ssh.log" });
    const url = try localSsh(a, &sb, f.clone, log, has);
    const to_has = std.mem.trim(u8, (try git.runInRepo(a, &.{ "config", "core.sshCommand" }, f.clone)).stdout, " \r\n");
    const to_bare = try std.fs.path.join(a, &.{ sb.root, "bare-ssh" });
    try testutil.writeExecutable(to_bare, try std.fmt.allocPrint(a, "#!/bin/sh\n[ \"$1\" = -G ] && exit 1\nfor last; do :; done\nexec sh -c \"$(printf '%s' \"$last\" | sed 's|/holt-remote.git|{s}|')\"\n", .{f.bare}));
    try testutil.runGit(&sb, f.clone, &.{ "config", "--unset", "core.sshCommand" });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", url });
    try testutil.runGit(&sb, f.clone, &.{ "config", "extensions.worktreeConfig", "true" });
    var heads: [2][]const u8 = undefined;
    for ([_][]const u8{ "a", "b" }, [_][]const u8{ to_has, to_bare }, &heads) |name, ssh, *head| {
        const wt = try std.fs.path.join(a, &.{ sb.root, name });
        try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
        try testutil.runGit(&sb, wt, &.{ "config", "--worktree", "core.sshCommand", ssh });
        try shIn(&f, wt, try std.fmt.allocPrint(a, "git commit -q --allow-empty -m only-in-{s} && git push -q '{s}' HEAD:refs/heads/{s}", .{ name, has, name }));
        head.* = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "HEAD" }, wt)).stdout, " \r\n");
    }
    const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    const b_shown = try fsutil.contractTilde(a, app.envOf_current(), try std.fs.path.join(a, &.{ sb.root, "b" }));
    const a_shown = try fsutil.contractTilde(a, app.envOf_current(), try std.fs.path.join(a, &.{ sb.root, "a" }));
    if (!contains(got.err, try std.fmt.allocPrint(a, "  {s}: commit {s}, which only the HEAD of worktree b holds and no remote has", .{ b_shown, heads[1] }))) {
        std.debug.print("got:\n{s}\n", .{got.err});
        return error.TestUnexpectedResult;
    }
    try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "  {s} (run: git -C ", .{a_shown})));
}

test "repo remove --clone: push URLs whose host key was not verified share a line only on the same port, and a shared line names every host it covers" {
    try skipWithoutLinks();
    const Case = struct { urls: [2][]const u8, lines: []const []const u8 };
    const cases = [_]Case{
        .{ .urls = .{ "ssh://127.0.0.1:2222/acme/a.git", "ssh://127.0.0.1:2223/acme/b.git" }, .lines = &.{
            "(remote origin could not be asked at ssh://127.0.0.1:2222/acme/a.git: host key not verified); verify the host key of 127.0.0.1:2222 and run again, or --force deletes it\n",
            "(remote origin could not be asked at ssh://127.0.0.1:2223/acme/b.git: host key not verified); verify the host key of 127.0.0.1:2223 and run again, or --force deletes it\n",
        } },
        .{ .urls = .{ "ssh://127.0.0.1/acme/a.git", "ssh://127.0.0.1:22/acme/b.git" }, .lines = &.{
            "(remote origin could not be asked at ssh://127.0.0.1/acme/a.git, ssh://127.0.0.1:22/acme/b.git: host key not verified); verify the host key of 127.0.0.1 and 127.0.0.1:22 and run again, or --force deletes it\n",
        } },
    };
    for (cases) |c| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const script = try std.fs.path.join(a, &.{ sb.root, "badkey-ssh" });
        try testutil.writeExecutable(script, "#!/bin/sh\necho 'Host key verification failed.' >&2\nexit 255\n");
        try testutil.runGit(&sb, f.clone, &.{ "config", "core.sshCommand", script });
        try testutil.runGit(&sb, f.clone, &.{ "config", "ssh.variant", "ssh" });
        const elsewhere = try Elsewhere.ports(a, &.{ 22, 2222, 2223 });
        defer elsewhere.restore();
        for (c.urls) |u| try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.pushurl", u });
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "not pushed yet" });
        const got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expectEqual(c.lines.len, count(got.err, "not confirmed held"));
        for (c.lines) |line| if (!contains(got.err, line)) {
            std.debug.print("wanted {s} in:\n{s}\n", .{ line, got.err });
            return error.TestUnexpectedResult;
        };
    }
}

test "repo remove --clone: a nested repository in a linked worktree is named with holt repo adopt, never with a removal, until none remain, and the empty directory it leaves needs no skip" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const wt = try std.fs.path.join(a, &.{ sb.root, "linked" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
    try f.ignore("/vendor/");
    const nested = try std.fs.path.join(a, &.{ wt, "vendor", "lib" });
    try fsutil.ensureDir(nested);
    try testutil.runGit(&sb, nested, &.{ "init", "-q", "-b", "main" });
    try testutil.runGit(&sb, nested, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    const only = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "HEAD" }, nested)).stdout, " \r\n");
    const shown = try fsutil.contractTilde(a, app.envOf_current(), wt);
    const nq = try q_test(a, nested);
    const cq = try q_test(a, f.clone);
    const wq = try q_test(a, wt);

    var got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    const line = try std.fmt.allocPrint(a, "  {s}: nested repository {s} (run: holt repo adopt {s})\n", .{ shown, nq, nq });
    if (!contains(got.err, line)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ line, got.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(!contains(got.err, " worktree remove ") and !contains(got.err, " worktree prune"));

    const adopted = try f.run(repo_cmd.adopt_command.run, &.{nested});
    if (adopted.code != 0) {
        std.debug.print("adopt failed:\n{s}\n", .{adopted.err});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(kept.content.Entry.dir, try kept.content.entryAt(try std.fs.path.join(a, &.{ wt, "vendor" })));
    got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(!contains(got.err, "nested repository") and !contains(got.err, "not kept"));
    const removal = try std.fmt.allocPrint(a, "  {s} (run: git -C {s} worktree remove {s})\n", .{ shown, cq, wq });
    if (!contains(got.err, removal)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ removal, got.err });
        return error.TestUnexpectedResult;
    }
    try runHint(&f, got.err, removal[0..std.mem.indexOf(u8, removal, "(run: ").?], "");
    got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    if (got.code != 0) {
        std.debug.print("delete refused:\n{s}\n", .{got.err});
        return error.TestUnexpectedResult;
    }
    const moved = try fsutil.joinSlashy(a, f.ws.cfg.code_root, "local/lib");
    const held = try git.runInRepo(a, &.{ "cat-file", "-t", only }, moved);
    try testing.expectEqualStrings("commit\n", held.stdout);
}

/// Every file, directory, and link under each of `roots`, each file by
/// its bytes' hash (`kept_hooks.snapshot`), for a check that a refusal
/// left them as they were.
fn treesState(a: std.mem.Allocator, roots: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (roots) |r| {
        try out.print(a, "{s} {s}\n", .{ r, @tagName(try kept.content.entryAt(r)) });
        if (try kept.content.entryAt(r) == .file) try out.appendSlice(a, try kept.content.readSmall(a, r));
        try out.appendSlice(a, try kept_hooks.snapshot(a, r, null));
    }
    return out.items;
}

/// Checks that `text` holds `unresolvedLine` for `path`, saying `seen`,
/// with `git_in` the git it names, and no command writing or removing
/// anything; then runs the `<git_in> worktree list` it names in this
/// state, which must succeed.
fn expectUnresolved(f: *const Fixture, text: []const u8, path: []const u8, seen: []const u8, git_in: []const u8) !void {
    const want = try std.fmt.allocPrint(f.a, "{s}: {s}; holt does not change it: resolve it with git ({s} worktree list), then run again", .{ try q_test(f.a, path), seen, git_in });
    if (!contains(text, want)) {
        std.debug.print("wanted {s}in:\n{s}\n", .{ want, text });
        return error.TestUnexpectedResult;
    }
    for ([_][]const u8{ "printf", "rm -rf", "Remove-Item", "Set-Content", "stash push", " worktree remove", " worktree repair", " worktree prune" }) |cmd| {
        if (contains(text, cmd)) {
            std.debug.print("named {s} in:\n{s}\n", .{ cmd, text });
            return error.TestUnexpectedResult;
        }
    }
    const res = try proc.runEnv(f.a, &.{ "sh", "-c", try std.fmt.allocPrint(f.a, "{s} worktree list", .{git_in}) }, null, &f.sb.git_env.map);
    if (res.status != 0) {
        std.debug.print("{s} worktree list failed:\n{s}\n", .{ git_in, res.stderr });
        return error.TestUnexpectedResult;
    }
}

/// Makes a worktree with `holt worktree` holding, when `at_risk`, a commit
/// only its HEAD holds, and leaves its `.git` as `how` says; checks that
/// `worktree -r`, with or without `force`, refuses it with
/// `unresolvedLine` alone, leaving its record, its tree, and the clone's
/// records as they were; then, once the user puts its `.git` back, that
/// the removal weighs and removes it as any other.
/// How `unlinkedCase` leaves a worktree's `.git`: removed, or naming a
/// git directory that is not there, as after its clone was moved by hand.
const UnlinkedHow = enum { removed, dangling };

fn unlinkedCase(at_risk: bool, force: bool, how: UnlinkedHow) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n");
    if (at_risk) try shIn(&f, wt, "git switch -q --detach && git commit -q --allow-empty -m only-in-head");
    const only = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "HEAD" }, wt)).stdout, " \r\n");
    const dot_git = try std.fs.path.join(a, &.{ wt, ".git" });
    const link = try kept.content.readSmall(a, dot_git);
    switch (how) {
        .removed => try fsutil.removePath(dot_git),
        .dangling => try f.write(wt, ".git", try linkText(a, try std.fs.path.join(a, &.{ sb.root, "moved-away", ".git", "worktrees", "feature" }))),
    }
    const seen = switch (how) {
        .removed => "a linked working tree whose .git is gone",
        .dangling => "a linked working tree whose .git names a git directory that is not there",
    };
    const shown = try fsutil.contractTilde(a, app.envOf_current(), wt);
    const roots: []const []const u8 = &.{ wt, std.fs.path.dirname(record).? };
    const before = try treesState(a, roots);

    const argv: []const []const u8 = if (force) &.{ "proj/widget", "feature", "-r", "--force" } else &.{ "proj/widget", "feature", "-r" };
    var got = try f.run(worktree_cmd.command.run, argv);
    if (got.code != 1 or got.out.len != 0 or !std.mem.startsWith(u8, got.err, "holt: ") or std.mem.count(u8, got.err, "\n") != 1) {
        std.debug.print("{s} at_risk={} force={}: wanted the refusal alone, got {d}:\n{s}{s}\n", .{ @tagName(how), at_risk, force, got.code, got.out, got.err });
        return error.TestUnexpectedResult;
    }
    try expectUnresolved(&f, got.err, wt, seen, try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
    try testing.expectEqualStrings(before, try treesState(a, roots));

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = dot_git, .data = link });
    got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    if (at_risk) {
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(contains(got.err, try std.fmt.allocPrint(a, "commit {s}, which only the HEAD of worktree feature holds and no remote has, in ", .{only})));
        try runHint(&f, got.err, try std.fmt.allocPrint(a, "commit {s}, ", .{only}), "");
        got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    }
    if (got.code != 0) {
        std.debug.print("{s} at_risk={}: the removal once its .git is back failed:\n{s}\n", .{ shown, at_risk, got.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(!fsutil.exists(wt));
    try testing.expect(!fsutil.exists(record));
}

test "worktree -r: a worktree whose .git is gone is refused, even with --force, naming what is seen there and git worktree list alone, and leaving it and every record as they were; once its .git is back it is weighed and removed" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |at_risk| {
        try unlinkedCase(at_risk, false, .removed);
        try unlinkedCase(at_risk, true, .removed);
    }
}

test "worktree -r: a worktree whose .git names a git directory that is gone is refused, even with --force, naming what is seen there and git worktree list alone, and leaving it and every record as they were; once its .git is back it is weighed and removed" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |at_risk| {
        try unlinkedCase(at_risk, false, .dangling);
        try unlinkedCase(at_risk, true, .dangling);
    }
}

test "linkOf and linkSeen: a worktree path that is a symlink to the tree leads back; a .git that is gone, names a git directory that is gone, does not read as a link, names another repository, or names its record git cannot open, a .git symlink to another repository or to nothing, and a path holding a file or a symlink to nothing, are unresolved, each seen as what it is" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const wt = try std.fs.path.join(a, &.{ sb.root, "linked" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
    const record = try fsutil.realPathOrSelf(a, std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n"));
    const common = try commonDirOf(a, .{ .repo = f.clone });
    const alias = try std.fs.path.join(a, &.{ sb.root, "alias" });
    try kept.content.createLink(wt, alias, .dir);
    for ([_][]const u8{ wt, alias }) |p| {
        try testing.expectEqual(Link.there, try linkOf(a, common, record, p));
        try testing.expect(try linkSeen(a, common, record, p) == null);
    }
    const gone = try std.fs.path.join(a, &.{ sb.root, "gone-wt" });
    try testing.expectEqual(Link.absent, try linkOf(a, common, record, gone));
    try testing.expect(try linkSeen(a, common, record, gone) == null);

    const link = try kept.content.readSmall(a, try std.fs.path.join(a, &.{ wt, ".git" }));
    const other = try std.fs.path.join(a, &.{ sb.root, "other" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", other });
    const Case = struct { text: ?[]const u8, seen: []const u8 };
    for ([_]Case{
        .{ .text = null, .seen = "a linked working tree whose .git is gone" },
        .{ .text = try linkText(a, try std.fs.path.join(a, &.{ sb.root, "gone", "worktrees", "linked" })), .seen = "a linked working tree whose .git names a git directory that is not there" },
        .{ .text = "not a link\n", .seen = "a linked working tree whose .git does not read as a link to a git directory" },
        .{ .text = try linkText(a, try std.fs.path.join(a, &.{ other, ".git" })), .seen = "a linked working tree whose .git leads to another git directory than its record" },
    }) |c| {
        const dot_git = try std.fs.path.join(a, &.{ wt, ".git" });
        if (c.text) |t| try f.write(wt, ".git", t) else try fsutil.removePath(dot_git);
        for ([_][]const u8{ wt, alias }) |p| {
            try testing.expectEqual(Link.unresolved, try linkOf(a, common, record, p));
            try testing.expectEqualStrings(c.seen, (try linkSeen(a, common, record, p)).?);
        }
    }
    const dot_git = try std.fs.path.join(a, &.{ wt, ".git" });
    for ([_][2][]const u8{ .{ try std.fs.path.join(a, &.{ other, ".git" }), "a linked working tree whose .git leads to another git directory than its record" }, .{ try std.fs.path.join(a, &.{ sb.root, "no-such-git" }), "a linked working tree whose .git is a symlink to nothing" } }) |c| {
        try fsutil.removePath(dot_git);
        try kept.content.createLink(c[0], dot_git, .dir);
        try testing.expectEqual(Link.unresolved, try linkOf(a, common, record, wt));
        try testing.expectEqualStrings(c[1], (try linkSeen(a, common, record, wt)).?);
    }
    try fsutil.removePath(dot_git);
    try f.write(wt, ".git", link);
    try testing.expectEqual(Link.there, try linkOf(a, common, record, wt));
    const head_path = try std.fs.path.join(a, &.{ record, "HEAD" });
    const head = try kept.content.readSmall(a, head_path);
    try fsutil.removePath(head_path);
    try testing.expectEqual(Link.unresolved, try linkOf(a, common, record, wt));
    try testing.expectEqualStrings("a linked working tree whose .git names its record, which git cannot open there", (try linkSeen(a, common, record, wt)).?);
    try f.write(record, "HEAD", head);
    try testing.expectEqual(Link.there, try linkOf(a, common, record, wt));

    const file = try std.fs.path.join(a, &.{ sb.root, "a-file" });
    try f.write(sb.root, "a-file", "not a tree\n");
    const nowhere = try std.fs.path.join(a, &.{ sb.root, "nowhere" });
    try kept.content.createLink(try std.fs.path.join(a, &.{ sb.root, "no-such-dir" }), nowhere, .dir);
    for ([_][2][]const u8{ .{ file, "a linked working tree whose path holds something that is not a directory" }, .{ nowhere, "a linked working tree whose path is a symlink to nothing" } }) |c| {
        try testing.expectEqual(Link.unresolved, try linkOf(a, common, record, c[0]));
        try testing.expectEqualStrings(c[1], (try linkSeen(a, common, record, c[0])).?);
    }
}

test "linkOf and linkSeen: a worktree path under a file, or under a symlink to nothing, is unresolved, seen as a path under something that is not a directory" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const blk = try std.fs.path.join(a, &.{ sb.root, "blk" });
    const wt = try std.fs.path.join(a, &.{ blk, "deep", "linked" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
    const record = try fsutil.realPathOrSelf(a, std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n"));
    const common = try commonDirOf(a, .{ .repo = f.clone });
    for ([_]bool{ false, true }) |dangling| {
        try std.Io.Dir.cwd().deleteTree(io(), blk);
        if (dangling) try kept.content.createLink(try std.fs.path.join(a, &.{ sb.root, "no-such-dir" }), blk, .dir) else try f.write(sb.root, "blk", "not a tree\n");
        try testing.expectEqual(Link.unresolved, try linkOf(a, common, record, wt));
        try testing.expectEqualStrings("a linked working tree whose path lies under something that is not a directory", (try linkSeen(a, common, record, wt)).?);
    }
    try std.Io.Dir.cwd().deleteTree(io(), blk);
    try testing.expectEqual(Link.absent, try linkOf(a, common, record, wt));
}

test "linkOf and linkSeen: a worktree path holt is denied, and a symlink loop at it, are unresolved, each seen as a path that cannot be read" {
    try skipWithoutLinks();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const shut = try std.fs.path.join(a, &.{ sb.root, "shut" });
    const wt = try std.fs.path.join(a, &.{ shut, "linked" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
    const record = try fsutil.realPathOrSelf(a, std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n"));
    const common = try commonDirOf(a, .{ .repo = f.clone });
    const loop = try std.fs.path.join(a, &.{ sb.root, "loop" });
    try kept.content.createLink(loop, loop, .dir);
    try testing.expectEqual(@as(u8, 0), (try proc.run(a, &.{ "chmod", "000", shut }, null)).status);
    defer _ = proc.run(a, &.{ "chmod", "700", shut }, null) catch {};
    if (kept.content.entryAt(wt)) |_| return error.SkipZigTest else |_| {}
    for ([_][]const u8{ wt, loop }) |p| {
        try testing.expectEqual(Link.unresolved, try linkOf(a, common, record, p));
        try testing.expectEqualStrings("a linked working tree whose path cannot be read", (try linkSeen(a, common, record, p)).?);
    }
}

test "linkSeen: a relative .git is read against the real path of its directory, so a symlinked parent at another depth is seen as leading to the git directory git reaches" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const deep = try std.fs.path.join(a, &.{ sb.root, "deep", "er", "wts" });
    try fsutil.ensureDir(deep);
    const wts = try std.fs.path.join(a, &.{ sb.root, "wts" });
    try kept.content.createLink(deep, wts, .dir);
    const wt = try std.fs.path.join(a, &.{ wts, "linked" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
    const record = try fsutil.realPathOrSelf(a, std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n"));
    const common = try commonDirOf(a, .{ .repo = f.clone });
    const other = try std.fs.path.join(a, &.{ sb.root, "other" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", other });
    const rel = try std.fs.path.relative(a, ".", null, try fsutil.realPathOrSelf(a, wt), try std.fs.path.join(a, &.{ other, ".git" }));
    try f.write(wt, ".git", try std.fmt.allocPrint(a, "gitdir: {s}\n", .{rel}));
    const found = try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt);
    try testing.expectEqual(@as(u32, 0), found.status);
    try testing.expectEqualStrings("a linked working tree whose .git leads to another git directory than its record", (try linkSeen(a, common, record, wt)).?);
}

test "worktree -r: a directory no worktree record names, or a path that is not there, is refused as not a working tree before anything is named or set aside" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try f.ignore("/secret.txt");
    const dirs = try std.fmt.allocPrint(a, "{s}@worktrees", .{f.clone});
    const plain = try std.fs.path.join(a, &.{ dirs, "plain" });
    try f.write(plain, "secret.txt", "only here");
    const repo = try std.fs.path.join(a, &.{ dirs, "repo" });
    try f.write(repo, "secret.txt", "only here");
    try shIn(&f, repo, "git init -q && git commit -q --allow-empty -m only-here");
    const before = try f.snapshot(true);

    for ([_][]const u8{ "plain", "repo", "never" }) |branch| for ([_]bool{ false, true }) |force| {
        const argv: []const []const u8 = if (force) &.{ "proj/widget", branch, "-r", "--force" } else &.{ "proj/widget", branch, "-r" };
        const got = try f.run(worktree_cmd.command.run, argv);
        const wt = try std.fs.path.join(a, &.{ try fsutil.realPathOrSelf(a, dirs), branch });
        const want = try std.fmt.allocPrint(a, "holt: {s} is not a working tree of {s}\n", .{ try q_test(a, wt), try q_test(a, f.clone) });
        if (got.code != 1 or got.out.len != 0 or !std.mem.eql(u8, got.err, want)) {
            std.debug.print("{s} force={}: wanted only {s}got {d}:\n{s}{s}\n", .{ branch, force, want, got.code, got.out, got.err });
            return error.TestUnexpectedResult;
        }
    };
    try testing.expectEqualStrings("only here", try kept.content.readSmall(a, try std.fs.path.join(a, &.{ plain, "secret.txt" })));
    try testing.expectEqualStrings("only here", try kept.content.readSmall(a, try std.fs.path.join(a, &.{ repo, "secret.txt" })));
    try testing.expect(fsutil.exists(try std.fs.path.join(a, &.{ repo, ".git" })));
    try testing.expectEqualDeep(before, try f.snapshot(true));
}

/// Test-only: what `probeCloneLock` tries to lock, and whether it found
/// the lock held.
var probe_kctx: ?kept.Ctx = null;
var probe_common: []const u8 = "";
var probe_held: bool = false;

fn probeCloneLock() void {
    const kctx = probe_kctx orelse return;
    if (kept.lockClone(kctx, probe_common)) |l| l.release() else |err| probe_held = err == error.WouldBlock;
}

test "worktree -r: a worktree whose directory is gone is removed under the clone's lock, and its HEAD, a per-worktree ref, or an operation in progress changing after the weighing keeps its record" {
    try skipWithoutLinks();
    const cases = [_][]const u8{
        "c=$(git -C '{c}' -c user.name=t -c user.email=t@t.invalid commit-tree -m moved 'HEAD^{tree}') && git --git-dir='{r}' update-ref --no-deref HEAD \"$c\"",
        "git --git-dir='{r}' update-ref refs/bisect/bad HEAD",
        "echo start > '{r}/BISECT_LOG'",
        "",
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try setupWithProject(a, &sb);
        try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
        const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
        const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
        const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n");
        try std.Io.Dir.cwd().deleteTree(io(), wt);

        if (case.len == 0) {
            kept_ctx.lock_nonblocking_for_test = true;
            defer kept_ctx.lock_nonblocking_for_test = false;
            probe_kctx = f.kctx;
            probe_common = try fsutil.joinSlashy(a, f.clone, ".git");
            probe_held = false;
            before_reread_for_test = probeCloneLock;
            defer {
                before_reread_for_test = null;
                probe_kctx = null;
            }
            const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
            if (got.code != 0) std.debug.print("{s}\n", .{got.err});
            try testing.expectEqual(@as(u8, 0), got.code);
            try testing.expect(probe_held);
            try testing.expect(!fsutil.exists(record));
            continue;
        }
        const cmd = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, case, "{c}", f.clone), "{r}", record);
        const seam = Seam.install(&sb, &.{cmd});
        defer seam.restore();
        const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        if (got.code != 1 or !contains(got.err, "changed while it was being weighed (its HEAD, a ref, an operation in progress, its staged changes, or a submodule git directory in its record changed, or git could not read them again); its record was kept; run the command again\n")) {
            std.debug.print("{s}: wanted a refusal in:\n{s}{s}\n", .{ case, got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(fsutil.exists(record));
    }
}

test "worktree -r --force: setting aside that fails partway names each entry it set aside, with where it is held, and says the worktree was kept, never that nothing was deleted" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const m = try makeFeature(a, &sb, false);
    const f = &m.f;
    try f.ignore("/cache/");
    try f.write(m.wt, "notes.txt", "only here");
    try f.write(m.wt, "cache/.held.icloud", "a placeholder");

    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r", "--force" });
    const shown = try fsutil.contractTilde(a, app.envOf_current(), try fsutil.joinSlashy(a, m.wt, "notes.txt"));
    const lead = try std.fmt.allocPrint(a, "set aside {s} (kept/.holt-aside/", .{shown});
    const at = std.mem.indexOf(u8, got.out, lead);
    if (got.code != 1 or at == null or contains(got.err, "nothing was deleted")) {
        std.debug.print("wanted notes.txt set aside and the refusal, got {d}:\n{s}{s}\n", .{ got.code, got.out, got.err });
        return error.TestUnexpectedResult;
    }
    const rest = got.out[at.? + lead.len ..];
    const stamp = rest[0 .. std.mem.indexOfScalar(u8, rest, ')') orelse return error.TestUnexpectedResult];
    const want = try std.fmt.allocPrint(a, "holt: the worktree was kept; set aside: {s} (kept/.holt-aside/{s})\n", .{ shown, stamp });
    if (!contains(got.err, want)) {
        std.debug.print("wanted {s}in:\n{s}\n", .{ want, got.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(fsutil.exists(try fsutil.joinSlashy(a, m.wt, "notes.txt")));
    try testing.expect(fsutil.exists(m.record));
    const held = try f.asideData("notes.txt");
    try testing.expectEqual(@as(usize, 1), held.len);
    try testing.expectEqualStrings("only here", held[0]);
}

test "worktree -r: a HEAD that moves after holt's links were recorded and removed names each, with where it is held, and says the worktree was kept" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const m = try makeFeature(a, &sb, false);
    const f = &m.f;
    try f.ignore("/.env");
    try f.write(m.wt, ".env", "kept");
    try f.keep(m.wt, ".env");
    try testing.expectEqual(kept.content.Entry.symlink, try kept.content.entryAt(try fsutil.joinSlashy(a, m.wt, ".env")));
    const seam = Seam.install(&sb, &.{try std.fmt.allocPrint(a, "git -C '{s}' -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m moved", .{m.wt})});
    defer seam.restore();

    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    var stamp: ?[]const u8 = null;
    var d = try std.Io.Dir.cwd().openDir(io(), try f.kctx.layout.asideDir(a), .{ .iterate = true });
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        const man = (try kept.aside.readManifest(a, f.kctx.layout, e.name)) orelse continue;
        if (std.mem.eql(u8, man.rel, ".env") and man.links.len == 1) stamp = try a.dupe(u8, e.name);
    }
    const shown = try fsutil.contractTilde(a, app.envOf_current(), try fsutil.joinSlashy(a, m.wt, ".env"));
    const want = try std.fmt.allocPrint(a, "changed while it was being weighed (a ref or HEAD moved, or git could not read them again); the worktree was kept; set aside: {s} (kept/.holt-aside/{s}); run the command again\n", .{ shown, stamp orelse "" });
    if (got.code != 1 or stamp == null or !contains(got.err, want)) {
        std.debug.print("wanted {s}in:\n{s}{s}\n", .{ want, got.out, got.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(fsutil.exists(m.wt));
}

/// A worktree `holt worktree` made on a new branch `feature` of a clone
/// that is a member of a project, with a submodule `sub` when `sub`: the
/// fixture, the worktree, and its record.
const Made = struct { f: Fixture, wt: []const u8, record: []const u8 };

fn makeFeature(a: std.mem.Allocator, sb: *testutil.Sandbox, sub: bool) !Made {
    const f = try setupWithProject(a, sb);
    if (sub) _ = try withSubmodule(&f, false);
    try testutil.runGit(sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n");
    return .{ .f = f, .wt = wt, .record = record };
}

test "worktree -r: a worktree whose directory is gone and whose record holds a submodule git directory with a commit only there is refused, naming that commit; --force names it as deleted" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |force| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const m = try makeFeature(a, &sb, true);
        const f = &m.f;
        try shIn(f, m.wt, "git -c protocol.file.allow=always submodule update -q --init && cd sub && git commit -q --allow-empty -m only-in-worktree-submodule");
        const only = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "HEAD" }, try std.fs.path.join(a, &.{ m.wt, "sub" }))).stdout, " \r\n");
        const modgit = try std.fs.path.join(a, &.{ m.record, "modules", "sub" });
        try std.Io.Dir.cwd().deleteTree(io(), m.wt);
        const mod_shown = try fsutil.contractTilde(a, app.envOf_current(), modgit);
        if (force) {
            const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r", "--force" });
            if (got.code != 0 or !contains(got.out, try std.fmt.allocPrint(a, "deleting commit {s}, which only the HEAD of {s} holds", .{ only, mod_shown }))) {
                std.debug.print("wanted {s} named as deleted in:\n{s}{s}\n", .{ only, got.out, got.err });
                return error.TestUnexpectedResult;
            }
            try testing.expect(!fsutil.exists(m.record));
            continue;
        }
        const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        const risk = try std.fmt.allocPrint(a, "commit {s}, which only the HEAD of {s} holds", .{ only, mod_shown });
        if (got.code != 1 or !contains(got.err, risk)) {
            std.debug.print("wanted {s} in:\n{s}{s}\n", .{ risk, got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(fsutil.exists(modgit));
        const remote = std.mem.trim(u8, (try git.runInRepo(a, &.{ "config", "--file", ".gitmodules", "submodule.sub.url" }, f.clone)).stdout, " \r\n");
        try runHint(f, got.err, risk, "");
        const removed = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        if (removed.code != 0) {
            std.debug.print("the removal after the hint failed:\n{s}\n", .{removed.err});
            return error.TestUnexpectedResult;
        }
        try testing.expect(!fsutil.exists(m.record));
        try testing.expectEqualStrings("commit\n", (try git.runInRepo(a, &.{ "cat-file", "-t", only }, remote)).stdout);
    }
}

test "repo remove --clone: a linked worktree whose directory is gone and whose record holds a submodule git directory with a commit only there is named with that commit, and no removal" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    _ = try withSubmodule(&f, false);
    const wt = try std.fs.path.join(a, &.{ sb.root, "linked" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
    const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n");
    try shIn(&f, wt, "git -c protocol.file.allow=always submodule update -q --init && cd sub && git commit -q --allow-empty -m only-in-worktree-submodule");
    const only = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "HEAD" }, try std.fs.path.join(a, &.{ wt, "sub" }))).stdout, " \r\n");
    const modgit = try std.fs.path.join(a, &.{ record, "modules", "sub" });
    try std.Io.Dir.cwd().deleteTree(io(), wt);
    const mod_shown = try fsutil.contractTilde(a, app.envOf_current(), modgit);

    var got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    const risk = try std.fmt.allocPrint(a, "commit {s}, which only the HEAD of {s} holds", .{ only, mod_shown });
    if (got.code != 1 or !contains(got.err, risk)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ risk, got.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(!contains(got.err, ", which is gone (run: "));
    try testing.expect(fsutil.exists(modgit));
    const remote = std.mem.trim(u8, (try git.runInRepo(a, &.{ "config", "--file", ".gitmodules", "submodule.sub.url" }, f.clone)).stdout, " \r\n");
    try runHint(&f, got.err, risk, "");
    got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expect(!contains(got.err, only));
    try runHint(&f, got.err, ", which is gone ", "");
    got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    if (got.code != 0) {
        std.debug.print("delete refused:\n{s}\n", .{got.err});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("commit\n", (try git.runInRepo(a, &.{ "cat-file", "-t", only }, remote)).stdout);
}

test "worktree -r: a worktree whose directory is gone keeps its record when a ref or an operation in progress of a submodule git directory under it, or its staged changes, change after the weighing" {
    try skipWithoutLinks();
    const cases = [_][]const u8{
        "git --git-dir='{m}' --work-tree='{m}' update-ref refs/heads/extra HEAD",
        "echo start > '{m}/BISECT_LOG'",
        "git --git-dir='{r}' read-tree --empty",
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const m = try makeFeature(a, &sb, true);
        try shIn(&m.f, m.wt, "git -c protocol.file.allow=always submodule update -q --init");
        const modgit = try std.fs.path.join(a, &.{ m.record, "modules", "sub" });
        try std.Io.Dir.cwd().deleteTree(io(), m.wt);
        const cmd = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, case, "{m}", modgit), "{r}", m.record);
        const seam = Seam.install(&sb, &.{cmd});
        defer seam.restore();
        const got = try m.f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        if (got.code != 1 or !contains(got.err, "changed while it was being weighed (its HEAD, a ref, an operation in progress, its staged changes, or a submodule git directory in its record changed, or git could not read them again); its record was kept; run the command again\n")) {
            std.debug.print("{s}: wanted a refusal in:\n{s}{s}\n", .{ case, got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(fsutil.exists(modgit));
    }
}

test "worktree -r --force: a worktree whose .git is gone is refused, writing no .git, leaving its record, and another repository's worktree at a path a stale record names, as they were" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const m = try makeFeature(a, &sb, false);
    const f = &m.f;
    const other = try std.fs.path.join(a, &.{ try fsutil.realPathOrSelf(a, sb.root), "shared-wt" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", other });
    try std.Io.Dir.cwd().deleteTree(io(), other);
    const b = try std.fs.path.join(a, &.{ sb.root, "otherrepo" });
    try fsutil.ensureDir(b);
    try shIn(f, b, try std.fmt.allocPrint(a, "git init -q -b main && git commit -q --allow-empty -m b && git worktree add -q --detach {s}", .{other}));
    try fsutil.removePath(try std.fs.path.join(a, &.{ m.wt, ".git" }));
    const roots: []const []const u8 = &.{ m.wt, other, try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees" }), try std.fs.path.join(a, &.{ b, ".git", "worktrees" }) };
    const before = try treesState(a, roots);

    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r", "--force" });
    if (got.code != 1 or got.out.len != 0) {
        std.debug.print("wanted the refusal alone, got {d}:\n{s}{s}\n", .{ got.code, got.out, got.err });
        return error.TestUnexpectedResult;
    }
    try expectUnresolved(f, got.err, m.wt, "a linked working tree whose .git is gone", try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
    try testing.expectEqualStrings(before, try treesState(a, roots));
    try testing.expect(fsutil.exists(m.record));
}

test "worktree -r: an am paused in a worktree whose directory is gone is refused, naming the command that brings the worktree back and those that finish or abort the am there, which settle it; --force names it as deleted" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |force| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const m = try makeFeature(a, &sb, false);
        const f = &m.f;
        const patch = try std.fs.path.join(a, &.{ sb.root, "one.patch" });
        try shIn(f, m.wt, try std.fmt.allocPrint(a, "echo one > README && git add README && git commit -q -m one && git format-patch -1 --stdout HEAD > '{s}' && git reset -q --hard HEAD~1 && echo two > README && git add README && git commit -q -m two && ! git am '{s}' >/dev/null 2>&1", .{ patch, patch }));
        const applying = try std.fs.path.join(a, &.{ m.record, "rebase-apply" });
        try testing.expect(fsutil.exists(applying));
        try std.Io.Dir.cwd().deleteTree(io(), m.wt);
        const shown = try fsutil.contractTilde(a, app.envOf_current(), m.wt);
        const wq = try q_test(a, m.wt);
        if (force) {
            const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r", "--force" });
            const lost = try std.fmt.allocPrint(a, "deleting the am in progress in {s}\n", .{shown});
            if (got.code != 0 or !contains(got.out, lost)) {
                std.debug.print("wanted {s} in:\n{s}{s}\n", .{ lost, got.out, got.err });
                return error.TestUnexpectedResult;
            }
            try testing.expect(!fsutil.exists(m.record));
            continue;
        }
        var got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        const back = try std.fmt.allocPrint(a, "  {s}: its directory is gone; bring it back from its record first (run: ", .{shown});
        const op = try std.fmt.allocPrint(a, "  {s}: am in progress in {s}; finish it or abort it (run: git -C {s} am --continue, or git -C {s} am --abort)\n", .{ shown, shown, wq, wq });
        if (got.code != 1 or !contains(got.err, back) or !contains(got.err, op)) {
            std.debug.print("wanted {s} and {s} in:\n{s}{s}\n", .{ back, op, got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(fsutil.exists(applying));
        try runHint(f, got.err, back[0 .. back.len - "(run: ".len], "");
        got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        const there = try std.fmt.allocPrint(a, "am in progress in {s}; finish it or abort it ", .{shown});
        if (got.code != 1 or !contains(got.err, there)) {
            std.debug.print("wanted {s} once it is back in:\n{s}{s}\n", .{ there, got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try runAlternative(f, got.err, there, 1);
        got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        if (got.code != 0) {
            std.debug.print("the removal after the hints failed:\n{s}{s}\n", .{ got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(!fsutil.exists(m.record));
    }
}

test "worktree -r: staged changes only the record of a worktree whose directory is gone holds are refused, named with the commands that bring the worktree back and stash them, which settle it, and --force names them as deleted; for one whose .git is gone, the record is refused unweighed, even with --force, and left as it was" {
    try skipWithoutLinks();
    for ([_]Link{ .absent, .unresolved }) |link| for ([_]bool{ false, true }) |force| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const m = try makeFeature(a, &sb, false);
        const f = &m.f;
        try shIn(f, m.wt, "echo staged > README && git add README");
        switch (link) {
            .absent => try std.Io.Dir.cwd().deleteTree(io(), m.wt),
            else => try fsutil.removePath(try std.fs.path.join(a, &.{ m.wt, ".git" })),
        }
        const shown = try fsutil.contractTilde(a, app.envOf_current(), m.wt);
        const wq = try q_test(a, m.wt);
        const staged = try std.fmt.allocPrint(a, "staged changes only {s}'s record holds", .{shown});
        const argv: []const []const u8 = if (force) &.{ "proj/widget", "feature", "-r", "--force" } else &.{ "proj/widget", "feature", "-r" };
        if (link == .unresolved) {
            const roots: []const []const u8 = &.{ m.wt, std.fs.path.dirname(m.record).? };
            const before = try treesState(a, roots);
            const got = try f.run(worktree_cmd.command.run, argv);
            try testing.expectEqual(@as(u8, 1), got.code);
            try testing.expect(!contains(got.err, staged));
            try expectUnresolved(f, got.err, m.wt, "a linked working tree whose .git is gone", try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
            try testing.expectEqualStrings(before, try treesState(a, roots));
            continue;
        }
        if (force) {
            const got = try f.run(worktree_cmd.command.run, argv);
            if (got.code != 0 or !contains(got.out, try std.fmt.allocPrint(a, "deleting the {s}\n", .{staged}))) {
                std.debug.print("wanted the staged changes named as deleted in:\n{s}{s}\n", .{ got.out, got.err });
                return error.TestUnexpectedResult;
            }
            try testing.expect(!fsutil.exists(m.record));
            continue;
        }
        var got = try f.run(worktree_cmd.command.run, argv);
        const line = try std.fmt.allocPrint(a, "  {s}: {s}; commit or stash them there (run: git -C {s} stash push)\n", .{ shown, staged, wq });
        const first = try std.fmt.allocPrint(a, "  {s}: its directory is gone; bring it back from its record first ", .{shown});
        if (got.code != 1 or !contains(got.err, line) or !contains(got.err, first)) {
            std.debug.print("wanted {s} and {s} in:\n{s}{s}\n", .{ first, line, got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try runHint(f, got.err, first, "");
        try runHint(f, got.err, line[0..std.mem.indexOf(u8, line, "(run: ").?], "");
        got = try f.run(worktree_cmd.command.run, argv);
        if (got.code != 0) {
            std.debug.print("the removal after the hints failed:\n{s}{s}\n", .{ got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(!fsutil.exists(m.record));
        try testing.expectEqualStrings("staged\n", (try git.runInRepo(a, &.{ "show", "refs/stash^2:README" }, f.clone)).stdout);
    };
}

test "worktree -r: a path a worktree record names that holds another repository's working tree is refused, even with --force, never weighed, set aside, or removed, leaving that working tree and the record as they were; once that working tree is gone the record is weighed and removed" {
    try skipWithoutLinks();
    const Case = enum { plain, force, at_risk };
    for (std.enums.values(Case)) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const m = try makeFeature(a, &sb, false);
        const f = &m.f;
        if (case == .at_risk) try shIn(f, m.wt, "git switch -q --detach && git commit -q --allow-empty -m only-in-head");
        const only = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "HEAD" }, m.wt)).stdout, " \r\n");
        try std.Io.Dir.cwd().deleteTree(io(), m.wt);
        const b = try std.fs.path.join(a, &.{ sb.root, "otherrepo" });
        try fsutil.ensureDir(b);
        try shIn(f, b, try std.fmt.allocPrint(a, "git init -q -b main && git commit -q --allow-empty -m b && git worktree add -q --detach '{s}'", .{m.wt}));
        try f.write(m.wt, "b-only.txt", "b's own");
        const before = try f.snapshot(true);
        const roots: []const []const u8 = &.{ m.wt, std.fs.path.dirname(m.record).?, try std.fs.path.join(a, &.{ b, ".git" }) };
        const trees = try treesState(a, roots);

        const argv: []const []const u8 = if (case == .force) &.{ "proj/widget", "feature", "-r", "--force" } else &.{ "proj/widget", "feature", "-r" };
        var got = try f.run(worktree_cmd.command.run, argv);
        if (got.code != 1 or got.out.len != 0 or contains(got.err, "not kept")) {
            std.debug.print("{s}: wanted the refusal alone, got {d}:\n{s}{s}\n", .{ @tagName(case), got.code, got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try expectUnresolved(f, got.err, m.wt, "a linked working tree whose .git leads to another git directory than its record", try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
        try testing.expectEqualStrings(trees, try treesState(a, roots));
        try expectSame(before, try f.snapshot(true));

        try shIn(f, b, try std.fmt.allocPrint(a, "git worktree remove --force '{s}'", .{m.wt}));
        got = try f.run(worktree_cmd.command.run, argv);
        if (case == .at_risk) {
            const risk = try std.fmt.allocPrint(a, "commit {s}, which only the HEAD of worktree feature holds", .{only});
            if (got.code != 1 or !contains(got.err, risk)) {
                std.debug.print("wanted {s} in:\n{s}{s}\n", .{ risk, got.out, got.err });
                return error.TestUnexpectedResult;
            }
            try testing.expect(fsutil.exists(m.record));
            try runHint(f, got.err, risk, "");
            got = try f.run(worktree_cmd.command.run, argv);
        }
        if (got.code != 0) {
            std.debug.print("{s}: the removal once that working tree is gone failed:\n{s}{s}\n", .{ @tagName(case), got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try testing.expect(!fsutil.exists(m.record));
    }
}

test "repo remove --clone: a linked worktree whose path holds another repository's working tree is named with what is seen there and git worktree list alone, leaving that working tree and the record as they were; once that working tree is gone the record's removal is named, which settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const wt = try std.fs.path.join(a, &.{ try fsutil.realPathOrSelf(a, sb.root), "linked" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", wt });
    const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n");
    try std.Io.Dir.cwd().deleteTree(io(), wt);
    const b = try std.fs.path.join(a, &.{ sb.root, "otherrepo" });
    try fsutil.ensureDir(b);
    try shIn(&f, b, try std.fmt.allocPrint(a, "git init -q -b main && git commit -q --allow-empty -m b && git worktree add -q --detach '{s}'", .{wt}));
    try f.write(wt, "b-only.txt", "b's own");
    const roots: []const []const u8 = &.{ wt, std.fs.path.dirname(record).?, try std.fs.path.join(a, &.{ b, ".git" }) };
    const before = try treesState(a, roots);
    const cq = try q_test(a, f.clone);

    var got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    if (got.code != 1 or contains(got.err, "not kept")) {
        std.debug.print("wanted a refusal in:\n{s}\n", .{got.err});
        return error.TestUnexpectedResult;
    }
    try expectUnresolved(&f, got.err, wt, "a linked working tree whose .git leads to another git directory than its record", try std.fmt.allocPrint(a, "git -C {s}", .{cq}));
    try testing.expectEqualStrings(before, try treesState(a, roots));

    try shIn(&f, b, try std.fmt.allocPrint(a, "git worktree remove --force '{s}'", .{wt}));
    got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    const line = try std.fmt.allocPrint(a, "  {s}, which is gone (run: git -C {s} worktree remove {s})\n", .{ try fsutil.contractTilde(a, app.envOf_current(), wt), cq, try q_test(a, wt) });
    if (got.code != 1 or !contains(got.err, line)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ line, got.err });
        return error.TestUnexpectedResult;
    }
    try runHint(&f, got.err, line[0..std.mem.indexOf(u8, line, "(run: ").?], "");
    got = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    if (got.code != 0) {
        std.debug.print("delete refused:\n{s}\n", .{got.err});
        return error.TestUnexpectedResult;
    }
    try testing.expect(!fsutil.exists(f.clone));
}

test "a command reaching a git directory alone names it as its own word, which the shell expands when it starts with ~" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const home = try fsutil.realPathOrSelf(a, sb.root);
    const scope = try testutil.EnvScope.install(a, &.{.{ "HOME", home }});
    defer scope.restore();
    const dir = try std.fs.path.join(a, &.{ home, "gd.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", dir });
    const ws = try testutil.testWorkspace(a, sb.root);
    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = .{ .ws = ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    const cmd = try settleRisk(&ctx, .{ .repo = dir, .risk = .{ .what = .stashes }, .git_dir_only = true });
    try testing.expectEqualStrings("git --git-dir ~/gd.git --work-tree ~/gd.git stash list", cmd);
    try sb.git_env.map.put("HOME", home);
    const res = try proc.runEnv(a, &.{ "sh", "-c", cmd }, null, &sb.git_env.map);
    if (res.status != 0) {
        std.debug.print("{s} failed:\n{s}\n", .{ cmd, res.stderr });
        return error.TestUnexpectedResult;
    }
}

test "removeCmdFor: rm -rf for a POSIX shell, and for PowerShell Remove-Item -Recurse -Force -LiteralPath, which takes each path whole and a comma between them, on every platform" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = null, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    const one = "/c/.git/worktrees/it's";
    const two = "/c/.git/worktrees/z";
    try testing.expectEqualStrings("rm -rf '/c/.git/worktrees/it'\\''s'", try removeCmdFor(&ctx, &.{one}, .posix));
    try testing.expectEqualStrings("rm -rf '/c/.git/worktrees/it'\\''s' /c/.git/worktrees/z", try removeCmdFor(&ctx, &.{ one, two }, .posix));
    try testing.expectEqualStrings("Remove-Item -Recurse -Force -LiteralPath '/c/.git/worktrees/it''s'", try removeCmdFor(&ctx, &.{one}, .powershell));
    try testing.expectEqualStrings("Remove-Item -Recurse -Force -LiteralPath '/c/.git/worktrees/it''s', /c/.git/worktrees/z", try removeCmdFor(&ctx, &.{ one, two }, .powershell));
}

test "relinkCmdFor and repointCmdFor: the POSIX form and the PowerShell form each name the one file they write, on every platform, and the POSIX form writes the bytes linkText and recordText give" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = null, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    const sep = std.fs.path.sep_str;
    const tree = "/w/it's tree";
    const record = "/c/.git/worktrees/it's";
    try testing.expectEqualStrings("printf 'gitdir: %s\\n' '/c/.git/worktrees/it'\\''s' > '/w/it'\\''s tree" ++ sep ++ ".git'", try relinkCmdFor(&ctx, tree, record, false, .posix));
    try testing.expectEqualStrings("mkdir -p '/w/it'\\''s tree' && printf 'gitdir: %s\\n' '/c/.git/worktrees/it'\\''s' > '/w/it'\\''s tree" ++ sep ++ ".git' && git -C '/w/it'\\''s tree' checkout-index -a", try relinkCmdFor(&ctx, tree, record, true, .posix));
    try testing.expectEqualStrings("Set-Content -NoNewline -LiteralPath '/w/it''s tree" ++ sep ++ ".git' -Value ('gitdir: ' + '/c/.git/worktrees/it''s' + \"`n\")", try relinkCmdFor(&ctx, tree, record, false, .powershell));
    try testing.expectEqualStrings("New-Item -ItemType Directory -Force -Path '/w/it''s tree' && Set-Content -NoNewline -LiteralPath '/w/it''s tree" ++ sep ++ ".git' -Value ('gitdir: ' + '/c/.git/worktrees/it''s' + \"`n\") && git -C '/w/it''s tree' checkout-index -a", try relinkCmdFor(&ctx, tree, record, true, .powershell));
    try testing.expectEqualStrings("printf '%s/.git\\n' '/w/it'\\''s tree' > '/c/.git/worktrees/it'\\''s" ++ sep ++ "gitdir'", try repointCmdFor(&ctx, record, tree, .posix));
    try testing.expectEqualStrings("Set-Content -NoNewline -LiteralPath '/c/.git/worktrees/it''s" ++ sep ++ "gitdir' -Value ('/w/it''s tree' + \"/.git`n\")", try repointCmdFor(&ctx, record, tree, .powershell));
    try testing.expectEqualStrings("gitdir: C:/c/.git/worktrees/x\n", try linkText(a, "C:\\c\\.git\\worktrees\\x"));
    try testing.expectEqualStrings("C:/w/x/.git\n", try recordText(a, "C:\\w\\x"));

    if (builtin.os.tag == .windows) return;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const wt = try std.fs.path.join(a, &.{ root, "it's tree" });
    const rec = try std.fs.path.join(a, &.{ root, "rec's" });
    try fsutil.ensureDir(wt);
    try fsutil.ensureDir(rec);
    for ([_][]const u8{ try relinkCmdFor(&ctx, wt, rec, false, .posix), try repointCmdFor(&ctx, rec, wt, .posix) }) |cmd| {
        const res = try proc.runEnv(a, &.{ "sh", "-c", cmd }, null, null);
        try testing.expectEqual(@as(u8, 0), res.status);
    }
    try testing.expectEqualStrings(try linkText(a, rec), try kept.content.readSmall(a, try std.fs.path.join(a, &.{ wt, ".git" })));
    try testing.expectEqualStrings(try recordText(a, wt), try kept.content.readSmall(a, try std.fs.path.join(a, &.{ rec, "gitdir" })));
}

test "relinkCmdFor and repointCmdFor: the PowerShell forms write the tree's .git and the record's gitdir when both paths hold a typographic single quote" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = null, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    for ([_][]const u8{ "'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}" }) |quote| {
        const wt = try std.fs.path.join(a, &.{ root, try std.mem.concat(a, u8, &.{ "Bob", quote, "s tree" }) });
        const rec = try std.fs.path.join(a, &.{ root, try std.mem.concat(a, u8, &.{ "rec", quote, "; echo x > pwned", quote }) });
        try fsutil.ensureDir(wt);
        try fsutil.ensureDir(rec);
        for ([_][]const u8{ try relinkCmdFor(&ctx, wt, rec, false, .powershell), try repointCmdFor(&ctx, rec, wt, .powershell) }) |cmd| {
            const res = proc.run(a, &.{ "timeout", "60", "pwsh", "-NoProfile", "-NonInteractive", "-Command", cmd }, root) catch return error.SkipZigTest;
            if (res.status == 127) return error.SkipZigTest;
            if (res.status != 0) std.debug.print("{s}\n{s}\n", .{ cmd, res.stderr });
            try testing.expectEqual(@as(u32, 0), res.status);
        }
        try testing.expectEqualStrings(try linkText(a, rec), try kept.content.readSmall(a, try std.fs.path.join(a, &.{ wt, ".git" })));
        try testing.expectEqualStrings(try recordText(a, wt), try kept.content.readSmall(a, try std.fs.path.join(a, &.{ rec, "gitdir" })));
        try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try std.fs.path.join(a, &.{ root, "pwned" })));
    }
}

test "worktree -r: a commit only the worktree's reflogs name is not weighed and is removed with its record" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    try testing.expectEqual(@as(u8, 0), made.code);
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, wt)).stdout, " \r\n");
    try shIn(&f, wt, "git switch -q --detach && git commit -q --allow-empty -m only-in-reflog && git switch -q feature");
    const logged = try kept.content.readSmall(a, try std.fs.path.join(a, &.{ record, "logs", "HEAD" }));
    try testing.expect(contains(logged, "only-in-reflog"));

    const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    if (got.code != 0) std.debug.print("{s}{s}\n", .{ got.out, got.err });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(record));
}

test "worktree -r: an extra record naming the worktree's path that holds a commit only its HEAD holds is refused, even with --force, never weighed or removed, leaving every record and the tree as they were; once the user settles it and removes the copy, the removal goes through with the commit kept" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |force| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try setupWithProject(a, &sb);
        try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
        const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
        try testing.expectEqual(@as(u8, 0), made.code);
        const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
        const records = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees" }));
        const own = try std.fs.path.join(a, &.{ records, "feature" });
        const copy = try std.fs.path.join(a, &.{ records, "z-copy" });
        const cp = try proc.runEnv(a, &.{ "cp", "-R", own, copy }, null, &sb.git_env.map);
        try testing.expectEqual(@as(u8, 0), cp.status);
        const made_commit = try git.runInRepo(a, &.{ "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "only-in-copy" }, f.clone);
        try testing.expectEqual(@as(u32, 0), made_commit.status);
        const only = std.mem.trim(u8, made_commit.stdout, " \r\n");
        try f.write(copy, "HEAD", try std.fmt.allocPrint(a, "{s}\n", .{only}));
        const roots: []const []const u8 = &.{ records, wt };
        const before = try treesState(a, roots);

        const argv: []const []const u8 = if (force) &.{ "proj/widget", "feature", "-r", "--force" } else &.{ "proj/widget", "feature", "-r" };
        const refused = try f.run(worktree_cmd.command.run, argv);
        if (refused.code != 1 or refused.out.len != 0 or std.mem.count(u8, refused.err, "\n") != 1 or contains(refused.err, only)) {
            std.debug.print("force={}: wanted the refusal alone, got {d}:\n{s}{s}\n", .{ force, refused.code, refused.out, refused.err });
            return error.TestUnexpectedResult;
        }
        try expectUnresolved(&f, refused.err, try resolvedPath(a, wt), shared_seen, try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
        try testing.expectEqualStrings(before, try treesState(a, roots));

        try testutil.runGit(&sb, f.clone, &.{ "branch", "kept-copy", only });
        try std.Io.Dir.cwd().deleteTree(io(), copy);
        const got = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
        if (got.code != 0) std.debug.print("{s}{s}\n", .{ got.out, got.err });
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expect(!fsutil.exists(wt));
        try testing.expectEqualStrings("commit\n", (try git.runInRepo(a, &.{ "cat-file", "-t", only }, f.clone)).stdout);
    }
}

test "repo remove --clone: an extra record of a submodule's linked working tree that holds a commit only its HEAD holds is named with what is seen there and the submodule's git worktree list alone, never weighed or removed, and every record is left as it was" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |force| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const sub = try withSubmodule(&f, false);
        const sub_wt = try std.fs.path.join(a, &.{ sb.root, "sub-wt" });
        try testutil.runGit(&sb, sub, &.{ "worktree", "add", "-q", "--detach", sub_wt });
        const module = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }));
        const records = try std.fs.path.join(a, &.{ module, "worktrees" });
        const own = try std.fs.path.join(a, &.{ records, "sub-wt" });
        const copy = try std.fs.path.join(a, &.{ records, "z-copy" });
        const cp = try proc.runEnv(a, &.{ "cp", "-R", own, copy }, null, &sb.git_env.map);
        try testing.expectEqual(@as(u8, 0), cp.status);
        const made_commit = try git.runInRepo(a, &.{ "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "only-in-copy" }, sub);
        try testing.expectEqual(@as(u32, 0), made_commit.status);
        const only = std.mem.trim(u8, made_commit.stdout, " \r\n");
        try f.write(copy, "HEAD", try std.fmt.allocPrint(a, "{s}\n", .{only}));
        const roots: []const []const u8 = &.{ records, sub_wt };
        const before = try treesState(a, roots);
        const wt = try fsutil.realPathOrSelf(a, sub_wt);
        const lead = try std.fmt.allocPrint(a, "the delete would leave a linked working tree of its submodules without their repository: {s}; ", .{try q_test(a, wt)});

        const argv: []const []const u8 = if (force) &.{ Fixture.key, "--clone", "--force", "--yes" } else &.{ Fixture.key, "--clone", "--yes" };
        const refused = try f.run(repo_cmd.remove_command.run, argv);
        if (refused.code != 1 or !contains(refused.err, lead) or contains(refused.err, only)) {
            std.debug.print("force={}: wanted {s} alone in:\n{s}\n", .{ force, lead, refused.err });
            return error.TestUnexpectedResult;
        }
        try expectUnresolved(&f, refused.err, wt, shared_seen, try std.fmt.allocPrint(a, "git --git-dir {s}", .{try q_test(a, module)}));
        try testing.expectEqualStrings(before, try treesState(a, roots));
        try testing.expect(fsutil.exists(f.clone));
    }
}

test "repo remove --clone: a submodule's linked working tree whose directory is gone is named with git --git-dir <module> worktree remove, never git -C at the gone tree, which settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const sub = try withSubmodule(&f, false);
    const sub_wt = try std.fs.path.join(a, &.{ sb.root, "sub-wt" });
    try testutil.runGit(&sb, sub, &.{ "worktree", "add", "-q", "--detach", sub_wt });
    const wq = try q_test(a, try fsutil.realPathOrSelf(a, sub_wt));
    try std.Io.Dir.cwd().deleteTree(io(), sub_wt);
    const module = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }));
    const lead = try std.fmt.allocPrint(a, "without their repository: {s}; ", .{wq});

    const refused = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    const want = try std.fmt.allocPrint(a, "{s}remove it first (run: git --git-dir {s} worktree remove {s})", .{ lead, try q_test(a, module), wq });
    if (!contains(refused.err, want)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ want, refused.err });
        return error.TestUnexpectedResult;
    }
    try runHint(&f, refused.err, lead, "");
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try std.fs.path.join(a, &.{ module, "worktrees" })));
    const after = try f.run(repo_cmd.remove_command.run, &.{ Fixture.key, "--clone", "--yes" });
    if (after.code != 0) std.debug.print("{s}\n", .{after.err});
    try testing.expectEqual(@as(u8, 0), after.code);
    try testing.expect(!fsutil.exists(f.clone));
}

test "moduleTreeGit: a submodule's linked working tree that is gone is reached through its git directory, with --work-tree there when the submodule's core.worktree names no directory, which removes its record" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const sub = try withSubmodule(&f, false);
    const module = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }));
    const sub_wt = try std.fs.path.join(a, &.{ sb.root, "sub-wt" });
    try testutil.runGit(&sb, sub, &.{ "worktree", "add", "-q", "--detach", sub_wt });
    const t: ModuleTree = .{ .path = try fsutil.realPathOrSelf(a, sub_wt), .module = module };
    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = null, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    const mq = try q(&ctx, module);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "git -C {s}", .{try q(&ctx, t.path)}), try moduleTreeGit(&ctx, t));
    try std.Io.Dir.cwd().deleteTree(io(), sub_wt);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "git --git-dir {s}", .{mq}), try moduleTreeGit(&ctx, t));
    try testutil.runGit(&sb, null, &.{ "--git-dir", module, "config", "core.worktree", try std.fs.path.join(a, &.{ sb.root, "no-such-dir" }) });
    const cmd = try moduleTreeGit(&ctx, t);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "git --git-dir {s} --work-tree {s}", .{ mq, mq }), cmd);
    const res = try proc.runEnv(a, &.{ "sh", "-c", try std.fmt.allocPrint(a, "{s} worktree remove {s}", .{ cmd, try q(&ctx, t.path) }) }, null, &sb.git_env.map);
    if (res.status != 0) std.debug.print("{s}\n", .{res.stderr});
    try testing.expectEqual(@as(u32, 0), res.status);
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try std.fs.path.join(a, &.{ module, "worktrees" })));
}

test "worktree -r: another repository's worktree reached through a symlinked worktrees dir, whose relative .git climbs above that link, is refused, even with --force, and its .git and files are left as they were" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    try testing.expectEqual(@as(u8, 0), made.code);
    const wt = std.mem.trim(u8, made.out, "\r\n");
    const wts = std.fs.path.dirname(wt).?;
    const elsewhere = try std.fs.path.join(a, &.{ sb.root, "elsewhere" });
    try fsutil.ensureDir(elsewhere);
    const moved = try std.fs.path.join(a, &.{ elsewhere, "wts" });
    try shIn(&f, sb.root, try std.fmt.allocPrint(a, "mv '{s}' '{s}' && ln -s '{s}' '{s}' && rm -rf '{s}/feature'", .{ wts, moved, moved, wts, moved }));
    const other = try std.fs.path.join(a, &.{ sb.root, "B" });
    try shIn(&f, sb.root, try std.fmt.allocPrint(a, "git init -q '{s}' && cd '{s}' && git commit -q --allow-empty -m b && git -c worktree.useRelativePaths=true worktree add -q -b bfeat '{s}/feature'", .{ other, other, moved }));
    const b_tree = try std.fs.path.join(a, &.{ moved, "feature" });
    try f.write(b_tree, "only-here.txt", "B's uncommitted work\n");
    const roots: []const []const u8 = &.{ b_tree, try std.fs.path.join(a, &.{ other, ".git" }), try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees" }) };
    const before = try treesState(a, roots);

    for ([_]bool{ false, true }) |force| {
        const argv: []const []const u8 = if (force) &.{ "proj/widget", "feature", "-r", "--force" } else &.{ "proj/widget", "feature", "-r" };
        const got = try f.run(worktree_cmd.command.run, argv);
        if (got.code != 1 or got.out.len != 0) {
            std.debug.print("force={}: wanted the refusal alone, got {d}:\n{s}{s}\n", .{ force, got.code, got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try expectUnresolved(&f, got.err, wt, "a linked working tree whose .git leads to another git directory than its record", try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
        try testing.expectEqualStrings(before, try treesState(a, roots));
    }
}

test "worktree -r: an extra record holding staged changes, at a path whose .git is gone, is refused, even with --force, naming what is seen there and git worktree list alone, and every record is left as it was" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const f = try setupWithProject(a, &sb);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    const made = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature" });
    try testing.expectEqual(@as(u8, 0), made.code);
    const wt = try fsutil.realPathOrSelf(a, std.mem.trim(u8, made.out, "\r\n"));
    const records = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees" }));
    const own = try std.fs.path.join(a, &.{ records, "feature" });
    const copy = try std.fs.path.join(a, &.{ records, "z-copy" });
    const cp = try proc.runEnv(a, &.{ "cp", "-R", own, copy }, null, &sb.git_env.map);
    try testing.expectEqual(@as(u8, 0), cp.status);
    try shIn(&f, f.clone, try std.fmt.allocPrint(a, "b=$(echo staged-only-in-copy | git hash-object -w --stdin) && GIT_INDEX_FILE='{s}/index' git update-index --add --cacheinfo 100644,$b,staged.txt", .{copy}));
    try fsutil.removePath(try std.fs.path.join(a, &.{ wt, ".git" }));
    const roots: []const []const u8 = &.{ records, wt };
    const before = try treesState(a, roots);

    for ([_]bool{ false, true }) |force| {
        const argv: []const []const u8 = if (force) &.{ "proj/widget", "feature", "-r", "--force" } else &.{ "proj/widget", "feature", "-r" };
        const refused = try f.run(worktree_cmd.command.run, argv);
        if (refused.code != 1 or refused.out.len != 0 or contains(refused.err, "staged changes only ")) {
            std.debug.print("force={}: wanted the refusal alone, got {d}:\n{s}{s}\n", .{ force, refused.code, refused.out, refused.err });
            return error.TestUnexpectedResult;
        }
        try expectUnresolved(&f, refused.err, try resolvedPath(a, wt), shared_seen, try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
        try testing.expectEqualStrings(before, try treesState(a, roots));
    }
}

test "worktree -r: a worktree path that is a symlink to nothing, or holds a file, is refused, even with --force, naming what is seen there and git worktree list alone, and left with its record as it was" {
    try skipWithoutLinks();
    for ([_]bool{ false, true }) |file| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(a, sb.root);
        defer state.restore();
        const m = try makeFeature(a, &sb, false);
        const f = &m.f;
        try std.Io.Dir.cwd().deleteTree(io(), m.wt);
        if (file) try f.write(std.fs.path.dirname(m.wt).?, std.fs.path.basename(m.wt), "not a tree\n") else try kept.content.createLink(try std.fs.path.join(a, &.{ sb.root, "no-such-dir" }), m.wt, .dir);
        const seen = if (file) "a linked working tree whose path holds something that is not a directory" else "a linked working tree whose path is a symlink to nothing";
        const roots: []const []const u8 = &.{ std.fs.path.dirname(m.record).?, m.wt };
        const before = try std.mem.concat(a, u8, &.{ try treesState(a, roots), (try kept.content.readLink(a, m.wt)) orelse "" });
        for ([_]bool{ false, true }) |force| {
            const argv: []const []const u8 = if (force) &.{ "proj/widget", "feature", "-r", "--force" } else &.{ "proj/widget", "feature", "-r" };
            const got = try f.run(worktree_cmd.command.run, argv);
            if (got.code != 1 or got.out.len != 0) {
                std.debug.print("file={} force={}: wanted the refusal alone, got {d}:\n{s}{s}\n", .{ file, force, got.code, got.out, got.err });
                return error.TestUnexpectedResult;
            }
            try expectUnresolved(f, got.err, m.wt, seen, try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
            try testing.expectEqualStrings(before, try std.mem.concat(a, u8, &.{ try treesState(a, roots), (try kept.content.readLink(a, m.wt)) orelse "" }));
        }
    }
}

test "worktree -r: a worktree path under a file is refused, even with --force, naming what is seen there and git worktree list alone, never mkdir; once the file is moved away, removing it settles it" {
    try skipWithoutLinks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(a, sb.root);
    defer state.restore();
    const m = try makeFeature(a, &sb, false);
    const f = &m.f;
    const parent = std.fs.path.dirname(m.wt).?;
    try std.Io.Dir.cwd().deleteTree(io(), parent);
    try f.write(std.fs.path.dirname(parent).?, std.fs.path.basename(parent), "not a tree\n");
    const roots: []const []const u8 = &.{ std.fs.path.dirname(m.record).?, parent };
    const before = try treesState(a, roots);
    for ([_]bool{ false, true }) |force| {
        const argv: []const []const u8 = if (force) &.{ "proj/widget", "feature", "-r", "--force" } else &.{ "proj/widget", "feature", "-r" };
        const got = try f.run(worktree_cmd.command.run, argv);
        if (got.code != 1 or got.out.len != 0 or contains(got.err, "mkdir")) {
            std.debug.print("force={}: wanted the refusal alone, got {d}:\n{s}{s}\n", .{ force, got.code, got.out, got.err });
            return error.TestUnexpectedResult;
        }
        try expectUnresolved(f, got.err, m.wt, "a linked working tree whose path lies under something that is not a directory", try std.fmt.allocPrint(a, "git -C {s}", .{try q_test(a, f.clone)}));
        try testing.expectEqualStrings(before, try treesState(a, roots));
    }
    try fsutil.removePath(parent);
    const removed = try f.run(worktree_cmd.command.run, &.{ "proj/widget", "feature", "-r" });
    if (removed.code != 0) {
        std.debug.print("wanted the removal, got {d}:\n{s}{s}\n", .{ removed.code, removed.out, removed.err });
        return error.TestUnexpectedResult;
    }
    try testing.expect(!fsutil.exists(m.record));
}
