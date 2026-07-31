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
//! `adopt <path> [-p <project>] [--force]` registers an existing clone at
//! <path>, moving it to its identity path. The clone's origin (if any)
//! determines its identity; an unset origin becomes a `local:<basename>`
//! pseudo-URL, the same intake path `promote` later moves off of once a
//! real remote is added. Without -p the repo is standalone; with -p it is
//! recorded as a project member. Like `promote`, relocating the clone is
//! gated by `recover.check` and a destination that already exists is never
//! overwritten.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("../app.zig");
const common = @import("common.zig");
const project_mod = @import("../project.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const hub = @import("../hub.zig");
const git = @import("../git.zig");
const recover = @import("../recover.zig");
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
    .usage = "holt repo <new|get|adopt> ...",
    .group = .create,
    .subcommands = &.{ new_command, get_command, adopt_command },
    .needs_context = true,
    .run = runFallback,
};

fn runFallback(ctx: *app.Ctx) anyerror!u8 {
    return app.usageError(ctx, "usage: holt repo <new|get|adopt> ...", .{});
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

const AdoptSpec = struct {
    path: cli.Pos([]const u8, .{ .complete = .files, .help = "the existing clone to ingest" }),
    project: cli.Opt([]const u8, .{ .short = 'p', .value_name = "project", .complete = app.cat(.project), .help = "record the adopted repo as a member of this project" }),
    force: cli.Flag(.{ .short = 'f', .help = "adopt even if the clone has unrecoverable local state" }),
};

pub const adopt_command = app.command(AdoptSpec, .{
    .name = "adopt",
    .summary = "Register an existing clone, moving it to its identity path",
    .usage = "holt repo adopt <path> [-p <project>] [--force]",
    .group = .create,
    .needs_context = true,
    .details =
    \\Moves the clone to <code_root>/<host>/<owner>/<repo> (or local/<name> when
    \\it has no origin) and, with -p, records it in that project's marker.
    \\Refuses on dirty, stashed, or unpushed state unless --force.
    \\
    \\Example:
    \\  holt repo adopt ~/src/widget -p acme/widget
    ,
}, runAdopt);

/// The final path segment of `path`, ignoring any trailing slashes.
fn basenameOf(path: []const u8) []const u8 {
    var trimmed = path;
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    return std.fs.path.basename(trimmed);
}

/// Compares two paths by their resolved (symlink-free) form so a clone
/// already sitting at its identity path - reached via a different-but-equal
/// route - isn't mistaken for out-of-place. `clone_path` may not exist yet,
/// in which case its resolution falls back to the literal path.
fn samePath(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const ra = try fsutil.realPathOrSelf(alloc, a);
    const rb = try fsutil.realPathOrSelf(alloc, b);
    return std.mem.eql(u8, ra, rb);
}

/// `recover.check` restricted to dirty/stash blockers, for a clone with no
/// origin: unpushed/no_upstream are meaningless when there is no remote to
/// have pushed to in the first place.
fn localSafetyCheck(alloc: std.mem.Allocator, repo_path: []const u8) !recover.Verdict {
    var blockers: std.ArrayListUnmanaged(recover.Blocker) = .empty;
    if (try git.isDirty(alloc, repo_path)) try blockers.append(alloc, .dirty);
    if (try git.hasStashes(alloc, repo_path)) try blockers.append(alloc, .stashes);
    return .{ .blockers = blockers };
}

fn runAdopt(ctx: *app.Ctx, a: cli.Args(AdoptSpec)) anyerror!u8 {
    const project_query: ?[]const u8 = a.project;
    const path_arg: []const u8 = a.path;
    const force = a.force;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    // Project setup (project mode only): resolve, lock, re-read the marker.
    var p: project_mod.Project = undefined;
    var content_lock: ?projectlock.Handle = null;
    defer if (content_lock) |l| l.release();
    if (project_query) |q| {
        p = (try common.resolveOne(ctx, q)) orelse return 1;
        content_lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
        p.marker = try marker.load(alloc, try p.markerPath(alloc), null);
    }

    const abs_path = try fsutil.toAbsolute(alloc, path_arg);

    if (!fsutil.exists(abs_path)) {
        try ctx.err.print("holt: no clone found at {s}\n", .{try app.tilde(ctx, abs_path)});
        return 1;
    }

    if (!try git.inspectable(alloc, abs_path)) {
        try ctx.err.print("holt: {s} is not a readable git repository\n", .{try app.tilde(ctx, abs_path)});
        return 1;
    }

    const origin = try git.remoteUrl(alloc, abs_path);
    const basename = basenameOf(abs_path);

    var id: identity.Identity = undefined;
    var marker_value: []const u8 = undefined;
    if (origin) |o| {
        id = identity.fromUrl(alloc, o) catch |err| switch (err) {
            error.UnrecognizedUrl => {
                try ctx.err.print("holt: origin \"{s}\" is not a recognized git url\n", .{o});
                return 1;
            },
            else => return err,
        };
        marker_value = o;
    } else {
        id = identity.local(basename);
        marker_value = try std.fmt.allocPrint(alloc, "local:{s}", .{basename});
    }

    if (project_query != null and p.marker.repos.contains(id.repo)) {
        try ctx.err.print("holt: \"{s}\" is already a member of {s}/{s}\n", .{ id.repo, p.org, p.name });
        return 1;
    }

    const clone_path = try id.clonePath(alloc, ws.cfg.code_root);

    // Hold the clone-path lock through the relocate and the marker write (after
    // the content lock, a fixed order), so a concurrent `archive --prune`
    // cannot delete the destination clone between the move and the reference
    // to it landing on disk.
    var clone_lock = try projectlock.acquire(alloc, app.envOf(ctx), clone_path);
    defer clone_lock.release();

    var final_path: []const u8 = abs_path;
    var moved = false;

    if (!try samePath(alloc, abs_path, clone_path)) {
        if (fsutil.exists(clone_path)) {
            try ctx.err.print("holt: destination {s} already exists; refusing to overwrite\n", .{try app.tilde(ctx, clone_path)});
            return 1;
        }

        // A repo with no origin at all has no upstream by definition, so
        // recover.check's unpushed/no_upstream blockers would always fire
        // regardless of how safe the repo actually is - meaningless noise
        // for a local-only intake. Only dirty/stash state (real, avoidable
        // data-loss risk from the move) gates a local adopt.
        var verdict = if (origin != null) try recover.check(alloc, abs_path) else try localSafetyCheck(alloc, abs_path);
        if (!verdict.safe() and !force) {
            try ctx.err.print("holt: {s} has unrecoverable local state, refusing to adopt (use --force to override):\n", .{try app.tilde(ctx, abs_path)});
            try verdict.render(ctx.err);
            return 1;
        }

        common.moveClone(ctx, abs_path, clone_path) catch return 1;
        final_path = clone_path;
        moved = true;
    }

    // Standalone: no marker, no hub. Print the clone path (cd-friendly), like `get`.
    if (project_query == null) {
        try ctx.out.print("{s}\n", .{final_path});
        try ctx.err.print("{s}\n", .{if (moved) "adopted (standalone)" else "already there"});
        return 0;
    }

    // Project mode: record + reconcile, then report.
    try p.marker.repos.put(alloc, id.repo, marker_value);
    const marker_path = try p.markerPath(alloc);
    // Once the clone has been relocated, a marker or hub failure leaves the
    // move done but the project not yet updated. Name where the clone landed
    // and the idempotent re-run that finishes it, rather than leaking a bare
    // internal error that hides both.
    marker.save(&p.marker, marker_path) catch |err| {
        if (moved) {
            try reportUnfinishedAdopt(ctx, p.org, p.name, clone_path, err);
            return 1;
        }
        return err;
    };

    _ = hub.reconcile(alloc, &ws, &p, false) catch |err| {
        if (moved) {
            try reportUnfinishedAdopt(ctx, p.org, p.name, clone_path, err);
            return 1;
        }
        return err;
    };

    const rel = try id.relPath(alloc);
    try ctx.out.print("{s}\n", .{final_path});
    try ctx.err.print("adopted {s} -> {s}\n", .{ rel, try app.tilde(ctx, final_path) });
    return 0;
}

fn reportUnfinishedAdopt(ctx: *app.Ctx, org: []const u8, name: []const u8, clone_path: []const u8, err: anyerror) !void {
    const shown = try app.tilde(ctx, clone_path);
    try ctx.err.print("holt: the clone was moved to {s} but updating {s}/{s} failed: {s}; re-run \"holt repo adopt {s} -p {s}/{s}\" to finish\n", .{ shown, org, name, @errorName(err), shown, org, name });
}

/// Clones `bare` to `dest` and repoints origin at `fake_origin` - a URL
/// `identity.fromUrl` can parse - standing in for the real remote of a
/// clone the user made by hand somewhere outside `code_root`.
fn cloneWithOrigin(sb: *testutil.Sandbox, bare: []const u8, dest: []const u8, fake_origin: []const u8) !void {
    try testutil.runGit(sb, null, &.{ "clone", bare, dest });
    try testutil.runGit(sb, dest, &.{ "remote", "set-url", "origin", fake_origin });
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

test "adopt: takes the project as -p, not as a leading positional" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "acme/proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 1), loaded.repos.count());
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

test "adopt: adopts an out-of-place clone with an origin, moving it to the identity path and updating marker + hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    try testing.expect(!fsutil.exists(stray_path));
    try testing.expect(fsutil.exists(new_clone_path));
    try testing.expect(std.mem.indexOf(u8, got.out, new_clone_path) != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings(fake_origin, loaded.repos.get("scratch").?);

    const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "scratch" });
    switch (try fsutil.linkState(arena, code_link)) {
        .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
        else => return error.TestUnexpectedResult,
    }
}

test "adopt: adopts a no-remote dir into local/<basename> with a local: marker value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "myrepo" });
    try fsutil.ensureDir(stray_path);
    try testutil.runGit(&sb, stray_path, &.{ "init", "-b", "main" });

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const want_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "myrepo" });
    try testing.expect(!fsutil.exists(stray_path));
    try testing.expect(fsutil.exists(want_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:myrepo", loaded.repos.get("myrepo").?);
}

test "adopt: a dirty out-of-place clone refuses without --force, then proceeds with --force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);
    {
        var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), stray_path, .{});
        defer dir.close(fsutil.io());
        try dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });
    }

    const refused = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "uncommitted changes present") != null);
    try testing.expect(fsutil.exists(stray_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const before = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), before.repos.count());

    const forced = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "proj", "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(stray_path));

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(fsutil.exists(new_clone_path));
}

test "adopt: a destination already occupied refuses to overwrite" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const other_bare = try testutil.makeBareRepo(&sb, "other.git");
    defer testing.allocator.free(other_bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(std.fs.path.dirname(new_clone_path).?);
    try testutil.runGit(&sb, null, &.{ "clone", other_bare, new_clone_path });

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists") != null);
    try testing.expect(fsutil.exists(stray_path));
    try testing.expect(fsutil.exists(new_clone_path));
}

test "adopt: a repo short name already a member of the project is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "https://holt-test.invalid/other/scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already a member") != null);
}

test "adopt: no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ "/somewhere", "-p", "nope" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "adopt: a marker-save failure after the move names the new clone path and re-run command, and re-running finishes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    // A read-only content dir makes marker.save (writing .holt.json.tmp) fail
    // after the clone has already been relocated. Mode bits don't gate
    // access on Windows, so this whole simulation is POSIX-only.
    if (builtin.os.tag != .windows) {
        const content_rel = "synced/projects/acme/proj";
        try sb.tmp.dir.setFilePermissions(testing.io, content_rel, std.Io.File.Permissions.fromMode(0o555), .{});
        defer sb.tmp.dir.setFilePermissions(testing.io, content_rel, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "proj" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, try fsutil.contractTilde(arena, app.envOf_current(), new_clone_path)) != null);
        try testing.expect(std.mem.indexOf(u8, got.err, "re-run") != null);
        try testing.expect(std.mem.indexOf(u8, got.err, "holt repo adopt") != null);
        try testing.expect(std.mem.indexOf(u8, got.err, "-p acme/proj") != null);

        try testing.expect(!fsutil.exists(stray_path));
        try testing.expect(fsutil.exists(new_clone_path));

        // Restore perms and re-run with the new path: the idempotent move
        // short-circuits and the adopt completes.
        try sb.tmp.dir.setFilePermissions(testing.io, content_rel, std.Io.File.Permissions.fromMode(0o755), .{});
        const again = try testutil.runCmd(arena, adopt_command.run, ws, &.{ new_clone_path, "-p", "proj" });
        try testing.expectEqual(@as(u8, 0), again.code);

        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings(fake_origin, loaded.repos.get("scratch").?);
    }
}

test "adopt: a plain directory with no .git is refused as unreadable, nothing moved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const plain_path = try std.fs.path.join(arena, &.{ sb.root, "plain-dir" });
    try fsutil.ensureDir(plain_path);

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ plain_path, "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not a readable git repository") != null);
    try testing.expect(fsutil.exists(plain_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.repos.count());
}

test "adopt: a nonexistent path is a hard error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const missing_path = try std.fs.path.join(arena, &.{ root, "does-not-exist" });
    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ missing_path, "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, try fsutil.contractTilde(arena, app.envOf_current(), missing_path)) != null);
}

test "adopt: one-arg standalone adopt moves a clone to its ghq path with no marker and no hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/widget";

    // An existing local checkout at a NON-ghq path, with origin = fake_origin.
    const src = try std.fs.path.join(arena, &.{ sb.root, "checkout", "widget" });
    try cloneWithOrigin(&sb, bare, src, fake_origin);

    // Standalone adopt: no -p.
    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 0), got.code);

    const id = try identity.fromUrl(arena, fake_origin);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(fsutil.exists(clone_path)); // moved to ghq
    try testing.expect(!fsutil.exists(src)); // source gone
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{clone_path}), got.out); // path on stdout
    // Standalone: no marker, no hub.
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ clone_path, ".holt.json" })));
    try testing.expect(!fsutil.exists(ws.cfg.synced_root));
    try testing.expect(!fsutil.exists(ws.cfg.hub_root));
}

test "adopt: a relative path argument resolves against the cwd instead of crashing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = .empty });

    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    // cwd is process-global and shared by every test in this binary, so a
    // missing restore here would corrupt every test that runs afterward.
    try std.process.setCurrentPath(fsutil.io(), sb.root);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ "stray-clone", "-p", "proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    try testing.expect(!fsutil.exists(stray_path));
    try testing.expect(fsutil.exists(new_clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings(fake_origin, loaded.repos.get("scratch").?);

    const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "scratch" });
    switch (try fsutil.linkState(arena, code_link)) {
        .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
        else => return error.TestUnexpectedResult,
    }
}

test "adopt: standalone adopt of a repo with no remote lands under code/local" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // A local repo with NO origin.
    const src = try std.fs.path.join(arena, &.{ sb.root, "scratch", "thing" });
    try fsutil.ensureDir(src);
    try testutil.runGit(&sb, src, &.{ "init", "-q" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "f" }), .data = "x\n" });
    try testutil.runGit(&sb, src, &.{ "add", "f" });
    try testutil.runGit(&sb, src, &.{ "commit", "-m", "c" });

    const got2 = try testutil.runCmd(arena, adopt_command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 0), got2.code);
    const dest = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "thing" });
    try testing.expect(fsutil.exists(dest));
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}\n", .{dest}), got2.out);
}

test "adopt: standalone adopt of a clone already at its ghq path is a no-op" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const src = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "thing" });
    try fsutil.ensureDir(src);
    try testutil.runGit(&sb, src, &.{ "init", "-q" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "f" }), .data = "x\n" });
    try testutil.runGit(&sb, src, &.{ "add", "f" });
    try testutil.runGit(&sb, src, &.{ "commit", "-m", "c" });
    const inode_before = (try std.Io.Dir.cwd().statFile(fsutil.io(), src, .{})).inode;

    const got2 = try testutil.runCmd(arena, adopt_command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 0), got2.code);
    try testing.expect(std.mem.indexOf(u8, got2.err, "already there") != null);
    try testing.expectEqual(inode_before, (try std.Io.Dir.cwd().statFile(fsutil.io(), src, .{})).inode);
}

test "adopt: standalone adopt refuses when the ghq destination is occupied by another clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin2 = "https://holt-test.invalid/acme/widget";

    const id = try identity.fromUrl(arena, fake_origin2);
    const occupied_dest = try id.clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(occupied_dest);
    try testutil.runGit(&sb, occupied_dest, &.{ "init", "-q" }); // a DIFFERENT clone already there

    // Sandbox.init freezes GIT_CONFIG_GLOBAL=/dev/null into its git env
    // snapshot, so an insteadOf rewrite via a second gitconfig is invisible
    // to runGit; cloneWithOrigin (clone the bare repo directly, then
    // set-url) is the only way to get a real clone with fake_origin2 set.
    const bare2 = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare2);
    const src = try std.fs.path.join(arena, &.{ sb.root, "checkout", "widget" });
    try cloneWithOrigin(&sb, bare2, src, fake_origin2);

    const got2 = try testutil.runCmd(arena, adopt_command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 1), got2.code);
    try testing.expect(std.mem.indexOf(u8, got2.err, "already exists") != null);
    try testing.expect(fsutil.exists(src)); // source untouched
}

test "adopt: standalone adopt of a non-git path errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const dir = try std.fs.path.join(arena, &.{ sb.root, "plain" });
    try fsutil.ensureDir(dir);

    const got2 = try testutil.runCmd(arena, adopt_command.run, ws, &.{dir});
    try testing.expectEqual(@as(u8, 1), got2.code);
    try testing.expect(std.mem.indexOf(u8, got2.err, "not a readable git repository") != null);
}

test "adopt: standalone adopt of a dirty repo needs --force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const src = try std.fs.path.join(arena, &.{ sb.root, "scratch", "thing" });
    try fsutil.ensureDir(src);
    try testutil.runGit(&sb, src, &.{ "init", "-q" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "f" }), .data = "x\n" });
    try testutil.runGit(&sb, src, &.{ "add", "f" });
    try testutil.runGit(&sb, src, &.{ "commit", "-m", "c" });
    // Make it dirty: an uncommitted change.
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ src, "f" }), .data = "changed\n" });

    const refused = try testutil.runCmd(arena, adopt_command.run, ws, &.{src});
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "unrecoverable local state") != null);
    try testing.expect(fsutil.exists(src)); // not moved

    const forced = try testutil.runCmd(arena, adopt_command.run, ws, &.{ src, "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    const dest = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "thing" });
    try testing.expect(fsutil.exists(dest));
}
