//! `holt backends`: read-only listing of every `[backends.*]` preset from
//! config, its expanded synced_root, whether that path exists on disk, and
//! which one (if any) is active.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const workspace = @import("../workspace.zig");
const fsutil = @import("../fsutil.zig");
const ui = @import("../ui.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {};

pub const command = args.command(Spec, .{
    .name = "backends",
    .about = "List configured backend presets",
    .usage = "holt backends",
    .group = .inspect,
    .details =
    \\Example:
    \\  holt backends
    ,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    _ = a;

    const cfg = ctx.ws.?.cfg;
    const alloc = ctx.alloc;

    if (cfg.backend == null) {
        try ctx.out.print("active: synced_root = {s}  (no backend)\n", .{cfg.synced_root});
    }

    if (cfg.presets.len == 0) {
        try ctx.err_w.writeAll("no backends defined; run \"holt setup\" or add [backends.*] to your config\n");
        return 0;
    }

    const names = try alloc.alloc([]const u8, cfg.presets.len);
    const expanded = try alloc.alloc([]const u8, cfg.presets.len);
    for (cfg.presets, names, expanded) |p, *n, *e| {
        n.* = p.name;
        e.* = try fsutil.expandTilde(alloc, p.synced_root);
    }
    const name_width = ui.columnWidth(names);
    const path_width = ui.columnWidth(expanded);

    for (cfg.presets, expanded) |p, path| {
        const state = if (fsutil.exists(path)) "[exists]" else "[missing]";
        try ui.padTo(ctx.out, p.name, name_width);
        try ctx.out.writeAll("  ");
        try ui.padTo(ctx.out, path, path_width);
        try ctx.out.print("  {s}", .{state});
        if (cfg.backend != null and std.mem.eql(u8, cfg.backend.?, p.name)) {
            try ctx.out.writeAll(" (active)");
        }
        try ctx.out.writeByte('\n');
    }

    return 0;
}

fn testWorkspace(alloc: std.mem.Allocator, root: []const u8, backend: ?[]const u8, presets: []const @import("../config.zig").Preset) !workspace.Workspace {
    return .{ .cfg = .{
        .backend = backend,
        .presets = @constCast(presets),
        .synced_root = try std.fs.path.join(alloc, &.{ root, "synced" }),
        .code_root = try std.fs.path.join(alloc, &.{ root, "code" }),
        .hub_root = try std.fs.path.join(alloc, &.{ root, "hub" }),
    } };
}

test "run: two presets, one active, lists both with expanded synced_root, marks the active one, shows exists/missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const present_dir = try std.fs.path.join(arena, &.{ root, "present-backend" });
    try fsutil.ensureDir(present_dir);
    const missing_dir = try std.fs.path.join(arena, &.{ root, "missing-backend" });

    const presets = [_]@import("../config.zig").Preset{
        .{ .name = "dropbox", .synced_root = present_dir },
        .{ .name = "icloud", .synced_root = missing_dir },
    };
    const ws = try testWorkspace(arena, root, "dropbox", &presets);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(std.mem.indexOf(u8, got.out, "dropbox") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, present_dir) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "[exists]") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "(active)") != null);

    try testing.expect(std.mem.indexOf(u8, got.out, "icloud") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, missing_dir) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "[missing]") != null);

    const dropbox_line_end = std.mem.indexOf(u8, got.out, "\n").?;
    try testing.expect(std.mem.indexOf(u8, got.out[0..dropbox_line_end], "(active)") != null);
}

test "run: direct-mode config (backend == null) prints the active synced_root line ahead of its presets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const preset_dir = try std.fs.path.join(arena, &.{ root, "some-backend" });
    const presets = [_]@import("../config.zig").Preset{
        .{ .name = "spare", .synced_root = preset_dir },
    };
    const ws = try testWorkspace(arena, root, null, &presets);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);

    const want_active_line = try std.fmt.allocPrint(arena, "active: synced_root = {s}  (no backend)\n", .{ws.cfg.synced_root});
    try testing.expect(std.mem.indexOf(u8, got.out, want_active_line) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "spare") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "(active)") == null);
}

test "run: empty presets prints a stderr note and exits 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testWorkspace(arena, root, "dropbox", &.{});

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "no backends defined") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt setup") != null);
}
