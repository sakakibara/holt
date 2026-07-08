//! Resolves $EDITOR and launches it on a path with inherited stdio, shared by
//! `holt edit` and `holt config edit`. $EDITOR may carry arguments (e.g.
//! "code -w" or "emacsclient -nw"); they are split on whitespace and passed
//! ahead of the path, so a multi-word editor command works rather than being
//! treated as one impossible binary name.

const std = @import("std");
const cli = @import("cli.zig");
const proc = @import("proc.zig");
const fsutil = @import("fsutil.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

/// Opens `path` in $EDITOR (child cwd `cwd`, or the process cwd when null),
/// returning the editor's exit code. Reports on ctx.err_w and returns 1 when
/// $EDITOR is unset or blank, its binary is not on PATH, or it exits nonzero -
/// an interactive editor needs the real terminal, so stdio is inherited.
pub fn open(ctx: *cli.Ctx, path: []const u8, cwd: ?[]const u8) !u8 {
    const alloc = ctx.alloc;

    const environ = std.Io.Threaded.global_single_threaded.environ.process_environ;
    const raw = std.process.Environ.getAlloc(environ, alloc, "EDITOR") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            try ctx.err_w.writeAll("holt: $EDITOR is not set\n");
            return 1;
        },
        else => return err,
    };
    // An EDITOR of "" (set but empty) means the same as unset, not a spawn of
    // the empty string.
    if (std.mem.trim(u8, raw, " \t").len == 0) {
        try ctx.err_w.writeAll("holt: $EDITOR is not set\n");
        return 1;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, raw, " \t");
    while (words.next()) |word| try argv.append(alloc, word);
    try argv.append(alloc, path);

    const status = proc.spawnInherited(alloc, argv.items, cwd) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.err_w.print("holt: editor \"{s}\" was not found on your PATH\n", .{argv.items[0]});
            return 1;
        },
        else => return err,
    };
    if (status != 0) {
        try ctx.err_w.print("holt: {s} exited with status {d}\n", .{ raw, status });
        return 1;
    }
    return 0;
}

fn testCtx(arena: std.mem.Allocator, out: *std.Io.Writer.Allocating, err_w: *std.Io.Writer.Allocating, args: *cli.Args) cli.Ctx {
    return .{ .alloc = arena, .ws = null, .args = args, .out = &out.writer, .err_w = &err_w.writer };
}

test "open: a multi-word $EDITOR is split into a command plus the path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    // A two-word editor: the wrapper script records each argv it received, so
    // splitting "<script> --flag" into two words plus the path is observable.
    const record = try std.fs.path.join(arena, &.{ root, "argv.txt" });
    const script = try testutil.writeFakeEditor(arena, root, record, .{ .args = 2 });

    const editor_val = try std.fmt.allocPrint(arena, "{s} --flag", .{script});
    const override = try testutil.EnvOverride.install(arena, "EDITOR", editor_val);
    defer override.restore();

    const target = try std.fs.path.join(arena, &.{ root, "file.txt" });

    var args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx = testCtx(arena, &out, &err_w, &args);

    try testing.expectEqual(@as(u8, 0), try open(&ctx, target, null));

    const recorded = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), record, arena, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, recorded, "\r\n"), '\n');
    try testing.expectEqualStrings("--flag", std.mem.trimEnd(u8, lines.next().?, "\r"));
    try testing.expectEqualStrings(target, std.mem.trimEnd(u8, lines.next().?, "\r"));
}

test "open: a blank $EDITOR is treated as unset, never spawned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const override = try testutil.EnvOverride.install(arena, "EDITOR", "   ");
    defer override.restore();

    var args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx = testCtx(arena, &out, &err_w, &args);

    try testing.expectEqual(@as(u8, 1), try open(&ctx, "/tmp/whatever", null));
    try testing.expect(std.mem.indexOf(u8, err_w.written(), "EDITOR") != null);
}

test "open: an editor binary that is not on PATH is reported by name, not a bare error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const override = try testutil.EnvOverride.install(arena, "EDITOR", "holt-no-such-editor-xyz");
    defer override.restore();

    var args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx = testCtx(arena, &out, &err_w, &args);

    try testing.expectEqual(@as(u8, 1), try open(&ctx, "/tmp/whatever", null));
    try testing.expect(std.mem.indexOf(u8, err_w.written(), "holt-no-such-editor-xyz") != null);
    try testing.expect(std.mem.indexOf(u8, err_w.written(), "not") != null);
}
