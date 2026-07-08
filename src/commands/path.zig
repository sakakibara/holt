//! Resolves a project or project/repo query to a filesystem path. A bare
//! project query prints the hub symlink path; a `<project>/<repo>` query
//! prints the repo's real clone path under code_root, never the hub link.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const identity = @import("../identity.zig");
const common = @import("common.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    query: args.Pos(?[]const u8, .{ .complete = comp.cat(.project_repo), .help = "the project or project/repo to resolve" }),
};

pub const command = args.command(Spec, .{
    .name = "path",
    .about = "Print the filesystem path for a project or project/repo",
    .usage = "holt path [<project>|<project>/<repo>]",
    .group = .navigate,
    .details =
    \\Example:
    \\  holt path myproj/backend
    ,
}, run);

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    // An empty query (bare `holt path`, or `h` with no argument via the
    // shell function) means "the hub root itself", not a usage error - the
    // shell function relies on this to make bare `h` cd there.
    const query = a.query orelse "";
    const ws = ctx.ws.?;

    if (query.len == 0) {
        try ctx.out.print("{s}\n", .{ws.cfg.hub_root});
        return 0;
    }

    return resolve(ctx, ws, query);
}

fn resolve(ctx: *cli.Ctx, ws: workspace.Workspace, query: []const u8) anyerror!u8 {
    const alloc = ctx.alloc;

    // `<project>/<repo>@<branch>` resolves to that branch's worktree checkout.
    // The branch (after '@') may itself contain '/', so it is taken whole.
    if (std.mem.indexOfScalar(u8, query, '@')) |at| {
        const repo_sel = query[0..at];
        const branch = query[at + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, repo_sel, '/')) |s| {
            const pq = repo_sel[0..s];
            const rq = repo_sel[s + 1 ..];
            if (pq.len > 0 and rq.len > 0 and branch.len > 0) {
                return resolveWorktree(ctx, ws, pq, rq, branch);
            }
        }
    }

    // Try the whole query as a project first: `find` already understands
    // "org/name", so a project query that happens to contain '/' resolves
    // here without ever reaching the repo-splitting branch below.
    const whole = try ws.find(alloc, query);
    switch (whole) {
        .one => |p| {
            try ctx.out.print("{s}\n", .{p.hub_path});
            return 0;
        },
        .none, .ambiguous => {},
    }

    if (std.mem.lastIndexOfScalar(u8, query, '/')) |slash| {
        const project_query = query[0..slash];
        const repo_query = query[slash + 1 ..];
        if (project_query.len > 0 and repo_query.len > 0) {
            return resolveRepo(ctx, ws, project_query, repo_query);
        }
    }

    return common.reportProjectFailure(ctx, query, whole);
}

fn resolveRepo(ctx: *cli.Ctx, ws: workspace.Workspace, project_query: []const u8, repo_query: []const u8) anyerror!u8 {
    const clone_path = (try resolveRepoPath(ctx, ws, project_query, repo_query)) orelse return 1;
    try ctx.out.print("{s}\n", .{clone_path});
    return 0;
}

/// Resolves `<project>/<repo>@<branch>` to that branch's worktree path under
/// the repo's sibling `<clone>@worktrees/` dir; null (after reporting) when the
/// repo does not resolve or has no such worktree.
fn resolveWorktree(ctx: *cli.Ctx, ws: workspace.Workspace, project_query: []const u8, repo_query: []const u8, branch: []const u8) anyerror!u8 {
    const alloc = ctx.alloc;
    const clone_path = (try resolveRepoPath(ctx, ws, project_query, repo_query)) orelse return 1;
    const worktrees_dir = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{clone_path});
    const wt_path = try fsutil.joinSlashy(alloc, worktrees_dir, branch);
    if (!fsutil.exists(wt_path)) {
        try ctx.err_w.print("holt: no worktree for branch \"{s}\" in {s}/{s} (create it: holt worktree {s}/{s} {s})\n", .{ branch, project_query, repo_query, project_query, repo_query, branch });
        return 1;
    }
    try ctx.out.print("{s}\n", .{wt_path});
    return 0;
}

/// Resolves a `<project>/<repo>` pair to the repo's identity; null (after
/// reporting why on ctx.err_w) for no project match, an ambiguous one, or no
/// matching repo. Callers wanting the clone path use `resolveRepoPath`.
pub fn resolveRepoId(ctx: *cli.Ctx, ws: workspace.Workspace, project_query: []const u8, repo_query: []const u8) anyerror!?identity.Identity {
    _ = ws;
    const alloc = ctx.alloc;

    const p = (try common.resolveOne(ctx, project_query)) orelse return null;

    const repo_name = findRepo(p, repo_query) orelse {
        const qualified = try p.qualified(alloc);
        try ctx.err_w.print("holt: no repo matches \"{s}\" in {s}\n", .{ repo_query, qualified });
        return null;
    };

    return try p.repoIdentity(alloc, repo_name);
}

/// Resolves a `<project>/<repo>` pair to the repo's real clone path under
/// code_root, never a hub link; null (after reporting) on any resolution miss.
pub fn resolveRepoPath(ctx: *cli.Ctx, ws: workspace.Workspace, project_query: []const u8, repo_query: []const u8) anyerror!?[]const u8 {
    const id = (try resolveRepoId(ctx, ws, project_query, repo_query)) orelse return null;
    return try id.clonePath(ctx.alloc, ws.cfg.code_root);
}

/// Exact repo short name, else the unique case-insensitive subsequence
/// match among the project's member names; null if none or ambiguous.
fn findRepo(p: project_mod.Project, query: []const u8) ?[]const u8 {
    if (p.marker.repos.contains(query)) return query;

    var found: ?[]const u8 = null;
    for (p.marker.repos.keys()) |name| {
        if (!workspace.isSubsequenceIgnoreCase(query, name)) continue;
        if (found != null) return null;
        found = name;
    }
    return found;
}

fn testWorkspace(arena: std.mem.Allocator, root: []const u8, code_root: []const u8) workspace.Workspace {
    return .{ .cfg = .{
        .backend = null,
        .presets = &.{},
        .synced_root = @constCast(root),
        .code_root = @constCast(code_root),
        .hub_root = std.fs.path.join(arena, &.{ root, "hub" }) catch unreachable,
    } };
}

test "run: <project>/<repo>@<branch> resolves the worktree path, and misses report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    // A worktree only needs to exist on disk for resolution; stage the dir.
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "backend" });
    const wt_path = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "feature", "x" });
    try fsutil.ensureDir(wt_path);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"proj/backend@feature/x"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings(wt_path, std.mem.trim(u8, got.out, "\n"));

    const miss = try testutil.runCmd(arena, command.run, ws, &.{"proj/backend@nope"});
    try testing.expectEqual(@as(u8, 1), miss.code);
    try testing.expect(std.mem.indexOf(u8, miss.err, "no worktree") != null);
}

test "run: bare query (empty positional) prints the hub root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = testWorkspace(arena, root, "/code");

    var cli_args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = ws, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    const code = try command.run(&ctx);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{ws.cfg.hub_root}), out.written());
}

test "run: a project query prints the hub path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = testWorkspace(arena, root, "/code");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    var cli_args = try cli.Args.init(arena, &.{"widget"});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = ws, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    const code = try command.run(&ctx);
    try testing.expectEqual(@as(u8, 0), code);

    const want_hub = try std.fs.path.join(arena, &.{ root, "hub", "acme", "widget" });
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{want_hub}), out.written());
}

test "run: a project/repo query prints the real clone path, not the hub link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://github.com/acme/backend");

    const ws = testWorkspace(arena, root, "/code");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = repos });

    var cli_args = try cli.Args.init(arena, &.{"widget/backend"});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = ws, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    const code = try command.run(&ctx);
    try testing.expectEqual(@as(u8, 0), code);

    const got = out.written();
    const want_clone = try std.fs.path.join(arena, &.{ "/code", "github.com", "acme", "backend" });
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{want_clone}), got);

    const hub_path = try std.fs.path.join(arena, &.{ root, "hub", "acme", "widget" });
    try testing.expect(std.mem.indexOf(u8, got, hub_path) == null);
}

test "run: repo resolves by unique subsequence when not an exact name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://github.com/acme/backend");

    const ws = testWorkspace(arena, root, "/code");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = repos });

    var cli_args = try cli.Args.init(arena, &.{"widget/bck"});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = ws, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    const code = try command.run(&ctx);
    try testing.expectEqual(@as(u8, 0), code);
    const want_clone = try std.fs.path.join(arena, &.{ "/code", "github.com", "acme", "backend" });
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{want_clone}), out.written());
}

test "run: no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = testWorkspace(arena, root, "/code");

    var cli_args = try cli.Args.init(arena, &.{"nope"});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = ws, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    const code = try command.run(&ctx);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, err_w.written(), "nope") != null);
}

test "run: ambiguous project exits 1 and lists every candidate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = testWorkspace(arena, root, "/code");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "other", "widget", .{ .version = 1, .org = "other", .name = "widget", .repos = .empty });

    var cli_args = try cli.Args.init(arena, &.{"widget"});
    var out: std.Io.Writer.Allocating = .init(arena);
    var err_w: std.Io.Writer.Allocating = .init(arena);
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = ws, .args = &cli_args, .out = &out.writer, .err_w = &err_w.writer };

    const code = try command.run(&ctx);
    try testing.expectEqual(@as(u8, 1), code);
    const got = err_w.written();
    try testing.expect(std.mem.indexOf(u8, got, "acme/widget") != null);
    try testing.expect(std.mem.indexOf(u8, got, "other/widget") != null);
}
