//! `holt project`: groups project lifecycle commands under the noun they
//! act on. `new <org>/<name>` creates a project's content dirs (docs/,
//! assets/, links/), its marker, and its hub - nothing else. A new project
//! has no repo members; populating it is a separate operation (`holt repo
//! get`). `remove <project>` permanently deletes the project's content dir
//! and hub; clones under Code/ are always kept. `rename <old> <new>` moves a
//! project's content dir to a new org/name, rewrites its marker, and rebuilds
//! its hub at the new location; the clone under Code/ never moves. `archive
//! <project>` moves a project's content dir out of projects/ into archive/
//! and drops its hub; its clones stay unless --prune, which additionally
//! deletes each member clone that is safe to re-fetch. `unarchive <project>`
//! reverses the move: the content dir goes back into projects/ and the hub is
//! rebuilt (a pruned clone comes back with `holt restore`).

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("../app.zig");
const marker = @import("../marker.zig");
const fsutil = @import("../fsutil.zig");
const project_mod = @import("../project.zig");
const common = @import("common.zig");
const hub = @import("../hub.zig");
const ui = @import("../ui.zig");
const projectlock = @import("../projectlock.zig");
const identity = @import("../identity.zig");
const deleter = @import("deleter.zig");
const keep_cmd = @import("keep.zig");
const workspace = @import("../workspace.zig");
const git = @import("../git.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    org_name: cli.Pos([]const u8, .{ .complete = app.cat(.org), .help = "the org/name to create" }),
};

pub const new_command = app.command(Spec, .{
    .name = "new",
    .summary = "Create a new project",
    .usage = "holt project new <org>/<name>",
    .group = .create,
    .needs_context = true,
    .details =
    \\Creates the project's content dirs, marker, and hub. The hub path is the
    \\sole line on stdout, so `cd $(holt project new acme/widget)` drops you
    \\into it. A new project has no repos; add one with `holt repo get`.
    \\
    \\Example:
    \\  holt project new acme/widget
    ,
}, runNew);

pub const command: app.Command = .{
    .name = "project",
    .summary = "Create, remove, rename, archive, and unarchive projects",
    .usage = "holt project <new|remove|rename|archive|unarchive> ...",
    .group = .create,
    .subcommands = &.{ new_command, remove_command, rename_command, archive_command, unarchive_command },
    .needs_context = true,
    .run = runFallback,
};

fn runFallback(ctx: *app.Ctx) anyerror!u8 {
    return app.usageError(ctx, "usage: holt project <new|remove|rename|archive|unarchive> ...", .{});
}

fn runNew(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const spec = a.org_name;

    const on = common.parseOrgName(spec) orelse {
        return app.usageError(ctx, "{s}", .{try common.parseOrgNameMessage(ctx.alloc, spec)});
    };

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const content_path = try std.fs.path.join(alloc, &.{ ws.cfg.synced_root, "projects", on.org, on.name });
    const marker_path = try std.fs.path.join(alloc, &.{ content_path, marker.marker_basename });
    if (fsutil.exists(marker_path)) {
        try ctx.err.print("holt: project \"{s}/{s}\" already exists\n", .{ on.org, on.name });
        return 1;
    }

    const archive_root = try ws.archiveRoot(alloc);
    const archive_marker = try std.fs.path.join(alloc, &.{ archive_root, on.org, on.name, marker.marker_basename });
    if (fsutil.exists(archive_marker)) {
        try ctx.err.print("holt: {s}/{s} already exists in archive (bring it back with `holt project unarchive {s}/{s}`)\n", .{ on.org, on.name, on.org, on.name });
        return 1;
    }

    var lock = try projectlock.acquire(alloc, app.envOf(ctx), content_path);
    defer lock.release();

    for (project_mod.content_dirs) |sub| {
        try fsutil.ensureDir(try std.fs.path.join(alloc, &.{ content_path, sub }));
    }

    var m: marker.Marker = .init(on.org, on.name);
    try marker.save(&m, marker_path);

    const hub_path = try std.fs.path.join(alloc, &.{ ws.cfg.hub_root, on.org, on.name });
    const p: project_mod.Project = .{
        .org = on.org,
        .name = on.name,
        .content_path = content_path,
        .hub_path = hub_path,
        .marker = m,
    };
    _ = try hub.reconcile(alloc, &ws, &p, false);

    // stdout is the hub path alone (cd-friendly); human status goes to stderr,
    // where its tilde-abbreviated paths cannot leak into a substitution.
    try ctx.out.print("{s}\n", .{hub_path});
    try ctx.err.print("created {s}/{s}\n", .{ on.org, on.name });
    try ctx.err.print("no repos yet - add one with `holt repo get <url> -p {s}/{s}`\n", .{ on.org, on.name });
    return 0;
}

const RemoveSpec = struct {
    project: cli.Pos([]const u8, .{ .complete = app.cat(.project), .help = "the project to remove" }),
    yes: cli.Flag(.{ .short = 'y', .help = "skip the confirmation prompt" }),
};

pub const remove_command = app.command(RemoveSpec, .{
    .name = "remove",
    .summary = "Remove a project's content and hub (clones are kept)",
    .usage = "holt project remove <project> [--yes]",
    .group = .create,
    .needs_context = true,
    .details =
    \\Danger: permanently deletes the project's content dir and hub. Clones
    \\under Code/ are always kept; a clone left referenced by no project is
    \\reported so it can be removed with `holt repo remove <repo> --clone`.
    \\Requires typed confirmation unless --yes.
    \\
    \\Example:
    \\  holt project remove acme/widget --yes
    ,
}, runRemove);

fn runRemove(ctx: *app.Ctx, a: cli.Args(RemoveSpec)) anyerror!u8 {
    const project_query = a.project;
    const yes = a.yes;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const p = (try common.resolveOne(ctx, project_query)) orelse return 1;
    const qualified = try p.qualified(alloc);

    if (!yes) {
        const prompt = try std.fmt.allocPrint(alloc, "delete {s} (content + hub; clones are kept). Type {s} to confirm:", .{ qualified, qualified });
        if (!try ui.confirmTyped(ctx.out, prompt, qualified)) {
            try ctx.out.print("aborted: {s} not deleted\n", .{qualified});
            return 0;
        }
    }

    // Take the lock only now (not across the confirmation prompt), then
    // serialize the destructive removal against concurrent per-project edits.
    var lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
    defer lock.release();

    // Remove the hub first, then the content with the marker deleted LAST: a
    // content-delete failure then leaves the marker in place, so the project
    // stays listable and this command stays re-runnable rather than stranding
    // an invisible half-deleted project.
    try hub.removeHub(&p);

    var failed_path: []const u8 = p.content_path;
    removeContentMarkerLast(alloc, p.content_path, &failed_path) catch |err| {
        try ctx.err.print("holt: failed to delete {s}: {s} (run \"holt project remove {s}\" again)\n", .{ try app.tilde(ctx, failed_path), @errorName(err), qualified });
        return 1;
    };

    if (std.fs.path.dirname(p.content_path)) |old_org_dir| fsutil.rmdirIfEmpty(old_org_dir);
    try ctx.out.print("deleted {s}\n", .{qualified});

    for (p.marker.entries) |*e| {
        const src = e.source orelse continue;
        const id = switch (src) {
            .remote => |r| r.id,
            .local => |seg| identity.local(seg),
        };
        const others = try ws.projectsUsing(alloc, id);
        if (others.len == 0) {
            const clone_path = try id.clonePath(alloc, ws.cfg.code_root);
            // The project (and its -p handle on this member) is already gone,
            // so the hint must name the clone by its code-tree key, not the
            // member's short name, for `holt repo remove <key> --clone` to
            // resolve it.
            const key = try id.relPath(alloc);
            try ctx.out.print("clone at {s} is now unreferenced; remove it with `holt repo remove {s} --clone`\n", .{ try app.tilde(ctx, clone_path), key });
        }
    }

    return 0;
}

/// Deletes everything under `content_path`, removing the marker file LAST so a
/// partial failure leaves the marker present (project still listable, remove
/// still re-runnable). `failed` names the entry that could not be removed when
/// an error is returned.
fn removeContentMarkerLast(alloc: std.mem.Allocator, content_path: []const u8, failed: *[]const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const dio = fsutil.io();
    failed.* = content_path;

    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = cwd.openDir(dio, content_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer dir.close(dio);
        var it = dir.iterate();
        while (try it.next(dio)) |entry| {
            if (std.mem.eql(u8, entry.name, marker.marker_basename)) continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
    }

    for (names.items) |name| {
        const entry_path = try std.fs.path.join(alloc, &.{ content_path, name });
        cwd.deleteTree(dio, entry_path) catch |err| {
            failed.* = entry_path;
            return err;
        };
    }

    const marker_path = try std.fs.path.join(alloc, &.{ content_path, marker.marker_basename });
    cwd.deleteFile(dio, marker_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            failed.* = marker_path;
            return err;
        },
    };

    fsutil.rmdirIfEmpty(content_path);
}

const RenameSpec = struct {
    old: cli.Pos([]const u8, .{ .complete = app.cat(.project), .help = "the project to rename" }),
    new_name: cli.Pos([]const u8, .{ .help = "the new <org>/<name>" }),
};

pub const rename_command = app.command(RenameSpec, .{
    .name = "rename",
    .summary = "Rename a project, moving its content and rebuilding its hub",
    .usage = "holt project rename <old> <new-org>/<new-name>",
    .group = .create,
    .needs_context = true,
    .details =
    \\Example:
    \\  holt project rename acme/widget corp/gadget
    ,
}, runRename);

fn runRename(ctx: *app.Ctx, a: cli.Args(RenameSpec)) anyerror!u8 {
    const old_query = a.old;
    const new_spec = a.new_name;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const p = (try common.resolveOne(ctx, old_query)) orelse return 1;

    // Serialize the content move against concurrent per-project mutators.
    var lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
    defer lock.release();

    const target = common.parseOrgName(new_spec) orelse {
        return app.usageError(ctx, "{s}", .{try common.parseOrgNameMessage(alloc, new_spec)});
    };

    const projects_root = try ws.projectsRoot(alloc);
    const dest_path = try std.fs.path.join(alloc, &.{ projects_root, target.org, target.name });

    if (std.mem.eql(u8, p.content_path, dest_path)) {
        try ctx.err.writeAll("holt: source and target are the same project\n");
        return 1;
    }
    if (fsutil.exists(dest_path)) {
        try ctx.err.print("holt: {s}/{s} already exists in projects\n", .{ target.org, target.name });
        return 1;
    }

    const old_org_dir = std.fs.path.dirname(p.content_path).?;

    common.moveProject(ctx, &ws, &p, target.org, target.name) catch return 1;
    fsutil.rmdirIfEmpty(old_org_dir);

    try ctx.out.print("renamed {s}/{s} -> {s}/{s}\n", .{ p.org, p.name, target.org, target.name });
    return 0;
}

const ArchiveSpec = struct {
    project: cli.Pos([]const u8, .{ .complete = app.cat(.project), .help = "the project to archive" }),
    prune: cli.Flag(.{ .help = "also reclaim member clones that are safe to re-fetch" }),
    yes: cli.Flag(.{ .short = 'y', .help = "skip the prune confirmation prompt" }),
};

pub const archive_command = app.command(ArchiveSpec, .{
    .name = "archive",
    .summary = "Move a project's content into archive/ and drop its hub",
    .usage = "holt project archive <project> [--prune] [--yes]",
    .group = .create,
    .needs_context = true,
    .details =
    \\With --prune, after archiving, each member clone no longer used by any
    \\active project is deleted to reclaim disk (it can be re-cloned from its
    \\remote by `holt restore`) when it passes the gates holt repo remove
    \\--clone weighs. A clone with a linked worktree, uncommitted changes,
    \\stash entries, commits or other git state no remote holds, an operation
    \\in progress (a merge, rebase, am, cherry-pick, revert, or bisect), files
    \\holt does not keep, nested repositories, or unsettled kept files is kept
    \\and reported as `not pruned <repo>: <reason>`, each reason on a line of
    \\its own when there are several, then `once settled, delete it with: holt
    \\repo remove <key> --clone`; a branch with no upstream whose commits a
    \\remote holds is no reason, and a clone git cannot read is named as
    \\such. A remote holds only what its URLs on another machine list now, as
    \\holt repo remove --help says; each clone is weighed once before the
    \\prompt, and once after it only when the prompt waited at a terminal
    \\(not with --yes). A host that gave no answer, or whose host key was not
    \\verified, is named once, after the last clone, with the clones it kept
    \\from being asked. Since the project is archived, a remote that could
    \\not be asked is settled by reconnecting, or verifying the host key,
    \\then deleting each clone with holt repo remove <key> --clone, never by
    \\running the archive again. A reason that names deleting anyway names
    \\holt repo remove <key> --clone --force. A clone still shared with an
    \\active project is never touched.
    \\On a terminal, without --yes, a clone those checks would keep is first
    \\offered holt keep --review inline, then weighed again.
    \\
    \\Example:
    \\  holt project archive acme/widget --prune --yes
    ,
}, runArchive);

fn runArchive(ctx: *app.Ctx, a: cli.Args(ArchiveSpec)) anyerror!u8 {
    const project_query = a.project;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const p = (try common.resolveOne(ctx, project_query)) orelse return 1;

    // Serialize against concurrent per-project mutators (add/rm/...) so the
    // content move never races an in-flight marker edit on the same project.
    var lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
    defer lock.release();

    // Snapshot the non-local member clones before the marker moves, so a
    // later --prune knows what this project referenced.
    var members: std.ArrayList(Member) = .empty;
    if (a.prune) {
        for (p.marker.entries) |*e| {
            const src = e.source orelse continue;
            const rem = switch (src) {
                .remote => |r| r,
                .local => continue,
            };
            try members.append(alloc, .{ .repo = e.name, .id = rem.id, .clone_path = try rem.id.clonePath(alloc, ws.cfg.code_root) });
        }
    }

    const archive_root = try ws.archiveRoot(alloc);
    const dest = try std.fs.path.join(alloc, &.{ archive_root, p.org, p.name });
    if (fsutil.exists(dest)) {
        try ctx.err.print("holt: {s}/{s} already exists in archive\n", .{ p.org, p.name });
        return 1;
    }

    common.moveDir(ctx, p.content_path, dest) catch return 1;
    hub.removeHub(&p) catch |err| {
        try common.reportHubFailure(ctx, p.org, p.name, err);
        return 1;
    };

    if (std.fs.path.dirname(p.content_path)) |old_org_dir| fsutil.rmdirIfEmpty(old_org_dir);

    try ctx.out.print("archived {s}/{s}\n", .{ p.org, p.name });

    if (a.prune) try pruneClones(ctx, &ws, members.items, a.yes);
    return 0;
}

const Member = struct { repo: []const u8, id: identity.Identity, clone_path: []const u8 };

/// After the project is archived, deletes each member clone that is safe to
/// reclaim - present on disk, referenced by no remaining active project,
/// with no linked worktree, and holding nothing the gates weigh
/// (`deleter`): no file holt does not keep, no uncommitted change, and no
/// commit or other object no remote holds.
/// Everything else is kept and reported as `not pruned <repo>: <reason>`,
/// or with every reason on a line of its own (`printNotPruned`).
/// Never fails the command: the archive already succeeded.
fn pruneClones(ctx: *app.Ctx, ws: *const workspace.Workspace, members: []const Member, yes: bool) !void {
    const alloc = ctx.alloc;

    const Eligible = struct { m: Member, answers: ?*deleter.Answers };
    var eligible: std.ArrayList(Eligible) = .empty;
    var held: HeldBack = .{};
    for (members) |m| {
        if (!fsutil.exists(m.clone_path)) continue;
        if ((try ws.projectsUsing(alloc, m.id)).len > 0) {
            try ctx.out.print("not pruned {s}: still used by an active project\n", .{m.repo});
            continue;
        }
        // Deleting the clone leaves a linked worktree without its repository,
        // as repo remove --clone refuses. If we can't tell (>1 defaults on
        // error), keep it. worktreeCount includes the main tree, so >1 means
        // extra worktrees exist. As for repo remove --clone, only a repo git
        // can read is asked: the deleter weighs one it cannot read.
        if (try git.inspectable(alloc, m.clone_path) and (git.worktreeCount(alloc, m.clone_path) catch 2) > 1) {
            try ctx.out.print("not pruned {s}: has worktrees\n", .{m.repo});
            continue;
        }
        var prepared = (try prepareClone(ctx, m, .{ .review = keep_cmd.reviewHeld, .interactive = !yes and ui.stdinIsTerminal(), .many = true }, &held)) orelse continue;
        prepared.release();
        try eligible.append(alloc, .{ .m = m, .answers = prepared.answers });
    }

    defer held.print(ctx) catch {};
    if (eligible.items.len == 0) return;

    if (!yes) {
        const msg = try std.fmt.allocPrint(alloc, "reclaim {d} clone(s) (delete the local checkout; re-clonable from its remote)?", .{eligible.items.len});
        if (!try ui.confirm(ctx.out, msg)) {
            try ctx.out.writeAll("prune cancelled (project stays archived)\n");
            return;
        }
    }

    // What the remotes said before the prompt stands unless the prompt
    // waited on a person at a terminal.
    const prompted = !yes and ui.stdinIsTerminal();
    for (eligible.items) |e| {
        const m = e.m;
        // Hold the clone-path lock across the final reference re-check and the
        // delete. A concurrent add/new/adopt/promote that references this clone
        // holds the same lock while writing its marker, so if one slipped in
        // since the eligibility scan (or across the confirmation prompt) its
        // reference is on disk and visible here - and we keep the clone.
        var lock = try projectlock.acquire(alloc, app.envOf(ctx), m.clone_path);
        defer lock.release();
        if ((try ws.projectsUsing(alloc, m.id)).len > 0) {
            try ctx.out.print("not pruned {s}: now used by an active project\n", .{m.repo});
            continue;
        }
        var prepared = (try prepareClone(ctx, m, .{ .answers = if (prompted) null else e.answers, .many = true }, &held)) orelse continue;
        defer prepared.release();
        switch (try prepared.clear(ctx, false, .reuse)) {
            .done => {},
            .blocked => {
                try held.add(ctx, &prepared, m);
                try printNotPruned(ctx, m, try prepared.reasons(ctx, try forceCmd(ctx, m), try deleteCmd(ctx, m)));
                continue;
            },
            .failed => {
                try ctx.out.print("not pruned {s}: what it holds could not be set aside{s}\n", .{ m.repo, try followUp(ctx, m) });
                continue;
            },
        }
        if (!try prepared.unchanged(ctx, false)) {
            try ctx.out.print("not pruned {s}: {s}; delete it with: holt repo remove {s} --clone\n", .{ m.repo, try prepared.changedWhy(ctx, "the clone"), try ui.shellQuote(alloc, try m.id.relPath(alloc)) });
            continue;
        }
        prepared.beforeDelete();
        std.Io.Dir.cwd().deleteTree(fsutil.io(), m.clone_path) catch |err| {
            try ctx.err.print("holt: failed to delete {s}: {s}; part of it may already be gone\n", .{ try app.tilde(ctx, m.clone_path), @errorName(err) });
            continue;
        };
        if (std.fs.path.dirname(m.clone_path)) |owner_dir| {
            fsutil.rmdirIfEmpty(owner_dir);
            if (std.fs.path.dirname(owner_dir)) |host_dir| fsutil.rmdirIfEmpty(host_dir);
        }
        try ctx.out.print("reclaimed {s} ({s})\n", .{ m.repo, try app.tilde(ctx, m.clone_path) });
    }
}

/// What deletes `m`'s clone once what kept it is settled, the project
/// being archived already, for the end of its `not pruned` lines.
fn followUp(ctx: *app.Ctx, m: Member) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "once settled, delete it with: {s}", .{try deleteCmd(ctx, m)});
}

/// `holt repo remove <key> --clone`, which deletes `m`'s clone.
fn deleteCmd(ctx: *app.Ctx, m: Member) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "holt repo remove {s} --clone", .{try ui.shellQuote(ctx.alloc, try m.id.relPath(ctx.alloc))});
}

/// What deletes `m`'s clone anyway, setting aside what it can first, for
/// the `not pruned` reasons that name one.
fn forceCmd(ctx: *app.Ctx, m: Member) ![]const u8 {
    return std.fmt.allocPrint(ctx.alloc, "holt repo remove {s} --clone --force", .{try ui.shellQuote(ctx.alloc, try m.id.relPath(ctx.alloc))});
}

/// The clones a skipped host kept from being asked, and so from being
/// pruned (`deleter.Prepared.skippedHosts`), named once per host after
/// the last clone.
const HeldBack = struct {
    by_host: deleter.HeldBack = .{},

    fn add(h: *HeldBack, ctx: *app.Ctx, p: *const deleter.Prepared, m: Member) !void {
        const a = ctx.alloc;
        const key = try ui.shellQuote(a, try m.id.relPath(a));
        for (try p.skippedHosts(a)) |sk| try h.by_host.add(a, sk, key);
    }

    fn print(h: *const HeldBack, ctx: *app.Ctx) !void {
        for (try h.by_host.lines(ctx.alloc, "not asked and not pruned", "holt repo remove <key> --clone", ", or holt repo remove <key> --clone --force deletes one")) |line| try ctx.out.print("{s}\n", .{line});
    }
};

fn paths_contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Prints why `m`'s clone is kept, `why` holding a phrase per unmet gate,
/// then what deletes it once they are settled: on one line for one gate,
/// which names it alone when it names it already (a remote that could not
/// be asked), else each on a line of its own; nothing when `why` is empty,
/// as for a clone only a host that did not answer held back (`HeldBack`).
fn printNotPruned(ctx: *app.Ctx, m: Member, why: []const []const u8) !void {
    if (why.len == 0) return;
    const named = try std.fmt.allocPrint(ctx.alloc, ", then delete it with: {s},", .{try deleteCmd(ctx, m)});
    if (why.len == 1 and std.mem.indexOf(u8, why[0], named) != null) return ctx.out.print("not pruned {s}: {s}\n", .{ m.repo, why[0] });
    if (why.len == 1) return ctx.out.print("not pruned {s}: {s}; {s}\n", .{ m.repo, why[0], try followUp(ctx, m) });
    try ctx.out.print("not pruned {s}:\n", .{m.repo});
    for (why) |w| try ctx.out.print("  {s}\n", .{w});
    try ctx.out.print("  {s}\n", .{try followUp(ctx, m)});
}

/// The kept-file steps for pruning `m`'s clone, holding its locks; null,
/// with its `not pruned` line printed, when the clone must be kept.
fn prepareClone(ctx: *app.Ctx, m: Member, opts: deleter.Options, held: *HeldBack) !?deleter.Prepared {
    switch (try deleter.prepare(ctx, m.clone_path, .clone, opts)) {
        .refused => |why| {
            try ctx.out.print("not pruned {s}: {s}; {s}\n", .{ m.repo, why, try followUp(ctx, m) });
            return null;
        },
        .ready => |p| {
            var prepared = p;
            if (prepared.found.blocked()) {
                try held.add(ctx, &prepared, m);
                try printNotPruned(ctx, m, try prepared.reasons(ctx, try forceCmd(ctx, m), try deleteCmd(ctx, m)));
                prepared.release();
                return null;
            }
            return prepared;
        },
    }
}

const UnarchiveSpec = struct {
    project: cli.Pos([]const u8, .{ .complete = app.cat(.archived), .help = "the project to unarchive" }),
};

pub const unarchive_command = app.command(UnarchiveSpec, .{
    .name = "unarchive",
    .summary = "Move an archived project back into projects/ and rebuild its hub",
    .usage = "holt project unarchive <project>",
    .group = .create,
    .needs_context = true,
    .details =
    \\Example:
    \\  holt project unarchive acme/widget
    ,
}, runUnarchive);

fn runUnarchive(ctx: *app.Ctx, a: cli.Args(UnarchiveSpec)) anyerror!u8 {
    const spec = a.project;

    const ws = ctx.context.?.ws;
    const alloc = ctx.alloc;

    const on = common.parseOrgName(spec) orelse {
        return app.usageError(ctx, "{s}", .{try common.parseOrgNameMessage(alloc, spec)});
    };

    const archive_root = try ws.archiveRoot(alloc);
    const archive_path = try std.fs.path.join(alloc, &.{ archive_root, on.org, on.name });
    const archive_marker = try std.fs.path.join(alloc, &.{ archive_path, marker.marker_basename });
    if (!fsutil.exists(archive_marker)) {
        try ctx.err.print("holt: no archived project at {s}\n", .{try app.tilde(ctx, archive_path)});
        return 1;
    }

    const projects_root = try ws.projectsRoot(alloc);
    const dest_path = try std.fs.path.join(alloc, &.{ projects_root, on.org, on.name });
    if (fsutil.exists(dest_path)) {
        try ctx.err.print("holt: {s}/{s} already exists in projects\n", .{ on.org, on.name });
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

    try ctx.out.print("unarchived {s}/{s}\n", .{ on.org, on.name });
    return 0;
}

test "new: creates content dirs and marker, and names the next step on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const hub_path = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "widget" });
    try testing.expectEqualStrings(hub_path, std.mem.trim(u8, got.out, " \t\r\n"));
    try testing.expect(std.mem.indexOf(u8, got.err, "created acme/widget") != null);
    // A memberless project has no code/ dir; say how to add one.
    try testing.expect(std.mem.indexOf(u8, got.err, "holt repo get") != null);
    try testing.expect(std.mem.indexOf(u8, got.err, "-p acme/widget") != null);

    for (project_mod.content_dirs) |sub| {
        const dir_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "widget", sub });
        try testing.expect(fsutil.exists(dir_path));
    }
}

test "new: a url argument is rejected - populating a project is repo get's job" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{ "acme/widget", "https://example.invalid/a/b" });
    try testing.expectEqual(@as(u8, 2), got.code);
}

test "new: an already-existing project is a hard error, not overwritten" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const first = try testutil.runCmd(arena, new_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), first.code);

    const second = try testutil.runCmd(arena, new_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 1), second.code);
    try testing.expect(std.mem.indexOf(u8, second.err, "already exists") != null);
}

test "new: a project already in the archive is refused and nothing is created" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .empty, .empty);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists in archive") != null);
    // The one verb that brings it back, named in the refusal.
    try testing.expect(std.mem.indexOf(u8, got.err, "holt project unarchive acme/widget") != null);

    const marker_path = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget", marker.marker_basename });
    try testing.expect(!fsutil.exists(marker_path));
}

test "new: a malformed spec (no slash) is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try testutil.runCmd(arena, new_command.run, null, &.{"widget"});
    try testing.expectEqual(@as(u8, 2), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "widget") != null);
}

test "new: an org that traverses out of the roots is rejected and nothing is written outside them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"../escape"});
    try testing.expectEqual(@as(u8, 2), got.code);

    const projects_root = try ws.projectsRoot(arena);
    const content_escape = try std.fs.path.join(arena, &.{ projects_root, "..", "escape" });
    try testing.expect(!fsutil.exists(content_escape));
    const hub_escape = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "..", "escape" });
    try testing.expect(!fsutil.exists(hub_escape));
}

test "new: a control-char name is rejected before anything is created" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, new_command.run, ws, &.{"acme/wi\x01dget"});
    try testing.expectEqual(@as(u8, 2), got.code);

    const org_dir = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(!fsutil.exists(org_dir));
}

// This test always passes --yes: ui.confirm blocks on real stdin, and a test
// run has no interactive stdin to feed it.
test "remove: deletes content and hub, keeps the clone, and reports it unreferenced" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", repos, .empty);

    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
    try fsutil.ensureDir(clone_path);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "acme/widget", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "deleted acme/widget") != null);
    // The unreferenced-clone note tilde-abbreviates the path for display.
    try testing.expect(std.mem.indexOf(u8, got.out, try fsutil.contractTilde(arena, app.envOf_current(), clone_path)) != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "unreferenced") != null);

    try testing.expect(!fsutil.exists(p.content_path));
    try testing.expect(!fsutil.exists(p.hub_path));
    try testing.expect(fsutil.exists(clone_path));
}

test "remove: --yes deleting the last project in an org prunes the emptied org's content and hub dirs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "acme/widget", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(!fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(!fsutil.exists(old_org_hub));
}

test "remove: --yes deleting one of two projects in an org leaves the org's content and hub dirs in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "gizmo", .empty, .empty);
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);
    const gizmo_p = switch (try ws.find(arena, "acme/gizmo")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &gizmo_p, false);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "acme/widget", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(fsutil.exists(old_org_hub));
    const remaining_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "gizmo" });
    try testing.expect(fsutil.exists(remaining_content));
}

test "remove: --yes on a project with no repos deletes cleanly with no orphan report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "empty", .empty, .empty);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "acme/empty", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "deleted acme/empty") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "unreferenced") == null);
}

test "remove: no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "nope", "--yes" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "remove: a partial content-delete failure keeps the marker, so the project stays listable and remove is re-runnable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    // A child inside a read-only dir cannot be removed, so deleteTree of
    // "locked" fails and the marker (deleted last) survives. Mode bits don't
    // gate access on Windows, so this whole simulation is POSIX-only.
    const locked_rel = "synced/projects/acme/widget/locked";
    try tmp.dir.createDirPath(testing.io, locked_rel ++ "/nested");
    if (builtin.os.tag != .windows) {
        try tmp.dir.setFilePermissions(testing.io, locked_rel, std.Io.File.Permissions.fromMode(0o555), .{});
        defer tmp.dir.setFilePermissions(testing.io, locked_rel, std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        const got = try testutil.runCmd(arena, remove_command.run, ws, &.{ "acme/widget", "--yes" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "failed to delete") != null);
        try testing.expect(std.mem.indexOf(u8, got.err, "holt project remove acme/widget") != null);

        const marker_path = try p.markerPath(arena);
        try testing.expect(fsutil.exists(marker_path));
        switch (try ws.find(arena, "acme/widget")) {
            .one => {},
            else => return error.TestUnexpectedResult,
        }

        // Restore perms and re-run: remove now completes fully.
        try tmp.dir.setFilePermissions(testing.io, locked_rel, std.Io.File.Permissions.fromMode(0o755), .{});
        const again = try testutil.runCmd(arena, remove_command.run, ws, &.{ "acme/widget", "--yes" });
        try testing.expectEqual(@as(u8, 0), again.code);
        try testing.expect(!fsutil.exists(p.content_path));
    }
}

test "rename: moves content to the new org/name and rebuilds the hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "old", .empty, .empty);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme/old", "acme/new" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const moved = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "new", marker.marker_basename });
    try testing.expect(fsutil.exists(moved));
}

test "archive: moves content into archive/ and drops the hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "old", .empty, .empty);

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{ "acme/old", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const archived = try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme", "old", marker.marker_basename });
    try testing.expect(fsutil.exists(archived));
}

test "rename: moves content, rewrites the marker, and rebuilds the hub at the new name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget", "docs" }));
    const old_p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &old_p, false);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme/widget", "corp/gadget" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "renamed acme/widget -> corp/gadget") != null);

    const old_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(!fsutil.exists(old_content));
    const new_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "corp", "gadget" });
    try testing.expect(fsutil.exists(new_content));

    const marker_path = try std.fs.path.join(arena, &.{ new_content, marker.marker_basename });
    const loaded = try marker.load(arena, marker_path, null);
    try testing.expectEqualStrings("corp", loaded.org);
    try testing.expectEqualStrings("gadget", loaded.name);

    try testing.expect(!fsutil.exists(old_p.hub_path));
    const new_hub_docs = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "corp", "gadget", "docs" });
    switch (try fsutil.linkState(arena, new_hub_docs)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "rename: a hub rebuild failure after the content move points the user at holt sync, content already moved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    // A read-only hub_root makes creating the new hub dir fail, after the
    // content has already moved to its new home. Mode bits don't gate
    // access on Windows, so this whole simulation is POSIX-only.
    if (builtin.os.tag != .windows) {
        try tmp.dir.setFilePermissions(testing.io, "hub", std.Io.File.Permissions.fromMode(0o555), .{});
        defer tmp.dir.setFilePermissions(testing.io, "hub", std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme/widget", "corp/gadget" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "holt sync") != null);

        const new_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "corp", "gadget" });
        try testing.expect(fsutil.exists(new_content));
    }
}

test "rename: refuses when the target project already exists, leaving the source in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "corp", "gadget", .empty, .empty);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme/widget", "corp/gadget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists") != null);

    const old_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(old_content));
}

test "rename: source and target are the same project reports the clearer message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme/widget", "acme/widget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expectStringEndsWith(got.err, "holt: source and target are the same project\n");

    const content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(content));
}

test "rename: renaming the last project out of an org prunes the emptied org's content and hub dirs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    const old_p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &old_p, false);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme/widget", "corp/gadget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(!fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(!fsutil.exists(old_org_hub));
}

test "rename: renaming one of two projects out of an org leaves the org's content and hub dirs in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "gizmo", .empty, .empty);
    const widget_p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &widget_p, false);
    const gizmo_p = switch (try ws.find(arena, "acme/gizmo")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &gizmo_p, false);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme/widget", "corp/gadget" });
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(fsutil.exists(old_org_hub));
    const remaining_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "gizmo" });
    try testing.expect(fsutil.exists(remaining_content));
}

test "rename: a malformed <new-org>/<new-name> spec is a usage error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme/widget", "no-slash" });
    try testing.expectEqual(@as(u8, 2), got.code);
}

test "rename: a target that traverses out of the roots is rejected, leaving the source in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "acme/widget", "acme/../x" });
    try testing.expectEqual(@as(u8, 2), got.code);

    const source = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(source));
    const escape = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "..", "x" });
    try testing.expect(!fsutil.exists(escape));
}

test "rename: no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, rename_command.run, ws, &.{ "nope", "corp/gadget" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "archive: moves content into archive/, drops the hub, and unarchive round-trips it back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget", "docs" }));
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "archived acme/widget") != null);

    const projects_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(!fsutil.exists(projects_content));
    const archived_content = try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(archived_content));
    try testing.expect(!fsutil.exists(p.hub_path));

    const unarchive_got = try testutil.runCmd(arena, unarchive_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), unarchive_got.code);

    try testing.expect(fsutil.exists(projects_content));
    try testing.expect(!fsutil.exists(archived_content));

    const docs_link = try std.fs.path.join(arena, &.{ p.hub_path, "docs" });
    switch (try fsutil.linkState(arena, docs_link)) {
        .symlink => {},
        else => return error.TestUnexpectedResult,
    }
}

test "archive: archiving the last project in an org prunes the emptied org's content and hub dirs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(!fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(!fsutil.exists(old_org_hub));
}

test "archive: archiving one of two projects in an org leaves the org's content and hub dirs in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "gizmo", .empty, .empty);
    const p = switch (try ws.find(arena, "acme/widget")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &p, false);
    const gizmo_p = switch (try ws.find(arena, "acme/gizmo")) {
        .one => |proj| proj,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub.reconcile(arena, &ws, &gizmo_p, false);

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const old_org_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme" });
    try testing.expect(fsutil.exists(old_org_content));
    const old_org_hub = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme" });
    try testing.expect(fsutil.exists(old_org_hub));
    const remaining_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "gizmo" });
    try testing.expect(fsutil.exists(remaining_content));
}

test "archive: refuses when the archive destination already exists, leaving content in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .empty, .empty);

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists") != null);

    const projects_content = try std.fs.path.join(arena, &.{ try ws.projectsRoot(arena), "acme", "widget" });
    try testing.expect(fsutil.exists(projects_content));
}

fn writeProjectWithClone(sb: *testutil.Sandbox, arena: std.mem.Allocator, ws: workspace.Workspace, org: []const u8, name: []const u8, repo: []const u8, url: []const u8) ![]const u8 {
    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, repo, url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), org, name, repos, .empty);
    const bare = try testutil.makeBareRepo(sb, try std.fmt.allocPrint(arena, "{s}-{s}.git", .{ org, name }));
    defer testing.allocator.free(bare);
    const id = try identity.fromUrl(arena, url);
    const clone_path = try id.clonePath(arena, ws.cfg.code_root);
    try git.clone(arena, bare, clone_path, .allow, null);
    return clone_path;
}

test "archive: --prune reclaims a clean, synced, unreferenced member clone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", "https://holt-test.invalid/acme/widget");
    try testing.expect(fsutil.exists(clone_path));

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "archived acme/proj") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, "reclaimed widget") != null);
    try testing.expect(!fsutil.exists(clone_path));
}

test "archive: --prune keeps a clone still referenced by another active project" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const url = "https://holt-test.invalid/acme/widget";
    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", url);
    // A second active project references the same clone.
    var repos2: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos2.put(arena, "widget", url);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "other", repos2, .empty);

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "not pruned widget: still used by an active project") != null);
    try testing.expect(fsutil.exists(clone_path));
}

test "archive: --prune keeps a clone with uncommitted local changes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", "https://holt-test.invalid/acme/widget");
    // Dirty the clone so it is no longer safe to reclaim.
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), clone_path, .{});
    defer d.close(fsutil.io());
    try d.writeFile(fsutil.io(), .{ .sub_path = "uncommitted.txt", .data = "work in progress\n" });

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "not pruned widget: 1 uncommitted change in ") != null);
    try testing.expect(fsutil.exists(clone_path));
}

test "archive: --prune keeps a clone that has worktrees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", "https://holt-test.invalid/acme/widget");

    // An extra worktree (which may hold uncommitted work) must block reclaim.
    const wt = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "feature-x" });
    try fsutil.ensureDir(std.fs.path.dirname(wt).?);
    try testutil.runGit(&sb, clone_path, &.{ "branch", "feature-x" });
    try testutil.runGit(&sb, clone_path, &.{ "worktree", "add", wt, "feature-x" });

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "not pruned widget: has worktrees") != null);
    try testing.expect(fsutil.exists(clone_path));
}

test "archive: no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{"nope"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}

test "unarchive: moves an archived project back into projects/ and rebuilds its hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .empty, .empty);
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme", "widget", "docs" }));

    const got = try testutil.runCmd(arena, unarchive_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "unarchived acme/widget") != null);

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

test "unarchive: unarchiving the only project in an org prunes the emptied archive org dir" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .empty, .empty);

    const archive_org_dir = try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme" });
    try testing.expect(fsutil.exists(archive_org_dir));

    const got = try testutil.runCmd(arena, unarchive_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);

    try testing.expect(!fsutil.exists(archive_org_dir));
}

test "unarchive: a project with no archive entry is a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, unarchive_command.run, ws, &.{"acme/nope"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "no archived project") != null);
}

test "unarchive: unarchiving over an existing project is a hard error, archive kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "acme", "widget", .empty, .empty);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);

    const got = try testutil.runCmd(arena, unarchive_command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "already exists") != null);

    const archive_marker = try std.fs.path.join(arena, &.{ try ws.archiveRoot(arena), "acme", "widget", marker.marker_basename });
    try testing.expect(fsutil.exists(archive_marker));
}

test "archive: --prune keeps a clone whose uncommitted change only a paused rebase --autostash holds, naming the rebase" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", "https://holt-test.invalid/acme/widget");
    {
        var d = try std.Io.Dir.cwd().openDir(fsutil.io(), clone_path, .{});
        defer d.close(fsutil.io());
        try d.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "unsaved work\n" });
    }
    try testutil.runGit(&sb, clone_path, &.{ "-c", "sequence.editor=sed -i.orig s/^pick/edit/", "rebase", "-i", "--autostash", "--root" });
    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expect(fsutil.exists(clone_path));
    const cq = try ui.quotePath(arena, app.envOf_current(), try fsutil.realPathOrSelf(arena, clone_path));
    try testing.expect(std.mem.indexOf(u8, got.out, "not pruned widget: rebase in progress in ") != null);
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "; finish it or abort it (run: git -C {s} rebase --continue, or git -C {s} rebase --abort); once settled, delete it with: holt repo remove holt-test.invalid/acme/widget --clone\n", .{ cq, cq })) != null);
}

test "archive: --prune names a clone git cannot read as unreadable, with the repo remove that deletes it, not as one with worktrees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const state = try testutil.stateScope(arena, sb.root);
    defer state.restore();
    const ws = try testutil.testWorkspace(arena, sb.root);
    const clone_path = try writeProjectWithClone(&sb, arena, ws, "acme", "proj", "widget", "https://holt-test.invalid/acme/widget");
    try testutil.runGit(&sb, clone_path, &.{ "config", "core.repositoryformatversion", "1" });
    try testutil.runGit(&sb, clone_path, &.{ "config", "extensions.holt-test-unknown", "x" });
    const got = try testutil.runCmd(arena, archive_command.run, ws, &.{ "acme/proj", "--prune", "--yes" });
    try testing.expect(fsutil.exists(clone_path));
    try testing.expect(std.mem.indexOf(u8, got.out, "has worktrees") == null);
    const shown = try fsutil.contractTilde(arena, app.envOf_current(), clone_path);
    try testing.expect(std.mem.indexOf(u8, got.out, try std.fmt.allocPrint(arena, "not pruned widget: git state of {s} could not be read; holt repo remove holt-test.invalid/acme/widget --clone --force deletes it; once settled, delete it with: holt repo remove holt-test.invalid/acme/widget --clone\n", .{shown})) != null);
}
