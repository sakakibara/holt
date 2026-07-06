//! `holt restore --all | <project>`: rebuilds derived state that isn't
//! synced content. `--all` clones every member repo missing from
//! `code_root` and rebuilds every project's hub (the new-machine path);
//! `<project>` moves an archived project back into `projects/` (a pure-file
//! move within the synced tree) and rebuilds its hub.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const project_mod = @import("../project.zig");
const common = @import("common.zig");
const marker = @import("../marker.zig");
const git = @import("../git.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const parallel = @import("../parallel.zig");
const diagnostic = @import("../diag.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    project: args.Pos(?[]const u8, .{ .complete = comp.cat(.archived), .help = "unarchive this project and rebuild its hub" }),
    all: args.Flag(.{ .help = "clone every missing repo and rebuild every hub (new-machine path)" }),
    jobs: args.Opt(usize, .{ .short = 'j', .value_name = "N", .help = "with --all, clone in up to N repos concurrently (default: auto; 1 = serial)" }),
};

pub const command = args.command(Spec, .{
    .name = "restore",
    .about = "Clone missing repos and rebuild hubs, or unarchive one project",
    .usage = "holt restore --all [-j N] | <project>",
    .group = .maintain,
    .details =
    \\Example:
    \\  holt restore --all
    ,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const all_flag = a.all;
    const project_spec = a.project;

    if (all_flag and project_spec != null) {
        ctx.args.message = "cannot combine --all with a project argument";
        return error.UsageError;
    }
    if (!all_flag and project_spec == null) {
        ctx.args.message = "requires --all or a <project> argument";
        return error.UsageError;
    }
    if (a.jobs) |n| {
        if (n == 0) {
            ctx.args.message = "-j/--jobs must be at least 1";
            return error.UsageError;
        }
    }

    if (all_flag) return runAll(ctx, a.jobs);
    return runUnarchive(ctx, project_spec.?);
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

fn runAll(ctx: *cli.Ctx, jobs_cap: ?usize) anyerror!u8 {
    const ws = ctx.ws.?;
    const alloc = ctx.alloc;
    const all = try ws.list(alloc);

    // Gather every missing remote clone, deduped by real clone path so a repo
    // shared across projects is fetched once, not once per referencing marker.
    var had_error = false;
    var jobs: std.ArrayList(CloneJob) = .empty;
    var job_of_path = std.StringHashMap(usize).init(alloc);
    for (all) |p| {
        const qualified = try p.qualified(alloc);
        for (p.marker.repos.keys()) |repo_name| {
            const id = p.repoIdentity(alloc, repo_name) catch {
                try ctx.err_w.print("holt: {s}: cannot resolve repo {s} (malformed marker url)\n", .{ qualified, repo_name });
                had_error = true;
                continue;
            };
            if (id.isLocal()) continue;
            const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
            if (fsutil.exists(clone_path)) continue;
            if (job_of_path.contains(clone_path)) continue;
            try job_of_path.put(clone_path, jobs.items.len);
            try jobs.append(alloc, .{ .url = p.marker.repos.get(repo_name).?, .clone_path = clone_path });
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

    for (all) |p| {
        const qualified = try p.qualified(alloc);
        var attempted_any = false;

        for (p.marker.repos.keys()) |repo_name| {
            const id = p.repoIdentity(alloc, repo_name) catch continue;
            if (id.isLocal()) continue;
            const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
            const ji = job_of_path.get(clone_path) orelse continue;
            attempted_any = true;

            if (results[ji].ok) {
                if (!success_printed[ji]) {
                    try ctx.out.print("{s}: cloned {s} -> {s}\n", .{ qualified, repo_name, clone_path });
                    success_printed[ji] = true;
                }
            } else {
                if (!fail_reported[ji]) {
                    try ctx.err_w.print("holt: {s}\n", .{results[ji].message});
                    fail_reported[ji] = true;
                }
                try ctx.err_w.print("holt: could not restore {s} repo {s}\n", .{ qualified, repo_name });
                had_error = true;
            }
        }

        // A member whose url won't resolve was already reported above;
        // reconcile would only re-hit the same failure, so skip this project's
        // hub rather than aborting the whole restore.
        _ = hub.reconcile(alloc, &ws, &p, false) catch |err| switch (err) {
            error.UnrecognizedUrl => continue,
            else => return err,
        };
        if (!attempted_any) try ctx.out.print("{s}: hub rebuilt, no missing clones\n", .{qualified});

        // A local repo has no remote to re-clone, so a missing clone after
        // the pass leaves a dangling hub link only re-adoption can rebuild.
        for (p.marker.repos.keys()) |repo_name| {
            const id = p.repoIdentity(alloc, repo_name) catch continue;
            if (!id.isLocal()) continue;
            const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
            if (fsutil.exists(clone_path)) continue;
            try ctx.err_w.print("holt: {s}: local repo {s} has no remote and its clone is missing; re-adopt it to restore its hub link\n", .{ qualified, repo_name });
        }
    }
    return if (had_error) 1 else 0;
}

fn runUnarchive(ctx: *cli.Ctx, spec: []const u8) anyerror!u8 {
    const ws = ctx.ws.?;
    const alloc = ctx.alloc;

    const on = common.parseOrgName(spec) orelse {
        ctx.args.message = try common.parseOrgNameMessage(alloc, spec);
        return error.UsageError;
    };

    const archive_root = try ws.archiveRoot(alloc);
    const archive_path = try std.fs.path.join(alloc, &.{ archive_root, on.org, on.name });
    const archive_marker = try std.fs.path.join(alloc, &.{ archive_path, marker.marker_basename });
    if (!fsutil.exists(archive_marker)) {
        try ctx.err_w.print("holt: no archived project at {s}\n", .{archive_path});
        return 1;
    }

    const projects_root = try ws.projectsRoot(alloc);
    const dest_path = try std.fs.path.join(alloc, &.{ projects_root, on.org, on.name });
    if (fsutil.exists(dest_path)) {
        try ctx.err_w.print("holt: {s}/{s} already exists in projects\n", .{ on.org, on.name });
        return 1;
    }

    common.moveDir(ctx, archive_path, dest_path) catch return 1;

    const marker_path = try std.fs.path.join(alloc, &.{ dest_path, marker.marker_basename });
    const m = try marker.load(alloc, marker_path, null);
    const hub_path = try std.fs.path.join(alloc, &.{ ws.cfg.hub_root, on.org, on.name });
    const p: project_mod.Project = .{ .org = on.org, .name = on.name, .content_path = dest_path, .hub_path = hub_path, .marker = m };
    _ = hub.reconcile(alloc, &ws, &p, false) catch |err| {
        try common.reportHubFailure(ctx, on.org, on.name, err);
        return 1;
    };

    if (std.fs.path.dirname(archive_path)) |old_archive_org_dir| fsutil.rmdirIfEmpty(old_archive_org_dir);

    try ctx.out.print("restored {s}/{s}\n", .{ on.org, on.name });
    return 0;
}

test "run: --all clones every missing member repo from its bare and rebuilds each hub" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos_first });

    var repos_second: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_second.put(arena, "repob", url_b);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = repos_second });

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{
        .{ .url = url_a, .bare = bare_a },
        .{ .url = url_b, .bare = bare_b },
    });
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--all"});
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

test "run: --all reports and continues past an unreachable repo, still cloning and hubbing the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_good = try testutil.makeBareRepo(&sb, "good.git");
    defer testing.allocator.free(bare_good);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url_good = "https://holt-test.invalid/acme/repogood";
    const url_bad = "git://127.0.0.1:1/acme/repobad";

    var repos_bad: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_bad.put(arena, "repobad", url_bad);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "bad", .{ .version = 1, .org = "acme", .name = "bad", .repos = repos_bad });

    var repos_good: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_good.put(arena, "repogood", url_good);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "good", .{ .version = 1, .org = "acme", .name = "good", .repos = repos_good });

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{
        .{ .url = url_good, .bare = bare_good },
    });
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--all"});
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

test "run: --all warns when a local repo's clone is missing and cannot be re-cloned" {
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--all"});
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

test "run: --all on an already-complete project just rebuilds the hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .{ .version = 1, .org = "acme", .name = "empty", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--all"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "no missing clones") != null);

    const docs_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "empty", "docs" });
    switch (try fsutil.linkState(arena, docs_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: --all clones a repo shared by two projects exactly once and links both hubs" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = repos_first });

    var repos_second: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_second.put(arena, "lib", url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = repos_second });

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--all"});
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

test "run: --all with -j 0 is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_args = try cli.Args.init(arena, &.{ "--all", "-j", "0" });
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.UsageError, command.run(&ctx));
}

test "run: --all reports a repo whose marker url cannot resolve and exits nonzero" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--all"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "acme/proj") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "malformed marker url") != null);
}

test "run: <project> unarchives, moving the marker back and rebuilding its hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "restored acme/widget") != null);

    const archive_dir = try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme", "widget" });
    try testing.expect(!fsutil.exists(archive_dir));

    const marker_path = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget", marker.marker_basename });
    try testing.expect(fsutil.exists(marker_path));

    const docs_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "widget", "docs" });
    switch (try fsutil.linkState(arena, docs_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "run: unarchiving the only project in an org prunes the emptied archive org dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const archive_org_dir = try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme" });
    try testing.expect(fsutil.exists(archive_org_dir));

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(!fsutil.exists(archive_org_dir));
}

test "run: unarchiving a project with no archive entry is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/nope"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "no archived project") != null);
}

test "run: unarchiving over an existing project is a hard error, archive kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists") != null);

    const archive_marker = try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme", "widget", marker.marker_basename });
    try testing.expect(fsutil.exists(archive_marker));
}

test "run: --all together with a project argument is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_args = try cli.Args.init(arena, &.{ "--all", "acme/widget" });
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.UsageError, command.run(&ctx));
}

test "run: neither --all nor a project argument is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.UsageError, command.run(&ctx));
}
