//! Enforces the workspace invariants and reports drift:
//!   D1 - no symlink anywhere under the synced projects/archive trees
//!        (or the whole synced root with `full`).
//!   D2 - `code_root` is not inside `synced_root`, and no clone (`.git` dir)
//!        lives under `<synced>/projects`.
//!   D3 - `hub_root` is not inside `synced_root`.
//! plus: markers that fail to parse, member URLs that don't resolve to an
//! identity, missing clones, hub drift (a reconcile dry-run reports
//! changes), and hub entries whose project has no marker (orphans).
//! Report-only besides: hub symlinks pointing at a target that no longer
//! exists (dangling), an `<org>/<name>` present in both projects and archive
//! (shadow), a markerless directory under an org (orphaned content), and a
//! marker alias keyed to a repo that is not a member (stale alias).
//!
//! `fix` applies only the hub-drift repair (`hub.reconcile` for real): it
//! never touches CONTENT, never deletes a clone, never removes a D1 symlink
//! offender, and never repairs any of the report-only checks above - those
//! may be user data or need user judgment.

const std = @import("std");
const workspace = @import("workspace.zig");
const project_mod = @import("project.zig");
const marker = @import("marker.zig");
const hub = @import("hub.zig");
const git = @import("git.zig");
const fsutil = @import("fsutil.zig");
const parallel = @import("parallel.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

const Workspace = workspace.Workspace;
const Project = project_mod.Project;

pub const MarkerFailure = workspace.Workspace.MarkerFailure;
pub const EvictedMarker = workspace.Workspace.EvictedMarker;
pub const BadIdentity = struct { project: []const u8, repo: []const u8 };
pub const MissingClone = struct { project: []const u8, repo: []const u8, path: []const u8 };
pub const BrokenClone = struct { project: []const u8, repo: []const u8, path: []const u8 };
pub const Orphan = struct { org: []const u8, name: []const u8 };
pub const DanglingLink = struct { project: []const u8, link_path: []const u8, target: []const u8, is_local: bool };
pub const Shadow = struct { org: []const u8, name: []const u8 };
pub const OrphanedContent = struct { path: []const u8 };
pub const StaleAlias = struct { project: []const u8, alias: []const u8 };
pub const ConflictCopy = struct { path: []const u8 };
/// A `*.holt-tmp` clone-staging dir under code_root, left by a clone that was
/// hard-killed before its atomic rename. `removed` is set when `--fix` deleted
/// it.
pub const CloneTemp = struct { path: []const u8, removed: bool };

pub const DriftEntry = struct {
    project: []const u8,
    report: hub.ReconcileReport,
    /// Only ever true when `Options.fix` was set and the drift was the
    /// safe-to-repair kind (create/retarget/sweep); a conflict is never
    /// fixed, since reconcile never touches a real file/dir in its way.
    fixed: bool,

    pub fn hasDrift(self: DriftEntry) bool {
        const r = self.report;
        return r.created > 0 or r.retargeted > 0 or r.removed > 0 or r.conflicts.len > 0;
    }

    pub fn unresolved(self: DriftEntry) bool {
        return self.hasDrift() and !self.fixed;
    }
};

pub const Report = struct {
    d1_offenders: [][]u8 = &.{},
    d2_ok: bool = true,
    d3_ok: bool = true,
    marker_failures: []MarkerFailure = &.{},
    evicted_markers: []EvictedMarker = &.{},
    bad_identities: []BadIdentity = &.{},
    missing_clones: []MissingClone = &.{},
    broken_clones: []BrokenClone = &.{},
    drift: []DriftEntry = &.{},
    orphans: []Orphan = &.{},
    dangling_links: []DanglingLink = &.{},
    shadows: []Shadow = &.{},
    orphaned_content: []OrphanedContent = &.{},
    stale_aliases: []StaleAlias = &.{},
    conflict_copies: []ConflictCopy = &.{},
    clone_temps: []CloneTemp = &.{},

    pub fn ok(self: Report) bool {
        if (self.d1_offenders.len != 0) return false;
        if (!self.d2_ok or !self.d3_ok) return false;
        if (self.marker_failures.len != 0) return false;
        if (self.evicted_markers.len != 0) return false;
        if (self.bad_identities.len != 0) return false;
        if (self.missing_clones.len != 0) return false;
        if (self.broken_clones.len != 0) return false;
        if (self.orphans.len != 0) return false;
        if (self.dangling_links.len != 0) return false;
        if (self.shadows.len != 0) return false;
        if (self.orphaned_content.len != 0) return false;
        if (self.stale_aliases.len != 0) return false;
        if (self.conflict_copies.len != 0) return false;
        for (self.clone_temps) |t| if (!t.removed) return false;
        for (self.drift) |d| if (d.unresolved()) return false;
        return true;
    }
};

pub const Options = struct {
    full: bool = false,
    fix: bool = false,
    /// Concurrency for the per-clone integrity scan; null = auto, 1 = serial.
    jobs: ?usize = null,
};

/// One present member clone whose integrity is checked concurrently.
const CloneCheck = struct {
    project: []const u8,
    repo: []const u8,
    path: []const u8,
};

/// Worker body: allocates only from `arena`, reads only its path. `git`'s
/// helpers are safe to call concurrently (see parallel.zig).
fn checkComplete(_: void, arena: std.mem.Allocator, path: []const u8) anyerror!bool {
    return git.isCompleteClone(arena, path);
}

/// Every project dir under `<synced>/projects/<org>/<name>` with a marker
/// present, split into markers that loaded and ones that didn't (path +
/// diagnostic message). A project dir with no marker file at all is not
/// this workspace's concern yet - it isn't a project.
const ProjectScan = struct {
    ok: []Project,
    failures: []MarkerFailure,
    evicted: []EvictedMarker,
};

fn scanMarkers(alloc: std.mem.Allocator, ws: *const Workspace) !ProjectScan {
    const entries = try ws.scanProjects(alloc);

    var oks: std.ArrayList(Project) = .empty;
    var fails: std.ArrayList(MarkerFailure) = .empty;
    var evicted: std.ArrayList(EvictedMarker) = .empty;
    for (entries) |entry| switch (entry) {
        .ok => |p| try oks.append(alloc, p),
        .failed => |f| try fails.append(alloc, f),
        .evicted => |e| try evicted.append(alloc, e),
    };

    return .{ .ok = try oks.toOwnedSlice(alloc), .failures = try fails.toOwnedSlice(alloc), .evicted = try evicted.toOwnedSlice(alloc) };
}

/// Recursively lists every symlink under `root_path` into `offenders`,
/// without ever following one: `walker.enter` is only called for an entry
/// whose own directory-entry kind is `.directory`, so a symlink (even one
/// pointing at a directory) is reported but never descended into - a
/// symlink to a huge tree is never walked.
fn scanNoFollow(alloc: std.mem.Allocator, root_path: []const u8, offenders: *std.ArrayList([]u8)) !void {
    var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer root_dir.close(fsutil.io());

    var walker = try root_dir.walkSelectively(alloc);
    defer walker.deinit();

    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind == .sym_link) {
            try offenders.append(alloc, try std.fs.path.join(alloc, &.{ root_path, entry.path }));
            continue;
        }
        if (entry.kind == .directory) try walker.enter(fsutil.io(), entry);
    }
}

/// D1: no symlink under `<synced>/projects` or `<synced>/archive`; `full`
/// widens the scan to the whole synced root.
pub fn checkD1(alloc: std.mem.Allocator, ws: *const Workspace, full: bool) ![][]u8 {
    var offenders: std.ArrayList([]u8) = .empty;
    if (full) {
        try scanNoFollow(alloc, ws.cfg.synced_root, &offenders);
    } else {
        try scanNoFollow(alloc, try ws.projectsRoot(alloc), &offenders);
        try scanNoFollow(alloc, try ws.archiveRoot(alloc), &offenders);
    }
    return offenders.toOwnedSlice(alloc);
}

/// True the moment a directory named ".git" is found under `root_path`;
/// stops descending at that point (a real clone's object database can be
/// large and there is no need to look inside it once found). Same
/// no-follow-symlinks discipline as `scanNoFollow`.
fn hasGitDirUnder(alloc: std.mem.Allocator, root_path: []const u8) !bool {
    var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    defer root_dir.close(fsutil.io());

    var walker = try root_dir.walkSelectively(alloc);
    defer walker.deinit();

    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.basename, ".git")) return true;
        try walker.enter(fsutil.io(), entry);
    }
    return false;
}

/// D2: `code_root` outside `synced_root`, and no clone living inside the
/// synced projects tree. Both roots are resolved through symlinks first, so
/// a `code_root` that is itself a symlink into `synced_root` is still caught
/// even though the two configured paths look lexically disjoint.
pub fn checkD2(alloc: std.mem.Allocator, ws: *const Workspace) !bool {
    const synced_real = try fsutil.realPathOrSelf(alloc, ws.cfg.synced_root);
    const code_real = try fsutil.realPathOrSelf(alloc, ws.cfg.code_root);
    if (fsutil.pathIsInside(code_real, synced_real)) return false;
    if (try hasGitDirUnder(alloc, try ws.projectsRoot(alloc))) return false;
    return true;
}

/// D3: `hub_root` outside `synced_root`, both resolved through symlinks
/// first for the same reason as `checkD2`.
pub fn checkD3(alloc: std.mem.Allocator, ws: *const Workspace) !bool {
    const synced_real = try fsutil.realPathOrSelf(alloc, ws.cfg.synced_root);
    const hub_real = try fsutil.realPathOrSelf(alloc, ws.cfg.hub_root);
    return !fsutil.pathIsInside(hub_real, synced_real);
}

/// A `<hub_root>/<org>/<name>` directory with no marker at
/// `<synced>/projects/<org>/<name>/.holt.json` - a hub entry left behind by
/// a project that was archived or deleted without its hub being torn down.
fn findOrphans(alloc: std.mem.Allocator, ws: *const Workspace) ![]Orphan {
    var orphans: std.ArrayList(Orphan) = .empty;

    var hub_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), ws.cfg.hub_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer hub_dir.close(fsutil.io());

    var org_it = hub_dir.iterate();
    while (try org_it.next(fsutil.io())) |org_entry| {
        if (org_entry.kind != .directory) continue;

        var org_dir = try hub_dir.openDir(fsutil.io(), org_entry.name, .{ .iterate = true });
        defer org_dir.close(fsutil.io());

        var proj_it = org_dir.iterate();
        while (try proj_it.next(fsutil.io())) |proj_entry| {
            if (proj_entry.kind != .directory) continue;
            const content_dir = try std.fs.path.join(alloc, &.{ ws.cfg.synced_root, "projects", org_entry.name, proj_entry.name });
            const marker_path = try std.fs.path.join(alloc, &.{ content_dir, marker.marker_basename });
            // A present marker, or one merely evicted from local storage, both
            // mean the project still exists - not a hub left behind.
            if (fsutil.exists(marker_path) or marker.markerEvicted(alloc, content_dir)) continue;
            try orphans.append(alloc, .{ .org = try alloc.dupe(u8, org_entry.name), .name = try alloc.dupe(u8, proj_entry.name) });
        }
    }

    return orphans.toOwnedSlice(alloc);
}

/// Every symlink under a project hub's `code/` subtree whose target does not
/// exist: a clone deleted out from under a valid marker, or a `local:` member
/// never cloned. The `docs`/`assets`/`links` CONTENT links are deliberately
/// out of scope - `holt new` leaves those content dirs empty and cloud
/// backends drop empty directories, so a healthy synced workspace routinely
/// has dangling content links that are not a fault.
/// The marker-correct link still points where reconcile wants it, so hub
/// drift stays quiet; the missing-clone check skips `local:` members entirely.
/// `is_local` is true when the dead target sits under `<code_root>/local`,
/// selecting the "re-adopt" hint over "holt restore".
fn collectDanglingUnder(
    alloc: std.mem.Allocator,
    root_path: []const u8,
    project: []const u8,
    local_root: []const u8,
    out: *std.ArrayList(DanglingLink),
) !void {
    var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer root_dir.close(fsutil.io());

    var walker = try root_dir.walkSelectively(alloc);
    defer walker.deinit();

    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind == .sym_link) {
            const link_path = try std.fs.path.join(alloc, &.{ root_path, entry.path });
            switch (try fsutil.linkState(alloc, link_path)) {
                .symlink => |target| {
                    const resolved = if (std.fs.path.isAbsolute(target))
                        target
                    else
                        try std.fs.path.join(alloc, &.{ std.fs.path.dirname(link_path).?, target });
                    if (!fsutil.exists(resolved)) try out.append(alloc, .{
                        .project = project,
                        .link_path = link_path,
                        .target = target,
                        .is_local = fsutil.pathIsInside(resolved, local_root),
                    });
                },
                else => {},
            }
            continue;
        }
        if (entry.kind == .directory) try walker.enter(fsutil.io(), entry);
    }
}

fn findDanglingLinks(alloc: std.mem.Allocator, ws: *const Workspace, projects: []const Project) ![]DanglingLink {
    var out: std.ArrayList(DanglingLink) = .empty;
    const local_root = try std.fs.path.join(alloc, &.{ ws.cfg.code_root, "local" });
    for (projects) |p| {
        const code_root = try std.fs.path.join(alloc, &.{ p.hub_path, "code" });
        try collectDanglingUnder(alloc, code_root, try p.qualified(alloc), local_root, &out);
    }
    return out.toOwnedSlice(alloc);
}

/// One `<org>/<name>` directory directly under `root_path`, with whether it
/// carries a marker file. A dir with no marker is content holt cannot see;
/// two markered dirs of the same `<org>/<name>` across projects and archive
/// are a shadow.
const NameDir = struct { org: []const u8, name: []const u8, path: []const u8, has_marker: bool };

fn scanNameDirs(alloc: std.mem.Allocator, root_path: []const u8) ![]NameDir {
    var out: std.ArrayList(NameDir) = .empty;

    var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer root_dir.close(fsutil.io());

    var org_it = root_dir.iterate();
    while (try org_it.next(fsutil.io())) |org_entry| {
        if (org_entry.kind != .directory) continue;

        var org_dir = try root_dir.openDir(fsutil.io(), org_entry.name, .{ .iterate = true });
        defer org_dir.close(fsutil.io());

        var name_it = org_dir.iterate();
        while (try name_it.next(fsutil.io())) |name_entry| {
            if (name_entry.kind != .directory) continue;
            const path = try std.fs.path.join(alloc, &.{ root_path, org_entry.name, name_entry.name });
            const marker_path = try std.fs.path.join(alloc, &.{ path, marker.marker_basename });
            try out.append(alloc, .{
                .org = try alloc.dupe(u8, org_entry.name),
                .name = try alloc.dupe(u8, name_entry.name),
                .path = path,
                .has_marker = fsutil.exists(marker_path),
            });
        }
    }

    return out.toOwnedSlice(alloc);
}

fn findShadows(alloc: std.mem.Allocator, active: []const NameDir, archived: []const NameDir) ![]Shadow {
    var out: std.ArrayList(Shadow) = .empty;
    for (active) |a| {
        if (!a.has_marker) continue;
        for (archived) |b| {
            if (!b.has_marker) continue;
            if (std.mem.eql(u8, a.org, b.org) and std.mem.eql(u8, a.name, b.name)) {
                try out.append(alloc, .{ .org = a.org, .name = a.name });
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

/// A directory name holt should ignore when scanning for stray content: a
/// dot-file/dir (`.git`, `.dropbox`, `.stfolder`, `.stversions`, a Linux
/// `.Trash-1000`) or an `@`-prefixed sync/NAS metadata dir (Synology's
/// `@eaDir`). These land inside a synced tree as legitimate system state, so
/// flagging them as "leftover content with no marker" is a false alarm.
fn isSystemDir(name: []const u8) bool {
    return name.len > 0 and (name[0] == '.' or name[0] == '@');
}

fn findOrphanedContent(alloc: std.mem.Allocator, groups: []const []const NameDir) ![]OrphanedContent {
    var out: std.ArrayList(OrphanedContent) = .empty;
    for (groups) |dirs| {
        for (dirs) |d| {
            if (d.has_marker) continue;
            // A cloud/NAS metadata dir or a conflict copy is not "leftover
            // content" the user forgot a marker on - the former is system
            // state, the latter is reported separately - so neither counts,
            // at either the org or the project level.
            if (isSystemDir(d.name) or isSystemDir(d.org)) continue;
            if (workspace.isConflictCopyName(d.name) or workspace.isConflictCopyName(d.org)) continue;
            // A dir whose marker is merely evicted is a real project reported
            // under evicted_markers, not orphaned content.
            if (marker.markerEvicted(alloc, d.path)) continue;
            try out.append(alloc, .{ .path = d.path });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Every directory under `<synced>/{projects,archive}` whose name carries a
/// cloud-sync conflict-copy signature, at either the org or the project
/// level. Report-only: holt never deletes one (it may hold real edits the
/// user needs to merge), it just surfaces them so they are not silently
/// ignored now that `scanProjects` refuses to adopt them as projects.
fn findConflictCopies(alloc: std.mem.Allocator, ws: *const Workspace) ![]ConflictCopy {
    var out: std.ArrayList(ConflictCopy) = .empty;
    try collectConflictCopies(alloc, try ws.projectsRoot(alloc), &out);
    try collectConflictCopies(alloc, try ws.archiveRoot(alloc), &out);
    return out.toOwnedSlice(alloc);
}

fn collectConflictCopies(alloc: std.mem.Allocator, root_path: []const u8, out: *std.ArrayList(ConflictCopy)) !void {
    var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer root_dir.close(fsutil.io());

    var org_it = root_dir.iterate();
    while (try org_it.next(fsutil.io())) |org_entry| {
        if (org_entry.kind != .directory) continue;
        if (workspace.isConflictCopyName(org_entry.name)) {
            try out.append(alloc, .{ .path = try std.fs.path.join(alloc, &.{ root_path, org_entry.name }) });
            continue;
        }
        var org_dir = try root_dir.openDir(fsutil.io(), org_entry.name, .{ .iterate = true });
        defer org_dir.close(fsutil.io());

        var name_it = org_dir.iterate();
        while (try name_it.next(fsutil.io())) |name_entry| {
            if (name_entry.kind != .directory) continue;
            if (workspace.isConflictCopyName(name_entry.name))
                try out.append(alloc, .{ .path = try std.fs.path.join(alloc, &.{ root_path, org_entry.name, name_entry.name }) });
        }
    }
}

fn findStaleAliases(alloc: std.mem.Allocator, projects: []const Project) ![]StaleAlias {
    var out: std.ArrayList(StaleAlias) = .empty;
    for (projects) |p| {
        for (p.marker.aliases.keys()) |alias_key| {
            if (!p.marker.repos.contains(alias_key)) {
                try out.append(alloc, .{ .project = try p.qualified(alloc), .alias = alias_key });
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Runs every check and, with `opts.fix`, repairs hub drift in place
/// (create/retarget/sweep only - never a conflict, never content, never a
/// clone, never a D1 offender).
pub fn run(alloc: std.mem.Allocator, ws: *const Workspace, opts: Options) !Report {
    const scan = try scanMarkers(alloc, ws);

    var bad_identities: std.ArrayList(BadIdentity) = .empty;
    var missing_clones: std.ArrayList(MissingClone) = .empty;
    var broken_clones: std.ArrayList(BrokenClone) = .empty;
    var drift: std.ArrayList(DriftEntry) = .empty;

    // Resolve identities and existence serially (cheap), collecting the
    // present clones whose integrity needs a git call into one flat worklist.
    var present: std.ArrayList(CloneCheck) = .empty;
    for (scan.ok) |p| {
        const qualified = try p.qualified(alloc);
        for (p.marker.repos.keys()) |repo_name| {
            const id = p.repoIdentity(alloc, repo_name) catch {
                try bad_identities.append(alloc, .{ .project = qualified, .repo = repo_name });
                continue;
            };
            if (id.isLocal()) continue;
            const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
            if (!fsutil.exists(clone_path)) {
                try missing_clones.append(alloc, .{ .project = qualified, .repo = repo_name, .path = clone_path });
            } else {
                try present.append(alloc, .{ .project = qualified, .repo = repo_name, .path = clone_path });
            }
        }
    }

    // The expensive part: one `git.isCompleteClone` per present clone, run
    // concurrently. Results stay in worklist order, so classification below
    // preserves project/repo order.
    const paths = try alloc.alloc([]const u8, present.items.len);
    for (present.items, paths) |c, *slot| slot.* = c.path;
    const results = try alloc.alloc(anyerror!bool, present.items.len);
    var arenas = try parallel.map(void, []const u8, anyerror!bool, checkComplete, alloc, opts.jobs, {}, paths, results);
    defer arenas.deinit();
    for (present.items, results) |c, res| {
        // Present on disk but with no commit reachable from HEAD - an
        // interrupted clone that existence checks alone read as fine.
        if (!try res) try broken_clones.append(alloc, .{ .project = c.project, .repo = c.repo, .path = c.path });
    }

    for (scan.ok) |p| {
        // A repo with an unparseable URL already surfaced above; hub.reconcile
        // resolves every member's identity again internally and would only
        // repeat the same failure, so this project's hub is skipped rather
        // than aborting the whole doctor run.
        const dry_report = hub.reconcile(alloc, ws, &p, true) catch |err| switch (err) {
            error.UnrecognizedUrl => continue,
            else => return err,
        };

        var fixed = false;
        if (opts.fix and (dry_report.created > 0 or dry_report.retargeted > 0 or dry_report.removed > 0)) {
            _ = try hub.reconcile(alloc, ws, &p, false);
            fixed = dry_report.conflicts.len == 0;
        }
        if (dry_report.created > 0 or dry_report.retargeted > 0 or dry_report.removed > 0 or dry_report.conflicts.len > 0) {
            const qualified = try p.qualified(alloc);
            try drift.append(alloc, .{ .project = qualified, .report = dry_report, .fixed = fixed });
        }
    }

    const active_dirs = try scanNameDirs(alloc, try ws.projectsRoot(alloc));
    const archived_dirs = try scanNameDirs(alloc, try ws.archiveRoot(alloc));

    return .{
        .d1_offenders = try checkD1(alloc, ws, opts.full),
        .d2_ok = try checkD2(alloc, ws),
        .d3_ok = try checkD3(alloc, ws),
        .marker_failures = scan.failures,
        .evicted_markers = scan.evicted,
        .bad_identities = try bad_identities.toOwnedSlice(alloc),
        .missing_clones = try missing_clones.toOwnedSlice(alloc),
        .broken_clones = try broken_clones.toOwnedSlice(alloc),
        .drift = try drift.toOwnedSlice(alloc),
        .orphans = try findOrphans(alloc, ws),
        .dangling_links = try findDanglingLinks(alloc, ws, scan.ok),
        .shadows = try findShadows(alloc, active_dirs, archived_dirs),
        .orphaned_content = try findOrphanedContent(alloc, &.{ active_dirs, archived_dirs }),
        .stale_aliases = try findStaleAliases(alloc, scan.ok),
        .conflict_copies = try findConflictCopies(alloc, ws),
        .clone_temps = try findCloneTemps(alloc, ws, opts.fix),
    };
}

/// Finds `*.holt-tmp` clone-staging dirs left under code_root by a clone that
/// was killed before its atomic rename (see git.clone). With `fix`, each is
/// removed. The walk descends the host/owner skeleton but never enters a real
/// clone (a dir with a `.git`) or a temp itself, so it does not traverse repo
/// working trees. A temp of a clone still in progress is one holt would only
/// leave on a hard kill; running `doctor --fix` while a clone is in flight can
/// race it, so `--fix` is a maintenance action to run when no clone is active.
fn findCloneTemps(alloc: std.mem.Allocator, ws: *const Workspace, fix: bool) ![]CloneTemp {
    var out: std.ArrayList(CloneTemp) = .empty;

    var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), ws.cfg.code_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.toOwnedSlice(alloc),
        else => return err,
    };
    defer root_dir.close(fsutil.io());

    var walker = try root_dir.walkSelectively(alloc);
    defer walker.deinit();

    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind != .directory) continue;
        const full = try std.fs.path.join(alloc, &.{ ws.cfg.code_root, entry.path });

        if (std.mem.endsWith(u8, std.fs.path.basename(entry.path), ".holt-tmp")) {
            var removed = false;
            if (fix) {
                std.Io.Dir.cwd().deleteTree(fsutil.io(), full) catch {};
                removed = !fsutil.exists(full);
            }
            try out.append(alloc, .{ .path = full, .removed = removed });
            continue;
        }

        // A repo's sibling worktrees dir is git's to manage; never walk into it.
        if (std.mem.endsWith(u8, std.fs.path.basename(entry.path), "@worktrees")) continue;

        // Descend only into skeleton dirs, never into a real clone's tree.
        const dotgit = try std.fs.path.join(alloc, &.{ full, ".git" });
        if (!fsutil.exists(dotgit)) try walker.enter(fsutil.io(), entry);
    }

    return out.toOwnedSlice(alloc);
}

fn tmpRoot(alloc: std.mem.Allocator, tmp: *testing.TmpDir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return alloc.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
}

test "checkD1: a planted symlink under projects is caught, one under archive too, neither followed if it points at a huge dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const projects_link = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", "evil" });
    try fsutil.replaceSymlink("/nonexistent-huge-tree", projects_link);

    const archive_dir = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "archive", "acme", "old" });
    try fsutil.ensureDir(archive_dir);
    const archive_link = try std.fs.path.join(arena, &.{ archive_dir, "evil2" });
    try fsutil.replaceSymlink("/nonexistent-huge-tree-2", archive_link);

    const offenders = try checkD1(arena, &ws, false);
    try testing.expectEqual(@as(usize, 2), offenders.len);
}

test "checkD1: default scope misses a symlink outside projects/archive, --full catches it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    try fsutil.ensureDir(ws.cfg.synced_root);
    const stray_link = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "backups", "evil" });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "backups" }));
    try fsutil.replaceSymlink("/nonexistent", stray_link);

    const narrow = try checkD1(arena, &ws, false);
    try testing.expectEqual(@as(usize, 0), narrow.len);

    const full = try checkD1(arena, &ws, true);
    try testing.expectEqual(@as(usize, 1), full.len);
}

test "checkD2: passes by default, fails when code_root is synced or a .git dir lives under projects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    try testing.expect(try checkD2(arena, &ws));

    var synced_code_ws = ws;
    synced_code_ws.cfg.code_root = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "code" });
    try testing.expect(!try checkD2(arena, &synced_code_ws));

    const git_dir = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", ".git" });
    try fsutil.ensureDir(git_dir);
    try testing.expect(!try checkD2(arena, &ws));
}

test "checkD2: a code_root symlink whose physical target lies inside synced_root is caught" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    const inner = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "inner-code" });
    try fsutil.ensureDir(inner);

    var symlinked_ws = ws;
    symlinked_ws.cfg.code_root = try std.fs.path.join(arena, &.{ root, "code-link" });
    try fsutil.replaceSymlink(inner, symlinked_ws.cfg.code_root);

    try testing.expect(!try checkD2(arena, &symlinked_ws));

    // A code_root genuinely outside synced_root, symlink or not, still passes.
    const outer = try std.fs.path.join(arena, &.{ root, "outer-code" });
    try fsutil.ensureDir(outer);
    var outer_ws = ws;
    outer_ws.cfg.code_root = try std.fs.path.join(arena, &.{ root, "outer-link" });
    try fsutil.replaceSymlink(outer, outer_ws.cfg.code_root);
    try testing.expect(try checkD2(arena, &outer_ws));
}

test "checkD3: passes by default, fails when hub_root is inside synced_root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    try testing.expect(try checkD3(arena, &ws));

    var synced_hub_ws = ws;
    synced_hub_ws.cfg.hub_root = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "hub" });
    try testing.expect(!try checkD3(arena, &synced_hub_ws));
}

test "run: an orphaned hub entry with no marker is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "gone" }));

    const report = try run(arena, &ws, .{});
    try testing.expectEqual(@as(usize, 1), report.orphans.len);
    try testing.expectEqualStrings("acme", report.orphans[0].org);
    try testing.expectEqualStrings("gone", report.orphans[0].name);
    try testing.expect(!report.ok());
}

test "run: an evicted marker is reported as evicted and suppresses its hub-orphan and orphaned-content false positives" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    // A real project keeps the org dir alive.
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "real", .{ .version = 1, .org = "acme", .name = "real", .repos = .empty });

    // An evicted project: only the placeholder on disk, plus a leftover hub
    // dir that would read as a hub orphan if eviction were not recognized.
    const evicted_content = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "gone" });
    try fsutil.ensureDir(evicted_content);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ evicted_content, marker.evicted_marker_basename }), .data = "" });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "gone" }));

    const report = try run(arena, &ws, .{});
    try testing.expectEqual(@as(usize, 1), report.evicted_markers.len);
    try testing.expectEqualStrings("gone", report.evicted_markers[0].name);
    try testing.expectEqual(@as(usize, 0), report.orphans.len);
    try testing.expectEqual(@as(usize, 0), report.orphaned_content.len);
    try testing.expect(!report.ok());
}

test "run: a corrupted marker is reported as a failure, not fatal to the whole run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "good", .{ .version = 1, .org = "acme", .name = "good", .repos = .empty });

    const broken_dir = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "broken" });
    try fsutil.ensureDir(broken_dir);
    const broken_marker = try std.fs.path.join(arena, &.{ broken_dir, marker.marker_basename });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = broken_marker, .data = "not json" });

    const report = try run(arena, &ws, .{});
    try testing.expectEqual(@as(usize, 1), report.marker_failures.len);
    try testing.expect(std.mem.indexOf(u8, report.marker_failures[0].path, "broken") != null);
    try testing.expect(!report.ok());
}

test "run: a missing clone is reported with its would-be path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const report = try run(arena, &ws, .{});
    try testing.expectEqual(@as(usize, 1), report.missing_clones.len);
    try testing.expectEqualStrings("acme/proj", report.missing_clones[0].project);
    try testing.expectEqualStrings("holt", report.missing_clones[0].repo);
    try testing.expect(!report.ok());
}

test "run: a member clone present but incomplete is reported under broken clones, not missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    // Plant a half-finished clone at the member's identity path: a `.git`
    // with no commits (existence checks pass, HEAD does not resolve).
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "sakakibara", "holt" });
    try fsutil.ensureDir(clone_path);
    try testutil.runGit(&sb, clone_path, &.{ "init", "-q" });

    const report = try run(arena, &ws, .{});
    try testing.expectEqual(@as(usize, 0), report.missing_clones.len);
    try testing.expectEqual(@as(usize, 1), report.broken_clones.len);
    try testing.expectEqualStrings("holt", report.broken_clones[0].repo);
    try testing.expect(!report.ok());
}

test "run: --fix repairs a stale hub link but leaves a still-missing clone reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const scan = try scanMarkers(arena, &ws);
    _ = try hub.reconcile(arena, &ws, &scan.ok[0], false);

    const stale_link = try std.fs.path.join(arena, &.{ scan.ok[0].hub_path, "code", "gone" });
    try fsutil.replaceSymlink("/nowhere", stale_link);

    const before = try run(arena, &ws, .{});
    try testing.expectEqual(@as(usize, 1), before.drift.len);
    try testing.expect(!before.drift[0].fixed);
    try testing.expect(!before.ok());

    const after = try run(arena, &ws, .{ .fix = true });
    try testing.expectEqual(@as(usize, 1), after.drift.len);
    try testing.expect(after.drift[0].fixed);
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, stale_link));
    // The missing clone is untouched by --fix - still reported, never cloned.
    try testing.expectEqual(@as(usize, 1), after.missing_clones.len);
    try testing.expect(!after.ok());
}
