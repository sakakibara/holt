//! `holt create <spec> [-p <project>]`: make a git repo from scratch.
//! A bare <spec> ("foo") is a LOCAL repo at <code_root>/local/foo with no
//! origin; a URL/shorthand ("owner/repo", a full git url) is a remote-destined
//! repo at its identity path with `origin` set (nothing pushed). Without -p the
//! repo is standalone (no marker, no hub); with -p it is attached as a project
//! member. The repo is left commitless (plain `git init`); its path is printed.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const common = @import("common.zig");
const project_mod = @import("../project.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const hub = @import("../hub.zig");
const git = @import("../git.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    spec: args.Pos([]const u8, .{ .help = "a name for a local repo, or a git url / owner/repo shorthand for a remote-destined one" }),
    project: args.Opt([]const u8, .{ .short = 'p', .value_name = "project", .complete = comp.cat(.project), .help = "attach the new repo as a member of this project" }),
};

pub const command = args.command(Spec, .{
    .name = "create",
    .about = "Create a git repo from scratch",
    .usage = "holt create <spec> [-p <project>]",
    .group = .create,
    .details =
    \\Runs `git init` (no initial commit). A bare <spec> makes a local repo at
    \\<code_root>/local/<name>; a url or owner/repo shorthand makes one at its
    \\identity path with origin set (nothing is pushed). Without -p the repo is
    \\standalone; with -p it is added as a member of <project>. The created
    \\path is the sole line on stdout, so `cd $(holt create foo)` works.
    \\
    \\Example:
    \\  holt create scratch
    \\  holt create acme/widget
    \\  holt create tool -p myproject
    ,
    .needs_workspace = true,
}, run);

/// Classifies <spec>: a recognized url/shorthand yields its identity and the
/// expanded origin url; a bare word yields a local identity and null url.
const Target = struct { id: identity.Identity, origin: ?[]const u8 };

fn classify(alloc: std.mem.Allocator, spec: []const u8) !Target {
    const url = identity.expand(alloc, spec) catch |err| switch (err) {
        error.UnrecognizedUrl => return .{ .id = identity.local(spec), .origin = null },
        else => return err,
    };
    return .{ .id = try identity.fromUrl(alloc, url), .origin = url };
}

/// A local repo name must be a single safe path segment: no separator, no
/// `..`, no leading `.`/`~` (each would escape or shadow the `local/` bucket).
fn isSafeLocalName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '.' or name[0] == '~') return false;
    for (name) |c| if (c == '/' or c == '\\') return false;
    return true;
}

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const ws = ctx.ws.?;
    const alloc = ctx.alloc;

    const target = classify(alloc, a.spec) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err_w.print("holt: \"{s}\" is not a valid repo url\n", .{a.spec});
            return 1;
        },
        else => return err,
    };
    const clone_path = try target.id.clonePath(alloc, ws.cfg.code_root);

    if (target.id.isLocal()) {
        if (!isSafeLocalName(a.spec)) {
            try ctx.err_w.print("holt: \"{s}\" is not a valid repo name\n", .{a.spec});
            return 1;
        }
    }

    if (fsutil.exists(clone_path)) {
        try ctx.err_w.print("holt: {s} already exists; use `holt adopt` to register an existing clone\n", .{clone_path});
        return 1;
    }

    // Resolve -p BEFORE any filesystem work, so a bad project fails without
    // leaving an orphaned git init behind.
    var project: ?project_mod.Project = null;
    if (a.project) |project_query| {
        project = (try common.resolveOne(ctx, project_query)) orelse return 1;
    }

    const res = try git.run(alloc, &.{ "git", "init", "-q", "-b", "main", clone_path }, null);
    if (res.status != 0) {
        const cause = std.mem.trim(u8, res.stderr, " \t\r\n");
        try ctx.err_w.print("holt: git init failed at {s}: {s}\n", .{ clone_path, cause });
        return 1;
    }

    if (target.origin) |origin| {
        const rr = try git.run(alloc, &.{ "git", "-C", clone_path, "remote", "add", "origin", origin }, null);
        if (rr.status != 0) {
            const cause = std.mem.trim(u8, rr.stderr, " \t\r\n");
            try ctx.err_w.print("holt: failed to set origin on {s}: {s}\n", .{ clone_path, cause });
            return 1;
        }
    }

    if (project) |*p| {
        var lock = try projectlock.acquire(alloc, p.content_path);
        defer lock.release();
        p.marker = try marker.load(alloc, try p.markerPath(alloc), null);

        const member_value = if (target.origin) |origin|
            origin
        else
            try std.fmt.allocPrint(alloc, "local:{s}", .{target.id.repo});

        try p.marker.repos.put(alloc, target.id.repo, member_value);
        try marker.save(&p.marker, try p.markerPath(alloc));
        _ = try hub.reconcile(alloc, &ws, p, false);
    }

    try ctx.out.print("{s}\n", .{clone_path});
    return 0;
}

test "run: a bare name creates a local repo at code_root/local/<name>, prints the path, no marker or hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const expected_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "scratch" });
    // stdout is the created path (sole line).
    try testing.expectEqualStrings(expected_path, std.mem.trim(u8, got.out, " \t\r\n"));
    // It is a git repo (has a .git) ...
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ expected_path, ".git" })));
    // ... but commitless (unborn HEAD): no commit reachable from HEAD.
    try testing.expect(!try git.isCompleteClone(arena, expected_path));
    // No marker and no hub for a standalone create.
    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "local", "scratch", marker.marker_basename });
    try testing.expect(!fsutil.exists(marker_path));
}

test "run: an unsafe local name is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    for ([_][]const u8{ "..", ".hidden", "~x" }) |bad| {
        const got = try testutil.runCmd(arena, command.run, ws, &.{bad});
        try testing.expectEqual(@as(u8, 1), got.code);
    }
}

test "run: refuses when the target path already exists, pointing at adopt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // Pre-create the target path.
    const target = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "taken" });
    try fsutil.ensureDir(target);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"taken"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "adopt") != null);
}

test "run: a traversal spec that looks remote is refused (does not init outside code_root)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    for ([_][]const u8{ "../foo", "../../etc/passwd" }) |bad| {
        const got = try testutil.runCmd(arena, command.run, ws, &.{bad});
        try testing.expectEqual(@as(u8, 1), got.code);
    }
}

test "run: a backslash-traversal spec (Windows escape) is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // A segment carrying a literal backslash-dotdot would escape code_root on
    // Windows (clonePath joins with the platform separator); refuse it.
    const got = try testutil.runCmd(arena, command.run, ws, &.{"a/..\\..\\..\\evil"});
    try testing.expectEqual(@as(u8, 1), got.code);
}

test "run: a scheme'd url with a traversal segment is refused via fromUrl" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // A full URL bypasses expand's shorthand path and reaches fromUrl, which
    // rejects the ".." segment - proving create's classify/run error routing
    // (not isSafeLocalName, which only guards the bare-name local branch).
    const got = try testutil.runCmd(arena, command.run, ws, &.{"https://github.com/acme/../evil"});
    try testing.expectEqual(@as(u8, 1), got.code);
    // Nothing created on refusal.
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme" })));
}

test "run: a normal owner/repo shorthand still creates at the identity path with origin set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const expected_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme", "widget" });
    try testing.expectEqualStrings(expected_path, std.mem.trim(u8, got.out, " \t\r\n"));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ expected_path, ".git" })));

    // origin is set to the expanded url.
    const url = try identity.expand(arena, "acme/widget");
    const remote = try git.run(arena, &.{ "git", "-C", expected_path, "remote", "get-url", "origin" }, null);
    try testing.expectEqual(@as(u8, 0), remote.status);
    try testing.expectEqualStrings(url, std.mem.trim(u8, remote.stdout, " \t\r\n"));
}

test "run: -p attaches a local member (marker local:<name> + hub) and doctor does not flag it broken" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "tool", "-p", "acme/widget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget", marker.marker_basename });
    const m = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:tool", m.repos.get("tool").?);

    const clone_path = try identity.local("tool").clonePath(arena, ws.cfg.code_root);
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ clone_path, ".git" })));

    const doctor = @import("../doctor.zig");
    const report = try doctor.run(arena, &ws, .{ .full = false, .fix = false, .jobs = 1 });
    try testing.expectEqual(@as(usize, 0), report.broken_clones.len);
}

test "run: -p to a nonexistent project fails without creating the repo" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{ "tool", "-p", "no/such" });
    try testing.expectEqual(@as(u8, 1), got.code);
    // No orphaned repo left behind.
    const clone_path = try identity.local("tool").clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(clone_path));
}
