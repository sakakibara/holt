//! `holt worktree <project>/<repo> [<branch>] [--remove [--force]]`: manage a
//! repo's git worktrees. A worktree is an extra checkout that shares the
//! repo's one canonical clone - never a second clone. Worktrees live in a
//! sibling `<clone>@worktrees/` dir and surface in the hub as
//! `code/<repo>@worktrees`, so a project opened at its hub root can reach
//! every branch's checkout. Removing one runs the kept-file steps every
//! deleter runs (`deleter`).

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("../app.zig");
const path = @import("path.zig");
const git = @import("../git.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const kept = @import("../kept.zig");
const diagnostic = @import("../diag.zig");
const workspace = @import("../workspace.zig");
const identity = @import("../identity.zig");
const kept_hooks = @import("kept_hooks.zig");
const deleter = @import("deleter.zig");
const keep_cmd = @import("keep.zig");
const ui = @import("../ui.zig");
const quotePath = @import("kept_util.zig").q;
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    repo: cli.Pos([]const u8, .{ .complete = app.cat(.project_repo), .help = "the <project>/<repo> whose worktrees to manage" }),
    branch: cli.Pos([]const u8, .{ .value_name = "branch", .complete = app.cat(.worktree_branch), .optional = true, .help = "branch to check out in a new worktree; omit to list" }),
    remove: cli.Flag(.{ .short = 'r', .help = "remove the worktree for <branch> instead of creating it" }),
    force: cli.Flag(.{ .short = 'f', .help = "with --remove: remove it even when dirty or holding files holt does not keep (those are set aside first)" }),
};

pub const command = app.command(Spec, .{
    .name = "worktree",
    .summary = "Create, list, or remove a repo's git worktrees",
    .usage = "holt worktree <project>/<repo> [<branch>] [--remove [--force]]",
    .group = .navigate,
    .needs_context = true,
    .details =
    \\A worktree is an extra checkout of a repo's one canonical clone, on a
    \\different branch, so two branches can be checked out at once without a
    \\second clone. It appears in the hub as `code/<repo>@worktrees/<branch>`,
    \\and a new one gets links to the repo's kept files.
    \\
    \\--remove refuses, even with --force, a path no worktree record of the
    \\clone names, as not a working tree of it, before it names or sets
    \\anything aside. It also refuses, even with --force, before anything is
    \\weighed, set aside, or written, a worktree in a state holt does not
    \\change: a path more than one record names, as a copied record leaves,
    \\where git worktree remove may reach any of them; a directory whose
    \\.git is gone, does not read as a link, names a git directory that is
    \\not there, or leads to another git directory than its record, as
    \\another repository's working tree at its path does; and a path that
    \\holds something that is not a directory, is a symlink to nothing,
    \\lies under something that is not a directory, or cannot be read.
    \\Each is named with what git and holt see there and git -C <clone>
    \\worktree list, to be resolved with git before running it again; holt
    \\names no command writing a .git or a record, or removing a record, for
    \\it. It looks for these states again once the worktree is weighed,
    \\before anything is set aside. It refuses a locked
    \\worktree, and one with uncommitted changes, commits only its HEAD or
    \\its per-worktree refs hold (hinting a
    \\holt-kept/ branch or ref that survives the removal), a merge, rebase,
    \\am, cherry-pick, revert, or bisect in progress (hinting the commands
    \\finishing or aborting it), files holt does not keep, nested
    \\repositories, unsettled kept files, or submodule commits and stashes no
    \\remote has, naming the command that settles each; on a terminal, without
    \\--force, it first offers holt keep --review inline. For a worktree
    \\whose directory is gone, it weighs through its record alone, as holt
    \\repo remove --clone weighs it, under the clone's lock, its HEAD,
    \\per-worktree refs, operations in progress, staged changes only the
    \\record's index holds, and each submodule git directory under the
    \\record's modules/ with its refs, HEAD, and operations in progress,
    \\and keeps the record if any of them changed before its removal; one
    \\holding an operation in progress or staged changes is named first
    \\with the mkdir, printf, and git checkout-index bringing it back from
    \\its record (New-Item and Set-Content on Windows). It never runs or
    \\names git worktree repair or prune, which reach every worktree of the
    \\clone. A remote holds only what its URLs on another machine list now,
    \\as holt repo remove --help says; no remote is asked when the refs that
    \\survive the removal hold everything it weighs.
    \\--force removes it anyway, passing --force to git worktree remove:
    \\files holt does not keep, uncommitted changes (a symlink by its
    \\target), and unsettled content are still set aside in kept/ first;
    \\nested repositories, commits no remote has, operations in progress,
    \\with the autostash one holds, and staged changes only a gone
    \\worktree's record holds are deleted, each named.
    \\Nothing is removed if setting aside fails. A refusal after something
    \\was set aside, or holt's links were recorded and removed, says the
    \\worktree was kept and names each, with where kept/.holt-aside/ holds
    \\it. Reflogs are not weighed: commits only the record's own reflogs
    \\name are deleted with it.
    \\
    \\Examples:
    \\  holt worktree acme/backend feature-x      # create; prints its path
    \\  holt worktree acme/backend                # list
    \\  holt worktree acme/backend feature-x -r   # remove
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const slash = std.mem.lastIndexOfScalar(u8, a.repo, '/') orelse {
        return app.usageError(ctx, "worktree takes <project>/<repo>", .{});
    };
    const project_query = a.repo[0..slash];
    const repo_query = a.repo[slash + 1 ..];
    if (project_query.len == 0 or repo_query.len == 0) {
        return app.usageError(ctx, "worktree takes <project>/<repo>", .{});
    }
    if (a.branch) |b| {
        if (fsutil.SafeRel.parse(b) == null) {
            return app.usageError(ctx, "invalid branch name \"{s}\"", .{b});
        }
    }

    const id = (try path.resolveRepoId(ctx, ws, project_query, repo_query)) orelse return 1;
    const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
    if (!fsutil.exists(clone_path)) {
        try ctx.err.print("holt: {s} is not cloned yet; run `holt restore` first\n", .{a.repo});
        return 1;
    }
    const worktrees_dir = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{clone_path});

    if (a.force and !a.remove) {
        return app.usageError(ctx, "--force only applies to --remove", .{});
    }
    if (a.branch == null) {
        if (a.remove) {
            return app.usageError(ctx, "--remove needs a <branch>", .{});
        }
        const listing = git.worktreeList(alloc, clone_path) catch {
            try ctx.err.print("holt: could not list worktrees for {s}\n", .{try app.tilde(ctx, clone_path)});
            return 1;
        };
        defer alloc.free(listing);
        try ctx.out.writeAll(listing);
        return 0;
    }

    const branch = a.branch.?;
    const wt_path = try fsutil.joinSlashy(alloc, worktrees_dir, branch);

    if (a.remove) {
        const named = try soleRecord(ctx, clone_path, wt_path) orelse return 1;
        const locked = git.worktreeLocked(alloc, clone_path, wt_path) catch {
            try ctx.err.print("holt: cannot tell whether {s} is locked; refusing to remove (run: git -C {s} worktree list --porcelain)\n", .{ try quotePath(ctx, wt_path), try quotePath(ctx, clone_path) });
            return 1;
        };
        if (locked) {
            try ctx.err.print("holt: {s} is locked; refusing to remove (run: git -C {s} worktree unlock {s})\n", .{ try quotePath(ctx, wt_path), try quotePath(ctx, clone_path), try quotePath(ctx, wt_path) });
            return 1;
        }
        const force_cmd = try std.fmt.allocPrint(alloc, "holt worktree {s} {s} -r --force", .{ try ui.shellQuote(alloc, a.repo), try ui.shellQuote(alloc, branch) });
        var gone: ?Gone = null;
        defer if (gone) |g| g.lock.release();
        if (named.link == .absent) gone = (try weighGone(ctx, clone_path, wt_path, force_cmd, a.force)) orelse return 1;
        var prepared = switch (try deleter.prepare(ctx, wt_path, .worktree, .{ .review = keep_cmd.reviewHeld, .interactive = !a.force and ui.stdinIsTerminal() })) {
            .refused => |why| {
                try ctx.err.print("holt: {s}: {s}; refusing to remove\n", .{ try quotePath(ctx, wt_path), why });
                return 1;
            },
            .ready => |p| p,
        };
        defer prepared.release();
        if (!a.force) {
            if (prepared.found.blocked()) {
                try prepared.printBlocked(ctx, force_cmd);
                return 1;
            }
            // Checked before anything is unlinked, so a refusal git would
            // make leaves the worktree as it was.
            if (fsutil.exists(wt_path) and try git.isDirty(alloc, wt_path)) {
                try ctx.err.print("holt: {s} has uncommitted changes (run: git -C {s} stash push -u, or: {s})\n", .{ try quotePath(ctx, wt_path), try quotePath(ctx, wt_path), force_cmd });
                return 1;
            }
        }
        // git worktree remove may reach any record naming the path, so the
        // path is found again as it was weighed, before anything is set
        // aside.
        if (builtin.is_test) if (before_recheck_for_test) |seam| seam();
        const again = try soleRecord(ctx, clone_path, wt_path) orelse return 1;
        if (!std.mem.eql(u8, again.rec.record, named.rec.record) or again.link != named.link) {
            try ctx.err.writeAll(try deleter.recordChangedLine(ctx, wt_path, try prepared.asideNote(ctx)));
            return 1;
        }
        switch (try prepared.clear(ctx, a.force, .reuse)) {
            .done => {},
            .blocked => {
                try prepared.printBlocked(ctx, force_cmd);
                return 1;
            },
            .failed => return 1,
        }
        if (!try prepared.unchanged(ctx, a.force)) {
            try ctx.err.print("holt: {s}; run the command again\n", .{try prepared.changedWhy(ctx, "the worktree")});
            return 1;
        }
        if (gone) |g| if (!a.force) {
            if (!try deleter.recordUnchanged(alloc, g.record, wt_path, g.state)) {
                try ctx.err.writeAll(try deleter.recordChangedLine(ctx, wt_path, try prepared.asideNote(ctx)));
                return 1;
            }
        };
        prepared.beforeDelete();
        var d: diagnostic.Diagnostic = .{};
        git.worktreeRemove(alloc, clone_path, wt_path, a.force, &d) catch {
            try ctx.err.print("holt: {s}\n", .{d.message});
            return 1;
        };
        // Once the last worktree is gone the dir is empty; drop it so the hub
        // link reconciles away.
        fsutil.rmdirIfEmpty(worktrees_dir);
        try reconcileUsers(ctx, ws, id);
        try ctx.out.print("removed worktree {s}\n", .{try app.tilde(ctx, wt_path)});
        return 0;
    }

    var d: diagnostic.Diagnostic = .{};
    git.worktreeAdd(alloc, clone_path, wt_path, branch, &d) catch {
        try ctx.err.print("holt: {s}\n", .{d.message});
        return 1;
    };
    try reconcileUsers(ctx, ws, id);
    try ctx.out.print("{s}\n", .{wt_path});
    try kept_hooks.hook(ctx, ctx.err, clone_path, .{ .path = wt_path, .whole = false });
    return 0;
}

/// Test seam: runs right before `worktree -r` finds the worktree's record
/// again.
pub var before_recheck_for_test: ?*const fn () void = null;

/// The clone's lock `weighGone` holds until the record is removed, and
/// the record it weighed, with its state then (`deleter.recordState`).
const Gone = struct {
    lock: kept.Lock,
    record: []const u8,
    state: ?[]const u8,
};

/// Weighs the worktree at `wt_path` of the clone at `clone_path`, whose
/// directory is gone, through its record as `repo remove --clone` weighs
/// it (`deleter.weighRecord`), under the clone's lock, the record's state
/// read first, and its record found again as `soleRecord` finds it: what
/// removing the record destroys (`deleter.LinkedTree.atRisk`) refuses,
/// each named with the command settling it, and `force_cmd`; with
/// `force`, each is named as deleted (`deleter.LinkedTree.lostLines`).
/// Returns the lock, held, and the record's state, when the removal may go
/// ahead; null, having said why, when it may not.
fn weighGone(ctx: *app.Ctx, clone_path: []const u8, wt_path: []const u8, force_cmd: []const u8, force: bool) !?Gone {
    const alloc = ctx.alloc;
    const kctx = deleter.keptCtx(ctx) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try ctx.err.print("holt: this machine's id cannot be read or written ({s}); refusing to remove {s}\n", .{ @errorName(err), try quotePath(ctx, wt_path) });
            return null;
        },
    };
    const c = kept.clone.inspect(alloc, clone_path, kctx.code_root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return unreadableRecords(ctx, clone_path, wt_path),
    };
    const lock = kept.lockClone(kctx, c.common_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try ctx.err.print("holt: the kept-file state directory of {s} cannot be locked ({s}); refusing to remove {s}\n", .{ try quotePath(ctx, clone_path), @errorName(err), try quotePath(ctx, wt_path) });
            return null;
        },
    };
    var ok = false;
    defer if (!ok) lock.release();
    const sole = try soleRecord(ctx, clone_path, wt_path) orelse return null;
    const state = try deleter.recordState(alloc, sole.rec.record, wt_path);
    const t = deleter.weighRecord(try deleter.Asker.of(ctx), clone_path, sole.rec) catch |err| switch (err) {
        error.GitFailed => return unreadableRecords(ctx, clone_path, wt_path),
        else => return err,
    };
    if (t.seen) |seen| {
        try ctx.err.print("holt: {s}\n", .{try deleter.unresolvedLine(ctx, wt_path, seen, try deleter.mainGit(ctx, clone_path))});
        return null;
    }
    if (t.atRisk()) {
        if (!force) {
            try ctx.err.print("holt: refusing to remove {s}, which is gone; its record holds:\n", .{try quotePath(ctx, wt_path)});
            for (try t.lines(ctx, clone_path, force_cmd)) |line| try ctx.err.print("  {s}\n", .{line});
            try ctx.err.print("or, to delete it anyway: {s}\n", .{force_cmd});
            return null;
        }
        for (try t.lostLines(ctx)) |line| try ctx.out.print("{s}\n", .{line});
    }
    ok = true;
    return .{ .lock = lock, .record = t.record, .state = state };
}

/// The one record of the clone at `clone_path` naming the worktree at
/// `wt_path`, and how the worktree stands to it, `.there` or `.absent`;
/// null, having said why, when none does, when the records cannot be
/// read, or in a state holt leaves to the user (`deleter.unresolvedSeen`):
/// more than one record names it, where `git worktree remove` may reach
/// any of them, or what is at its path does not lead back to its record.
/// That is refused with `deleter.unresolvedLine`, even with `--force`,
/// before anything is weighed, set aside, or written.
fn soleRecord(ctx: *app.Ctx, clone_path: []const u8, wt_path: []const u8) !?Sole {
    const alloc = ctx.alloc;
    const common = deleter.commonDirOf(alloc, .{ .repo = clone_path }) catch |err| switch (err) {
        error.GitFailed => {
            _ = try unreadableRecords(ctx, clone_path, wt_path);
            return null;
        },
        else => return err,
    };
    const recs = deleter.recordsIn(alloc, common, wt_path) catch |err| switch (err) {
        error.GitFailed => {
            _ = try unreadableRecords(ctx, clone_path, wt_path);
            return null;
        },
        else => return err,
    };
    if (recs.len == 0) {
        _ = try notWorkingTree(ctx, clone_path, wt_path);
        return null;
    }
    if (try deleter.unresolvedSeen(alloc, common, recs, recs[0])) |seen| {
        try ctx.err.print("holt: {s}\n", .{try deleter.unresolvedLine(ctx, wt_path, seen, try deleter.mainGit(ctx, clone_path))});
        return null;
    }
    return .{ .rec = recs[0], .link = try deleter.linkOf(alloc, common, recs[0].record, wt_path) };
}

/// The record `soleRecord` finds, and how the worktree stands to it.
const Sole = struct { rec: kept.clone.Record, link: deleter.Link };

/// Says that no worktree record of the clone at `clone_path` names
/// `wt_path`, refusing to remove it; 1, the exit code.
fn notWorkingTree(ctx: *app.Ctx, clone_path: []const u8, wt_path: []const u8) !u8 {
    try ctx.err.print("holt: {s} is not a working tree of {s}\n", .{ try quotePath(ctx, wt_path), try quotePath(ctx, clone_path) });
    return 1;
}

/// Says that the worktree records of the clone at `clone_path` cannot be
/// read, refusing to remove `wt_path`; null, for `weighGone`.
fn unreadableRecords(ctx: *app.Ctx, clone_path: []const u8, wt_path: []const u8) !?Gone {
    try ctx.err.print("holt: the worktree records of {s} cannot be read; refusing to remove {s} (run: git -C {s} worktree list --porcelain)\n", .{ try quotePath(ctx, clone_path), try quotePath(ctx, wt_path), try quotePath(ctx, clone_path) });
    return null;
}

/// Reconcile the hub of every project that uses this repo, so the
/// `code/<repo>@worktrees` link appears or disappears in all of them at once -
/// a repo can be shared across projects, and each must see its worktrees.
/// Best-effort: the git worktree change already succeeded and `holt sync`
/// rebuilds hubs anyway, so a hub hiccup here is not worth failing over.
fn reconcileUsers(ctx: *app.Ctx, ws: workspace.Workspace, id: identity.Identity) !void {
    const users = ws.projectsUsing(ctx.alloc, id) catch return;
    for (users) |p| {
        _ = hub.reconcile(ctx.alloc, &ws, &p, false) catch {};
    }
}

test "run: creating a worktree before the clone exists reports a restore hint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // A member repo whose clone was never fetched (fresh-machine case).
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj/backend", "feature" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not cloned") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "restore") != null);
}

test "run: a branch whose segments would escape the worktrees dir is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const state = try testutil.stateScope(arena, root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    for ([_][]const u8{ "../evil", "a/../b", "..\\..\\pwn" }) |branch| {
        const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj/backend", branch });
        try testing.expectEqual(@as(u8, 2), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "invalid branch name") != null);

        const removed = try testutil.runCmd(arena, command.run, ws, &.{ "proj/backend", branch, "-r" });
        try testing.expectEqual(@as(u8, 2), removed.code);
        try testing.expect(std.mem.indexOf(u8, removed.err, "invalid branch name") != null);
    }
}

test "run: an emptied @worktrees dir (raw git removal) drops the hub link on reconcile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "backend.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "backend" });
    try fsutil.ensureDir(std.fs.path.dirname(clone_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, clone_path });
    try testutil.runGit(&sb, clone_path, &.{ "branch", "feature-x" });

    const wt_path = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "feature-x" });
    const hub_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "backend@worktrees" });

    _ = try testutil.runCmd(arena, command.run, ws, &.{ "proj/backend", "feature-x" });
    switch (try fsutil.linkState(arena, hub_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }

    // Remove the worktree with raw git (bypassing holt), which leaves the now-
    // empty @worktrees dir behind. A reconcile must drop the stale hub link.
    // git's own worktree admin links are recorded on '/' even on Windows, so
    // this raw call - unlike holt's own git.worktreeAdd/Remove - must forward-
    // slash the path itself to match what `worktree add` registered. --force
    // because a fresh checkout reads as dirty under Windows git's line-ending
    // defaults; the simulated external removal only needs the worktree gone.
    try testutil.runGit(&sb, clone_path, &.{ "worktree", "remove", "--force", try fsutil.forwardSlashed(arena, wt_path) });
    const p = switch (try ws.find(arena, "proj")) {
        .one => |one| one,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, hub_link));
}

test "run: a worktree on a shared repo surfaces in every project that uses it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "lib.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/lib";

    // Two projects share the same repo.
    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "lib", url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "one", repos_a, .empty);
    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "lib", url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "two", repos_b, .empty);

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "lib" });
    try fsutil.ensureDir(std.fs.path.dirname(clone_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, clone_path });
    try testutil.runGit(&sb, clone_path, &.{ "branch", "feature" });

    // Create the worktree via one project; both hubs must gain the link.
    const got = try testutil.runCmd(arena, command.run, ws, &.{ "one/lib", "feature" });
    try testing.expectEqual(@as(u8, 0), got.code);

    for ([_][]const u8{ "one", "two" }) |proj| {
        const link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", proj, "code", "lib@worktrees" });
        switch (try fsutil.linkState(arena, link)) {
            .symlink => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

test "run: create, list, and remove a worktree; the hub link tracks it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "backend.git");
    defer testing.allocator.free(bare);

    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    // Clone the repo into its identity path and add a branch to check out.
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "backend" });
    try fsutil.ensureDir(std.fs.path.dirname(clone_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, clone_path });
    try testutil.runGit(&sb, clone_path, &.{ "branch", "feature-x" });

    const wt_path = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "feature-x" });
    const hub_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "backend@worktrees" });

    const created = try testutil.runCmd(arena, command.run, ws, &.{ "proj/backend", "feature-x" });
    try testing.expectEqual(@as(u8, 0), created.code);
    try testing.expect(std.mem.indexOf(u8, created.out, wt_path) != null);
    try testing.expectEqualStrings("feature-x", (try git.currentBranch(arena, wt_path)).?);
    switch (try fsutil.linkState(arena, hub_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }

    const listed = try testutil.runCmd(arena, command.run, ws, &.{"proj/backend"});
    try testing.expectEqual(@as(u8, 0), listed.code);
    try testing.expect(std.mem.indexOf(u8, listed.out, "feature-x") != null);

    const removed = try testutil.runCmd(arena, command.run, ws, &.{ "proj/backend", "feature-x", "--remove" });
    try testing.expectEqual(@as(u8, 0), removed.code);
    try testing.expect(!fsutil.exists(wt_path));
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, hub_link));
}

test "run: a new worktree gets links to the repo's kept files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_hooks.TestBed.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const key = "holt-test.invalid/acme/backend";
    const c = try bed.clone(key);
    try testutil.runGit(&sb, c, &.{ "branch", "feature" });
    try bed.write(c, ".clasp.json", "{\"scriptId\": \"abc\"}");
    try bed.keep(c, ".clasp.json");
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try bed.ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{ "proj/backend", "feature" });
    try testing.expectEqual(@as(u8, 0), got.code);
    const wt = std.mem.trim(u8, got.out, "\n");
    try testing.expect(try bed.linked(wt, key, ".clasp.json"));
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try bed.read(wt, ".clasp.json"));
    try testing.expect(std.mem.indexOf(u8, got.err, "linked ") != null);
}
