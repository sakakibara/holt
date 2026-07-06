//! Prints the CLI version baked in at build time via `-Dversion`
//! (`build_options`, wired in build.zig from build.zig.zon).

const std = @import("std");
const build_options = @import("build_options");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const testing = std.testing;

const Spec = struct {};

pub const command = args.command(Spec, .{
    .name = "version",
    .about = "Print the holt version",
    .usage = "holt version",
    .group = .system,
    .details =
    \\Example:
    \\  holt version
    ,
    .needs_workspace = false,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    _ = a;
    try ctx.out.print("holt {s}\n", .{build_options.version});
    return 0;
}

test "run: prints holt <version> and exits 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);

    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };
    const code = try command.run(&ctx);

    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("holt " ++ build_options.version ++ "\n", out.written());
}

test "run: leftover arguments are a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_args = try cli.Args.init(arena, &.{"extra"});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);

    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };
    try testing.expectError(error.UsageError, command.run(&ctx));
}
