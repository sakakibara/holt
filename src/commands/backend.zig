//! `holt backend [<name>]`: with no argument, shows the active backend (or
//! synced_root in direct mode); with `<name>`, surgically rewrites the
//! `[workspace] backend = "..."` line in config.toml to switch presets,
//! leaving every comment, blank line, and `[backends.*]` block untouched.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const config = @import("../config.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    name: cli.spec.Pos([]const u8, .{ .complete = app.cat(.backend), .optional = true, .help = "switch to this backend preset" }),
};

pub const command = app.command(Spec, .{
    .name = "backend",
    .summary = "Show or switch the active backend preset",
    .usage = "holt backend [<name>]",
    .group = .maintain,
    .details =
    \\With no argument, prints the active backend (or synced_root, in direct
    \\mode) and its resolved path.
    \\
    \\With <name>, <name> must already be a [backends.<name>] preset (see
    \\"holt backends"). Only the workspace.backend line is rewritten; every
    \\comment and [backends.*] block is left byte-for-byte unchanged.
    \\
    \\Example:
    \\  holt backend
    \\  holt backend dropbox
    ,
    .needs_context = true,
}, run);

fn hasPreset(presets: []const config.Preset, name: []const u8) bool {
    for (presets) |p| {
        if (std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const name_opt = a.name;

    const cfg = ctx.context.?.ws.cfg;

    const name = name_opt orelse {
        if (cfg.backend) |b| {
            try ctx.out.print("{s}: synced_root = {s}\n", .{ b, cfg.synced_root });
        } else {
            try ctx.out.print("synced_root = {s} (no backend)\n", .{cfg.synced_root});
        }
        return 0;
    };

    if (!hasPreset(cfg.presets, name)) {
        try ctx.err.print("holt: backend \"{s}\" is not defined; run \"holt backends\"\n", .{name});
        return 1;
    }

    const path = try config.configPath(ctx.alloc);
    const src = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), path, ctx.alloc, .limited(1 << 20));

    const rewritten = switchBackendLine(ctx.alloc, src, name) catch |err| switch (err) {
        error.NoBackendLine => {
            try ctx.err.writeAll("holt: config uses a direct synced_root, not a backend; edit the file or run \"holt setup\"\n");
            return 1;
        },
        else => return err,
    };

    try fsutil.writeFileAtomic(ctx.alloc, path, rewritten);

    try ctx.out.print("backend -> {s}\n", .{name});
    return 0;
}

const Line = struct { text: []const u8, start: usize, end: usize };

/// Walks `src` line by line, tracking the byte offsets each line spans -
/// `end` points at the line's terminating '\n' (or src.len for the final,
/// unterminated line), so callers can splice in a replacement while keeping
/// the original line-ending character untouched.
const LineIter = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(self: *LineIter) ?Line {
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        const nl = std.mem.indexOfScalarPos(u8, self.src, start, '\n');
        const end = nl orelse self.src.len;
        self.pos = if (nl) |n| n + 1 else self.src.len;
        return .{ .text = self.src[start..end], .start = start, .end = end };
    }
};

/// True if `trimmed_key_eq` (a trimmed line already known to contain '=')
/// assigns exactly `key` - i.e. the text before '=' trims to `key`, not some
/// other identifier that merely starts with it (e.g. "backend_url").
fn assignsKey(trimmed: []const u8, key: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    return std.mem.eql(u8, std.mem.trimEnd(u8, trimmed[0..eq], " \t"), key);
}

/// True if `trimmed` (already known to start with '[') is a table header
/// naming exactly `name` - the header name is the text between '[' and ']',
/// so a trailing comment or whitespace after the ']' (e.g. `[workspace]  #
/// note`) doesn't stop it from matching.
fn isTableHeader(trimmed: []const u8, name: []const u8) bool {
    const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse trimmed.len;
    return std.mem.eql(u8, trimmed[1..close], name);
}

/// Returns the trailing `  # ...` comment (including its leading whitespace)
/// following a line's `= "..."` value, or "" if the value has no comment
/// after it. A '#' inside the quoted value is part of the value, not a
/// comment, so only text after the closing quote is searched.
fn valueTrailingComment(line_text: []const u8, indent_len: usize) []const u8 {
    const eq = std.mem.indexOfScalarPos(u8, line_text, indent_len, '=') orelse return "";
    var i = eq + 1;
    while (i < line_text.len and (line_text[i] == ' ' or line_text[i] == '\t')) : (i += 1) {}
    if (i >= line_text.len or line_text[i] != '"') return "";
    const close = std.mem.indexOfScalarPos(u8, line_text, i + 1, '"') orelse return "";
    const remainder = line_text[close + 1 ..];
    if (std.mem.indexOfScalar(u8, remainder, '#') == null) return "";
    return remainder;
}

/// Locates the single `backend = "..."` line inside the `[workspace]` table
/// (before the next `[...]` table header, so a `[backends.*]` block's own
/// `synced_root = ` line is never in scope) and replaces its value with
/// `name`, preserving indentation, a trailing inline comment, and every
/// other byte of the file - comments, blank lines, and `[backends.*]` blocks
/// included. Returns `error.NoBackendLine` when the file has no such line
/// (direct-synced_root mode), leaving the caller to report that as a
/// structural-change error.
fn switchBackendLine(alloc: std.mem.Allocator, src: []const u8, name: []const u8) ![]u8 {
    var it: LineIter = .{ .src = src };
    var in_workspace = false;
    var target: ?Line = null;

    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line.text, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            in_workspace = isTableHeader(trimmed, "workspace");
            continue;
        }
        if (!in_workspace or trimmed.len == 0 or trimmed[0] == '#') continue;
        if (assignsKey(trimmed, "backend")) {
            target = line;
            break;
        }
    }

    const line = target orelse return error.NoBackendLine;
    const indent_len = line.text.len - std.mem.trimStart(u8, line.text, " \t").len;
    const comment = valueTrailingComment(line.text, indent_len);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll(src[0..line.start]);
    try w.writeAll(line.text[0..indent_len]);
    try w.print("backend = \"{s}\"", .{name});
    try w.writeAll(comment);
    try w.writeAll(src[line.end..]);
    return aw.toOwnedSlice();
}

fn testWorkspace(alloc: std.mem.Allocator, root: []const u8, backend: ?[]const u8, presets: []const config.Preset) !@import("../workspace.zig").Workspace {
    return .{ .cfg = .{
        .backend = backend,
        .presets = @constCast(presets),
        .synced_root = try std.fs.path.join(alloc, &.{ root, "synced" }),
        .code_root = try std.fs.path.join(alloc, &.{ root, "code" }),
        .hub_root = try std.fs.path.join(alloc, &.{ root, "hub" }),
    } };
}

fn writeConfigFixture(alloc: std.mem.Allocator, tmp: *testing.TmpDir, content: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const dir_path = try std.fs.path.join(alloc, &.{ root, "holt" });
    try fsutil.ensureDir(dir_path);
    const path = try std.fs.path.join(alloc, &.{ dir_path, "config.toml" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = path, .data = content });
    return path;
}

test "run: no argument prints the active backend name and resolved synced_root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const presets = [_]config.Preset{.{ .name = "dropbox", .synced_root = "~/Dropbox/workspace" }};
    const ws = try testWorkspace(arena, root, "dropbox", &presets);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "dropbox: synced_root = ") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, ws.cfg.synced_root) != null);
}

test "run: no argument in direct mode prints the (no backend) form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = try testWorkspace(arena, root, null, &.{});

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    const want = try std.fmt.allocPrint(arena, "synced_root = {s} (no backend)\n", .{ws.cfg.synced_root});
    try testing.expectEqualStrings(want, got.out);
}

test "run: switching to a defined preset rewrites only the workspace.backend line, preserving comments and [backends.*] blocks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer override.restore();

    const fixture =
        \\[workspace]
        \\# The active backend selects a preset from [backends] below.
        \\backend = "dropbox"
        \\code_root = "~/Code"
        \\hub_root = "~/Projects"
        \\
        \\# my note
        \\
        \\[backends.dropbox]
        \\synced_root = "~/Dropbox/workspace"
        \\
        \\[backends.icloud]
        \\synced_root = "~/Library/Mobile Documents/com~apple~CloudDocs/workspace"
        \\
    ;
    const path = try writeConfigFixture(arena, &tmp, fixture);

    const presets = [_]config.Preset{
        .{ .name = "dropbox", .synced_root = "~/Dropbox/workspace" },
        .{ .name = "icloud", .synced_root = "~/Library/Mobile Documents/com~apple~CloudDocs/workspace" },
    };
    const ws = try testWorkspace(arena, root, "dropbox", &presets);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"icloud"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("backend -> icloud\n", got.out);

    const want = try std.mem.replaceOwned(u8, arena, fixture, "backend = \"dropbox\"", "backend = \"icloud\"");
    const after = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(want, after);
    try testing.expect(std.mem.indexOf(u8, after, "# my note") != null);
    try testing.expect(std.mem.indexOf(u8, after, "[backends.dropbox]") != null);
    try testing.expect(std.mem.indexOf(u8, after, "[backends.icloud]") != null);

    const reloaded = try config.load(arena, path, null);
    try testing.expectEqualStrings("icloud", reloaded.backend.?);
}

test "run: switching preserves a trailing inline comment on the backend line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer override.restore();

    const fixture =
        \\[workspace]
        \\backend = "icloud"  # pick one
        \\code_root = "~/Code"
        \\hub_root = "~/Projects"
        \\
        \\[backends.dropbox]
        \\synced_root = "~/Dropbox/workspace"
        \\
        \\[backends.icloud]
        \\synced_root = "~/Library/Mobile Documents/com~apple~CloudDocs/workspace"
        \\
    ;
    const path = try writeConfigFixture(arena, &tmp, fixture);

    const presets = [_]config.Preset{
        .{ .name = "dropbox", .synced_root = "~/Dropbox/workspace" },
        .{ .name = "icloud", .synced_root = "~/Library/Mobile Documents/com~apple~CloudDocs/workspace" },
    };
    const ws = try testWorkspace(arena, root, "icloud", &presets);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"dropbox"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("backend -> dropbox\n", got.out);

    const want = try std.mem.replaceOwned(u8, arena, fixture, "backend = \"icloud\"", "backend = \"dropbox\"");
    const after = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(want, after);
    try testing.expect(std.mem.indexOf(u8, after, "backend = \"dropbox\"  # pick one") != null);

    const reloaded = try config.load(arena, path, null);
    try testing.expectEqualStrings("dropbox", reloaded.backend.?);
}

test "run: a commented [workspace] header is still recognized as the workspace table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer override.restore();

    const fixture =
        \\[workspace]  # main table
        \\backend = "alpha"
        \\
        \\[backends.alpha]
        \\synced_root = "~/alpha"
        \\
        \\[backends.beta]
        \\synced_root = "~/beta"
        \\
    ;
    const path = try writeConfigFixture(arena, &tmp, fixture);

    const presets = [_]config.Preset{
        .{ .name = "alpha", .synced_root = "~/alpha" },
        .{ .name = "beta", .synced_root = "~/beta" },
    };
    const ws = try testWorkspace(arena, root, "alpha", &presets);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"beta"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("backend -> beta\n", got.out);

    const want = try std.mem.replaceOwned(u8, arena, fixture, "backend = \"alpha\"", "backend = \"beta\"");
    const after = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(want, after);

    const reloaded = try config.load(arena, path, null);
    try testing.expectEqualStrings("beta", reloaded.backend.?);
}

test "run: an undefined preset name exits 1 and leaves the file byte-unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer override.restore();

    const fixture =
        \\[workspace]
        \\backend = "dropbox"
        \\
        \\[backends.dropbox]
        \\synced_root = "~/Dropbox/workspace"
        \\
    ;
    const path = try writeConfigFixture(arena, &tmp, fixture);

    const presets = [_]config.Preset{.{ .name = "dropbox", .synced_root = "~/Dropbox/workspace" }};
    const ws = try testWorkspace(arena, root, "dropbox", &presets);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"nope"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "\"nope\" is not defined") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt backends") != null);

    const after = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(fixture, after);
}

test "run: a direct-synced_root config errors and leaves the file byte-unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", root);
    defer override.restore();

    const fixture =
        \\[workspace]
        \\synced_root = "~/x"
        \\
    ;
    const path = try writeConfigFixture(arena, &tmp, fixture);

    const presets = [_]config.Preset{.{ .name = "dropbox", .synced_root = "~/Dropbox/workspace" }};
    const ws = try testWorkspace(arena, root, null, &presets);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"dropbox"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "direct synced_root") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt setup") != null);

    const after = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(fixture, after);
}

test "switchBackendLine: a [backends.*] block's own synced_root line is never mistaken for workspace.backend" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\[workspace]
        \\backend = "a"
        \\
        \\[backends.a]
        \\synced_root = "~/a"
        \\
        \\[backends.b]
        \\synced_root = "~/b"
        \\
    ;
    const got = try switchBackendLine(arena, src, "b");
    try testing.expect(std.mem.indexOf(u8, got, "backend = \"b\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "synced_root = \"~/a\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "synced_root = \"~/b\"") != null);
}
