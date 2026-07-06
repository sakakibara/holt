//! `holt get <url> [--update]`: clones a repo standalone into the code tree
//! at its canonical host/owner/repo identity path, with no project marker and
//! no hub link.
//! For a project-attached clone use `new`/`add`/`adopt` instead. A
//! `local:<name>` argument is rejected - `get` takes a real remote URL.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const common = @import("common.zig");
const identity = @import("../identity.zig");
const git = @import("../git.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    url: args.Pos([]const u8, .{ .help = "a git url, or owner/repo (host/owner/repo) shorthand" }),
    update: args.Flag(.{ .short = 'u', .help = "fast-forward an existing clone instead of re-cloning" }),
};

pub const command = args.command(Spec, .{
    .name = "get",
    .about = "Clone a repo standalone into the code tree",
    .usage = "holt get <url> [--update]",
    .group = .create,
    .details =
    \\Clones <url> into <code_root>/<host>/<owner>/<repo> with no project
    \\attached - use `new`/`add`/`adopt` for project-attached repos. The clone
    \\path, derived from the remote, is stable and shared across projects. It is
    \\always the sole line on stdout - fresh, already present, or updated -
    \\so `cd $(holt get <url>)` works regardless; a status note ("already
    \\present" / "updated") goes to stderr instead. With --update, an
    \\existing clone is fast-forwarded rather than re-cloned.
    \\
    \\Example:
    \\  holt get https://github.com/acme/widget.git
    ,
    .needs_workspace = true,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const raw = a.url;
    const update = a.update;

    const ws = ctx.ws.?;
    const alloc = ctx.alloc;

    if (std.mem.startsWith(u8, raw, "local:")) {
        try ctx.err_w.print("holt: \"{s}\" is a local repo; use `holt adopt` to bring it into a project\n", .{raw});
        return 1;
    }

    // Expand "owner/repo" / "host/owner/repo" shorthand to a real clone URL.
    const url = identity.expand(alloc, raw) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err_w.print("holt: \"{s}\" is not a recognized git url\n", .{raw});
            return 1;
        },
        else => return err,
    };

    const id = try identity.fromUrl(alloc, url);

    const clone_path = try id.clonePath(alloc, ws.cfg.code_root);

    if (fsutil.exists(clone_path)) {
        // Guard the "already present" fast path against an interrupted clone:
        // a `.git` with no commits is not a usable clone to report or update.
        if (!try git.isCompleteClone(alloc, clone_path)) {
            try ctx.err_w.print("holt: clone at {s} looks incomplete (an interrupted clone?); remove it and retry\n", .{clone_path});
            return 1;
        }
        if (!update) {
            try ctx.out.print("{s}\n", .{clone_path});
            try ctx.err_w.print("already present\n", .{});
            return 0;
        }
        const res = try git.run(alloc, &.{ "git", "-C", clone_path, "pull", "--ff-only" }, null);
        if (res.status != 0) {
            const trimmed = std.mem.trim(u8, res.stderr, " \t\r\n");
            const cause = if (trimmed.len == 0) "git pull failed" else trimmed;
            try ctx.err_w.print("holt: failed to update {s}: {s}\n", .{ clone_path, cause });
            return 1;
        }
        try ctx.out.print("{s}\n", .{clone_path});
        try ctx.err_w.print("updated\n", .{});
        return 0;
    }

    _ = common.cloneIfAbsent(ctx, url, clone_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return 1,
    };

    try ctx.out.print("{s}\n", .{clone_path});
    return 0;
}

test "run: clones a url standalone to its identity path with no marker and no hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/widget";

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 0), got.code);

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(fsutil.exists(clone_path));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ clone_path, ".git" })));
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{clone_path}), got.out);

    // Standalone: no project marker anywhere and no hub tree at all.
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ clone_path, ".holt.json" })));
    try testing.expect(!fsutil.exists(ws.cfg.synced_root));
    try testing.expect(!fsutil.exists(ws.cfg.hub_root));
}

test "run: an incomplete existing clone is refused, not reported as already present" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/widget";

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(clone_path);
    try testutil.runGit(&sb, clone_path, &.{ "init", "-q" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "incomplete") != null);
    // It must NOT have been printed to stdout as a usable clone path.
    try testing.expect(std.mem.indexOf(u8, got.out, clone_path) == null);
}

test "run: a second get on a present clone is idempotent and does not re-clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/widget";

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const first = try testutil.runCmd(arena, command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 0), first.code);

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    const stat_before = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_path, .{});

    const second = try testutil.runCmd(arena, command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 0), second.code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{clone_path}), second.out);
    try testing.expect(std.mem.indexOf(u8, second.err, "already present") != null);

    const stat_after = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_path, .{});
    try testing.expectEqual(stat_before.inode, stat_after.inode);
}

test "run: --update fast-forwards a present clone to a new upstream commit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/widget";

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const first = try testutil.runCmd(arena, command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 0), first.code);

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);

    // Advance the bare's main by one commit from a throwaway clone, so the
    // ff-only pull has something real to fast-forward to.
    const push_clone = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(push_clone);
    {
        var d = try std.Io.Dir.cwd().openDir(fsutil.io(), push_clone, .{});
        defer d.close(fsutil.io());
        try d.writeFile(fsutil.io(), .{ .sub_path = "NEWFILE", .data = "upstream advance\n" });
    }
    try testutil.runGit(&sb, push_clone, &.{ "add", "NEWFILE" });
    try testutil.runGit(&sb, push_clone, &.{ "commit", "-m", "advance" });
    try testutil.runGit(&sb, push_clone, &.{ "push", "origin", "main" });

    const updated = try testutil.runCmd(arena, command.run, ws, &.{ url, "--update" });
    try testing.expectEqual(@as(u8, 0), updated.code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{clone_path}), updated.out);
    try testing.expect(std.mem.indexOf(u8, updated.err, "updated") != null);
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ clone_path, "NEWFILE" })));
}

test "run: a parseable but unreachable url surfaces git's cause, naming the url" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // Loopback with nothing listening: connection refused immediately, no
    // DNS or network dependency, so the failure is fast and deterministic.
    const url = "https://holt-test.invalid/x/y.git";
    const got = try testutil.runCmd(arena, command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, url) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "GitCloneFailed") == null);

    const id = try identity.fromUrl(arena, url);
    const owner_dir = try std.fs.path.join(arena, &.{ ws.cfg.code_root, id.host, id.owner });
    try testing.expect(!fsutil.exists(owner_dir));
}

test "run: a local: url is rejected pointing at the project commands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"local:scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "adopt") != null);
}
