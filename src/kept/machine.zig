//! This machine's identity for the kept store: a random id kept in holt's
//! machine-local state directory beside a fingerprint of the host, and
//! replaced when the fingerprint no longer matches, so a home directory
//! restored onto another machine does not bring the old machine's id.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("json");
const Env = @import("env").Env;
const env_dirs = @import("env").dirs;
const fsutil = @import("../fsutil.zig");
const content = @import("content.zig");
const testing = std.testing;

pub const id_len = 16;
const file_name = "machine.json";

/// True for a string shaped like a machine id: 16 lowercase hex digits.
pub fn valid(s: []const u8) bool {
    if (s.len != id_len) return false;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// holt's machine-local state directory: `$XDG_STATE_HOME/holt`, or the
/// platform's equivalent.
pub fn stateDir(alloc: std.mem.Allocator, env: Env) ![]u8 {
    return env_dirs.appDir(alloc, try env_dirs.stateHome(alloc, env), "holt");
}

/// This machine's id, created on first use.
pub fn load(alloc: std.mem.Allocator, env: Env) ![]const u8 {
    return loadIn(alloc, try stateDir(alloc, env), try hostFingerprint(alloc));
}

/// The id recorded in `state_dir` for the host whose fingerprint is
/// `fingerprint`; a new random id when none is recorded or the recorded one
/// belongs to another fingerprint. An empty fingerprint (none available)
/// keeps whatever is recorded. A state directory shared by hosts with
/// different fingerprints (a home directory on a network share) therefore
/// regenerates the id whenever the other host last wrote it, and each
/// regeneration makes this machine look new to the kept store.
pub fn loadIn(alloc: std.mem.Allocator, state_dir: []const u8, fingerprint: []const u8) ![]const u8 {
    const path = try std.fs.path.join(alloc, &.{ state_dir, file_name });
    const host = try hostDigest(alloc, fingerprint);
    if (try readRecorded(alloc, path)) |rec| {
        if (fingerprint.len == 0 or std.mem.eql(u8, rec.host, host)) return rec.id;
        return write(alloc, path, host, .replace);
    }
    return write(alloc, path, host, .create);
}

/// This machine's id as recorded, or null when none is recorded for this
/// host yet; never creates or replaces one, so a command that only reports
/// writes nothing.
pub fn peek(alloc: std.mem.Allocator, env: Env) !?[]const u8 {
    return peekIn(alloc, try stateDir(alloc, env), try hostFingerprint(alloc));
}

/// The id `loadIn` would return from `state_dir` for `fingerprint` without
/// writing one: null when none is recorded or the recorded one belongs to
/// another fingerprint.
pub fn peekIn(alloc: std.mem.Allocator, state_dir: []const u8, fingerprint: []const u8) !?[]const u8 {
    const rec = (try readRecorded(alloc, try std.fs.path.join(alloc, &.{ state_dir, file_name }))) orelse return null;
    if (fingerprint.len == 0 or std.mem.eql(u8, rec.host, try hostDigest(alloc, fingerprint))) return rec.id;
    return null;
}

const Recorded = struct { id: []const u8, host: []const u8 };

fn readRecorded(alloc: std.mem.Allocator, path: []const u8) !?Recorded {
    const bytes = content.readSmall(alloc, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const v = json.parse(alloc, bytes, .{}) catch return null;
    if (v != .object) return null;
    const id_v = v.object.get("id") orelse return null;
    const host_v = v.object.get("host") orelse return null;
    if (id_v != .string or host_v != .string or !valid(id_v.string)) return null;
    return .{ .id = id_v.string, .host = host_v.string };
}

fn write(alloc: std.mem.Allocator, path: []const u8, host: []const u8, mode: enum { create, replace }) ![]const u8 {
    var bytes: [id_len / 2]u8 = undefined;
    fsutil.io().random(&bytes);
    const new_id = try alloc.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));

    var obj: json.ObjectMap = .empty;
    try obj.put(alloc, "host", .{ .string = host });
    try obj.put(alloc, "id", .{ .string = new_id });
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try json.encode(&aw.writer, .{ .object = obj }, .{ .indent = 2, .sort_keys = true });
    try aw.writer.writeByte('\n');

    if (std.fs.path.dirname(path)) |d| try fsutil.ensureDir(d);
    switch (mode) {
        .replace => try fsutil.writeFileAtomic(alloc, path, aw.written()),
        .create => {
            const tmp = try content.tempSibling(alloc, path);
            try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = tmp, .data = aw.written() });
            content.renameNoReplace(alloc, tmp, path) catch |err| {
                fsutil.removePath(tmp) catch {};
                if (err != error.PathAlreadyExists) return err;
                if (try readRecorded(alloc, path)) |rec| return rec.id;
                return error.MalformedMachineRecord;
            };
        },
    }
    return new_id;
}

fn hostDigest(alloc: std.mem.Allocator, fingerprint: []const u8) ![]const u8 {
    if (fingerprint.len == 0) return "";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fingerprint, &digest, .{});
    return alloc.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

/// A value that identifies this host's hardware or OS installation: the
/// hardware UUID on macOS, `/etc/machine-id` on Linux, `MachineGuid` on
/// Windows. Empty when the platform offers none.
pub fn hostFingerprint(alloc: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag.isDarwin()) {
        var uuid: [16]u8 = undefined;
        const wait: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        if (gethostuuid(&uuid, &wait) != 0) return "";
        return alloc.dupe(u8, &std.fmt.bytesToHex(uuid, .lower));
    }
    if (builtin.os.tag == .windows) return windowsMachineGuid(alloc);
    for ([_][]const u8{ "/etc/machine-id", "/var/lib/dbus/machine-id" }) |p| {
        const bytes = content.readSmall(alloc, p) catch continue;
        const t = std.mem.trim(u8, bytes, " \t\r\n");
        if (t.len > 0) return t;
    }
    return "";
}

extern "c" fn gethostuuid(id: *[16]u8, wait: *const std.c.timespec) c_int;

const HKEY = *opaque {};
const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
const RRF_RT_REG_SZ: u32 = 0x00000002;
const RRF_SUBKEY_WOW6464KEY: u32 = 0x00010000;

extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: [*:0]const u16,
    lpValue: [*:0]const u16,
    dwFlags: u32,
    pdwType: ?*u32,
    pvData: ?*anyopaque,
    pcbData: ?*u32,
) callconv(.winapi) i32;

fn windowsMachineGuid(alloc: std.mem.Allocator) ![]const u8 {
    var buf: [128]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(buf));
    const rc = RegGetValueW(
        HKEY_LOCAL_MACHINE,
        std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\Cryptography"),
        std.unicode.utf8ToUtf16LeStringLiteral("MachineGuid"),
        RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY,
        null,
        &buf,
        &size,
    );
    if (rc != 0) return "";
    const units = size / 2;
    const s = buf[0..if (units > 0 and buf[units - 1] == 0) units - 1 else units];
    return std.unicode.utf16LeToUtf8Alloc(alloc, s);
}

/// The longest name `hostName` gives.
pub const host_name_max = 64;

/// This host's name as the OS reports it (`gethostname`, or
/// `GetComputerNameW` on Windows), cut to `host_name_max` bytes, with every
/// byte but an ASCII letter, digit, `.`, or `_` replaced by `_`, so it can
/// stand between `-`s in a file name; `unknown` when the OS reports none.
/// A container is its own host, so its processes are told apart from the
/// host's even where their ids overlap.
pub fn hostName(buf: *[host_name_max]u8) []const u8 {
    var n: usize = 0;
    if (builtin.os.tag == .windows) {
        var wide: [host_name_max]u16 = undefined;
        var len: u32 = wide.len;
        if (GetComputerNameW(&wide, &len) != 0) {
            for (wide[0..@min(len, wide.len)]) |u| {
                buf[n] = if (u < 0x80) @intCast(u) else '_';
                n += 1;
            }
        }
    } else {
        var raw: [std.posix.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&raw)) |got| {
            n = @min(got.len, buf.len);
            @memcpy(buf[0..n], got[0..n]);
        } else |_| {}
    }
    if (n == 0) {
        @memcpy(buf[0.."unknown".len], "unknown");
        return buf[0.."unknown".len];
    }
    for (buf[0..n]) |*c| {
        if (!validHostByte(c.*)) c.* = '_';
    }
    return buf[0..n];
}

/// Whether `s` is shaped like a name `hostName` gives.
pub fn validHost(s: []const u8) bool {
    if (s.len == 0 or s.len > host_name_max) return false;
    for (s) |c| if (!validHostByte(c)) return false;
    return true;
}

fn validHostByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_';
}

extern "kernel32" fn GetComputerNameW(buf: [*]u16, size: *u32) callconv(.winapi) i32;

/// This process's id.
pub fn processId() u32 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    if (builtin.os.tag == .linux) return @intCast(std.os.linux.getpid());
    return @intCast(std.c.getpid());
}

/// Whether a process with the id `pid` is running on this machine. One that
/// exists but that holt may not inspect counts as running.
pub fn processRunning(pid: u32) bool {
    if (builtin.os.tag == .windows) {
        const h = OpenProcess(process_query_limited_information, 0, pid) orelse return GetLastError() == error_access_denied;
        defer _ = CloseHandle(h);
        var code: u32 = 0;
        if (GetExitCodeProcess(h, &code) == 0) return true;
        return code == still_active;
    }
    if (pid == 0 or pid > std.math.maxInt(std.posix.pid_t)) return false;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| return err != error.ProcessNotFound;
    return true;
}

const process_query_limited_information: u32 = 0x1000;
const error_access_denied: u32 = 5;
const still_active: u32 = 259;

extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn GetExitCodeProcess(h: std.os.windows.HANDLE, code: *u32) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: std.os.windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const Fixture = @import("harness.zig").Fixture;

test "loadIn: the id persists for one fingerprint and is replaced for another" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const root = f.root;
    const state = try std.fs.path.join(a, &.{ root, "state", "holt" });

    const first = try loadIn(a, state, "host-a");
    try testing.expect(valid(first));
    try testing.expectEqualStrings(first, try loadIn(a, state, "host-a"));
    try testing.expectEqualStrings(first, try loadIn(a, state, ""));

    const moved = try loadIn(a, state, "host-b");
    try testing.expect(valid(moved));
    try testing.expect(!std.mem.eql(u8, first, moved));
    try testing.expectEqualStrings(moved, try loadIn(a, state, "host-b"));
}

test "peekIn: the recorded id for this fingerprint, never writing one" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const state = try std.fs.path.join(a, &.{ f.root, "state", "holt" });

    try testing.expect(try peekIn(a, state, "host-a") == null);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(state));
    const id = try loadIn(a, state, "host-a");
    try testing.expectEqualStrings(id, (try peekIn(a, state, "host-a")).?);
    try testing.expectEqualStrings(id, (try peekIn(a, state, "")).?);
    try testing.expect(try peekIn(a, state, "host-b") == null);
    try testing.expectEqualStrings(id, try loadIn(a, state, "host-a"));
}

test "valid: only 16 lowercase hex digits" {
    try testing.expect(valid("0123456789abcdef"));
    try testing.expect(!valid("0123456789ABCDEF"));
    try testing.expect(!valid("0123456789abcde"));
    try testing.expect(!valid("0123456789abcdef.x.tmp"));
}

test "hostFingerprint: stable across calls" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(try hostFingerprint(a), try hostFingerprint(a));
}

test "processRunning: this process is running, an id no system hands out is not" {
    try testing.expect(processRunning(processId()));
    try testing.expect(!processRunning(0x7ffffffe));
    try testing.expect(!processRunning(0));
}

test "hostName: stable, and shaped to stand between dashes in a file name" {
    var one: [host_name_max]u8 = undefined;
    var two: [host_name_max]u8 = undefined;
    const got = hostName(&one);
    try testing.expect(validHost(got));
    try testing.expect(std.mem.indexOfScalar(u8, got, '-') == null);
    try testing.expectEqualStrings(got, hostName(&two));
    try testing.expect(!validHost("a-b"));
    try testing.expect(!validHost(""));
}
