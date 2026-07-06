//! Generic subprocess spawning: captured stdio (for output a caller wants to
//! inspect) and inherited stdio (for an interactive or streaming child that
//! needs the real terminal). Every function here spawns a real child process
//! using the caller's real environment and credentials unless an explicit
//! env-override map is given.

const std = @import("std");
const testing = std.testing;

pub const RunResult = struct { status: u8, stdout: []u8, stderr: []u8 };

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
    var threaded = spawnThreaded(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .environ_map = environ_map,
    });
    return .{
        .status = termStatus(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
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
/// interactivity and liveness.
pub fn spawnInherited(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !u8 {
    var threaded = spawnThreaded(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
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

test "termStatus: maps exited, signal, stopped, and unknown terms" {
    try testing.expectEqual(@as(u8, 0), termStatus(.{ .exited = 0 }));
    try testing.expectEqual(@as(u8, 42), termStatus(.{ .exited = 42 }));
    try testing.expectEqual(@as(u8, 255), termStatus(.{ .signal = std.posix.SIG.KILL }));
    try testing.expectEqual(@as(u8, 255), termStatus(.{ .stopped = std.posix.SIG.STOP }));
    try testing.expectEqual(@as(u8, 255), termStatus(.{ .unknown = 0 }));
}

test "spawnInherited: runs a real child and returns its mapped exit code" {
    const status = try spawnInherited(testing.allocator, &.{ "sh", "-c", "exit 0" }, null);
    try testing.expectEqual(@as(u8, 0), status);

    const failed = try spawnInherited(testing.allocator, &.{ "sh", "-c", "exit 3" }, null);
    try testing.expectEqual(@as(u8, 3), failed);
}
