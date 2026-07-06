//! Terminal presentation: ANSI color gated on TTY + NO_COLOR
//! (https://no-color.org), a yes/no stdin prompt, and column-width padding
//! for aligned table output.

const std = @import("std");
const fsutil = @import("fsutil.zig");
const testing = std.testing;

/// True when `file` is a terminal and NO_COLOR is unset. Any NO_COLOR
/// value, including empty, disables color.
pub fn colorEnabled(file: std.Io.File) bool {
    const is_tty = file.isTty(fsutil.io()) catch return false;
    if (!is_tty) return false;
    const environ = std.Io.Threaded.global_single_threaded.environ.process_environ;
    return environ.getPosix("NO_COLOR") == null;
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

/// True iff the trimmed line starts with 'y' or 'Y' (matches "y", "yes",
/// etc). Anything else, including an empty line, means no.
fn parseYesNo(line: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    return trimmed.len > 0 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
}

/// Prints `message` to `w` and blocks on a line from stdin. EOF or anything
/// not starting with y/Y counts as "no".
pub fn confirm(w: *std.Io.Writer, message: []const u8) !bool {
    try w.print("{s} [y/N] ", .{message});
    try w.flush();

    var buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(fsutil.io(), &buf);
    const line = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return false,
        error.ReadFailed => return err,
    } orelse return false;

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
    var stdin_reader = std.Io.File.stdin().reader(fsutil.io(), &buf);
    const line = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return false,
        error.ReadFailed => return err,
    } orelse return false;

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
    var stdin_reader = std.Io.File.stdin().reader(fsutil.io(), &buf);
    const line = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return "",
        error.ReadFailed => return err,
    } orelse return "";

    return alloc.dupe(u8, trimLine(line));
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

    try testing.expect(!colorEnabled(file));
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

test "matchesExpected: exact match, whitespace-tolerant, rejects wrong name or prefix" {
    try testing.expect(matchesExpected("personal/feed", "personal/feed"));
    try testing.expect(matchesExpected("  personal/feed\r\n", "personal/feed"));
    try testing.expect(matchesExpected("personal/feed\n", "personal/feed"));
    try testing.expect(!matchesExpected("personal/other", "personal/feed"));
    try testing.expect(!matchesExpected("", "personal/feed"));
    try testing.expect(!matchesExpected("personal/f", "personal/fe"));
}
