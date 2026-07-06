//! `holt keep <path>`: promote a loose local entry at the hub root into synced
//! content, leaving a symlink behind so it still shows at the project root and
//! now syncs to the cloud. The project is inferred from the working directory.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const common = @import("common.zig");
const fsutil = @import("../fsutil.zig");
const projectlock = @import("../projectlock.zig");
const testutil = @import("../testutil.zig");
const testing = std.testing;

const Spec = struct {
    path: args.Pos([]const u8, .{ .complete = .files, .help = "the loose file or dir at the hub root to keep in synced content" }),
};

pub const command = args.command(Spec, .{
    .name = "keep",
    .about = "Promote a loose hub-root file into synced content",
    .usage = "holt keep <path>",
    .group = .create,
    .details =
    \\Run from inside a project's hub. Moves the loose local entry into the
    \\project's synced content and leaves a symlink at the hub root, so it now
    \\syncs to the cloud.
    ,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const alloc = ctx.alloc;

    const p = (try common.projectFromCwd(ctx)) orelse {
        try ctx.err_w.writeAll("holt: run \"holt keep\" from inside a project hub\n");
        return 1;
    };

    const abs = try fsutil.toAbsolute(alloc, a.path);
    const base = std.fs.path.basename(abs);

    if (std.mem.eql(u8, base, "code") or std.mem.eql(u8, base, ".holt.json")) {
        try ctx.err_w.print("holt: {s} is reserved and cannot be kept\n", .{base});
        return 1;
    }

    switch (try fsutil.linkState(alloc, abs)) {
        .missing => {
            try ctx.err_w.print("holt: no such entry {s}\n", .{abs});
            return 1;
        },
        .symlink => {
            try ctx.out.print("already kept: {s}\n", .{base});
            return 0;
        },
        .other => {},
    }

    const dest = try std.fs.path.join(alloc, &.{ p.content_path, base });
    if (fsutil.exists(dest)) {
        try ctx.err_w.print("holt: content already has {s}; refusing to overwrite\n", .{base});
        return 1;
    }

    var lock = try projectlock.acquire(alloc, p.content_path);
    defer lock.release();

    try fsutil.moveTree(alloc, abs, dest);
    try fsutil.replaceSymlink(dest, abs);

    try ctx.out.print("kept {s} -> content\n", .{base});
    return 0;
}

test "run: moves a loose hub file into content and leaves a symlink" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = try testutil.testWorkspace(arena, root);
    const repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const content = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj" });
    try fsutil.ensureDir(content);
    const hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(hub);

    // A loose local file at the hub root.
    const loose = try std.fs.path.join(arena, &.{ hub, "notes.md" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = loose, .data = "hello\n" });

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    // cwd is process-global and shared by every test in this binary, so a
    // missing restore here would corrupt every test that runs afterward.
    try std.process.setCurrentPath(fsutil.io(), hub);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const got = try testutil.runCmd(arena, command.run, ws, &.{"notes.md"});
    try testing.expectEqual(@as(u8, 0), got.code);

    // Moved into content.
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ content, "notes.md" })));
    // Hub entry is now a symlink into content.
    switch (try fsutil.linkState(arena, loose)) {
        .symlink => |t| try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ content, "notes.md" }), t),
        else => return error.TestUnexpectedResult,
    }
}

test "run: keeping an already-kept entry is an idempotent no-op success" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = try testutil.testWorkspace(arena, root);
    const repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const content = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj" });
    try fsutil.ensureDir(content);
    const hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(hub);

    const loose = try std.fs.path.join(arena, &.{ hub, "notes.md" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = loose, .data = "hello\n" });

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    try std.process.setCurrentPath(fsutil.io(), hub);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const first = try testutil.runCmd(arena, command.run, ws, &.{"notes.md"});
    try testing.expectEqual(@as(u8, 0), first.code);

    // notes.md is now a symlink into content; keeping it again is a no-op,
    // not a re-move or an error.
    const again = try testutil.runCmd(arena, command.run, ws, &.{"notes.md"});
    try testing.expectEqual(@as(u8, 0), again.code);
    try testing.expect(std.mem.indexOf(u8, again.out, "already kept") != null);

    switch (try fsutil.linkState(arena, loose)) {
        .symlink => |t| try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ content, "notes.md" }), t),
        else => return error.TestUnexpectedResult,
    }
}

test "run: refuses when content already has that name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = try testutil.testWorkspace(arena, root);
    const repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const content = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj" });
    try fsutil.ensureDir(content);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ content, "notes.md" }), .data = "existing\n" });
    const hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(hub);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ hub, "notes.md" }), .data = "loose\n" });

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    try std.process.setCurrentPath(fsutil.io(), hub);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const got = try testutil.runCmd(arena, command.run, ws, &.{"notes.md"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already has") != null);
}

test "run: errors clearly when not inside a hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const outside = try std.fs.path.join(arena, &.{ root, "elsewhere" });
    try fsutil.ensureDir(outside);

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    try std.process.setCurrentPath(fsutil.io(), outside);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const got = try testutil.runCmd(arena, command.run, ws, &.{"whatever"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "from inside a project hub") != null);
}
