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
//! `remove <repo> [-p <project>] [--clone] [--yes] [--force]` unlinks a repo
//! from a project's marker (-p) and, only when asked, deletes its checkout
//! under code_root (--clone). At least one of -p and --clone is required.
//! --clone refuses while any active project still references the repo, naming
//! them; refuses while a linked worktree exists (its objects live in the
//! clone's .git, so --force does not override this); and, unless --force,
//! refuses on what the deleter weighs (`deleter`): uncommitted changes, git
//! state no remote holds, files holt does not keep, nested repositories, and
//! unsettled kept files; --force still sets aside all but the nested
//! repositories first. Once every gate passes it names the checkout and asks;
//! only --yes skips that prompt, --force does not, since --force is what
//! waived the gates. With -p, the member is unlinked only once the delete has
//! succeeded, so a refused or failed delete leaves it in the project.
//! Without -p, <repo> is a code-tree key (as `holt list --repos` prints it);
//! with -p it is the member's short name in that project's marker.
//! `promote <repo> [--dry-run] [--yes] [--force]` moves a local repo
//! (recorded in markers as `local:<repo>`) to its real remote identity, once
//! its clone has grown an origin. The single most destructive operation in
//! holt - it relocates the clone on disk and rewrites every marker
//! referencing it - so the `recover.check` gate is mandatory unless --force
//! overrides it, and a destination that already exists is never merged into
//! or overwritten. Unlike every other subcommand here, <repo> is a local
//! repo's short name, not a member needing -p to name its project.
//! `alias <repo> [<name>] -p <project>` sets or clears the hub link name a
//! member repo browses under. With a name, the member's `code/<repo>` link
//! becomes `code/<name>`; without one, the alias is dropped and the derived
//! name returns. Either way the hub is reconciled so the on-disk symlink
//! follows.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const Env = @import("env").Env;
const app = @import("../app.zig");
const common = @import("common.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const hub = @import("../hub.zig");
const git = @import("../git.zig");
const recover = @import("../recover.zig");
const deleter = @import("deleter.zig");
const keep_cmd = @import("keep.zig");
const fsutil = @import("../fsutil.zig");
const ui = @import("../ui.zig");
const kept = @import("../kept.zig");
const kept_hooks = @import("kept_hooks.zig");
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
    .usage = "holt repo <new|get|adopt|remove|promote|alias> ...",
    .group = .create,
    .subcommands = &.{ new_command, get_command, adopt_command, remove_command, promote_command, alias_command },
    .needs_context = true,
    .run = runFallback,
};

fn runFallback(ctx: *app.Ctx) anyerror!u8 {
    return app.usageError(ctx, "usage: holt repo <new|get|adopt|remove|promote|alias> ...", .{});
}

/// Classifies <spec>: a recognized url/shorthand yields its identity and the
/// expanded origin url; a bare word that is a safe path segment yields a
/// local identity and null url. Anything else is UnrecognizedUrl.
const Target = struct { id: identity.Identity, origin: ?[]const u8 };

fn classify(alloc: std.mem.Allocator, spec: []const u8) !Target {
    const url = identity.expand(alloc, spec) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            const seg = fsutil.SafeSegment.parse(spec) orelse return error.UnrecognizedUrl;
            return .{ .id = identity.local(seg), .origin = null };
        },
        else => return err,
    };
    return .{ .id = try identity.fromUrl(alloc, url), .origin = url };
}

fn runNew(ctx: *app.Ctx, a: cli.Args(NewSpec)) anyerror!u8 {
    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const target = classify(alloc, a.spec) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err.print("holt: \"{s}\" is not a valid repo url or name\n", .{a.spec});
            return 1;
        },
        else => return err,
    };
    const clone_path = try target.id.clonePath(alloc, ws.cfg.code_root);

    // Resolve -p BEFORE any filesystem work, so a bad project fails without
    // leaving an orphaned git init behind.
    var project: ?project_mod.Project = null;
    if (a.project) |project_query| {
        project = (try common.resolveOne(ctx, project_query)) orelse return 1;
    }

    // Serialize with any other holt mutating this same project, then hold the
    // clone-path lock nested inside it - the fixed content-before-clone order
    // get/adopt/remove also use, so no two of them can deadlock. The clone
    // lock spans the init and the marker write, so a concurrent `repo remove
    // <key> --clone --force` cannot delete the fresh repo in between.
    var content_lock: ?projectlock.Handle = null;
    defer if (content_lock) |l| l.release();
    if (project) |*p| content_lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);

    var clone_lock = try projectlock.acquire(alloc, app.envOf(ctx), clone_path);
    defer clone_lock.release();

    if (fsutil.exists(clone_path)) {
        try ctx.err.print("holt: {s} already exists; use `holt repo adopt` to register an existing clone\n", .{try app.tilde(ctx, clone_path)});
        return 1;
    }

    const res = try git.run(alloc, &.{ "git", "init", "-q", "-b", "main", clone_path }, null);
    if (res.status != 0) {
        const cause = std.mem.trim(u8, res.stderr, " \t\r\n");
        try ctx.err.print("holt: git init failed at {s}: {s}\n", .{ try app.tilde(ctx, clone_path), cause });
        return 1;
    }

    if (target.origin) |origin| {
        // `--` separates the url from the options: git parses an option
        // anywhere in `remote add`'s argv, positionals included.
        const rr = try git.run(alloc, &.{ "git", "-C", clone_path, "remote", "add", "--", "origin", origin }, null);
        if (rr.status != 0) {
            const cause = std.mem.trim(u8, rr.stderr, " \t\r\n");
            try ctx.err.print("holt: failed to set origin on {s}: {s}\n", .{ try app.tilde(ctx, clone_path), cause });
            return 1;
        }
    }

    if (project) |*p| {
        // Re-read under the lock so this load-modify-save acts on the current
        // marker rather than a snapshot a concurrent run may have superseded.
        p.marker = try marker.load(alloc, try p.markerPath(alloc), null);

        const member_value = if (target.origin) |origin|
            origin
        else
            try std.fmt.allocPrint(alloc, "local:{s}", .{target.id.repo});

        try p.marker.upsert(alloc, target.id.repo, member_value);
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
    \\left as-is. The repo's kept files are linked into the clone.
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
        if (p.marker.findRepo(id.repo) != null) {
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
        try p.marker.upsert(alloc, id.repo, url);
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
    try kept_hooks.hook(ctx, ctx.err, clone_path, .{ .path = clone_path });
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
    \\Refuses on dirty, stashed, or unpushed state unless --force. Kept files
    \\of a clone under the code tree move to the new identity first. Its
    \\<clone>@worktrees dir moves with it; when that dir cannot be moved,
    \\each worktree is relinked where it is and the dir is named. A linked
    \\worktree of another repository is refused, naming the adopt of that
    \\repository's main clone instead.
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
    if (try refuseLinked(ctx, abs_path, project_query)) return 1;

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
        // With no origin the directory's own name becomes the local identity,
        // so it is held to the same single-safe-segment rule every reader of a
        // "local:<name>" marker value applies. Refusing here - before the
        // move - keeps adopt from minting a value nothing can read back.
        const seg = fsutil.SafeSegment.parse(basename) orelse {
            try ctx.err.print("holt: directory name \"{s}\" is not a usable repo name; rename the directory or give it an origin\n", .{basename});
            return 1;
        };
        id = identity.local(seg);
        marker_value = try std.fmt.allocPrint(alloc, "local:{s}", .{basename});
    }

    if (project_query != null and p.marker.findRepo(id.repo) != null) {
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
    var status: u8 = 0;

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

        const kept_locks = (try kept_hooks.moveKept(ctx, ctx.err, try kept_hooks.keyOf(ctx, abs_path), try id.relPath(alloc), abs_path, try adoptCommand(ctx, abs_path, project_query))) orelse return 1;
        common.moveClone(ctx, abs_path, clone_path) catch {
            kept_locks.release();
            return 1;
        };
        kept_locks.release();
        final_path = clone_path;
        moved = true;
    } else if (!try kept_hooks.finishMoves(ctx, ctx.err, try id.relPath(alloc), abs_path, try adoptCommand(ctx, abs_path, project_query))) {
        status = 1;
    }

    // Standalone: no marker, no hub. Print the clone path (cd-friendly), like `get`.
    if (project_query == null) {
        try ctx.out.print("{s}\n", .{final_path});
        try ctx.err.print("{s}\n", .{if (moved) "adopted (standalone)" else "already there"});
        try kept_hooks.hook(ctx, ctx.err, final_path, .{ .path = final_path });
        return status;
    }

    // Project mode: record + reconcile, then report.
    try p.marker.upsert(alloc, id.repo, marker_value);
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
    try kept_hooks.hook(ctx, ctx.err, final_path, .{ .path = final_path });
    return status;
}

/// Whether `path` is a linked worktree of another repository
/// (`git.linkedMain`), which adopt and promote refuse, naming its main
/// clone and the adopt of it, into `project` when given; moving the
/// worktree would relink that repository's records.
fn refuseLinked(ctx: *app.Ctx, path: []const u8, project: ?[]const u8) !bool {
    const main = try git.linkedMain(ctx.alloc, path) orelse return false;
    try ctx.err.print("holt: {s} is a linked worktree of the repository at {s}; adopt that clone instead (run: {s})\n", .{ try app.tilde(ctx, path), try app.tilde(ctx, main), try adoptCommand(ctx, main, project) });
    return true;
}

/// The `repo adopt` command that adopts the clone at `path`, into
/// `project` when given.
fn adoptCommand(ctx: *app.Ctx, path: []const u8, project: ?[]const u8) ![]const u8 {
    const p = try kept_hooks.quotedPath(ctx, path);
    if (project) |q| return std.fmt.allocPrint(ctx.alloc, "holt repo adopt {s} -p {s}", .{ p, try ui.shellQuote(ctx.alloc, q) });
    return std.fmt.allocPrint(ctx.alloc, "holt repo adopt {s}", .{p});
}

fn reportUnfinishedAdopt(ctx: *app.Ctx, org: []const u8, name: []const u8, clone_path: []const u8, err: anyerror) !void {
    const shown = try app.tilde(ctx, clone_path);
    try ctx.err.print("holt: the clone was moved to {s} but updating {s}/{s} failed: {s}; re-run \"holt repo adopt {s} -p {s}/{s}\" to finish\n", .{ shown, org, name, @errorName(err), shown, org, name });
}

const RemoveSpec = struct {
    repo: cli.Pos([]const u8, .{ .complete = app.cat(.repo), .help = "the member repo name, or a code-tree key when --clone is used alone" }),
    project: cli.Opt([]const u8, .{ .short = 'p', .value_name = "project", .complete = app.cat(.project), .help = "unlink the repo from this project" }),
    clone: cli.Flag(.{ .help = "also delete the checkout under code_root" }),
    yes: cli.Flag(.{ .short = 'y', .help = "skip the confirmation prompt --clone asks before deleting" }),
    force: cli.Flag(.{ .short = 'f', .help = "delete the checkout even with unrecoverable local state or files holt does not keep (those are set aside first)" }),
};

pub const remove_command = app.command(RemoveSpec, .{
    .name = "remove",
    .summary = "Unlink a repo from a project, and optionally delete its checkout",
    .usage = "holt repo remove <repo> [-p <project>] [--clone] [--yes] [--force]",
    .group = .create,
    .needs_context = true,
    .details =
    \\-p unlinks the repo from that project; the shared checkout stays. --clone
    \\additionally deletes the checkout, refusing while any active project
    \\still references it, while a linked worktree exists, and, unless
    \\--force, on dirty, stashed, or unpushed state, on a merge, rebase, am,
    \\cherry-pick, revert, or bisect in progress, or while it holds files holt
    \\does not keep, nested repositories, or unsettled kept files, naming the
    \\command that settles each: for an operation in a submodule git
    \\directory whose working tree is gone, first the commands bringing that
    \\tree back, and for one in a git directory that names no working tree,
    \\--force alone. One in a submodule git directory whose core.worktree
    \\names something that is not a directory, a symlink to nothing, a path
    \\under something that is not a directory, or what cannot be read
    \\refuses, even with --force, naming what is seen
    \\there and git config --file <module>/config core.worktree, to be
    \\resolved with git first. On a terminal, without --yes or --force, it
    \\first offers holt keep --review inline.
    \\At least one of -p and --clone is required.
    \\
    \\--force does not override a linked worktree. Each is weighed first, as
    \\holt worktree -r weighs it: one whose HEAD or per-worktree refs hold a
    \\commit neither a remote nor another ref holds is named with the
    \\command keeping it on a holt-kept/ branch or ref, and one with an
    \\operation in progress or staged changes only its record holds with the
    \\commands finishing, aborting, or stashing them (for one that is gone,
    \\after the command bringing it back from its record), one whose record
    \\holds a submodule git directory with a commit or stash no remote has
    \\with the command settling it, and one that is there holding nested
    \\repositories with holt repo adopt for each, and files holt does not
    \\keep with each of them and holt keep --review <worktree>; a line naming
    \\how to delete anyway names that worktree's removal with --force. Only a
    \\worktree holding nothing is named with the command removing it: holt
    \\worktree ... -r for one holt worktree made, when -p names its project,
    \\else git worktree remove <worktree>, which for one whose directory is
    \\gone removes that one record; a locked one is unlocked first, and a
    \\dirty one is committed or discarded first. A worktree in a state holt
    \\does not change, as holt worktree --help lists them (a path more than
    \\one record names, where git worktree remove may reach any of them, or
    \\one whose .git is gone, leads nowhere, or leads to another git
    \\directory than its record), and a worktree record git does not list
    \\(one whose gitdir cannot be read or is missing), with or without
    \\--force, is not weighed: it is named, once for each path, with what
    \\git and holt see there and git -C <clone> worktree list, or, for a
    \\record git does not list, the record's path, to be resolved with git
    \\first. holt never names git
    \\worktree repair or prune, which reach every worktree of the clone. On
    \\Windows, hints are for PowerShell 7, and rm -rf <path> is Remove-Item
    \\-Recurse -Force -LiteralPath <path>.
    \\
    \\A remote holds only what its ssh, git, http, and https URLs on another
    \\machine list now (git ls-remote): the push URLs of each ref's target
    \\first, then, while something is not held, its other URLs; none when
    \\nothing weighed is at risk. Each URL is asked once for each repository
    \\before the prompt, and again after it only when the prompt waited at a
    \\terminal (not with --yes), in a session of its own, with no prompt, for
    \\30 seconds at most, and stopped with holt when SIGINT, SIGTERM, or
    \\SIGHUP ends it. On a terminal each URL is announced on stderr once; off
    \\one, a query that has run 5 seconds says which host it waits for. Once
    \\a URL on a host fails for a reason of the host's, no other URL on that
    \\host is asked in the run; each is named not asked. A
    \\local path, a remote helper, and a URL whose host is this machine never
    \\count as a copy and are not asked. A URL that cannot be asked holds
    \\nothing, and why is named by holt, never quoted from git. A hint pushes
    \\a ref by its full name to a full destination, under holt-kept/ unless a
    \\branch can keep its own name. URLs are shown without their userinfo,
    \\query, and fragment, so no password or token is printed.
    \\
    \\--force waives the recoverability check and the kept-file checks: files
    \\holt does not keep, uncommitted changes (a symlink by its target), and
    \\unsettled content are still set aside in kept/ first; nested
    \\repositories, commits no remote has, and operations in progress, with
    \\the autostash one holds, are deleted, each named.
    \\Nothing is deleted if setting aside fails, or if the clone has kept-file
    \\links while kept/ cannot be reached; a refusal after something was
    \\set aside says the clone was kept and names each, with where
    \\kept/.holt-aside/ holds it. The clone's kept files stay in
    \\kept/<key>/; holt unkeep --repo <key> releases them.
    \\
    \\--clone names the checkout and asks before deleting it. Only --yes skips
    \\that prompt; --force does not, since --force is what waived the
    \\recoverability check.
    \\
    \\Example:
    \\  holt repo remove widget -p acme/proj
    \\  holt repo remove github.com/acme/widget --clone
    ,
}, runRemove);

fn runRemove(ctx: *app.Ctx, a: cli.Args(RemoveSpec)) anyerror!u8 {
    if (a.project == null and !a.clone) {
        return app.usageError(ctx, "requires -p <project>, --clone, or both", .{});
    }

    const alloc = ctx.alloc;
    const ws = ctx.context.?.ws;

    var id: ?identity.Identity = null;

    // Hold the content lock (if any) for the whole function, so a clone lock
    // taken further down for --clone nests inside it - the fixed content-
    // before-clone order `get`/`adopt` also use, avoiding a lock-order
    // deadlock against those commands.
    var content_lock: ?projectlock.Handle = null;
    defer if (content_lock) |l| l.release();
    var member: ?project_mod.Project = null;

    if (a.project) |q| {
        var p = (try common.resolveOne(ctx, q)) orelse return 1;

        // Lock and re-read so a concurrent holt mutating this project cannot
        // make this remove clobber (or be clobbered by) its edit.
        content_lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
        p.marker = try marker.load(alloc, try p.markerPath(alloc), null);

        const entry = p.marker.findEntry(a.repo) orelse {
            try ctx.err.print("holt: \"{s}\" is not a member of {s}/{s}\n", .{ a.repo, p.org, p.name });
            return 1;
        };

        // Resolved before any mutation, and never swallowed into a fallback:
        // an unusable marker value must not silently reinterpret <repo>
        // (a short member name) as a code-tree key further down - that would
        // resolve to, and delete, an unrelated clone. The entry itself stays
        // removable either way; only --clone needs a resolvable checkout.
        if (entry.source) |src| {
            id = switch (src) {
                .remote => |r| r.id,
                .local => |seg| identity.local(seg),
            };
        } else if (a.clone) {
            if (entry.raw_source != null) {
                try ctx.err.print("holt: {s}/{s}'s marker entry for \"{s}\" is not a usable url; --clone cannot resolve its checkout\n", .{ p.org, p.name, a.repo });
            } else {
                try ctx.err.print("holt: \"{s}\" is only an alias in {s}/{s}; there is no clone to remove\n", .{ a.repo, p.org, p.name });
            }
            return 1;
        }

        if (!a.clone) {
            try unlinkMember(ctx, &p, a.repo);
            if (id) |i| {
                const others = try ws.projectsUsing(alloc, i);
                const cp = try i.clonePath(alloc, ws.cfg.code_root);
                if (others.len > 0) {
                    try ctx.out.print("clone at {s} still used by:", .{try app.tilde(ctx, cp)});
                    for (others) |o| try ctx.out.print(" {s}", .{try o.qualified(alloc)});
                    try ctx.out.writeByte('\n');
                } else {
                    try ctx.out.print("no project references {s}; clone kept\n", .{try app.tilde(ctx, cp)});
                }
            }
            return 0;
        }
        member = p;
    }
    // With -p, the member is unlinked only once the clone's delete has
    // succeeded, so a refused or failed delete leaves it in the project.
    const still: []const u8 = if (member) |m| try std.fmt.allocPrint(alloc, "nothing changed, {s} is still in {s}/{s}", .{ a.repo, m.org, m.name }) else "";
    const unchanged: []const u8 = if (member != null) try std.mem.concat(alloc, u8, &.{ "; ", still }) else "";

    // --clone: only reached when a.clone is true (the usage check above
    // rejects neither -p nor --clone being given). `id` is set whenever -p
    // was given (a resolution failure above already returned), so this only
    // falls back to reading a.repo as a code-tree key for a bare --clone.
    const target = id orelse (identityFromKey(alloc, a.repo) catch |err| switch (err) {
        error.UnrecognizedUrl => {
            try ctx.err.print("holt: \"{s}\" is not a known repo or code-tree key\n", .{a.repo});
            return 1;
        },
        else => return err,
    });
    const clone_path = try target.clonePath(alloc, ws.cfg.code_root);

    // Hold the clone-path lock across the reference re-check and the delete:
    // a concurrent get/new/adopt that comes to reference this clone acquires
    // the same lock while writing its marker, so a reference that appears
    // after an earlier glance is still caught here rather than raced past.
    var clone_lock = try projectlock.acquire(alloc, app.envOf(ctx), clone_path);
    defer clone_lock.release();

    var users: std.ArrayList([]const u8) = .empty;
    for (try ws.projectsUsing(alloc, target)) |u| {
        if (member) |m| if (std.mem.eql(u8, u.org, m.org) and std.mem.eql(u8, u.name, m.name)) continue;
        try users.append(alloc, try u.qualified(alloc));
    }
    if (users.items.len > 0) {
        try ctx.err.print("holt: clone is still referenced by active project(s):", .{});
        for (users.items) |u| try ctx.err.print(" {s}", .{u});
        try ctx.err.print("{s}\n", .{unchanged});
        return 1;
    }

    if (!fsutil.exists(clone_path)) {
        try ctx.err.print("holt: no clone at {s}{s}\n", .{ try app.tilde(ctx, clone_path), unchanged });
        return 1;
    }

    // Deleting the clone leaves each linked worktree without its repository,
    // so it is refused, with no override, until each is removed. Each is
    // weighed first, as worktree -r weighs it: one whose removal would lose
    // something is not named with a removal until that is settled.
    //
    // Only a repo git can read is asked. A directory with no usable .git fails
    // the listing for want of a repository, not for a worktree; the deleter
    // weighs it as git state it cannot read, which --force does override. A
    // readable repo whose listing still fails is unexplained, so that case
    // keeps failing closed.
    if (try git.inspectable(alloc, clone_path)) {
        const worktree_count = git.worktreeCount(alloc, clone_path) catch 2;
        if (worktree_count > 1) {
            const cq = try ui.quotePath(alloc, app.envOf(ctx), clone_path);
            const kctx = deleter.keptCtx(ctx) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try ctx.err.print("holt: {s}: this machine's id cannot be read or written ({s}); refusing to delete{s}\n", .{ try app.tilde(ctx, clone_path), @errorName(err), unchanged });
                    return 1;
                },
            };
            var index: kept.store.KeyIndex = .{ .keys = &.{}, .successors = .empty, .bad = &.{} };
            if (try deleter.storeState(alloc, kctx.layout) == .ready) index = try kept.store.loadIndex(alloc, kctx.layout);
            const linked = deleter.linkedTrees(try deleter.Asker.of(ctx), clone_path, .{ .kctx = kctx, .index = &index }) catch |err| switch (err) {
                error.GitFailed => {
                    try ctx.err.print("holt: {s} has linked worktrees git cannot list; remove them first (run: git -C {s} worktree list){s}\n", .{ try app.tilde(ctx, clone_path), cq, unchanged });
                    return 1;
                },
                else => return err,
            };
            try ctx.err.print("holt: {s} has {d} other worktree(s); remove them first{s}:\n", .{ try app.tilde(ctx, clone_path), linked.len, unchanged });
            for (linked) |w| try printLinked(ctx, clone_path, member, a.repo, w, linked);
            return 1;
        }
    }

    var prepared = switch (try deleter.prepare(ctx, clone_path, .clone, .{ .review = keep_cmd.reviewHeld, .interactive = !a.yes and !a.force and ui.stdinIsTerminal() })) {
        .refused => |why| {
            try ctx.err.print("holt: {s}: {s}; refusing to delete{s}\n", .{ try app.tilde(ctx, clone_path), why, unchanged });
            return 1;
        },
        .ready => |p| p,
    };
    defer prepared.release();
    const force_cmd = if (member) |m|
        try std.fmt.allocPrint(alloc, "holt repo remove {s} -p {s} --clone --force", .{ try ui.shellQuote(alloc, a.repo), try ui.shellQuote(alloc, try m.qualified(alloc)) })
    else
        try std.fmt.allocPrint(alloc, "holt repo remove {s} --clone --force", .{try ui.shellQuote(alloc, try common.codeKey(alloc, ws.cfg.code_root, clone_path))});
    if (prepared.found.blocked() and !a.force) {
        try prepared.printBlocked(ctx, force_cmd);
        if (member != null) try ctx.err.print("holt: {s}\n", .{still});
        return 1;
    }

    // Asked last, once every gate has passed, so nobody confirms a delete the
    // command then refuses. The clone lock stays held across the answer, so a
    // concurrent command that would come to reference this clone still blocks
    // on it and cannot slip a marker write past the reference check above.
    if (!a.yes) {
        const detail = if (a.force)
            "--force waived the recoverability check, so whatever it holds may be unrecoverable"
        else
            "it is clean and pushed, so it can be cloned again from its remote";
        const msg = try std.fmt.allocPrint(alloc, "delete the local checkout at {s}? {s}", .{ try app.tilde(ctx, clone_path), detail });
        if (!try ui.confirm(ctx.out, msg)) {
            try ctx.out.print("delete cancelled; clone kept{s}\n", .{unchanged});
            return 0;
        }
    }

    switch (try prepared.clear(ctx, a.force, if (!a.yes and ui.stdinIsTerminal()) .fresh else .reuse)) {
        .done => {},
        .blocked => {
            try prepared.printBlocked(ctx, force_cmd);
            if (member != null) try ctx.err.print("holt: {s}\n", .{still});
            return 1;
        },
        .failed => {
            if (member != null) try ctx.err.print("holt: {s}\n", .{still});
            return 1;
        },
    }
    if (!try prepared.unchanged(ctx, a.force)) {
        try ctx.err.print("holt: {s}; run the command again\n", .{try prepared.changedWhy(ctx, "the clone")});
        if (member != null) try ctx.err.print("holt: {s}\n", .{still});
        return 1;
    }
    prepared.beforeDelete();
    common.removeContent(ctx, clone_path) catch {
        if (member) |m| try ctx.err.print("holt: {s} is still in {s}/{s}\n", .{ a.repo, m.org, m.name });
        return 1;
    };
    if (member) |*m| try unlinkMember(ctx, m, a.repo);
    if (std.fs.path.dirname(clone_path)) |owner_dir| {
        fsutil.rmdirIfEmpty(owner_dir);
        if (std.fs.path.dirname(owner_dir)) |host_dir| fsutil.rmdirIfEmpty(host_dir);
    }
    try ctx.out.print("deleted clone at {s}\n", .{try app.tilde(ctx, clone_path)});
    try prepared.printKeptRemain(ctx);
    return 0;
}

/// Prints the line or lines for the linked worktree `w` of the clone at
/// `clone_path`, one of `all`: for one holt leaves to the user
/// (`deleter.LinkedTree.seen`), `deleter.unresolvedLine`, once for each
/// path; what removing it destroys, each with the command settling it and
/// the command removing it anyway, when it holds anything
/// (`deleter.LinkedTree.atRisk`); else the command removing it. A
/// worktree `holt worktree` made is removed by that command when
/// `member`, the project `repo` is a member of, names it, else by git's,
/// which for one whose directory is gone removes that one record; a
/// locked one is unlocked first, and a dirty one is committed or discarded
/// first.
fn printLinked(ctx: *app.Ctx, clone_path: []const u8, member: ?project_mod.Project, repo: []const u8, w: deleter.LinkedTree, all: []const deleter.LinkedTree) !void {
    const alloc = ctx.alloc;
    const env = app.envOf(ctx);
    if (w.seen) |seen| {
        for (all) |o| {
            if (std.mem.eql(u8, o.record, w.record)) break;
            if (o.seen != null and std.mem.eql(u8, try deleter.resolvedPath(alloc, o.path), try deleter.resolvedPath(alloc, w.path))) return;
        }
        return ctx.err.print("  {s}\n", .{try deleter.unresolvedLine(ctx, w.path, seen, try deleter.mainGit(ctx, clone_path))});
    }
    const shown = try ui.printable(alloc, try app.tilde(ctx, w.path));
    const cq = try ui.quotePath(alloc, env, clone_path);
    const wq = try ui.quotePath(alloc, env, w.path);
    const unlock: []const u8 = if (w.locked) try std.fmt.allocPrint(alloc, "git -C {s} worktree unlock {s} && ", .{ cq, wq }) else "";
    const holt_cmd = try holtWorktree(ctx, clone_path, member, repo, w.path);
    if (w.atRisk()) {
        const force = if (holt_cmd) |cmd|
            try std.fmt.allocPrint(alloc, "{s}{s} --force", .{ unlock, cmd })
        else if (w.link == .absent)
            try std.fmt.allocPrint(alloc, "{s}git -C {s} worktree remove {s}", .{ unlock, cq, wq })
        else
            try std.fmt.allocPrint(alloc, "{s}git -C {s} worktree remove --force {s}", .{ unlock, cq, wq });
        for (try w.lines(ctx, clone_path, force)) |line| try ctx.err.print("  {s}\n", .{line});
        return;
    }
    const remove = holt_cmd orelse try std.fmt.allocPrint(alloc, "git -C {s} worktree remove {s}", .{ cq, wq });
    const state: []const u8 = if (w.gone()) ", which is gone" else if (w.locked) ", which is locked" else "";
    if (w.dirty) return ctx.err.print("  commit or discard the changes in {s}, then (run: {s}{s})\n", .{ shown, unlock, remove });
    try ctx.err.print("  {s}{s} (run: {s}{s})\n", .{ shown, state, unlock, remove });
}

/// `holt worktree <project>/<repo> <branch> -r`, which removes the linked
/// worktree at `path` of the clone at `clone_path` when `holt worktree`
/// made it there (`<clone>@worktrees/<branch>`) and `member`, the project
/// `repo` is a member of, names it; null otherwise.
fn holtWorktree(ctx: *app.Ctx, clone_path: []const u8, member: ?project_mod.Project, repo: []const u8, path: []const u8) !?[]const u8 {
    const alloc = ctx.alloc;
    const m = member orelse return null;
    const dir = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{clone_path});
    const at = try fsutil.normalizeTarget(alloc, path);
    const branch = for ([_][]const u8{ dir, try fsutil.realPathOrSelf(alloc, dir) }) |raw| {
        const d = try fsutil.normalizeTarget(alloc, raw);
        if (at.len > d.len + 1 and fsutil.pathIsInside(at, d)) break at[d.len + 1 ..];
    } else return null;
    const rel = try alloc.dupe(u8, branch);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
    if (fsutil.SafeRel.parse(rel) == null) return null;
    const target = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ try m.qualified(alloc), repo });
    return try std.fmt.allocPrint(alloc, "holt worktree {s} {s} -r", .{ try ui.shellQuote(alloc, target), try ui.shellQuote(alloc, rel) });
}

/// `holtWorktree` for the linked worktree at `path` of the clone at
/// `clone_path`, with the first member of a project of the run's
/// workspace whose clone is there; null when there is no workspace, or
/// no such member names it.
pub fn holtWorktreeOf(ctx: *app.Ctx, clone_path: []const u8, path: []const u8) !?[]const u8 {
    const alloc = ctx.alloc;
    const c = ctx.context orelse return null;
    const want = try fsutil.realPathOrSelf(alloc, clone_path);
    for (try c.ws.list(alloc)) |p| for (p.marker.entries) |e| {
        const src = e.source orelse continue;
        const at = try src.id().clonePath(alloc, c.ws.cfg.code_root);
        if (!std.mem.eql(u8, try fsutil.realPathOrSelf(alloc, at), want)) continue;
        if (try holtWorktree(ctx, clone_path, p, e.name, path)) |cmd| return cmd;
    };
    return null;
}

/// Removes the member `repo` from `p`'s marker, under the content lock the
/// caller holds, and rebuilds its hub.
fn unlinkMember(ctx: *app.Ctx, p: *project_mod.Project, repo: []const u8) !void {
    const alloc = ctx.alloc;
    const ws = ctx.context.?.ws;
    _ = p.marker.remove(repo);
    try marker.save(&p.marker, try p.markerPath(alloc));
    _ = try hub.reconcile(alloc, &ws, p, false);
    try ctx.out.print("removed {s} from {s}/{s}\n", .{ repo, p.org, p.name });
}

/// Resolves a code-tree key as `holt list --repos` prints it
/// (`<host>/<owner>/<repo>` or `local/<name>`) to an identity, so a clone with
/// no remaining project reference can still be named. The `local/` suffix is
/// held to the same single-safe-segment rule `fromUrl` applies to every other
/// segment: `clonePath` joins without normalizing, so a `..` here would name a
/// path outside code_root for the caller to delete.
fn identityFromKey(alloc: std.mem.Allocator, key: []const u8) !identity.Identity {
    if (std.mem.startsWith(u8, key, "local/")) {
        const name = key["local/".len..];
        const seg = fsutil.SafeSegment.parse(name) orelse return error.UnrecognizedUrl;
        return identity.local(seg);
    }
    return identity.fromUrl(alloc, try identity.expand(alloc, key));
}

const PromoteSpec = struct {
    repo: cli.Pos([]const u8, .{ .complete = app.cat(.local_repo), .help = "the short name of a local repo that has since gained a remote" }),
    dry_run: cli.Flag(.{ .help = "print the planned move and affected projects, then exit" }),
    yes: cli.Flag(.{ .short = 'y', .help = "skip the confirmation prompt" }),
    force: cli.Flag(.{ .short = 'f', .help = "promote even if the clone has unrecoverable local state (also skips the confirmation prompt)" }),
};

pub const promote_command = app.command(PromoteSpec, .{
    .name = "promote",
    .summary = "Move a local repo to its real remote identity once it has an origin",
    .usage = "holt repo promote <repo> [--dry-run] [--yes] [--force]",
    .group = .create,
    .needs_context = true,
    .details =
    \\<repo> is the short name of a local (unpushed) repo that has since gained
    \\a remote, as recorded in markers by "local:<repo>" - not a project
    \\selector. Its kept files move to the new identity before the clone does.
    \\Its <clone>@worktrees dir moves with it; when that dir cannot be moved,
    \\each worktree is relinked where it is and the dir is named. A local
    \\repo that is a linked worktree of another repository is refused,
    \\naming the adopt of that repository's main clone instead.
    \\
    \\Example:
    \\  holt repo promote scratch --yes
    ,
}, runPromote);

const Referencing = struct {
    project: project_mod.Project,
    repo_key: []const u8,
};

/// Every (project, repo key) pair whose member resolves to the local repo
/// `name`.
fn findReferencing(alloc: std.mem.Allocator, ws: *const workspace.Workspace, name: []const u8) ![]Referencing {
    const all = try ws.list(alloc);

    var out: std.ArrayList(Referencing) = .empty;
    for (all) |p| {
        for (p.marker.entries) |*e| {
            const src = e.source orelse continue;
            if (src != .local) continue;
            if (std.mem.eql(u8, src.local.bytes, name)) try out.append(alloc, .{ .project = p, .repo_key = e.name });
        }
    }
    return out.toOwnedSlice(alloc);
}

const Resolution = struct {
    origin: []const u8,
    new_id: identity.Identity,
    new_path: []const u8,
    /// False when a prior, interrupted promote already relocated the clone
    /// to `new_path` - the rename step is then skipped entirely.
    move_needed: bool,
};

const Resumed = struct { origin: []const u8, id: identity.Identity, path: []const u8 };

/// Points one referencing project's `repo_key` at the promoted repo's real
/// `origin`, under that project's lock with a fresh re-read, so a concurrent
/// holt mutating the same project neither loses this rewrite nor is lost by
/// it. The lock is scoped to this one project and released on return, so
/// promoting across many projects never holds two locks at once (no deadlock
/// against another promote acquiring them in a different order).
fn rewriteMemberOrigin(alloc: std.mem.Allocator, env: Env, ref: Referencing, origin: []const u8) !void {
    var lock = try projectlock.acquire(alloc, env, ref.project.content_path);
    defer lock.release();

    var p = ref.project;
    const marker_path = try p.markerPath(alloc);
    p.marker = try marker.load(alloc, marker_path, null);
    try p.marker.upsert(alloc, ref.repo_key, origin);
    try marker.save(&p.marker, marker_path);
}

/// A local repo's clone is gone from `old_path`. This is either an already
/// fully-promoted repo (nothing here to do - caught by `move_needed` being
/// moot) or a promote interrupted after the rename but before every marker
/// was rewritten: a sibling project sharing `ref.repo_key` already holds
/// the real origin instead of the "local:<name>" pseudo-URL, and the clone
/// now lives at that origin's identity clonePath.
fn alreadyMovedOrigin(alloc: std.mem.Allocator, ws: *const workspace.Workspace, referencing: []const Referencing) !?Resumed {
    const all = try ws.list(alloc);
    for (referencing) |ref| {
        for (all) |p| {
            const e = p.marker.findRepo(ref.repo_key) orelse continue;
            const src = e.source orelse continue;
            if (src != .remote) continue;

            // The url is another project's marker bytes, returned verbatim:
            // `rewriteMemberOrigin` writes it back into every referencing
            // marker, so normalizing it here would rewrite their remotes.
            const path = try src.remote.id.clonePath(alloc, ws.cfg.code_root);
            if (!fsutil.exists(path)) continue;
            if (try git.remoteUrl(alloc, path) == null) continue;

            return .{ .origin = src.remote.url, .id = src.remote.id, .path = path };
        }
    }
    return null;
}

/// Walks `code_root` (skipping the reserved "local" subtree) for a directory
/// named `name` that is a git clone with an `origin` remote configured - the
/// shape a promoted clone takes once moved to its real identity path. This
/// is the last-resort way to resume a promote interrupted before its very
/// first marker write, when no sibling marker survives to name the origin
/// either. Never descends into a clone's own `.git` internals.
fn findMovedClone(alloc: std.mem.Allocator, code_root: []const u8, name: []const u8) !?Resumed {
    var root_dir = std.Io.Dir.cwd().openDir(fsutil.io(), code_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer root_dir.close(fsutil.io());

    var walker = try root_dir.walkSelectively(alloc);
    defer walker.deinit();

    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.path, "local")) continue;

        const abs_path = try std.fs.path.join(alloc, &.{ code_root, entry.path });
        const git_dir = try std.fs.path.join(alloc, &.{ abs_path, ".git" });
        if (!fsutil.exists(git_dir)) {
            try walker.enter(fsutil.io(), entry);
            continue;
        }
        if (!std.mem.eql(u8, entry.basename, name)) continue;

        const origin = try git.remoteUrl(alloc, abs_path) orelse continue;
        const id = identity.fromUrl(alloc, origin) catch continue;
        return .{ .origin = origin, .id = id, .path = abs_path };
    }
    return null;
}

/// Resolves the origin URL and move state for `name`. Returns null after
/// printing the appropriate error to `ctx.err` - the caller should then
/// exit 1.
fn resolveOrigin(
    ctx: *app.Ctx,
    alloc: std.mem.Allocator,
    ws: *const workspace.Workspace,
    name: []const u8,
    old_path: []const u8,
    referencing: []const Referencing,
) !?Resolution {
    if (fsutil.exists(old_path)) {
        const origin = try git.remoteUrl(alloc, old_path) orelse {
            try ctx.err.print("holt: no remote configured for {s}\n", .{name});
            return null;
        };
        const new_id = identity.fromUrl(alloc, origin) catch |err| switch (err) {
            error.UnrecognizedUrl => {
                try ctx.err.print("holt: origin \"{s}\" for {s} is not a recognized git url\n", .{ origin, name });
                return null;
            },
            else => return err,
        };
        const new_path = try new_id.clonePath(alloc, ws.cfg.code_root);
        return .{ .origin = origin, .new_id = new_id, .new_path = new_path, .move_needed = true };
    }

    const resumed = (try alreadyMovedOrigin(alloc, ws, referencing)) orelse
        (try findMovedClone(alloc, ws.cfg.code_root, name));
    if (resumed) |r| {
        return .{ .origin = r.origin, .new_id = r.id, .new_path = r.path, .move_needed = false };
    }

    try ctx.err.print("holt: local clone for {s} not found at {s}\n", .{ name, try app.tilde(ctx, old_path) });
    return null;
}

/// Reports which projects were already rewritten before an error hit, so a
/// partial failure is diagnosable instead of a silent crash. Safe to call
/// with an empty `done`. `new_path` is where the clone sits right now (the
/// move already happened by the time this is called); when `done` is empty,
/// a re-run can only find it again via `findMovedClone`'s basename match, so
/// the "re-run to finish" hint is only printed when that would succeed.
fn printResumeHint(ctx: *app.Ctx, alloc: std.mem.Allocator, done: []const Referencing, name: []const u8, new_path: []const u8) !void {
    if (done.len == 0) {
        if (std.mem.eql(u8, std.fs.path.basename(new_path), name)) {
            try ctx.err.print("holt: promote failed before updating any project; re-run \"holt repo promote {s}\" to finish\n", .{name});
        } else {
            try ctx.err.print("holt: promote failed before updating any project; the clone now lives at {s} and cannot be found automatically - update a project's marker or move it back to resume\n", .{try app.tilde(ctx, new_path)});
        }
        return;
    }
    try ctx.err.writeAll("holt: promote updated ");
    for (done, 0..) |ref, i| {
        if (i != 0) try ctx.err.writeAll(", ");
        try ctx.err.print("{s}", .{try ref.project.qualified(alloc)});
    }
    try ctx.err.print(" before failing; re-run \"holt repo promote {s}\" to finish\n", .{name});
}

/// Prints the pending relocation and every project marker that will be
/// rewritten - the shared preview for both `--dry-run` and the interactive
/// confirmation.
fn printPlan(ctx: *app.Ctx, alloc: std.mem.Allocator, old_path: []const u8, new_path: []const u8, move_needed: bool, referencing: []const Referencing) !void {
    if (move_needed) {
        try ctx.out.print("move {s} -> {s}\n", .{ try app.tilde(ctx, old_path), try app.tilde(ctx, new_path) });
    } else {
        try ctx.out.print("clone already at {s}\n", .{try app.tilde(ctx, new_path)});
    }
    try ctx.out.print("rewrite {d} marker(s):\n", .{referencing.len});
    for (referencing) |ref| {
        try ctx.out.print("  {s}\n", .{try ref.project.qualified(alloc)});
    }
}

fn runPromote(ctx: *app.Ctx, a: cli.Args(PromoteSpec)) anyerror!u8 {
    const name = a.repo;
    const dry_run = a.dry_run;
    const yes = a.yes;
    const force = a.force;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    // The name arrives from argv, not from a parsed marker entry; check it
    // here, before it becomes the clone path this command moves and prunes
    // around.
    const seg = fsutil.SafeSegment.parse(name) orelse {
        try ctx.err.print("holt: \"{s}\" is not a usable local repo name\n", .{name});
        return 1;
    };

    const referencing = try findReferencing(alloc, &ws, name);
    if (referencing.len == 0) {
        try ctx.err.print("holt: no project references a local repo named \"{s}\"\n", .{name});
        return 1;
    }

    const old_path = try identity.local(seg).clonePath(alloc, ws.cfg.code_root);
    const resolved = try resolveOrigin(ctx, alloc, &ws, name, old_path, referencing) orelse return 1;
    const origin = resolved.origin;
    const new_path = resolved.new_path;

    if (resolved.move_needed and fsutil.exists(new_path)) {
        const dest_origin = try git.remoteUrl(alloc, new_path);
        const same_remote = if (dest_origin) |d| std.mem.eql(u8, d, origin) else false;
        if (same_remote) {
            try ctx.err.print("holt: destination {s} already cloned; resolve manually\n", .{try app.tilde(ctx, new_path)});
        } else {
            try ctx.err.print("holt: destination {s} already exists and is a different repo\n", .{try app.tilde(ctx, new_path)});
        }
        return 1;
    }

    if (fsutil.exists(old_path) and try refuseLinked(ctx, old_path, null)) return 1;

    const old_key = try std.fmt.allocPrint(alloc, "local/{s}", .{name});
    const new_key = try resolved.new_id.relPath(alloc);
    if (dry_run) {
        try printPlan(ctx, alloc, old_path, new_path, resolved.move_needed, referencing);
        const layout: kept.store.Layout = .{ .synced_root = ws.cfg.synced_root };
        if (try kept.store.readRecord(alloc, layout, old_key) != null or try kept.rekey.holds(alloc, layout, old_key)) {
            try ctx.out.print("move kept files kept/{s} -> kept/{s}\n", .{ old_key, new_key });
        }
        return 0;
    }

    if (resolved.move_needed) {
        var verdict = try recover.check(alloc, old_path);
        if (!verdict.safe() and !force) {
            try ctx.err.print("holt: {s} has unrecoverable local state, refusing to promote (use --force to override):\n", .{name});
            try verdict.render(ctx.err);
            return 1;
        }
    }

    if (!force and !yes) {
        try printPlan(ctx, alloc, old_path, new_path, resolved.move_needed, referencing);
        const prompt = try std.fmt.allocPrint(alloc, "Promote {s}? this moves the clone and rewrites {d} marker(s)", .{ name, referencing.len });
        if (!try ui.confirm(ctx.out, prompt)) {
            try ctx.out.writeAll("promote cancelled\n");
            return 0;
        }
    }

    // No clone-path lock here, deliberately. It is unnecessary: `archive
    // --prune` can never target this move. The source is a `local:` clone,
    // which prune never weighs (it skips `local:` members); the
    // destination, if it already exists, makes promote refuse above, and if it
    // does not, prune skips it as missing. A concurrent clone of the same
    // remote onto `new_path` is made non-corrupting by git.clone's atomic
    // temp-then-rename (this move would just fail cleanly with DirNotEmpty).
    // Taking a clone lock here WOULD deadlock: promote locks content per
    // referenced project below, so a clone-then-content order here inverts the
    // content-then-clone order add/adopt use.
    const kept_locks = (try kept_hooks.moveKept(ctx, ctx.err, old_key, new_key, if (resolved.move_needed) old_path else new_path, try std.fmt.allocPrint(alloc, "holt repo promote {s}", .{try ui.shellQuote(alloc, name)}))) orelse return 1;
    if (resolved.move_needed) {
        common.moveClone(ctx, old_path, new_path) catch {
            kept_locks.release();
            return 1;
        };
        if (std.fs.path.dirname(old_path)) |old_local_dir| fsutil.rmdirIfEmpty(old_local_dir);
    }
    kept_locks.release();

    var progress: std.ArrayList(Referencing) = .empty;
    for (referencing) |ref| {
        rewriteMemberOrigin(alloc, app.envOf(ctx), ref, origin) catch |err| {
            try printResumeHint(ctx, alloc, progress.items, name, new_path);
            return err;
        };
        try progress.append(alloc, ref);
    }

    const affected = try ws.projectsUsing(alloc, resolved.new_id);
    for (affected) |p| {
        _ = hub.reconcile(alloc, &ws, &p, false) catch |err| {
            try printResumeHint(ctx, alloc, progress.items, name, new_path);
            return err;
        };
    }

    try ctx.out.print("moved {s} -> {s}\n", .{ try app.tilde(ctx, old_path), try app.tilde(ctx, new_path) });
    try ctx.out.print("{d} marker(s) updated, hub(s) rebuilt\n", .{referencing.len});
    try kept_hooks.hook(ctx, ctx.out, new_path, .{ .path = new_path });
    return 0;
}

const AliasSpec = struct {
    repo: cli.Pos([]const u8, .{ .complete = app.cat(.repo), .help = "the member repo to alias" }),
    name: cli.Pos([]const u8, .{ .optional = true, .help = "the hub link name (omit to clear the alias)" }),
    project: cli.Opt([]const u8, .{ .short = 'p', .value_name = "project", .complete = app.cat(.project), .help = "the project whose hub link is renamed" }),
};

pub const alias_command = app.command(AliasSpec, .{
    .name = "alias",
    .summary = "Name the hub link a repo browses under",
    .usage = "holt repo alias <repo> [<name>] -p <project>",
    .group = .create,
    .needs_context = true,
    .details =
    \\Omit <name> to clear the alias and go back to the repo's own name.
    \\
    \\Example:
    \\  holt repo alias widget gadget -p acme/proj
    ,
}, runAlias);

const reserved_link_names = [_][]const u8{ "docs", "assets", "links" };

fn isReserved(name: []const u8) bool {
    for (reserved_link_names) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

/// True if `links` contains two entries sharing a rel-path.
fn hasDuplicateRel(links: []const hub.Link) bool {
    for (links, 0..) |a, i| {
        for (links[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.rel, b.rel)) return true;
        }
    }
    return false;
}

fn runAlias(ctx: *app.Ctx, a: cli.Args(AliasSpec)) anyerror!u8 {
    const query = a.project orelse return app.usageError(ctx, "alias requires -p <project>", .{});
    const repo_name = a.repo;
    const new_name = a.name;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    var p = (try common.resolveOne(ctx, query)) orelse return 1;

    // Lock and re-read so a concurrent holt mutating this project cannot make
    // this alias change clobber (or be clobbered by) its edit.
    var lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
    defer lock.release();
    p.marker = try marker.load(alloc, try p.markerPath(alloc), null);

    if (p.marker.findRepo(repo_name) == null) {
        try ctx.err.print("holt: \"{s}\" is not a member of {s}/{s}\n", .{ repo_name, p.org, p.name });
        return 1;
    }

    if (new_name) |name| {
        if (fsutil.SafeSegment.parse(name) == null) {
            try ctx.err.print("holt: \"{s}\" is not a valid link name (must be a single path segment)\n", .{name});
            return 1;
        }
        if (isReserved(name)) {
            try ctx.err.print("holt: \"{s}\" is a reserved hub link name\n", .{name});
            return 1;
        }

        _ = try p.marker.setAlias(alloc, repo_name, name);
        const links = (try hub.desiredLinks(alloc, &ws, &p)).links;
        if (hasDuplicateRel(links)) {
            try ctx.err.print("holt: alias \"{s}\" collides with another hub link in {s}/{s}\n", .{ name, p.org, p.name });
            return 1;
        }

        const marker_path = try p.markerPath(alloc);
        try marker.save(&p.marker, marker_path);
        _ = try hub.reconcile(alloc, &ws, &p, false);

        try ctx.out.print("aliased {s} -> code/{s}\n", .{ repo_name, name });
        return 0;
    }

    if (try p.marker.setAlias(alloc, repo_name, null)) {
        const marker_path = try p.markerPath(alloc);
        try marker.save(&p.marker, marker_path);
        _ = try hub.reconcile(alloc, &ws, &p, false);
        try ctx.out.print("cleared alias for {s}\n", .{repo_name});
    } else {
        try ctx.out.print("{s} has no alias in {s}/{s}\n", .{ repo_name, p.org, p.name });
    }
    return 0;
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{ "scratch", "-p", "acme/proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const expected = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "scratch" });
    try testing.expectEqualStrings(expected, std.mem.trim(u8, got.out, " \t\r\n"));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:scratch", loaded.findRepo("scratch").?.raw_source.?.string);
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

    for ([_][]const u8{ "..", "~x", ".git", "x.holt-tmp", "x@worktrees" }) |bad| {
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
    // (not the SafeSegment guard, which only covers the bare-name local branch).
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{ "tool", "-p", "acme/widget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget", marker.marker_basename });
    const m = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:tool", m.findRepo("tool").?.raw_source.?.string);

    const clone_path = try identity.local(fsutil.SafeSegment.parse("tool").?).clonePath(arena, ws.cfg.code_root);
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
    const clone_path = try identity.local(fsutil.SafeSegment.parse("tool").?).clonePath(arena, ws.cfg.code_root);
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);

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
    try testing.expectEqualStrings(url, loaded.findRepo("widget").?.raw_source.?.string);
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

    const url = "https://holt-test.invalid/x/y.git";
    const override = try testutil.gitUnreachable(arena, root, &.{url});
    defer override.restore();
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

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", .empty, .empty);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", .empty, .empty);

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

    const url = "https://holt-test.invalid/acme/widget";
    const override = try testutil.gitUnreachable(arena, root, &.{url});
    defer override.restore();
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray-clone" });
    try cloneWithOrigin(&sb, bare, stray_path, fake_origin);

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "acme/proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 1), loaded.memberCount());
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

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
    try testing.expectEqualStrings(fake_origin, loaded.findRepo("scratch").?.raw_source.?.string);

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

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
    try testing.expectEqualStrings("local:myrepo", loaded.findRepo("myrepo").?.raw_source.?.string);
}

test "adopt: a dot-leading no-remote dir is a usable local name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

    const stray_path = try std.fs.path.join(arena, &.{ sb.root, ".dotfiles" });
    try fsutil.ensureDir(stray_path);
    try testutil.runGit(&sb, stray_path, &.{ "init", "-b", "main" });

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ stray_path, "-p", "proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const want_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", ".dotfiles" });
    try testing.expect(!fsutil.exists(stray_path));
    try testing.expect(fsutil.exists(want_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:.dotfiles", loaded.findRepo(".dotfiles").?.raw_source.?.string);
}

test "adopt: a no-remote dir whose name is unusable as a local name is refused before the move" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

    // The basename is the whole local identity here, and every reader of a
    // "local:<name>" marker value rejects these - so adopt must never mint one.
    for ([_][]const u8{ "~cache", "x.holt-tmp", "x@worktrees" }) |bad_name| {
        const stray_path = try std.fs.path.join(arena, &.{ sb.root, "stray", bad_name });
        try fsutil.ensureDir(stray_path);
        try testutil.runGit(&sb, stray_path, &.{ "init", "-b", "main" });

        for ([_][]const []const u8{
            &.{ stray_path, "-p", "proj" },
            &.{stray_path}, // standalone, no marker involved
        }) |argv| {
            const got = try testutil.runCmd(arena, adopt_command.run, ws, argv);
            try testing.expectEqual(@as(u8, 1), got.code);
            try testing.expect(std.mem.indexOf(u8, got.err, bad_name) != null);

            // Refused BEFORE the move: the clone is still where it was.
            try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ stray_path, ".git" })));
            try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", bad_name })));
        }
    }

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.memberCount());
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

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
    try testing.expectEqual(@as(usize, 0), before.memberCount());

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

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
        try testing.expectEqualStrings(fake_origin, loaded.findRepo("scratch").?.raw_source.?.string);
    }
}

test "adopt: a plain directory with no .git is refused as unreadable, nothing moved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

    const plain_path = try std.fs.path.join(arena, &.{ sb.root, "plain-dir" });
    try fsutil.ensureDir(plain_path);

    const got = try testutil.runCmd(arena, adopt_command.run, ws, &.{ plain_path, "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not a readable git repository") != null);
    try testing.expect(fsutil.exists(plain_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.memberCount());
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

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
    try testing.expectEqualStrings(fake_origin, loaded.findRepo("scratch").?.raw_source.?.string);

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

test "remove: -p unlinks the member and leaves the clone on disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const id = try identity.fromUrl(arena, "https://holt-test.invalid/acme/widget");
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(clone_path);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "acme/proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.memberCount());
    try testing.expect(fsutil.exists(clone_path));
}

test "remove: --clone deletes an unreferenced checkout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");
    const reach = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = "https://holt-test.invalid/acme/widget", .bare = bare }});
    defer reach.restore();

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(clone_path));
}

test "remove: --clone asks before deleting, --force does not skip the prompt, only --yes does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");
    const reach = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = "https://holt-test.invalid/acme/widget", .bare = bare }});
    defer reach.restore();

    // Nothing to read is a "no", which is what a non-interactive invocation
    // gets: the prompt names the checkout and the clone survives.
    ui.stdin_for_test = "";
    defer ui.stdin_for_test = null;

    const declined = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone" });
    try testing.expectEqual(@as(u8, 0), declined.code);
    try testing.expect(std.mem.indexOf(u8, declined.out, "delete the local checkout at") != null);
    try testing.expect(std.mem.indexOf(u8, declined.out, "widget") != null);
    try testing.expect(std.mem.indexOf(u8, declined.out, "clone kept") != null);
    try testing.expect(fsutil.exists(clone_path));

    // The invocation that waives the recoverability check is asked too, and
    // told what --force means for the checkout it is about to destroy.
    {
        var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), clone_path, .{});
        defer dir.close(fsutil.io());
        try dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });
    }

    const forced = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone", "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(std.mem.indexOf(u8, forced.out, "delete the local checkout at") != null);
    try testing.expect(std.mem.indexOf(u8, forced.out, "may be unrecoverable") != null);
    try testing.expect(fsutil.exists(clone_path));

    // --yes is the one thing that deletes without asking.
    const accepted = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), accepted.code);
    try testing.expect(std.mem.indexOf(u8, accepted.out, "delete the local checkout at") == null);
    try testing.expect(!fsutil.exists(clone_path));
}

test "remove: --clone with -p changes nothing when the prompt is declined" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "only", repos, .empty);

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");
    const reach = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = "https://holt-test.invalid/acme/widget", .bare = bare }});
    defer reach.restore();

    ui.stdin_for_test = "";
    defer ui.stdin_for_test = null;

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "only", "--clone" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "clone kept; nothing changed, widget is still in acme/only") != null);
    try testing.expect(fsutil.exists(clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "only", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 1), loaded.memberCount());
}

test "remove: --clone refuses to delete a clone that has a linked worktree, even with --force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");

    // A linked worktree's objects and any unpushed commits live in the main
    // clone's .git; recover.check only inspects the main checkout, so this
    // must block regardless of the recoverability verdict there.
    const wt = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "feature-x" });
    try fsutil.ensureDir(std.fs.path.dirname(wt).?);
    try testutil.runGit(&sb, clone_path, &.{ "branch", "feature-x" });
    try testutil.runGit(&sb, clone_path, &.{ "worktree", "add", wt, "feature-x" });

    const refused = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "worktree") != null);
    try testing.expect(fsutil.exists(clone_path));

    // --force overrides recover.check's verdict, never the worktree guard.
    const forced = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone", "--force" });
    try testing.expectEqual(@as(u8, 1), forced.code);
    try testing.expect(std.mem.indexOf(u8, forced.err, "worktree") != null);
    try testing.expect(fsutil.exists(clone_path));
}

test "remove: --clone reports an unreadable directory as unreadable, and --force clears it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // A directory at an identity path that git cannot read as a repository:
    // `git worktree list` fails here for want of a repo, not for a worktree.
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try fsutil.ensureDir(clone_path);

    const refused = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "could not be read; --force deletes it\n") != null);
    try testing.expect(std.mem.indexOf(u8, refused.err, "other worktree(s)") == null);
    try testing.expect(fsutil.exists(clone_path));

    const forced = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(clone_path));
}

test "remove: --clone refuses a dirty clone without --force, then proceeds with --force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");
    const offline = try testutil.gitUnreachable(arena, sb.root, &.{"https://holt-test.invalid/acme/widget"});
    defer offline.restore();

    {
        var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), clone_path, .{});
        defer dir.close(fsutil.io());
        try dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });
    }

    const refused = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone" });
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "uncommitted changes: ") != null);
    try testing.expect(std.mem.indexOf(u8, refused.err, "run: git -C ") != null);
    try testing.expect(fsutil.exists(clone_path));

    const forced = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(clone_path));
}

test "remove: --clone refuses while a project still references the repo, naming it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "keeper", repos, .empty);

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "acme/keeper") != null);
    try testing.expect(fsutil.exists(clone_path));
}

test "remove: neither -p nor --clone is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{"widget"});
    try testing.expectEqual(@as(u8, 2), got.code);
}

test "remove: -p removing from one of two referencing projects keeps the clone and names the other" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos, .empty);

    var repos2: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos2.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", repos2, .empty);

    // A placeholder clone dir standing in for what a real `repo get` would
    // have cloned - remove never touches the clone in the -p-only path.
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try fsutil.ensureDir(clone_path);

    // Build the hub so the stale code/ link exists to be swept.
    const first_p = switch (try ws.find(arena, "first")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &first_p, false);
    const second_p = switch (try ws.find(arena, "second")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &second_p, false);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "first" });
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(fsutil.exists(clone_path));
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/second") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "still used by") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "first", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.memberCount());

    const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "first", "code", "widget" });
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, code_link));
}

test "remove: -p removing the last reference reports the clone as kept, still on disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "only", repos, .empty);

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try fsutil.ensureDir(clone_path);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "only" });
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(fsutil.exists(clone_path));
    try testing.expect(std.mem.indexOf(u8, got.out, "no project references") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "clone kept") != null);
}

test "remove: -p removing a repo drops its stale alias from the marker" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try aliases.put(arena, "widget", "gadget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, aliases);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expect(loaded.findEntry("widget") == null);
    try testing.expectEqual(@as(usize, 0), loaded.memberCount());
}

test "remove: -p to a repo not a member of the project is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not a member") != null);
}

test "remove: -p to no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "nope" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "remove: -p and --clone together unlink and delete when nothing else references the repo" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "only", repos, .empty);

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");
    const reach = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = "https://holt-test.invalid/acme/widget", .bare = bare }});
    defer reach.restore();

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "only", "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!fsutil.exists(clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "only", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.memberCount());
}

test "remove: -p and --clone together change nothing when a second project still references the clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos, .empty);

    var repos2: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos2.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", repos2, .empty);

    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "first", "--clone" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "acme/second; nothing changed, widget is still in acme/first") != null);
    try testing.expect(fsutil.exists(clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "first", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 1), loaded.memberCount());
}

test "remove: -p and --clone on a dirty clone refuse once, through the delete's gates, naming what settles it and changing nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "only", repos, .empty);
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");
    const offline = try testutil.gitUnreachable(arena, sb.root, &.{"https://holt-test.invalid/acme/widget"});
    defer offline.restore();
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ clone_path, "untracked.txt" }), .data = "hi\n" });

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "only", "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "unrecoverable local state") == null);
    try testing.expect(std.mem.indexOf(u8, got.err, "uncommitted changes: ") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "\nholt: nothing changed, widget is still in acme/only\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt;") == null);
    try testing.expect(std.mem.indexOf(u8, got.out, "removed widget") == null);
    try testing.expect(fsutil.exists(clone_path));
    const loaded = try marker.load(arena, try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "only", marker.marker_basename }), null);
    try testing.expectEqual(@as(usize, 1), loaded.memberCount());

    const hint = "holt repo remove widget -p acme/only --clone --force";
    try testing.expect(std.mem.indexOf(u8, got.err, hint) != null);
    const forced = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "acme/only", "--clone", "--force", "--yes" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(clone_path));
}

test "remove: -p and --clone whose delete fails leave the member in the project" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "only", repos, .empty);
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");
    const reach = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = "https://holt-test.invalid/acme/widget", .bare = bare }});
    defer reach.restore();
    const stuck = try std.fs.path.join(arena, &.{ clone_path, ".git", "stuck" });
    try fsutil.ensureDir(stuck);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ stuck, "f" }), .data = "x" });
    try std.Io.Dir.cwd().setFilePermissions(fsutil.io(), stuck, @enumFromInt(0o500), .{});
    defer std.Io.Dir.cwd().setFilePermissions(fsutil.io(), stuck, @enumFromInt(0o755), .{}) catch {};
    if (std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ stuck, "probe" }), .data = "x" })) |_| return error.SkipZigTest else |_| {}

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "widget", "-p", "only", "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt: widget is still in acme/only") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "removed widget") == null);
    const loaded = try marker.load(arena, try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "only", marker.marker_basename }), null);
    try testing.expectEqual(@as(usize, 1), loaded.memberCount());
}

test "remove: -p with an unparseable marker url refuses without falling back to a code-tree key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // The member's short name ("acme/widget") happens to also look like a
    // valid owner/repo shorthand - if the unusable marker value silently fell
    // back to identityFromKey, this would resolve to and threaten to delete
    // github.com/acme/widget, an entirely unrelated clone.
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "acme/widget", "not a url");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const decoy_clone = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "github.com", "acme", "widget" });
    try fsutil.ensureDir(decoy_clone);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "acme/widget", "-p", "proj", "--clone" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "acme/widget") != null);
    try testing.expect(fsutil.exists(decoy_clone));

    // Refused before mutating the marker: the bad entry is still there to fix.
    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 1), loaded.memberCount());
}

test "remove: -p without --clone removes a member whose value never parsed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "broken", "not a url");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "broken", "-p", "proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expect(loaded.findEntry("broken") == null);
}

test "remove: -p deletes an orphan alias" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    try testutil.writeRawMarker(arena, try ws.projectsRoot(arena), "acme", "proj",
        \\{"version":1,"org":"acme","name":"proj","repos":{},"aliases":{"ghost":"x"}}
    );

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "ghost", "-p", "proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.entries.len);
    try testing.expect(std.mem.indexOf(u8, try std.Io.Dir.cwd().readFileAlloc(testing.io, marker_path, arena, .limited(1 << 20)), "ghost") == null);
}

test "remove: --clone with a traversing local/ key is refused, leaving the outside target intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    // A clean, fully-pushed checkout outside code_root: every gate after the
    // key is resolved (references, worktrees, recover.check) would pass it, so
    // only refusing the key itself keeps it.
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const outside = try std.fs.path.join(arena, &.{ sb.root, "outside", "victim" });
    try cloneWithOrigin(&sb, bare, outside, "https://holt-test.invalid/acme/victim");

    // The key the identity path is derived from: code_root/local/<suffix>
    // resolves to the checkout outside code_root, which is what makes it a
    // deletable target rather than a name that fails to exist.
    const key = "local/../../outside/victim";
    const derived = try std.fs.path.join(arena, &.{ ws.cfg.code_root, key });
    try testing.expectEqualStrings(outside, try std.fs.path.resolve(arena, &.{derived}));

    for ([_][]const []const u8{
        &.{ key, "--clone" },
        &.{ key, "--clone", "--force" },
    }) |argv| {
        const got = try testutil.runCmd(arena, remove_command.run, ws, argv);
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "not a known repo or code-tree key") != null);
        try testing.expect(fsutil.exists(outside));
        try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ outside, ".git" })));
    }
}

test "promote: presents its argument as a local repo, not a project selector" {
    try testing.expect(std.mem.indexOf(u8, promote_command.usage, "<project>") == null);
    try testing.expect(std.mem.indexOf(u8, promote_command.usage, "<repo>") != null);
    try testing.expect(std.mem.indexOf(u8, promote_command.details, "local") != null);
    try testing.expect(std.mem.indexOf(u8, promote_command.details, "not a project") != null);
}

test "promote: promotes a local repo shared by two projects, rewriting both markers and both hubs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos_a, .empty);

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", repos_b, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);

    const first_before = switch (try ws.find(arena, "first")) {
        .one => |p| p,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &first_before, false);
    const second_before = switch (try ws.find(arena, "second")) {
        .one => |p| p,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &second_before, false);

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "2 marker(s) updated") != null);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    try testing.expect(!fsutil.exists(local_clone_path));
    try testing.expect(fsutil.exists(new_clone_path));

    for ([_][]const u8{ "first", "second" }) |proj_name| {
        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", proj_name, marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings(fake_origin, loaded.findRepo("scratch").?.raw_source.?.string);

        const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", proj_name, "code", "scratch" });
        switch (try fsutil.linkState(arena, code_link)) {
            .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "promote: carries a repo's worktrees along and keeps them working" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);

    // A worktree on the local clone, at its sibling `@worktrees` dir.
    const wt_old = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{local_clone_path}), "feature" });
    try testutil.runGit(&sb, local_clone_path, &.{ "branch", "feature" });
    try testutil.runGit(&sb, local_clone_path, &.{ "worktree", "add", wt_old, "feature" });

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const new_clone_path = try (try identity.fromUrl(arena, fake_origin)).clonePath(arena, ws.cfg.code_root);
    const wt_new = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{new_clone_path}), "feature" });

    // The worktrees dir moved with the clone, and the worktree still works -
    // currentBranch only succeeds if git's admin links were repaired.
    try testing.expect(!fsutil.exists(wt_old));
    try testing.expect(fsutil.exists(wt_new));
    try testing.expectEqualStrings("feature", (try git.currentBranch(arena, wt_new)).?);
}

test "promote: relinks each worktree that moved, and one outside the worktrees dir, one at a time, leaving another repository's worktree at a stale record's path and that record as they were" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);
    const wt_old = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{local_clone_path}), "feature" });
    try testutil.runGit(&sb, local_clone_path, &.{ "worktree", "add", "-q", "-b", "feature", wt_old });
    const outside = try std.fs.path.join(arena, &.{ sb.root, "outside" });
    try testutil.runGit(&sb, local_clone_path, &.{ "worktree", "add", "-q", "-b", "outside", outside });
    const shared = try std.fs.path.join(arena, &.{ sb.root, "shared" });
    try testutil.runGit(&sb, local_clone_path, &.{ "worktree", "add", "-q", "-b", "stale", shared });
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), shared);
    const other = try std.fs.path.join(arena, &.{ sb.root, "other" });
    try cloneWithOrigin(&sb, bare, other, "https://holt-test.invalid/acme/other");
    try testutil.runGit(&sb, other, &.{ "worktree", "add", "-q", "--detach", shared });
    const shared_git = try std.fs.path.join(arena, &.{ shared, ".git" });
    const shared_link = try kept.content.readSmall(arena, shared_git);
    const stale_gitdir = "worktrees/shared/gitdir";
    const stale_before = try kept.content.readSmall(arena, try std.fs.path.join(arena, &.{ local_clone_path, ".git", stale_gitdir }));

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const new_clone_path = try (try identity.fromUrl(arena, fake_origin)).clonePath(arena, ws.cfg.code_root);
    const wt_new = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{new_clone_path}), "feature" });
    try testing.expectEqualStrings("feature", (try git.currentBranch(arena, wt_new)).?);
    try testing.expectEqualStrings("outside", (try git.currentBranch(arena, outside)).?);
    const common_dir = try fsutil.realPathOrSelf(arena, try std.fs.path.join(arena, &.{ new_clone_path, ".git" }));
    for ([_][]const u8{ wt_new, outside }) |tree| {
        const found = try git.runInRepo(arena, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }, tree);
        try testing.expectEqualStrings(common_dir, try fsutil.realPathOrSelf(arena, std.mem.trim(u8, found.stdout, " \r\n")));
    }
    try testing.expectEqualStrings(shared_link, try kept.content.readSmall(arena, shared_git));
    try testing.expectEqualStrings(stale_before, try kept.content.readSmall(arena, try std.fs.path.join(arena, &.{ new_clone_path, ".git", stale_gitdir })));
    const theirs = try git.runInRepo(arena, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }, shared);
    try testing.expectEqualStrings(try fsutil.realPathOrSelf(arena, try std.fs.path.join(arena, &.{ other, ".git" })), try fsutil.realPathOrSelf(arena, std.mem.trim(u8, theirs.stdout, " \r\n")));
}

test "promote: when the worktrees dir cannot be moved, relinks each worktree where it is, the ones in that dir and the one outside it, and names the dir that was not moved" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);
    const old_wt_dir = try std.fmt.allocPrint(arena, "{s}@worktrees", .{local_clone_path});
    const wt_old = try std.fs.path.join(arena, &.{ old_wt_dir, "feature" });
    try testutil.runGit(&sb, local_clone_path, &.{ "worktree", "add", "-q", "-b", "feature", wt_old });
    const outside = try std.fs.path.join(arena, &.{ sb.root, "outside" });
    try testutil.runGit(&sb, local_clone_path, &.{ "worktree", "add", "-q", "-b", "outside", outside });
    const new_clone_path = try (try identity.fromUrl(arena, fake_origin)).clonePath(arena, ws.cfg.code_root);
    const new_wt_dir = try std.fmt.allocPrint(arena, "{s}@worktrees", .{new_clone_path});
    try fsutil.ensureDir(new_wt_dir);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ new_wt_dir, "blocker" }), .data = "x" });

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(fsutil.exists(wt_old));
    try testing.expectEqualStrings("feature", (try git.currentBranch(arena, wt_old)).?);
    try testing.expectEqualStrings("outside", (try git.currentBranch(arena, outside)).?);
    const common_dir = try fsutil.realPathOrSelf(arena, try std.fs.path.join(arena, &.{ new_clone_path, ".git" }));
    for ([_][]const u8{ wt_old, outside }) |tree| {
        const found = try git.runInRepo(arena, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }, tree);
        try testing.expectEqualStrings(common_dir, try fsutil.realPathOrSelf(arena, std.mem.trim(u8, found.stdout, " \r\n")));
    }
    try testing.expect(std.mem.indexOf(u8, got.err, try std.fmt.allocPrint(arena, "holt: moved clone but could not move its worktrees dir {s} to {s} (", .{ try fsutil.contractTilde(arena, app.envOf_current(), old_wt_dir), try fsutil.contractTilde(arena, app.envOf_current(), new_wt_dir) })) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "); the worktrees in it were not moved\n") != null);
    const listed = try git.runInRepo(arena, &.{ "worktree", "list", "--porcelain" }, new_clone_path);
    try testing.expect(std.mem.indexOf(u8, listed.stdout, "prunable") == null);
}

test "promote: --dry-run prints the planned move and affected projects, changing nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos_a, .empty);

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", repos_b, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--dry-run" });
    try testing.expectEqual(@as(u8, 0), got.code);
    const env = app.envOf_current();
    try testing.expect(std.mem.indexOf(u8, got.out, try fsutil.contractTilde(arena, env, local_clone_path)) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, try fsutil.contractTilde(arena, env, new_clone_path)) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/first") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "acme/second") != null);

    try testing.expect(fsutil.exists(local_clone_path));
    try testing.expect(!fsutil.exists(new_clone_path));

    for ([_][]const u8{ "first", "second" }) |proj_name| {
        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", proj_name, marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings("local:scratch", loaded.findRepo("scratch").?.raw_source.?.string);
    }
}

test "promote: a dirty clone refuses without --force, then proceeds with --force" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);

    var clone_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), local_clone_path, .{});
    defer clone_dir.close(fsutil.io());
    try clone_dir.writeFile(fsutil.io(), .{ .sub_path = "untracked.txt", .data = "hi\n" });

    const refused = try testutil.runCmd(arena, promote_command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), refused.code);
    try testing.expect(std.mem.indexOf(u8, refused.err, "uncommitted changes present") != null);
    try testing.expect(fsutil.exists(local_clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded_after_refusal = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:scratch", loaded_after_refusal.findRepo("scratch").?.raw_source.?.string);

    const forced = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--force" });
    try testing.expectEqual(@as(u8, 0), forced.code);
    try testing.expect(!fsutil.exists(local_clone_path));

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try testing.expect(fsutil.exists(new_clone_path));

    const loaded_after_force = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings(fake_origin, loaded_after_force.findRepo("scratch").?.raw_source.?.string);
}

test "promote: a destination already cloned from the same remote stops without changing anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, new_clone_path, fake_origin);

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already cloned; resolve manually") != null);

    try testing.expect(fsutil.exists(local_clone_path));
    try testing.expect(fsutil.exists(new_clone_path));

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:scratch", loaded.findRepo("scratch").?.raw_source.?.string);
}

test "promote: a destination occupied by a different repo is a hard error" {
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
    const fake_origin = "https://holt-test.invalid/acme/scratch";
    const other_fake_origin = "https://holt-test.invalid/other/thing";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, other_bare, new_clone_path, other_fake_origin);

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "different repo") != null);
    try testing.expect(fsutil.exists(local_clone_path));
}

test "promote: no project referencing the local repo is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{"nope"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "promote: a traversing local name is refused, leaving the outside checkout in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const ws = try testutil.testWorkspace(arena, sb.root);

    // A clean, fully-pushed checkout outside code_root. `findReferencing`
    // matches marker values verbatim, so the marker alone makes this name
    // reachable; every later gate (remote, recover.check, destination) would
    // pass it, so only refusing the name itself keeps the checkout put.
    const name = "../../outside/victim";
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", try std.fmt.allocPrint(arena, "local:{s}", .{name}));
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const outside = try std.fs.path.join(arena, &.{ sb.root, "outside", "victim" });
    try cloneWithOrigin(&sb, bare, outside, "https://holt-test.invalid/acme/victim");

    // code_root/local must exist for the traversal to resolve at all.
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local" }));
    const derived = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", name });
    try testing.expectEqualStrings(outside, try std.fs.path.resolve(arena, &.{derived}));

    for ([_][]const []const u8{
        &.{ name, "--yes" },
        &.{ name, "--dry-run" },
        &.{ name, "--force" },
    }) |argv| {
        const got = try testutil.runCmd(arena, promote_command.run, ws, argv);
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "not a usable local repo name") != null);
        try testing.expect(fsutil.exists(outside));
        try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ outside, ".git" })));
        try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ sb.root, "outside" })));
    }

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("local:../../outside/victim", loaded.findRepo("widget").?.raw_source.?.string);
}

test "promote: no remote configured on the local clone is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(local_clone_path);
    try testutil.runGit(&sb, local_clone_path, &.{ "init", "-b", "main" });

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "no remote configured for scratch") != null);
}

test "promote: resumes an interrupted promote, finishing the leftover marker and hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    // "first" already got its marker rewritten by a prior run; "second" is
    // the leftover this run must finish.
    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "scratch", fake_origin);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos_a, .empty);

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", repos_b, .empty);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, new_clone_path, fake_origin);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(local_clone_path));

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "1 marker(s) updated") != null);

    for ([_][]const u8{ "first", "second" }) |proj_name| {
        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", proj_name, marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings(fake_origin, loaded.findRepo("scratch").?.raw_source.?.string);

        const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", proj_name, "code", "scratch" });
        switch (try fsutil.linkState(arena, code_link)) {
            .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
            else => return error.TestUnexpectedResult,
        }
    }

    try testing.expect(!fsutil.exists(local_clone_path));
    try testing.expect(fsutil.exists(new_clone_path));
}

test "promote: resumes a promote whose clone moved before any marker was written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    // Both projects are still on the "local:scratch" pseudo-URL, as if the
    // prior run's rename succeeded but failed before its very first marker
    // write - no sibling marker survives to name the origin.
    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos_a, .empty);

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "second", repos_b, .empty);

    const new_id = try identity.fromUrl(arena, fake_origin);
    const new_clone_path = try new_id.clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, new_clone_path, fake_origin);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(local_clone_path));

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "2 marker(s) updated") != null);

    for ([_][]const u8{ "first", "second" }) |proj_name| {
        const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", proj_name, marker.marker_basename });
        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqualStrings(fake_origin, loaded.findRepo("scratch").?.raw_source.?.string);

        const code_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", proj_name, "code", "scratch" });
        switch (try fsutil.linkState(arena, code_link)) {
            .symlink => |t| try testing.expectEqualStrings(new_clone_path, t),
            else => return error.TestUnexpectedResult,
        }
    }

    try testing.expect(!fsutil.exists(local_clone_path));
    try testing.expect(fsutil.exists(new_clone_path));
}

test "promote: promoting the last local repo prunes the emptied code_root/local/ dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);

    const local_dir = std.fs.path.dirname(local_clone_path).?;
    try testing.expect(fsutil.exists(local_dir));

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(!fsutil.exists(local_dir));
}

test "promote: promoting one of two local repos leaves code_root/local/ in place for the other" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);

    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);

    const other_local_path = try identity.local(fsutil.SafeSegment.parse("other").?).clonePath(arena, ws.cfg.code_root);
    try fsutil.ensureDir(other_local_path);

    const local_dir = std.fs.path.dirname(local_clone_path).?;

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(fsutil.exists(local_dir));
    try testing.expect(fsutil.exists(other_local_path));
}

test "promote: a local clone missing from both the old and new path is a hard error, not a crash" {
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

    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try testing.expect(!fsutil.exists(local_clone_path));

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not found at") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, try fsutil.contractTilde(arena, app.envOf_current(), local_clone_path)) != null);
}

test "alias: takes the project as -p and renames the hub link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, alias_command.run, ws, &.{ "widget", "gadget", "-p", "acme/proj" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("gadget", loaded.findEntry("widget").?.raw_alias.?.string);
}

test "alias: missing -p is a usage error naming the requirement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, alias_command.run, ws, &.{ "widget", "gadget" });
    try testing.expectEqual(@as(u8, 2), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "-p") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "project") != null);
}

test "alias: setting an alias records it and reconciles the hub link" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    // Build the hub first so the derived code/widget link exists to be swept.
    const p0 = switch (try ws.find(arena, "proj")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p0, false);

    const got = try testutil.runCmd(arena, alias_command.run, ws, &.{ "widget", "gadget", "-p", "proj" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "code/gadget") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("gadget", loaded.findEntry("widget").?.raw_alias.?.string);

    const alias_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "gadget" });
    switch (try fsutil.linkState(arena, alias_link)) {
        .symlink => |t| try testing.expectEqualStrings(
            try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" }),
            t,
        ),
        else => return error.TestUnexpectedResult,
    }
    const old_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "widget" });
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, old_link));
}

test "alias: clearing an alias reverts the hub link to the derived name" {
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
    var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try aliases.put(arena, "widget", "gadget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, aliases);

    const p0 = switch (try ws.find(arena, "proj")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p0, false);

    // No trailing <name>: proves the optional second positional still omits
    // cleanly with a flag (-p) following it on the command line.
    const got = try testutil.runCmd(arena, alias_command.run, ws, &.{ "widget", "-p", "proj" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "cleared alias") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.aliasCount());

    const derived_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "widget" });
    switch (try fsutil.linkState(arena, derived_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
    const alias_link = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj", "code", "gadget" });
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(arena, alias_link));
}

test "alias: an alias colliding with a reserved link name errors and changes nothing" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, alias_command.run, ws, &.{ "widget", "docs", "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "reserved") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.aliasCount());
}

test "alias: an alias carrying a path separator errors and changes nothing" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    for ([_][]const u8{ "../../evil", "..\\..\\evil", "~evil" }) |bad| {
        const got = try testutil.runCmd(arena, alias_command.run, ws, &.{ "widget", bad, "-p", "proj" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "not a valid link name") != null);

        const loaded = try marker.load(arena, marker_path, null);
        try testing.expectEqual(@as(usize, 0), loaded.aliasCount());
    }
}

test "alias: an alias colliding with another member's link errors and changes nothing" {
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
    try repos.put(arena, "gadget", "https://holt-test.invalid/acme/gadget");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try testutil.runCmd(arena, alias_command.run, ws, &.{ "widget", "gadget", "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "collides") != null);

    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "proj", marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqual(@as(usize, 0), loaded.aliasCount());
}

test "alias: aliasing a non-member repo is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .empty, .empty);

    const got = try testutil.runCmd(arena, alias_command.run, ws, &.{ "widget", "gadget", "-p", "proj" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "not a member") != null);
}

test "alias: no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, alias_command.run, ws, &.{ "widget", "gadget", "-p", "nope" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

const kept_test = kept_hooks.TestBed;
const kept_interrupt = @import("../kept/interrupt.zig");

/// Replaces `to`'s `kept/` with `from`'s, as a backend delivering every
/// change, deletions included.
fn deliverKept(a: std.mem.Allocator, from: *const kept_test, to: *const kept_test) !void {
    const dst = try std.fs.path.join(a, &.{ to.ws.cfg.synced_root, "kept" });
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), dst);
    try kept.content.copyRegular(a, try std.fs.path.join(a, &.{ from.ws.cfg.synced_root, "kept" }), dst);
}

test "get: links the kept files of the repo into its new clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const key = "holt-test.invalid/acme/widget";
    const first = try bed.clone(key);
    try bed.write(first, "notes.txt", "notes");
    try bed.keep(first, "notes.txt");
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), first);

    const url = "https://holt-test.invalid/acme/widget";
    const override = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = url, .bare = bed.bare }});
    defer override.restore();
    const got = try testutil.runCmd(arena, get_command.run, bed.ws, &.{url});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(try bed.linked(first, key, "notes.txt"));
    try testing.expectEqualStrings("notes", try bed.read(first, "notes.txt"));
    try testing.expect(std.mem.indexOf(u8, got.err, try std.fmt.allocPrint(arena, "linked {s}\n", .{try bed.shown(try std.fs.path.join(arena, &.{ first, "notes.txt" }))})) != null);
}

test "get: without kept/, a fresh clone holding nothing to keep prints no first-use line, and stdout stays the clone path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.init(arena, &sb, "");
    defer bed.deinit();
    const url = "https://holt-test.invalid/acme/widget";
    const override = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = url, .bare = bed.bare }});
    defer override.restore();
    const got = try testutil.runCmd(arena, get_command.run, bed.ws, &.{url});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, kept_hooks.not_set_up) == null);
    try testing.expect(std.mem.indexOf(u8, got.out, kept_hooks.not_set_up) == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, "\n"));
}

test "adopt: moves the kept files to the new key before the clone, and relinks them there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const src = try bed.clone("tmp/widget");
    try testutil.runGit(&sb, src, &.{ "remote", "set-url", "origin", "https://holt-test.invalid/acme/widget" });
    try bed.write(src, ".clasp.json", "{\"scriptId\": \"abc\"}");
    try bed.keep(src, ".clasp.json");
    try testutil.runGit(&sb, src, &.{ "branch", "feature" });
    try testutil.runGit(&sb, src, &.{ "worktree", "add", "-q", try std.fmt.allocPrint(arena, "{s}@worktrees/feature", .{src}), "feature" });

    const got = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{src});
    try testing.expectEqual(@as(u8, 0), got.code);
    const new_key = "holt-test.invalid/acme/widget";
    const dest = try fsutil.joinSlashy(arena, bed.ws.cfg.code_root, new_key);
    try testing.expect(try bed.linked(dest, new_key, ".clasp.json"));
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try bed.read(dest, ".clasp.json"));
    const moved_wt = try std.fmt.allocPrint(arena, "{s}@worktrees/feature", .{dest});
    try testing.expect(try bed.linked(moved_wt, new_key, ".clasp.json"));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ bed.ws.cfg.synced_root, "kept", "tmp" })));
    try testing.expect(std.mem.indexOf(u8, got.err, "moved 1 kept path from kept/tmp/widget to kept/holt-test.invalid/acme/widget\n") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "retargeted ") != null);
}

test "promote: kept files move with the repo on one machine, and a second machine still on the old identity is told, then retargets after promoting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const saved = app.environ_override;
    defer app.environ_override = saved;
    defer kept_interrupt.at = null;
    const origin = "https://holt-test.invalid/acme/scratch";
    const new_key = "holt-test.invalid/acme/scratch";

    var ma = try kept_test.init(arena, &sb, "a");
    try ma.createStore();
    const ca = try ma.clone("local/scratch");
    try testutil.runGit(&sb, ca, &.{ "remote", "set-url", "origin", origin });
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ma.ws.projectsRoot(arena), "acme", "proj", repos, .empty);
    try ma.write(ca, ".clasp.json", "{\"scriptId\": \"abc\"}");
    try ma.write(ca, ".superpowers/plan.md", "plan");
    try ma.keep(ca, ".clasp.json");
    try ma.keep(ca, ".superpowers");

    var mb = try kept_test.init(arena, &sb, "b");
    mb.bare = ma.bare;
    const cb = try mb.clone("local/scratch");
    try testutil.runGit(&sb, cb, &.{ "remote", "remove", "origin" });
    try testutil.writeMarker(arena, try mb.ws.projectsRoot(arena), "acme", "proj", repos, .empty);
    try deliverKept(arena, &ma, &mb);
    const sync_cmd = @import("sync.zig").command;
    const first_b = try testutil.runCmd(arena, sync_cmd.run, mb.ws, &.{});
    try testing.expectEqual(@as(u8, 0), first_b.code);
    try testing.expect(try mb.linked(cb, "local/scratch", ".clasp.json"));

    try ma.use();
    kept_interrupt.at = .rekey_path;
    const cut = try testutil.runCmd(arena, promote_command.run, ma.ws, &.{ "scratch", "--yes" });
    kept_interrupt.at = null;
    try testing.expectEqual(@as(u8, 1), cut.code);
    try testing.expect(std.mem.indexOf(u8, cut.err, "cannot move the kept files of kept/local/scratch to kept/holt-test.invalid/acme/scratch: Interrupted; the clone was not moved - run: holt repo promote scratch\n") != null);
    try testing.expect(fsutil.exists(ca));
    const moved_first = try (kept.store.Layout{ .synced_root = ma.ws.cfg.synced_root }).copyPath(arena, new_key, ".clasp.json");
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try kept.content.readSmall(arena, moved_first));
    const between = try testutil.runCmd(arena, @import("sync.zig").command.run, ma.ws, &.{});
    try testing.expect(std.mem.indexOf(u8, between.out, " - run: holt repo promote scratch\n") != null);

    const done = try testutil.runCmd(arena, promote_command.run, ma.ws, &.{ "scratch", "--yes" });
    try testing.expectEqual(@as(u8, 0), done.code);
    const na = try fsutil.joinSlashy(arena, ma.ws.cfg.code_root, new_key);
    try testing.expect(try ma.linked(na, new_key, ".clasp.json"));
    try testing.expect(try ma.linked(na, new_key, ".superpowers"));
    try testing.expectEqualStrings("plan", try ma.read(na, ".superpowers/plan.md"));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ ma.ws.cfg.synced_root, "kept", "local", "scratch" })));

    try deliverKept(arena, &ma, &mb);
    try mb.use();
    const told = try testutil.runCmd(arena, sync_cmd.run, mb.ws, &.{});
    try testing.expectEqual(@as(u8, 1), told.code);
    const want = try std.fmt.allocPrint(arena, "not linked: {s}: this repo moved to {s} - run: git -C {s} remote add origin '{s}' && holt repo promote scratch\n", .{ try mb.shown(try std.fs.path.join(arena, &.{ cb, ".clasp.json" })), new_key, try mb.shown(cb), origin });
    try testing.expect(std.mem.indexOf(u8, told.out, want) != null);

    try testutil.runGit(&sb, cb, &.{ "remote", "add", "origin", origin });
    const later = try testutil.runCmd(arena, promote_command.run, mb.ws, &.{ "scratch", "--force" });
    try testing.expectEqual(@as(u8, 0), later.code);
    const nb = try fsutil.joinSlashy(arena, mb.ws.cfg.code_root, new_key);
    try testing.expect(try mb.linked(nb, new_key, ".clasp.json"));
    try testing.expect(try mb.linked(nb, new_key, ".superpowers"));
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try mb.read(nb, ".clasp.json"));
    const settled = try testutil.runCmd(arena, sync_cmd.run, mb.ws, &.{});
    try testing.expectEqual(@as(u8, 0), settled.code);
}

test "promote: a clone of a local repo no marker names any more, without origin, is hinted to add and fetch origin, then the chain its fetched state needs, which settles it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const saved = app.environ_override;
    defer app.environ_override = saved;
    const origin = "https://holt-test.invalid/acme/scratch";
    const new_key = "holt-test.invalid/acme/scratch";

    var ma = try kept_test.init(arena, &sb, "a");
    try ma.createStore();
    const ca = try ma.clone("local/scratch");
    try testutil.runGit(&sb, ca, &.{ "remote", "set-url", "origin", origin });
    var local_repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try local_repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ma.ws.projectsRoot(arena), "acme", "proj", local_repos, .empty);
    try ma.write(ca, ".clasp.json", "{\"scriptId\": \"abc\"}");
    try ma.keep(ca, ".clasp.json");

    var mb = try kept_test.init(arena, &sb, "b");
    mb.bare = ma.bare;
    const cb = try mb.clone("local/scratch");
    try testutil.runGit(&sb, cb, &.{ "remote", "remove", "origin" });
    try testutil.writeMarker(arena, try mb.ws.projectsRoot(arena), "acme", "proj", local_repos, .empty);
    try deliverKept(arena, &ma, &mb);
    const sync_cmd = @import("sync.zig").command;
    try testing.expectEqual(@as(u8, 0), (try testutil.runCmd(arena, sync_cmd.run, mb.ws, &.{})).code);
    try testing.expect(try mb.linked(cb, "local/scratch", ".clasp.json"));

    try ma.use();
    try testing.expectEqual(@as(u8, 0), (try testutil.runCmd(arena, promote_command.run, ma.ws, &.{ "scratch", "--yes" })).code);
    const na = try fsutil.joinSlashy(arena, ma.ws.cfg.code_root, new_key);
    try testutil.runGit(&sb, na, &.{ "commit", "-q", "--allow-empty", "-m", "after the promote" });
    try testutil.runGit(&sb, na, &.{ "push", "-q", ma.bare, "HEAD" });
    try deliverKept(arena, &ma, &mb);
    try mb.use();
    var remote_repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try remote_repos.put(arena, "scratch", origin);
    try testutil.writeMarker(arena, try mb.ws.projectsRoot(arena), "acme", "proj", remote_repos, .empty);

    try testutil.runGit(&sb, cb, &.{ "commit", "-q", "--allow-empty", "-m", "only on b" });
    const told = try testutil.runCmd(arena, sync_cmd.run, mb.ws, &.{});
    try testing.expectEqual(@as(u8, 1), told.code);
    const at = try mb.shown(cb);
    const want = try std.fmt.allocPrint(arena, " - run: git -C {s} remote add origin '{s}' && git -C {s} fetch origin && holt sync\n", .{ at, origin, at });
    try testing.expect(std.mem.indexOf(u8, told.out, want) != null);
    try testing.expect(std.mem.indexOf(u8, told.out, "holt repo promote") == null);

    try testutil.runGit(&sb, cb, &.{ "remote", "add", "origin", origin });
    try testutil.runGit(&sb, cb, &.{ "config", try std.fmt.allocPrint(arena, "url.{s}.insteadOf", .{ma.bare}), origin });
    try testutil.runGit(&sb, cb, &.{ "fetch", "-q", "origin" });
    const next = try testutil.runCmd(arena, sync_cmd.run, mb.ws, &.{});
    try testing.expectEqual(@as(u8, 1), next.code);
    const branch = (try git.currentBranch(arena, cb)).?;
    const pull = try std.fmt.allocPrint(arena, "git -C {s} pull --rebase origin {s}", .{ at, branch });
    const chain = try std.fmt.allocPrint(arena, " - run: git -C {s} fetch origin && {s} && git -C {s} push -u origin HEAD && holt repo adopt {s}\n", .{ at, pull, at, at });
    try testing.expect(std.mem.indexOf(u8, next.out, chain) != null);
    try testutil.runGit(&sb, cb, &.{ "fetch", "-q", "origin" });
    try testutil.runGit(&sb, cb, &.{ "pull", "-q", "--rebase", "origin", branch });
    try testutil.runGit(&sb, cb, &.{ "push", "-q", "-u", "origin", "HEAD" });
    const adopted = try testutil.runCmd(arena, adopt_command.run, mb.ws, &.{cb});
    try testing.expectEqual(@as(u8, 0), adopted.code);
    const nb = try fsutil.joinSlashy(arena, mb.ws.cfg.code_root, new_key);
    try testing.expect(try mb.linked(nb, new_key, ".clasp.json"));
    try testing.expectEqual(@as(u8, 0), (try testutil.runCmd(arena, sync_cmd.run, mb.ws, &.{})).code);
}

test "promote: --dry-run names the kept move and moves nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const c = try bed.clone("local/scratch");
    try testutil.runGit(&sb, c, &.{ "remote", "set-url", "origin", "https://holt-test.invalid/acme/scratch" });
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try bed.ws.projectsRoot(arena), "acme", "proj", repos, .empty);
    try bed.write(c, "notes.txt", "notes");
    try bed.keep(c, "notes.txt");
    const before = try kept_hooks.snapshot(arena, bed.ws.cfg.synced_root, null);

    const got = try testutil.runCmd(arena, promote_command.run, bed.ws, &.{ "scratch", "--dry-run" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "move kept files kept/local/scratch -> kept/holt-test.invalid/acme/scratch\n") != null);
    try testing.expectEqualStrings(before, try kept_hooks.snapshot(arena, bed.ws.cfg.synced_root, null));
}

var lock_probe: ?struct { ctx: kept.Ctx, held: usize = 0, free: usize = 0 } = null;

fn probeLocks(point: kept_interrupt.Point) void {
    if (point != .rekey_record and point != .rekey_path) return;
    const p = &(lock_probe orelse return);
    for ([_][]const u8{ "local/scratch", "holt-test.invalid/acme/scratch" }) |key| {
        if (kept.lockKey(p.ctx, key)) |h| {
            h.release();
            p.free += 1;
        } else |err| {
            if (err == error.WouldBlock) p.held += 1;
        }
    }
    lock_probe = p.*;
}

test "promote: both keys stay locked while the kept files move" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const c = try bed.clone("local/scratch");
    try testutil.runGit(&sb, c, &.{ "remote", "set-url", "origin", "https://holt-test.invalid/acme/scratch" });
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try bed.ws.projectsRoot(arena), "acme", "proj", repos, .empty);
    try bed.write(c, "notes.txt", "notes");
    try bed.keep(c, "notes.txt");

    const ctx_mod = @import("../kept/ctx.zig");
    ctx_mod.lock_nonblocking_for_test = true;
    defer ctx_mod.lock_nonblocking_for_test = false;
    lock_probe = .{ .ctx = try bed.kc() };
    defer lock_probe = null;
    kept_interrupt.hook = probeLocks;
    defer kept_interrupt.hook = null;
    const got = try testutil.runCmd(arena, promote_command.run, bed.ws, &.{ "scratch", "--yes" });
    kept_interrupt.hook = null;
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(usize, 4), lock_probe.?.held);
    try testing.expectEqual(@as(usize, 0), lock_probe.?.free);
    try testing.expect(try bed.linked(try fsutil.joinSlashy(arena, bed.ws.cfg.code_root, "holt-test.invalid/acme/scratch"), "holt-test.invalid/acme/scratch", "notes.txt"));
}

/// A kept store and a clone at `<code_root>/tmp/widget` whose origin files
/// it under `holt-test.invalid/acme/widget`, keeping `.clasp.json` and
/// `notes.txt`.
fn adoptBed(arena: std.mem.Allocator, sb: *testutil.Sandbox) !struct { bed: kept_test, src: []const u8 } {
    var bed = try kept_test.init(arena, sb, "");
    try bed.createStore();
    const src = try bed.clone("tmp/widget");
    try testutil.runGit(sb, src, &.{ "remote", "set-url", "origin", "https://holt-test.invalid/acme/widget" });
    try bed.write(src, ".clasp.json", "{\"scriptId\": \"abc\"}");
    try bed.write(src, "notes.txt", "notes");
    try bed.keep(src, ".clasp.json");
    try bed.keep(src, "notes.txt");
    return .{ .bed = bed, .src = src };
}

const adopted_key = "holt-test.invalid/acme/widget";

test "adopt: interrupted while the kept files move, the clone stays, sync names the adopt that finishes it, and rerunning adopt does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    defer kept_interrupt.at = null;
    var k = try adoptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const shown = try bed.shown(k.src);

    kept_interrupt.at = .rekey_path;
    const cut = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{k.src});
    kept_interrupt.at = null;
    try testing.expectEqual(@as(u8, 1), cut.code);
    try testing.expect(std.mem.indexOf(u8, cut.err, try std.fmt.allocPrint(arena, "the clone was not moved - run: holt repo adopt {s}\n", .{shown})) != null);
    try testing.expect(fsutil.exists(k.src));

    const between = try testutil.runCmd(arena, @import("sync.zig").command.run, bed.ws, &.{});
    try testing.expectEqual(@as(u8, 1), between.code);
    try testing.expect(std.mem.indexOf(u8, between.out, try std.fmt.allocPrint(arena, " - run: holt repo adopt {s}\n", .{shown})) != null);
    try testing.expectEqualStrings("notes", try bed.read(k.src, "notes.txt"));
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try bed.read(k.src, ".clasp.json"));

    const done = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{k.src});
    try testing.expectEqual(@as(u8, 0), done.code);
    const dest = try fsutil.joinSlashy(arena, bed.ws.cfg.code_root, adopted_key);
    try testing.expect(try bed.linked(dest, adopted_key, ".clasp.json"));
    try testing.expect(try bed.linked(dest, adopted_key, "notes.txt"));
    try testing.expectEqualStrings("notes", try bed.read(dest, "notes.txt"));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ bed.ws.cfg.synced_root, "kept", "tmp" })));
}

test "adopt: interrupted while a path the new key holds differently is set aside, nothing moves, and rerunning sets the old copy aside and names it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    defer kept_interrupt.at = null;
    var k = try adoptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const layout: kept.store.Layout = .{ .synced_root = bed.ws.cfg.synced_root };
    const index = try kept.store.loadIndex(arena, layout);
    _ = try kept.store.ensureKey(arena, layout, &index, adopted_key, null, null, &.{});
    const theirs = try layout.copyPath(arena, adopted_key, ".clasp.json");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = theirs, .data = "{\"scriptId\": \"theirs\"}" });
    try kept.store.writeFact(arena, layout, adopted_key, "000000000000000b", ".clasp.json", .file, &(try kept.content.hashFile(arena, theirs)));
    const ours = try layout.copyPath(arena, "tmp/widget", ".clasp.json");

    for ([_]kept_interrupt.Point{ .aside_copied, .rekey_aside }) |point| {
        kept_interrupt.at = point;
        const cut = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{k.src});
        kept_interrupt.at = null;
        try testing.expectEqual(@as(u8, 1), cut.code);
        try testing.expect(fsutil.exists(k.src));
        try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try kept.content.readSmall(arena, ours));
        try testing.expectEqual(@as(usize, 1), (try kept.store.loadKeyState(arena, layout, "tmp/widget")).factsFor(".clasp.json").len);
    }

    const done = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{k.src});
    try testing.expectEqual(@as(u8, 0), done.code);
    try testing.expect(std.mem.indexOf(u8, done.err, "kept/holt-test.invalid/acme/widget/.clasp.json already held different content; the copy from kept/tmp/widget is set aside - to use it instead, run: holt keep --take-aside ") != null);
    const dest = try fsutil.joinSlashy(arena, bed.ws.cfg.code_root, adopted_key);
    try testing.expectEqualStrings("{\"scriptId\": \"theirs\"}", try bed.read(dest, ".clasp.json"));
    try testing.expectEqualStrings("notes", try bed.read(dest, "notes.txt"));
}

test "adopt: a kept file that has not arrived, a link in the old key, and a new key holding stray files each stop the move with what to do" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try adoptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const layout: kept.store.Layout = .{ .synced_root = bed.ws.cfg.synced_root };
    const notes = try layout.copyPath(arena, "tmp/widget", "notes.txt");
    const clasp = try layout.copyPath(arena, "tmp/widget", ".clasp.json");
    const new_dir = try layout.keyDir(arena, adopted_key);

    try fsutil.removePath(notes);
    try fsutil.removePath(clasp);
    try kept.content.createLink(try std.fs.path.join(arena, &.{ sb.root, "elsewhere" }), clasp, .file);
    const got = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{k.src});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(fsutil.exists(k.src));
    try testing.expect(std.mem.indexOf(u8, got.err, try std.fmt.allocPrint(arena, "holt: {s} has not arrived yet (not downloaded, or deleted elsewhere) - wait for {s} to finish downloading it, or if it was deleted, run: holt unkeep {s}\n", .{ try bed.shown(notes), "your cloud client", try bed.shown(try std.fs.path.join(arena, &.{ k.src, "notes.txt" })) })) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, try std.fmt.allocPrint(arena, "holt: {s} is a link or a special file, which holt does not move - replace it with a regular file, or remove it\n", .{try bed.shown(clasp)})) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "holt: the clone was not moved - once the paths above are settled, run: holt repo adopt ") != null);

    try fsutil.removePath(clasp);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = clasp, .data = "{\"scriptId\": \"abc\"}" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = notes, .data = "notes" });
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), new_dir);
    try bed.write(new_dir, "stray.txt", "stray");
    const stray = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{k.src});
    try testing.expectEqual(@as(u8, 1), stray.code);
    try testing.expect(std.mem.indexOf(u8, stray.err, try std.fmt.allocPrint(arena, "holt: {s} already holds files but no record, so holt will not file this repo's kept files there; the clone was not moved - move those files out of it, then run: holt repo adopt {s}\n", .{ try bed.shown(new_dir), try bed.shown(k.src) })) != null);
}

test "adopt: a clone with no commit keeps its files where they are, and says to commit first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const raw = try fsutil.joinSlashy(arena, bed.ws.cfg.code_root, "tmp/scratch");
    try fsutil.ensureDir(raw);
    try testutil.runGit(&sb, raw, &.{ "init", "-q" });
    const src = try fsutil.realPathOrSelf(arena, raw);
    try bed.write(src, "notes.txt", "notes");
    try bed.keep(src, "notes.txt");

    const got = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{src});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, try std.fmt.allocPrint(arena, "holt: kept/local/scratch needs the repo's first commit, and this clone has none; the clone was not moved - commit once, then run: holt repo adopt {s}\n", .{try bed.shown(src)})) != null);
    try testing.expect(fsutil.exists(src));
    try testing.expect(try bed.linked(src, "tmp/scratch", "notes.txt"));
}

test "get: a kept store that cannot be read is reported, and the clone is still made" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var bed = try kept_test.init(arena, &sb, "");
    defer bed.deinit();
    try bed.createStore();
    const url = "https://holt-test.invalid/acme/widget";
    const override = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = url, .bare = bed.bare }});
    defer override.restore();

    // Mode bits don't gate access on Windows, so this is POSIX-only.
    if (@import("builtin").os.tag != .windows) {
        const synced = bed.ws.cfg.synced_root;
        try std.Io.Dir.cwd().setFilePermissions(testing.io, synced, std.Io.File.Permissions.fromMode(0o000), .{});
        defer std.Io.Dir.cwd().setFilePermissions(testing.io, synced, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        const got = try testutil.runCmd(arena, get_command.run, bed.ws, &.{url});
        try testing.expectEqual(@as(u8, 0), got.code);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, "\n"));
        try testing.expect(std.mem.indexOf(u8, got.err, "kept files not linked in ") != null);
    }
}

test "adopt: a kept store that cannot be read keeps the clone where it is, and says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try adoptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;

    if (@import("builtin").os.tag != .windows) {
        const synced = bed.ws.cfg.synced_root;
        try std.Io.Dir.cwd().setFilePermissions(testing.io, synced, std.Io.File.Permissions.fromMode(0o000), .{});
        defer std.Io.Dir.cwd().setFilePermissions(testing.io, synced, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        const got = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{k.src});
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, try std.fmt.allocPrint(arena, "; the clone was not moved - make it readable, then run: holt repo adopt {s}\n", .{try bed.shown(k.src)})) != null);
        try testing.expect(fsutil.exists(k.src));
    }
}

test "adopt: a clone already at its identity path gets what an earlier identity of its key still holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var k = try adoptBed(arena, &sb);
    defer k.bed.deinit();
    const bed = &k.bed;
    const first = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{k.src});
    try testing.expectEqual(@as(u8, 0), first.code);
    const dest = try fsutil.joinSlashy(arena, bed.ws.cfg.code_root, adopted_key);
    const layout: kept.store.Layout = .{ .synced_root = bed.ws.cfg.synced_root };
    const late = try layout.copyPath(arena, "tmp/widget", "late.txt");
    try bed.write(try layout.keyDir(arena, "tmp/widget"), "late.txt", "arrived late");
    try kept.store.writeFact(arena, layout, "tmp/widget", "000000000000000b", "late.txt", .file, &(try kept.content.hashFile(arena, late)));

    const again = try testutil.runCmd(arena, adopt_command.run, bed.ws, &.{dest});
    try testing.expectEqual(@as(u8, 0), again.code);
    try testing.expect(std.mem.indexOf(u8, again.err, "moved 1 kept path from kept/tmp/widget to kept/holt-test.invalid/acme/widget\n") != null);
    try testing.expect(try bed.linked(dest, adopted_key, "late.txt"));
    try testing.expectEqualStrings("arrived late", try bed.read(dest, "late.txt"));
    try testing.expect(!fsutil.exists(try std.fs.path.join(arena, &.{ bed.ws.cfg.synced_root, "kept", "tmp" })));
}

test "remove: --clone refuses a clone whose uncommitted change only a paused rebase --autostash holds, naming the rebase with the commands that finish or abort it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(&sb, bare, clone_path, "https://holt-test.invalid/acme/widget");
    const reach = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = "https://holt-test.invalid/acme/widget", .bare = bare }});
    defer reach.restore();
    {
        var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), clone_path, .{});
        defer dir.close(fsutil.io());
        try dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "unsaved work\n" });
    }
    try testutil.runGit(&sb, clone_path, &.{ "-c", "sequence.editor=sed -i.orig s/^pick/edit/", "rebase", "-i", "--autostash", "--root" });
    const cq = try ui.quotePath(arena, app.envOf_current(), try fsutil.realPathOrSelf(arena, clone_path));
    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "holt-test.invalid/acme/widget", "--clone", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(fsutil.exists(clone_path));
    try testing.expect(std.mem.indexOf(u8, got.err, try std.fmt.allocPrint(arena, "; finish it or abort it (run: git -C {s} rebase --continue, or git -C {s} rebase --abort)\n", .{ cq, cq })) != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "  rebase in progress in ") != null);
}

test "remove --clone: a linked worktree's line naming how to delete anyway names the command removing that worktree with --force, and one holt leaves to the user is named with what is seen there and git worktree list alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(a, sb.root);
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(a, "widget", "https://holt-test.invalid/acme/widget");
    try testutil.writeMarker(a, try ws.projectsRoot(a), "acme", "proj", repos, .empty);
    var out: std.Io.Writer.Allocating = .init(a);
    var err_w: std.Io.Writer.Allocating = .init(a);
    var ctx: app.Ctx = .{ .alloc = a, .io = testing.io, .context = .{ .ws = ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer, .argv = &.{} };
    const member = (try common.resolveOne(&ctx, "acme/proj")).?;
    const clone = try fsutil.joinSlashy(a, ws.cfg.code_root, "holt-test.invalid/acme/widget");
    const linked = try std.fs.path.join(a, &.{ sb.root, "linked" });
    const made = try std.fmt.allocPrint(a, "{s}@worktrees/feature", .{clone});
    const env = app.envOf_current();
    const cq = try ui.quotePath(a, env, clone);
    const lq = try ui.quotePath(a, env, linked);
    const risk: deleter.RiskAt = .{ .repo = clone, .risk = .{ .what = .unasked, .refs = &.{"refs/heads/x"}, .remote = "origin", .url = "https://holt-test.invalid/acme/widget", .why = "timed out" } };
    const Case = struct { tree: deleter.LinkedTree, holt: bool = false, force: []const u8 };
    const record = try fsutil.joinSlashy(a, clone, ".git/worktrees/linked");
    const cases = [_]Case{
        .{ .tree = .{ .path = linked, .record = record }, .force = try std.fmt.allocPrint(a, "git -C {s} worktree remove --force {s}", .{ cq, lq }) },
        .{ .tree = .{ .path = linked, .record = record, .locked = true }, .force = try std.fmt.allocPrint(a, "git -C {s} worktree unlock {s} && git -C {s} worktree remove --force {s}", .{ cq, lq, cq, lq }) },
        .{ .tree = .{ .path = linked, .record = record, .link = .absent }, .force = try std.fmt.allocPrint(a, "git -C {s} worktree remove {s}", .{ cq, lq }) },
        .{ .tree = .{ .path = made, .record = record }, .holt = true, .force = "holt worktree acme/proj/widget feature -r --force" },
    };
    for (cases) |c| {
        err_w.clearRetainingCapacity();
        var tree = c.tree;
        tree.risks = &.{risk};
        try printLinked(&ctx, clone, if (c.holt) member else null, "widget", tree, &.{tree});
        const want = try std.fmt.allocPrint(a, "; reconnect and run again, or {s} deletes it\n", .{c.force});
        if (std.mem.indexOf(u8, err_w.written(), want) == null) {
            std.debug.print("wanted {s} in:\n{s}\n", .{ want, err_w.written() });
            return error.TestUnexpectedResult;
        }
    }
    err_w.clearRetainingCapacity();
    const seen = "a linked working tree whose .git is gone";
    const left: deleter.LinkedTree = .{ .path = linked, .record = record, .link = .unresolved, .seen = seen, .risks = &.{risk} };
    try printLinked(&ctx, clone, null, "widget", left, &.{ left, .{ .path = linked, .record = "other", .link = .unresolved, .seen = seen } });
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "  {s}: {s}; holt does not change it: resolve it with git (git -C {s} worktree list), then run again\n", .{ lq, seen, cq }), err_w.written());
}

test "promote: a worktree outside the worktrees dir made with relative paths is relinked and its record pointed at it, while one made so in the worktrees dir moves along untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos, .empty);
    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);
    const outside = try std.fs.path.join(arena, &.{ sb.root, "outside" });
    try testutil.runGit(&sb, local_clone_path, &.{ "-c", "worktree.useRelativePaths=true", "worktree", "add", "-q", "-b", "outside", outside });
    const wt_old = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{local_clone_path}), "feature" });
    try testutil.runGit(&sb, local_clone_path, &.{ "branch", "feature" });
    try git.worktreeAdd(arena, local_clone_path, wt_old, "feature", null);
    const inside_link = try kept.content.readSmall(arena, try std.fs.path.join(arena, &.{ wt_old, ".git" }));

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    if (got.code != 0) std.debug.print("{s}", .{got.err});
    try testing.expectEqual(@as(u8, 0), got.code);
    const new_clone_path = try (try identity.fromUrl(arena, fake_origin)).clonePath(arena, ws.cfg.code_root);
    const wt_new = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{new_clone_path}), "feature" });
    for ([_][]const u8{ outside, wt_new }) |tree| {
        const st = try git.runInRepo(arena, &.{ "status", "--porcelain" }, tree);
        if (st.status != 0) std.debug.print("{s}: {s}\n", .{ tree, st.stderr });
        try testing.expectEqual(@as(u32, 0), st.status);
    }
    if (!std.fs.path.isAbsolute(std.mem.trimEnd(u8, inside_link, "\r\n")["gitdir: ".len..]))
        try testing.expectEqualStrings(inside_link, try kept.content.readSmall(arena, try std.fs.path.join(arena, &.{ wt_new, ".git" })));
    const listed = try git.runInRepo(arena, &.{ "worktree", "list", "--porcelain" }, new_clone_path);
    if (std.mem.indexOf(u8, listed.stdout, "prunable") != null) std.debug.print("{s}", .{listed.stdout});
    try testing.expect(std.mem.indexOf(u8, listed.stdout, "prunable") == null);
}

test "promote: a worktree of a clone with a separate git dir has its record pointed at where it moved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos, .empty);
    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    const sep_dir = try std.fs.path.join(arena, &.{ sb.root, "gitdirs", "scratch.git" });
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ sb.root, "gitdirs" }));
    try testutil.runGit(&sb, null, &.{ "clone", "-q", "--separate-git-dir", sep_dir, bare, local_clone_path });
    try testutil.runGit(&sb, local_clone_path, &.{ "remote", "set-url", "origin", fake_origin });
    const wt_old = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{local_clone_path}), "feature" });
    try testutil.runGit(&sb, local_clone_path, &.{ "worktree", "add", "-q", "-b", "feature", wt_old });

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    if (got.code != 0) std.debug.print("{s}", .{got.err});
    try testing.expectEqual(@as(u8, 0), got.code);
    const new_clone_path = try (try identity.fromUrl(arena, fake_origin)).clonePath(arena, ws.cfg.code_root);
    const wt_new = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{new_clone_path}), "feature" });
    try testing.expectEqualStrings("feature", (try git.currentBranch(arena, wt_new)).?);
    const listed = try git.runInRepo(arena, &.{ "worktree", "list", "--porcelain" }, new_clone_path);
    if (std.mem.indexOf(u8, listed.stdout, "prunable") != null) std.debug.print("{s}", .{listed.stdout});
    try testing.expect(std.mem.indexOf(u8, listed.stdout, "prunable") == null);
}

test "promote: when the worktrees dir cannot be moved, a worktree holt made with relative paths is relinked where it is and stays unprunable" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const bare = try testutil.makeBareRepo(&sb, "origin.git");
    defer testing.allocator.free(bare);
    const ws = try testutil.testWorkspace(arena, sb.root);
    const fake_origin = "https://holt-test.invalid/acme/scratch";
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "scratch", "local:scratch");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos, .empty);
    const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
    try cloneWithOrigin(&sb, bare, local_clone_path, fake_origin);
    const wt_old = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{local_clone_path}), "feature" });
    try testutil.runGit(&sb, local_clone_path, &.{ "branch", "feature" });
    try git.worktreeAdd(arena, local_clone_path, wt_old, "feature", null);
    const new_clone_path = try (try identity.fromUrl(arena, fake_origin)).clonePath(arena, ws.cfg.code_root);
    const new_wt_dir = try std.fmt.allocPrint(arena, "{s}@worktrees", .{new_clone_path});
    try fsutil.ensureDir(new_wt_dir);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ new_wt_dir, "blocker" }), .data = "x" });

    const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
    if (got.code != 0) std.debug.print("{s}", .{got.err});
    try testing.expectEqual(@as(u8, 0), got.code);
    const st = try git.runInRepo(arena, &.{ "status", "--porcelain" }, wt_old);
    if (st.status != 0) std.debug.print("{s}\n", .{st.stderr});
    try testing.expectEqual(@as(u32, 0), st.status);
    const listed = try git.runInRepo(arena, &.{ "worktree", "list", "--porcelain" }, new_clone_path);
    if (std.mem.indexOf(u8, listed.stdout, "prunable") != null) std.debug.print("{s}", .{listed.stdout});
    try testing.expect(std.mem.indexOf(u8, listed.stdout, "prunable") == null);
}

test "promote: a worktree holt made with relative paths in a clone with a separate git dir works where it moved, the code root reached through a symlink to another depth or not" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    for ([_]bool{ false, true }) |linked_root| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const bare = try testutil.makeBareRepo(&sb, "origin.git");
        defer testing.allocator.free(bare);
        const ws = try testutil.testWorkspace(arena, sb.root);
        if (linked_root) {
            const deep = try std.fs.path.join(arena, &.{ sb.root, "deep", "er", "code" });
            try fsutil.ensureDir(deep);
            try std.Io.Dir.cwd().symLink(fsutil.io(), deep, ws.cfg.code_root, .{ .is_directory = true });
        }
        const fake_origin = "https://holt-test.invalid/acme/scratch";
        var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        try repos.put(arena, "scratch", "local:scratch");
        try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "first", repos, .empty);
        const local_clone_path = try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
        const sep_dir = try std.fs.path.join(arena, &.{ sb.root, "gitdirs", "scratch.git" });
        try fsutil.ensureDir(try std.fs.path.join(arena, &.{ sb.root, "gitdirs" }));
        try testutil.runGit(&sb, null, &.{ "clone", "-q", "--separate-git-dir", sep_dir, bare, local_clone_path });
        try testutil.runGit(&sb, local_clone_path, &.{ "remote", "set-url", "origin", fake_origin });
        const wt_old = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{local_clone_path}), "feature" });
        try testutil.runGit(&sb, local_clone_path, &.{ "branch", "feature" });
        try git.worktreeAdd(arena, local_clone_path, wt_old, "feature", null);

        const got = try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes" });
        if (got.code != 0) std.debug.print("{s}{s}\n", .{ got.out, got.err });
        try testing.expectEqual(@as(u8, 0), got.code);
        const new_clone_path = try (try identity.fromUrl(arena, fake_origin)).clonePath(arena, ws.cfg.code_root);
        const wt_new = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{new_clone_path}), "feature" });
        const st = try git.runInRepo(arena, &.{ "status", "--porcelain" }, wt_new);
        if (st.status != 0) std.debug.print("linked root {}: {s}\n", .{ linked_root, st.stderr });
        try testing.expectEqual(@as(u32, 0), st.status);
        const listed = try git.runInRepo(arena, &.{ "worktree", "list", "--porcelain" }, new_clone_path);
        if (std.mem.indexOf(u8, listed.stdout, "prunable") != null) std.debug.print("linked root {}: {s}", .{ linked_root, listed.stdout });
        try testing.expect(std.mem.indexOf(u8, listed.stdout, "prunable") == null);
    }
}

fn unlistedRecordSetup(arena: std.mem.Allocator, sb: *testutil.Sandbox, ws: anytype, gitdir_dir: bool) !struct { clone: []const u8, record: []const u8 } {
    const bare_raw = try testutil.makeBareRepo(sb, "origin.git");
    const bare = try arena.dupe(u8, bare_raw);
    testing.allocator.free(bare_raw);
    const work = try std.fs.path.join(arena, &.{ sb.root, "work-other" });
    try testutil.runGit(sb, null, &.{ "clone", bare, work });
    try testutil.runGit(sb, work, &.{ "checkout", "-b", "other" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ work, "other.txt" }), .data = "other\n" });
    try testutil.runGit(sb, work, &.{ "add", "other.txt" });
    try testutil.runGit(sb, work, &.{ "commit", "-m", "other" });
    try testutil.runGit(sb, work, &.{ "push", "origin", "other" });
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try cloneWithOrigin(sb, bare, clone_path, "https://holt-test.invalid/acme/widget");
    const wt = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "wt" });
    try fsutil.ensureDir(std.fs.path.dirname(wt).?);
    try testutil.runGit(sb, clone_path, &.{ "worktree", "add", "--detach", wt, "origin/main" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ wt, "README" }), .data = "USER WORK ONLY HERE\n" });
    try testutil.runGit(sb, wt, &.{ "merge", "--autostash", "--no-ff", "--no-commit", "origin/other" });
    const record = try std.fs.path.join(arena, &.{ clone_path, ".git", "worktrees", "wt" });
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ record, "MERGE_AUTOSTASH" })));
    const gitdir = try std.fs.path.join(arena, &.{ record, "gitdir" });
    try fsutil.removePath(gitdir);
    if (gitdir_dir) try std.Io.Dir.cwd().createDirPath(fsutil.io(), gitdir);
    return .{ .clone = clone_path, .record = record };
}

test "remove --clone: a worktree record git does not list, holding no gitdir or an unreadable one, is refused with what is seen there and the record's path, which is there, with or without --force, and left with the clone as it was" {
    for ([_]bool{ true, false }) |gitdir_dir| for ([_]bool{ false, true }) |force| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const state = try testutil.stateScope(arena, sb.root);
        defer state.restore();
        const ws = try testutil.testWorkspace(arena, sb.root);
        const set = try unlistedRecordSetup(arena, &sb, ws, gitdir_dir);
        const reach = try testutil.gitInsteadOf(arena, try std.fs.path.join(arena, &.{ sb.root, "insteadof.gitconfig" }), &.{.{ .url = "https://holt-test.invalid/acme/widget", .bare = try std.fs.path.join(arena, &.{ sb.root, "origin.git" }) }});
        defer reach.restore();
        const listed = try git.runInRepo(arena, &.{ "worktree", "list", "--porcelain" }, set.clone);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, listed.stdout, "worktree "));
        const argv: []const []const u8 = if (force) &.{ "holt-test.invalid/acme/widget", "--clone", "--yes", "--force" } else &.{ "holt-test.invalid/acme/widget", "--clone", "--yes" };
        const got = try testutil.runCmd(arena, remove_command.run, ws, argv);
        try testing.expectEqual(@as(u8, 1), got.code);
        const seen = if (gitdir_dir) deleter.record_unreadable_seen else deleter.half_made_seen;
        const rq = try fsutil.contractTilde(arena, app.envOf_current(), set.record);
        const want = try std.fmt.allocPrint(arena, "{s}: {s}; holt does not change it: resolve it with git (the record is {s}), then run again", .{ rq, seen, rq });
        if (std.mem.indexOf(u8, got.err, want) == null) {
            std.debug.print("want: {s}\ngot: {s}\n", .{ want, got.err });
            return error.TestExpectedEqual;
        }
        try testing.expect(fsutil.exists(set.clone));
        try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ set.record, "MERGE_AUTOSTASH" })));
        try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ set.record, "HEAD" })));
        const ls = try @import("../proc.zig").runEnv(arena, &.{ "sh", "-c", try std.fmt.allocPrint(arena, "ls -d {s}", .{try ui.quotePath(arena, app.envOf_current(), set.record)}) }, null, &sb.git_env.map);
        try testing.expectEqual(@as(u8, 0), ls.status);
    };
}

test "adopt and promote: a linked worktree of another repository is refused, naming its main clone to adopt instead, and that repository's records are left as they were; the named adopt runs" {
    for ([_]bool{ false, true }) |promote| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        const bare = try testutil.makeBareRepo(&sb, "origin.git");
        defer testing.allocator.free(bare);
        const ws = try testutil.testWorkspace(arena, sb.root);
        const main_clone = try std.fs.path.join(arena, &.{ sb.root, "checkout", "widget" });
        try cloneWithOrigin(&sb, bare, main_clone, "https://holt-test.invalid/acme/widget");
        const wt = if (promote) blk: {
            var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            try repos.put(arena, "scratch", "local:scratch");
            try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);
            break :blk try identity.local(fsutil.SafeSegment.parse("scratch").?).clonePath(arena, ws.cfg.code_root);
        } else try std.fs.path.join(arena, &.{ sb.root, "elsewhere", "wt" });
        try fsutil.ensureDir(std.fs.path.dirname(wt).?);
        try testutil.runGit(&sb, main_clone, &.{ "worktree", "add", "-q", "--detach", wt });
        const gitdir = try std.fs.path.join(arena, &.{ main_clone, ".git", "worktrees", std.fs.path.basename(wt), "gitdir" });
        const before = try kept.content.readSmall(arena, gitdir);

        const got = if (promote)
            try testutil.runCmd(arena, promote_command.run, ws, &.{ "scratch", "--yes", "--force" })
        else
            try testutil.runCmd(arena, adopt_command.run, ws, &.{ wt, "--force" });
        try testing.expectEqual(@as(u8, 1), got.code);
        const want = try std.fmt.allocPrint(arena, "holt: {s} is a linked worktree of the repository at {s}; adopt that clone instead (run: holt repo adopt {s})\n", .{ try fsutil.contractTilde(arena, app.envOf_current(), wt), try fsutil.contractTilde(arena, app.envOf_current(), main_clone), try fsutil.contractTilde(arena, app.envOf_current(), main_clone) });
        if (!std.mem.eql(u8, want, got.err)) {
            std.debug.print("want: {s}got: {s}\n", .{ want, got.err });
            return error.TestExpectedEqual;
        }
        try testing.expect(fsutil.exists(wt));
        try testing.expectEqualStrings(before, try kept.content.readSmall(arena, gitdir));
        try testing.expect(try deleter.findsRecord(arena, wt, std.fs.path.dirname(gitdir).?));

        const hinted = try testutil.runCmd(arena, adopt_command.run, ws, &.{main_clone});
        try testing.expectEqual(@as(u8, 0), hinted.code);
    }
}
