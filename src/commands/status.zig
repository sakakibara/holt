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
const json = @import("json");
const testing = std.testing;
const testutil = @import("../testutil.zig");
const proc = @import("../proc.zig");

const color_red = "31";
const color_green = "32";
const color_yellow = "33";

const ignore_exact = [_][]const u8{ ".claude", ".DS_Store", ".git" };

fn isIgnored(name: []const u8) bool {
    for (ignore_exact) |n| if (std.mem.eql(u8, name, n)) return true;
    if (std.mem.endsWith(u8, name, ".swp")) return true; // vim swap
    if (std.mem.endsWith(u8, name, "~")) return true; // editor backup
    if (std.mem.startsWith(u8, name, ".#")) return true; // emacs lock
    return false;
}

/// Real (non-symlink) hub-root entries that are not `code` and not ignored -
/// the loose local files that do not sync.
fn localOnlyEntries(alloc: std.mem.Allocator, p: project_mod.Project) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.openDirAbsolute(fsutil.io(), p.hub_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return names.toOwnedSlice(alloc),
        else => return err,
    };
    defer dir.close(fsutil.io());
    var it = dir.iterate();
    while (try it.next(fsutil.io())) |entry| {
        if (entry.kind == .sym_link) continue; // a managed mirror/code link
        if (std.mem.eql(u8, entry.name, "code")) continue;
        if (isIgnored(entry.name)) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(alloc);
}

const Spec = struct {
    // org/jobs are options and must be parsed before the positional below: a
    // bare positional scan would otherwise mistake either's value token for
    // the project query.
    org: cli.spec.Opt([]const u8, .{ .value_name = "org", .complete = app.cat(.org), .help = "with no <project> given, only show projects in this org" }),
    jobs: cli.spec.Opt(usize, .{ .short = 'j', .value_name = "N", .help = "probe up to N repos concurrently (default: auto; 1 = serial)" }),
    project: cli.spec.Pos([]const u8, .{ .complete = app.cat(.project), .optional = true, .help = "only show this project's member repos" }),
    dirty: cli.spec.Flag(.{ .help = "only show repos with a finding (dirty, unpushed, missing)" }),
    json: cli.spec.Flag(.{ .help = "emit a JSON array instead of plain text (ignores --dirty)" }),
};

pub const command = app.command(Spec, .{
    .name = "status",
    .summary = "Show git status across a project's (or every project's) member repos",
    .usage = "holt status [<project>] [--dirty] [--org <org>] [--json]",
    .group = .inspect,
    .needs_context = true,
    .details =
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

const Probed = struct {
    /// Flattened member repos across `targets`, in project-then-repo order.
    repo_names: [][]const u8,
    /// `bounds[i]` is the exclusive end index into `results`/`repo_names` for
    /// `targets[i]`; `bounds[i-1]` (or 0) is its start.
    bounds: []usize,
    results: []Probe,
    arenas: parallel.Arenas,

    fn deinit(self: *Probed) void {
        self.arenas.deinit();
    }
};

/// Probes every member repo of every project in `targets` through the bounded
/// pool, preserving project-then-repo order so rendering is deterministic
/// regardless of the worker count.
fn probeTargets(alloc: std.mem.Allocator, ws: *const workspace.Workspace, targets: []const project_mod.Project, jobs: ?usize) !Probed {
    var total: usize = 0;
    for (targets) |p| total += p.marker.repos.keys().len;

    const paths = try alloc.alloc([]const u8, total);
    const repo_names = try alloc.alloc([]const u8, total);
    const bounds = try alloc.alloc(usize, targets.len);

    var i: usize = 0;
    for (targets, bounds) |p, *b| {
        for (p.marker.repos.keys()) |repo_name| {
            const id = try p.repoIdentity(alloc, repo_name);
            paths[i] = try id.clonePath(alloc, ws.cfg.code_root);
            repo_names[i] = repo_name;
            i += 1;
        }
        b.* = i;
    }

    const results = try alloc.alloc(Probe, total);
    const arenas = try parallel.map(void, []const u8, Probe, probe, alloc, jobs, {}, paths, results);
    return .{ .repo_names = repo_names, .bounds = bounds, .results = results, .arenas = arenas };
}

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
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

    if (json_flag) return runJson(ctx, &ws, org_filter, project_query, jobs);

    if (project_query) |q| {
        const p = (try common.resolveOne(ctx, q)) orelse return 1;
        if (p.marker.repos.keys().len == 0 and (try localOnlyEntries(alloc, p)).len == 0) {
            const qualified = try p.qualified(alloc);
            try ctx.err.print("{s} has no member repos\n", .{qualified});
            return 0;
        }
        const one = try alloc.alloc(project_mod.Project, 1);
        one[0] = p;
        return report(ctx, &ws, one, dirty_only, jobs);
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
        try ctx.err.writeAll("no projects yet - create one with \"holt new <org>/<name>\"\n");
        return 0;
    }

    return report(ctx, &ws, targets, dirty_only, jobs);
}

/// Emits `org_filter`/`project_query`'s selected projects as a compact JSON
/// array: `{ project, repos: [{ name, state, branch }] }`. `state` collapses
/// dirty/unpushed findings into one of clean|dirty|unpushed|no-upstream|
/// missing|unreadable, in that precedence when more than one applies. Never
/// prints the human empty-state message - an empty result is `[]`.
fn runJson(ctx: *app.Ctx, ws: *const workspace.Workspace, org_filter: ?[]const u8, project_query: ?[]const u8, jobs: ?usize) anyerror!u8 {
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

    var items: std.ArrayList(json.Value) = .empty;
    var start: usize = 0;
    for (targets, probed.bounds) |p, end| {
        const qualified = try p.qualified(alloc);

        var repo_items: std.ArrayList(json.Value) = .empty;
        for (probed.repo_names[start..end], probed.results[start..end]) |repo_name, res| {
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
            try repo_items.append(alloc, .{ .object = repo_obj });
        }

        const locals = try localOnlyEntries(alloc, p);
        var local_items: std.ArrayList(json.Value) = .empty;
        for (locals) |name| try local_items.append(alloc, .{ .string = name });

        var obj: json.ObjectMap = .empty;
        try obj.put(alloc, "project", .{ .string = qualified });
        try obj.put(alloc, "repos", .{ .array = try repo_items.toOwnedSlice(alloc) });
        try obj.put(alloc, "local_only", .{ .array = try local_items.toOwnedSlice(alloc) });
        try items.append(alloc, .{ .object = obj });
        start = end;
    }

    try json.encode(ctx.out, .{ .array = try items.toOwnedSlice(alloc) }, .{});
    try ctx.out.writeByte('\n');
    return 0;
}

/// Renders one line for `repo_name` in `st`, honoring `dirty_only`; null when
/// the repo has no finding and `dirty_only` is set. Owned by `alloc`.
fn formatLine(ctx: *app.Ctx, alloc: std.mem.Allocator, repo_name: []const u8, st: RepoState, dirty_only: bool) !?[]const u8 {
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
            if (dirty_only and !has_finding) return null;

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
            return aw.written();
        },
    }
}

fn report(ctx: *app.Ctx, ws: *const workspace.Workspace, targets: []const project_mod.Project, dirty_only: bool, jobs: ?usize) !u8 {
    const alloc = ctx.alloc;

    var probed = try probeTargets(alloc, ws, targets, jobs);
    defer probed.deinit();

    var start: usize = 0;
    for (targets, probed.bounds) |p, end| {
        var lines: std.ArrayList([]const u8) = .empty;
        for (probed.repo_names[start..end], probed.results[start..end]) |repo_name, res| {
            const st = try res;
            if (try formatLine(ctx, alloc, repo_name, st, dirty_only)) |line| try lines.append(alloc, line);
        }
        start = end;

        const locals = try localOnlyEntries(alloc, p);
        if (lines.items.len == 0 and locals.len == 0) continue;
        const qualified = try p.qualified(alloc);
        try ctx.out.print("{s}\n", .{qualified});
        for (lines.items) |line| try ctx.out.writeAll(line);
        if (locals.len > 0) {
            try ctx.out.writeAll("  local-only (not synced):\n");
            for (locals) |name| try ctx.out.print("    {s} (run: holt keep {s})\n", .{ name, name });
        }
    }
    return 0;
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos_a });

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "other-missing", "https://holt-test.invalid/acme/other-missing");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = repos_b });

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

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

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty-proj", .{ .version = 1, .org = "acme", .name = "empty-proj", .repos = .empty });

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos_acme });

    var repos_other: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_other.put(arena, "gone", "https://holt-test.invalid/other/gone");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "other", "second", .{ .version = 1, .org = "other", .name = "second", .repos = repos_other });

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

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

    const Repo = struct { name: []const u8, state: []const u8, branch: ?[]const u8 };
    const Entry = struct { project: []const u8, repos: []Repo, local_only: [][]const u8 };
    const parsed = try json.parseInto([]Entry, arena, got.out, .{});
    try testing.expectEqual(@as(usize, 1), parsed.len);
    try testing.expectEqualStrings("acme/proj", parsed[0].project);

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });
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
        try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", proj, .{ .version = 1, .org = "acme", .name = proj, .repos = repos });
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
