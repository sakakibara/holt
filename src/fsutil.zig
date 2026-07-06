const std = @import("std");
const testing = std.testing;

/// The process has no `Io` threaded down to it from `main`, so filesystem
/// and environment access here goes through the default singleton that
/// Zig's startup code populates with the real argv/environ before `main` runs.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn homeDirAlloc(alloc: std.mem.Allocator) ![]u8 {
    return std.process.Environ.getAlloc(std.Io.Threaded.global_single_threaded.environ.process_environ, alloc, "HOME");
}

/// Expands a leading "~" (home directory) or "~/rest" (home-relative path)
/// using $HOME. Any other path, absolute or relative, is duped unchanged.
/// Caller owns the returned memory.
pub fn expandTilde(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.eql(u8, path, "~") and !std.mem.startsWith(u8, path, "~/")) {
        return alloc.dupe(u8, path);
    }
    const home = try homeDirAlloc(alloc);
    defer alloc.free(home);
    if (path.len == 1) return alloc.dupe(u8, home);
    return std.fs.path.join(alloc, &.{ home, path[2..] });
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
    std.Io.Dir.accessAbsolute(io(), path, .{}) catch return false;
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
        else => return err,
    };
    return alloc.dupe(u8, buf[0..n]);
}

pub const LinkState = union(enum) {
    missing,
    symlink: []const u8,
    other,
};

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

test "expandTilde: ~ and ~/x expand via $HOME, other paths pass through" {
    const home = try homeDirAlloc(testing.allocator);
    defer testing.allocator.free(home);

    {
        const got = try expandTilde(testing.allocator, "~");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(home, got);
    }
    {
        const got = try expandTilde(testing.allocator, "~/x");
        defer testing.allocator.free(got);
        const want = try std.fs.path.join(testing.allocator, &.{ home, "x" });
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, got);
    }
    {
        const got = try expandTilde(testing.allocator, "/abs/path");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/abs/path", got);
    }
    {
        const got = try expandTilde(testing.allocator, "relative/path");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("relative/path", got);
    }
}

test "toAbsolute: absolute input passes through, relative input joins the cwd" {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path = buf[0..try std.process.currentPath(io(), &buf)];

    {
        const got = try toAbsolute(testing.allocator, "/abs/path");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/abs/path", got);
    }
    {
        const got = try toAbsolute(testing.allocator, "relative/path");
        defer testing.allocator.free(got);
        const want = try std.fs.path.join(testing.allocator, &.{ cwd_path, "relative/path" });
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
    try testing.expect(pathIsInside("/a/b/c", "/a/b"));
    try testing.expect(!pathIsInside("/a/bc", "/a/b"));
    try testing.expect(pathIsInside("/a/b", "/a/b"));
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
