//! `holt restore [<project>]`: clones every member repo missing from
//! `code_root`, rebuilds hubs, and links kept files. With no argument, every
//! project is restored and every clone in the code tree has its kept files
//! linked; with one, only that project and its member clones.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const project_mod = @import("../project.zig");
const common = @import("common.zig");
const git = @import("../git.zig");
const hub = @import("../hub.zig");
const identity = @import("../identity.zig");
const fsutil = @import("../fsutil.zig");
const parallel = @import("../parallel.zig");
const diagnostic = @import("../diag.zig");
const kept_hooks = @import("kept_hooks.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    project: cli.Pos([]const u8, .{ .complete = app.cat(.project), .optional = true, .help = "only restore this project (default: every project)" }),
    jobs: cli.Opt(usize, .{ .short = 'j', .value_name = "N", .help = "clone in up to N repos concurrently (default: auto; 1 = serial)" }),
};

pub const command = app.command(Spec, .{
    .name = "restore",
    .summary = "Clone missing repos and rebuild hubs",
    .usage = "holt restore [<project>] [-j N]",
    .group = .maintain,
    .needs_context = true,
    .details =
    \\Clones every member repo missing from the code tree, rebuilds hubs, and
    \\links kept files. With no argument, every project, and the kept files of
    \\every clone in the code tree; with one, just that project and its member
    \\clones. Exits 1 when a clone fails or a kept file is not linked.
    \\
    \\Example:
    \\  holt restore
    \\  holt restore acme/widget
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    if (a.jobs) |n| {
        if (n == 0) {
            return app.usageError(ctx, "-j/--jobs must be at least 1", .{});
        }
    }

    const ws = ctx.context.?.ws;
    const targets = if (a.project) |q| blk: {
        const p = (try common.resolveOne(ctx, q)) orelse return 1;
        break :blk try ctx.alloc.dupe(project_mod.Project, &.{p});
    } else try ws.list(ctx.alloc);

    const cloned = try runProjects(ctx, targets, a.jobs);
    const kept_bad = try restoreKept(ctx, if (a.project == null) null else targets, a.jobs);
    return if (cloned != 0 or kept_bad) 1 else 0;
}

/// Links the kept files of every clone in the code tree (`only` null), or
/// of the member clones of `only`, and prints `linked N kept files in M
/// repos`, with 0 when `kept/` is not ready, but for a `kept/` that may
/// still be downloading (`kept_hooks.absentLine`). With every clone, auto
/// patterns are kept, the candidates line printed, and each key with kept
/// files, no clone here, and no marker naming it gets its settling
/// commands. True when an unsettled state remains, `kept/` cannot be
/// read, or it is under the synced root holt's links point into instead
/// of this one.
fn restoreKept(ctx: *app.Ctx, only: ?[]const project_mod.Project, jobs: ?usize) !bool {
    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;
    var clones: std.ArrayList([]const u8) = .empty;
    if (only) |projects| {
        for (projects) |p| for (p.marker.entries) |*e| {
            const src = e.source orelse continue;
            const path = try src.id().clonePath(alloc, ws.cfg.code_root);
            if (!fsutil.exists(path)) continue;
            for (clones.items) |c| {
                if (std.mem.eql(u8, c, path)) break;
            } else try clones.append(alloc, path);
        };
    } else try clones.appendSlice(alloc, try ws.listClones(alloc));

    const st = try kept_hooks.storeState(ctx, clones.items);
    if (st != .ready) {
        try kept_hooks.printStore(ctx, ctx.out, st, clones.items);
        if (st != .elsewhere and !(st == .absent and kept_hooks.holdsProjects(ctx))) try ctx.out.writeAll("linked 0 kept files in 0 repos\n");
        return st == .unreadable or st == .elsewhere;
    }
    const targets = try alloc.alloc(kept_hooks.Target, clones.items.len);
    for (clones.items, targets) |c, *t| t.* = .{ .path = c };
    const s = try kept_hooks.run(ctx, ctx.out, targets, .{ .candidates = if (only == null) .auto else .none, .jobs = jobs });
    const n = s.linked + s.retargeted;
    try ctx.out.print("linked {d} kept {s} in {d} {s}\n", .{ n, if (n == 1) "file" else "files", s.linked_repos, if (s.linked_repos == 1) "repo" else "repos" });
    if (only == null) {
        try kept_hooks.printOrphanKeys(ctx, ctx.out, s.keys);
        try kept_hooks.printCandidates(ctx.out, s);
    }
    return s.unsettled > 0;
}

/// One missing clone to fetch. Many markers can reference the same repo (the
/// shared-clone model), so the worklist is deduplicated by `clone_path` before
/// any worker runs: each real clone path is fetched exactly once, and no two
/// workers ever write the same directory.
const CloneJob = struct {
    url: []const u8,
    clone_path: []const u8,
};

const CloneOutcome = struct {
    ok: bool,
    /// git's own failure text, allocated in the task's arena; read on the main
    /// thread before `Arenas.deinit`.
    message: []const u8,
};

/// Runs in a worker thread: allocates only from `arena`, touches no shared
/// state but the read-only job, and calls the concurrency-safe `git.clone`.
fn cloneJob(_: void, arena: std.mem.Allocator, job: CloneJob) CloneOutcome {
    var cd: diagnostic.Diagnostic = .{};
    git.clone(arena, job.url, job.clone_path, &cd) catch {
        const msg = if (cd.message.len == 0) "clone failed" else cd.message;
        return .{ .ok = false, .message = msg };
    };
    return .{ .ok = true, .message = "" };
}

fn runProjects(ctx: *app.Ctx, targets: []const project_mod.Project, jobs_cap: ?usize) anyerror!u8 {
    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    // Gather every missing remote clone, deduped by real clone path so a repo
    // shared across projects is fetched once, not once per referencing marker.
    var had_error = false;
    var jobs: std.ArrayList(CloneJob) = .empty;
    var job_of_path = std.StringHashMap(usize).init(alloc);
    for (targets) |p| {
        const qualified = try p.qualified(alloc);
        for (p.marker.entries) |*e| {
            if (e.raw_source == null) continue;
            const src = e.source orelse {
                try ctx.err.print("holt: {s}: cannot resolve repo {s} (malformed marker url)\n", .{ qualified, e.name });
                had_error = true;
                continue;
            };
            const rem = switch (src) {
                .remote => |r| r,
                .local => continue,
            };
            const clone_path = try rem.id.clonePath(alloc, ws.cfg.code_root);
            if (fsutil.exists(clone_path)) continue;
            if (job_of_path.contains(clone_path)) continue;
            try job_of_path.put(clone_path, jobs.items.len);
            try jobs.append(alloc, .{ .url = rem.url, .clone_path = clone_path });
        }
    }

    const results = try alloc.alloc(CloneOutcome, jobs.items.len);
    var arenas = try parallel.map(void, CloneJob, CloneOutcome, cloneJob, alloc, jobs_cap, {}, jobs.items, results);
    defer arenas.deinit();

    // Render on the main thread, in project order. A job's "cloned" line prints
    // once (at the first project that references it); a failed shared clone is
    // reported against every project that needed it.
    const success_printed = try alloc.alloc(bool, jobs.items.len);
    @memset(success_printed, false);
    const fail_reported = try alloc.alloc(bool, jobs.items.len);
    @memset(fail_reported, false);

    for (targets) |p| {
        const qualified = try p.qualified(alloc);
        var attempted_any = false;

        for (p.marker.entries) |*e| {
            const src = e.source orelse continue;
            const rem = switch (src) {
                .remote => |r| r,
                .local => continue,
            };
            const clone_path = try rem.id.clonePath(alloc, ws.cfg.code_root);
            const ji = job_of_path.get(clone_path) orelse continue;
            attempted_any = true;

            if (results[ji].ok) {
                if (!success_printed[ji]) {
                    try ctx.out.print("{s}: cloned {s} -> {s}\n", .{ qualified, e.name, try app.tilde(ctx, clone_path) });
                    success_printed[ji] = true;
                }
            } else {
                if (!fail_reported[ji]) {
                    try ctx.err.print("holt: {s}\n", .{results[ji].message});
                    fail_reported[ji] = true;
                }
                try ctx.err.print("holt: could not restore {s} repo {s}\n", .{ qualified, e.name });
                had_error = true;
            }
        }

        // A member whose url won't resolve was already reported above;
        // reconcile passes it over, so the project's remaining links are still
        // rebuilt.
        _ = try hub.reconcile(alloc, &ws, &p, false);
        if (!attempted_any) try ctx.out.print("{s}: hub rebuilt, no missing clones\n", .{qualified});

        // A local repo has no remote to re-clone, so a missing clone after
        // the pass leaves a dangling hub link only re-adoption can rebuild.
        for (p.marker.entries) |*e| {
            const src = e.source orelse continue;
            const seg = switch (src) {
                .local => |s| s,
                .remote => continue,
            };
            const clone_path = try identity.local(seg).clonePath(alloc, ws.cfg.code_root);
            if (fsutil.exists(clone_path)) continue;
            try ctx.err.print("holt: {s}: local repo {s} has no remote and its clone is missing; re-adopt it to restore its hub link\n", .{ qualified, e.name });
        }
    }
    return if (had_error) 1 else 0;
}

test "run: with no project argument, clones every missing member repo from its bare and rebuilds each hub" {
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
    const url_a = "https://holt-test.invalid/acme/repoa";
    const url_b = "https://holt-test.invalid/acme/repob";

    var repos_first: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_first.put(arena, "repoa", url_a);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos_first, .empty);

    var repos_second: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_second.put(arena, "repob", url_b);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", repos_second, .empty);

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{
        .{ .url = url_a, .bare = bare_a },
        .{ .url = url_b, .bare = bare_b },
    });
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "cloned repoa") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "cloned repob") != null);

    const clone_a = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repoa" });
    const branch_a = try git.currentBranch(arena, clone_a);
    try testing.expect(branch_a != null);
    const clone_b = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repob" });
    const branch_b = try git.currentBranch(arena, clone_b);
    try testing.expect(branch_b != null);

    const hub_link_a = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "first", "code", "repoa" });
    switch (try fsutil.linkState(arena, hub_link_a)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
    const hub_link_b = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "second", "code", "repob" });
    switch (try fsutil.linkState(arena, hub_link_b)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: with no project argument, reports and continues past an unreachable repo, still cloning and hubbing the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_good = try testutil.makeBareRepo(&sb, "good.git");
    defer testing.allocator.free(bare_good);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url_good = "https://holt-test.invalid/acme/repogood";
    const url_bad = "https://holt-test.invalid/acme/repobad";

    var repos_bad: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_bad.put(arena, "repobad", url_bad);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "bad", repos_bad, .empty);
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "bad", "docs" }));

    var repos_good: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_good.put(arena, "repogood", url_good);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "good", repos_good, .empty);

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{
        .{ .url = url_good, .bare = bare_good },
        .{ .url = url_bad, .bare = try std.fs.path.join(arena, &.{ sb.root, "absent.git" }) },
    });
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "cloned repogood") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "failed to clone") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, url_bad) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "acme/bad") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "repobad") != null);

    const clone_good = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repogood" });
    const branch_good = try git.currentBranch(arena, clone_good);
    try testing.expect(branch_good != null);

    const hub_link_good = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "good", "code", "repogood" });
    switch (try fsutil.linkState(arena, hub_link_good)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }

    const docs_link_bad = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "bad", "docs" });
    switch (try fsutil.linkState(arena, docs_link_bad)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: with no project argument, warns when a local repo's clone is missing and cannot be re-cloned" {
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
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "proj", "docs" }));

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "acme/proj") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "scratch") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "re-adopt") != null);

    const docs_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "docs" });
    switch (try fsutil.linkState(arena, docs_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: with no project argument, an already-complete project just rebuilds its hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .empty, .empty);
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "empty", "docs" }));

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no missing clones") != null);

    const docs_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "empty", "docs" });
    switch (try fsutil.linkState(arena, docs_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: with no project argument, clones a repo shared by two projects exactly once and links both hubs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "shared.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/shared";

    // Both projects name the same repo - the shared-clone case that would race
    // two workers onto one directory without dedup.
    var repos_first: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_first.put(arena, "lib", url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos_first, .empty);

    var repos_second: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_second.put(arena, "lib", url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", repos_second, .empty);

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    // Cloned exactly once despite two referencing markers.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, "cloned lib"));

    const clone = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "shared" });
    try testing.expect((try git.currentBranch(arena, clone)) != null);

    // The hub link is named for the repo's identity ("shared"), not the
    // marker's short key ("lib"); both projects link the one shared clone.
    const hub_first = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "first", "code", "shared" });
    switch (try fsutil.linkState(arena, hub_first)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
    const hub_second = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "second", "code", "shared" });
    switch (try fsutil.linkState(arena, hub_second)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: -j 0 is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try testutil.runCmd(arena, command.run, null, &.{ "-j", "0" });
    try testing.expectEqual(@as(u8, 2), got.code);
}

test "run: with no project argument, reports a repo whose marker url cannot resolve and exits nonzero" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // A bare host is not a resolvable remote; it must be reported, not silently
    // skipped, and it must flip the exit code.
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "bad", "github.com");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "acme/proj") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "malformed marker url") != null);
}

test "run: a marker url that git would read as an option is refused, and nothing is spawned or created for it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // `--upload-pack=<cmd>` names a command git runs. The marker is synced
    // data, so the value must not reach git's option parser at all.
    const artifact = try std.fs.path.join(arena, &.{ root, "pwned" });
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", try std.fmt.allocPrint(arena, "--upload-pack=touch {s}", .{artifact}));
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/proj"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "malformed marker url") != null);
    try testing.expect(!fsutil.exists(artifact));

    // The value never became a clone path either, so code_root stays untouched.
    if (fsutil.exists(ws.cfg.code_root)) {
        var code_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), ws.cfg.code_root, .{ .iterate = true });
        defer code_dir.close(fsutil.io());
        var it = code_dir.iterate();
        try testing.expect((try it.next(fsutil.io())) == null);
    }
}

test "run: a project argument matching no project exits 1 and reports on stderr" {
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

test "run: a bare project argument re-clones that project only, it does not unarchive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/proj") != null);
    // The archive path is `project unarchive`'s job now.
    try testing.expect(std.mem.indexOf(u8, got.err, "no archived project") == null);
}

const kept_test = @import("kept_hooks.zig");
const kept = @import("../kept.zig");

test "run: bare restore links every clone's kept files and names each kept repo with no clone here" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.TestBed.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const key = "github.com/acme/widget";
    const widget = try bed.clone(key);
    try bed.write(widget, "notes.txt", "notes");
    try bed.keep(widget, "notes.txt");
    try bed.remove(widget, "notes.txt");

    const gone = try bed.clone("holt-test.invalid/acme/gone");
    try testutil.runGit(&sb, gone, &.{ "remote", "set-url", "origin", "https://holt-test.invalid/acme/gone" });
    try bed.write(gone, "a.txt", "a");
    try bed.keep(gone, "a.txt");
    const scratch = try bed.clone("local/scratch");
    try testutil.runGit(&sb, scratch, &.{ "remote", "remove", "origin" });
    try bed.write(scratch, "b.txt", "b");
    try bed.keep(scratch, "b.txt");
    const archived = try bed.clone("holt-test.invalid/acme/old");
    try bed.write(archived, "c.txt", "c");
    try bed.keep(archived, "c.txt");
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "old", "https://holt-test.invalid/acme/old");
    try testutil.writeMarker(arena, try bed.ws.archiveRoot(arena), "acme", "past", repos, .empty);
    for ([_][]const u8{ gone, scratch, archived }) |p| try std.Io.Dir.cwd().deleteTree(fsutil.io(), p);

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(try bed.linked(widget, key, "notes.txt"));
    try testing.expect(std.mem.indexOf(u8, got.out, "linked 1 kept file in 1 repo\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "kept/holt-test.invalid/acme/gone has no clone here - run: holt repo get 'https://holt-test.invalid/acme/gone'\n  or, if the repo is no longer wanted, run: holt unkeep --repo holt-test.invalid/acme/gone\n") != null);
    const dest = try bed.shown(try std.fs.path.join(arena, &.{ bed.ws.cfg.code_root, "local", "scratch" }));
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "kept/local/scratch has no clone here and no remote: copy the clone to {s}, then run: holt repo adopt {s}\n  or, if the repo is no longer wanted, run: holt unkeep --repo local/scratch\n", .{ dest, dest })) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/old") == null);
}

test "run: restore <project> links the kept files of its member clones, including ones already there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.TestBed.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const key = "holt-test.invalid/acme/widget";
    const widget = try bed.clone(key);
    const other = try bed.clone("holt-test.invalid/acme/other");
    for ([_][]const u8{ widget, other }) |c| {
        try bed.write(c, "notes.txt", "notes");
        try bed.keep(c, "notes.txt");
        try bed.remove(c, "notes.txt");
    }
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try bed.ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "linked 1 kept file in 1 repo\n") != null);
    try testing.expect(try bed.linked(widget, key, "notes.txt"));
    try testing.expect(!try bed.linked(other, "holt-test.invalid/acme/other", "notes.txt"));
    try testing.expect(std.mem.indexOf(u8, got.out, "has no clone here") == null);

    try bed.remove(widget, "notes.txt");
    try bed.write(widget, "notes.txt", "edited");
    const differs = try testutil.runCmd(arena, command.run, bed.ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 1), differs.code);
    try testing.expect(std.mem.indexOf(u8, differs.out, "local copy differs") != null);
    try testing.expectEqualStrings("edited", try bed.read(widget, "notes.txt"));
}

test "run: restore without kept/ in a synced folder holding projects says kept/ may still be downloading, and prints no link count" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.TestBed.init(arena, &sb, "");
    defer bed.deinit();
    const widget = try bed.clone("github.com/acme/widget");
    try testutil.writeMarker(arena, try bed.ws.projectsRoot(arena), "acme", "proj", .empty, .empty);
    try bed.write(widget, ".git/info/exclude", "/secret.txt\n");
    try bed.write(widget, "secret.txt", "only here");

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no kept/ here yet: if another machine keeps files, wait for your cloud client to download it, then run holt sync; otherwise run holt keep --review --all\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, kept_test.not_set_up) == null);
    try testing.expect(std.mem.indexOf(u8, got.out, "linked 0 kept files") == null);
}

test "run: restore without kept/ prints the first-use line only while a clone holds a file not kept, and links nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.TestBed.init(arena, &sb, "");
    defer bed.deinit();
    const widget = try bed.clone("github.com/acme/widget");

    const none = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), none.code);
    try testing.expect(std.mem.indexOf(u8, none.out, kept_test.not_set_up) == null);

    try bed.write(widget, ".git/info/exclude", "/secret.txt\n");
    try bed.write(widget, "secret.txt", "only here");
    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, kept_test.not_set_up) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "linked 0 kept files in 0 repos\n") != null);
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ bed.ws.cfg.synced_root, "kept" })));
}

test "run: a clone whose kept files cannot be linked is reported, never named as a kept repo with no clone here" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.TestBed.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const key = "holt-test.invalid/acme/broken";
    const broken = try bed.clone(key);
    try bed.write(broken, "a.txt", "a");
    try bed.keep(broken, "a.txt");
    try bed.write(broken, ".git/HEAD", "not a ref");

    const got = try testutil.runCmd(arena, command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "not linked: {s}: ", .{try bed.shown(broken)})) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "has no clone here") == null);
    try testing.expect(std.mem.indexOf(u8, got.out, "linked 0 kept files in 0 repos\n") != null);
}
