//! Project resolution, org/name parsing, and content-dir filesystem ops
//! shared by every single-project command: `resolveOne` turns a user query
//! into exactly one `Project` (reporting and returning null on no match or
//! ambiguity), `parseOrgName` splits an "<org>/<name>" spec, `moveDir`/
//! `removeContent` wrap a rename/delete with a contextual error message
//! instead of leaking a raw error name to the user, and `moveProject`
//! performs the full mechanical move of a project to a new org/name.

const std = @import("std");
const builtin = @import("builtin");
const app = @import("../app.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const marker = @import("../marker.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const kept = @import("../kept.zig");
const deleter = @import("deleter.zig");
const diagnostic = @import("../diag.zig");
const testutil = @import("../testutil.zig");
const testing = std.testing;

/// Reports why `query` failed to resolve to exactly one project. A `.none`
/// for an "<org>/<name>" query whose marker exists but fails to parse gets a
/// malformed-marker hint pointing at `holt doctor` instead of a bare "no
/// project matches", so a corrupt marker isn't mistaken for no such project.
pub fn reportProjectFailure(ctx: *app.Ctx, query: []const u8, found: workspace.FindResult) anyerror!u8 {
    switch (found) {
        .none => {
            if (std.mem.indexOfScalar(u8, query, '/')) |slash| {
                const org = query[0..slash];
                const name = query[slash + 1 ..];
                if (try ctx.context.?.ws.hasMalformedMarker(ctx.alloc, org, name)) {
                    try ctx.err.print("holt: {s}/{s} has a malformed marker (run \"holt doctor\")\n", .{ org, name });
                    return 1;
                }
                const content_path = try std.fs.path.join(ctx.alloc, &.{ try ctx.context.?.ws.projectsRoot(ctx.alloc), org, name });
                if (marker.markerEvicted(ctx.alloc, content_path)) {
                    try ctx.err.print("holt: {s}/{s}'s marker is evicted from local storage; open its folder to download it, then retry\n", .{ org, name });
                    return 1;
                }
            }
            try ctx.err.print("holt: no project matches \"{s}\"\n", .{query});
        },
        .ambiguous => |cands| {
            try ctx.err.print("holt: \"{s}\" is ambiguous between:\n", .{query});
            for (cands) |c| {
                const qualified = try c.qualified(ctx.alloc);
                try ctx.err.print("  {s}\n", .{qualified});
            }
        },
        .one => unreachable,
    }
    return 1;
}

/// Resolves `query` against the loaded workspace to exactly one project;
/// null (after reporting why on ctx.err) for no match or an ambiguous one.
/// Callers do `(try resolveOne(ctx, query)) orelse return 1`.
pub fn resolveOne(ctx: *app.Ctx, query: []const u8) !?project_mod.Project {
    const found = try ctx.context.?.ws.find(ctx.alloc, query);
    switch (found) {
        .one => |p| return p,
        .none, .ambiguous => {
            _ = try reportProjectFailure(ctx, query, found);
            return null;
        },
    }
}

/// If the current working directory is inside a project's hub
/// (<hub_root>/<org>/<name>/...), resolves and returns that project. Returns
/// null when the cwd is not under any hub.
pub fn projectFromCwd(ctx: *app.Ctx) !?project_mod.Project {
    const alloc = ctx.alloc;
    const ws = ctx.context.?.ws;

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = buf[0..try std.process.currentPath(fsutil.io(), &buf)];
    const cwd_real = try fsutil.realPathOrSelf(alloc, cwd);
    const hub_real = try fsutil.realPathOrSelf(alloc, ws.cfg.hub_root);

    if (!fsutil.pathIsInside(cwd_real, hub_real)) return null;
    if (cwd_real.len == hub_real.len) return null;

    const rel = cwd_real[hub_real.len + 1 ..];
    var parts = std.mem.splitScalar(u8, rel, std.fs.path.sep);
    const org = parts.next() orelse return null;
    const name = parts.next() orelse return null;
    if (org.len == 0 or name.len == 0) return null;

    const query = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ org, name });
    const found = try ws.find(alloc, query);
    switch (found) {
        .one => |p| return p,
        .none, .ambiguous => return null,
    }
}

pub const OrgName = struct { org: []const u8, name: []const u8 };

/// Reserved as an ORG only: these are the structural siblings of - or the
/// name of - the projects dir under the synced root, so an org named after
/// one would confuse the on-disk layout.
/// The code-tree key of the clone at `clone_path` under `code_root`, as
/// `holt list --repos` prints it.
pub fn codeKey(alloc: std.mem.Allocator, code_root: []const u8, clone_path: []const u8) ![]const u8 {
    const rel = try alloc.dupe(u8, if (clone_path.len > code_root.len and fsutil.pathIsInside(clone_path, code_root)) clone_path[code_root.len + 1 ..] else clone_path);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
    return rel;
}

const reserved_orgs = [_][]const u8{ "archive", "backups", "projects" };

/// Rejects an org or project name that is unsafe or confusing as a single
/// path segment, returning a short reason (else null when acceptable). This
/// is a denylist of the genuinely dangerous - traversal, path separators,
/// control bytes, the marker/.git names, and org-reserved siblings - so an
/// org/name flows straight into a filesystem path with no chance of escaping
/// the configured roots. Ordinary names, including unicode, are left alone.
pub fn validateSegment(comptime kind: enum { org, name }, seg: []const u8) ?[]const u8 {
    if (seg.len == 0) return "cannot be empty";
    if (seg.len > 255) return "is longer than 255 bytes";
    if (std.ascii.isWhitespace(seg[0]) or std.ascii.isWhitespace(seg[seg.len - 1]))
        return "cannot have leading or trailing whitespace";
    if (std.mem.indexOfScalar(u8, seg, '/') != null) return "cannot contain a \"/\"";
    if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, ".."))
        return "cannot be \".\" or \"..\"";
    for (seg) |c| {
        if (c < 0x20 or c == 0x7f) return "cannot contain control characters";
    }
    if (std.mem.eql(u8, seg, ".git") or std.mem.eql(u8, seg, marker.marker_basename))
        return "is a reserved name";
    if (workspace.isConflictCopyName(seg))
        return "looks like a cloud-sync conflict copy";
    if (kind == .org) {
        for (reserved_orgs) |r| {
            if (std.mem.eql(u8, seg, r)) return "is a reserved org name";
        }
    }
    return null;
}

/// Splits "<org>/<name>" on the first slash and validates both segments; null
/// on a missing slash, an empty side, or an org/name `validateSegment`
/// rejects (a second slash inside `name` is caught as an invalid name, since
/// a project name is one path segment). Callers turn null into a usage error
/// and can name the specific reason via `parseOrgNameMessage`.
pub fn parseOrgName(spec: []const u8) ?OrgName {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return null;
    const org = spec[0..slash];
    const name = spec[slash + 1 ..];
    if (validateSegment(.org, org) != null) return null;
    if (validateSegment(.name, name) != null) return null;
    return .{ .org = org, .name = name };
}

/// Builds the usage message for a spec `parseOrgName` rejected, naming which
/// segment failed and why (or the bare "<org>/<name>" form on a missing
/// slash). Callers assign the result to `ctx.args.message`.
pub fn parseOrgNameMessage(alloc: std.mem.Allocator, spec: []const u8) ![]const u8 {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse
        return std.fmt.allocPrint(alloc, "expected \"<org>/<name>\", got \"{s}\"", .{spec});
    const org = spec[0..slash];
    const name = spec[slash + 1 ..];
    if (validateSegment(.org, org)) |why|
        return std.fmt.allocPrint(alloc, "invalid org name \"{s}\": {s}", .{ org, why });
    if (validateSegment(.name, name)) |why|
        return std.fmt.allocPrint(alloc, "invalid project name \"{s}\": {s}", .{ name, why });
    return std.fmt.allocPrint(alloc, "expected \"<org>/<name>\", got \"{s}\"", .{spec});
}

/// Moves `from` to `to`, creating `to`'s parent directory first so the move
/// can land. Callers are expected to have already refused a `to` that exists;
/// this only performs the move itself. On failure, prints a message naming
/// both paths and the underlying error to `ctx.err` instead of letting a
/// raw error name reach the user via dispatch's catch-all.
pub fn moveDir(ctx: *app.Ctx, from: []const u8, to: []const u8) !void {
    // moveTree renames within a filesystem and copy-then-deletes across one, so
    // a clone whose checkout lives on a different volume than code_root still
    // relocates instead of failing with CrossDevice.
    fsutil.moveTree(ctx.alloc, from, to) catch |err| {
        try ctx.err.print("holt: failed to move {s} -> {s}: {s}\n", .{ try app.tilde(ctx, from), try app.tilde(ctx, to), @errorName(err) });
        return err;
    };
}

/// Moves a clone `from` -> `to`, carrying its sibling `<clone>@worktrees` dir
/// along so a repo's worktrees survive its clone moving to a new identity,
/// then points each linked worktree that no longer leads back to its record
/// at it again, one worktree and one record at a time (`relinkMoved`).
/// When the `@worktrees` dir cannot be moved, the worktrees in it are
/// relinked where they are, as is every other, and the failure is then
/// named with the dir that was not moved. Used by the movers that relocate
/// a clone (promote, adopt).
///
/// A worktree in `<clone>@worktrees` created with relative admin paths
/// (git 2.48+, see git.worktreeAdd) keeps working untouched when that dir
/// moves along, because the layout between the clone and it is preserved;
/// one elsewhere, or left behind, is relinked as any other.
pub fn moveClone(ctx: *app.Ctx, from: []const u8, to: []const u8) !void {
    try moveDir(ctx, from, to);

    const alloc = ctx.alloc;
    const from_wt = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{from});
    const to_wt = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{to});
    var wt_failed: ?anyerror = null;
    if (fsutil.exists(from_wt)) fsutil.moveTree(alloc, from_wt, to_wt) catch |err| {
        wt_failed = err;
    };
    try relinkMoved(ctx, from, to, wt_failed == null);
    if (wt_failed) |err| try ctx.err.print("holt: moved clone but could not move its worktrees dir {s} to {s} ({s}); the worktrees in it were not moved\n", .{ try app.tilde(ctx, from_wt), try app.tilde(ctx, to_wt), @errorName(err) });
}

/// For each record of a linked worktree of the clone moved from `from` to
/// `to`: the worktree is where the record's `gitdir` named it before the
/// move, a relative one read against where the record was then, moved
/// along when that is under `from`, or under `<from>@worktrees` and
/// `wt_moved` says that dir moved. A worktree where git does not find the
/// record, whose `.git` names the record where it was before the move, a
/// relative one read against where the worktree was then, gets its `.git`
/// written as the record is now (`deleter.writeLink`). Each path is
/// compared with its deepest existing directory resolved to its real path
/// (`deleter.resolvedPath`), and each relative one is read against such a
/// path, so a symlinked parent folds `..` as git does.
/// Once git there finds the record, the record's `gitdir` is written as
/// where the worktree is now (`deleter.recordText`) whenever it no longer
/// leads there, as a relative one does once only the record moved. Every
/// other worktree and record is left as it is: one with no `.git`, and one
/// whose `.git` names anything else, as another repository's worktree at
/// the path of a stale record does. Each that cannot be written is named
/// with the command that settles it.
fn relinkMoved(ctx: *app.Ctx, from: []const u8, to: []const u8, wt_moved: bool) !void {
    const a = ctx.alloc;
    const res = git.runInRepo(a, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }, to) catch return;
    if (res.status != 0) return;
    const common = try fsutil.realPathOrSelf(a, std.mem.trim(u8, res.stdout, " \t\r\n"));
    const to_real = try fsutil.realPathOrSelf(a, to);
    const from_real = try deleter.resolvedPath(a, from);
    const old_common = if (fsutil.pathIsInside(common, to_real)) try std.mem.concat(a, u8, &.{ from_real, common[to_real.len..] }) else common;
    const records = kept.clone.linkedRecords(a, common) catch return;
    for (records) |rec| {
        const now = rec.path orelse continue;
        const old_record = try std.mem.concat(a, u8, &.{ old_common, rec.record[common.len..] });
        const at = kept.clone.recordedTree(a, rec.record, old_record) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const old_tree = try deleter.resolvedPath(a, at);
        const tree = try movedPath(a, old_tree, from_real, to_real, wt_moved);
        if (!try deleter.findsRecord(a, tree, rec.record)) {
            const old = kept.content.readSmall(a, try std.fs.path.join(a, &.{ tree, ".git" })) catch continue;
            const line = std.mem.trimEnd(u8, old, " \t\r\n");
            if (!std.mem.startsWith(u8, line, "gitdir: ")) continue;
            const named = try deleter.resolvedPath(a, try std.fs.path.resolve(a, &.{ old_tree, line["gitdir: ".len..] }));
            if (!std.mem.eql(u8, named, old_record)) continue;
            deleter.writeLink(a, tree, rec.record, old) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try ctx.err.print("holt: moved clone but could not relink its worktree {s} ({s}) (run: {s})\n", .{ try app.tilde(ctx, tree), @errorName(err), try deleter.relinkCmd(ctx, tree, rec.record, false) });
                    continue;
                },
            };
        }
        if (std.mem.eql(u8, try deleter.resolvedPath(a, now), tree)) continue;
        fsutil.writeFileAtomic(a, try std.fs.path.join(a, &.{ rec.record, "gitdir" }), try deleter.recordText(a, tree)) catch |err| {
            try ctx.err.print("holt: moved clone but could not point the record of its worktree {s} at it ({s}) (run: {s})\n", .{ try app.tilde(ctx, tree), @errorName(err), try deleter.repointCmd(ctx, rec.record, tree) });
        };
    }
}

/// `path` moved from under `from` to under `to`: under `<to>@worktrees`
/// for one under `<from>@worktrees` when `wt_moved`, else `path` itself;
/// under `to` for one under `from`; `path` itself for any other.
fn movedPath(a: std.mem.Allocator, path: []const u8, from: []const u8, to: []const u8, wt_moved: bool) ![]const u8 {
    const from_wt = try std.mem.concat(a, u8, &.{ from, "@worktrees" });
    if (fsutil.pathIsInside(path, from_wt)) return if (wt_moved) std.mem.concat(a, u8, &.{ to, "@worktrees", path[from_wt.len..] }) else path;
    if (fsutil.pathIsInside(path, from)) return std.mem.concat(a, u8, &.{ to, path[from.len..] });
    return path;
}

/// Clones `url` into `clone_path` if it is not already present, returning
/// whether it actually cloned (false means the directory was already
/// there). On a clone failure, prints git's diagnostic (naming the url and
/// git's own error) to ctx.err and returns the error, re-propagating
/// OutOfMemory untouched.
pub fn cloneIfAbsent(ctx: *app.Ctx, url: []const u8, clone_path: []const u8) !bool {
    if (fsutil.exists(clone_path)) {
        // A clone left half-finished by an interrupted `git clone` has a
        // `.git` but no commits; adopting it binds the project to a broken
        // clone that every later check reads as healthy. Refuse it with an
        // actionable message rather than silently reusing it.
        if (!try git.isCompleteClone(ctx.alloc, clone_path)) {
            try ctx.err.print("holt: clone at {s} looks incomplete (an interrupted clone?); remove it and retry\n", .{try app.tilde(ctx, clone_path)});
            return error.IncompleteClone;
        }
        return false;
    }
    var cd: diagnostic.Diagnostic = .{};
    git.clone(ctx.alloc, url, clone_path, &cd) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try ctx.err.print("holt: {s}\n", .{cd.message});
            // A failed clone still left the ensureDir'd parent scaffold behind;
            // prune it back up to (but never above) code_root, leaving a
            // shared owner/host dir with other clones untouched.
            if (std.fs.path.dirname(clone_path)) |owner_dir| {
                fsutil.rmdirIfEmpty(owner_dir);
                if (std.fs.path.dirname(owner_dir)) |host_dir| fsutil.rmdirIfEmpty(host_dir);
            }
            return err;
        },
    };
    return true;
}

/// Recursively deletes `path`, reporting a contextual message on failure
/// instead of a raw error name, and that what was deleted before it failed
/// is gone.
pub fn removeContent(ctx: *app.Ctx, path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(fsutil.io(), path) catch |err| {
        try ctx.err.print("holt: failed to delete {s}: {s}; part of it may already be gone\n", .{ try app.tilde(ctx, path), @errorName(err) });
        return err;
    };
}

/// Reports a hub reconcile/removeHub failure that struck after a project's
/// content was already moved: the content sits correctly at its new path and a
/// later `holt sync` rebuilds the hub.
pub fn reportHubFailure(ctx: *app.Ctx, org: []const u8, name: []const u8, err: anyerror) !void {
    try ctx.err.print("holt: {s}/{s} moved, but rebuilding its hub failed: {s}; run \"holt sync\" to rebuild\n", .{ org, name, @errorName(err) });
}

/// Moves a project's content dir to `<projects>/<new_org>/<new_name>`,
/// rewrites its marker to match, and rebuilds its hub at the new location.
/// Purely mechanical: the caller has already refused a colliding
/// destination and obtained any confirmation, and is responsible for
/// pruning the emptied old-org content dir afterward.
pub fn moveProject(ctx: *app.Ctx, ws: *const workspace.Workspace, p: *const project_mod.Project, new_org: []const u8, new_name: []const u8) !void {
    const alloc = ctx.alloc;
    const projects_root = try ws.projectsRoot(alloc);
    const dest_path = try std.fs.path.join(alloc, &.{ projects_root, new_org, new_name });

    try moveDir(ctx, p.content_path, dest_path);

    var new_marker = p.marker;
    new_marker.org = new_org;
    new_marker.name = new_name;
    const marker_path = try std.fs.path.join(alloc, &.{ dest_path, marker.marker_basename });
    try marker.save(&new_marker, marker_path);

    hub.removeHub(p) catch |err| {
        try reportHubFailure(ctx, new_org, new_name, err);
        return err;
    };

    const new_hub_path = try std.fs.path.join(alloc, &.{ ws.cfg.hub_root, new_org, new_name });
    const new_p: project_mod.Project = .{ .org = new_org, .name = new_name, .content_path = dest_path, .hub_path = new_hub_path, .marker = new_marker };
    _ = hub.reconcile(alloc, ws, &new_p, false) catch |err| {
        try reportHubFailure(ctx, new_org, new_name, err);
        return err;
    };
}

test "validateSegment: rejects the structurally dangerous set for both org and name" {
    const cases = [_][]const u8{
        "..",
        ".",
        "a/b",
        "",
        "  ",
        " x",
        "x ",
        "a\x01b",
        ".git",
        marker.marker_basename,
    };
    inline for (cases) |seg| {
        try testing.expect(validateSegment(.org, seg) != null);
        try testing.expect(validateSegment(.name, seg) != null);
    }

    var long: [300]u8 = undefined;
    @memset(&long, 'a');
    try testing.expect(validateSegment(.name, &long) != null);
}

test "validateSegment: rejects sibling names only as an org, not as a name" {
    for ([_][]const u8{ "archive", "backups", "projects" }) |r| {
        try testing.expect(validateSegment(.org, r) != null);
        try testing.expect(validateSegment(.name, r) == null);
    }
    try testing.expect(validateSegment(.org, "kept") == null);
}

test "validateSegment: accepts ordinary and unicode names" {
    for ([_][]const u8{ "widget", "my-repo.v2", ".config", "\xf0\x9f\x9a\x80" }) |seg| {
        try testing.expect(validateSegment(.org, seg) == null);
        try testing.expect(validateSegment(.name, seg) == null);
    }
}

test "validateSegment: rejects a name that looks like a cloud conflict copy" {
    for ([_][]const u8{ "widget (conflicted copy 2024-01-01)", "widget (Case Conflict)" }) |seg| {
        try testing.expect(validateSegment(.org, seg) != null);
        try testing.expect(validateSegment(.name, seg) != null);
    }
}

test "parseOrgName: rejects a traversal or slashed segment and reports which part" {
    try testing.expect(parseOrgName("../x") == null);
    try testing.expect(parseOrgName("acme/../x") == null);
    try testing.expect(parseOrgName("acme/x") != null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const org_msg = try parseOrgNameMessage(arena, "../x");
    try testing.expect(std.mem.indexOf(u8, org_msg, "invalid org name") != null);

    const name_msg = try parseOrgNameMessage(arena, "acme/..");
    try testing.expect(std.mem.indexOf(u8, name_msg, "invalid project name") != null);

    const no_slash = try parseOrgNameMessage(arena, "widget");
    try testing.expect(std.mem.indexOf(u8, no_slash, "<org>/<name>") != null);
}

test "reportProjectFailure: an evicted marker gets a download-it message, not a bare no-match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const evicted_content = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "acme", "gone" });
    try fsutil.ensureDir(evicted_content);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ evicted_content, marker.evicted_marker_basename }), .data = "" });

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = .{ .ws = ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer };

    const found = try ctx.context.?.ws.find(arena, "acme/gone");
    _ = try reportProjectFailure(&ctx, "acme/gone", found);

    const reported = err_w.written();
    try testing.expect(std.mem.indexOf(u8, reported, "evicted") != null);
    try testing.expect(std.mem.indexOf(u8, reported, "acme/gone") != null);
}

test "moveDir: a move that fails reports both paths and the error, not a bare error name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const from = try std.fs.path.join(arena, &.{ root, "does-not-exist" });
    const to = try std.fs.path.join(arena, &.{ root, "dest", "widget" });

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = null, .out = &out.writer, .err = &err_w.writer };

    try testing.expectError(error.FileNotFound, moveDir(&ctx, from, to));

    const reported = err_w.written();
    try testing.expect(std.mem.indexOf(u8, reported, "failed to move") != null);
    const env = app.envOf_current();
    try testing.expect(std.mem.indexOf(u8, reported, try fsutil.contractTilde(arena, env, from)) != null);
    try testing.expect(std.mem.indexOf(u8, reported, try fsutil.contractTilde(arena, env, to)) != null);
}

test "removeContent: a delete that fails reports the path and the error, not a bare error name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "parent/target");

    // Stripping write permission from "parent" makes removing "target" from
    // it fail, without relying on deleteTree's already-gone-is-fine path.
    // Mode bits don't gate access on Windows, so this is POSIX-only.
    if (builtin.os.tag != .windows) {
        try tmp.dir.setFilePermissions(testing.io, "parent", std.Io.File.Permissions.fromMode(0o555), .{});
        defer tmp.dir.setFilePermissions(testing.io, "parent", std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
        const target_path = try std.fs.path.join(arena, &.{ root, "parent", "target" });

        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(arena);
        defer err_w.deinit();
        var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = null, .out = &out.writer, .err = &err_w.writer };

        try testing.expectError(error.AccessDenied, removeContent(&ctx, target_path));

        const reported = err_w.written();
        try testing.expect(std.mem.indexOf(u8, reported, "failed to delete") != null);
        try testing.expect(std.mem.indexOf(u8, reported, try fsutil.contractTilde(arena, app.envOf_current(), target_path)) != null);
    }
}

test "cloneIfAbsent: an incomplete clone already at the destination is refused, not adopted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    // A `.git` with no commits, exactly what a killed `git clone` leaves.
    const clone_path = try std.fs.path.join(arena, &.{ sb.root, "host", "owner", "repo" });
    try fsutil.ensureDir(clone_path);
    try testutil.runGit(&sb, clone_path, &.{ "init", "-q" });

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = null, .out = &out.writer, .err = &err_w.writer };

    try testing.expectError(error.IncompleteClone, cloneIfAbsent(&ctx, "https://holt-test.invalid/x/y", clone_path));
    try testing.expect(std.mem.indexOf(u8, err_w.written(), "incomplete") != null);
}

test "cloneIfAbsent: a failed clone prunes the empty owner and host scaffold it created" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const url = "https://127.0.0.1/acme/widget";
    const override = try testutil.gitUnreachable(arena, root, &.{url});
    defer override.restore();
    const clone_path = try std.fs.path.join(arena, &.{ root, "127.0.0.1", "acme", "widget" });

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = null, .out = &out.writer, .err = &err_w.writer };

    try testing.expectError(error.GitCloneFailed, cloneIfAbsent(&ctx, url, clone_path));

    const owner_dir = try std.fs.path.join(arena, &.{ root, "127.0.0.1", "acme" });
    const host_dir = try std.fs.path.join(arena, &.{ root, "127.0.0.1" });
    try testing.expect(!fsutil.exists(owner_dir));
    try testing.expect(!fsutil.exists(host_dir));
}

test "projectFromCwd: resolves the project when cwd is inside its hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = try testutil.testWorkspace(arena, root);
    const repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const hub_dir = try std.fs.path.join(arena, &.{ ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(hub_dir);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = .{ .ws = ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer };

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    // cwd is process-global and shared by every test in this binary, so a
    // missing restore here would corrupt every test that runs afterward.
    try std.process.setCurrentPath(fsutil.io(), hub_dir);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    const p = (try projectFromCwd(&ctx)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("acme", p.org);
    try testing.expectEqualStrings("proj", p.name);
}

test "projectFromCwd: returns null when cwd is exactly hub_root, not just inside it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws = try testutil.testWorkspace(arena, root);
    try fsutil.ensureDir(ws.cfg.hub_root);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = .{ .ws = ws, .color = false, .env = app.envOf_current() }, .out = &out.writer, .err = &err_w.writer };

    var orig_cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig_cwd = try testing.allocator.dupe(u8, orig_cwd_buf[0..try std.process.currentPath(fsutil.io(), &orig_cwd_buf)]);
    defer testing.allocator.free(orig_cwd);

    // cwd is process-global and shared by every test in this binary, so a
    // missing restore here would corrupt every test that runs afterward.
    try std.process.setCurrentPath(fsutil.io(), ws.cfg.hub_root);
    defer std.process.setCurrentPath(fsutil.io(), orig_cwd) catch {};

    try testing.expect((try projectFromCwd(&ctx)) == null);
}

test "cloneIfAbsent: a failed clone leaves a shared owner directory holding another clone in place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const owner_dir = try std.fs.path.join(arena, &.{ root, "127.0.0.1", "acme" });
    const sibling_clone = try std.fs.path.join(arena, &.{ owner_dir, "other" });
    try fsutil.ensureDir(sibling_clone);

    const url = "https://127.0.0.1/acme/widget";
    const override = try testutil.gitUnreachable(arena, root, &.{url});
    defer override.restore();
    const clone_path = try std.fs.path.join(arena, &.{ owner_dir, "widget" });

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: app.Ctx = .{ .alloc = arena, .io = testing.io, .context = null, .out = &out.writer, .err = &err_w.writer };

    try testing.expectError(error.GitCloneFailed, cloneIfAbsent(&ctx, url, clone_path));

    try testing.expect(fsutil.exists(owner_dir));
    try testing.expect(fsutil.exists(sibling_clone));

    const host_dir = try std.fs.path.join(arena, &.{ root, "127.0.0.1" });
    try testing.expect(fsutil.exists(host_dir));
}
