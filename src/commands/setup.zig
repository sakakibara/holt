//! `holt setup`: writes the config.toml that every other command reads,
//! seeding the built-in backend presets (config.builtin_seeds). Given flags,
//! writes non-interactively; given a real terminal and no flags, runs a
//! light pick-or-enter prompt flow. Never presumes iCloud or any other
//! backend.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("../app.zig");
const config = @import("../config.zig");
const ui = @import("../ui.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    backend: cli.spec.Opt([]const u8, .{ .value_name = "name", .complete = app.cat(.backend_seed), .help = "activate a seeded preset (e.g. dropbox, icloud)" }),
    synced_root: cli.spec.Opt([]const u8, .{ .value_name = "path", .complete = .files, .help = "use this path directly instead of a preset" }),
    code_root: cli.spec.Opt([]const u8, .{ .value_name = "path", .complete = .files, .help = "defaults to ~/Code" }),
    hub_root: cli.spec.Opt([]const u8, .{ .value_name = "path", .complete = .files, .help = "defaults to ~/Projects" }),
    force: cli.spec.Flag(.{ .help = "overwrite an existing config file" }),
};

pub const command = app.command(Spec, .{
    .name = "setup",
    .summary = "Create config.toml, picking or seeding a synced-storage backend",
    .usage = "holt setup [--backend <name>|--synced-root <path>] [--code-root <path>] [--hub-root <path>] [--force]",
    .group = .system,
    .exclusive = &.{&.{ "backend", "synced_root" }},
    .details =
    \\--backend and --synced-root are mutually exclusive. With neither given
    \\and a real terminal attached, setup asks interactively.
    \\
    \\Example:
    \\  holt setup --backend dropbox
    ,
    .needs_context = false,
}, run);

const default_code_root = "~/Code";
const default_hub_root = "~/Projects";

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const backend_opt = a.backend;
    const synced_root_opt = a.synced_root;
    const code_root_opt = a.code_root;
    const hub_root_opt = a.hub_root;
    const force = a.force;

    const alloc = ctx.alloc;
    const path = try config.configPath(alloc, app.envOf(ctx));

    if (fsutil.exists(path) and !force) {
        try ctx.err.print("holt: config already exists at {s} (use --force to overwrite)\n", .{path});
        return 1;
    }

    const code_root = code_root_opt orelse default_code_root;
    const hub_root = hub_root_opt orelse default_hub_root;

    if (backend_opt) |name| {
        return writeConfig(ctx, path, name, null, code_root, hub_root);
    }
    if (synced_root_opt) |root| {
        return writeConfig(ctx, path, null, root, code_root, hub_root);
    }

    const stdin_is_tty = std.Io.File.stdin().isTty(fsutil.io()) catch false;
    if (!stdin_is_tty) {
        try ctx.err.writeAll("holt: no backend or synced_root given and no terminal to ask; pass --backend <name> or --synced-root <path>\n");
        return 1;
    }

    return runInteractive(ctx, path, code_root_opt, hub_root_opt);
}

fn writeConfig(ctx: *app.Ctx, path: []const u8, active: ?[]const u8, direct_root: ?[]const u8, code_root: []const u8, hub_root: []const u8) !u8 {
    const alloc = ctx.alloc;
    const body = try config.renderConfig(alloc, active, direct_root, code_root, hub_root);

    writeBody(alloc, path, body) catch |err| switch (err) {
        error.AccessDenied => {
            try ctx.err.print("holt: cannot write config to {s}: permission denied (is the directory writable?)\n", .{path});
            return 1;
        },
        else => return err,
    };

    try ctx.out.print("wrote {s}\n", .{path});
    return 0;
}

fn writeBody(alloc: std.mem.Allocator, path: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try fsutil.ensureDir(parent);
    try fsutil.writeFileAtomic(alloc, path, body);
}

/// Warns (never fails) on ctx.err when `raw_root` is set but does not yet
/// resolve to something on disk - a not-yet-mounted cloud is a normal case,
/// not an error.
fn warnIfMissing(ctx: *app.Ctx, raw_root: []const u8) !void {
    const expanded = try fsutil.expandTilde(ctx.alloc, app.envOf(ctx), raw_root);
    if (!fsutil.exists(expanded)) {
        try ctx.err.print("holt: warning: {s} does not exist yet\n", .{expanded});
    }
}

/// Light pick-or-enter flow (spec 3.4, 4): list the seeds, propose the
/// chosen one's synced_root, and let the reply either accept it (backend
/// mode, the preset's own value) or replace it (direct mode - renderConfig
/// has no way to carry a custom path under a preset name, so an edited
/// reply falls back to a plain synced_root rather than silently discarding
/// the user's edit).
fn runInteractive(ctx: *app.Ctx, path: []const u8, code_root_opt: ?[]const u8, hub_root_opt: ?[]const u8) !u8 {
    const alloc = ctx.alloc;
    const w = ctx.out;

    try w.writeAll("Pick a synced-storage backend:\n");
    for (config.builtin_seeds, 0..) |seed, i| {
        if (seed.commented) {
            try w.print("  {d}) {s} - you must fill in your account ({s})\n", .{ i + 1, seed.name, seed.synced_root });
        } else {
            try w.print("  {d}) {s} ({s})\n", .{ i + 1, seed.name, seed.synced_root });
        }
    }
    const custom_choice = config.builtin_seeds.len + 1;
    try w.print("  {d}) custom path\n", .{custom_choice});

    const choice_line = try ui.prompt(alloc, w, "Choice:");
    const choice = std.fmt.parseInt(usize, choice_line, 10) catch 0;

    var active: ?[]const u8 = null;
    var direct_root: ?[]const u8 = null;

    if (choice >= 1 and choice <= config.builtin_seeds.len) {
        const seed = config.builtin_seeds[choice - 1];
        const reply_msg = try std.fmt.allocPrint(alloc, "synced_root [{s}]:", .{seed.synced_root});
        const reply = try ui.prompt(alloc, w, reply_msg);
        if (reply.len == 0) {
            active = seed.name;
        } else {
            direct_root = reply;
        }
    } else if (choice == custom_choice) {
        const reply = try ui.prompt(alloc, w, "synced_root:");
        if (reply.len == 0) {
            try ctx.err.writeAll("holt: a synced_root is required\n");
            return 1;
        }
        direct_root = reply;
    } else {
        try ctx.err.print("holt: \"{s}\" is not a valid choice\n", .{choice_line});
        return 1;
    }

    const code_reply_msg = try std.fmt.allocPrint(alloc, "code_root [{s}]:", .{code_root_opt orelse default_code_root});
    const code_reply = try ui.prompt(alloc, w, code_reply_msg);
    const code_root = if (code_reply.len > 0) code_reply else (code_root_opt orelse default_code_root);

    const hub_reply_msg = try std.fmt.allocPrint(alloc, "hub_root [{s}]:", .{hub_root_opt orelse default_hub_root});
    const hub_reply = try ui.prompt(alloc, w, hub_reply_msg);
    const hub_root = if (hub_reply.len > 0) hub_reply else (hub_root_opt orelse default_hub_root);

    if (direct_root) |root| {
        try warnIfMissing(ctx, root);
    } else if (active) |name| {
        for (config.builtin_seeds) |seed| {
            if (std.mem.eql(u8, seed.name, name)) {
                try warnIfMissing(ctx, seed.synced_root);
                break;
            }
        }
    }

    return writeConfig(ctx, path, active, direct_root, code_root, hub_root);
}

test "run: --backend dropbox writes a config that loads with backend dropbox, naming the path on stdout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvScope.install(arena, &.{.{ "XDG_CONFIG_HOME", root }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, null, &.{ "--backend", "dropbox" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const path = try config.configPath(arena, app.envOf_current());
    try testing.expect(std.mem.indexOf(u8, got.out, path) != null);

    const cfg = try config.load(arena, app.envOf_current(), path, null);
    try testing.expectEqualStrings("dropbox", cfg.backend.?);
}

test "run: --synced-root writes direct mode; load resolves it with no active backend" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvScope.install(arena, &.{.{ "XDG_CONFIG_HOME", root }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, null, &.{ "--synced-root", "~/custom" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const path = try config.configPath(arena, app.envOf_current());
    const cfg = try config.load(arena, app.envOf_current(), path, null);
    try testing.expectEqual(@as(?[]const u8, null), cfg.backend);
    const home = try fsutil.expandTilde(arena, app.envOf_current(), "~");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "custom" }), cfg.synced_root);
}

test "run: refuses to overwrite an existing config without --force, --force overwrites" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvScope.install(arena, &.{.{ "XDG_CONFIG_HOME", root }});
    defer override.restore();

    const path = try config.configPath(arena, app.envOf_current());
    try fsutil.ensureDir(std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = path, .data = "[workspace]\nsynced_root = \"/custom\"\n" });

    const refused = try testutil.runCmd(arena, command.run, null, &.{ "--backend", "dropbox" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "already exists") != null);

    const preserved = try config.load(arena, app.envOf_current(), path, null);
    try testing.expectEqual(@as(?[]const u8, null), preserved.backend);

    const forced = try testutil.runCmd(arena, command.run, null, &.{ "--backend", "dropbox", "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);

    const overwritten = try config.load(arena, app.envOf_current(), path, null);
    try testing.expectEqualStrings("dropbox", overwritten.backend.?);
}

test "run: --backend and --synced-root together is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvScope.install(arena, &.{.{ "XDG_CONFIG_HOME", root }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, null, &.{ "--backend", "dropbox", "--synced-root", "~/x" });
    try testing.expectEqual(@as(u8, 2), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "mutually exclusive") != null);
}

test "run: a read-only config directory yields a permission-denied message, not a bare internal error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    // XDG points at a directory holt cannot write into. Mode bits don't
    // gate access on Windows, so this whole simulation is POSIX-only.
    const xdg = try std.fs.path.join(arena, &.{ root, "ro-cfg" });
    try fsutil.ensureDir(xdg);
    if (builtin.os.tag != .windows) {
        try tmp.dir.setFilePermissions(testing.io, "ro-cfg", std.Io.File.Permissions.fromMode(0o555), .{});
        defer tmp.dir.setFilePermissions(testing.io, "ro-cfg", std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        const override = try testutil.EnvScope.install(arena, &.{.{ "XDG_CONFIG_HOME", xdg }});
        defer override.restore();

        const got = try testutil.runCmd(arena, command.run, null, &.{ "--backend", "dropbox" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "permission denied") != null);
    }
}

test "run: no flags and no terminal (the test harness's real stdin) errors asking for a flag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvScope.install(arena, &.{.{ "XDG_CONFIG_HOME", root }});
    defer override.restore();

    try testing.expect(!(std.Io.File.stdin().isTty(fsutil.io()) catch false));

    const got = try testutil.runCmd(arena, command.run, null, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "no terminal to ask") != null);
}
