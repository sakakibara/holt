//! End-to-end integration test: drives the real command table (the same one
//! `main.zig` registers with the process) through `cli.dispatchTo`, with a
//! config file loaded from disk exactly as a real invocation would. Every
//! other test in this tree calls a command's `run` directly against a
//! hand-built `Ctx`, which never exercises command-table registration or
//! `config.loadDefault` - this is the one seam that catches a command
//! missing from the table or a broken cross-command filesystem contract.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const main = @import("main.zig");
const marker = @import("marker.zig");
const fsutil = @import("fsutil.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

const Result = struct { code: u8, out: []const u8, err: []const u8 };

fn dispatch(arena: std.mem.Allocator, argv: []const []const u8) Result {
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    const code = cli.dispatchTo(testing.allocator, argv, &main.command_table, &out.writer, &err_w.writer, false);
    return .{ .code = code, .out = out.written(), .err = err_w.written() };
}

fn writeConfig(alloc: std.mem.Allocator, xdg_config_home: []const u8, synced_root: []const u8, code_root: []const u8, hub_root: []const u8) !void {
    const holt_dir = try std.fs.path.join(alloc, &.{ xdg_config_home, "holt" });
    try fsutil.ensureDir(holt_dir);
    const config_path = try std.fs.path.join(alloc, &.{ holt_dir, "config.toml" });
    const content = try std.fmt.allocPrint(alloc,
        \\[workspace]
        \\synced_root = "{s}"
        \\code_root = "{s}"
        \\hub_root = "{s}"
        \\
    , .{ synced_root, code_root, hub_root });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = config_path, .data = content });
}

// identity.fromUrl only accepts a remote-shaped url, never a bare local path,
// so fake holt-test.invalid urls are rewritten via a git insteadOf config to
// real hermetic bare repos for the process's git children. XDG_CONFIG_HOME
// rides along in the same overridden environ so config.loadDefault (which
// dispatchTo calls for real, unlike every other command test) finds our
// fixture config instead of the developer's real one. Both are restored
// after the test.
const EnvOverride = struct {
    original: std.process.Environ,

    fn install(
        alloc: std.mem.Allocator,
        gitconfig_path: []const u8,
        xdg_config_home: []const u8,
        pairs: []const struct { url: []const u8, bare: []const u8 },
    ) !EnvOverride {
        var content: std.ArrayList(u8) = .empty;
        for (pairs) |pair| {
            try content.appendSlice(alloc, try std.fmt.allocPrint(alloc, "[url \"{s}\"]\n\tinsteadOf = {s}\n", .{ pair.bare, pair.url }));
        }
        try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = gitconfig_path, .data = content.items });

        const singleton = std.Io.Threaded.global_single_threaded;
        const original = singleton.environ.process_environ;
        if (builtin.os.tag != .windows) {
            var map = try std.process.Environ.createMap(singleton.environ.process_environ, alloc);
            try map.put("GIT_CONFIG_GLOBAL", gitconfig_path);
            try map.put("XDG_CONFIG_HOME", xdg_config_home);
            const block = try map.createPosixBlock(alloc, .{});
            singleton.environ.process_environ = .{ .block = block };
        }
        return .{ .original = original };
    }

    fn restore(self: EnvOverride) void {
        std.Io.Threaded.global_single_threaded.environ.process_environ = self.original;
    }
};

fn expectSymlink(arena: std.mem.Allocator, path: []const u8) !void {
    switch (try fsutil.linkState(arena, path)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "integration: new -> add -> rm -> archive -> restore -> delete through the real command table and dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_a = try testutil.makeBareRepo(&sb, "a.git");
    defer testing.allocator.free(bare_a);
    const bare_b = try testutil.makeBareRepo(&sb, "b.git");
    defer testing.allocator.free(bare_b);

    const synced_root = try std.fs.path.join(arena, &.{ sb.root, "synced" });
    const code_root = try std.fs.path.join(arena, &.{ sb.root, "code" });
    const hub_root = try std.fs.path.join(arena, &.{ sb.root, "hub" });
    const xdg_config_home = try std.fs.path.join(arena, &.{ sb.root, "xdg-config" });
    try writeConfig(arena, xdg_config_home, synced_root, code_root, hub_root);

    const url_a = "https://holt-test.invalid/acme/alpha";
    const url_b = "https://holt-test.invalid/acme/beta";
    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try EnvOverride.install(arena, gitconfig_path, xdg_config_home, &.{
        .{ .url = url_a, .bare = bare_a },
        .{ .url = url_b, .bare = bare_b },
    });
    defer override.restore();

    const clone_alpha = try std.fs.path.join(arena, &.{ code_root, "holt-test.invalid", "acme", "alpha" });
    const clone_beta = try std.fs.path.join(arena, &.{ code_root, "holt-test.invalid", "acme", "beta" });
    const marker_path_proj = try std.fs.path.join(arena, &.{ synced_root, "projects", "acme", "proj", marker.marker_basename });
    const marker_path_other = try std.fs.path.join(arena, &.{ synced_root, "projects", "acme", "other", marker.marker_basename });
    const hub_proj_path = try std.fs.path.join(arena, &.{ hub_root, "acme", "proj" });
    const hub_proj_docs = try std.fs.path.join(arena, &.{ hub_proj_path, "docs" });
    const hub_proj_code_alpha = try std.fs.path.join(arena, &.{ hub_proj_path, "code", "alpha" });
    const hub_proj_code_beta = try std.fs.path.join(arena, &.{ hub_proj_path, "code", "beta" });
    const hub_other_code_alpha = try std.fs.path.join(arena, &.{ hub_root, "acme", "other", "code", "alpha" });
    const proj_content = try std.fs.path.join(arena, &.{ synced_root, "projects", "acme", "proj" });
    const proj_archived = try std.fs.path.join(arena, &.{ synced_root, "archive", "acme", "proj" });

    // new acme/proj <urlA>: creates the project, clones alpha, builds the hub.
    {
        const got = dispatch(arena, &.{ "new", "acme/proj", url_a });
        try testing.expectEqual(@as(u8, 0), got.code);
    }
    {
        const loaded = try marker.load(arena, marker_path_proj, null);
        try testing.expectEqual(@as(usize, 1), loaded.repos.count());
        try testing.expectEqualStrings(url_a, loaded.repos.get("alpha").?);
    }
    try testing.expect(fsutil.exists(clone_alpha));
    try expectSymlink(arena, hub_proj_docs);
    switch (try fsutil.linkState(arena, hub_proj_code_alpha)) {
        .symlink => |t| try testing.expectEqualStrings(clone_alpha, t),
        else => return error.TestUnexpectedResult,
    }

    // add acme/proj <urlB>: second repo, second clone + hub link.
    {
        const got = dispatch(arena, &.{ "add", "acme/proj", url_b });
        try testing.expectEqual(@as(u8, 0), got.code);
    }
    {
        const loaded = try marker.load(arena, marker_path_proj, null);
        try testing.expectEqual(@as(usize, 2), loaded.repos.count());
    }
    try testing.expect(fsutil.exists(clone_beta));
    try expectSymlink(arena, hub_proj_code_beta);

    // new acme/other (no url): a second project to later share alpha with.
    {
        const got = dispatch(arena, &.{ "new", "acme/other" });
        try testing.expectEqual(@as(u8, 0), got.code);
    }

    // add acme/other <urlA>: shares proj's existing clone, no re-clone.
    const stat_before = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_alpha, .{});
    {
        const got = dispatch(arena, &.{ "add", "acme/other", url_a });
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expect(std.mem.indexOf(u8, got.out, "using existing clone") != null);
    }
    const stat_after = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_alpha, .{});
    try testing.expectEqual(stat_before.inode, stat_after.inode);
    {
        const loaded = try marker.load(arena, marker_path_other, null);
        try testing.expectEqual(@as(usize, 1), loaded.repos.count());
    }
    switch (try fsutil.linkState(arena, hub_other_code_alpha)) {
        .symlink => |t| try testing.expectEqualStrings(clone_alpha, t),
        else => return error.TestUnexpectedResult,
    }

    // status / info: cross-project read paths, still mid-lifecycle (proj has both repos).
    {
        const got = dispatch(arena, &.{"status"});
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expect(std.mem.indexOf(u8, got.out, "acme/proj") != null);
        try testing.expect(std.mem.indexOf(u8, got.out, "acme/other") != null);
    }
    {
        const got = dispatch(arena, &.{ "info", "acme/proj" });
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expect(std.mem.indexOf(u8, got.out, "alpha:") != null);
        try testing.expect(std.mem.indexOf(u8, got.out, "beta:") != null);
    }

    // rm acme/proj beta: back to 1 repo, hub link swept, clone kept on disk.
    {
        const got = dispatch(arena, &.{ "rm", "acme/proj", "beta" });
        try testing.expectEqual(@as(u8, 0), got.code);
    }
    {
        const loaded = try marker.load(arena, marker_path_proj, null);
        try testing.expectEqual(@as(usize, 1), loaded.repos.count());
        try testing.expect(loaded.repos.contains("alpha"));
    }
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, hub_proj_code_beta));
    try testing.expect(fsutil.exists(clone_beta));

    // archive acme/proj: content moves out of projects/ into archive/, hub torn down.
    {
        const got = dispatch(arena, &.{ "archive", "acme/proj" });
        try testing.expectEqual(@as(u8, 0), got.code);
    }
    try testing.expect(!fsutil.exists(proj_content));
    try testing.expect(fsutil.exists(proj_archived));
    try testing.expect(!fsutil.exists(hub_proj_path));

    // restore acme/proj: content moves back, hub rebuilt.
    {
        const got = dispatch(arena, &.{ "restore", "acme/proj" });
        try testing.expectEqual(@as(u8, 0), got.code);
    }
    try testing.expect(fsutil.exists(proj_content));
    try testing.expect(!fsutil.exists(proj_archived));
    try expectSymlink(arena, hub_proj_docs);
    try expectSymlink(arena, hub_proj_code_alpha);

    // delete acme/proj --yes: content + hub gone, clones untouched (alpha still
    // used by acme/other; beta is never deleted regardless of references).
    {
        const got = dispatch(arena, &.{ "delete", "acme/proj", "--yes" });
        try testing.expectEqual(@as(u8, 0), got.code);
    }
    try testing.expect(!fsutil.exists(proj_content));
    try testing.expect(!fsutil.exists(hub_proj_path));
    try testing.expect(fsutil.exists(clone_alpha));
    try testing.expect(fsutil.exists(clone_beta));
}
