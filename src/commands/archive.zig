//! `holt archive <project>`: moves a project's CONTENT dir out of
//! `projects/` into `archive/` (a pure-file move within the synced tree)
//! and drops its hub. The clone under code_root is never touched - `holt
//! restore <project>` reverses this exact move.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const identity = @import("../identity.zig");
const projectlock = @import("../projectlock.zig");
const recover = @import("../recover.zig");
const ui = @import("../ui.zig");
const workspace = @import("../workspace.zig");
const git = @import("../git.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    project: cli.spec.Pos([]const u8, .{ .complete = app.cat(.project), .help = "the project to archive" }),
    prune: cli.spec.Flag(.{ .help = "also reclaim member clones that are safe to re-fetch" }),
    yes: cli.spec.Flag(.{ .short = 'y', .help = "skip the prune confirmation prompt" }),
};

pub const command = app.command(Spec, .{
    .name = "archive",
    .summary = "Move a project's content out of projects/ into archive/ and drop its hub",
    .usage = "holt archive <project> [--prune] [--yes]",
    .group = .maintain,
    .needs_context = true,
    .details =
    \\With --prune, after archiving, each member clone that is clean, in sync
    \\with its remote, and no longer used by any active project is deleted to
    \\reclaim disk (it can be re-cloned from its remote by `holt restore`).
    \\A clone with local changes, unpushed commits, or no upstream is kept and
    \\reported, and a clone still shared with an active project is never
    \\touched.
    \\
    \\Example:
    \\  holt archive myproj
    \\  holt archive myproj --prune
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const project_query = a.project;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const p = (try common.resolveOne(ctx, project_query)) orelse return 1;

    // Serialize against concurrent per-project mutators (add/rm/...) so the
    // content move never races an in-flight marker edit on the same project.
    var lock = try projectlock.acquire(alloc, p.content_path);
    defer lock.release();

    // Snapshot the non-local member clones before the marker moves, so a
    // later --prune knows what this project referenced.
    var members: std.ArrayList(Member) = .empty;
    if (a.prune) {
        for (p.marker.repos.keys()) |repo_name| {
            const id = p.repoIdentity(alloc, repo_name) catch continue;
            if (id.isLocal()) continue;
            try members.append(alloc, .{ .repo = repo_name, .id = id, .clone_path = try id.clonePath(alloc, ws.cfg.code_root) });
        }
    }

    const archive_root = try ws.archiveRoot(alloc);
    const dest = try std.fs.path.join(alloc, &.{ archive_root, p.org, p.name });
    if (fsutil.exists(dest)) {
        try ctx.err.print("holt: {s}/{s} already exists in archive\n", .{ p.org, p.name });
        return 1;
    }

    common.moveDir(ctx, p.content_path, dest) catch return 1;
    hub.removeHub(&p) catch |err| {
        try common.reportHubFailure(ctx, p.org, p.name, err);
        return 1;
    };

    if (std.fs.path.dirname(p.content_path)) |old_org_dir| fsutil.rmdirIfEmpty(old_org_dir);

    try ctx.out.print("archived {s}/{s}\n", .{ p.org, p.name });

    if (a.prune) try pruneClones(ctx, &ws, members.items, a.yes);
    return 0;
}

const Member = struct { repo: []const u8, id: identity.Identity, clone_path: []const u8 };

/// After the project is archived, deletes each member clone that is safe to
/// reclaim - present on disk, referenced by no remaining active project, and
/// clean + in sync with its remote (so nothing is lost that isn't already
/// pushed). Everything else is kept and reported with the reason. Never fails
/// the command: the archive already succeeded.
fn pruneClones(ctx: *app.Ctx, ws: *const workspace.Workspace, members: []const Member, yes: bool) !void {
    const alloc = ctx.alloc;

    var eligible: std.ArrayList(Member) = .empty;
    for (members) |m| {
        if (!fsutil.exists(m.clone_path)) continue;
        if ((try ws.projectsUsing(alloc, m.id)).len > 0) {
            try ctx.out.print("kept {s}: still used by an active project\n", .{m.repo});
            continue;
        }
        // A linked worktree may hold uncommitted work that recover.check on the
        // main clone can't see; refuse rather than risk deleting it. If we
        // can't tell (>1 defaults on error), keep it - deletion is never worth
        // guessing wrong. worktreeCount includes the main tree, so >1 means
        // extra worktrees exist.
        if ((git.worktreeCount(alloc, m.clone_path) catch 2) > 1) {
            try ctx.out.print("kept {s}: has worktrees\n", .{m.repo});
            continue;
        }
        var verdict = recover.check(alloc, m.clone_path) catch {
            try ctx.out.print("kept {s}: could not verify it is safe to reclaim\n", .{m.repo});
            continue;
        };
        if (!verdict.safe()) {
            try ctx.out.print("kept {s}: has local changes or unpushed commits\n", .{m.repo});
            continue;
        }
        try eligible.append(alloc, m);
    }

    if (eligible.items.len == 0) return;

    if (!yes) {
        const msg = try std.fmt.allocPrint(alloc, "reclaim {d} clone(s) (delete the local checkout; re-clonable from its remote)?", .{eligible.items.len});
        if (!try ui.confirm(ctx.out, msg)) {
            try ctx.out.writeAll("prune cancelled (project stays archived)\n");
            return;
        }
    }

    for (eligible.items) |m| {
        // Hold the clone-path lock across the final reference re-check and the
        // delete. A concurrent add/new/adopt/promote that references this clone
        // holds the same lock while writing its marker, so if one slipped in
        // since the eligibility scan (or across the confirmation prompt) its
        // reference is on disk and visible here - and we keep the clone.
        var lock = try projectlock.acquire(alloc, m.clone_path);
        defer lock.release();
        if ((try ws.projectsUsing(alloc, m.id)).len > 0) {
            try ctx.out.print("kept {s}: now used by an active project\n", .{m.repo});
            continue;
        }
        std.Io.Dir.cwd().deleteTree(fsutil.io(), m.clone_path) catch |err| {
            try ctx.err.print("holt: could not reclaim {s}: {s}\n", .{ m.clone_path, @errorName(err) });
            continue;
        };
        if (std.fs.path.dirname(m.clone_path)) |owner_dir| {
            fsutil.rmdirIfEmpty(owner_dir);
            if (std.fs.path.dirname(owner_dir)) |host_dir| fsutil.rmdirIfEmpty(host_dir);
        }
        try ctx.out.print("reclaimed {s} ({s})\n", .{ m.repo, try fsutil.contractTilde(alloc, m.clone_path) });
    }
}

const restore_cmd = @import("restore.zig");

test "run: archive moves content into archive/, drops the hub, and restore round-trips it back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget", "docs" }));
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "archived acme/widget") != null);

    const projects_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(!fsutil.exists(projects_content));
    const archived_content = try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(archived_content));
    try testing.expect(!fsutil.exists(p.hub_path));

    const restore_got = try testutil.runCmd(arena, restore_cmd.command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), restore_got.code);

    try testing.expect(fsutil.exists(projects_content));
    try testing.expect(!fsutil.exists(archived_content));

    const docs_link = try std.fs.path.join(arena, &.{ p.hub_path, "docs" });
    switch (try fsutil.linkState(arena, docs_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: archiving the last project in an org prunes the emptied org's content and hub dirs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(!fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(!fsutil.exists(old_org_hub));
}

test "run: archiving one of two projects in an org leaves the org's content and hub dirs in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "gizmo", .{ .version = 1, .org = "acme", .name = "gizmo", .repos = .empty });
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);
    const gizmo_p = switch (try ws.find(arena, "acme/gizmo")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &gizmo_p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(fsutil.exists(old_org_hub));
    const remaining_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "gizmo" });
    try testing.expect(fsutil.exists(remaining_content));
}

test "run: refuses when the archive destination already exists, leaving content in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists") != null);

    const projects_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(projects_content));
}

fn writeProjectWithClone(sb: *testutil.Sandbox, arena: std.mem.Allocator, ws: workspace.Workspace, org: []const u8, name: []const u8, repo: []const u8, url: []const u8) ![]const u8 {
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, repo, url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), org, name, .{ .version = 1, .org = org, .name = name, .repos = repos });
    const bare = try testutil.makeBareRepo(sb, try std.fmt.allocPrint(arena, "{s}-{s}.git", .{ org, name }));
    defer testing.allocator.free(bare);
    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try git.clone(arena, bare, clone_path, null);
    return clone_path;
}

test "run: --prune reclaims a clean, synced, unreferenced member clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", "https://holt-test.invalid/acme/widget");
    try testing.expect(fsutil.exists(clone_path));

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "archived acme/proj") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "reclaimed widget") != null);
    try testing.expect(!fsutil.exists(clone_path));
}

test "run: --prune keeps a clone still referenced by another active project" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const url = "https://holt-test.invalid/acme/widget";
    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", url);
    // A second active project references the same clone.
    var repos2: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos2.put(arena, "widget", url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "other", .{ .version = 1, .org = "acme", .name = "other", .repos = repos2 });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "kept widget: still used by an active project") != null);
    try testing.expect(fsutil.exists(clone_path));
}

test "run: --prune keeps a clone with uncommitted local changes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", "https://holt-test.invalid/acme/widget");
    // Dirty the clone so it is no longer safe to reclaim.
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), clone_path, .{});
    defer d.close(fsutil.io());
    try d.writeFile(fsutil.io(), .{ .sub_path = "uncommitted.txt", .data = "work in progress\n" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "kept widget: has local changes or unpushed commits") != null);
    try testing.expect(fsutil.exists(clone_path));
}

test "run: --prune keeps a clone that has worktrees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", "https://holt-test.invalid/acme/widget");

    // An extra worktree (which may hold uncommitted work) must block reclaim.
    const wt = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "feature-x" });
    try fsutil.ensureDir(std.fs.path.dirname(wt).?);
    try testutil.runGit(&sb, clone_path, &.{ "branch", "feature-x" });
    try testutil.runGit(&sb, clone_path, &.{ "worktree", "add", wt, "feature-x" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "kept widget: has worktrees") != null);
    try testing.expect(fsutil.exists(clone_path));
}

test "run: no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"nope"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}
