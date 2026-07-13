//! `holt doctor [--fix] [--full]`: checks the workspace invariants (D1-D3)
//! plus a drift report, printing one pass/fail line per check. `--fix`
//! applies only the hub-drift repair; it never touches CONTENT, never
//! deletes a clone, and never removes a D1 symlink offender (report only -
//! it may be user data).

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("../app.zig");
const doctor = @import("../doctor.zig");
const marker = @import("../marker.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const project_mod = @import("../project.zig");
const config = @import("../config.zig");
const ui = @import("../ui.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    fix: cli.spec.Flag(.{ .help = "repair hub drift; never touches CONTENT or deletes a clone" }),
    full: cli.spec.Flag(.{ .help = "extend the D1 symlink scan to the whole synced root, not just projects/ and archive/" }),
    jobs: cli.spec.Opt(usize, .{ .short = 'j', .value_name = "N", .help = "check clone integrity in up to N clones concurrently (default: auto; 1 = serial)" }),
};

pub const command = app.command(Spec, .{
    .name = "doctor",
    .summary = "Check the workspace for invariant violations and drift",
    .usage = "holt doctor [--fix] [--full]",
    .group = .maintain,
    .needs_context = true,
    .details =
    \\Example:
    \\  holt doctor --fix --full
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const fix = a.fix;
    const full = a.full;
    if (a.jobs) |n| {
        if (n == 0) {
            return app.usageError(ctx, "-j/--jobs must be at least 1", .{});
        }
    }

    const ws = ctx.context.?.ws;
    const report = try doctor.run(ctx.alloc, &ws, .{ .full = full, .fix = fix, .jobs = a.jobs });
    try renderBackend(ctx.out, &ws.cfg);
    try render(ctx.out, &report, ctx.context.?.color);
    return if (report.ok()) 0 else 1;
}

/// Informational: names the active backend and whether its resolved
/// synced_root exists on disk. Never affects doctor's pass/fail exit code -
/// a missing synced_root may just be an unmounted cloud.
fn renderBackend(w: *std.Io.Writer, cfg: *const config.Config) !void {
    const name = cfg.backend orelse "(direct synced_root)";
    const status = if (fsutil.exists(cfg.synced_root)) "exists" else "missing";
    try w.print("backend: {s} -> {s} [{s}]\n", .{ name, cfg.synced_root, status });
}

fn passFail(w: *std.Io.Writer, color_enabled: bool, name: []const u8, passed: bool) !void {
    try w.print("{s}: ", .{name});
    if (passed) {
        try ui.color(color_enabled, w, "32", "PASS");
    } else {
        try ui.color(color_enabled, w, "31", "FAIL");
    }
    try w.writeByte('\n');
}

fn render(w: *std.Io.Writer, report: *const doctor.Report, color_enabled: bool) !void {
    try passFail(w, color_enabled, "no symlinks under projects/archive", report.d1_offenders.len == 0);
    for (report.d1_offenders) |p| try w.print("  symlink: {s}\n", .{p});

    try passFail(w, color_enabled, "code is outside the synced folder", report.d2_ok);
    try passFail(w, color_enabled, "hub is outside the synced folder", report.d3_ok);

    try passFail(w, color_enabled, "markers parse", report.marker_failures.len == 0);
    for (report.marker_failures) |f| try w.print("  {s}: {s}\n", .{ f.path, f.message });

    try passFail(w, color_enabled, "markers present locally", report.evicted_markers.len == 0);
    for (report.evicted_markers) |e| try w.print("  {s}/{s}: marker evicted from local storage (hint: open its folder to download it)\n", .{ e.org, e.name });

    try passFail(w, color_enabled, "member identities resolve", report.bad_identities.len == 0);
    for (report.bad_identities) |b| try w.print("  {s}: {s}\n", .{ b.project, b.repo });

    try passFail(w, color_enabled, "clones present", report.missing_clones.len == 0);
    for (report.missing_clones) |m| try w.print("  {s}: {s} missing at {s} (hint: holt restore --all)\n", .{ m.project, m.repo, m.path });

    try passFail(w, color_enabled, "clones intact", report.broken_clones.len == 0);
    for (report.broken_clones) |b| try w.print("  {s}: {s} at {s} is an incomplete clone (hint: remove it and re-clone)\n", .{ b.project, b.repo, b.path });

    var drift_ok = true;
    for (report.drift) |d| {
        if (d.unresolved()) drift_ok = false;
    }
    try passFail(w, color_enabled, "hub drift", drift_ok);
    for (report.drift) |d| {
        const status = if (d.fixed) "fixed" else "unresolved";
        try w.print("  {s}: created {d}, retargeted {d}, removed {d}, conflicts {d} ({s})\n", .{
            d.project, d.report.created, d.report.retargeted, d.report.removed, d.report.conflicts.len, status,
        });
    }

    try passFail(w, color_enabled, "hub orphans", report.orphans.len == 0);
    for (report.orphans) |o| try w.print("  {s}/{s} (hint: holt sync removes it)\n", .{ o.org, o.name });

    try passFail(w, color_enabled, "dangling hub links", report.dangling_links.len == 0);
    for (report.dangling_links) |d| {
        const hint = if (d.is_local) "re-adopt the clone" else "holt restore --all";
        try w.print("  {s} -> {s} (hint: {s})\n", .{ d.link_path, d.target, hint });
    }

    try passFail(w, color_enabled, "no archive/active shadow", report.shadows.len == 0);
    for (report.shadows) |s| try w.print("  {s}/{s} (hint: delete or restore one)\n", .{ s.org, s.name });

    try passFail(w, color_enabled, "no orphaned content", report.orphaned_content.len == 0);
    for (report.orphaned_content) |o| try w.print("  {s} (hint: leftover content with no marker; remove it manually or restore its marker)\n", .{o.path});

    try passFail(w, color_enabled, "aliases valid", report.stale_aliases.len == 0);
    for (report.stale_aliases) |a| try w.print("  {s}: alias \"{s}\" has no such member\n", .{ a.project, a.alias });

    try passFail(w, color_enabled, "no conflict copies", report.conflict_copies.len == 0);
    for (report.conflict_copies) |c| try w.print("  {s} (hint: a cloud-sync conflict copy; merge what you need, then delete it)\n", .{c.path});

    var temps_ok = true;
    for (report.clone_temps) |t| {
        if (!t.removed) temps_ok = false;
    }
    try passFail(w, color_enabled, "no stale clone temporaries", temps_ok);
    for (report.clone_temps) |t| {
        const status = if (t.removed) "removed" else "run doctor --fix to remove";
        try w.print("  {s} ({s})\n", .{ t.path, status });
    }

    if (builtin.os.tag == .windows and report.unsurfaced_files.len > 0) {
        try w.print("note: {d} content file(s) not surfaced at the hub root (run `holt sync`; on Windows, file links need Developer Mode):\n", .{report.unsurfaced_files.len});
        for (report.unsurfaced_files) |u| try w.print("  {s}: {s}\n", .{ u.project, u.rel });
    }
}

test "run: every planted violation is caught; --fix resolves only the hub drift" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // A healthy project whose hub gets built, then a stale link planted
    // to simulate drift, plus a repo whose clone never existed (missing).
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "good", .{ .version = 1, .org = "acme", .name = "good", .repos = repos });

    const good_hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "good" });
    const good_content_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "good" });
    const m = try marker.load(arena, try std.fs.path.join(arena, &.{ good_content_path, marker.marker_basename }), null);
    const p: project_mod.Project = .{ .org = "acme", .name = "good", .content_path = good_content_path, .hub_path = good_hub_path, .marker = m };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const stale_link = try std.fs.path.join(arena, &.{ good_hub_path, "code", "gone" });
    try fsutil.replaceSymlink("/nowhere", stale_link);

    // A symlink planted directly under CONTENT (D1).
    const d1_offender = try std.fs.path.join(arena, &.{ good_content_path, "evil" });
    try fsutil.replaceSymlink("/nonexistent-huge-tree", d1_offender);

    // A corrupted marker.
    const broken_dir = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "broken" });
    try fsutil.ensureDir(broken_dir);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ broken_dir, marker.marker_basename }), .data = "not json" });

    const before = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), before.code);
    try testing.expect(std.mem.indexOf(u8, before.out, "no symlinks under projects/archive: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, before.out, "markers parse: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, before.out, "clones present: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, before.out, "hub drift: FAIL") != null);

    const after = try testutil.runCmd(arena, command.run, ws, &.{"--fix"});
    try testing.expectEqual(@as(u8, 1), after.code);
    // Hub drift is now resolved...
    try testing.expect(std.mem.indexOf(u8, after.out, "hub drift: PASS") != null);
    // ...but the rest are untouched: still failing.
    try testing.expect(std.mem.indexOf(u8, after.out, "no symlinks under projects/archive: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, after.out, "markers parse: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, after.out, "clones present: FAIL") != null);

    switch (try fsutil.linkState(arena, d1_offender)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, stale_link));
}

test "run: a stale clone temp is reported, and --fix removes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // A clean project with its hub built, so the only finding is the temp.
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .{ .version = 1, .org = "acme", .name = "empty", .repos = .empty });
    const content_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "empty" });
    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "empty" });
    const m = try marker.load(arena, try std.fs.path.join(arena, &.{ content_path, marker.marker_basename }), null);
    const p: project_mod.Project = .{ .org = "acme", .name = "empty", .content_path = content_path, .hub_path = hub_path, .marker = m };
    _ = try hub.reconcile(arena, &ws, &p, false);

    // A leftover clone-staging dir at a clone-sibling path under code_root.
    const temp = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme", "widget.AbC123.holt-tmp" });
    try fsutil.ensureDir(temp);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ temp, "partial" }), .data = "x" });

    const before = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), before.code);
    try testing.expect(std.mem.indexOf(u8, before.out, "no stale clone temporaries: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, before.out, temp) != null);

    const after = try testutil.runCmd(arena, command.run, ws, &.{"--fix"});
    try testing.expect(std.mem.indexOf(u8, after.out, "no stale clone temporaries: PASS") != null);
    try testing.expect(!fsutil.exists(temp));
}

test "run: a clean workspace passes every check and exits 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .{ .version = 1, .org = "acme", .name = "empty", .repos = .empty });

    // doctor treats an unbuilt hub as drift (correctly), so the hub has to
    // be built first for this workspace to actually be clean.
    // No docs/assets/links content dirs: `holt new` leaves them empty and
    // cloud backends drop empty directories, so a healthy synced workspace
    // routinely has dangling content links. That must still pass doctor.
    const content_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "empty" });
    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "empty" });
    const m = try marker.load(arena, try std.fs.path.join(arena, &.{ content_path, marker.marker_basename }), null);
    const p: project_mod.Project = .{ .org = "acme", .name = "empty", .content_path = content_path, .hub_path = hub_path, .marker = m };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no symlinks under projects/archive: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "code is outside the synced folder: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "hub is outside the synced folder: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "dangling hub links: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "no archive/active shadow: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "no orphaned content: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "aliases valid: PASS") != null);

    const want_backend_line = try std.fmt.allocPrint(arena, "backend: (direct synced_root) -> {s} [exists]\n", .{ws.cfg.synced_root});
    try testing.expect(std.mem.indexOf(u8, got.out, want_backend_line) != null);
}

test "run: reports the active backend name and flags a missing synced_root as informational only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    var ws = try testutil.testWorkspace(arena, root);
    ws.cfg.backend = "dropbox";
    ws.cfg.synced_root = try std.fs.path.join(arena, &.{ root, "never-mounted" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    // A missing synced_root is informational (an unmounted cloud), so it must
    // not flip an otherwise-clean doctor run to a failing exit code.
    try testing.expectEqual(@as(u8, 0), got.code);

    const want_backend_line = try std.fmt.allocPrint(arena, "backend: dropbox -> {s} [missing]\n", .{ws.cfg.synced_root});
    try testing.expect(std.mem.indexOf(u8, got.out, want_backend_line) != null);
}

test "run: output leads with human check names, never the internal D1/D2/D3 codes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .{ .version = 1, .org = "acme", .name = "empty", .repos = .empty });

    const content_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "empty" });
    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "empty" });
    const m = try marker.load(arena, try std.fs.path.join(arena, &.{ content_path, marker.marker_basename }), null);
    const p: project_mod.Project = .{ .org = "acme", .name = "empty", .content_path = content_path, .hub_path = hub_path, .marker = m };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!leaksCode(got.out, "D1"));
    try testing.expect(!leaksCode(got.out, "D2"));
    try testing.expect(!leaksCode(got.out, "D3"));
}

/// True when `code` appears as a word of its own. The output carries the
/// workspace's paths, and a temp directory is named at random -- a check that
/// merely scanned for the substring would fail whenever those random letters
/// happened to spell one, which they eventually do.
fn leaksCode(out: []const u8, code: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, code)) |at| {
        i = at + code.len;
        const before_ok = at == 0 or !std.ascii.isAlphanumeric(out[at - 1]);
        const after = at + code.len;
        const after_ok = after == out.len or !std.ascii.isAlphanumeric(out[after]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

test "run: dangling hub links catches a deleted remote clone and a cloneless local repo" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var remote_repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try remote_repos.put(arena, "holt", "https://github.com/sakakibara/holt");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "remote", .{ .version = 1, .org = "acme", .name = "remote", .repos = remote_repos });

    var local_repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try local_repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "scratchy", .{ .version = 1, .org = "acme", .name = "scratchy", .repos = local_repos });

    // --fix builds each hub before the dangling scan runs, so a single pass
    // both materializes the links and reports them dead.
    const got = try testutil.runCmd(arena, command.run, ws, &.{"--fix"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "dangling hub links: FAIL") != null);

    const remote_target = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "sakakibara", "holt" });
    const remote_line = try std.fmt.allocPrint(arena, "{s} (hint: holt restore --all)", .{remote_target});
    try testing.expect(std.mem.indexOf(u8, got.out, remote_line) != null);

    const local_target = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "scratch" });
    const local_line = try std.fmt.allocPrint(arena, "{s} (hint: re-adopt the clone)", .{local_target});
    try testing.expect(std.mem.indexOf(u8, got.out, local_line) != null);

    // The local repo's missing clone is invisible to the clones-present check,
    // proving the dangling scan is what catches it.
    try testing.expect(std.mem.indexOf(u8, got.out, "scratchy: scratch missing at") == null);
}

test "run: an org/name present in both projects and archive is a shadow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "dup", .{ .version = 1, .org = "acme", .name = "dup", .repos = .empty });
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "dup", .{ .version = 1, .org = "acme", .name = "dup", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no archive/active shadow: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/dup (hint: delete or restore one)") != null);
}

test "run: a marker-less dir under an org is orphaned content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // A real project so the org dir exists, plus a sibling dir with no marker.
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "real", .{ .version = 1, .org = "acme", .name = "real", .repos = .empty });
    const leftover = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "leftover" });
    try fsutil.ensureDir(leftover);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no orphaned content: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, leftover) != null);
}

test "run: cloud conflict copies are reported; NAS/sync metadata dirs are not orphaned content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    const proot = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects" });

    try testutil.writeMarker(arena, proot, "acme", "real", .{ .version = 1, .org = "acme", .name = "real", .repos = .empty });

    // A name-level conflict copy (marker and all) and a whole-org conflict copy.
    try testutil.writeMarker(arena, proot, "acme", "real (conflicted copy 2024-01-01)", .{ .version = 1, .org = "acme", .name = "real", .repos = .empty });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ proot, "acme (conflicted copy)", "child" }));

    // Cloud/NAS metadata dirs that must NOT be flagged as orphaned content.
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ proot, "acme", "@eaDir" }));
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ proot, "acme", ".stfolder" }));

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no conflict copies: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "real (conflicted copy 2024-01-01)") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme (conflicted copy)") != null);
    // The metadata dirs and the child under the conflict-copy org are not
    // "orphaned content".
    try testing.expect(std.mem.indexOf(u8, got.out, "no orphaned content: PASS") != null);
}

test "run: a stale alias with no matching member is reported" {
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
    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try aliases.put(arena, "ghost", "whatever");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos, .aliases = aliases });

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "aliases valid: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/proj: alias \"ghost\" has no such member") != null);
}

test "run: --fix never repairs the report-only checks" {
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
    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try aliases.put(arena, "ghost", "whatever");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos, .aliases = aliases });

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "dup", .{ .version = 1, .org = "acme", .name = "dup", .repos = .empty });
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "dup", .{ .version = 1, .org = "acme", .name = "dup", .repos = .empty });

    const leftover = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "leftover" });
    try fsutil.ensureDir(leftover);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--fix"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "dangling hub links: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "no archive/active shadow: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "no orphaned content: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "aliases valid: FAIL") != null);

    // --fix touches only the hub: the shadowing archive marker and the
    // marker-less content dir are still on disk afterward.
    const archived_marker = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "archive", "acme", "dup", marker.marker_basename });
    try testing.expect(fsutil.exists(archived_marker));
    try testing.expect(fsutil.exists(leftover));
}
