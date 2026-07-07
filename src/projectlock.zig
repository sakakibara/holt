//! Serializes concurrent mutation of one project's marker across holt
//! processes. Every single-project mutator holds an exclusive advisory lock
//! for the duration of its load-modify-save, so two `holt` runs touching the
//! same project cannot interleave and silently drop each other's edit
//! (last-writer-wins on the marker). The lock lives in a local, never-synced
//! runtime dir keyed by a hash of the project's content path; the kernel
//! releases it if the holding process dies, so a crash never wedges a project.

const std = @import("std");
const fsutil = @import("fsutil.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

pub const Handle = struct {
    file: std.Io.File,

    /// Releases the lock. Closing the fd drops the advisory lock; the empty
    /// lock file is intentionally left on disk to be reused next time.
    pub fn release(self: Handle) void {
        self.file.close(fsutil.io());
    }
};

/// Blocks until it holds the exclusive lock for the project whose content dir
/// is `content_path`, then returns a handle whose `release` drops it. Two
/// processes resolving the same project derive the same lock file, so their
/// critical sections run one at a time.
pub fn acquire(alloc: std.mem.Allocator, content_path: []const u8) !Handle {
    const lock_path = try lockPath(alloc, content_path);
    const file = try std.Io.Dir.createFileAbsolute(fsutil.io(), lock_path, .{ .truncate = false, .lock = .exclusive });
    return .{ .file = file };
}

/// `<runtime>/holt-locks/holt-<hash>.lock`, where `<runtime>` is a local dir
/// that is never part of a synced tree, so lock files are never cloud-synced.
/// The lock dir is created if absent. Exposed for tests.
fn lockPath(alloc: std.mem.Allocator, content_path: []const u8) ![]const u8 {
    const base = try fsutil.tempDir(alloc);
    const dir = try std.fs.path.join(alloc, &.{ base, "holt-locks" });
    try fsutil.ensureDir(dir);

    const key = std.hash.Wyhash.hash(0, content_path);
    const filename = try std.fmt.allocPrint(alloc, "holt-{x}.lock", .{key});
    return std.fs.path.join(alloc, &.{ dir, filename });
}

test "acquire: a held lock blocks a second acquirer; releasing frees it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Point TMPDIR at a throwaway dir so the test never touches a real lock.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const override = try testutil.EnvOverride.install(arena, "TMPDIR", root);
    defer override.restore();

    const content_path = "/some/project/acme/widget";

    var first = try acquire(arena, content_path);

    // While held, a non-blocking exclusive open of the same lock file must
    // report the lock as taken rather than succeed.
    const path = try lockPath(arena, content_path);
    try testing.expectError(error.WouldBlock, std.Io.Dir.createFileAbsolute(fsutil.io(), path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }));

    // After release, the same lock is acquirable again.
    first.release();
    var second = try acquire(arena, content_path);
    second.release();
}
