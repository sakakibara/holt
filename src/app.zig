//! Instantiates cli-zig's `Cli(cfg)` for holt: the per-command `Context`
//! (loaded workspace + color decision), the help-grouping `Group` enum, and
//! the `loadContext` hook that ports `config.loadDefault` into cli-zig's
//! shape. Coexists with the old `cli.zig`/`args.zig` dispatcher until the
//! migration cuts every command over.

const std = @import("std");
const cli = @import("cli");
const workspace = @import("workspace.zig");
const config = @import("config.zig");
const diagnostic = @import("diag.zig");
const testing = std.testing;

/// Per-command context: the loaded workspace and whether output should be
/// colored.
pub const Context = struct {
    ws: workspace.Workspace,
    color: bool,
};

/// Section a command is listed under in the general help table, in the same
/// order as the old `cli.zig`'s `Group`.
pub const Group = enum {
    navigate,
    create,
    inspect,
    maintain,
    system,
};

/// Whether a command should color its output. `loadContext` runs with no
/// access to the process's real stdout file (cli-zig's `Ctx.io` is an
/// `std.Io`, not a file handle), so the decision is made once in `main.zig`
/// against the real stdout - the same one-shot-against-the-real-terminal
/// timing the old dispatcher used - and stored here as a process-global for
/// `loadContext` to read.
pub var color_enabled: bool = false;

/// Ports `config.loadDefault` into cli-zig's context-loader shape: on
/// failure, copies holt's diagnostic message into `diag.message` and
/// propagates the error; on success, wraps the config in a `Workspace`.
pub fn loadContext(alloc: std.mem.Allocator, io: std.Io, diag: *cli.args.Diagnostic) anyerror!Context {
    _ = io;
    var holt_diag: diagnostic.Diagnostic = .{};
    const cfg = config.loadDefault(alloc, &holt_diag) catch |err| {
        diag.message = holt_diag.message;
        return err;
    };
    return .{ .ws = .{ .cfg = cfg }, .color = color_enabled };
}

pub const HoltCli = cli.cli.Cli(.{
    .Context = Context,
    .Group = Group,
    .loadContext = loadContext,
});

pub const Ctx = HoltCli.Ctx;
pub const Command = HoltCli.Command;
pub const About = HoltCli.About;
pub const run = HoltCli.run;
pub const command = HoltCli.command;

const SmokeSpec = struct {};

fn smokeRun(ctx: *Ctx, _: cli.args.Args(SmokeSpec)) anyerror!u8 {
    try ctx.out.writeAll("smoke ok\n");
    return 0;
}

test "HoltCli wiring: a command built via command() dispatches through run() and writes output" {
    const smoke_cmd = command(SmokeSpec, .{
        .name = "smoke",
        .summary = "smoke-tests the cli-zig wiring",
        .group = .system,
    }, smokeRun);

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try run(testing.allocator, testing.io, &.{ "holt", "smoke" }, &.{smoke_cmd}, &out_w, &err_w);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("smoke ok\n", out_w.buffered());
}
