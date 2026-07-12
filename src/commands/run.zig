//! `holt run <project> [--repo <name>] -- <cmd...>`, `holt run --org <org>
//! -- <cmd...>`, or `holt run --all -- <cmd...>`: runs a command in each
//! selected member repo's real clone path. A single-project run headers each
//! block `==> <repo>`; a run spanning multiple projects headers each block
//! `==> <host>/<owner>/<repo>` (the repo's identity relPath) since a bare
//! repo name is no longer unique. Because one repo can be a member of
//! several projects, an --org/--all run collects the set of unique real
//! clone paths first and runs the command once per clone, never once per
//! project membership. The child inherits holt's own stdio, so an
//! interactive or long-running command (a dev server, a pager, colorized
//! test output) gets a real terminal and streams live in the child's own
//! interleaving, rather than being captured and replayed only after it
//! exits. A missing clone is reported and skipped, not fatal; a nonzero
//! exit from one repo doesn't stop the rest, but is reflected in the
//! command's own exit code once every repo has been attempted.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const proc = @import("../proc.zig");
const fsutil = @import("../fsutil.zig");
const parallel = @import("../parallel.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    org: cli.spec.Opt([]const u8, .{ .value_name = "org", .complete = app.cat(.org), .help = "run in every member repo of every project in this org" }),
    repo: cli.spec.Opt([]const u8, .{ .value_name = "repo", .complete = app.cat(.repo), .help = "run in only this member repo (single-project form only)" }),
    jobs: cli.spec.Opt(usize, .{ .short = 'j', .value_name = "N", .help = "run in up to N repos concurrently (default 1: serial, streaming live)" }),
    all: cli.spec.Flag(.{ .help = "run in every member repo of every project in the workspace" }),
    project: cli.spec.Pos([]const u8, .{ .complete = app.cat(.project), .optional = true, .help = "the project whose member repos to run in" }),
    cmd: cli.spec.Rest(.{ .help = "the command to run in each repo (after --)" }),
};

const about: app.About = .{
    .name = "run",
    .summary = "Run a command in each member repo's clone",
    .usage = "holt run (<project> | --org <org> | --all) [--repo <repo>] -- <cmd...>",
    .group = .maintain,
    .needs_context = true,
    .details =
    \\Exactly one of <project>, --org, or --all must be given. A repo shared
    \\across projects is one physical clone; the command runs there once,
    \\not once per project that references it.
    \\
    \\Everything after "--" is passed through verbatim to each repo's clone.
    \\
    \\Example:
    \\  holt run myproj -- git status
    \\  holt run --org acme -- git pull
    \\  holt run --all -- git fetch
    ,
};

/// `project` (an optional positional) and `cmd` (a `Rest` tail) are resolved
/// natively by cli-zig's `parseInto`: a fixed positional paired with a
/// `Rest` field only fills from tokens before a literal "--", so `run`'s own
/// "--" always introduces the child command and never gets mistaken for a
/// value for `project`.
pub const command = app.command(Spec, about, run);

const Target = struct {
    header: []const u8,
    clone_path: []const u8,
};

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const cmd = a.cmd;
    if (cmd.len == 0) {
        return app.usageError(ctx, "missing command after --", .{});
    }
    if (a.jobs) |n| {
        if (n == 0) {
            return app.usageError(ctx, "-j/--jobs must be at least 1", .{});
        }
    }

    const org_filter = a.org;
    const all_flag = a.all;
    const repo_filter = a.repo;
    const jobs = a.jobs;
    const project_query = a.project;

    const selector_count: u8 = (if (project_query != null) @as(u8, 1) else 0) +
        (if (org_filter != null) @as(u8, 1) else 0) +
        (if (all_flag) @as(u8, 1) else 0);
    if (selector_count != 1) {
        return app.usageError(ctx, "specify exactly one of <project>, --org <org>, or --all", .{});
    }
    if (repo_filter != null and (org_filter != null or all_flag)) {
        return app.usageError(ctx, "--repo cannot be combined with --org or --all", .{});
    }

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    if (project_query) |query| {
        return runSingleProject(ctx, ws, alloc, query, repo_filter, cmd, jobs);
    }

    var projects = try ws.list(alloc);
    if (org_filter) |org| {
        var filtered: std.ArrayList(project_mod.Project) = .empty;
        for (projects) |p| {
            if (std.mem.eql(u8, p.org, org)) try filtered.append(alloc, p);
        }
        projects = try filtered.toOwnedSlice(alloc);
    }

    return runAcrossProjects(ctx, ws, alloc, projects, cmd, jobs);
}

fn runSingleProject(ctx: *app.Ctx, ws: workspace.Workspace, alloc: std.mem.Allocator, query: []const u8, repo_filter: ?[]const u8, cmd: []const []const u8, jobs: ?usize) anyerror!u8 {
    const p = (try common.resolveOne(ctx, query)) orelse return 1;

    if (p.marker.repos.keys().len == 0) {
        const qualified = try p.qualified(alloc);
        try ctx.err.print("{s} has no member repos\n", .{qualified});
        return 0;
    }

    var repo_names: []const []const u8 = p.marker.repos.keys();
    if (repo_filter) |name| {
        if (!p.marker.repos.contains(name)) {
            const qualified = try p.qualified(alloc);
            try ctx.err.print("holt: {s} has no member repo named \"{s}\"\n", .{ qualified, name });
            return 1;
        }
        const one = try alloc.alloc([]const u8, 1);
        one[0] = name;
        repo_names = one;
    }

    var targets: std.ArrayList(Target) = .empty;
    for (repo_names) |repo_name| {
        const id = try p.repoIdentity(alloc, repo_name);
        const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
        try targets.append(alloc, .{ .header = repo_name, .clone_path = clone_path });
    }

    return runTargets(ctx, alloc, cmd, targets.items, jobs);
}

/// Collects the unique real clone paths across every member repo of every
/// project in `projects`, so a repo shared by more than one project runs the
/// command exactly once rather than once per project that references it.
fn runAcrossProjects(ctx: *app.Ctx, ws: workspace.Workspace, alloc: std.mem.Allocator, projects: []const project_mod.Project, cmd: []const []const u8, jobs: ?usize) anyerror!u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var targets: std.ArrayList(Target) = .empty;

    for (projects) |p| {
        for (p.marker.repos.keys()) |repo_name| {
            const id = try p.repoIdentity(alloc, repo_name);
            const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
            if (seen.contains(clone_path)) continue;
            try seen.put(alloc, clone_path, {});

            const header = try id.relPath(alloc);
            try targets.append(alloc, .{ .header = header, .clone_path = clone_path });
        }
    }

    return runTargets(ctx, alloc, cmd, targets.items, jobs);
}

fn captureEnabled(alloc: std.mem.Allocator) !bool {
    const environ = std.Io.Threaded.global_single_threaded.environ.process_environ;
    return std.process.Environ.containsUnempty(environ, alloc, "HOLT_RUN_CAPTURE");
}

/// `-j 1` (the default) runs serially and, unless HOLT_RUN_CAPTURE is set,
/// lets each child stream live to the terminal; `-j N>1` runs up to N children
/// concurrently with captured output, replayed per repo in input order.
fn runTargets(ctx: *app.Ctx, alloc: std.mem.Allocator, cmd: []const []const u8, targets: []const Target, jobs: ?usize) anyerror!u8 {
    if ((jobs orelse 1) > 1) return runParallel(ctx, alloc, cmd, targets, jobs);
    return runSerial(ctx, alloc, cmd, targets);
}

fn runSerial(ctx: *app.Ctx, alloc: std.mem.Allocator, cmd: []const []const u8, targets: []const Target) anyerror!u8 {
    const capture = try captureEnabled(alloc);

    var any_failed = false;
    for (targets) |t| {
        // Flushed before spawning so the header can't land after the
        // child's own (inherited, live) output in the real terminal.
        try ctx.out.print("==> {s}\n", .{t.header});
        try ctx.out.flush();

        if (!fsutil.exists(t.clone_path)) {
            try ctx.out.writeAll("  missing\n");
            continue;
        }

        const spawn_result: anyerror!u8 = if (capture)
            runCaptured(ctx, alloc, cmd, t.clone_path)
        else
            proc.spawnInherited(alloc, cmd, t.clone_path);
        const status = spawn_result catch |err| {
            if (err == error.FileNotFound) {
                try ctx.err.print("holt: command \"{s}\" not found\n", .{cmd[0]});
                return 1;
            }
            return err;
        };
        if (status != 0) {
            any_failed = true;
            try ctx.out.print("  exited {d}\n", .{status});
        }
    }

    return if (any_failed) 1 else 0;
}

const RunOut = struct {
    missing: bool = false,
    not_found: bool = false,
    status: u8 = 0,
    output: []const u8 = "",
};

const RunProbe = anyerror!RunOut;

/// Runs `cmd` in one clone with captured stdout+stderr. Worker-thread task:
/// allocates only from its OWN `arena` (proc.run's output plus the joined
/// block), never the caller's arena.
fn runTask(cmd: []const []const u8, arena: std.mem.Allocator, clone_path: []const u8) RunProbe {
    if (!fsutil.exists(clone_path)) return .{ .missing = true };
    const res = proc.run(arena, cmd, clone_path) catch |err| {
        if (err == error.FileNotFound) return .{ .not_found = true };
        return err;
    };
    var buf: std.Io.Writer.Allocating = .init(arena);
    try buf.writer.writeAll(res.stdout);
    try buf.writer.writeAll(res.stderr);
    return .{ .status = res.status, .output = buf.written() };
}

/// Runs `cmd` across `targets` through the bounded pool, then replays each
/// repo's captured block under its header in input order (deterministic
/// regardless of completion order). Aggregate exit is nonzero if any child
/// failed; a missing command is reported once by name, mirroring the serial
/// path.
fn runParallel(ctx: *app.Ctx, alloc: std.mem.Allocator, cmd: []const []const u8, targets: []const Target, jobs: ?usize) anyerror!u8 {
    const items = try alloc.alloc([]const u8, targets.len);
    for (targets, items) |t, *it| it.* = t.clone_path;

    const results = try alloc.alloc(RunProbe, targets.len);
    var arenas = try parallel.map([]const []const u8, []const u8, RunProbe, runTask, alloc, jobs, cmd, items, results);
    defer arenas.deinit();

    for (results) |res| {
        if ((try res).not_found) {
            try ctx.err.print("holt: command \"{s}\" not found\n", .{cmd[0]});
            return 1;
        }
    }

    var any_failed = false;
    for (targets, results) |t, res| {
        const o = try res;
        try ctx.out.print("==> {s}\n", .{t.header});
        if (o.missing) {
            try ctx.out.writeAll("  missing\n");
            continue;
        }
        try ctx.out.writeAll(o.output);
        if (o.status != 0) {
            any_failed = true;
            try ctx.out.print("  exited {d}\n", .{o.status});
        }
    }

    return if (any_failed) 1 else 0;
}

/// Spawns `argv` with piped stdout/stderr, writing the captured output to
/// `ctx.out` once the child exits. Test-only path: inheriting the test
/// runner's own stdio would corrupt its `--listen` IPC on fd 1.
fn runCaptured(ctx: *app.Ctx, alloc: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !u8 {
    const res = try proc.run(alloc, argv, cwd);
    try ctx.out.writeAll(res.stdout);
    try ctx.out.writeAll(res.stderr);
    return res.status;
}

fn installCapture(alloc: std.mem.Allocator) !testutil.EnvOverride {
    return testutil.EnvOverride.install(alloc, "HOLT_RUN_CAPTURE", "1");
}

test "run: touches a marker file in each of 2 member clones, exit 0" {
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
    try repos.put(arena, "repo-a", "https://holt-test.invalid/acme/repo-a");
    try repos.put(arena, "repo-b", "https://holt-test.invalid/acme/repo-b");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const path_a = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-a" });
    try fsutil.ensureDir(std.fs.path.dirname(path_a).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_a, path_a });

    const path_b = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-b" });
    try fsutil.ensureDir(std.fs.path.dirname(path_b).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_b, path_b });

    const override = try installCapture(arena);
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--", "touch", "marker-file" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "==> repo-a") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "==> repo-b") != null);

    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path_a, "marker-file" })));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path_b, "marker-file" })));
}

test "run: with HOLT_RUN_CAPTURE set, a child's stdout appears in ctx.out under its repo header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_a = try testutil.makeBareRepo(&sb, "a.git");
    defer testing.allocator.free(bare_a);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "repo-a", "https://holt-test.invalid/acme/repo-a");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const path_a = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-a" });
    try fsutil.ensureDir(std.fs.path.dirname(path_a).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_a, path_a });

    const override = try installCapture(arena);
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--", "echo", "hello-from-child" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const header_at = std.mem.indexOf(u8, got.out, "==> repo-a") orelse return error.TestExpectedEqual;
    const child_at = std.mem.indexOf(u8, got.out, "hello-from-child") orelse return error.TestExpectedEqual;
    try testing.expect(child_at > header_at);
}

test "run: a failing command in one repo doesn't stop the other, but the overall exit is 1" {
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
    try repos.put(arena, "repo-a", "https://holt-test.invalid/acme/repo-a");
    try repos.put(arena, "repo-b", "https://holt-test.invalid/acme/repo-b");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const path_a = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-a" });
    try fsutil.ensureDir(std.fs.path.dirname(path_a).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_a, path_a });

    const path_b = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-b" });
    try fsutil.ensureDir(std.fs.path.dirname(path_b).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_b, path_b });

    const override = try installCapture(arena);
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--", "sh", "-c", "touch ran; exit 3" });
    try testing.expectEqual(@as(u8, 1), got.code);

    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path_a, "ran" })));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path_b, "ran" })));
}

test "run: --repo limits execution to a single member" {
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
    try repos.put(arena, "repo-a", "https://holt-test.invalid/acme/repo-a");
    try repos.put(arena, "repo-b", "https://holt-test.invalid/acme/repo-b");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const path_a = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-a" });
    try fsutil.ensureDir(std.fs.path.dirname(path_a).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_a, path_a });

    const path_b = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-b" });
    try fsutil.ensureDir(std.fs.path.dirname(path_b).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_b, path_b });

    const override = try installCapture(arena);
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--repo", "repo-a", "--", "touch", "only-a" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "==> repo-a") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "==> repo-b") == null);
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path_a, "only-a" })));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ path_b, "only-a" })));
}

test "run: a missing clone is reported and skipped, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "gone", "https://holt-test.invalid/acme/gone");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const override = try installCapture(arena);
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--", "echo", "hi" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "==> gone") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "missing") != null);
}

test "run: missing -- separator is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj"});
    try testing.expectEqual(@as(u8, 2), got.code);
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

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "nope", "--", "echo", "hi" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "run: a command that doesn't exist is reported by name, not as a raw FileNotFound" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "a.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "repo-a", "https://holt-test.invalid/acme/repo-a");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const path_a = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-a" });
    try fsutil.ensureDir(std.fs.path.dirname(path_a).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, path_a });

    const override = try installCapture(arena);
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "--", "definitely-not-a-real-command-xyz" });
    try testing.expect(got.code != 0);
    try testing.expect(std.mem.indexOf(u8, got.err, "command \"definitely-not-a-real-command-xyz\" not found") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "FileNotFound") == null);
}

test "run: a project with no member repos reports so instead of printing nothing, exit 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty-proj", .{ .version = 1, .org = "acme", .name = "empty-proj", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "acme/empty-proj", "--", "echo", "hi" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("", got.out);
    try testing.expect(std.mem.indexOf(u8, got.err, "acme/empty-proj has no member repos") != null);
}

test "run: --org runs in every member repo of every project in that org" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_a = try testutil.makeBareRepo(&sb, "a.git");
    defer testing.allocator.free(bare_a);
    const bare_b = try testutil.makeBareRepo(&sb, "b.git");
    defer testing.allocator.free(bare_b);
    const bare_c = try testutil.makeBareRepo(&sb, "c.git");
    defer testing.allocator.free(bare_c);

    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos_1: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_1.put(arena, "repo-a", "https://holt-test.invalid/acme/repo-a");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj1", .{ .version = 1, .org = "acme", .name = "proj1", .repos = repos_1 });

    var repos_2: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_2.put(arena, "repo-b", "https://holt-test.invalid/acme/repo-b");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj2", .{ .version = 1, .org = "acme", .name = "proj2", .repos = repos_2 });

    var repos_other: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_other.put(arena, "repo-c", "https://holt-test.invalid/other/repo-c");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "other", "proj3", .{ .version = 1, .org = "other", .name = "proj3", .repos = repos_other });

    const path_a = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-a" });
    try fsutil.ensureDir(std.fs.path.dirname(path_a).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_a, path_a });

    const path_b = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-b" });
    try fsutil.ensureDir(std.fs.path.dirname(path_b).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_b, path_b });

    const path_c = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "other", "repo-c" });
    try fsutil.ensureDir(std.fs.path.dirname(path_c).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_c, path_c });

    const override = try installCapture(arena);
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "--org", "acme", "--", "touch", "org-marker" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "==> holt-test.invalid/acme/repo-a") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "==> holt-test.invalid/acme/repo-b") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "repo-c") == null);

    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path_a, "org-marker" })));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path_b, "org-marker" })));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ path_c, "org-marker" })));
}

test "run: --all spans every project in the workspace" {
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

    var repos_acme: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_acme.put(arena, "repo-a", "https://holt-test.invalid/acme/repo-a");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj1", .{ .version = 1, .org = "acme", .name = "proj1", .repos = repos_acme });

    var repos_other: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_other.put(arena, "repo-b", "https://holt-test.invalid/other/repo-b");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "other", "proj2", .{ .version = 1, .org = "other", .name = "proj2", .repos = repos_other });

    const path_a = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-a" });
    try fsutil.ensureDir(std.fs.path.dirname(path_a).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_a, path_a });

    const path_b = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "other", "repo-b" });
    try fsutil.ensureDir(std.fs.path.dirname(path_b).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_b, path_b });

    const override = try installCapture(arena);
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "--all", "--", "touch", "all-marker" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path_a, "all-marker" })));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path_b, "all-marker" })));
}

test "run: --all runs a repo shared by two projects exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_shared = try testutil.makeBareRepo(&sb, "shared.git");
    defer testing.allocator.free(bare_shared);

    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos_1: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_1.put(arena, "shared", "https://holt-test.invalid/acme/shared");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj1", .{ .version = 1, .org = "acme", .name = "proj1", .repos = repos_1 });

    var repos_2: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_2.put(arena, "shared-alias", "https://holt-test.invalid/acme/shared");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj2", .{ .version = 1, .org = "acme", .name = "proj2", .repos = repos_2 });

    const shared_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "shared" });
    try fsutil.ensureDir(std.fs.path.dirname(shared_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_shared, shared_path });

    const override = try installCapture(arena);
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "--all", "--", "sh", "-c", "echo hit >> counter" });
    try testing.expectEqual(@as(u8, 0), got.code);

    // A single "hit" line proves the shared clone ran the command exactly
    // once, not once per project that references it.
    const counter_path = try std.fs.path.join(arena, &.{ shared_path, "counter" });
    const contents = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), counter_path, arena, .limited(1 << 10));
    try testing.expectEqualStrings("hit\n", contents);
}

test "run: --repo combined with --org is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "--org", "acme", "--repo", "repo-a", "--", "echo", "hi" });
    try testing.expectEqual(@as(u8, 2), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "--repo") != null);
}

test "run: no target selector (no project, --org, or --all) is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "--", "echo", "hi" });
    try testing.expectEqual(@as(u8, 2), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "exactly one") != null);
}

test "run: -j 4 runs the command in every repo, one failing child yields aggregate exit 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    const names = [_][]const u8{ "repo-0", "repo-1", "repo-2", "repo-3", "repo-4" };
    for (names) |name| {
        const url = try std.fmt.allocPrint(arena, "https://holt-test.invalid/acme/{s}", .{name});
        try repos.put(arena, name, url);
    }
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    var paths: [names.len][]const u8 = undefined;
    for (names, &paths) |name, *path| {
        path.* = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", name });
        try fsutil.ensureDir(std.fs.path.dirname(path.*).?);
        try testutil.runGit(&sb, null, &.{ "clone", bare, path.* });
    }

    // -j > 1 always captures, so no HOLT_RUN_CAPTURE seam is needed. repo-2
    // exits nonzero; every repo still touches its marker and gets a header.
    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "-j", "4", "--", "sh", "-c", "touch ran; case \"$(basename \"$PWD\")\" in repo-2) exit 5;; esac" });
    try testing.expectEqual(@as(u8, 1), got.code);

    for (names, paths) |name, path| {
        try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ path, "ran" })));
        const header = try std.fmt.allocPrint(arena, "==> {s}", .{name});
        try testing.expect(std.mem.indexOf(u8, got.out, header) != null);
    }
    try testing.expect(std.mem.indexOf(u8, got.out, "exited 5") != null);
}

test "run: --all -j 4 runs a repo shared by two projects exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare_shared = try testutil.makeBareRepo(&sb, "shared.git");
    defer testing.allocator.free(bare_shared);

    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos_1: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_1.put(arena, "shared", "https://holt-test.invalid/acme/shared");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj1", .{ .version = 1, .org = "acme", .name = "proj1", .repos = repos_1 });

    var repos_2: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_2.put(arena, "shared-alias", "https://holt-test.invalid/acme/shared");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj2", .{ .version = 1, .org = "acme", .name = "proj2", .repos = repos_2 });

    const shared_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "shared" });
    try fsutil.ensureDir(std.fs.path.dirname(shared_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare_shared, shared_path });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "--all", "-j", "4", "--", "sh", "-c", "echo hit >> counter" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const counter_path = try std.fs.path.join(arena, &.{ shared_path, "counter" });
    const contents = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), counter_path, arena, .limited(1 << 10));
    try testing.expectEqualStrings("hit\n", contents);
}

test "run: -j 4 with a captured child's stdout appears under its repo header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "a.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "repo-a", "https://holt-test.invalid/acme/repo-a");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const path_a = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "repo-a" });
    try fsutil.ensureDir(std.fs.path.dirname(path_a).?);
    try testutil.runGit(&sb, null, &.{ "clone", bare, path_a });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "proj", "-j", "2", "--", "echo", "hello-from-child" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const header_at = std.mem.indexOf(u8, got.out, "==> repo-a") orelse return error.TestExpectedEqual;
    const child_at = std.mem.indexOf(u8, got.out, "hello-from-child") orelse return error.TestExpectedEqual;
    try testing.expect(child_at > header_at);
}
