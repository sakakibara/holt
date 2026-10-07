//! What every kept-store operation runs against, the per-key locks that
//! serialize writers on one machine, and the per-clone lock that
//! serializes writers of a clone's own state wherever they run.

const std = @import("std");
const builtin = @import("builtin");
const Env = @import("env").Env;
const projectlock = @import("../projectlock.zig");
const fsutil = @import("../fsutil.zig");
const store = @import("store.zig");
const machine = @import("machine.zig");
const content = @import("content.zig");
const paths = @import("paths.zig");
const clone = @import("clone.zig");

pub const Ctx = struct {
    alloc: std.mem.Allocator,
    env: Env,
    layout: store.Layout,
    code_root: []const u8,
    machine_id: []const u8,
    /// Set for a command that only reports (`doctor`, `status`): the files
    /// a run hands git, and the matcher's scratch repository while holt's
    /// own is absent, go in this run's directory, so nothing is written in
    /// holt's machine-local state directory.
    scratch: ?*RunScratch = null,
    /// Where a run tells a retired machine that the facts it writes count
    /// again (`writeOwnFact`); null runs say nothing.
    retired_notice: ?*RetiredNotice = null,
    /// Where `patterns.match` says why it failed with `MatcherFailed`, in
    /// `alloc`'s memory; null keeps the reason unsaid. One per thread.
    matcher_why: ?*[]const u8 = null,
};

/// The warning a retired machine gets the first time a run writes one of
/// its facts: a fact written after its retirement is not covered by it
/// (`store.factRetired`), so it blocks other machines as any fact does.
/// One per run, shared by every context the run makes.
pub const RetiredNotice = struct {
    /// Where the warning is printed, and its words for the retirement
    /// record; nothing is printed while either is null.
    err: ?*std.Io.Writer = null,
    words: ?*const fn (std.mem.Allocator, store.Retired) anyerror![]const u8 = null,
    lock: std.atomic.Mutex = .unlocked,
    done: bool = false,

    fn note(n: *RetiredNotice, alloc: std.mem.Allocator, layout: store.Layout, machine_id: []const u8) !void {
        while (!n.lock.tryLock()) std.atomic.spinLoopHint();
        defer n.lock.unlock();
        const err = n.err orelse return;
        const words = n.words orelse return;
        if (n.done) return;
        n.done = true;
        const ret = (try store.readRetired(alloc, layout, machine_id)) orelse return;
        try err.print("holt: warning: {s}\n", .{try words(alloc, ret)});
    }
};

/// Writes this machine's fact for `rel` of `key` (`store.writeFact`),
/// warning once per run when this machine is retired (`RetiredNotice`).
pub fn writeOwnFact(ctx: Ctx, key: []const u8, rel: []const u8, kind: content.Kind, sha256: []const u8) !void {
    try store.writeFact(ctx.alloc, ctx.layout, key, ctx.machine_id, rel, kind, sha256);
    if (ctx.retired_notice) |n| try n.note(ctx.alloc, ctx.layout, ctx.machine_id);
}

/// Makes this machine's fact for `rel` of `key` the only one
/// (`store.replaceFacts`), warning as `writeOwnFact` does.
pub fn replaceOwnFacts(ctx: Ctx, key: []const u8, rel: []const u8, kind: content.Kind, sha256: []const u8) !void {
    try store.replaceFacts(ctx.alloc, ctx.layout, key, ctx.machine_id, rel, kind, sha256);
    if (ctx.retired_notice) |n| try n.note(ctx.alloc, ctx.layout, ctx.machine_id);
}

/// Warns once per run, as `writeOwnFact` does, for this machine's other
/// writes that change what every machine keeps: a release or a purge.
pub fn noteOwnWrite(ctx: Ctx) !void {
    if (ctx.retired_notice) |n| try n.note(ctx.alloc, ctx.layout, ctx.machine_id);
}

/// A directory of one run's own, `holt-report-<random>` under the system
/// temporary directory, made by `init` and removed with everything in it
/// by `deinit`. The matcher makes its scratch repository there once per
/// run, however many threads ask (`ready`, under `lock`).
pub const RunScratch = struct {
    dir: []const u8,
    lock: std.atomic.Mutex = .unlocked,
    /// Whether the matcher's scratch repository is made in `dir`.
    ready: bool = false,

    pub fn init(alloc: std.mem.Allocator, env: Env) !RunScratch {
        const suffix = content.randomSuffix();
        const dir = try std.fs.path.join(alloc, &.{ try fsutil.tempDir(alloc, env), try std.mem.concat(alloc, u8, &.{ "holt-report-", &suffix }) });
        try fsutil.ensureDir(dir);
        return .{ .dir = dir };
    }

    pub fn deinit(s: *RunScratch) void {
        std.Io.Dir.cwd().deleteTree(fsutil.io(), s.dir) catch {};
    }
};

/// A lock this process holds, and the lock file it is held on.
pub const Lock = struct {
    handle: projectlock.Handle,
    /// The lock file, as `keyLockPath` or `cloneLockPath` derives it.
    path: []const u8,

    pub fn release(self: Lock) void {
        self.handle.release();
    }
};

/// Blocks until this process holds `key`'s lock. The lock lives in holt's
/// machine-local state directory, `$XDG_STATE_HOME/holt/locks/` or the
/// platform's equivalent, so every holt process on the machine finds it
/// whatever its temporary directory, and is named by `lockName`
/// (`keyLockPath`).
pub fn lockKey(ctx: Ctx, key: []const u8) !Lock {
    return lockNamed(ctx, key, try lockName(ctx, key));
}

/// The lock file of `key`'s lock (`lockKey`), its directory created if
/// absent.
pub fn keyLockPath(ctx: Ctx, key: []const u8) ![]const u8 {
    return projectlock.lockPathIn(ctx.alloc, try lockDir(ctx), try lockName(ctx, key));
}

fn lockNamed(ctx: Ctx, key: []const u8, name: []const u8) !Lock {
    if (builtin.is_test) if (lock_trace_for_test) |t| try t.append(ctx.alloc, key);
    const path = try projectlock.lockPathIn(ctx.alloc, try lockDir(ctx), name);
    return .{ .handle = try lockAt(path), .path = path };
}

fn lockAt(path: []const u8) !projectlock.Handle {
    if (builtin.is_test and lock_nonblocking_for_test) {
        const file = try std.Io.Dir.createFileAbsolute(fsutil.io(), path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
        return .{ .file = file };
    }
    return projectlock.acquireAt(path);
}

/// What `key`'s lock is named by: the real path of the key's directory, so
/// every spelling of one synced root takes one lock. For a directory not
/// created yet, the real path of its nearest existing ancestor with the
/// rest of the normalized path appended. The whole name is then folded
/// under case folding and Unicode normalization (`paths.Folding.all`),
/// whatever the filesystem holding the key's directory does, so two
/// spellings of a key share a lock before its directory exists and keep
/// sharing it once one of them creates it, and nothing a probe could
/// answer ever splits one key's lock. Keys differing only by case or
/// normalization on a filesystem that tells them apart share a lock too,
/// which only serializes them.
fn lockName(ctx: Ctx, key: []const u8) ![]const u8 {
    const a = ctx.alloc;
    const full = try std.fs.path.resolve(a, &.{try ctx.layout.keyDir(a, key)});
    var head: []const u8 = full;
    while (try content.entryAt(head) == .absent) {
        head = std.fs.path.dirname(head) orelse break;
    }
    if (try content.entryAt(head) == .absent) return full;
    const real = try fsutil.realPathOrSelf(a, head);
    const name = try std.mem.concat(a, u8, &.{ real, full[head.len..] });
    return paths.Folding.all.key(a, name) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => name,
    };
}

/// Blocks until this process holds the lock of the clone whose common
/// directory is `common_dir`: the file `lock` in the clone's own state
/// directory (`clone.stateDir`, created if absent), so every process that
/// writes the clone's state (its block, `pending`, and temporaries)
/// serializes with every other, whatever holt state directory each uses,
/// as a host and a container sharing one clone through a bind mount do.
/// Taken before any key lock. `CloneStateUnwritable` when the state
/// directory or the lock file cannot be created.
pub fn lockClone(ctx: Ctx, common_dir: []const u8) !Lock {
    const dir = try clone.stateDir(ctx.alloc, common_dir);
    fsutil.ensureDir(dir) catch return error.CloneStateUnwritable;
    const path = try cloneLockPath(ctx, common_dir);
    const handle = lockAt(path) catch |err| switch (err) {
        error.WouldBlock => return err,
        else => return error.CloneStateUnwritable,
    };
    return .{ .handle = handle, .path = path };
}

/// The lock file of the clone's lock (`lockClone`) whose common directory
/// is `common_dir`.
pub fn cloneLockPath(ctx: Ctx, common_dir: []const u8) ![]const u8 {
    return std.fs.path.join(ctx.alloc, &.{ try clone.stateDir(ctx.alloc, common_dir), "lock" });
}

/// Locks a caller already holds, handed to a call that would otherwise
/// take them: each lock is held per open file, so taking one again from
/// the same process would wait on itself. A call trusts them only while
/// each is still open on the very lock file it would take itself.
pub const Held = struct {
    /// The clone's lock held (`lockClone`).
    clone: Lock,
    /// The key's lock held (`lockKey`).
    key: Lock,

    pub fn of(clone_lock: Lock, key_lock: Lock) Held {
        return .{ .clone = clone_lock, .key = key_lock };
    }

    /// Whether these locks are held on the lock files of the clone whose
    /// common directory is `common_dir` and of `key` (`cloneLockPath`, and
    /// `keyLockPath`'s file): each handle is still open, on the same device
    /// and inode as the file at that path (`content.handleIs`), whatever
    /// the path each lock names. Creates nothing.
    pub fn covers(h: Held, ctx: Ctx, common_dir: []const u8, key: []const u8) !bool {
        if (!try content.handleIs(ctx.alloc, h.clone.handle.file, try cloneLockPath(ctx, common_dir))) return false;
        const key_file = try projectlock.lockFileIn(ctx.alloc, try lockDir(ctx), try lockName(ctx, key));
        return content.handleIs(ctx.alloc, h.key.handle.file, key_file);
    }
};

fn lockDir(ctx: Ctx) ![]const u8 {
    return std.fs.path.join(ctx.alloc, &.{ try machine.stateDir(ctx.alloc, ctx.env), "locks" });
}

/// Test seam: every key `lockKey` locks is appended, in order.
pub var lock_trace_for_test: ?*std.ArrayList([]const u8) = null;

/// Test seam: a lock already held is `WouldBlock` instead of a wait.
pub var lock_nonblocking_for_test = false;

pub const Pair = struct {
    first: Lock,
    second: ?Lock,

    pub fn release(self: Pair) void {
        if (self.second) |s| s.release();
        self.first.release();
    }
};

/// Both keys' locks, taken in the lexicographic order of their lock names
/// (`lockName`) so two processes locking the same pair never deadlock. One
/// lock when both keys name one lock, as two spellings of one directory do.
pub fn lockKeys(ctx: Ctx, a: []const u8, b: []const u8) !Pair {
    const na = try lockName(ctx, a);
    const nb = try lockName(ctx, b);
    if (std.mem.eql(u8, na, nb)) return .{ .first = try lockNamed(ctx, a, na), .second = null };
    const lo, const hi = if (std.mem.order(u8, na, nb) == .lt) .{ .{ a, na }, .{ b, nb } } else .{ .{ b, nb }, .{ a, na } };
    const first = try lockNamed(ctx, lo[0], lo[1]);
    errdefer first.release();
    return .{ .first = first, .second = try lockNamed(ctx, hi[0], hi[1]) };
}

/// Locks taken together by `lockAll`.
pub const Set = struct {
    handles: []const Lock,

    pub fn release(self: Set) void {
        var i = self.handles.len;
        while (i > 0) {
            i -= 1;
            self.handles[i].release();
        }
    }
};

/// Every key's lock in `keys`, taken as `lockKeys` takes two: in the
/// lexicographic order of their lock names (`lockName`), and once for keys
/// that name one lock.
pub fn lockAll(ctx: Ctx, keys: []const []const u8) !Set {
    const a = ctx.alloc;
    const Named = struct {
        key: []const u8,
        name: []const u8,

        fn less(_: void, x: @This(), y: @This()) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    };
    const list = try a.alloc(Named, keys.len);
    for (keys, list) |k, *n| n.* = .{ .key = k, .name = try lockName(ctx, k) };
    std.mem.sort(Named, list, {}, Named.less);
    const handles = try a.alloc(Lock, list.len);
    var n: usize = 0;
    errdefer (Set{ .handles = handles[0..n] }).release();
    for (list, 0..) |x, i| {
        if (i > 0 and std.mem.eql(u8, list[i - 1].name, x.name)) continue;
        handles[n] = try lockNamed(ctx, x.key, x.name);
        n += 1;
    }
    return .{ .handles = handles[0..n] };
}

const Fixture = @import("harness.zig").Fixture;

fn testCtx(f: *Fixture, tmp: []const u8) !Ctx {
    const a = f.alloc();
    const map = try a.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(a);
    try map.put("TMPDIR", try f.path(tmp));
    try map.put("TEMP", try f.path(tmp));
    try map.put("HOME", f.root);
    try map.put("USERPROFILE", f.root);
    try map.put("XDG_STATE_HOME", try f.path("state"));
    return .{ .alloc = a, .env = .{ .map = map }, .layout = .{ .synced_root = f.root }, .code_root = f.root, .machine_id = "0123456789abcdef" };
}

test "lockKeys: takes the lower key first in either argument order, and one lock for equal keys" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f, "tmp");
    var trace: std.ArrayList([]const u8) = .empty;
    lock_trace_for_test = &trace;
    defer lock_trace_for_test = null;

    const p1 = try lockKeys(ctx, "github.com/b/x", "github.com/a/x");
    p1.release();
    const p2 = try lockKeys(ctx, "github.com/a/x", "github.com/b/x");
    p2.release();
    const same = try lockKeys(ctx, "github.com/a/x", "github.com/a/x");
    try std.testing.expect(same.second == null);
    same.release();

    const want = [_][]const u8{ "github.com/a/x", "github.com/b/x", "github.com/a/x", "github.com/b/x", "github.com/a/x" };
    try std.testing.expectEqual(want.len, trace.items.len);
    for (want, trace.items) |w, got| try std.testing.expectEqualStrings(w, got);
}

test "lockAll: takes each distinct lock once, in lock-name order" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f, "tmp");
    var trace: std.ArrayList([]const u8) = .empty;
    lock_trace_for_test = &trace;
    defer lock_trace_for_test = null;
    lock_nonblocking_for_test = true;
    defer lock_nonblocking_for_test = false;

    const set = try lockAll(ctx, &.{ "github.com/c/x", "github.com/a/x", "github.com/b/x", "github.com/a/x" });
    try std.testing.expectEqual(@as(usize, 3), set.handles.len);
    try std.testing.expectError(error.WouldBlock, lockKey(ctx, "github.com/b/x"));
    set.release();
    const again = try lockKey(ctx, "github.com/b/x");
    again.release();
    const want = [_][]const u8{ "github.com/a/x", "github.com/b/x", "github.com/c/x", "github.com/b/x", "github.com/b/x" };
    try std.testing.expectEqual(want.len, trace.items.len);
    for (want, trace.items) |w, got| try std.testing.expectEqualStrings(w, got);
}

test "lockKey: processes with different temporary directories share one lock" {
    var f = try Fixture.init();
    defer f.deinit();
    const one = try testCtx(&f, "tmp-one");
    const two = try testCtx(&f, "tmp-two");
    const held = try lockKey(one, "github.com/a/x");
    defer held.release();
    const path = try projectlock.lockPathIn(two.alloc, try lockDir(two), try lockName(two, "github.com/a/x"));
    try std.testing.expectError(error.WouldBlock, std.Io.Dir.createFileAbsolute(fsutil.io(), path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }));
}

test "lockKeys: two keys naming one directory take its lock once" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f, "tmp");
    const a = ctx.alloc;
    try fsutil.ensureDir(try ctx.layout.keyDir(a, "github.com/acme/w"));
    try content.createLink(try ctx.layout.keyDir(a, "github.com/acme"), try ctx.layout.keyDir(a, "github.com/alias"), .dir);
    lock_nonblocking_for_test = true;
    defer lock_nonblocking_for_test = false;

    var pairs: std.ArrayList([2][]const u8) = .empty;
    try pairs.append(a, .{ "github.com/alias/w", "github.com/acme/w" });
    try pairs.append(a, .{ "github.com/acme/w", "github.com/alias/w" });
    if (!try @import("harness.zig").caseSensitive(a, f.root)) try pairs.append(a, .{ "github.com/Acme/w", "github.com/acme/w" });
    for (pairs.items) |p| {
        const held = try lockKeys(ctx, p[0], p[1]);
        defer held.release();
        try std.testing.expect(held.second == null);
    }
}

test "lockKey: two spellings of one synced root share one lock, whether or not the key's directory exists yet" {
    var f = try Fixture.init();
    defer f.deinit();
    const real = try testCtx(&f, "tmp");
    var alias = real;
    alias.layout = .{ .synced_root = try f.path("alias") };
    try content.createLink(f.root, alias.layout.synced_root, .dir);
    try fsutil.ensureDir(try real.layout.keyDir(real.alloc, "github.com/a/x"));

    for ([_][]const u8{ "github.com/a/x", "github.com/a/not-yet" }) |key| {
        const held = try lockKey(alias, key);
        defer held.release();
        const path = try projectlock.lockPathIn(real.alloc, try lockDir(real), try lockName(real, key));
        try std.testing.expectError(error.WouldBlock, std.Io.Dir.createFileAbsolute(fsutil.io(), path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }));
    }
}

test "lockKeys: where filesystems fold names, two spellings of a key not created yet take one lock, before and after it is created" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f, "tmp");
    try fsutil.ensureDir(try ctx.layout.keyDir(ctx.alloc, "github.com"));
    paths.folding_for_test = .all;
    defer paths.folding_for_test = null;
    lock_nonblocking_for_test = true;
    defer lock_nonblocking_for_test = false;

    {
        const held = try lockKeys(ctx, "github.com/Acme/new", "github.com/acme/new");
        defer held.release();
        try std.testing.expect(held.second == null);
    }
    const before = try lockKey(ctx, "github.com/Acme/new");
    defer before.release();
    try fsutil.ensureDir(try ctx.layout.keyDir(ctx.alloc, "github.com/Acme/new"));
    try std.testing.expectError(error.WouldBlock, lockKey(ctx, "github.com/Acme/new"));
    try std.testing.expectError(error.WouldBlock, lockKey(ctx, "github.com/acme/new"));
}

test "lockKeys: two spellings of a key take one lock even where the filesystem tells them apart" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f, "tmp");
    try fsutil.ensureDir(try ctx.layout.keyDir(ctx.alloc, "github.com"));
    paths.folding_for_test = .none;
    defer paths.folding_for_test = null;
    lock_nonblocking_for_test = true;
    defer lock_nonblocking_for_test = false;

    {
        const held = try lockKeys(ctx, "github.com/Acme/new", "github.com/acme/new");
        defer held.release();
        try std.testing.expect(held.second == null);
    }
    const held = try lockKey(ctx, "github.com/Acme/new");
    defer held.release();
    try std.testing.expectError(error.WouldBlock, lockKey(ctx, "github.com/acme/new"));
}

test "Held.covers: only locks still open on the lock files holt would take count, and checking creates nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f, "tmp");
    lock_nonblocking_for_test = true;
    defer lock_nonblocking_for_test = false;
    const common = try f.path("clone/.git");
    try fsutil.ensureDir(common);
    const key = "github.com/a/x";

    const clone_lock = try lockClone(ctx, common);
    defer clone_lock.release();
    const key_lock = try lockKey(ctx, key);
    defer key_lock.release();
    try std.testing.expect(try Held.of(clone_lock, key_lock).covers(ctx, common, key));

    const other = try std.Io.Dir.createFileAbsolute(fsutil.io(), try f.path("elsewhere.lock"), .{ .truncate = false });
    defer other.close(fsutil.io());
    const forged: Lock = .{ .handle = .{ .file = other }, .path = key_lock.path };
    try std.testing.expect(!try Held.of(clone_lock, forged).covers(ctx, common, key));
    try std.testing.expect(!try Held.of(forged, key_lock).covers(ctx, common, key));

    const released = try lockKey(ctx, "github.com/a/y");
    released.release();
    try std.testing.expect(!try Held.of(clone_lock, released).covers(ctx, common, "github.com/a/y"));

    const elsewhere = try testCtx(&f, "tmp");
    try @constCast(elsewhere.env.map).put("XDG_STATE_HOME", try f.path("state-absent"));
    try std.testing.expect(!try Held.of(clone_lock, key_lock).covers(elsewhere, common, key));
    try std.testing.expectEqual(content.Entry.absent, try content.entryAt(try f.path("state-absent")));
}
