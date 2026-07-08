//! `holt worktree <project>/<repo> [<branch>] [--remove]`: manage a repo's git
//! worktrees. A worktree is an extra checkout that shares the repo's one
//! canonical clone - never a second clone. Worktrees live in a sibling
//! `<clone>@worktrees/` dir and surface in the hub as `code/<repo>@worktrees`,
//! so a project opened at its hub root can reach every branch's checkout.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const path = @import("path.zig");
const git = @import("../git.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const diagnostic = @import("../diag.zig");
const workspace = @import("../workspace.zig");
const identity = @import("../identity.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    repo: args.Pos([]const u8, .{ .complete = comp.cat(.project_repo), .help = "the <project>/<repo> whose worktrees to manage" }),
    branch: args.Pos(?[]const u8, .{ .value_name = "branch", .help = "branch to check out in a new worktree; omit to list" }),
    remove: args.Flag(.{ .short = 'r', .help = "remove the worktree for <branch> instead of creating it" }),
};

pub const command = args.command(Spec, .{
    .name = "worktree",
    .about = "Create, list, or remove a repo's git worktrees",
    .usage = "holt worktree <project>/<repo> [<branch>] [--remove]",
    .group = .navigate,
    .details =
    \\A worktree is an extra checkout of a repo's one canonical clone, on a
    \\different branch, so two branches can be checked out at once without a
    \\second clone. It appears in the hub as `code/<repo>@worktrees/<branch>`.
    \\
    \\Examples:
    \\  holt worktree acme/backend feature-x      # create; prints its path
    \\  holt worktree acme/backend                # list
    \\  holt worktree acme/backend feature-x -r   # remove
    ,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const ws = ctx.ws.?;
    const alloc = ctx.alloc;

    const slash = std.mem.lastIndexOfScalar(u8, a.repo, '/') orelse {
        ctx.args.message = "worktree takes <project>/<repo>";
        return error.UsageError;
    };
    const project_query = a.repo[0..slash];
    const repo_query = a.repo[slash + 1 ..];
    if (project_query.len == 0 or repo_query.len == 0) {
        ctx.args.message = "worktree takes <project>/<repo>";
        return error.UsageError;
    }

    const id = (try path.resolveRepoId(ctx, ws, project_query, repo_query)) orelse return 1;
    const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
    if (!fsutil.exists(clone_path)) {
        try ctx.err_w.print("holt: {s} is not cloned yet; run `holt restore` first\n", .{a.repo});
        return 1;
    }
    const worktrees_dir = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{clone_path});

    if (a.branch == null) {
        if (a.remove) {
            ctx.args.message = "--remove needs a <branch>";
            return error.UsageError;
        }
        const listing = git.worktreeList(alloc, clone_path) catch {
            try ctx.err_w.print("holt: could not list worktrees for {s}\n", .{clone_path});
            return 1;
        };
        defer alloc.free(listing);
        try ctx.out.writeAll(listing);
        return 0;
    }

    const branch = a.branch.?;
    const wt_path = try fsutil.joinSlashy(alloc, worktrees_dir, branch);

    if (a.remove) {
        var d: diagnostic.Diagnostic = .{};
        git.worktreeRemove(alloc, clone_path, wt_path, &d) catch {
            try ctx.err_w.print("holt: {s}\n", .{d.message});
            return 1;
        };
        // Once the last worktree is gone the dir is empty; drop it so the hub
        // link reconciles away.
        fsutil.rmdirIfEmpty(worktrees_dir);
        try reconcileUsers(ctx, ws, id);
        try ctx.out.print("removed worktree {s}\n", .{wt_path});
        return 0;
    }

    var d: diagnostic.Diagnostic = .{};
    git.worktreeAdd(alloc, clone_path, wt_path, branch, &d) catch {
        try ctx.err_w.print("holt: {s}\n", .{d.message});
        return 1;
    };
    try reconcileUsers(ctx, ws, id);
    try ctx.out.print("{s}\n", .{wt_path});
    return 0;
}

/// Reconcile the hub of every project that uses this repo, so the
/// `code/<repo>@worktrees` link appears or disappears in all of them at once -
/// a repo can be shared across projects, and each must see its worktrees.
/// Best-effort: the git worktree change already succeeded and `holt sync`
/// rebuilds hubs anyway, so a hub hiccup here is not worth failing over.
fn reconcileUsers(ctx: *cli.Ctx, ws: workspace.Workspace, id: identity.Identity) !void {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj/backend", "feature" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not cloned") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "restore") != null);
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "one", .{ .version = 1, .org = "acme", .name = "one", .repos = repos_a });
    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "lib", url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "two", .{ .version = 1, .org = "acme", .name = "two", .repos = repos_b });

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

    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

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
