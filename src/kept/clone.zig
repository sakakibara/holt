//! What the kept store needs to know about a clone and its working trees,
//! read from git: the key a clone files under, its root commits, the
//! working trees sharing it, which paths are tracked, and the sparse cone.
//! Also the per-clone `pending` record of interrupted writes.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("json");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const env_path = @import("env").path;
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const block = @import("block.zig");
const machine = @import("machine.zig");
const testing = std.testing;

pub const Clone = struct {
    /// The top of the working tree that was inspected.
    worktree: []const u8,
    git_dir: []const u8,
    /// `$GIT_COMMON_DIR`, shared by every working tree of the clone.
    common_dir: []const u8,
    /// Which working tree this is: its `$GIT_DIR` relative to the common
    /// directory, `/`-joined (`.` for the main one, `worktrees/<id>` for a
    /// linked one), so it survives the clone moving.
    tree: []const u8,
    /// The main working tree, whose place under `code_root` is the key: the
    /// directory holding the common directory.
    main: []const u8,
    /// The top of the main working tree as git finds it: `main`, unless
    /// `core.worktree` names another directory.
    main_toplevel: []const u8,
    /// The clone's key, or null when its main working tree is not under
    /// `code_root`, or git finds its files in another directory than
    /// `main` (`worktreeElsewhere`), which would file them under a key
    /// that is not theirs.
    key: ?[]const u8,

    /// Whether git finds the main working tree's files in another directory
    /// than the one holding the common directory.
    pub fn worktreeElsewhere(c: Clone) bool {
        return !std.mem.eql(u8, c.main_toplevel, c.main);
    }
};

/// Runs `git <args>` in `repo` as every kept-files query does: with the
/// user's own configuration, and never reading another repository or index
/// that the environment names (`git.runInRepoScoped`).
fn gitIn(alloc: std.mem.Allocator, args: []const []const u8, repo: []const u8) !git.RunResult {
    return git.runInRepoScoped(alloc, args, repo);
}

/// The oldest git kept files work with: before 2.32, `git ls-files
/// --others --ignored --directory` leaves out an ignored file inside an
/// untracked directory, so what the block hides would go unlisted.
pub const min_git = [2]u32{ 2, 32 };

const GitCheck = struct {
    lock: std.atomic.Mutex = .unlocked,
    done: bool = false,
    ok: bool = false,
    found: [64]u8 = undefined,
    found_len: usize = 0,
};

var git_check: GitCheck = .{};

/// `GitTooOld` unless the git on PATH is `min_git` or newer. git is asked
/// (`git --version`) once per process; `gitTooOld` says what it reported.
pub fn requireGit(alloc: std.mem.Allocator) !void {
    if (builtin.is_test and waive_git_check_for_test) return;
    while (!git_check.lock.tryLock()) std.atomic.spinLoopHint();
    const done = git_check.done;
    const ok = git_check.ok;
    git_check.lock.unlock();
    if (!done) {
        const res = try git.run(alloc, &.{ "git", "--version" }, null);
        const v = parseGitVersion(res.stdout);
        while (!git_check.lock.tryLock()) std.atomic.spinLoopHint();
        defer git_check.lock.unlock();
        git_check.ok = res.status == 0 and v.ok;
        const found = if (res.status == 0) v.found else "no version";
        git_check.found_len = @min(found.len, git_check.found.len);
        @memcpy(git_check.found[0..git_check.found_len], found[0..git_check.found_len]);
        git_check.done = true;
        if (!git_check.ok) return error.GitTooOld;
        return;
    }
    if (!ok) return error.GitTooOld;
}

/// What to tell the user after `requireGit` refused.
pub fn gitTooOld(alloc: std.mem.Allocator) ![]const u8 {
    while (!git_check.lock.tryLock()) std.atomic.spinLoopHint();
    defer git_check.lock.unlock();
    return std.fmt.allocPrint(alloc, "kept files need git {d}.{d} or newer (found {s})", .{ min_git[0], min_git[1], git_check.found[0..git_check.found_len] });
}

/// Test seam: `requireGit` asks git again on its next call.
pub fn forgetGitForTest() void {
    while (!git_check.lock.tryLock()) std.atomic.spinLoopHint();
    defer git_check.lock.unlock();
    git_check.done = false;
}

/// Test seam: `requireGit` accepts any git, so a test can show what an older
/// one would list.
pub var waive_git_check_for_test = false;

/// The version `git --version` printed, and whether it is `min_git` or
/// newer. Output that names no version is too old.
fn parseGitVersion(out: []const u8) struct { ok: bool, found: []const u8 } {
    const line = std.mem.trim(u8, out, " \t\r\n");
    const prefix = "git version ";
    if (!std.mem.startsWith(u8, line, prefix)) return .{ .ok = false, .found = if (line.len == 0) "no version" else line };
    const rest = line[prefix.len..];
    const found = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
    var it = std.mem.splitScalar(u8, found, '.');
    const major = std.fmt.parseInt(u32, it.next() orelse "", 10) catch return .{ .ok = false, .found = found };
    const minor = std.fmt.parseInt(u32, it.next() orelse "", 10) catch return .{ .ok = false, .found = found };
    return .{ .ok = major > min_git[0] or (major == min_git[0] and minor >= min_git[1]), .found = found };
}

fn lines(alloc: std.mem.Allocator, out: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |l| {
        const t = std.mem.trimEnd(u8, l, "\r");
        if (t.len > 0) try list.append(alloc, t);
    }
    return list.items;
}

fn nativePath(alloc: std.mem.Allocator, p: []const u8) ![]const u8 {
    return fsutil.realPathOrSelf(alloc, try std.fs.path.resolve(alloc, &.{p}));
}

/// Reads the working tree containing `path`.
pub fn inspect(alloc: std.mem.Allocator, path: []const u8, code_root: []const u8) !Clone {
    const res = try gitIn(alloc, &.{ "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir" }, path);
    if (res.status != 0) return error.NotAClone;
    const ls = try lines(alloc, res.stdout);
    if (ls.len != 3) return error.NotAClone;
    const worktree = try nativePath(alloc, ls[0]);
    const git_dir = try nativePath(alloc, ls[1]);
    const common_dir = try nativePath(alloc, ls[2]);
    const main = std.fs.path.dirname(common_dir) orelse common_dir;
    const is_dotgit = std.mem.eql(u8, std.fs.path.basename(common_dir), ".git");
    const tree = try treeName(alloc, git_dir, common_dir);
    const main_toplevel = if (std.mem.eql(u8, tree, ".")) worktree else try toplevelOf(alloc, main);
    const c: Clone = .{
        .worktree = worktree,
        .git_dir = git_dir,
        .common_dir = common_dir,
        .tree = tree,
        .main = main,
        .main_toplevel = main_toplevel,
        .key = null,
    };
    if (!is_dotgit or c.worktreeElsewhere()) return c;
    var keyed = c;
    keyed.key = try keyFor(alloc, main, code_root);
    return keyed;
}

/// The nearest directory at or above `dir` that holds a `.git` entry: the
/// top of the working tree containing `dir`, which `inspect` must be given,
/// since git is never let to search above a path's own parent. Null when
/// there is none.
pub fn enclosing(alloc: std.mem.Allocator, dir: []const u8) !?[]const u8 {
    var at: ?[]const u8 = dir;
    while (at) |d| : (at = std.fs.path.dirname(d)) {
        if (try content.entryAt(d) != .dir) continue;
        if (try content.entryAt(try std.fs.path.join(alloc, &.{ d, ".git" })) != .absent) return d;
    }
    return null;
}

/// The top of the working tree git finds from `dir`, or `dir` itself when
/// git finds none there (a bare repository).
fn toplevelOf(alloc: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const res = try gitIn(alloc, &.{ "rev-parse", "--path-format=absolute", "--show-toplevel" }, dir);
    if (res.status != 0) return dir;
    const ls = try lines(alloc, res.stdout);
    if (ls.len != 1) return dir;
    return nativePath(alloc, ls[0]);
}

/// `git_dir` named relative to `common_dir`, `/`-joined: `.` when they are
/// one directory; `git_dir` itself when it lies elsewhere.
fn treeName(alloc: std.mem.Allocator, git_dir: []const u8, common_dir: []const u8) ![]const u8 {
    if (std.mem.eql(u8, git_dir, common_dir)) return ".";
    if (!fsutil.pathIsInside(git_dir, common_dir)) return git_dir;
    const rel = try alloc.dupe(u8, git_dir[common_dir.len + 1 ..]);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
    return rel;
}

/// The key of the main working tree at `main`: its `/`-joined path under
/// `code_root`, or null when it is not under it.
fn keyFor(alloc: std.mem.Allocator, main: []const u8, code_root: []const u8) !?[]const u8 {
    const root = try fsutil.realPathOrSelf(alloc, code_root);
    const rel = (try env_path.relUnder(alloc, root, try fsutil.realPathOrSelf(alloc, main))) orelse return null;
    return if (store.validKey(rel)) rel else null;
}

/// Why a working tree git records for the clone cannot be swept, each for
/// that one working tree or record alone.
pub const TreeProblem = enum {
    /// Nothing is where git records the working tree: it was moved or
    /// removed, or it is on a volume that is not mounted.
    absent,
    /// Something is there, but it cannot be opened as a directory.
    unreadable,
    /// The directory holds no `.git`, so git no longer finds it as this
    /// clone's working tree.
    not_linked,
    /// git's record of where the working tree is (`worktrees/<id>/gitdir`
    /// in the common directory) cannot be read.
    record_unreadable,
    /// The record names the working tree in the other side of WSL's form
    /// (a `C:/` path read on Linux, a `/` path read on Windows), so it
    /// cannot be found from here; the path is the record's text. Settled by
    /// running holt on that side.
    other_side,
    /// A repository that is not this working tree of the clone is at the
    /// recorded path: git there finds another common directory, or another
    /// record's working tree, or cannot open the `.git` there at all.
    foreign_repository,
};

pub const Worktree = struct {
    /// Where the working tree is; for one whose record cannot be read, the
    /// record's directory.
    path: []const u8,
    /// Why the working tree cannot be swept, or null when it can.
    problem: ?TreeProblem = null,
    /// False for the working tree `worktrees` was asked about when git
    /// records it under no path of its own (a copy of a linked working
    /// tree, or one moved with plain `mv`); it is swept all the same.
    recorded: bool = true,
    /// For an unrecorded working tree, the path git's record for it holds,
    /// which it shares; null when git records it nowhere.
    shares: ?[]const u8 = null,

    pub fn readable(w: Worktree) bool {
        return w.problem == null;
    }
};

/// Every working tree of the clone, read from the common directory itself,
/// since `git worktree list` cannot print every path (one holding a
/// newline): the main one first (none for a bare repository), then each
/// linked one in order of its record's name, where its record
/// `worktrees/<id>/gitdir` says, and last `c.worktree` itself when no
/// working tree before it is at that path (`Worktree.recorded`). An entry
/// of `worktrees/` that is not a directory, or a directory holding no
/// `gitdir` (`halfCreated`), names no working tree and is left out, as git
/// leaves it out. Whether the repository is bare is asked of git only
/// from a linked working tree: git found `c` as the main one, so it is not.
/// `WorktreeListFailed` when the records, or whether the repository is
/// bare, cannot be read.
///
/// Limits: a checkout git records nowhere (one made with
/// `--separate-git-dir` into the clone's `.git`, or a copy of the main
/// working tree's files without its `.git`) is found only when it is
/// `c.worktree`, so what the block hides there is swept only while holt
/// runs in it.
pub fn worktrees(alloc: std.mem.Allocator, c: Clone) ![]const Worktree {
    var out: std.ArrayList(Worktree) = .empty;
    var own: ?Worktree = null;
    const is_bare = if (std.mem.eql(u8, c.tree, ".")) false else blk: {
        const bare = try gitIn(alloc, &.{ "config", "--bool", "core.bare" }, c.common_dir);
        if (bare.status > 1) return error.WorktreeListFailed;
        break :blk bare.status == 0 and std.mem.startsWith(u8, bare.stdout, "true");
    };
    if (!is_bare) {
        try out.append(alloc, try treeAt(alloc, c.main_toplevel, null));
        if (std.mem.eql(u8, c.tree, ".")) own = out.items[0];
    }

    const records = try std.fs.path.join(alloc, &.{ c.common_dir, "worktrees" });
    for (try recordDirs(alloc, records)) |id| {
        const record = try std.fs.path.join(alloc, &.{ records, id });
        const t: Worktree = if (recordedPath(alloc, record)) |at| blk: {
            if (otherSide(at)) break :blk .{ .path = at, .problem = .other_side };
            break :blk try treeAt(alloc, if (std.fs.path.isAbsolute(at)) at else try std.fs.path.join(alloc, &.{ record, at }), .{ .common_dir = c.common_dir, .record = record });
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            error.FileNotFound => continue,
            else => .{ .path = record, .problem = .record_unreadable },
        };
        try out.append(alloc, t);
        if (std.mem.eql(u8, c.tree, try std.mem.concat(alloc, u8, &.{ "worktrees/", id }))) own = t;
    }
    for (out.items) |t| if (std.mem.eql(u8, t.path, c.worktree)) return out.items;
    const shares: ?[]const u8 = if (own) |o| (if (o.problem == .record_unreadable) null else o.path) else null;
    try out.append(alloc, .{ .path = c.worktree, .recorded = false, .shares = shares });
    return out.items;
}

/// A record of a linked working tree, `<common>/worktrees/<id>`, and where
/// the working tree is, as its `gitdir` names it (read as `worktrees` reads
/// it), a relative path resolved against the record; null when its
/// `gitdir` cannot be read.
pub const Record = struct { record: []const u8, path: ?[]const u8 };

/// The records of the linked working trees the common directory
/// `common_dir` holds, in order of their names; a record holding no
/// `gitdir` names none and is left out. `WorktreeListFailed` when the
/// records cannot be read.
pub fn linkedRecords(alloc: std.mem.Allocator, common_dir: []const u8) ![]const Record {
    const records = try std.fs.path.join(alloc, &.{ common_dir, "worktrees" });
    var out: std.ArrayList(Record) = .empty;
    for (try recordDirs(alloc, records)) |id| {
        const record = try std.fs.path.join(alloc, &.{ records, id });
        const at = recordedTree(alloc, record, record) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.FileNotFound => continue,
            else => {
                try out.append(alloc, .{ .record = record, .path = null });
                continue;
            },
        };
        try out.append(alloc, .{ .record = record, .path = at });
    }
    return out.items;
}

/// A directory of a common directory's `worktrees/` that git's worktree
/// list leaves out, and why: it holds no `gitdir`, or one that cannot be
/// read as a path.
pub const Unlisted = struct { record: []const u8, why: enum { no_gitdir, unreadable } };

/// The records of the common directory `common_dir` that git's worktree
/// list leaves out (`Unlisted`), in order of their names; those
/// `linkedRecords` leaves out or gives no path. `WorktreeListFailed` when
/// the records cannot be read.
pub fn unlistedRecords(alloc: std.mem.Allocator, common_dir: []const u8) ![]const Unlisted {
    const records = try std.fs.path.join(alloc, &.{ common_dir, "worktrees" });
    var out: std.ArrayList(Unlisted) = .empty;
    for (try recordDirs(alloc, records)) |id| {
        const record = try std.fs.path.join(alloc, &.{ records, id });
        _ = recordedTree(alloc, record, record) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.FileNotFound => try out.append(alloc, .{ .record = record, .why = .no_gitdir }),
            else => try out.append(alloc, .{ .record = record, .why = .unreadable }),
        };
    }
    return out.items;
}

/// Where the `gitdir` of the record `record` names its linked working
/// tree (`recordedPath`), a relative path resolved against `base`: git
/// writes and reads one relative to the record's directory, so `base` is
/// `record` for the record as git reads it now, or where the record was
/// when it was written, for one since moved. `FileNotFound` when `record`
/// holds no `gitdir`.
pub fn recordedTree(alloc: std.mem.Allocator, record: []const u8, base: []const u8) ![]const u8 {
    const at = try recordedPath(alloc, record);
    if (std.fs.path.isAbsolute(at) or otherSide(at)) return at;
    return std.fs.path.resolve(alloc, &.{ base, at });
}

/// The directories of the common directory's `worktrees/` that hold no
/// `gitdir`: records `git worktree add` left half made, which name no
/// working tree and which removing that directory settles. Empty when the
/// records cannot be read.
pub fn halfCreated(alloc: std.mem.Allocator, c: Clone) ![]const []const u8 {
    const records = try std.fs.path.join(alloc, &.{ c.common_dir, "worktrees" });
    var out: std.ArrayList([]const u8) = .empty;
    const ids = recordDirs(alloc, records) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return out.items,
    };
    for (ids) |id| {
        const record = try std.fs.path.join(alloc, &.{ records, id });
        const e = content.entryAt(try std.fs.path.join(alloc, &.{ record, "gitdir" })) catch continue;
        if (e == .absent) try out.append(alloc, record);
    }
    return out.items;
}

/// The names of the directories in `records`, sorted; a link counts when
/// it leads to one, as git follows it. None when `records` is absent.
fn recordDirs(alloc: std.mem.Allocator, records: []const u8) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var d = std.Io.Dir.cwd().openDir(fsutil.io(), records, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return ids.items,
        else => return error.WorktreeListFailed,
    };
    defer d.close(fsutil.io());
    var it = d.iterate();
    while (it.next(fsutil.io()) catch return error.WorktreeListFailed) |e| {
        switch (e.kind) {
            .directory => {},
            .sym_link => {
                var sub = d.openDir(fsutil.io(), e.name, .{}) catch continue;
                sub.close(fsutil.io());
            },
            else => continue,
        }
        try ids.append(alloc, try alloc.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, ids.items, {}, paths.lessThan);
    return ids.items;
}

/// Where the linked working tree whose record is the directory `record`
/// is, as its `gitdir` holds it, read as git reads it: trailing whitespace
/// and a trailing `/.git` removed; relative to `record` unless absolute.
/// `FileNotFound` when `record` holds no `gitdir`.
fn recordedPath(alloc: std.mem.Allocator, record: []const u8) ![]const u8 {
    const raw = try content.readSmall(alloc, try std.fs.path.join(alloc, &.{ record, "gitdir" }));
    var p: []const u8 = std.mem.trimEnd(u8, raw, " \t\n\r\x0b\x0c");
    if (std.mem.endsWith(u8, p, "/.git")) p = p[0 .. p.len - "/.git".len];
    if (p.len == 0) return error.MalformedRecord;
    return p;
}

/// Whether the recorded path `p` has the form the other side of WSL
/// writes: a drive-letter path read outside Windows, or a `/`-rooted one
/// (not `//`, a network path) read on Windows.
fn otherSide(p: []const u8) bool {
    if (builtin.os.tag == .windows) return p.len > 0 and p[0] == '/' and !(p.len > 1 and p[1] == '/');
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '/' or p[2] == '\\');
}

/// The record of a linked working tree: the clone's common directory and
/// the record's directory, `<common>/worktrees/<id>`.
const Linked = struct { common_dir: []const u8, record: []const u8 };

/// `gitIn` as though the user owned `repo` (`-c safe.directory=*`), with
/// git's messages in English for `refusedForOwner`.
pub fn gitAsOwner(alloc: std.mem.Allocator, args: []const []const u8, repo: []const u8) !git.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ "-c", "safe.directory=*" });
    try argv.appendSlice(alloc, args);
    return git.runInRepoScopedWith(alloc, argv.items, repo, .{ .set = &.{ .{ "LC_ALL", "C" }, .{ "LANGUAGE", "C" } } });
}

/// Whether git, run by `gitAsOwner`, refused the repository for who owns
/// it: a git that reads `safe.directory` only from the user's own files,
/// or knows no `*` there, still refuses.
pub fn refusedForOwner(res: git.RunResult) bool {
    if (res.status == 0) return false;
    return std.mem.indexOf(u8, res.stderr, "dubious ownership") != null or std.mem.indexOf(u8, res.stderr, "unsafe repository") != null;
}

/// The working tree at `raw`, with the problem that keeps it from being
/// swept. A `linked` one must hold a `.git`, and git run there, looking no
/// higher, must find the clone's common directory and the record's own
/// directory as its `$GIT_DIR`. Ownership (`safe.directory`) is not
/// judged, since it says nothing of whose tree it is: where git refuses
/// the tree for its owner all the same, it is taken as recorded, and
/// listing it fails.
fn treeAt(alloc: std.mem.Allocator, raw: []const u8, linked: ?Linked) !Worktree {
    const p = try nativePath(alloc, raw);
    const e = content.entryAt(p) catch return .{ .path = p, .problem = .unreadable };
    if (e == .absent) return .{ .path = p, .problem = .absent };
    var d = std.Io.Dir.cwd().openDir(fsutil.io(), p, .{}) catch return .{ .path = p, .problem = .unreadable };
    d.close(fsutil.io());
    const l = linked orelse return .{ .path = p };
    const dot_git = content.entryAt(try std.fs.path.join(alloc, &.{ p, ".git" })) catch content.Entry.other;
    if (dot_git == .absent) return .{ .path = p, .problem = .not_linked };
    if (!try leadsBack(alloc, p, l.common_dir, l.record)) return .{ .path = p, .problem = .foreign_repository };
    return .{ .path = p };
}

/// Whether git, run at `path`, a directory holding a `.git`, looking no
/// higher, finds the common directory `common_dir` and the record `record`
/// of a linked working tree in it as its `$GIT_DIR`: false when it finds
/// another repository, or cannot open the `.git` there. Where git refuses
/// the directory for its owner (`refusedForOwner`), true, as `treeAt`
/// takes it.
pub fn leadsBack(alloc: std.mem.Allocator, path: []const u8, common_dir: []const u8, record: []const u8) !bool {
    const res = try gitAsOwner(alloc, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir" }, path);
    if (refusedForOwner(res)) return true;
    if (res.status != 0) return false;
    const ls = try lines(alloc, res.stdout);
    if (ls.len != 2) return false;
    return std.mem.eql(u8, try nativePath(alloc, ls[0]), try nativePath(alloc, common_dir)) and
        std.mem.eql(u8, try nativePath(alloc, ls[1]), try nativePath(alloc, record));
}

/// Test seam: `folding` probes at the working tree's root, as for a working
/// tree on another filesystem than its common directory.
pub var probe_at_root_for_test = false;

/// How the filesystem holding the working tree compares names, probed once
/// per filesystem for the process (`content.probeFoldingAs`): in the
/// clone's own state directory (`stateDir`) when it lies on the same
/// filesystem, otherwise at the working tree's root, under a block line
/// for as long as the probe exists. Unless `may_write`, nothing is probed
/// and nothing written: the answer is the one this process probed for the
/// filesystem already, else what the working tree's `core.ignorecase`
/// says (`ignoresCase`), for case and normalization alike. A probe that
/// fails for any reason but memory is `Folding.all`, the answer that never
/// tells two spellings apart; the result then says why.
pub fn folding(alloc: std.mem.Allocator, c: Clone, may_write: bool) !Probed {
    if (builtin.is_test) if (paths.folding_for_test) |f| return .{ .fold = f };
    const got = probeWorktree(alloc, c, may_write) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .fold = .all, .failure = err },
    };
    return .{ .fold = got };
}

/// How `folding` found the working tree compares names.
pub const Probed = struct {
    fold: paths.Folding,
    /// Why the probe failed, when it did; `fold` is then `Folding.all`.
    failure: ?anyerror = null,
};

fn probeWorktree(alloc: std.mem.Allocator, c: Clone, may_write: bool) !paths.Folding {
    const force_root = builtin.is_test and probe_at_root_for_test;
    const state = try stateDir(alloc, c.common_dir);
    const dev = try content.deviceOf(alloc, c.worktree);
    const known = if (force_root) null else content.knownFolding(dev);
    if (!may_write) {
        if (known) |f| return f;
        const ic = try ignoresCase(alloc, c.worktree);
        return .{ .case = ic, .norm = ic };
    }
    if (try content.entryAt(state) != .dir) try fsutil.ensureDir(state);
    const at_root = dev == null or dev != try content.deviceOf(alloc, state) or force_root;
    if (!at_root) return content.probeFolding(alloc, state);
    if (known) |f| return f;
    const name = try paths.probeName(alloc, content.randomSuffix());
    try block.add(alloc, c.common_dir, &.{name});
    defer block.drop(alloc, c.common_dir, name) catch {};
    const got = try content.probeFoldingAs(alloc, c.worktree, name);
    content.rememberFolding(dev, got);
    return got;
}

/// How git's HEAD or index lists a path, or for a directory a path below
/// it.
pub const Tracked = union(enum) {
    none,
    /// Listed byte for byte.
    exact,
    /// Listed only under other spellings, equal under case folding and
    /// Unicode normalization: each spelling of the path's own components
    /// (for a directory, the leading components of the paths below it).
    folded: []const []const u8,

    /// Whether the working tree's `rel` is the path git tracks: listed byte
    /// for byte, or under another spelling that names the same file on disk,
    /// as a case- or normalization-insensitive filesystem resolves it.
    /// Where the working tree's filesystem folds names at all (`fold`, from
    /// `folding`), another spelling also counts when both are absent, since
    /// nothing on disk then tells them apart; one present and the other
    /// absent are two files, since such a filesystem would find either
    /// under both spellings.
    pub fn isTracked(self: Tracked, alloc: std.mem.Allocator, worktree: []const u8, rel: []const u8, fold: paths.Folding) !bool {
        switch (self) {
            .none => return false,
            .exact => return true,
            .folded => |spellings| {
                const here = try fsutil.joinSlashy(alloc, worktree, rel);
                const here_absent = try content.entryAt(here) == .absent;
                for (spellings) |s| {
                    const there = try fsutil.joinSlashy(alloc, worktree, s);
                    if (fold.folds() and here_absent and try content.entryAt(there) == .absent) return true;
                    if (try content.sameFile(alloc, here, there)) return true;
                }
                return false;
            },
        }
    }
};

/// How the working tree's HEAD and index list each member of `rels`, in
/// order. `GitFailed` when git cannot list the index, or HEAD other than an
/// unborn one.
pub fn tracked(alloc: std.mem.Allocator, worktree: []const u8, rels: []const []const u8) ![]const Tracked {
    const out = try alloc.alloc(Tracked, rels.len);
    @memset(out, .none);
    if (rels.len == 0) return out;
    var listed: std.ArrayList([]const u8) = .empty;
    const index = try gitIn(alloc, &.{ "ls-files", "-z" }, worktree);
    if (index.status != 0) return error.GitFailed;
    try appendNul(alloc, &listed, index.stdout);
    const head = try gitIn(alloc, &.{ "ls-tree", "-r", "-z", "--name-only", "HEAD" }, worktree);
    if (head.status == 0) {
        try appendNul(alloc, &listed, head.stdout);
    } else {
        const born = try gitIn(alloc, &.{ "rev-parse", "-q", "--verify", "HEAD" }, worktree);
        if (born.status == 0) return error.GitFailed;
    }

    const keys = try alloc.alloc([]const u8, rels.len);
    for (rels, keys) |rel, *k| k.* = try paths.foldKey(alloc, rel);
    const spellings = try alloc.alloc(std.ArrayList([]const u8), rels.len);
    @memset(spellings, .empty);
    for (listed.items) |p| {
        for (rels, keys, out, spellings) |rel, k, *t, *sp| {
            if (t.* == .exact) continue;
            if (std.mem.eql(u8, p, rel) or below(p, rel)) {
                t.* = .exact;
                continue;
            }
            const lead = leading(p, std.mem.count(u8, rel, "/") + 1) orelse continue;
            const lk = paths.foldKey(alloc, lead) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            if (std.mem.eql(u8, lk, k) and !paths.contains(sp.items, lead)) try sp.append(alloc, lead);
        }
    }
    for (out, spellings) |*t, sp| {
        if (t.* == .none and sp.items.len > 0) t.* = .{ .folded = sp.items };
    }
    return out;
}

/// The first `n` components of `p`, or null when it has fewer.
pub fn leading(p: []const u8, n: usize) ?[]const u8 {
    var seen: usize = 0;
    for (p, 0..) |c, i| {
        if (c != '/') continue;
        seen += 1;
        if (seen == n) return p[0..i];
    }
    return if (seen + 1 == n) p else null;
}

fn appendNul(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), out: []const u8) !void {
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |p| if (p.len > 0) try list.append(alloc, p);
}

/// Whether git in the working tree at `worktree` matches names in any ASCII
/// case (`core.ignorecase` true, from any level of the user's
/// configuration). False when it is unset or git cannot say.
pub fn ignoresCase(alloc: std.mem.Allocator, worktree: []const u8) !bool {
    const res = try gitIn(alloc, &.{ "config", "--type=bool", "core.ignorecase" }, worktree);
    return res.status == 0 and std.mem.startsWith(u8, res.stdout, "true");
}

/// The members of `rels` git does not ignore in the working tree: the ones
/// `git ls-files --others --exclude-standard` lists, asked once for all of
/// them. When git fails, every member is returned.
pub fn notIgnored(alloc: std.mem.Allocator, worktree: []const u8, rels: []const []const u8) ![]const []const u8 {
    if (rels.len == 0) return &.{};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ "--literal-pathspecs", "ls-files", "--others", "--exclude-standard", "-z", "--" });
    try argv.appendSlice(alloc, rels);
    const res = try gitIn(alloc, argv.items, worktree);
    if (res.status != 0) return rels;
    var listed: std.ArrayList([]const u8) = .empty;
    try appendNul(alloc, &listed, res.stdout);
    var out: std.ArrayList([]const u8) = .empty;
    for (rels) |rel| if (paths.contains(listed.items, rel)) try out.append(alloc, rel);
    return out.items;
}

/// A negated gitignore line (`!<pattern>`) that makes git see a path
/// holt's block line would hide.
pub const Negation = struct {
    /// The file holding the line, absolute.
    source: []const u8,
    /// Its line number, as git prints it.
    line: []const u8,
    /// The line as the file spells it, `!` included.
    pattern: []const u8,
};

/// The negated line that decides whether git ignores `rel` of the working
/// tree of `c` (`git check-ignore -v --no-index`) when it outranks holt's
/// block: one in a `.gitignore` of the working tree, or in the clone's
/// `info/exclude` below the block, where git reads it after the block's
/// lines. A negation in any other exclude file ranks below the block. Null
/// when no such line decides; `GitFailed` when git cannot tell.
pub fn negation(alloc: std.mem.Allocator, c: Clone, rel: []const u8) !?Negation {
    const res = try gitIn(alloc, &.{ "check-ignore", "-v", "--no-index", "--", try std.mem.concat(alloc, u8, &.{ "./", rel }) }, c.worktree);
    if (res.status == 1) return null;
    if (res.status != 0) return error.GitFailed;
    const out = std.mem.trimEnd(u8, res.stdout, "\r\n");
    const tab = std.mem.lastIndexOfScalar(u8, out, '\t') orelse return error.GitFailed;
    const spec = out[0..tab];
    var at: usize = 0;
    const colon, const next = while (std.mem.indexOfScalarPos(u8, spec, at, ':')) |i| : (at = i + 1) {
        var j = i + 1;
        while (j < spec.len and std.ascii.isDigit(spec[j])) j += 1;
        if (j > i + 1 and j < spec.len and spec[j] == ':') break .{ i, j };
    } else return error.GitFailed;
    const pattern = spec[next + 1 ..];
    if (pattern.len == 0 or pattern[0] != '!') return null;
    const src = spec[0..colon];
    const native_src = try fsutil.nativeSlashed(alloc, src);
    const source = if (std.fs.path.isAbsolute(native_src)) native_src else try std.fs.path.join(alloc, &.{ c.worktree, native_src });
    const line = spec[colon + 1 .. next];
    const exclude = try block.excludePath(alloc, c.common_dir);
    if (std.mem.eql(u8, try fsutil.realPathOrSelf(alloc, source), try fsutil.realPathOrSelf(alloc, exclude))) {
        const text = content.readSmall(alloc, exclude) catch return error.GitFailed;
        const parsed = block.parse(alloc, text) catch return error.GitFailed;
        if (!parsed.present) return null;
        const after_first = std.mem.count(u8, text[0 .. text.len - parsed.after.len], "\n") + 1;
        const n = std.fmt.parseInt(usize, line, 10) catch return error.GitFailed;
        if (n < after_first) return null;
    } else if (std.fs.path.isAbsolute(src) or !std.mem.eql(u8, std.fs.path.basename(src), ".gitignore")) return null;
    return .{ .source = source, .line = try alloc.dupe(u8, line), .pattern = try alloc.dupe(u8, pattern) };
}

/// The places in the working tree that the gitignore lines `patterns` hide
/// from git and that git does not track, as `git ls-files --others
/// --ignored --directory` lists them with those lines as its only exclude
/// source, `/`-joined without a trailing `/`: a directory whose content is
/// all hidden as the directory, and inside a directory holding tracked or
/// visible content each hidden entry on its own. git runs with the user's
/// own configuration, so names match as the user's git matches them
/// (`core.ignorecase` from any level) and it lists what the user's git
/// would delete. Empty directories are listed too: with
/// `--no-empty-directory`, git leaves out a hidden file inside a directory
/// that holds nothing else, and a directory it cannot open. The lines go
/// to an `exclude-<machine>-<host>-<pid>-<hex>` file (`machine_id`,
/// `machine.hostName`, this process's id, a random suffix) in the first of
/// `dirs` that can take one, removed again on every path out. Null when no
/// directory can take the file or git fails.
pub fn blockHides(alloc: std.mem.Allocator, worktree: []const u8, dirs: []const []const u8, machine_id: []const u8, patterns: []const u8) !?[]const []const u8 {
    if (builtin.is_test) if (listing_for_test) |l| return l;
    const file = (try writeRunFile(alloc, dirs, machine_id, patterns)) orelse return null;
    defer fsutil.removePath(file) catch {};
    const res = try gitIn(alloc, &.{ "ls-files", "-z", "--others", "--ignored", try std.fmt.allocPrint(alloc, "--exclude-from={s}", .{file}), "--directory" }, worktree);
    if (res.status != 0) return null;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, res.stdout, 0);
    while (it.next()) |p| {
        const t = std.mem.trimEnd(u8, p, "/");
        if (t.len > 0) try out.append(alloc, t);
    }
    return out.items;
}

const exclude_prefix = "exclude-";

/// Writes `data` to a new file named `exclude-<machine>-<host>-<pid>-<hex>`
/// (`machine_id`, `machine.hostName`, this process's id, a random suffix)
/// in the first of `dirs` that can take one, and returns its path; null
/// when none can. The caller removes it; one an interrupted run leaves is
/// removed by `clearStaleExcludes`.
pub fn writeRunFile(alloc: std.mem.Allocator, dirs: []const []const u8, machine_id: []const u8, data: []const u8) !?[]const u8 {
    const suffix = content.randomSuffix();
    var host_buf: [machine.host_name_max]u8 = undefined;
    const name = try std.fmt.allocPrint(alloc, exclude_prefix ++ "{s}-{s}-{d}-{s}", .{ machine_id, machine.hostName(&host_buf), machine.processId(), &suffix });
    for (dirs) |d| {
        const path = try std.fs.path.join(alloc, &.{ d, name });
        std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = path, .data = data, .flags = .{ .exclusive = true } }) catch |err| {
            if (err != error.PathAlreadyExists) fsutil.removePath(path) catch {};
            continue;
        };
        return path;
    }
    return null;
}

/// Removes from `dir` each file `blockHides` names that an interrupted holt
/// left: one this machine (`machine_id`) made on this host (`host`,
/// `machine.hostName`) in a process that is no longer running, and one of
/// any machine or host last changed more than a day before `now`
/// (nanoseconds since the epoch), an `exclude-<hex>` file an older holt
/// named included. A process id is judged only on the host that made it,
/// since a container and its host number processes apart. Anything else,
/// and anything that cannot be read, stays.
pub fn clearStaleExcludes(alloc: std.mem.Allocator, dir: []const u8, machine_id: []const u8, host: []const u8, now: i96) !void {
    var d = std.Io.Dir.cwd().openDir(fsutil.io(), dir, .{ .iterate = true }) catch return;
    defer d.close(fsutil.io());
    var stale: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(fsutil.io()) catch return) |e| {
        if (e.kind != .file) continue;
        const made = excludeMaker(e.name) orelse continue;
        const st = d.statFile(fsutil.io(), e.name, .{ .follow_symlinks = false }) catch continue;
        const old = st.mtime.nanoseconds < now - std.time.ns_per_day;
        const orphaned = if (made.by) |by| std.mem.eql(u8, by.machine, machine_id) and std.mem.eql(u8, by.host, host) and !machine.processRunning(by.pid) else false;
        if (old or orphaned) try stale.append(alloc, try std.fs.path.join(alloc, &.{ dir, e.name }));
    }
    for (stale.items) |p| fsutil.removePath(p) catch {};
}

/// Who made the file `blockHides` named `name`: its machine, host, and
/// process, or none for an `exclude-<hex>` file an older holt named; null
/// for any other name.
fn excludeMaker(name: []const u8) ?struct { by: ?struct { machine: []const u8, host: []const u8, pid: u32 } } {
    if (!std.mem.startsWith(u8, name, exclude_prefix)) return null;
    const rest = name[exclude_prefix.len..];
    if (machine.valid(rest)) return .{ .by = null };
    var it = std.mem.splitScalar(u8, rest, '-');
    const m = it.next() orelse return null;
    const host = it.next() orelse return null;
    const pid_text = it.next() orelse return null;
    const suffix = it.next() orelse return null;
    if (it.next() != null or !machine.valid(m) or !machine.validHost(host) or !machine.valid(suffix)) return null;
    for (pid_text) |c| if (c < '0' or c > '9') return null;
    const pid = std.fmt.parseInt(u32, pid_text, 10) catch return null;
    return .{ .by = .{ .machine = m, .host = host, .pid = pid } };
}

/// Test seam: what `blockHides` lists, whatever is on disk, as an older git
/// that leaves places out.
pub var listing_for_test: ?[]const []const u8 = null;

/// Every root commit reachable from any ref but a replace ref, each commit
/// read as stored rather than as a replace ref stands in for it, so a
/// replace ref changes no root.
pub fn rootCommits(alloc: std.mem.Allocator, repo: []const u8) ![]const []const u8 {
    const res = try gitIn(alloc, &.{ "rev-list", "--max-parents=0", "--exclude=refs/replace/*", "--all" }, repo);
    if (res.status != 0) return error.GitFailed;
    return lines(alloc, res.stdout);
}

/// The smallest root commit of the default branch (`origin/HEAD` when set,
/// else the main working tree's HEAD), each commit read as stored rather
/// than as a replace ref stands in for it, or null for a shallow clone or
/// one with no commit.
pub fn defaultRoot(alloc: std.mem.Allocator, main: []const u8) !?[]const u8 {
    const shallow = try gitIn(alloc, &.{ "rev-parse", "--is-shallow-repository" }, main);
    if (shallow.status != 0 or std.mem.startsWith(u8, shallow.stdout, "true")) return null;
    const origin_head = try gitIn(alloc, &.{ "rev-parse", "-q", "--verify", "refs/remotes/origin/HEAD" }, main);
    const ref: []const u8 = if (origin_head.status == 0) "refs/remotes/origin/HEAD" else "HEAD";
    const res = try gitIn(alloc, &.{ "rev-list", "--max-parents=0", ref, "--" }, main);
    if (res.status != 0) return null;
    var best: ?[]const u8 = null;
    for (try lines(alloc, res.stdout)) |l| {
        if (best == null or std.mem.order(u8, l, best.?) == .lt) best = l;
    }
    return best;
}

/// The origin URL with any `userinfo@` removed from a `scheme://` URL, or
/// null when the clone has no origin.
pub fn originUrl(alloc: std.mem.Allocator, repo: []const u8) !?[]const u8 {
    const res = try gitIn(alloc, &.{ "config", "--get", "remote.origin.url" }, repo);
    if (res.status != 0) return null;
    const url = std.mem.trim(u8, res.stdout, "\r\n");
    if (url.len == 0) return null;
    return try stripUserinfo(alloc, url);
}

pub fn stripUserinfo(alloc: std.mem.Allocator, url: []const u8) ![]const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return url;
    const auth_start = sep + 3;
    const auth_end = std.mem.indexOfScalarPos(u8, url, auth_start, '/') orelse url.len;
    const at = std.mem.lastIndexOfScalar(u8, url[auth_start..auth_end], '@') orelse return url;
    return std.mem.concat(alloc, u8, &.{ url[0..auth_start], url[auth_start + at + 1 ..] });
}

pub const Sparse = struct {
    mode: enum {
        /// Not a sparse checkout.
        off,
        /// Cone mode, with its directories in `dirs`.
        cone,
        /// Any other sparse checkout: patterns holt does not evaluate.
        patterns,
    } = .off,
    dirs: []const []const u8 = &.{},

    /// False for a path the sparse checkout of `worktree` leaves out. In
    /// cone mode that is a directory neither in, under, nor above a listed
    /// one, or a file whose directory is none of those. With other patterns
    /// it is a path whose parent directory git has not materialized, since
    /// git creates the directories of every path it includes.
    pub fn includes(self: Sparse, alloc: std.mem.Allocator, worktree: []const u8, rel: []const u8, kind: content.Kind) !bool {
        switch (self.mode) {
            .off => return true,
            .patterns => {
                const parent = std.fs.path.dirnamePosix(rel) orelse return true;
                return try content.entryAt(try fsutil.joinSlashy(alloc, worktree, parent)) == .dir;
            },
            .cone => {},
        }
        const target = if (kind == .dir) rel else (std.fs.path.dirnamePosix(rel) orelse return true);
        for (self.dirs) |d| {
            if (std.mem.eql(u8, d, target)) return true;
            if (below(target, d) or below(d, target)) return true;
        }
        return false;
    }
};

fn below(child: []const u8, parent: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

/// The working tree's sparse checkout. Only an explicit
/// `core.sparseCheckoutCone=true` whose directories git lists is cone mode;
/// any other sparse checkout, or one git cannot describe, is judged by its
/// materialized directories.
pub fn sparse(alloc: std.mem.Allocator, worktree: []const u8) !Sparse {
    const on = try gitIn(alloc, &.{ "config", "--bool", "core.sparseCheckout" }, worktree);
    if (on.status == 1) return .{};
    if (on.status == 0 and !std.mem.startsWith(u8, on.stdout, "true")) return .{};
    const cone = try gitIn(alloc, &.{ "config", "--bool", "core.sparseCheckoutCone" }, worktree);
    if (on.status != 0 or cone.status != 0 or !std.mem.startsWith(u8, cone.stdout, "true")) return .{ .mode = .patterns };
    const list = try gitIn(alloc, &.{ "sparse-checkout", "list" }, worktree);
    if (list.status != 0) return .{ .mode = .patterns };
    return .{ .mode = .cone, .dirs = try lines(alloc, list.stdout) };
}

pub const Op = enum {
    keep,
    take_local,
    take_kept,
    take_aside,
    /// Reconcile replacing local content identical to the kept copy with
    /// the link.
    relink,
    /// Reconcile replacing a released path's link with a regular copy.
    release,
};

/// A write of `rel` in the working tree `tree` (`Clone.tree`) that has not
/// finished: the command that started it, the aside entry it works from,
/// and where the working tree was (`Clone.worktree`), so a temporary it
/// left can still be found once git no longer lists the tree. Only that
/// working tree settles or clears it, while git lists it.
pub const Pending = struct { tree: []const u8, rel: []const u8, op: Op, entry: ?[]const u8 = null, worktree: ?[]const u8 = null };

/// The clone's own holt state, `$GIT_COMMON_DIR/holt`.
pub fn stateDir(alloc: std.mem.Allocator, common_dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ common_dir, "holt" });
}

fn pendingPath(alloc: std.mem.Allocator, common_dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ try stateDir(alloc, common_dir), "pending" });
}

/// Every pending record of the clone. A line that does not read as one is
/// `MalformedPending`, so no interrupted write is ever forgotten.
pub fn readPending(alloc: std.mem.Allocator, common_dir: []const u8) ![]const Pending {
    var out: std.ArrayList(Pending) = .empty;
    const bytes = content.readSmall(alloc, try pendingPath(alloc, common_dir)) catch |err| switch (err) {
        error.FileNotFound => return out.items,
        else => return err,
    };
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const v = json.parse(alloc, line, .{}) catch return error.MalformedPending;
        if (v != .object) return error.MalformedPending;
        const tree = v.object.get("tree") orelse return error.MalformedPending;
        const rel = v.object.get("rel") orelse return error.MalformedPending;
        const op = v.object.get("op") orelse return error.MalformedPending;
        if (tree != .string or rel != .string or op != .string) return error.MalformedPending;
        const parsed = std.meta.stringToEnum(Op, op.string) orelse return error.MalformedPending;
        const entry: ?[]const u8 = if (v.object.get("entry")) |e| (if (e == .string) e.string else null) else null;
        const worktree: ?[]const u8 = if (v.object.get("worktree")) |e| (if (e == .string) e.string else null) else null;
        try out.append(alloc, .{ .tree = tree.string, .rel = rel.string, .op = parsed, .entry = entry, .worktree = worktree });
    }
    return out.items;
}

fn writePending(alloc: std.mem.Allocator, common_dir: []const u8, list: []const Pending) !void {
    var buf: std.ArrayList(u8) = .empty;
    for (list) |p| {
        var obj: json.ObjectMap = .empty;
        try obj.put(alloc, "op", .{ .string = @tagName(p.op) });
        try obj.put(alloc, "rel", .{ .string = p.rel });
        try obj.put(alloc, "tree", .{ .string = p.tree });
        if (p.entry) |e| try obj.put(alloc, "entry", .{ .string = e });
        if (p.worktree) |w| try obj.put(alloc, "worktree", .{ .string = w });
        var aw: std.Io.Writer.Allocating = .init(alloc);
        try json.encode(&aw.writer, .{ .object = obj }, .{ .sort_keys = true });
        try buf.appendSlice(alloc, aw.written());
        try buf.append(alloc, '\n');
    }
    const path = try pendingPath(alloc, common_dir);
    try fsutil.ensureDir(std.fs.path.dirname(path).?);
    try fsutil.writeFileAtomic(alloc, path, buf.items);
}

fn samePending(p: Pending, tree: []const u8, rel: []const u8) bool {
    return std.mem.eql(u8, p.tree, tree) and std.mem.eql(u8, p.rel, rel);
}

/// Records `p`, replacing any record for the same working tree and path.
pub fn addPending(alloc: std.mem.Allocator, common_dir: []const u8, p: Pending) !void {
    var list: std.ArrayList(Pending) = .empty;
    for (try readPending(alloc, common_dir)) |old| {
        if (!samePending(old, p.tree, p.rel)) try list.append(alloc, old);
    }
    try list.append(alloc, p);
    try writePending(alloc, common_dir, list.items);
}

/// Removes the working tree `tree`'s record for `rel`, leaving every other
/// working tree's.
pub fn clearPending(alloc: std.mem.Allocator, common_dir: []const u8, tree: []const u8, rel: []const u8) !void {
    var list: std.ArrayList(Pending) = .empty;
    var found = false;
    for (try readPending(alloc, common_dir)) |old| {
        if (samePending(old, tree, rel)) {
            found = true;
        } else try list.append(alloc, old);
    }
    if (found) try writePending(alloc, common_dir, list.items);
}

/// Whether git still lists the working tree `tree` (`Clone.tree`) of the
/// clone whose common directory is `common_dir`: the main one always, a
/// linked one while its administrative directory exists, prunable or not.
pub fn treeListed(alloc: std.mem.Allocator, common_dir: []const u8, tree: []const u8) !bool {
    if (std.mem.eql(u8, tree, ".")) return true;
    const dir = if (std.fs.path.isAbsolute(tree)) tree else try fsutil.joinSlashy(alloc, common_dir, tree);
    return try content.entryAt(dir) == .dir;
}

/// The working tree `tree`'s record for `rel`.
pub fn findPending(list: []const Pending, tree: []const u8, rel: []const u8) ?Pending {
    for (list) |p| if (samePending(p, tree, rel)) return p;
    return null;
}

/// Whether the block line for the temporary `temp` (`paths.tempRel`) must
/// stay: some working tree in `trees` has something at it, or a record in
/// `pending`, of any working tree, is for the path it sits beside. Always
/// when the working trees are unknown (null) or one cannot be read.
pub fn tempInUse(alloc: std.mem.Allocator, trees: ?[]const Worktree, pending: []const Pending, temp: []const u8) !bool {
    for (pending) |p| {
        if (paths.check(p.rel) == null and std.mem.eql(u8, try paths.tempRel(alloc, p.rel), temp)) return true;
    }
    for (trees orelse return true) |t| {
        if (!t.readable()) return true;
        if (try content.entryAt(try fsutil.joinSlashy(alloc, t.path, temp)) != .absent) return true;
    }
    return false;
}

const testutil = @import("../testutil.zig");

const Fixture = @import("harness.zig").Fixture;

test "inspect: a clone and its linked worktree share the clone's key; a clone outside code_root has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const code = try std.fs.path.join(a, &.{ sb.root, "code" });
    const clone_path = try std.fs.path.join(a, &.{ code, "github.com", "acme", "widget" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", bare, clone_path });
    const wt = try std.fs.path.join(a, &.{ code, "github.com", "acme", "widget@worktrees", "feature" });
    try testutil.runGit(&sb, clone_path, &.{ "worktree", "add", "-q", "-b", "feature", wt });

    const c = try inspect(a, clone_path, code);
    try testing.expectEqualStrings("github.com/acme/widget", c.key.?);
    const w = try inspect(a, wt, code);
    try testing.expectEqualStrings("github.com/acme/widget", w.key.?);
    try testing.expectEqualStrings(c.common_dir, w.common_dir);
    try testing.expect(!std.mem.eql(u8, c.git_dir, w.git_dir));
    try testing.expectEqualStrings(".", c.tree);
    try testing.expectEqualStrings("worktrees/feature", w.tree);

    const trees = try worktrees(a, w);
    try testing.expectEqual(@as(usize, 2), trees.len);
    try testing.expectEqualStrings(c.worktree, trees[0].path);

    const outside = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(outside);
    try testing.expect((try inspect(a, outside, code)).key == null);
}

test "worktrees: read from the common directory, a record's relative path resolved from it, and a record that cannot be read listed as such" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    for ([_][]const u8{ "one", "two" }) |name| {
        try testutil.runGit(&sb, work, &.{ "worktree", "add", "-q", "-b", name, try std.fs.path.join(a, &.{ sb.root, name }) });
    }
    const c = try inspect(a, work, sb.root);
    const records = try std.fs.path.join(a, &.{ c.common_dir, "worktrees" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ records, "one", "gitdir" }), .data = "../../../../one/.git\n" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ records, "two", "gitdir" }), .data = "\n" });

    const got = try worktrees(a, c);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings(c.worktree, got[0].path);
    try testing.expect(got[0].readable());
    try testing.expectEqualStrings(try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ sb.root, "one" })), got[1].path);
    try testing.expect(got[1].readable());
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ records, "two" }), got[2].path);
    try testing.expectEqual(@as(?TreeProblem, .record_unreadable), got[2].problem);
}

test "worktrees and unlistedRecords: a record whose gitdir holt is denied, or is a symlink loop, is a record that cannot be read" {
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
    for ([_][]const u8{ "denied", "loop" }) |name| {
        try testutil.runGit(&sb, work, &.{ "worktree", "add", "-q", "-b", name, try std.fs.path.join(a, &.{ sb.root, name }) });
    }
    const c = try inspect(a, work, sb.root);
    const records = try std.fs.path.join(a, &.{ c.common_dir, "worktrees" });
    const denied = try std.fs.path.join(a, &.{ records, "denied", "gitdir" });
    const loop = try std.fs.path.join(a, &.{ records, "loop", "gitdir" });
    try fsutil.removePath(loop);
    try content.createLink(loop, loop, .file);
    const proc = @import("../proc.zig");
    try testing.expectEqual(@as(u8, 0), (try proc.run(a, &.{ "chmod", "000", denied }, null)).status);
    defer _ = proc.run(a, &.{ "chmod", "600", denied }, null) catch {};
    if (content.readSmall(a, denied)) |_| return error.SkipZigTest else |_| {}

    const got = try worktrees(a, c);
    try testing.expectEqual(@as(usize, 3), got.len);
    for (got[1..], [_][]const u8{ "denied", "loop" }) |t, name| {
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ records, name }), t.path);
        try testing.expectEqual(@as(?TreeProblem, .record_unreadable), t.problem);
    }
    const unlisted = try unlistedRecords(a, c.common_dir);
    try testing.expectEqual(@as(usize, 2), unlisted.len);
    for (unlisted, [_][]const u8{ "denied", "loop" }) |u, name| {
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ records, name }), u.record);
        try testing.expect(u.why == .unreadable);
    }
}

test "worktrees: a file among the records and a record with no gitdir name no working tree, and a record in the other side of WSL's form cannot be found here" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const c = try inspect(a, work, sb.root);
    const records = try std.fs.path.join(a, &.{ c.common_dir, "worktrees" });
    try fsutil.ensureDir(try std.fs.path.join(a, &.{ records, "half" }));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ records, "stray" }), .data = "not a record" });
    const other = if (builtin.os.tag == .windows) "/mnt/c/Users/me/wt" else "C:/Users/me/wt";
    try fsutil.ensureDir(try std.fs.path.join(a, &.{ records, "wsl" }));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ records, "wsl", "gitdir" }), .data = other ++ "/.git\n" });

    const got = try worktrees(a, c);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings(c.worktree, got[0].path);
    try testing.expect(got[0].readable() and got[0].recorded);
    try testing.expectEqualStrings(other, got[1].path);
    try testing.expectEqual(@as(?TreeProblem, .other_side), got[1].problem);
    const half = try halfCreated(a, c);
    try testing.expectEqual(@as(usize, 1), half.len);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ records, "half" }), half[0]);
}

test "tracked, rootCommits, defaultRoot: read from git" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try fsutil.ensureDir(try std.fs.path.join(a, &.{ work, "dir" }));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ work, "dir", "t" }), .data = "t" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ work, "staged" }), .data = "s" });
    try testutil.runGit(&sb, work, &.{ "add", "dir/t" });
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "-m", "dir" });
    try testutil.runGit(&sb, work, &.{ "add", "staged" });

    const got = try tracked(a, work, &.{ "README", "dir", "staged", "untracked", "di", "*" });
    try testing.expectEqual(@as(usize, 6), got.len);
    for (got, [_]bool{ true, true, true, false, false, false }) |t, want| try testing.expectEqual(want, t == .exact);
    for (got[3..]) |t| try testing.expect(t == .none);

    const roots = try rootCommits(a, work);
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings(roots[0], (try defaultRoot(a, work)).?);
}

test "tracked: a path equal under case folding or normalization is tracked when it is the same file on disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ work, "caf\u{e9}.txt" }), .data = "c" });
    try fsutil.ensureDir(try std.fs.path.join(a, &.{ work, "Docs" }));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ work, "Docs", "a" }), .data = "a" });
    try testutil.runGit(&sb, work, &.{ "add", "." });
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "-m", "names" });

    const rels = [_][]const u8{ "readme", "cafe\u{301}.txt", "docs", "CAF\u{c9}.TXT", "other" };
    const got = try tracked(a, work, &rels);
    try testing.expectEqualStrings("README", got[0].folded[0]);
    try testing.expectEqualStrings("caf\u{e9}.txt", got[1].folded[0]);
    try testing.expectEqualStrings("Docs", got[2].folded[0]);
    try testing.expectEqualStrings("caf\u{e9}.txt", got[3].folded[0]);
    try testing.expect(got[4] == .none);

    const sensitive = try @import("harness.zig").caseSensitive(a, work);
    const fold = try content.probeFolding(a, work);
    for (rels[0..3], got[0..3], [_]bool{ !sensitive, fold.norm, !sensitive }) |rel, t, same| {
        try testing.expectEqual(same, try t.isTracked(a, work, rel, fold));
    }
    if (!sensitive) return;
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ work, "readme" }), .data = "a different file" });
    try testing.expect(!try got[0].isTracked(a, work, "readme", fold));
}

test "Tracked.isTracked: where the filesystem folds names, another spelling counts when both are absent or both are one file, never when only one is present" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const t: Tracked = .{ .folded = &.{"B"} };

    try testing.expect(try t.isTracked(a, f.root, "a", .all));
    try testing.expect(try t.isTracked(a, f.root, "a", .{ .case = false, .norm = true }));
    const here = try f.write("a", "here");
    try testing.expect(!try t.isTracked(a, f.root, "a", .all));
    try fsutil.removePath(here);
    const there = try f.write("B", "there");
    try testing.expect(!try t.isTracked(a, f.root, "a", .all));
    try testutil.hardLink(a, there, here);
    try testing.expect(try t.isTracked(a, f.root, "a", .all));
    try fsutil.removePath(here);
    _ = try f.write("a", "a separate file");
    try testing.expect(!try t.isTracked(a, f.root, "a", .all));

    try fsutil.removePath(here);
    try fsutil.removePath(there);
    try testing.expect(!try t.isTracked(a, f.root, "a", .none));
}

test "folding: probed in the state directory, or at the working tree's root under a block line that is gone afterwards" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const c = try inspect(a, work, sb.root);
    const want = !try @import("harness.zig").caseSensitive(a, work);

    try testing.expectEqual(want, (try folding(a, c, true)).fold.case);
    probe_at_root_for_test = true;
    defer probe_at_root_for_test = false;
    try testing.expectEqual(want, (try content.probeFoldingAs(a, work, try paths.probeName(a, content.randomSuffix()))).case);
    try testing.expectEqual(want, (try folding(a, c, true)).fold.case);
    try testing.expect(!(try block.read(a, c.common_dir)).present);
    const res = try git.runInRepo(a, &.{ "status", "--porcelain", "--ignored", "--untracked-files=all" }, work);
    try testing.expectEqualStrings("", res.stdout);
}

test "tracked: when git cannot list it fails; an unborn HEAD lists only the index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const not_repo = try std.fs.path.join(a, &.{ sb.root, "plain" });
    try fsutil.ensureDir(not_repo);
    try testing.expectError(error.GitFailed, tracked(a, not_repo, &.{ "a", "b" }));

    const unborn = try std.fs.path.join(a, &.{ sb.root, "unborn" });
    try fsutil.ensureDir(unborn);
    try testutil.runGit(&sb, unborn, &.{ "init", "-q" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ unborn, "staged" }), .data = "s" });
    try testutil.runGit(&sb, unborn, &.{ "add", "staged" });
    const got = try tracked(a, unborn, &.{ "staged", "other" });
    try testing.expect(got[0] == .exact and got[1] == .none);

    try testing.expectError(error.GitFailed, rootCommits(a, not_repo));
}

test "notIgnored: one query returns the paths git would show" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const target = try std.fs.path.join(a, &.{ sb.root, "elsewhere" });
    try fsutil.ensureDir(target);
    for ([_][]const u8{ ".clasp.json", ".superpowers", "shown", "shown-dir" }) |name| {
        try content.createLink(target, try std.fs.path.join(a, &.{ work, name }), if (std.mem.endsWith(u8, name, "dir") or std.mem.eql(u8, name, ".superpowers")) .dir else .file);
    }
    const c = try inspect(a, work, sb.root);
    _ = try @import("block.zig").write(a, c.common_dir, &.{ ".clasp.json", ".superpowers" });

    const got = try notIgnored(a, work, &.{ ".clasp.json", ".superpowers", "shown", "shown-dir", "absent" });
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("shown", got[0]);
    try testing.expectEqualStrings("shown-dir", got[1]);
}

test "rootCommits, defaultRoot: a replace ref on the root commit changes neither, so the clone's key stays as it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const before = try rootCommits(a, work);
    const default_before = (try defaultRoot(a, work)).?;
    try testing.expectEqual(@as(usize, 1), before.len);

    const tree = try git.runInRepoScoped(a, &.{ "rev-parse", "HEAD^{tree}" }, work);
    const other = try git.runInRepoScoped(a, &.{ "-c", "user.name=t", "-c", "user.email=t@holt.invalid", "commit-tree", std.mem.trim(u8, tree.stdout, "\r\n"), "-m", "another history" }, work);
    try testing.expectEqual(@as(u8, 0), other.status);
    try testutil.runGit(&sb, work, &.{ "replace", "--graft", before[0], std.mem.trim(u8, other.stdout, "\r\n") });

    const after = try rootCommits(a, work);
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqualStrings(before[0], after[0]);
    try testing.expectEqualStrings(default_before, (try defaultRoot(a, work)).?);
}

test "defaultRoot: a shallow clone has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const shallow = try std.fs.path.join(a, &.{ sb.root, "shallow" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", "--depth", "1", try std.fmt.allocPrint(a, "file://{s}", .{bare}), shallow });
    try testing.expect((try defaultRoot(a, shallow)) == null);
    try testing.expectEqual(@as(usize, 1), (try rootCommits(a, shallow)).len);
}

test "stripUserinfo: drops credentials from scheme URLs only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("https://github.com/acme/widget", try stripUserinfo(a, "https://user:tok@github.com/acme/widget"));
    try testing.expectEqualStrings("ssh://host/acme/widget", try stripUserinfo(a, "ssh://git@host/acme/widget"));
    try testing.expectEqualStrings("git@github.com:acme/widget.git", try stripUserinfo(a, "git@github.com:acme/widget.git"));
    try testing.expectEqualStrings("https://github.com/a@b", try stripUserinfo(a, "https://github.com/a@b"));
}

test "Sparse.includes: cone mode keeps root files, listed trees, and files directly in their ancestors" {
    const a = testing.allocator;
    const sp: Sparse = .{ .mode = .cone, .dirs = &.{"apps/web"} };
    try testing.expect(try sp.includes(a, "/w", ".clasp.json", .file));
    try testing.expect(try sp.includes(a, "/w", "apps/web/.env", .file));
    try testing.expect(try sp.includes(a, "/w", "apps/.env", .file));
    try testing.expect(try sp.includes(a, "/w", "apps/web/deep/x", .file));
    try testing.expect(!try sp.includes(a, "/w", "apps/api/.env", .file));
    try testing.expect(!try sp.includes(a, "/w", ".superpowers", .dir));
    try testing.expect(try sp.includes(a, "/w", "apps", .dir));
    try testing.expect(try (Sparse{}).includes(a, "/w", ".superpowers", .dir));
}

test "sparse: a non-cone checkout includes only paths whose directory git materialized" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    for ([_][]const u8{ "in", "out" }) |d| {
        try fsutil.ensureDir(try std.fs.path.join(a, &.{ work, d }));
        try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ work, d, "f" }), .data = d });
    }
    try testutil.runGit(&sb, work, &.{ "add", "." });
    try testutil.runGit(&sb, work, &.{ "commit", "-q", "-m", "dirs" });
    try testutil.runGit(&sb, work, &.{ "config", "core.sparseCheckout", "true" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ work, ".git", "info", "sparse-checkout" }), .data = "/README\n/in/\n" });
    try testutil.runGit(&sb, work, &.{ "read-tree", "-mu", "HEAD" });

    const sp = try sparse(a, work);
    try testing.expect(sp.mode == .patterns);
    try testing.expect(try sp.includes(a, work, "in/.env", .file));
    try testing.expect(try sp.includes(a, work, ".env", .file));
    try testing.expect(!try sp.includes(a, work, "out/.env", .file));

    try testutil.runGit(&sb, work, &.{ "sparse-checkout", "init", "--cone" });
    try testutil.runGit(&sb, work, &.{ "sparse-checkout", "set", "in" });
    const cone = try sparse(a, work);
    try testing.expect(cone.mode == .cone);
    try testing.expect(!try cone.includes(a, work, "out/.env", .file));
}

test "pending: add replaces a working tree's record for a path, clear removes only that one" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const common = f.root;

    try testing.expectEqual(@as(usize, 0), (try readPending(a, common)).len);
    try addPending(a, common, .{ .tree = ".", .rel = ".clasp.json", .op = .keep });
    try addPending(a, common, .{ .tree = ".", .rel = ".env", .op = .take_local });
    try addPending(a, common, .{ .tree = ".", .rel = ".clasp.json", .op = .take_aside, .entry = "stamp" });
    try addPending(a, common, .{ .tree = "worktrees/w", .rel = ".clasp.json", .op = .keep, .worktree = "/code/w" });
    const got = try readPending(a, common);
    try testing.expectEqualStrings("/code/w", findPending(got, "worktrees/w", ".clasp.json").?.worktree.?);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(Op.take_aside, findPending(got, ".", ".clasp.json").?.op);
    try testing.expectEqualStrings("stamp", findPending(got, ".", ".clasp.json").?.entry.?);
    try clearPending(a, common, ".", ".clasp.json");
    try testing.expect(findPending(try readPending(a, common), ".", ".clasp.json") == null);
    try testing.expect(findPending(try readPending(a, common), "worktrees/w", ".clasp.json") != null);
    try testing.expect(findPending(try readPending(a, common), ".", ".env") != null);

    const file = try pendingPath(a, common);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = file, .data = try std.fmt.allocPrint(a, "{s}not json\n", .{try content.readSmall(a, file)}) });
    try testing.expectError(error.MalformedPending, readPending(a, common));
    try testing.expectError(error.MalformedPending, addPending(a, common, .{ .tree = ".", .rel = "x", .op = .keep }));
}

test "every query reads the clone it is given, whatever repository, working tree, or index a git hook's environment names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const other = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(other);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ other, "only-there" }), .data = "o" });
    try testutil.runGit(&sb, other, &.{ "add", "only-there" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ work, ".env" }), .data = "e" });
    const want = try inspect(a, work, sb.root);

    const other_git = try std.fs.path.join(a, &.{ other, ".git" });
    const pointers = [_][2][]const u8{
        .{ "GIT_DIR", other_git },
        .{ "GIT_WORK_TREE", other },
        .{ "GIT_INDEX_FILE", try std.fs.path.join(a, &.{ other_git, "index" }) },
        .{ "GIT_COMMON_DIR", other_git },
        .{ "GIT_OBJECT_DIRECTORY", try std.fs.path.join(a, &.{ other_git, "objects" }) },
        .{ "GIT_NAMESPACE", "elsewhere" },
    };
    var overrides: [pointers.len]testutil.EnvOverride = undefined;
    for (pointers, &overrides) |p, *o| o.* = try testutil.EnvOverride.install(a, p[0], p[1]);
    defer {
        var i = overrides.len;
        while (i > 0) {
            i -= 1;
            overrides[i].restore();
        }
    }

    const got = try inspect(a, work, sb.root);
    try testing.expectEqualStrings(want.worktree, got.worktree);
    try testing.expectEqualStrings(want.common_dir, got.common_dir);
    try testing.expect((try tracked(a, work, &.{"only-there"}))[0] == .none);
    const state = try stateDir(a, got.common_dir);
    try fsutil.ensureDir(state);
    const hidden = (try blockHides(a, work, &.{state}, "0123456789abcdef", "/.env\n")).?;
    try testing.expectEqual(@as(usize, 1), hidden.len);
    try testing.expectEqualStrings(".env", hidden[0]);
    try testing.expectEqual(@as(usize, 1), (try worktrees(a, got)).len);
}

test "parseGitVersion: 2.32 and newer pass, whatever a vendor appends; older or unreadable output does not" {
    for ([_][]const u8{ "git version 2.32.0\n", "git version 2.39.3 (Apple Git-146)\n", "git version 2.45.1.windows.1\r\n", "git version 3.0\n" }) |out| {
        try testing.expect(parseGitVersion(out).ok);
    }
    const old = parseGitVersion("git version 2.31.8\n");
    try testing.expect(!old.ok);
    try testing.expectEqualStrings("2.31.8", old.found);
    try testing.expect(!parseGitVersion("git version 1.99.9\n").ok);
    try testing.expect(!parseGitVersion("something else").ok);
    try testing.expect(!parseGitVersion("git version x.y\n").ok);
}

test "folding: unless it may write, it probes nowhere, answering from core.ignorecase" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);
    const c = try inspect(a, work, sb.root);
    const state = try stateDir(a, c.common_dir);
    probe_at_root_for_test = true;
    defer probe_at_root_for_test = false;

    const ic = try ignoresCase(a, work);
    const absent = try folding(a, c, false);
    try testing.expectEqual(paths.Folding{ .case = ic, .norm = ic }, absent.fold);
    try testing.expectEqual(@as(?anyerror, null), absent.failure);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(state));
    try fsutil.ensureDir(state);
    const state_before = try std.Io.Dir.cwd().statFile(fsutil.io(), state, .{});
    try testutil.runGit(&sb, work, &.{ "config", "core.ignorecase", if (ic) "false" else "true" });
    const at_root = try folding(a, c, false);
    try testing.expectEqual(paths.Folding{ .case = !ic, .norm = !ic }, at_root.fold);
    try testing.expectEqual(@as(?anyerror, null), at_root.failure);
    try testing.expect(!(try block.read(a, c.common_dir)).present);
    probe_at_root_for_test = false;
    _ = try folding(a, c, false);
    try testing.expectEqual(state_before.mtime.nanoseconds, (try std.Io.Dir.cwd().statFile(fsutil.io(), state, .{})).mtime.nanoseconds);
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{ .iterate = true });
    defer d.close(fsutil.io());
    var it = d.iterate();
    while (try it.next(fsutil.io())) |e| try testing.expect(!std.mem.startsWith(u8, e.name, ".holt-"));
}

test "blockHides leaves no file behind when git fails, and clearStaleExcludes removes only what an interrupted run left" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const mine = "0123456789abcdef";
    const dir = try f.path("state");
    try fsutil.ensureDir(dir);
    const not_repo = try f.path("plain");
    try fsutil.ensureDir(not_repo);
    try testing.expect((try blockHides(a, not_repo, &.{ try f.path("absent"), dir }, mine, "/x\n")) == null);
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), dir, .{ .iterate = true });
    var it = d.iterate();
    try testing.expect((try it.next(fsutil.io())) == null);
    d.close(fsutil.io());

    const now = std.Io.Clock.real.now(fsutil.io()).nanoseconds;
    const gone_pid = 0x7ffffffe;
    const host = "this.host";
    const me = machine.processId();
    const live = try std.fmt.allocPrint(a, "state/exclude-{s}-{s}-{d}-00000000000000aa", .{ mine, host, me });
    const busy = try std.fmt.allocPrint(a, "state/exclude-{s}-{s}-{d}-00000000000000ab", .{ mine, host, me });
    const kept = [_][]const u8{
        live,
        busy,
        try std.fmt.allocPrint(a, "state/exclude-fedcba9876543210-{s}-{d}-00000000000000bb", .{ host, gone_pid }),
        try std.fmt.allocPrint(a, "state/exclude-{s}-a_container-{d}-00000000000000bc", .{ mine, gone_pid }),
        "state/exclude-0123456789abcdef",
        "state/pending",
    };
    const removed = [_][]const u8{
        try std.fmt.allocPrint(a, "state/exclude-{s}-{s}-{d}-00000000000000cc", .{ mine, host, gone_pid }),
        try std.fmt.allocPrint(a, "state/exclude-fedcba9876543210-{s}-{d}-00000000000000dd", .{ host, gone_pid }),
        try std.fmt.allocPrint(a, "state/exclude-{s}-{s}-{d}-00000000000000ee", .{ mine, host, me }),
        try std.fmt.allocPrint(a, "state/exclude-{s}-a_container-{d}-00000000000000ef", .{ mine, me }),
        "state/exclude-00000000000000ff",
    };
    for (kept ++ removed) |rel| _ = try f.write(rel, "/x\n");
    try testutil.setModified(a, try f.path(busy), now - 2 * std.time.ns_per_min);
    for (removed[1..]) |rel| {
        try testutil.setModified(a, try f.path(rel), now - 2 * std.time.ns_per_day);
    }
    try clearStaleExcludes(a, dir, mine, host, now);
    for (kept) |rel| try testing.expectEqual(content.Entry.file, try content.entryAt(try f.path(rel)));
    for (removed) |rel| try testing.expectEqual(content.Entry.absent, try content.entryAt(try f.path(rel)));
}
