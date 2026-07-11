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
const completion_source = @import("completion_source.zig");
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

/// Dynamic shell-completion source: ports the old `completion.zig`'s
/// `candidatesFor` plus `resolve()`'s `cur`-based special cases into the one
/// hook cli-zig's engine calls for every `.dynamic` completion key.
pub const resolveCompletion = completion_source.resolveCompletion;

/// Maps the handful of environment/tooling failures that can surface from
/// deep inside a command to a clear, actionable line, so a missing external
/// tool or an unusable config location reads as guidance rather than a bare
/// "error: <ErrorName>". Anything not listed keeps cli-zig's generic
/// fallback. Ported from the old `cli.zig`'s `friendlyError`; the `"holt: "`
/// prefix is baked into the message here (rather than added by cli-zig's
/// `reportError`, which prints the message verbatim) so a reported error
/// reads identically to the old dispatcher's `"holt: {s}\n"`.
pub fn describeError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoHomeDir => "holt: cannot locate the holt config: set $HOME or $XDG_CONFIG_HOME to an absolute path",
        error.GitNotFound => "holt: git is not installed or not on your PATH",
        error.TarNotFound => "holt: tar is not installed or not on your PATH",
        error.CurlNotFound => "holt: curl is not installed or not on your PATH",
        else => null,
    };
}

/// Section heading text for the general help table, ported verbatim from
/// the old `cli.zig`'s `groupHeading`.
pub fn groupHeading(g: Group) []const u8 {
    return switch (g) {
        .navigate => "Navigate",
        .create => "Create & membership",
        .inspect => "Inspect",
        .maintain => "Maintain",
        .system => "System",
    };
}

/// Top-level help footer, ported verbatim from the old `cli.zig`'s
/// `printHelp` trailer.
pub fn renderHelpFooter(w: *std.Io.Writer, prog_name: []const u8) anyerror!void {
    try w.writeAll("\nA <project> is <org>/<name>, or a unique name or abbreviation of one.\n");
    try w.print("Run \"{s} <command> --help\" for details on a command.\n", .{prog_name});
    try w.print("Run \"{s} init <shell>\" to set up the h/hi shell helpers.\n", .{prog_name});
}

pub const HoltCli = cli.cli.Cli(.{
    .Context = Context,
    .Group = Group,
    .loadContext = loadContext,
    .resolveCompletion = resolveCompletion,
    .describeError = describeError,
    .groupHeading = groupHeading,
    .renderHelpFooter = renderHelpFooter,
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

test "describeError: known tooling/config errors match holt's old friendlyError wording, prefixed for byte-identical stderr" {
    try testing.expectEqualStrings("holt: cannot locate the holt config: set $HOME or $XDG_CONFIG_HOME to an absolute path", describeError(error.NoHomeDir).?);
    try testing.expectEqualStrings("holt: git is not installed or not on your PATH", describeError(error.GitNotFound).?);
    try testing.expectEqualStrings("holt: tar is not installed or not on your PATH", describeError(error.TarNotFound).?);
    try testing.expectEqualStrings("holt: curl is not installed or not on your PATH", describeError(error.CurlNotFound).?);
    try testing.expect(describeError(error.SomethingElse) == null);
}

test "groupHeading: matches holt's old cli.zig group headings exactly" {
    try testing.expectEqualStrings("Navigate", groupHeading(.navigate));
    try testing.expectEqualStrings("Create & membership", groupHeading(.create));
    try testing.expectEqualStrings("Inspect", groupHeading(.inspect));
    try testing.expectEqualStrings("Maintain", groupHeading(.maintain));
    try testing.expectEqualStrings("System", groupHeading(.system));
}

test "renderHelpFooter: matches holt's old printHelp footer text exactly" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderHelpFooter(&w, "holt");
    try testing.expectEqualStrings(
        "\nA <project> is <org>/<name>, or a unique name or abbreviation of one.\n" ++
            "Run \"holt <command> --help\" for details on a command.\n" ++
            "Run \"holt init <shell>\" to set up the h/hi shell helpers.\n",
        w.buffered(),
    );
}

test "HoltCli wiring: top-level help renders holt's group headings and footer" {
    const smoke_cmd = command(SmokeSpec, .{
        .name = "smoke",
        .summary = "smoke-tests the cli-zig wiring",
        .group = .system,
    }, smokeRun);

    var out_buf: [512]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try run(testing.allocator, testing.io, &.{"holt"}, &.{smoke_cmd}, &out_w, &err_w);
    try testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\nSystem:\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "A <project> is <org>/<name>, or a unique name or abbreviation of one.\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Run \"holt init <shell>\" to set up the h/hi shell helpers.\n") != null);
}

test "HoltCli wiring: a command-body known error reports holt's old friendly message verbatim" {
    const S = struct {
        fn r(_: *Ctx, _: cli.args.Args(SmokeSpec)) anyerror!u8 {
            return error.GitNotFound;
        }
    };
    const boom_cmd = command(SmokeSpec, .{
        .name = "boom",
        .group = .system,
    }, S.r);

    var out_buf: [64]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [128]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    const code = try run(testing.allocator, testing.io, &.{ "holt", "boom" }, &.{boom_cmd}, &out_w, &err_w);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expectEqualStrings("holt: git is not installed or not on your PATH\n", err_w.buffered());
}

const SeedSpec = struct {
    seed: cli.spec.Pos([]const u8, .{ .complete = .{ .dynamic = "backend_seed" } }),
};

fn seedRun(_: *Ctx, _: cli.args.Args(SeedSpec)) anyerror!u8 {
    return 0;
}

test "HoltCli wiring: __complete resolves a .dynamic key through resolveCompletion end-to-end" {
    const seed_cmd = command(SeedSpec, .{
        .name = "setup",
        .group = .system,
    }, seedRun);

    var out_buf: [1024]u8 = undefined;
    var out_w = std.Io.Writer.fixed(&out_buf);
    var err_buf: [64]u8 = undefined;
    var err_w = std.Io.Writer.fixed(&err_buf);

    // "backend_seed" never needs a loaded workspace, so this proves the
    // resolveCompletion wiring works even when the test environment has no
    // real holt config on disk.
    const code = try run(testing.allocator, testing.io, &.{ "holt", "__complete", "setup", "" }, &.{seed_cmd}, &out_w, &err_w);
    try testing.expectEqual(@as(u8, 0), code);
    const out = out_w.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "default\n"));
    try testing.expect(std.mem.indexOf(u8, out, "dropbox") != null);
}
