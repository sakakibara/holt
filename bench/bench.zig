//! `zig build bench`: seeds a synthetic workspace at N=500 and N=1000
//! projects and times the hot read operations directly (no `holt` subprocess
//! spawns for the operation itself - only the git calls those operations make
//! on their own member repos), printing a ranked, slowest-first baseline.
//! Dev-only; kept out of the `test` step so the normal suite stays fast.

const std = @import("std");
const holt_lib = @import("holt_lib");
const fsutil = holt_lib.fsutil;
const workspace = holt_lib.workspace;
const testutil = holt_lib.testutil;
const app = holt_lib.app;
const recent_cmd = holt_lib.recent_cmd;
const status_cmd = holt_lib.status_cmd;
const sync_cmd = holt_lib.sync_cmd;
const doctor_cmd = holt_lib.doctor_cmd;

/// One repo per project keeps N=1000's real `git init` + commit seeding (and
/// the git spawns `status`/`recent`/`doctor` make against those clones) inside
/// a few minutes; every repo is a real clone, no subset truncation.
const repos_per_project = 1;

const Spec = struct { orgs: usize, projects_per_org: usize };
const specs = [_]Spec{
    .{ .orgs = 50, .projects_per_org = 10 }, // N=500
    .{ .orgs = 50, .projects_per_org = 20 }, // N=1000
};

pub fn main(init: std.process.Init) u8 {
    runBench(init.gpa) catch |err| {
        std.debug.print("bench failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn runBench(gpa: std.mem.Allocator) !void {
    for (specs) |spec| try benchOne(gpa, spec.orgs, spec.projects_per_org);
}

/// Bumped once per `benchOne` call so two runs in the same process (N=500,
/// then N=1000) never collide on the same temp leaf name.
var tmp_seq: std.atomic.Value(u32) = .init(0);

fn makeTempRoot(alloc: std.mem.Allocator, total_projects: usize) ![]const u8 {
    const environ = std.Io.Threaded.global_single_threaded.environ.process_environ;
    const base = std.process.Environ.getAlloc(environ, alloc, "TMPDIR") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try alloc.dupe(u8, "/tmp"),
        else => return err,
    };
    const seq = tmp_seq.fetchAdd(1, .monotonic);
    const leaf = try std.fmt.allocPrint(alloc, "holt-bench-{d}-{d}-{d}", .{ total_projects, std.Thread.getCurrentId(), seq });
    const root = try std.fs.path.join(alloc, &.{ base, leaf });
    // A stale dir from a prior crashed run must not leak leftover markers/
    // clones into this run's fresh seed.
    std.Io.Dir.cwd().deleteTree(fsutil.io(), root) catch {};
    try fsutil.ensureDir(root);
    return root;
}

fn benchOne(gpa: std.mem.Allocator, orgs: usize, projects_per_org: usize) !void {
    const total_projects = orgs * projects_per_org;

    var setup_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer setup_arena_state.deinit();
    const setup = setup_arena_state.allocator();

    const root = try makeTempRoot(setup, total_projects);
    defer std.Io.Dir.cwd().deleteTree(fsutil.io(), root) catch {};

    std.debug.print(
        "\n== N={d} projects ({d} orgs x {d} projects_per_org), {d} repo(s)/project, every repo a real clone (with_git=true, no subset truncation) ==\n",
        .{ total_projects, orgs, projects_per_org, repos_per_project },
    );

    const seed_start = std.Io.Clock.now(.awake, fsutil.io());
    try testutil.seedSyntheticWorkspace(setup, root, .{
        .orgs = orgs,
        .projects_per_org = projects_per_org,
        .repos_per_project = repos_per_project,
        .with_git = true,
    });
    const seed_ns = elapsedNs(seed_start);
    std.debug.print("seed: {d:.2}s ({d} projects, {d} repos)\n", .{ msFromNs(seed_ns) / 1000.0, total_projects, total_projects * repos_per_project });

    const ws = try testutil.testWorkspace(setup, root);

    var results: [8]Result = undefined;
    results[0] = try measure(gpa, "list", .scan, listOp, ws);
    results[1] = try measure(gpa, "find (resolver)", .scan, findOp, ws);
    results[2] = try measure(gpa, "__complete", .scan, completeOp, ws);
    results[3] = try measure(gpa, "recent", .git, recentOp, ws);
    results[4] = try measure(gpa, "status", .git, statusOp, ws);
    results[5] = try measure(gpa, "sync", .scan, syncOp, ws);
    results[6] = try measure(gpa, "doctor", .git, doctorOp, ws);
    results[7] = try measure(gpa, "doctor --full", .git, doctorFullOp, ws);

    std.mem.sort(Result, &results, {}, moreExpensive);

    std.debug.print("-- ranked baseline, N={d} (slowest first) --\n", .{total_projects});
    for (results) |r| {
        std.debug.print("{s:<16} {d:>10.3} ms  [{s}]\n", .{ r.name, msFromNs(r.ns), r.bound.tag() });
    }
}

/// Nanoseconds elapsed on the monotonic (`.awake`) clock since `start`.
fn elapsedNs(start: std.Io.Timestamp) u64 {
    const end = std.Io.Clock.now(.awake, fsutil.io());
    return @intCast(start.durationTo(end).nanoseconds);
}

fn msFromNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

const Bound = enum {
    /// Cost dominated by a filesystem marker scan - no subprocess spawned.
    scan,
    /// Cost dominated by one or more `git` subprocess spawns per member repo.
    git,

    fn tag(self: Bound) []const u8 {
        return switch (self) {
            .scan => "scan-bound",
            .git => "git-bound",
        };
    }
};

const Result = struct { name: []const u8, ns: u64, bound: Bound };

fn moreExpensive(_: void, a: Result, b: Result) bool {
    return a.ns > b.ns;
}

/// Runs `op` once unmeasured (warm-up: populates OS file-cache/dentry state),
/// then again under a fresh arena while timed. Each call gets its own arena
/// backed by `gpa`, exactly like a real `holt` invocation (see
/// `cli.dispatchTo`), so allocation behavior matches production.
fn measure(
    gpa: std.mem.Allocator,
    name: []const u8,
    bound: Bound,
    comptime op: fn (std.mem.Allocator, workspace.Workspace) anyerror!void,
    ws: workspace.Workspace,
) !Result {
    {
        var warm_arena = std.heap.ArenaAllocator.init(gpa);
        defer warm_arena.deinit();
        try op(warm_arena.allocator(), ws);
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const start = std.Io.Clock.now(.awake, fsutil.io());
    try op(arena.allocator(), ws);
    const ns = elapsedNs(start);
    return .{ .name = name, .ns = ns, .bound = bound };
}

fn listOp(alloc: std.mem.Allocator, ws: workspace.Workspace) !void {
    _ = try ws.list(alloc);
}

/// An exact `org/name` query - the resolver's cheapest tier - since the
/// seeded org/project naming (`orgNNNN`/`projNNNN`) makes "org0000/proj0000"
/// unique on the first (exact) tier rather than falling through to a fuzzier,
/// more expensive one.
fn findOp(alloc: std.mem.Allocator, ws: workspace.Workspace) !void {
    _ = try ws.find(alloc, "org0000/proj0000");
}

fn completeOp(alloc: std.mem.Allocator, ws: workspace.Workspace) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var err_w: std.Io.Writer.Allocating = .init(alloc);
    var ctx: app.Ctx = .{
        .alloc = alloc,
        .io = fsutil.io(),
        .context = .{ .ws = ws, .color = false },
        .out = &out.writer,
        .err = &err_w.writer,
    };
    _ = try app.HoltCli.completionCompute(alloc, &app.command_table, &.{ "info", "" }, app.HoltCli.completion_resolve, &ctx);
}

/// Drives a command's `.run` the same way `testutil.runCmd` does for tests,
/// but against a real `std.Io` (`fsutil.io()`) instead of `std.testing.io` -
/// bench compiles as a plain executable, not a test binary, so referencing
/// `std.testing.io` there would be a compile error.
fn runCmd(alloc: std.mem.Allocator, run_fn: *const fn (ctx: *app.Ctx) anyerror!u8, ws: workspace.Workspace, argv: []const []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var err_w: std.Io.Writer.Allocating = .init(alloc);
    var ctx: app.Ctx = .{
        .alloc = alloc,
        .io = fsutil.io(),
        .context = .{ .ws = ws, .color = false },
        .out = &out.writer,
        .err = &err_w.writer,
        .argv = argv,
    };
    _ = try run_fn(&ctx);
}

fn recentOp(alloc: std.mem.Allocator, ws: workspace.Workspace) !void {
    try runCmd(alloc, recent_cmd.command.run, ws, &.{});
}

fn statusOp(alloc: std.mem.Allocator, ws: workspace.Workspace) !void {
    try runCmd(alloc, status_cmd.command.run, ws, &.{});
}

fn syncOp(alloc: std.mem.Allocator, ws: workspace.Workspace) !void {
    try runCmd(alloc, sync_cmd.command.run, ws, &.{});
}

fn doctorOp(alloc: std.mem.Allocator, ws: workspace.Workspace) !void {
    try runCmd(alloc, doctor_cmd.command.run, ws, &.{});
}

fn doctorFullOp(alloc: std.mem.Allocator, ws: workspace.Workspace) !void {
    try runCmd(alloc, doctor_cmd.command.run, ws, &.{"--full"});
}
