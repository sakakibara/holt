//! Emits shell integration code: the `h`/`hi` navigation functions for
//! whichever shell the caller's dotfiles source `holt init` from.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const shell = @import("../shell.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    shell: args.Pos([]const u8, .{ .complete = .{ .choices = &.{ "fish", "zsh", "bash", "powershell" } }, .help = "the shell to emit integration code for" }),
};

pub const command = args.command(Spec, .{
    .name = "init",
    .about = "Print shell integration code (h/hi functions)",
    .usage = "holt init <fish|zsh|bash|powershell>",
    .group = .navigate,
    .details =
    \\Example:
    \\  holt init fish
    ,
    .needs_workspace = false,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const name = a.shell;

    const sh = shell.parse(name) orelse {
        ctx.args.message = try std.fmt.allocPrint(ctx.alloc, "unsupported shell \"{s}\" (want fish, zsh, bash, or powershell)", .{name});
        return error.UsageError;
    };

    try ctx.out.writeAll(shell.snippet(sh));
    return 0;
}

test "run: each shell name prints its own snippet with h, hi, and holt path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "fish", "zsh", "bash", "powershell" }) |name| {
        const got = try testutil.runCmd(arena, command.run, null, &.{name});
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expect(std.mem.indexOf(u8, got.out, "holt path") != null);
        try testing.expect(std.mem.indexOf(u8, got.out, "holt list") != null);
    }
}

test "run: missing shell name is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.UsageError, command.run(&ctx));
}

test "run: unknown shell name is a usage error naming the bad shell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_args = try cli.Args.init(arena, &.{"csh"});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.UsageError, command.run(&ctx));
    try testing.expect(std.mem.indexOf(u8, cli_args.message, "csh") != null);
}
