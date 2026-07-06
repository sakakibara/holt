//! Runs `git` as a subprocess and interprets its output for the workspace
//! CLI's status/sync commands. Every function here spawns a real child
//! process (never inherits the parent's stdio) using the caller's real
//! git configuration and credentials.

const std = @import("std");
const fsutil = @import("fsutil.zig");
const diagnostic = @import("diag.zig");
const proc = @import("proc.zig");
const testing = std.testing;

pub const RunResult = proc.RunResult;

/// Spawn `git` as an ordinary subprocess. A `FileNotFound` from the spawn
/// itself means the `git` binary is not on PATH; it is mapped to the distinct
/// `GitNotFound` so callers (and dispatch's catch-all) can report "git is not
/// installed" instead of a bare `internal error: FileNotFound`. Every git
/// invocation in this file - and every direct `git.run` caller elsewhere -
/// goes through these two, so the mapping lives in one place.
pub fn run(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !proc.RunResult {
    return proc.run(alloc, argv, cwd) catch |err| switch (err) {
        error.FileNotFound => error.GitNotFound,
        else => err,
    };
}

pub fn runEnv(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map) !proc.RunResult {
    return proc.runEnv(alloc, argv, cwd, environ_map) catch |err| switch (err) {
        error.FileNotFound => error.GitNotFound,
        else => err,
    };
}

pub const Unpushed = enum { clean, ahead, no_upstream };

/// `git clone url dest`, creating `dest`'s parent directories first. On
/// failure, if `diag` is non-null, it is set to git's own stderr so the
/// caller can show the real cause instead of a bare error name.
///
/// The clone lands in a unique sibling temp dir and is then renamed into
/// `dest` atomically, so the canonical path only ever appears fully populated:
/// a crashed clone leaves a stray temp (never a half-clone that reads as
/// healthy), and if a concurrent process wins the race to `dest` first, this
/// one keeps the winner's clone and discards its own.
pub fn clone(alloc: std.mem.Allocator, url: []const u8, dest: []const u8, diag: ?*diagnostic.Diagnostic) !void {
    if (std.fs.path.dirname(dest)) |parent| try fsutil.ensureDir(parent);

    var random_bytes: [8]u8 = undefined;
    fsutil.io().random(&random_bytes);
    var suffix_buf: [16]u8 = undefined;
    const suffix = std.base64.url_safe_no_pad.Encoder.encode(&suffix_buf, &random_bytes);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.{s}.holt-tmp", .{ dest, suffix });
    defer alloc.free(tmp);
    defer std.Io.Dir.cwd().deleteTree(fsutil.io(), tmp) catch {};

    const res = run(alloc, &.{ "git", "clone", url, tmp }, null) catch |err| switch (err) {
        error.GitNotFound => {
            if (diag) |d| d.set(alloc, "git is not installed or not on your PATH", .{});
            return error.GitNotFound;
        },
        else => return err,
    };
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) {
        if (diag) |d| {
            const trimmed = std.mem.trim(u8, res.stderr, " \t\r\n");
            const cause = if (trimmed.len == 0) "git clone failed" else trimmed;
            d.set(alloc, "failed to clone {s}: {s}", .{ url, cause });
        }
        return error.GitCloneFailed;
    }

    // Atomic publish. A populated `dest` means a concurrent clone already won;
    // keep theirs and drop ours (the deferred deleteTree cleans the temp).
    std.Io.Dir.renameAbsolute(tmp, dest, fsutil.io()) catch |err| switch (err) {
        error.DirNotEmpty, error.NotDir => return,
        else => return err,
    };
}

/// `git -C repo worktree add <path> <branch>`, creating `path`'s parent dirs
/// first. On a nonzero exit `diag` (if given) carries git's own stderr - the
/// real cause (unknown branch, branch already checked out elsewhere).
pub fn worktreeAdd(alloc: std.mem.Allocator, repo: []const u8, path: []const u8, branch: []const u8, diag: ?*diagnostic.Diagnostic) !void {
    if (std.fs.path.dirname(path)) |parent| try fsutil.ensureDir(parent);
    // `worktree.useRelativePaths` (git 2.48+) records the worktree's admin
    // links relative to the clone, so moving the clone and its sibling
    // `@worktrees` dir together (see common.moveClone) keeps them working with
    // no repair. Older git silently ignores the unknown config and records
    // absolute paths, which moveClone then repairs - so this degrades cleanly.
    const res = try run(alloc, &.{ "git", "-C", repo, "-c", "worktree.useRelativePaths=true", "worktree", "add", path, branch }, null);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) {
        if (diag) |d| {
            const t = std.mem.trim(u8, res.stderr, " \t\r\n");
            d.set(alloc, "{s}", .{if (t.len == 0) "git worktree add failed" else t});
        }
        return error.WorktreeAddFailed;
    }
}

/// `git -C repo worktree list` output (caller owns the returned bytes).
pub fn worktreeList(alloc: std.mem.Allocator, repo: []const u8) ![]u8 {
    const res = try run(alloc, &.{ "git", "-C", repo, "worktree", "list" }, null);
    defer alloc.free(res.stderr);
    if (res.status != 0) {
        alloc.free(res.stdout);
        return error.WorktreeListFailed;
    }
    return res.stdout;
}

/// `git -C repo worktree remove <path>`. git refuses a dirty worktree without
/// --force, which is deliberately not passed: `diag` carries that refusal.
pub fn worktreeRemove(alloc: std.mem.Allocator, repo: []const u8, path: []const u8, diag: ?*diagnostic.Diagnostic) !void {
    const res = try run(alloc, &.{ "git", "-C", repo, "worktree", "remove", path }, null);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) {
        if (diag) |d| {
            const t = std.mem.trim(u8, res.stderr, " \t\r\n");
            d.set(alloc, "{s}", .{if (t.len == 0) "git worktree remove failed" else t});
        }
        return error.WorktreeRemoveFailed;
    }
}

/// `git -C repo worktree repair <path>...`: reestablish the admin links after
/// a clone and its worktrees were moved on disk (each `path` is a worktree's
/// new location). Best-effort - repair fixes what it can and a partial failure
/// still leaves the repo usable, so a nonzero exit is not propagated.
pub fn worktreeRepair(alloc: std.mem.Allocator, repo: []const u8, paths: []const []const u8) !void {
    if (paths.len == 0) return;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "-C", repo, "worktree", "repair" });
    try argv.appendSlice(alloc, paths);
    const res = run(alloc, argv.items, null) catch return;
    alloc.free(res.stdout);
    alloc.free(res.stderr);
}

/// Count of worktrees attached to `repo`, main working tree included, so a
/// result > 1 means extra linked worktrees exist (each may hold uncommitted
/// work). Uses the stable `--porcelain` format, one `worktree ` line each.
pub fn worktreeCount(alloc: std.mem.Allocator, repo: []const u8) !usize {
    const res = try run(alloc, &.{ "git", "-C", repo, "worktree", "list", "--porcelain" }, null);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) return error.WorktreeListFailed;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) n += 1;
    }
    return n;
}

/// True iff `repo` is a readable git repository (`git -C repo rev-parse
/// --git-dir` exits 0). A nonzero exit means the directory cannot be
/// trusted to inspect further - callers gate on this before treating any
/// other git query's result as meaningful. An allocation or spawn-
/// infrastructure failure (OutOfMemory, etc.) propagates as an error rather
/// than being folded into a false "not readable" result.
///
/// GIT_CEILING_DIRECTORIES is pinned to `repo`'s own parent so a broken or
/// non-repo `repo` is judged on its own merits rather than git silently
/// walking up and finding an unrelated ancestor repository (e.g. `repo`
/// sitting inside a developer's own checkout of this project).
pub fn inspectable(alloc: std.mem.Allocator, repo: []const u8) !bool {
    const real_env = std.Io.Threaded.global_single_threaded.environ.process_environ;
    var map = try std.process.Environ.createMap(real_env, alloc);
    defer map.deinit();
    try map.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(repo) orelse repo);

    const res = try runEnv(alloc, &.{ "git", "-C", repo, "rev-parse", "--git-dir" }, null, &map);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.status == 0;
}

/// True iff `repo` is a fully-populated clone: it has a commit reachable from
/// HEAD. This is stronger than `inspectable`, which only checks that a `.git`
/// exists - an interrupted `git clone` (SIGKILL, power loss) leaves a `.git`
/// with "No commits yet", which `inspectable` accepts but this rejects, so a
/// half-finished clone is not silently adopted as if complete.
///
/// GIT_CEILING_DIRECTORIES is pinned to `repo`'s parent for the same reason
/// as `inspectable`: a non-repo `repo` must be judged on its own merits, not
/// resolve HEAD from some ancestor repository.
pub fn isCompleteClone(alloc: std.mem.Allocator, repo: []const u8) !bool {
    const real_env = std.Io.Threaded.global_single_threaded.environ.process_environ;
    var map = try std.process.Environ.createMap(real_env, alloc);
    defer map.deinit();
    try map.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(repo) orelse repo);

    const res = try runEnv(alloc, &.{ "git", "-C", repo, "rev-parse", "-q", "--verify", "HEAD" }, null, &map);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.status == 0;
}

/// The `origin` remote URL, or null if it is unset. Caller owns the returned
/// memory.
pub fn remoteUrl(alloc: std.mem.Allocator, repo: []const u8) !?[]u8 {
    const res = try run(alloc, &.{ "git", "config", "--get", "remote.origin.url" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) return null;

    const trimmed = std.mem.trim(u8, res.stdout, "\n");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

/// True if `git status --porcelain` reports anything, tracked or not.
pub fn isDirty(alloc: std.mem.Allocator, repo: []const u8) !bool {
    const res = try run(alloc, &.{ "git", "status", "--porcelain" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.stdout.len != 0;
}

/// True if the repo has any stash entries.
pub fn hasStashes(alloc: std.mem.Allocator, repo: []const u8) !bool {
    const res = try run(alloc, &.{ "git", "stash", "list" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.stdout.len != 0;
}

/// Compares HEAD against its upstream. `no_upstream` covers both a detached
/// HEAD and a branch with no tracking configured, since `@{upstream}` fails
/// to resolve in either case.
pub fn unpushed(alloc: std.mem.Allocator, repo: []const u8) !Unpushed {
    const res = try run(alloc, &.{ "git", "rev-list", "@{upstream}..HEAD" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) return .no_upstream;
    return if (res.stdout.len == 0) .clean else .ahead;
}

/// The current branch name, or null on a detached HEAD. Caller owns the
/// returned memory.
pub fn currentBranch(alloc: std.mem.Allocator, repo: []const u8) !?[]u8 {
    const res = try run(alloc, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) return null;

    const trimmed = std.mem.trim(u8, res.stdout, "\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "HEAD")) return null;
    return try alloc.dupe(u8, trimmed);
}

const testutil = @import("testutil.zig");

test "clone: populates dest from a makeBareRepo bare, checked out on main" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const dest = try std.fs.path.join(testing.allocator, &.{ sb.root, "cloned" });
    defer testing.allocator.free(dest);

    try clone(testing.allocator, bare, dest, null);

    const branch = try currentBranch(testing.allocator, dest);
    defer if (branch) |b| testing.allocator.free(b);
    try testing.expect(branch != null);
    try testing.expectEqualStrings("main", branch.?);
}

test "clone: on failure, sets the diagnostic to a message containing the url" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const dest = try std.fs.path.join(testing.allocator, &.{ sb.root, "cloned" });
    defer testing.allocator.free(dest);

    var cd: diagnostic.Diagnostic = .{};
    const url = "git://127.0.0.1:1/acme/widget";
    try testing.expectError(error.GitCloneFailed, clone(testing.allocator, url, dest, &cd));
    defer testing.allocator.free(cd.message);
    try testing.expect(std.mem.indexOf(u8, cd.message, url) != null);
}

test "inspectable: true for a real repo, false for a plain directory and a nonexistent path" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try testing.expect(try inspectable(testing.allocator, work));

    const plain_dir = try std.fs.path.join(testing.allocator, &.{ sb.root, "plain" });
    defer testing.allocator.free(plain_dir);
    try fsutil.ensureDir(plain_dir);
    try testing.expect(!try inspectable(testing.allocator, plain_dir));

    const missing = try std.fs.path.join(testing.allocator, &.{ sb.root, "does-not-exist" });
    defer testing.allocator.free(missing);
    try testing.expect(!try inspectable(testing.allocator, missing));
}

test "isCompleteClone: true for a checked-out clone, false for an empty git init and a plain dir" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try testing.expect(try isCompleteClone(testing.allocator, work));

    // An interrupted `git clone` leaves a `.git` with no commits; `git init`
    // reproduces exactly that state - inspectable, but not a complete clone.
    const empty = try std.fs.path.join(testing.allocator, &.{ sb.root, "empty" });
    defer testing.allocator.free(empty);
    try fsutil.ensureDir(empty);
    try testutil.runGit(&sb, empty, &.{ "init", "-q" });
    try testing.expect(try inspectable(testing.allocator, empty));
    try testing.expect(!try isCompleteClone(testing.allocator, empty));

    const plain = try std.fs.path.join(testing.allocator, &.{ sb.root, "plain" });
    defer testing.allocator.free(plain);
    try fsutil.ensureDir(plain);
    try testing.expect(!try isCompleteClone(testing.allocator, plain));
}

test "remoteUrl: round-trips the origin URL set by clone" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    const url = try remoteUrl(testing.allocator, work);
    defer if (url) |u| testing.allocator.free(u);
    try testing.expect(url != null);
    try testing.expectEqualStrings(bare, url.?);
}

test "remoteUrl: null when origin is unset" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try testutil.runGit(&sb, work, &.{ "remote", "remove", "origin" });

    const url = try remoteUrl(testing.allocator, work);
    try testing.expect(url == null);
}

test "isDirty: false on a fresh clone, true once an untracked file appears" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try testing.expect(!(try isDirty(testing.allocator, work)));

    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });

    try testing.expect(try isDirty(testing.allocator, work));
}

test "unpushed: clean on a fresh clone, ahead after a local commit, no_upstream on an untracked branch" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try testing.expectEqual(Unpushed.clean, try unpushed(testing.allocator, work));

    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "changed\n" });
    try testutil.runGit(&sb, work, &.{ "commit", "-am", "local change" });

    try testing.expectEqual(Unpushed.ahead, try unpushed(testing.allocator, work));

    try testutil.runGit(&sb, work, &.{ "checkout", "-b", "feature" });
    try testing.expectEqual(Unpushed.no_upstream, try unpushed(testing.allocator, work));
}

test "hasStashes: false with a clean tree, true after `git stash`" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try testing.expect(!(try hasStashes(testing.allocator, work)));

    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "changed\n" });
    try testutil.runGit(&sb, work, &.{"stash"});

    try testing.expect(try hasStashes(testing.allocator, work));
}

test "currentBranch: returns the checked-out branch name" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    const branch = try currentBranch(testing.allocator, work);
    defer if (branch) |b| testing.allocator.free(b);
    try testing.expect(branch != null);
    try testing.expectEqualStrings("main", branch.?);
}
