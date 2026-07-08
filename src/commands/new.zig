//! `holt new <org>/<name> [url]`: creates a project's CONTENT dirs and
//! marker, optionally cloning a repo and recording it as the project's
//! first member, then builds the hub.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const project_mod = @import("../project.zig");
const common = @import("common.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const git = @import("../git.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const projectlock = @import("../projectlock.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    org_name: args.Pos([]const u8, .{ .complete = comp.cat(.org), .help = "the org/name to create" }),
    url: args.Pos(?[]const u8, .{ .complete = .files, .help = "a repo url to clone as the project's first member" }),
};

pub const command = args.command(Spec, .{
    .name = "new",
    .about = "Create a new project, optionally cloning its first repo",
    .usage = "holt new <org>/<name> [url]",
    .group = .create,
    .details =
    \\Example:
    \\  holt new acme/widget https://github.com/acme/widget.git
    ,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const spec = a.org_name;
    const url = a.url;

    const on = common.parseOrgName(spec) orelse {
        ctx.args.message = try common.parseOrgNameMessage(ctx.alloc, spec);
        return error.UsageError;
    };

    const ws = ctx.ws.?;
    const alloc = ctx.alloc;

    const content_path = try std.fs.path.join(alloc, &.{ ws.cfg.synced_root, "projects", on.org, on.name });
    const marker_path = try std.fs.path.join(alloc, &.{ content_path, marker.marker_basename });
    if (fsutil.exists(marker_path)) {
        try ctx.err_w.print("holt: project \"{s}/{s}\" already exists\n", .{ on.org, on.name });
        return 1;
    }

    const archive_root = try ws.archiveRoot(alloc);
    const archive_marker = try std.fs.path.join(alloc, &.{ archive_root, on.org, on.name, marker.marker_basename });
    if (fsutil.exists(archive_marker)) {
        try ctx.err_w.print("holt: {s}/{s} already exists in archive (restore or delete it first)\n", .{ on.org, on.name });
        return 1;
    }

    const id: ?identity.Identity = if (url) |u| identity.fromUrl(alloc, u) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err_w.print("holt: \"{s}\" is not a recognized git url\n", .{u});
            return 1;
        },
        else => return err,
    } else null;

    // Clone (into code_root, outside the synced tree) happens before any
    // content dir is created, so a clone failure leaves nothing under
    // synced/projects behind - there is no partial project to clean up.
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var cloned = false;
    var clone_path: ?[]const u8 = null;
    // Held from the clone until the marker (the reference) is on disk, so a
    // concurrent `archive --prune` cannot delete the clone in between.
    var clone_lock: ?projectlock.Handle = null;
    defer if (clone_lock) |l| l.release();
    if (id) |i| {
        const u = url.?;
        const cp = try i.clonePath(alloc, ws.cfg.code_root);
        clone_lock = try projectlock.acquire(alloc, cp);
        cloned = common.cloneIfAbsent(ctx, u, cp) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return 1,
        };
        try repos.put(alloc, i.repo, u);
        clone_path = cp;
    }

    for ([_][]const u8{ "docs", "assets", "links" }) |sub| {
        try fsutil.ensureDir(try std.fs.path.join(alloc, &.{ content_path, sub }));
    }

    var m: marker.Marker = .{ .version = marker.marker_version, .org = on.org, .name = on.name, .repos = repos };
    try marker.save(&m, marker_path);

    const hub_path = try std.fs.path.join(alloc, &.{ ws.cfg.hub_root, on.org, on.name });
    const p: project_mod.Project = .{
        .org = on.org,
        .name = on.name,
        .content_path = content_path,
        .hub_path = hub_path,
        .marker = m,
    };
    _ = try hub.reconcile(alloc, &ws, &p, false);

    try ctx.out.print("created {s}/{s}\n", .{ on.org, on.name });
    if (clone_path) |cp| {
        if (cloned) {
            try ctx.out.print("cloned {s} -> {s}\n", .{ url.?, cp });
        } else {
            try ctx.out.print("using existing clone at {s}\n", .{cp});
        }
    }
    return 0;
}

test "run: new with a url clones a real testutil bare and builds the marker + 4 hub links" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/widget";

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", url });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget", marker.marker_basename });
    try testing.expect(fsutil.exists(marker_path));

    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 1), loaded.repos.count());
    try testing.expectEqualStrings(url, loaded.repos.get("widget").?);

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    const branch = try git.currentBranch(arena, clone_path);
    try testing.expect(branch != null);
    try testing.expectEqualStrings("main", branch.?);

    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "widget" });
    for ([_][]const u8{ "docs", "assets", "links" }) |name| {
        const link = try std.fs.path.join(arena, &.{ hub_path, name });
        switch (try fsutil.linkState(arena, link)) {
            .symlink => {},
            else => return error.TestUnexpectedResult,
        }
    }
    const code_link = try std.fs.path.join(arena, &.{ hub_path, "code", "widget" });
    switch (try fsutil.linkState(arena, code_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: new without a url writes an empty-repos marker and no clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/scratch"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "scratch", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.repos.count());

    for ([_][]const u8{ "docs", "assets", "links" }) |sub| {
        const dir_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "scratch", sub });
        try testing.expect(fsutil.exists(dir_path));
    }
}

test "run: an already-existing project is a hard error, not overwritten" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const first = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), first.code);

    const second = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 1), second.code);
    try testing.expect(std.mem.indexOf(u8, second.err, "already exists") != null);
}

test "run: a project already in the archive is refused and nothing is created" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists in archive") != null);

    const marker_path = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget", marker.marker_basename });
    try testing.expect(!fsutil.exists(marker_path));
}

test "run: a malformed spec (no slash) is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_args = try cli.Args.init(arena, &.{"widget"});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.UsageError, command.run(&ctx));
    try testing.expect(std.mem.indexOf(u8, cli_args.message, "widget") != null);
}

test "run: an org that traverses out of the roots is rejected and nothing is written outside them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testing.expectError(error.UsageError, testutil.runCmd(arena, command.run, ws, &.{"../escape"}));

    const projects_root = try ws.projectsRoot(arena);
    const content_escape = try std.fs.path.join(arena, &.{ projects_root, "..", "escape" });
    try testing.expect(!fsutil.exists(content_escape));
    const hub_escape = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "..", "escape" });
    try testing.expect(!fsutil.exists(hub_escape));
}

test "run: a control-char name is rejected before anything is created" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testing.expectError(error.UsageError, testutil.runCmd(arena, command.run, ws, &.{"acme/wi\x01dget"}));

    const org_dir = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(!fsutil.exists(org_dir));
}

test "run: an unrecognized url is reported and nothing is created" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", "not-a-url" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not-a-url") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget", marker.marker_basename });
    try testing.expect(!fsutil.exists(marker_path));
}

test "run: a parseable but unreachable url fails the clone and leaves no content dir behind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // Loopback with nothing listening: connection refused immediately, no
    // DNS or network dependency, so the failure is fast and deterministic.
    const url = "git://127.0.0.1:1/acme/widget";
    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/widget", url });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "failed to clone") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, url) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "GitCloneFailed") == null);

    const content_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget" });
    try testing.expect(!fsutil.exists(content_path));

    const id = try identity.fromUrl(arena, url);
    const owner_dir = try std.fs.path.join(arena, &.{ ws.cfg.code_root, id.host, id.owner });
    try testing.expect(!fsutil.exists(owner_dir));
}
