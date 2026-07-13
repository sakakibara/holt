//! `holt recent [-n N]`: projects ordered by the most recent commit
//! timestamp (`git log -1 --format=%ct`, the committer date) across their
//! member clones. A project with no clones present (or none with any
//! commits) sorts last.

const std = @import("std");
const Env = @import("env").Env;
const cli = @import("cli");
const app = @import("../app.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const git = @import("../git.zig");
const fsutil = @import("../fsutil.zig");
const parallel = @import("../parallel.zig");
const json = @import("json");
const testing = std.testing;
const testutil = @import("../testutil.zig");
const proc = @import("../proc.zig");

const Spec = struct {
    count: cli.spec.Opt(usize, .{ .short = 'n', .value_name = "N", .help = "show only the N most recently committed projects (default 10)" }),
    org: cli.spec.Opt([]const u8, .{ .value_name = "org", .complete = app.cat(.org), .help = "only include projects under this org" }),
    json: cli.spec.Flag(.{ .help = "emit a JSON array (org, name, and commit timestamp) instead of plain text" }),
    jobs: cli.spec.Opt(usize, .{ .short = 'j', .value_name = "N", .help = "look up commit times in up to N clones concurrently (default: auto; 1 = serial)" }),
};

pub const command = app.command(Spec, .{
    .name = "recent",
    .summary = "List projects ordered by their most recent commit",
    .usage = "holt recent [-n N] [--org <org>] [--json]",
    .group = .inspect,
    .details =
    \\Example:
    \\  holt recent -n 5
    ,
    .needs_context = true,
}, run);

const default_count = 10;

const Entry = struct { p: project_mod.Project, ts: ?i64 };

const CloneTs = anyerror!?i64;

/// `%ct` (committer timestamp, seconds since epoch) of a clone's tip, or null
/// if the clone is missing, unreadable, or has no commits. Runs on a worker
/// thread with its OWN `arena`; every git call here is concurrency-safe.
fn cloneTimestamp(_: void, arena: std.mem.Allocator, clone_path: []const u8) CloneTs {
    if (!fsutil.exists(clone_path)) return null;

    const res = try git.runInRepo(arena, &.{ "log", "-1", "--format=%ct" }, clone_path);
    if (res.status != 0) return null;

    const trimmed = std.mem.trim(u8, res.stdout, "\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

/// `a` before `b`: non-null timestamps sort descending (most recent first);
/// a null timestamp always sorts last.
fn moreRecent(_: void, a: Entry, b: Entry) bool {
    if (a.ts == null) return false;
    if (b.ts == null) return true;
    return a.ts.? > b.ts.?;
}

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    if (a.jobs) |n| {
        if (n == 0) {
            return app.usageError(ctx, "-j/--jobs must be at least 1", .{});
        }
    }
    const jobs = a.jobs;
    const n: usize = a.count orelse default_count;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;
    const listed = try ws.list(alloc);

    // Restrict to one org up front so only its clones get a git lookup.
    var projects: std.ArrayList(project_mod.Project) = .empty;
    for (listed) |p| {
        if (a.org) |org| {
            if (!std.mem.eql(u8, p.org, org)) continue;
        }
        try projects.append(alloc, p);
    }
    const all = projects.items;

    if (all.len == 0) {
        if (a.json) {
            try ctx.out.writeAll("[]\n");
            return 0;
        }
        try ctx.err.writeAll("no projects with commits yet\n");
        return 0;
    }

    // Flatten every project's clones into one worklist so all `git log`
    // lookups share the bounded pool, then fold each project's clone
    // timestamps back into its max. `bounds[i]` is the exclusive end into
    // `results` for project `i` (project-then-repo order, deterministic).
    var total: usize = 0;
    for (all) |p| total += p.marker.repos.keys().len;

    const paths = try alloc.alloc([]const u8, total);
    const bounds = try alloc.alloc(usize, all.len);
    var i: usize = 0;
    for (all, bounds) |p, *b| {
        for (p.marker.repos.keys()) |repo_name| {
            const id = try p.repoIdentity(alloc, repo_name);
            paths[i] = try id.clonePath(alloc, ws.cfg.code_root);
            i += 1;
        }
        b.* = i;
    }

    const results = try alloc.alloc(CloneTs, total);
    var arenas = try parallel.map(void, []const u8, CloneTs, cloneTimestamp, alloc, jobs, {}, paths, results);
    defer arenas.deinit();

    const entries = try alloc.alloc(Entry, all.len);
    var start: usize = 0;
    for (all, entries, bounds) |p, *e, end| {
        var best: ?i64 = null;
        for (results[start..end]) |res| {
            if (try res) |ts| {
                if (best == null or ts > best.?) best = ts;
            }
        }
        e.* = .{ .p = p, .ts = best };
        start = end;
    }

    std.mem.sort(Entry, entries, {}, moreRecent);

    const shown = @min(n, entries.len);

    if (a.json) return runJson(ctx, entries[0..shown]);

    for (entries[0..shown]) |e| {
        const qualified = try e.p.qualified(alloc);
        try ctx.out.print("{s}\n", .{qualified});
    }
    // Signal, rather than silently swallow, the projects beyond the cap.
    if (entries.len > shown) {
        try ctx.err.print("... and {d} more (use -n to show more)\n", .{entries.len - shown});
    }
    return 0;
}

/// Emits the shown entries as a JSON array, one object per project: org, name,
/// and `timestamp` (committer epoch seconds, or null when no clone has a
/// commit). Order matches the human output - most recent first.
fn runJson(ctx: *app.Ctx, entries: []const Entry) anyerror!u8 {
    const alloc = ctx.alloc;
    var items: std.ArrayList(json.Value) = .empty;
    for (entries) |e| {
        var obj: json.ObjectMap = .empty;
        try obj.put(alloc, "org", .{ .string = e.p.org });
        try obj.put(alloc, "name", .{ .string = e.p.name });
        try obj.put(alloc, "timestamp", if (e.ts) |ts| .{ .integer = ts } else .null);
        try items.append(alloc, .{ .object = obj });
    }
    try json.encode(ctx.out, .{ .array = try items.toOwnedSlice(alloc) }, .{});
    try ctx.out.writeByte('\n');
    return 0;
}

/// Empty commit at a controlled committer timestamp (`GIT_AUTHOR_DATE`/
/// `GIT_COMMITTER_DATE`), so ordering tests never race real wall-clock time.
/// Uses `git.runEnv` directly (not `testutil.runGit`, which has no hook for
/// extra env vars), pointing GIT_CONFIG_GLOBAL/SYSTEM at /dev/null so the
/// commit ignores the developer's real gitconfig.
fn commitAtEpoch(alloc: std.mem.Allocator, cwd: []const u8, epoch_seconds: i64) !void {
    const date = try std.fmt.allocPrint(alloc, "@{d} +0000", .{epoch_seconds});

    var map = try Env.current().createMap(alloc);
    defer map.deinit();
    try map.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try map.put("GIT_CONFIG_SYSTEM", "/dev/null");
    try map.put("GIT_AUTHOR_DATE", date);
    try map.put("GIT_COMMITTER_DATE", date);

    const argv = &[_][]const u8{
        "git",                  "-c",                           "user.name=holt-test",
        "-c",                   "user.email=test@holt.invalid", "-c",
        "commit.gpgsign=false", "commit",                       "--allow-empty",
        "-m",                   "dated commit",
    };
    const res = try git.runEnv(alloc, argv, cwd, &map);
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    if (res.status != 0) {
        std.debug.print("git commit failed: {s}\n", .{res.stderr});
        return error.GitCommandFailed;
    }
}

test "run: --org restricts the listing to one org" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "one", .{ .version = 1, .org = "acme", .name = "one", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "two", .{ .version = 1, .org = "acme", .name = "two", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "zebra", "three", .{ .version = 1, .org = "zebra", .name = "three", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "--org", "acme" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/one") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/two") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "zebra/three") == null);
}

test "run: --json emits objects; a project with no commit has a null timestamp" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"--json"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const Rec = struct { org: []const u8, name: []const u8, timestamp: ?i64 };
    const parsed = try json.parseInto([]Rec, arena, got.out, .{});
    try testing.expectEqual(@as(usize, 1), parsed.len);
    try testing.expectEqualStrings("acme", parsed[0].org);
    try testing.expectEqualStrings("proj", parsed[0].name);
    try testing.expect(parsed[0].timestamp == null);
}

test "run: -n caps the list and notes the remainder on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "a", .{ .version = 1, .org = "acme", .name = "a", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "b", .{ .version = 1, .org = "acme", .name = "b", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "c", .{ .version = 1, .org = "acme", .name = "c", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "-n", "1" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, "\n"));
    try testing.expect(std.mem.indexOf(u8, got.err, "and 2 more") != null);
}

test "run: orders projects by their most recent planted commit date, newest first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_old = try testutil.makeBareRepo(&sb, "old.git");
    defer testing.allocator.free(bare_old);
    const bare_new = try testutil.makeBareRepo(&sb, "new.git");
    defer testing.allocator.free(bare_new);

    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos_old: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_old.put(arena, "old-repo", "https://holt-test.invalid/acme/old-repo");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "older", .{ .version = 1, .org = "acme", .name = "older", .repos = repos_old });

    var repos_new: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_new.put(arena, "new-repo", "https://holt-test.invalid/acme/new-repo");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "newer", .{ .version = 1, .org = "acme", .name = "newer", .repos = repos_new });

    const old_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "old-repo" });
    try fsutil.ensureDir(std.fs.path.dirname(old_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_old, old_path });
    try commitAtEpoch(arena, old_path, 1_000_000_000);

    const new_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "new-repo" });
    try fsutil.ensureDir(std.fs.path.dirname(new_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_new, new_path });
    try commitAtEpoch(arena, new_path, 2_000_000_000);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("acme/newer\nacme/older\n", got.out);
}

test "run: a project with no clones present sorts last" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "no-clone", .{ .version = 1, .org = "acme", .name = "no-clone", .repos = .empty });

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "has-clone", "https://holt-test.invalid/acme/has-clone");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "has-clone", .{ .version = 1, .org = "acme", .name = "has-clone", .repos = repos });

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "has-clone" });
    try fsutil.ensureDir(std.fs.path.dirname(clone_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, clone_path });
    try commitAtEpoch(arena, clone_path, 1_500_000_000);

    const got = try testutil.runCmd(arena, command.run, ws, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("acme/has-clone\nacme/no-clone\n", got.out);
}

test "run: -n limits the count shown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "one", .{ .version = 1, .org = "acme", .name = "one", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "two", .{ .version = 1, .org = "acme", .name = "two", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "three", .{ .version = 1, .org = "acme", .name = "three", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "-n", "2" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got.out, "\n"));
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
    try testing.expect(std.mem.indexOf(u8, got.err, "no projects with commits yet") != null);
}

test "run: -j 1 and -j 8 produce byte-identical ordering across many projects and clones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);

    // Six projects; a couple carry two clones so the per-project max-timestamp
    // aggregation (not just a single lookup) is exercised. Epochs are chosen
    // so the newest clone in each project produces a strict, unambiguous order.
    const specs = [_]struct { name: []const u8, epochs: []const i64 }{
        .{ .name = "p0", .epochs = &.{1_000_000_000} },
        .{ .name = "p1", .epochs = &.{ 1_200_000_000, 1_900_000_000 } },
        .{ .name = "p2", .epochs = &.{1_500_000_000} },
        .{ .name = "p3", .epochs = &.{ 1_100_000_000, 1_700_000_000 } },
        .{ .name = "p4", .epochs = &.{1_300_000_000} },
        .{ .name = "p5", .epochs = &.{1_800_000_000} },
    };

    for (specs) |spec| {
        var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (spec.epochs, 0..) |epoch, ri| {
            const repo_name = try std.fmt.allocPrint(arena, "{s}-r{d}", .{ spec.name, ri });
            const url = try std.fmt.allocPrint(arena, "https://holt-test.invalid/acme/{s}", .{repo_name});
            try repos.put(arena, repo_name, url);

            const path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", repo_name });
            try fsutil.ensureDir(std.fs.path.dirname(path).?);
            try testutil.runGit(&sb, null, &.{ "clone", bare, path });
            try commitAtEpoch(arena, path, epoch);
        }
        try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", spec.name, .{ .version = 1, .org = "acme", .name = spec.name, .repos = repos });
    }

    const serial = try testutil.runCmd(arena, command.run, ws, &.{ "-j", "1" });
    const parallel_run = try testutil.runCmd(arena, command.run, ws, &.{ "-j", "8" });

    try testing.expectEqual(@as(u8, 0), serial.code);
    try testing.expectEqual(@as(u8, 0), parallel_run.code);
    try testing.expectEqualStrings(serial.out, parallel_run.out);
    // Newest-first: p1 (1.9e9) leads, p0 (1.0e9) trails.
    try testing.expectEqualStrings("acme/p1\nacme/p5\nacme/p3\nacme/p2\nacme/p4\nacme/p0\n", serial.out);
}

test "cloneTimestamp: matches a direct `git log -1 --format=%ct` for a valid clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    const want = try git.run(arena, &.{ "git", "log", "-1", "--format=%ct" }, work);
    const want_ts = try std.fmt.parseInt(i64, std.mem.trim(u8, want.stdout, "\n"), 10);

    const got = try cloneTimestamp({}, arena, work);
    try testing.expect(got != null);
    try testing.expectEqual(want_ts, got.?);
}

test "cloneTimestamp: reads a present clone's tip with exactly one git subprocess (was two)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    // recent reads each clone's tip with ONE git call (was two: inspectable +
    // git log). A regression that re-adds the inspectable precheck fails here.
    const before = proc.spawn_count.load(.monotonic);
    const got = try cloneTimestamp({}, arena, work);
    const after = proc.spawn_count.load(.monotonic);

    try testing.expect(got != null);
    try testing.expectEqual(@as(u64, 1), after - before);
}

test "cloneTimestamp: null for a clone with a corrupted .git (HEAD overwritten with garbage)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const work = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(work);

    const head_path = try std.fs.path.join(arena, &.{ work, ".git", "HEAD" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = head_path, .data = "garbage, not a ref\n" });

    try testing.expect(try cloneTimestamp({}, arena, work) == null);
}

test "cloneTimestamp: null for a plain non-repo directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    try testing.expect(try cloneTimestamp({}, arena, root) == null);
}

test "cloneTimestamp: null for a non-repo subdirectory nested inside a parent git repo (ceiling guard)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    try testutil.runGit(&sb, null, &.{ "init", "-q", sb.root });
    try testutil.runGit(&sb, sb.root, &.{ "commit", "--allow-empty", "-m", "parent commit" });

    const sub = try std.fs.path.join(arena, &.{ sb.root, "sub" });
    try fsutil.ensureDir(sub);

    // Without the ceiling guard this would resolve `sb.root`'s HEAD and
    // return its timestamp instead of null.
    try testing.expect(try cloneTimestamp({}, arena, sub) == null);
}

test "cloneTimestamp: null for a missing path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const missing = try std.fs.path.join(arena, &.{ sb.root, "does-not-exist" });
    try testing.expect(try cloneTimestamp({}, arena, missing) == null);
}
