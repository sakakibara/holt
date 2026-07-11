//! `holt keep <path>`: promote a loose local entry at the hub root into synced
//! content, leaving a symlink behind so it still shows at the project root and
//! now syncs to the cloud. The project is inferred from the working directory.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const fsutil = @import("../fsutil.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const testutil = @import("../testutil.zig");
const testing = std.testing;

const Spec = struct {
    path: cli.spec.Pos([]const u8, .{ .complete = .files, .help = "the loose file or dir at the hub root to keep in synced content" }),
};

pub const command = app.command(Spec, .{
    .name = "keep",
    .summary = "Promote a loose hub-root file into synced content",
    .usage = "holt keep <path>",
    .group = .create,
    .needs_context = true,
    .details =
    \\Run from inside a project's hub. Moves the loose local entry into the
    \\project's synced content and leaves a symlink at the hub root, so it now
    \\syncs to the cloud.
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const alloc = ctx.alloc;

    const p = (try common.projectFromCwd(ctx)) orelse {
        try ctx.err.writeAll("holt: run \"holt keep\" from inside a project hub\n");
        return 1;
    };

    const abs = try fsutil.toAbsolute(alloc, a.path);
    const base = std.fs.path.basename(abs);

    if (std.mem.eql(u8, base, "code") or std.mem.eql(u8, base, marker.marker_basename)) {
        try ctx.err.print("holt: {s} is reserved and cannot be kept\n", .{base});
        return 1;
    }

    const parent_real = try fsutil.realPathOrSelf(alloc, std.fs.path.dirname(abs) orelse abs);
    const hub_real = try fsutil.realPathOrSelf(alloc, p.hub_path);
    if (!std.mem.eql(u8, parent_real, hub_real)) {
        try ctx.err.print("holt: keep only accepts an entry at the project root ({s})\n", .{p.hub_path});
        return 1;
    }

    switch (try fsutil.linkState(alloc, abs)) {
        .missing => {
            try ctx.err.print("holt: no such entry {s}\n", .{abs});
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
        try ctx.err.print("holt: content already has {s}; refusing to overwrite\n", .{base});
        return 1;
    }

    var lock = try projectlock.acquire(alloc, p.content_path);
    defer lock.release();

    try fsutil.moveTree(alloc, abs, dest);
    const dest_stat = try std.Io.Dir.cwd().statFile(fsutil.io(), dest, .{});
    const result = try fsutil.replaceLink(dest, abs, dest_stat.kind == .directory);

    try ctx.out.print("kept {s} -> content\n", .{base});
    if (result == .skipped_unprivileged) {
        try ctx.err.print("holt: warning: {s} is in content but not surfaced at the hub root (needs Developer Mode for file links); run \"holt sync\" after enabling it\n", .{base});
    }
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

test "run: refuses a path that is not directly at the hub root" {
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

    // A file that lives outside the hub entirely, elsewhere under the tmp root.
    const outside_dir = try std.fs.path.join(arena, &.{ root, "elsewhere" });
    try fsutil.ensureDir(outside_dir);
    const outside = try std.fs.path.join(arena, &.{ outside_dir, "secret.txt" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = outside, .data = "do not move me\n" });

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    try std.process.setCurrentPath(fsutil.io(), hub);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const got = try testutil.runCmd(arena, command.run, ws, &.{outside});
    try testing.expectEqual(@as(u8, 1), got.code);

    // The outside file must still exist untouched at its original location,
    // and must not have been moved into content.
    try testing.expect(fsutil.exists(outside));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ content, "secret.txt" })));
}

test "run: refuses to keep a reserved name" {
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

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    try std.process.setCurrentPath(fsutil.io(), hub);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const got_code = try testutil.runCmd(arena, command.run, ws, &.{"code"});
    try testing.expectEqual(@as(u8, 1), got_code.code);
    try testing.expect(std.mem.indexOf(u8, got_code.err, "reserved") != null);
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ content, "code" })));

    const got_marker = try testutil.runCmd(arena, command.run, ws, &.{marker.marker_basename});
    try testing.expectEqual(@as(u8, 1), got_marker.code);
    try testing.expect(std.mem.indexOf(u8, got_marker.err, "reserved") != null);
}

test "run: errors clearly when the given path does not exist" {
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

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    try std.process.setCurrentPath(fsutil.io(), hub);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const got = try testutil.runCmd(arena, command.run, ws, &.{"does-not-exist.md"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "no such entry") != null);
}

test "run: keeps a loose directory, moving its contents and leaving a symlink" {
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

    // A loose local directory (with a file inside) at the hub root.
    const loose = try std.fs.path.join(arena, &.{ hub, "assets" });
    try fsutil.ensureDir(loose);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ loose, "logo.png" }), .data = "binary\n" });

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    try std.process.setCurrentPath(fsutil.io(), hub);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const got = try testutil.runCmd(arena, command.run, ws, &.{"assets"});
    try testing.expectEqual(@as(u8, 0), got.code);

    // The directory (and its contents) moved into content.
    const dest = try std.fs.path.join(arena, &.{ content, "assets" });
    try testing.expect(fsutil.exists(dest));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ dest, "logo.png" })));

    // Hub entry is now a symlink into content.
    switch (try fsutil.linkState(arena, loose)) {
        .symlink => |t| try testing.expectEqualStrings(dest, t),
        else => return error.TestUnexpectedResult,
    }
}
