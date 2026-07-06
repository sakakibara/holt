//! Derives a project's desired hub symlinks from its marker and reconciles
//! the on-disk hub (`<hub_root>/<org>/<name>/`) to match. The hub is the
//! unified browse view: `docs`/`assets`/`links` point into the synced
//! content dir, and `code/<name>` points into the real clone under
//! `code_root`.

const std = @import("std");
const workspace = @import("workspace.zig");
const project_mod = @import("project.zig");
const identity = @import("identity.zig");
const fsutil = @import("fsutil.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

const Workspace = workspace.Workspace;
const Project = project_mod.Project;

pub const Link = struct { rel: []u8, target: []u8 };

pub const ReconcileReport = struct {
    created: u32 = 0,
    retargeted: u32 = 0,
    removed: u32 = 0,
    conflicts: [][]u8 = &.{},
};

/// Replaces every "/" in `owner` with "-" (gitlab subgroup flattening).
/// Caller owns the returned memory.
fn flattenOwner(alloc: std.mem.Allocator, owner: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, owner);
    for (out) |*c| {
        if (c.* == '/') c.* = '-';
    }
    return out;
}

/// The `docs`/`assets`/`links` content links plus one `code/<name>` link per
/// marker repo. A member carrying a marker `aliases` entry links as
/// `code/<alias>`, overriding both the flat name and collision
/// owner-qualification. For the rest, a repo's short name (`identity.repo`)
/// shared by more than one non-aliased member forces every member of that
/// group to link owner-qualified (`code/<owner>-<repo>`, "/" flattened to
/// "-", local repos as `code/local-<name>`); non-colliding repos stay flat as
/// `code/<repo>`.
pub fn desiredLinks(alloc: std.mem.Allocator, ws: *const Workspace, p: *const Project) ![]Link {
    var links: std.ArrayList(Link) = .empty;

    const content_names = [_][]const u8{ "docs", "assets", "links" };
    for (content_names) |name| {
        try links.append(alloc, .{
            .rel = try alloc.dupe(u8, name),
            .target = try std.fs.path.join(alloc, &.{ p.content_path, name }),
        });
    }

    const repo_names = p.marker.repos.keys();
    const ids = try alloc.alloc(identity.Identity, repo_names.len);
    for (repo_names, 0..) |name, i| ids[i] = try p.repoIdentity(alloc, name);

    for (repo_names, ids) |name, id| {
        const code_name = if (p.marker.aliases.get(name)) |alias|
            try alloc.dupe(u8, alias)
        else blk: {
            // Owner-qualify only when another non-aliased member shares this
            // short name; aliased members no longer occupy their flat name.
            var collisions: u32 = 0;
            for (repo_names, ids) |other_name, other| {
                if (p.marker.aliases.contains(other_name)) continue;
                if (std.mem.eql(u8, other.repo, id.repo)) collisions += 1;
            }
            if (collisions > 1) {
                const owner_flat = if (id.isLocal()) try alloc.dupe(u8, "local") else try flattenOwner(alloc, id.owner);
                break :blk try std.fmt.allocPrint(alloc, "{s}-{s}", .{ owner_flat, id.repo });
            }
            break :blk try alloc.dupe(u8, id.repo);
        };

        const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
        try links.append(alloc, .{
            .rel = try std.fmt.allocPrint(alloc, "code/{s}", .{code_name}),
            .target = clone_path,
        });

        // A repo's git worktrees live in a sibling `<clone>@worktrees` dir, and
        // that whole dir is surfaced as one hub link - git owns the (possibly
        // slashy) branch tree inside it, so holt never names a branch. Linked
        // only when a real worktree is present, so an empty leftover dir (from
        // a raw `git worktree remove`) doesn't leave a link to nothing.
        const worktrees_dir = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{clone_path});
        if (try worktreesPresent(alloc, worktrees_dir)) {
            try links.append(alloc, .{
                .rel = try std.fmt.allocPrint(alloc, "code/{s}@worktrees", .{code_name}),
                .target = worktrees_dir,
            });
        }
    }

    return links.toOwnedSlice(alloc);
}

/// True iff `dir_path` holds at least one linked worktree (a subdir with a
/// `.git` entry), stopping at the first. False when the dir is absent or holds
/// only empty leftover branch dirs, so the hub never links a worktrees dir with
/// nothing in it.
fn worktreesPresent(alloc: std.mem.Allocator, dir_path: []const u8) !bool {
    var dir = std.Io.Dir.openDirAbsolute(fsutil.io(), dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(fsutil.io());
    var walker = try dir.walkSelectively(alloc);
    defer walker.deinit();
    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind != .directory) continue;
        const full = try std.fs.path.join(alloc, &.{ dir_path, entry.path });
        if (fsutil.exists(try std.fs.path.join(alloc, &.{ full, ".git" }))) return true;
        try walker.enter(fsutil.io(), entry);
    }
    return false;
}

fn isDesired(links: []const Link, rel: []const u8) bool {
    for (links) |l| {
        if (std.mem.eql(u8, l.rel, rel)) return true;
    }
    return false;
}

/// Removes stale entries under `dir_path` (whose desired rel-path carries
/// `prefix`, e.g. "" for the hub root or "code/" for the code subdir). Only
/// this one directory level is inspected - subdirectories of `code/` are
/// never descended into. A symlink not in `links` is stale and removed; a
/// real file or directory not in `links` is a conflict and is never touched.
fn sweepDir(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    prefix: []const u8,
    links: []const Link,
    dry_run: bool,
    report: *ReconcileReport,
    conflicts: *std.ArrayList([]u8),
) !void {
    var dir = std.Io.Dir.openDirAbsolute(fsutil.io(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(fsutil.io());

    var it = dir.iterate();
    while (try it.next(fsutil.io())) |entry| {
        // The ensureDir'd "code" container itself is expected at hub root
        // but is not part of the desired link set (only its members are);
        // its contents are swept separately via the code/ subdir pass.
        if (prefix.len == 0 and entry.kind == .directory and std.mem.eql(u8, entry.name, "code")) continue;

        const rel = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, entry.name });
        if (isDesired(links, rel)) continue;

        const full_path = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .sym_link => {
                report.removed += 1;
                if (!dry_run) try std.Io.Dir.cwd().deleteFile(fsutil.io(), full_path);
            },
            else => try conflicts.append(alloc, full_path),
        }
    }
}

/// Idempotently reconciles the on-disk hub to `desiredLinks(ws, p)`: creates
/// missing links, retargets links pointing at the wrong place, and sweeps
/// away stale symlinks no longer desired. Real files/dirs blocking a desired
/// link, or left behind by the sweep, are reported as conflicts and never
/// touched. `dry_run` computes the identical report without writing
/// anything to disk.
pub fn reconcile(alloc: std.mem.Allocator, ws: *const Workspace, p: *const Project, dry_run: bool) !ReconcileReport {
    var report: ReconcileReport = .{};
    var conflicts: std.ArrayList([]u8) = .empty;

    const links = try desiredLinks(alloc, ws, p);
    const code_dir_path = try std.fs.path.join(alloc, &.{ p.hub_path, "code" });

    if (!dry_run) {
        try fsutil.ensureDir(p.hub_path);
        try fsutil.ensureDir(code_dir_path);
    }

    for (links, 0..) |link, i| {
        // Two desired links sharing one rel-path (only reachable from a
        // hand-edited marker whose alias duplicates another member's name)
        // is a conflict, not a last-writer-wins retarget.
        var dup = false;
        for (links[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.rel, link.rel)) dup = true;
        }
        if (dup) {
            try conflicts.append(alloc, try std.fs.path.join(alloc, &.{ p.hub_path, link.rel }));
            continue;
        }

        const link_path = try std.fs.path.join(alloc, &.{ p.hub_path, link.rel });
        const state = try fsutil.linkState(alloc, link_path);
        switch (state) {
            .missing => {
                report.created += 1;
                if (!dry_run) try fsutil.replaceSymlink(link.target, link_path);
            },
            .symlink => |current_target| {
                if (!std.mem.eql(u8, current_target, link.target)) {
                    report.retargeted += 1;
                    if (!dry_run) try fsutil.replaceSymlink(link.target, link_path);
                }
            },
            .other => try conflicts.append(alloc, link_path),
        }
    }

    try sweepDir(alloc, p.hub_path, "", links, dry_run, &report, &conflicts);
    try sweepDir(alloc, code_dir_path, "code/", links, dry_run, &report, &conflicts);

    report.conflicts = try conflicts.toOwnedSlice(alloc);
    return report;
}

/// Removes every symlink under a project's hub (root and `code/`), then the
/// `code` dir and the hub dir itself if left empty, and finally the org hub
/// dir above it if that is now empty too. Used by archive/delete/rename,
/// none of which want the hub entry to exist at all once a project is gone
/// from its org. A hub that is already absent, or left non-empty by a real
/// file a sweep would have conflicted on, is not an error.
pub fn removeHub(p: *const Project) !void {
    var hub_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), p.hub_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };

    if (hub_dir.openDir(fsutil.io(), "code", .{ .iterate = true })) |code_dir_const| {
        var code_dir = code_dir_const;
        var it = code_dir.iterate();
        while (try it.next(fsutil.io())) |entry| {
            if (entry.kind == .sym_link) try code_dir.deleteFile(fsutil.io(), entry.name);
        }
        code_dir.close(fsutil.io());
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }
    hub_dir.deleteDir(fsutil.io(), "code") catch |err| switch (err) {
        error.FileNotFound, error.DirNotEmpty => {},
        else => return err,
    };

    var it = hub_dir.iterate();
    while (try it.next(fsutil.io())) |entry| {
        if (entry.kind == .sym_link) try hub_dir.deleteFile(fsutil.io(), entry.name);
    }
    hub_dir.close(fsutil.io());

    fsutil.rmdirIfEmpty(p.hub_path);
    if (std.fs.path.dirname(p.hub_path)) |org_hub_path| fsutil.rmdirIfEmpty(org_hub_path);
}

fn testProject(alloc: std.mem.Allocator, ws: *const Workspace, org: []const u8, name: []const u8, repos: std.StringArrayHashMapUnmanaged([]const u8)) !Project {
    const content_path = try std.fs.path.join(alloc, &.{ ws.cfg.synced_root, "projects", org, name });
    const hub_path = try std.fs.path.join(alloc, &.{ ws.cfg.hub_root, org, name });
    return .{
        .org = org,
        .name = name,
        .content_path = content_path,
        .hub_path = hub_path,
        .marker = .{ .version = 1, .org = org, .name = name, .repos = repos },
    };
}

fn tmpRoot(alloc: std.mem.Allocator, tmp: *testing.TmpDir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return alloc.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
}

fn oneRepo(alloc: std.mem.Allocator, name: []const u8, url: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(alloc, name, url);
    return repos;
}

/// True if `path` is a symlink, regardless of whether its target resolves -
/// `fsutil.exists` follows the link, which is wrong for test clone targets
/// that are never actually populated on disk.
fn symlinkExists(alloc: std.mem.Allocator, path: []const u8) !bool {
    return switch (try fsutil.linkState(alloc, path)) {
        .symlink => true,
        else => false,
    };
}

test "desiredLinks: content links plus one flat code link per repo, absolute targets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "acme", "proj", repos);

    const links = try desiredLinks(arena, &ws, &p);
    try testing.expectEqual(@as(usize, 4), links.len);

    try testing.expectEqualStrings("docs", links[0].rel);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ p.content_path, "docs" }), links[0].target);
    try testing.expectEqualStrings("assets", links[1].rel);
    try testing.expectEqualStrings("links", links[2].rel);

    try testing.expectEqualStrings("code/holt", links[3].rel);
    try testing.expectEqualStrings(
        try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "sakakibara", "holt" }),
        links[3].target,
    );
}

test "desiredLinks: colliding short names go owner-qualified, others stay flat" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "docs-a", "https://github.com/sakakibara/docs");
    try repos.put(arena, "docs-b", "https://github.com/acme/docs");
    try repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "org", "proj", repos);

    const links = try desiredLinks(arena, &ws, &p);

    var saw_sakakibara_docs = false;
    var saw_acme_docs = false;
    var saw_flat_holt = false;
    for (links) |l| {
        if (std.mem.eql(u8, l.rel, "code/sakakibara-docs")) saw_sakakibara_docs = true;
        if (std.mem.eql(u8, l.rel, "code/acme-docs")) saw_acme_docs = true;
        if (std.mem.eql(u8, l.rel, "code/holt")) saw_flat_holt = true;
        // The collision must never leak a bare "code/docs".
        try testing.expect(!std.mem.eql(u8, l.rel, "code/docs"));
    }
    try testing.expect(saw_sakakibara_docs);
    try testing.expect(saw_acme_docs);
    try testing.expect(saw_flat_holt);
}

test "desiredLinks: colliding local repo qualifies as local-<name>" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try repos.put(arena, "scratch2", "https://github.com/acme/scratch");
    const p = try testProject(arena, &ws, "org", "proj", repos);

    const links = try desiredLinks(arena, &ws, &p);

    var saw_local = false;
    for (links) |l| {
        if (std.mem.eql(u8, l.rel, "code/local-scratch")) saw_local = true;
    }
    try testing.expect(saw_local);
}

test "desiredLinks: an aliased repo links as code/<alias> at its real clone path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    var p = try testProject(arena, &ws, "acme", "proj", repos);
    try p.marker.aliases.put(arena, "holt", "gadget");

    const links = try desiredLinks(arena, &ws, &p);

    var saw_alias = false;
    for (links) |l| {
        if (std.mem.eql(u8, l.rel, "code/gadget")) {
            saw_alias = true;
            try testing.expectEqualStrings(
                try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "sakakibara", "holt" }),
                l.target,
            );
        }
        try testing.expect(!std.mem.eql(u8, l.rel, "code/holt"));
    }
    try testing.expect(saw_alias);
}

test "desiredLinks: aliasing one of two colliding members frees the other to stay flat" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "docs-a", "https://github.com/sakakibara/docs");
    try repos.put(arena, "docs-b", "https://github.com/acme/docs");
    var p = try testProject(arena, &ws, "org", "proj", repos);
    try p.marker.aliases.put(arena, "docs-a", "mydocs");

    const links = try desiredLinks(arena, &ws, &p);

    var saw_alias = false;
    var saw_flat_docs = false;
    for (links) |l| {
        if (std.mem.eql(u8, l.rel, "code/mydocs")) saw_alias = true;
        if (std.mem.eql(u8, l.rel, "code/docs")) saw_flat_docs = true;
    }
    try testing.expect(saw_alias);
    try testing.expect(saw_flat_docs);
}

test "reconcile: fresh build creates all links with correct targets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    const repos = try oneRepo(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "acme", "proj", repos);

    const report = try reconcile(arena, &ws, &p, false);
    try testing.expectEqual(@as(u32, 4), report.created);
    try testing.expectEqual(@as(u32, 0), report.retargeted);
    try testing.expectEqual(@as(u32, 0), report.removed);
    try testing.expectEqual(@as(usize, 0), report.conflicts.len);

    const docs_link = try std.fs.path.join(arena, &.{ p.hub_path, "docs" });
    const state = try fsutil.linkState(arena, docs_link);
    switch (state) {
        .symlink => |t| try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ p.content_path, "docs" }), t),
        else => return error.TestUnexpectedResult,
    }

    const code_link = try std.fs.path.join(arena, &.{ p.hub_path, "code", "holt" });
    const code_state = try fsutil.linkState(arena, code_link);
    switch (code_state) {
        .symlink => |t| try testing.expectEqualStrings(
            try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "sakakibara", "holt" }),
            t,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "reconcile: second run is idempotent (all zero)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    const repos = try oneRepo(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "acme", "proj", repos);

    _ = try reconcile(arena, &ws, &p, false);
    const report = try reconcile(arena, &ws, &p, false);

    try testing.expectEqual(@as(u32, 0), report.created);
    try testing.expectEqual(@as(u32, 0), report.retargeted);
    try testing.expectEqual(@as(u32, 0), report.removed);
    try testing.expectEqual(@as(usize, 0), report.conflicts.len);
}

test "reconcile: a marker URL change retargets the existing link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    const repos = try oneRepo(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "acme", "proj", repos);
    _ = try reconcile(arena, &ws, &p, false);

    const moved_repos = try oneRepo(arena, "holt", "https://github.com/newowner/holt");
    const p2 = try testProject(arena, &ws, "acme", "proj", moved_repos);
    const report = try reconcile(arena, &ws, &p2, false);

    try testing.expectEqual(@as(u32, 0), report.created);
    try testing.expectEqual(@as(u32, 1), report.retargeted);
    try testing.expectEqual(@as(u32, 0), report.removed);

    const code_link = try std.fs.path.join(arena, &.{ p.hub_path, "code", "holt" });
    const state = try fsutil.linkState(arena, code_link);
    switch (state) {
        .symlink => |t| try testing.expectEqualStrings(
            try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "newowner", "holt" }),
            t,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "reconcile: a stale extra symlink is swept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    const repos = try oneRepo(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "acme", "proj", repos);
    _ = try reconcile(arena, &ws, &p, false);

    const stale_link = try std.fs.path.join(arena, &.{ p.hub_path, "code", "gone" });
    try fsutil.replaceSymlink("/nowhere", stale_link);

    const report = try reconcile(arena, &ws, &p, false);
    try testing.expectEqual(@as(u32, 1), report.removed);
    try testing.expectEqual(@as(usize, 0), report.conflicts.len);
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, stale_link));
}

test "reconcile: a real file in code/ is a conflict and is preserved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    const repos = try oneRepo(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "acme", "proj", repos);
    _ = try reconcile(arena, &ws, &p, false);

    const stray_path = try std.fs.path.join(arena, &.{ p.hub_path, "code", "stray.txt" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = stray_path, .data = "keep me" });

    const report = try reconcile(arena, &ws, &p, false);
    try testing.expectEqual(@as(u32, 0), report.removed);
    try testing.expectEqual(@as(usize, 1), report.conflicts.len);
    try testing.expectEqualStrings(stray_path, report.conflicts[0]);
    try testing.expect(fsutil.exists(stray_path));
}

test "reconcile: dry_run computes the report without touching disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    const repos = try oneRepo(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "acme", "proj", repos);

    const report = try reconcile(arena, &ws, &p, true);
    try testing.expectEqual(@as(u32, 4), report.created);
    try testing.expectEqual(@as(u32, 0), report.retargeted);
    try testing.expectEqual(@as(u32, 0), report.removed);
    try testing.expectEqual(@as(usize, 0), report.conflicts.len);

    try testing.expect(!fsutil.exists(p.hub_path));
}

test "reconcile: collision case links both members owner-qualified, third stays flat" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "docs-a", "https://github.com/sakakibara/docs");
    try repos.put(arena, "docs-b", "https://github.com/acme/docs");
    try repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "org", "proj", repos);

    const report = try reconcile(arena, &ws, &p, false);
    try testing.expectEqual(@as(u32, 6), report.created);
    try testing.expectEqual(@as(usize, 0), report.conflicts.len);

    const flat_holt = try std.fs.path.join(arena, &.{ p.hub_path, "code", "holt" });
    try testing.expect(try symlinkExists(arena, flat_holt));
    const sakakibara_docs = try std.fs.path.join(arena, &.{ p.hub_path, "code", "sakakibara-docs" });
    try testing.expect(try symlinkExists(arena, sakakibara_docs));
    const acme_docs = try std.fs.path.join(arena, &.{ p.hub_path, "code", "acme-docs" });
    try testing.expect(try symlinkExists(arena, acme_docs));
    const bare_docs = try std.fs.path.join(arena, &.{ p.hub_path, "code", "docs" });
    try testing.expect(!try symlinkExists(arena, bare_docs));
}

test "removeHub: removes links and then-empty dirs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    const repos = try oneRepo(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "acme", "proj", repos);
    _ = try reconcile(arena, &ws, &p, false);

    try removeHub(&p);

    try testing.expect(!fsutil.exists(p.hub_path));
}

test "removeHub: a real file left behind keeps the hub dir but drops the links" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    const ws = try testutil.testWorkspace(arena, root);
    const repos = try oneRepo(arena, "holt", "https://github.com/sakakibara/holt");
    const p = try testProject(arena, &ws, "acme", "proj", repos);
    _ = try reconcile(arena, &ws, &p, false);

    const stray_path = try std.fs.path.join(arena, &.{ p.hub_path, "keep.txt" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = stray_path, .data = "keep me" });

    try removeHub(&p);

    try testing.expect(fsutil.exists(p.hub_path));
    try testing.expect(fsutil.exists(stray_path));
    const docs_link = try std.fs.path.join(arena, &.{ p.hub_path, "docs" });
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, docs_link));
}
