//! Generic subprocess spawning: captured stdio (for output a caller wants to
//! inspect) and inherited stdio (for an interactive or streaming child that
//! needs the real terminal). Every function here spawns a real child process
//! using the caller's real environment and credentials unless an explicit
//! env-override map is given.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// A child's exit status and output; `timed_out` when `runEnvLimited` killed
/// it at its limit, with what it had printed by then.
pub const RunResult = struct { status: u8, stdout: []u8, stderr: []u8, timed_out: bool = false };

/// Total subprocesses spawned this process. Incremented once per real spawn so
/// perf-regression tests can assert an operation's per-repo subprocess count
/// stays reduced (e.g. status probes each repo with ONE git call, not four).
pub var spawn_count: std.atomic.Value(u64) = .init(0);

// fsutil.io() is backed by std.Io.Threaded.global_single_threaded, whose
// allocator is hardcoded to `.failing`: Zig 0.16's spawnPosix builds the
// child's argv/env blocks through an ArenaAllocator wrapping that allocator
// before fork/execve, so every spawn through it fails with OutOfMemory.
// Spawning needs a Threaded backed by a real allocator instead. The
// singleton's `environ` field is still real (Zig's startup code populates it
// from the process's actual argv/envp before main runs), so we borrow just
// that data to keep PATH and credential-relevant env vars intact.
fn spawnThreaded(gpa: std.mem.Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(gpa, .{
        .environ = std.Io.Threaded.global_single_threaded.environ.process_environ,
    });
}

/// Maps a child's exit status to a single u8: the real code on a normal
/// exit, 255 for a signal, stop, or anything else that isn't a clean exit.
pub fn termStatus(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 255,
    };
}

/// Spawns `argv` (never inheriting stdio) and collects its exit status,
/// stdout, and stderr. `environ_map`, when set, replaces the child's
/// environment entirely; callers needing the real environment pass `run`
/// instead, which leaves it null.
pub fn runEnv(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map) !RunResult {
    return capture(alloc, argv, cwd, environ_map, null);
}

/// A line `runEnvLimited` writes to `w`, and flushes, once the child has
/// run `after` without ending.
pub const Notice = struct { after: std.Io.Duration, w: *std.Io.Writer, line: []const u8 };

/// Captures a query under a deadline, draining output for at most one second
/// after exit. POSIX queries have their own session and group, which holt
/// kills when SIGINT, SIGTERM or SIGHUP ends it; on Linux the kernel also
/// kills a query when the thread that spawned it ends. On macOS a query
/// outlives a SIGKILL of holt until it ends by itself.
pub fn runEnvLimited(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map, limit: std.Io.Duration, notice: ?Notice) !RunResult {
    var threaded = spawnThreaded(alloc);
    defer threaded.deinit();
    const io = threaded.io();
    const started = std.Io.Clock.awake.now(io);
    const deadline = started.addDuration(limit);
    const posix = @import("proc_posix.zig");
    var setup: ?std.Io.File = null;
    var slot: ?usize = null;
    var child = if (builtin.os.tag == .windows) try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = environ_map,
        .create_no_window = true,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) else child: {
        const spawned = try posix.spawn(alloc, io, argv, cwd, environ_map, .null_device);
        setup = spawned.setup;
        slot = spawned.slot;
        break :child spawned.child;
    };
    defer {
        if (child.id) |id| {
            if (builtin.os.tag != .windows) {
                posix.kill(id);
                posix.release(slot);
            }
            child.kill(io);
        }
        if (setup) |file| file.close(io);
    }
    _ = spawn_count.fetchAdd(1, .monotonic);

    const stream_count = if (builtin.os.tag == .windows) 2 else 3;
    var buffer: std.Io.File.MultiReader.Buffer(stream_count) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    const files = if (builtin.os.tag == .windows) &.{ child.stdout.?, child.stderr.? } else &.{ child.stdout.?, child.stderr.?, setup.? };
    multi.init(alloc, io, buffer.toStreams(), files);
    var reading = true;
    defer if (reading) multi.deinit();
    var pending = notice;
    var drain: ?std.Io.Timestamp = null;
    var timed_out = false;
    var eof = false;
    while (true) {
        const now = std.Io.Clock.awake.now(io);
        if (drain == null) {
            const ended = if (builtin.os.tag == .windows) try windowsExited(child.id.?) else try posix.exited(child.id.?);
            if (ended) {
                drain = now.addDuration(.fromSeconds(1));
            } else if (now.nanoseconds >= deadline.nanoseconds) {
                timed_out = true;
                if (builtin.os.tag == .windows) {
                    const windows = std.os.windows;
                    _ = windows.ntdll.NtTerminateProcess(child.id.?, @enumFromInt(1));
                } else posix.kill(child.id.?);
                drain = now.addDuration(.fromSeconds(1));
            } else if (pending) |n| {
                if (now.nanoseconds >= started.addDuration(n.after).nanoseconds) {
                    pending = null;
                    try n.w.writeAll(n.line);
                    try n.w.flush();
                }
            }
        }
        if (drain) |until| if (eof or now.nanoseconds >= until.nanoseconds) break;
        var wake = now.addDuration(.fromMilliseconds(10));
        const until = drain orelse deadline;
        wake.nanoseconds = @min(wake.nanoseconds, until.nanoseconds);
        if (drain == null) if (pending) |n| {
            wake.nanoseconds = @min(wake.nanoseconds, started.addDuration(n.after).nanoseconds);
        };
        if (eof) {
            try wake.withClock(.awake).wait(io);
        } else {
            multi.fill(64, .{ .deadline = wake.withClock(.awake) }) catch |err| switch (err) {
                error.EndOfStream => eof = true,
                error.Timeout => {},
                else => |e| return e,
            };
        }
    }
    try multi.checkAnyError();
    if (builtin.os.tag != .windows) {
        const report = multi.reader(2).buffered();
        if (report.len != 0) {
            if (report.len != 2) return error.Unexpected;
            return @errorFromInt(std.mem.readInt(u16, report[0..2], .little));
        }
    }
    multi.batch.cancel(io);
    const stdout = try multi.toOwnedSlice(0);
    errdefer alloc.free(stdout);
    const stderr = try multi.toOwnedSlice(1);
    errdefer alloc.free(stderr);
    multi.deinit();
    reading = false;
    child.stdout.?.close(io);
    child.stdout = null;
    child.stderr.?.close(io);
    child.stderr = null;
    if (builtin.os.tag != .windows) {
        posix.kill(child.id.?);
        posix.release(slot);
        slot = null;
    }
    const term = try waitQuery(&child, io);
    return .{ .status = if (timed_out) 255 else termStatus(term), .stdout = stdout, .stderr = stderr, .timed_out = timed_out };
}

fn waitQuery(child: *std.process.Child, io: std.Io) !std.process.Child.Term {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return child.wait(io);
}

fn windowsExited(handle: std.os.windows.HANDLE) !bool {
    const windows = std.os.windows;
    const zero: windows.LARGE_INTEGER = 0;
    return switch (windows.ntdll.NtWaitForSingleObject(handle, .FALSE, &zero)) {
        .SUCCESS => true,
        .TIMEOUT => false,
        else => error.Unexpected,
    };
}

/// `runEnv` with the child's standard input read from the file at
/// `stdin_path` rather than the null device.
pub fn runEnvInput(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map, stdin_path: []const u8) !RunResult {
    return capture(alloc, argv, cwd, environ_map, stdin_path);
}

/// Runs `argv` with its standard input the file at `stdin_path`, or the
/// null device, and collects its status and output. When reading either
/// stream fails, the child is killed and the run fails at once. The child
/// stays in holt's process group, so a signal the terminal sends holt
/// reaches it too.
fn capture(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map, stdin_path: ?[]const u8) !RunResult {
    var threaded = spawnThreaded(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const input: ?std.Io.File = if (stdin_path) |p| try std.Io.Dir.cwd().openFile(io, p, .{}) else null;
    defer if (input) |f| f.close(io);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = environ_map,
        .create_no_window = true,
        .stdin = if (input) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // A child that ignores the SIGTERM `kill` sends would keep it waiting.
    defer {
        if (builtin.os.tag != .windows) if (child.id) |id| std.posix.kill(id, .KILL) catch {};
        child.kill(io);
    }
    _ = spawn_count.fetchAdd(1, .monotonic);

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(alloc, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    try readAll(&multi);
    const term = try child.wait(io);
    const stdout = try multi.toOwnedSlice(0);
    errdefer alloc.free(stdout);
    const stderr = try multi.toOwnedSlice(1);
    return .{ .status = termStatus(term), .stdout = stdout, .stderr = stderr };
}

/// `runEnv` with `data` written to the child's standard input through a
/// pipe, which is closed once it is all written or the child stops
/// reading; nothing is written to a file. On POSIX the child is a query:
/// it has a session and process group of its own, so a descendant still
/// holding its standard input or output ends with it, and holt kills them
/// when SIGINT, SIGTERM or SIGHUP ends it (`runEnvLimited`).
pub fn runEnvData(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map, data: []const u8) !RunResult {
    var threaded = spawnThreaded(alloc);
    defer threaded.deinit();
    const io = threaded.io();
    const posix = @import("proc_posix.zig");

    // Joined only after the child is killed, so a feeder blocked writing
    // to a child that no longer reads ends first.
    var feeder: ?std.Thread = null;
    defer if (feeder) |f| f.join();
    var setup: ?std.Io.File = null;
    var slot: ?usize = null;
    var child = if (builtin.os.tag == .windows) try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = environ_map,
        .create_no_window = true,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) else child: {
        const spawned = try posix.spawn(alloc, io, argv, cwd, environ_map, .pipe);
        setup = spawned.setup;
        slot = spawned.slot;
        break :child spawned.child;
    };
    defer {
        if (child.id) |id| {
            if (builtin.os.tag != .windows) {
                posix.kill(id);
                posix.release(slot);
            }
            child.kill(io);
        }
        if (setup) |file| file.close(io);
    }
    _ = spawn_count.fetchAdd(1, .monotonic);

    const input = child.stdin.?;
    child.stdin = null;
    feeder = std.Thread.spawn(.{}, feed, .{ input, io, data }) catch |err| {
        input.close(io);
        return err;
    };

    const stream_count = if (builtin.os.tag == .windows) 2 else 3;
    var buffer: std.Io.File.MultiReader.Buffer(stream_count) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    const files = if (builtin.os.tag == .windows) &.{ child.stdout.?, child.stderr.? } else &.{ child.stdout.?, child.stderr.?, setup.? };
    multi.init(alloc, io, buffer.toStreams(), files);
    defer multi.deinit();
    try readAll(&multi);
    if (builtin.os.tag != .windows) {
        const report = multi.reader(2).buffered();
        if (report.len != 0) {
            if (report.len != 2) return error.Unexpected;
            return @errorFromInt(std.mem.readInt(u16, report[0..2], .little));
        }
    }
    feeder.?.join();
    feeder = null;
    // Released before the child is reaped and its pid can be taken again.
    if (builtin.os.tag != .windows) posix.release(slot);
    slot = null;
    const term = try child.wait(io);
    const stdout = try multi.toOwnedSlice(0);
    errdefer alloc.free(stdout);
    const stderr = try multi.toOwnedSlice(1);
    return .{ .status = termStatus(term), .stdout = stdout, .stderr = stderr };
}

/// Reads every stream of `multi` to its end, and fails as soon as one
/// fails: a stream that failed is no longer read, so a child still writing
/// to it could keep the others open forever.
fn readAll(multi: *std.Io.File.MultiReader) !void {
    while (multi.fill(64, .none)) |_| {
        try multi.checkAnyError();
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();
}

fn feed(file: std.Io.File, io: std.Io, data: []const u8) void {
    defer file.close(io);
    file.writeStreamingAll(io, data) catch {};
}

/// Spawns `argv` with the caller's real environment (real credentials, real
/// config). Caller owns `stdout`/`stderr`.
pub fn run(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !RunResult {
    return runEnv(alloc, argv, cwd, null);
}

/// Spawns `argv` with inherited stdio (stdin/stdout/stderr all pass through
/// to the real terminal) and waits for it, returning the mapped exit code.
/// An interactive or long-running child - an editor, a dev server, a pager -
/// needs the real terminal; capturing or piping its output would break both
/// interactivity and liveness. Under test there is no terminal, and the test
/// runner's stdin and stdout carry its protocol, so the child gets none of
/// them: its stdio is null.
pub fn spawnInherited(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !u8 {
    return spawnInheritedEnv(alloc, argv, cwd, null);
}

/// `spawnInherited` with `environ_map`, when set, as the child's whole
/// environment.
pub fn spawnInheritedEnv(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map) !u8 {
    var threaded = spawnThreaded(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const stdio: std.process.SpawnOptions.StdIo = if (builtin.is_test) .ignore else .inherit;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = environ_map,
        .stdin = stdio,
        .stdout = stdio,
        .stderr = stdio,
    });
    _ = spawn_count.fetchAdd(1, .monotonic);
    return termStatus(try child.wait(io));
}

test "run: captures a child's stdout" {
    const res = try run(testing.allocator, &.{ "sh", "-c", "echo hi" }, null);
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(@as(u8, 0), res.status);
    try testing.expectEqualStrings("hi\n", res.stdout);
}

test "run: a nonzero exit is reflected in status, not an error" {
    const res = try run(testing.allocator, &.{ "sh", "-c", "exit 7" }, null);
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(@as(u8, 7), res.status);
}

test "runEnv: when reading the child's output fails, the run fails at once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const started = std.Io.Clock.awake.now(testing.io);
    // A descendant holds the child's standard error for 20 seconds, while
    // the child writes more output than the allocator takes.
    const res = runEnv(capped, &.{ "sh", "-c", "sleep 20 & exec 2>&-; head -c 4000000 /dev/zero" }, null, null);
    if (res) |r| {
        capped.free(r.stdout);
        capped.free(r.stderr);
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.OutOfMemory, err);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 5 * std.time.ns_per_s);
}

test "runEnvLimited: a notice is written once the child has run that long, and never for one that ends first" {
    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    const slow = try runEnvLimited(testing.allocator, &.{ "sh", "-c", "sleep 2; echo done" }, null, null, .fromSeconds(30), .{ .after = .fromMilliseconds(300), .w = &w.writer, .line = "waiting\n" });
    defer testing.allocator.free(slow.stdout);
    defer testing.allocator.free(slow.stderr);
    try testing.expect(!slow.timed_out);
    try testing.expectEqualStrings("done\n", slow.stdout);
    try testing.expectEqualStrings("waiting\n", w.written());
    const fast = try runEnvLimited(testing.allocator, &.{ "sh", "-c", "echo done" }, null, null, .fromSeconds(30), .{ .after = .fromSeconds(5), .w = &w.writer, .line = "again\n" });
    defer testing.allocator.free(fast.stdout);
    defer testing.allocator.free(fast.stderr);
    try testing.expectEqualStrings("waiting\n", w.written());
}

test "runEnvLimited: a child that finishes in time is run as runEnv runs it" {
    const res = try runEnvLimited(testing.allocator, &.{ "sh", "-c", "echo out; echo err >&2; exit 3" }, null, null, .fromSeconds(30), null);
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expect(!res.timed_out);
    try testing.expectEqual(@as(u8, 3), res.status);
    try testing.expectEqualStrings("out\n", res.stdout);
    try testing.expectEqualStrings("err\n", res.stderr);
}

test "runEnvLimited: a child that outlives the limit is killed at it, with every process it started" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const started = std.Io.Clock.awake.now(testing.io);
    const res = try runEnvLimited(testing.allocator, &.{ "sh", "-c", "sleep 60 & echo $!; wait" }, null, null, .fromMilliseconds(500), null);
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expect(res.timed_out);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 10 * std.time.ns_per_s);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, res.stdout, " \n"), 10);
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
    }
    return error.TestUnexpectedResult;
}

test "runEnvData: the child reads the data as its standard input, and one that stops reading early ends the run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const res = try runEnvData(testing.allocator, &.{"cat"}, null, null, "from the pipe\n");
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqualStrings("from the pipe\n", res.stdout);
    const big = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const started = std.Io.Clock.awake.now(testing.io);
    const early = try runEnvData(testing.allocator, &.{ "sh", "-c", "head -c 1 >/dev/null; exit 3" }, null, null, big);
    defer testing.allocator.free(early.stdout);
    defer testing.allocator.free(early.stderr);
    try testing.expectEqual(@as(u8, 3), early.status);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 10 * std.time.ns_per_s);
}

/// Test-only: `testing.allocator`, except that it refuses any block of
/// 256 KiB or more, which a child's output reaches before anything else
/// a run allocates does.
const capped: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = struct {
        fn f(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            if (len >= 256 << 10) return null;
            return testing.allocator.rawAlloc(len, alignment, ret_addr);
        }
    }.f,
    .resize = struct {
        fn f(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            if (new_len >= 256 << 10) return false;
            return testing.allocator.rawResize(memory, alignment, new_len, ret_addr);
        }
    }.f,
    .remap = struct {
        fn f(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            if (new_len >= 256 << 10) return null;
            return testing.allocator.rawRemap(memory, alignment, new_len, ret_addr);
        }
    }.f,
    .free = struct {
        fn f(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            testing.allocator.rawFree(memory, alignment, ret_addr);
        }
    }.f,
} };

test "runEnvData: when reading the child's output fails, the run fails at once and ends every process the child started" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const big = try testing.allocator.alloc(u8, 4 << 20);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const started = std.Io.Clock.awake.now(testing.io);
    // A descendant holds the child's standard input, unread, and its
    // standard error for 20 seconds, while the child writes more output
    // than the allocator takes.
    const res = runEnvData(capped, &.{ "sh", "-c", "exec 3<&0; sleep 20 & exec 2>&-; head -c 4000000 /dev/zero; exec sleep 20" }, null, null, big);
    if (res) |r| {
        capped.free(r.stdout);
        capped.free(r.stderr);
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.OutOfMemory, err);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 5 * std.time.ns_per_s);
}

/// Test-only: ends a forked process running a child with `sig`, and
/// checks that it ended by that signal and that the child ends with it:
/// a query (`runEnvLimited`), or a child fed data (`runEnvData`) when
/// `fed`.
fn expectChildEndsWith(sig: std.posix.SIG, fed: bool) !void {
    const posix = std.posix;
    const sys = posix.system;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const pid_file = try std.fs.path.join(testing.allocator, &.{ dir, "query.pid" });
    defer testing.allocator.free(pid_file);
    const script = try std.fmt.allocPrint(testing.allocator, "echo $$ > '{s}.tmp' && mv '{s}.tmp' '{s}' && exec sleep 47", .{ pid_file, pid_file, pid_file });
    defer testing.allocator.free(script);

    const rc = sys.fork();
    if (posix.errno(rc) != .SUCCESS) return error.SystemResources;
    if (rc == 0) {
        if (fed) {
            _ = runEnvData(std.heap.page_allocator, &.{ "sh", "-c", script }, null, null, "data\n") catch {};
        } else _ = runEnvLimited(std.heap.page_allocator, &.{ "sh", "-c", script }, null, null, .fromSeconds(60), null) catch {};
        if (builtin.link_libc) std.c._exit(3) else std.os.linux.exit_group(3);
    }
    const holt: posix.pid_t = @intCast(rc);
    var status: if (builtin.link_libc) c_int else u32 = 0;
    var reaped = false;
    defer if (!reaped) {
        _ = sys.kill(holt, .KILL);
        _ = sys.waitpid(holt, &status, 0);
    };

    var query: ?posix.pid_t = null;
    defer if (query) |q| {
        _ = sys.kill(q, .KILL);
    };
    var tries: usize = 0;
    while (query == null and tries < 500) : (tries += 1) {
        if (tmp.dir.readFileAlloc(testing.io, "query.pid", testing.allocator, .limited(64))) |text| {
            defer testing.allocator.free(text);
            query = try std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, text, " \n"), 10);
        } else |_| try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
    }
    const q = query orelse return error.TestUnexpectedResult;

    _ = sys.kill(holt, sig);
    tries = 0;
    while (true) : (tries += 1) {
        const got = sys.waitpid(holt, &status, posix.W.NOHANG);
        if (posix.errno(got) == .SUCCESS and got != 0) {
            reaped = true;
            break;
        }
        if (tries >= 500) return error.TestUnexpectedResult;
        try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
    }
    const raw: u32 = @bitCast(status);
    try testing.expect(posix.W.IFSIGNALED(raw));
    try testing.expectEqual(sig, posix.W.TERMSIG(raw));

    tries = 0;
    while (tries < 250) : (tries += 1) {
        posix.kill(q, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => {
                query = null;
                return;
            },
            else => return err,
        };
        try std.Io.sleep(testing.io, .fromMilliseconds(20), .awake);
    }
    return error.TestUnexpectedResult;
}

test "runEnvLimited: holt ended by SIGINT, SIGTERM or SIGHUP while a query runs leaves no process of the query" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |sig| {
        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &old);
        if (old.handler.handler == std.posix.SIG.IGN) continue;
        try expectChildEndsWith(sig, false);
    }
}

test "runEnvLimited: on Linux, holt killed with SIGKILL while a query runs leaves no process of the query" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try expectChildEndsWith(.KILL, false);
}

test "runEnvData: holt ended by SIGINT, SIGTERM or SIGHUP while the child it feeds runs leaves no process of the child" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |sig| {
        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &old);
        if (old.handler.handler == std.posix.SIG.IGN) continue;
        try expectChildEndsWith(sig, true);
    }
}

test "runEnvData: on Linux, holt killed with SIGKILL while the child it feeds runs leaves no process of the child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try expectChildEndsWith(.KILL, true);
}

test "runEnvInput: the child reads the file as its standard input" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "in", .data = "from the file\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "in" });
    defer testing.allocator.free(path);
    const res = try runEnvInput(testing.allocator, &.{"cat"}, null, null, path);
    defer testing.allocator.free(res.stdout);
    defer testing.allocator.free(res.stderr);
    try testing.expectEqual(@as(u8, 0), res.status);
    try testing.expectEqualStrings("from the file\n", res.stdout);
}

test "runEnvInput: when reading the child's output fails, the run fails at once" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const started = std.Io.Clock.awake.now(testing.io);
    // A descendant holds the child's standard error for 20 seconds, while
    // the child writes more output than the allocator takes.
    const res = runEnvInput(capped, &.{ "sh", "-c", "sleep 20 & exec 2>&-; head -c 4000000 /dev/zero" }, null, null, "/dev/null");
    if (res) |r| {
        capped.free(r.stdout);
        capped.free(r.stderr);
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.OutOfMemory, err);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 5 * std.time.ns_per_s);
}

test "termStatus: maps exited, signal, stopped, and unknown terms" {
    try testing.expectEqual(@as(u8, 0), termStatus(.{ .exited = 0 }));
    try testing.expectEqual(@as(u8, 42), termStatus(.{ .exited = 42 }));
    if (builtin.os.tag != .windows) {
        try testing.expectEqual(@as(u8, 255), termStatus(.{ .signal = std.posix.SIG.KILL }));
        try testing.expectEqual(@as(u8, 255), termStatus(.{ .stopped = std.posix.SIG.STOP }));
    }
    try testing.expectEqual(@as(u8, 255), termStatus(.{ .unknown = 0 }));
}

test "spawnInherited: runs a real child and returns its mapped exit code" {
    const status = try spawnInherited(testing.allocator, &.{ "sh", "-c", "exit 0" }, null);
    try testing.expectEqual(@as(u8, 0), status);

    const failed = try spawnInherited(testing.allocator, &.{ "sh", "-c", "exit 3" }, null);
    try testing.expectEqual(@as(u8, 3), failed);
}

test "spawnInherited: under test, a child's output never reaches the test runner's stderr" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "stderr" });
    defer testing.allocator.free(path);

    const cap = try @import("testutil.zig").StderrCapture.begin(path);
    const status = spawnInherited(testing.allocator, &.{ "sh", "-c", "echo noise >&2" }, null);
    cap.end();
    try testing.expectEqual(@as(u8, 0), try status);
    const got = try tmp.dir.readFileAlloc(testing.io, "stderr", testing.allocator, .limited(1024));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "runEnvLimited: child exit bounds inherited pipe draining" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const started = std.Io.Clock.awake.now(testing.io);
    const result = try runEnvLimited(testing.allocator, &.{ "sh", "-c", "sleep 3 >&2 & echo $! >&2; echo done" }, null, null, .fromMilliseconds(500), null);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(!result.timed_out);
    try testing.expectEqual(@as(u8, 0), result.status);
    try testing.expectEqualStrings("done\n", result.stdout);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, result.stderr, " \n"), 10);
    var gone = false;
    for (0..100) |_| {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => {
                gone = true;
                break;
            },
            else => return err,
        };
        try std.Io.sleep(testing.io, .fromMilliseconds(5), .awake);
    }
    try testing.expect(gone);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 2 * std.time.ns_per_s);
}

test "runEnvLimited: EOF does not bypass the child deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const started = std.Io.Clock.awake.now(testing.io);
    const result = try runEnvLimited(testing.allocator, &.{ "sh", "-c", "exec 1>&- 2>&-; sleep 2" }, null, null, .fromMilliseconds(100), null);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(result.timed_out);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < std.time.ns_per_s);
}

test "runEnvData: setup errors are returned" {
    try testing.expectError(error.FileNotFound, runEnvData(testing.allocator, &.{"/holt-missing-data-executable"}, null, null, "data\n"));
    try testing.expectError(error.FileNotFound, runEnvData(testing.allocator, &.{"sh"}, "/holt-missing-data-directory", null, "data\n"));
}

test "runEnvLimited: setup errors are returned" {
    try testing.expectError(error.FileNotFound, runEnvLimited(testing.allocator, &.{"/holt-missing-query-executable"}, null, null, .fromSeconds(1), null));
    try testing.expectError(error.FileNotFound, runEnvLimited(testing.allocator, &.{"sh"}, "/holt-missing-query-directory", null, .fromSeconds(1), null));
}

test "runEnvLimited: continuous output does not bypass the deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const started = std.Io.Clock.awake.now(testing.io);
    const result = try runEnvLimited(testing.allocator, &.{ "sh", "-c", "i=0; while [ $i -lt 1000000 ]; do echo output; i=$((i+1)); done" }, null, null, .fromMilliseconds(100), null);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(result.timed_out);
    try testing.expect(result.stdout.len > 0);
    try testing.expect(started.durationTo(std.Io.Clock.awake.now(testing.io)).nanoseconds < 2 * std.time.ns_per_s);
}

test "runEnvLimited: notice failure cleans up the child" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = path_buffer[0..try tmp.dir.realPath(testing.io, &path_buffer)];
    var writer = std.Io.Writer.fixed(&.{});
    try testing.expectError(error.WriteFailed, runEnvLimited(testing.allocator, &.{ "sh", "-c", "echo $$ > pid; sleep 3" }, dir, null, .fromSeconds(2), .{ .after = .fromMilliseconds(100), .w = &writer, .line = "waiting" }));
    const pid_text = try tmp.dir.readFileAlloc(testing.io, "pid", testing.allocator, .limited(100));
    defer testing.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, " \n"), 10);
    try testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
}

test "runEnvLimited: query leader has its own session" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const posix = @import("proc_posix.zig");
    var threaded = spawnThreaded(testing.allocator);
    defer threaded.deinit();
    const io = threaded.io();
    var spawned = try posix.spawn(testing.allocator, io, &.{ "sh", "-c", "sleep 3" }, null, null, .null_device);
    defer {
        posix.kill(spawned.child.id.?);
        spawned.child.kill(io);
        spawned.setup.close(io);
    }
    const c = struct {
        extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;
    };
    for (0..100) |_| {
        const sid = if (builtin.os.tag == .linux) std.os.linux.getsid(spawned.child.id.?) else c.getsid(spawned.child.id.?);
        if (sid == spawned.child.id.?) return;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.TestUnexpectedResult;
}

test "runEnvLimited: spawn remaps closed standard descriptors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const posix = @import("proc_posix.zig");
    const sys = std.posix.system;
    var threaded = spawnThreaded(testing.allocator);
    defer threaded.deinit();
    const io = threaded.io();
    var spawned = child: {
        var saved: [3]std.posix.fd_t = undefined;
        var count: usize = 0;
        defer for (saved[0..count], 0..) |fd, i| {
            _ = sys.dup2(fd, @intCast(i));
            std.Io.Threaded.closeFd(fd);
        };
        for (0..3) |i| {
            const fd = sys.fcntl(@intCast(i), std.posix.F.DUPFD_CLOEXEC, @as(c_int, 3));
            if (std.posix.errno(fd) != .SUCCESS) return error.SystemResources;
            saved[i] = @intCast(fd);
            count += 1;
        }
        for (0..3) |i| _ = sys.close(@intCast(i));
        break :child try posix.spawn(testing.allocator, io, &.{ "sh", "-c", "echo out; echo err >&2; if read value; then exit 99; fi" }, null, null, .null_device);
    };
    defer {
        if (spawned.child.id) |id| posix.kill(id);
        spawned.child.kill(io);
        spawned.setup.close(io);
    }
    var buffer: std.Io.File.MultiReader.Buffer(3) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(testing.allocator, io, buffer.toStreams(), &.{ spawned.child.stdout.?, spawned.child.stderr.?, spawned.setup });
    defer multi.deinit();
    const deadline: std.Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake }) };
    while (multi.fill(64, deadline)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try multi.checkAnyError();
    try testing.expectEqualStrings("out\n", multi.reader(0).buffered());
    try testing.expectEqualStrings("err\n", multi.reader(1).buffered());
    try testing.expectEqualStrings("", multi.reader(2).buffered());
    var ended = false;
    for (0..100) |_| {
        ended = try posix.exited(spawned.child.id.?);
        if (ended) break;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    try testing.expect(ended);
    posix.kill(spawned.child.id.?);
    try testing.expectEqual(@as(u8, 0), termStatus(try spawned.child.wait(io)));
}

test "runEnvLimited: pending cancellation cannot interrupt reaping" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const posix = @import("proc_posix.zig");
    var threaded = spawnThreaded(testing.allocator);
    defer threaded.deinit();
    const io = threaded.io();
    var spawned = try posix.spawn(testing.allocator, io, &.{ "sh", "-c", "sleep 3" }, null, null, .null_device);
    const pid = spawned.child.id.?;
    defer {
        if (spawned.child.id) |id| posix.kill(id);
        spawned.child.kill(io);
        spawned.setup.close(io);
    }
    const Worker = struct {
        fn run(worker_io: std.Io, child: *std.process.Child, ready: *std.Io.Event) !void {
            ready.set(worker_io);
            std.Io.sleep(worker_io, .fromSeconds(3), .awake) catch |err| switch (err) {
                error.Canceled => worker_io.recancel(),
            };
            posix.kill(child.id.?);
            _ = try waitQuery(child, worker_io);
            try testing.expectError(error.Canceled, worker_io.checkCancel());
        }
    };
    var ready: std.Io.Event = .unset;
    var future = try io.concurrent(Worker.run, .{ io, &spawned.child, &ready });
    try ready.wait(io);
    try future.cancel(io);
    try testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
}
