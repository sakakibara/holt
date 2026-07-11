//! Emits shell integration code: the `h`/`hi` navigation functions for
//! whichever shell the caller's dotfiles source `holt init` from.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const shell = @import("../shell.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    shell: cli.spec.Pos([]const u8, .{ .complete = .{ .choices = &.{ "fish", "zsh", "bash", "powershell" } }, .help = "the shell to emit integration code for" }),
};

pub const command = app.command(Spec, .{
    .name = "init",
    .summary = "Print shell integration code (h/hi functions)",
    .usage = "holt init <fish|zsh|bash|powershell>",
    .group = .navigate,
    .details =
    \\Example:
    \\  holt init fish
    ,
    .needs_context = false,
}, run);

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const name = a.shell;

    const sh = shell.parse(name) orelse {
        return app.usageError(ctx, "unsupported shell \"{s}\" (want fish, zsh, bash, or powershell)", .{name});
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

    const got = try testutil.runCmd(arena, command.run, null, &.{});
    try testing.expectEqual(@as(u8, 2), got.code);
}

test "run: unknown shell name is a usage error naming the bad shell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try testutil.runCmd(arena, command.run, null, &.{"csh"});
    try testing.expectEqual(@as(u8, 2), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "csh") != null);
}
