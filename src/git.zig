//! Runs `git` as a subprocess and interprets its output for the workspace
//! CLI's status/sync commands. Every function here spawns a real child
//! process (never inherits the parent's stdio) using the caller's real
//! git configuration and credentials.

const std = @import("std");
const builtin = @import("builtin");
const fsutil = @import("fsutil.zig");
const diagnostic = @import("diag.zig");
const proc = @import("proc.zig");
const testing = std.testing;

pub const RunResult = proc.RunResult;

/// Spawn `git` as an ordinary subprocess, in the process's environment with
/// GIT_OPTIONAL_LOCKS=0, so a command that only reads (`status`, say) never
/// writes the repository's index to refresh it. A `FileNotFound` from the
/// spawn itself means the `git` binary is not on PATH; it is mapped to the
/// distinct `GitNotFound` so callers (and dispatch's catch-all) can report
/// "git is not installed" instead of a bare `internal error: FileNotFound`.
/// Every git invocation in this file - and every direct `git.run` caller
/// elsewhere - goes through these two, so the mapping lives in one place.
pub fn run(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !proc.RunResult {
    const real_env = std.Io.Threaded.global_single_threaded.environ.process_environ;
    var map = try std.process.Environ.createMap(real_env, alloc);
    defer map.deinit();
    try map.put("GIT_OPTIONAL_LOCKS", "0");
    return runEnv(alloc, argv, cwd, &map);
}

/// `run` for a command that only reads: GIT_NO_LAZY_FETCH=1 too, so a
/// missing object is never fetched from a promisor remote (git 2.44 and
/// newer honor it; older ones ignore it), GIT_NO_REPLACE_OBJECTS=1, so
/// each object is read as stored, and GIT_TERMINAL_PROMPT=0, so a fetch an
/// older git makes for a missing object never waits on a prompt.
fn runRead(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !proc.RunResult {
    const real_env = std.Io.Threaded.global_single_threaded.environ.process_environ;
    var map = try std.process.Environ.createMap(real_env, alloc);
    defer map.deinit();
    try map.put("GIT_OPTIONAL_LOCKS", "0");
    try map.put("GIT_NO_LAZY_FETCH", "1");
    try map.put("GIT_NO_REPLACE_OBJECTS", "1");
    try map.put("GIT_TERMINAL_PROMPT", "0");
    return runEnv(alloc, argv, cwd, &map);
}

pub fn runEnv(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map) !proc.RunResult {
    return proc.runEnv(alloc, argv, cwd, environ_map) catch |err| switch (err) {
        error.FileNotFound => error.GitNotFound,
        else => err,
    };
}

/// Runs `argv` with inherited stdio so a long-running git child streams its
/// own progress to the terminal and can prompt for credentials, returning the
/// mapped exit status. Nothing is captured, so a caller wanting git's stderr
/// text uses `run` instead.
pub fn spawnStreamed(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map) !u8 {
    return proc.spawnInheritedEnv(alloc, argv, cwd, environ_map) catch |err| switch (err) {
        error.FileNotFound => error.GitNotFound,
        else => err,
    };
}

pub const Unpushed = enum { clean, ahead, no_upstream };

/// Whether a clone may ask on the terminal, git for credentials or ssh for
/// a passphrase or a host key. Clones running side by side `forbid` it:
/// their prompts would share one terminal, and each line typed would reach
/// whichever read first.
pub const Prompt = enum { allow, forbid };

/// The ssh command git runs when nothing may prompt: ssh fails rather than
/// asks, gives up on a host silent for ten seconds, and opens no shared
/// connection another command could hold.
pub const batch_ssh = "ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=no";

/// Whether `environ` names the command git runs for ssh: a non-empty
/// `GIT_SSH_COMMAND` or `GIT_SSH`. `core.sshCommand` names one too.
pub fn environNamesSsh(environ: *const std.process.Environ.Map) bool {
    for ([_][]const u8{ "GIT_SSH_COMMAND", "GIT_SSH" }) |name| {
        if (environ.get(name)) |v| if (v.len > 0) return true;
    }
    return false;
}

/// `git clone url dest`, creating `dest`'s parent directories first. The
/// clone streams git's own progress to the terminal and, under `.allow`, can
/// prompt; under `.forbid`, git cannot, nor can ssh, run as `batch_ssh`
/// unless the user names an ssh command, which is left as it is. git prints
/// the real cause of a failure itself, so `diag` (if non-null) carries only
/// a short summary.
///
/// The clone lands in a unique sibling temp dir and is then renamed into
/// `dest` atomically, so the canonical path only ever appears fully populated:
/// a crashed clone leaves a stray temp (never a half-clone that reads as
/// healthy), and if a concurrent process wins the race to `dest` first, this
/// one keeps the winner's clone and discards its own.
///
/// `url` is a marker value, so it is separated from the options by `--`:
/// without it a value starting with `-` is read by git as an option
/// (`--upload-pack=<cmd>` names a command git runs) rather than a repository.
pub fn clone(alloc: std.mem.Allocator, url: []const u8, dest: []const u8, prompt: Prompt, diag: ?*diagnostic.Diagnostic) !void {
    if (std.fs.path.dirname(dest)) |parent| try fsutil.ensureDir(parent);

    var env: ?std.process.Environ.Map = null;
    defer if (env) |*m| m.deinit();
    if (prompt == .forbid) {
        env = try std.process.Environ.createMap(std.Io.Threaded.global_single_threaded.environ.process_environ, alloc);
        try env.?.put("GIT_TERMINAL_PROMPT", "0");
        if (!environNamesSsh(&env.?) and !try configNamesSsh(alloc, std.fs.path.dirname(dest))) try env.?.put("GIT_SSH_COMMAND", batch_ssh);
    }

    var random_bytes: [8]u8 = undefined;
    fsutil.io().random(&random_bytes);
    var suffix_buf: [16]u8 = undefined;
    const suffix = std.base64.url_safe_no_pad.Encoder.encode(&suffix_buf, &random_bytes);
    const tmp = try std.fmt.allocPrint(alloc, "{s}.{s}.holt-tmp", .{ dest, suffix });
    defer alloc.free(tmp);
    defer std.Io.Dir.cwd().deleteTree(fsutil.io(), tmp) catch {};

    const status = spawnStreamed(alloc, &.{ "git", "clone", "--", url, tmp }, null, if (env) |*m| m else null) catch |err| switch (err) {
        error.GitNotFound => {
            if (diag) |d| d.set(alloc, "git is not installed or not on your PATH", .{});
            return error.GitNotFound;
        },
        else => return err,
    };
    if (status != 0) {
        if (diag) |d| d.set(alloc, "failed to clone {s} (see the git output above)", .{url});
        return error.GitCloneFailed;
    }

    // Atomic publish. A populated `dest` means a concurrent clone already won;
    // keep theirs and drop ours (the deferred deleteTree cleans the temp).
    std.Io.Dir.renameAbsolute(tmp, dest, fsutil.io()) catch |err| switch (err) {
        error.DirNotEmpty, error.NotDir => return,
        else => return err,
    };
}

/// Whether git, run in `dir` (or the current directory), reads a
/// non-empty `core.sshCommand`.
fn configNamesSsh(alloc: std.mem.Allocator, dir: ?[]const u8) !bool {
    const res = try run(alloc, &.{ "git", "config", "core.sshCommand" }, dir);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.status == 0 and std.mem.trim(u8, res.stdout, " \t\r\n").len > 0;
}

/// `git -C repo worktree add <path> <branch>`, creating `path`'s parent dirs
/// first. On a nonzero exit `diag` (if given) carries git's own stderr - the
/// real cause (unknown branch, branch already checked out elsewhere).
///
/// `branch` is user input, so `--` separates it from the options: without it
/// a branch starting with `-` is read by git as an option (`--detach` would
/// silently make a detached worktree instead of failing on a bad ref).
pub fn worktreeAdd(alloc: std.mem.Allocator, repo: []const u8, path: []const u8, branch: []const u8, diag: ?*diagnostic.Diagnostic) !void {
    if (std.fs.path.dirname(path)) |parent| try fsutil.ensureDir(parent);
    // git's worktree admin links are recorded and matched on '/' even on
    // Windows; a native `\`-path here can fail to match on a later
    // `worktree remove`, so forward-slash it before handing it off.
    const git_path = try fsutil.forwardSlashed(alloc, path);
    defer alloc.free(git_path);
    // `worktree.useRelativePaths` (git 2.48+) records the worktree's admin
    // links relative to the clone, so moving the clone and its sibling
    // `@worktrees` dir together (see common.moveClone) keeps them working with
    // nothing rewritten. Older git silently ignores the unknown config and
    // records absolute paths, which moveClone then relinks one worktree at a
    // time - so this degrades cleanly.
    const res = try run(alloc, &.{ "git", "-C", repo, "-c", "worktree.useRelativePaths=true", "worktree", "add", "--", git_path, branch }, null);
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
    const res = try runRead(alloc, &.{ "git", "-C", repo, "worktree", "list" }, null);
    defer alloc.free(res.stderr);
    if (res.status != 0) {
        alloc.free(res.stdout);
        return error.WorktreeListFailed;
    }
    return res.stdout;
}

/// `git -C repo worktree remove [--force] <path>`. Without `force` git
/// refuses a dirty worktree, and `diag` carries that refusal.
pub fn worktreeRemove(alloc: std.mem.Allocator, repo: []const u8, path: []const u8, force: bool, diag: ?*diagnostic.Diagnostic) !void {
    const git_path = try fsutil.forwardSlashed(alloc, path);
    defer alloc.free(git_path);
    const res = if (force)
        try run(alloc, &.{ "git", "-C", repo, "worktree", "remove", "--force", git_path }, null)
    else
        try run(alloc, &.{ "git", "-C", repo, "worktree", "remove", git_path }, null);
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

/// Count of worktrees attached to `repo`, main working tree included, so a
/// result > 1 means extra linked worktrees exist (each may hold uncommitted
/// work). Uses the stable `--porcelain` format, one `worktree ` line each.
pub fn worktreeCount(alloc: std.mem.Allocator, repo: []const u8) !usize {
    const res = try runRead(alloc, &.{ "git", "-C", repo, "worktree", "list", "--porcelain" }, null);
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

/// Whether `git -C repo worktree list --porcelain` records the working tree
/// at `path` as locked, both paths compared as real paths.
/// `WorktreeListFailed` when git cannot list them.
pub fn worktreeLocked(alloc: std.mem.Allocator, repo: []const u8, path: []const u8) !bool {
    const res = try runRead(alloc, &.{ "git", "-C", repo, "worktree", "list", "--porcelain" }, null);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) return error.WorktreeListFailed;
    const want = try fsutil.realPathOrSelf(alloc, path);
    defer alloc.free(want);
    var here = false;
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "worktree ")) {
            const got = try fsutil.realPathOrSelf(alloc, line["worktree ".len..]);
            defer alloc.free(got);
            here = std.mem.eql(u8, got, want);
        } else if (here and (std.mem.eql(u8, line, "locked") or std.mem.startsWith(u8, line, "locked "))) {
            return true;
        }
    }
    return false;
}

/// A process-environment map with GIT_CEILING_DIRECTORIES pinned to `repo`'s
/// parent, so a git command run in `repo` is judged on its own merits and
/// never walks up to resolve an ancestor repository above it, and
/// GIT_OPTIONAL_LOCKS=0, so a command that only reads (`status`, say) never
/// writes the repository's index to refresh it, GIT_NO_LAZY_FETCH=1, so it
/// never fetches a missing object from a promisor remote (git 2.44 and
/// newer honor it; older ones ignore it), GIT_NO_REPLACE_OBJECTS=1, so
/// it reads each object as stored, never one a replace ref stands in for
/// it, and GIT_TERMINAL_PROMPT=0, so it never waits on a prompt, a fetch
/// an older git makes for a missing object included. Caller owns the
/// returned map and must deinit it.
fn ceilingEnviron(alloc: std.mem.Allocator, repo: []const u8) !std.process.Environ.Map {
    const real_env = std.Io.Threaded.global_single_threaded.environ.process_environ;
    var map = try std.process.Environ.createMap(real_env, alloc);
    errdefer map.deinit();
    try map.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(repo) orelse repo);
    try map.put("GIT_OPTIONAL_LOCKS", "0");
    try map.put("GIT_NO_LAZY_FETCH", "1");
    try map.put("GIT_NO_REPLACE_OBJECTS", "1");
    try map.put("GIT_TERMINAL_PROMPT", "0");
    return map;
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
    var map = try ceilingEnviron(alloc, repo);
    defer map.deinit();

    const res = try runEnv(alloc, &.{ "git", "-C", repo, "rev-parse", "--git-dir" }, null, &map);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.status == 0;
}

/// When `repo` is a linked working tree of another repository (its git
/// directory, `git rev-parse --git-dir`, is not its common directory,
/// `--git-common-dir`), that repository's main working tree as `git
/// worktree list` names it first (the repository itself for a bare one),
/// or its common directory when git lists none, with native separators;
/// null for any other `repo`, and when git cannot read it.
pub fn linkedMain(alloc: std.mem.Allocator, repo: []const u8) !?[]const u8 {
    const dirs = try runInRepo(alloc, &.{ "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" }, repo);
    defer alloc.free(dirs.stdout);
    defer alloc.free(dirs.stderr);
    if (dirs.status != 0) return null;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, dirs.stdout, " \t\r\n"), '\n');
    const git_dir = std.mem.trimEnd(u8, it.next() orelse return null, "\r");
    const common_dir = std.mem.trimEnd(u8, it.next() orelse return null, "\r");
    const g = try fsutil.realPathOrSelf(alloc, git_dir);
    defer alloc.free(g);
    const c = try fsutil.realPathOrSelf(alloc, common_dir);
    defer alloc.free(c);
    if (std.mem.eql(u8, g, c)) return null;
    const listed = try runInRepo(alloc, &.{ "worktree", "list", "--porcelain" }, repo);
    defer alloc.free(listed.stdout);
    defer alloc.free(listed.stderr);
    if (listed.status == 0) {
        const first = std.mem.trimEnd(u8, std.mem.sliceTo(listed.stdout, '\n'), "\r");
        if (std.mem.startsWith(u8, first, "worktree ")) return try fsutil.nativeSlashed(alloc, first["worktree ".len..]);
    }
    return try fsutil.nativeSlashed(alloc, common_dir);
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
    var map = try ceilingEnviron(alloc, repo);
    defer map.deinit();

    const res = try runEnv(alloc, &.{ "git", "-C", repo, "rev-parse", "-q", "--verify", "HEAD" }, null, &map);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.status == 0;
}

/// Runs `git <args...>` inside `repo`, ceiling-pinned like `inspectable` so a
/// non-repo `repo` is judged on its own merits rather than git walking up and
/// resolving some ancestor repository above it. For read commands that must
/// stay scoped to the clone at `repo` without a separate `inspectable`
/// precheck.
pub fn runInRepo(alloc: std.mem.Allocator, args: []const []const u8, repo: []const u8) !proc.RunResult {
    var map = try ceilingEnviron(alloc, repo);
    defer map.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "-C", repo });
    try argv.appendSlice(alloc, args);

    return runEnv(alloc, argv.items, null, &map);
}

/// The variables that point git at a repository, working tree, index,
/// object store, or ref namespace other than the one it finds from its
/// working directory, that add configuration a parent git passed down
/// (`git -c`, `--config-env`), or that change how every pathspec matches.
/// A git hook runs with some of them set.
const scoped_out = [_][]const u8{
    "GIT_DIR",              "GIT_WORK_TREE",        "GIT_INDEX_FILE",        "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY", "GIT_NAMESPACE",        "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
    "GIT_GLOB_PATHSPECS",   "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",   "GIT_LITERAL_PATHSPECS",
};

/// The prefixes of the numbered `GIT_CONFIG_COUNT` entries.
const scoped_out_prefixes = [_][]const u8{ "GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_" };

/// `runInRepo` with `scoped_out` and every `scoped_out_prefixes` variable
/// removed from git's environment, so the command reads `repo`'s own
/// repository and index, and matches as the user's own git does, even when
/// holt runs from inside a git hook. The user's configuration files apply
/// as usual.
pub fn runInRepoScoped(alloc: std.mem.Allocator, args: []const []const u8, repo: []const u8) !proc.RunResult {
    return runInRepoScopedWith(alloc, args, repo, .{});
}

pub const ScopedOptions = struct {
    /// Variables set in git's environment on top of the scoped one.
    set: []const [2][]const u8 = &.{},
    /// A file git reads as its standard input; the null device when null.
    stdin_path: ?[]const u8 = null,
    /// What git reads as its standard input, through a pipe; not with
    /// `stdin_path`.
    stdin_data: ?[]const u8 = null,
    /// How long git may run before it is killed (`proc.runEnvLimited`);
    /// unlimited when null. Not with `stdin_path` or `stdin_data`.
    limit: ?std.Io.Duration = null,
    /// With `limit`, the line written once git has run that long.
    notice: ?proc.Notice = null,
};

/// `runInRepoScoped` with `opts.set` added to git's environment, when
/// `opts.stdin_path` or `opts.stdin_data` is set, that file or data as
/// git's standard input, and, when
/// `opts.limit` is set, git killed once it has passed.
pub fn runInRepoScopedWith(alloc: std.mem.Allocator, args: []const []const u8, repo: []const u8, opts: ScopedOptions) !proc.RunResult {
    var map = try scopedEnviron(alloc, repo);
    defer map.deinit();
    return runInMap(alloc, args, repo, &map, opts);
}

/// What a command the delete gate runs does (`runGateWith`).
pub const Gate = enum {
    /// Reads the repository: no transport may run, whatever the user's
    /// configuration allows (`GIT_ALLOW_PROTOCOL` names none), so no read
    /// of a missing object reaches a promisor remote.
    read,
    /// Asks a remote what it holds, under the user's own protocol
    /// configuration: an inherited `GIT_ALLOW_PROTOCOL` is removed.
    query,
};

/// `runInRepoScopedWith` in the environment of a command the delete gate
/// runs: no prompt git or ssh could raise for a password or a host key
/// (`GIT_ASKPASS` empty, `SSH_ASKPASS` unset, `SSH_ASKPASS_REQUIRE=never`),
/// no tracing (`GIT_TRACE*` unset), git's messages in English
/// (`LC_ALL=C`), so they can be matched, and the transport policy of
/// `gate`. Other callers of `runInRepoScopedWith` keep the user's settings
/// of these.
pub fn runGateWith(alloc: std.mem.Allocator, args: []const []const u8, repo: []const u8, gate: Gate, opts: ScopedOptions) !proc.RunResult {
    var map = try scopedEnviron(alloc, repo);
    defer map.deinit();
    var i: usize = 0;
    while (i < map.count()) {
        const name = map.keys()[i];
        if (if (builtin.os.tag == .windows) std.ascii.startsWithIgnoreCase(name, "GIT_TRACE") else std.mem.startsWith(u8, name, "GIT_TRACE")) {
            _ = map.orderedRemove(name);
        } else i += 1;
    }
    try map.put("GIT_ASKPASS", "");
    _ = map.orderedRemove("SSH_ASKPASS");
    try map.put("SSH_ASKPASS_REQUIRE", "never");
    try map.put("LC_ALL", "C");
    switch (gate) {
        .read => try map.put("GIT_ALLOW_PROTOCOL", "holt_none"),
        .query => _ = map.orderedRemove("GIT_ALLOW_PROTOCOL"),
    }
    return runInMap(alloc, args, repo, &map, opts);
}

/// `ceilingEnviron` without `scoped_out` and every `scoped_out_prefixes`
/// variable.
fn scopedEnviron(alloc: std.mem.Allocator, repo: []const u8) !std.process.Environ.Map {
    var map = try ceilingEnviron(alloc, repo);
    errdefer map.deinit();
    for (scoped_out) |name| _ = map.swapRemove(name);
    var i: usize = 0;
    while (i < map.count()) {
        const name = map.keys()[i];
        const numbered = for (scoped_out_prefixes) |prefix| {
            if (if (builtin.os.tag == .windows) std.ascii.startsWithIgnoreCase(name, prefix) else std.mem.startsWith(u8, name, prefix)) break true;
        } else false;
        if (numbered) {
            _ = map.orderedRemove(name);
        } else i += 1;
    }
    return map;
}

/// Runs `git -C <repo> <args>` in `map` with `opts.set` added, as
/// `runInRepoScopedWith` describes.
fn runInMap(alloc: std.mem.Allocator, args: []const []const u8, repo: []const u8, map: *std.process.Environ.Map, opts: ScopedOptions) !proc.RunResult {
    for (opts.set) |kv| try map.put(kv[0], kv[1]);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "-C", repo });
    try argv.appendSlice(alloc, args);

    if (opts.stdin_path) |p| return proc.runEnvInput(alloc, argv.items, null, map, p) catch |err| switch (err) {
        error.FileNotFound => error.GitNotFound,
        else => err,
    };
    if (opts.stdin_data) |d| return proc.runEnvData(alloc, argv.items, null, map, d) catch |err| switch (err) {
        error.FileNotFound => error.GitNotFound,
        else => err,
    };
    if (opts.limit) |limit| return proc.runEnvLimited(alloc, argv.items, null, map, limit, opts.notice) catch |err| switch (err) {
        error.FileNotFound => error.GitNotFound,
        else => err,
    };
    return runEnv(alloc, argv.items, null, map);
}

/// The `origin` remote URL, or null if it is unset. Caller owns the returned
/// memory.
pub fn remoteUrl(alloc: std.mem.Allocator, repo: []const u8) !?[]u8 {
    const res = try runRead(alloc, &.{ "git", "config", "--get", "remote.origin.url" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) return null;

    const trimmed = std.mem.trim(u8, res.stdout, "\n");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

/// True if `git status --porcelain` reports anything, tracked or not,
/// whatever `status.showUntrackedFiles` and each submodule's `ignore` say,
/// or if git cannot tell.
pub fn isDirty(alloc: std.mem.Allocator, repo: []const u8) !bool {
    const res = try runRead(alloc, &.{ "git", "status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=none" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.status != 0 or res.stdout.len != 0;
}

/// True if the repo has any stash entries.
pub fn hasStashes(alloc: std.mem.Allocator, repo: []const u8) !bool {
    const res = try runRead(alloc, &.{ "git", "stash", "list" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    return res.stdout.len != 0;
}

/// Compares HEAD against its upstream. `no_upstream` covers both a detached
/// HEAD and a branch with no tracking configured, since `@{upstream}` fails
/// to resolve in either case.
pub fn unpushed(alloc: std.mem.Allocator, repo: []const u8) !Unpushed {
    const res = try runRead(alloc, &.{ "git", "rev-list", "@{upstream}..HEAD" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) return .no_upstream;
    return if (res.stdout.len == 0) .clean else .ahead;
}

/// The current branch name, or null on a detached HEAD. Caller owns the
/// returned memory.
pub fn currentBranch(alloc: std.mem.Allocator, repo: []const u8) !?[]u8 {
    const res = try runRead(alloc, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) return null;

    const trimmed = std.mem.trim(u8, res.stdout, "\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "HEAD")) return null;
    return try alloc.dupe(u8, trimmed);
}

pub const RepoStatus = struct { branch: ?[]u8, dirty: bool, unpushed: Unpushed };

/// Branch, working-tree dirtiness, and ahead-of-upstream from a SINGLE `git
/// status --porcelain=v2 --branch` - the three facts `status` needs in one
/// subprocess instead of `currentBranch`+`isDirty`+`unpushed` (three).
/// Ceiling-pinned like `inspectable` so it never resolves a parent repo.
/// Returns `error.NotInspectable` on a nonzero git exit (corrupt/non-repo) so
/// the caller maps it to unreadable, preserving corrupted-repo detection.
pub fn repoStatus(alloc: std.mem.Allocator, repo: []const u8) !RepoStatus {
    var map = try ceilingEnviron(alloc, repo);
    defer map.deinit();

    const res = try runEnv(alloc, &.{ "git", "-C", repo, "status", "--porcelain=v2", "--branch" }, null, &map);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) return error.NotInspectable;
    return parseStatusV2(alloc, res.stdout);
}

/// `repoStatus`'s reading of `git status --porcelain=v2 --branch` output.
/// Header lines and ignored entries (`!`, which only `--ignored` lists)
/// never make the tree dirty; every other entry does.
fn parseStatusV2(alloc: std.mem.Allocator, out: []const u8) !RepoStatus {
    var branch: ?[]u8 = null;
    var dirty = false;
    var unpushed_state: Unpushed = .no_upstream;

    var unborn = false;

    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "# branch.oid ")) {
            const oid = line["# branch.oid ".len..];
            if (std.mem.eql(u8, oid, "(initial)")) unborn = true;
        } else if (std.mem.startsWith(u8, line, "# branch.head ")) {
            const name = line["# branch.head ".len..];
            if (!std.mem.eql(u8, name, "(detached)")) branch = try alloc.dupe(u8, name);
        } else if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            const rest = line["# branch.ab ".len..];
            const ahead_str = rest[1 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
            const ahead = std.fmt.parseInt(u64, ahead_str, 10) catch 0;
            unpushed_state = if (ahead > 0) .ahead else .clean;
        } else if (!std.mem.startsWith(u8, line, "# ") and line.len > 0 and line[0] != '!') {
            dirty = true;
        }
    }

    // An unborn HEAD (no commits yet) still reports `# branch.head <name>`,
    // but the old `currentBranch` (`git rev-parse --abbrev-ref HEAD`) exits
    // nonzero with nothing to resolve and returns null - match that here
    // regardless of header order.
    if (unborn) {
        if (branch) |b| alloc.free(b);
        branch = null;
    }

    return .{ .branch = branch, .dirty = dirty, .unpushed = unpushed_state };
}

const testutil = @import("testutil.zig");

test "parseStatusV2: an ignored entry is not dirty; an untracked one is" {
    const clean = try parseStatusV2(testing.allocator, "# branch.oid abc\n# branch.head main\n! .env\n! node_modules/\n");
    defer if (clean.branch) |b| testing.allocator.free(b);
    try testing.expect(!clean.dirty);
    const dirty = try parseStatusV2(testing.allocator, "# branch.head main\n! .env\n? notes.txt\n");
    defer if (dirty.branch) |b| testing.allocator.free(b);
    try testing.expect(dirty.dirty);
}

test "clone: populates dest from a makeBareRepo bare, checked out on main" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const dest = try std.fs.path.join(testing.allocator, &.{ sb.root, "cloned" });
    defer testing.allocator.free(dest);

    try clone(testing.allocator, bare, dest, .allow, null);

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
    const url = "https://holt-test.invalid/acme/widget";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const override = try testutil.gitUnreachable(arena_state.allocator(), sb.root, &.{url});
    defer override.restore();
    try testing.expectError(error.GitCloneFailed, clone(testing.allocator, url, dest, .allow, &cd));
    defer testing.allocator.free(cd.message);
    try testing.expect(std.mem.indexOf(u8, cd.message, url) != null);
}

test "clone: a url beginning with `-` is the repository git clones, not an option it parses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    // git resolves an `insteadOf` rewrite only for a url-shaped string, so the
    // fake url carries a scheme separator behind its leading `-`. Read as an
    // option instead, it is an unknown switch and the clone cannot happen.
    const url = "-dashy://holt-test.invalid/acme/widget";
    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const dest = try std.fs.path.join(arena, &.{ sb.root, "cloned" });
    try clone(arena, url, dest, .allow, null);

    const branch = try currentBranch(arena, dest);
    try testing.expect(branch != null);
    try testing.expectEqualStrings("main", branch.?);
}

test "worktreeAdd: a branch beginning with `-` is a ref git rejects, not an option it obeys" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    const wt_path = try std.fs.path.join(testing.allocator, &.{ sb.root, "wt" });
    defer testing.allocator.free(wt_path);

    // Read as an option, "--detach" would quietly produce a detached worktree.
    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(
        error.WorktreeAddFailed,
        worktreeAdd(testing.allocator, work, wt_path, "--detach", &d),
    );
    defer testing.allocator.free(d.message);
    try testing.expect(!fsutil.exists(wt_path));
}

test "worktreeAdd: a backslashed path is slashed for git without leaking the copy" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    // A `\` in the path makes forwardSlashed copy on every platform, so the
    // testing allocator bounds the copy's lifetime here, not only in Windows
    // CI where every absolute path carries one.
    const wt_path = try std.fs.path.join(testing.allocator, &.{ sb.root, "wt\\sub" });
    defer testing.allocator.free(wt_path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(
        error.WorktreeAddFailed,
        worktreeAdd(testing.allocator, work, wt_path, "--detach", &d),
    );
    defer testing.allocator.free(d.message);
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

test "runInRepo: `git log -1 --format=%ct` on a real repo matches a plain `git log` run" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    const want = try run(testing.allocator, &.{ "git", "log", "-1", "--format=%ct" }, work);
    defer testing.allocator.free(want.stdout);
    defer testing.allocator.free(want.stderr);
    try testing.expectEqual(@as(u8, 0), want.status);

    const got = try runInRepo(testing.allocator, &.{ "log", "-1", "--format=%ct" }, work);
    defer testing.allocator.free(got.stdout);
    defer testing.allocator.free(got.stderr);
    try testing.expectEqual(@as(u8, 0), got.status);
    try testing.expectEqualStrings(want.stdout, got.stdout);
}

test "runInRepo: never resolves a parent repo above a non-repo subdirectory" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    // `sb.root` itself is a git repo with a commit (`makeBareRepo`'s seed
    // clone lands there too, but a fresh init at the root is more direct).
    try testutil.runGit(&sb, null, &.{ "init", "-q", sb.root });
    try testutil.runGit(&sb, sb.root, &.{ "commit", "--allow-empty", "-m", "parent commit" });

    const sub = try std.fs.path.join(testing.allocator, &.{ sb.root, "sub" });
    defer testing.allocator.free(sub);
    try fsutil.ensureDir(sub);

    const got = try runInRepo(testing.allocator, &.{ "log", "-1", "--format=%ct" }, sub);
    defer testing.allocator.free(got.stdout);
    defer testing.allocator.free(got.stderr);
    try testing.expect(got.status != 0);
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

test "isDirty: an untracked file counts even when status.showUntrackedFiles is no" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try testutil.runGit(&sb, work, &.{ "config", "status.showUntrackedFiles", "no" });
    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });

    try testing.expect(try isDirty(testing.allocator, work));
}

test "worktreeLocked: true only for the working tree git records as locked" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wt = try std.fs.path.join(arena, &.{ sb.root, "wt" });
    const git_wt = try fsutil.forwardSlashed(arena, wt);
    try testutil.runGit(&sb, work, &.{ "worktree", "add", "-q", "-b", "feature", git_wt });

    try testing.expect(!(try worktreeLocked(testing.allocator, work, wt)));
    try testutil.runGit(&sb, work, &.{ "worktree", "lock", "--reason", "on a removable disk", git_wt });
    try testing.expect(try worktreeLocked(testing.allocator, work, wt));
    try testing.expect(!(try worktreeLocked(testing.allocator, work, work)));
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

/// Asserts `repoStatus(repo)` agrees, field for field, with what the three
/// helpers it replaces (`currentBranch`+`isDirty`+`unpushed`) report for the
/// same repo - the byte-identical proof the collapse-to-one-call rewrite
/// depends on.
fn expectRepoStatusMatchesHelperTrio(alloc: std.mem.Allocator, repo: []const u8) !void {
    const want_branch = try currentBranch(alloc, repo);
    defer if (want_branch) |b| alloc.free(b);
    const want_dirty = try isDirty(alloc, repo);
    const want_unpushed = try unpushed(alloc, repo);

    const got = try repoStatus(alloc, repo);
    defer if (got.branch) |b| alloc.free(b);

    if (want_branch) |wb| {
        try testing.expect(got.branch != null);
        try testing.expectEqualStrings(wb, got.branch.?);
    } else {
        try testing.expect(got.branch == null);
    }
    try testing.expectEqual(want_dirty, got.dirty);
    try testing.expectEqual(want_unpushed, got.unpushed);
}

test "repoStatus: matches currentBranch+isDirty+unpushed on a clean fresh clone" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try expectRepoStatusMatchesHelperTrio(testing.allocator, work);

    const got = try repoStatus(testing.allocator, work);
    defer if (got.branch) |b| testing.allocator.free(b);
    try testing.expectEqualStrings("main", got.branch.?);
    try testing.expect(!got.dirty);
    try testing.expectEqual(Unpushed.clean, got.unpushed);
}

test "repoStatus: matches the trio once an untracked file makes the tree dirty" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });

    try expectRepoStatusMatchesHelperTrio(testing.allocator, work);

    const got = try repoStatus(testing.allocator, work);
    defer if (got.branch) |b| testing.allocator.free(b);
    try testing.expect(got.dirty);
}

test "repoStatus: matches the trio once a local commit is ahead of upstream" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "changed\n" });
    try testutil.runGit(&sb, work, &.{ "commit", "-am", "local change" });

    try expectRepoStatusMatchesHelperTrio(testing.allocator, work);

    const got = try repoStatus(testing.allocator, work);
    defer if (got.branch) |b| testing.allocator.free(b);
    try testing.expectEqual(Unpushed.ahead, got.unpushed);
}

test "repoStatus: matches the trio on a detached HEAD (branch null, no_upstream)" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try testutil.runGit(&sb, work, &.{ "checkout", "--detach", "HEAD" });

    try expectRepoStatusMatchesHelperTrio(testing.allocator, work);

    const got = try repoStatus(testing.allocator, work);
    defer if (got.branch) |b| testing.allocator.free(b);
    try testing.expect(got.branch == null);
    try testing.expectEqual(Unpushed.no_upstream, got.unpushed);
}

test "repoStatus: matches currentBranch (both null) on an unborn HEAD (empty clone, no commits)" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try std.fs.path.join(testing.allocator, &.{ sb.root, "empty-origin.git" });
    defer testing.allocator.free(bare);
    try testutil.runGit(&sb, null, &.{ "init", "--bare", bare });

    const work = try std.fs.path.join(testing.allocator, &.{ sb.root, "unborn-clone" });
    defer testing.allocator.free(work);
    try testutil.runGit(&sb, null, &.{ "clone", bare, work });

    try expectRepoStatusMatchesHelperTrio(testing.allocator, work);

    const got = try repoStatus(testing.allocator, work);
    defer if (got.branch) |b| testing.allocator.free(b);
    try testing.expect(got.branch == null);
}

test "repoStatus: errors on a corrupted .git, so the caller can map it to unreadable" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    const head_path = try std.fs.path.join(testing.allocator, &.{ work, ".git", "HEAD" });
    defer testing.allocator.free(head_path);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = head_path, .data = "garbage, not a ref\n" });

    try testing.expectError(error.NotInspectable, repoStatus(testing.allocator, work));
}

test "runInRepoScoped: git sees no variable that points it at another repository, adds configuration, or changes how pathspecs match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try testutil.runGit(&sb, work, &.{ "config", "alias.holt-env", "!env" });

    const set = [_][2][]const u8{
        .{ "GIT_DIR", "/elsewhere/.git" },
        .{ "GIT_CONFIG_PARAMETERS", "'core.worktree'='/elsewhere'" },
        .{ "GIT_CONFIG_COUNT", "2" },
        .{ "GIT_CONFIG_KEY_0", "core.worktree" },
        .{ "GIT_CONFIG_VALUE_0", "/elsewhere" },
        .{ "GIT_CONFIG_KEY_1", "core.ignorecase" },
        .{ "GIT_CONFIG_VALUE_1", "true" },
        .{ "GIT_GLOB_PATHSPECS", "1" },
        .{ "GIT_NOGLOB_PATHSPECS", "1" },
        .{ "GIT_ICASE_PATHSPECS", "1" },
        .{ "GIT_LITERAL_PATHSPECS", "1" },
    };
    var overrides: [set.len]testutil.EnvOverride = undefined;
    for (set, &overrides) |p, *o| o.* = try testutil.EnvOverride.install(a, p[0], p[1]);
    defer {
        var i = overrides.len;
        while (i > 0) {
            i -= 1;
            overrides[i].restore();
        }
    }

    const res = try runInRepoScoped(a, &.{ "-c", "alias.holt-env=!env", "holt-env" }, work);
    try testing.expectEqual(@as(u8, 0), res.status);
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |line| {
        for (set) |p| {
            if (std.mem.eql(u8, p[0], "GIT_CONFIG_PARAMETERS")) {
                if (std.mem.startsWith(u8, line, "GIT_CONFIG_PARAMETERS=")) try testing.expect(std.mem.indexOf(u8, line, "elsewhere") == null);
                continue;
            }
            try testing.expect(!(std.mem.startsWith(u8, line, p[0]) and line.len > p[0].len and line[p[0].len] == '='));
        }
    }
}

test "the git commands holt runs only to read never fetch a missing object, read each object as stored, and never prompt: GIT_NO_LAZY_FETCH, GIT_NO_REPLACE_OBJECTS, and GIT_TERMINAL_PROMPT=0 are set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    const env_alias: []const []const u8 = &.{ "-c", "alias.holt-env=!env", "holt-env" };
    const runs = [_]proc.RunResult{
        try runInRepoScoped(a, env_alias, work),
        try runInRepo(a, env_alias, work),
        try runRead(a, try std.mem.concat(a, []const u8, &.{ &.{ "git", "-C", work }, env_alias }), null),
    };
    for (runs) |res| {
        try testing.expectEqual(@as(u8, 0), res.status);
        for ([_][]const u8{ "GIT_NO_LAZY_FETCH=1\n", "GIT_NO_REPLACE_OBJECTS=1\n", "GIT_TERMINAL_PROMPT=0\n" }) |line| {
            try testing.expect(std.mem.indexOf(u8, res.stdout, try std.mem.concat(a, u8, &.{ "\n", line })) != null or std.mem.startsWith(u8, res.stdout, line));
        }
    }
}
