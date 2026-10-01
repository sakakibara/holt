//! `holt status [<project>] [--dirty]`: per-member-repo git status (branch,
//! dirty, unpushed) across one project or, by default, every project. A
//! clone missing from disk is reported as such rather than crashing on the
//! `git` call. `--dirty` narrows the output to only repos with findings.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const common = @import("common.zig");
const git = @import("../git.zig");
const fsutil = @import("../fsutil.zig");
const parallel = @import("../parallel.zig");
const ui = @import("../ui.zig");
const util = @import("kept_util.zig");
const json = @import("json");
const testing = std.testing;
const testutil = @import("../testutil.zig");
const proc = @import("../proc.zig");
const kept = @import("../kept.zig");
const kept_cmd = @import("../kept_cmd.zig");
const kept_hints = @import("kept_hints.zig");
const kept_hooks = @import("kept_hooks.zig");
const doctor_cmd = @import("doctor.zig");

const color_red = "31";
const color_green = "32";
const color_yellow = "33";

/// What status shows of kept files for this run: whether the store is set
/// up and, when it is and git can serve it, the context and key index
/// every clone is judged against.
const KeptView = struct {
    setup: kept_cmd.Setup,
    ctx: ?kept.Ctx = null,
    index: ?kept.store.KeyIndex = null,
    /// Why kept files cannot be judged: the git on PATH is too old, or
    /// this machine's id or the store cannot be read.
    unjudged: ?[]const u8 = null,
    /// The run's own directory for what it hands git (`kept.RunScratch`),
    /// so status writes nothing in holt's machine-local state.
    scratch: ?*kept.RunScratch = null,

    fn load(alloc: std.mem.Allocator, ws: *const workspace.Workspace) !KeptView {
        var v: KeptView = .{ .setup = try kept_cmd.setup(alloc, ws.cfg.synced_root) };
        if (v.setup != .present) return v;
        const scratch = try alloc.create(kept.RunScratch);
        scratch.* = kept.RunScratch.init(alloc, ws.env) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                v.unjudged = try std.fmt.allocPrint(alloc, "cannot judge kept files: {s}", .{@errorName(err)});
                return v;
            },
        };
        v.scratch = scratch;
        const ctx = kept_cmd.reportCtx(alloc, ws, scratch) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                v.unjudged = try std.fmt.allocPrint(alloc, "cannot judge kept files: {s}", .{@errorName(err)});
                return v;
            },
        };
        v.ctx = ctx;
        kept.clone.requireGit(alloc) catch |err| switch (err) {
            error.GitTooOld => {
                v.unjudged = try kept.clone.gitTooOld(alloc);
                return v;
            },
            else => return err,
        };
        v.index = kept.store.loadIndex(alloc, ctx.layout) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                v.unjudged = try std.fmt.allocPrint(alloc, "cannot judge kept files: kept/ cannot be read ({s})", .{@errorName(err)});
                return v;
            },
        };
        return v;
    }

    /// Whether clones are judged: the store is set up and git serves it.
    fn judges(v: KeptView) bool {
        return v.index != null;
    }

    fn deinit(v: *KeptView) void {
        if (v.scratch) |sc| sc.deinit();
    }
};

/// The loose entries of `p`'s hub root: once `kept/` exists, what the skip
/// patterns leave (`kept_cmd.hubLoose`).
fn localOnlyEntries(alloc: std.mem.Allocator, p: project_mod.Project, view: *const KeptView) ![]const []const u8 {
    return kept_cmd.hubLoose(alloc, p.hub_path, if (view.setup == .present) view.ctx else null);
}

/// What kept files look like in one clone: how many of its files are not
/// kept (every working tree's candidates) and how many nested repositories
/// git's listing shows, which working trees and submodules git could not
/// list, which kept paths of its main working tree are not linked, and
/// which paths an auto pattern matches that git does not ignore.
/// `failed` names the error when it could not be judged.
const KeptProbe = struct {
    not_kept: usize = 0,
    /// Files an auto pattern matches that the next `holt sync` keeps,
    /// counted apart from `not_kept`.
    will_keep: usize = 0,
    nested: usize = 0,
    unlisted: []const Unlisted = &.{},
    not_linked: []const kept_cmd.NotLinked = &.{},
    /// Paths an auto pattern matches that git does not ignore, each under
    /// its working tree.
    auto_unignored: []const AutoUnignored = &.{},
    failed: ?[]const u8 = null,
};

const AutoUnignored = struct { path: []const u8, pattern: []const u8, negation: ?kept.clone.Negation = null };

/// A working tree or submodule git could not list, and why: a working
/// tree's record that cannot be swept (`problem`), or git's error.
const Unlisted = struct { path: []const u8, problem: ?kept.clone.TreeProblem = null, detail: ?[]const u8 = null };

const KeptShared = struct { ctx: kept.Ctx, index: *const kept.store.KeyIndex };

/// Judges one clone on a worker thread, allocating only from `arena`. The
/// candidates are listed without the deep walk for nested repositories.
fn keptProbe(shared: *const KeptShared, arena: std.mem.Allocator, clone_path: []const u8) KeptProbe {
    var ctx = shared.ctx;
    ctx.alloc = arena;
    return keptProbeIn(ctx, shared.index, clone_path) catch |err| .{ .failed = @errorName(err) };
}

fn keptProbeIn(ctx: kept.Ctx, index: *const kept.store.KeyIndex, clone_path: []const u8) !KeptProbe {
    const a = ctx.alloc;
    const c = try kept.clone.inspect(a, clone_path, ctx.code_root);
    const all = try kept.candidates.listAll(ctx, index, c, .{ .auto_plan = true });
    var got: KeptProbe = .{};
    var unlisted: std.ArrayList(Unlisted) = .empty;
    var auto: std.ArrayList(AutoUnignored) = .empty;
    for (all.unlisted) |u| try unlisted.append(a, .{ .path = u.worktree, .problem = u.problem, .detail = u.detail });
    for (all.listings) |l| {
        got.not_kept += l.notKept();
        got.will_keep += l.would_auto.len;
        got.nested += l.nested.len;
        for (l.submodules_failed) |sm| try unlisted.append(a, .{ .path = try fsutil.joinSlashy(a, l.worktree, sm), .detail = "git could not list the submodule" });
        for (l.auto_unignored) |u| try auto.append(a, .{ .path = try fsutil.joinSlashy(a, l.worktree, u.rel), .pattern = u.pattern, .negation = u.negation });
    }
    got.unlisted = unlisted.items;
    got.auto_unignored = auto.items;
    got.not_linked = try kept_cmd.notLinked(ctx, index, c);
    return got;
}

/// One `KeptProbe` per distinct present clone of `probed`, keyed by clone
/// path; empty when kept files are not judged.
fn probeKept(alloc: std.mem.Allocator, view: *const KeptView, probed: *const Probed, jobs: ?usize) !std.StringHashMapUnmanaged(KeptProbe) {
    var out: std.StringHashMapUnmanaged(KeptProbe) = .empty;
    if (!view.judges()) return out;
    var clone_paths: std.ArrayList([]const u8) = .empty;
    for (probed.paths, probed.results) |p, res| {
        const st = res catch continue;
        if (st.kind != .ok) continue;
        if (paths_contains(clone_paths.items, p)) continue;
        try clone_paths.append(alloc, p);
    }
    const shared: KeptShared = .{ .ctx = view.ctx.?, .index = &view.index.? };
    const results = try alloc.alloc(KeptProbe, clone_paths.items.len);
    var arenas = try parallel.map(*const KeptShared, []const u8, KeptProbe, keptProbe, alloc, jobs, &shared, clone_paths.items, results);
    defer arenas.deinit();
    for (clone_paths.items, results) |p, r| {
        var copy: KeptProbe = .{ .not_kept = r.not_kept, .will_keep = r.will_keep, .nested = r.nested, .failed = if (r.failed) |f| try alloc.dupe(u8, f) else null };
        var ul: std.ArrayList(Unlisted) = .empty;
        for (r.unlisted) |u| try ul.append(alloc, .{ .path = try alloc.dupe(u8, u.path), .problem = u.problem, .detail = try dupeOpt(alloc, u.detail) });
        copy.unlisted = ul.items;
        var nl: std.ArrayList(kept_cmd.NotLinked) = .empty;
        for (r.not_linked) |x| try nl.append(alloc, .{ .rel = try alloc.dupe(u8, x.rel), .item = if (x.item) |i| try dupeItem(alloc, i) else null, .stop = x.stop });
        copy.not_linked = nl.items;
        var au: std.ArrayList(AutoUnignored) = .empty;
        for (r.auto_unignored) |u| {
            const neg: ?kept.clone.Negation = if (u.negation) |n| .{ .source = try alloc.dupe(u8, n.source), .line = try alloc.dupe(u8, n.line), .pattern = try alloc.dupe(u8, n.pattern) } else null;
            try au.append(alloc, .{ .path = try alloc.dupe(u8, u.path), .pattern = try alloc.dupe(u8, u.pattern), .negation = neg });
        }
        copy.auto_unignored = au.items;
        try out.put(alloc, p, copy);
    }
    return out;
}

fn paths_contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn dupeOpt(alloc: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try alloc.dupe(u8, v) else null;
}

/// `i` with every string it holds copied into `alloc`, off a worker's arena.
fn dupeItem(alloc: std.mem.Allocator, i: kept.reconcile.Item) !kept.reconcile.Item {
    var out = i;
    out.rel = try alloc.dupe(u8, i.rel);
    out.entry = try dupeOpt(alloc, i.entry);
    out.detail = try dupeOpt(alloc, i.detail);
    out.worktree = try dupeOpt(alloc, i.worktree);
    out.skipped = &.{};
    var entries: std.ArrayList([]const u8) = .empty;
    for (i.entries) |e| try entries.append(alloc, try alloc.dupe(u8, e));
    out.entries = entries.items;
    return out;
}

const Spec = struct {
    // org/jobs are options and must be parsed before the positional below: a
    // bare positional scan would otherwise mistake either's value token for
    // the project query.
    org: cli.Opt([]const u8, .{ .value_name = "org", .complete = app.cat(.org), .help = "with no <project> given, only show projects in this org" }),
    jobs: cli.Opt(usize, .{ .short = 'j', .value_name = "N", .help = "probe up to N repos concurrently (default: auto; 1 = serial)" }),
    project: cli.Pos([]const u8, .{ .complete = app.cat(.project), .optional = true, .help = "only show this project's member repos" }),
    dirty: cli.Flag(.{ .help = "only show repos with a finding (dirty, unpushed, missing)" }),
    json: cli.Flag(.{ .help = "emit a JSON array instead of plain text (ignores --dirty)" }),
};

pub const command = app.command(Spec, .{
    .name = "status",
    .summary = "Show git status across a project's (or every project's) member repos",
    .usage = "holt status [<project>] [--dirty] [--org <org>] [--json]",
    .group = .inspect,
    .needs_context = true,
    .details =
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
    \\that cannot be read, which that list leaves out, with what is seen
    \\there and the record's path; each with no command.
    \\
    \\Example:
    \\  holt status myproj --dirty
    ,
}, run);

/// One member repo's inspected state. `branch` (when set) lives in the
/// worker arena that produced it and is valid until the probe's arenas are
/// deinited on the main thread.
const RepoState = struct {
    kind: enum { missing, unreadable, ok },
    branch: ?[]const u8 = null,
    dirty: bool = false,
    unpushed: git.Unpushed = .clean,
};

/// Inspects one clone. Runs on a worker thread with its OWN `arena`; every
/// git call here is safe to invoke concurrently (see parallel.zig).
fn probe(_: void, arena: std.mem.Allocator, clone_path: []const u8) anyerror!RepoState {
    if (!fsutil.exists(clone_path)) return .{ .kind = .missing };
    const st = git.repoStatus(arena, clone_path) catch |err| switch (err) {
        error.NotInspectable => return .{ .kind = .unreadable },
        else => return err,
    };
    return .{ .kind = .ok, .branch = st.branch, .dirty = st.dirty, .unpushed = st.unpushed };
}

const Probe = anyerror!RepoState;

const Skipped = struct { project: []const u8, repo: []const u8 };

const Probed = struct {
    /// Flattened member repos across `targets`, in project-then-repo order.
    repo_names: [][]const u8,
    /// Each member repo's clone path, parallel to `repo_names`.
    paths: [][]const u8,
    /// `bounds[i]` is the exclusive end index into `results`/`repo_names` for
    /// `targets[i]`; `bounds[i-1]` (or 0) is its start.
    bounds: []usize,
    results: []Probe,
    /// Members whose marker value did not resolve - reported, not probed,
    /// so one unusable value costs its own row and nothing else.
    skipped: []Skipped,
    arenas: parallel.Arenas,

    fn deinit(self: *Probed) void {
        self.arenas.deinit();
    }
};

fn reportSkipped(ctx: *app.Ctx, skipped: []const Skipped) !void {
    for (skipped) |s| {
        try ctx.err.print("holt: {s}: cannot resolve repo {s} (malformed marker url)\n", .{ s.project, s.repo });
    }
}

/// Probes every member repo of every project in `targets` through the bounded
/// pool, preserving project-then-repo order so rendering is deterministic
/// regardless of the worker count.
fn probeTargets(alloc: std.mem.Allocator, ws: *const workspace.Workspace, targets: []const project_mod.Project, jobs: ?usize) !Probed {
    var total: usize = 0;
    for (targets) |p| total += p.marker.entries.len;

    const paths = try alloc.alloc([]const u8, total);
    const repo_names = try alloc.alloc([]const u8, total);
    const bounds = try alloc.alloc(usize, targets.len);
    var skipped: std.ArrayList(Skipped) = .empty;

    var i: usize = 0;
    for (targets, bounds) |p, *b| {
        for (p.marker.entries) |*e| {
            if (e.raw_source == null) continue;
            const src = e.source orelse {
                try skipped.append(alloc, .{ .project = try p.qualified(alloc), .repo = e.name });
                continue;
            };
            paths[i] = try src.id().clonePath(alloc, ws.cfg.code_root);
            repo_names[i] = e.name;
            i += 1;
        }
        b.* = i;
    }

    const results = try alloc.alloc(Probe, i);
    const arenas = try parallel.map(void, []const u8, Probe, probe, alloc, jobs, {}, paths[0..i], results);
    return .{
        .repo_names = repo_names[0..i],
        .paths = paths[0..i],
        .bounds = bounds,
        .results = results,
        .skipped = try skipped.toOwnedSlice(alloc),
        .arenas = arenas,
    };
}

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    if (a.jobs) |n| {
        if (n == 0) {
            return app.usageError(ctx, "-j/--jobs must be at least 1", .{});
        }
    }
    const org_filter = a.org;
    const jobs = a.jobs;
    const project_query = a.project;
    const dirty_only = a.dirty;
    const json_flag = a.json;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;
    var view = try KeptView.load(alloc, &ws);
    defer view.deinit();

    if (json_flag) return runJson(ctx, &ws, &view, org_filter, project_query, jobs);

    if (project_query) |q| {
        const p = (try common.resolveOne(ctx, q)) orelse return 1;
        var member_count: usize = 0;
        for (p.marker.entries) |*e| {
            if (e.raw_source != null) member_count += 1;
        }
        if (member_count == 0 and (try localOnlyEntries(alloc, p, &view)).len == 0) {
            const qualified = try p.qualified(alloc);
            try ctx.err.print("{s} has no member repos\n", .{qualified});
            return 0;
        }
        const one = try alloc.alloc(project_mod.Project, 1);
        one[0] = p;
        return report(ctx, &ws, &view, one, dirty_only, jobs);
    }

    var targets = try ws.list(alloc);
    if (org_filter) |org| {
        var filtered: std.ArrayList(project_mod.Project) = .empty;
        for (targets) |p| {
            if (std.mem.eql(u8, p.org, org)) try filtered.append(alloc, p);
        }
        targets = try filtered.toOwnedSlice(alloc);
    }

    if (targets.len == 0) {
        try ctx.err.writeAll("no projects yet - create one with \"holt project new <org>/<name>\"\n");
        return 0;
    }

    return report(ctx, &ws, &view, targets, dirty_only, jobs);
}

/// Emits `org_filter`/`project_query`'s selected projects as a compact JSON
/// array: `{ project, repos: [{ name, state, branch, not_linked,
/// not_restored, not_kept, will_keep, nested, unlisted }], local_only,
/// unjudged }`. `state` collapses
/// dirty/unpushed findings into one of
/// clean|dirty|unpushed|no-upstream|missing|unreadable, in that precedence
/// when more than one applies; kept files never change it. `not_linked`
/// lists the kept paths not linked, but for `not_restored`, the purged
/// paths the next `holt sync` restores from aside; `not_kept` counts the files not kept,
/// `will_keep` those an auto pattern matches, which the next `holt sync`
/// keeps, `nested` the nested repositories git's listing shows, and `unlisted` the
/// working trees and submodules git could not list; while `kept/` is not
/// set up, or a clone cannot be judged, they are `[]` and `null`.
/// `unjudged` lists the clones whose kept files could not be judged. Never
/// prints the human empty-state message - an empty result is `[]`.
fn runJson(ctx: *app.Ctx, ws: *const workspace.Workspace, view: *const KeptView, org_filter: ?[]const u8, project_query: ?[]const u8, jobs: ?usize) anyerror!u8 {
    const alloc = ctx.alloc;

    var targets: []const project_mod.Project = undefined;
    if (project_query) |q| {
        const p = (try common.resolveOne(ctx, q)) orelse return 1;
        const one = try alloc.alloc(project_mod.Project, 1);
        one[0] = p;
        targets = one;
    } else {
        var all = try ws.list(alloc);
        if (org_filter) |org| {
            var filtered: std.ArrayList(project_mod.Project) = .empty;
            for (all) |p| {
                if (std.mem.eql(u8, p.org, org)) try filtered.append(alloc, p);
            }
            all = try filtered.toOwnedSlice(alloc);
        }
        targets = all;
    }

    var probed = try probeTargets(alloc, ws, targets, jobs);
    defer probed.deinit();
    try reportSkipped(ctx, probed.skipped);
    const kept_probes = try probeKept(alloc, view, &probed, jobs);

    var items: std.ArrayList(json.Value) = .empty;
    var start: usize = 0;
    for (targets, probed.bounds) |p, end| {
        const qualified = try p.qualified(alloc);

        var repo_items: std.ArrayList(json.Value) = .empty;
        var unjudged: std.ArrayList(json.Value) = .empty;
        for (probed.repo_names[start..end], probed.paths[start..end], probed.results[start..end]) |repo_name, clone_path, res| {
            const st = try res;
            var branch: ?[]const u8 = null;
            const state: []const u8 = switch (st.kind) {
                .missing => "missing",
                .unreadable => "unreadable",
                .ok => sw: {
                    if (st.branch) |b| branch = try alloc.dupe(u8, b);
                    if (st.dirty) break :sw "dirty";
                    break :sw switch (st.unpushed) {
                        .ahead => "unpushed",
                        .no_upstream => "no-upstream",
                        .clean => "clean",
                    };
                },
            };

            var repo_obj: json.ObjectMap = .empty;
            try repo_obj.put(alloc, "name", .{ .string = repo_name });
            try repo_obj.put(alloc, "state", .{ .string = state });
            try repo_obj.put(alloc, "branch", if (branch) |b| .{ .string = b } else .null);
            const kp: ?KeptProbe = kept_probes.get(clone_path);
            var nl_items: std.ArrayList(json.Value) = .empty;
            var nr_items: std.ArrayList(json.Value) = .empty;
            var not_kept: json.Value = .null;
            var will_keep: json.Value = .null;
            var nested: json.Value = .null;
            var unlisted: json.Value = .null;
            if (kp) |k| {
                if (k.failed == null) {
                    for (k.not_linked) |n| {
                        const restores = if (n.item) |i| i.outcome == .purged_restored else false;
                        try (if (restores) &nr_items else &nl_items).append(alloc, .{ .string = n.rel });
                    }
                    not_kept = .{ .integer = @intCast(k.not_kept) };
                    will_keep = .{ .integer = @intCast(k.will_keep) };
                    nested = .{ .integer = @intCast(k.nested) };
                    unlisted = .{ .integer = @intCast(k.unlisted.len) };
                } else if (!jsonHas(unjudged.items, clone_path)) try unjudged.append(alloc, .{ .string = clone_path });
            }
            try repo_obj.put(alloc, "not_linked", .{ .array = nl_items.items });
            try repo_obj.put(alloc, "not_restored", .{ .array = nr_items.items });
            try repo_obj.put(alloc, "not_kept", not_kept);
            try repo_obj.put(alloc, "will_keep", will_keep);
            try repo_obj.put(alloc, "nested", nested);
            try repo_obj.put(alloc, "unlisted", unlisted);
            try repo_items.append(alloc, .{ .object = repo_obj });
        }

        const locals = try localOnlyEntries(alloc, p, view);
        var local_items: std.ArrayList(json.Value) = .empty;
        for (locals) |name| try local_items.append(alloc, .{ .string = name });

        var obj: json.ObjectMap = .empty;
        try obj.put(alloc, "project", .{ .string = qualified });
        try obj.put(alloc, "repos", .{ .array = try repo_items.toOwnedSlice(alloc) });
        try obj.put(alloc, "local_only", .{ .array = try local_items.toOwnedSlice(alloc) });
        try obj.put(alloc, "unjudged", .{ .array = unjudged.items });
        try items.append(alloc, .{ .object = obj });
        start = end;
    }

    try json.encode(ctx.out, .{ .array = try items.toOwnedSlice(alloc) }, .{});
    try ctx.out.writeByte('\n');
    return 0;
}

fn jsonHas(items: []const json.Value, s: []const u8) bool {
    for (items) |v| if (v == .string and std.mem.eql(u8, v.string, s)) return true;
    return false;
}

/// Renders one line for `repo_name` in `st`, followed by `extra` (its kept
/// findings), honoring `dirty_only`; null when the repo has no finding and
/// `dirty_only` is set. Owned by `alloc`.
fn formatLine(ctx: *app.Ctx, alloc: std.mem.Allocator, repo_name: []const u8, st: RepoState, extra: []const u8, dirty_only: bool) !?[]const u8 {
    switch (st.kind) {
        .missing => {
            if (dirty_only) return null;
            var aw: std.Io.Writer.Allocating = .init(alloc);
            try aw.writer.print("  {s}: ", .{repo_name});
            try ui.color(ctx.context.?.color, &aw.writer, color_red, "missing");
            try aw.writer.writeByte('\n');
            return aw.written();
        },
        .unreadable => {
            if (dirty_only) return null;
            var aw: std.Io.Writer.Allocating = .init(alloc);
            try aw.writer.print("  {s}: ", .{repo_name});
            try ui.color(ctx.context.?.color, &aw.writer, color_red, "unreadable (not a git repository)");
            try aw.writer.writeByte('\n');
            return aw.written();
        },
        .ok => {
            const has_finding = st.dirty or st.unpushed != .clean;
            if (dirty_only and !has_finding and extra.len == 0) return null;

            var aw: std.Io.Writer.Allocating = .init(alloc);
            try aw.writer.print("  {s}: branch={s}", .{ repo_name, st.branch orelse "(detached)" });
            if (st.dirty) {
                try aw.writer.writeByte(' ');
                try ui.color(ctx.context.?.color, &aw.writer, color_yellow, "dirty");
            }
            switch (st.unpushed) {
                .ahead => {
                    try aw.writer.writeByte(' ');
                    try ui.color(ctx.context.?.color, &aw.writer, color_yellow, "unpushed");
                },
                .no_upstream => {
                    try aw.writer.writeByte(' ');
                    try ui.color(ctx.context.?.color, &aw.writer, color_yellow, "no-upstream");
                },
                .clean => {},
            }
            if (!has_finding) {
                try aw.writer.writeByte(' ');
                try ui.color(ctx.context.?.color, &aw.writer, color_green, "clean");
            }
            try aw.writer.writeByte('\n');
            try aw.writer.writeAll(extra);
            return aw.written();
        },
    }
}

/// The lines of a repo whose main working tree is `clone_path` for its kept
/// paths not linked: the `N not linked` lines (`unlinkedLines`), then the
/// `N purged paths not restored yet` line counting the purged paths the next sync
/// restores from aside.
fn notLinkedLines(ctx: *app.Ctx, ws: *const workspace.Workspace, clone_path: []const u8, kp: KeptProbe) ![]const u8 {
    const a = ctx.alloc;
    var aw: std.Io.Writer.Allocating = .init(a);
    var rest: std.ArrayList(kept_cmd.NotLinked) = .empty;
    var restores: usize = 0;
    for (kp.not_linked) |n| {
        if (n.item) |i| if (i.outcome == .purged_restored) {
            restores += 1;
            continue;
        };
        try rest.append(a, n);
    }
    try aw.writer.writeAll(try unlinkedLines(ctx, ws, clone_path, rest.items));
    if (restores > 0) try aw.writer.print("    {d} purged path{s} not restored yet (run: holt sync)\n", .{ restores, if (restores == 1) "" else "s" });
    return aw.written();
}

/// The `N not linked` lines for `not_linked`: one line with the hint when
/// every path shares it (`holt sync` for what linking alone settles),
/// otherwise one line per path with its own.
fn unlinkedLines(ctx: *app.Ctx, ws: *const workspace.Workspace, clone_path: []const u8, not_linked: []const kept_cmd.NotLinked) ![]const u8 {
    const a = ctx.alloc;
    var aw: std.Io.Writer.Allocating = .init(a);
    if (not_linked.len == 0) return aw.written();
    const hints = try a.alloc([]const u8, not_linked.len);
    var same = true;
    for (not_linked, hints) |n, *h| {
        const hint = if (n.item) |item|
            try kept_hints.forItem(ctx, clone_path, null, ws.cfg.synced_root, item)
        else if (n.stop != .none)
            try kept_hints.forStop(ctx, clone_path, n.stop, null)
        else
            try kept_hints.forItem(ctx, clone_path, null, ws.cfg.synced_root, .{ .rel = n.rel, .outcome = .failed, .unsettled = true, .detail = "not judged" });
        h.* = if (hint.sync) "run: holt sync" else try kept_hints.render(a, hint);
        if (!std.mem.eql(u8, h.*, hints[0])) same = false;
    }
    if (same and std.mem.startsWith(u8, hints[0], "run: ")) {
        try aw.writer.print("    {d} not linked ({s})\n", .{ not_linked.len, hints[0] });
        return aw.written();
    }
    try aw.writer.print("    {d} not linked:\n", .{not_linked.len});
    for (not_linked, hints) |n, h| {
        const p = try util.q(ctx, try fsutil.joinSlashy(a, clone_path, n.rel));
        if (std.mem.startsWith(u8, h, "run: ")) {
            try aw.writer.print("      {s} ({s})\n", .{ p, h });
        } else try aw.writer.print("      {s}: {s}\n", .{ p, h });
    }
    return aw.written();
}

/// The lines naming each working tree and submodule of a repo that git
/// could not list, so what it holds only here is unknown, with what settles
/// each.
fn unlistedLines(ctx: *app.Ctx, clone_path: []const u8, kp: KeptProbe) ![]const u8 {
    const a = ctx.alloc;
    var aw: std.Io.Writer.Allocating = .init(a);
    if (kp.unlisted.len == 0) return aw.written();
    try aw.writer.print("    {d} not listed, so what it holds only here is unknown:\n", .{kp.unlisted.len});
    for (kp.unlisted) |u| {
        const p = try util.q(ctx, u.path);
        const h = try kept_hints.unlisted(ctx, clone_path, u.path, u.problem, u.detail);
        try aw.writer.print("      {s}: {s}\n", .{ p, try kept_hints.render(a, h) });
    }
    return aw.written();
}

/// A line for each path of a repo an auto pattern matches that git does
/// not ignore, naming what settles it.
fn autoUnignoredLines(ctx: *app.Ctx, kp: KeptProbe) ![]const u8 {
    const a = ctx.alloc;
    var aw: std.Io.Writer.Allocating = .init(a);
    for (kp.auto_unignored) |u| {
        const p = try util.q(ctx, u.path);
        try aw.writer.print("    {s}: {s}\n", .{ p, try kept_hints.render(a, try kept_hints.autoUnignored(ctx, u.path, u.pattern, u.negation)) });
    }
    return aw.written();
}

fn report(ctx: *app.Ctx, ws: *const workspace.Workspace, view: *const KeptView, targets: []const project_mod.Project, dirty_only: bool, jobs: ?usize) !u8 {
    const alloc = ctx.alloc;

    var probed = try probeTargets(alloc, ws, targets, jobs);
    defer probed.deinit();
    try reportSkipped(ctx, probed.skipped);
    const kept_probes = try probeKept(alloc, view, &probed, jobs);

    var not_kept: usize = 0;
    var will_keep: usize = 0;
    var nested: usize = 0;
    var repos: usize = 0;
    var hubs: usize = 0;
    var counted: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (targets, probed.bounds) |p, end| {
        var lines: std.ArrayList([]const u8) = .empty;
        for (probed.repo_names[start..end], probed.paths[start..end], probed.results[start..end]) |repo_name, clone_path, res| {
            const st = try res;
            var extra: []const u8 = "";
            if (kept_probes.get(clone_path)) |kp| {
                if (kp.failed) |f| {
                    try ctx.err.print("holt: {s}: cannot judge kept files: {s}\n", .{ repo_name, f });
                } else {
                    extra = try std.mem.concat(alloc, u8, &.{ try notLinkedLines(ctx, ws, clone_path, kp), try unlistedLines(ctx, clone_path, kp), try autoUnignoredLines(ctx, kp) });
                    if (!paths_contains(counted.items, clone_path)) {
                        try counted.append(alloc, clone_path);
                        not_kept += kp.not_kept;
                        will_keep += kp.will_keep;
                        nested += kp.nested;
                        if (kp.not_kept + kp.nested > 0) repos += 1;
                    }
                }
            }
            if (try formatLine(ctx, alloc, repo_name, st, extra, dirty_only)) |line| try lines.append(alloc, line);
        }
        start = end;

        const locals = try localOnlyEntries(alloc, p, view);
        if (view.judges() and locals.len > 0) {
            not_kept += locals.len;
            hubs += 1;
        }
        if (lines.items.len == 0 and locals.len == 0) continue;
        const qualified = try p.qualified(alloc);
        try ctx.out.print("{s}\n", .{qualified});
        for (lines.items) |line| try ctx.out.writeAll(line);
        if (locals.len > 0) {
            try ctx.out.writeAll("  local-only (not synced):\n");
            for (locals) |name| {
                if (util.hasControl(name)) {
                    try ctx.out.print("    {s}: {s}\n", .{ try ui.printable(alloc, name), util.controlWords(name) });
                } else try ctx.out.print("    {s} (run: holt keep {s})\n", .{ name, try util.q(ctx, try std.fs.path.join(alloc, &.{ p.hub_path, name })) });
            }
        }
    }

    if (not_kept + nested > 0) {
        var what: std.ArrayList(u8) = .empty;
        if (not_kept > 0) try what.appendSlice(alloc, try doctor_cmd.counted(alloc, not_kept, "file not kept", "files not kept"));
        if (not_kept > 0 and nested > 0) try what.appendSlice(alloc, " and ");
        if (nested > 0) try what.appendSlice(alloc, try doctor_cmd.counted(alloc, nested, "nested repository", "nested repositories"));
        try ctx.out.print("{s} - run: holt keep --review --all\n", .{try doctor_cmd.filesIn(alloc, what.items, repos, hubs)});
    }
    if (will_keep > 0) try ctx.out.print("{d} will be kept automatically by holt sync\n", .{will_keep});
    try reportKeptSetup(ctx, ws, view, probed);
    return 0;
}

/// The one line about kept files as a whole, on stderr: why they cannot be
/// judged; or, with `kept/` absent and kept files not declined, where
/// the links of a shown clone say `kept/` still is (a backend switch that
/// left it behind), or, when a shown clone holds a file not kept
/// (`kept_hooks.anyNotKept`), that kept files are not set up.
fn reportKeptSetup(ctx: *app.Ctx, ws: *const workspace.Workspace, view: *const KeptView, probed: Probed) !void {
    if (view.unjudged) |msg| {
        try ctx.err.print("holt: {s}\n", .{msg});
        return;
    }
    if (view.setup != .absent) return;
    var present: std.ArrayList([]const u8) = .empty;
    for (probed.paths, probed.results) |p, res| {
        const st = res catch continue;
        if (st.kind != .ok) continue;
        if (try kept_cmd.oldRoot(ctx.alloc, ws.cfg.synced_root, ws.cfg.code_root, p)) |old| {
            try ctx.err.print("kept/ is at {s}: copy it to {s}\n", .{ try util.q(ctx, old), try util.q(ctx, ws.cfg.synced_root) });
            return;
        }
        try present.append(ctx.alloc, p);
    }
    if (try kept_hooks.anyNotKept(ctx, present.items)) try ctx.err.writeAll(try kept_hooks.absentLine(ctx));
}

test "run: lists loose local files and skips the ignore-list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = try testutil.testWorkspace(arena, root);
    const repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(hub);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ hub, "notes.md" }), .data = "x\n" });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ hub, ".claude" })); // ignored
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ hub, ".DS_Store" }), .data = "x\n" }); // ignored

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "local-only") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "notes.md") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, ".claude") == null);
    try testing.expect(std.mem.indexOf(u8, got.out, ".DS_Store") == null);
}

test "run: lists a real loose file but skips a symlink entry (the keep round-trip)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = try testutil.testWorkspace(arena, root);
    const repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(hub);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ hub, "notes.md" }), .data = "x\n" });

    const content = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj" });
    try fsutil.ensureDir(content);
    const link_path = try std.fs.path.join(arena, &.{ hub, "docs" });
    try fsutil.replaceSymlink(content, link_path);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "local-only") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "notes.md") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "docs") == null);
}

test "run: flags a dirty repo and an unpushed repo, a missing clone is shown, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_a = try testutil.makeBareRepo(&sb, "a.git");
    defer testing.allocator.free(bare_a);
    const bare_b = try testutil.makeBareRepo(&sb, "b.git");
    defer testing.allocator.free(bare_b);

    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "dirty-repo", "https://holt-test.invalid/acme/dirty-repo");
    try repos.put(arena, "unpushed-repo", "https://holt-test.invalid/acme/unpushed-repo");
    try repos.put(arena, "gone", "https://holt-test.invalid/acme/gone");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const dirty_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "dirty-repo" });
    try fsutil.ensureDir(std.fs.path.dirname(dirty_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_a, dirty_path });
    {
        var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), dirty_path, .{});
        defer dir.close(fsutil.io());
        try dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });
    }

    const unpushed_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "unpushed-repo" });
    try fsutil.ensureDir(std.fs.path.dirname(unpushed_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_b, unpushed_path });
    {
        var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), unpushed_path, .{});
        defer dir.close(fsutil.io());
        try dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "changed\n" });
    }
    try testutil.runGit(&sb, unpushed_path, &.{ "commit", "-am", "local change" });

    const gone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "gone" });
    try testing.expect(!fsutil.exists(gone_path));

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/proj") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "dirty-repo: branch=main dirty\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "unpushed-repo: branch=main unpushed\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "gone: missing\n") != null);

    const filtered = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--dirty" });
    try testing.expectEqual(@as(u8, 0), filtered.code);
    try testing.expect(std.mem.indexOf(u8, filtered.out, "dirty-repo") != null);
    try testing.expect(std.mem.indexOf(u8, filtered.out, "unpushed-repo") != null);
    try testing.expect(std.mem.indexOf(u8, filtered.out, "gone") == null);
}

test "run: a corrupted clone reports unreadable instead of a benign branch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "corrupt-repo", "https://holt-test.invalid/acme/corrupt-repo");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const corrupt_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "corrupt-repo" });
    try fsutil.ensureDir(std.fs.path.dirname(corrupt_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, corrupt_path });

    const head_path = try std.fs.path.join(arena, &.{ corrupt_path, ".git", "HEAD" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = head_path, .data = "garbage, not a ref\n" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "corrupt-repo: unreadable") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "branch=") == null);
}

test "probe: probes a present clone with exactly one git subprocess (was four)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(clone_path);

    // status probes each present repo with exactly ONE git subprocess (was four:
    // inspectable + currentBranch + isDirty + unpushed). A regression that
    // re-splits the probe into multiple git calls fails here.
    const before = proc.spawn_count.load(.monotonic);
    const st = try probe({}, arena, clone_path);
    const after = proc.spawn_count.load(.monotonic);

    try testing.expectEqual(.ok, st.kind);
    try testing.expectEqual(@as(u64, 1), after - before);
}

test "run: with no project argument, every project gets its own section" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "missing-repo", "https://holt-test.invalid/acme/missing-repo");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos_a, .empty);

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "other-missing", "https://holt-test.invalid/acme/other-missing");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", repos_b, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/first") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/second") != null);
}

test "run: --dirty with nothing to report omits the project section entirely" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "clean.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "clean-repo", "https://holt-test.invalid/acme/clean-repo");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const clean_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "clean-repo" });
    try fsutil.ensureDir(std.fs.path.dirname(clean_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, clean_path });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--dirty" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("", got.out);
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

test "run: an empty workspace prints a helpful hint on stderr, stdout stays clean, exit 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("", got.out);
    try testing.expect(std.mem.indexOf(u8, got.err, "no projects yet") != null);
}

test "run: a project with zero member repos reports so instead of printing nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty-proj", .empty, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/empty-proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("", got.out);
    try testing.expect(std.mem.indexOf(u8, got.err, "acme/empty-proj has no member repos") != null);
}

test "run: --org filters to a single org's projects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos_acme: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_acme.put(arena, "gone", "https://holt-test.invalid/acme/gone");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos_acme, .empty);

    var repos_other: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_other.put(arena, "gone", "https://holt-test.invalid/other/gone");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "other", "second", repos_other, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "--org", "other" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "other/second") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/first") == null);
}

test "run: colors the dirty/unpushed/missing/clean tokens when the destination is color-enabled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "clean.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "clean-repo", "https://holt-test.invalid/acme/clean-repo");
    try repos.put(arena, "gone", "https://holt-test.invalid/acme/gone");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const clean_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "clean-repo" });
    try fsutil.ensureDir(std.fs.path.dirname(clean_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, clean_path });

    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = .{ .ws = ws, .color = true, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer, .argv = &.{"proj"} };
    const code = try command.run(&ctx);

    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[32mclean\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[31mmissing\x1b[0m") != null);
}

test "run: --json reports each repo's state as a string, no ANSI escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_clean = try testutil.makeBareRepo(&sb, "clean.git");
    defer testing.allocator.free(bare_clean);
    const bare_dirty = try testutil.makeBareRepo(&sb, "dirty.git");
    defer testing.allocator.free(bare_dirty);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "clean-repo", "https://holt-test.invalid/acme/clean-repo");
    try repos.put(arena, "dirty-repo", "https://holt-test.invalid/acme/dirty-repo");
    try repos.put(arena, "gone", "https://holt-test.invalid/acme/gone");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const clean_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "clean-repo" });
    try fsutil.ensureDir(std.fs.path.dirname(clean_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_clean, clean_path });

    const dirty_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "dirty-repo" });
    try fsutil.ensureDir(std.fs.path.dirname(dirty_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_dirty, dirty_path });
    {
        var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), dirty_path, .{});
        defer dir.close(fsutil.io());
        try dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });
    }

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--json" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "\x1b[") == null);

    const Repo = struct { name: []const u8, state: []const u8, branch: ?[]const u8, not_linked: [][]const u8, not_restored: [][]const u8, not_kept: ?u64, will_keep: ?u64, nested: ?u64, unlisted: ?u64 };
    const Entry = struct { project: []const u8, repos: []Repo, local_only: [][]const u8, unjudged: [][]const u8 };
    const parsed = try json.parseInto([]Entry, arena, got.out, .{});
    try testing.expectEqual(@as(usize, 1), parsed.len);
    try testing.expectEqualStrings("acme/proj", parsed[0].project);
    for (parsed[0].repos) |r| {
        try testing.expectEqual(@as(usize, 0), r.not_linked.len);
        try testing.expect(r.not_kept == null);
    }

    var states: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (parsed[0].repos) |r| try states.put(arena, r.name, r.state);
    try testing.expectEqualStrings("clean", states.get("clean-repo").?);
    try testing.expectEqualStrings("dirty", states.get("dirty-repo").?);
    try testing.expectEqualStrings("missing", states.get("gone").?);
}

test "runJson: includes a local_only array per project" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = try testutil.testWorkspace(arena, root);
    const repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);
    const hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(hub);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ hub, "notes.md" }), .data = "x\n" });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--json" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "\"local_only\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "notes.md") != null);
}

test "run: --json on an empty workspace emits [] on stdout, not the human hint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--json"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("[]\n", got.out);
    try testing.expectEqualStrings("", got.err);
}

/// Builds a workspace with 12 member repos across 3 projects: a mix of clean,
/// dirty, unpushed, missing, and one corrupted (unreadable) clone, so the
/// serial-vs-parallel equivalence tests exercise every code path. Returns the
/// workspace; all clones share one bare origin cloned into distinct paths.
fn buildManyRepoWorkspace(arena: std.mem.Allocator, sb: *testutil.Sandbox) !workspace.Workspace {
    const bare = try testutil.makeBareRepo(sb, "origin.git");
    defer sb.alloc.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);

    const projects = [_][]const u8{ "alpha", "beta", "gamma" };
    for (projects, 0..) |proj, pi| {
        var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (0..4) |ri| {
            const repo_name = try std.fmt.allocPrint(arena, "repo-{d}-{d}", .{ pi, ri });
            const url = try std.fmt.allocPrint(arena, "https://holt-test.invalid/acme/{s}", .{repo_name});
            try repos.put(arena, repo_name, url);
        }
        try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", proj, repos, .empty);
    }

    // Materialize clones with a deterministic variety of states.
    for (projects, 0..) |_, pi| {
        for (0..4) |ri| {
            const repo_name = try std.fmt.allocPrint(arena, "repo-{d}-{d}", .{ pi, ri });
            const path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", repo_name });

            // Every 4th repo (ri==3) stays missing on disk.
            if (ri == 3) continue;

            try fsutil.ensureDir(std.fs.path.dirname(path).?);
            try testutil.runGit(sb, null, &.{ "clone", bare, path });

            if (ri == 1) {
                // Dirty: an untracked file.
                var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), path, .{});
                defer dir.close(fsutil.io());
                try dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });
            } else if (ri == 2 and pi == 0) {
                // Unreadable: corrupt HEAD in exactly one clone.
                const head_path = try std.fs.path.join(arena, &.{ path, ".git", "HEAD" });
                try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = head_path, .data = "garbage, not a ref\n" });
            } else if (ri == 2) {
                // Unpushed: a local commit ahead of upstream.
                var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), path, .{});
                defer dir.close(fsutil.io());
                try dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "changed\n" });
                try testutil.runGit(sb, path, &.{ "commit", "-am", "local change" });
            }
        }
    }

    return ws;
}

test "run: -j 1 and -j 8 produce byte-identical human output across many repos" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try buildManyRepoWorkspace(arena, &sb);

    const serial = try testutil.runCmd(arena, command.run, ws, &.{ "-j", "1" });
    const parallel_run = try testutil.runCmd(arena, command.run, ws, &.{ "-j", "8" });

    try testing.expectEqual(@as(u8, 0), serial.code);
    try testing.expectEqual(@as(u8, 0), parallel_run.code);
    try testing.expectEqualStrings(serial.out, parallel_run.out);

    // The oracle must actually be exercising every state, not empty output.
    try testing.expect(std.mem.indexOf(u8, serial.out, "dirty") != null);
    try testing.expect(std.mem.indexOf(u8, serial.out, "unpushed") != null);
    try testing.expect(std.mem.indexOf(u8, serial.out, "missing") != null);
    try testing.expect(std.mem.indexOf(u8, serial.out, "unreadable") != null);
    try testing.expect(std.mem.indexOf(u8, serial.out, "clean") != null);
}

test "run: --json is byte-identical at -j 1 and -j 8 across many repos" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try buildManyRepoWorkspace(arena, &sb);

    const serial = try testutil.runCmd(arena, command.run, ws, &.{ "--json", "-j", "1" });
    const parallel_run = try testutil.runCmd(arena, command.run, ws, &.{ "--json", "-j", "8" });

    try testing.expectEqual(@as(u8, 0), serial.code);
    try testing.expectEqual(@as(u8, 0), parallel_run.code);
    try testing.expectEqualStrings(serial.out, parallel_run.out);
    try testing.expect(std.mem.indexOf(u8, serial.out, "unreadable") != null);
}

test "run: an unreadable clone among many under -j 8 is reported, not a crash or deadlock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try buildManyRepoWorkspace(arena, &sb);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "-j", "8" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "unreadable (not a git repository)") != null);
}

test "jobsOption: -j 0 and a non-integer are usage errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    {
        const got = try testutil.runCmd(arena, command.run, ws, &.{ "-j", "0" });
        try testing.expectEqual(@as(u8, 2), got.code);
    }
    {
        const got = try testutil.runCmd(arena, command.run, ws, &.{ "--jobs", "abc" });
        try testing.expectEqual(@as(u8, 2), got.code);
    }
}

test "run: a member whose marker value never parsed is reported and the rest still probe" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "good", "https://holt-test.invalid/acme/good");
    try repos.put(arena, "broken", "not a url");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "cannot resolve repo broken") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "good") != null);
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// `path` as a hint prints it (`ui.quotePath`).
fn quoted(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return ui.quotePath(a, app.envOf_current(), path);
}

test "run: without kept/, the not-set-up line on stderr while a clone holds a file not kept, silenced once kept files are declined" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, false);
    defer w.deinit();

    const none = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), none.code);
    try testing.expect(!has(none.err, "no kept/ here yet"));

    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ w.clone, ".git", "info", "exclude" }), .data = "/secret.txt\n" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ w.clone, "secret.txt" }), .data = "only here" });
    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(has(got.err, "no kept/ here yet: if another machine keeps files, wait for your cloud client to download it, then run holt sync; otherwise run holt keep --review --all\n"));
    try testing.expect(!has(got.out, "not kept"));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ w.ws.cfg.synced_root, "kept" })));

    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ w.ws.cfg.synced_root, kept_cmd.off_basename }), .data = "" });
    const off = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(!has(off.err, "not set up"));
}

test "run: links into a kept/ under another synced root print the copy hint, never the setup line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{\"scriptId\":\"x\"}\n");

    var moved = w.ws;
    moved.cfg.synced_root = try std.fs.path.join(arena, &.{ sb.root, "new-synced" });
    try fsutil.ensureDir(moved.cfg.synced_root);
    try fsutil.copyTree(arena, try std.fs.path.join(arena, &.{ w.ws.cfg.synced_root, "projects" }), try std.fs.path.join(arena, &.{ moved.cfg.synced_root, "projects" }));

    const got = try testutil.runCmd(arena, command.run, moved, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    const want = try std.fmt.allocPrint(arena, "kept/ is at {s}: copy it to {s}\n", .{ try quoted(arena, w.ws.cfg.synced_root), try quoted(arena, moved.cfg.synced_root) });
    try testing.expect(has(got.err, want));
    try testing.expect(!has(got.err, "not set up"));
}

test "run: the candidates line counts ignored files and hub-root entries, a file the auto patterns will keep is counted on a line of its own, and state stays clean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();

    const exclude = try std.fs.path.join(arena, &.{ w.clone, ".git", "info", "exclude" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = exclude, .data = ".env\nnode_modules/\n.clasp.json\n" });
    _ = try w.write(arena, ".env", "SECRET=1\n");
    _ = try w.write(arena, "node_modules/x/index.js", "x\n");
    _ = try w.write(arena, ".clasp.json", "{}\n");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ w.hub, "notes.md" }), .data = "n\n" });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(has(got.out, "widget: branch=main clean\n"));
    try testing.expect(has(got.out, "2 files not kept in 1 repo and 1 hub root - run: holt keep --review --all\n"));
    try testing.expect(has(got.out, "1 will be kept automatically by holt sync\n"));
    try testing.expect(!has(got.err, "not set up"));
    const js = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--json" });
    try testing.expect(has(js.out, "\"not_kept\":1,\"will_keep\":1,"));

    try testing.expectEqual(@as(u8, 0), (try testutil.runCmd(arena, @import("sync.zig").command.run, w.ws, &.{})).code);
    const after = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(!has(after.out, "will be kept automatically"));
}

test "run: an auto-pattern match git does not ignore is named with what settles it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    const auto = try w.write(arena, "sub/.clasp.json", "{}\n");

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    const q = try ui.quotePath(arena, app.envOf_current(), auto);
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "    {s}: matches an auto pattern (.clasp.json) but git does not ignore it; add it to .gitignore, or keep it (run: holt keep {s})\n", .{ q, q })));

    try w.keep(arena, "neg/.clasp.json", "{}\n");
    _ = try w.write(arena, "neg/.gitignore", "!.clasp.json\n");
    const kept_one = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(!has(kept_one.out, "neg/.clasp.json"));
}

test "run: an auto-pattern match a .gitignore negation un-ignores names that line and offers no keep; once the line is gone, sync keeps it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    const ignore = try w.write(arena, "neg/.gitignore", "*.json\n!.clasp.json\n");
    const auto = try w.write(arena, "neg/.clasp.json", "{}\n");

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    const q = try ui.quotePath(arena, app.envOf_current(), auto);
    const line = try std.fmt.allocPrint(arena, "{s}:2:!.clasp.json", .{try fsutil.contractTilde(arena, app.envOf_current(), ignore)});
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "    {s}: matches an auto pattern (.clasp.json) but {s} un-ignores it, so holt cannot keep it; remove or narrow that line, or leave it for a commit\n", .{ q, line })));
    try testing.expect(!has(got.out, try std.fmt.allocPrint(arena, "holt keep {s}", .{q})));

    _ = try w.write(arena, "neg/.gitignore", "*.json\n");
    try testing.expectEqual(@as(u8, 0), (try testutil.runCmd(arena, @import("sync.zig").command.run, w.ws, &.{})).code);
    const settled = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(!has(settled.out, "neg/.clasp.json"));
    try testing.expectEqualStrings(try w.keptPath(arena, "neg/.clasp.json"), (try kept.content.readLink(arena, auto)).?);
}

test "run: once kept/ exists the hub root hides only .git and skip matches, so .claude is offered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, false);
    defer w.deinit();

    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ w.hub, ".claude" }));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ w.hub, ".claude", "settings.local.json" }), .data = "{}\n" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ w.hub, ".DS_Store" }), .data = "x" });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ w.hub, "node_modules" }));
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ w.hub, ".git" }));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ w.hub, "draft.md~" }), .data = "x" });

    const before = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(!has(before.out, ".claude"));
    try testing.expect(has(before.out, "node_modules"));
    try testing.expect(!has(before.out, "draft.md~"));

    _ = try kept.patterns.createStore(arena, .{ .synced_root = w.ws.cfg.synced_root });
    const after = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    const claude = try std.fmt.allocPrint(arena, "    .claude (run: holt keep {s})\n", .{try quoted(arena, try std.fs.path.join(arena, &.{ w.hub, ".claude" }))});
    try testing.expect(has(after.out, claude));
    try testing.expect(has(after.out, "draft.md~"));
    try testing.expect(!has(after.out, ".DS_Store"));
    try testing.expect(!has(after.out, "node_modules"));
    try testing.expect(!has(after.out, ".git "));
    try testing.expect(has(after.out, "2 files not kept in 1 hub root - run: holt keep --review --all\n"));

    const js = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--json" });
    try testing.expect(has(js.out, "\"local_only\":[\".claude\",\"draft.md~\"]"));
}

test "run: a kept path whose link is gone is one line hinting holt sync; differing content names the settling commands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{\"scriptId\":\"x\"}\n");
    try w.keep(arena, "local.json", "{}\n");

    const healthy = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(!has(healthy.out, "not linked"));
    const quiet = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--dirty" });
    try testing.expectEqualStrings("", quiet.out);

    try fsutil.removePath(try fsutil.joinSlashy(arena, w.clone, ".clasp.json"));
    try fsutil.removePath(try fsutil.joinSlashy(arena, w.clone, "local.json"));
    const gone = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(has(gone.out, "widget: branch=main clean\n    2 not linked (run: holt sync)\n"));
    const dirty = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--dirty" });
    try testing.expect(has(dirty.out, "2 not linked (run: holt sync)"));

    _ = try w.write(arena, "local.json", "{\"changed\":true}\n");
    const differs = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    const p = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, "local.json"));
    const clasp = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, ".clasp.json"));
    const want = try std.fmt.allocPrint(arena, "    2 not linked:\n      {s} (run: holt sync)\n      {s}: local copy differs from the kept copy (run: holt keep --take-local {s}, or holt keep --take-kept {s})\n", .{ clasp, p, p, p });
    try testing.expect(has(differs.out, want));
    try testing.expect(has(differs.out, "widget: branch=main clean\n"));

    const js = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--json" });
    try testing.expect(has(js.out, "\"not_linked\":[\".clasp.json\",\"local.json\"]"));
    try testing.expect(has(js.out, "\"not_kept\":0"));
    try testing.expect(has(js.out, "\"state\":\"clean\""));
}

test "run: a purged path the next sync restores from aside is counted as not restored yet, apart from the paths not linked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".env", "E=1\n");
    try w.keep(arena, "local.json", "{}\n");
    _ = try w.purgeElsewhere(arena, ".env");
    try fsutil.removePath(try fsutil.joinSlashy(arena, w.clone, "local.json"));

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(has(got.out, "widget: branch=main clean\n    1 not linked (run: holt sync)\n    1 purged path not restored yet (run: holt sync)\n"));
    const js = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--json" });
    try testing.expect(has(js.out, "\"not_linked\":[\"local.json\"],\"not_restored\":[\".env\"]"));
    const synced = try testutil.runCmd(arena, @import("sync.zig").command.run, w.ws, &.{});
    try testing.expectEqual(@as(u8, 0), synced.code);
    const after = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(!has(after.out, "not restored"));
    try testing.expect(!has(after.out, "not linked"));
}

test "run: a kept path the branch tracks is not reported as not linked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");

    try fsutil.removePath(try fsutil.joinSlashy(arena, w.clone, ".clasp.json"));
    _ = try w.write(arena, ".clasp.json", "{}\n");
    try testutil.runGit(&sb, w.clone, &.{ "add", "-f", ".clasp.json" });
    try testutil.runGit(&sb, w.clone, &.{ "commit", "-qm", "track it" });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--json" });
    try testing.expect(has(got.out, "\"not_linked\":[]"));
}

test "run: kept files cost no git call per repo while they are declined, and a bounded few while kept/ is absent or once it exists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const scope = try testutil.EnvScope.install(arena, &.{.{ "XDG_STATE_HOME", try std.fs.path.join(arena, &.{ sb.root, "state" }) }});
    defer scope.restore();
    const ws = try buildManyRepoWorkspace(arena, &sb);

    var present: u64 = 0;
    for (try ws.list(arena)) |p| {
        for (p.marker.entries) |*e| {
            const cp = try e.source.?.id().clonePath(arena, ws.cfg.code_root);
            if (fsutil.exists(cp)) present += 1;
        }
    }

    const off = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, kept_cmd.off_basename });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = off, .data = "" });
    const before = proc.spawn_count.load(.monotonic);
    _ = try testutil.runCmd(arena, command.run, ws, &.{ "-j", "1" });
    try testing.expectEqual(present, proc.spawn_count.load(.monotonic) - before);
    try fsutil.removePath(off);

    const unset = proc.spawn_count.load(.monotonic);
    _ = try testutil.runCmd(arena, command.run, ws, &.{ "-j", "1" });
    try testing.expect(proc.spawn_count.load(.monotonic) - unset <= present * 12 + 4);

    _ = try kept.patterns.createStore(arena, .{ .synced_root = ws.cfg.synced_root });
    const started = std.Io.Clock.awake.now(testing.io).nanoseconds;
    const mid = proc.spawn_count.load(.monotonic);
    const got = try testutil.runCmd(arena, command.run, ws, &.{ "-j", "4" });
    const kept_calls = proc.spawn_count.load(.monotonic) - mid;
    const elapsed_ns = std.Io.Clock.awake.now(testing.io).nanoseconds - started;
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(kept_calls <= present * 12 + 4);
    try testing.expect(elapsed_ns < 120 * std.time.ns_per_s);
}

test "run: a holt link into an old synced root is not linked, hinting holt sync" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{\"a\":1}\n");
    var moved = w.ws;
    moved.cfg.synced_root = try std.fs.path.join(arena, &.{ sb.root, "new-synced" });
    try fsutil.ensureDir(moved.cfg.synced_root);
    try fsutil.copyTree(arena, try std.fs.path.join(arena, &.{ w.ws.cfg.synced_root, "projects" }), try std.fs.path.join(arena, &.{ moved.cfg.synced_root, "projects" }));
    try fsutil.copyTree(arena, try std.fs.path.join(arena, &.{ w.ws.cfg.synced_root, "kept" }), try std.fs.path.join(arena, &.{ moved.cfg.synced_root, "kept" }));

    const got = try testutil.runCmd(arena, command.run, moved, &.{"proj"});
    try testing.expect(has(got.out, "widget: branch=main clean\n    1 not linked (run: holt sync)\n"));
    const js = try testutil.runCmd(arena, command.run, moved, &.{ "proj", "--json" });
    try testing.expect(has(js.out, "\"not_linked\":[\".clasp.json\"]"));
}

test "run: nested repositories count on the candidates line and in the JSON, and a path outside the sparse checkout is not reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, "sub/a.json", "{}\n");
    _ = try w.write(arena, ".gitignore", "vendor/\n");
    try testutil.runGit(&sb, w.clone, &.{ "add", ".gitignore" });
    try testutil.runGit(&sb, w.clone, &.{ "commit", "-qm", "gi" });
    try testutil.seedMinimalGitClone(arena, &sb.git_env, try fsutil.joinSlashy(arena, w.clone, "vendor/lib"));
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), try fsutil.joinSlashy(arena, w.clone, "sub"));
    try testutil.runGit(&sb, w.clone, &.{ "sparse-checkout", "set", "--cone", "other" });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(has(got.out, "1 nested repository in 1 repo - run: holt keep --review --all\n"));
    try testing.expect(!has(got.out, "not linked"));
    try testing.expect(!has(got.out, "outside_sparse"));
    const js = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--json" });
    try testing.expect(has(js.out, "\"not_linked\":[],\"not_restored\":[],\"not_kept\":0,\"will_keep\":0,\"nested\":1,\"unlisted\":0"));
    try testing.expect(has(js.out, "\"unjudged\":[]"));
}

test "run: a worktree record whose gitdir cannot be read is named with what is seen there and the record's path, which is there, and left as it was" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    const linked = try std.fmt.allocPrint(arena, "{s}@worktrees/feat", .{w.clone});
    try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "feat", linked });
    const record = try std.fs.path.join(arena, &.{ w.clone, ".git", "worktrees", "feat" });
    const gitdir = try std.fs.path.join(arena, &.{ record, "gitdir" });
    try fsutil.removePath(gitdir);
    try fsutil.ensureDir(gitdir);
    const recs = try kept_hooks.snapshot(arena, record, null);

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    const rq = try quoted(arena, record);
    const want = try std.fmt.allocPrint(arena, "      {s}: a linked working tree whose record git cannot read, which git worktree list leaves out; holt does not change it: resolve it with git (the record is {s}), then run again\n", .{ rq, rq });
    if (!has(got.out, want) or has(got.out, " worktree list)")) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ want, got.out });
        return error.TestUnexpectedResult;
    }
    const res = try proc.runEnv(arena, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "ls -d {s}", .{rq}) }, null, &sb.git_env.map);
    try testing.expectEqual(@as(u8, 0), res.status);
    try testing.expectEqualStrings(recs, try kept_hooks.snapshot(arena, record, null));
}

test "run: a working tree status cannot list is named with commands reaching that worktree or its record alone, each of which settles it and leaves another worktree's record as it was; one holt leaves to the user is named with what is seen there and git worktree list alone, which runs, and left as it was" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Case = enum { absent_back, absent_removed, locked_removed, unlinked, dangling, foreign, nowhere };
    for (std.enums.values(Case)) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try kept_cmd.TestWorld.init(arena, &sb, true);
        defer w.deinit();
        try w.keep(arena, ".clasp.json", "{}\n");
        const linked = try std.fmt.allocPrint(arena, "{s}@worktrees/feat", .{w.clone});
        const other = try std.fmt.allocPrint(arena, "{s}@worktrees/other", .{w.clone});
        const also = try std.fmt.allocPrint(arena, "{s}@worktrees/also", .{w.clone});
        try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "feat", linked });
        try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "other", other });
        try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "also", also });
        try std.Io.Dir.cwd().deleteTree(fsutil.io(), also);
        const records = try std.fs.path.join(arena, &.{ w.clone, ".git", "worktrees" });
        const other_gitdir = try std.fs.path.join(arena, &.{ records, "other", "gitdir" });
        const other_link = try std.fs.path.join(arena, &.{ other, ".git" });
        try std.Io.Dir.cwd().deleteTree(fsutil.io(), other);
        try fsutil.ensureDir(other);
        try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = other_link, .data = "gitdir: /nowhere/at/all\n" });
        const before = try kept.content.readSmall(arena, other_gitdir);
        switch (case) {
            .absent_back, .absent_removed, .locked_removed => try std.Io.Dir.cwd().deleteTree(fsutil.io(), linked),
            .unlinked => try fsutil.removePath(try std.fs.path.join(arena, &.{ linked, ".git" })),
            .dangling => try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ linked, ".git" }), .data = "gitdir: /moved/away/.git/worktrees/feat\n" }),
            .foreign => {
                try std.Io.Dir.cwd().deleteTree(fsutil.io(), linked);
                const theirs = try std.fs.path.join(arena, &.{ sb.root, "theirs" });
                try testutil.runGit(&sb, null, &.{ "clone", "-q", w.clone, theirs });
                try testutil.runGit(&sb, theirs, &.{ "worktree", "add", "-q", "--detach", linked });
            },
            .nowhere => {
                try std.Io.Dir.cwd().deleteTree(fsutil.io(), linked);
                try kept.content.createLink(try std.fs.path.join(arena, &.{ sb.root, "no-such-dir" }), linked, .dir);
            },
        }
        if (case == .locked_removed) try testutil.runGit(&sb, w.clone, &.{ "worktree", "lock", linked });

        const seen: ?[]const u8 = switch (case) {
            .unlinked => "a linked working tree whose .git is gone",
            .dangling => "a linked working tree whose .git names a git directory that is not there",
            .foreign => "a linked working tree whose .git leads to another git directory than its record",
            .nowhere => "a linked working tree whose path is a symlink to nothing",
            else => null,
        };
        if (seen) |s| {
            const trees = try std.mem.concat(arena, u8, &.{ try kept_hooks.snapshot(arena, linked, null), (try kept.content.readLink(arena, linked)) orelse "" });
            const recs = try kept_hooks.snapshot(arena, records, null);
            const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
            const git_in = try std.fmt.allocPrint(arena, "git -C {s}", .{try quoted(arena, w.clone)});
            const want = try std.fmt.allocPrint(arena, "      {s}: {s}; holt does not change it: resolve it with git ({s} worktree list), then run again\n", .{ try quoted(arena, linked), s, git_in });
            if (!has(got.out, want)) {
                std.debug.print("{s}: wanted {s} in:\n{s}\n", .{ @tagName(case), want, got.out });
                return error.TestUnexpectedResult;
            }
            const res = try proc.runEnv(arena, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "{s} worktree list", .{git_in}) }, null, &sb.git_env.map);
            try testing.expectEqual(@as(u32, 0), res.status);
            try testing.expectEqualStrings(trees, try std.mem.concat(arena, u8, &.{ try kept_hooks.snapshot(arena, linked, null), (try kept.content.readLink(arena, linked)) orelse "" }));
            try testing.expectEqualStrings(recs, try kept_hooks.snapshot(arena, records, null));
            try testing.expectEqualStrings("gitdir: /nowhere/at/all\n", try kept.content.readSmall(arena, other_link));
            continue;
        }

        const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
        const lead = try std.fmt.allocPrint(arena, "      {s}: a working tree that cannot be read (", .{try quoted(arena, linked)});
        const at = std.mem.indexOf(u8, got.out, lead) orelse {
            std.debug.print("{s}: wanted {s} in:\n{s}\n", .{ @tagName(case), lead, got.out });
            return error.TestUnexpectedResult;
        };
        const line = got.out[at..std.mem.indexOfScalarPos(u8, got.out, at, '\n').?];
        try testing.expect(!has(line, "worktree repair") and !has(line, "worktree prune"));
        const open = std.mem.indexOf(u8, line, "(run: ").? + "(run: ".len;
        const cmds = line[open .. line.len - 1];
        const cmd = switch (case) {
            .absent_back => cmds[0..std.mem.indexOf(u8, cmds, ", or ").?],
            else => cmds[std.mem.indexOf(u8, cmds, ", or ").? + ", or ".len ..],
        };
        const res = try proc.runEnv(arena, &.{ "sh", "-c", cmd }, null, &sb.git_env.map);
        if (res.status != 0) {
            std.debug.print("{s}: hint failed: {s}\n{s}\n", .{ @tagName(case), cmd, res.stderr });
            return error.TestUnexpectedResult;
        }
        const after = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
        if (has(after.out, lead)) {
            std.debug.print("{s}: not settled by {s}:\n{s}\n", .{ @tagName(case), cmd, after.out });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualStrings(before, try kept.content.readSmall(arena, other_gitdir));
        try testing.expectEqualStrings("gitdir: /nowhere/at/all\n", try kept.content.readSmall(arena, other_link));
        try testing.expectEqual(kept.content.Entry.dir, try kept.content.entryAt(try std.fs.path.join(arena, &.{ records, "also" })));
        try testing.expectEqual(case != .absent_back, try kept.content.entryAt(try std.fs.path.join(arena, &.{ records, "feat" })) == .absent);
    }
}

test "run: a working tree whose path lies under a file is named with what is seen there and git worktree list alone, which runs, never mkdir; once the file is moved away, bringing it back settles it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    const blk = try std.fmt.allocPrint(arena, "{s}@worktrees/nest", .{w.clone});
    const linked = try std.fs.path.join(arena, &.{ blk, "feat" });
    try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "nest/feat", linked });
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), blk);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = blk, .data = "not a tree\n" });

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    const git_in = try std.fmt.allocPrint(arena, "git -C {s}", .{try quoted(arena, w.clone)});
    const want = try std.fmt.allocPrint(arena, "      {s}: a linked working tree whose path lies under something that is not a directory; holt does not change it: resolve it with git ({s} worktree list), then run again\n", .{ try quoted(arena, linked), git_in });
    if (!has(got.out, want) or has(got.out, "mkdir")) {
        std.debug.print("wanted {s} in:\n{s}\n", .{ want, got.out });
        return error.TestUnexpectedResult;
    }
    const res = try proc.runEnv(arena, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "{s} worktree list", .{git_in}) }, null, &sb.git_env.map);
    try testing.expectEqual(@as(u8, 0), res.status);
    try testing.expectEqualStrings("not a tree\n", try kept.content.readSmall(arena, blk));

    try fsutil.removePath(blk);
    const gone = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    const lead = try std.fmt.allocPrint(arena, "      {s}: a working tree that cannot be read (absent)", .{try quoted(arena, linked)});
    const at = std.mem.indexOf(u8, gone.out, lead) orelse {
        std.debug.print("wanted {s} in:\n{s}\n", .{ lead, gone.out });
        return error.TestUnexpectedResult;
    };
    const line = gone.out[at..std.mem.indexOfScalarPos(u8, gone.out, at, '\n').?];
    const open = std.mem.indexOf(u8, line, "(run: ").? + "(run: ".len;
    const cmds = line[open .. line.len - 1];
    const cmd = cmds[0 .. std.mem.indexOf(u8, cmds, ", or ") orelse cmds.len];
    const back = try proc.runEnv(arena, &.{ "sh", "-c", cmd }, null, &sb.git_env.map);
    if (back.status != 0) {
        std.debug.print("hint failed: {s}\n{s}\n", .{ cmd, back.stderr });
        return error.TestUnexpectedResult;
    }
    const after = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    if (has(after.out, try quoted(arena, linked))) {
        std.debug.print("not settled by {s}:\n{s}\n", .{ cmd, after.out });
        return error.TestUnexpectedResult;
    }
}

test "run: a working tree whose directory is gone and whose record holds staged changes is offered no git worktree remove: one holt worktree made names holt worktree -r, which refuses it, another the lines naming what removing it destroys, and bringing it back settles it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const worktree_cmd = @import("worktree.zig");
    const Case = enum { holt, elsewhere };
    for (std.enums.values(Case)) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try kept_cmd.TestWorld.init(arena, &sb, true);
        defer w.deinit();
        try w.keep(arena, ".clasp.json", "{}\n");
        const linked = switch (case) {
            .holt => try std.fmt.allocPrint(arena, "{s}@worktrees/feat", .{w.clone}),
            .elsewhere => try std.fs.path.join(arena, &.{ sb.root, "elsewhere" }),
        };
        try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "feat", linked });
        try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ linked, "staged.txt" }), .data = "only in the index\n" });
        try testutil.runGit(&sb, linked, &.{ "add", "staged.txt" });
        try std.Io.Dir.cwd().deleteTree(fsutil.io(), linked);
        const record = try std.fs.path.join(arena, &.{ w.clone, ".git", "worktrees", "feat" });

        const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
        const wq = try quoted(arena, linked);
        const lead = try std.fmt.allocPrint(arena, "      {s}: a working tree that cannot be read (absent)", .{wq});
        const at = std.mem.indexOf(u8, got.out, lead) orelse {
            std.debug.print("{s}: wanted {s} in:\n{s}\n", .{ @tagName(case), lead, got.out });
            return error.TestUnexpectedResult;
        };
        const line = got.out[at..std.mem.indexOfScalarPos(u8, got.out, at, '\n').?];
        try testing.expect(!has(line, " worktree remove ") and !has(line, "worktree prune"));
        const relink = switch (case) {
            .holt => blk: {
                const open = std.mem.indexOf(u8, line, "(run: ").? + "(run: ".len;
                const cmds = line[open .. line.len - 1];
                const holt = ", or holt worktree acme/proj/widget feat -r";
                try testing.expect(std.mem.endsWith(u8, cmds, holt));
                const refused = try testutil.runCmd(arena, worktree_cmd.command.run, w.ws, &.{ "acme/proj/widget", "feat", "-r" });
                try testing.expectEqual(@as(u8, 1), refused.code);
                try testing.expect(has(refused.err, "staged changes only "));
                try testing.expectEqual(kept.content.Entry.dir, try kept.content.entryAt(record));
                break :blk cmds[0 .. cmds.len - holt.len];
            },
            .elsewhere => blk: {
                try testing.expect(has(line, "removing the record destroys what it holds: "));
                try testing.expect(std.mem.endsWith(u8, line, try std.fmt.allocPrint(arena, "commit or stash them there (run: git -C {s} stash push)", .{wq})));
                const first = "its directory is gone; bring it back from its record first (run: ";
                const open = std.mem.indexOf(u8, line, first).? + first.len;
                break :blk line[open..std.mem.indexOfPos(u8, line, open, "); ").?];
            },
        };
        const res = try proc.runEnv(arena, &.{ "sh", "-c", relink }, null, &sb.git_env.map);
        if (res.status != 0) {
            std.debug.print("{s}: hint failed: {s}\n{s}\n", .{ @tagName(case), relink, res.stderr });
            return error.TestUnexpectedResult;
        }
        const after = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
        try testing.expect(!has(after.out, lead));
        try testing.expectEqualStrings("only in the index\n", try kept.content.readSmall(arena, try std.fs.path.join(arena, &.{ linked, "staged.txt" })));
        const stash = try proc.runEnv(arena, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "git -C {s} stash push", .{wq}) }, null, &sb.git_env.map);
        try testing.expectEqual(@as(u8, 0), stash.status);
        const stashed = try git.runInRepo(arena, &.{ "stash", "list" }, w.clone);
        try testing.expect(stashed.stdout.len > 0);
    }
}

test "run: a working tree two records name, as a copied record leaves, is named with what is seen there and git worktree list alone, never a removal, leaving both records as they were; once the user removes the copy it is named no more, or named as gone with the commands settling it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Case = enum { there, gone };
    for (std.enums.values(Case)) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try kept_cmd.TestWorld.init(arena, &sb, true);
        defer w.deinit();
        try w.keep(arena, ".clasp.json", "{}\n");
        const linked = try std.fs.path.join(arena, &.{ sb.root, "shared" });
        try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "feat", linked });
        const records = try fsutil.realPathOrSelf(arena, try std.fs.path.join(arena, &.{ w.clone, ".git", "worktrees" }));
        const copy = try std.fs.path.join(arena, &.{ records, "z-copy" });
        const cp = try proc.runEnv(arena, &.{ "cp", "-R", try std.fs.path.join(arena, &.{ records, "shared" }), copy }, null, &sb.git_env.map);
        try testing.expectEqual(@as(u8, 0), cp.status);
        if (case == .gone) try std.Io.Dir.cwd().deleteTree(fsutil.io(), linked);
        const recs = try kept_hooks.snapshot(arena, records, null);

        const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
        const git_in = try std.fmt.allocPrint(arena, "git -C {s}", .{try quoted(arena, w.clone)});
        const want = try std.fmt.allocPrint(arena, "      {s}: a linked working tree whose path more than one worktree record names; holt does not change it: resolve it with git ({s} worktree list), then run again\n", .{ try quoted(arena, linked), git_in });
        if (!has(got.out, want)) {
            std.debug.print("{s}: wanted {s} in:\n{s}\n", .{ @tagName(case), want, got.out });
            return error.TestUnexpectedResult;
        }
        for ([_][]const u8{ " worktree remove ", "worktree prune", "rm -rf", "printf" }) |cmd| try testing.expect(!has(got.out, cmd));
        const res = try proc.runEnv(arena, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "{s} worktree list", .{git_in}) }, null, &sb.git_env.map);
        try testing.expectEqual(@as(u32, 0), res.status);
        try testing.expectEqualStrings(recs, try kept_hooks.snapshot(arena, records, null));

        try std.Io.Dir.cwd().deleteTree(fsutil.io(), copy);
        const after = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
        try testing.expect(!has(after.out, "more than one worktree record"));
        const gone = try std.fmt.allocPrint(arena, "      {s}: a working tree that cannot be read (absent)", .{try quoted(arena, linked)});
        try testing.expectEqual(case == .gone, has(after.out, gone));
    }
}

test "run: a clone status cannot judge is named in the JSON, and one with a working tree git cannot list names it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    const linked = try std.fmt.allocPrint(arena, "{s}@worktrees{c}feat", .{ w.clone, std.fs.path.sep });
    try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "feat", linked });
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), linked);

    const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    const lq = try quoted(arena, linked);
    const cq = try quoted(arena, w.clone);
    const rq = try quoted(arena, try fsutil.joinSlashy(arena, w.clone, ".git/worktrees/feat"));
    const gq = try quoted(arena, try std.fs.path.join(arena, &.{ linked, ".git" }));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "    1 not listed, so what it holds only here is unknown:\n      {s}: a working tree that cannot be read (absent): nothing is at its path; move it back or remount its volume, bring it back from its record, or remove the record once it is gone for good (run: ", .{lq})));
    try testing.expect(has(got.out, try std.fmt.allocPrint(arena, ", or git -C {s} worktree remove {s})\n", .{ cq, lq })));
    if (ui.native_shell == .posix) try testing.expect(has(got.out, try std.fmt.allocPrint(arena, "(run: mkdir -p {s} && printf 'gitdir: %s\\n' {s} > {s} && git -C {s} checkout-index -a, or ", .{ lq, rq, gq, lq })));
    const js = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--json" });
    try testing.expect(has(js.out, "\"unlisted\":1"));

    try std.Io.Dir.cwd().deleteTree(fsutil.io(), try std.fs.path.join(arena, &.{ w.clone, ".git", "worktrees" }));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ w.clone, ".git", "worktrees" }), .data = "not a directory" });
    const broken = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "--json" });
    try testing.expect(has(broken.out, try std.fmt.allocPrint(arena, "\"not_kept\":null,\"will_keep\":null,\"nested\":null,\"unlisted\":null", .{})));
    const esc = try std.mem.replaceOwned(u8, arena, w.clone, "\\", "\\\\");
    try testing.expect(has(broken.out, try std.fmt.allocPrint(arena, "\"unjudged\":[\"{s}\"]", .{esc})));
}

test "run: status writes nothing in holt's machine-local state and takes at most five git calls of its own for a healthy repo" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    try w.keep(arena, ".clasp.json", "{}\n");
    const state = try std.fs.path.join(arena, &.{ sb.root, "state" });
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), state);

    const before = proc.spawn_count.load(.monotonic);
    const got = try testutil.runCmd(arena, command.run, w.ws, &.{ "proj", "-j", "1" });
    const calls = proc.spawn_count.load(.monotonic) - before;
    try testing.expect(has(got.out, "widget: branch=main clean\n"));
    try testing.expect(!has(got.out, "not linked"));
    try testing.expect(calls <= 1 + 5);

    const exclude = try std.fs.path.join(arena, &.{ w.clone, ".git", "info", "exclude" });
    const text = try kept.content.readSmall(arena, exclude);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = exclude, .data = try std.mem.concat(arena, u8, &.{ text, ".env\n" }) });
    _ = try w.write(arena, ".env", "S=1\n");
    const listed = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
    try testing.expect(has(listed.out, "1 file not kept in 1 repo - run: holt keep --review --all\n"));
    try testing.expect(!fsutil.exists(state));
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), try std.fs.path.join(arena, &.{ sb.root, "tmp" }), .{ .iterate = true });
    defer d.close(fsutil.io());
    var it = d.iterate();
    while (try it.next(fsutil.io())) |e| try testing.expect(!std.mem.startsWith(u8, e.name, "holt-report-"));
}

/// Every entry under `dir`, links not followed, each with its kind, size,
/// modification time, and, for a file, its bytes' hash.
fn gitDirSnapshot(a: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), dir, .{ .iterate = true });
    defer d.close(fsutil.io());
    var walker = try d.walk(a);
    defer walker.deinit();
    while (try walker.next(fsutil.io())) |e| {
        const st = try d.statFile(fsutil.io(), e.path, .{ .follow_symlinks = false });
        const hash: [64]u8 = if (e.kind == .file) try kept.content.hashFile(a, try std.fs.path.join(a, &.{ dir, e.path })) else @splat('-');
        try out.append(a, try std.fmt.allocPrint(a, "{s} {s} {d} {d} {s}", .{ e.path, @tagName(e.kind), st.size, st.mtime.nanoseconds, &hash }));
    }
    std.mem.sort([]const u8, out.items, {}, kept.paths.lessThan);
    return out.items;
}

test "status, info, doctor, doctor --retire, and sync --dry-run leave the clone's .git as it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try kept_cmd.TestWorld.init(arena, &sb, true);
    defer w.deinit();
    for (try w.ws.list(arena)) |p| _ = try @import("../hub.zig").reconcile(arena, &w.ws, &p, false);
    try w.keep(arena, ".clasp.json", "{}\n");
    _ = try w.write(arena, "tracked.txt", "t\n");
    try testutil.runGit(&sb, w.clone, &.{ "add", "tracked.txt" });
    try testutil.runGit(&sb, w.clone, &.{ "commit", "-q", "-m", "tracked" });
    try testutil.runGit(&sb, w.clone, &.{ "push", "-q", "origin", "HEAD" });
    const exclude = try std.fs.path.join(arena, &.{ w.clone, ".git", "info", "exclude" });
    const text = try kept.content.readSmall(arena, exclude);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = exclude, .data = try std.mem.concat(arena, u8, &.{ text, ".env\n" }) });
    _ = try w.write(arena, ".env", "S=1\n");
    const git_dir = try std.fs.path.join(arena, &.{ w.clone, ".git" });
    const runs = [_]struct { name: []const u8, cmd: *const fn (ctx: *app.Ctx) anyerror!u8, argv: []const []const u8 }{
        .{ .name = "status", .cmd = command.run, .argv = &.{"proj"} },
        .{ .name = "info", .cmd = @import("info.zig").command.run, .argv = &.{"proj"} },
        .{ .name = "doctor", .cmd = doctor_cmd.command.run, .argv = &.{} },
        .{ .name = "doctor --retire", .cmd = doctor_cmd.command.run, .argv = &.{"--retire"} },
        .{ .name = "sync --dry-run", .cmd = @import("sync.zig").command.run, .argv = &.{"--dry-run"} },
    };
    for (runs) |r| {
        _ = try w.write(arena, "tracked.txt", "t\n");
        const before = try gitDirSnapshot(arena, git_dir);
        _ = try testutil.runCmd(arena, r.cmd, w.ws, r.argv);
        const after = try gitDirSnapshot(arena, git_dir);
        if (before.len != after.len) std.debug.print("{s}: {d} entries became {d}\n", .{ r.name, before.len, after.len });
        try testing.expectEqual(before.len, after.len);
        for (before, after) |x, y| {
            if (!std.mem.eql(u8, x, y)) std.debug.print("{s}: {s}\n  became {s}\n", .{ r.name, x, y });
            try testing.expectEqualStrings(x, y);
        }
    }
}

test "run: status never names a bare rm -rf of a record whose HEAD alone holds a commit: a copied record, and one whose tree's .git does not read as a link or leads nowhere" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Case = enum { copied_record, unparseable_git, dangling_git };
    var failed = false;
    for (std.enums.values(Case)) |case| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try kept_cmd.TestWorld.init(arena, &sb, true);
        defer w.deinit();
        try w.keep(arena, ".clasp.json", "{}\n");
        const linked = try std.fs.path.join(arena, &.{ sb.root, "shared" });
        try testutil.runGit(&sb, w.clone, &.{ "worktree", "add", "-q", "-b", "feat", linked });
        const records = try fsutil.realPathOrSelf(arena, try std.fs.path.join(arena, &.{ w.clone, ".git", "worktrees" }));
        const own = try std.fs.path.join(arena, &.{ records, "shared" });
        const made = try git.runInRepo(arena, &.{ "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "only-in-record" }, w.clone);
        const only = std.mem.trim(u8, made.stdout, " \r\n");
        const victim = switch (case) {
            .copied_record => blk: {
                const copy = try std.fs.path.join(arena, &.{ records, "z-copy" });
                const cp = try proc.runEnv(arena, &.{ "cp", "-R", own, copy }, null, &sb.git_env.map);
                try testing.expectEqual(@as(u8, 0), cp.status);
                try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ copy, "HEAD" }), .data = try std.fmt.allocPrint(arena, "{s}\n", .{only}) });
                break :blk copy;
            },
            .unparseable_git, .dangling_git => blk: {
                try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ own, "HEAD" }), .data = try std.fmt.allocPrint(arena, "{s}\n", .{only}) });
                const text = if (case == .unparseable_git) "not a link\n" else try std.fmt.allocPrint(arena, "gitdir: {s}/moved-away/.git/worktrees/shared\n", .{sb.root});
                try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ linked, ".git" }), .data = text });
                break :blk own;
            },
        };
        const got = try testutil.runCmd(arena, command.run, w.ws, &.{"proj"});
        const seen = switch (case) {
            .copied_record => "a linked working tree whose path more than one worktree record names",
            .unparseable_git => "a linked working tree whose .git does not read as a link to a git directory",
            .dangling_git => "a linked working tree whose .git names a git directory that is not there",
        };
        const named = try std.fmt.allocPrint(arena, "{s}: {s}; holt does not change it: resolve it with git (git -C {s} worktree list), then run again\n", .{ try quoted(arena, linked), seen, try quoted(arena, w.clone) });
        if (!has(got.out, named)) {
            std.debug.print("{s}: wanted {s} in:\n{s}\n", .{ @tagName(case), named, got.out });
            failed = true;
        }
        const bare = try std.fmt.allocPrint(arena, "rm -rf {s}", .{try quoted(arena, victim)});
        if (has(got.out, bare)) {
            std.debug.print("{s}: names {s} though {s} holds commit {s} alone:\n{s}\n", .{ @tagName(case), bare, victim, only, got.out });
            const res = try proc.runEnv(arena, &.{ "sh", "-c", bare }, null, &sb.git_env.map);
            try testing.expectEqual(@as(u32, 0), res.status);
            const all = try git.runInRepo(arena, &.{ "rev-list", "--all", "--reflog" }, w.clone);
            std.debug.print("{s}: after the hint, commit reachable: {}\n", .{ @tagName(case), std.mem.indexOf(u8, all.stdout, only) != null });
            failed = true;
        }
    }
    if (failed) return error.TestUnexpectedResult;
}
