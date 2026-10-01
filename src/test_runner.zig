//! Test runner for the unit test binary.
//!
//! The tests run in `--jobs=N` worker processes at once, twice the CPU
//! count by default, since a test spends most of its time waiting on the
//! git it starts. Each worker is this binary given `--worker`; it runs the
//! tests it is handed one at a time, each with the globals a test sets as
//! the last test it ran left them, so no two tests run in one process at
//! once. `--jobs=1` runs every test in this process instead. Under
//! `--listen=-` the results are served over the build runner's test
//! protocol, as the standard runner serves them; otherwise each failure is
//! printed with what the test wrote to stderr.
//!
//! Every process the tests start inherits `hermetic_git`: git reads no
//! global or system configuration file, so the developer's hooks, filters
//! and includes never run under the suite, and a git that finds no
//! configured `user.email` takes `EMAIL` rather than deriving one from the
//! host name, a name lookup that can take seconds. A test that needs a
//! global configuration still points `GIT_CONFIG_GLOBAL` at its own file.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

const hermetic_git = [_][2][]const u8{
    .{ "GIT_CONFIG_GLOBAL", "/dev/null" },
    .{ "GIT_CONFIG_SYSTEM", "/dev/null" },
    .{ "EMAIL", "holt-test@holt.invalid" },
};

/// Starts the line a worker writes to stderr once a test has run, after
/// whatever the test wrote there: the test's index, status, leak count and
/// logged error count.
const result_mark = "\x1eholt-test-result ";

const gpa = std.heap.page_allocator;
var log_err_count: usize = 0;
const runner_io: Io = Io.Threaded.global_single_threaded.io();

const Status = enum(u8) { pass, skip, fail };

const Result = struct {
    status: Status = .fail,
    leaks: u32 = 0,
    logged: u32 = 0,
    output: []const u8 = "",
};

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.toSlice(gpa) catch |err| std.debug.panic("unable to parse command line args: {t}", .{err});

    var listen = false;
    var worker = false;
    var jobs: ?usize = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.eql(u8, arg, "--worker")) {
            worker = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            jobs = std.fmt.parseUnsigned(usize, arg["--jobs=".len..], 10) catch null;
            if (jobs == null or jobs.? == 0) std.debug.panic("--jobs takes a count of at least 1: {s}", .{arg});
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {} else {
            std.debug.panic("unrecognized command line argument: {s}", .{arg});
        }
    }

    const environ = hermetic(init.environ) catch |err| std.debug.panic("unable to set the test environment: {t}", .{err});
    if (worker) return serveWorker(init.args, environ) catch |err| std.debug.panic("test worker failure: {t}", .{err});

    const count = jobs orelse 2 * (std.Thread.getCpuCount() catch 1);
    if (listen) {
        serve(init.args, environ, count) catch |err| std.debug.panic("internal test runner failure: {t}", .{err});
    } else {
        runAll(init.args, environ, count) catch |err| std.debug.panic("internal test runner failure: {t}", .{err});
    }
}

extern "kernel32" fn SetEnvironmentVariableW(name: ?[*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) std.os.windows.BOOL;

/// `environ` with `hermetic_git` set, installed as the process environment
/// children inherit.
fn hermetic(environ: std.process.Environ) !std.process.Environ {
    if (builtin.os.tag == .windows) {
        for (hermetic_git) |kv| {
            const key = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, kv[0]);
            const value = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, kv[1]);
            if (!SetEnvironmentVariableW(key.ptr, value.ptr).toBool()) return error.SetEnvironmentVariableFailed;
        }
        return environ;
    }
    var map = try std.process.Environ.createMap(environ, gpa);
    for (hermetic_git) |kv| try map.put(kv[0], kv[1]);
    const with: std.process.Environ = .{ .block = try map.createPosixBlock(gpa, .{}) };
    Io.Threaded.global_single_threaded.environ.process_environ = with;
    return with;
}

/// Runs the test at `index` in this process.
fn runOne(args: std.process.Args, environ: std.process.Environ, index: usize) Result {
    testing.environ = environ;
    testing.allocator_instance = .{};
    testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(args), .environ = environ });
    testing.log_level = .warn;
    log_err_count = 0;
    const test_fn = builtin.test_functions[index];
    const status: Status = if (test_fn.func()) |_| .pass else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => s: {
            std.debug.print("error: {t}\n", .{err});
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            break :s .fail;
        },
    };
    testing.io_instance.deinit();
    const leaks = testing.allocator_instance.detectLeaks();
    testing.allocator_instance.deinitWithoutLeakChecks();
    return .{
        .status = status,
        .leaks = std.math.lossyCast(u32, leaks),
        .logged = std.math.lossyCast(u32, log_err_count),
    };
}

/// Reads test indexes from stdin, one a line, and runs each, writing its
/// `result_mark` line to stderr after it.
fn serveWorker(args: std.process.Args, environ: std.process.Environ) !void {
    var buffer: [64]u8 = undefined;
    var reader: Io.File.Reader = .initStreaming(.stdin(), runner_io, &buffer);
    while (reader.interface.takeDelimiter('\n')) |line| {
        const text = line orelse return;
        const index = try std.fmt.parseUnsigned(usize, text, 10);
        const r = runOne(args, environ, index);
        std.debug.print("\n" ++ result_mark ++ "{d} {d} {d} {d}\n", .{ index, @intFromEnum(r.status), r.leaks, r.logged });
    } else |err| return err;
}

/// Runs every test in `jobs` workers, or in this process when `jobs` is 1,
/// and returns each test's result by index.
fn runTests(args: std.process.Args, environ: std.process.Environ, jobs: usize) ![]Result {
    const results = try gpa.alloc(Result, builtin.test_functions.len);
    @memset(results, .{});
    if (jobs == 1) {
        for (results, 0..) |*r, i| r.* = runOne(args, environ, i);
        return results;
    }
    var threaded: Io.Threaded = .init(gpa, .{ .argv0 = .init(args), .environ = environ });
    defer threaded.deinit();
    var pool: Pool = .{
        .io = threaded.io(),
        .exe = try std.process.executablePathAlloc(threaded.io(), gpa),
        .results = results,
    };
    const threads = try gpa.alloc(std.Thread, @min(jobs, results.len));
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, Pool.drive, .{&pool});
    for (threads) |t| t.join();
    if (pool.failure) |err| return err;
    return results;
}

const Pool = struct {
    io: Io,
    exe: []const u8,
    results: []Result,
    next: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,

    /// Feeds tests to one worker after another until none is left; a worker
    /// that ends while it runs a test fails that test and is replaced.
    fn drive(pool: *Pool) void {
        pool.driveWorkers() catch |err| {
            pool.failure = err;
        };
    }

    fn driveWorkers(pool: *Pool) !void {
        const io = pool.io;
        var pending: ?usize = null;
        while (true) {
            var child = try std.process.spawn(io, .{
                .argv = &.{ pool.exe, "--worker" },
                .create_no_window = true,
                .stdin = .pipe,
                .stdout = .ignore,
                .stderr = .pipe,
            });
            var buffer: [64 * 1024]u8 = undefined;
            var reader = child.stderr.?.readerStreaming(io, &buffer);
            var out: std.ArrayList(u8) = .empty;
            while (true) {
                const index = pending orelse pool.next.fetchAdd(1, .monotonic);
                if (index >= pool.results.len) {
                    child.stdin.?.close(io);
                    child.stdin = null;
                    _ = try child.wait(io);
                    return;
                }
                pending = index;
                var line: [24]u8 = undefined;
                child.stdin.?.writeStreamingAll(io, try std.fmt.bufPrint(&line, "{d}\n", .{index})) catch break;
                const r = try readResult(&reader.interface, &out) orelse break;
                if (r.index != index) return error.WorkerOutOfStep;
                pool.results[index] = r.result;
                pending = null;
            }
            const term = try child.wait(io);
            try out.appendSlice(gpa, reader.interface.buffered());
            try out.print(gpa, "the test worker ended while running it ({any})\n", .{term});
            pool.results[pending.?] = .{ .status = .fail, .output = out.items };
            pending = null;
        }
    }

    const Read = struct { index: usize, result: Result };

    /// What a worker wrote for its next test: the output before its
    /// `result_mark` line, and the result there. Null at end of stream.
    fn readResult(r: *Io.Reader, out: *std.ArrayList(u8)) !?Read {
        out.* = .empty;
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    try out.appendSlice(gpa, r.buffered());
                    r.tossBuffered();
                    continue;
                },
                error.EndOfStream => return null,
                error.ReadFailed => return err,
            };
            const at = std.mem.indexOf(u8, line, result_mark) orelse {
                try out.appendSlice(gpa, line);
                continue;
            };
            try out.appendSlice(gpa, line[0..at]);
            var fields = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line[at + result_mark.len ..], "\r\n"), ' ');
            var v: [4]u32 = undefined;
            for (&v) |*x| x.* = try std.fmt.parseUnsigned(u32, fields.next() orelse return error.BadWorkerResult, 10);
            const output = std.mem.trimEnd(u8, out.items, "\n");
            return .{ .index = v[0], .result = .{
                .status = std.enums.fromInt(Status, v[1]) orelse return error.BadWorkerResult,
                .leaks = v[2],
                .logged = v[3],
                .output = output,
            } };
        }
    }
};

fn serve(args: std.process.Args, environ: std.process.Environ, jobs: usize) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), runner_io, &stdin_buffer);
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), runner_io, &stdout_buffer);
    var server = try std.zig.Server.init(.{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
        .zig_version = builtin.zig_version_string,
    });

    var results: ?[]Result = null;
    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => return std.process.exit(0),
            .query_test_metadata => {
                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(gpa);
                try string_bytes.append(gpa, 0);
                const test_fns = builtin.test_functions;
                const names = try gpa.alloc(u32, test_fns.len);
                defer gpa.free(names);
                const expected_panic_msgs = try gpa.alloc(u32, test_fns.len);
                defer gpa.free(expected_panic_msgs);
                for (test_fns, names, expected_panic_msgs) |test_fn, *name, *expected_panic_msg| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.appendSlice(gpa, test_fn.name);
                    try string_bytes.append(gpa, 0);
                    expected_panic_msg.* = 0;
                }
                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },
            .run_test => {
                const index = try server.receiveBody_u32();
                try server.serveStringMessage(.test_started, &.{});
                if (results == null) results = try runTests(args, environ, jobs);
                const r = results.?[index];
                if (r.output.len != 0) {
                    // The build runner pairs a test's result with the stderr it
                    // has read by then, so the output goes in one write, given
                    // time to be read before the result follows it.
                    try Io.File.stderr().writeStreamingAll(runner_io, try std.mem.concat(gpa, u8, &.{ r.output, "\n" }));
                    try runner_io.sleep(.fromMilliseconds(50), .awake);
                }
                const TestResults = std.zig.Server.Message.TestResults;
                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .status = switch (r.status) {
                            .pass => .pass,
                            .skip => .skip,
                            .fail => .fail,
                        },
                        .fuzz = false,
                        .log_err_count = std.math.lossyCast(@FieldType(TestResults.Flags, "log_err_count"), r.logged),
                        .leak_count = std.math.lossyCast(@FieldType(TestResults.Flags, "leak_count"), r.leaks),
                    },
                });
            },
            else => {
                std.debug.print("unsupported message: {x}\n", .{@intFromEnum(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

fn runAll(args: std.process.Args, environ: std.process.Environ, jobs: usize) !void {
    const results = try runTests(args, environ, jobs);
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaks: usize = 0;
    var logged: usize = 0;
    for (results, builtin.test_functions) |r, test_fn| {
        switch (r.status) {
            .pass => {},
            .skip => skipped += 1,
            .fail => failed += 1,
        }
        if (r.leaks != 0) leaks += 1;
        logged += r.logged;
        if (r.status == .fail or r.leaks != 0 or r.logged != 0) {
            std.debug.print("{s}...{s}\n", .{ test_fn.name, if (r.status == .fail) "FAIL" else if (r.leaks != 0) "LEAK" else "LOGGED ERRORS" });
            if (r.output.len != 0) std.debug.print("{s}\n", .{r.output});
        }
    }
    std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ results.len - skipped - failed, skipped, failed });
    if (logged != 0) std.debug.print("{d} errors were logged.\n", .{logged});
    if (leaks != 0) std.debug.print("{d} tests leaked memory.\n", .{leaks});
    if (failed != 0 or leaks != 0 or logged != 0) std.process.exit(1);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) log_err_count +|= 1;
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n", args);
    }
}
