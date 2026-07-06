//! Subcommand dispatcher: parses argv into flags/options/positionals,
//! routes to a registered `Command`, loads the workspace when the command
//! needs one, and renders help/usage/error output the same way for every
//! command so individual commands only implement their own `run`.

const std = @import("std");
const workspace = @import("workspace.zig");
const config = @import("config.zig");
const diagnostic = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const ui = @import("ui.zig");
const completion = @import("completion.zig");
const testing = std.testing;

pub const Ctx = struct {
    alloc: std.mem.Allocator,
    ws: ?workspace.Workspace,
    args: *Args,
    out: *std.Io.Writer,
    err_w: *std.Io.Writer,
    /// The command being run - lets the declarative accessors below resolve a
    /// flag's short form and validate leftover tokens against the declared
    /// flag set. Null only in unit tests that build a Ctx by hand.
    command: ?*const Command = null,
    /// Whether a command should color its output (real stdout is a TTY and
    /// NO_COLOR is unset). Always false under the test harness's Allocating
    /// buffer, so golden/substring assertions there see plain text.
    color: bool = false,

    fn findFlag(self: *Ctx, long: []const u8) ?Flag {
        const cmd = self.command orelse return null;
        for (cmd.flags) |f| {
            if (std.mem.eql(u8, f.long, long)) return f;
        }
        return null;
    }

    /// Reads a boolean flag by its declared long name, using the declaration
    /// for its short form - so a command names the flag once (in `flags`) and
    /// reads it without repeating the short letter.
    pub fn flag(self: *Ctx, long: []const u8) bool {
        const short = if (self.findFlag(long)) |f| f.short else null;
        return self.args.flag(long, short);
    }

    /// Reads a value option by its declared long name, accepting `--long v`,
    /// `--long=v`, or the declared short form `-s v`.
    pub fn value(self: *Ctx, long: []const u8) Args.Error!?[]const u8 {
        if (try self.args.option(long)) |v| return v;
        if (self.findFlag(long)) |f| {
            if (f.short) |s| return self.args.shortOption(s);
        }
        return null;
    }

    /// Next positional argument in argv order, or null when none remain.
    pub fn arg(self: *Ctx) ?[]const u8 {
        return self.args.positional();
    }

    /// Next positional, erroring if absent - `name` names it in the message.
    pub fn requiredArg(self: *Ctx, name: []const u8) Args.Error![]const u8 {
        return self.args.requiredPositional(name);
    }

    /// Everything after a literal `--` (a passthrough command's own argv).
    pub fn rest(self: *Ctx) std.mem.Allocator.Error!?[]const []const u8 {
        return self.args.restAfterDoubleDash();
    }

    /// Verifies no token was left unconsumed. An unknown flag is named against
    /// the command's declared flags so the message says "unknown flag" rather
    /// than the generic "unexpected argument".
    pub fn finish(self: *Ctx) Args.Error!void {
        return self.args.finish();
    }
};

/// Section a command is listed under in the general help table.
pub const Group = enum {
    navigate,
    create,
    inspect,
    maintain,
    system,
};

/// How a positional slot or a flag's value completes. Declarative - a value,
/// not a callback, so a command author never writes a completion function or
/// touches a directive bit-flag (the two worst parts of cobra's model). The
/// framework's `__complete` engine maps each kind to candidates; `.dynamic`
/// keys (project/org/repo/...) resolve through the one app-provided hook,
/// keeping the framework core free of any app-specific knowledge.
pub const Complete = union(enum) {
    none,
    /// Defer to the shell's own filesystem completion (a path argument).
    files,
    /// A fixed set of literal candidates (e.g. `config`'s "edit").
    choices: []const []const u8,
    /// An app-defined category resolved at runtime via the completion hook.
    dynamic: []const u8,
};

/// One positional slot, declared in order. `variadic` marks a final slot that
/// soaks up the rest (e.g. `run`'s command words after `--`).
pub const Arg = struct {
    name: []const u8,
    complete: Complete = .none,
    optional: bool = false,
    variadic: bool = false,
};

/// A single flag/option, declared once. This is the sole source of truth for
/// the flag: the framework parses it, completes it, and renders it in help
/// from this one definition - never a second hand-written copy.
pub const Flag = struct {
    long: []const u8,
    short: ?u8 = null,
    help: []const u8 = "",
    /// True for an option that takes a value (`--org <name>`); false for a
    /// boolean switch (`--json`).
    takes_value: bool = false,
    value_name: []const u8 = "value",
    /// How the value completes (only meaningful when `takes_value`).
    value: Complete = .none,
};

pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    group: Group,
    /// Long-form help shown by `holt <command> --help` / `holt help
    /// <command>`: extra prose (examples, notes) on top of the auto-rendered
    /// synopsis + flags. Empty means the summary and usage already say
    /// everything worth saying.
    details: []const u8 = "",
    /// Declared positional slots, in order - drives usage rendering and
    /// per-slot completion. Empty is fine (a command with no positionals, or
    /// one not yet annotated).
    args: []const Arg = &.{},
    /// Declared flags - the single definition the parser, completer, and help
    /// all read from.
    flags: []const Flag = &.{},
    /// Nested subcommands (`holt org rename`, `holt config edit`). One level
    /// deep is all holt needs; the dispatcher resolves the first matching
    /// sub-name before parsing.
    subcommands: []const Command = &.{},
    /// False only for version, init, upgrade - every other command needs a
    /// loaded workspace before `run` is called.
    needs_workspace: bool,
    run: *const fn (ctx: *Ctx) anyerror!u8,
};

/// Left-to-right argv parser: flags, `--opt value`/`--opt=value` options,
/// and positionals are each consumed independently of call order and of
/// their position in argv, so a command can ask for them in whatever order
/// suits it. `finish` then verifies nothing was left over.
pub const Args = struct {
    alloc: std.mem.Allocator,
    items: []Item,
    /// Set by whichever of `option`/`requiredPositional`/`finish` returns
    /// `error.UsageError`; dispatch reports this to the user.
    message: []const u8 = "",

    const Item = struct {
        raw: []const u8,
        consumed: bool = false,
    };

    pub const Error = error{UsageError};

    pub fn init(alloc: std.mem.Allocator, raw_args: []const []const u8) !Args {
        const items = try alloc.alloc(Item, raw_args.len);
        for (raw_args, items) |raw, *item| item.* = .{ .raw = raw };
        return .{ .alloc = alloc, .items = items };
    }

    pub fn looksLikeFlag(s: []const u8) bool {
        return s.len > 1 and s[0] == '-';
    }

    /// Next unconsumed token that isn't flag-shaped, in argv order.
    pub fn positional(self: *Args) ?[]const u8 {
        for (self.items) |*item| {
            if (item.consumed or looksLikeFlag(item.raw)) continue;
            item.consumed = true;
            return item.raw;
        }
        return null;
    }

    /// Like `positional`, but treats a missing or empty-string result as a
    /// usage error. A project-name query obtained from the CLI must never
    /// reach `workspace.find` as an empty string - `find("")` matches every
    /// project as ambiguous instead of reporting "missing argument".
    pub fn requiredPositional(self: *Args, name: []const u8) Error![]const u8 {
        const got = self.positional() orelse "";
        if (got.len == 0) {
            self.message = std.fmt.allocPrint(self.alloc, "missing required argument: {s}", .{name}) catch "missing required argument";
            return error.UsageError;
        }
        return got;
    }

    fn isLongFlag(raw: []const u8, long: []const u8) bool {
        return std.mem.startsWith(u8, raw, "--") and std.mem.eql(u8, raw[2..], long);
    }

    fn isShortFlag(raw: []const u8, short: u8) bool {
        return raw.len == 2 and raw[0] == '-' and raw[1] == short;
    }

    /// Matches `--long` or `-{short}` among unconsumed tokens. `short` is
    /// optional; pass null for a flag with no short form.
    pub fn flag(self: *Args, long: []const u8, short: ?u8) bool {
        for (self.items) |*item| {
            if (item.consumed) continue;
            if (isLongFlag(item.raw, long) or (short != null and isShortFlag(item.raw, short.?))) {
                item.consumed = true;
                return true;
            }
        }
        return false;
    }

    /// Matches `--long=value` or `--long value` among unconsumed tokens.
    /// The two-token form errors if `--long` is the last token.
    pub fn option(self: *Args, long: []const u8) Error!?[]const u8 {
        for (self.items, 0..) |*item, i| {
            if (item.consumed or !std.mem.startsWith(u8, item.raw, "--")) continue;
            const rest = item.raw[2..];

            if (std.mem.eql(u8, rest, long)) {
                if (i + 1 >= self.items.len or self.items[i + 1].consumed) {
                    self.message = std.fmt.allocPrint(self.alloc, "--{s} requires a value", .{long}) catch "option requires a value";
                    return error.UsageError;
                }
                item.consumed = true;
                self.items[i + 1].consumed = true;
                return self.items[i + 1].raw;
            }

            if (rest.len > long.len and rest[long.len] == '=' and std.mem.startsWith(u8, rest, long)) {
                item.consumed = true;
                return rest[long.len + 1 ..];
            }
        }
        return null;
    }

    /// Matches `-{short} value` (two-token only, no glued `-nVALUE` form)
    /// among unconsumed tokens - the short-option counterpart to `option`
    /// for flags with no long form, like `recent`'s `-n`.
    pub fn shortOption(self: *Args, short: u8) Error!?[]const u8 {
        for (self.items, 0..) |*item, i| {
            if (item.consumed or !isShortFlag(item.raw, short)) continue;
            if (i + 1 >= self.items.len or self.items[i + 1].consumed) {
                self.message = std.fmt.allocPrint(self.alloc, "-{c} requires a value", .{short}) catch "option requires a value";
                return error.UsageError;
            }
            item.consumed = true;
            self.items[i + 1].consumed = true;
            return self.items[i + 1].raw;
        }
        return null;
    }

    /// Everything after a literal "--" token, verbatim - the escape hatch
    /// for a command (like `run`) that hands its own argv through to a
    /// spawned subprocess. Consumes "--" and every token after it
    /// immediately, regardless of shape, so a later `option`/`flag` call
    /// never mistakes passthrough content (e.g. a `-c` meant for the child
    /// command) for one of holt's own switches. Null when no "--" token is
    /// present. Caller owns the returned slice.
    pub fn restAfterDoubleDash(self: *Args) std.mem.Allocator.Error!?[]const []const u8 {
        for (self.items, 0..) |*item, i| {
            if (item.consumed or !std.mem.eql(u8, item.raw, "--")) continue;
            item.consumed = true;
            const tail = self.items[i + 1 ..];
            const out = try self.alloc.alloc([]const u8, tail.len);
            for (tail, out) |*t, *o| {
                t.consumed = true;
                o.* = t.raw;
            }
            return out;
        }
        return null;
    }

    /// Errors if any token was never consumed by `positional`/`flag`/`option`.
    pub fn finish(self: *Args) Error!void {
        for (self.items) |item| {
            if (!item.consumed) {
                self.message = std.fmt.allocPrint(self.alloc, "unexpected argument: {s}", .{item.raw}) catch "unexpected argument";
                return error.UsageError;
            }
        }
    }
};

fn findCommand(table: []const Command, name: []const u8) ?Command {
    for (table) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// Bounded Levenshtein edit distance; command names are short so a fixed
/// 32-byte stack row never needs to grow.
fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 31 or b.len > 31) {
        return if (a.len > b.len) a.len - b.len else b.len - a.len;
    }

    var prev: [32]usize = undefined;
    var curr: [32]usize = undefined;
    for (0..b.len + 1) |i| prev[i] = i;

    for (0..a.len) |i| {
        curr[0] = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            curr[j + 1] = @min(@min(prev[j + 1] + 1, curr[j] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// Nearest registered command name to `name`: an exact prefix match either
/// way, else the closest by edit distance. Null only for an empty table.
fn suggestCommand(table: []const Command, name: []const u8) ?[]const u8 {
    for (table) |c| {
        if (std.mem.startsWith(u8, c.name, name) or std.mem.startsWith(u8, name, c.name)) return c.name;
    }

    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (table) |c| {
        const d = editDistance(name, c.name);
        if (d < best_dist) {
            best = c.name;
            best_dist = d;
        }
    }
    return best;
}

fn groupHeading(g: Group) []const u8 {
    return switch (g) {
        .navigate => "Navigate",
        .create => "Create & membership",
        .inspect => "Inspect",
        .maintain => "Maintain",
        .system => "System",
    };
}

const group_order = [_]Group{ .navigate, .create, .inspect, .maintain, .system };

fn printHelp(w: *std.Io.Writer, table: []const Command) !void {
    var width: usize = 0;
    for (table) |c| width = @max(width, c.name.len);

    try w.writeAll("Usage: holt <command> [flags]\n");

    for (group_order) |g| {
        var any = false;
        for (table) |c| {
            if (c.group == g) any = true;
        }
        if (!any) continue;

        try w.print("\n{s}:\n", .{groupHeading(g)});
        for (table) |c| {
            if (c.group != g) continue;
            try w.writeAll("  ");
            try ui.padTo(w, c.name, width);
            try w.writeAll("  ");
            try w.writeAll(c.summary);
            try w.writeByte('\n');
        }
    }

    try w.writeAll("\nA <project> is <org>/<name>, or a unique name or abbreviation of one.\n");
    try w.writeAll("Run \"holt <command> --help\" for details on a command.\n");
    try w.writeAll("Run \"holt init <shell>\" to set up the h/hi shell helpers.\n");
}

/// `--long`, `--long, -s`, `--long <value>`, or `--long, -s <value>` for one
/// flag - the left column of the auto-rendered Flags section.
fn flagSpelling(alloc: std.mem.Allocator, f: Flag) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try aw.writer.print("--{s}", .{f.long});
    if (f.short) |s| try aw.writer.print(", -{c}", .{s});
    if (f.takes_value) try aw.writer.print(" <{s}>", .{f.value_name});
    return aw.toOwnedSlice();
}

fn printUsage(alloc: std.mem.Allocator, w: *std.Io.Writer, command: Command) !void {
    try w.print("Usage: {s}\n\n{s}\n", .{ command.usage, command.summary });

    if (command.flags.len > 0) {
        var width: usize = 0;
        const spellings = try alloc.alloc([]const u8, command.flags.len);
        for (command.flags, spellings) |f, *s| {
            s.* = try flagSpelling(alloc, f);
            width = @max(width, s.*.len);
        }
        try w.writeAll("\nFlags:\n");
        for (command.flags, spellings) |f, s| {
            try w.writeAll("  ");
            try ui.padTo(w, s, width);
            if (f.help.len > 0) try w.print("  {s}", .{f.help});
            try w.writeByte('\n');
        }
    }

    if (command.details.len > 0) {
        try w.print("\n{s}\n", .{command.details});
    }
}

/// Parses `argv` (the process's arguments, without the program name),
/// routes to the matching command in `table`, and returns the process exit
/// code, writing help/usage/error output to `out`/`err_w`. `alloc` backs a
/// fresh arena scoped to this one dispatch. Split out from `dispatch` so
/// tests can inject in-memory writers instead of the process's real stdout
/// and stderr.
/// Maps the handful of environment/tooling failures that can surface from
/// deep inside a command to a clear, actionable line, so a missing external
/// tool or an unusable config location reads as guidance rather than a bare
/// "internal error: <ErrorName>". Anything not listed keeps the generic path.
fn friendlyError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoHomeDir => "cannot locate the holt config: set $HOME or $XDG_CONFIG_HOME to an absolute path",
        error.GitNotFound => "git is not installed or not on your PATH",
        error.TarNotFound => "tar is not installed or not on your PATH",
        error.CurlNotFound => "curl is not installed or not on your PATH",
        else => null,
    };
}

fn reportUnknownCommand(table: []const Command, name: []const u8, err_w: *std.Io.Writer) u8 {
    if (suggestCommand(table, name)) |suggestion| {
        err_w.print("holt: unknown command \"{s}\" (did you mean \"{s}\"?)\n", .{ name, suggestion }) catch {};
    } else {
        err_w.print("holt: unknown command \"{s}\"\n", .{name}) catch {};
    }
    return 2;
}

/// Runs `command` with no argv, for global flags (`--version`) that borrow
/// a registered command's own output instead of duplicating it.
fn runWithNoArgs(arena: std.mem.Allocator, command: Command, out: *std.Io.Writer, err_w: *std.Io.Writer, color: bool) u8 {
    var args = Args.init(arena, &.{}) catch return 1;
    var ctx: Ctx = .{ .alloc = arena, .ws = null, .args = &args, .out = out, .err_w = err_w, .color = color };
    return command.run(&ctx) catch |err| {
        if (friendlyError(err)) |msg| {
            err_w.print("holt: {s}\n", .{msg}) catch {};
            return 1;
        }
        err_w.print("holt: internal error: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
}

/// `color` is decided once by the caller (`dispatch`, against the real
/// stdout file) and threaded down to every command's `Ctx` rather than
/// re-derived here, since a test harness has no real terminal to check.
pub fn dispatchTo(alloc: std.mem.Allocator, argv: []const []const u8, table: []const Command, out: *std.Io.Writer, err_w: *std.Io.Writer, color: bool) u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (argv.len == 0) {
        printHelp(out, table) catch {};
        return 0;
    }

    // Internal completion endpoint the generated shell scripts call. Loads the
    // workspace best-effort (a broken config just yields no dynamic
    // candidates) and never errors the shell.
    if (std.mem.eql(u8, argv[0], "__complete")) {
        var ws_storage: ?workspace.Workspace = null;
        if (config.loadDefault(arena, null)) |cfg| {
            ws_storage = .{ .cfg = cfg };
        } else |_| {}
        const ws_ptr: ?*const workspace.Workspace = if (ws_storage) |*w| w else null;
        completion.reply(arena, table, argv[1..], ws_ptr, out) catch {};
        return 0;
    }

    if (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) {
        printHelp(out, table) catch {};
        return 0;
    }

    if (std.mem.eql(u8, argv[0], "--version") or std.mem.eql(u8, argv[0], "-v")) {
        const command = findCommand(table, "version") orelse return reportUnknownCommand(table, "version", err_w);
        return runWithNoArgs(arena, command, out, err_w, color);
    }

    if (std.mem.eql(u8, argv[0], "help")) {
        if (argv.len < 2) {
            printHelp(out, table) catch {};
            return 0;
        }
        const command = findCommand(table, argv[1]) orelse return reportUnknownCommand(table, argv[1], err_w);
        printUsage(arena, out, command) catch {};
        return 0;
    }

    const cmd_name = argv[0];
    var command = findCommand(table, cmd_name) orelse return reportUnknownCommand(table, cmd_name, err_w);

    // Route one level of subcommand (`holt org rename ...`): if the next token
    // names a subcommand, dispatch to it and drop that token; otherwise the
    // parent command handles the args itself (`holt config` -> show).
    var rest = argv[1..];
    if (command.subcommands.len > 0 and rest.len > 0 and !Args.looksLikeFlag(rest[0])) {
        if (findCommand(command.subcommands, rest[0])) |sub| {
            command = sub;
            rest = rest[1..];
        }
    }

    var args = Args.init(arena, rest) catch return 1;

    if (args.flag("help", 'h')) {
        printUsage(arena, out, command) catch {};
        return 0;
    }

    var ws: ?workspace.Workspace = null;
    if (command.needs_workspace) {
        var diag: diagnostic.Diagnostic = .{};
        const cfg = config.loadDefault(arena, &diag) catch {
            err_w.print("holt: {s}\n", .{diag.message}) catch {};
            return 1;
        };
        ws = .{ .cfg = cfg };
    }

    var ctx: Ctx = .{ .alloc = arena, .ws = ws, .args = &args, .out = out, .err_w = err_w, .color = color, .command = &command };
    return command.run(&ctx) catch |err| {
        if (err == error.UsageError) {
            err_w.print("holt: {s}\n", .{args.message}) catch {};
            return 2;
        }
        if (friendlyError(err)) |msg| {
            err_w.print("holt: {s}\n", .{msg}) catch {};
            return 1;
        }
        err_w.print("holt: internal error: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
}

/// Production entry point: wraps `dispatchTo` with the process's real
/// stdout/stderr, flushing both before returning the exit code.
pub fn dispatch(alloc: std.mem.Allocator, argv: []const []const u8, table: []const Command) u8 {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_fw: std.Io.File.Writer = .init(stdout_file, fsutil.io(), &out_buf);
    var stderr_fw: std.Io.File.Writer = .init(.stderr(), fsutil.io(), &err_buf);
    const out = &stdout_fw.interface;
    const err_w = &stderr_fw.interface;
    defer out.flush() catch {};
    defer err_w.flush() catch {};

    return dispatchTo(alloc, argv, table, out, err_w, ui.colorEnabled(stdout_file));
}

fn testNoopRun(_: *Ctx) anyerror!u8 {
    return 0;
}

test "Args: flag, option, and positional are consumed regardless of order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var args = try Args.init(arena, &.{ "--force", "myproj" });
        try testing.expect(args.flag("force", 'f'));
        try testing.expectEqualStrings("myproj", args.positional().?);
    }
    {
        var args = try Args.init(arena, &.{ "myproj", "--force" });
        try testing.expectEqualStrings("myproj", args.positional().?);
        try testing.expect(args.flag("force", 'f'));
    }
    {
        var args = try Args.init(arena, &.{ "--org", "acme", "myproj" });
        try testing.expectEqualStrings("acme", (try args.option("org")).?);
        try testing.expectEqualStrings("myproj", args.positional().?);
    }
    {
        var args = try Args.init(arena, &.{ "myproj", "--org=acme" });
        try testing.expectEqualStrings("myproj", args.positional().?);
        try testing.expectEqualStrings("acme", (try args.option("org")).?);
    }
    {
        var args = try Args.init(arena, &.{"-f"});
        try testing.expect(args.flag("force", 'f'));
    }
}

test "Args.shortOption: matches -{short} value, errors when the value is missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var args = try Args.init(arena, &.{ "-n", "5", "myproj" });
        try testing.expectEqualStrings("5", (try args.shortOption('n')).?);
        try testing.expectEqualStrings("myproj", args.positional().?);
    }
    {
        var args = try Args.init(arena, &.{"myproj"});
        try testing.expect((try args.shortOption('n')) == null);
    }
    {
        var args = try Args.init(arena, &.{"-n"});
        try testing.expectError(error.UsageError, args.shortOption('n'));
        try testing.expect(std.mem.indexOf(u8, args.message, "-n") != null);
    }
}

test "Args.option: missing value after --long is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try Args.init(arena, &.{"--org"});
    try testing.expectError(error.UsageError, args.option("org"));
    try testing.expect(std.mem.indexOf(u8, args.message, "org") != null);
}

test "Args.finish: rejects unconsumed leftovers, ok once everything is taken" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var args = try Args.init(arena, &.{ "myproj", "extra" });
        _ = args.positional();
        try testing.expectError(error.UsageError, args.finish());
        try testing.expect(std.mem.indexOf(u8, args.message, "extra") != null);
    }
    {
        var args = try Args.init(arena, &.{"myproj"});
        _ = args.positional();
        try args.finish();
    }
}

test "Args.restAfterDoubleDash: isolates passthrough content from later flag/option/positional scans" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var args = try Args.init(arena, &.{ "proj", "--repo", "a", "--", "sh", "-c", "echo hi" });
        const rest = (try args.restAfterDoubleDash()).?;
        try testing.expectEqual(@as(usize, 3), rest.len);
        try testing.expectEqualStrings("sh", rest[0]);
        try testing.expectEqualStrings("-c", rest[1]);
        try testing.expectEqualStrings("echo hi", rest[2]);

        try testing.expectEqualStrings("proj", args.positional().?);
        try testing.expectEqualStrings("a", (try args.option("repo")).?);
        try args.finish();
    }
    {
        var args = try Args.init(arena, &.{"proj"});
        try testing.expect((try args.restAfterDoubleDash()) == null);
        _ = args.positional();
        try args.finish();
    }
}

test "Args.requiredPositional: rejects missing or empty, accepts the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var args = try Args.init(arena, &.{});
        try testing.expectError(error.UsageError, args.requiredPositional("project"));
    }
    {
        var args = try Args.init(arena, &.{""});
        try testing.expectError(error.UsageError, args.requiredPositional("project"));
    }
    {
        var args = try Args.init(arena, &.{"widget"});
        try testing.expectEqualStrings("widget", try args.requiredPositional("project"));
    }
}

test "suggestCommand: prefix match wins, else nearest by edit distance" {
    const table = [_]Command{
        .{ .name = "version", .summary = "", .usage = "", .group = .system, .needs_workspace = false, .run = testNoopRun },
        .{ .name = "init", .summary = "", .usage = "", .group = .system, .needs_workspace = false, .run = testNoopRun },
    };
    try testing.expectEqualStrings("version", suggestCommand(&table, "versoin").?);
    try testing.expectEqualStrings("init", suggestCommand(&table, "in").?);
    // Even a far-off typo resolves to its nearest neighbor.
    try testing.expectEqualStrings("init", suggestCommand(&table, "inot").?);
    try testing.expect(suggestCommand(&[_]Command{}, "anything") == null);
}

test "printHelp: lists every registered command exactly once" {
    const table = [_]Command{
        .{ .name = "version", .summary = "print the build identifier", .usage = "", .group = .system, .needs_workspace = false, .run = testNoopRun },
        .{ .name = "list", .summary = "enumerate every project", .usage = "", .group = .system, .needs_workspace = false, .run = testNoopRun },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try printHelp(&aw.writer, &table);

    const out = aw.written();
    for (table) |c| {
        const first = std.mem.indexOf(u8, out, c.name) orelse return error.TestUnexpectedResult;
        try testing.expect(std.mem.indexOf(u8, out[first + c.name.len ..], c.name) == null);
        try testing.expect(std.mem.indexOf(u8, out, c.summary) != null);
    }
}

test "printHelp: footer explains the project selector forms" {
    const table = [_]Command{
        .{ .name = "list", .summary = "enumerate every project", .usage = "", .group = .system, .needs_workspace = false, .run = testNoopRun },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try printHelp(&aw.writer, &table);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "A <project> is <org>/<name>, or a unique name or abbreviation of one.") != null);
}

test "printUsage: shows the command's usage and summary" {
    const command: Command = .{ .name = "version", .summary = "print the build identifier", .usage = "holt version", .group = .system, .needs_workspace = false, .run = testNoopRun };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try printUsage(testing.allocator, &aw.writer, command);

    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "holt version") != null);
    try testing.expect(std.mem.indexOf(u8, out, "print the build identifier") != null);
}

test "dispatch: no args or help prints the table and exits 0" {
    const table = [_]Command{
        .{ .name = "ok", .summary = "does nothing", .usage = "holt ok", .group = .system, .needs_workspace = false, .run = testNoopRun },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_w.deinit();

    try testing.expectEqual(@as(u8, 0), dispatchTo(testing.allocator, &.{}, &table, &out.writer, &err_w.writer, false));
    try testing.expect(std.mem.indexOf(u8, out.written(), "ok") != null);

    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), dispatchTo(testing.allocator, &.{"help"}, &table, &out.writer, &err_w.writer, false));
    try testing.expect(std.mem.indexOf(u8, out.written(), "ok") != null);
}

test "dispatch: routes to a command and returns its exit code" {
    const S = struct {
        fn run(ctx: *Ctx) anyerror!u8 {
            try testing.expect(ctx.ws == null);
            return 42;
        }
    };
    const table = [_]Command{
        .{ .name = "ok", .summary = "does nothing", .usage = "holt ok", .group = .system, .needs_workspace = false, .run = S.run },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_w.deinit();

    try testing.expectEqual(@as(u8, 42), dispatchTo(testing.allocator, &.{"ok"}, &table, &out.writer, &err_w.writer, false));
}

test "dispatch: unknown command exits 2 and suggests the closest name" {
    const table = [_]Command{
        .{ .name = "version", .summary = "", .usage = "", .group = .system, .needs_workspace = false, .run = testNoopRun },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_w.deinit();

    try testing.expectEqual(@as(u8, 2), dispatchTo(testing.allocator, &.{"bogus"}, &table, &out.writer, &err_w.writer, false));
    try testing.expect(std.mem.indexOf(u8, err_w.written(), "bogus") != null);
}

test "dispatch: a command's usage error exits 2 and reports the message" {
    const S = struct {
        fn run(ctx: *Ctx) anyerror!u8 {
            try ctx.args.finish();
            return 0;
        }
    };
    const table = [_]Command{
        .{ .name = "ok", .summary = "", .usage = "holt ok", .group = .system, .needs_workspace = false, .run = S.run },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_w.deinit();

    try testing.expectEqual(@as(u8, 2), dispatchTo(testing.allocator, &.{ "ok", "extra" }, &table, &out.writer, &err_w.writer, false));
    try testing.expect(std.mem.indexOf(u8, err_w.written(), "extra") != null);
}

test "dispatch: a command's generic error exits 1" {
    const S = struct {
        fn run(_: *Ctx) anyerror!u8 {
            return error.Boom;
        }
    };
    const table = [_]Command{
        .{ .name = "ok", .summary = "", .usage = "holt ok", .group = .system, .needs_workspace = false, .run = S.run },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_w.deinit();

    try testing.expectEqual(@as(u8, 1), dispatchTo(testing.allocator, &.{"ok"}, &table, &out.writer, &err_w.writer, false));
    try testing.expect(std.mem.indexOf(u8, err_w.written(), "holt: internal error: Boom") != null);
}

test "dispatch: --help and -h print the table and exit 0" {
    const table = [_]Command{
        .{ .name = "ok", .summary = "does nothing", .usage = "holt ok", .group = .system, .needs_workspace = false, .run = testNoopRun },
    };

    for ([_][]const u8{ "--help", "-h" }) |flag_arg| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();

        try testing.expectEqual(@as(u8, 0), dispatchTo(testing.allocator, &.{flag_arg}, &table, &out.writer, &err_w.writer, false));
        try testing.expect(std.mem.indexOf(u8, out.written(), "ok") != null);
    }
}

test "dispatch: --version and -v run the registered version command and exit 0" {
    const S = struct {
        fn run(ctx: *Ctx) anyerror!u8 {
            try ctx.args.finish();
            try ctx.out.writeAll("holt 9.9.9\n");
            return 0;
        }
    };
    const table = [_]Command{
        .{ .name = "version", .summary = "print the build identifier", .usage = "holt version", .group = .system, .needs_workspace = false, .run = S.run },
    };

    for ([_][]const u8{ "--version", "-v" }) |flag_arg| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();

        try testing.expectEqual(@as(u8, 0), dispatchTo(testing.allocator, &.{flag_arg}, &table, &out.writer, &err_w.writer, false));
        try testing.expectEqualStrings("holt 9.9.9\n", out.written());
    }
}

test "dispatch: help <command> prints that command's usage; unknown name is a usage error" {
    const table = [_]Command{
        .{ .name = "delete", .summary = "Delete a project's content and hub", .usage = "holt delete <project> [--yes]", .group = .system, .needs_workspace = true, .run = testNoopRun },
    };

    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();

        try testing.expectEqual(@as(u8, 0), dispatchTo(testing.allocator, &.{ "help", "delete" }, &table, &out.writer, &err_w.writer, false));
        try testing.expect(std.mem.indexOf(u8, out.written(), "delete") != null);
    }
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();

        try testing.expectEqual(@as(u8, 2), dispatchTo(testing.allocator, &.{ "help", "bogus" }, &table, &out.writer, &err_w.writer, false));
        try testing.expect(std.mem.indexOf(u8, err_w.written(), "bogus") != null);
    }
}

test "dispatch: a command's own -h is equivalent to --help" {
    const table = [_]Command{
        .{ .name = "ok", .summary = "does nothing", .usage = "holt ok", .group = .system, .needs_workspace = false, .run = testNoopRun },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_w.deinit();

    try testing.expectEqual(@as(u8, 0), dispatchTo(testing.allocator, &.{ "ok", "-h" }, &table, &out.writer, &err_w.writer, false));
    try testing.expect(std.mem.indexOf(u8, out.written(), "holt ok") != null);
}
