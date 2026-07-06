//! Recoverability gate every clone-moving operation (promote, adopt, sync
//! promotions) consults before discarding a clone: spec S9.3 step 3 requires
//! callers to refuse a destructive move unless `--force` when the verdict
//! isn't safe.

const std = @import("std");
const git = @import("git.zig");
const testing = std.testing;

pub const Blocker = enum { dirty, stashes, unpushed, no_upstream, unreadable };

pub const Verdict = struct {
    blockers: std.ArrayListUnmanaged(Blocker),

    pub fn safe(self: @This()) bool {
        return self.blockers.items.len == 0;
    }

    pub fn render(self: @This(), w: *std.Io.Writer) !void {
        for (self.blockers.items) |b| {
            try w.writeAll(switch (b) {
                .dirty => "uncommitted changes present\n",
                .stashes => "stash entries present\n",
                .unpushed => "unpushed commits present\n",
                .no_upstream => "current branch has no upstream to push to\n",
                .unreadable => "repository is unreadable\n",
            });
        }
    }
};

/// Collects every blocker in `repo_path` that would make a destructive move
/// lossy: uncommitted changes, stashes, or commits/branches not on a remote.
pub fn check(alloc: std.mem.Allocator, repo_path: []const u8) !Verdict {
    var blockers: std.ArrayListUnmanaged(Blocker) = .empty;

    if (!try git.inspectable(alloc, repo_path)) {
        try blockers.append(alloc, .unreadable);
        return .{ .blockers = blockers };
    }

    if (try git.isDirty(alloc, repo_path)) try blockers.append(alloc, .dirty);
    if (try git.hasStashes(alloc, repo_path)) try blockers.append(alloc, .stashes);
    switch (try git.unpushed(alloc, repo_path)) {
        .ahead => try blockers.append(alloc, .unpushed),
        .no_upstream => try blockers.append(alloc, .no_upstream),
        .clean => {},
    }

    return .{ .blockers = blockers };
}

const fsutil = @import("fsutil.zig");
const testutil = @import("testutil.zig");

test "check: a fresh clone is safe" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    var verdict = try check(testing.allocator, work);
    defer verdict.blockers.deinit(testing.allocator);
    try testing.expect(verdict.safe());
}

test "check: an untracked file marks the clone dirty" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });

    var verdict = try check(testing.allocator, work);
    defer verdict.blockers.deinit(testing.allocator);
    try testing.expect(!verdict.safe());
    try testing.expectEqual(1, verdict.blockers.items.len);
    try testing.expectEqual(Blocker.dirty, verdict.blockers.items[0]);
}

test "check: a stash entry blocks recovery" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "changed\n" });
    try testutil.runGit(&sb, work, &.{"stash"});

    var verdict = try check(testing.allocator, work);
    defer verdict.blockers.deinit(testing.allocator);
    try testing.expect(!verdict.safe());
    try testing.expectEqual(1, verdict.blockers.items.len);
    try testing.expectEqual(Blocker.stashes, verdict.blockers.items[0]);
}

test "check: a local commit not yet pushed blocks recovery" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "changed\n" });
    try testutil.runGit(&sb, work, &.{ "commit", "-am", "local change" });

    var verdict = try check(testing.allocator, work);
    defer verdict.blockers.deinit(testing.allocator);
    try testing.expect(!verdict.safe());
    try testing.expectEqual(1, verdict.blockers.items.len);
    try testing.expectEqual(Blocker.unpushed, verdict.blockers.items[0]);
}

test "check: a branch with no upstream blocks recovery" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    try testutil.runGit(&sb, work, &.{ "checkout", "-b", "feature" });

    var verdict = try check(testing.allocator, work);
    defer verdict.blockers.deinit(testing.allocator);
    try testing.expect(!verdict.safe());
    try testing.expectEqual(1, verdict.blockers.items.len);
    try testing.expectEqual(Blocker.no_upstream, verdict.blockers.items[0]);
}

test "check: a corrupted .git directory is unreadable and blocks recovery" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    const head_path = try std.fs.path.join(testing.allocator, &.{ work, ".git", "HEAD" });
    defer testing.allocator.free(head_path);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = head_path, .data = "garbage, not a ref\n" });

    var verdict = try check(testing.allocator, work);
    defer verdict.blockers.deinit(testing.allocator);
    try testing.expect(!verdict.safe());
    try testing.expectEqual(1, verdict.blockers.items.len);
    try testing.expectEqual(Blocker.unreadable, verdict.blockers.items[0]);
}

test "render: writes one line per blocker present" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    // Stashing a tracked change leaves the untracked file behind, so dirty,
    // stashes, and unpushed are all present at once for this clone.
    var work_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), work, .{});
    defer work_dir.close(fsutil.io());
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });
    try work_dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "changed\n" });
    try testutil.runGit(&sb, work, &.{ "stash", "push", "--", "README" });
    try testutil.runGit(&sb, work, &.{ "commit", "--allow-empty", "-m", "local change" });

    var verdict = try check(testing.allocator, work);
    defer verdict.blockers.deinit(testing.allocator);
    try testing.expectEqual(3, verdict.blockers.items.len);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try verdict.render(&aw.writer);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "uncommitted changes present") != null);
    try testing.expect(std.mem.indexOf(u8, out, "stash entries present") != null);
    try testing.expect(std.mem.indexOf(u8, out, "unpushed commits present") != null);
}
