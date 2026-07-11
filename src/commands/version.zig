//! Prints the CLI version baked in at build time via `-Dversion`
//! (`build_options`, wired in build.zig from build.zig.zon).

const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli");
const app = @import("../app.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {};

pub const command = app.command(Spec, .{
    .name = "version",
    .summary = "Print the holt version",
    .usage = "holt version",
    .group = .system,
    .details =
    \\Example:
    \\  holt version
    ,
    .needs_context = false,
}, run);

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    _ = a;
    try ctx.out.print("holt {s}\n", .{build_options.version});
    return 0;
}

test "run: prints holt <version> and exits 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try testutil.runCmd(arena, command.run, null, &.{});

    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("holt " ++ build_options.version ++ "\n", got.out);
}

test "run: leftover arguments are a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try testutil.runCmd(arena, command.run, null, &.{"extra"});
    try testing.expectEqual(@as(u8, 2), got.code);
}
