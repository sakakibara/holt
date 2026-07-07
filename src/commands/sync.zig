//! `holt sync [--dry-run]`: reconciles every project's hub with its marker
//! and reports what changed, then hints at any local repo that has grown a
//! remote and is ready for `holt promote`. Sync only detects promotable
//! repos - the destructive move itself is left to the explicit command.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const git = @import("../git.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    dry_run: args.Flag(.{ .help = "report what would change without touching the hub" }),
};

pub const command = args.command(Spec, .{
    .name = "sync",
    .about = "Reconcile every project's hub with its marker",
    .usage = "holt sync [--dry-run]",
    .group = .maintain,
    .details =
    \\Example:
    \\  holt sync --dry-run
    ,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const dry_run = a.dry_run;

    const ws = ctx.ws.?;
    const alloc = ctx.alloc;
    const all = try ws.list(alloc);

    var changed: u32 = 0;
    var had_conflict = false;
    for (all) |p| {
        const report = try hub.reconcile(alloc, &ws, &p, dry_run);
        if (report.created == 0 and report.retargeted == 0 and report.removed == 0 and report.conflicts.len == 0) continue;

        changed += 1;
        if (report.conflicts.len > 0) had_conflict = true;
        const qualified = try p.qualified(alloc);
        try ctx.out.print("{s}: created {d}, retargeted {d}, removed {d}, conflicts {d}\n", .{
            qualified, report.created, report.retargeted, report.removed, report.conflicts.len,
        });
        for (report.conflicts) |c| try ctx.out.print("  conflict: {s}\n", .{c});
    }

    changed += try pruneOrphanHubs(ctx, &ws, alloc, dry_run);

    if (changed == 0) try ctx.out.writeAll("all projects up to date\n");

    try printPromotable(ctx, &ws, alloc, all);

    // A conflict means a real file sits where a hub symlink must go - the hub
    // is left broken and only the user can resolve it, so surface it in the
    // exit code (like doctor) rather than reporting success.
    return if (had_conflict) 1 else 0;
}

/// Removes hub trees left behind by a project that was renamed, archived, or
/// deleted (or a move interrupted before its hub was torn down): a
/// `<hub>/<org>/<name>` whose project has neither a marker nor an eviction
/// placeholder. Only a hub that is purely derived symlinks is safe to
/// deleteTree without loss, so this guards both ways that assumption can be
/// false: a hub_root reached through a symlink (deleteTree would resolve
/// through it into live content, not just unlink the link) is skipped
/// entirely, and an individual orphan holding a real file (loose local
/// content dropped via `holt keep`, not yet synced) is left alone rather than
/// swept. Returns how many were actually pruned (or, under `dry_run`, would
/// be). Empty org dirs left behind by a pruned hub are swept too.
fn pruneOrphanHubs(ctx: *cli.Ctx, ws: *const workspace.Workspace, alloc: std.mem.Allocator, dry_run: bool) !u32 {
    switch (try fsutil.linkState(alloc, ws.cfg.hub_root)) {
        .symlink => {
            try ctx.err_w.print("holt: hub_root {s} is a symlink; skipping orphan-hub pruning to avoid deleting content through it\n", .{ws.cfg.hub_root});
            return 0;
        },
        else => {},
    }

    var hub_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), ws.cfg.hub_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        else => return err,
    };
    defer hub_dir.close(fsutil.io());

    const Orphan = struct { org: []const u8, name: []const u8, hub_path: []const u8 };
    var orphans: std.ArrayList(Orphan) = .empty;

    var org_it = hub_dir.iterate();
    while (try org_it.next(fsutil.io())) |org_entry| {
        if (org_entry.kind != .directory) continue;

        var org_dir = try hub_dir.openDir(fsutil.io(), org_entry.name, .{ .iterate = true });
        defer org_dir.close(fsutil.io());

        var name_it = org_dir.iterate();
        while (try name_it.next(fsutil.io())) |name_entry| {
            if (name_entry.kind != .directory) continue;
            const content_dir = try std.fs.path.join(alloc, &.{ ws.cfg.synced_root, "projects", org_entry.name, name_entry.name });
            const marker_path = try std.fs.path.join(alloc, &.{ content_dir, marker.marker_basename });
            if (fsutil.exists(marker_path) or marker.markerEvicted(alloc, content_dir)) continue;
            try orphans.append(alloc, .{
                .org = try alloc.dupe(u8, org_entry.name),
                .name = try alloc.dupe(u8, name_entry.name),
                .hub_path = try std.fs.path.join(alloc, &.{ ws.cfg.hub_root, org_entry.name, name_entry.name }),
            });
        }
    }

    var pruned: u32 = 0;
    for (orphans.items) |o| {
        if (try hubHasRealFile(alloc, o.hub_path)) {
            if (dry_run) {
                try ctx.out.print("would keep hub {s}/{s} (has local files)\n", .{ o.org, o.name });
            } else {
                try ctx.out.print("kept hub {s}/{s}: it has local files, not pruning (holt keep them, or remove manually)\n", .{ o.org, o.name });
            }
            continue;
        }

        if (dry_run) {
            try ctx.out.print("would remove orphaned hub {s}/{s}\n", .{ o.org, o.name });
            pruned += 1;
            continue;
        }
        try std.Io.Dir.cwd().deleteTree(fsutil.io(), o.hub_path);
        if (std.fs.path.dirname(o.hub_path)) |org_hub| fsutil.rmdirIfEmpty(org_hub);
        try ctx.out.print("removed orphaned hub {s}/{s}\n", .{ o.org, o.name });
        pruned += 1;
    }

    return pruned;
}

/// True if any regular file sits anywhere under `path`, recursing into
/// directories but never following a symlink - a legitimate prunable hub is
/// purely symlinks (mirror links plus `code`'s clone-symlinks) and empty
/// directories, so any real file found means the hub holds content that
/// deleteTree must not touch.
fn hubHasRealFile(alloc: std.mem.Allocator, path: []const u8) !bool {
    var dir = try std.Io.Dir.openDirAbsolute(fsutil.io(), path, .{ .iterate = true });
    defer dir.close(fsutil.io());

    var it = dir.iterate();
    while (try it.next(fsutil.io())) |entry| {
        switch (entry.kind) {
            .file => return true,
            .directory => {
                const child = try std.fs.path.join(alloc, &.{ path, entry.name });
                if (try hubHasRealFile(alloc, child)) return true;
            },
            else => {}, // symlinks (and any other special entry) are skipped, never followed
        }
    }
    return false;
}

/// Hints at every distinct `local:<name>` repo whose clone has grown an
/// origin - a candidate for `holt promote`. A name shared by more than one
/// project is only ever hinted once.
fn printPromotable(ctx: *cli.Ctx, ws: *const workspace.Workspace, alloc: std.mem.Allocator, all: []const project_mod.Project) !void {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (all) |p| {
        for (p.marker.repos.keys()) |repo_name| {
            const url = p.marker.repos.get(repo_name).?;
            if (!std.mem.startsWith(u8, url, "local:")) continue;

            const name = url["local:".len..];
            if (seen.contains(name)) continue;
            try seen.put(alloc, name, {});

            const local_clone_path = try identity.local(name).clonePath(alloc, ws.cfg.code_root);
            if (!fsutil.exists(local_clone_path)) continue;
            const origin = try git.remoteUrl(alloc, local_clone_path) orelse continue;
            const new_id = identity.fromUrl(alloc, origin) catch continue;
            const rel = try new_id.relPath(alloc);
            try ctx.out.print("promotable: {s} -> {s} (run: holt promote {s})\n", .{ name, rel, name });
        }
    }
}

fn threeProjectSandbox(arena: std.mem.Allocator, root: []const u8) !workspace.Workspace {
    const ws = try testutil.testWorkspace(arena, root);

    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "holt", "https://github.com/sakakibara/holt");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = repos_a });

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "docs", "https://github.com/acme/docs");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "gadget", .{ .version = 1, .org = "acme", .name = "gadget", .repos = repos_b });

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "zebra", "aardvark", .{ .version = 1, .org = "zebra", .name = "aardvark", .repos = .empty });

    // A real `holt new` project always has these seeded on disk; the fixture
    // mirrors that so a project with no repos still yields desired links.
    const proot = try ws.projectsRoot(arena);
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ proot, "zebra", "aardvark", "docs" }));

    return ws;
}

test "run: fresh build reports changes for every project, second run is all zero" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try threeProjectSandbox(arena, root);

    const first = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), first.code);
    try testing.expect(std.mem.indexOf(u8, first.out, "acme/widget") != null);
    try testing.expect(std.mem.indexOf(u8, first.out, "acme/gadget") != null);
    try testing.expect(std.mem.indexOf(u8, first.out, "zebra/aardvark") != null);

    const second = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), second.code);
    try testing.expectEqualStrings("all projects up to date\n", second.out);
}

test "run: a hub conflict is reported and exits nonzero" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    // A real "docs" content entry makes `docs` a desired hub link. A real
    // directory already sitting at that hub path blocks reconcile from
    // creating or retargeting it, so it is an unresolvable conflict - unlike
    // a loose file with no matching desired link, which the hub-root sweep
    // now leaves alone for `holt status` to surface instead.
    const content_path = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ content_path, "docs" }));
    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "widget" });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ hub_path, "docs" }));

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "conflict:") != null);
}

test "run: --dry-run reports the same changes without writing anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try threeProjectSandbox(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--dry-run"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/widget") != null);

    try testing.expect(!fsutil.exists(ws.cfg.hub_root));
}

test "run: a stale hub link left by a marker change is swept on the next sync" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = repos });

    _ = try testutil.runCmd(arena, command.run, ws, &.{});

    const stale_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "widget", "code", "gone" });
    try fsutil.replaceSymlink("/nowhere", stale_link);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "removed 1") != null);
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, stale_link));
}

test "run: hints a local repo that has grown an origin, without moving anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(std.fs.path.dirname(local_clone_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, local_clone_path });
    try testutil.runGit(&sb, local_clone_path, &.{ "remote", "set-url", "origin", fake_origin });

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "promotable: scratch -> holt-test.invalid/acme/scratch (run: holt promote scratch)") != null);

    try testing.expect(fsutil.exists(local_clone_path));
    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(new_clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:scratch", loaded.repos.get("scratch").?);
}

test "run: an orphaned hub with no project is pruned; --dry-run only reports it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // A hub tree for a project that no longer has a marker - what an
    // interrupted rename/archive/delete leaves behind.
    const orphan_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "gone" });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ orphan_hub, "code" }));

    const dry = try testutil.runCmd(arena, command.run, ws, &.{"--dry-run"});
    try testing.expectEqual(@as(u8, 0), dry.code);
    try testing.expect(std.mem.indexOf(u8, dry.out, "would remove orphaned hub acme/gone") != null);
    try testing.expect(fsutil.exists(orphan_hub));

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "removed orphaned hub acme/gone") != null);
    try testing.expect(!fsutil.exists(orphan_hub));
    // The now-empty org dir is swept too.
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" })));
}

test "run: an orphaned hub holding a real local file is kept, not deleted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // An orphan hub that also holds a loose local file dropped via `holt
    // keep`, alongside a derived symlink - the file must survive pruning
    // even though the hub itself has no project marker.
    const orphan_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "gone" });
    try fsutil.ensureDir(orphan_hub);
    const notes_path = try std.fs.path.join(arena, &.{ orphan_hub, "notes.md" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = notes_path, .data = "keep me\n" });
    try fsutil.replaceSymlink("/nowhere", try std.fs.path.join(arena, &.{ orphan_hub, "code" }));

    const dry = try testutil.runCmd(arena, command.run, ws, &.{"--dry-run"});
    try testing.expectEqual(@as(u8, 0), dry.code);
    try testing.expect(std.mem.indexOf(u8, dry.out, "would keep hub acme/gone (has local files)") != null);
    try testing.expect(fsutil.exists(notes_path));

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "kept hub acme/gone") != null);
    try testing.expect(fsutil.exists(orphan_hub));
    try testing.expect(fsutil.exists(notes_path));
}

test "run: a symlinked hub_root is never pruned through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // Simulates the old hive layout where hub_root itself is a symlink into
    // live synced content (e.g. ~/Projects -> synced/projects). An orphan
    // hub with a real file sits behind it; deleteTree must never resolve
    // through the symlink to reach it.
    const real_target = try std.fs.path.join(arena, &.{ root, "real-hub" });
    const orphan_hub = try std.fs.path.join(arena, &.{ real_target, "acme", "gone" });
    try fsutil.ensureDir(orphan_hub);
    const notes_path = try std.fs.path.join(arena, &.{ orphan_hub, "notes.md" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = notes_path, .data = "keep me\n" });
    try fsutil.replaceSymlink(real_target, ws.cfg.hub_root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "hub_root") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "is a symlink") != null);
    try testing.expect(fsutil.exists(notes_path));
    try testing.expect(fsutil.exists(orphan_hub));
}

test "run: a hub whose project marker is merely evicted is not pruned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "evicted" });
    try fsutil.ensureDir(hub_path);
    // The project exists but its marker is evicted (placeholder only).
    const content_dir = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "evicted" });
    try fsutil.ensureDir(content_dir);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ content_dir, marker.evicted_marker_basename }), .data = "" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "removed orphaned hub") == null);
    try testing.expect(fsutil.exists(hub_path));
}

test "run: a local: marker whose clone dir is absent is skipped, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const local_clone_path = try identity.local("scratch").clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(local_clone_path));

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "promotable:") == null);
}
