//! `holt repo`: groups repo lifecycle commands under the noun they act on.
//! `new <spec> [-p <project>]` runs `git init` (no initial commit) for a
//! from-scratch repo: a bare <spec> makes a local repo at
//! <code_root>/local/<name> with no origin; a url or owner/repo shorthand
//! makes one at its identity path with origin set (nothing pushed). Without
//! -p the repo is standalone (no marker, no hub); with -p it is attached as
//! a project member.
//! `get <url> [-p <project>] [--update]` clones an existing remote into the
//! code tree at its identity path, reusing a present clone rather than
//! re-cloning it. Without -p the repo is standalone; with -p it is also
//! recorded as a project member and linked into that project's hub. A
//! `local:<name>` argument, or a path that is itself an existing git
//! checkout, is rejected - those belong to `holt repo adopt`.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
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

const NewSpec = struct {
    spec: cli.Pos([]const u8, .{ .help = "a name for a local repo, or a git url / owner/repo shorthand for a remote-destined one" }),
    project: cli.Opt([]const u8, .{ .short = 'p', .value_name = "project", .complete = app.cat(.project), .help = "attach the new repo as a member of this project" }),
};

pub const new_command = app.command(NewSpec, .{
    .name = "new",
    .summary = "Create a git repo from scratch",
    .usage = "holt repo new <spec> [-p <project>]",
    .group = .create,
    .needs_context = true,
    .details =
    \\Runs `git init` (no initial commit). A bare <spec> makes a local repo at
    \\<code_root>/local/<name>; a url or owner/repo shorthand makes one at its
    \\identity path with origin set (nothing is pushed). Without -p the repo is
    \\standalone; with -p it is added as a member of <project>. The created
    \\path is the sole line on stdout, so `cd $(holt repo new foo)` works.
    \\
    \\Example:
    \\  holt repo new scratch
    \\  holt repo new acme/widget
    \\  holt repo new tool -p myproject
    ,
}, runNew);

pub const command: app.Command = .{
    .name = "repo",
    .summary = "Create, fetch, and manage repo clones",
    .usage = "holt repo <new|get> ...",
    .group = .create,
    .subcommands = &.{ new_command, get_command },
    .needs_context = true,
    .run = runFallback,
};

fn runFallback(ctx: *app.Ctx) anyerror!u8 {
    return app.usageError(ctx, "usage: holt repo <new|get> ...", .{});
}

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

fn runNew(ctx: *app.Ctx, a: cli.Args(NewSpec)) anyerror!u8 {
    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const target = classify(alloc, a.spec) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err.print("holt: \"{s}\" is not a valid repo url\n", .{a.spec});
            return 1;
        },
        else => return err,
    };
    const clone_path = try target.id.clonePath(alloc, ws.cfg.code_root);

    if (target.id.isLocal()) {
        if (!isSafeLocalName(a.spec)) {
            try ctx.err.print("holt: \"{s}\" is not a valid repo name\n", .{a.spec});
            return 1;
        }
    }

    if (fsutil.exists(clone_path)) {
        try ctx.err.print("holt: {s} already exists; use `holt repo adopt` to register an existing clone\n", .{try app.tilde(ctx, clone_path)});
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
        try ctx.err.print("holt: git init failed at {s}: {s}\n", .{ try app.tilde(ctx, clone_path), cause });
        return 1;
    }

    if (target.origin) |origin| {
        const rr = try git.run(alloc, &.{ "git", "-C", clone_path, "remote", "add", "origin", origin }, null);
        if (rr.status != 0) {
            const cause = std.mem.trim(u8, rr.stderr, " \t\r\n");
            try ctx.err.print("holt: failed to set origin on {s}: {s}\n", .{ try app.tilde(ctx, clone_path), cause });
            return 1;
        }
    }

    if (project) |*p| {
        var lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
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
    try ctx.err.print("created {s}\n", .{try app.tilde(ctx, clone_path)});
    return 0;
}

const GetSpec = struct {
    url: cli.Pos([]const u8, .{ .complete = .files, .help = "a git url, or owner/repo (host/owner/repo) shorthand" }),
    project: cli.Opt([]const u8, .{ .short = 'p', .value_name = "project", .complete = app.cat(.project), .help = "also record the repo as a member of this project" }),
    update: cli.Flag(.{ .short = 'u', .help = "if the clone already exists, fast-forward it instead of leaving it as-is" }),
};

pub const get_command = app.command(GetSpec, .{
    .name = "get",
    .summary = "Clone a repo into the code tree, optionally into a project",
    .usage = "holt repo get <url> [-p <project>] [--update]",
    .group = .create,
    .needs_context = true,
    .details =
    \\Clones into <code_root>/<host>/<owner>/<repo>, reusing an existing clone
    \\if it is already there. Without -p the repo is standalone; with -p it is
    \\also recorded in that project's marker and linked into its hub. The
    \\clone path is the sole line on stdout, so `cd $(holt repo get <url>)`
    \\works. With --update, a present clone is fast-forwarded rather than
    \\left as-is.
    \\
    \\Example:
    \\  holt repo get https://github.com/acme/widget
    \\  holt repo get acme/widget -p acme/widget
    ,
}, runGet);

fn runGet(ctx: *app.Ctx, a: cli.Args(GetSpec)) anyerror!u8 {
    const raw = a.url;
    const alloc = ctx.alloc;
    const ws = ctx.context.?.ws;

    // Resolve -p before any filesystem work, so a bad project fails without
    // leaving a clone behind.
    var project: ?project_mod.Project = null;
    if (a.project) |q| project = (try common.resolveOne(ctx, q)) orelse return 1;

    // Serialize with any other holt mutating this same project, and re-read
    // the marker under the lock so the load-modify-save below acts on the
    // current state rather than a snapshot that a concurrent run may have
    // already superseded (which would silently drop that run's edit).
    var content_lock: ?projectlock.Handle = null;
    defer if (content_lock) |l| l.release();
    if (project) |*p| {
        content_lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
        p.marker = try marker.load(alloc, try p.markerPath(alloc), null);
    }

    if (std.mem.startsWith(u8, raw, "local:")) {
        try ctx.err.print("holt: \"{s}\" is a local repo; bring it in with `holt repo adopt <path>`\n", .{raw});
        return 1;
    }

    // An existing local checkout belongs to `repo adopt`, which moves it,
    // not here, which clones a remote.
    const maybe_local = try fsutil.toAbsolute(alloc, raw);
    if (fsutil.exists(maybe_local) and try git.inspectable(alloc, maybe_local)) {
        try ctx.err.print("holt: {s} is a local checkout; bring it in with `holt repo adopt {s}`\n", .{ raw, raw });
        return 1;
    }

    // Expand "owner/repo" / "host/owner/repo" shorthand to a real clone URL.
    const url = identity.expand(alloc, raw) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err.print("holt: \"{s}\" is not a recognized git url\n", .{raw});
            return 1;
        },
        else => return err,
    };
    const id = identity.fromUrl(alloc, url) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err.print("holt: \"{s}\" is not a recognized git url\n", .{raw});
            return 1;
        },
        else => return err,
    };

    if (project) |*p| {
        if (p.marker.repos.contains(id.repo)) {
            try ctx.err.print("holt: \"{s}\" is already a member of {s}/{s}\n", .{ id.repo, p.org, p.name });
            return 1;
        }
    }

    const clone_path = try id.clonePath(alloc, ws.cfg.code_root);

    // Hold the clone-path lock nested inside any content lock acquired above
    // (a fixed order that prevents deadlock against another holt command
    // locking the same two paths), so a concurrent `archive --prune` cannot
    // delete this clone between it landing and our reference to it landing.
    var clone_lock = try projectlock.acquire(alloc, app.envOf(ctx), clone_path);
    defer clone_lock.release();

    const cloned = common.cloneIfAbsent(ctx, url, clone_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return 1,
    };

    if (!cloned and a.update) {
        const res = try git.run(alloc, &.{ "git", "-C", clone_path, "pull", "--ff-only" }, null);
        if (res.status != 0) {
            const trimmed = std.mem.trim(u8, res.stderr, " \t\r\n");
            const cause = if (trimmed.len == 0) "git pull failed" else trimmed;
            try ctx.err.print("holt: failed to update {s}: {s}\n", .{ try app.tilde(ctx, clone_path), cause });
            return 1;
        }
    }

    if (project) |*p| {
        try p.marker.repos.put(alloc, id.repo, url);
        try marker.save(&p.marker, try p.markerPath(alloc));
        _ = try hub.reconcile(alloc, &ws, p, false);
    }

    try ctx.out.print("{s}\n", .{clone_path});
    if (project) |*p| {
        try ctx.err.print("added {s} to {s}/{s}\n", .{ id.repo, p.org, p.name });
    }
    const shown = try app.tilde(ctx, clone_path);
    if (cloned) {
        try ctx.err.print("cloned {s} -> {s}\n", .{ url, shown });
    } else if (a.update) {
        try ctx.err.print("updated\n", .{});
    } else {
        try ctx.err.print("already present\n", .{});
    }
    return 0;
}

test "new: a bare name creates a local repo and attaches it when -p is given" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{ "scratch", "-p", "acme/proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const expected = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "scratch" });
    try testing.expectEqualStrings(expected, std.mem.trim(u8, got.out, " \t\r\n"));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:scratch", loaded.repos.get("scratch").?);
}

test "new: a bare name creates a local repo at code_root/local/<name>, prints the path, no marker or hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const expected_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "scratch" });
    // stdout is the created path (sole line); the "created" note is stderr.
    try testing.expectEqualStrings(expected_path, std.mem.trim(u8, got.out, " \t\r\n"));
    try testing.expect(std.mem.indexOf(u8, got.err, "created") != null);
    // It is a git repo (has a .git) ...
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ expected_path, ".git" })));
    // ... but commitless (unborn HEAD): no commit reachable from HEAD.
    try testing.expect(!try git.isCompleteClone(arena, expected_path));
    // No marker and no hub for a standalone create.
    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "local", "scratch", marker.marker_basename });
    try testing.expect(!fsutil.exists(marker_path));
}

test "new: an unsafe local name is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    for ([_][]const u8{ "..", ".hidden", "~x" }) |bad| {
        const got = try testutil.runCmd(arena, new_command.run, ws, &.{bad});
        try testing.expectEqual(@as(u8, 1), got.code);
    }
}

test "new: refuses when the target path already exists, pointing at adopt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // Pre-create the target path.
    const target = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "taken" });
    try fsutil.ensureDir(target);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"taken"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "adopt") != null);
}

test "new: a traversal spec that looks remote is refused (does not init outside code_root)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    for ([_][]const u8{ "../foo", "../../etc/passwd" }) |bad| {
        const got = try testutil.runCmd(arena, new_command.run, ws, &.{bad});
        try testing.expectEqual(@as(u8, 1), got.code);
    }
}

test "new: a backslash-traversal spec (Windows escape) is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // A segment carrying a literal backslash-dotdot would escape code_root on
    // Windows (clonePath joins with the platform separator); refuse it.
    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"a/..\\..\\..\\evil"});
    try testing.expectEqual(@as(u8, 1), got.code);
}

test "new: a scheme'd url with a traversal segment is refused via fromUrl" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // A full URL bypasses expand's shorthand path and reaches fromUrl, which
    // rejects the ".." segment - proving new's classify/run error routing
    // (not isSafeLocalName, which only guards the bare-name local branch).
    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"https://github.com/acme/../evil"});
    try testing.expectEqual(@as(u8, 1), got.code);
    // Nothing created on refusal.
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme" })));
}

test "new: a normal owner/repo shorthand still creates at the identity path with origin set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"acme/widget"});
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

test "new: -p attaches a local member (marker local:<name> + hub) and doctor does not flag it broken" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{ "tool", "-p", "acme/widget" });
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

test "new: -p to a nonexistent project fails without creating the repo" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{ "tool", "-p", "no/such" });
    try testing.expectEqual(@as(u8, 1), got.code);
    // No orphaned repo left behind.
    const clone_path = try identity.local("tool").clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(clone_path));
}

test "get: without -p clones a url standalone to its identity path with no marker and no hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/widget";

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const got = try testutil.runCmd(arena, get_command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 0), got.code);

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(fsutil.exists(clone_path));
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ clone_path, ".git" })));
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{clone_path}), got.out);

    // Standalone: no project marker anywhere and no hub tree at all.
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ clone_path, ".holt.json" })));
    try testing.expect(!fsutil.exists(ws.cfg.synced_root));
    try testing.expect(!fsutil.exists(ws.cfg.hub_root));
}

test "get: with -p clones, checks out a branch, and records the repo as a project member" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const url = "https://holt-test.invalid/acme/widget";
    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const got = try testutil.runCmd(arena, get_command.run, ws, &.{ url, "-p", "widget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try testing.expectEqualStrings(clone_path, std.mem.trim(u8, got.out, " \t\r\n"));
    const branch = try git.currentBranch(arena, clone_path);
    try testing.expect(branch != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings(url, loaded.repos.get("widget").?);
}

test "get: a local: argument is rejected and points at adopt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, get_command.run, ws, &.{"local:scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt repo adopt") != null);
}

test "get: an incomplete existing clone is refused, not reported as already present" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/widget";

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(clone_path);
    try testutil.runGit(&sb, clone_path, &.{ "init", "-q" });

    const got = try testutil.runCmd(arena, get_command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "incomplete") != null);
    // It must NOT have been printed to stdout as a usable clone path.
    try testing.expect(std.mem.indexOf(u8, got.out, clone_path) == null);
}

test "get: a second get on a present clone is idempotent and does not re-clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/widget";

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const first = try testutil.runCmd(arena, get_command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 0), first.code);

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    const stat_before = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_path, .{});

    const second = try testutil.runCmd(arena, get_command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 0), second.code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{clone_path}), second.out);
    try testing.expect(std.mem.indexOf(u8, second.err, "already present") != null);

    const stat_after = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_path, .{});
    try testing.expectEqual(stat_before.inode, stat_after.inode);
}

test "get: --update fast-forwards a present clone to a new upstream commit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const url = "https://holt-test.invalid/acme/widget";

    const gitconfig_path = try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" });
    const override = try testutil.gitInsteadOf(arena, gitconfig_path, &.{.{ .url = url, .bare = bare }});
    defer override.restore();

    const first = try testutil.runCmd(arena, get_command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 0), first.code);

    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);

    // Advance the bare's main by one commit from a throwaway clone, so the
    // ff-only pull has something real to fast-forward to.
    const push_clone = try testutil.makeWorkClone(&sb, bare);
    defer testing.allocator.free(push_clone);
    {
        var d = try std.Io.Dir.cwd().openDir(fsutil.io(), push_clone, .{});
        defer d.close(fsutil.io());
        try d.writeFile(fsutil.io(), .{ .sub_path = "NEWFILE", .data = "upstream advance\n" });
    }
    try testutil.runGit(&sb, push_clone, &.{ "add", "NEWFILE" });
    try testutil.runGit(&sb, push_clone, &.{ "commit", "-m", "advance" });
    try testutil.runGit(&sb, push_clone, &.{ "push", "origin", "main" });

    const updated = try testutil.runCmd(arena, get_command.run, ws, &.{ url, "--update" });
    try testing.expectEqual(@as(u8, 0), updated.code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{clone_path}), updated.out);
    try testing.expect(std.mem.indexOf(u8, updated.err, "updated") != null);
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ clone_path, "NEWFILE" })));
}

test "get: a parseable but unreachable url surfaces git's cause, naming the url" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    // Loopback with nothing listening: connection refused immediately, no
    // DNS or network dependency, so the failure is fast and deterministic.
    const url = "https://holt-test.invalid/x/y.git";
    const got = try testutil.runCmd(arena, get_command.run, ws, &.{url});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, url) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "GitCloneFailed") == null);

    const id = try identity.fromUrl(arena, url);
    const owner_dir = try std.fs.path.join(arena, &.{ ws.cfg.code_root, id.host, id.owner });
    try testing.expect(!fsutil.exists(owner_dir));
}

test "get: an existing local checkout redirects to repo adopt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const repo = try std.fs.path.join(arena, &.{ sb.root, "checkout", "widget" });
    try fsutil.ensureDir(repo);
    try testutil.runGit(&sb, repo, &.{ "init", "-q" });

    const got = try testutil.runCmd(arena, get_command.run, ws, &.{repo});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt repo adopt") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "local checkout") != null);
}

test "get: -p to a second project shares an existing clone rather than re-cloning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .{ .version = 1, .org = "acme", .name = "first", .repos = .empty });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .{ .version = 1, .org = "acme", .name = "second", .repos = .empty });

    const url = "https://holt-test.invalid/acme/widget";
    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);

    // Simulates a clone that already happened (via a prior `repo get`): a
    // real, complete clone at the identity path. Fresh clone success itself
    // is covered elsewhere, so this test only proves the shared-clone skip
    // and marker/hub wiring - but the clone must be genuine now that the
    // skip path rejects an incomplete one.
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    try git.clone(arena, bare, clone_path, null);
    const stat_before = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_path, .{});

    const first = try testutil.runCmd(arena, get_command.run, ws, &.{ url, "-p", "first" });
    try testing.expectEqual(@as(u8, 0), first.code);

    const second = try testutil.runCmd(arena, get_command.run, ws, &.{ url, "-p", "second" });
    try testing.expectEqual(@as(u8, 0), second.code);

    const stat_after = try std.Io.Dir.cwd().statFile(fsutil.io(), clone_path, .{});
    try testing.expectEqual(stat_before.inode, stat_after.inode);
    try testing.expect(std.mem.indexOf(u8, second.err, "already present") != null);

    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "second", "code", "widget" });
    switch (try fsutil.linkState(arena, hub_path)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "get: a repo already a member of the -p project is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const got = try testutil.runCmd(arena, get_command.run, ws, &.{ "https://holt-test.invalid/acme/widget", "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already a member") != null);
}

test "get: a local: argument with -p is rejected with adopt guidance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const got = try testutil.runCmd(arena, get_command.run, ws, &.{ "local:scratch", "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "adopt") != null);
}

test "get: with -p, a parseable but unreachable url surfaces git's cause, not a bare error name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    // Loopback with nothing listening: connection refused immediately, no
    // DNS or network dependency, so the failure is fast and deterministic.
    const url = "git://127.0.0.1:1/acme/widget";
    const got = try testutil.runCmd(arena, get_command.run, ws, &.{ url, "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "failed to clone") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, url) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "GitCloneFailed") == null);

    const id = try identity.fromUrl(arena, url);
    const owner_dir = try std.fs.path.join(arena, &.{ ws.cfg.code_root, id.host, id.owner });
    try testing.expect(!fsutil.exists(owner_dir));
}

test "get: -p to no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, get_command.run, ws, &.{ "https://holt-test.invalid/acme/widget", "-p", "nope" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}
