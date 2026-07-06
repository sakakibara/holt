//! Project resolution, org/name parsing, and content-dir filesystem ops
//! shared by every single-project command: `resolveOne` turns a user query
//! into exactly one `Project` (reporting and returning null on no match or
//! ambiguity), `parseOrgName` splits an "<org>/<name>" spec, `moveDir`/
//! `removeContent` wrap a rename/delete with a contextual error message
//! instead of leaking a raw error name to the user, and `moveProject`
//! performs the full mechanical move of a project to a new org/name.

const std = @import("std");
const cli = @import("../cli.zig");
const workspace = @import("../workspace.zig");
const project_mod = @import("../project.zig");
const marker = @import("../marker.zig");
const hub = @import("../hub.zig");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const diagnostic = @import("../diag.zig");
const testutil = @import("../testutil.zig");
const testing = std.testing;

/// Reports why `query` failed to resolve to exactly one project. A `.none`
/// for an "<org>/<name>" query whose marker exists but fails to parse gets a
/// malformed-marker hint pointing at `holt doctor` instead of a bare "no
/// project matches", so a corrupt marker isn't mistaken for no such project.
pub fn reportProjectFailure(ctx: *cli.Ctx, query: []const u8, found: workspace.FindResult) anyerror!u8 {
    switch (found) {
        .none => {
            if (std.mem.indexOfScalar(u8, query, '/')) |slash| {
                const org = query[0..slash];
                const name = query[slash + 1 ..];
                if (try ctx.ws.?.hasMalformedMarker(ctx.alloc, org, name)) {
                    try ctx.err_w.print("holt: {s}/{s} has a malformed marker (run \"holt doctor\")\n", .{ org, name });
                    return 1;
                }
                const content_path = try std.fs.path.join(ctx.alloc, &.{ try ctx.ws.?.projectsRoot(ctx.alloc), org, name });
                if (marker.markerEvicted(ctx.alloc, content_path)) {
                    try ctx.err_w.print("holt: {s}/{s}'s marker is evicted from local storage; open its folder to download it, then retry\n", .{ org, name });
                    return 1;
                }
            }
            try ctx.err_w.print("holt: no project matches \"{s}\"\n", .{query});
        },
        .ambiguous => |cands| {
            try ctx.err_w.print("holt: \"{s}\" is ambiguous between:\n", .{query});
            for (cands) |c| {
                const qualified = try c.qualified(ctx.alloc);
                try ctx.err_w.print("  {s}\n", .{qualified});
            }
        },
        .one => unreachable,
    }
    return 1;
}

/// Resolves `query` against the loaded workspace to exactly one project;
/// null (after reporting why on ctx.err_w) for no match or an ambiguous one.
/// Callers do `(try resolveOne(ctx, query)) orelse return 1`.
pub fn resolveOne(ctx: *cli.Ctx, query: []const u8) !?project_mod.Project {
    const found = try ctx.ws.?.find(ctx.alloc, query);
    switch (found) {
        .one => |p| return p,
        .none, .ambiguous => {
            _ = try reportProjectFailure(ctx, query, found);
            return null;
        },
    }
}

pub const OrgName = struct { org: []const u8, name: []const u8 };

/// Reserved as an ORG only: these are the structural siblings of - or the
/// name of - the projects dir under the synced root, so an org named after
/// one would confuse the on-disk layout.
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
/// both paths and the underlying error to `ctx.err_w` instead of letting a
/// raw error name reach the user via dispatch's catch-all.
pub fn moveDir(ctx: *cli.Ctx, from: []const u8, to: []const u8) !void {
    if (std.fs.path.dirname(to)) |parent| try fsutil.ensureDir(parent);
    std.Io.Dir.renameAbsolute(from, to, fsutil.io()) catch |err| {
        try ctx.err_w.print("holt: failed to move {s} -> {s}: {s}\n", .{ from, to, @errorName(err) });
        return err;
    };
}

/// Moves a clone `from` -> `to`, carrying its sibling `<clone>@worktrees` dir
/// along so a repo's worktrees survive its clone moving to a new identity.
/// Used by the movers that relocate a clone (promote, adopt).
///
/// Worktrees created with relative admin paths (git 2.48+, see git.worktreeAdd)
/// keep working across this move untouched, because the clone-to-worktree
/// layout is preserved. The repair below is only for worktrees git recorded
/// with absolute paths (older git) - a no-op otherwise.
pub fn moveClone(ctx: *cli.Ctx, from: []const u8, to: []const u8) !void {
    try moveDir(ctx, from, to);

    const alloc = ctx.alloc;
    const from_wt = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{from});
    if (!fsutil.exists(from_wt)) return;

    const to_wt = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{to});
    std.Io.Dir.renameAbsolute(from_wt, to_wt, fsutil.io()) catch |err| {
        try ctx.err_w.print("holt: moved clone but could not move its worktrees dir: {s}\n", .{@errorName(err)});
        return;
    };

    // Fallback for absolute-path worktrees (pre-2.48 git); harmless otherwise.
    var leaves: std.ArrayList([]const u8) = .empty;
    try collectWorktreeLeaves(alloc, to_wt, &leaves);
    git.worktreeRepair(alloc, to, leaves.items) catch {};
}

/// Absolute paths of the leaf worktrees under `dir_path` - dirs containing a
/// `.git` entry - without descending into them, so a nested slashy branch is
/// collected at its leaf.
fn collectWorktreeLeaves(alloc: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayList([]const u8)) !void {
    var dir = std.Io.Dir.openDirAbsolute(fsutil.io(), dir_path, .{ .iterate = true }) catch return;
    defer dir.close(fsutil.io());
    var walker = try dir.walkSelectively(alloc);
    defer walker.deinit();
    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind != .directory) continue;
        const full = try std.fs.path.join(alloc, &.{ dir_path, entry.path });
        const dotgit = try std.fs.path.join(alloc, &.{ full, ".git" });
        if (fsutil.exists(dotgit)) {
            try out.append(alloc, full);
        } else {
            try walker.enter(fsutil.io(), entry);
        }
    }
}

/// Clones `url` into `clone_path` if it is not already present, returning
/// whether it actually cloned (false means the directory was already
/// there). On a clone failure, prints git's diagnostic (naming the url and
/// git's own error) to ctx.err_w and returns the error, re-propagating
/// OutOfMemory untouched.
pub fn cloneIfAbsent(ctx: *cli.Ctx, url: []const u8, clone_path: []const u8) !bool {
    if (fsutil.exists(clone_path)) {
        // A clone left half-finished by an interrupted `git clone` has a
        // `.git` but no commits; adopting it binds the project to a broken
        // clone that every later check reads as healthy. Refuse it with an
        // actionable message rather than silently reusing it.
        if (!try git.isCompleteClone(ctx.alloc, clone_path)) {
            try ctx.err_w.print("holt: clone at {s} looks incomplete (an interrupted clone?); remove it and retry\n", .{clone_path});
            return error.IncompleteClone;
        }
        return false;
    }
    var cd: diagnostic.Diagnostic = .{};
    git.clone(ctx.alloc, url, clone_path, &cd) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try ctx.err_w.print("holt: {s}\n", .{cd.message});
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
/// instead of a raw error name.
pub fn removeContent(ctx: *cli.Ctx, path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(fsutil.io(), path) catch |err| {
        try ctx.err_w.print("holt: failed to delete {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// Reports a hub reconcile/removeHub failure that struck after a project's
/// content was already moved: the content sits correctly at its new path and a
/// later `holt sync` rebuilds the hub.
pub fn reportHubFailure(ctx: *cli.Ctx, org: []const u8, name: []const u8, err: anyerror) !void {
    try ctx.err_w.print("holt: {s}/{s} moved, but rebuilding its hub failed: {s}; run \"holt sync\" to rebuild\n", .{ org, name, @errorName(err) });
}

/// Moves a project's content dir to `<projects>/<new_org>/<new_name>`,
/// rewrites its marker to match, and rebuilds its hub at the new location.
/// Purely mechanical: the caller has already refused a colliding
/// destination and obtained any confirmation, and is responsible for
/// pruning the emptied old-org content dir afterward.
pub fn moveProject(ctx: *cli.Ctx, ws: *const workspace.Workspace, p: *const project_mod.Project, new_org: []const u8, new_name: []const u8) !void {
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

    var args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = ws, .args = &args, .out = &out.writer, .err_w = &err_w.writer };

    const found = try ctx.ws.?.find(arena, "acme/gone");
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

    var args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.FileNotFound, moveDir(&ctx, from, to));

    const reported = err_w.written();
    try testing.expect(std.mem.indexOf(u8, reported, "failed to move") != null);
    try testing.expect(std.mem.indexOf(u8, reported, from) != null);
    try testing.expect(std.mem.indexOf(u8, reported, to) != null);
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
    try tmp.dir.setFilePermissions(testing.io, "parent", std.Io.File.Permissions.fromMode(0o555), .{});
    defer tmp.dir.setFilePermissions(testing.io, "parent", std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const target_path = try std.fs.path.join(arena, &.{ root, "parent", "target" });

    var args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.AccessDenied, removeContent(&ctx, target_path));

    const reported = err_w.written();
    try testing.expect(std.mem.indexOf(u8, reported, "failed to delete") != null);
    try testing.expect(std.mem.indexOf(u8, reported, target_path) != null);
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

    var args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &args, .out = &out.writer, .err_w = &err_w.writer };

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

    // Loopback with nothing listening: connection refused immediately, no
    // DNS or network dependency, so the failure is fast and deterministic.
    const url = "git://127.0.0.1:1/acme/widget";
    const clone_path = try std.fs.path.join(arena, &.{ root, "127.0.0.1", "acme", "widget" });

    var args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.GitCloneFailed, cloneIfAbsent(&ctx, url, clone_path));

    const owner_dir = try std.fs.path.join(arena, &.{ root, "127.0.0.1", "acme" });
    const host_dir = try std.fs.path.join(arena, &.{ root, "127.0.0.1" });
    try testing.expect(!fsutil.exists(owner_dir));
    try testing.expect(!fsutil.exists(host_dir));
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

    // Loopback with nothing listening: connection refused immediately, no
    // DNS or network dependency, so the failure is fast and deterministic.
    const url = "git://127.0.0.1:1/acme/widget";
    const clone_path = try std.fs.path.join(arena, &.{ owner_dir, "widget" });

    var args = try cli.Args.init(arena, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(arena);
    defer err_w.deinit();
    var ctx: cli.Ctx = .{ .alloc = arena, .ws = null, .args = &args, .out = &out.writer, .err_w = &err_w.writer };

    try testing.expectError(error.GitCloneFailed, cloneIfAbsent(&ctx, url, clone_path));

    try testing.expect(fsutil.exists(owner_dir));
    try testing.expect(fsutil.exists(sibling_clone));

    const host_dir = try std.fs.path.join(arena, &.{ root, "127.0.0.1" });
    try testing.expect(fsutil.exists(host_dir));
}
