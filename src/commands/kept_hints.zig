//! What every command says about a kept path reconcile could not settle,
//! and the commands that settle it. Every command names its path
//! quoted and tilde-contracted (`ui.quotePath`).

const std = @import("std");
const app = @import("../app.zig");
const kept = @import("../kept.zig");
const fsutil = @import("../fsutil.zig");
const ui = @import("../ui.zig");
const util = @import("kept_util.zig");
const git = @import("../git.zig");
const deleter = @import("deleter.zig");
const repo_cmd = @import("repo.zig");

const reconcile = kept.reconcile;

pub const Hint = struct {
    /// What is wrong, for a person.
    what: []const u8,
    /// Commands that each settle it; none when only the user can.
    run: []const []const u8 = &.{},
    /// Whether `holt sync` alone settles it.
    sync: bool = false,
};

const sync_only: []const []const u8 = &.{"holt sync"};

/// `list` copied into `alloc`, so a hint built from runtime strings
/// outlives the call that built it.
fn cmds(alloc: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    return alloc.dupe([]const u8, list);
}

fn syncHint(what: []const u8) Hint {
    return .{ .what = what, .run = sync_only, .sync = true };
}

/// The place `i` is about: `rel` under its working tree, which is `tree`
/// unless the item names another.
pub fn placeOf(alloc: std.mem.Allocator, tree: []const u8, i: reconcile.Item) ![]const u8 {
    const where = i.worktree orelse tree;
    if (std.mem.eql(u8, i.rel, ".")) return where;
    return fsutil.joinSlashy(alloc, where, i.rel);
}

fn keepCmd(ctx: *app.Ctx, flag: []const u8, p: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "holt keep {s}{s}", .{ flag, p });
}

/// The aside entry `stamp` of the kept store under `synced_root`, as a
/// quoted path.
fn entryPath(ctx: *app.Ctx, synced_root: []const u8, stamp: []const u8) ![]const u8 {
    const layout: kept.store.Layout = .{ .synced_root = synced_root };
    return util.q(ctx, try std.fs.path.join(ctx.alloc, &.{ try layout.asideDir(ctx.alloc), stamp }));
}

/// What stands where a parent directory of `rel` in the working tree at
/// `tree` belongs: the first component that is not a real directory, and
/// the hint that puts one there. A symlink holds no content, so removing it
/// is named; a file is only to be moved.
fn parentHint(ctx: *app.Ctx, tree: []const u8, rel: []const u8) !Hint {
    const a = ctx.alloc;
    var cur: []const u8 = tree;
    var it = std.mem.splitScalar(u8, rel, '/');
    var comp = it.next() orelse return .{ .what = "a parent directory is a symlink or a file, so it cannot be linked", .run = sync_only };
    while (it.next()) |next| : (comp = next) {
        cur = try std.fs.path.join(a, &.{ cur, comp });
        const at = try util.q(ctx, cur);
        switch (try kept.content.entryAt(cur)) {
            .dir => continue,
            .symlink => {
                const target = (try kept.content.readLink(a, cur)) orelse "";
                return .{
                    .what = try std.fmt.allocPrint(a, "its parent {s} is a symlink (-> {s}), where a directory belongs; remove the link and sync to make one", .{ at, try ui.printable(a, target) }),
                    .run = try cmds(a, &.{try std.fmt.allocPrint(a, "rm {s} && holt sync", .{at})}),
                };
            },
            .absent => break,
            else => return .{ .what = try std.fmt.allocPrint(a, "its parent {s} is a file, where a directory belongs; move the file elsewhere, then sync to make the directory", .{at}), .run = sync_only },
        }
    }
    return syncHint("a parent directory was not a real directory; sync links it once one is there");
}

fn backendName(ctx: *app.Ctx) []const u8 {
    return util.backendName(ctx);
}

/// What a path another machine kept says while that machine's content has
/// not arrived here: `machine_id` names that machine, `p` is the quoted
/// path, `retry` the command to run once the content is here, and `entry`
/// the aside entry the local content was set aside in, if any, named
/// before the ways out. Waiting is the normal fix; the machine can give the
/// path up, or, once it is gone, be retired here.
pub fn notArrived(ctx: *app.Ctx, machine_id: []const u8, p: []const u8, retry: []const u8, entry: ?[]const u8) !Hint {
    const a = ctx.alloc;
    const layout: kept.store.Layout = .{ .synced_root = ctx.context.?.ws.cfg.synced_root };
    const host = try ui.printable(a, (kept.store.readHost(a, layout, machine_id) catch null) orelse "a machine of unknown host");
    const held = if (entry) |e| try std.fmt.allocPrint(a, ", and its local content is set aside in aside entry {s}", .{e}) else "";
    return .{
        .what = try std.fmt.allocPrint(a, "kept on {s} (machine {s}), not here yet{s}: waiting is the normal fix, until {s} downloads it; if it will never arrive, run holt unkeep {s} on {s}, or, if that machine is gone, retire it here", .{ host, machine_id, held, backendName(ctx), p, host }),
        .run = try cmds(a, &.{ retry, try std.fmt.allocPrint(a, "holt keep --retire-machine {s}", .{machine_id}) }),
    };
}

/// What a retired machine is told when it writes a fact its retirement
/// `ret` does not cover (`kept.RetiredNotice`).
pub fn retiredWarning(alloc: std.mem.Allocator, ret: kept.store.Retired) ![]const u8 {
    return std.fmt.allocPrint(alloc, "this machine was retired on {s} from {s}; its new kept changes count again", .{ try kept.store.shownDate(alloc, ret.date), try ui.printable(alloc, ret.by_host) });
}

/// The kept copy of `rel` under the key `tree` files under (`key`, else
/// its clone's own), quoted.
fn keptCopy(ctx: *app.Ctx, tree: []const u8, key: ?[]const u8, synced_root: []const u8, rel: []const u8) ![]const u8 {
    const a = ctx.alloc;
    const layout: kept.store.Layout = .{ .synced_root = synced_root };
    const k = ownKey(ctx, tree, key) orelse return util.q(ctx, rel);
    return util.q(ctx, try layout.copyPath(a, k, rel));
}

/// The own key of the clone at `tree`, `key` when given.
fn ownKey(ctx: *app.Ctx, tree: []const u8, key: ?[]const u8) ?[]const u8 {
    if (key) |k| return k;
    const c = kept.clone.inspect(ctx.alloc, tree, ctx.context.?.ws.cfg.code_root) catch return null;
    return c.key;
}

/// The command that finishes moving a repo's kept files out of an earlier
/// identity: for a `local/` clone, what moves it to its successor
/// (`localMoveCmd`), else the adopt of the clone.
fn moveCmd(ctx: *app.Ctx, tree: []const u8, key: ?[]const u8, synced_root: []const u8) !Move {
    const a = ctx.alloc;
    if (ownKey(ctx, tree, null)) |own| if (kept.store.isLocalKey(own)) {
        const index = kept.store.loadIndex(a, .{ .synced_root = synced_root }) catch null;
        const later: []const []const u8 = if (index) |ix| ix.successorsOf(own) else &.{};
        return localMoveCmd(ctx, tree, own["local/".len..], synced_root, if (later.len > 0) later[0] else key);
    };
    return .{ .cmd = try std.fmt.allocPrint(a, "holt repo adopt {s}", .{try util.q(ctx, tree)}) };
}

/// The command that moves the clone at `tree`, awaiting promote, to
/// `successor`.
fn promoteCmdFor(ctx: *app.Ctx, tree: []const u8, key: ?[]const u8, synced_root: []const u8, successor: []const u8) !Move {
    const own = ownKey(ctx, tree, key);
    const name = if (own) |k| (if (kept.store.isLocalKey(k)) k["local/".len..] else std.fs.path.basename(k)) else std.fs.path.basename(tree);
    return localMoveCmd(ctx, tree, name, synced_root, successor);
}

/// Whether a project's marker names the local repo `name`.
fn markerNamesLocal(ctx: *app.Ctx, name: []const u8) bool {
    const projects = ctx.context.?.ws.list(ctx.alloc) catch return false;
    for (projects) |p| for (p.marker.entries) |*e| {
        const src = e.source orelse continue;
        if (src == .local and std.mem.eql(u8, src.local.bytes, name)) return true;
    };
    return false;
}

/// The commands that move the clone at `tree` of the local repo `name` to
/// the key `successor` (null when unknown): `holt repo promote` while a
/// project's marker names the local repo, which is what promote moves;
/// otherwise `holt repo adopt`, which moves the clone and its kept files
/// to the identity its origin names, after the git steps that give the
/// current branch an upstream it is not ahead of, since adopt refuses
/// one without (`upstreamSteps`). The remote is added first when the clone
/// has none, named as the successor's record names it; with no origin to
/// judge the branch by, the adopt's steps are left to the next sync, after
/// a fetch.
fn localMoveCmd(ctx: *app.Ctx, tree: []const u8, name: []const u8, synced_root: []const u8, successor: ?[]const u8) !Move {
    const a = ctx.alloc;
    const t = try util.q(ctx, tree);
    var steps: std.ArrayList([]const u8) = .empty;
    const has_origin = try kept.clone.originUrl(a, tree) != null;
    if (!has_origin) {
        const rec = if (successor) |s| kept.store.readRecord(a, .{ .synced_root = synced_root }, s) catch null else null;
        const origin = if (rec) |r| r.origin else null;
        try steps.append(a, try std.fmt.allocPrint(a, "git -C {s} remote add origin {s}", .{ t, if (origin) |o| try ui.shellQuote(a, o) else "<url>" }));
    }
    if (markerNamesLocal(ctx, name)) {
        try steps.append(a, try std.fmt.allocPrint(a, "holt repo promote {s}", .{try ui.shellQuote(a, name)}));
        return .{ .cmd = try std.mem.join(a, " && ", steps.items) };
    }
    if (!has_origin) {
        try steps.append(a, try std.fmt.allocPrint(a, "git -C {s} fetch origin", .{t}));
        try steps.append(a, "holt sync");
        return .{ .cmd = try std.mem.join(a, " && ", steps.items) };
    }
    const note = try upstreamSteps(a, tree, t, &steps);
    try steps.append(a, try std.fmt.allocPrint(a, "holt repo adopt {s}", .{t}));
    return .{ .cmd = try std.mem.join(a, " && ", steps.items), .note = note };
}

/// A command that moves a clone, and what to say beside it when it asks
/// the user to reconcile the clone's history first.
const Move = struct { cmd: []const u8, note: ?[]const u8 = null };

/// How far the commit `x` and `y` of the clone at `tree` each hold commits
/// the other lacks, or null when git cannot compare them.
fn divergence(alloc: std.mem.Allocator, tree: []const u8, x: []const u8, y: []const u8) !?struct { ahead: bool, behind: bool } {
    const res = git.runInRepoScoped(alloc, &.{ "rev-list", "--left-right", "--count", try std.fmt.allocPrint(alloc, "{s}...{s}", .{ x, y }), "--" }, tree) catch return null;
    if (res.status != 0) return null;
    var it = std.mem.tokenizeAny(u8, res.stdout, " \t\r\n");
    const l = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const r = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return .{ .ahead = l > 0, .behind = r > 0 };
}

fn gitOk(alloc: std.mem.Allocator, tree: []const u8, args: []const []const u8) bool {
    const res = git.runInRepoScoped(alloc, args, tree) catch return false;
    return res.status == 0;
}

/// Appends to `steps` the git commands, for the clone at `tree` (quoted
/// `t`), after which its current branch has an upstream on origin that it
/// is not ahead of, as adopt needs, judged by the clone's remote-tracking
/// refs: with an upstream, a push when ahead; without one, a fetch, then
/// `branch -u origin/<branch>` when not ahead of origin's branch, or a push
/// that sets it when ahead or when origin has no such branch. A branch
/// that has diverged from origin's is rebased onto it first
/// (`pull --rebase`), and the returned note says so.
fn upstreamSteps(alloc: std.mem.Allocator, tree: []const u8, t: []const u8, steps: *std.ArrayList([]const u8)) !?[]const u8 {
    const branch = (git.currentBranch(alloc, tree) catch null) orelse {
        try steps.append(alloc, try std.fmt.allocPrint(alloc, "git -C {s} push -u origin HEAD", .{t}));
        return null;
    };
    const qb = try ui.shellQuote(alloc, branch);
    if (gitOk(alloc, tree, &.{ "rev-parse", "--verify", "-q", "@{upstream}" })) {
        const d = (try divergence(alloc, tree, "HEAD", "@{upstream}")) orelse return null;
        if (d.ahead and d.behind) {
            const pull = try std.fmt.allocPrint(alloc, "git -C {s} pull --rebase", .{t});
            try steps.append(alloc, pull);
            try steps.append(alloc, try std.fmt.allocPrint(alloc, "git -C {s} push", .{t}));
            return try divergedNote(alloc, pull);
        }
        if (d.ahead) try steps.append(alloc, try std.fmt.allocPrint(alloc, "git -C {s} push", .{t}));
        return null;
    }
    const fetch = try std.fmt.allocPrint(alloc, "git -C {s} fetch origin", .{t});
    const track = try std.fmt.allocPrint(alloc, "git -C {s} branch -u origin/{s}", .{ t, qb });
    const push = try std.fmt.allocPrint(alloc, "git -C {s} push -u origin HEAD", .{t});
    const remote_ref = try std.fmt.allocPrint(alloc, "refs/remotes/origin/{s}", .{branch});
    if (gitOk(alloc, tree, &.{ "rev-parse", "--verify", "-q", remote_ref })) {
        const d = (try divergence(alloc, tree, "HEAD", remote_ref)) orelse return null;
        try steps.append(alloc, fetch);
        if (d.ahead and d.behind) {
            const pull = try std.fmt.allocPrint(alloc, "git -C {s} pull --rebase origin {s}", .{ t, qb });
            try steps.append(alloc, pull);
            try steps.append(alloc, push);
            return try divergedNote(alloc, pull);
        }
        try steps.append(alloc, if (d.ahead) push else track);
        return null;
    }
    if (fetched(alloc, tree)) {
        try steps.append(alloc, push);
        return null;
    }
    try steps.append(alloc, fetch);
    try steps.append(alloc, track);
    return null;
}

fn divergedNote(alloc: std.mem.Allocator, pull: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "its branch and origin's have diverged: reconcile them with git ({s}) before the adopt", .{pull});
}

/// Whether origin was fetched into the clone at `tree`: a remote-tracking
/// ref of origin, or a FETCH_HEAD, is there.
fn fetched(alloc: std.mem.Allocator, tree: []const u8) bool {
    const refs = git.runInRepoScoped(alloc, &.{ "for-each-ref", "--count=1", "--format=%(refname)", "refs/remotes/origin/" }, tree) catch return false;
    if (refs.status == 0 and std.mem.trim(u8, refs.stdout, " \r\n").len > 0) return true;
    const at = git.runInRepoScoped(alloc, &.{ "rev-parse", "--git-path", "FETCH_HEAD" }, tree) catch return false;
    if (at.status != 0) return false;
    const rel = std.mem.trim(u8, at.stdout, "\r\n");
    const path = if (std.fs.path.isAbsolute(rel)) rel else std.fs.path.join(alloc, &.{ tree, rel }) catch return false;
    return fsutil.exists(path);
}

fn moveHint(ctx: *app.Ctx, what: []const u8, m: Move) !Hint {
    const a = ctx.alloc;
    return .{
        .what = if (m.note) |n| try std.fmt.allocPrint(a, "{s}; {s}", .{ what, n }) else what,
        .run = try cmds(a, &.{m.cmd}),
    };
}

/// The hint for an interrupted take of an aside entry its record does not
/// name: only a take of an aside entry of the path goes on with it, so each
/// such entry here is named; with none, the record is to be removed by hand.
fn takeAsideUnnamed(ctx: *app.Ctx, tree: []const u8, key: ?[]const u8, synced_root: []const u8, i: reconcile.Item) !Hint {
    const a = ctx.alloc;
    const layout: kept.store.Layout = .{ .synced_root = synced_root };
    const entries: []const []const u8 = if (ownKey(ctx, tree, key)) |k| kept.aside.findEntries(a, layout, k, i.rel, null) catch &.{} else &.{};
    if (entries.len > 0) {
        var takes: std.ArrayList([]const u8) = .empty;
        for (entries) |e| try takes.append(a, try keepCmd(ctx, "--take-aside ", try ui.shellQuote(a, e)));
        return .{ .what = "interrupted while taking an aside entry its record does not name; take the one you meant", .run = takes.items };
    }
    const c = kept.clone.inspect(a, i.worktree orelse tree, ctx.context.?.ws.cfg.code_root) catch return .{ .what = "interrupted while taking an aside entry its record does not name, and no aside entry of it is here; remove its line from the clone's .git/holt/pending, then sync", .run = sync_only };
    return .{
        .what = try std.fmt.allocPrint(a, "interrupted while taking an aside entry its record does not name, and no aside entry of it is here; remove its line from {s}, then sync", .{try util.q(ctx, try std.fs.path.join(a, &.{ try kept.clone.stateDir(a, c.common_dir), "pending" }))}),
        .run = sync_only,
    };
}

/// The hint for reconcile's item `i` of the working tree at `tree`, whose
/// clone's own key is `key`, where `synced_root` is the current synced
/// root.
pub fn forItem(ctx: *app.Ctx, tree: []const u8, key: ?[]const u8, synced_root: []const u8, i: reconcile.Item) !Hint {
    return guard(ctx, try placeOf(ctx.alloc, tree, i), try itemHint(ctx, tree, key, synced_root, i));
}

/// `h` for the place `path`: with no command when the path holds a
/// control character, which no pasted command can name, saying so instead.
fn guard(ctx: *app.Ctx, path: []const u8, h: Hint) !Hint {
    if (!util.hasControl(path) or h.run.len == 0) return h;
    return .{ .what = try std.fmt.allocPrint(ctx.alloc, "{s}; {s}", .{ h.what, util.control_hint_words }) };
}

fn itemHint(ctx: *app.Ctx, tree: []const u8, key: ?[]const u8, synced_root: []const u8, i: reconcile.Item) !Hint {
    const a = ctx.alloc;
    const p = try util.q(ctx, try placeOf(a, tree, i));
    const detail = i.detail orelse "";
    return switch (i.outcome) {
        .linked => syncHint("not linked yet"),
        .retargeted => syncHint("links to an old location"),
        .old_differs => syncHint("links to an old location holding different content, which sync sets aside"),
        .old_unreadable => .{ .what = try std.fmt.allocPrint(a, "links to an old location that cannot be read ({s}); make it readable, then sync", .{detail}), .run = sync_only },
        .relinked => syncHint("local copy identical to the kept copy, not yet a link"),
        .dangling_removed => syncHint("a link to a kept copy no machine keeps"),
        .keep_abandoned => syncHint("git reads it only as a regular file, so holt cannot keep it; sync gives it up, and git sees it again"),
        .tracked_link_removed => .{ .what = "holt's link at a path this branch tracks", .run = try cmds(a, &.{try std.fmt.allocPrint(a, "holt sync && git -C {s} restore -- {s}", .{ try util.q(ctx, i.worktree orelse tree), try ui.shellQuote(a, i.rel) })}) },
        .mismatch_link_removed => syncHint("a link into a local/ key this clone does not match"),
        .pending_move => try moveHint(ctx, "links into an earlier key whose kept copy has not moved yet", try moveCmd(ctx, i.worktree orelse tree, key, synced_root)),
        .orphan_temp => syncHint("a temporary of a working tree git no longer lists"),
        .hidden => if (i.entry != null)
            .{ .what = "content git cannot see and holt holds only in aside; keep it, or leave it in aside", .run = try cmds(a, &.{try keepCmd(ctx, "--review ", try util.q(ctx, i.worktree orelse tree))}) }
        else
            syncHint("content git cannot see that exists only here; sync sets it aside"),
        .aside_failed => .{ .what = try std.fmt.allocPrint(a, "setting local content aside failed ({s})", .{detail}), .run = sync_only },
        .failed => .{ .what = try std.fmt.allocPrint(a, "failed: {s}", .{detail}), .run = sync_only },
        .interrupted => blk: {
            if (i.op) |op| switch (op) {
                .take_local => break :blk .{ .what = "interrupted", .run = try cmds(a, &.{try keepCmd(ctx, "--take-local ", p)}) },
                .take_kept => break :blk .{ .what = "interrupted", .run = try cmds(a, &.{try keepCmd(ctx, "--take-kept ", p)}) },
                .take_aside => {
                    if (i.entry) |e| break :blk .{ .what = "interrupted", .run = try cmds(a, &.{try keepCmd(ctx, "--take-aside ", try ui.shellQuote(a, e))}) };
                    break :blk try takeAsideUnnamed(ctx, tree, key, synced_root, i);
                },
                .relink, .release => break :blk syncHint("interrupted"),
                .keep => {},
            };
            if (i.detail != null) break :blk syncHint("interrupted, leaving a temporary beside it");
            break :blk .{ .what = "interrupted", .run = try cmds(a, &.{try keepCmd(ctx, "", p)}) };
        },
        .temp_stuck, .temp_stuck_local => blk: {
            const where = i.worktree orelse tree;
            const temp_path = try fsutil.joinSlashy(a, where, if (i.outcome == .temp_stuck) i.detail orelse try kept.paths.tempRel(a, i.rel) else try kept.paths.tempRel(a, i.rel));
            const temp = try util.q(ctx, temp_path);
            const held = if (i.entry) |e| try std.fmt.allocPrint(a, "; its content is in {s}", .{try entryPath(ctx, synced_root, e)}) else "";
            if (i.outcome == .temp_stuck_local) break :blk .{ .what = try std.fmt.allocPrint(a, "local content beside an interrupted write holt cannot settle{s}; remove {s}, then sync", .{ held, temp }), .run = sync_only };
            const take: []const []const u8 = if (i.entry) |e| try cmds(a, &.{ try keepCmd(ctx, "--take-aside ", try ui.shellQuote(a, e)), try deleter.removeCmd(ctx, &.{temp_path}) }) else &.{};
            break :blk .{ .what = try std.fmt.allocPrint(a, "an interrupted write left {s}, which holt cannot settle{s}; take it as the kept copy, or remove it", .{ temp, held }), .run = take };
        },
        .two_machines => blk: {
            var takes: std.ArrayList([]const u8) = .empty;
            for (i.entries) |e| try takes.append(a, try keepCmd(ctx, "--take-aside ", try ui.shellQuote(a, e)));
            if (takes.items.len == 0) break :blk .{ .what = try std.fmt.allocPrint(a, "kept on two machines with different content; wait for {s} to deliver both versions, then sync", .{backendName(ctx)}), .run = sync_only };
            break :blk .{ .what = "kept on two machines with different content; both are in aside", .run = takes.items };
        },
        .missing => .{ .what = try std.fmt.allocPrint(a, "kept copy missing (deleted elsewhere, or not synced yet); restore it from {s}'s trash, or give it up", .{backendName(ctx)}), .run = try cmds(a, &.{try std.fmt.allocPrint(a, "holt unkeep {s}", .{p})}) },
        .missing_local => .{ .what = "kept copy missing; local copy left in place, to be made the kept copy", .run = try cmds(a, &.{try keepCmd(ctx, "--take-local ", p)}) },
        .not_arrived => try notArrived(ctx, detail, p, "holt sync", i.entry),
        .retired_gone => blk: {
            const unkeep = try std.fmt.allocPrint(a, "holt unkeep {s}", .{p});
            if (i.entries.len == 0) break :blk .{ .what = "kept copy gone, and only a retired machine kept it; give it up", .run = try cmds(a, &.{unkeep}) };
            var run: std.ArrayList([]const u8) = .empty;
            for (i.entries) |e| try run.append(a, try keepCmd(ctx, "--take-aside ", try ui.shellQuote(a, e)));
            try run.append(a, unkeep);
            const held = if (i.entries.len == 1)
                try std.fmt.allocPrint(a, "aside entry {s} holds its content: take it back", .{i.entries[0]})
            else
                try std.fmt.allocPrint(a, "aside entries {s} hold its content: take one back", .{try std.mem.join(a, ", ", i.entries)});
            break :blk .{ .what = try std.fmt.allocPrint(a, "kept copy gone, and only a retired machine kept it; {s}, or give the path up", .{held}), .run = run.items };
        },
        .not_present => .{ .what = try std.fmt.allocPrint(a, "kept copy not here yet; sync once {s} finishes downloading", .{backendName(ctx)}), .run = sync_only },
        .in_old_root => .{ .what = try std.fmt.allocPrint(a, "kept copy is in {s}: copy it to {s}, then sync", .{ try util.q(ctx, try std.fs.path.join(a, &.{ detail, "kept" })), try util.q(ctx, try std.fs.path.join(a, &.{ synced_root, "kept" })) }), .run = sync_only },
        .awaiting_promote => try moveHint(ctx, try std.fmt.allocPrint(a, "this repo moved to {s}", .{detail}), try promoteCmdFor(ctx, i.worktree orelse tree, key, synced_root, detail)),
        .kept_not_regular => .{ .what = try std.fmt.allocPrint(a, "the kept copy {s} is a symlink or not a regular file or directory; replace it with a regular file or directory, then sync", .{try keptCopy(ctx, tree, key, synced_root, i.rel)}), .run = sync_only },
        .kind_mismatch => .{ .what = "the kept copy is a file where its records say a directory, or the reverse", .run = try cmds(a, &.{ try keepCmd(ctx, "--take-local ", p), try std.fmt.allocPrint(a, "holt unkeep {s}", .{p}) }) },
        .kept_reserved => .{ .what = try std.fmt.allocPrint(a, "the kept directory holds a name holt reserves ({s}); rename it there, then sync", .{detail}), .run = sync_only },
        .unrecorded_link => .{ .what = "holt's link to a kept copy no record names", .run = try cmds(a, &.{try keepCmd(ctx, "", p)}) },
        .foreign_link => .{ .what = try std.fmt.allocPrint(a, "a symlink holt did not make (-> {s})", .{detail}), .run = try cmds(a, &.{try std.fmt.allocPrint(a, "rm {s} && holt sync", .{p})}) },
        .local_differs => .{ .what = "local copy differs from the kept copy", .run = try cmds(a, &.{ try keepCmd(ctx, "--take-local ", p), try keepCmd(ctx, "--take-kept ", p) }) },
        .stray => .{ .what = "local content where the kept copy is not recorded as kept; move it out of the working tree, then sync", .run = sync_only },
        .local_not_regular => .{ .what = "local content is not a regular file or directory, so it cannot be compared or linked; replace it with a regular file or directory, then sync", .run = sync_only },
        .cannot_compare => .{ .what = "cannot compare: online-only; download it, then sync", .run = sync_only },
        .online_only => .{ .what = "the kept copy is online-only; download it, then sync", .run = sync_only },
        .no_symlink_privilege => .{ .what = "this machine cannot create symlinks (on Windows, turn on Developer Mode), then sync", .run = sync_only },
        .nested_repository => .{ .what = "a nested repository git cannot see, which holt never copies; move it out of the clone, then sync", .run = sync_only },
        .hidden_not_copyable => .{ .what = "a symlink or special file git cannot see, which git clean would delete; move it out of the clone, then sync", .run = sync_only },
        .tree_unreadable => try unreadableTree(ctx, tree, i.worktree orelse tree, detail),
        .line_refused => .{ .what = try std.fmt.allocPrint(a, "not hidden from git: its block line would hide what cannot be set aside ({s}); settle the places reported beside it, then sync", .{detail}), .run = sync_only },
        .stopped => syncHint("content git cannot see, in a working tree reconcile could not evaluate"),
        .invalid => if (i.invalid == .git_reads_unlinked)
            .{ .what = "git reads it only as a regular file, so holt never links it", .run = try cmds(a, &.{try std.fmt.allocPrint(a, "holt unkeep {s}", .{p})}) }
        else
            .{ .what = try std.fmt.allocPrint(a, "not a valid kept path ({s}), so holt never links it; keep the file under a valid name instead", .{detail}) },
        .parent_not_dir => try parentHint(ctx, i.worktree orelse tree, i.rel),
        .tracked => .{ .what = "tracked on this branch" },
        .temp_settled => .{ .what = "a temporary an interrupted write left was settled" },
        .released_converted => .{ .what = "released: holt's link was replaced by a copy of the kept file" },
        .released_local => .{ .what = "released: local content left alone" },
        .purged_link_removed => syncHint("purged on another machine; its link points at nothing, and sync removes it"),
        .purged_restored => .{ .what = try std.fmt.allocPrint(a, "purged on another machine; sync restores a local copy from aside entry {s}", .{i.entry orelse ""}), .run = sync_only },
        .purged_pending => .{ .what = try std.fmt.allocPrint(a, "purged on another machine; its aside entry {s} has not arrived yet; sync once {s} downloads it", .{ i.entry orelse "", backendName(ctx) }), .run = sync_only },
        .purged_unrestorable => .{ .what = try std.fmt.allocPrint(a, "purged on another machine, and aside entry {s} does not hold a whole copy of it; its link points at nothing", .{i.entry orelse ""}), .run = try cmds(a, &.{try std.fmt.allocPrint(a, "rm {s}", .{p})}) },
        .released_missing => .{ .what = "released, and its kept copy is gone", .run = try cmds(a, &.{try std.fmt.allocPrint(a, "rm {s}", .{p})}) },
        .outside_sparse => .{ .what = "outside the sparse checkout, so not linked here" },
        .ok => .{ .what = "linked" },
        .tree_unrecorded => try unrecordedTree(ctx, i.worktree orelse tree, i.detail),
        .half_created_record => try halfCreated(ctx, i.detail orelse tree),
        .fold_unknown => .{ .what = "how this filesystem compares names is unknown, so holt takes it to fold them" },
    };
}

/// What settles the working tree at `wt` of the clone at `tree` that
/// cannot be swept, `problem` naming why (`kept.clone.TreeProblem`). Each
/// command reaches that one worktree or its one record, never `git
/// worktree repair` or `prune`, which reach every one: for one whose
/// directory is gone, bringing it back from its record
/// (`deleter.relinkCmd`), or, once it is gone for good, removing that
/// record, weighed as the deleters weigh it (`deleter.weighRecord`): when
/// nothing is at risk, with `git worktree remove`, unlocking it first; else,
/// for a worktree `holt worktree` made, with `holt worktree -r`, which
/// weighs it again and names what it refuses on, and for any other, no
/// removal, only the lines naming what removing it destroys
/// (`deleter.LinkedTree.lines`), which name bringing it back first when
/// it holds an operation in progress or staged changes. One holt leaves
/// to the user is named with what git and holt see there
/// (`deleter.unresolvedWhat`) and no command: a path more than one record
/// names, one whose `.git` is gone, leads nowhere, or leads to another git
/// directory, a symlink to nothing, and one whose record cannot be read,
/// which names the record (`deleter.recordWhat`).
/// One that cannot be opened, and one recorded in the other side of WSL's
/// form, are settled by the user alone; so is any whose record cannot be
/// found.
pub fn unreadableTree(ctx: *app.Ctx, tree: []const u8, wt: []const u8, problem: []const u8) !Hint {
    const a = ctx.alloc;
    const lead = try std.fmt.allocPrint(a, "a working tree that cannot be read ({s})", .{problem});
    const p = std.meta.stringToEnum(kept.clone.TreeProblem, problem) orelse return .{ .what = lead };
    const git_in = try deleter.mainGit(ctx, try mainOf(ctx, tree));
    switch (p) {
        .other_side => return .{ .what = try std.fmt.allocPrint(a, "{s}: git records it in the other side of WSL's form; run holt on that side", .{lead}) },
        .record_unreadable => return .{ .what = try deleter.recordWhat(ctx, deleter.record_unreadable_seen, wt) },
        .unreadable => if (try dirThere(a, wt)) return .{ .what = try std.fmt.allocPrint(a, "{s}: what is at its path cannot be opened as a directory; make it readable or move it away, then sync", .{lead}) },
        else => {},
    }
    const common: []const u8 = deleter.commonDirOf(a, .{ .repo = tree }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => "",
    };
    const recs = if (common.len == 0) &.{} else deleter.recordsIn(a, common, wt) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => &.{},
    };
    if (recs.len == 0) return .{ .what = try std.fmt.allocPrint(a, "{s}; no record of the clone names it any longer, so sync again", .{lead}), .run = sync_only };
    const rec = recs[0];
    const unresolved = deleter.unresolvedSeen(a, common, recs, rec) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => "a linked working tree whose path cannot be read",
    };
    if (unresolved) |seen| return .{ .what = try deleter.unresolvedWhat(ctx, seen, git_in) };
    if (p != .absent) return .{ .what = try std.fmt.allocPrint(a, "{s}; git finds it again, so sync again", .{lead}), .run = sync_only };
    const t = try deleter.weighRecord(try deleter.Asker.of(ctx), tree, rec);
    if (t.seen) |seen| return .{ .what = try deleter.unresolvedWhat(ctx, seen, git_in) };
    const cq = try util.q(ctx, tree);
    const wq = try util.q(ctx, wt);
    const unlock = if (t.locked) try std.fmt.allocPrint(a, "git -C {s} worktree unlock {s} && ", .{ cq, wq }) else "";
    const remove = try std.fmt.allocPrint(a, "{s}git -C {s} worktree remove {s}", .{ unlock, cq, wq });
    const relink = try deleter.relinkCmd(ctx, wt, rec.record, true);
    const what = try std.fmt.allocPrint(a, "{s}: nothing is at its path; move it back or remount its volume, bring it back from its record, or remove the record once it is gone for good", .{lead});
    if (!t.atRisk()) return .{ .what = what, .run = try cmds(a, &.{ relink, remove }) };
    if (try repo_cmd.holtWorktreeOf(ctx, tree, wt)) |holt| return .{ .what = what, .run = try cmds(a, &.{ relink, try std.mem.concat(a, u8, &.{ unlock, holt }) }) };
    return .{
        .what = try std.fmt.allocPrint(a, "{s}: nothing is at its path; move it back or remount its volume, or bring it back from its record; removing the record destroys what it holds: {s}", .{ lead, try std.mem.join(a, "; ", try t.lines(ctx, tree, remove)) }),
        .run = if (t.ops.len > 0 or t.staged) &.{} else try cmds(a, &.{relink}),
    };
}

/// Whether `path`, a symlink followed, is a directory; false when that
/// cannot be told.
fn dirThere(a: std.mem.Allocator, path: []const u8) !bool {
    const real = fsutil.realPathOrSelf(a, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    return (kept.content.entryAt(real) catch return false) == .dir;
}

/// The main working tree of the clone the working tree `tree` belongs to;
/// `tree` itself when it cannot be read.
fn mainOf(ctx: *app.Ctx, tree: []const u8) ![]const u8 {
    const context = ctx.context orelse return tree;
    const c = kept.clone.inspect(ctx.alloc, tree, context.ws.cfg.code_root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return tree,
    };
    return c.main;
}

/// What settles the working tree at `wt` of the clone at `tree` whose
/// files git could not list: `unreadableTree` for one that cannot be swept
/// (`problem`), else `git status` there, with `detail` saying why.
pub fn unlisted(ctx: *app.Ctx, tree: []const u8, wt: []const u8, problem: ?kept.clone.TreeProblem, detail: ?[]const u8) !Hint {
    if (problem) |p| return unreadableTree(ctx, tree, wt, @tagName(p));
    return .{ .what = detail orelse "git could not list it", .run = try cmds(ctx.alloc, &.{try std.fmt.allocPrint(ctx.alloc, "git -C {s} status", .{try util.q(ctx, wt)})}) };
}

/// What settles the working tree at `tree`, which git records under no
/// path of its own, `shares` being the path the record it holds names:
/// for one whose record names a path that is gone, as after a plain `mv`,
/// holt leaves it to the user (`deleter.unresolvedWhat`), naming no
/// command, since the one that settles it writes the record; for a copy
/// of the working tree at `shares`, which is there, and one git records
/// nowhere, no command, since pointing the record here would take it from
/// the working tree it names.
pub fn unrecordedTree(ctx: *app.Ctx, tree: []const u8, shares: ?[]const u8) !Hint {
    const a = ctx.alloc;
    const at = shares orelse return .{ .what = "a working tree git records under no path at all" };
    const shown = try util.show(ctx, at);
    if (try kept.content.entryAt(at) != .absent) return .{ .what = try std.fmt.allocPrint(a, "a copy of the working tree at {s}, sharing its record, so git takes the two for one; remove the copy, or add a working tree of its own with git worktree add", .{shown}) };
    const seen = try std.fmt.allocPrint(a, "a working tree git records under {s}, which is gone, as after a move", .{shown});
    return .{ .what = try deleter.unresolvedWhat(ctx, seen, try deleter.mainGit(ctx, try mainOf(ctx, tree))) };
}

/// What is said of the record `record` that `git worktree add` left half
/// made, which names no working tree: holt leaves it to the user, naming
/// the record (`deleter.recordWhat`) and no command.
fn halfCreated(ctx: *app.Ctx, record: []const u8) !Hint {
    return .{ .what = try deleter.recordWhat(ctx, deleter.half_made_seen, record) };
}

/// The negated gitignore line `n` as a person reads it: its file, line
/// number, and text, as `git check-ignore -v` prints them.
fn negationAt(ctx: *app.Ctx, n: kept.clone.Negation) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "{s}:{s}:{s}", .{ try util.show(ctx, n.source), n.line, try ui.printable(ctx.alloc, n.pattern) });
}

/// What keep says for the path `path` the negated line `n` makes git see
/// past holt's block: the line to remove or narrow, then the keep again.
pub fn negated(ctx: *app.Ctx, n: kept.clone.Negation, path: []const u8) !Hint {
    const a = ctx.alloc;
    return guard(ctx, path, .{
        .what = try std.fmt.allocPrint(a, "{s} un-ignores it, and holt's block cannot hide it from git past that line; remove or narrow the line, then keep it", .{try negationAt(ctx, n)}),
        .run = try cmds(a, &.{try std.fmt.allocPrint(a, "holt keep {s}", .{try util.q(ctx, path)})}),
    });
}

/// The hint for the path `path` an auto pattern `pattern` matches that git
/// does not ignore, so holt does not keep it on its own; with `negation`,
/// the negated line that un-ignores it, which keeping it could not get
/// past (`clone.negation`).
pub fn autoUnignored(ctx: *app.Ctx, path: []const u8, pattern: []const u8, negation: ?kept.clone.Negation) !Hint {
    const a = ctx.alloc;
    if (negation) |n| return .{
        .what = try std.fmt.allocPrint(a, "matches an auto pattern ({s}) but {s} un-ignores it, so holt cannot keep it; remove or narrow that line, or leave it for a commit", .{ try ui.printable(a, pattern), try negationAt(ctx, n) }),
    };
    return guard(ctx, path, .{
        .what = try std.fmt.allocPrint(a, "matches an auto pattern ({s}) but git does not ignore it; add it to .gitignore, or keep it", .{try ui.printable(a, pattern)}),
        .run = try cmds(a, &.{try std.fmt.allocPrint(a, "holt keep {s}", .{try util.q(ctx, path)})}),
    });
}

/// The hint for a working tree reconcile stopped at with `s`.
pub fn forStop(ctx: *app.Ctx, tree: []const u8, s: reconcile.Stop, key: ?[]const u8) !Hint {
    const a = ctx.alloc;
    const t = try util.q(ctx, tree);
    return switch (s) {
        .none => .{ .what = "" },
        .store_absent => .{ .what = try std.fmt.allocPrint(a, "kept/ is missing, but this clone has kept-file links; if another machine keeps files, wait for {s} to finish downloading it, then sync", .{backendName(ctx)}), .run = sync_only },
        .store_unreadable => .{ .what = try std.fmt.allocPrint(a, "kept/ cannot be read; make {s} readable, then sync", .{try util.q(ctx, try std.fs.path.join(a, &.{ ctx.context.?.ws.cfg.synced_root, "kept" }))}), .run = sync_only },
        .no_key => .{ .what = if (try underCodeRoot(ctx, tree)) "not at a repo's path under the code root (<host>/<owner>/<repo> or local/<name>), so it has no kept files" else "not under the code root, so it has no kept files" },
        .unknown_version => .{ .what = try std.fmt.allocPrint(a, "the record of {s} has a version this holt does not know; upgrade holt", .{key orelse "its key"}), .run = &.{"holt upgrade"} },
        .local_mismatch => .{
            .what = try std.fmt.allocPrint(a, "does not match the local/ key {s} (a different repo, or its record has not arrived); give this clone another directory name and run holt repo adopt on it there, or, if that repo is gone, release its kept files", .{key orelse ""}),
            .run = if (key) |k| try cmds(a, &.{try std.fmt.allocPrint(a, "holt unkeep --repo {s}", .{try ui.shellQuote(a, k)})}) else &.{},
        },
        .block_unbalanced => blk: {
            const c = kept.clone.inspect(a, tree, ctx.context.?.ws.cfg.code_root) catch break :blk .{ .what = "holt's block in info/exclude is unbalanced; restore its begin and end lines by hand", .run = try cmds(a, &.{try std.fmt.allocPrint(a, "git -C {s} rev-parse --git-path info/exclude", .{t})}) };
            break :blk .{ .what = try std.fmt.allocPrint(a, "holt's block in {s} is unbalanced; restore its begin and end lines by hand", .{try util.q(ctx, try kept.block.excludePath(a, c.common_dir))}) };
        },
        .git_failed => .{ .what = "git could not read its index or HEAD", .run = try cmds(a, &.{try std.fmt.allocPrint(a, "git -C {s} status", .{t})}) },
        .worktrees_unknown => .{ .what = "the clone's working trees cannot be read; make its worktree records readable, then sync", .run = try cmds(a, &.{ try std.fmt.allocPrint(a, "git -C {s} worktree list", .{t}), "holt sync" }) },
        .worktree_elsewhere => .{ .what = "core.worktree points elsewhere, so this clone has no key" },
    };
}

fn underCodeRoot(ctx: *app.Ctx, tree: []const u8) !bool {
    const code_root = ctx.context.?.ws.cfg.code_root;
    const a = ctx.alloc;
    return fsutil.pathIsInside(try fsutil.realPathOrSelf(a, tree), try fsutil.realPathOrSelf(a, code_root));
}

/// `h`'s commands as `run: <cmd>, or <cmd>`, or null when it has none.
pub fn runText(alloc: std.mem.Allocator, h: Hint) !?[]const u8 {
    if (h.run.len == 0) return null;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try aw.writer.writeAll("run: ");
    for (h.run, 0..) |r, n| {
        if (n > 0) try aw.writer.writeAll(", or ");
        try aw.writer.writeAll(r);
    }
    return aw.written();
}

/// `h` as a line's text after a place: `<what> - run: <cmd>, or <cmd>`.
pub fn renderDash(alloc: std.mem.Allocator, h: Hint) ![]const u8 {
    const run_text = (try runText(alloc, h)) orelse return h.what;
    return std.fmt.allocPrint(alloc, "{s} - {s}", .{ h.what, run_text });
}

/// `h` as the text after a place: `<what> (run: <cmd>, or <cmd>)`.
pub fn render(alloc: std.mem.Allocator, h: Hint) ![]const u8 {
    if (h.run.len == 0) return h.what;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try aw.writer.print("{s} (run: ", .{h.what});
    for (h.run, 0..) |r, n| {
        if (n > 0) try aw.writer.writeAll(", or ");
        try aw.writer.writeAll(r);
    }
    try aw.writer.writeByte(')');
    return aw.written();
}

/// Why `--prune-aside` without names spares an aside entry less than
/// `kept.ops.young_days` days old (`kept.ops.AsideInfo.Held.young`), and
/// `anyway`, the command that removes it anyway.
pub fn youngAside(alloc: std.mem.Allocator, anyway: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "it is less than {d} days old, and another machine or an unfinished operation may still need it (to remove it anyway, run: {s})", .{ kept.ops.young_days, anyway });
}

const testing = std.testing;
const testutil = @import("../testutil.zig");

fn stepsOf(a: std.mem.Allocator, tree: []const u8) !struct { cmd: []const u8, note: ?[]const u8 } {
    var steps: std.ArrayList([]const u8) = .empty;
    const note = try upstreamSteps(a, tree, "T", &steps);
    return .{ .cmd = try std.mem.join(a, " && ", steps.items), .note = note };
}

test "upstreamSteps: fetch and track when not ahead, push when ahead or origin lacks the branch, rebase first when diverged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer sb.alloc.free(bare);
    const w = try testutil.makeWorkClone(&sb, bare);
    defer sb.alloc.free(w);
    const other = try testutil.makeWorkClone(&sb, bare);
    defer sb.alloc.free(other);
    const b = (try git.currentBranch(a, w)).?;

    try testing.expectEqualStrings("", (try stepsOf(a, w)).cmd);
    try testutil.runGit(&sb, w, &.{ "branch", "--unset-upstream" });
    const track = try std.fmt.allocPrint(a, "git -C T fetch origin && git -C T branch -u origin/{s}", .{b});
    try testing.expectEqualStrings(track, (try stepsOf(a, w)).cmd);

    try testutil.runGit(&sb, other, &.{ "commit", "-q", "--allow-empty", "-m", "theirs" });
    try testutil.runGit(&sb, other, &.{ "push", "-q" });
    try testutil.runGit(&sb, w, &.{ "fetch", "-q", "origin" });
    try testing.expectEqualStrings(track, (try stepsOf(a, w)).cmd);

    try testutil.runGit(&sb, w, &.{ "commit", "-q", "--allow-empty", "-m", "ours" });
    const diverged = try stepsOf(a, w);
    const pull = try std.fmt.allocPrint(a, "git -C T pull --rebase origin {s}", .{b});
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "git -C T fetch origin && {s} && git -C T push -u origin HEAD", .{pull}), diverged.cmd);
    try testing.expect(std.mem.indexOf(u8, diverged.note.?, pull) != null);

    try testutil.runGit(&sb, w, &.{ "rebase", "-q", try std.fmt.allocPrint(a, "origin/{s}", .{b}) });
    try testing.expectEqualStrings("git -C T fetch origin && git -C T push -u origin HEAD", (try stepsOf(a, w)).cmd);
    try testutil.runGit(&sb, w, &.{ "branch", "-q", "-u", try std.fmt.allocPrint(a, "origin/{s}", .{b}) });
    try testing.expectEqualStrings("git -C T push", (try stepsOf(a, w)).cmd);

    try testutil.runGit(&sb, w, &.{ "branch", "--unset-upstream" });
    try testutil.runGit(&sb, w, &.{ "switch", "-q", "-c", "topic" });
    try testing.expectEqualStrings("git -C T push -u origin HEAD", (try stepsOf(a, w)).cmd);
}
