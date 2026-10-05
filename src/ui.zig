//! Terminal presentation: ANSI color gated on TTY + NO_COLOR
//! (https://no-color.org), stdin prompts and whether stdin is a terminal,
//! paths quoted for pasting into a shell, and column-width padding for
//! aligned table output.

const std = @import("std");
const fsutil = @import("fsutil.zig");
const Env = @import("env").Env;
const testing = std.testing;

/// True when `file` is a terminal and NO_COLOR is unset. Any NO_COLOR
/// value, including empty, disables color.
pub fn colorEnabled(file: std.Io.File, alloc: std.mem.Allocator, env: Env) bool {
    const is_tty = file.isTty(fsutil.io()) catch return false;
    if (!is_tty) return false;
    // Any NO_COLOR value disables color, including an empty one, so presence is
    // the question -- not whether it reads as set.
    const raw = env.getAlloc(alloc, "NO_COLOR") catch return true;
    alloc.free(raw);
    return false;
}

/// Writes `text` wrapped in the ANSI SGR `code` (e.g. "32" for green) when
/// `enabled` is true (the caller decides this once via `colorEnabled`,
/// against the real destination file), otherwise writes it plain.
pub fn color(enabled: bool, w: *std.Io.Writer, code: []const u8, text: []const u8) !void {
    if (!enabled) return w.writeAll(text);
    try w.print("\x1b[{s}m{s}\x1b[0m", .{ code, text });
}

/// Longest byte length among `cells`, for sizing a padded column.
pub fn columnWidth(cells: []const []const u8) usize {
    var width: usize = 0;
    for (cells) |cell| width = @max(width, cell.len);
    return width;
}

/// Writes `text` followed by enough spaces to reach `width` (a no-op pad
/// when `text` is already that long or longer).
pub fn padTo(w: *std.Io.Writer, text: []const u8, width: usize) !void {
    try w.writeAll(text);
    if (text.len < width) try w.splatByteAll(' ', width - text.len);
}

/// `arg` ready to paste into a POSIX shell or fish: bare when it is
/// unambiguously literal, otherwise single-quoted, with each embedded quote
/// spliced as `'\''` outside the quotes, where both shells read it alike.
/// A backslash stays inside the quotes, where both shells keep it, unless
/// another backslash, a quote, or the closing quote follows it, which fish
/// would read with it as an escape; that one is spliced as `'\\'`. A
/// marker-derived name may hold spaces or shell metacharacters - SafeSegment
/// does not forbid them.
pub fn shellQuote(alloc: std.mem.Allocator, arg: []const u8) ![]const u8 {
    var plain = arg.len > 0;
    for (arg) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-', '/', '@' => {},
            else => plain = false,
        }
    }
    if (plain) return arg;

    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '\'');
    for (arg, 0..) |c, i| {
        switch (c) {
            '\'' => try out.appendSlice(alloc, "'\\''"),
            '\\' => if (i + 1 < arg.len and arg[i + 1] != '\\' and arg[i + 1] != '\'')
                try out.append(alloc, c)
            else
                try out.appendSlice(alloc, "'\\\\'"),
            else => try out.append(alloc, c),
        }
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

/// `arg` single-quoted for PowerShell (`powershellQuoted`), or bare when
/// every byte is one PowerShell reads literally in an argument.
pub fn powershellQuote(alloc: std.mem.Allocator, arg: []const u8) ![]const u8 {
    var plain = arg.len > 0;
    for (arg) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-', '/', '\\', ':' => {},
            else => plain = false,
        }
    }
    if (plain) return arg;
    return powershellQuoted(alloc, arg);
}

/// `s` as a PowerShell single-quoted string, each quote in it doubled:
/// `'` and U+2018 to U+201B, each of which PowerShell also reads as a
/// single quote.
pub fn powershellQuoted(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '\'');
    var i: usize = 0;
    while (i < s.len) {
        const n: usize = if (s[i] == '\'') 1 else if (i + 3 <= s.len and s[i] == 0xe2 and s[i + 1] == 0x80 and s[i + 2] >= 0x98 and s[i + 2] <= 0x9b) 3 else 0;
        if (n == 0) {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        }
        try out.appendSlice(alloc, s[i .. i + n]);
        try out.appendSlice(alloc, s[i .. i + n]);
        i += n;
    }
    try out.append(alloc, '\'');
    return out.toOwnedSlice(alloc);
}

/// The shell a hint is written for.
pub const Shell = enum { posix, powershell };

/// The shell hints are written for on this platform.
pub const native_shell: Shell = if (@import("builtin").os.tag == .windows) .powershell else .posix;

/// `path` as a hint the user pastes into a shell (`native_shell`):
/// `quotePathFor`.
pub fn quotePath(alloc: std.mem.Allocator, env: Env, path: []const u8) ![]const u8 {
    return quotePathFor(alloc, env, path, native_shell);
}

/// `path` as a hint the user pastes into `shell`. For a POSIX shell or fish,
/// `$HOME` is contracted to `~` (`fsutil.contractTilde`), `~` itself and a
/// leading `~/` are left bare so the shell still expands them, and the rest
/// is quoted when a shell would reinterpret it (`shellQuote`). For
/// PowerShell, the native absolute path, never contracted, quoted by
/// `powershellQuote`. A control character is shown as `\xHH`
/// (`printable`), so such a path is shown safely but cannot be pasted.
pub fn quotePathFor(alloc: std.mem.Allocator, env: Env, path: []const u8, shell: Shell) ![]const u8 {
    if (shell == .powershell) return printable(alloc, try powershellQuote(alloc, path));
    const t = try fsutil.contractTilde(alloc, env, path);
    if (std.mem.eql(u8, t, "~")) return t;
    if (std.mem.startsWith(u8, t, "~/")) return printable(alloc, try std.mem.concat(alloc, u8, &.{ "~/", try shellQuote(alloc, t[2..]) }));
    return printable(alloc, try shellQuote(alloc, t));
}

/// `s` with each control character, C0, DEL, or a C1 one in UTF-8, shown
/// as `\xHH` for each of its bytes, so what a name holds never drives the
/// terminal.
pub fn printable(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    for (s, 0..) |_, i| {
        if (controlLen(s, i) > 0) break;
    } else return s;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    var i: usize = 0;
    while (i < s.len) {
        const n = controlLen(s, i);
        if (n == 0) {
            try aw.writer.writeByte(s[i]);
            i += 1;
            continue;
        }
        for (s[i .. i + n]) |c| try aw.writer.print("\\x{x:0>2}", .{c});
        i += n;
    }
    return aw.written();
}

/// The bytes of the control character at `s[i]`, or 0 when none starts there.
fn controlLen(s: []const u8, i: usize) usize {
    const c = s[i];
    if (c < 0x20 or c == 0x7f) return 1;
    if (c == 0xc2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9f) return 2;
    return 0;
}

/// Test seam: when set, `stderrIsTerminal` answers this instead of asking.
pub var stderr_terminal_for_test: ?bool = null;

/// Whether standard error is a terminal; under test, false unless the seam
/// says otherwise.
pub fn stderrIsTerminal() bool {
    if (stderr_terminal_for_test) |t| return t;
    if (@import("builtin").is_test) return false;
    return std.Io.File.stderr().isTty(fsutil.io()) catch false;
}

/// Columns of the terminal standard error is on; 80 when that cannot be
/// told, as on Windows.
pub fn stderrColumns() usize {
    if (@import("builtin").os.tag == .windows) return 80;
    var size: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDERR_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
    if (std.posix.errno(rc) != .SUCCESS or size.col == 0) return 80;
    return size.col;
}

/// Whether standard error is a terminal that takes ANSI escape codes,
/// turning them on where they must be, as in a Windows console; never when
/// `TERM` is `dumb`, and under test, false unless the `stderrIsTerminal`
/// seam says otherwise.
pub fn stderrTakesEscapes(alloc: std.mem.Allocator, env: Env) bool {
    if (env.get(alloc, "TERM")) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    if (stderr_terminal_for_test) |t| return t;
    if (@import("builtin").is_test) return false;
    const f = std.Io.File.stderr();
    if (!(f.isTty(fsutil.io()) catch false)) return false;
    f.enableAnsiEscapeCodes(fsutil.io()) catch return false;
    return true;
}

/// Test seam: when set, `stdinIsTerminal` answers this instead of asking.
pub var stdin_terminal_for_test: ?bool = null;

/// Whether stdin is a terminal a prompt can read an answer from: a tty,
/// or on Windows a console or a Cygwin or MSYS pty.
pub fn stdinIsTerminal() bool {
    if (stdin_terminal_for_test) |t| return t;
    return std.Io.File.stdin().isTty(fsutil.io()) catch false;
}

/// True iff the trimmed line starts with 'y' or 'Y' (matches "y", "yes",
/// etc). Anything else, including an empty line, means no.
fn parseYesNo(line: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    return trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
}

// Test seam: when set, the prompts below answer from this buffer instead of
// the process's stdin, which under the test runner carries the build
// protocol. Each read consumes one line; an exhausted buffer reads as EOF.
pub var stdin_for_test: ?[]const u8 = null;

/// One line from stdin, without its terminator. Null means no line: end of
/// input, or a line longer than `buf`.
fn takeLine(buf: []u8) !?[]const u8 {
    if (stdin_for_test) |*canned| {
        if (canned.len == 0) return null;
        const nl = std.mem.indexOfScalar(u8, canned.*, '\n') orelse {
            defer canned.* = canned.*[canned.len..];
            return canned.*;
        };
        defer canned.* = canned.*[nl + 1 ..];
        return canned.*[0..nl];
    }

    var stdin_reader = std.Io.File.stdin().reader(fsutil.io(), buf);
    return stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => null,
        error.ReadFailed => err,
    };
}

/// Prints `message` to `w` and blocks on a line from stdin. EOF or anything
/// not starting with y/Y counts as "no".
pub fn confirm(w: *std.Io.Writer, message: []const u8) !bool {
    try w.print("{s} [y/N] ", .{message});
    try w.flush();

    var buf: [256]u8 = undefined;
    const line = try takeLine(&buf) orelse return false;
    return parseYesNo(line);
}

/// True iff `line`, trimmed of surrounding ASCII whitespace, equals
/// `expected` exactly. A prefix or suffix of `expected` does not match.
pub fn matchesExpected(line: []const u8, expected: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.eql(u8, trimmed, expected);
}

/// Prints `message` to `w` and blocks on a line from stdin, requiring it to
/// equal `expected` exactly. EOF or a read error counts as "no".
pub fn confirmTyped(w: *std.Io.Writer, message: []const u8, expected: []const u8) !bool {
    try w.print("{s} ", .{message});
    try w.flush();

    var buf: [256]u8 = undefined;
    const line = try takeLine(&buf) orelse return false;
    return matchesExpected(line, expected);
}

/// Trims surrounding ASCII whitespace and the trailing CR a Windows-style
/// line ending leaves behind after `takeDelimiter('\n')`.
fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

/// Prints `message` to `w` and blocks on one line from stdin, trimmed of
/// surrounding whitespace. EOF or an over-long line returns an empty string.
/// Caller owns the returned memory.
pub fn prompt(alloc: std.mem.Allocator, w: *std.Io.Writer, message: []const u8) ![]const u8 {
    try w.print("{s} ", .{message});
    try w.flush();

    var buf: [1024]u8 = undefined;
    const line = try takeLine(&buf) orelse return "";
    return alloc.dupe(u8, trimLine(line));
}

/// Prints `message` to `w` and blocks on one line from stdin, trimmed of
/// surrounding whitespace; null at end of input or for an over-long line,
/// so a caller asking again on an empty answer never loops on a closed
/// stdin.
pub fn ask(alloc: std.mem.Allocator, w: *std.Io.Writer, message: []const u8) !?[]const u8 {
    try w.print("{s} ", .{message});
    try w.flush();

    var buf: [1024]u8 = undefined;
    const line = try takeLine(&buf) orelse return null;
    return try alloc.dupe(u8, trimLine(line));
}

test "ask: a trimmed line, an empty one, then null at end of input" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    stdin_for_test = " keep \n\n";
    defer stdin_for_test = null;
    const first = (try ask(testing.allocator, &aw.writer, "what?")).?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("keep", first);
    const second = (try ask(testing.allocator, &aw.writer, "what?")).?;
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("", second);
    try testing.expect(try ask(testing.allocator, &aw.writer, "what?") == null);
    try testing.expectEqualStrings("what? what? what? ", aw.written());
}

test "quotePath: ~ and a leading ~/ stay bare, the rest quoted when a shell would reinterpret it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const map = try arena.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(arena);
    const home = if (@import("builtin").os.tag == .windows) "C:\\Users\\u" else "/home/u";
    try map.put("HOME", home);
    try map.put("USERPROFILE", home);
    const env: Env = .{ .map = map };
    if (@import("builtin").os.tag == .windows) return;
    try testing.expectEqualStrings("~/Code/x/.env", try quotePath(arena, env, "/home/u/Code/x/.env"));
    try testing.expectEqualStrings("~/'my repo/.env'", try quotePath(arena, env, "/home/u/my repo/.env"));
    try testing.expectEqualStrings("/srv/a", try quotePath(arena, env, "/srv/a"));
    try testing.expectEqualStrings("'/srv/it'\\''s'", try quotePath(arena, env, "/srv/it's"));
    try testing.expectEqualStrings("~", try quotePath(arena, env, "/home/u"));
    try testing.expectEqualStrings("~/'dir'\\\\''", try quotePath(arena, env, "/home/u/dir\\"));
    try testing.expectEqualStrings("'/srv/a\\b'", try quotePath(arena, env, "/srv/a\\b"));
}

test "quotePathFor: PowerShell gets the native path, never contracted, single-quoted with quotes doubled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const map = try arena.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(arena);
    try map.put("HOME", "C:\\Users\\u");
    try map.put("USERPROFILE", "C:\\Users\\u");
    const env: Env = .{ .map = map };
    try testing.expectEqualStrings("C:\\Users\\u\\Code\\x\\.env", try quotePathFor(arena, env, "C:\\Users\\u\\Code\\x\\.env", .powershell));
    try testing.expectEqualStrings("C:\\Users\\u", try quotePathFor(arena, env, "C:\\Users\\u", .powershell));
    try testing.expectEqualStrings("'C:\\Users\\u\\my repo\\.env'", try quotePathFor(arena, env, "C:\\Users\\u\\my repo\\.env", .powershell));
    try testing.expectEqualStrings("'C:\\it''s\\$x'", try quotePathFor(arena, env, "C:\\it's\\$x", .powershell));
    try testing.expectEqualStrings("'C:\\Program Files (x86)\\x'", try quotePathFor(arena, env, "C:\\Program Files (x86)\\x", .powershell));
}

test "trimLine: strips surrounding ascii whitespace and a trailing CR" {
    try testing.expectEqualStrings("hello", trimLine("  hello \r\n"));
    try testing.expectEqualStrings("", trimLine(""));
    try testing.expectEqualStrings("dropbox", trimLine("dropbox\r\n"));
}

test "colorEnabled: false for a non-tty (regular) file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = "x" });
    const file = try tmp.dir.openFile(testing.io, "f.txt", .{});
    defer file.close(testing.io);

    try testing.expect(!colorEnabled(file, testing.allocator, Env.current()));
}

test "color: writes plain text when disabled, ANSI-wrapped when enabled" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try color(false, &aw.writer, "32", "ok");
    try testing.expectEqualStrings("ok", aw.written());

    aw.clearRetainingCapacity();
    try color(true, &aw.writer, "32", "ok");
    try testing.expectEqualStrings("\x1b[32mok\x1b[0m", aw.written());
}

test "columnWidth: longest cell length, zero for an empty slice" {
    try testing.expectEqual(@as(usize, 7), columnWidth(&.{ "a", "version", "in" }));
    try testing.expectEqual(@as(usize, 0), columnWidth(&.{}));
}

test "padTo: pads short text, leaves text at or past width alone" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try padTo(&aw.writer, "ab", 5);
    try testing.expectEqualStrings("ab   ", aw.written());

    aw.clearRetainingCapacity();
    try padTo(&aw.writer, "abcdef", 3);
    try testing.expectEqualStrings("abcdef", aw.written());
}

test "parseYesNo: y/yes/Y match, everything else including empty does not" {
    try testing.expect(parseYesNo("y"));
    try testing.expect(parseYesNo("yes"));
    try testing.expect(parseYesNo("Y"));
    try testing.expect(parseYesNo("Yes"));
    try testing.expect(!parseYesNo("n"));
    try testing.expect(!parseYesNo("no"));
    try testing.expect(!parseYesNo(""));
    try testing.expect(!parseYesNo("\r"));
}

test "confirm: prints the message, accepts a y line, and declines at end of input" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    stdin_for_test = "y\n";
    defer stdin_for_test = null;
    try testing.expect(try confirm(&aw.writer, "delete it?"));
    try testing.expectEqualStrings("delete it? [y/N] ", aw.written());

    // Nothing left to read - what a non-interactive caller gets - is a "no".
    try testing.expect(!try confirm(&aw.writer, "delete it?"));
}

test "matchesExpected: exact match, whitespace-tolerant, rejects wrong name or prefix" {
    try testing.expect(matchesExpected("personal/feed", "personal/feed"));
    try testing.expect(matchesExpected("  personal/feed\r\n", "personal/feed"));
    try testing.expect(matchesExpected("personal/feed\n", "personal/feed"));
    try testing.expect(!matchesExpected("personal/other", "personal/feed"));
    try testing.expect(!matchesExpected("", "personal/feed"));
    try testing.expect(!matchesExpected("personal/f", "personal/fe"));
}

test "shellQuote: leaves a plain name bare, single-quotes anything a shell would reinterpret" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "scratch", "my.repo", "a-b_c", "v2", "code/local/x", "app@worktrees/feature" }) |plain| {
        try testing.expectEqualStrings(plain, try shellQuote(arena, plain));
    }
    try testing.expectEqualStrings("'pkg send'", try shellQuote(arena, "pkg send"));
    try testing.expectEqualStrings("'a$(x)'", try shellQuote(arena, "a$(x)"));
    try testing.expectEqualStrings("'a;b'", try shellQuote(arena, "a;b"));
    try testing.expectEqualStrings("'it'\\''s'", try shellQuote(arena, "it's"));
    try testing.expectEqualStrings("'a\\b'", try shellQuote(arena, "a\\b"));
    try testing.expectEqualStrings("'^/w/run/one\\.git$'", try shellQuote(arena, "^/w/run/one\\.git$"));
    try testing.expectEqualStrings("'a'\\\\'\\b'", try shellQuote(arena, "a\\\\b"));
    try testing.expectEqualStrings("'end'\\\\''", try shellQuote(arena, "end\\"));
}

test "shellQuote: POSIX sh and fish read a quoted backslash and quote back as the same bytes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const shells = [_][]const []const u8{ &.{ "/bin/sh", "-c" }, &.{ "fish", "--no-config", "-c" } };
    for ([_][]const u8{ "a\\b", "end\\", "it's\\", "\\\\'", "sp ace\\\\x", "app@worktrees/x", "^/w/run/one\\.git$", "a\\'b", "\\\\\\x" }) |arg| {
        for (shells) |sh| {
            const script = try std.fmt.allocPrint(arena, "printf %s {s}", .{try shellQuote(arena, arg)});
            const argv = try std.mem.concat(arena, []const u8, &.{ sh, &.{script} });
            const res = @import("proc.zig").runEnv(arena, argv, null, null) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            try testing.expectEqualStrings(arg, res.stdout);
        }
    }
}

test "powershellQuote: doubles each typographic single quote PowerShell reads as a quote, as it does an ASCII one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "'" }) |quote| {
        const arg = try std.mem.concat(arena, u8, &.{ "C:\\Bob", quote, "s tree" });
        const want = try std.mem.concat(arena, u8, &.{ "'C:\\Bob", quote, quote, "s tree'" });
        try testing.expectEqualStrings(want, try powershellQuote(arena, arg));
    }
    try testing.expectEqualStrings("'C:\\\u{201C}x\u{201D}'", try powershellQuote(arena, "C:\\\u{201C}x\u{201D}"));
}

test "printable: a C1 control character is escaped byte by byte, other characters pass" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("a\\xc2\\x85b\\xc2\\x9b", try printable(arena, "a\u{85}b\u{9b}"));
    try testing.expectEqualStrings("\u{e9}\u{a0}\u{30de}", try printable(arena, "\u{e9}\u{a0}\u{30de}"));
}

test "stderrTakesEscapes: a terminal that says it is dumb takes none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const map = try arena.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(arena);
    const env: Env = .{ .map = map };
    stderr_terminal_for_test = true;
    defer stderr_terminal_for_test = null;
    try testing.expect(stderrTakesEscapes(arena, env));
    try map.put("TERM", "dumb");
    try testing.expect(!stderrTakesEscapes(arena, env));
}
