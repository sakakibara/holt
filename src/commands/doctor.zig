//! `holt doctor [--fix] [--full]`: checks the workspace invariants (D1-D3)
//! plus a drift report, printing one pass/fail line per check. `--fix`
//! applies only the hub-drift repair and the kept-file link repairs that
//! move no content (creating, retargeting, and removing links); it never
//! changes file content, never deletes a clone, and never removes a D1
//! symlink offender (report only - it may be user data). `--retire` runs
//! the check before retiring the machine instead (`retire`).

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("../app.zig");
const doctor = @import("../doctor.zig");
const doctor_kept = @import("../doctor_kept.zig");
const kept_hints = @import("kept_hints.zig");
const workspace = @import("../workspace.zig");
const marker = @import("../marker.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const project_mod = @import("../project.zig");
const config = @import("../config.zig");
const ui = @import("../ui.zig");
const util = @import("kept_util.zig");
const kept_hooks = @import("kept_hooks.zig");
const retire = @import("retire.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    fix: cli.Flag(.{ .help = "repair hub and kept-file links; never changes file content or deletes a clone" }),
    full: cli.Flag(.{ .help = "extend the D1 symlink scan to the whole synced root, not just projects/, archive/, and kept/" }),
    jobs: cli.Opt(usize, .{ .short = 'j', .value_name = "N", .help = "check clone integrity in up to N clones concurrently (default: auto; 1 = serial)" }),
    retire: cli.Flag(.{ .help = "report what exists only on this machine before retiring it; changes nothing" }),
};

pub const command = app.command(Spec, .{
    .name = "doctor",
    .summary = "Check the workspace for invariant violations and drift",
    .usage = "holt doctor [--fix] [--full] | holt doctor --retire",
    .group = .maintain,
    .needs_context = true,
    .details =
    \\--retire is the check before retiring this machine. It changes nothing
    \\and fails, naming the command that settles each one, on files holt does
    \\not keep, nested repositories, unsettled kept files, uncommitted changes,
    \\the git state no remote holds that the deleters refuse on (stashes, and
    \\refs and HEADs, every working tree's included, naming what no remote
    \\holds, in submodules too), staged changes only the record of a
    \\worktree that is gone holds, a merge, rebase, am, cherry-pick, revert,
    \\or bisect in progress in any git directory it weighs (with the
    \\commands finishing or aborting it; for one in a working tree that is
    \\gone, first the commands bringing it back from its record, or from
    \\its git directory for a submodule's, for one in a submodule git
    \\directory that names no working tree, the holt repo remove --force
    \\deleting it, and for one in a submodule git directory whose
    \\core.worktree names something that is not a directory, a symlink to
    \\nothing, or what cannot be read, what is seen there and git config
    \\--file <module>/config core.worktree alone), weighed and hinted as the
    \\deleters do it
    \\(each URL asked once for each clone, never one on this machine, nor one
    \\on a host that gave no answer earlier in the run: each such host is
    \\named once, with the clones it kept from being asked), each remote
    \\whose push URLs are all on this machine (once, with the command
    \\replacing them), working trees git cannot list (with commands reaching
    \\that one worktree or its record, never git worktree repair or prune,
    \\and for one that is gone git worktree remove only when a weighing of
    \\its record as the deleters weigh it finds nothing at risk; one in a
    \\state holt does not change, as holt worktree --help lists them, with
    \\what git and holt see there and git -C <clone> worktree list alone,
    \\and a worktree record git does not list with what is seen there and
    \\the record's path alone), files in the code tree
    \\outside every clone, and loose entries in hubs. It also lists state
    \\holt never keeps (git hooks, extra git config sections, info/exclude
    \\lines, holt's own config) and every machine with kept files, by id,
    \\host, and the UTC date of its newest record, and ends by naming holt
    \\keep --retire-machine. On a machine with no kept-file records it ends
    \\by saying there is nothing to retire, and on a retired machine that has
    \\changed no kept files since, by saying "This machine was retired on
    \\<date>" and where holt keep --retire-machine ran. After a backend
    \\switch that left kept/ behind, it fails with that alone: kept/ is at
    \\<old>: copy it to <new>.
    \\
    \\Example:
    \\  holt doctor --fix --full
    \\  holt doctor --retire
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    if (a.retire) {
        if (a.fix or a.full or a.jobs != null) return app.usageError(ctx, "--retire takes no other option", .{});
        return retire.run(ctx);
    }
    const fix = a.fix;
    const full = a.full;
    if (a.jobs) |n| {
        if (n == 0) {
            return app.usageError(ctx, "-j/--jobs must be at least 1", .{});
        }
    }

    const ws = ctx.context.?.ws;
    const report = try doctor.run(ctx.alloc, &ws, .{ .full = full, .fix = fix, .jobs = a.jobs });
    try renderBackend(ctx, &ws.cfg);
    try render(ctx, &report);
    if (fix) try fixKept(ctx, a.jobs);
    const kept_report = try doctor_kept.run(ctx.alloc, &ws, try loadedProjects(ctx.alloc, &ws));
    try renderKept(ctx, &ws, &kept_report);
    return if (report.ok() and kept_report.ok()) 0 else 1;
}

/// The projects whose markers load; the ones that do not are reported by
/// `markers parse`.
fn loadedProjects(alloc: std.mem.Allocator, ws: *const workspace.Workspace) ![]const project_mod.Project {
    var out: std.ArrayList(project_mod.Project) = .empty;
    for (try ws.scanProjects(alloc)) |e| switch (e) {
        .ok => |p| try out.append(alloc, p),
        else => {},
    };
    return out.items;
}

/// Reconciles the kept files of every clone in the code tree in fix mode,
/// which only creates, retargets, and removes links, and prints each
/// repair.
fn fixKept(ctx: *app.Ctx, jobs: ?usize) !void {
    const clones = try ctx.context.?.ws.listClones(ctx.alloc);
    if (try kept_hooks.storeState(ctx, clones) != .ready) return;
    const targets = try ctx.alloc.alloc(kept_hooks.Target, clones.len);
    for (clones, targets) |c, *t| t.* = .{ .path = c };
    _ = try kept_hooks.run(ctx, ctx.out, targets, .{ .mode = .fix, .jobs = jobs, .actions_only = true });
}

/// Informational: names the active backend and whether its resolved
/// synced_root exists on disk. Never affects doctor's pass/fail exit code -
/// a missing synced_root may just be an unmounted cloud.
fn renderBackend(ctx: *app.Ctx, cfg: *const config.Config) !void {
    const name = cfg.backend orelse "(direct synced_root)";
    const status = if (fsutil.exists(cfg.synced_root)) "exists" else "missing";
    try ctx.out.print("backend: {s} -> {s} [{s}]\n", .{ name, try app.tilde(ctx, cfg.synced_root), status });
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

fn render(ctx: *app.Ctx, report: *const doctor.Report) !void {
    const w = ctx.out;
    const color_enabled = ctx.context.?.color;

    try passFail(w, color_enabled, "no symlinks under projects/archive/kept", report.d1_offenders.len == 0);
    for (report.d1_offenders) |p| try w.print("  symlink: {s}\n", .{try app.tilde(ctx, p)});

    try passFail(w, color_enabled, "code is outside the synced folder", report.d2_ok);
    try passFail(w, color_enabled, "hub is outside the synced folder", report.d3_ok);

    try passFail(w, color_enabled, "markers parse", report.marker_failures.len == 0);
    for (report.marker_failures) |f| try w.print("  {s}: {s}\n", .{ try app.tilde(ctx, f.path), f.message });

    try passFail(w, color_enabled, "markers present locally", report.evicted_markers.len == 0);
    for (report.evicted_markers) |e| try w.print("  {s}/{s}: marker evicted from local storage (hint: open its folder to download it)\n", .{ e.org, e.name });

    try passFail(w, color_enabled, "member identities resolve", report.bad_identities.len == 0);
    for (report.bad_identities) |b| try w.print("  {s}: {s}\n", .{ b.project, b.repo });

    try passFail(w, color_enabled, "clones present", report.missing_clones.len == 0);
    for (report.missing_clones) |m| try w.print("  {s}: {s} missing at {s} (hint: holt restore)\n", .{ m.project, m.repo, try app.tilde(ctx, m.path) });

    try passFail(w, color_enabled, "clones intact", report.broken_clones.len == 0);
    for (report.broken_clones) |b| try w.print("  {s}: {s} at {s} is an incomplete clone (hint: remove it and re-clone)\n", .{ b.project, b.repo, try app.tilde(ctx, b.path) });

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
        const hint = if (d.is_local) "re-adopt the clone" else "holt restore";
        try w.print("  {s} -> {s} (hint: {s})\n", .{ try app.tilde(ctx, d.link_path), try app.tilde(ctx, d.target), hint });
    }

    try passFail(w, color_enabled, "no archive/active shadow", report.shadows.len == 0);
    for (report.shadows) |s| try w.print("  {s}/{s} (hint: holt project remove {s}/{s} for the active one, or delete its archive dir)\n", .{ s.org, s.name, s.org, s.name });

    try passFail(w, color_enabled, "no orphaned content", report.orphaned_content.len == 0);
    for (report.orphaned_content) |o| try w.print("  {s} (hint: leftover content with no marker; remove it manually or restore its marker)\n", .{try app.tilde(ctx, o.path)});

    try passFail(w, color_enabled, "aliases valid", report.stale_aliases.len == 0 and report.bad_aliases.len == 0);
    for (report.stale_aliases) |a| try w.print("  {s}: alias \"{s}\" has no such member\n", .{ a.project, a.alias });
    for (report.bad_aliases) |a| try w.print("  {s}: unusable alias value for \"{s}\"\n", .{ a.project, a.repo });

    try passFail(w, color_enabled, "no conflict copies", report.conflict_copies.len == 0);
    for (report.conflict_copies) |c| try w.print("  {s} (hint: a cloud-sync conflict copy; merge what you need, then delete it)\n", .{try app.tilde(ctx, c.path)});

    var temps_ok = true;
    for (report.clone_temps) |t| {
        if (!t.removed) temps_ok = false;
    }
    try passFail(w, color_enabled, "no stale clone temporaries", temps_ok);
    for (report.clone_temps) |t| {
        const status = if (t.removed) "removed" else "run doctor --fix to remove";
        try w.print("  {s} ({s})\n", .{ try app.tilde(ctx, t.path), status });
    }

    try passFail(w, color_enabled, "no local repos with an origin", report.locals_with_origin.len == 0);
    for (report.locals_with_origin) |l| {
        const target = l.target orelse "an unrecognized url";
        if (l.claimed) {
            try w.print("  {s} -> {s} (hint: holt repo promote {s})\n", .{ try app.tilde(ctx, l.path), target, try ui.shellQuote(ctx.alloc, l.name) });
        } else {
            try w.print("  {s} -> {s} (hint: holt repo adopt {s})\n", .{ try app.tilde(ctx, l.path), target, try ui.quotePath(ctx.alloc, app.envOf(ctx), l.path) });
        }
    }

    if (report.remoteless_locals.len > 0) {
        try w.print("note: {d} local repo(s) have no remote; no other machine can restore them (hint: push them, or copy them before retiring this machine):\n", .{report.remoteless_locals.len});
        for (report.remoteless_locals) |l| {
            if (l.claimant) |c| {
                try w.print("  {s} (member of {s})\n", .{ try app.tilde(ctx, l.path), c });
            } else {
                try w.print("  {s}\n", .{try app.tilde(ctx, l.path)});
            }
        }
    }

    if (builtin.os.tag == .windows and report.unsurfaced_files.len > 0) {
        try w.print("note: {d} content file(s) not surfaced at the hub root (run `holt sync`; on Windows, file links need Developer Mode):\n", .{report.unsurfaced_files.len});
        for (report.unsurfaced_files) |u| try w.print("  {s}: {s}\n", .{ u.project, u.rel });
    }
}

fn place(ctx: *app.Ctx, tree: []const u8, rel: []const u8) ![]const u8 {
    return util.q(ctx, try fsutil.joinSlashy(ctx.alloc, tree, rel));
}

/// `n` bytes for a person: B, KiB, MiB, or GiB.
fn humanBytes(alloc: std.mem.Allocator, n: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB" };
    var v: u64 = n;
    var u: usize = 0;
    while (v >= 1024 * 10 and u + 1 < units.len) : (u += 1) v /= 1024;
    return std.fmt.allocPrint(alloc, "{d} {s}", .{ v, units[u] });
}

/// `n` and the noun for it: `one` for 1, `many` otherwise.
pub fn counted(alloc: std.mem.Allocator, n: usize, one: []const u8, many: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{d} {s}", .{ n, if (n == 1) one else many });
}

/// `<files> in <repos>[ and <hub roots>]`, naming only the parts that are
/// not zero.
pub fn filesIn(alloc: std.mem.Allocator, files: []const u8, repos: usize, hubs: usize) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try aw.writer.print("{s} in ", .{files});
    if (repos > 0) try aw.writer.writeAll(try counted(alloc, repos, "repo", "repos"));
    if (repos > 0 and hubs > 0) try aw.writer.writeAll(" and ");
    if (hubs > 0) try aw.writer.writeAll(try counted(alloc, hubs, "hub root", "hub roots"));
    return aw.written();
}

fn renderKept(ctx: *app.Ctx, ws: *const workspace.Workspace, r: *const doctor_kept.Report) !void {
    const w = ctx.out;
    const a = ctx.alloc;
    const color_enabled = ctx.context.?.color;
    const synced = ws.cfg.synced_root;

    try passFail(w, color_enabled, "kept files linked", r.linkedOk());
    if (r.git_too_old) |msg| try w.print("  {s}\n", .{msg});
    for (r.stops) |s| {
        const h = try kept_hints.forStop(ctx, s.tree, s.stop, s.key);
        try w.print("  {s}: {s}\n", .{ try util.q(ctx, s.tree), try kept_hints.render(a, h) });
    }
    for (r.unlinked) |p| {
        const h = try kept_hints.forItem(ctx, p.tree, p.key, synced, p.item);
        try w.print("  {s}: {s}\n", .{ try util.q(ctx, try kept_hints.placeOf(a, p.tree, p.item)), try kept_hints.render(a, h) });
    }
    for (r.not_ignored) |n| {
        try w.print("  {s}: git does not ignore holt's link, so it could be committed; a .gitignore negation may include it (run: git -C {s} check-ignore --no-index -v -- {s})\n", .{ try place(ctx, n.tree, n.rel), try util.q(ctx, n.tree), try ui.printable(a, try ui.shellQuote(a, n.rel)) });
    }
    for (r.failures) |f| try w.print("  {s}: could not check: {s}\n", .{ try util.q(ctx, f.path), f.detail });
    if (r.old_root) |old| try w.print("  kept/ is at {s}: copy it to {s}\n", .{ try util.q(ctx, old), try util.q(ctx, synced) });

    try passFail(w, color_enabled, "kept store valid", r.storeOk());
    const layout: @import("../kept.zig").store.Layout = .{ .synced_root = synced };
    for (r.invalid) |i| try w.print("  {s}: not a valid kept path ({s}); it is never linked\n", .{ try util.q(ctx, try layout.copyPath(a, i.key, i.rel)), i.reason });
    for (r.bad_markers) |b| try w.print("  {s}: {s}; it is never used\n", .{ try util.q(ctx, b.path), b.reason });
    for (r.unknown_versions) |k| try w.print("  {s}: its record has a version this holt does not know, so holt never writes to it (run: holt upgrade)\n", .{try util.q(ctx, try layout.keyDir(a, k))});
    for (r.unrecorded) |p| try w.print("  {s}: no key record here yet (not synced, or lost); nothing in it is linked or removed until its {s} arrives\n", .{ try util.q(ctx, p), @import("../kept.zig").store.record_basename });
    for (r.unknown_dirs) |p| try w.print("  {s}: unknown directory in the kept store, never linked; records naming what it holds may not have synced yet, so once every machine has synced, move out what you need\n", .{try util.q(ctx, p)});
    for (r.unknown_files) |p| try w.print("  {s}: unknown file in the kept store, never linked (a cloud conflict copy or a stray file); merge what you need, then delete it\n", .{try util.q(ctx, p)});
    for (r.conflict_copies) |c| {
        if (c.dir) {
            try w.print("  {s}: a cloud conflict copy of a holt directory; move what it holds into the directory it copies\n", .{try util.q(ctx, c.path)});
        } else try w.print("  {s}: a cloud conflict copy of a holt file; merge what you need, then delete it\n", .{try util.q(ctx, c.path)});
    }
    for (r.placeholders) |p| try w.print("  {s}: online-only on this machine; open it to download it\n", .{try util.q(ctx, p)});
    for (r.local_mismatch) |s| {
        const h = try kept_hints.forStop(ctx, s.tree, s.stop, s.key);
        try w.print("  {s}: {s}\n", .{ try util.q(ctx, s.tree), try kept_hints.render(a, h) });
    }
    for (r.tracked_links) |t| {
        try w.print("  {s}: a tracked symlink into kept/ (-> {s}) (run: git -C {s} rm --cached -- {s})\n", .{ try place(ctx, t.tree, t.rel), try ui.printable(a, try app.tilde(ctx, t.detail orelse "")), try util.q(ctx, t.tree), try ui.printable(a, try ui.shellQuote(a, t.rel)) });
    }
    for (r.aside_bad) |e| {
        const why = if (e.check == .missing) "is incomplete or its manifest cannot be read" else "no longer matches its manifest";
        try w.print("  {s}: aside entry {s}\n", .{ try util.q(ctx, try std.fs.path.join(a, &.{ try layout.asideDir(a), e.stamp })), why });
    }

    try passFail(w, color_enabled, "tracked kept path", r.trackedOk());
    for (r.tracked_upstream) |t| try w.print("  {s}: tracked on the upstream default branch (run: holt unkeep {s})\n", .{ try place(ctx, t.tree, t.rel), try place(ctx, t.tree, t.rel) });

    for (r.keyless) |s| {
        const h = try kept_hints.forStop(ctx, s.tree, s.stop, s.key);
        try w.print("note: {s}: {s}\n", .{ try util.q(ctx, s.tree), try kept_hints.render(a, h) });
    }
    var files: usize = 0;
    var repos: usize = 0;
    var hubs: usize = 0;
    var nested: usize = 0;
    var subs: usize = 0;
    for (r.candidates) |c| {
        files += c.rels.len;
        if (c.rels.len > 0) {
            if (c.hub) hubs += 1 else repos += 1;
        }
        nested += c.nested.len;
        subs += c.submodules_failed.len;
    }
    if (files > 0) {
        try w.print("note: {s} (run: holt keep --review --all):\n", .{try filesIn(a, try counted(a, files, "file not kept", "files not kept"), repos, hubs)});
        for (r.candidates) |c| {
            if (c.rels.len == 0) continue;
            const at = try util.q(ctx, c.place);
            try w.print("  {s}: {d} (run: holt keep --review {s})\n", .{ at, c.rels.len, at });
        }
    }
    if (nested > 0) {
        try w.print("note: {s}; nothing in one can be kept, so push each or move it out of the clone:\n", .{try counted(a, nested, "nested repository", "nested repositories")});
        for (r.candidates) |c| for (c.nested) |n| try w.print("  {s}\n", .{try place(ctx, c.place, n)});
    }
    if (subs > 0) {
        try w.print("note: {s} git could not list, so what they hold only here is unknown:\n", .{try counted(a, subs, "submodule", "submodules")});
        for (r.candidates) |c| for (c.submodules_failed) |sm| {
            const p = try place(ctx, c.place, sm);
            try w.print("  {s} (run: git -C {s} status)\n", .{ p, p });
        };
    }
    for (r.candidate_failures) |f| try w.print("note: could not list what is not kept in {s}: {s}\n", .{ try util.q(ctx, f.path), f.detail });
    for (r.auto_unignored) |u| {
        const h = try kept_hints.autoUnignored(ctx, try fsutil.joinSlashy(a, u.tree, u.rel), u.pattern, u.negation);
        try w.print("note: {s}: {s}\n", .{ try place(ctx, u.tree, u.rel), try kept_hints.render(a, h) });
    }
    if (r.aside_entries > 0) {
        try w.print("note: aside holds {s}, {s}", .{ try counted(a, r.aside_entries, "entry", "entries"), try humanBytes(a, r.aside_bytes) });
        if (r.aside_prunable > 0) try w.print("; {d} can be removed (run: holt keep --prune-aside)", .{r.aside_prunable});
        try w.writeByte('\n');
    }
    for (r.aside_unchecked) |e| {
        const why = if (e.check == .online_only) "online-only, so it was not verified" else "names a device or stream, so it was not verified";
        try w.print("note: aside entry {s} is {s}\n", .{ try util.q(ctx, try std.fs.path.join(a, &.{ try layout.asideDir(a), e.stamp })), why });
    }
    for (r.released) |rel| {
        var aw: std.Io.Writer.Allocating = .init(a);
        for (rel.machines, 0..) |m, n| {
            if (n > 0) try aw.writer.writeAll(", ");
            try aw.writer.writeAll(m);
            if (r.machine_id) |me| if (std.mem.eql(u8, me, m)) try aw.writer.writeAll(" (this machine)");
        }
        const cmd = if (rel.clone) |c|
            try std.fmt.allocPrint(a, "run: holt unkeep --purge {s} --yes", .{try place(ctx, c, rel.rel)})
        else blk: {
            const at = try std.fs.path.join(a, &.{ ws.cfg.code_root, rel.key });
            const purge = try std.fmt.allocPrint(a, "holt unkeep --purge {s} --yes", .{try place(ctx, at, rel.rel)});
            if (rel.origin) |o| break :blk try std.fmt.allocPrint(a, "run: holt repo get {s} && {s}", .{ try ui.printable(a, try ui.shellQuote(a, o)), purge });
            break :blk try std.fmt.allocPrint(a, "with its clone back at {s}, run: {s}", .{ try util.q(ctx, at), purge });
        };
        try w.print("note: {s} was released but its kept copy remains; once every machine has synced (records from: {s}), remove it ({s})\n", .{ try util.q(ctx, try layout.copyPath(a, rel.key, rel.rel)), if (rel.machines.len == 0) "none" else aw.written(), cmd });
    }
    for (r.orphans) |o| {
        try w.print("note: {s} has no clone here, and {s} shares its history: same history - renamed, transferred, or a fork (run: holt keep --from {s} {s})\n", .{ o.key, try util.q(ctx, o.clone), try ui.shellQuote(a, o.key), try util.q(ctx, o.clone) });
    }
    for (r.suspected_conflicts) |p| try w.print("note: {s} looks like a cloud conflict copy; merge what you need, then delete it\n", .{try util.q(ctx, p)});
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "good", repos, .empty);

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
    try testing.expect(std.mem.indexOf(u8, before.out, "no symlinks under projects/archive/kept: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, before.out, "markers parse: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, before.out, "clones present: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, before.out, "hub drift: FAIL") != null);

    const after = try testutil.runCmd(arena, command.run, ws, &.{"--fix"});
    try testing.expectEqual(@as(u8, 1), after.code);
    // Hub drift is now resolved...
    try testing.expect(std.mem.indexOf(u8, after.out, "hub drift: PASS") != null);
    // ...but the rest are untouched: still failing.
    try testing.expect(std.mem.indexOf(u8, after.out, "no symlinks under projects/archive/kept: FAIL") != null);
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .empty, .empty);
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
    try testing.expect(std.mem.indexOf(u8, before.out, try fsutil.contractTilde(arena, app.envOf_current(), temp)) != null);

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

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .empty, .empty);

    // doctor treats an unbuilt hub as drift (correctly), so the hub has to
    // be built first for this workspace to actually be clean.
    // No docs/assets/links content dirs: `holt project new` leaves them empty and
    // cloud backends drop empty directories, so a healthy synced workspace
    // routinely has dangling content links. That must still pass doctor.
    const content_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "empty" });
    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "empty" });
    const m = try marker.load(arena, try std.fs.path.join(arena, &.{ content_path, marker.marker_basename }), null);
    const p: project_mod.Project = .{ .org = "acme", .name = "empty", .content_path = content_path, .hub_path = hub_path, .marker = m };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no symlinks under projects/archive/kept: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "code is outside the synced folder: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "hub is outside the synced folder: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "dangling hub links: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "no archive/active shadow: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "no orphaned content: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "aliases valid: PASS") != null);

    const want_backend_line = try std.fmt.allocPrint(arena, "backend: (direct synced_root) -> {s} [exists]\n", .{try fsutil.contractTilde(arena, app.envOf_current(), ws.cfg.synced_root)});
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

    const want_backend_line = try std.fmt.allocPrint(arena, "backend: dropbox -> {s} [missing]\n", .{try fsutil.contractTilde(arena, app.envOf_current(), ws.cfg.synced_root)});
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

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .empty, .empty);

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "remote", remote_repos, .empty);

    var local_repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try local_repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "scratchy", local_repos, .empty);

    // --fix builds each hub before the dangling scan runs, so a single pass
    // both materializes the links and reports them dead.
    const got = try testutil.runCmd(arena, command.run, ws, &.{"--fix"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "dangling hub links: FAIL") != null);

    const remote_target = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "sakakibara", "holt" });
    const remote_line = try std.fmt.allocPrint(arena, "{s} (hint: holt restore)", .{try fsutil.contractTilde(arena, app.envOf_current(), remote_target)});
    try testing.expect(std.mem.indexOf(u8, got.out, remote_line) != null);

    const local_target = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "scratch" });
    const local_line = try std.fmt.allocPrint(arena, "{s} (hint: re-adopt the clone)", .{try fsutil.contractTilde(arena, app.envOf_current(), local_target)});
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

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "dup", .empty, .empty);
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "dup", .empty, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no archive/active shadow: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/dup (hint: holt project remove acme/dup for the active one, or delete its archive dir)") != null);
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "real", .empty, .empty);
    const leftover = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "leftover" });
    try fsutil.ensureDir(leftover);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no orphaned content: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, try fsutil.contractTilde(arena, app.envOf_current(), leftover)) != null);
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

    try testutil.writeMarker(arena, proot, "acme", "real", .empty, .empty);

    // A name-level conflict copy (marker and all) and a whole-org conflict copy.
    try testutil.writeMarkerAs(arena, proot, "acme", "real (conflicted copy 2024-01-01)", "acme", "real", .empty, .empty);
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, aliases);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "aliases valid: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/proj: alias \"ghost\" has no such member") != null);
}

test "run: a member whose alias value is unusable is reported, not silently skipped" {
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
    try aliases.put(arena, "holt", "../evil");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, aliases);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "aliases valid: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/proj: unusable alias value for \"holt\"") != null);
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, aliases);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "dup", .empty, .empty);
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "dup", .empty, .empty);

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

test "run: a local clone that has grown an origin fails, hinted promote when claimed and adopt when not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "claimed", "local:claimed");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_root = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local" });
    try fsutil.ensureDir(local_root);
    for ([_][2][]const u8{
        .{ "claimed", "https://holt-test.invalid/acme/claimed" },
        .{ "stray", "https://holt-test.invalid/acme/stray" },
        .{ "plain", "" },
    }) |c| {
        const path = try std.fs.path.join(arena, &.{ local_root, c[0] });
        try testutil.runGit(&sb, null, &.{ "clone", bare, path });
        if (c[1].len == 0) {
            try testutil.runGit(&sb, path, &.{ "remote", "remove", "origin" });
        } else {
            try testutil.runGit(&sb, path, &.{ "remote", "set-url", "origin", c[1] });
        }
    }

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no local repos with an origin: FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "claimed -> holt-test.invalid/acme/claimed (hint: holt repo promote claimed)") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "stray -> holt-test.invalid/acme/stray (hint: holt repo adopt ") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "plain ->") == null);
    try testing.expect(std.mem.indexOf(u8, got.out, "note: 1 local repo(s) have no remote") != null);
}

test "run: local clones without an origin pass the local-origin check and are noted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "claimed", "local:claimed");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    for ([_][]const u8{ "scratch", "claimed" }) |name| {
        const path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", name });
        try testutil.seedMinimalGitClone(arena, &sb.git_env, path);
    }

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expect(std.mem.indexOf(u8, got.out, "no local repos with an origin: PASS") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "note: 2 local repo(s) have no remote") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, std.fs.path.sep_str ++ "claimed (member of acme/proj)\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, std.fs.path.sep_str ++ "scratch\n") != null);
}

test "run: remoteless local clones alone never fail doctor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "scratch" });
    try testutil.seedMinimalGitClone(arena, &sb.git_env, path);

    const report = try doctor.run(arena, &ws, .{});
    try testing.expectEqual(@as(usize, 1), report.remoteless_locals.len);
    try testing.expect(report.ok());
}

test "run: --fix links a kept file that is missing its link, and never touches a differing local copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_hooks.TestBed.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const key = "github.com/acme/widget";
    const c = try bed.clone(key);
    try bed.write(c, "a.txt", "a");
    try bed.write(c, "b.txt", "b");
    try bed.keep(c, "a.txt");
    try bed.keep(c, "b.txt");
    try bed.remove(c, "a.txt");
    try bed.remove(c, "b.txt");
    try bed.write(c, "b.txt", "b edited");
    const aside_dir = try std.fs.path.join(arena, &.{ bed.ws.cfg.synced_root, "kept", ".holt-aside" });
    const aside_before = try kept_hooks.snapshot(arena, aside_dir, null);

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{"--fix"});
    try testing.expect(try bed.linked(c, key, "a.txt"));
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "linked {s}\n", .{try bed.shown(try std.fs.path.join(arena, &.{ c, "a.txt" }))})) != null);
    try testing.expectEqualStrings("b edited", try bed.read(c, "b.txt"));
    try testing.expect(!try bed.linked(c, key, "b.txt"));
    try testing.expectEqualStrings("b", try kept.content.readSmall(arena, try (kept.store.Layout{ .synced_root = bed.ws.cfg.synced_root }).copyPath(arena, key, "b.txt")));
    try testing.expectEqualStrings(aside_before, try kept_hooks.snapshot(arena, aside_dir, null));
    const b_shown = try bed.shown(try std.fs.path.join(arena, &.{ c, "b.txt" }));
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "linked {s}\n", .{b_shown})) == null);
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "  {s}: local copy differs from the kept copy", .{b_shown})) != null);

    const plain = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expect(std.mem.indexOf(u8, plain.out, "linked ") == null);
}

test "run: --fix judges the kept files after its repairs, so what it just linked passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    try std.Io.Dir.cwd().deleteFile(fsutil.io(), try fsutil.joinSlashy(arena, w.clone, ".clasp.json"));

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"--fix"});
    try testing.expect(has(got.out, "linked "));
    try testing.expect(has(got.out, "kept files linked: PASS\n"));
    try testing.expectEqual(@as(u8, 0), got.code);
}

const kept = @import("../kept.zig");
const kept_cmd = @import("../kept_cmd.zig");

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// `path` as a hint prints it (`ui.quotePath`).
fn quoted(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return ui.quotePath(a, app.envOf_current(), path);
}

/// A kept world whose hub is built, so only kept findings can fail.
fn keptWorld(a: std.mem.Allocator, sb: *testutil.Sandbox, with_store: bool) !kept_cmd.TestWorld {
    const w = try kept_cmd.TestWorld.init(a, sb, with_store);
    for (try w.ws.list(a)) |p| _ = try hub.reconcile(a, &w.ws, &p, false);
    return w;
}

fn firstAside(a: std.mem.Allocator, synced: []const u8) ![]const u8 {
    const dir = try std.fs.path.join(a, &.{ synced, "kept", ".holt-aside" });
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), dir, .{ .iterate = true });
    defer d.close(fsutil.io());
    var it = d.iterate();
    while (try it.next(fsutil.io())) |e| if (e.kind == .directory) return std.fs.path.join(a, &.{ dir, e.name });
    return error.NoAside;
}

test "run: kept checks pass on a healthy kept path, and note the aside, naming --prune-aside once its entry is 30 days old" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(has(got.out, "kept files linked: PASS\n"));
    try testing.expect(has(got.out, "kept store valid: PASS\n"));
    try testing.expect(has(got.out, "tracked kept path: PASS\n"));
    try testing.expect(has(got.out, "no symlinks under projects/archive/kept: PASS\n"));
    try testing.expect(has(got.out, "note: aside holds 1 entry, "));
    try testing.expect(!has(got.out, "--prune-aside"));

    try testutil.ageAsideEntries(arena, w.ws.cfg.synced_root);
    const aged = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(aged.out, "; 1 can be removed (run: holt keep --prune-aside)\n"));
}

test "run: the aside note names --prune-aside only while an entry can be removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, "local.json", "{}\n");
    const p = try fsutil.joinSlashy(arena, w.clone, "local.json");
    try fsutil.removePath(p);
    _ = try w.write(arena, "local.json", "{\"mine\": 1}\n");
    const c = try w.ctx(arena);
    var index = try kept.store.loadIndex(arena, c.layout);
    _ = try kept.reconcile.reconcile(c, &index, w.clone, .apply);

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(got.out, "note: aside holds "));
    try testing.expect(!has(got.out, "--prune-aside"));
}

test "run: kept files linked fails for a link gone, a local copy that differs, and a link git does not ignore" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    try w.keep(arena, "local.json", "{}\n");
    try w.keep(arena, "shown.json", "{}\n");

    try fsutil.removePath(try fsutil.joinSlashy(arena, w.clone, ".clasp.json"));
    try fsutil.removePath(try fsutil.joinSlashy(arena, w.clone, "local.json"));
    _ = try w.write(arena, "local.json", "{\"changed\":1}\n");
    const exclude = try std.fs.path.join(arena, &.{ w.clone, ".git", "info", "exclude" });
    const text = try kept.content.readSmall(arena, exclude);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = exclude, .data = try std.mem.concat(arena, u8, &.{ text, "!/shown.json\n" }) });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(has(got.out, "kept files linked: FAIL\n"));
    const clasp = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, ".clasp.json"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: not linked yet (run: holt sync)\n", .{clasp})));
    const local = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, "local.json"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: local copy differs from the kept copy (run: holt keep --take-local {s}, or holt keep --take-kept {s})\n", .{ local, local, local })));
    const shown = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, "shown.json"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: git does not ignore holt's link, so it could be committed; a .gitignore negation may include it (run: git -C {s} check-ignore --no-index -v -- shown.json)\n", .{ shown, try quoted(arena, w.clone) })));
    try testing.expect(has(got.out, "kept store valid: PASS\n"));
    try testing.expect(fsutil.exists(try fsutil.joinSlashy(arena, w.clone, "local.json")));
    try testing.expect(try kept.content.entryAt(try fsutil.joinSlashy(arena, w.clone, ".clasp.json")) == .absent);
}

test "run: kept store valid fails on unknown files, conflict copies, unknown versions, a tampered aside, and a tracked link into kept/, but never on an org named kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");

    const layout: kept.store.Layout = .{ .synced_root = w.ws.cfg.synced_root };
    const key_dir = try layout.keyDir(arena, w.key);
    const kept_dir = try layout.keptDir(arena);
    const stray = try std.fs.path.join(arena, &.{ key_dir, "stray.txt" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = stray, .data = "x" });
    const loose = try std.fs.path.join(arena, &.{ kept_dir, "loose.txt" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = loose, .data = "x" });
    const copy = try std.fs.path.join(arena, &.{ kept_dir, ".holt-skip (1)" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = copy, .data = "x" });
    const key_copy = try std.fs.path.join(arena, &.{ key_dir, ".holt-kept (conflicted copy).json" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = key_copy, .data = "{}" });
    const other_key = try layout.keyDir(arena, "github.com/acme/future");
    try fsutil.ensureDir(other_key);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ other_key, kept.store.record_basename }), .data = "{\"version\": 99}\n" });

    const entry = try firstAside(arena, w.ws.cfg.synced_root);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ entry, "data", ".clasp.json" }), .data = "tampered" });

    const committed = try fsutil.joinSlashy(arena, w.clone, "committed-link");
    try kept.content.createLink(try w.keptPath(arena, ".clasp.json"), committed, .file);
    try testutil.runGit(&sb, w.clone, &.{ "add", "committed-link" });
    try testutil.runGit(&sb, w.clone, &.{ "commit", "-qm", "oops" });

    const org = try std.fs.path.join(arena, &.{ w.ws.cfg.synced_root, "projects", "kept" });
    try fsutil.ensureDir(org);

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(has(got.out, "kept store valid: FAIL\n"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: unknown file in the kept store", .{try quoted(arena, stray)})));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: unknown file in the kept store", .{try quoted(arena, loose)})));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: a cloud conflict copy of a holt file", .{try quoted(arena, copy)})));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: a cloud conflict copy of a holt file", .{try quoted(arena, key_copy)})));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: its record has a version this holt does not know, so holt never writes to it (run: holt upgrade)\n", .{try quoted(arena, other_key)})));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: aside entry no longer matches its manifest\n", .{try quoted(arena, entry)})));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: a tracked symlink into kept/", .{try quoted(arena, committed)})));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "(run: git -C {s} rm --cached -- committed-link)\n", .{try quoted(arena, w.clone)})));
    try testing.expect(!has(got.out, try quoted(arena, org)));
    try testing.expect(fsutil.exists(stray) and fsutil.exists(copy));
}

test "run: an online-only stand-in for a kept copy is a placeholder, not an unknown file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, "local.json", "{}\n");

    const kc = try w.keptPath(arena, "local.json");
    try fsutil.removePath(kc);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ std.fs.path.dirname(kc).?, ".local.json.icloud" }), .data = "" });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: online-only on this machine; open it to download it\n", .{try quoted(arena, kc)})));
    try testing.expect(!has(got.out, "unknown file in the kept store"));
}

test "run: a kept path the upstream default branch tracks fails, and is skipped once origin/HEAD is unset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, "conf/local.json", "{}\n");

    const other = try std.fs.path.join(arena, &.{ sb.root, "other-clone" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", w.bare, other });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ other, "conf" }));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ other, "conf", "local.json" }), .data = "{}\n" });
    try testutil.runGit(&sb, other, &.{ "add", "conf/local.json" });
    try testutil.runGit(&sb, other, &.{ "commit", "-qm", "track it upstream" });
    try testutil.runGit(&sb, other, &.{ "push", "-q", "origin", "main" });
    try testutil.runGit(&sb, w.clone, &.{ "fetch", "-q" });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    const p = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, "conf/local.json"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "tracked kept path: FAIL\n  {s}: tracked on the upstream default branch (run: holt unkeep {s})\n", .{ p, p })));

    try testutil.runGit(&sb, w.clone, &.{ "remote", "set-head", "origin", "-d" });
    const unset = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(unset.out, "tracked kept path: PASS\n"));
}

test "run: an auto-pattern match a .gitignore negation un-ignores is noted with that line and no keep" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    const ignore = try w.write(arena, "neg/.gitignore", "*.json\n!.clasp.json\n");
    const auto = try w.write(arena, "neg/.clasp.json", "{}\n");

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    const line = try std.fmt.allocPrint(arena, "{s}:2:!.clasp.json", .{try fsutil.contractTilde(arena, app.envOf_current(), ignore)});
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "note: {s}: matches an auto pattern (.clasp.json) but {s} un-ignores it, so holt cannot keep it; remove or narrow that line, or leave it for a commit\n", .{ try quoted(arena, auto), line })));
    try testing.expect(!has(got.out, "holt keep "));
}

test "run: notes candidates, an auto-pattern match git does not ignore, a released path still holding content, an orphan key, and a suspected conflict copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, "notes", "");
    try fsutil.removePath(try fsutil.joinSlashy(arena, w.clone, "notes"));
    try fsutil.ensureDir(try fsutil.joinSlashy(arena, w.clone, "docs-local"));
    _ = try w.write(arena, "docs-local/a.md", "a\n");
    _ = try w.write(arena, "docs-local/a (1).md", "a2\n");
    const c = try w.ctx(arena);
    {
        const index = try kept.store.loadIndex(arena, c.layout);
        _ = try kept.place.keepPath(c, &index, w.clone, "docs-local", .{});
    }
    try w.keep(arena, "old.json", "{}\n");
    const layout = c.layout;
    try kept.store.writeReleased(arena, layout, w.key, "old.json");

    const exclude = try std.fs.path.join(arena, &.{ w.clone, ".git", "info", "exclude" });
    const text = try kept.content.readSmall(arena, exclude);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = exclude, .data = try std.mem.concat(arena, u8, &.{ text, ".env\n" }) });
    _ = try w.write(arena, ".env", "S=1\n");
    _ = try w.write(arena, "sub/.clasp.json", "{}\n");

    const roots = try kept.clone.rootCommits(arena, w.clone);
    const old_key = "github.com/acme/old-widget";
    const old_dir = try layout.keyDir(arena, old_key);
    try fsutil.ensureDir(old_dir);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ old_dir, kept.store.record_basename }), .data = try std.fmt.allocPrint(arena, "{{\"version\": 1, \"root\": \"{s}\"}}\n", .{roots[0]}) });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ old_dir, "legacy.json" }), .data = "{}" });
    try kept.store.writeFact(arena, layout, old_key, "00000000000000ff", "legacy.json", .file, &(try kept.content.hashFile(arena, try std.fs.path.join(arena, &.{ old_dir, "legacy.json" }))));

    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ w.hub, "todo.md" }), .data = "t\n" });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    const clone_q = try quoted(arena, w.clone);
    const hub_q = try quoted(arena, w.hub);
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "note: 2 files not kept in 1 repo and 1 hub root (run: holt keep --review --all):\n  {s}: 1 (run: holt keep --review {s})\n  {s}: 1 (run: holt keep --review {s})\n", .{ clone_q, clone_q, hub_q, hub_q })));
    const auto = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, "sub/.clasp.json"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "note: {s}: matches an auto pattern (.clasp.json) but git does not ignore it; add it to .gitignore, or keep it (run: holt keep {s})\n", .{ auto, auto })));
    const released = try quoted(arena, try w.keptPath(arena, "old.json"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "note: {s} was released but its kept copy remains; once every machine has synced (records from: {s} (this machine)), remove it (run: holt unkeep --purge {s} --yes)\n", .{ released, c.machine_id, try quoted(arena, try fsutil.joinSlashy(arena, w.clone, "old.json")) })));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "note: github.com/acme/old-widget has no clone here, and {s} shares its history: same history - renamed, transferred, or a fork (run: holt keep --from github.com/acme/old-widget {s})\n", .{ clone_q, clone_q })));
    const suspect = try quoted(arena, try fsutil.joinSlashy(arena, try w.keptPath(arena, "docs-local"), "a (1).md"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "note: {s} looks like a cloud conflict copy; merge what you need, then delete it\n", .{suspect})));
}

test "run: without kept/, a clone whose links point into another synced root fails with the copy hint alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");

    var moved = w.ws;
    moved.cfg.synced_root = try std.fs.path.join(arena, &.{ sb.root, "new-synced" });
    try fsutil.copyTree(arena, try std.fs.path.join(arena, &.{ w.ws.cfg.synced_root, "projects" }), try std.fs.path.join(arena, &.{ moved.cfg.synced_root, "projects" }));
    for (try moved.list(arena)) |p| _ = try hub.reconcile(arena, &moved, &p, false);

    const got = try testutil.runCmd(arena, command.run, moved, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(has(got.out, "kept files linked: FAIL\n"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  kept/ is at {s}: copy it to {s}\n", .{ try quoted(arena, w.ws.cfg.synced_root), try quoted(arena, moved.cfg.synced_root) })));
    try testing.expect(!has(got.out, "kept/ is missing"));
    try testing.expect(has(got.out, "kept store valid: PASS\n"));
}

test "run: without kept/ and with no clone holding kept-file links, the kept checks pass and load nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, false);
    defer w.deinit();
    _ = try w.write(arena, ".env", "S=1\n");

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(has(got.out, "kept files linked: PASS\nkept store valid: PASS\ntracked kept path: PASS\n"));
    try testing.expect(!has(got.out, "note: "));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ sb.root, "state" })));
}

test "run: a clone that does not match its local/ key fails kept store valid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();

    const local = try std.fs.path.join(arena, &.{ w.ws.cfg.code_root, "local", "scratch" });
    try testutil.seedMinimalGitClone(arena, &sb.git_env, local);
    const layout: kept.store.Layout = .{ .synced_root = w.ws.cfg.synced_root };
    const key_dir = try layout.keyDir(arena, "local/scratch");
    try fsutil.ensureDir(key_dir);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ key_dir, kept.store.record_basename }), .data = "{\"version\": 1, \"root\": \"" ++ "0" ** 40 ++ "\"}\n" });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(has(got.out, "kept store valid: FAIL\n"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: does not match the local/ key local/scratch (a different repo, or its record has not arrived); give this clone another directory name and run holt repo adopt on it there, or, if that repo is gone, release its kept files (run: holt unkeep --repo local/scratch)\n", .{try quoted(arena, local)})));
}

test "run: every working tree is judged: a linked tree's missing link and hidden content, and a moved tree's record" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");

    const linked = try std.fmt.allocPrint(arena, "{s}@worktrees/feat", .{w.clone});
    try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "feat", linked });
    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    const lq = try quoted(arena, try fsutil.joinSlashy(arena, linked, ".clasp.json"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: not linked yet (run: holt sync)\n", .{lq})));

    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(arena, linked, ".clasp.json"), .data = "{\"only\":\"here\"}\n" });
    const hidden = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(hidden.out, try std.fmt.allocPrint(arena, "  {s}: local copy differs from the kept copy", .{lq})));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, hidden.out, lq) - 2);

    const moved = try std.fmt.allocPrint(arena, "{s}@worktrees/moved", .{w.clone});
    try std.Io.Dir.cwd().rename(linked, std.Io.Dir.cwd(), moved, fsutil.io());
    const gone = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), gone.code);
    const cq = try quoted(arena, w.clone);
    const wq = try quoted(arena, linked);
    const rq = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, ".git/worktrees/feat"));
    try testing.expect(has(gone.out, try std.fmt.allocPrint(arena, ", or git -C {s} worktree remove {s})\n", .{ cq, wq })));
    if (ui.native_shell == .posix) try testing.expect(has(gone.out, try std.fmt.allocPrint(arena, "(run: mkdir -p {s} && printf 'gitdir: %s\\n' {s} > {s} && git -C {s} checkout-index -a, or ", .{ wq, rq, try quoted(arena, try std.fs.path.join(arena, &.{ linked, ".git" })), wq })));
    try testing.expect(!has(gone.out, "worktree repair") and !has(gone.out, "worktree prune"));
}

test "run: a worktree holt worktree made whose directory is gone and whose record holds staged changes is offered no git worktree remove but holt worktree -r, which refuses it, and bringing it back settles it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const proc = @import("../proc.zig");
    const worktree_cmd = @import("worktree.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    const linked = try std.fmt.allocPrint(arena, "{s}@worktrees/feat", .{w.clone});
    try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "feat", linked });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ linked, "staged.txt" }), .data = "only in the index\n" });
    try testutil.runGit(&sb, linked, &.{ "add", "staged.txt" });
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), linked);

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    const lead = "a working tree that cannot be read (absent)";
    const at = std.mem.indexOf(u8, got.out, lead) orelse {
        std.debug.print("wanted {s} in:\n{s}\n", .{ lead, got.out });
        return error.TestUnexpectedResult;
    };
    const line = got.out[at..std.mem.indexOfScalarPos(u8, got.out, at, '\n').?];
    try testing.expect(!has(got.out, " worktree remove ") and !has(got.out, "worktree prune"));
    const holt = ", or holt worktree acme/proj/widget feat -r)";
    try testing.expect(std.mem.endsWith(u8, line, holt));
    const refused = try testutil.runCmd(arena, worktree_cmd.command.run, w.ws, &.{ "acme/proj/widget", "feat", "-r" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(has(refused.err, "staged changes only "));
    const open = std.mem.indexOf(u8, line, "(run: ").? + "(run: ".len;
    const relink = line[open .. line.len - holt.len];
    const res = try proc.runEnv(arena, &.{ "sh", "-c", relink }, null, &sb.git_env.map);
    try testing.expectEqual(@as(u8, 0), res.status);
    const after = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(!has(after.out, lead));
    try testing.expectEqualStrings("only in the index\n", try kept.content.readSmall(arena, try std.fs.path.join(arena, &.{ linked, "staged.txt" })));
}

test "run: a kept path this branch tracks is information, never a failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    try testutil.runGit(&sb, w.clone, &.{ "remote", "set-head", "origin", "-d" });

    try fsutil.removePath(try fsutil.joinSlashy(arena, w.clone, ".clasp.json"));
    _ = try w.write(arena, ".clasp.json", "{\"tracked\":1}\n");
    try testutil.runGit(&sb, w.clone, &.{ "add", "-f", ".clasp.json" });
    try testutil.runGit(&sb, w.clone, &.{ "commit", "-qm", "track it" });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(got.out, "kept files linked: PASS\n"));
    try testing.expect(has(got.out, "tracked kept path: PASS\n"));
}

fn noReportScratch(a: std.mem.Allocator, sb: *testutil.Sandbox) !bool {
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), try std.fs.path.join(a, &.{ sb.root, "tmp" }), .{ .iterate = true });
    defer d.close(fsutil.io());
    var it = d.iterate();
    while (try it.next(fsutil.io())) |e| if (std.mem.startsWith(u8, e.name, "holt-report-")) return false;
    return true;
}

test "run: a key directory whose record has not arrived is reported, never hinted for deletion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    const layout: kept.store.Layout = .{ .synced_root = w.ws.cfg.synced_root };
    const other = try layout.keyDir(arena, "github.com/acme/other");
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ other, ".holt-paths", "ab" }));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ other, ".env" }), .data = "SECRET=1\n" });
    const bare = try layout.keyDir(arena, "gitlab.com/acme/lagging");
    try fsutil.ensureDir(bare);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ bare, "notes.md" }), .data = "n\n" });
    const nested = try std.fs.path.join(arena, &.{ try layout.keyDir(arena, w.key), "sub" });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ nested, ".holt-paths" }));

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(has(got.out, "kept store valid: FAIL\n"));
    for ([_][]const u8{ other, try std.fs.path.join(arena, &.{ w.ws.cfg.synced_root, "kept", "gitlab.com" }), nested }) |p| {
        try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: no key record here yet (not synced, or lost); nothing in it is linked or removed until its .holt-kept.json arrives\n", .{try quoted(arena, p)})));
    }
    try testing.expect(!has(got.out, "delete it"));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ other, ".env" })));
}

test "run: what folders gather on their own is never unknown in kept/, iCloud's stand-ins for holt's files are placeholders, and control characters are escaped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    const layout: kept.store.Layout = .{ .synced_root = w.ws.cfg.synced_root };
    const key_dir = try layout.keyDir(arena, w.key);
    const kept_dir = try layout.keptDir(arena);
    for ([_][]const u8{ kept_dir, try std.fs.path.join(arena, &.{ kept_dir, "holt-test.invalid" }), key_dir, try layout.asideDir(arena) }) |d| {
        for ([_][]const u8{ ".DS_Store", "Icon\r", "desktop.ini", "Thumbs.db", ".directory" }) |n| {
            try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ d, n }), .data = "x" });
        }
        try fsutil.ensureDir(try std.fs.path.join(arena, &.{ d, "@eaDir", "x" }));
        try fsutil.ensureDir(try std.fs.path.join(arena, &.{ d, ".Trash-1000", "files" }));
    }
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ kept_dir, ".stversions" }));
    const clean = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 0), clean.code);
    try testing.expect(has(clean.out, "kept store valid: PASS\n"));

    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ kept_dir, "..holt-skip.icloud" }), .data = "x" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ key_dir, "..holt-paths.icloud" }), .data = "x" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ key_dir, "bad\x1b[31mname" }), .data = "x" });
    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    for ([_][]const u8{ try std.fs.path.join(arena, &.{ kept_dir, ".holt-skip" }), try std.fs.path.join(arena, &.{ key_dir, ".holt-paths" }) }) |p| {
        try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: online-only on this machine; open it to download it\n", .{try quoted(arena, p)})));
    }
    try testing.expect(!has(got.out, ".icloud"));
    try testing.expect(!has(got.out, "\x1b"));
    try testing.expect(has(got.out, "bad\\x1b[31mname': unknown file in the kept store"));
}

test "run: doctor writes nothing in holt's machine-local state, leaves no scratch, and names this machine only once its id exists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, "old.json", "{}\n");
    try kept.store.writeReleased(arena, .{ .synced_root = w.ws.cfg.synced_root }, w.key, "old.json");
    const exclude = try std.fs.path.join(arena, &.{ w.clone, ".git", "info", "exclude" });
    const text = try kept.content.readSmall(arena, exclude);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = exclude, .data = try std.mem.concat(arena, u8, &.{ text, ".env\n" }) });
    _ = try w.write(arena, ".env", "S=1\n");
    const state = try std.fs.path.join(arena, &.{ sb.root, "state" });
    const saved = try std.fs.path.join(arena, &.{ sb.root, "state-saved" });
    try fsutil.copyTree(arena, state, saved);
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), state);

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(got.out, "note: 1 file not kept in 1 repo (run: holt keep --review --all):\n"));
    try testing.expect(has(got.out, " was released but its kept copy remains"));
    try testing.expect(!has(got.out, "(this machine)"));
    try testing.expect(!fsutil.exists(state));
    try testing.expect(try noReportScratch(arena, &sb));

    try fsutil.copyTree(arena, saved, state);
    const again = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(again.out, " (this machine)"));
}

test "run: doctor and status never wait on a writer's locks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    try fsutil.removePath(try fsutil.joinSlashy(arena, w.clone, ".clasp.json"));
    const c = try w.ctx(arena);
    const cl = try kept.clone.inspect(arena, w.clone, c.code_root);
    const clone_lock = try kept.lockClone(c, cl.common_dir);
    defer clone_lock.release();
    const key_lock = try kept.lockKey(c, w.key);
    defer key_lock.release();
    @import("../kept/ctx.zig").lock_nonblocking_for_test = true;
    defer @import("../kept/ctx.zig").lock_nonblocking_for_test = false;

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(!has(got.out, "WouldBlock"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: not linked yet (run: holt sync)\n", .{try quoted(arena, try fsutil.joinSlashy(arena, w.clone, ".clasp.json"))})));
    const st = try testutil.runCmd(arena, @import("status.zig").command.run, w.ws, &.{});
    try testing.expect(!has(st.err, "WouldBlock"));
    try testing.expect(has(st.out, "1 not linked (run: holt sync)\n"));
}

test "run: a clone with no key is information: one outside a repo's path, and one whose core.worktree points elsewhere" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    const odd = try std.fs.path.join(arena, &.{ w.ws.cfg.code_root, "scratch" });
    try testutil.seedMinimalGitClone(arena, &sb.git_env, odd);
    const elsewhere = try std.fs.path.join(arena, &.{ w.ws.cfg.code_root, "local", "moved" });
    try testutil.seedMinimalGitClone(arena, &sb.git_env, elsewhere);
    const tree = try std.fs.path.join(arena, &.{ sb.root, "tree-elsewhere" });
    try fsutil.ensureDir(tree);
    try testutil.runGit(&sb, elsewhere, &.{ "config", "core.worktree", tree });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(got.out, "kept files linked: PASS\n"));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "note: {s}: not at a repo's path under the code root (<host>/<owner>/<repo> or local/<name>), so it has no kept files\n", .{try quoted(arena, odd)})));
    try testing.expect(has(got.out, ": core.worktree points elsewhere, so this clone has no key\n"));
    try testing.expect(!has(got.out, "not under the code root"));
}

test "run: a kept path whose parent is a symlink or a file fails, naming what is there and how to put a directory back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, "conf/a.json", "{}\n");
    const conf = try fsutil.joinSlashy(arena, w.clone, "conf");
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), conf);
    const elsewhere = try std.fs.path.join(arena, &.{ sb.root, "elsewhere" });
    try fsutil.ensureDir(elsewhere);
    try fsutil.replaceSymlink(elsewhere, conf);
    const cq = try quoted(arena, conf);
    const aq = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, "conf/a.json"));

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    const want = try std.fmt.allocPrint(arena, "  {s}: its parent {s} is a symlink (-> {s}), where a directory belongs; remove the link and sync to make one (run: rm {s} && holt sync)\n", .{ aq, cq, elsewhere, cq });
    try testing.expect(has(got.out, "kept files linked: FAIL\n"));
    try testing.expect(has(got.out, want));
    const st = try testutil.runCmd(arena, @import("status.zig").command.run, w.ws, &.{});
    try testing.expect(has(st.out, want[2..]));
    try testing.expect(!has(st.out, "not judged"));

    try fsutil.removePath(conf);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = conf, .data = "only here\n" });
    const file = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(file.out, try std.fmt.allocPrint(arena, "  {s}: its parent {s} is a file, where a directory belongs; move the file elsewhere, then sync to make the directory (run: holt sync)\n", .{ aq, cq })));
}

test "run: nested repositories print under their own note, and a holt link committed to the branch is reported once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    try testutil.runGit(&sb, w.clone, &.{ "remote", "set-head", "origin", "-d" });
    _ = try w.write(arena, ".gitignore", "vendor/\n");
    try testutil.runGit(&sb, w.clone, &.{ "add", ".gitignore" });
    try testutil.runGit(&sb, w.clone, &.{ "add", "-f", ".clasp.json" });
    try testutil.runGit(&sb, w.clone, &.{ "commit", "-qm", "oops" });
    const nested = try fsutil.joinSlashy(arena, w.clone, "vendor/lib");
    try testutil.seedMinimalGitClone(arena, &sb.git_env, nested);

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "note: 1 nested repository; nothing in one can be kept, so push each or move it out of the clone:\n  {s}\n", .{try quoted(arena, nested)})));
    const link = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, ".clasp.json"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, try std.fmt.allocPrint(arena, "  {s}: ", .{link})));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: a tracked symlink into kept/", .{link})));
}

test "run: a purged path the next sync restores from aside names the entry, and a purge whose aside entry has not arrived fails until it does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".env", "E=1\n");
    const stamp = try w.purgeElsewhere(arena, ".env");
    const p = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, ".env"));

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "  {s}: purged on another machine; sync restores a local copy from aside entry {s} (run: holt sync)\n", .{ p, stamp })));

    const layout: kept.store.Layout = .{ .synced_root = w.ws.cfg.synced_root };
    const entry = try std.fs.path.join(arena, &.{ try layout.asideDir(arena), stamp });
    const away = try std.fs.path.join(arena, &.{ sb.root, "away" });
    try std.Io.Dir.renameAbsolute(entry, away, fsutil.io());
    const pending = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 1), pending.code);
    try testing.expect(has(pending.out, try std.fmt.allocPrint(arena, "  {s}: purged on another machine; its aside entry {s} has not arrived yet; sync once your cloud client downloads it (run: holt sync)\n", .{ p, stamp })));
    const waiting = try testutil.runCmd(arena, @import("sync.zig").command.run, w.ws, &.{});
    try testing.expect(has(waiting.out, "has not arrived yet"));
    try testing.expectEqual(kept.content.Entry.symlink, try kept.content.entryAt(try fsutil.joinSlashy(arena, w.clone, ".env")));

    try std.Io.Dir.renameAbsolute(away, entry, fsutil.io());
    _ = try testutil.runCmd(arena, @import("sync.zig").command.run, w.ws, &.{});
    try testing.expectEqualStrings("E=1\n", try kept.content.readSmall(arena, try fsutil.joinSlashy(arena, w.clone, ".env")));
    const clean = try testutil.runCmd(arena, command.run, w.ws, &.{});
    try testing.expect(!has(clean.out, "kept files linked: FAIL"));
}

test "run: a released path of a key with no clone here names the clone to get and the path to purge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try keptWorld(arena, &sb, true);
    defer w.deinit();
    const layout: kept.store.Layout = .{ .synced_root = w.ws.cfg.synced_root };
    const key = "github.com/acme/gone";
    const dir = try layout.keyDir(arena, key);
    try fsutil.ensureDir(dir);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ dir, kept.store.record_basename }), .data = "{\"version\": 1, \"origin\": \"https://github.com/acme/gone\"}\n" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "old.json" }), .data = "{}" });
    try kept.store.writeFact(arena, layout, key, "00000000000000ff", "old.json", .file, &(try kept.content.hashFile(arena, try std.fs.path.join(arena, &.{ dir, "old.json" }))));
    try kept.store.writeReleased(arena, layout, key, "old.json");

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{});
    const at = try quoted(arena, try std.fs.path.join(arena, &.{ w.ws.cfg.code_root, "github.com", "acme", "gone", "old.json" }));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "(run: holt repo get 'https://github.com/acme/gone' && holt unkeep --purge {s} --yes)\n", .{at})));
}
