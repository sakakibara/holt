const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = posix.system;
const Threaded = std.Io.Threaded;

/// A query spawned: its child, the pipe that reports a setup failure, and
/// its slot among the queries `release` stops guarding (`active`).
pub const Spawned = struct { child: std.process.Child, setup: std.Io.File, slot: ?usize };

/// The signals that end holt, after which no query of it may run on.
const guarded = [_]posix.SIG{ .INT, .TERM, .HUP };

/// The session leader of each query running now, 0 in a free slot; a
/// query with no slot free is not guarded.
var active: [64]std.atomic.Value(posix.pid_t) = @splat(.init(0));

/// What each of `guarded` did before `guard` installed `onSignal` for it;
/// valid once `state` is `.installed`.
var previous: [guarded.len]posix.Sigaction = undefined;
var state: std.atomic.Value(enum(u8) { none, installing, installed }) = .init(.none);

/// Installs `onSignal` for each signal of `guarded` holt does not ignore,
/// once per process.
fn guard() void {
    while (true) switch (state.cmpxchgWeak(.none, .installing, .acq_rel, .acquire) orelse break) {
        .installed => return,
        else => std.atomic.spinLoopHint(),
    };
    var mask = posix.sigemptyset();
    for (guarded) |sig| posix.sigaddset(&mask, sig);
    const act: posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = mask, .flags = 0 };
    for (guarded, &previous) |sig, *old| {
        posix.sigaction(sig, null, old);
        if (old.handler.handler == posix.SIG.IGN) continue;
        posix.sigaction(sig, &act, null);
    }
    state.store(.installed, .release);
}

/// Kills the process group of every query running, then ends holt as the
/// signal would have: its default action, which the signal, pending
/// until this returns, then takes.
fn onSignal(sig: posix.SIG) callconv(.c) void {
    for (&active) |*slot| {
        const pid = slot.load(.acquire);
        if (pid <= 0) continue;
        _ = sys.kill(-pid, .KILL);
        _ = sys.kill(pid, .KILL);
    }
    const default: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(sig, &default, null);
    _ = sys.kill(sys.getpid(), sig);
}

/// Records `pid`, a query's session leader, as running; its slot, or null
/// when every slot is taken.
fn hold(pid: posix.pid_t) ?usize {
    for (&active, 0..) |*slot, i| {
        if (slot.cmpxchgStrong(0, pid, .acq_rel, .acquire) == null) return i;
    }
    return null;
}

/// Stops guarding the query in `slot`, before it is reaped and its pid
/// can be taken again.
pub fn release(slot: ?usize) void {
    if (slot) |i| active[i].store(0, .release);
}

fn aboveStdio(fd: posix.fd_t) !posix.fd_t {
    if (fd > 2) return fd;
    const result = sys.fcntl(fd, posix.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (posix.errno(result) != .SUCCESS) return error.SystemResources;
    Threaded.closeFd(fd);
    return @intCast(result);
}

fn pipe() ![2]posix.fd_t {
    var fds = try Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer for (fds) |fd| Threaded.closeFd(fd);
    fds[0] = try aboveStdio(fds[0]);
    fds[1] = try aboveStdio(fds[1]);
    return fds;
}

/// What a query `spawn` starts reads as its standard input: the null
/// device, or a pipe whose write end is the child's `stdin`.
pub const Input = enum { null_device, pipe };

/// Starts `argv` as a query: in a session and process group of its own,
/// which `onSignal` kills until `release`, its standard output and error
/// piped, and its standard input as `stdin` says.
pub fn spawn(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, environ_map: ?*const std.process.Environ.Map, stdin: Input) !Spawned {
    if (argv.len == 0) return error.FileNotFound;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| args[i] = (try a.dupeZ(u8, arg)).ptr;
    const directory = if (cwd) |c| try a.dupeZ(u8, c) else null;
    const environ = Threaded.global_single_threaded.environ.process_environ;
    const env = if (environ_map) |map| try map.createPosixBlock(a, .{}) else try environ.createPosixBlock(a, .{});
    var paths: std.ArrayList([:0]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, argv[0], '/') != null) {
        try paths.append(a, try a.dupeZ(u8, argv[0]));
    } else {
        var it = std.mem.tokenizeScalar(u8, environ.getPosix("PATH") orelse Threaded.default_PATH, ':');
        while (it.next()) |entry| try paths.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ entry, argv[0] }, 0));
    }
    const output = try pipe();
    errdefer for (output) |fd| Threaded.closeFd(fd);
    const errors = try pipe();
    errdefer for (errors) |fd| Threaded.closeFd(fd);
    const setup = try pipe();
    errdefer for (setup) |fd| Threaded.closeFd(fd);
    const fed: ?[2]posix.fd_t = if (stdin == .pipe) try pipe() else null;
    errdefer if (fed) |fds| Threaded.closeFd(fds[1]);
    defer if (fed) |fds| Threaded.closeFd(fds[0]);
    var input: std.Io.File = if (fed) |fds| .{ .handle = fds[0], .flags = .{ .nonblocking = false } } else try std.Io.Dir.cwd().openFile(io, "/dev/null", .{});
    defer if (fed == null) input.close(io);
    if (fed == null) input.handle = try aboveStdio(input.handle);
    guard();
    var blocked = posix.sigemptyset();
    for (guarded) |sig| posix.sigaddset(&blocked, sig);
    var mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, &blocked, &mask);
    const parent = sys.getpid();
    const rc = sys.fork();
    if (posix.errno(rc) != .SUCCESS) {
        posix.sigprocmask(posix.SIG.SETMASK, &mask, null);
        return error.SystemResources;
    }
    if (rc == 0) {
        for (guarded, &previous) |sig, *old| posix.sigaction(sig, old, null);
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(posix.SIG.KILL), 0, 0, 0);
            if (sys.getppid() != parent) linux.exit_group(127);
        }
        posix.sigprocmask(posix.SIG.SETMASK, &mask, null);
        if (posix.errno(sys.setsid()) != .SUCCESS) fail(setup[1], error.PermissionDenied);
        if (directory) |dir| switch (posix.errno(sys.chdir(dir))) {
            .SUCCESS => {},
            .NOENT => fail(setup[1], error.FileNotFound),
            .NOTDIR => fail(setup[1], error.NotDir),
            .ACCES => fail(setup[1], error.AccessDenied),
            else => fail(setup[1], error.Unexpected),
        };
        childDup(input.handle, 0, setup[1]);
        childDup(output[1], 1, setup[1]);
        childDup(errors[1], 2, setup[1]);
        for ([_]posix.fd_t{ input.handle, output[0], output[1], errors[0], errors[1], setup[0] }) |fd| _ = sys.close(fd);
        if (fed) |fds| _ = sys.close(fds[1]);
        var denied = false;
        for (paths.items) |path| {
            const result = sys.execve(path, args.ptr, env.slice.ptr);
            switch (posix.errno(result)) {
                .ACCES => denied = true,
                .NOENT, .NOTDIR => {},
                .NOEXEC, .INVAL => fail(setup[1], error.InvalidExe),
                .PERM => fail(setup[1], error.PermissionDenied),
                else => fail(setup[1], error.Unexpected),
            }
        }
        fail(setup[1], if (denied) error.AccessDenied else error.FileNotFound);
    }
    const slot = hold(@intCast(rc));
    posix.sigprocmask(posix.SIG.SETMASK, &mask, null);
    Threaded.closeFd(output[1]);
    Threaded.closeFd(errors[1]);
    Threaded.closeFd(setup[1]);
    return .{
        .child = .{
            .id = @intCast(rc),
            .thread_handle = {},
            .stdin = if (fed) |fds| .{ .handle = fds[1], .flags = .{ .nonblocking = false } } else null,
            .stdout = .{ .handle = output[0], .flags = .{ .nonblocking = false } },
            .stderr = .{ .handle = errors[0], .flags = .{ .nonblocking = false } },
            .request_resource_usage_statistics = false,
        },
        .setup = .{ .handle = setup[0], .flags = .{ .nonblocking = false } },
        .slot = slot,
    };
}

fn childDup(fd: posix.fd_t, dest: posix.fd_t, report: posix.fd_t) void {
    while (true) switch (posix.errno(sys.dup2(fd, dest))) {
        .SUCCESS => return,
        .INTR => continue,
        else => fail(report, error.SystemResources),
    };
}

fn fail(fd: posix.fd_t, err: anyerror) noreturn {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, @intFromError(err), .little);
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = sys.write(fd, bytes[sent..].ptr, bytes.len - sent);
        switch (posix.errno(rc)) {
            .SUCCESS => sent += @intCast(rc),
            .INTR => continue,
            else => break,
        }
    }
    if (builtin.link_libc) std.c._exit(127) else std.os.linux.exit_group(127);
}

extern "c" fn waitid(kind: c_uint, id: c_uint, info: *std.c.siginfo_t, options: c_int) c_int;

pub fn exited(pid: posix.pid_t) !bool {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
        while (true) switch (linux.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null))) {
            .SUCCESS => return info.fields.common.first.piduid.pid != 0,
            .INTR => continue,
            else => return error.Unexpected,
        };
    } else if (builtin.os.tag.isDarwin()) {
        var info: std.c.siginfo_t = std.mem.zeroes(std.c.siginfo_t);
        const p_pid = 1;
        const w_exited = 4;
        const w_nowait = 32;
        while (true) switch (posix.errno(waitid(p_pid, @intCast(pid), &info, w_exited | posix.W.NOHANG | w_nowait))) {
            .SUCCESS => return info.pid != 0,
            .INTR => continue,
            else => return error.Unexpected,
        };
    } else {
        @compileError("query session observation requires a waitid binding for this target");
    }
}

pub fn kill(pid: posix.pid_t) void {
    posix.kill(-pid, .KILL) catch {};
    posix.kill(pid, .KILL) catch {};
}
