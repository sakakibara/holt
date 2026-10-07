//! `holt sync [--dry-run]`: reconciles every project's hub with its marker
//! and reports what changed, then hints at any local repo that has grown a
//! remote and is ready for `holt repo promote`. Sync only detects promotable
//! repos - the destructive move itself is left to the explicit command.
//! Last, it reconciles the kept files of every clone in the code tree and
//! each of its working trees, keeps what the auto patterns name, and counts
//! the files not kept.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const git = @import("../git.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const ui = @import("../ui.zig");
const kept_hooks = @import("kept_hooks.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    dry_run: cli.Flag(.{ .help = "report what would change without touching the hub or any kept file" }),
};

pub const command = app.command(Spec, .{
    .name = "sync",
    .summary = "Reconcile every project's hub with its marker",
    .usage = "holt sync [--dry-run]",
    .group = .maintain,
    .needs_context = true,
    .details =
    \\Also links every clone's kept files, in each of its working trees, and
    \\keeps what the auto patterns name. Exits 1 while a hub conflict or a
    \\kept file that is not linked remains.
    \\
    \\A working tree whose directory is gone is named with the commands
    \\bringing it back from its record, and with git worktree remove only
    \\when a weighing of that record as the deleters weigh it finds nothing
    \\at risk; else with holt worktree <project>/<repo> <branch> -r for one
    \\holt worktree made, which weighs it again, and for any other with the
    \\lines naming what removing it destroys. One in a state holt does not
    \\change (a path more than one worktree record names, a .git that is
    \\gone, leads nowhere, or leads to another git directory than its
    \\record, a symlink to nothing, a path under something that is not a
    \\directory, a working tree moved with plain mv) is named with what git
    \\and holt see there and git -C <clone> worktree list, and a record
    \\that cannot be read or that git worktree add left half made, which
    \\that list leaves out, with what is seen there and the record's path;
    \\each with no command.
    \\
    \\Example:
    \\  holt sync --dry-run
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const dry_run = a.dry_run;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;
    const all = try ws.list(alloc);

    var changed: u32 = 0;
    var unhealthy = false;
    for (all) |p| {
        const report = try hub.reconcile(alloc, &ws, &p, dry_run);
        if (report.created == 0 and report.retargeted == 0 and report.removed == 0 and
            report.conflicts.len == 0 and report.skipped_unprivileged.len == 0 and
            report.unresolved_members.len == 0 and report.ignored_aliases.len == 0) continue;

        changed += 1;
        if (report.conflicts.len > 0 or report.unresolved_members.len > 0 or
            report.ignored_aliases.len > 0) unhealthy = true;
        const qualified = try p.qualified(alloc);
        try ctx.out.print("{s}: created {d}, retargeted {d}, removed {d}, conflicts {d}\n", .{
            qualified, report.created, report.retargeted, report.removed, report.conflicts.len,
        });
        for (report.conflicts) |c| try ctx.out.print("  conflict: {s}\n", .{try app.tilde(ctx, c)});
        for (report.unresolved_members) |repo_name| try ctx.out.print(
            "  unresolved member: {s} (marker url is not a usable repo url; no hub link)\n",
            .{repo_name},
        );
        for (report.ignored_aliases) |repo_name| try ctx.out.print(
            "  ignored alias: {s} (marker alias is not a valid hub link name; linked under its own name)\n",
            .{repo_name},
        );

        if (report.skipped_unprivileged.len > 0) {
            try ctx.out.print("  {d} content file(s) not surfaced at the hub root (needs Developer Mode for file links):\n", .{report.skipped_unprivileged.len});
            for (report.skipped_unprivileged) |rel| try ctx.out.print("    {s}\n", .{rel});
        }
    }

    changed += try pruneOrphanHubs(ctx, &ws, alloc, dry_run);

    if (changed == 0) try ctx.out.writeAll("all projects up to date\n");

    try printPromotable(ctx, &ws, alloc, all);

    if (try syncKept(ctx, dry_run)) unhealthy = true;

    // A conflict means a real file sits where a hub symlink must go; an
    // unresolved member means a marker entry names no reachable repo; an
    // ignored alias means the hub link a marker asked for was not a name holt
    // will build. Each leaves the hub other than the marker describes and only
    // the user can resolve it, so surface it in the exit code (like doctor)
    // rather than reporting success.
    return if (unhealthy) 1 else 0;
}

/// Reconciles the kept files of every clone in the code tree (plan mode
/// under `dry_run`, which also keeps nothing automatically), prints each
/// action and unsettled state, the candidates line, and a summary. True
/// when an unsettled state remains, `kept/` cannot be read, or it is under
/// the synced root holt's links point into instead of this one.
fn syncKept(ctx: *app.Ctx, dry_run: bool) !bool {
    const ws = ctx.context.?.ws;
    const clones = try ws.listClones(ctx.alloc);
    const st = try kept_hooks.storeState(ctx, clones);
    if (st != .ready) {
        try kept_hooks.printStore(ctx, ctx.out, st, clones);
        return st == .unreadable or st == .elsewhere;
    }
    const targets = try ctx.alloc.alloc(kept_hooks.Target, clones.len);
    for (clones, targets) |c, *t| t.* = .{ .path = c };
    const s = try kept_hooks.run(ctx, ctx.out, targets, .{
        .mode = if (dry_run) .plan else .apply,
        .candidates = if (dry_run) .plan else .auto,
    });
    try kept_hooks.printCandidates(ctx.out, s);
    if (try keptSummary(ctx.alloc, s, dry_run, s.counted_repos)) |line| try ctx.out.writeAll(line);
    return s.unsettled > 0;
}

/// The summary line of `s` over `repos` clones, naming only the counts that
/// are not zero; null when all are.
fn keptSummary(alloc: std.mem.Allocator, s: kept_hooks.Summary, dry_run: bool, repos: usize) !?[]const u8 {
    const Count = struct { n: usize, what: []const u8 };
    const counts: []const Count = if (dry_run)
        &.{ .{ .n = s.linked, .what = "to link" }, .{ .n = s.retargeted, .what = "to retarget" }, .{ .n = s.auto_kept, .what = "to keep automatically" }, .{ .n = s.unsettled, .what = "unsettled" } }
    else
        &.{ .{ .n = s.linked, .what = "linked" }, .{ .n = s.retargeted, .what = "retargeted" }, .{ .n = s.auto_kept, .what = "kept automatically" }, .{ .n = s.unsettled, .what = "unsettled" } };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    for (counts) |c| {
        if (c.n == 0) continue;
        try aw.writer.writeAll(if (aw.written().len == 0) (if (dry_run) "kept files (dry run): " else "kept files: ") else ", ");
        try aw.writer.print("{d} {s}", .{ c.n, c.what });
    }
    if (aw.written().len == 0) return null;
    try aw.writer.print(" in {d} {s}\n", .{ repos, if (repos == 1) "repo" else "repos" });
    return aw.written();
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
fn pruneOrphanHubs(ctx: *app.Ctx, ws: *const workspace.Workspace, alloc: std.mem.Allocator, dry_run: bool) !u32 {
    switch (try fsutil.linkState(alloc, ws.cfg.hub_root)) {
        .symlink => {
            try ctx.err.print("holt: hub_root {s} is a symlink; skipping orphan-hub pruning to avoid deleting content through it\n", .{try app.tilde(ctx, ws.cfg.hub_root)});
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
        // An I/O error probing the hub (e.g. permission-denied subdir) must
        // not abort the whole sync over one orphan - assume the worst
        // (real files present), warn, and leave it for the next run rather
        // than deleting on incomplete information or crashing outright.
        const has_files = hubHasRealFile(alloc, o.hub_path) catch |err| {
            try ctx.err.print("holt: could not check hub {s}/{s} for real files ({s}); leaving it in place, not pruning\n", .{ o.org, o.name, @errorName(err) });
            continue;
        };
        if (has_files) {
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
            .sym_link => {}, // never followed
            .unknown => {
                // Some filesystems (NFS/FUSE mounts) never populate dirent
                // d_type, so every entry - including real files - reports
                // as `.unknown`; resolve it with an lstat-then-stat pair
                // rather than guess, since guessing wrong here means a
                // real file silently escapes the guard.
                const child = try std.fs.path.join(alloc, &.{ path, entry.name });
                switch (try fsutil.linkState(alloc, child)) {
                    .symlink => {}, // never followed
                    .other, .missing => {
                        const st = std.Io.Dir.cwd().statFile(fsutil.io(), child, .{}) catch |err| switch (err) {
                            error.FileNotFound => continue, // raced away between iterate and stat
                            else => return err,
                        };
                        switch (st.kind) {
                            .directory => if (try hubHasRealFile(alloc, child)) return true,
                            else => return true,
                        }
                    },
                }
            },
            else => {}, // other special entries (device nodes, etc.) are ignored, never followed
        }
    }
    return false;
}

/// Hints at every distinct `local:<name>` repo whose clone has grown an
/// origin - a candidate for `holt repo promote`. A name shared by more than
/// one project is only ever hinted once, and a name `repo promote` would
/// refuse is never hinted at all.
fn printPromotable(ctx: *app.Ctx, ws: *const workspace.Workspace, alloc: std.mem.Allocator, all: []const project_mod.Project) !void {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (all) |p| {
        for (p.marker.entries) |*e| {
            const src = e.source orelse continue;
            const seg = switch (src) {
                .local => |s| s,
                .remote => continue,
            };
            const name = seg.bytes;
            if (seen.contains(name)) continue;
            try seen.put(alloc, name, {});

            const local_clone_path = try identity.local(seg).clonePath(alloc, ws.cfg.code_root);
            if (!fsutil.exists(local_clone_path)) continue;
            const origin = try git.remoteUrl(alloc, local_clone_path) orelse continue;
            const new_id = identity.fromUrl(alloc, origin) catch continue;
            const rel = try new_id.relPath(alloc);
            try ctx.out.print("promotable: {s} -> {s} (run: holt repo promote {s})\n", .{ name, rel, try ui.shellQuote(alloc, name) });
        }
    }
}

fn threeProjectSandbox(arena: std.mem.Allocator, root: []const u8) !workspace.Workspace {
    const ws = try testutil.testWorkspace(arena, root);

    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "holt", "https://github.com/sakakibara/holt");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", repos_a, .empty);

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "docs", "https://github.com/acme/docs");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "gadget", repos_b, .empty);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "zebra", "aardvark", .empty, .empty);

    // A real `holt project new` project always has these seeded on disk; the fixture
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

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);

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

test "run: a marker alias that is not a link name is named, and plants nothing outside the hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://github.com/acme/widget");
    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try aliases.put(arena, "widget", "../../../../planted");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, aliases);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/proj") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "ignored alias: widget") != null);

    // The member links under its own name, and the traversal target the alias
    // aimed at outside hub_root is never written.
    switch (try fsutil.linkState(arena, try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "widget" }))) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, try std.fs.path.join(arena, &.{ root, "planted" })));
}

test "run: a marker member with an unusable url is named, the rest of the workspace still syncs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // A marker synced from another machine can carry a `local:` value that
    // escapes the local bucket; it must cost that one member its hub link and
    // nothing else.
    var poisoned: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try poisoned.put(arena, "evil", "local:../../evil");
    try poisoned.put(arena, "holt", "https://github.com/sakakibara/holt");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", poisoned, .empty);

    var sound: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try sound.put(arena, "docs", "https://github.com/acme/docs");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "zebra", "gadget", sound, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/widget") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "unresolved member: evil") != null);

    // The poisoned project's sound member still links, and the untouched
    // project is reconciled rather than abandoned.
    switch (try fsutil.linkState(arena, try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "widget", "code", "holt" }))) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
    switch (try fsutil.linkState(arena, try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "zebra", "gadget", "code", "docs" }))) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ root, "evil" })));
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", repos, .empty);

    _ = try testutil.runCmd(arena, command.run, ws, &.{});

    const stale_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "widget", "code", "gone" });
    try fsutil.replaceSymlink("/nowhere", stale_link);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "removed 1") != null);
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, stale_link));
}

test "run: a promotable name a shell would reinterpret is hinted quoted" {
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
    try repos.put(arena, "pkg send", "local:pkg send");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("pkg send").?).clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(std.fs.path.dirname(local_clone_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, local_clone_path });
    try testutil.runGit(&sb, local_clone_path, &.{ "remote", "set-url", "origin", fake_origin });

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "run: holt repo promote 'pkg send'") != null);
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(std.fs.path.dirname(local_clone_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, local_clone_path });
    try testutil.runGit(&sb, local_clone_path, &.{ "remote", "set-url", "origin", fake_origin });

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "promotable: scratch -> holt-test.invalid/acme/scratch (run: holt repo promote scratch)") != null);

    try testing.expect(fsutil.exists(local_clone_path));
    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(new_clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:scratch", loaded.findRepo("scratch").?.raw_source.?.string);
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

test "run: an orphaned hub containing only symlinks is still pruned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // An orphan hub holding nothing but legitimate derived symlinks (a
    // mirror link plus a clone-symlink) - no regular file anywhere under
    // it - must still be pruned; `hubHasRealFile` skipping symlinks must
    // not be mistaken for "has real files".
    const orphan_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "gone" });
    try fsutil.ensureDir(orphan_hub);
    try fsutil.replaceSymlink("/nowhere", try std.fs.path.join(arena, &.{ orphan_hub, "docs" }));
    try fsutil.replaceSymlink("/nowhere-else", try std.fs.path.join(arena, &.{ orphan_hub, "code" }));

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "removed orphaned hub acme/gone") != null);
    try testing.expect(!fsutil.exists(orphan_hub));
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

test "run: warns about content files not surfaced for lack of privilege" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    const content_path = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try fsutil.writeFileAtomic(arena, try std.fs.path.join(arena, &.{ content_path, "notes.md" }), "hi");

    hub.force_skip_file_links_for_test = true;
    defer hub.force_skip_file_links_for_test = false;

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expect(std.mem.indexOf(u8, got.out, "not surfaced") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "notes.md") != null);
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(local_clone_path));

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "promotable:") == null);
}

const kept_test = @import("kept_hooks.zig");

/// A kept store and one clone at `github.com/acme/widget` with a linked
/// worktree, keeping `notes.txt` and `.superpowers/`; `.clasp.json` and
/// `secret.env` are ignored and not kept.
fn keptBed(arena: std.mem.Allocator, sb: *testutil.Sandbox) !struct { bed: kept_test.TestBed, clone: []const u8, wt: []const u8 } {
    var bed = try kept_test.TestBed.init(arena, sb, "");
    try bed.createStore();
    const c = try bed.clone("github.com/acme/widget");
    try testutil.runGit(sb, c, &.{ "branch", "feature" });
    const wt = try std.fs.path.join(arena, &.{ sb.root, "wt" });
    try testutil.runGit(sb, c, &.{ "worktree", "add", "-q", wt, "feature" });
    try bed.write(c, "notes.txt", "notes");
    try bed.write(c, ".superpowers/plan.md", "plan");
    try bed.keep(c, "notes.txt");
    try bed.keep(c, ".superpowers");
    const exclude = try std.fs.path.join(arena, &.{ c, ".git", "info", "exclude" });
    const now = try kept.content.readSmall(arena, exclude);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = exclude, .data = try std.mem.concat(arena, u8, &.{ "/.clasp.json\n/secret.env\n", now }) });
    try bed.write(c, ".clasp.json", "{\"scriptId\": \"abc\"}");
    try bed.write(c, "secret.env", "TOKEN=1");
    return .{ .bed = bed, .clone = c, .wt = try fsutil.realPathOrSelf(arena, wt) };
}

const kept = @import("../kept.zig");

fn hasText(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "run: a clone whose files not kept cannot be listed is named with why the patterns could not be matched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const head = try std.fs.path.join(arena, &.{ std.fs.path.dirname(k.bed.ws.cfg.synced_root).?, "state", "holt", "matcher", ".git", "HEAD" });
    try fsutil.ensureDir(std.fs.path.dirname(head).?);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = head, .data = "not a ref\n" });

    const got = try testutil.runCmd(arena, command.run, k.bed.ws, &.{});
    const all = try std.mem.concat(arena, u8, &.{ got.out, got.err });
    try testing.expect(hasText(all, "could not list files not kept in "));
    try testing.expect(hasText(all, ": MatcherFailed: git check-ignore exited "));
}

test "run: links kept files in every working tree, keeps what an auto pattern names, and counts the files not kept and only the repos it acted in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    try bed.remove(k.clone, "notes.txt");
    _ = try bed.clone("github.com/acme/other");

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    const key = "github.com/acme/widget";
    for ([_][]const u8{ k.clone, k.wt }) |tree| {
        try testing.expect(try bed.linked(tree, key, "notes.txt"));
        try testing.expect(try bed.linked(tree, key, ".superpowers"));
        try testing.expect(try bed.linked(tree, key, ".clasp.json"));
    }
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try bed.read(k.wt, ".clasp.json"));
    const out = got.out;
    try testing.expect(std.mem.indexOf(u8, out, try std.fmt.allocPrint(arena, "linked {s}\n", .{try bed.shown(try std.fs.path.join(arena, &.{ k.clone, "notes.txt" }))})) != null);
    try testing.expect(std.mem.indexOf(u8, out, try std.fmt.allocPrint(arena, "linked {s}\n", .{try bed.shown(try std.fs.path.join(arena, &.{ k.wt, ".superpowers" }))})) != null);
    try testing.expect(std.mem.indexOf(u8, out, try std.fmt.allocPrint(arena, "kept automatically: {s} (matches '.clasp.json')\n", .{try bed.shown(try std.fs.path.join(arena, &.{ k.clone, ".clasp.json" }))})) != null);
    try testing.expect(std.mem.indexOf(u8, out, "1 file not kept in 1 repo - run: holt keep --review --all\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "kept files: 4 linked, 1 kept automatically in 1 repo\n") != null);

    const again = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), again.code);
    try testing.expect(std.mem.indexOf(u8, again.out, "kept files") == null);
}

test "run: a file git reads only as a regular file that an auto pattern matches is named as not kept automatically, with why and a review hint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const exclude = try std.fs.path.join(arena, &.{ k.clone, ".git", "info", "exclude" });
    const now = try kept.content.readSmall(arena, exclude);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = exclude, .data = try std.mem.concat(arena, u8, &.{ "/sub/.gitignore\n", now }) });
    try bed.write(k.clone, "sub/.gitignore", "*.tmp\n");
    const layout: kept.store.Layout = .{ .synced_root = bed.ws.cfg.synced_root };
    try bed.write(try layout.keptDir(arena), ".holt-auto.d/1", ".gitignore\n");

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    const qp = try bed.shown(try std.fs.path.join(arena, &.{ k.clone, "sub", ".gitignore" }));
    try testing.expect(hasText(got.out, try std.fmt.allocPrint(arena, "not kept automatically: {s} (matches '.gitignore'): {s} - run: holt keep --review {s}\n", .{ qp, kept.paths.Invalid.git_reads_unlinked.describe(), try bed.shown(k.clone) })));
    try testing.expectEqual(kept.content.Entry.file, try kept.content.entryAt(try std.fs.path.join(arena, &.{ k.clone, "sub", ".gitignore" })));
}

test "run: a kept path whose local copy differs is not linked, and not also a file not kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const first = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), first.code);
    try bed.remove(k.clone, "notes.txt");
    try bed.write(k.clone, "notes.txt", "edited here");

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "not linked: {s}: local copy differs", .{try bed.shown(try std.fs.path.join(arena, &.{ k.clone, "notes.txt" }))})) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "1 file not kept in 1 repo - run: holt keep --review --all\n") != null);
}

test "run: --dry-run reports the kept actions and writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    try bed.remove(k.clone, "notes.txt");
    const git_dir = try std.fs.path.join(arena, &.{ k.clone, ".git" });
    const holt_state = try std.fs.path.join(arena, &.{ git_dir, "holt" });
    const exclude = try std.fs.path.join(arena, &.{ git_dir, "info", "exclude" });
    const before = .{
        try kept_test.snapshot(arena, k.clone, git_dir),
        try kept_test.snapshot(arena, k.wt, null),
        try kept_test.snapshot(arena, bed.ws.cfg.synced_root, null),
        try kept_test.snapshot(arena, holt_state, null),
        try kept.content.readSmall(arena, exclude),
    };

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{"--dry-run"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "would link {s}\n", .{try bed.shown(try std.fs.path.join(arena, &.{ k.clone, "notes.txt" }))})) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "kept files (dry run): 3 to link, 1 to keep automatically in 1 repo\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "would keep automatically: {s} (matches '.clasp.json')\n", .{try bed.shown(try std.fs.path.join(arena, &.{ k.clone, ".clasp.json" }))})) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "1 file not kept in 1 repo") != null);

    try testing.expectEqualStrings(before[0], try kept_test.snapshot(arena, k.clone, git_dir));
    try testing.expectEqualStrings(before[1], try kept_test.snapshot(arena, k.wt, null));
    try testing.expectEqualStrings(before[2], try kept_test.snapshot(arena, bed.ws.cfg.synced_root, null));
    try testing.expectEqualStrings(before[3], try kept_test.snapshot(arena, holt_state, null));
    try testing.expectEqualStrings(before[4], try kept.content.readSmall(arena, exclude));
}

test "run: --dry-run creates no machine id, lock, or matcher repository in holt's state directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    try bed.remove(k.clone, "notes.txt");
    const state = try kept.machine.stateDir(arena, app.envOf_current());
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), state);

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{"--dry-run"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "1 file not kept in 1 repo") != null);
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(state));
}

test "run: sync and doctor name the same commands for the same unsettled kept path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    try bed.remove(k.wt, "notes.txt");
    try bed.write(k.wt, "notes.txt", "edited by a tool that saves a new file");
    try bed.remove(k.clone, ".superpowers");
    try bed.write(k.clone, ".superpowers", "a file where the kept directory belongs");

    const synced = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    const doctored = try testutil.runCmd(arena, @import("doctor.zig").command.run, bed.ws, &.{});
    for ([_][]const u8{ try std.fs.path.join(arena, &.{ k.wt, "notes.txt" }), try std.fs.path.join(arena, &.{ k.clone, ".superpowers" }) }) |at| {
        const p = try bed.shown(at);
        const line_start = std.mem.indexOf(u8, synced.out, try std.fmt.allocPrint(arena, "not linked: {s}: local copy differs", .{p})) orelse return error.TestUnexpectedResult;
        const line = synced.out[line_start .. std.mem.indexOfScalarPos(u8, synced.out, line_start, '\n') orelse synced.out.len];
        const run_at = std.mem.indexOf(u8, line, " - run: ") orelse return error.TestUnexpectedResult;
        const cmds = line[run_at + " - run: ".len ..];
        try testing.expect(std.mem.indexOf(u8, doctored.out, try std.fmt.allocPrint(arena, "(run: {s})\n", .{cmds})) != null);
    }
}

test "run: a kept file that is not linked exits 1 and names the commands that settle it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    try bed.remove(k.wt, "notes.txt");
    try bed.write(k.wt, "notes.txt", "edited by a tool that saves a new file");

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    const p = try bed.shown(try std.fs.path.join(arena, &.{ k.wt, "notes.txt" }));
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "not linked: {s}: local copy differs from the kept copy; set aside in aside entry ", .{p})) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, " - run: holt keep --take-local {s}, or holt keep --take-kept {s}\n", .{ p, p })) != null);
    try testing.expectEqualStrings("edited by a tool that saves a new file", try bed.read(k.wt, "notes.txt"));
    try testing.expectEqualStrings("notes", try bed.read(k.clone, "notes.txt"));
}

test "run: without kept/, the first-use line is printed once while a clone holds a file not kept, and .holt-kept-off silences it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.TestBed.init(arena, &sb, "");
    defer bed.deinit();
    const widget = try bed.clone("github.com/acme/widget");
    const other = try bed.clone("github.com/acme/other");

    const none = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), none.code);
    try testing.expect(std.mem.indexOf(u8, none.out, "kept files") == null);

    for ([_][]const u8{ widget, other }) |c| {
        try bed.write(c, ".git/info/exclude", "/secret.txt\n");
        try bed.write(c, "secret.txt", "only here");
    }
    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, kept_test.not_set_up));

    try bed.write(bed.ws.cfg.synced_root, kept_test.off_basename, "");
    const off = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), off.code);
    try testing.expect(std.mem.indexOf(u8, off.out, "kept files") == null);
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ bed.ws.cfg.synced_root, "kept" })));
}

test "run: after a backend switch that left kept/ behind, the copy hint is printed instead of the first-use line, and sync fails" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const old_root = bed.ws.cfg.synced_root;
    var ws = bed.ws;
    ws.cfg.synced_root = try std.fs.path.join(arena, &.{ sb.root, "new-backend" });
    try fsutil.ensureDir(ws.cfg.synced_root);
    try bed.write(ws.cfg.synced_root, kept_test.off_basename, "");

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    const want = try std.fmt.allocPrint(arena, "kept/ is at {s}: copy it to {s}\n", .{ try bed.shown(old_root), try bed.shown(ws.cfg.synced_root) });
    try testing.expect(std.mem.indexOf(u8, got.out, want) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, kept_test.not_set_up) == null);
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "kept" })));
}

test "run: a kept path tracked in one working tree is never linked there, and holt's link at a path added to the index is removed with the command that restores it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const key = "github.com/acme/widget";
    try bed.write(k.wt, "notes.txt", "tracked on this branch");
    try testutil.runGit(&sb, k.wt, &.{ "add", "-f", "notes.txt" });
    try testutil.runGit(&sb, k.wt, &.{ "commit", "-q", "-m", "track notes" });
    try testutil.runGit(&sb, k.clone, &.{ "add", "-f", ".superpowers" });

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("tracked on this branch", try bed.read(k.wt, "notes.txt"));
    try testing.expect(!try bed.linked(k.wt, key, "notes.txt"));
    try testing.expect(try bed.linked(k.clone, key, "notes.txt"));
    try testing.expect(!try bed.linked(k.clone, key, ".superpowers"));
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "removed holt's link at {s}, which is tracked on this branch - run: git -C {s} restore -- .superpowers\n", .{ try bed.shown(try std.fs.path.join(arena, &.{ k.clone, ".superpowers" })), try bed.shown(k.clone) })) != null);
    const kept_plan = try (kept.store.Layout{ .synced_root = bed.ws.cfg.synced_root }).copyPath(arena, key, ".superpowers/plan.md");
    try testing.expectEqualStrings("plan", try kept.content.readSmall(arena, kept_plan));
}

test "run: a linked worktree moved without git's knowledge is reported unsettled with the commands bringing it back or removing its record alone, and nothing in it is lost" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    try bed.write(k.wt, "notes.txt", "only in the worktree");
    const moved = try std.fs.path.join(arena, &.{ sb.root, "wt-moved" });
    try std.Io.Dir.cwd().rename(k.wt, std.Io.Dir.cwd(), moved, fsutil.io());

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    if (ui.native_shell == .posix) try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "- run: mkdir -p {s} && ", .{try bed.shown(k.wt)})) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, ", or git -C {s} worktree remove {s}\n", .{ try bed.shown(k.clone), try bed.shown(k.wt) })) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "worktree repair") == null and std.mem.indexOf(u8, got.out, "worktree prune") == null);
    try testing.expectEqualStrings("only in the worktree", try bed.read(moved, "notes.txt"));
}

test "run: a linked worktree whose directory is gone and whose record holds staged changes is offered no git worktree remove, only the lines naming what removing it destroys, and bringing it back settles it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const proc = @import("../proc.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    try bed.write(k.wt, "staged.txt", "only in the index\n");
    try testutil.runGit(&sb, k.wt, &.{ "add", "staged.txt" });
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), k.wt);

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    const lead = "a working tree that cannot be read (absent)";
    const at = std.mem.indexOf(u8, got.out, lead) orelse {
        std.debug.print("wanted {s} in:\n{s}\n", .{ lead, got.out });
        return error.TestUnexpectedResult;
    };
    const line = got.out[at..std.mem.indexOfScalarPos(u8, got.out, at, '\n').?];
    try testing.expect(!hasText(got.out, " worktree remove ") and !hasText(got.out, "worktree prune"));
    try testing.expect(hasText(line, "removing the record destroys what it holds: "));
    try testing.expect(!hasText(got.out, "no record of the clone names it any longer"));
    try testing.expect(std.mem.endsWith(u8, line, try std.fmt.allocPrint(arena, "commit or stash them there (run: git -C {s} stash push)", .{try bed.shown(k.wt)})));
    const first = "its directory is gone; bring it back from its record first (run: ";
    const open = std.mem.indexOf(u8, line, first).? + first.len;
    const relink = line[open..std.mem.indexOfPos(u8, line, open, "); ").?];
    const res = try proc.runEnv(arena, &.{ "sh", "-c", relink }, null, &sb.git_env.map);
    try testing.expectEqual(@as(u8, 0), res.status);
    const after = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expect(!hasText(after.out, lead));
    try testing.expectEqualStrings("only in the index\n", try bed.read(k.wt, "staged.txt"));
}

test "run: a worktree moved with plain mv is named with what is seen there and git worktree list alone, and a half-made record with the record's path, each of which is there, and left as they were; a copy of a worktree is named with no command" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const records = try std.fs.path.join(arena, &.{ k.clone, ".git", "worktrees" });
    const wt_gitdir = try std.fs.path.join(arena, &.{ records, std.fs.path.basename(k.wt), "gitdir" });
    const wt_before = try kept.content.readSmall(arena, wt_gitdir);
    const moved = try std.fs.path.join(arena, &.{ sb.root, "wt-moved" });
    try std.Io.Dir.cwd().rename(k.wt, std.Io.Dir.cwd(), moved, fsutil.io());
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ records, "half" }));

    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = .{ .ws = bed.ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    try kept_hooks.hook(&ctx, &out.writer, k.clone, .{ .path = moved, .whole = false });
    const git_in = try std.fmt.allocPrint(arena, "git -C {s}", .{try bed.shown(k.clone)});
    const resolve = try std.fmt.allocPrint(arena, "; holt does not change it: resolve it with git ({s} worktree list), then run again\n", .{git_in});
    const note = try std.fmt.allocPrint(arena, "note: {s}: a working tree git records under {s}, which is gone, as after a move{s}", .{ try bed.shown(moved), try fsutil.contractTilde(arena, app.envOf_current(), k.wt), resolve });
    const half_record = try std.fs.path.join(arena, &.{ records, "half" });
    const half = try std.fmt.allocPrint(arena, "note: {s}: a half-made worktree record, which names no working tree and which git worktree list leaves out; holt does not change it: resolve it with git (the record is {s}), then run again\n", .{ try bed.shown(half_record), try bed.shown(half_record) });
    for ([_][]const u8{ note, half }) |want| if (std.mem.indexOf(u8, out.written(), want) == null) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ want, out.written() });
        return error.TestUnexpectedResult;
    };
    for ([_][]const u8{ "worktree repair", "worktree prune", "rm -rf", "/gitdir" }) |cmd| try testing.expect(std.mem.indexOf(u8, out.written(), cmd) == null);
    const res = try @import("../proc.zig").runEnv(arena, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "{s} worktree list && ls -d {s}", .{ git_in, try bed.shown(half_record) }) }, null, &sb.git_env.map);
    try testing.expectEqual(@as(u8, 0), res.status);
    try testing.expectEqual(kept.content.Entry.dir, try kept.content.entryAt(half_record));
    try testing.expectEqualStrings(wt_before, try kept.content.readSmall(arena, wt_gitdir));

    try std.Io.Dir.cwd().rename(moved, std.Io.Dir.cwd(), k.wt, fsutil.io());
    const copy = try std.fs.path.join(arena, &.{ sb.root, "copy" });
    const cp = try @import("../proc.zig").runEnv(arena, &.{ "cp", "-R", k.wt, copy }, null, null);
    try testing.expectEqual(@as(u8, 0), cp.status);
    out.clearRetainingCapacity();
    try kept_hooks.hook(&ctx, &out.writer, k.clone, .{ .path = copy, .whole = false });
    const copied = try std.fmt.allocPrint(arena, "note: {s}: a copy of the working tree at {s}, sharing its record, so git takes the two for one; remove the copy, or add a working tree of its own with git worktree add\n", .{ try bed.shown(copy), try fsutil.contractTilde(arena, app.envOf_current(), k.wt) });
    if (std.mem.indexOf(u8, out.written(), copied) == null) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ copied, out.written() });
        return error.TestUnexpectedResult;
    }
}

test "run: --dry-run never waits on a kept-file writer holding the clone's or the key's lock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    try bed.remove(k.clone, "notes.txt");
    const kc = try bed.kc();
    const c = try kept.clone.inspect(arena, k.clone, kc.code_root);
    const ctx_mod = @import("../kept/ctx.zig");
    ctx_mod.lock_nonblocking_for_test = true;
    defer ctx_mod.lock_nonblocking_for_test = false;
    const clone_lock = try kept.lockClone(kc, c.common_dir);
    defer clone_lock.release();
    const key_lock = try kept.lockKey(kc, c.key.?);
    defer key_lock.release();
    const locks = try std.fs.path.join(arena, &.{ try kept.machine.stateDir(arena, kc.env), "locks" });
    const before = try kept_test.snapshot(arena, locks, null);
    try testing.expect(before.len > 0);

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{"--dry-run"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings(before, try kept_test.snapshot(arena, locks, null));
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "would link {s}\n", .{try bed.shown(try std.fs.path.join(arena, &.{ k.clone, "notes.txt" }))})) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "WouldBlock") == null);
}

test "run: a temporary holt cannot settle names its aside entry and the commands that settle it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try keptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const c = try kept.clone.inspect(arena, k.clone, bed.ws.cfg.code_root);
    const temp = try kept.paths.tempRel(arena, "notes.txt");
    try bed.write(k.clone, temp, "left by a write no record names");
    try kept.block.add(arena, c.common_dir, &.{temp});
    try bed.remove(k.clone, "notes.txt");
    try bed.write(k.clone, "notes.txt", "committed");
    try testutil.runGit(&sb, k.clone, &.{ "add", "-f", "notes.txt" });

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    const tp = try bed.shown(try std.fs.path.join(arena, &.{ k.clone, temp }));
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "an interrupted write left {s}, which holt cannot settle; its content is in ", .{tp})) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "; take it as the kept copy, or remove it - run: holt keep --take-aside ") != null);
    const rm = if (ui.native_shell == .posix) "rm -rf " else "Remove-Item -Recurse -Force -LiteralPath ";
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, ", or {s}{s}\n", .{ rm, tp })) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "status") == null);
}
