//! Test runner for the unit test binary.
//!
//! `--shard=I/N` runs only the tests whose index is I modulo N, so the build
//! can run the suite as N processes at once; with no `--shard` every test
//! runs. Under `--listen=-` it serves the build runner's test protocol, as
//! the standard runner does, over that shard's tests alone; otherwise it
//! runs them in turn and prints each failure.
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

var log_err_count: usize = 0;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
const runner_io: Io = Io.Threaded.global_single_threaded.io();

const Shard = struct {
    index: u32 = 0,
    count: u32 = 1,

    fn has(s: Shard, test_index: usize) bool {
        return test_index % s.count == s.index;
    }

    fn parse(text: []const u8) !Shard {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return error.BadShard;
        const s: Shard = .{
            .index = try std.fmt.parseUnsigned(u32, text[0..slash], 10),
            .count = try std.fmt.parseUnsigned(u32, text[slash + 1 ..], 10),
        };
        if (s.count == 0 or s.index >= s.count) return error.BadShard;
        return s;
    }
};

pub fn main(init: std.process.Init.Minimal) void {
    const gpa = std.heap.page_allocator;
    const args = init.args.toSlice(gpa) catch |err| std.debug.panic("unable to parse command line args: {t}", .{err});

    var listen = false;
    var shard: Shard = .{};
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--shard=")) {
            shard = Shard.parse(arg["--shard=".len..]) catch
                std.debug.panic("--shard takes I/N with I below N: {s}", .{arg});
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {} else {
            std.debug.panic("unrecognized command line argument: {s}", .{arg});
        }
    }

    const environ = hermetic(init.environ) catch |err| std.debug.panic("unable to set the test environment: {t}", .{err});
    if (listen) {
        serve(init.args, environ, shard) catch |err| std.debug.panic("internal test runner failure: {t}", .{err});
    } else {
        runAll(init.args, environ, shard);
    }
}

extern "kernel32" fn SetEnvironmentVariableW(name: ?[*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) std.os.windows.BOOL;

/// `environ` with `hermetic_git` set, installed as the process environment
/// children inherit.
fn hermetic(environ: std.process.Environ) !std.process.Environ {
    const gpa = std.heap.page_allocator;
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

fn beginTest(args: std.process.Args, environ: std.process.Environ) void {
    testing.environ = environ;
    testing.allocator_instance = .{};
    testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(args), .environ = environ });
    testing.log_level = .warn;
    log_err_count = 0;
}

fn serve(args: std.process.Args, environ: std.process.Environ, shard: Shard) !void {
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), runner_io, &stdin_buffer);
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), runner_io, &stdout_buffer);
    var server = try std.zig.Server.init(.{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
        .zig_version = builtin.zig_version_string,
    });
    const gpa = std.heap.page_allocator;

    var shard_tests: std.ArrayList(u32) = .empty;
    for (builtin.test_functions, 0..) |_, i| if (shard.has(i)) try shard_tests.append(gpa, @intCast(i));

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => return std.process.exit(0),
            .query_test_metadata => {
                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(gpa);
                try string_bytes.append(gpa, 0);
                const names = try gpa.alloc(u32, shard_tests.items.len);
                defer gpa.free(names);
                const expected_panic_msgs = try gpa.alloc(u32, shard_tests.items.len);
                defer gpa.free(expected_panic_msgs);
                for (shard_tests.items, names, expected_panic_msgs) |i, *name, *expected_panic_msg| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.appendSlice(gpa, builtin.test_functions[i].name);
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
                const test_fn = builtin.test_functions[shard_tests.items[index]];
                beginTest(args, environ);
                try server.serveStringMessage(.test_started, &.{});

                const TestResults = std.zig.Server.Message.TestResults;
                const status: TestResults.Status = if (test_fn.func()) |_| .pass else |err| switch (err) {
                    error.SkipZigTest => .skip,
                    else => s: {
                        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                        break :s .fail;
                    },
                };
                testing.io_instance.deinit();
                const leak_count = testing.allocator_instance.detectLeaks();
                testing.allocator_instance.deinitWithoutLeakChecks();
                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .status = status,
                        .fuzz = false,
                        .log_err_count = std.math.lossyCast(@FieldType(TestResults.Flags, "log_err_count"), log_err_count),
                        .leak_count = std.math.lossyCast(@FieldType(TestResults.Flags, "leak_count"), leak_count),
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

fn runAll(args: std.process.Args, environ: std.process.Environ, shard: Shard) void {
    var ran: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaks: usize = 0;
    var logged: usize = 0;
    for (builtin.test_functions, 0..) |test_fn, i| {
        if (!shard.has(i)) continue;
        ran += 1;
        beginTest(args, environ);
        if (test_fn.func()) |_| {} else |err| switch (err) {
            error.SkipZigTest => skipped += 1,
            else => {
                failed += 1;
                std.debug.print("{s}...FAIL ({t})\n", .{ test_fn.name, err });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
        testing.io_instance.deinit();
        if (testing.allocator_instance.deinit() == .leak) {
            leaks += 1;
            std.debug.print("{s}...LEAK\n", .{test_fn.name});
        }
        logged += log_err_count;
    }
    std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ran - skipped - failed, skipped, failed });
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
