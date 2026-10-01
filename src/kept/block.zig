//! The delimited block holt keeps in `$GIT_COMMON_DIR/info/exclude`: one
//! anchored, escaped line per kept path git must not see, and one per
//! temporary holt has beside such a path. Text outside the block is never
//! changed.

const std = @import("std");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const testing = std.testing;

pub const begin_line = "# holt kept files (managed by holt)";
pub const end_line = "# end holt kept files";

pub const Parsed = struct {
    /// Bytes before the block's first line, or the whole file when there
    /// is no block.
    before: []const u8,
    /// Bytes after the block's last line and its line ending.
    after: []const u8,
    present: bool,
    /// The paths the block's lines name, in file order.
    rels: []const []const u8,
    /// The temporaries (`paths.tempRel`) the block's lines name.
    temps: []const []const u8,
    /// Block lines that name no valid path, kept verbatim on rewrite.
    foreign: []const []const u8,
};

/// Splits `text` around holt's block. More than one begin or end line, an
/// end before a begin, or a begin without an end is `UnbalancedBlock`.
pub fn parse(alloc: std.mem.Allocator, text: []const u8) !Parsed {
    var begin: ?usize = null;
    var end: ?usize = null;
    var after_start: usize = text.len;
    var rels: std.ArrayList([]const u8) = .empty;
    var temps: std.ArrayList([]const u8) = .empty;
    var foreign: std.ArrayList([]const u8) = .empty;

    var pos: usize = 0;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n');
        const line_end = nl orelse text.len;
        const next = if (nl) |n| n + 1 else text.len;
        const line = std.mem.trimEnd(u8, text[pos..line_end], "\r");
        if (std.mem.eql(u8, line, begin_line)) {
            if (begin != null) return error.UnbalancedBlock;
            begin = pos;
        } else if (std.mem.eql(u8, line, end_line)) {
            if (begin == null or end != null) return error.UnbalancedBlock;
            end = pos;
            after_start = next;
        } else if (begin != null and end == null and line.len > 0) {
            if (lineRel(alloc, line)) |rel| {
                if (paths.isTempRel(rel)) try temps.append(alloc, rel) else try rels.append(alloc, rel);
            } else try foreign.append(alloc, line);
        }
        pos = next;
    }
    if (begin == null) {
        if (end != null) return error.UnbalancedBlock;
        return .{ .before = text, .after = "", .present = false, .rels = &.{}, .temps = &.{}, .foreign = &.{} };
    }
    if (end == null) return error.UnbalancedBlock;
    return .{ .before = text[0..begin.?], .after = text[after_start..], .present = true, .rels = rels.items, .temps = temps.items, .foreign = foreign.items };
}

/// The paths and temporaries an unbalanced block most likely names: every
/// line after a begin line, up to the next end line or the end of `text`.
pub fn salvage(alloc: std.mem.Allocator, text: []const u8) !struct { rels: []const []const u8, temps: []const []const u8 } {
    var rels: std.ArrayList([]const u8) = .empty;
    var temps: std.ArrayList([]const u8) = .empty;
    var inside = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, begin_line)) {
            inside = true;
        } else if (std.mem.eql(u8, line, end_line)) {
            inside = false;
        } else if (inside) if (lineRel(alloc, line)) |rel| {
            if (paths.isTempRel(rel)) try temps.append(alloc, rel) else try rels.append(alloc, rel);
        };
    }
    return .{ .rels = rels.items, .temps = temps.items };
}

fn lineRel(alloc: std.mem.Allocator, line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '/') return null;
    const rel = paths.unescapePattern(alloc, line[1..]) catch return null;
    if (paths.check(rel) != null and !paths.isTempRel(rel)) return null;
    return rel;
}

/// The block line for `rel`: anchored at the repository root, escaped, and
/// never ending in `/`, since git sees a directory link as a file.
fn lineFor(alloc: std.mem.Allocator, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "/{s}", .{try paths.escapePattern(alloc, rel, false)});
}

/// `parsed`'s surrounding text with a block naming `rels` (paths and
/// temporaries; sorted, unique) plus its foreign lines. With nothing to
/// name, the block is left out.
pub fn render(alloc: std.mem.Allocator, parsed: Parsed, rels: []const []const u8) ![]u8 {
    const sorted = try alloc.dupe([]const u8, rels);
    std.mem.sort([]const u8, sorted, {}, paths.lessThan);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, parsed.before);
    if (sorted.len + parsed.foreign.len > 0) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
        try out.appendSlice(alloc, begin_line ++ "\n");
        for (sorted, 0..) |rel, i| {
            if (i > 0 and std.mem.eql(u8, sorted[i - 1], rel)) continue;
            try out.appendSlice(alloc, try lineFor(alloc, rel));
            try out.append(alloc, '\n');
        }
        for (parsed.foreign) |line| {
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
        }
        try out.appendSlice(alloc, end_line ++ "\n");
    }
    try out.appendSlice(alloc, parsed.after);
    return out.items;
}

/// The block lines naming `rels` (paths and temporaries), followed by
/// `foreign` verbatim, one per line: what git reads from the block.
pub fn patternText(alloc: std.mem.Allocator, rels: []const []const u8, foreign: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (rels) |rel| {
        try out.appendSlice(alloc, try lineFor(alloc, rel));
        try out.append(alloc, '\n');
    }
    for (foreign) |line| {
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    return out.items;
}

pub fn excludePath(alloc: std.mem.Allocator, common_dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ common_dir, "info", "exclude" });
}

/// The block of the clone whose common git directory is `common_dir`. A
/// missing exclude file has no block.
pub fn read(alloc: std.mem.Allocator, common_dir: []const u8) !Parsed {
    const bytes = content.readSmall(alloc, try excludePath(alloc, common_dir)) catch |err| switch (err) {
        error.FileNotFound => return parse(alloc, ""),
        else => return err,
    };
    return parse(alloc, bytes);
}

/// Rewrites the clone's block to name exactly `rels` (paths and
/// temporaries), atomically, creating `info/` if absent. Returns whether
/// the file changed.
pub fn write(alloc: std.mem.Allocator, common_dir: []const u8, rels: []const []const u8) !bool {
    const path = try excludePath(alloc, common_dir);
    const old = content.readSmall(alloc, path) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const new = try render(alloc, try parse(alloc, old), rels);
    if (std.mem.eql(u8, old, new)) return false;
    try fsutil.ensureDir(std.fs.path.dirname(path).?);
    try fsutil.writeFileAtomic(alloc, path, new);
    return true;
}

const Fixture = @import("harness.zig").Fixture;

/// Adds `extra` (paths or temporaries) to the lines the clone's block
/// already names.
pub fn add(alloc: std.mem.Allocator, common_dir: []const u8, extra: []const []const u8) !void {
    const parsed = try read(alloc, common_dir);
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.appendSlice(alloc, parsed.rels);
    try lines.appendSlice(alloc, parsed.temps);
    try lines.appendSlice(alloc, extra);
    _ = try write(alloc, common_dir, lines.items);
}

/// Removes the line naming `line` (a path or a temporary) from the clone's
/// block.
pub fn drop(alloc: std.mem.Allocator, common_dir: []const u8, line: []const u8) !void {
    const parsed = try read(alloc, common_dir);
    var lines: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ parsed.rels, parsed.temps }) |list| {
        for (list) |l| if (!std.mem.eql(u8, l, line)) try lines.append(alloc, l);
    }
    _ = try write(alloc, common_dir, lines.items);
}

test "parse and render: text outside the block survives byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const text = "# git ls-files --others --exclude-from=.git/info/exclude\r\n*.swp\n" ++
        begin_line ++ "\n/.clasp.json\n/.superpowers\n" ++ end_line ++ "\ntrailing\n";
    const p = try parse(a, text);
    try testing.expect(p.present);
    try testing.expectEqual(@as(usize, 2), p.rels.len);
    try testing.expectEqualStrings(text, try render(a, p, p.rels));

    const grown = try render(a, p, &.{ "z[1].txt", ".clasp.json", ".superpowers", ".clasp.json" });
    try testing.expectEqualStrings("# git ls-files --others --exclude-from=.git/info/exclude\r\n*.swp\n" ++
        begin_line ++ "\n/.clasp.json\n/.superpowers\n/z\\[1\\].txt\n" ++ end_line ++ "\ntrailing\n", grown);

    const emptied = try render(a, p, &.{});
    try testing.expectEqualStrings("# git ls-files --others --exclude-from=.git/info/exclude\r\n*.swp\ntrailing\n", emptied);
}

test "render: appends a block after text with no final newline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = try render(a, try parse(a, "*.o"), &.{"a b "});
    try testing.expectEqualStrings("*.o\n" ++ begin_line ++ "\n/a b\\ \n" ++ end_line ++ "\n", got);
    try testing.expectEqualStrings("a b ", (try parse(a, got)).rels[0]);
}

test "parse: an unbalanced block is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{
        begin_line ++ "\n/a\n",
        end_line ++ "\n",
        end_line ++ "\n" ++ begin_line ++ "\n",
        begin_line ++ "\n" ++ begin_line ++ "\n" ++ end_line ++ "\n",
        begin_line ++ "\n" ++ end_line ++ "\n" ++ end_line ++ "\n",
    }) |text| try testing.expectError(error.UnbalancedBlock, parse(a, text));
}

test "salvage: an unbalanced block's lines are read up to an end line or the end of the file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const temp = try paths.tempRel(a, "b");
    const got = try salvage(a, try std.fmt.allocPrint(a, "/user\n" ++ begin_line ++ "\n/a\n" ++ end_line ++ "\n/outside\n" ++ begin_line ++ "\n/b\n/{s}\n", .{temp}));
    try testing.expectEqual(@as(usize, 2), got.rels.len);
    try testing.expectEqualStrings("a", got.rels[0]);
    try testing.expectEqualStrings("b", got.rels[1]);
    try testing.expectEqualStrings(temp, got.temps[0]);
}

test "parse: a line naming no valid path is kept verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p = try parse(a, begin_line ++ "\n/ok\nnot-anchored\n/../x\n" ++ end_line ++ "\n");
    try testing.expectEqual(@as(usize, 1), p.rels.len);
    try testing.expectEqual(@as(usize, 2), p.foreign.len);
    try testing.expectEqualStrings(begin_line ++ "\n/ok\nnot-anchored\n/../x\n" ++ end_line ++ "\n", try render(a, p, p.rels));
}

test "parse: a temporary's line is read apart from the paths" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const temp = try paths.tempRel(a, "dir/.env");
    const text = try render(a, try parse(a, ""), &.{ "dir/.env", temp });
    const p = try parse(a, text);
    try testing.expectEqual(@as(usize, 1), p.rels.len);
    try testing.expectEqualStrings("dir/.env", p.rels[0]);
    try testing.expectEqual(@as(usize, 1), p.temps.len);
    try testing.expectEqualStrings(temp, p.temps[0]);
    try testing.expectEqual(@as(usize, 0), p.foreign.len);
}

test "write: creates info/, reports change, and is a no-op when nothing changes" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const common = f.root;

    try testing.expect(try write(a, common, &.{".clasp.json"}));
    try testing.expect(!try write(a, common, &.{".clasp.json"}));
    try testing.expectEqualStrings(".clasp.json", (try read(a, common)).rels[0]);
    try testing.expect(try write(a, common, &.{}));
    try testing.expectEqualStrings("", try content.readSmall(a, try excludePath(a, common)));
}
