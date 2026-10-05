//! How the reporting commands (`status`, `doctor`) stand kept files up: the
//! `kept.Ctx` of a workspace, whether its kept store is set up, where a
//! working tree's links say an earlier store is, and the per-clone findings
//! `status` shows. Nothing here prints or changes content.

const std = @import("std");
const kept = @import("kept.zig");
const workspace = @import("workspace.zig");
const fsutil = @import("fsutil.zig");

const io = fsutil.io;
const store = kept.store;
const reconcile = kept.reconcile;

/// Whether the kept store is set up under the synced root.
pub const Setup = enum {
    /// `kept/` is there.
    present,
    /// `kept/` is absent and the user has not declined kept files.
    absent,
    /// `kept/` is absent and `.holt-kept-off` says the user declined them,
    /// which silences every kept-files hint.
    off,
    /// The synced root itself is not a directory (an unmounted cloud), so
    /// nothing can be said about `kept/`.
    no_synced_root,
};

pub const off_basename = ".holt-kept-off";

pub fn setup(alloc: std.mem.Allocator, synced_root: []const u8) !Setup {
    if (!try fsutil.isDirFollowing(alloc, synced_root)) return .no_synced_root;
    const layout: store.Layout = .{ .synced_root = synced_root };
    if (try kept.content.entryAt(try layout.keptDir(alloc)) != .absent) return .present;
    const off = try std.fs.path.join(alloc, &.{ synced_root, off_basename });
    return if (try kept.content.entryAt(off) == .absent) .absent else .off;
}

/// The context every kept operation of a command runs against, this
/// machine's id loaded (and created on first use).
pub fn ctxFor(alloc: std.mem.Allocator, ws: *const workspace.Workspace) !kept.Ctx {
    return .{
        .alloc = alloc,
        .env = ws.env,
        .layout = .{ .synced_root = ws.cfg.synced_root },
        .code_root = ws.cfg.code_root,
        .machine_id = try kept.machine.load(alloc, ws.env),
    };
}

/// The context `status` and `doctor` judge kept files with, writing nothing
/// in holt's machine-local state: this machine's id as recorded
/// (`machine.peek`), or, before one is recorded, an id for this run alone
/// that is never written; and `scratch` for every file the run hands git.
pub fn reportCtx(alloc: std.mem.Allocator, ws: *const workspace.Workspace, scratch: *kept.RunScratch) !kept.Ctx {
    const recorded = try kept.machine.peek(alloc, ws.env);
    return .{
        .alloc = alloc,
        .env = ws.env,
        .layout = .{ .synced_root = ws.cfg.synced_root },
        .code_root = ws.cfg.code_root,
        .machine_id = recorded orelse try alloc.dupe(u8, &kept.content.randomSuffix()),
        .scratch = scratch,
    };
}

/// The synced root, other than `synced_root`, whose `kept/` a holt link in
/// the working tree at `worktree` points into (a backend switch that left
/// `kept/` behind), or null when no link does. Only the block's paths are
/// looked at, and a clone whose `info/exclude` holds no block costs no git
/// call.
pub fn oldRoot(alloc: std.mem.Allocator, synced_root: []const u8, code_root: []const u8, worktree: []const u8) !?[]const u8 {
    const dot_git = try std.fs.path.join(alloc, &.{ worktree, ".git" });
    switch (try kept.content.entryAt(dot_git)) {
        .dir => {
            const exclude = try std.fs.path.join(alloc, &.{ dot_git, "info", "exclude" });
            const text = kept.content.readSmall(alloc, exclude) catch return null;
            if (std.mem.indexOf(u8, text, kept.block.begin_line) == null) return null;
        },
        .file => {},
        else => return null,
    }
    const c = kept.clone.inspect(alloc, worktree, code_root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    const key = c.key orelse return null;
    const text = kept.content.readSmall(alloc, try kept.block.excludePath(alloc, c.common_dir)) catch return null;
    const rels = if (kept.block.parse(alloc, text)) |p| p.rels else |_| (try kept.block.salvage(alloc, text)).rels;
    for (rels) |rel| {
        const lp = try fsutil.joinSlashy(alloc, c.worktree, rel);
        const raw = (try kept.content.readLink(alloc, lp)) orelse continue;
        const root = kept.link.shapeRoot(alloc, lp, raw, &.{key}, rel) orelse continue;
        if (!kept.link.sameRoot(alloc, root, synced_root) and try kept.store.recordsRoot(alloc, root)) return root;
    }
    return null;
}

const hub_ignore_exact = [_][]const u8{ ".claude", ".DS_Store", ".git" };

/// Before `kept/` exists, the hub-root entries `status` has always hidden:
/// editor leftovers and tool state no one keeps.
fn hubIgnoredBeforeKept(name: []const u8) bool {
    for (hub_ignore_exact) |n| if (std.mem.eql(u8, name, n)) return true;
    if (std.mem.endsWith(u8, name, ".swp")) return true;
    if (std.mem.endsWith(u8, name, "~")) return true;
    if (std.mem.startsWith(u8, name, ".#")) return true;
    return false;
}

/// The loose entries of the hub root at `hub_path`: real (not symlinked)
/// entries other than `code` - what does not sync unless kept. With `kept/`
/// set up (`matcher` given), only `.git` and what the skip patterns every
/// repo shares match (`kept.patterns.hubSkipped`) are left out, so a hub's
/// `.claude/` is offered like any other entry; a matcher that fails leaves
/// out only `.git`. Without it, the entries `status` has always hidden
/// (`hubIgnoredBeforeKept`) are left out. In name order.
pub fn hubLoose(alloc: std.mem.Allocator, hub_path: []const u8, matcher: ?kept.Ctx) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var queries: std.ArrayList(kept.patterns.Query) = .empty;
    var dir = std.Io.Dir.openDirAbsolute(io(), hub_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer dir.close(io());
    var it = dir.iterate();
    while (try it.next(io())) |entry| {
        if (entry.kind == .sym_link) continue;
        if (std.mem.eql(u8, entry.name, "code") or std.mem.eql(u8, entry.name, ".git")) continue;
        if (matcher == null and hubIgnoredBeforeKept(entry.name)) continue;
        const name = try alloc.dupe(u8, entry.name);
        try names.append(alloc, name);
        try queries.append(alloc, .{ .path = name, .dir = entry.kind == .directory });
    }
    std.mem.sort([]const u8, names.items, {}, kept.paths.lessThan);
    std.mem.sort(kept.patterns.Query, queries.items, {}, struct {
        fn lt(_: void, x: kept.patterns.Query, y: kept.patterns.Query) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.lt);
    const m = matcher orelse return names.items;
    if (names.items.len == 0) return names.items;
    const skipped = kept.patterns.hubSkipped(m, queries.items, null) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return names.items,
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (names.items, skipped) |n, s| if (!s) try out.append(alloc, n);
    return out.items;
}

/// A kept path of a working tree that is not linked: not tracked, and not
/// holt's link to its kept copy under the current synced root, or that copy
/// is absent; or a released path purged elsewhere whose holt link, pointing
/// at nothing, is still here. `item` is what reconcile, planning only, reports for it;
/// `stop` why reconcile could not judge it, when it stopped.
pub const NotLinked = struct { rel: []const u8, item: ?reconcile.Item, stop: reconcile.Stop = .none };

/// The kept paths of the working tree `c` that are not linked
/// (`NotLinked`), in path order, leaving out what reconcile reports as
/// information only: a path outside the sparse checkout. Only the store's
/// facts and one `lstat` per kept path are read unless some path is not
/// linked; then git is asked what it tracks, and reconcile plans (writing
/// nothing of the clone's) to say what settles each.
pub fn notLinked(ctx: kept.Ctx, index: *const store.KeyIndex, c: kept.clone.Clone) ![]const NotLinked {
    const a = ctx.alloc;
    const own = c.key orelse return &.{};
    var rk = own;
    if (!store.isLocalKey(own) and index.successorsOf(own).len > 0) {
        rk = switch (try store.resolve(a, ctx.layout, index, own, try kept.clone.rootCommits(a, c.main))) {
            .own, .awaiting_promote => own,
            .successor => |s| s,
        };
    }
    const ks = try store.loadKeyState(a, ctx.layout, rk);
    var loose: std.ArrayList([]const u8) = .empty;
    const roots = try store.syncedRoots(a, ctx.layout);
    for (try ks.keptSet(a)) |rel| {
        if (kept.paths.check(rel) != null) {
            try loose.append(a, rel);
            continue;
        }
        const want = try ctx.layout.copyPath(a, rk, rel);
        const side = try kept.link.classify(a, try fsutil.joinSlashy(a, c.worktree, rel), want, &.{ rk, own }, roots, rel);
        if (side == .right and try kept.content.entryAt(want) != .absent) continue;
        try loose.append(a, rel);
    }
    for (ks.released) |rel| {
        if (ks.factsFor(rel).len > 0 or kept.paths.check(rel) != null) continue;
        if (!try kept.link.parentsReal(a, c.worktree, rel)) continue;
        const lp = try fsutil.joinSlashy(a, c.worktree, rel);
        const raw = (try kept.content.readLink(a, lp)) orelse continue;
        if (!kept.link.isHolt(a, lp, raw, &.{ rk, own }, roots, rel)) continue;
        if (try kept.content.entryAt(try kept.link.resolveTarget(a, lp, raw)) != .absent) continue;
        try loose.append(a, rel);
    }
    if (loose.items.len == 0) return &.{};

    var valid: std.ArrayList([]const u8) = .empty;
    for (loose.items) |rel| if (kept.paths.check(rel) == null) try valid.append(a, rel);
    const how = kept.clone.tracked(a, c.worktree, valid.items) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    const fold = (try kept.clone.folding(a, c, false)).fold;
    var out: std.ArrayList(NotLinked) = .empty;
    for (loose.items) |rel| {
        if (how) |h| {
            for (valid.items, h) |v, t| {
                if (std.mem.eql(u8, v, rel) and try t.isTracked(a, c.worktree, rel, fold)) break;
            } else try out.append(a, .{ .rel = rel, .item = null });
        } else try out.append(a, .{ .rel = rel, .item = null });
    }
    if (out.items.len == 0) return &.{};

    const report = try reconcile.reconcile(ctx, index, c.worktree, .plan);
    var shown: std.ArrayList(NotLinked) = .empty;
    for (out.items) |n| {
        var got = n;
        got.stop = report.stop;
        for (report.items) |i| {
            if (i.worktree != null or !std.mem.eql(u8, i.rel, n.rel)) continue;
            if (got.item == null or (got.item.?.state == null and i.state != null)) got.item = i;
        }
        if (got.item) |i| switch (i.outcome) {
            .outside_sparse, .ok, .tracked => continue,
            else => {},
        };
        try shown.append(a, got);
    }
    return shown.items;
}

const testing = std.testing;
const testutil = @import("testutil.zig");

/// Test support for the commands' kept-file tests: a workspace in the
/// sandbox whose project `acme/proj` lists one clone of a fresh origin,
/// holt's machine-local state and the temporary directory kept inside the
/// sandbox (`tmp`), and, with
/// `with_store`, `kept/` created. `deinit` restores the environment.
pub const TestWorld = struct {
    scope: testutil.EnvScope,
    ws: workspace.Workspace,
    bare: []const u8,
    clone: []const u8,
    hub: []const u8,
    key: []const u8,

    pub const url = "https://holt-test.invalid/acme/widget";

    pub fn init(a: std.mem.Allocator, sb: *testutil.Sandbox, with_store: bool) !TestWorld {
        const tmp = try std.fs.path.join(a, &.{ sb.root, "tmp" });
        try fsutil.ensureDir(tmp);
        const scope = try testutil.EnvScope.install(a, &.{
            .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ sb.root, "state" }) },
            .{ "TMPDIR", tmp },
            .{ "TEMP", tmp },
        });
        errdefer scope.restore();
        const ws = try testutil.testWorkspace(a, sb.root);
        try fsutil.ensureDir(ws.cfg.synced_root);
        var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        try repos.put(a, "widget", url);
        try testutil.writeMarker(a, try ws.projectsRoot(a), "acme", "proj", repos, .empty);
        const bare_owned = try testutil.makeBareRepo(sb, "widget.git");
        defer sb.alloc.free(bare_owned);
        const clone_path = try std.fs.path.join(a, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "widget" });
        try testutil.runGit(sb, null, &.{ "clone", "-q", bare_owned, clone_path });
        const hub = try std.fs.path.join(a, &.{ ws.cfg.hub_root, "acme", "proj" });
        try fsutil.ensureDir(hub);
        if (with_store) _ = try kept.patterns.createStore(a, .{ .synced_root = ws.cfg.synced_root });
        return .{ .scope = scope, .ws = ws, .bare = try a.dupe(u8, bare_owned), .clone = clone_path, .hub = hub, .key = "holt-test.invalid/acme/widget" };
    }

    pub fn deinit(w: *TestWorld) void {
        w.scope.restore();
    }

    pub fn ctx(w: *const TestWorld, a: std.mem.Allocator) !kept.Ctx {
        return ctxFor(a, &w.ws);
    }

    /// Writes `data` at `rel` in the clone, creating parents.
    pub fn write(w: *const TestWorld, a: std.mem.Allocator, rel: []const u8, data: []const u8) ![]const u8 {
        const p = try fsutil.joinSlashy(a, w.clone, rel);
        try fsutil.ensureDir(std.fs.path.dirname(p).?);
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = data });
        return p;
    }

    /// Writes `data` at `rel` in the clone and keeps it.
    pub fn keep(w: *const TestWorld, a: std.mem.Allocator, rel: []const u8, data: []const u8) !void {
        _ = try w.write(a, rel, data);
        const c = try w.ctx(a);
        const index = try store.loadIndex(a, c.layout);
        _ = try kept.place.keepPath(c, &index, w.clone, rel, .{});
    }

    /// The kept copy of `rel`.
    pub fn keptPath(w: *const TestWorld, a: std.mem.Allocator, rel: []const u8) ![]const u8 {
        const layout: store.Layout = .{ .synced_root = w.ws.cfg.synced_root };
        return layout.copyPath(a, w.key, rel);
    }

    /// Purges the kept path `rel` as another machine would: its kept copy
    /// set aside, its released marker marked purged naming that aside
    /// entry, which is returned, its facts removed, and the kept copy gone.
    pub fn purgeElsewhere(w: *const TestWorld, a: std.mem.Allocator, rel: []const u8) ![]const u8 {
        const layout: store.Layout = .{ .synced_root = w.ws.cfg.synced_root };
        const target = try layout.copyPath(a, w.key, rel);
        const e = try kept.aside.setAside(a, layout, "000000000000000f", w.key, rel, target, .purged);
        try store.writePurged(a, layout, w.key, .{ .rel = rel, .entry = e.stamp });
        try store.removeFacts(a, layout, w.key, rel);
        try std.Io.Dir.cwd().deleteTree(io(), target);
        return e.stamp;
    }
};

test "setup: absent, declined, present, and a synced root that is not there" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    try testing.expectEqual(Setup.no_synced_root, try setup(a, try std.fs.path.join(a, &.{ root, "gone" })));
    try testing.expectEqual(Setup.absent, try setup(a, root));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ root, off_basename }), .data = "" });
    try testing.expectEqual(Setup.off, try setup(a, root));
    try fsutil.ensureDir(try std.fs.path.join(a, &.{ root, "kept" }));
    try testing.expectEqual(Setup.present, try setup(a, root));
}

test "oldRoot: a clone with no block costs no git call and names no root" {
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const clone_path = try std.fs.path.join(a, &.{ sb.root, "code", "github.com", "acme", "w" });
    try testutil.seedMinimalGitClone(a, &sb.git_env, clone_path);
    try testing.expect(try oldRoot(a, try std.fs.path.join(a, &.{ sb.root, "synced" }), try std.fs.path.join(a, &.{ sb.root, "code" }), clone_path) == null);
}
