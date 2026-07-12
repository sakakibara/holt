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
/// failure, copies holt's diagnostic message into `diag.message` (unprefixed
/// - `cfg.messagePrefix` adds "holt: " uniformly, and cli-zig prints
/// `diag.message` verbatim with that prefix prepended) and propagates the
/// error; on success, wraps the config in a `Workspace`.
pub fn loadContext(alloc: std.mem.Allocator, io: std.Io, diag: *cli.args.Diagnostic) anyerror!Context {
    _ = io;
    var holt_diag: diagnostic.Diagnostic = .{};
    const cfg = config.loadDefault(alloc, &holt_diag) catch |err| {
        diag.message = try alloc.dupe(u8, holt_diag.message);
        return err;
    };
    return .{ .ws = .{ .cfg = cfg }, .color = color_enabled };
}

/// Dynamic shell-completion source: ports the old `completion.zig`'s
/// `candidatesFor` plus `resolve()`'s `cur`-based special cases into the one
/// hook cli-zig's engine calls for every `.dynamic` completion key.
pub const resolveCompletion = completion_source.resolveCompletion;
/// A schema field's `.dynamic` completion category, typed against
/// `completion_source.Category` so a command's spec cannot misspell one.
pub const cat = completion_source.cat;

/// Maps the handful of environment/tooling failures that can surface from
/// deep inside a command to a clear, actionable line, so a missing external
/// tool or an unusable config location reads as guidance rather than a bare
/// "error: <ErrorName>", plus a catch-all for everything else so no error
/// ever falls back to cli-zig's own "error: <name>" wording. Ported from the
/// old `cli.zig`'s `friendlyError`; every returned message is unprefixed -
/// `cfg.messagePrefix` adds "holt: " uniformly, so baking it in here would
/// double it. The catch-all uses `alloc` (a short-lived arena cli-zig scopes
/// to this one call) to match the old dispatcher's `"internal error: {s}"`
/// wording for an uncategorized error.
pub fn describeError(alloc: std.mem.Allocator, err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoHomeDir => "cannot locate the holt config: set $HOME or $XDG_CONFIG_HOME to an absolute path",
        error.GitNotFound => "git is not installed or not on your PATH",
        error.TarNotFound => "tar is not installed or not on your PATH",
        error.CurlNotFound => "curl is not installed or not on your PATH",
        else => std.fmt.allocPrint(alloc, "internal error: {s}", .{@errorName(err)}) catch null,
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

fn flagSpellingLen(f: anytype) usize {
    var n: usize = 2 + f.long.len;
    if (f.short != null) n += 4; // ", -X"
    if (f.takes_value) n += 3 + f.value_name.len; // " <value_name>"
    return n;
}

fn writeFlagSpelling(w: *std.Io.Writer, f: anytype) !void {
    try w.print("--{s}", .{f.long});
    if (f.short) |s| try w.print(", -{c}", .{s});
    if (f.takes_value) try w.print(" <{s}>", .{f.value_name});
}

/// Per-command help, ported verbatim from the old `cli.zig`'s `printUsage`:
/// usage line, blank line, summary, an optional Flags table, an optional
/// details block. Deliberately does NOT use cli-zig's default renderer,
/// which also emits Args:/Commands: sections holt's old dispatcher never
/// had - a command's explicit `.usage` string and a subcommand parent's
/// `.details` prose already document that structure, so adding those
/// sections would change `--help` output that today's users already see.
/// `cmd` is `anytype` (a `HoltCli.Command`, though that type cannot be named
/// here - `Cli(cfg)` is still being built from this very hook).
pub fn renderCommandHelp(w: *std.Io.Writer, prog_name: []const u8, cmd: anytype) anyerror!void {
    _ = prog_name;
    try w.print("Usage: {s}\n\n{s}\n", .{ cmd.usage, cmd.summary });

    if (cmd.flags.len > 0) {
        var width: usize = 0;
        for (cmd.flags) |f| width = @max(width, flagSpellingLen(f));
        try w.writeAll("\nFlags:\n");
        for (cmd.flags) |f| {
            try w.writeAll("  ");
            const len = flagSpellingLen(f);
            try writeFlagSpelling(w, f);
            if (len < width) try w.splatByteAll(' ', width - len);
            if (f.help.len > 0) try w.print("  {s}", .{f.help});
            try w.writeByte('\n');
        }
    }

    if (cmd.details.len > 0) try w.print("\n{s}\n", .{cmd.details});
}

pub const HoltCli = cli.cli.Cli(.{
    .Context = Context,
    .Group = Group,
    .loadContext = loadContext,
    .resolveCompletion = resolveCompletion,
    .describeError = describeError,
    .groupHeading = groupHeading,
    .renderHelpFooter = renderHelpFooter,
    .renderCommandHelp = renderCommandHelp,
    .messagePrefix = "holt: ",
});

pub const Ctx = HoltCli.Ctx;
pub const Command = HoltCli.Command;
pub const About = HoltCli.About;
pub const run = HoltCli.run;
pub const command = HoltCli.command;

/// Reports a usage error the same way holt's old dispatcher rendered
/// `ctx.args.message = m; return error.UsageError;`: `"holt: " ++ fmt ++
/// "\n"` on `ctx.err`, exit code 2. Command bodies that reject their own
/// already-parsed arguments (an org/name collision, mutually exclusive
/// values not expressible via `About.exclusive`, a stray subcommand-parent
/// argument) call this directly instead of returning `error.UsageError`,
/// since cli-zig's `Ctx` has no `.args.message` slot for that idiom.
pub fn usageError(ctx: *Ctx, comptime fmt: []const u8, args: anytype) u8 {
    ctx.err.print("holt: " ++ fmt ++ "\n", args) catch {};
    return 2;
}

const version_cmd = @import("commands/version.zig");
const init_cmd = @import("commands/init.zig");
const setup_cmd = @import("commands/setup.zig");
const path_cmd = @import("commands/path.zig");
const list_cmd = @import("commands/list.zig");
const new_cmd = @import("commands/new.zig");
const add_cmd = @import("commands/add.zig");
const get_cmd = @import("commands/get.zig");
const create_cmd = @import("commands/create.zig");
const rm_cmd = @import("commands/rm.zig");
const alias_cmd = @import("commands/alias.zig");
const sync_cmd = @import("commands/sync.zig");
const restore_cmd = @import("commands/restore.zig");
const doctor_cmd = @import("commands/doctor.zig");
const promote_cmd = @import("commands/promote.zig");
const archive_cmd = @import("commands/archive.zig");
const delete_cmd = @import("commands/delete.zig");
const rename_cmd = @import("commands/rename.zig");
const org_cmd = @import("commands/org.zig");
const backup_cmd = @import("commands/backup.zig");
const info_cmd = @import("commands/info.zig");
const status_cmd = @import("commands/status.zig");
const backends_cmd = @import("commands/backends.zig");
const backend_cmd = @import("commands/backend.zig");
const recent_cmd = @import("commands/recent.zig");
const adopt_cmd = @import("commands/adopt.zig");
const keep_cmd = @import("commands/keep.zig");
const edit_cmd = @import("commands/edit.zig");
const config_cmd = @import("commands/config.zig");
const run_cmd = @import("commands/run.zig");
const upgrade_cmd = @import("commands/upgrade.zig");
const worktree_cmd = @import("commands/worktree.zig");

/// Every registered top-level command, in the same order as holt's old
/// `main.zig` table.
pub const command_table = [_]Command{
    path_cmd.command,
    list_cmd.command,
    init_cmd.command,
    setup_cmd.command,
    new_cmd.command,
    add_cmd.command,
    get_cmd.command,
    create_cmd.command,
    rm_cmd.command,
    alias_cmd.command,
    adopt_cmd.command,
    keep_cmd.command,
    info_cmd.command,
    status_cmd.command,
    backends_cmd.command,
    recent_cmd.command,
    sync_cmd.command,
    restore_cmd.command,
    doctor_cmd.command,
    promote_cmd.command,
    rename_cmd.command,
    org_cmd.command,
    archive_cmd.command,
    backup_cmd.command,
    edit_cmd.command,
    worktree_cmd.command,
    backend_cmd.command,
    config_cmd.command,
    run_cmd.command,
    version_cmd.command,
    upgrade_cmd.command,
    delete_cmd.command,
};

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

test "describeError: known tooling/config errors match holt's old friendlyError wording, unprefixed (cfg.messagePrefix adds \"holt: \")" {
    try testing.expectEqualStrings("cannot locate the holt config: set $HOME or $XDG_CONFIG_HOME to an absolute path", describeError(testing.allocator, error.NoHomeDir).?);
    try testing.expectEqualStrings("git is not installed or not on your PATH", describeError(testing.allocator, error.GitNotFound).?);
    try testing.expectEqualStrings("tar is not installed or not on your PATH", describeError(testing.allocator, error.TarNotFound).?);
    try testing.expectEqualStrings("curl is not installed or not on your PATH", describeError(testing.allocator, error.CurlNotFound).?);
    const internal = describeError(testing.allocator, error.SomethingElse).?;
    defer testing.allocator.free(internal);
    try testing.expectEqualStrings("internal error: SomethingElse", internal);
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
