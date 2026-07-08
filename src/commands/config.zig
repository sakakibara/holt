//! `holt config` prints the resolved [workspace]: the three roots, the
//! active backend (or "(direct synced_root)" when none is set), and the
//! config file path. On a broken config it reports the diagnostic instead
//! of aborting, since diagnosing a bad config is exactly this command's job.
//! `holt config edit` opens the config file in $EDITOR - the door to
//! hand-editing presets and roots, and the repair path for a broken config,
//! so it opens on a malformed file too and only refuses when the file is
//! altogether absent.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const config = @import("../config.zig");
const diagnostic = @import("../diag.zig");
const fsutil = @import("../fsutil.zig");
const editor = @import("../editor.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const EditSpec = struct {};

const edit_command = args.command(EditSpec, .{
    .name = "edit",
    .about = "Open the config file in $EDITOR, even when it is broken",
    .usage = "holt config edit",
    .group = .system,
    .needs_workspace = false,
}, runEdit);

pub const command: cli.Command = .{
    .name = "config",
    .summary = "Show the resolved configuration, or edit it in $EDITOR",
    .usage = "holt config [edit]",
    .group = .system,
    .details =
    \\With no argument, prints synced_root, code_root, hub_root, the active
    \\backend, and the config file path. On a broken config, prints the
    \\path and the diagnostic instead of aborting.
    \\
    \\"edit" opens the config file in $EDITOR, even when it is broken.
    \\
    \\Example:
    \\  holt config
    \\  holt config edit
    ,
    .subcommands = &.{edit_command},
    .needs_workspace = false,
    .run = runShow,
};

fn runShow(ctx: *cli.Ctx) anyerror!u8 {
    // `config edit` is routed to the subcommand before reaching here, so any
    // positional left is an unrecognized argument - name the accepted form.
    if (ctx.args.positional() != null) {
        ctx.args.message = "usage: holt config [edit]";
        return error.UsageError;
    }
    try ctx.args.finish();
    const path = try config.configPath(ctx.alloc);

    var diag: diagnostic.Diagnostic = .{};
    const cfg = config.loadDefault(ctx.alloc, &diag) catch {
        try ctx.err_w.print("holt: config file = {s}\n", .{path});
        try ctx.err_w.print("holt: {s}\n", .{diag.message});
        try ctx.err_w.writeAll("holt: fix it with \"holt config edit\" or \"holt setup\"\n");
        return 1;
    };

    try ctx.out.print("synced_root = {s}\n", .{cfg.synced_root});
    try ctx.out.print("code_root = {s}\n", .{cfg.code_root});
    try ctx.out.print("hub_root = {s}\n", .{cfg.hub_root});
    if (cfg.backend) |name| {
        try ctx.out.print("backend = {s}\n", .{name});
    } else {
        try ctx.out.writeAll("backend = (direct synced_root)\n");
    }
    try ctx.out.print("config file = {s}\n", .{path});
    return 0;
}

fn runEdit(ctx: *cli.Ctx, _: args.Args(EditSpec)) anyerror!u8 {
    const alloc = ctx.alloc;
    const path = try config.configPath(alloc);

    if (!fsutil.exists(path)) {
        try ctx.err_w.print("holt: no config at {s}; run \"holt setup\" to create one\n", .{path});
        return 1;
    }

    return editor.open(ctx, path, null);
}

fn writeConfigFile(alloc: std.mem.Allocator, xdg_root: []const u8, content: []const u8) ![]u8 {
    const holt_dir = try std.fs.path.join(alloc, &.{ xdg_root, "holt" });
    try fsutil.ensureDir(holt_dir);
    const path = try std.fs.path.join(alloc, &.{ holt_dir, "config.toml" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = path, .data = content });
    return path;
}

fn tmpRoot(arena: std.mem.Allocator, tmp: *testing.TmpDir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
}

test "run: with no argument, prints the three roots, the active backend, and the config path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const xdg_override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer xdg_override.restore();

    const synced_root = try std.fs.path.join(arena, &.{ root, "synced" });
    const code_root = try std.fs.path.join(arena, &.{ root, "code" });
    const hub_root = try std.fs.path.join(arena, &.{ root, "hub" });
    const content = try std.fmt.allocPrint(arena,
        \\[workspace]
        \\backend = "dropbox"
        \\code_root = "{s}"
        \\hub_root = "{s}"
        \\
        \\[backends.dropbox]
        \\synced_root = "{s}"
        \\
    , .{ try config.tomlEscape(arena, code_root), try config.tomlEscape(arena, hub_root), try config.tomlEscape(arena, synced_root) });
    const path = try writeConfigFile(arena, root, content);

    const got = try testutil.runCmd(arena, command.run, null, &.{});

    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, synced_root) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, code_root) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, hub_root) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "backend = dropbox") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, path) != null);
}

test "run: with no argument in direct mode, the backend line reads (direct synced_root)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const xdg_override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer xdg_override.restore();

    const synced_root = try std.fs.path.join(arena, &.{ root, "synced" });
    const content = try std.fmt.allocPrint(arena,
        \\[workspace]
        \\synced_root = "{s}"
        \\
    , .{try config.tomlEscape(arena, synced_root)});
    _ = try writeConfigFile(arena, root, content);

    const got = try testutil.runCmd(arena, command.run, null, &.{});

    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "backend = (direct synced_root)") != null);
}

test "run: with no argument, a broken config reports the path and diagnostic instead of aborting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const xdg_override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer xdg_override.restore();

    const path = try writeConfigFile(arena, root,
        \\[workspace]
        \\backend = "nope"
        \\
    );

    const got = try testutil.runCmd(arena, command.run, null, &.{});

    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, path) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "fix it with \"holt config edit\"") != null);
}

test "run: an argument other than \"edit\" is a usage error naming the accepted form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_args = try cli.Args.init(arena, &.{"bogus"});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.UsageError, command.run(&ctx));
    try testing.expect(std.mem.indexOf(u8, cli_args.message, "holt config [edit]") != null);
}

test "run: config edit opens $EDITOR even when the config file is malformed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const marker_path = try std.fs.path.join(arena, &.{ root, "editor-invocation.txt" });
    const script_path = try testutil.writeFakeEditor(arena, root, marker_path, .{});

    const editor_override = try testutil.EnvOverride.install(arena, "EDITOR", script_path);
    defer editor_override.restore();
    const xdg_override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer xdg_override.restore();

    const path = try writeConfigFile(arena, root,
        \\[workspace
        \\backend = "dropbox"
        \\
    );

    const got = try testutil.runCmd(arena, edit_command.run, null, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);

    const recorded = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), marker_path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(path, std.mem.trimEnd(u8, recorded, "\r\n"));
}

test "run: config edit with no config file errors, pointing at holt setup, without spawning anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const marker_path = try std.fs.path.join(arena, &.{ root, "editor-invocation.txt" });
    const script_path = try testutil.writeFakeEditor(arena, root, marker_path, .{});

    const editor_override = try testutil.EnvOverride.install(arena, "EDITOR", script_path);
    defer editor_override.restore();
    const xdg_override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer xdg_override.restore();

    const got = try testutil.runCmd(arena, edit_command.run, null, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "no config at") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt setup") != null);
    try testing.expect(!fsutil.exists(marker_path));
}

test "run: config edit with no $EDITOR errors cleanly, without spawning anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const xdg_override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer xdg_override.restore();
    _ = try writeConfigFile(arena, root,
        \\[workspace]
        \\synced_root = "/tmp/whatever"
        \\
    );

    const override = try testutil.EnvOverride.install(arena, "EDITOR", null);
    defer override.restore();

    const got = try testutil.runCmd(arena, edit_command.run, null, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "EDITOR") != null);
}
