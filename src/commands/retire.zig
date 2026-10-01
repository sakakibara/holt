//! `holt doctor --retire`: the check before retiring a machine. Reports,
//! and changes nothing (reconcile runs in plan mode, no auto-keep), each
//! thing that exists only here with the command that settles it: files
//! holt does not keep, nested repositories, unsettled kept files, git state
//! no remote holds (submodules' included), clones with no remote, what lies
//! in the code tree outside every clone, and loose entries in hubs; then
//! lists, without failing, the state holt never keeps and every machine
//! with kept files, and ends by naming the backend whose uploads must
//! finish first and `holt keep --retire-machine`, the last command to run
//! here, or that this machine is retired already. Writes nothing, this
//! machine's id included.

const std = @import("std");
const app = @import("../app.zig");
const kept = @import("../kept.zig");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const ui = @import("../ui.zig");
const recover = @import("../recover.zig");
const marker = @import("../marker.zig");
const config = @import("../config.zig");
const deleter = @import("deleter.zig");
const doctor_cmd = @import("doctor.zig");
const util = @import("kept_util.zig");
const kept_hooks = @import("kept_hooks.zig");
const kept_hints = @import("kept_hints.zig");
const common = @import("common.zig");

const io = fsutil.io;

/// One failing finding: what exists only here, the commands settling it,
/// empty when only the user can, and what the line says after them.
const Fail = struct { text: []const u8, cmd: []const u8, after: []const u8 = "" };

const Report = struct {
    fails: std.ArrayList(Fail) = .empty,
    notes: std.ArrayList([]const u8) = .empty,
    /// The clones a skipped host kept from being asked, named once per
    /// host after the last clone.
    held: deleter.HeldBack = .{},
    /// The code-tree key of the clone being checked, which the line of
    /// git state that could not be read names.
    key: []const u8 = "",

    fn fail(r: *Report, ctx: *app.Ctx, cmd: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try r.failAfter(ctx, cmd, "", fmt, args);
    }

    /// Adds the finding unless the same one is there already.
    fn failAfter(r: *Report, ctx: *app.Ctx, cmd: []const u8, after: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(ctx.alloc, fmt, args);
        for (r.fails.items) |f| if (std.mem.eql(u8, f.text, text) and std.mem.eql(u8, f.cmd, cmd)) return;
        try r.fails.append(ctx.alloc, .{ .text = text, .cmd = cmd, .after = after });
    }

    fn note(r: *Report, ctx: *app.Ctx, comptime fmt: []const u8, args: anytype) !void {
        try r.notes.append(ctx.alloc, try std.fmt.allocPrint(ctx.alloc, fmt, args));
    }
};

/// Runs the check over every clone in the code tree, each of its working
/// trees, and every hub, prints it, and returns 1 when anything exists only
/// on this machine.
pub fn run(ctx: *app.Ctx) !u8 {
    const a = ctx.alloc;
    const ws = ctx.context.?.ws;
    var r: Report = .{};

    var scratch: kept.RunScratch = undefined;
    var kctx: ?kept.Ctx = kept_hooks.planCtx(ctx, &scratch) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => blk: {
            try r.fail(ctx, "holt doctor", "this machine's id or a scratch directory cannot be read ({s}), so kept files cannot be checked", .{@errorName(err)});
            break :blk null;
        },
    };
    defer if (kctx != null) scratch.deinit();
    if (kctx != null) {
        kept.clone.requireGit(a) catch |err| switch (err) {
            error.GitTooOld => {
                try r.fail(ctx, "git --version", "{s}, so kept files cannot be checked", .{try kept.clone.gitTooOld(a)});
                kctx = null;
            },
            else => return err,
        };
    }
    var index: kept.store.KeyIndex = .{ .keys = &.{}, .successors = .empty, .bad = &.{} };
    var store_ready = false;
    if (kctx) |k| switch (try deleter.storeState(a, k.layout)) {
        .ready => {
            store_ready = true;
            index = try kept.store.loadIndex(a, k.layout);
        },
        .absent => if (try util.keptElsewhere(ctx)) |root| {
            try ctx.out.writeAll("retire: nothing exists only on this machine: ");
            try ui.color(ctx.context.?.color, ctx.out, "31", "FAIL");
            try ctx.out.print("\n  {s}", .{try kept_hooks.elsewhereLine(ctx, root)});
            return 1;
        },
        .unreadable => try r.fail(ctx, try std.fmt.allocPrint(a, "ls -la {s}", .{try util.q(ctx, try k.layout.keptDir(a))}), "kept/ cannot be read, so kept files cannot be checked", .{}),
    };

    var holders: std.ArrayList([]const u8) = .empty;
    for (try ws.listClones(a)) |clone_path| {
        try holders.append(a, try fsutil.realPathOrSelf(a, clone_path));
        try checkClone(ctx, &r, kctx, &index, store_ready, clone_path, &holders);
    }
    for (try r.held.lines(a, "not asked", null, "")) |line| try r.fail(ctx, "", "{s}", .{line});
    try checkCodeRoot(ctx, &r, kctx, holders.items);
    try checkHubs(ctx, &r, kctx);

    const cfg_path = config.configPath(a, app.envOf(ctx)) catch null;
    if (cfg_path) |p| if (fsutil.exists(p)) try r.note(ctx, "holt's configuration: {s} (copy it, or run holt setup on the new machine)", .{try util.show(ctx, p)});

    const w = ctx.out;
    try w.writeAll("retire: nothing exists only on this machine: ");
    try ui.color(ctx.context.?.color, w, if (r.fails.items.len == 0) "32" else "31", if (r.fails.items.len == 0) "PASS" else "FAIL");
    try w.writeByte('\n');
    for (r.fails.items) |f| {
        if (f.cmd.len == 0) {
            try w.print("  {s}{s}\n", .{ f.text, f.after });
        } else {
            const with: []const u8 = if (std.mem.indexOf(u8, f.cmd, "<url>") != null) ", with <url> a URL on another machine" else "";
            try w.print("  {s} (run: {s}{s}){s}\n", .{ f.text, f.cmd, with, f.after });
        }
    }
    if (r.notes.items.len > 0) {
        try w.writeAll("note: holt does not keep this state; copy what you need by hand:\n");
        for (r.notes.items) |n| try w.print("  {s}\n", .{n});
    }
    if (store_ready) try printMachines(ctx, kctx.?, &index);
    try w.print("Before wiping this machine, check that {s} shows no pending uploads.\n", .{util.backendName(ctx)});
    if (store_ready) try printLast(ctx, kctx.?, &index);
    return if (r.fails.items.len == 0) 0 else 1;
}

/// Lists every machine the kept store has facts from, with its host label,
/// the date of its newest fact, and whether it is retired; a machine that
/// is gone can be retired from here by its id.
fn printMachines(ctx: *app.Ctx, k: kept.Ctx, index: *const kept.store.KeyIndex) !void {
    const list = try kept.store.machines(ctx.alloc, k.layout, index);
    if (list.len == 0) return;
    const w = ctx.out;
    try w.writeAll("machines with kept files (a machine that is gone: holt keep --retire-machine <id>):\n");
    for (list) |m| {
        const last = if (m.last_fact) |s| try kept.store.shownDate(ctx.alloc, try kept.store.utcDate(ctx.alloc, s)) else if (m.last_unknown) "unknown" else "none";
        try w.print("  {s}, last record {s}", .{ try util.machineLabel(ctx, k, m.id), last });
        if (m.retired) |ret| try w.print(", retired {s}{s}", .{ try kept.store.shownDate(ctx.alloc, ret.date), if (m.active_again) ", active again" else "" });
        try w.writeByte('\n');
    }
}

/// The last line: `holt keep --retire-machine` to run here once everything
/// passes, unless this machine is retired already and has written no kept
/// files since, which is said instead, naming the host that retired it
/// unless this machine did, or has never written kept files, so there is
/// nothing to retire.
fn printLast(ctx: *app.Ctx, k: kept.Ctx, index: *const kept.store.KeyIndex) !void {
    const w = ctx.out;
    const run_last = "Once everything passes, run on this machine, last: holt keep --retire-machine\n";
    const ret = try kept.store.readRetired(ctx.alloc, k.layout, k.machine_id) orelse {
        if (try kept.store.readHost(ctx.alloc, k.layout, k.machine_id) == null) return w.writeAll("This machine has no kept-file records: there is nothing to retire.\n");
        return w.writeAll(run_last);
    };
    const date = try kept.store.shownDate(ctx.alloc, ret.date);
    if (try kept.store.activeAgain(ctx.alloc, k.layout, index, k.machine_id)) {
        try w.print("This machine was retired on {s} from {s}, and has kept files changed since.\n", .{ date, try ui.printable(ctx.alloc, ret.by_host) });
        return w.writeAll(run_last);
    }
    if (ret.by_machine != null and std.mem.eql(u8, ret.by_machine.?, k.machine_id)) {
        return w.print("This machine was retired on {s} from {s}: holt keep --retire-machine has run here.\n", .{ date, try ui.printable(ctx.alloc, ret.by_host) });
    }
    const by = if (ret.by_machine) |m| try std.fmt.allocPrint(ctx.alloc, " (machine {s})", .{try ui.printable(ctx.alloc, m)}) else "";
    try w.print("This machine was retired on {s}: holt keep --retire-machine {s} ran on {s}{s}.\n", .{ date, k.machine_id, try ui.printable(ctx.alloc, ret.by_host), by });
}

fn q(ctx: *app.Ctx, path: []const u8) ![]const u8 {
    return util.q(ctx, path);
}

fn gitCmd(ctx: *app.Ctx, repo: []const u8, comptime rest: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "git -C {s} " ++ rest, .{try q(ctx, repo)} ++ args);
}

/// Checks the clone at `clone_path` and each of its working trees, adding
/// the real path of each working tree it records to `holders`. The clone's
/// checks are one weighing pass: each remote URL is asked once for them.
fn checkClone(ctx: *app.Ctx, r: *Report, kctx_opt: ?kept.Ctx, index: *const kept.store.KeyIndex, store_ready: bool, clone_path: []const u8, holders: *std.ArrayList([]const u8)) !void {
    const a = ctx.alloc;
    r.key = try common.codeKey(a, ctx.context.?.ws.cfg.code_root, clone_path);
    const shown = try util.show(ctx, clone_path);
    var asker = try deleter.Asker.of(ctx);
    asker.terminal = false;
    const kctx = kctx_opt orelse {
        if (kept.clone.inspect(a, clone_path, ctx.context.?.ws.cfg.code_root)) |c| {
            try checkGoneRecords(ctx, r, c, &.{});
            try checkOps(ctx, r, c, &.{}, &.{});
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }
        return checkGit(ctx, r, asker, clone_path, &.{clone_path}, null);
    };
    const c = kept.clone.inspect(a, clone_path, kctx.code_root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try failRisk(ctx, r, "", .{ .repo = clone_path, .risk = .{ .what = .unreadable } }, &.{});
            return;
        },
    };
    const trees = kept.clone.worktrees(a, c) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try r.fail(ctx, try gitCmd(ctx, clone_path, "worktree list", .{}), "the working trees of {s} cannot be read", .{shown});
            return;
        },
    };
    var readable: std.ArrayList([]const u8) = .empty;
    for (trees) |t| {
        if (t.readable()) try readable.append(a, t.path);
        try holders.append(a, try fsutil.realPathOrSelf(a, t.path));
    }
    var sub_trees: []const []const u8 = &.{};
    var listed_subs: []const []const u8 = &.{};

    var reported: std.ArrayList([]const u8) = .empty;
    var unlisted_trees: std.ArrayList([]const u8) = .empty;
    const AtKept = struct { path: []const u8, tree: []const u8 };
    var at_kept: std.ArrayList(AtKept) = .empty;
    const review_all = struct {
        fn cmd(cx: *app.Ctx, tree: []const u8) ![]const u8 {
            return std.fmt.allocPrint(cx.alloc, "holt keep --review {s}", .{try q(cx, tree)});
        }
    }.cmd;
    const opts: kept.candidates.Options = .{ .deep_nested = true, .tracked_edits = true };
    if (kept.candidates.listAll(kctx, index, c, opts)) |all| {
        for (all.listings) |l| {
            for (l.candidates) |cand| {
                const path = try fsutil.joinSlashy(a, l.worktree, cand.rel);
                if (cand.at_kept_path and store_ready and c.key != null) {
                    try at_kept.append(a, .{ .path = path, .tree = l.worktree });
                    continue;
                }
                try reported.append(a, path);
                if (cand.hidden_tracked_edit) {
                    try r.fail(ctx, try gitCmd(ctx, l.worktree, "update-index --no-skip-worktree --no-assume-unchanged -- {s}", .{try ui.shellQuote(a, cand.rel)}), "edit git hides in a tracked file: {s}", .{try util.show(ctx, path)});
                } else if (cand.submodule_uninitialized) {
                    try r.fail(ctx, try review_all(ctx, l.worktree), "files in a submodule that is not initialized: {s}", .{try util.show(ctx, path)});
                } else {
                    try r.fail(ctx, try review_all(ctx, l.worktree), "not kept: {s}", .{try util.show(ctx, path)});
                }
            }
            for (l.nested) |n| {
                const path = try fsutil.joinSlashy(a, l.worktree, n.repo);
                try reported.append(a, path);
                try r.fail(ctx, try std.fmt.allocPrint(a, "holt repo adopt {s}", .{try q(ctx, path)}), "nested repository: {s}", .{try util.show(ctx, path)});
            }
            for (l.submodules_failed) |s| {
                const path = try fsutil.joinSlashy(a, l.worktree, s);
                try r.fail(ctx, try gitCmd(ctx, path, "status", .{}), "submodule git cannot list: {s}", .{try util.show(ctx, path)});
            }
            for (l.submodules) |s| {
                if (paths_contains(l.submodules_failed, s)) continue;
                try checkSubmodule(ctx, r, asker, try fsutil.joinSlashy(a, l.worktree, s));
            }
        }
        for (all.unlisted) |u| {
            try unlisted_trees.append(a, u.worktree);
            const h = try kept_hints.unlisted(ctx, c.main, u.worktree, u.problem, u.detail);
            try r.fail(ctx, try runOf(ctx, h), "working tree git cannot list: {s}: {s}", .{ try util.show(ctx, u.worktree), h.what });
        }
        var subs: std.ArrayList([]const u8) = .empty;
        for (all.listings) |l| for (l.submodules) |s| try subs.append(a, try fsutil.joinSlashy(a, l.worktree, s));
        listed_subs = subs.items;
        const roots = try deleter.moduleRoots(a, c, .clone);
        const module_risks = try deleter.moduleRisks(asker, roots, subs.items);
        for (module_risks) |at| try failRisk(ctx, r, "submodule not checked out: ", at, module_risks);
        var module_trees: std.ArrayList([]const u8) = .empty;
        for (try deleter.moduleWorktrees(a, roots, subs.items)) |t| {
            try module_trees.append(a, t.path);
            try holders.append(a, try fsutil.realPathOrSelf(a, t.path));
        }
        sub_trees = module_trees.items;
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => try r.fail(ctx, try gitCmd(ctx, clone_path, "status", .{}), "the files holt does not keep in {s} cannot be listed ({s})", .{ shown, @errorName(err) }),
    }

    var covered: std.ArrayList([]const u8) = .empty;
    if (store_ready and c.key != null) {
        const Unsettled = struct { tree: []const u8, report: kept.reconcile.Report, item: kept.reconcile.Item, path: []const u8 };
        var found: std.ArrayList(Unsettled) = .empty;
        for (readable.items) |tree| {
            const report = kept.reconcile.reconcile(kctx, index, tree, .plan) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try r.fail(ctx, "holt sync", "the kept files of {s} cannot be evaluated ({s})", .{ try util.show(ctx, tree), @errorName(err) });
                    continue;
                },
            };
            if (report.stop != .none and report.stop != .store_absent and deleter.hasBlock(a, c.common_dir)) {
                const h = try kept_hints.forStop(ctx, tree, report.stop, report.key);
                try r.fail(ctx, try runOf(ctx, h), "the kept files of {s} cannot be evaluated: {s}", .{ try util.show(ctx, tree), h.what });
            }
            for (report.items) |item| {
                if (!item.unsettled) continue;
                if (item.outcome == .tree_unreadable and paths_contains(unlisted_trees.items, item.worktree orelse tree)) continue;
                const path = try fsutil.joinSlashy(a, item.worktree orelse tree, item.rel);
                if (kept.paths.contains(reported.items, path)) continue;
                try found.append(a, .{ .tree = tree, .report = report, .item = item, .path = path });
            }
        }
        var seen: std.ArrayList([]const u8) = .empty;
        for (found.items) |u| {
            if (u.item.worktree != null and u.item.outcome == .hidden and ownItem(found.items, u.path)) continue;
            try covered.append(a, u.path);
            const tag = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ u.path, @tagName(u.item.outcome) });
            if (kept.paths.contains(seen.items, tag)) continue;
            try seen.append(a, tag);
            const h = try kept_hints.forItem(ctx, u.tree, u.report.resolved orelse u.report.key, kctx.layout.synced_root, u.item);
            try r.fail(ctx, try runOf(ctx, h), "unsettled kept file: {s}: {s}", .{ try util.show(ctx, u.path), h.what });
        }
    }

    for (at_kept.items) |k| {
        if (kept.paths.contains(covered.items, k.path)) continue;
        try r.fail(ctx, try review_all(ctx, k.tree), "not kept: {s}", .{try util.show(ctx, k.path)});
    }

    try checkGoneRecords(ctx, r, c, unlisted_trees.items);
    try checkOps(ctx, r, c, listed_subs, sub_trees);
    try checkGit(ctx, r, asker, c.main, try std.mem.concat(a, []const u8, &.{ readable.items, sub_trees }), c.common_dir);
}

/// Fails on each record of `c` git's worktree list leaves out
/// (`deleter.unlistedRecords`), and each linked working tree of `c` holt
/// leaves to the user (`deleter.unresolvedSeen`), with
/// `deleter.unresolvedLine`, once for each path, but those of `listed`,
/// the working trees the listing named already; and on the staged changes only the record of each whose
/// directory is gone holds, with the lines the deleters give
/// (`deleter.LinkedTree.lines`), first the command bringing it back from
/// its record. What else such a record holds is weighed with the clone:
/// its HEAD and refs (`checkGit`), its operations in progress
/// (`checkOps`), and its submodule git directories
/// (`deleter.moduleRoots`).
fn checkGoneRecords(ctx: *app.Ctx, r: *Report, c: kept.clone.Clone, listed: []const []const u8) !void {
    const a = ctx.alloc;
    const records = kept.clone.linkedRecords(a, c.common_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    const unlisted = deleter.unlistedRecords(a, c.common_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    var named: std.ArrayList([]const u8) = .empty;
    for (listed) |p| try named.append(a, try deleter.resolvedPath(a, p));
    for (unlisted) |u| {
        if (kept.paths.contains(named.items, try deleter.resolvedPath(a, u.record))) continue;
        try r.fail(ctx, "", "{s}", .{try deleter.unresolvedLine(ctx, u.record, deleter.unlistedSeen(u), try deleter.mainGit(ctx, c.main))});
    }
    for (records) |rec| {
        const path = rec.path orelse continue;
        if (try deleter.unresolvedSeen(a, c.common_dir, records, rec)) |seen| {
            const at = try deleter.resolvedPath(a, path);
            if (kept.paths.contains(named.items, at)) continue;
            try named.append(a, at);
            try r.fail(ctx, "", "{s}", .{try deleter.unresolvedLine(ctx, path, seen, try deleter.mainGit(ctx, c.main))});
            continue;
        }
        const link = try deleter.linkOf(a, c.common_dir, rec.record, path);
        if (link == .there) continue;
        const staged = deleter.stagedIn(a, rec.record) catch |err| switch (err) {
            error.GitFailed => {
                try failRisk(ctx, r, "", .{ .repo = path, .risk = .{ .what = .unreadable } }, &.{});
                continue;
            },
            else => return err,
        };
        if (!staged) continue;
        const t: deleter.LinkedTree = .{ .path = path, .record = rec.record, .link = link, .staged = true };
        const force = try std.fmt.allocPrint(a, "holt repo remove {s} --clone --force", .{try ui.shellQuote(a, r.key)});
        for (try t.lines(ctx, c.main, force)) |line| try r.fail(ctx, "", "{s}", .{line});
    }
}

/// Fails on each operation in progress in the git directories a weighing
/// of the clone `c` reads (`deleter.cloneOps`, with the checked-out
/// submodules `subs`) and in those of `trees`, its submodules' linked
/// working trees that are there, each with the line the deleters give
/// (`deleter.opLine`); on git state that could not be read for one that
/// cannot be read.
fn checkOps(ctx: *app.Ctx, r: *Report, c: kept.clone.Clone, subs: []const []const u8, trees: []const []const u8) !void {
    const a = ctx.alloc;
    var ops: std.ArrayList(deleter.InProgress) = .empty;
    if (deleter.cloneOps(a, c, subs)) |found| try ops.appendSlice(a, found) else |err| switch (err) {
        error.GitFailed => try failRisk(ctx, r, "", .{ .repo = c.main, .risk = .{ .what = .unreadable } }, &.{}),
        else => return err,
    }
    for (trees) |tree| {
        if (try kept.content.entryAt(tree) != .dir) continue;
        if (deleter.treeOps(a, tree)) |found| try ops.appendSlice(a, found) else |err| switch (err) {
            error.GitFailed => try failRisk(ctx, r, "", .{ .repo = tree, .risk = .{ .what = .unreadable } }, &.{}),
            else => return err,
        }
    }
    const force = try std.fmt.allocPrint(a, "holt repo remove {s} --clone --force", .{try ui.shellQuote(a, r.key)});
    for (ops.items) |x| try r.fail(ctx, "", "{s}", .{try deleter.opLine(ctx, x, force)});
}

/// Whether `found` holds an item for `path` from the reconcile of the
/// working tree `path` is in, which names what settles it: another tree's
/// closing sweep reporting the same place as `hidden` says less.
fn ownItem(found: anytype, path: []const u8) bool {
    for (found) |u| {
        if (u.item.worktree == null and std.mem.eql(u8, u.path, path)) return true;
    }
    return false;
}

/// What the initialized submodule at `sub` holds that no remote has:
/// uncommitted changes and what `deleter.gitRisks` finds.
fn checkSubmodule(ctx: *app.Ctx, r: *Report, asker: deleter.Asker, sub: []const u8) !void {
    if (try git.isDirty(ctx.alloc, sub)) {
        try r.fail(ctx, try gitCmd(ctx, sub, "status", .{}), "uncommitted changes in a submodule: {s}", .{try util.show(ctx, sub)});
    }
    const risks = try riskAts(ctx.alloc, sub, try deleter.gitRisks(asker, sub));
    for (risks) |at| try failRisk(ctx, r, "submodule ", at, risks);
}

/// `risks`, each a risk of the repository at `repo`.
fn riskAts(a: std.mem.Allocator, repo: []const u8, risks: []const deleter.Risk) ![]const deleter.RiskAt {
    var out: std.ArrayList(deleter.RiskAt) = .empty;
    for (risks) |risk| try out.append(a, .{ .repo = repo, .risk = risk });
    return out.items;
}

/// Fails with `at` (`deleter.describeRisk`) after `lead`, naming the
/// command that settles it, if any; for the no-target line, and a URL that
/// did not answer, what that command does and the note it carries
/// (`deleter.noTargetHint`, `deleter.unaskedHint`); for git state that
/// could not be read, making it readable or deleting the clone
/// (`Report.key`) with `holt repo remove --force`. A URL a skipped host
/// kept from being asked is named once per host instead (`Report.held`),
/// and a note of URLs that did not answer only beside a line of the same
/// repository in `all` it is about (`deleter.besideLine`).
fn failRisk(ctx: *app.Ctx, r: *Report, comptime lead: []const u8, at: deleter.RiskAt, all: []const deleter.RiskAt) !void {
    if (deleter.skippedOf(at)) |sk| return r.held.add(ctx.alloc, sk, try util.show(ctx, at.repo));
    if (at.risk.what == .note and !deleter.besideLine(all, at.repo)) return;
    const what = try deleter.describeRisk(ctx, at);
    if (at.risk.what == .unreadable) return r.fail(ctx, "", lead ++ "{s}; make it readable, or delete it with holt repo remove {s} --clone --force", .{ what, try ui.shellQuote(ctx.alloc, r.key) });
    const way = switch (at.risk.what) {
        .no_target => try deleter.noTargetHint(ctx, at),
        .unasked => try deleter.unaskedHint(ctx, at),
        else => return r.fail(ctx, try deleter.settleRisk(ctx, at), lead ++ "{s}", .{what}),
    };
    try r.failAfter(ctx, way.cmd, way.note, lead ++ "{s}; {s}", .{ what, way.text });
}

/// `h`'s commands joined as a failing line names them; empty when only the
/// user can settle it.
fn runOf(ctx: *app.Ctx, h: kept_hints.Hint) ![]const u8 {
    const text = (try kept_hints.runText(ctx.alloc, h)) orelse return "";
    return text["run: ".len..];
}

/// What git holds only here: per working tree in `trees`, `recover.check`'s
/// uncommitted changes, stash entries, and state git cannot read; for the
/// clone at `main`, what `deleter.gitRisks` finds, and each remote on this
/// machine no no-target line names (`deleter.localRemotes`), which
/// `deleter.localHint` settles; and, with its common directory, the state
/// holt never keeps as notes.
fn checkGit(ctx: *app.Ctx, r: *Report, asker: deleter.Asker, main: []const u8, trees: []const []const u8, common_dir: ?[]const u8) !void {
    const a = ctx.alloc;
    for (trees, 0..) |tree, i| {
        const verdict = try recover.check(a, tree);
        for (verdict.blockers.items) |b| switch (b) {
            .dirty => try r.fail(ctx, try gitCmd(ctx, tree, "status", .{}), "uncommitted changes: {s}", .{try util.show(ctx, tree)}),
            .stashes => if (i == 0) try r.fail(ctx, try gitCmd(ctx, tree, "stash list", .{}), "stash entries: {s}", .{try util.show(ctx, tree)}),
            .unreadable => try failRisk(ctx, r, "", .{ .repo = tree, .risk = .{ .what = .unreadable } }, &.{}),
            .unpushed, .no_upstream => {},
        };
    }

    var named: std.ArrayList([]const u8) = .empty;
    const risks = try riskAts(a, main, try deleter.gitRisks(asker, main));
    for (risks) |at| {
        if (at.risk.what == .stashes) continue;
        if (at.risk.what == .no_target) for (at.risk.gone) |g| try named.append(a, g.name);
        try failRisk(ctx, r, "", at, risks);
    }
    const locals = deleter.localRemotes(asker, main) catch |err| switch (err) {
        error.GitFailed => &.{},
        else => return err,
    };
    const shown = try util.show(ctx, main);
    for (locals) |g| {
        if (paths_contains(named.items, g.name)) continue;
        const h = try deleter.localHint(ctx, main, g);
        if (h.cmd.len == 0) {
            try r.fail(ctx, "", "{s}, so no other machine can restore from it: {s}", .{ h.text, shown });
        } else try r.failAfter(ctx, h.cmd, h.note, "{s}, so no other machine can restore from it: {s}; {s}", .{ h.text, shown, h.way });
    }
    if (common_dir) |cd| try notesFor(ctx, r, cd);
}

fn paths_contains(list: []const []const u8, s: []const u8) bool {
    return kept.paths.contains(list, s);
}

/// Every entry under `code_root` that lies outside the clones and the
/// working trees they record (`holders`, real paths): files, and the
/// outermost directories holding files, that no clone holds, what is left
/// in a `<clone>@worktrees` directory beside the working trees git
/// records, and clone staging an interrupted clone left (`*.holt-tmp`).
/// A directory holding only directories is looked into; links, empty
/// directories, and what the skip patterns name are passed over.
fn checkCodeRoot(ctx: *app.Ctx, r: *Report, kctx: ?kept.Ctx, holders: []const []const u8) !void {
    const a = ctx.alloc;
    const ws = ctx.context.?.ws;
    const Loose = struct { path: []const u8, rel: []const u8, dir: bool, stale: bool };
    var loose: std.ArrayList(Loose) = .empty;
    const Dir = struct { path: []const u8, rel: []const u8, bucket: bool };
    var todo: std.ArrayList(Dir) = .empty;
    try todo.append(a, .{ .path = ws.cfg.code_root, .rel = "", .bucket = false });
    while (todo.pop()) |here| {
        var d = std.Io.Dir.cwd().openDir(io(), here.path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                try r.fail(ctx, try std.fmt.allocPrint(a, "ls -la {s}", .{try q(ctx, here.path)}), "the code tree cannot be read at {s}", .{try util.show(ctx, here.path)});
                continue;
            },
        };
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| {
            if (e.kind == .sym_link) continue;
            const path = try std.fs.path.join(a, &.{ here.path, e.name });
            const rel = if (here.rel.len == 0) try a.dupe(u8, e.name) else try std.mem.concat(a, u8, &.{ here.rel, "/", e.name });
            if (e.kind != .directory) {
                try loose.append(a, .{ .path = path, .rel = rel, .dir = false, .stale = here.bucket });
                continue;
            }
            const real = try fsutil.realPathOrSelf(a, path);
            if (paths_contains(holders, real)) continue;
            if (std.mem.endsWith(u8, e.name, ".holt-tmp")) {
                try r.fail(ctx, "holt doctor --fix", "clone staging an interrupted clone left: {s}", .{try util.show(ctx, path)});
                continue;
            }
            const above = for (holders) |h| {
                if (h.len > real.len and fsutil.pathIsInside(h, real)) break true;
            } else false;
            const bucket = here.bucket or std.mem.endsWith(u8, e.name, "@worktrees");
            if (above or !try holdsFile(path)) {
                try todo.append(a, .{ .path = path, .rel = rel, .bucket = bucket });
                continue;
            }
            try loose.append(a, .{ .path = path, .rel = rel, .dir = true, .stale = bucket });
        }
    }
    if (loose.items.len == 0) return;
    std.mem.sort(Loose, loose.items, {}, struct {
        fn less(_: void, x: Loose, y: Loose) bool {
            return kept.paths.lessThan({}, x.rel, y.rel);
        }
    }.less);
    var skipped: []const bool = &.{};
    if (kctx) |k| {
        var queries: std.ArrayList(kept.patterns.Query) = .empty;
        for (loose.items) |l| try queries.append(a, .{ .path = l.rel, .dir = l.dir });
        skipped = kept.patterns.hubSkipped(k, queries.items, null) catch &.{};
    }
    const settle = "move it into a clone or out of the code tree, or delete it";
    for (loose.items, 0..) |l, i| {
        if (i < skipped.len and skipped[i]) continue;
        if (l.stale) {
            try r.fail(ctx, "", "left in a worktree directory, in no working tree git records: {s}; " ++ settle, .{try util.show(ctx, l.path)});
        } else {
            try r.fail(ctx, "", "in the code tree, inside no clone: {s}; " ++ settle, .{try util.show(ctx, l.path)});
        }
    }
}

/// Whether the directory at `path` directly holds anything but directories
/// and links; true when it cannot be read.
fn holdsFile(path: []const u8) !bool {
    var d = std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true }) catch return true;
    defer d.close(io());
    var it = d.iterate();
    while (it.next(io()) catch return true) |e| {
        if (e.kind != .directory and e.kind != .sym_link) return true;
    }
    return false;
}

/// The state holt never keeps in the clone whose common directory is
/// `common_dir`: hooks other than git's samples, configuration sections
/// other than core, remote, branch, and submodule (which `git submodule
/// init` derives from `.gitmodules`) holding a key git did not write for
/// holt (`holtSet`), and lines outside holt's block in `info/exclude`.
fn notesFor(ctx: *app.Ctx, r: *Report, common_dir: []const u8) !void {
    const a = ctx.alloc;
    const hooks = try std.fs.path.join(a, &.{ common_dir, "hooks" });
    if (std.Io.Dir.cwd().openDir(io(), hooks, .{ .iterate = true })) |opened| {
        var d = opened;
        defer d.close(io());
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (it.next(io()) catch null) |e| {
            if (std.mem.endsWith(u8, e.name, ".sample")) continue;
            try names.append(a, try a.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, kept.paths.lessThan);
        for (names.items) |n| try r.note(ctx, "git hook: {s}", .{try util.show(ctx, try std.fs.path.join(a, &.{ hooks, n }))});
    } else |_| {}

    const cfg = try std.fs.path.join(a, &.{ common_dir, "config" });
    const listed = try git.runInRepoScoped(a, &.{ "config", "--file", cfg, "--name-only", "--list" }, common_dir);
    if (listed.status == 0) {
        var sections: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, listed.stdout, "\r\n");
        while (it.next()) |name| {
            const dot = std.mem.indexOfScalar(u8, name, '.') orelse continue;
            const section = name[0..dot];
            const clone_own = for ([_][]const u8{ "core", "remote", "branch", "submodule" }) |x| {
                if (std.ascii.eqlIgnoreCase(section, x)) break true;
            } else false;
            if (clone_own) continue;
            if (holtSet(name)) continue;
            if (paths_contains(sections.items, section)) continue;
            try sections.append(a, section);
        }
        for (sections.items) |s| try r.note(ctx, "git config section [{s}]: {s}", .{ s, try util.show(ctx, cfg) });
    }

    const exclude = try kept.block.excludePath(a, common_dir);
    const text = kept.content.readSmall(a, exclude) catch return;
    const outside = if (kept.block.parse(a, text)) |p| try std.mem.concat(a, u8, &.{ p.before, "\n", p.after }) else |_| text;
    var it = std.mem.tokenizeAny(u8, outside, "\r\n");
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0 or t[0] == '#') continue;
        try r.note(ctx, "info/exclude line outside holt's block: {s} ({s})", .{ try ui.printable(a, t), try util.show(ctx, exclude) });
    }
}

/// Whether git writes the configuration key `name` for what holt asks of
/// it: `extensions.relativeWorktrees`, for the relative worktree links
/// `git.worktreeAdd` asks for.
fn holtSet(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "extensions.relativeworktrees");
}

/// Every loose entry of every directory under `<hub_root>/*/*`, hubs no
/// project owns any more included, and every file directly under
/// `<hub_root>/*`: anything but a link at the hub root or in its `code/`,
/// an empty directory, or what the skip patterns name.
fn checkHubs(ctx: *app.Ctx, r: *Report, kctx: ?kept.Ctx) !void {
    const a = ctx.alloc;
    const ws = ctx.context.?.ws;
    var root = std.Io.Dir.openDirAbsolute(io(), ws.cfg.hub_root, .{ .iterate = true }) catch return;
    defer root.close(io());
    var orgs = root.iterate();
    while (try orgs.next(io())) |org| {
        if (org.kind != .directory) continue;
        var org_dir = root.openDir(io(), org.name, .{ .iterate = true }) catch continue;
        defer org_dir.close(io());
        var files: std.ArrayList([]const u8) = .empty;
        var names = org_dir.iterate();
        while (try names.next(io())) |name| {
            if (name.kind == .sym_link) continue;
            if (name.kind != .directory) {
                try files.append(a, try a.dupe(u8, name.name));
                continue;
            }
            const hub_path = try std.fs.path.join(a, &.{ ws.cfg.hub_root, org.name, name.name });
            const content_dir = try std.fs.path.join(a, &.{ ws.cfg.synced_root, "projects", org.name, name.name });
            const orphan = !fsutil.exists(try std.fs.path.join(a, &.{ content_dir, marker.marker_basename })) and !marker.markerEvicted(a, content_dir);
            try checkHub(ctx, r, kctx, hub_path, orphan);
        }
        if (files.items.len == 0) continue;
        std.mem.sort([]const u8, files.items, {}, kept.paths.lessThan);
        var skipped: []const bool = &.{};
        if (kctx) |k| {
            var queries: std.ArrayList(kept.patterns.Query) = .empty;
            for (files.items) |n| try queries.append(a, .{ .path = n, .dir = false });
            skipped = kept.patterns.hubSkipped(k, queries.items, null) catch &.{};
        }
        for (files.items, 0..) |n, i| {
            if (i < skipped.len and skipped[i]) continue;
            const path = try std.fs.path.join(a, &.{ ws.cfg.hub_root, org.name, n });
            try r.fail(ctx, try std.fmt.allocPrint(a, "mv {s} {s}", .{ try q(ctx, path), try q(ctx, ws.cfg.synced_root) }), "loose file in a hub org directory: {s}", .{try util.show(ctx, path)});
        }
    }
}

fn checkHub(ctx: *app.Ctx, r: *Report, kctx: ?kept.Ctx, hub_path: []const u8, orphan: bool) !void {
    const a = ctx.alloc;
    const ws = ctx.context.?.ws;
    const Loose = struct { path: []const u8, name: []const u8, dir: bool, in_code: bool };
    var loose: std.ArrayList(Loose) = .empty;
    var hub = std.Io.Dir.openDirAbsolute(io(), hub_path, .{ .iterate = true }) catch {
        try r.fail(ctx, try std.fmt.allocPrint(a, "ls -la {s}", .{try q(ctx, hub_path)}), "hub cannot be read: {s}", .{try util.show(ctx, hub_path)});
        return;
    };
    defer hub.close(io());
    var it = hub.iterate();
    while (try it.next(io())) |e| {
        if (e.kind == .sym_link) continue;
        const path = try std.fs.path.join(a, &.{ hub_path, e.name });
        if (e.kind == .directory and std.mem.eql(u8, e.name, "code")) {
            var code = hub.openDir(io(), "code", .{ .iterate = true }) catch continue;
            defer code.close(io());
            var cit = code.iterate();
            while (try cit.next(io())) |ce| {
                if (ce.kind == .sym_link) continue;
                const cpath = try std.fs.path.join(a, &.{ path, ce.name });
                if (ce.kind == .directory and !try kept.content.holdsAnything(a, cpath)) continue;
                try loose.append(a, .{ .path = cpath, .name = try a.dupe(u8, ce.name), .dir = ce.kind == .directory, .in_code = true });
            }
            continue;
        }
        if (e.kind == .directory and !try kept.content.holdsAnything(a, path)) continue;
        try loose.append(a, .{ .path = path, .name = try a.dupe(u8, e.name), .dir = e.kind == .directory, .in_code = false });
    }
    if (loose.items.len == 0) return;

    var skipped: []const bool = &.{};
    if (kctx) |k| {
        var queries: std.ArrayList(kept.patterns.Query) = .empty;
        for (loose.items) |l| try queries.append(a, .{ .path = l.name, .dir = l.dir });
        skipped = kept.patterns.hubSkipped(k, queries.items, null) catch &.{};
    }
    for (loose.items, 0..) |l, i| {
        if (i < skipped.len and skipped[i]) continue;
        const cmd = if (orphan)
            try std.fmt.allocPrint(a, "mv {s} {s}", .{ try q(ctx, l.path), try q(ctx, ws.cfg.synced_root) })
        else if (l.in_code)
            try std.fmt.allocPrint(a, "mv {s} {s} && holt keep {s}", .{ try q(ctx, l.path), try q(ctx, hub_path), try q(ctx, try std.fs.path.join(a, &.{ hub_path, l.name })) })
        else
            try std.fmt.allocPrint(a, "holt keep {s}", .{try q(ctx, l.path)});
        try r.fail(ctx, cmd, "loose entry in {s}hub: {s}", .{ if (orphan) "an orphaned " else "a ", try util.show(ctx, l.path) });
    }
}

const std_testing = std.testing;
const testutil = @import("../testutil.zig");
const builtin = @import("builtin");
const Fixture = deleter.Fixture;

/// `doctor --retire` over `f`'s workspace.
fn retireRun(f: *const Fixture) !testutil.RunResult {
    return f.run(doctor_cmd.command.run, &.{"--retire"});
}

fn has(out: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, out, needle) != null;
}

/// The failing line of `out` naming `what`, which must carry `cmd`.
fn expectFail(out: []const u8, what: []const u8, cmd: []const u8) !void {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (!has(line, what)) continue;
        if (has(line, "(run: ") and has(line, cmd)) return;
    }
    std.debug.print("no failing line naming \"{s}\" with \"{s}\" in:\n{s}\n", .{ what, cmd, out });
    return error.TestUnexpectedResult;
}

test "doctor --retire: fails on a deinitialized submodule's unpushed branch in the clone's .git/modules" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const remote_owned = try testutil.makeBareRepo(&sb, "sub.git");
    defer sb.alloc.free(remote_owned);
    try testutil.runGit(&sb, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "sub" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "add sub" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });
    try testutil.runGit(&sb, try f.path("sub"), &.{ "switch", "-q", "-c", "wip" });
    try testutil.runGit(&sb, try f.path("sub"), &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    try testutil.runGit(&sb, f.clone, &.{ "submodule", "deinit", "-q", "-f", "sub" });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const gd = try ui.quotePath(a, app.envOf_current(), try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }));
    try expectFail(got.out, try std.fmt.allocPrint(a, "submodule not checked out: commits of branch wip no remote has, in {s}", .{gd}), "push --recurse-submodules=no -- origin refs/heads/wip:refs/heads/wip");
}

test "doctor --retire: a clean machine passes, lists this machine, and ends with the command that retires it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");

    const got = try retireRun(&f);
    if (got.code != 0) std.debug.print("{s}\n", .{got.out});
    try std_testing.expectEqual(@as(u8, 0), got.code);
    try std_testing.expect(has(got.out, "retire: nothing exists only on this machine: PASS"));
    try std_testing.expect(has(got.out, "Before wiping this machine, check that your cloud client shows no pending uploads.\n"));
    var buf: [kept.machine.host_name_max]u8 = undefined;
    try std_testing.expect(has(got.out, try std.fmt.allocPrint(a, "machines with kept files (a machine that is gone: holt keep --retire-machine <id>):\n  {s} ({s}, this machine), last record {s} UTC\n", .{ f.kctx.machine_id, kept.machine.hostName(&buf), try kept.store.today(a) })));
    try std_testing.expect(std.mem.endsWith(u8, got.out, "Once everything passes, run on this machine, last: holt keep --retire-machine\n"));
}

test "doctor --retire: a place whose name holds a control character is shown with \\xHH, never raw" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.ignore("/s\x01.txt");
    try f.write(f.clone, "s\x01.txt", "only here");
    try f.ignore("/v\tdir/");
    const nested = try f.path("v\tdir");
    try fsutil.ensureDir(nested);
    try testutil.runGit(&sb, nested, &.{ "init", "-q" });

    const got = try retireRun(&f);
    try std_testing.expect(has(got.out, try std.fmt.allocPrint(a, "  not kept: {s} (run: ", .{try ui.printable(a, try fsutil.contractTilde(a, app.envOf_current(), try f.path("s\x01.txt")))})));
    try std_testing.expect(has(got.out, try std.fmt.allocPrint(a, "  nested repository: {s} (run: ", .{try ui.printable(a, try fsutil.contractTilde(a, app.envOf_current(), nested))})));
    try std_testing.expect(std.mem.indexOfAny(u8, got.out, "\x01\t") == null);
}

test "doctor --retire: on a retired machine it says so, naming the host that retired it, instead of naming --retire-machine, until the machine keeps files again" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const index = try kept.store.loadIndex(a, f.kctx.layout);
    try kept.store.writeRetired(a, f.kctx.layout, &index, f.kctx.machine_id, "2026-09-28", "old-host", "00000000000000bb");

    const got = try retireRun(&f);
    try std_testing.expect(has(got.out, ", retired 2026-09-28 UTC\n"));
    try std_testing.expect(std.mem.endsWith(u8, got.out, try std.fmt.allocPrint(a, "This machine was retired on 2026-09-28 UTC: holt keep --retire-machine {s} ran on old-host (machine 00000000000000bb).\n", .{f.kctx.machine_id})));
    try kept.store.writeRetired(a, f.kctx.layout, &index, f.kctx.machine_id, "2026-09-28", "old-host", f.kctx.machine_id);
    const here = try retireRun(&f);
    try std_testing.expect(std.mem.endsWith(u8, here.out, "This machine was retired on 2026-09-28 UTC from old-host: holt keep --retire-machine has run here.\n"));

    try f.write(f.clone, ".env.late", "late");
    try f.keep(f.clone, ".env.late");
    const again = try retireRun(&f);
    try std_testing.expect(has(again.out, ", retired 2026-09-28 UTC, active again\n"));
    try std_testing.expect(has(again.out, "This machine was retired on 2026-09-28 UTC from old-host, and has kept files changed since.\n"));
    try std_testing.expect(std.mem.endsWith(u8, again.out, "Once everything passes, run on this machine, last: holt keep --retire-machine\n"));
}

test "doctor --retire: fails on each planted risk with its command, and lists what holt does not keep" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const config_home = try std.fs.path.join(a, &.{ sb.root, "config" });
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", config_home },
    });
    defer state.restore();
    var f = try Fixture.init(a, &sb, true);
    f.ws.cfg.backend = "dropbox";
    const g = struct {
        fn run(fx: *const Fixture, args: []const []const u8) !void {
            try testutil.runGit(fx.sb, fx.clone, args);
        }
    }.run;

    try f.write(config_home, "holt/config.toml", "[workspace]\n");
    try f.ignore("/secret.txt");
    try f.write(f.clone, "secret.txt", "only here");
    try f.ignore("/vendor/");
    try fsutil.ensureDir(try f.path("vendor/lib"));
    try testutil.runGit(&sb, try f.path("vendor/lib"), &.{ "init", "-q" });
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try fsutil.removePath(try f.path(".env.kept"));
    try f.write(f.clone, ".env.kept", "saved by rename");

    try f.write(f.clone, "notes.txt", "tracked");
    try g(&f, &.{ "add", "notes.txt" });
    try g(&f, &.{ "commit", "-q", "-m", "notes" });
    try g(&f, &.{ "update-index", "--skip-worktree", "notes.txt" });
    try f.write(f.clone, "notes.txt", "hidden edit");
    try f.write(f.clone, "README", "stashed");
    try g(&f, &.{ "stash", "-q" });
    try f.write(f.clone, "README", "uncommitted");
    try g(&f, &.{ "branch", "feature" });
    try g(&f, &.{ "tag", "-a", "-m", "only here", "v1" });
    try g(&f, &.{ "config", "user.name", "someone" });
    try f.write(f.clone, ".git/hooks/pre-commit", "#!/bin/sh\n");

    const solo = try fsutil.joinSlashy(a, f.ws.cfg.code_root, "local/solo");
    try fsutil.ensureDir(solo);
    try testutil.runGit(&sb, solo, &.{ "init", "-q" });
    try testutil.runGit(&sb, solo, &.{ "commit", "-q", "--allow-empty", "-m", "one" });

    try testutil.writeMarker(a, try f.ws.projectsRoot(a), "acme", "proj", .empty, .empty);
    try f.write(f.ws.cfg.hub_root, "acme/proj/draft.md", "loose");
    try f.write(f.ws.cfg.hub_root, "acme/gone/left.md", "orphaned");
    try f.write(f.ws.cfg.hub_root, "acme/proj/.DS_Store", "skipped");

    const got = try retireRun(&f);
    const out = got.out;
    try std_testing.expectEqual(@as(u8, 1), got.code);
    try std_testing.expect(has(out, "retire: nothing exists only on this machine: FAIL"));
    try expectFail(out, "not kept: ", "holt keep --review ");
    try expectFail(out, "secret.txt", "holt keep --review ");
    try expectFail(out, "nested repository: ", "holt repo adopt ");
    try expectFail(out, ".env.kept", "holt keep");
    try expectFail(out, "edit git hides in a tracked file: ", "update-index --no-skip-worktree --no-assume-unchanged -- notes.txt");
    try expectFail(out, "uncommitted changes: ", " status");
    try expectFail(out, "stash entries: ", " stash list");
    try expectFail(out, "commits of branch feature no remote has", "push --recurse-submodules=no -- origin refs/heads/feature:refs/heads/feature");
    try expectFail(out, "commits of branch main no remote has", "push --recurse-submodules=no -- origin refs/heads/main:refs/heads/holt-kept/main");
    try expectFail(out, "the tag only refs/tags/v1 names, no remote has", "push --recurse-submodules=no -- origin refs/tags/v1:refs/tags/holt-kept/tags/v1");
    try expectFail(out, "no remote counts as a copy: it has no remote; add a remote on another machine", "remote add origin <url>");
    try std_testing.expect(!has(out, "cannot be evaluated"));
    try expectFail(out, "loose entry in a hub: ", try std.fmt.allocPrint(a, "holt keep {s}", .{try ui.quotePath(a, app.envOf_current(), try std.fs.path.join(a, &.{ f.ws.cfg.hub_root, "acme", "proj", "draft.md" }))}));
    try expectFail(out, "loose entry in an orphaned hub: ", "mv ");
    try std_testing.expect(!has(out, ".DS_Store"));
    try std_testing.expect(has(out, "git hook: "));
    try std_testing.expect(has(out, "pre-commit"));
    try std_testing.expect(has(out, "git config section [user]"));
    try std_testing.expect(has(out, "info/exclude line outside holt's block: /secret.txt"));
    try std_testing.expect(has(out, "holt's configuration: "));
    try std_testing.expect(std.mem.endsWith(u8, out, "Before wiping this machine, check that dropbox shows no pending uploads.\nOnce everything passes, run on this machine, last: holt keep --retire-machine\n"));
    try std_testing.expectEqualStrings("only here", try kept.content.readSmall(a, try f.path("secret.txt")));
    try std_testing.expectEqualStrings("saved by rename", try kept.content.readSmall(a, try f.path(".env.kept")));
}

test "doctor --retire: an unsettled kept file names the command every command gives for it, and that command settles it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try kept.clone.addPending(a, try std.fs.path.join(a, &.{ f.clone, ".git" }), .{ .tree = ".", .rel = ".env.kept", .op = .take_local, .worktree = f.clone });
    const qp = try ui.quotePath(a, app.envOf_current(), try f.path(".env.kept"));

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    try expectFail(got.out, ".env.kept", try std.fmt.allocPrint(a, "holt keep --take-local {s}", .{qp}));
    try std_testing.expect(!has(got.out, "(interrupted)"));

    const took = try f.run(@import("keep.zig").command.run, &.{ "--take-local", try f.path(".env.kept") });
    try std_testing.expectEqual(@as(u8, 0), took.code);
    const again = try retireRun(&f);
    try std_testing.expect(!has(again.out, ".env.kept"));
}

test "doctor --retire: a kept path that differs in another working tree is named once, with the command that settles it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const wt_path = try std.fs.path.join(a, &.{ sb.root, "wt" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "-b", "feature", wt_path });
    const wt = try fsutil.realPathOrSelf(a, wt_path);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try f.write(wt, ".env.kept", "the worktree's own");

    const qp = try ui.quotePath(a, app.envOf_current(), try fsutil.joinSlashy(a, wt, ".env.kept"));

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    try std_testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, try std.fmt.allocPrint(a, "unsettled kept file: {s}:", .{try fsutil.contractTilde(a, app.envOf_current(), try fsutil.joinSlashy(a, wt, ".env.kept"))})));
    try expectFail(got.out, "local copy differs from the kept copy", try std.fmt.allocPrint(a, "holt keep --take-local {s}", .{qp}));

    try std_testing.expectEqual(@as(u8, 0), (try f.run(@import("keep.zig").command.run, &.{ "--take-local", try fsutil.joinSlashy(a, wt, ".env.kept") })).code);
    const again = try retireRun(&f);
    try std_testing.expect(!has(again.out, ".env.kept"));
}

test "doctor --retire: takes no other option" {
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(a, sb.root);
    const got = try testutil.runCmd(a, doctor_cmd.command.run, ws, &.{ "--retire", "--fix" });
    try std_testing.expectEqual(@as(u8, 2), got.code);
}

/// A sandboxed `Fixture` whose state and config live in the sandbox.
fn retireEnv(a: std.mem.Allocator, sb: *testutil.Sandbox) !testutil.EnvScope {
    return testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
}

test "doctor --retire: fails on what the code tree holds outside every clone, notes, and files in a hub org directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const code = f.ws.cfg.code_root;

    try f.write(code, "scratch/notes.txt", "only here");
    try f.write(code, "loose.txt", "only here too");
    try f.write(code, "github.com/acme/x@worktrees/old/notes.txt", "left by a raw removal");
    try f.write(code, "github.com/acme/y.AbC123.holt-tmp/README", "partial clone");
    try f.write(code, ".DS_Store", "skipped");
    try fsutil.ensureDir(try fsutil.joinSlashy(a, code, "empty/dir"));
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "-u", "origin", "feature" });
    try testutil.runGit(&sb, f.bare, &.{ "branch", "-D", "feature" });
    try testutil.runGit(&sb, f.clone, &.{ "notes", "add", "-m", "a note", "HEAD" });
    try f.write(f.ws.cfg.hub_root, "acme/loose.md", "org-level loose file");

    const got = try retireRun(&f);
    const out = got.out;
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const settle = "; move it into a clone or out of the code tree, or delete it\n";
    try std_testing.expect(has(out, try std.fmt.allocPrint(a, "  in the code tree, inside no clone: {s}{s}", .{ try fsutil.contractTilde(a, app.envOf_current(), try fsutil.joinSlashy(a, code, "scratch")), settle })));
    try std_testing.expect(has(out, try std.fmt.allocPrint(a, "  in the code tree, inside no clone: {s}{s}", .{ try fsutil.contractTilde(a, app.envOf_current(), try fsutil.joinSlashy(a, code, "loose.txt")), settle })));
    try std_testing.expect(has(out, try std.fmt.allocPrint(a, "  left in a worktree directory, in no working tree git records: {s}{s}", .{ try fsutil.contractTilde(a, app.envOf_current(), try fsutil.joinSlashy(a, code, "github.com/acme/x@worktrees/old")), settle })));
    try std_testing.expect(!has(out, "ls -la"));
    try expectFail(out, "clone staging an interrupted clone left: ", "holt doctor --fix");
    try std_testing.expect(!has(out, "feature"));
    try expectFail(out, "commits only refs/notes/commits holds, no remote has", "push --recurse-submodules=no -- origin refs/notes/commits:refs/heads/holt-kept/notes/commits");
    try expectFail(out, "loose file in a hub org directory: ", "mv ");
    try std_testing.expect(!has(out, ".DS_Store"));
    try std_testing.expect(!has(out, "empty"));
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| try std_testing.expect(!(has(line, "inside no clone") and has(line, "holt-test.invalid")));
}

test "doctor --retire: the extension holt's worktrees make git write is not listed as state holt does not keep" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    try git.worktreeAdd(a, f.clone, try std.fmt.allocPrint(a, "{s}@worktrees/feature", .{f.clone}), "feature", null);

    const got = try retireRun(&f);
    try std_testing.expect(!has(got.out, "[extensions]"));

    try testutil.runGit(&sb, f.clone, &.{ "config", "extensions.worktreeConfig", "true" });
    const other = try retireRun(&f);
    try std_testing.expect(has(other.out, "git config section [extensions]: "));
}

test "doctor --retire: a remote list git cannot read is a failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const cfg = try std.fs.path.join(a, &.{ f.clone, ".git", "config" });
    const old = try kept.content.readSmall(a, cfg);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = cfg, .data = try std.mem.concat(a, u8, &.{ old, "[remote \"broken\"]\n\tfetch\n" }) });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    try std_testing.expect(has(got.out, try std.fmt.allocPrint(a, "  git state of {s} could not be read; make it readable, or delete it with holt repo remove holt-test.invalid/acme/widget --clone --force\n", .{try fsutil.contractTilde(a, app.envOf_current(), f.clone)})));
    const removed = try f.run(@import("repo.zig").remove_command.run, &.{ "holt-test.invalid/acme/widget", "--clone", "--force", "--yes" });
    try std_testing.expectEqual(@as(u8, 0), removed.code);
    try std_testing.expect(!has((try retireRun(&f)).out, "could not be read"));
}

test "doctor --retire: fails on a submodule's unpushed commit, stash, and hidden work, and on untracked files status.showUntrackedFiles hides" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const remote_owned = try testutil.makeBareRepo(&sb, "sub.git");
    defer sb.alloc.free(remote_owned);
    const g = struct {
        fn run(fx: *const Fixture, dir: []const u8, args: []const []const u8) !void {
            try testutil.runGit(fx.sb, dir, args);
        }
    }.run;
    try g(&f, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "sub" });
    try g(&f, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "quiet" });
    try g(&f, f.clone, &.{ "config", "-f", ".gitmodules", "submodule.quiet.ignore", "all" });
    try g(&f, f.clone, &.{ "add", ".gitmodules" });
    try g(&f, f.clone, &.{ "commit", "-q", "-m", "add submodules" });
    const sub = try f.path("sub");
    try f.write(sub, "work.txt", "unpushed work");
    try g(&f, sub, &.{ "add", "work.txt" });
    try g(&f, sub, &.{ "commit", "-q", "-m", "local only" });
    try f.write(sub, "stashme", "s");
    try g(&f, sub, &.{ "stash", "-q", "-u" });
    try g(&f, f.clone, &.{ "add", "sub" });
    try g(&f, f.clone, &.{ "commit", "-q", "-m", "bump sub" });
    try g(&f, f.clone, &.{ "push", "-q", "origin", "HEAD" });
    try f.write(try f.path("quiet"), "draft.md", "only here, untracked in a submodule git is told to ignore");
    try g(&f, f.clone, &.{ "config", "status.showUntrackedFiles", "no" });
    try f.write(f.clone, "draft.md", "only here");

    const got = try retireRun(&f);
    const out = got.out;
    try std_testing.expectEqual(@as(u8, 1), got.code);
    try expectFail(out, "submodule commits of branch main no remote has", "push --recurse-submodules=no -- origin refs/heads/main:refs/heads/holt-kept/main");
    try expectFail(out, "submodule stash entries of ", " stash list");
    try expectFail(out, "uncommitted changes in a submodule: ", " status");
    try expectFail(out, "quiet", " status");
    try expectFail(out, "uncommitted changes: ", " status");
}

test "doctor --retire: a commit only a custom local ref holds fails, as the deleters refuse it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "--detach" });
    try f.write(f.clone, "exp.txt", "only here");
    try testutil.runGit(&sb, f.clone, &.{ "add", "exp.txt" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "held by a custom ref" });
    try testutil.runGit(&sb, f.clone, &.{ "update-ref", "refs/backup/exp", "HEAD" });
    try testutil.runGit(&sb, f.clone, &.{ "switch", "-q", "main" });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
}

test "doctor --retire: the submodule config section git derives from .gitmodules is not listed as state holt does not keep" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const remote_owned = try testutil.makeBareRepo(&sb, "sub.git");
    defer sb.alloc.free(remote_owned);
    try testutil.runGit(&sb, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "sub" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "add sub" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });
    try testutil.runGit(&sb, f.clone, &.{ "config", "user.signingkey", "only-here" });

    const got = try retireRun(&f);
    try std_testing.expect(!has(got.out, "[submodule]"));
    try std_testing.expect(has(got.out, "git config section [user]: "));
}

test "doctor --retire: a submodule's linked working tree is weighed like the clone's own" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const remote_owned = try testutil.makeBareRepo(&sb, "sub.git");
    defer sb.alloc.free(remote_owned);
    try testutil.runGit(&sb, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "sub" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "add sub" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });
    const sub_wt = try std.fs.path.join(a, &.{ sb.root, "sub-wt" });
    try testutil.runGit(&sb, try f.path("sub"), &.{ "worktree", "add", "-q", "--detach", sub_wt });
    try f.write(sub_wt, "draft.txt", "only here");

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    try expectFail(got.out, "sub-wt", "uncommitted changes: ");
}

/// Where `doctor --retire` finds an operation in progress: a rebase in the
/// clone, in a linked working tree, or in one that is gone, holding an
/// autostash, or a bisect in a submodule.
const OpAt = enum { clone, linked, gone, submodule };

test "doctor --retire: an operation in progress in any git directory it weighs fails, with the line the deleters give, and the command it names settles it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for (std.enums.values(OpAt)) |at| {
        var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(std_testing.allocator);
        defer sb.deinit();
        const state = try retireEnv(a, &sb);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const env = app.envOf_current();
        const rebase = "export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid; echo dirty >> README && git -c sequence.editor='sed -i.orig s/^pick/edit/' rebase -i --autostash --root";
        const tree = switch (at) {
            .clone => f.clone,
            .linked, .gone => try std.fs.path.join(a, &.{ sb.root, "linked" }),
            .submodule => try f.path("sub"),
        };
        switch (at) {
            .clone => {},
            .linked, .gone => try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", tree }),
            .submodule => {
                const remote_owned = try testutil.makeBareRepo(&sb, "sub.git");
                defer sb.alloc.free(remote_owned);
                try testutil.runGit(&sb, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "sub" });
                try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "add sub" });
                try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });
            },
        }
        const script = if (at == .submodule) "git bisect start" else rebase;
        const res = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", script }, tree, &sb.git_env.map);
        try std_testing.expectEqual(@as(u8, 0), res.status);
        const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, tree)).stdout, " \r\n");
        const ts = try fsutil.contractTilde(a, env, tree);
        const tq = try ui.quotePath(a, env, tree);
        const line = switch (at) {
            .clone, .linked => try std.fmt.allocPrint(a, "  rebase in progress in {s}; finish it or abort it (run: git -C {s} rebase --continue, or git -C {s} rebase --abort)\n", .{ ts, tq, tq }),
            .gone => blk: {
                try std.Io.Dir.cwd().deleteTree(io(), tree);
                const gq = try ui.quotePath(a, env, try std.fs.path.join(a, &.{ tree, ".git" }));
                break :blk try std.fmt.allocPrint(a, "  rebase in progress in {s}, which is gone; bring it back from its record, then finish it or abort it there (run: mkdir -p {s} && printf 'gitdir: %s\\n' {s} > {s} && git -C {s} checkout-index -a)\n", .{ ts, tq, try ui.quotePath(a, env, record), gq, tq });
            },
            .submodule => try std.fmt.allocPrint(a, "  bisect in progress in {s}; finish it or abort it (run: git -C {s} bisect reset)\n", .{ ts, tq }),
        };
        const got = try retireRun(&f);
        if (got.code != 1 or !has(got.out, line)) {
            std.debug.print("{s}: wanted {s} in:\n{s}\n", .{ @tagName(at), line, got.out });
            return error.TestUnexpectedResult;
        }
        const run_at = std.mem.indexOf(u8, line, "(run: ").? + "(run: ".len;
        const cmds = line[run_at .. line.len - ")\n".len];
        const cmd = if (std.mem.lastIndexOf(u8, cmds, ", or ")) |i| cmds[i + ", or ".len ..] else cmds;
        const settled = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", cmd }, null, &sb.git_env.map);
        if (settled.status != 0) {
            std.debug.print("{s}: hint failed: {s}\n{s}\n", .{ @tagName(at), cmd, settled.stderr });
            return error.TestUnexpectedResult;
        }
        var after = try retireRun(&f);
        if (at == .gone) {
            const there = try std.fmt.allocPrint(a, "  rebase in progress in {s}; finish it or abort it (run: git -C {s} rebase --continue, or git -C {s} rebase --abort)\n", .{ ts, tq, tq });
            if (!has(after.out, there)) {
                std.debug.print("gone: wanted {s} once it is back in:\n{s}\n", .{ there, after.out });
                return error.TestUnexpectedResult;
            }
            const aborted = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", try std.fmt.allocPrint(a, "git -C {s} rebase --abort", .{tq}) }, null, &sb.git_env.map);
            try std_testing.expectEqual(@as(u8, 0), aborted.status);
            after = try retireRun(&f);
        }
        if (has(after.out, " in progress in ")) {
            std.debug.print("{s}: not settled by {s}:\n{s}\n", .{ @tagName(at), cmd, after.out });
            return error.TestUnexpectedResult;
        }
    }
}

test "doctor --retire: a machine with no kept-file records is told there is nothing to retire, not to run --retire-machine" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 0), got.code);
    try std_testing.expect(std.mem.endsWith(u8, got.out, "This machine has no kept-file records: there is nothing to retire.\n"));
    try std_testing.expect(!has(got.out, "--retire-machine\n"));
}

test "doctor --retire and keep --retire-machine: dates are UTC dates, labelled so, whatever TZ, TZDIR, or /etc/localtime say" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const zones = try std.fs.path.join(a, &.{ sb.root, "zones" });
    try fsutil.ensureDir(zones);
    var tzif: std.ArrayList(u8) = .empty;
    try tzif.appendSlice(a, "TZif");
    try tzif.appendNTimes(a, 0, 16);
    for ([_]u32{ 0, 0, 0, 0, 1, 4 }) |n| try tzif.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, n)));
    try tzif.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(i32, 14 * 3600)));
    try tzif.appendSlice(a, &.{ 0, 0, '+', '1', '4', 0 });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ zones, "Far_East" }), .data = tzif.items });
    const base = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
        .{ "XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ sb.root, "config" }) },
    });
    defer base.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const paths_dir = try f.kctx.layout.reserved(a, "holt-test.invalid/acme/widget", ".holt-paths");
    var d = try std.Io.Dir.cwd().openDir(io(), paths_dir, .{ .iterate = true });
    defer d.close(io());
    var walker = try d.walk(a);
    defer walker.deinit();
    while (try walker.next(io())) |e| {
        if (e.kind != .file or !std.mem.eql(u8, e.basename, f.kctx.machine_id)) continue;
        try d.setTimestamps(io(), e.path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1790596800 * std.time.ns_per_s } } });
    }
    const keep_cmd = @import("keep.zig").command;
    const today = try kept.store.today(a);

    const zoned = [_][]const [2][]const u8{
        &.{.{ "TZ", "<+14>-14" }},
        &.{ .{ "TZ", "Far_East" }, .{ "TZDIR", zones } },
        &.{},
    };
    for (zoned) |pairs| {
        const scope = if (pairs.len == 0) try testutil.EnvScope.without(a, &.{ "TZ", "TZDIR" }) else try testutil.EnvScope.install(a, pairs);
        defer scope.restore();
        const retired = try f.run(keep_cmd.run, &.{"--retire-machine"});
        try std_testing.expectEqual(@as(u8, 0), retired.code);
        try std_testing.expect(has(retired.out, try std.fmt.allocPrint(a, " on {s} UTC: its records so far", .{today})));
        try std_testing.expectEqualStrings(today, (try kept.store.readRetired(a, f.kctx.layout, f.kctx.machine_id)).?.date);
        try std_testing.expect(has((try retireRun(&f)).out, try std.fmt.allocPrint(a, ", last record 2026-09-28 UTC, retired {s} UTC\n", .{today})));
    }
}

test "doctor --retire: a last record far in the future prints the last date there is" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try std_testing.expectEqualStrings("9999-12-31", try kept.store.utcDate(a, 1 << 41));
    try std_testing.expectEqualStrings("9999-12-31", try kept.store.utcDate(a, std.math.maxInt(i64)));
    try std_testing.expectEqualStrings("1970-01-01", try kept.store.utcDate(a, -1));
    const paths_dir = try f.kctx.layout.reserved(a, "holt-test.invalid/acme/widget", ".holt-paths");
    var d = try std.Io.Dir.cwd().openDir(io(), paths_dir, .{ .iterate = true });
    defer d.close(io());
    var walker = try d.walk(a);
    defer walker.deinit();
    const far: i96 = 253402300800 * std.time.ns_per_s;
    while (try walker.next(io())) |e| {
        if (e.kind != .file or !std.mem.eql(u8, e.basename, f.kctx.machine_id)) continue;
        d.setTimestamps(io(), e.path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = far } } }) catch return error.SkipZigTest;
    }
    const got = try retireRun(&f);
    try std_testing.expect(has(got.out, ", last record "));
}

test "doctor --retire: a branch the remote's push URL lacks passes when its fetch URL holds it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const pushed = try std.fs.path.join(a, &.{ f.bare, "pushed.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", pushed });
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", pushed });

    const got = try retireRun(&f);
    try std_testing.expect(!has(got.out, "commits of branch main"));
}

test "doctor --retire: a retirement date read from the store is shown printable, and a last record whose time cannot be told is unknown" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const index = try kept.store.loadIndex(a, f.kctx.layout);
    try kept.store.writeRetired(a, f.kctx.layout, &index, f.kctx.machine_id, "2026-01-0\x1b1", "host", f.kctx.machine_id);
    const paths_dir = try f.kctx.layout.reserved(a, "holt-test.invalid/acme/widget", ".holt-paths");
    var d = try std.Io.Dir.cwd().openDir(io(), paths_dir, .{ .iterate = true });
    defer d.close(io());
    var walker = try d.walk(a);
    defer walker.deinit();
    while (try walker.next(io())) |e| {
        if (e.kind != .file or !std.mem.eql(u8, e.basename, f.kctx.machine_id)) continue;
        d.setTimestamps(io(), e.path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = -86400 * std.time.ns_per_s } } }) catch return error.SkipZigTest;
    }

    const got = try retireRun(&f);
    try std_testing.expect(has(got.out, ", last record unknown, retired 2026-01-0\\x1b1 UTC"));
    try std_testing.expect(has(got.out, "This machine was retired on 2026-01-0\\x1b1 UTC"));
    try std_testing.expect(!has(got.out, "\x1b"));
}

test "keep --retire-machine: on a machine with no kept-file records it says there is nothing to retire" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    for ([_]bool{ true, false }) |with_store| {
        var inner = try testutil.Sandbox.init(std_testing.allocator);
        defer inner.deinit();
        const f = try Fixture.init(a, &inner, with_store);
        const got = try f.run(@import("keep.zig").command.run, &.{"--retire-machine"});
        try std_testing.expectEqual(@as(u8, 0), got.code);
        try std_testing.expectEqualStrings("this machine has no kept-file records: there is nothing to retire\n", got.out);
    }
}

/// The command the failing line of `out` naming `what` carries, with
/// `<url>` replaced by `url`, run as a shell does; fails when it does.
fn runLineHint(f: *const Fixture, out: []const u8, what: []const u8, url: []const u8) !void {
    const line = blk: {
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |l| if (has(l, what)) break :blk l;
        return error.TestUnexpectedResult;
    };
    const start = (std.mem.indexOf(u8, line, "(run: ") orelse return error.TestUnexpectedResult) + "(run: ".len;
    const tail = line[start..];
    const end = std.mem.indexOf(u8, tail, ", with <url> a URL on another machine)") orelse std.mem.lastIndexOfScalar(u8, tail, ')') orelse return error.TestUnexpectedResult;
    const cmd = try std.mem.replaceOwned(u8, f.a, tail[0..end], "<url>", url);
    const res = try @import("../proc.zig").runEnv(f.a, &.{ "sh", "-c", cmd }, null, &f.sb.git_env.map);
    if (res.status != 0) {
        std.debug.print("hint failed: {s}\n{s}\n", .{ cmd, res.stderr });
        return error.TestUnexpectedResult;
    }
}

test "doctor --retire: a remote that cannot be asked is named once, not again as refs that cannot be listed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io(), .{ .reuse_address = true });
    const port = server.socket.address.getPort();
    server.deinit(io());
    const previous_ports = deleter.loopback_elsewhere_for_test;
    deleter.loopback_elsewhere_for_test = &.{port};
    defer deleter.loopback_elsewhere_for_test = previous_ports;
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/acme/widget.git", .{port});
    try testutil.runGit(&sb, f.clone, &.{ "remote", "set-url", "origin", url });
    const global = try std.fs.path.join(a, &.{ sb.root, "global.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = global, .data = try std.fmt.allocPrint(a, "[remote \"backup\"]\n\turl = {s}\n", .{f.bare}) });
    const env = try testutil.EnvOverride.install(a, "GIT_CONFIG_GLOBAL", global);
    defer env.restore();

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    try std_testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, try std.fmt.allocPrint(a, "could not be asked at {s}: ", .{url})));
    try std_testing.expect(!has(got.out, "cannot be listed"));
}

test "doctor --retire: a branch whose upstream the first fetch URL lacks passes when another URL of the remote holds its commit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const empty = try std.fs.path.join(a, &.{ f.bare, "empty.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", empty });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--unset-all", "remote.origin.url" });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.url", empty });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.origin.url", f.bare });

    const got = try retireRun(&f);
    if (got.code != 0) std.debug.print("{s}\n", .{got.out});
    try std_testing.expectEqual(@as(u8, 0), got.code);
}

test "doctor --retire: a branch whose upstream the remote no longer has passes when the remote holds its commit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    try testutil.runGit(&sb, f.clone, &.{ "branch", "feature" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "-u", "origin", "feature" });
    try testutil.runGit(&sb, f.bare, &.{ "branch", "-D", "feature" });

    const got = try retireRun(&f);
    if (got.code != 0) std.debug.print("{s}\n", .{got.out});
    try std_testing.expectEqual(@as(u8, 0), got.code);
    try std_testing.expect(!has(got.out, "feature"));
}

test "doctor --retire: a remote on this machine gets one line, whose command settles it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const backup = try std.fs.path.join(a, &.{ sb.root, "backup.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", backup });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", backup });
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.backup.pushurl", backup });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, got.out, '\n');
    while (it.next()) |line| if (has(line, "remote backup ")) {
        n += 1;
    };
    try std_testing.expectEqual(@as(usize, 1), n);
    const what = try std.fmt.allocPrint(a, "remote backup is on this machine ({s}), so no other machine can restore from it: ", .{backup});
    const moved = try std.fs.path.join(a, &.{ f.bare, "moved.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", moved });
    try runLineHint(&f, got.out, what, moved);

    const clean = try retireRun(&f);
    if (clean.code != 0) std.debug.print("{s}\n", .{clean.out});
    try std_testing.expectEqual(@as(u8, 0), clean.code);
}

test "doctor --retire: a remote whose fetch or push URL is a repository on this machine fails, naming the remote, and the hinted commands settle it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const backup = try std.fs.path.join(a, &.{ sb.root, "backup.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", backup });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", backup });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "backup", "main" });
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.origin.pushurl", backup });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const shown = try fsutil.contractTilde(a, app.envOf_current(), f.clone);
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    const backup_line = try std.fmt.allocPrint(a, "remote backup is on this machine ({s}), so no other machine can restore from it: {s}; replace its URLs", .{ backup, shown });
    try expectFail(got.out, backup_line, try std.fmt.allocPrint(a, "git -C {s} config --local --fixed-value --unset-all remote.backup.url {s} && git -C {s} config --local remote.backup.url <url>", .{ cq, try ui.shellQuote(a, backup), cq }));
    const origin_line = try std.fmt.allocPrint(a, "remote origin has its push URLs on this machine ({s}), so no other machine can restore from it: {s}; replace its push URLs", .{ backup, shown });
    try expectFail(got.out, origin_line, try std.fmt.allocPrint(a, "git -C {s} config --local --fixed-value --unset-all remote.origin.pushurl {s})", .{ cq, try ui.shellQuote(a, backup) }));
    try std_testing.expect(!has(got.out, try std.fmt.allocPrint(a, "({s})", .{f.bare})));

    const moved = try std.fs.path.join(a, &.{ f.bare, "moved.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", moved });
    try runLineHint(&f, got.out, backup_line, moved);
    try runLineHint(&f, got.out, origin_line, moved);
    const clean = try retireRun(&f);
    if (clean.code != 0) std.debug.print("{s}\n", .{clean.out});
    try std_testing.expectEqual(@as(u8, 0), clean.code);
}

test "doctor --retire: a remote an insteadOf rule rewrites to a repository on this machine is named on the no-target line, whose command gives the clone a push target" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const backup = try std.fs.path.join(a, &.{ sb.root, "backup.git" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", f.bare, backup });
    try testutil.runGit(&sb, f.clone, &.{ "config", try std.fmt.allocPrint(a, "url.{s}.insteadof", .{backup}), f.bare });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const what = try std.fmt.allocPrint(a, "no remote counts as a copy: remote origin is on this machine ({s}); add a remote on another machine", .{backup});
    try expectFail(got.out, what, "remote add holt-kept <url>");
    try std_testing.expect(!has(got.out, "rewritten"));
    const far = try std.fs.path.join(a, &.{ sb.root, "far" });
    try f.write(far, testutil.elsewhere_mark, "");
    const moved = try std.fs.path.join(a, &.{ far, "moved.git" });
    try testutil.runGit(&sb, null, &.{ "init", "-q", "--bare", moved });
    try runLineHint(&f, got.out, what, moved);

    const after = try retireRun(&f);
    try std_testing.expect(!has(after.out, "no remote counts as a copy"));
    try expectFail(after.out, "commits of branch main no remote has", "push --recurse-submodules=no -- holt-kept refs/heads/main:refs/heads/holt-kept/main");
}

test "doctor --retire: a remote with one URL on this machine among others is no remote on this machine" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    try f.write(f.clone, ".env.kept", "kept secret");
    try f.keep(f.clone, ".env.kept");
    const backup = try std.fs.path.join(a, &.{ sb.root, "backup.git" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", f.bare, backup });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", f.bare });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.backup.url", backup });

    const got = try retireRun(&f);
    if (got.code != 0) std.debug.print("{s}\n", .{got.out});
    try std_testing.expectEqual(@as(u8, 0), got.code);
    try std_testing.expect(!has(got.out, "remote backup"));
}

test "doctor --retire: a remote whose every URL is on this machine is named once, with one command replacing them, which settles it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const one = try std.fs.path.join(a, &.{ sb.root, "one.git" });
    const two = try std.fs.path.join(a, &.{ sb.root, "two.git" });
    for ([_][]const u8{ one, two }) |p| try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", f.bare, p });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", one });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--add", "remote.backup.url", two });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const what = try std.fmt.allocPrint(a, "remote backup is on this machine ({s}, {s}), so no other machine can restore from it: ", .{ one, two });
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try expectFail(got.out, what, try std.fmt.allocPrint(a, "git -C {s} config --local --fixed-value --unset-all remote.backup.url {s} && git -C {s} config --local --fixed-value --unset-all remote.backup.url {s} && git -C {s} config --local remote.backup.url <url>", .{ cq, try ui.shellQuote(a, one), cq, try ui.shellQuote(a, two), cq }));
    try std_testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, "remote backup "));
    try runLineHint(&f, got.out, what, f.bare);

    const after = try retireRun(&f);
    try std_testing.expect(!has(after.out, "remote backup"));
    const left = try git.runInRepoScoped(a, &.{ "config", "--get-all", "remote.backup.url" }, f.clone);
    try std_testing.expectEqualStrings(f.bare, std.mem.trim(u8, left.stdout, "\n"));
}

test "doctor --retire: a remote whose fetch URL is on this machine is never asked, and fails as on this machine, as the deleters judge it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const backup = try std.fs.path.join(a, &.{ sb.root, "backup.git" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", f.bare, backup });
    try testutil.runGit(&sb, backup, &.{ "branch", "-m", "main", "other" });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", backup });
    try testutil.runGit(&sb, f.clone, &.{ "fetch", "-q", "backup" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    try expectFail(got.out, try std.fmt.allocPrint(a, "remote backup is on this machine ({s}), so no other machine can restore from it: ", .{backup}), "remote.backup.url <url>");
    try expectFail(got.out, "commits of branch main no remote has", "push --recurse-submodules=no -- origin refs/heads/main:");
}

test "doctor --retire: a remote value in the system configuration carries the administrator note on the command replacing it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const one = try std.fs.path.join(a, &.{ sb.root, "one.git" });
    const two = try std.fs.path.join(a, &.{ sb.root, "two.git" });
    for ([_][]const u8{ one, two }) |p| try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", f.bare, p });
    const system = try std.fs.path.join(a, &.{ sb.root, "system.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = system, .data = try std.fmt.allocPrint(a, "[remote \"backup\"]\n\turl = {s}\n", .{one}) });
    const nosystem = try testutil.EnvOverride.install(a, "GIT_CONFIG_NOSYSTEM", null);
    defer nosystem.restore();
    const env = try testutil.EnvOverride.install(a, "GIT_CONFIG_SYSTEM", system);
    defer env.restore();
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.backup.url", two });
    try testutil.runGit(&sb, f.clone, &.{ "config", "remote.backup.fetch", "+refs/heads/*:refs/remotes/backup/*" });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const sq = try ui.quotePath(a, app.envOf_current(), system);
    const what = try std.fmt.allocPrint(a, "remote backup is on this machine ({s}, {s}), so no other machine can restore from it: ", .{ one, two });
    try expectFail(got.out, what, try std.fmt.allocPrint(a, "git config --file {s} --fixed-value --unset-all remote.backup.url {s} && ", .{ sq, try ui.shellQuote(a, one) }));
    try std_testing.expect(has(got.out, try std.fmt.allocPrint(a, ", with <url> a URL on another machine) (in {s}, which changes every repository and may need an administrator to change, sudo)\n", .{try fsutil.contractTilde(a, app.envOf_current(), system)})));
    try runLineHint(&f, got.out, what, f.bare);
    const clean = try retireRun(&f);
    try std_testing.expect(!has(clean.out, "remote backup"));
}

test "doctor --retire: a remote whose URLs on this machine are set in config and config.worktree is hinted away from each file, which settles it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const one = try std.fs.path.join(a, &.{ sb.root, "one.git" });
    const two = try std.fs.path.join(a, &.{ sb.root, "two.git" });
    for ([_][]const u8{ one, two }) |p| try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", f.bare, p });
    try testutil.runGit(&sb, f.clone, &.{ "config", "extensions.worktreeConfig", "true" });
    try testutil.runGit(&sb, f.clone, &.{ "remote", "add", "backup", one });
    try testutil.runGit(&sb, f.clone, &.{ "config", "--worktree", "remote.backup.url", two });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const what = try std.fmt.allocPrint(a, "remote backup is on this machine ({s}, {s}), so no other machine can restore from it: ", .{ one, two });
    const cq = try ui.quotePath(a, app.envOf_current(), f.clone);
    try expectFail(got.out, what, try std.fmt.allocPrint(a, "git -C {s} config --local --fixed-value --unset-all remote.backup.url {s} && git -C {s} config --worktree --fixed-value --unset-all remote.backup.url {s} && git -C {s} config --local remote.backup.url <url>", .{ cq, try ui.shellQuote(a, one), cq, try ui.shellQuote(a, two), cq }));
    try runLineHint(&f, got.out, what, f.bare);

    const after = try retireRun(&f);
    try std_testing.expect(!has(after.out, "remote backup"));
    const left = try git.runInRepoScoped(a, &.{ "remote", "get-url", "--all", "backup" }, f.clone);
    try std_testing.expectEqualStrings(f.bare, std.mem.trim(u8, left.stdout, "\n"));
}

/// A closed loopback port: nothing listens on it, so a query is refused.
fn refusedPort() !u16 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io(), .{ .reuse_address = true });
    defer server.deinit(io());
    return server.socket.address.getPort();
}

test "doctor --retire: a URL that did not answer names its way out, a host skipped after it is named once with the clones it held back, and a note of other URLs prints beside such a line" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    for ([_][]const u8{ "widget", "gadget", "gizmo" }) |n| {
        const path = try fsutil.joinSlashy(a, f.ws.cfg.code_root, try std.fmt.allocPrint(a, "holt-test.invalid/acme/{s}", .{n}));
        if (!std.mem.eql(u8, n, "widget")) try testutil.runGit(&sb, null, &.{ "clone", "-q", f.bare, path });
        try testutil.runGit(&sb, path, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
        try testutil.runGit(&sb, path, &.{ "remote", "set-url", "origin", try std.fmt.allocPrint(a, "ssh://127.0.0.1/acme/{s}.git", .{n}) });
    }
    const script = try std.fs.path.join(a, &.{ sb.root, "lost-ssh" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = script, .data = "#!/bin/sh\necho 'ssh: Could not resolve hostname 127.0.0.1: nodename nor servname provided, or not known' >&2\nexit 255\n" });
    try std.Io.Dir.cwd().setFilePermissions(io(), script, .fromMode(0o755), .{});
    const ssh = try testutil.EnvOverride.install(a, "GIT_SSH_COMMAND", script);
    defer ssh.restore();
    const target_port = try refusedPort();
    const other_port = try refusedPort();
    const previous_ports = deleter.loopback_elsewhere_for_test;
    deleter.loopback_elsewhere_for_test = &.{ 22, target_port, other_port };
    defer deleter.loopback_elsewhere_for_test = previous_ports;
    const noted = try fsutil.joinSlashy(a, f.ws.cfg.code_root, "holt-test.invalid/acme/noted");
    try testutil.runGit(&sb, null, &.{ "clone", "-q", f.bare, noted });
    try testutil.runGit(&sb, noted, &.{ "commit", "-q", "--allow-empty", "-m", "only here" });
    const target = try std.fmt.allocPrint(a, "git://localhost:{d}/acme/noted.git", .{target_port});
    const other = try std.fmt.allocPrint(a, "git://localhost:{d}/acme/mirror.git", .{other_port});
    try testutil.runGit(&sb, noted, &.{ "remote", "set-url", "origin", target });
    try testutil.runGit(&sb, noted, &.{ "remote", "add", "mirror", other });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    try std_testing.expect(!has(got.out, ": not asked: "));
    try std_testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, ": host not found); reconnect and run again\n"));
    try std_testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, "  127.0.0.1 did not answer, so 2 clones were not asked: "));
    try std_testing.expect(has(got.out, try std.fmt.allocPrint(a, "(remote origin could not be asked at {s}: connection refused); reconnect and run again\n", .{target})));
    try std_testing.expect(has(got.out, try std.fmt.allocPrint(a, "  could not be asked, in {s}: remote mirror at {s} (connection refused)\n", .{ try fsutil.contractTilde(a, app.envOf_current(), try fsutil.realPathOrSelf(a, noted)), other })));
}

test "doctor --retire: an operation in progress in a submodule git directory whose working tree is gone is named with the command bringing that tree back, and one in a git directory that names no working tree with the delete alone, never with git --work-tree at the git directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const env = app.envOf_current();
    const remote_owned = try testutil.makeBareRepo(&sb, "sub.git");
    defer sb.alloc.free(remote_owned);
    try testutil.runGit(&sb, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "sub" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "add sub" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });
    const sub = try f.path("sub");
    const modgit = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }));
    const proc_mod = @import("../proc.zig");
    const sh = struct {
        fn run(al: std.mem.Allocator, s: *testutil.Sandbox, cmd: []const u8) !void {
            const res = try proc_mod.runEnv(al, &.{ "sh", "-c", cmd }, null, &s.git_env.map);
            if (res.status != 0) {
                std.debug.print("failed: {s}\n{s}\n", .{ cmd, res.stderr });
                return error.TestUnexpectedResult;
            }
        }
    }.run;
    const sq = try ui.quotePath(a, env, sub);
    const mq = try ui.quotePath(a, env, modgit);
    try sh(a, &sb, try std.fmt.allocPrint(a, "git -C {s} bisect start && rm -rf {s}", .{ sq, sq }));

    const gone = try retireRun(&f);
    const back = try std.fmt.allocPrint(a, "  bisect in progress in {s}, which is gone; bring it back from its git directory, then finish it or abort it there (run: mkdir -p {s} && printf 'gitdir: %s\\n' {s} > {s} && git -C {s} checkout-index -a)\n", .{ try fsutil.contractTilde(a, env, sub), sq, mq, try ui.quotePath(a, env, try std.fs.path.join(a, &.{ sub, ".git" })), sq });
    if (!has(gone.out, back) or has(gone.out, "--work-tree")) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ back, gone.out });
        return error.TestUnexpectedResult;
    }
    try sh(a, &sb, back[std.mem.indexOf(u8, back, "(run: ").? + "(run: ".len .. back.len - ")\n".len]);
    const there = try retireRun(&f);
    const reset = try std.fmt.allocPrint(a, "  bisect in progress in {s}; finish it or abort it (run: git -C {s} bisect reset)\n", .{ try fsutil.contractTilde(a, env, sub), sq });
    if (!has(there.out, reset)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ reset, there.out });
        return error.TestUnexpectedResult;
    }
    try sh(a, &sb, try std.fmt.allocPrint(a, "git -C {s} bisect reset", .{sq}));
    try std_testing.expect(!has((try retireRun(&f)).out, " in progress in "));

    try sh(a, &sb, try std.fmt.allocPrint(a, "git -C {s} bisect start && git --git-dir {s} config --unset core.worktree && rm -rf {s}", .{ sq, mq, sq }));
    const none = try retireRun(&f);
    const deleted = try std.fmt.allocPrint(a, "  bisect in progress in {s}, a submodule git directory with no working tree, where git can neither finish nor abort it; holt repo remove holt-test.invalid/acme/widget --clone --force deletes it\n", .{try fsutil.contractTilde(a, env, modgit)});
    if (!has(none.out, deleted) or has(none.out, "--work-tree")) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ deleted, none.out });
        return error.TestUnexpectedResult;
    }
}

test "doctor --retire and repo remove --clone: an operation in progress in a submodule git directory whose core.worktree names a file or a symlink to nothing is named with what is seen there and the git reading that core.worktree, which runs, and the delete is refused, with --force too, naming no command bringing it back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |dangling| {
        var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(std_testing.allocator);
        defer sb.deinit();
        const state = try retireEnv(a, &sb);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const env = app.envOf_current();
        const remote_owned = try testutil.makeBareRepo(&sb, "sub.git");
        defer sb.alloc.free(remote_owned);
        try testutil.runGit(&sb, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "sub" });
        try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "add sub" });
        try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });
        const sub = try f.path("sub");
        const modgit = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }));
        const sq = try ui.quotePath(a, env, sub);
        const mq = try ui.quotePath(a, env, modgit);
        const put = if (dangling) try std.fmt.allocPrint(a, "ln -s {s} {s}", .{ try ui.quotePath(a, env, try std.fs.path.join(a, &.{ sb.root, "no-such-dir" })), sq }) else try std.fmt.allocPrint(a, "echo x > {s}", .{sq});
        const setup = try std.fmt.allocPrint(a, "git -C {s} bisect start && rm -rf {s} && {s}", .{ sq, sq, put });
        const res = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", setup }, null, &sb.git_env.map);
        try std_testing.expectEqual(@as(u8, 0), res.status);
        const seen = if (dangling) "a symlink to nothing" else "which is not a directory";
        const cq = try ui.quotePath(a, env, try std.fs.path.join(a, &.{ modgit, "config" }));
        const line = try std.fmt.allocPrint(a, "{s}: a submodule git directory with a bisect in progress, whose core.worktree names {s}, {s}; holt does not change it: resolve it with git (git config --file {s} core.worktree), then run again", .{ mq, try fsutil.contractTilde(a, env, sub), seen, cq });

        const got = try retireRun(&f);
        try std_testing.expectEqual(@as(u8, 1), got.code);
        if (!has(got.out, try std.fmt.allocPrint(a, "  {s}\n", .{line})) or has(got.out, "mkdir")) {
            std.debug.print("wanted {s} in:\n{s}\n", .{ line, got.out });
            return error.TestUnexpectedResult;
        }
        const shown = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", try std.fmt.allocPrint(a, "git config --file {s} core.worktree", .{cq}) }, null, &sb.git_env.map);
        try std_testing.expectEqual(@as(u8, 0), shown.status);
        try std_testing.expectEqualStrings(sub, try fsutil.realPathOrSelf(a, try std.fs.path.resolve(a, &.{ modgit, std.mem.trimEnd(u8, shown.stdout, "\n") })));

        for ([_]bool{ false, true }) |force| {
            const argv: []const []const u8 = if (force) &.{ "holt-test.invalid/acme/widget", "--clone", "--yes", "--force" } else &.{ "holt-test.invalid/acme/widget", "--clone", "--yes" };
            const removed = try f.run(@import("repo.zig").remove_command.run, argv);
            if (removed.code != 1 or !has(removed.err, line) or has(removed.err, "mkdir") or has(removed.out, "deleting")) {
                std.debug.print("wanted the refusal {s}, got {d}:\n{s}{s}\n", .{ line, removed.code, removed.out, removed.err });
                return error.TestUnexpectedResult;
            }
            try std_testing.expect(fsutil.exists(try std.fs.path.join(a, &.{ modgit, "BISECT_LOG" })));
        }
    }
}

test "doctor --retire and repo remove --clone: an operation in progress in a submodule git directory whose core.worktree names a path under a file is named with what is seen there and the git reading that core.worktree, and the delete is refused, with --force too, naming no mkdir; once the file is moved away, the line names bringing it back, which runs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const env = app.envOf_current();
    const remote_owned = try testutil.makeBareRepo(&sb, "sub.git");
    defer sb.alloc.free(remote_owned);
    try testutil.runGit(&sb, f.clone, &.{ "-c", "protocol.file.allow=always", "submodule", "add", "-q", remote_owned, "sub" });
    try testutil.runGit(&sb, f.clone, &.{ "commit", "-q", "-m", "add sub" });
    try testutil.runGit(&sb, f.clone, &.{ "push", "-q", "origin", "HEAD" });
    const sub = try f.path("sub");
    const modgit = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "modules", "sub" }));
    const blk = try std.fs.path.join(a, &.{ sb.root, "blk" });
    const tree = try std.fs.path.join(a, &.{ blk, "sub" });
    const cq = try ui.quotePath(a, env, try std.fs.path.join(a, &.{ modgit, "config" }));
    const setup = try std.fmt.allocPrint(a, "git -C {s} bisect start && rm -rf {s} && git config --file {s} core.worktree {s} && echo x > {s}", .{ try ui.quotePath(a, env, sub), try ui.quotePath(a, env, sub), cq, try ui.quotePath(a, env, tree), try ui.quotePath(a, env, blk) });
    const res = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", setup }, null, &sb.git_env.map);
    try std_testing.expectEqual(@as(u8, 0), res.status);
    const line = try std.fmt.allocPrint(a, "{s}: a submodule git directory with a bisect in progress, whose core.worktree names {s}, which lies under something that is not a directory; holt does not change it: resolve it with git (git config --file {s} core.worktree), then run again", .{ try ui.quotePath(a, env, modgit), try fsutil.contractTilde(a, env, tree), cq });

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    if (!has(got.out, try std.fmt.allocPrint(a, "  {s}\n", .{line})) or has(got.out, "mkdir")) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ line, got.out });
        return error.TestUnexpectedResult;
    }
    const shown = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", try std.fmt.allocPrint(a, "git config --file {s} core.worktree", .{cq}) }, null, &sb.git_env.map);
    try std_testing.expectEqual(@as(u8, 0), shown.status);
    try std_testing.expectEqualStrings(tree, std.mem.trimEnd(u8, shown.stdout, "\n"));
    for ([_]bool{ false, true }) |force| {
        const argv: []const []const u8 = if (force) &.{ "holt-test.invalid/acme/widget", "--clone", "--yes", "--force" } else &.{ "holt-test.invalid/acme/widget", "--clone", "--yes" };
        const removed = try f.run(@import("repo.zig").remove_command.run, argv);
        if (removed.code != 1 or !has(removed.err, line) or has(removed.err, "mkdir") or has(removed.out, "deleting")) {
            std.debug.print("wanted the refusal {s}, got {d}:\n{s}{s}\n", .{ line, removed.code, removed.out, removed.err });
            return error.TestUnexpectedResult;
        }
        try std_testing.expect(fsutil.exists(try std.fs.path.join(a, &.{ modgit, "BISECT_LOG" })));
    }

    try fsutil.removePath(blk);
    const gone = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), gone.code);
    const lead = "bring it back from its git directory, then finish it or abort it there (run: ";
    const at = std.mem.indexOf(u8, gone.out, lead) orelse {
        std.debug.print("wanted the line bringing it back in:\n{s}\n", .{gone.out});
        return error.TestUnexpectedResult;
    };
    const rest = gone.out[at + lead.len ..];
    const cmd = rest[0 .. std.mem.indexOf(u8, rest, ")\n") orelse return error.TestUnexpectedResult];
    const back = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", cmd }, null, &sb.git_env.map);
    if (back.status != 0) {
        std.debug.print("{s} failed:\n{s}\n", .{ cmd, back.stderr });
        return error.TestUnexpectedResult;
    }
    const status = try @import("../proc.zig").runEnv(a, &.{ "git", "-C", tree, "bisect", "reset" }, null, &sb.git_env.map);
    if (status.status != 0) {
        std.debug.print("git bisect reset in {s} failed:\n{s}\n", .{ tree, status.stderr });
        return error.TestUnexpectedResult;
    }
    try std_testing.expect(!fsutil.exists(try std.fs.path.join(a, &.{ modgit, "BISECT_LOG" })));
}

test "doctor --retire: a worktree that is gone is named once, as a working tree git cannot list, and never again as an unsettled kept file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const tree = try std.fs.path.join(a, &.{ sb.root, "linked" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", tree });
    try std.Io.Dir.cwd().deleteTree(io(), tree);

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const ts = try fsutil.contractTilde(a, app.envOf_current(), tree);
    if (std.mem.count(u8, got.out, try std.fmt.allocPrint(a, "working tree git cannot list: {s}: ", .{ts})) != 1 or has(got.out, "unsettled kept file: ")) {
        std.debug.print("wanted one line naming {s} in:\n{s}\n", .{ ts, got.out });
        return error.TestUnexpectedResult;
    }
}

test "doctor --retire: staged changes only the record of a worktree that is gone holds fail, with the lines the deleters give, whose commands settle them and leave another worktree's record as it was" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const env = app.envOf_current();
    const tree = try std.fs.path.join(a, &.{ sb.root, "linked" });
    const also = try std.fs.path.join(a, &.{ sb.root, "also" });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", tree });
    try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", also });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ tree, "staged.txt" }), .data = "staged" });
    try testutil.runGit(&sb, tree, &.{ "add", "staged.txt" });
    const record = std.mem.trim(u8, (try git.runInRepo(a, &.{ "rev-parse", "--absolute-git-dir" }, tree)).stdout, " \r\n");
    const also_gitdir = try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees", "also", "gitdir" });
    const also_before = try kept.content.readSmall(a, also_gitdir);
    try std.Io.Dir.cwd().deleteTree(io(), tree);
    try std.Io.Dir.cwd().deleteTree(io(), also);

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const ts = try fsutil.contractTilde(a, env, tree);
    const tq = try ui.quotePath(a, env, tree);
    const back = try std.fmt.allocPrint(a, "  {s}: its directory is gone; bring it back from its record first (run: mkdir -p {s} && printf 'gitdir: %s\\n' {s} > {s} && git -C {s} checkout-index -a)\n", .{ ts, tq, try ui.quotePath(a, env, record), try ui.quotePath(a, env, try std.fs.path.join(a, &.{ tree, ".git" })), tq });
    const staged = try std.fmt.allocPrint(a, "  {s}: staged changes only {s}'s record holds; commit or stash them there (run: git -C {s} stash push)\n", .{ ts, ts, tq });
    for ([_][]const u8{ back, staged }) |line| if (!has(got.out, line)) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ line, got.out });
        return error.TestUnexpectedResult;
    };
    try std_testing.expect(!has(got.out, "worktree repair") and !has(got.out, "worktree prune"));
    for ([_][]const u8{ back, staged }) |line| {
        const cmd = line[std.mem.indexOf(u8, line, "(run: ").? + "(run: ".len .. line.len - ")\n".len];
        const res = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", cmd }, null, &sb.git_env.map);
        if (res.status != 0) {
            std.debug.print("hint failed: {s}\n{s}\n", .{ cmd, res.stderr });
            return error.TestUnexpectedResult;
        }
    }
    const after = try retireRun(&f);
    if (has(after.out, try std.fmt.allocPrint(a, "  {s}", .{ts}))) {
        std.debug.print("not settled:\n{s}\n", .{after.out});
        return error.TestUnexpectedResult;
    }
    try std_testing.expectEqualStrings(also_before, try kept.content.readSmall(a, also_gitdir));
}

test "doctor --retire: a worktree whose .git is gone holding staged changes, and a path two records name, are each named once with what is seen there and git worktree list alone, never a stash or a record's removal, and left as they were" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(std_testing.allocator);
    defer sb.deinit();
    const state = try retireEnv(a, &sb);
    defer state.restore();
    const f = try Fixture.init(a, &sb, true);
    const env = app.envOf_current();
    const unlinked = try std.fs.path.join(a, &.{ sb.root, "unlinked" });
    const shared = try std.fs.path.join(a, &.{ sb.root, "shared" });
    for ([_][]const u8{ unlinked, shared }) |t| try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", t });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ unlinked, "staged.txt" }), .data = "staged" });
    try testutil.runGit(&sb, unlinked, &.{ "add", "staged.txt" });
    try fsutil.removePath(try std.fs.path.join(a, &.{ unlinked, ".git" }));
    const records = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees" }));
    const cp = try @import("../proc.zig").runEnv(a, &.{ "cp", "-R", try std.fs.path.join(a, &.{ records, "shared" }), try std.fs.path.join(a, &.{ records, "z-copy" }) }, null, &sb.git_env.map);
    try std_testing.expectEqual(@as(u8, 0), cp.status);
    const before = try kept_hooks.snapshot(a, records, null);

    const got = try retireRun(&f);
    try std_testing.expectEqual(@as(u8, 1), got.code);
    const git_in = try std.fmt.allocPrint(a, "git -C {s}", .{try ui.quotePath(a, env, f.clone)});
    for ([_][2][]const u8{ .{ unlinked, "a linked working tree whose .git is gone" }, .{ shared, deleter.shared_seen } }) |c| {
        const line = try std.fmt.allocPrint(a, "{s}: {s}; holt does not change it: resolve it with git ({s} worktree list), then run again", .{ try ui.quotePath(a, env, c[0]), c[1], git_in });
        if (std.mem.count(u8, got.out, line) != 1) {
            std.debug.print("wanted {s} once in:\n{s}\n", .{ line, got.out });
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "stash push", "rm -rf", "printf", "worktree repair", "worktree prune", "staged changes only " }) |cmd| try std_testing.expect(!has(got.out, cmd));
    const res = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", try std.fmt.allocPrint(a, "{s} worktree list", .{git_in}) }, null, &sb.git_env.map);
    try std_testing.expectEqual(@as(u32, 0), res.status);
    try std_testing.expectEqualStrings(before, try kept_hooks.snapshot(a, records, null));
}

test "doctor --retire: a worktree record git does not list, holding no gitdir or an unreadable one, fails with what is seen there and the record's path, which is there, and is left as it was" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |gitdir_dir| {
        var arena_state = std.heap.ArenaAllocator.init(std_testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(std_testing.allocator);
        defer sb.deinit();
        const state = try retireEnv(a, &sb);
        defer state.restore();
        const f = try Fixture.init(a, &sb, true);
        const env = app.envOf_current();
        const tree = try std.fs.path.join(a, &.{ sb.root, "linked" });
        try testutil.runGit(&sb, f.clone, &.{ "worktree", "add", "-q", "--detach", tree });
        const record = try std.fs.path.join(a, &.{ f.clone, ".git", "worktrees", "linked" });
        const gitdir = try std.fs.path.join(a, &.{ record, "gitdir" });
        try fsutil.removePath(gitdir);
        if (gitdir_dir) try std.Io.Dir.cwd().createDirPath(io(), gitdir);
        const head = try kept.content.readSmall(a, try std.fs.path.join(a, &.{ record, "HEAD" }));

        const got = try retireRun(&f);
        try std_testing.expectEqual(@as(u8, 1), got.code);
        const seen = if (gitdir_dir) deleter.record_unreadable_seen else deleter.half_made_seen;
        const rq = try ui.quotePath(a, env, record);
        const line = try std.fmt.allocPrint(a, "  {s}: {s}; holt does not change it: resolve it with git (the record is {s}), then run again\n", .{ rq, seen, rq });
        if (!has(got.out, line) and !has(got.out, try std.fmt.allocPrint(a, "  working tree git cannot list: {s}", .{line[2..]}))) {
            std.debug.print("wanted {s} in:\n{s}\n", .{ line, got.out });
            return error.TestUnexpectedResult;
        }
        try std_testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, seen));
        const res = try @import("../proc.zig").runEnv(a, &.{ "sh", "-c", try std.fmt.allocPrint(a, "ls -d {s}", .{rq}) }, null, &sb.git_env.map);
        try std_testing.expectEqual(@as(u8, 0), res.status);
        try std_testing.expectEqualStrings(head, try kept.content.readSmall(a, try std.fs.path.join(a, &.{ record, "HEAD" })));
        try std_testing.expectEqual(gitdir_dir, fsutil.exists(gitdir));
    }
}
