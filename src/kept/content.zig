//! Filesystem primitives the kept store is built on: what sits at a path
//! (without following links), content hashes of files and trees, online-only
//! detection, regular-only copies, no-replace renames, and link creation.

const std = @import("std");
const builtin = @import("builtin");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const interrupt = @import("interrupt.zig");
const testing = std.testing;

const io = fsutil.io;

/// A kept path is linked as one file or one whole directory, like a hub
/// link.
pub const Kind = @import("../hub.zig").LinkKind;

pub const Entry = enum { absent, file, dir, symlink, other };

/// What is at `path`, without following a final symlink. A missing parent,
/// or a parent that is not a directory, reads as absent; `underNonDir`
/// tells the two apart.
pub fn entryAt(path: []const u8) !Entry {
    const st = std.Io.Dir.cwd().statFile(io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .absent,
        else => return err,
    };
    return switch (st.kind) {
        .file => .file,
        .directory => .dir,
        .sym_link => .symlink,
        else => .other,
    };
}

/// Whether the nearest ancestor of `path` that is there is not a
/// directory, a symlink followed: a file, or a symlink to nothing or to
/// what is not a directory, under which nothing can be made at `path`.
/// False when that ancestor is a directory, or when none is there.
pub fn underNonDir(path: []const u8) !bool {
    var at = path;
    while (std.fs.path.dirname(at)) |parent| {
        at = parent;
        switch (try entryAt(at)) {
            .absent => continue,
            .dir => return false,
            .symlink => {
                const st = std.Io.Dir.cwd().statFile(io(), at, .{}) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => return true,
                    else => return err,
                };
                return st.kind != .directory;
            },
            .file, .other => return true,
        }
    }
    return false;
}

/// True when `path` is present only as a cloud placeholder whose content is
/// not on this machine: macOS `SF_DATALESS`, the Windows offline and recall
/// attributes, or an iCloud `.<name>.icloud` sibling standing in for an
/// absent `path`. Nothing is read, so nothing is downloaded.
pub fn isOnlineOnly(alloc: std.mem.Allocator, path: []const u8) bool {
    if (builtin.os.tag.isDarwin()) {
        const z = alloc.dupeZ(u8, path) catch return false;
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, z, &st, std.c.AT.SYMLINK_NOFOLLOW) == 0) {
            const sf_dataless: u32 = 0x40000000;
            return st.flags & sf_dataless != 0;
        }
    } else if (builtin.os.tag == .windows) {
        const w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch return false;
        const attrs = GetFileAttributesW(w.ptr);
        if (attrs != 0xFFFFFFFF) {
            const offline: u32 = 0x1000;
            const recall_on_open: u32 = 0x40000;
            const recall_on_data_access: u32 = 0x400000;
            return attrs & (offline | recall_on_open | recall_on_data_access) != 0;
        }
    }
    return hasIcloudPlaceholder(alloc, path);
}

/// True when `path` is absent and iCloud's `.<name>.icloud` placeholder
/// stands beside it.
pub fn hasIcloudPlaceholder(alloc: std.mem.Allocator, path: []const u8) bool {
    if ((entryAt(path) catch return false) != .absent) return false;
    const parent = std.fs.path.dirname(path) orelse return false;
    const base = std.fs.path.basename(path);
    const ph_name = std.fmt.allocPrint(alloc, ".{s}.icloud", .{base}) catch return false;
    const ph = std.fs.path.join(alloc, &.{ parent, ph_name }) catch return false;
    return (entryAt(ph) catch return false) == .file;
}

extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;

/// True when `a` and `b` name one filesystem object: the same device and
/// inode, or on Windows the same volume and file id. Neither is followed
/// if it is a link. False when either is absent. On Windows, a path that
/// is present but cannot be opened or identified counts as the same file,
/// so a failure to compare never reads as two files.
pub fn sameFile(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const ia = (try fileId(alloc, a)) orelse return false;
    const ib = (try fileId(alloc, b)) orelse return false;
    if (builtin.is_test and unknown_ids_for_test) return true;
    if (ia.form == .unknown or ib.form == .unknown or ia.form != ib.form) return true;
    return ia.dev == ib.dev and ia.ino == ib.ino;
}

/// Test seam: every file present is one whose id cannot be read, as on a
/// Windows filesystem that cannot identify it.
pub var unknown_ids_for_test = false;

/// Whether `a` and `b` are known to name one filesystem object, as
/// `sameFile` compares them, except that two objects either of which
/// cannot be identified are not.
pub fn knownSameFile(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const ia = (try fileId(alloc, a)) orelse return false;
    const ib = (try fileId(alloc, b)) orelse return false;
    if (builtin.is_test and unknown_ids_for_test) return false;
    if (ia.form == .unknown or ib.form == .unknown or ia.form != ib.form) return false;
    return ia.dev == ib.dev and ia.ino == ib.ino;
}

/// The filesystem holding `path`, not followed if it is a link: its device
/// or volume id. Null when absent or when the platform cannot identify it.
pub fn deviceOf(alloc: std.mem.Allocator, path: []const u8) !?u64 {
    const got = (try fileId(alloc, path)) orelse return null;
    return if (got.form == .unknown) null else got.dev;
}

const FoldCache = struct {
    lock: std.atomic.Mutex = .unlocked,
    devs: [32]u64 = undefined,
    got: [32]paths.Folding = undefined,
    len: usize = 0,

    fn find(c: *FoldCache, dev: u64) ?paths.Folding {
        while (!c.lock.tryLock()) std.atomic.spinLoopHint();
        defer c.lock.unlock();
        for (c.devs[0..c.len], c.got[0..c.len]) |d, g| if (d == dev) return g;
        return null;
    }

    fn put(c: *FoldCache, dev: u64, f: paths.Folding) void {
        while (!c.lock.tryLock()) std.atomic.spinLoopHint();
        defer c.lock.unlock();
        if (c.len == c.devs.len) return;
        c.devs[c.len] = dev;
        c.got[c.len] = f;
        c.len += 1;
    }
};

var fold_cache: FoldCache = .{};

/// How the filesystem `dev` (`deviceOf`) compares names, when this process
/// has already probed it.
pub fn knownFolding(dev: ?u64) ?paths.Folding {
    return fold_cache.find(dev orelse return null);
}

/// Records how the filesystem `dev` compares names, for `knownFolding`.
pub fn rememberFolding(dev: ?u64, f: paths.Folding) void {
    fold_cache.put(dev orelse return, f);
}

/// How the filesystem holding the directory `dir` compares names, probed
/// once per filesystem for the process (`probeFoldingAs`) under a fresh
/// `paths.probeName`. A probe that fails is not remembered.
pub fn probeFolding(alloc: std.mem.Allocator, dir: []const u8) !paths.Folding {
    if (builtin.is_test) if (paths.folding_for_test) |f| return f;
    const real = try fsutil.realPathOrSelf(alloc, dir);
    const dev = try deviceOf(alloc, real);
    if (knownFolding(dev)) |f| return f;
    const got = try probeFoldingAs(alloc, real, try paths.probeName(alloc, randomSuffix()));
    rememberFolding(dev, got);
    return got;
}

/// Creates the file `name` in the directory `dir`, looks it up under its
/// case-swapped and its decomposed spellings, and removes it. The error
/// when it cannot be created.
pub fn probeFoldingAs(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !paths.Folding {
    if (builtin.is_test) if (paths.folding_for_test) |f| return f;
    const probe = try std.fs.path.join(alloc, &.{ dir, name });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = probe, .data = "", .flags = .{ .exclusive = true } });
    defer fsutil.removePath(probe) catch {};
    const swapped = try alloc.dupe(u8, name);
    for (swapped) |*c| {
        if (std.ascii.isLower(c.*)) c.* = std.ascii.toUpper(c.*) else if (std.ascii.isUpper(c.*)) c.* = std.ascii.toLower(c.*);
    }
    return .{
        .case = try entryAt(try std.fs.path.join(alloc, &.{ dir, swapped })) != .absent,
        .norm = try entryAt(try std.fs.path.join(alloc, &.{ dir, try paths.nfd(alloc, name) })) != .absent,
    };
}

const FileId = struct {
    dev: u64,
    ino: u128,
    /// Which identity `dev` and `ino` are: Windows has a 128-bit file id
    /// with a 64-bit volume serial and, on older filesystems, only a 64-bit
    /// index with a 32-bit one. Ids of different forms are not compared.
    form: enum { unix, wide, narrow, unknown } = .unix,

    const unknown: FileId = .{ .dev = 0, .ino = 0, .form = .unknown };
};

fn fileId(alloc: std.mem.Allocator, path: []const u8) !?FileId {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const z = try alloc.dupeZ(u8, path);
        var sx: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .INO = true }, &sx);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .dev = (@as(u64, sx.dev_major) << 32) | sx.dev_minor, .ino = sx.ino },
            .NOENT, .NOTDIR => null,
            .ACCES, .PERM => error.AccessDenied,
            else => |e| std.posix.unexpectedErrno(e),
        };
    } else if (builtin.os.tag.isDarwin()) {
        const z = try alloc.dupeZ(u8, path);
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, z, &st, std.c.AT.SYMLINK_NOFOLLOW) == 0) {
            return .{ .dev = @as(u32, @bitCast(st.dev)), .ino = st.ino };
        }
        return switch (std.c.errno(-1)) {
            .NOENT, .NOTDIR => null,
            .ACCES, .PERM => error.AccessDenied,
            else => |e| std.posix.unexpectedErrno(e),
        };
    } else if (builtin.os.tag == .windows) {
        return windowsFileId(alloc, path);
    }
    const st = std.Io.Dir.cwd().statFile(io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    return .{ .dev = 0, .ino = @intCast(st.inode) };
}

/// The identity of the object at `path`, opened in the long-path form
/// without following a link: the 128-bit file id and 64-bit volume serial
/// where the filesystem has them, else the 64-bit index. Null when absent;
/// `FileId.unknown` when it cannot be opened or identified otherwise.
fn windowsFileId(alloc: std.mem.Allocator, path: []const u8) !?FileId {
    const long = try windowsLongPath(alloc, try std.fs.path.resolveWindows(alloc, &.{path}));
    const w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, long) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return FileId.unknown,
    };
    const file_read_attributes: u32 = 0x80;
    const share_all: u32 = 0x7;
    const open_existing: u32 = 3;
    const backup_semantics_open_reparse_point: u32 = 0x02000000 | 0x00200000;
    const h = CreateFileW(w.ptr, file_read_attributes, share_all, null, open_existing, backup_semantics_open_reparse_point, null);
    if (h == std.os.windows.INVALID_HANDLE_VALUE) {
        return switch (GetLastError()) {
            2, 3 => null,
            else => FileId.unknown,
        };
    }
    defer _ = CloseHandle(h);
    return windowsHandleId(h);
}

/// The identity of the object the open handle `h` is on, as
/// `windowsFileId` reads it.
fn windowsHandleId(h: std.os.windows.HANDLE) FileId {
    var wide: FileIdInfo = undefined;
    const file_id_info: u32 = 18;
    if (GetFileInformationByHandleEx(h, file_id_info, &wide, @sizeOf(FileIdInfo)) != 0) {
        return .{ .dev = wide.volume_serial, .ino = std.mem.readInt(u128, &wide.file_id, .little), .form = .wide };
    }
    var info: ByHandleFileInformation = undefined;
    if (GetFileInformationByHandle(h, &info) == 0) return FileId.unknown;
    return .{ .dev = info.volume_serial, .ino = (@as(u64, info.index_high) << 32) | info.index_low, .form = .narrow };
}

/// Whether `file` is still open on the object at `path`, not followed if
/// it is a link: the same device and inode, or on Windows the same volume
/// and file id. False when `file` has been closed, when `path` is absent,
/// or when either cannot be identified.
pub fn handleIs(alloc: std.mem.Allocator, file: std.Io.File, path: []const u8) !bool {
    const want = (fileId(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    }) orelse return false;
    const got = handleId(file) orelse return false;
    if (want.form == .unknown or got.form == .unknown or want.form != got.form) return false;
    return want.dev == got.dev and want.ino == got.ino;
}

/// The identity of the object `file` is open on, or null when it is not
/// open.
fn handleId(file: std.Io.File) ?FileId {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &sx);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .dev = (@as(u64, sx.dev_major) << 32) | sx.dev_minor, .ino = sx.ino };
    } else if (builtin.os.tag.isDarwin()) {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(file.handle, &st) != 0) return null;
        return .{ .dev = @as(u32, @bitCast(st.dev)), .ino = st.ino };
    } else if (builtin.os.tag == .windows) {
        const got = windowsHandleId(file.handle);
        return if (got.form == .unknown) null else got;
    }
    const st = file.stat(io()) catch return null;
    return .{ .dev = 0, .ino = @intCast(st.inode) };
}

/// Whether the entry at `path`, which reads as a link, is on Windows a
/// directory whose reparse point is not a link: a cloud file placeholder,
/// or any tag but `IO_REPARSE_TAG_SYMLINK` and `IO_REPARSE_TAG_MOUNT_POINT`.
/// Always false elsewhere, and when it cannot be read.
pub fn isPlainReparseDir(alloc: std.mem.Allocator, path: []const u8) !bool {
    if (builtin.os.tag != .windows) return false;
    const long = try windowsLongPath(alloc, try std.fs.path.resolveWindows(alloc, &.{path}));
    const w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, long) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    const file_read_attributes: u32 = 0x80;
    const share_all: u32 = 0x7;
    const open_existing: u32 = 3;
    const backup_semantics_open_reparse_point: u32 = 0x02000000 | 0x00200000;
    const h = CreateFileW(w.ptr, file_read_attributes, share_all, null, open_existing, backup_semantics_open_reparse_point, null);
    if (h == std.os.windows.INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(h);
    var info: extern struct { attributes: u32, reparse_tag: u32 } = undefined;
    const file_attribute_tag_info: u32 = 9;
    if (GetFileInformationByHandleEx(h, file_attribute_tag_info, &info, @sizeOf(@TypeOf(info))) == 0) return false;
    const directory: u32 = 0x10;
    const reparse_point: u32 = 0x400;
    const tag_symlink: u32 = 0xA000000C;
    const tag_mount_point: u32 = 0xA0000003;
    if (info.attributes & directory == 0 or info.attributes & reparse_point == 0) return false;
    return info.reparse_tag != tag_symlink and info.reparse_tag != tag_mount_point;
}

/// `abs`, an absolute Windows path with either separator, in the `\\?\`
/// form that lifts the `MAX_PATH` limit: `\\?\C:\...`, or
/// `\\?\UNC\server\share\...` for a UNC path; a path already in that form
/// or the `\\.\` device form only has its separators made `\`. The form
/// turns off Windows' own path parsing, so `abs` must already be resolved.
pub fn windowsLongPath(alloc: std.mem.Allocator, abs: []const u8) ![]u8 {
    const p = try alloc.dupe(u8, abs);
    std.mem.replaceScalar(u8, p, '/', '\\');
    if (std.mem.startsWith(u8, p, "\\\\?\\") or std.mem.startsWith(u8, p, "\\\\.\\")) return p;
    if (std.mem.startsWith(u8, p, "\\\\")) return std.mem.concat(alloc, u8, &.{ "\\\\?\\UNC\\", p[2..] });
    return std.mem.concat(alloc, u8, &.{ "\\\\?\\", p });
}

const FileIdInfo = extern struct {
    volume_serial: u64,
    file_id: [16]u8,
};

const ByHandleFileInformation = extern struct {
    attributes: u32,
    creation: [2]u32,
    access: [2]u32,
    write: [2]u32,
    volume_serial: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn GetFileInformationByHandle(h: std.os.windows.HANDLE, info: *ByHandleFileInformation) callconv(.winapi) i32;
extern "kernel32" fn GetFileInformationByHandleEx(h: std.os.windows.HANDLE, class: u32, info: *anyopaque, size: u32) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(h: std.os.windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// Gives each regular file at `to` the executable bits its counterpart at
/// `from` has and it lacks, leaving its content alone: `from` and `to` are
/// two files, or two directories holding the same paths. Nothing happens on
/// a platform without executable bits. No other attribute is carried.
/// Returns false when a file refused the change (a backend that does not
/// keep modes); every other file is still given its bits.
pub fn carryExecutable(alloc: std.mem.Allocator, from: []const u8, to: []const u8) !bool {
    return walkExecutable(alloc, from, to, .carry);
}

/// Whether every executable bit a regular file at `from` has is also set
/// on its counterpart at `to` (`carryExecutable`'s shapes). Always true on
/// a platform without executable bits.
pub fn executableCarried(alloc: std.mem.Allocator, from: []const u8, to: []const u8) !bool {
    return walkExecutable(alloc, from, to, .check);
}

fn walkExecutable(alloc: std.mem.Allocator, from: []const u8, to: []const u8, how: ExecAction) !bool {
    if (!std.Io.File.Permissions.has_executable_bit) return true;
    switch (try entryAt(from)) {
        .file => return executableFile(from, to, how),
        .dir => {
            var all = true;
            for ((try treeFilesNoHash(alloc, from)).files) |f| {
                if (!try executableFile(try fsutil.joinSlashy(alloc, from, f), try fsutil.joinSlashy(alloc, to, f), how)) all = false;
            }
            return all;
        },
        else => return true,
    }
}

const ExecAction = enum { carry, check };

/// Test seam: every change of a file's mode fails, as on a backend that
/// refuses chmod.
pub var chmod_fails_for_test = false;

fn executableFile(from: []const u8, to: []const u8, how: ExecAction) !bool {
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.statFile(io(), from, .{ .follow_symlinks = false });
    const dst = cwd.statFile(io(), to, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    if (src.kind != .file or dst.kind != .file) return true;
    const want: u32 = @intCast(@intFromEnum(src.permissions) & 0o111);
    const have: u32 = @intCast(@intFromEnum(dst.permissions) & 0o7777);
    if (have & want == want) return true;
    if (how == .check) return false;
    if (builtin.is_test and chmod_fails_for_test) return false;
    cwd.setFilePermissions(io(), to, @enumFromInt(have | want), .{ .follow_symlinks = false }) catch return false;
    return true;
}

pub const Hash = struct { kind: Kind, hex: [64]u8 };

/// One regular file of a tree: its `/`-joined path under the tree's root and
/// its content hash.
pub const FileHash = struct { path: []const u8, hex: [64]u8 };

/// Hex SHA-256 of the regular file at `path`. Refuses a placeholder.
pub fn hashFile(alloc: std.mem.Allocator, path: []const u8) ![64]u8 {
    if (isOnlineOnly(alloc, path)) return error.OnlineOnly;
    var file = try std.Io.Dir.cwd().openFile(io(), path, .{});
    defer file.close(io());
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositional(io(), &.{&buf}, offset);
        if (n == 0) break;
        h.update(buf[0..n]);
        offset += n;
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// Every regular file under the directory `root`, sorted by path, with its
/// hash. A symlink or non-regular entry anywhere is `NotRegular`; an
/// online-only file or an iCloud placeholder is `OnlineOnly`.
pub fn treeFiles(alloc: std.mem.Allocator, root: []const u8) ![]FileHash {
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var out: std.ArrayList(FileHash) = .empty;
    while (try walker.next(io())) |entry| {
        switch (entry.kind) {
            .directory => continue,
            .file => {},
            else => return error.NotRegular,
        }
        if (std.mem.startsWith(u8, entry.basename, ".") and std.mem.endsWith(u8, entry.basename, ".icloud")) {
            return error.OnlineOnly;
        }
        const native = try std.fs.path.join(alloc, &.{ root, entry.path });
        const rel = try alloc.dupe(u8, entry.path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        try out.append(alloc, .{ .path = rel, .hex = try hashFile(alloc, native) });
    }
    std.mem.sort(FileHash, out.items, {}, fileLess);
    return out.items;
}

/// Why `treeFilesPartial` left an entry out.
pub const Skip = enum {
    symlink,
    not_regular,
    online_only,
    unreadable,
    /// A name Windows cannot hold (`paths.windowsUnsafe`).
    windows_name,
    /// A nested repository (`isNestedRepo`).
    nested_repository,
};

/// An entry of a tree `treeFilesPartial` left out: its `/`-joined path
/// under the tree's root, and why.
pub const Skipped = struct { path: []const u8, why: Skip };

pub const Partial = struct { files: []FileHash, skipped: []Skipped };

/// Every regular file under the directory `root` that can be read, sorted
/// by path, with its hash, and every entry that cannot be, sorted: a
/// symlink, a special file, an online-only file or iCloud placeholder, a
/// file or directory that cannot be opened, a nested repository
/// (`isNestedRepo`, under the working tree's `core.ignorecase`,
/// `ignore_case`; left out whole), and, when `windows_names`, a name
/// Windows cannot hold. Nothing is followed or downloaded. `root` itself
/// being a nested repository is `NestedRepository`.
pub fn treeFilesPartial(alloc: std.mem.Allocator, root: []const u8, windows_names: bool, ignore_case: bool) !Partial {
    var files: std.ArrayList(FileHash) = .empty;
    var skipped: std.ArrayList(Skipped) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(alloc, "");
    while (pending.pop()) |sub| {
        const here = if (sub.len == 0) root else try fsutil.joinSlashy(alloc, root, sub);
        var dir = std.Io.Dir.cwd().openDir(io(), here, .{ .iterate = true }) catch |err| {
            if (sub.len == 0) return err;
            try skipped.append(alloc, .{ .path = sub, .why = .unreadable });
            continue;
        };
        defer dir.close(io());
        const Found = struct { name: []const u8, kind: std.Io.File.Kind };
        var found: std.ArrayList(Found) = .empty;
        var it = dir.iterate();
        var listed = true;
        while (it.next(io()) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            listed = false;
            break :blk null;
        }) |e| try found.append(alloc, .{ .name = try alloc.dupe(u8, e.name), .kind = e.kind });
        if (!listed) {
            if (sub.len == 0) return error.AccessDenied;
            try skipped.append(alloc, .{ .path = sub, .why = .unreadable });
            continue;
        }
        const nested = for (found.items) |f| {
            if (paths.isWalkDotGit(f.name, ignore_case)) break true;
        } else dotGitResolves(alloc, here) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => true,
        };
        if (nested) {
            if (sub.len == 0) return error.NestedRepository;
            try skipped.append(alloc, .{ .path = sub, .why = .nested_repository });
            continue;
        }
        for (found.items) |f| {
            const rel = if (sub.len == 0) f.name else try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sub, f.name });
            const why: Skip = switch (f.kind) {
                .directory => {
                    try pending.append(alloc, rel);
                    continue;
                },
                .sym_link => .symlink,
                .file => if (windows_names and paths.windowsUnsafe(f.name))
                    .windows_name
                else if (std.mem.startsWith(u8, f.name, ".") and std.mem.endsWith(u8, f.name, ".icloud"))
                    .online_only
                else if (hashFile(alloc, try std.fs.path.join(alloc, &.{ here, f.name }))) |hex| {
                    try files.append(alloc, .{ .path = rel, .hex = hex });
                    continue;
                } else |err| switch (err) {
                    error.OnlineOnly => .online_only,
                    else => .unreadable,
                },
                else => .not_regular,
            };
            try skipped.append(alloc, .{ .path = rel, .why = why });
        }
    }
    std.mem.sort(FileHash, files.items, {}, fileLess);
    std.mem.sort(Skipped, skipped.items, {}, struct {
        fn less(_: void, x: Skipped, y: Skipped) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.less);
    return .{ .files = files.items, .skipped = skipped.items };
}

/// Whether the directory `root` holds anything but directories, at any
/// depth. A directory that cannot be read counts as holding something.
pub fn holdsAnything(alloc: std.mem.Allocator, root: []const u8) !bool {
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(alloc, root);
    while (pending.pop()) |here| {
        var dir = std.Io.Dir.cwd().openDir(io(), here, .{ .iterate = true }) catch return true;
        defer dir.close(io());
        var it = dir.iterate();
        while (it.next(io()) catch return true) |e| {
            if (e.kind != .directory) return true;
            try pending.append(alloc, try std.fs.path.join(alloc, &.{ here, e.name }));
        }
    }
    return false;
}

/// Whether `path` is a regular file holding nothing, not followed if it is
/// a link.
pub fn isEmptyFile(path: []const u8) !bool {
    const st = std.Io.Dir.cwd().statFile(io(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return st.kind == .file and st.size == 0;
}

/// Whether the directory `dir_path` is a nested repository, as git's own
/// walk decides for a directory: it holds an entry the walk skips as `.git`
/// under the working tree's `core.ignorecase`, `ignore_case`
/// (`paths.isWalkDotGit`), or `<dir_path>/.git` names anything on the
/// filesystem (`dotGitResolves`), as a case- or normalization-insensitive
/// filesystem finds it under another spelling.
pub fn isNestedRepo(alloc: std.mem.Allocator, dir_path: []const u8, ignore_case: bool) !bool {
    if (try dotGitResolves(alloc, dir_path)) return true;
    var dir = try std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true });
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |e| {
        if (paths.isWalkDotGit(e.name, ignore_case)) return true;
    }
    return false;
}

/// Whether `<dir_path>/.git` names anything on the filesystem, links not
/// followed. The error when it cannot be looked up.
pub fn dotGitResolves(alloc: std.mem.Allocator, dir_path: []const u8) !bool {
    return try entryAt(try std.fs.path.join(alloc, &.{ dir_path, ".git" })) != .absent;
}

/// The nested repositories at or below the directory `root`: each
/// directory `isNestedRepo` counts, `/`-joined relative to
/// `root` (`""` for `root` itself), shallowest first and in name order
/// within a level, none looked into, at most `limit` of them. Links are not
/// followed, and a directory that cannot be read is passed over.
pub fn nestedRepos(alloc: std.mem.Allocator, root: []const u8, ignore_case: bool, limit: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.append(alloc, "");
    var i: usize = 0;
    while (i < queue.items.len and out.items.len < limit) : (i += 1) {
        const here = queue.items[i];
        const here_path = if (here.len == 0) root else try fsutil.joinSlashy(alloc, root, here);
        const resolves = dotGitResolves(alloc, here_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => false,
        };
        if (resolves) {
            try out.append(alloc, here);
            continue;
        }
        var d = std.Io.Dir.cwd().openDir(io(), here_path, .{ .iterate = true }) catch continue;
        defer d.close(io());
        var subs: std.ArrayList([]const u8) = .empty;
        var repo = false;
        var it = d.iterate();
        while (it.next(io()) catch null) |e| {
            if (paths.isWalkDotGit(e.name, ignore_case)) {
                repo = true;
                break;
            }
            if (e.kind == .directory) try subs.append(alloc, if (here.len == 0) try alloc.dupe(u8, e.name) else try std.mem.concat(alloc, u8, &.{ here, "/", e.name }));
        }
        if (repo) {
            try out.append(alloc, here);
            continue;
        }
        std.mem.sort([]const u8, subs.items, {}, paths.lessThan);
        try queue.appendSlice(alloc, subs.items);
    }
    return out.items;
}

/// The permission bits of the regular file at `path`, `0o777` at most; 0
/// on a platform without executable bits.
pub fn modeOf(path: []const u8) !u32 {
    if (!std.Io.File.Permissions.has_executable_bit) return 0;
    const st = try std.Io.Dir.cwd().statFile(io(), path, .{ .follow_symlinks = false });
    return @intCast(@intFromEnum(st.permissions) & 0o777);
}

/// Path order of tree files, for `std.mem.sort`.
pub fn fileLess(_: void, a: FileHash, b: FileHash) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// The hash of a directory's content: SHA-256 over each file's path and
/// hash in path order. Empty directories do not contribute.
pub fn treeHash(files: []const FileHash) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (files) |f| {
        h.update(f.path);
        h.update(&.{0});
        h.update(&f.hex);
        h.update(&.{0});
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// The kind and content hash of the file or directory at `path`, which is
/// not followed if it is a link.
pub fn hashPath(alloc: std.mem.Allocator, path: []const u8) !Hash {
    return switch (try entryAt(path)) {
        .file => .{ .kind = .file, .hex = try hashFile(alloc, path) },
        .dir => .{ .kind = .dir, .hex = treeHash(try treeFiles(alloc, path)) },
        .absent => if (hasIcloudPlaceholder(alloc, path)) error.OnlineOnly else error.FileNotFound,
        .symlink, .other => error.NotRegular,
    };
}

/// Copies the file or directory at `from` to `to`, which must not exist.
/// Only regular files and directories are copied: a link or special file
/// anywhere is `NotRegular`, found before anything is written.
pub fn copyRegular(alloc: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    if (try entryAt(to) != .absent) return error.PathAlreadyExists;
    const cwd = std.Io.Dir.cwd();
    switch (try entryAt(from)) {
        .file => try cwd.copyFile(from, cwd, to, io(), .{}),
        .dir => {
            const files = try treeFilesNoHash(alloc, from);
            try fsutil.ensureDir(to);
            for (files.dirs) |d| try fsutil.ensureDir(try fsutil.joinSlashy(alloc, to, d));
            for (files.files) |f| {
                try cwd.copyFile(try fsutil.joinSlashy(alloc, from, f), cwd, try fsutil.joinSlashy(alloc, to, f), io(), .{});
            }
        },
        .absent => return error.FileNotFound,
        .symlink, .other => return error.NotRegular,
    }
}

const Listing = struct { dirs: []const []const u8, files: []const []const u8 };

fn treeFilesNoHash(alloc: std.mem.Allocator, root: []const u8) !Listing {
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var dirs: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io())) |entry| {
        const rel = try alloc.dupe(u8, entry.path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        switch (entry.kind) {
            .directory => try dirs.append(alloc, rel),
            .file => try files.append(alloc, rel),
            else => return error.NotRegular,
        }
    }
    return .{ .dirs = dirs.items, .files = files.items };
}

/// Renames `from` to `to` only if nothing is at `to`: `renamex_np
/// RENAME_EXCL` on macOS, `renameat2 RENAME_NOREPLACE` on Linux, a
/// non-replacing move on Windows. Where the filesystem supports none of
/// these, a file is hard-linked then unlinked and a directory is renamed,
/// which the kernel refuses over any non-empty entry. Something at `to` is
/// `PathAlreadyExists`.
pub fn renameNoReplace(alloc: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const cwd = std.Io.Dir.cwd();
        return cwd.renamePreserve(from, cwd, to, io()) catch |err| switch (err) {
            error.AccessDenied => if (try entryAt(to) != .absent) error.PathAlreadyExists else err,
            else => err,
        };
    }
    const from_z = try alloc.dupeZ(u8, from);
    const to_z = try alloc.dupeZ(u8, to);
    if (builtin.os.tag.isDarwin()) {
        const rename_excl: c_uint = 0x00000004;
        if (renamex_np(from_z, to_z, rename_excl) == 0) return;
        switch (std.c.errno(-1)) {
            .EXIST, .NOTEMPTY => return error.PathAlreadyExists,
            .NOENT => return error.FileNotFound,
            .OPNOTSUPP, .INVAL, .NOSYS => {},
            .XDEV => return error.CrossDevice,
            .ACCES, .PERM => return error.AccessDenied,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    } else if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.renameat2(linux.AT.FDCWD, from_z, linux.AT.FDCWD, to_z, .{ .NOREPLACE = true });
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .EXIST, .NOTEMPTY => return error.PathAlreadyExists,
            .NOENT => return error.FileNotFound,
            .INVAL, .NOSYS, .OPNOTSUPP => {},
            .XDEV => return error.CrossDevice,
            .ACCES, .PERM => return error.AccessDenied,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
    return renameNoReplaceFallback(from, to);
}

extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;

/// Test seam: every `renameExchange` is `Unsupported`, as on a platform
/// or filesystem without one.
pub var no_exchange_for_test = false;

/// Swaps what is at `a` and `b` in one step: `renamex_np RENAME_SWAP` on
/// macOS, `renameat2 RENAME_EXCHANGE` on Linux. `Unsupported` where the
/// platform or filesystem has neither, and nothing moves.
pub fn renameExchange(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !void {
    if (builtin.is_test and no_exchange_for_test) return error.Unsupported;
    const a_z = try alloc.dupeZ(u8, a);
    const b_z = try alloc.dupeZ(u8, b);
    if (builtin.os.tag.isDarwin()) {
        const rename_swap: c_uint = 0x00000002;
        if (renamex_np(a_z, b_z, rename_swap) == 0) return;
        return switch (std.c.errno(-1)) {
            .OPNOTSUPP, .INVAL, .NOSYS => error.Unsupported,
            .NOENT => error.FileNotFound,
            .XDEV => error.CrossDevice,
            .ACCES, .PERM => error.AccessDenied,
            else => |e| std.posix.unexpectedErrno(e),
        };
    } else if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = linux.renameat2(linux.AT.FDCWD, a_z, linux.AT.FDCWD, b_z, .{ .EXCHANGE = true });
        return switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INVAL, .NOSYS, .OPNOTSUPP => error.Unsupported,
            .NOENT => error.FileNotFound,
            .XDEV => error.CrossDevice,
            .ACCES, .PERM => error.AccessDenied,
            else => |e| std.posix.unexpectedErrno(e),
        };
    }
    return error.Unsupported;
}

fn renameNoReplaceFallback(from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (try entryAt(to) != .absent) return error.PathAlreadyExists;
    switch (try entryAt(from)) {
        .dir => cwd.rename(from, cwd, to, io()) catch |err| switch (err) {
            error.DirNotEmpty, error.NotDir, error.IsDir => return error.PathAlreadyExists,
            else => return err,
        },
        .absent => return error.FileNotFound,
        else => {
            cwd.hardLink(from, cwd, to, io(), .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.PathAlreadyExists => return error.PathAlreadyExists,
                else => return err,
            };
            try cwd.deleteFile(io(), from);
        },
    }
}

/// A fresh random name component for temporaries.
pub fn randomSuffix() [16]u8 {
    var bytes: [8]u8 = undefined;
    io().random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// A path beside `path`, in the same directory and so on the same
/// filesystem, that nothing occupies yet.
pub fn tempSibling(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(path) orelse ".";
    const suffix = randomSuffix();
    return std.fs.path.join(alloc, &.{ parent, try std.fmt.allocPrint(alloc, ".holt-tmp-{s}", .{&suffix}) });
}

/// Test seam: every `createLink` fails with `SymlinkPrivilege`, as on a
/// Windows machine without Developer Mode.
pub var no_symlinks_for_test = false;

/// Test seam: every `createLink` to an absolute target stores it spelled
/// `/./<target>`, naming the same place, as Windows may store a target in
/// another spelling than the one given.
pub var respell_links_for_test = false;

/// Creates a symlink at `link_path` pointing at `target`; on Windows a real
/// symlink of the matching kind, never a junction. `SymlinkPrivilege` means
/// Windows refused for lack of Developer Mode.
pub const LinkError = std.Io.Dir.SymLinkError || error{SymlinkPrivilege};

pub fn createLink(target: []const u8, link_path: []const u8, kind: Kind) LinkError!void {
    if (builtin.is_test and no_symlinks_for_test) return error.SymlinkPrivilege;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const spelled = if (builtin.is_test and respell_links_for_test and target.len > 0 and target[0] == '/' and target.len + 2 <= buf.len) blk: {
        @memcpy(buf[0..2], "/.");
        @memcpy(buf[2 .. 2 + target.len], target);
        break :blk buf[0 .. 2 + target.len];
    } else target;
    std.Io.Dir.cwd().symLink(io(), spelled, link_path, .{ .is_directory = kind == .dir }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => if (builtin.os.tag == .windows) return error.SymlinkPrivilege else return err,
        else => return err,
    };
}

/// Creates and removes a link of `kind` in the directory `dir`, so a
/// caller learns whether it can link before it moves anything.
/// `SymlinkPrivilege` when this machine cannot create symlinks.
pub fn probeLink(alloc: std.mem.Allocator, dir: []const u8, kind: Kind) !void {
    try fsutil.ensureDir(dir);
    const suffix = randomSuffix();
    const probe = try std.fs.path.join(alloc, &.{ dir, try std.fmt.allocPrint(alloc, ".holt-probe-{s}", .{&suffix}) });
    try createLink(dir, probe, kind);
    try fsutil.removePath(probe);
}

/// Points the link at `link_path`, which must still read `expect_raw`, at
/// `target`. On POSIX the new link is made at `temp_path` beside it and
/// renamed over it, so the path is never absent. Anything else at
/// `link_path` is `LinkChanged`, and nothing is touched.
pub fn retargetLink(alloc: std.mem.Allocator, target: []const u8, link_path: []const u8, temp_path: []const u8, kind: Kind, expect_raw: []const u8) !void {
    if (builtin.os.tag == .windows) {
        if (!try isLinkTo(alloc, link_path, expect_raw)) return error.LinkChanged;
        try fsutil.removePath(link_path);
        return createLink(target, link_path, kind);
    }
    try createLink(target, temp_path, kind);
    try interrupt.check(.retarget_created);
    if (!try isLinkTo(alloc, link_path, expect_raw)) {
        try fsutil.removePath(temp_path);
        return error.LinkChanged;
    }
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), link_path, io());
}

/// Removes the link at `path` only if its raw target is still `raw`.
/// Returns whether it did.
pub fn removeLinkIf(alloc: std.mem.Allocator, path: []const u8, raw: []const u8) !bool {
    if (!try isLinkTo(alloc, path, raw)) return false;
    try fsutil.removePath(path);
    return true;
}

/// True when `path` is a link whose raw target is exactly `raw`.
pub fn isLinkTo(alloc: std.mem.Allocator, path: []const u8, raw: []const u8) !bool {
    const now = (try readLink(alloc, path)) orelse return false;
    return std.mem.eql(u8, now, raw);
}

/// The first path under the directory `root`, `/`-joined, whose name holt
/// reserves, or null when there is none.
pub fn findReserved(alloc: std.mem.Allocator, root: []const u8) !?[]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io())) |entry| {
        if (!paths.isReserved(entry.basename)) continue;
        const rel = try alloc.dupe(u8, entry.path);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        return rel;
    }
    return null;
}

/// Every entry under the directory `root`, `/`-joined and sorted, whose
/// name a kept path may not hold: one `paths.check` refuses (a `.holt-`
/// name, a name git treats as `.git` (a nested repository), a backslash, a
/// control character, invalid UTF-8), or one equal to a sibling's under
/// case folding or Unicode normalization, each of which is listed. Nothing
/// below such a directory is listed.
pub fn invalidNames(alloc: std.mem.Allocator, root: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(alloc, "");
    while (pending.pop()) |sub| {
        var dir = try std.Io.Dir.cwd().openDir(io(), if (sub.len == 0) root else try fsutil.joinSlashy(alloc, root, sub), .{ .iterate = true });
        defer dir.close(io());
        var names: std.ArrayList([]const u8) = .empty;
        var dirs: std.ArrayList(bool) = .empty;
        var it = dir.iterate();
        while (try it.next(io())) |e| {
            try names.append(alloc, try alloc.dupe(u8, e.name));
            try dirs.append(alloc, e.kind == .directory);
        }
        var valid: std.ArrayList([]const u8) = .empty;
        for (names.items) |n| if (paths.check(n) == null) try valid.append(alloc, n);
        const colliding = try paths.collisions(alloc, valid.items);
        for (names.items, dirs.items) |n, is_dir| {
            const rel = if (sub.len == 0) n else try std.fmt.allocPrint(alloc, "{s}/{s}", .{ sub, n });
            if (paths.check(n) != null or paths.contains(colliding, n)) {
                try out.append(alloc, rel);
            } else if (is_dir) try pending.append(alloc, rel);
        }
    }
    std.mem.sort([]const u8, out.items, {}, paths.lessThan);
    return out.items;
}

/// The raw target of the link at `path`, or null when `path` is not a link.
pub fn readLink(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    return switch (try fsutil.linkState(alloc, path)) {
        .symlink => |t| t,
        else => null,
    };
}

/// Reads `path` whole. For the kept store's small marker files.
pub fn readSmall(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, alloc, .limited(1 << 20));
}

const Fixture = @import("harness.zig").Fixture;

test "entryAt: absent, file, dir, symlink, and a path under a file" {
    var f = try Fixture.init();
    defer f.deinit();

    _ = try f.write("f", "x");
    try fsutil.ensureDir(try f.path("d"));
    try createLink(try f.path("f"), try f.path("l"), .file);

    try testing.expectEqual(Entry.absent, try entryAt(try f.path("missing")));
    try testing.expectEqual(Entry.file, try entryAt(try f.path("f")));
    try testing.expectEqual(Entry.dir, try entryAt(try f.path("d")));
    try testing.expectEqual(Entry.symlink, try entryAt(try f.path("l")));
    try testing.expectEqual(Entry.absent, try entryAt(try f.path("f/below")));
}

test "underNonDir: a path under a file, or a symlink to nothing or to a file, is; one under a directory, or a symlink to one, is not" {
    var f = try Fixture.init();
    defer f.deinit();

    _ = try f.write("f", "x");
    try fsutil.ensureDir(try f.path("d"));
    try createLink(try f.path("f"), try f.path("to-file"), .file);
    try createLink(try f.path("d"), try f.path("to-dir"), .dir);
    try createLink(try f.path("no-such"), try f.path("to-nothing"), .dir);

    for ([_][]const u8{ "f/below", "f/below/deeper", "to-file/below", "to-nothing/below/deeper" }) |rel| {
        try testing.expect(try underNonDir(try f.path(rel)));
    }
    for ([_][]const u8{ "missing", "missing/below", "d/below", "d/missing/below", "to-dir/below" }) |rel| {
        try testing.expect(!try underNonDir(try f.path(rel)));
    }
}

test "sameFile: one object under two names, never through a link, never when absent" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const one = try f.write("one", "x");
    const other = try f.write("other", "x");
    try std.Io.Dir.cwd().hardLink(one, std.Io.Dir.cwd(), try f.path("hard"), io(), .{});
    try createLink(one, try f.path("soft"), .file);
    try testing.expect(try sameFile(a, one, try f.path("hard")));
    try testing.expect(!try sameFile(a, one, other));
    try testing.expect(!try sameFile(a, one, try f.path("soft")));
    try testing.expect(!try sameFile(a, one, try f.path("missing")));
}

test "probeFoldingAs: agrees with what the directory does to other spellings, and leaves nothing behind" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const got = try probeFoldingAs(a, f.root, try paths.probeName(a, randomSuffix()));
    _ = try f.write("Probe-caf\u{e9}", "");
    try testing.expectEqual(try entryAt(try f.path("pROBE-caf\u{e9}")) != .absent, got.case);
    try testing.expectEqual(try entryAt(try f.path("Probe-cafe\u{301}")) != .absent, got.norm);
    try fsutil.removePath(try f.path("Probe-caf\u{e9}"));
    var d = try std.Io.Dir.cwd().openDir(io(), f.root, .{ .iterate = true });
    defer d.close(io());
    var it = d.iterate();
    try testing.expect((try it.next(io())) == null);
}

test "windowsLongPath: a drive path and a UNC path take the long form once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("\\\\?\\C:\\code\\a\\b", try windowsLongPath(a, "C:\\code/a\\b"));
    try testing.expectEqualStrings("\\\\?\\UNC\\server\\share\\x", try windowsLongPath(a, "\\\\server\\share/x"));
    try testing.expectEqualStrings("\\\\?\\C:\\x", try windowsLongPath(a, "\\\\?\\C:\\x"));
}

test "hashPath: a file hashes its bytes; equal trees hash equal; a changed or added file changes the hash" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();

    _ = try f.write("f", "");
    const fh = try hashPath(a, try f.path("f"));
    try testing.expectEqual(Kind.file, fh.kind);
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &fh.hex);

    _ = try f.write("one/a", "1");
    _ = try f.write("one/sub/b", "2");
    _ = try f.write("two/a", "1");
    _ = try f.write("two/sub/b", "2");
    const h1 = try hashPath(a, try f.path("one"));
    const h2 = try hashPath(a, try f.path("two"));
    try testing.expectEqual(Kind.dir, h1.kind);
    try testing.expectEqualStrings(&h1.hex, &h2.hex);

    _ = try f.write("two/sub/b", "3");
    try testing.expect(!std.mem.eql(u8, &h1.hex, &(try hashPath(a, try f.path("two"))).hex));
    _ = try f.write("two/sub/b", "2");
    _ = try f.write("two/c", "");
    try testing.expect(!std.mem.eql(u8, &h1.hex, &(try hashPath(a, try f.path("two"))).hex));
}

test "hashPath and copyRegular: a symlink inside a tree is refused before anything is copied" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();

    _ = try f.write("t/a", "1");
    try createLink("/nowhere", try f.path("t/l"), .file);
    const t = try f.path("t");
    try testing.expectError(error.NotRegular, hashPath(a, t));
    const dst = try f.path("copy");
    try testing.expectError(error.NotRegular, copyRegular(a, t, dst));
    try testing.expectEqual(Entry.absent, try entryAt(dst));
}

test "hashPath: an iCloud placeholder is online-only, never read" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();

    _ = try f.write("..clasp.json.icloud", "placeholder");
    const p = try f.path(".clasp.json");
    try testing.expect(isOnlineOnly(a, p));
    try testing.expectError(error.OnlineOnly, hashPath(a, p));

    _ = try f.write("d/.x.icloud", "placeholder");
    try testing.expectError(error.OnlineOnly, hashPath(a, try f.path("d")));
}

test "copyRegular: copies a tree and refuses an existing destination" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();

    _ = try f.write("src/a", "1");
    _ = try f.write("src/deep/b", "2");
    try fsutil.ensureDir(try f.path("src/empty"));
    const src = try f.path("src");
    const dst = try f.path("dst");
    try copyRegular(a, src, dst);
    try testing.expectEqualStrings(&(try hashPath(a, src)).hex, &(try hashPath(a, dst)).hex);
    try testing.expectEqual(Entry.dir, try entryAt(try f.path("dst/empty")));
    try testing.expectError(error.PathAlreadyExists, copyRegular(a, src, dst));
}

test "renameNoReplace: moves into an empty slot, refuses an occupied one for files and directories" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();

    _ = try f.write("f1", "one");
    _ = try f.write("f2", "two");
    try testing.expectError(error.PathAlreadyExists, renameNoReplace(a, try f.path("f1"), try f.path("f2")));
    try testing.expectEqualStrings("two", try readSmall(a, try f.path("f2")));
    try renameNoReplace(a, try f.path("f1"), try f.path("f3"));
    try testing.expectEqualStrings("one", try readSmall(a, try f.path("f3")));
    try testing.expectEqual(Entry.absent, try entryAt(try f.path("f1")));

    _ = try f.write("d1/x", "x");
    try fsutil.ensureDir(try f.path("d2"));
    try testing.expectError(error.PathAlreadyExists, renameNoReplace(a, try f.path("d1"), try f.path("d2")));
    try testing.expectError(error.PathAlreadyExists, renameNoReplace(a, try f.path("d1"), try f.path("f2")));
    try renameNoReplace(a, try f.path("d1"), try f.path("d3"));
    try testing.expectEqualStrings("x", try readSmall(a, try f.path("d3/x")));
}

test "retargetLink: the link ends pointing at the new target, and a link that changed is left alone" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();

    const l = try f.path("l");
    const t = try f.path(".holt-tmp-l");
    try createLink("/old", l, .file);
    try testing.expectError(error.LinkChanged, retargetLink(a, "/new", l, t, .file, "/other"));
    try testing.expectEqualStrings("/old", (try readLink(a, l)).?);
    try testing.expectEqual(Entry.absent, try entryAt(t));
    try retargetLink(a, "/new", l, t, .file, "/old");
    try testing.expectEqualStrings("/new", (try readLink(a, l)).?);
    try testing.expectEqual(Entry.absent, try entryAt(t));
}

test "renameExchange: a directory and a link trade places" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    _ = try f.write("d/x", "x");
    try createLink("/somewhere", try f.path("l"), .dir);
    renameExchange(a, try f.path("d"), try f.path("l")) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqual(Entry.dir, try entryAt(try f.path("l")));
    try testing.expectEqualStrings("x", try readSmall(a, try f.path("l/x")));
    try testing.expectEqualStrings("/somewhere", (try readLink(a, try f.path("d"))).?);

    no_exchange_for_test = true;
    defer no_exchange_for_test = false;
    try testing.expectError(error.Unsupported, renameExchange(a, try f.path("d"), try f.path("l")));
}

test "removeLinkIf: removes the link only while it still names the target" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const l = try f.path("l");
    try createLink("/one", l, .file);
    try testing.expect(!try removeLinkIf(a, l, "/two"));
    try testing.expectEqual(Entry.symlink, try entryAt(l));
    try testing.expect(try removeLinkIf(a, l, "/one"));
    try testing.expectEqual(Entry.absent, try entryAt(l));
    _ = try f.write("l", "a file");
    try testing.expect(!try removeLinkIf(a, l, "/one"));
    try testing.expectEqual(Entry.file, try entryAt(l));
}

test "findReserved: names the first reserved entry below a directory" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    _ = try f.write("d/ok/file", "x");
    try testing.expect((try findReserved(a, try f.path("d"))) == null);
    _ = try f.write("d/ok/.holt-kept.json", "{}");
    try testing.expectEqualStrings("ok/.holt-kept.json", (try findReserved(a, try f.path("d"))).?);
}

test "probeLink: fails before anything moves when links cannot be made" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    try probeLink(a, try f.path("state"), .file);
    no_symlinks_for_test = true;
    defer no_symlinks_for_test = false;
    try testing.expectError(error.SymlinkPrivilege, probeLink(a, try f.path("state"), .dir));
}

test "treeFilesPartial: a directory is left out as a nested repository only where git's walk skips a `.git` in it or the filesystem finds one there" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    _ = try f.write("d/alias/git~1/HEAD", "git's NTFS alias, a name like any other here");
    _ = try f.write("d/case/.GIT/HEAD", "a case spelling");
    _ = try f.write("d/plain/.git/HEAD", "a .git");
    const root = try f.path("d");
    const sensitive = try @import("harness.zig").caseSensitive(a, root);

    for ([_]bool{ false, true }) |ic| {
        const got = try treeFilesPartial(a, root, false, ic);
        var files: std.ArrayList([]const u8) = .empty;
        for (got.files) |fh| try files.append(a, fh.path);
        var nested: std.ArrayList([]const u8) = .empty;
        for (got.skipped) |sk| if (sk.why == .nested_repository) try nested.append(a, sk.path);
        try testing.expect(paths.contains(files.items, "alias/git~1/HEAD"));
        try testing.expect(paths.contains(nested.items, "plain"));
        const case_nested = ic or !sensitive;
        try testing.expectEqual(case_nested, paths.contains(nested.items, "case"));
        try testing.expectEqual(!case_nested, paths.contains(files.items, "case/.GIT/HEAD"));
    }
}

test "handleIs: an open file matches its own path only, and a closed one matches none" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const one = try f.write("one", "x");
    const other = try f.write("other", "x");
    const file = try std.Io.Dir.cwd().openFile(io(), one, .{});
    try testing.expect(try handleIs(a, file, one));
    try testing.expect(!try handleIs(a, file, other));
    try testing.expect(!try handleIs(a, file, try f.path("missing")));
    file.close(io());
    try testing.expect(!try handleIs(a, file, one));
}
