const std = @import("std");
const builtin = @import("builtin");
const env_zig = @import("env");
const Env = env_zig.Env;
const testutil = @import("testutil.zig");
const testing = std.testing;

fn testEnv(a: std.mem.Allocator, pairs: []const [2][]const u8) !Env {
    const map = try a.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(a);
    for (pairs) |p| try map.put(p[0], p[1]);
    return .{ .map = map };
}

/// The process has no `Io` threaded down to it from `main`, so filesystem
/// and environment access here goes through the default singleton that
/// Zig's startup code populates with the real argv/environ before `main` runs.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The process temp directory: `TMPDIR` then `/tmp` on POSIX; `TEMP` then
/// `TMP` then `C:\Windows\Temp` on Windows.
pub fn tempDir(alloc: std.mem.Allocator, env: Env) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (env.get(alloc, "TEMP")) |v| return v;
        if (env.get(alloc, "TMP")) |v| return v;
        return alloc.dupe(u8, "C:\\Windows\\Temp");
    }
    if (env.get(alloc, "TMPDIR")) |v| return v;
    return alloc.dupe(u8, "/tmp");
}

/// Expands a leading "~" (home directory) or "~/rest" (home-relative path)
/// using $HOME. Any other path, absolute or relative, is duped unchanged.
/// The "~/"-relative tail is always `/`-joined (it comes from config, which
/// is platform-agnostic); split it on `/` and rejoin so each segment nests
/// with the platform separator rather than leaving a literal `/` embedded in
/// a Windows path. Caller owns the returned memory.
pub fn expandTilde(alloc: std.mem.Allocator, env: Env, path: []const u8) ![]u8 {
    return env_zig.dirs.expandTilde(alloc, env, path);
}

/// Contracts a leading $HOME into "~" for display: the inverse of expandTilde.
/// `/Users/me/Code` becomes `~/Code`; a path outside $HOME (or any path when
/// $HOME is unset) is duped unchanged. The byte after the matched $HOME must
/// be a path separator, so `/Users/meXY` is left alone rather than mangled to
/// `~XY`. For human-facing prose ONLY - a whole-line path meant for
/// `cd $(holt ...)` must stay absolute, since neither fish nor bash expands a
/// tilde that arrives from a command substitution. Caller owns the result.
pub fn contractTilde(alloc: std.mem.Allocator, env: Env, path: []const u8) ![]u8 {
    return env_zig.dirs.contractTilde(alloc, env, path);
}

/// Joins `base` with `rel`, a `/`-delimited relative path (e.g. a git branch
/// name, which namespaces on '/' regardless of platform) - split first and
/// rejoined so each segment nests with the platform separator rather than
/// leaving a literal '/' embedded in a Windows path component. Caller owns
/// the returned memory.
pub fn joinSlashy(alloc: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    return env_zig.path.joinRel(alloc, base, rel);
}

/// Forward-slashes `path` - git's own internals (worktree admin links,
/// `insteadOf` config values, and other paths it later matches by string
/// comparison) normalize on '/' even on Windows, so a native `\`-path handed
/// to it can fail to match what it already has on file. A no-op (and thus
/// the identical slice) on POSIX, where '\' never appears in a path, and
/// whenever `path` already carries no backslash. Caller owns the returned
/// memory only when a copy was actually made.
pub fn forwardSlashed(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    const out = try alloc.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

/// Creates `dir_path` and any missing parents; succeeds if it already
/// exists as a directory.
pub fn ensureDir(dir_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io(), dir_path);
}

/// Writes `data` to `path` atomically: to a randomly-suffixed temp sibling
/// first, then renames over `path`, so a crash mid-write never leaves a
/// truncated file and a reader never sees a half-written one. The random
/// suffix means two processes writing the same target never collide on one
/// temp inode (which would abort one of them with a spurious rename error).
pub fn writeFileAtomic(alloc: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    var random_bytes: [8]u8 = undefined;
    io().random(&random_bytes);
    var suffix_buf: [16]u8 = undefined;
    const suffix = std.base64.url_safe_no_pad.Encoder.encode(&suffix_buf, &random_bytes);

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.{s}.tmp", .{ path, suffix });
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io(), .{ .sub_path = tmp_path, .data = data });
    try cwd.rename(tmp_path, cwd, path, io());
}

/// True if `path` exists (file, directory, or symlink target). Any access
/// error (permission denied, not found, etc.) counts as absent.
pub fn exists(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        if (!windowsNameable(path)) return false;
    }
    std.Io.Dir.accessAbsolute(io(), path, .{}) catch return false;
    return true;
}

/// Windows rejects these in a path *name* with OBJECT_NAME_INVALID, which the
/// std turns into an uncatchable panic rather than a lookup miss; a path
/// carrying one (e.g. a URL mistaken for a local checkout) cannot exist.
/// Contract: `path` is one of holt's own logical paths (config roots joined
/// via `path.join`), not an arbitrary Win32 form - a `\\?\`-prefixed long
/// path carries a literal `?` that this would reject as unnameable even
/// though the filesystem accepts it.
fn windowsNameable(path: []const u8) bool {
    for (path, 0..) |c, i| switch (c) {
        '<', '>', '"', '|', '?', '*' => return false,
        0...31 => return false,
        ':' => if (i != 1) return false, // only the drive-letter colon is legal
        else => {},
    };
    return true;
}

/// `adopt` takes a user-supplied path that may be relative, but downstream
/// `accessAbsolute`/`realpath` calls require an absolute one. Purely lexical:
/// joins a relative path against the process cwd and normalizes "." / ".."
/// components without touching the filesystem, so it works even when `path`
/// doesn't exist yet. Caller owns the returned memory.
pub fn toAbsolute(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(alloc, &.{path});
    }
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io(), &buf);
    return std.fs.path.resolve(alloc, &.{ buf[0..n], path });
}

/// Lexical containment check on two already-resolved absolute paths: true
/// if `child` equals `parent` or is nested under it. Does no filesystem
/// access or path resolution itself.
pub fn pathIsInside(child: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, child, parent)) return true;
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child[parent.len] == std.fs.path.sep;
}

/// Resolves `path` to its canonical, symlink-free absolute form, so a
/// containment check downstream sees the physical location rather than a
/// lexical alias. A root that doesn't exist yet (fresh machine, not yet
/// initialized) has nothing to resolve, so falls back to the input as-is.
/// Caller owns the returned memory.
pub fn realPathOrSelf(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.realPathFileAbsolute(io(), path, &buf) catch |err| switch (err) {
        error.FileNotFound => return alloc.dupe(u8, path),
        // Windows opens `path` through a non-directory handle here, which NT
        // refuses for a directory. A plain directory (no reparse point of its
        // own) resolves fine through a directory handle instead
        // (openDirAbsolute + Dir.realPath). But a directory symlink or
        // junction is typed at creation (Windows, unlike POSIX, distinguishes
        // a "file" reparse point from a "directory" one), and a mistyped one
        // - e.g. `replaceSymlink` always creates a non-directory-typed
        // symlink, even for a directory target - refuses that same
        // directory-handle open of the reparse point itself even though its
        // target is a real directory. Reading the reparse point's raw target
        // via `linkState` (which opens it untyped, without following it) and
        // resolving that instead sidesteps the mismatch entirely. Never
        // fires on POSIX, where a directory resolves through the call above
        // just fine.
        error.IsDir => switch (try linkState(alloc, path)) {
            .symlink => |raw_target| {
                defer alloc.free(raw_target);
                const target = try normalizeTarget(alloc, raw_target);
                defer if (builtin.os.tag == .windows) alloc.free(target);
                const resolved = if (std.fs.path.isAbsolute(target))
                    try alloc.dupe(u8, target)
                else
                    try std.fs.path.join(alloc, &.{ std.fs.path.dirname(path) orelse path, target });
                defer alloc.free(resolved);
                return realPathOrSelf(alloc, resolved);
            },
            else => {
                var dir = try std.Io.Dir.openDirAbsolute(io(), path, .{});
                defer dir.close(io());
                const dn = try dir.realPath(io(), &buf);
                return alloc.dupe(u8, buf[0..dn]);
            },
        },
        else => return err,
    };
    return alloc.dupe(u8, buf[0..n]);
}

pub const LinkState = union(enum) {
    missing,
    symlink: []const u8,
    other,
};

/// Outcome of `replaceLink`. `.skipped_unprivileged` only ever occurs on
/// Windows, when creating a file symlink requires a privilege the process
/// doesn't hold.
pub const LinkResult = enum { created, skipped_unprivileged };

/// A Windows junction's substitute name is stored NT-prefixed
/// (`\??\C:\...`); strip that prefix and canonicalize `/` to `\` so a
/// correctly-pointing junction's readback compares equal to holt's stored
/// (Win32-form) target and `hub.reconcile` stays idempotent. Identity on
/// POSIX, where a symlink reads back verbatim. Caller owns the returned
/// memory on Windows; on POSIX the input is returned unchanged.
pub fn normalizeTarget(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var s = raw;
        if (std.mem.startsWith(u8, s, "\\??\\")) s = s["\\??\\".len..];
        const out = try alloc.dupe(u8, s);
        std.mem.replaceScalar(u8, out, '/', '\\');
        return out;
    }
    return raw;
}

/// Compares two link targets after `normalizeTarget`, so a Windows
/// junction's real on-disk target and holt's stored target are judged
/// equal despite the NT-path prefix. Plain `std.mem.eql` on POSIX.
pub fn targetsEqual(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    return std.mem.eql(u8, try normalizeTarget(alloc, a), try normalizeTarget(alloc, b));
}

/// `pathIsInside` after `normalizeTarget` on both sides, so a Windows
/// junction's backslash-normalized readback and a root taken verbatim from
/// user config (which may carry forward slashes) are compared on the same
/// separator convention. Identity-normalized on POSIX, so byte-equivalent
/// to `pathIsInside` there.
pub fn pathIsInsideNormalized(alloc: std.mem.Allocator, child: []const u8, parent: []const u8) !bool {
    return pathIsInside(try normalizeTarget(alloc, child), try normalizeTarget(alloc, parent));
}

/// Inspects `path` without following a final symlink. Returns the raw
/// (unresolved) link target when `path` is a symlink. Caller owns the
/// returned target string.
pub fn linkState(alloc: std.mem.Allocator, path: []const u8) !LinkState {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(io(), path, &buf) catch |err| switch (err) {
        error.NotLink => return .other,
        error.FileNotFound, error.NotDir => return .missing,
        else => return err,
    };
    return .{ .symlink = try alloc.dupe(u8, buf[0..n]) };
}

/// Removes whatever is at `sub_path` under `dir` - a file, a symlink, or a
/// directory/junction. On Windows a junction is a directory reparse point,
/// which `deleteFile` refuses with `error.IsDir`; falls back to `deleteDir`,
/// which opens DIRECTORY_FILE + OPEN_REPARSE_POINT and removes the reparse
/// point itself, not the target's contents. On POSIX, `deleteFile` on a
/// symlink never yields `error.IsDir`, so that fallback is dead there. Absent
/// is success.
pub fn removeEntry(dir: std.Io.Dir, sub_path: []const u8) !void {
    dir.deleteFile(io(), sub_path) catch |err| switch (err) {
        error.FileNotFound => {},
        error.IsDir => dir.deleteDir(io(), sub_path) catch |e2| switch (e2) {
            error.FileNotFound => {},
            else => return e2,
        },
        else => return err,
    };
}

/// `removeEntry` against an absolute path, relative to the process cwd.
pub fn removePath(path: []const u8) !void {
    return removeEntry(std.Io.Dir.cwd(), path);
}

/// Points `link_path` at `target`, replacing any existing link (or file) at
/// that path first. Not atomic: a crash between the remove and the create
/// can leave `link_path` absent.
pub fn replaceSymlink(target: []const u8, link_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io(), link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try cwd.symLink(io(), target, link_path, .{});
}

/// Points `link_path` at `target`, replacing any existing link (or file) at
/// that path first. `is_dir` selects the platform-appropriate primitive: a
/// symlink on POSIX (both kinds), and on Windows a directory junction (no
/// privilege) for a directory target or a file symlink for a file target.
/// A Windows file symlink that fails for lack of the symlink privilege
/// returns `.skipped_unprivileged` rather than erroring. Not atomic: a crash
/// between the remove and the create can leave `link_path` absent.
pub fn replaceLink(target: []const u8, link_path: []const u8, is_dir: bool) !LinkResult {
    const cwd = std.Io.Dir.cwd();
    // A Windows directory junction (or a kind-flip from a prior file link)
    // is a directory reparse point that plain deleteFile refuses; removePath
    // falls back to deleteDir for that case.
    try removePath(link_path);
    if (builtin.os.tag != .windows) {
        try cwd.symLink(io(), target, link_path, .{});
        return .created;
    } else {
        if (is_dir) {
            try createJunction(target, link_path);
            return .created;
        }
        cwd.symLink(io(), target, link_path, .{ .is_directory = false }) catch |err| switch (err) {
            error.PermissionDenied, error.AccessDenied => return .skipped_unprivileged,
            else => return err,
        };
        return .created;
    }
}

/// Creates a directory junction (NTFS mount-point reparse point) at
/// `sym_link_path`, pointing at `target`. Requires no privilege, unlike a
/// Windows directory symlink. `target` must be an absolute path (junctions,
/// unlike symlinks, do not support relative targets); it is converted to its
/// NT `\??\`-prefixed form.
///
/// A direct port of Zig 0.16's `dirSymLinkWindows`
/// (`lib/std/Io/Threaded.zig`), specialized for the directory-junction case:
/// a MOUNT_POINT reparse tag instead of SYMLINK, no `Flags` field in the
/// reparse buffer, and an always-absolute substitute name. `OpenFile` and
/// `deviceIoControl` are private to `Threaded`, so the open and
/// `NtFsControlFile` calls are inlined here directly against
/// `std.os.windows` rather than routed through the `Io` vtable.
fn createJunction(target: []const u8, sym_link_path: []const u8) !void {
    const w = std.os.windows;
    const cwd = std.Io.Dir.cwd();

    const sym_link_path_w = try std.Io.Threaded.sliceToPrefixedFileW(cwd.handle, sym_link_path, .{});

    var result: w.HANDLE = undefined;
    const attr: w.OBJECT.ATTRIBUTES = .{
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(sym_link_path_w.span())) null else cwd.handle,
        .ObjectName = @constCast(&w.UNICODE_STRING.init(sym_link_path_w.span())),
    };
    var open_iosb: w.IO_STATUS_BLOCK = undefined;
    switch (w.ntdll.NtCreateFile(
        &result,
        .{ .GENERIC = .{ .READ = true, .WRITE = true }, .STANDARD = .{ .SYNCHRONIZE = true } },
        &attr,
        &open_iosb,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .CREATE,
        .{ .DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT },
        null,
        0,
    )) {
        .SUCCESS => {},
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        .ACCESS_DENIED => return error.AccessDenied,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .FILE_IS_A_DIRECTORY => return error.IsDir,
        .NOT_A_DIRECTORY => return error.NotDir,
        else => |status| return w.unexpectedStatus(status),
    }
    const junction_handle = result;
    defer w.CloseHandle(junction_handle);

    // The print name is the target as given (backslash-canonicalized, no NT
    // prefix) - the human-readable form Explorer shows as "Target:". The
    // substitute name is what the filesystem actually resolves and must be
    // the absolute NT-prefixed form.
    var target_path_w: std.Io.Threaded.WindowsPathSpace = undefined;
    target_path_w.len = try w.wtf8ToWtf16Le(&target_path_w.data, target);
    target_path_w.data[target_path_w.len] = 0;
    std.mem.replaceScalar(
        u16,
        target_path_w.data[0..target_path_w.len],
        std.mem.nativeToLittle(u16, '/'),
        std.mem.nativeToLittle(u16, '\\'),
    );

    const nt_prefix = [_]u16{ '\\', '?', '?', '\\' };
    var substitute: std.Io.Threaded.WindowsPathSpace = undefined;
    if (w.hasCommonNtPrefix(u16, target_path_w.data[0..target_path_w.len])) {
        @memcpy(substitute.data[0..target_path_w.len], target_path_w.data[0..target_path_w.len]);
        substitute.len = target_path_w.len;
    } else {
        substitute.data[0..nt_prefix.len].* = nt_prefix;
        @memcpy(substitute.data[nt_prefix.len..][0..target_path_w.len], target_path_w.data[0..target_path_w.len]);
        substitute.len = nt_prefix.len + target_path_w.len;
    }
    substitute.data[substitute.len] = 0;

    const MOUNT_POINT_DATA = extern struct {
        ReparseTag: w.IO_REPARSE_TAG,
        ReparseDataLength: w.USHORT,
        Reserved: w.USHORT,
        SubstituteNameOffset: w.USHORT,
        SubstituteNameLength: w.USHORT,
        PrintNameOffset: w.USHORT,
        PrintNameLength: w.USHORT,
        // PathBuffer: [SubstituteName\0][PrintName\0] (WTF-16LE), appended
        // after this header when building the wire buffer below.
    };

    const substitute_bytes: w.USHORT = @intCast(substitute.len * 2);
    const print_bytes: w.USHORT = @intCast(target_path_w.len * 2);
    const header_len = @sizeOf(w.ULONG) + @sizeOf(w.USHORT) * 2;
    const buf_len = @sizeOf(MOUNT_POINT_DATA) + substitute_bytes + 2 + print_bytes + 2;

    const mount_point_data: MOUNT_POINT_DATA = .{
        .ReparseTag = .MOUNT_POINT,
        .ReparseDataLength = @intCast(buf_len - header_len),
        .Reserved = 0,
        .SubstituteNameOffset = 0,
        .SubstituteNameLength = substitute_bytes,
        .PrintNameOffset = substitute_bytes + 2,
        .PrintNameLength = print_bytes,
    };

    var buffer: [w.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 = undefined;
    @memcpy(buffer[0..@sizeOf(MOUNT_POINT_DATA)], std.mem.asBytes(&mount_point_data));
    var offset: usize = @sizeOf(MOUNT_POINT_DATA);
    @memcpy(buffer[offset..][0..substitute_bytes], std.mem.sliceAsBytes(substitute.data[0..substitute.len]));
    offset += substitute_bytes;
    buffer[offset] = 0;
    buffer[offset + 1] = 0;
    offset += 2;
    @memcpy(buffer[offset..][0..print_bytes], std.mem.sliceAsBytes(target_path_w.data[0..target_path_w.len]));
    offset += print_bytes;
    buffer[offset] = 0;
    buffer[offset + 1] = 0;

    var ctl_iosb: w.IO_STATUS_BLOCK = undefined;
    switch (w.ntdll.NtFsControlFile(
        junction_handle,
        null,
        null,
        null,
        &ctl_iosb,
        .SET_REPARSE_POINT,
        buffer[0..buf_len].ptr,
        @intCast(buf_len),
        null,
        0,
    )) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .PRIVILEGE_NOT_HELD => return error.PermissionDenied,
        .ACCESS_DENIED => return error.AccessDenied,
        .INVALID_DEVICE_REQUEST => return error.FileSystem,
        else => |status| return w.unexpectedStatus(status),
    }
}

/// Removes `path` if it is now an empty directory - best-effort cleanup that
/// must never fail the caller's command. A directory still holding entries
/// (DirNotEmpty) or already gone (FileNotFound) is expected, not an error;
/// any other failure (permissions, races, ...) is likewise swallowed rather
/// than surfaced, since this is always cleanup after the operation that
/// actually mattered has already succeeded.
pub fn rmdirIfEmpty(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    const base = std.fs.path.basename(path);
    var parent_dir = std.Io.Dir.openDirAbsolute(io(), parent, .{}) catch return;
    defer parent_dir.close(io());
    parent_dir.deleteDir(io(), base) catch |err| switch (err) {
        error.DirNotEmpty, error.FileNotFound => {}, // dir has projects, or already gone
        else => {}, // best-effort cleanup must never fail the command
    };
}

test "tempDir honors the platform temp env var" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const key = if (builtin.os.tag == .windows) "TEMP" else "TMPDIR";
    const env = try testEnv(arena, &.{.{ key, "/some/tmp/dir" }});

    try testing.expectEqualStrings("/some/tmp/dir", try tempDir(arena, env));
}

test "expandTilde: ~ and ~/x expand via $HOME, other paths pass through" {
    var arena_home = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_home.deinit();
    const env = try testEnv(arena_home.allocator(), &.{.{ "HOME", "/home/me" }});
    const home = try env_zig.dirs.home(testing.allocator, env);
    defer testing.allocator.free(home);

    {
        const got = try expandTilde(testing.allocator, env, "~");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(home, got);
    }
    {
        const got = try expandTilde(testing.allocator, env, "~/x");
        defer testing.allocator.free(got);
        const want = try std.fs.path.join(testing.allocator, &.{ home, "x" });
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, got);
    }
    {
        const got = try expandTilde(testing.allocator, env, "/abs/path");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/abs/path", got);
    }
    {
        const got = try expandTilde(testing.allocator, env, "relative/path");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("relative/path", got);
    }
}

test "contractTilde: $HOME prefix becomes ~, boundary and outside paths are untouched" {
    // Arena: EnvOverride copies the whole environment and its restore does not
    // free it (it is built for arena callers), so bind it to one here.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const env = try testEnv(arena, &.{.{ "HOME", "/home/me" }});

    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "/home/me", .want = "~" },
        .{ .in = "/home/me/Code/x", .want = "~/Code/x" },
        // Boundary: a sibling that merely shares the prefix is not under $HOME.
        .{ .in = "/home/mext/x", .want = "/home/mext/x" },
        // Outside $HOME entirely.
        .{ .in = "/etc/passwd", .want = "/etc/passwd" },
    };
    for (cases) |c| {
        try testing.expectEqualStrings(c.want, try contractTilde(arena, env, c.in));
    }
}

test "contractTilde: a trailing separator on $HOME does not defeat the match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const env = try testEnv(arena, &.{.{ "HOME", "/home/me/" }});

    try testing.expectEqualStrings("~/Code", try contractTilde(arena, env, "/home/me/Code"));
}

test "toAbsolute: absolute input passes through, relative input joins the cwd" {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path = buf[0..try std.process.currentPath(io(), &buf)];

    {
        const abs_input = if (builtin.os.tag == .windows) "C:\\abs\\path" else "/abs/path";
        const want = try std.fs.path.resolve(testing.allocator, &.{abs_input});
        defer testing.allocator.free(want);
        const got = try toAbsolute(testing.allocator, abs_input);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
    }
    {
        const got = try toAbsolute(testing.allocator, "relative/path");
        defer testing.allocator.free(got);
        const want = try std.fs.path.join(testing.allocator, &.{ cwd_path, "relative", "path" });
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, got);
    }
    {
        const got = try toAbsolute(testing.allocator, ".");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(cwd_path, got);
    }
    {
        const got = try toAbsolute(testing.allocator, "a/../b");
        defer testing.allocator.free(got);
        const want = try std.fs.path.join(testing.allocator, &.{ cwd_path, "b" });
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, got);
    }
}

test "pathIsInside: lexical containment on resolved absolute paths" {
    const a_b = try std.fs.path.join(testing.allocator, &.{ "a", "b" });
    defer testing.allocator.free(a_b);
    const a_b_c = try std.fs.path.join(testing.allocator, &.{ "a", "b", "c" });
    defer testing.allocator.free(a_b_c);
    const a_bc = try std.fs.path.join(testing.allocator, &.{ "a", "bc" });
    defer testing.allocator.free(a_bc);

    try testing.expect(pathIsInside(a_b_c, a_b));
    try testing.expect(!pathIsInside(a_bc, a_b));
    try testing.expect(pathIsInside(a_b, a_b));
}

test "exists: true for a present path, false for a missing one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "present.txt", .data = "x" });
    const present = try std.fs.path.join(testing.allocator, &.{ root, "present.txt" });
    defer testing.allocator.free(present);
    try testing.expect(exists(present));

    const missing = try std.fs.path.join(testing.allocator, &.{ root, "missing.txt" });
    defer testing.allocator.free(missing);
    try testing.expect(!exists(missing));
}

test "writeFileAtomic: writes the data and leaves no temp file behind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const path = try std.fs.path.join(arena, &.{ root, "out.txt" });

    try writeFileAtomic(arena, path, "hello\n");

    const got = try std.Io.Dir.cwd().readFileAlloc(io(), path, arena, .limited(1 << 20));
    try testing.expectEqualStrings("hello\n", got);

    // No temp sibling survives a successful write.
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |entry| {
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
    }
}

test "ensureDir: mkpath, ok if already exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const nested = try std.fs.path.join(testing.allocator, &.{ root, "a", "b" });
    defer testing.allocator.free(nested);

    try ensureDir(nested);
    try ensureDir(nested);

    var dir = try std.Io.Dir.cwd().openDir(testing.io, nested, .{});
    dir.close(testing.io);
}

test "linkState: missing, regular file, symlink" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const missing_path = try std.fs.path.join(testing.allocator, &.{ root, "missing" });
    defer testing.allocator.free(missing_path);
    try testing.expectEqual(LinkState.missing, try linkState(testing.allocator, missing_path));

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "regular.txt", .data = "x" });
    const regular_path = try std.fs.path.join(testing.allocator, &.{ root, "regular.txt" });
    defer testing.allocator.free(regular_path);
    try testing.expectEqual(LinkState.other, try linkState(testing.allocator, regular_path));

    const link_path = try std.fs.path.join(testing.allocator, &.{ root, "link" });
    defer testing.allocator.free(link_path);
    try replaceSymlink("some-target", link_path);
    const state = try linkState(testing.allocator, link_path);
    switch (state) {
        .symlink => |t| {
            defer testing.allocator.free(t);
            try testing.expectEqualStrings("some-target", t);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "realPathOrSelf: resolves a symlink to its physical target, passes through a nonexistent path unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const target_dir = try std.fs.path.join(testing.allocator, &.{ root, "target" });
    defer testing.allocator.free(target_dir);
    try ensureDir(target_dir);

    const link_path = try std.fs.path.join(testing.allocator, &.{ root, "link" });
    defer testing.allocator.free(link_path);
    try replaceSymlink(target_dir, link_path);

    const resolved = try realPathOrSelf(testing.allocator, link_path);
    defer testing.allocator.free(resolved);
    try testing.expectEqualStrings(target_dir, resolved);

    const missing = try std.fs.path.join(testing.allocator, &.{ root, "does-not-exist" });
    defer testing.allocator.free(missing);
    const fallback = try realPathOrSelf(testing.allocator, missing);
    defer testing.allocator.free(fallback);
    try testing.expectEqualStrings(missing, fallback);
}

test "rmdirIfEmpty: removes an empty dir, leaves a non-empty one, no-ops on a missing one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const empty_dir = try std.fs.path.join(testing.allocator, &.{ root, "empty" });
    defer testing.allocator.free(empty_dir);
    try ensureDir(empty_dir);
    rmdirIfEmpty(empty_dir);
    try testing.expect(!exists(empty_dir));

    const nonempty_dir = try std.fs.path.join(testing.allocator, &.{ root, "nonempty" });
    defer testing.allocator.free(nonempty_dir);
    const child = try std.fs.path.join(testing.allocator, &.{ nonempty_dir, "child" });
    defer testing.allocator.free(child);
    try ensureDir(child);
    rmdirIfEmpty(nonempty_dir);
    try testing.expect(exists(nonempty_dir));

    const missing_dir = try std.fs.path.join(testing.allocator, &.{ root, "does-not-exist" });
    defer testing.allocator.free(missing_dir);
    rmdirIfEmpty(missing_dir);
}

/// Recursively copies `from` (a file, directory, or symlink) to `to`. `to`
/// must not already exist. Symlinks are recreated (not followed).
pub fn copyTree(alloc: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    if (exists(to)) return error.PathAlreadyExists;

    const cwd = std.Io.Dir.cwd();

    switch (try linkState(alloc, from)) {
        .symlink => |target| {
            try cwd.symLink(io(), target, to, .{});
            return;
        },
        else => {},
    }

    const stat = try cwd.statFile(io(), from, .{});
    if (stat.kind == .directory) {
        try ensureDir(to);
        var dir = try std.Io.Dir.openDirAbsolute(io(), from, .{ .iterate = true });
        defer dir.close(io());
        var it = dir.iterate();
        while (try it.next(io())) |entry| {
            const child_from = try std.fs.path.join(alloc, &.{ from, entry.name });
            const child_to = try std.fs.path.join(alloc, &.{ to, entry.name });
            try copyTree(alloc, child_from, child_to);
        }
        return;
    }

    try cwd.copyFile(from, cwd, to, io(), .{});
}

/// Moves `from` to `to`, falling back to copy+delete when the two paths live
/// on different filesystems (the hub is local disk, content is a cloud
/// mount, so a plain rename(2) across them fails with `error.CrossDevice`).
pub fn moveTree(alloc: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    if (std.fs.path.dirname(to)) |parent| try ensureDir(parent);
    std.Io.Dir.renameAbsolute(from, to, io()) catch |err| switch (err) {
        error.CrossDevice => {
            try copyTree(alloc, from, to);
            try std.Io.Dir.cwd().deleteTree(io(), from);
        },
        else => return err,
    };
}

test "copyTree: copies a file and a nested directory tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    // Source: a dir with a file and a subdir with a file.
    const src = try std.fs.path.join(arena, &.{ root, "src" });
    try ensureDir(try std.fs.path.join(arena, &.{ src, "sub" }));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "a.txt" }), .data = "a\n" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "sub", "b.txt" }), .data = "b\n" });

    const dst = try std.fs.path.join(arena, &.{ root, "dst" });
    try copyTree(arena, src, dst);

    const got_a = try std.Io.Dir.cwd().readFileAlloc(io(), try std.fs.path.join(arena, &.{ dst, "a.txt" }), arena, .limited(1 << 20));
    try testing.expectEqualStrings("a\n", got_a);
    const got_b = try std.Io.Dir.cwd().readFileAlloc(io(), try std.fs.path.join(arena, &.{ dst, "sub", "b.txt" }), arena, .limited(1 << 20));
    try testing.expectEqualStrings("b\n", got_b);
    // Original still there (copy, not move).
    try testing.expect(exists(try std.fs.path.join(arena, &.{ src, "a.txt" })));
}

test "copyTree: refuses a destination that already exists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const src_file = try std.fs.path.join(arena, &.{ root, "src.txt" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = src_file, .data = "src\n" });

    // Existing dest file: must not be silently overwritten.
    const dst_file = try std.fs.path.join(arena, &.{ root, "dst-file.txt" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = dst_file, .data = "pre-existing\n" });
    try testing.expectError(error.PathAlreadyExists, copyTree(arena, src_file, dst_file));
    const dst_file_contents = try std.Io.Dir.cwd().readFileAlloc(io(), dst_file, arena, .limited(1 << 20));
    try testing.expectEqualStrings("pre-existing\n", dst_file_contents);

    // Existing dest dir: must not be silently merged into.
    const src_dir = try std.fs.path.join(arena, &.{ root, "src-dir" });
    try ensureDir(src_dir);
    const dst_dir = try std.fs.path.join(arena, &.{ root, "dst-dir" });
    try ensureDir(dst_dir);
    try testing.expectError(error.PathAlreadyExists, copyTree(arena, src_dir, dst_dir));
}

test "copyTree: recreates a symlink rather than following it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const target_dir = try std.fs.path.join(arena, &.{ root, "target-dir" });
    try ensureDir(target_dir);

    const link_path = try std.fs.path.join(arena, &.{ root, "link" });
    try std.Io.Dir.cwd().symLink(io(), "target-dir", link_path, .{});

    const copy_path = try std.fs.path.join(arena, &.{ root, "link-copy" });
    try copyTree(arena, link_path, copy_path);

    const orig_state = try linkState(arena, link_path);
    const copy_state = try linkState(arena, copy_path);
    switch (copy_state) {
        .symlink => |copy_target| switch (orig_state) {
            .symlink => |orig_target| try testing.expectEqualStrings(orig_target, copy_target),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "moveTree: same-filesystem move removes the source" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const src = try std.fs.path.join(arena, &.{ root, "f.txt" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = src, .data = "hi\n" });
    const dst = try std.fs.path.join(arena, &.{ root, "moved.txt" });

    try moveTree(arena, src, dst);
    try testing.expect(exists(dst));
    try testing.expect(!exists(src));
}

test "replaceSymlink: overwrites an existing link pointing elsewhere" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const link_path = try std.fs.path.join(testing.allocator, &.{ root, "link" });
    defer testing.allocator.free(link_path);

    try replaceSymlink("wrong-target", link_path);
    try replaceSymlink("right-target", link_path);

    const state = try linkState(testing.allocator, link_path);
    switch (state) {
        .symlink => |t| {
            defer testing.allocator.free(t);
            try testing.expectEqualStrings("right-target", t);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "replaceLink: creates a working dir link and a working file link, returns .created" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    // A real directory target and a real file target.
    const dir_target = try std.fs.path.join(arena, &.{ root, "d" });
    try std.Io.Dir.cwd().createDirPath(io(), dir_target);
    const file_target = try std.fs.path.join(arena, &.{ root, "f" });
    try writeFileAtomic(arena, file_target, "x");

    const dir_link = try std.fs.path.join(arena, &.{ root, "d-link" });
    const file_link = try std.fs.path.join(arena, &.{ root, "f-link" });

    try testing.expectEqual(LinkResult.created, try replaceLink(dir_target, dir_link, true));
    try testing.expectEqual(LinkResult.created, try replaceLink(file_target, file_link, false));

    // Both links resolve to their targets' contents.
    try testing.expect(exists(dir_link));
    try testing.expect(exists(file_link));
}

test "replaceLink: overwrites an existing dir link pointing elsewhere" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const link_path = try std.fs.path.join(testing.allocator, &.{ root, "link" });
    defer testing.allocator.free(link_path);

    // On POSIX both calls take the symlink branch, so the second call
    // exercises the delete-then-recreate replace contract. The Windows
    // junction-overwrite path (deleteDir fallback on a mount-point reparse
    // point) is exercised only by the Windows CI suite.
    try testing.expectEqual(LinkResult.created, try replaceLink("wrong-target", link_path, true));
    try testing.expectEqual(LinkResult.created, try replaceLink("right-target", link_path, true));

    const state = try linkState(testing.allocator, link_path);
    switch (state) {
        .symlink => |t| {
            defer testing.allocator.free(t);
            try testing.expectEqualStrings("right-target", t);
        },
        else => return error.TestUnexpectedResult,
    }
}
