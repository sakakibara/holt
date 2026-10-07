//! `holt unkeep`: stops keeping paths of a clone. Each path is released:
//! its link becomes a regular copy of the kept content, on this machine now
//! and on every other at its next reconcile, and the kept content stays
//! until `--purge` removes it into an aside entry. `--repo` releases every
//! path of a repo no longer used. An entry directly at a project's hub root
//! moves from the project's synced content into its `docs/`.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const app = @import("../app.zig");
const ui = @import("../ui.zig");
const fsutil = @import("../fsutil.zig");
const marker = @import("../marker.zig");
const project_mod = @import("../project.zig");
const projectlock = @import("../projectlock.zig");
const hub_mod = @import("../hub.zig");
const kept = @import("../kept.zig");
const util = @import("kept_util.zig");
const sync = @import("sync.zig");
const testutil = @import("../testutil.zig");
const testing = std.testing;

const Spec = struct {
    purge: cli.Opt([]const u8, .{ .value_name = "path", .complete = app.cat(.released_path), .help = "remove the kept content of the released <path> from the kept store; it stays in an aside entry (needs --yes)" }),
    repo: cli.Opt([]const u8, .{ .value_name = "key", .complete = app.cat(.kept_key), .help = "release every kept path of the repo filed under <key>" }),
    yes: cli.Flag(.{ .short = 'y', .help = "with --purge: purge, though another machine may still link the path" }),
    paths: cli.Rest(.{ .complete = app.cat(.kept_path), .help = "the kept paths to release" }),
};

pub const command = app.command(Spec, .{
    .name = "unkeep",
    .summary = "Stop keeping files: a clone's become regular copies, a hub root's entries move into docs",
    .usage = "holt unkeep <path>... | --purge <path> [--yes] | --repo <key>",
    .group = .create,
    .needs_context = true,
    .exclusive = &.{.{ .any_of = &.{ "purge", "repo" }, .why = "each is a mode of its own" }},
    .requires = &.{.{ .field = "yes", .all_of = &.{"purge"} }},
    .details =
    \\A released path's link becomes a regular copy of its kept content, on
    \\this machine now and on every other at its next "holt sync". The kept
    \\content stays in the kept store until "holt unkeep --purge <path>
    \\--yes" removes it, and even then it stays in an aside entry under
    \\kept/.holt-aside/. Without --yes, --purge lists the machines that kept
    \\the path; when another machine did, purge once each has run "holt
    \\sync", since a machine that has not still links the kept content and
    \\gets its copy back from the aside entry only while that entry is kept.
    \\
    \\An entry directly at a project's hub root, which holt keep moved into
    \\the project's synced content, moves into the content's docs/ and is
    \\linked from the hub through docs. Any top-level content entry but the
    \\project's layout (code, docs, assets, links, and the marker) can be
    \\unkept this way, one placed in the cloud folder by hand included.
    \\--purge has nothing to remove for one.
    ,
}, run);

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    if (a.repo != null and a.paths.len > 0) return app.usageError(ctx, "--repo takes no path", .{});
    if (a.purge != null and a.paths.len > 0) return app.usageError(ctx, "--purge takes one path", .{});
    if (a.repo == null and a.purge == null and a.paths.len == 0) return app.usageError(ctx, "unkeep needs a <path>, or --repo <key>", .{});
    if (try util.refuseElsewhere(ctx)) return 1;
    if (a.repo) |key| return releaseRepo(ctx, key);
    if (a.purge) |p| return purge(ctx, p, a.yes);
    var failed = false;
    for (a.paths) |p| {
        if (!try unkeepOne(ctx, p)) failed = true;
    }
    return if (failed) 1 else 0;
}

fn unkeepOne(ctx: *app.Ctx, raw: []const u8) !bool {
    const alloc = ctx.alloc;
    const r = switch (try util.locate(ctx, raw, "unkeep")) {
        .refused => return false,
        .hub => |h| return unkeepHub(ctx, h.project, h.abs),
        .repo => |r| r,
    };
    const k = try util.keptCtx(ctx);
    var index = try kept.store.loadIndex(alloc, k.layout);

    var skip_line: ?[]const u8 = null;
    if (autoMatches(ctx, k, &index, r.c, r.rel)) |matched| {
        if (matched) skip_line = try kept.patterns.anchoredLine(alloc, r.rel);
    } else |err| {
        try util.refuse(ctx, "unkeep", r.abs, err);
        return false;
    }

    var inside: []const u8 = "";
    const got = kept.ops.unkeep(k, &index, r.c.worktree, r.rel, .{ .skip_line = skip_line, .inside = &inside }) catch |err| {
        switch (err) {
            error.InsideKeptDir => {
                const dir = try fsutil.joinSlashy(alloc, r.c.worktree, inside);
                try ctx.err.print("holt: cannot unkeep {s}: it is inside the kept directory {s} (run: holt unkeep {s})\n", .{ try util.show(ctx, r.abs), try util.show(ctx, dir), try util.q(ctx, dir) });
            },
            error.KeptElsewhere => try util.refuseNotArrived(ctx, k, r.c, r.rel, "unkeep", r.abs, try std.fmt.allocPrint(alloc, "holt unkeep {s}", .{try util.q(ctx, r.abs)})),
            else => try util.refuse(ctx, "unkeep", r.abs, err),
        }
        return false;
    };
    if (got.skip_file) |f| try ctx.out.print("added '{s}' to {s}\n", .{ skip_line.?, try util.show(ctx, f) });
    switch (got.status) {
        .gone => {
            try ctx.out.print("the kept copy of {s} was already gone: removed {s}\n", .{ try util.show(ctx, r.abs), if (got.link_removed) "its link and its record" else "its record" });
            return true;
        },
        .already_released => try ctx.out.print("already released: {s}\n", .{try util.show(ctx, r.abs)}),
        .released => {},
    }
    return !try util.reconcileAndShow(ctx, k, r.c.worktree, &.{r.rel});
}

/// Test seam: a path `unkeepHub` removes between its checks and taking
/// the project lock, as another machine's change arriving then would.
pub var remove_before_lock_for_test: ?[]const u8 = null;

/// Hub unkeep: moves the entry `abs` at `p`'s hub root, kept in the
/// project's synced content, into the content's `docs/`, then reconciles
/// the hub. Any top-level content entry but the layout's own qualifies,
/// whether its hub link is there or not yet made.
fn unkeepHub(ctx: *app.Ctx, p: project_mod.Project, abs: []const u8) !bool {
    const alloc = ctx.alloc;
    const shown = try util.show(ctx, abs);
    const raw_base = std.fs.path.basename(abs);
    const base = try contentSpelling(alloc, p.content_path, raw_base) orelse raw_base;
    if (isLayout(raw_base) or isLayout(base)) {
        try ctx.err.print("holt: cannot unkeep {s}: it is part of the project's layout\n", .{shown});
        return false;
    }
    const src = try std.fs.path.join(alloc, &.{ p.content_path, base });
    const linked = fsutil.exists(src) and switch (try fsutil.linkState(alloc, abs)) {
        .missing => true,
        .symlink => |t| try fsutil.targetsEqual(alloc, t, src),
        .other => false,
    };
    if (!linked) {
        try ctx.err.print("holt: cannot unkeep {s}: it is not kept (holt keep moves a hub-root entry into the project's synced content)\n", .{shown});
        return false;
    }

    if (builtin.is_test) if (remove_before_lock_for_test) |gone| try fsutil.removePath(gone);
    var lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
    defer lock.release();

    if (!fsutil.exists(src)) {
        try ctx.err.print("holt: cannot unkeep {s}: it is no longer in the project's synced content\n", .{shown});
        return false;
    }
    const docs = try std.fs.path.join(alloc, &.{ p.content_path, "docs" });
    const dest = try std.fs.path.join(alloc, &.{ docs, base });
    if (try fsutil.linkState(alloc, dest) != .missing or fsutil.hasIcloudPlaceholder(alloc, dest)) {
        try ctx.err.print("holt: cannot unkeep {s}: docs already has {s}; refusing to overwrite\n", .{ shown, try ui.printable(alloc, base) });
        return false;
    }
    try fsutil.ensureDir(docs);
    try fsutil.moveTree(alloc, src, dest);
    const report = try hub_mod.reconcile(alloc, &ctx.context.?.ws, &p, false);
    try ctx.out.print("moved {s} into the project's docs: {s}\n", .{ try ui.printable(alloc, base), try util.show(ctx, dest) });
    try sync.printConflicts(ctx, report.conflicts);
    return report.conflicts.len == 0;
}

fn isLayout(name: []const u8) bool {
    if (std.mem.eql(u8, name, "code") or std.mem.eql(u8, name, marker.marker_basename)) return true;
    for (project_mod.content_dirs) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

/// The name the content directory `dir` spells its entry `name` with:
/// `name` itself, or the entry that is the object `<dir>/<name>` resolves
/// to (`content.knownSameFile`); null when nothing is there.
fn contentSpelling(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !?[]const u8 {
    const typed = try std.fs.path.join(alloc, &.{ dir, name });
    if (try kept.content.entryAt(typed) == .absent) return null;
    var d = std.Io.Dir.openDirAbsolute(fsutil.io(), dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer d.close(fsutil.io());
    var it = d.iterate();
    while (try it.next(fsutil.io())) |e| {
        if (std.mem.eql(u8, e.name, name)) return try alloc.dupe(u8, e.name);
    }
    it = d.iterate();
    while (try it.next(fsutil.io())) |e| {
        if (try kept.content.knownSameFile(alloc, typed, try std.fs.path.join(alloc, &.{ dir, e.name }))) return try alloc.dupe(u8, e.name);
    }
    return null;
}

/// Whether an auto pattern names the kept path `rel` of `c`, so unkeep
/// must also skip it or the next sync would keep it again.
fn autoMatches(ctx: *app.Ctx, k: kept.Ctx, index: *const kept.store.KeyIndex, c: kept.clone.Clone, rel: []const u8) !bool {
    const alloc = ctx.alloc;
    const own = c.key.?;
    const key = switch (try kept.store.resolve(alloc, k.layout, index, own, try kept.clone.rootCommits(alloc, c.main))) {
        .own, .awaiting_promote => own,
        .successor => |s| s,
    };
    const dir = try kept.content.entryAt(try k.layout.copyPath(alloc, key, rel)) == .dir;
    const got = try kept.patterns.match(k, try kept.patterns.globalText(alloc, k.layout, .auto, null), &.{.{ .path = rel, .dir = dir }});
    return got[0] != null;
}

fn purge(ctx: *app.Ctx, raw: []const u8, yes: bool) !u8 {
    const alloc = ctx.alloc;
    const r = switch (try util.locate(ctx, raw, "purge")) {
        .refused => return 1,
        .hub => |h| {
            try ctx.err.print("holt: cannot purge {s}: hub-root entries are never in the kept store, so there is nothing to purge\n", .{try util.show(ctx, h.abs)});
            return 1;
        },
        .repo => |r| r,
    };
    const k = try util.keptCtx(ctx);
    const index = try kept.store.loadIndex(alloc, k.layout);
    var machines: []const []const u8 = &.{};
    const got = kept.ops.purge(k, &index, r.c.worktree, r.rel, .{ .confirmed = yes, .machines = &machines }) catch |err| {
        switch (err) {
            error.NotConfirmed => {
                try printMachines(ctx, k, machines);
                const others = for (machines) |m| {
                    if (!std.mem.eql(u8, m, k.machine_id)) break true;
                } else false;
                if (others) {
                    try ctx.err.print("holt: not purging {s}: a machine that has not run holt sync since the release still links the kept content, and gets its copy back from the aside entry only while that entry is kept; once each has, run: holt unkeep --purge {s} --yes (the content stays in an aside entry)\n", .{ try util.show(ctx, r.abs), try util.q(ctx, r.abs) });
                } else {
                    try ctx.err.print("holt: not purging {s} without --yes: purging removes its kept content (it stays in an aside entry); run: holt unkeep --purge {s} --yes\n", .{ try util.show(ctx, r.abs), try util.q(ctx, r.abs) });
                }
            },
            error.NotReleased => try ctx.err.print("holt: cannot purge {s}: it is still kept (run: holt unkeep {s} first)\n", .{ try util.show(ctx, r.abs), try util.q(ctx, r.abs) }),
            error.StillLinked => try ctx.err.print("holt: cannot purge {s}: a working tree of the clone still links it (run: holt sync first)\n", .{try util.show(ctx, r.abs)}),
            error.KeptChanged => try ctx.err.print("holt: cannot purge {s}: the kept content changed while it was set aside; nothing was removed\n", .{try util.show(ctx, r.abs)}),
            else => try util.refuse(ctx, "purge", r.abs, err),
        }
        return 1;
    };
    if (got.entry) |e| {
        try ctx.out.print("removed the kept content of {s} from {s}; it is in aside entry {s}\n", .{ try util.show(ctx, r.abs), got.key, e });
    } else try ctx.out.print("no kept content of {s} is here; removed its record\n", .{try util.show(ctx, r.abs)});
    try printMachines(ctx, k, got.machines);
    return 0;
}

fn printMachines(ctx: *app.Ctx, k: kept.Ctx, machines: []const []const u8) !void {
    if (machines.len == 0) return;
    try ctx.out.writeAll("machines that kept it:");
    for (machines, 0..) |m, i| try ctx.out.print("{s} {s}", .{ if (i > 0) "," else "", try util.machineLabel(ctx, k, m) });
    try ctx.out.writeByte('\n');
}

fn releaseRepo(ctx: *app.Ctx, key: []const u8) !u8 {
    const alloc = ctx.alloc;
    const k = try util.keptCtx(ctx);
    const got = kept.ops.unkeepRepo(k, key) catch |err| {
        switch (err) {
            error.NoSuchKey => try ctx.err.print("holt: no kept files are filed under {s}\n", .{key}),
            else => try ctx.err.print("holt: cannot release {s}: {s}\n", .{ key, (try util.reason(ctx, err)) orelse @errorName(err) }),
        }
        return 1;
    };
    for (got) |rel| try ctx.out.print("released {s} of {s}\n", .{ rel, key });
    try ctx.out.print("released {d} kept path{s} of {s}; the kept content stays in {s}\n", .{ got.len, if (got.len == 1) "" else "s", key, try util.show(ctx, try k.layout.keyDir(alloc, key)) });
    const clone_path = try fsutil.joinSlashy(alloc, k.code_root, key);
    if (got.len > 0 and fsutil.exists(try std.fs.path.join(alloc, &.{ clone_path, ".git" }))) {
        if (try util.reconcileAndShow(ctx, k, clone_path, got)) return 1;
    }
    return 0;
}

const Fx = struct {
    arena_state: std.heap.ArenaAllocator,
    sb: testutil.Sandbox,
    ws: @import("../workspace.zig").Workspace,
    clone: []const u8,
    env: testutil.EnvScope,
    orig_cwd: []const u8,

    fn a(f: *Fx) std.mem.Allocator {
        return f.arena_state.allocator();
    }

    fn path(f: *Fx, rel: []const u8) ![]const u8 {
        return fsutil.joinSlashy(f.a(), f.clone, rel);
    }

    fn write(f: *Fx, rel: []const u8, data: []const u8) !void {
        const p = try f.path(rel);
        try fsutil.ensureDir(std.fs.path.dirname(p).?);
        try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = p, .data = data });
    }

    fn keep(f: *Fx, argv: []const []const u8) !testutil.RunResult {
        return testutil.runCmd(f.a(), @import("keep.zig").command.run, f.ws, argv);
    }

    fn run(f: *Fx, argv: []const []const u8) !testutil.RunResult {
        return testutil.runCmd(f.a(), command.run, f.ws, argv);
    }

    fn keptPath(f: *Fx, rel: []const u8) ![]const u8 {
        return fsutil.joinSlashy(f.a(), try std.fs.path.join(f.a(), &.{ f.ws.cfg.synced_root, "kept", "github.com", "acme", "widget" }), rel);
    }

    fn deinit(f: *Fx) void {
        std.process.setCurrentPath(fsutil.io(), f.orig_cwd) catch {};
        testing.allocator.free(f.orig_cwd);
        f.env.restore();
        f.sb.deinit();
        f.arena_state.deinit();
    }
};

fn fixture(f: *Fx) !void {
    f.arena_state = .init(testing.allocator);
    f.sb = try testutil.Sandbox.init(testing.allocator);
    const a = f.a();
    const root = try a.dupe(u8, f.sb.root);
    f.ws = try testutil.testWorkspace(a, root);
    try fsutil.ensureDir(f.ws.cfg.synced_root);
    f.env = try testutil.EnvScope.install(a, &.{
        .{ "XDG_STATE_HOME", try std.fs.path.join(a, &.{ root, "state" }) },
        .{ "HOME", root },
        .{ "USERPROFILE", root },
    });
    f.ws.env = app.envOf_current();
    const bare = try testutil.makeBareRepo(&f.sb, "widget.git");
    defer f.sb.alloc.free(bare);
    const cp = try fsutil.joinSlashy(a, f.ws.cfg.code_root, "github.com/acme/widget");
    try testutil.runGit(&f.sb, null, &.{ "clone", "-q", bare, cp });
    f.clone = try fsutil.realPathOrSelf(a, cp);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try f.path(".gitignore"), .data = ".env\n.clasp.json\nnotes/\n" });
    try testutil.runGit(&f.sb, f.clone, &.{ "add", ".gitignore" });
    try testutil.runGit(&f.sb, f.clone, &.{ "commit", "-q", "-m", "ignore" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    f.orig_cwd = try testing.allocator.dupe(u8, buf[0..try std.process.currentPath(fsutil.io(), &buf)]);
    try std.process.setCurrentPath(fsutil.io(), f.clone);
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) != null) return;
    std.debug.print("expected to find:\n  {s}\nin:\n{s}\n", .{ needle, hay });
    return error.TestUnexpectedResult;
}

test "unkeep: the link becomes a regular copy; an auto-kept path is also skipped; again it is already released" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "x");
    try f.write(".clasp.json", "{}");
    _ = try f.keep(&.{ ".env", ".clasp.json" });

    const got = try f.run(&.{ ".env", ".clasp.json" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, "released ");
    try expectContains(got.out, "added '/.clasp.json' to ");
    try testing.expectEqual(kept.content.Entry.file, try kept.content.entryAt(try f.path(".env")));
    try testing.expectEqualStrings("x", try kept.content.readSmall(f.a(), try f.path(".env")));
    try testing.expectEqualStrings("x", try kept.content.readSmall(f.a(), try f.keptPath(".env")));

    const again = try f.run(&.{".env"});
    try testing.expectEqual(@as(u8, 0), again.code);
    try expectContains(again.out, "already released");
}

test "unkeep: refuses a path inside a kept directory naming it, a path not kept, and a hub entry" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write("notes/a.md", "a");
    try f.write("plain", "p");
    _ = try f.keep(&.{"notes"});

    const inside = try f.run(&.{"notes/a.md"});
    try testing.expectEqual(@as(u8, 1), inside.code);
    try expectContains(inside.err, try std.fmt.allocPrint(a, "(run: holt unkeep {s})", .{try ui.quotePath(a, app.envOf_current(), try f.path("notes"))}));
    const not = try f.run(&.{"plain"});
    try testing.expectEqual(@as(u8, 1), not.code);
    try expectContains(not.err, "it is not kept");

    try testutil.writeMarker(a, try f.ws.projectsRoot(a), "acme", "proj", .empty, .empty);
    const hub = try std.fs.path.join(a, &.{ f.ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(hub);
    const entry = try std.fs.path.join(a, &.{ hub, "x.md" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "x" });
    const hubbed = try f.run(&.{entry});
    try testing.expectEqual(@as(u8, 1), hubbed.code);
    try expectContains(hubbed.err, "it is not kept (holt keep moves a hub-root entry into the project's synced content)");
    try testing.expectEqualStrings("x", try kept.content.readSmall(a, entry));
    try testing.expectEqual(@as(u8, 2), (try f.run(&.{})).code);
}

test "unkeep --purge: refuses a kept path, then removes a released path's kept content into aside" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "x");
    _ = try f.keep(&.{".env"});
    const early = try f.run(&.{ "--purge", ".env", "--yes" });
    try testing.expectEqual(@as(u8, 1), early.code);
    try expectContains(early.err, try std.fmt.allocPrint(f.a(), "run: holt unkeep {s} first", .{try ui.quotePath(f.a(), app.envOf_current(), try f.path(".env"))}));
    _ = try f.run(&.{".env"});
    const asked = try f.run(&.{ "--purge", ".env" });
    try testing.expectEqual(@as(u8, 1), asked.code);
    try expectContains(asked.out, "machines that kept it: ");
    try expectContains(asked.err, try std.fmt.allocPrint(f.a(), "run: holt unkeep --purge {s} --yes", .{try ui.quotePath(f.a(), app.envOf_current(), try f.path(".env"))}));
    try testing.expect(std.mem.indexOf(u8, asked.err, "holt sync") == null);
    try testing.expectEqualStrings("x", try kept.content.readSmall(f.a(), try f.keptPath(".env")));
    const got = try f.run(&.{ "--purge", ".env", "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, "it is in aside entry ");
    try expectContains(got.out, ", this machine)");
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try f.keptPath(".env")));
    try testing.expectEqualStrings("x", try kept.content.readSmall(f.a(), try f.path(".env")));
    try testing.expectEqual(@as(u8, 2), (try f.run(&.{ "--purge", ".env", "b" })).code);
    try testing.expectEqual(@as(u8, 2), (try f.run(&.{ "--yes", ".env" })).code);
}

test "unkeep --repo: releases every kept path of the key and converts its clone's links" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "x");
    try f.write("notes/a", "a");
    _ = try f.keep(&.{ ".env", "notes" });
    const got = try f.run(&.{ "--repo", "github.com/acme/widget" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, "released 2 kept paths of github.com/acme/widget");
    try testing.expectEqual(kept.content.Entry.dir, try kept.content.entryAt(try f.path("notes")));
    const none = try f.run(&.{ "--repo", "github.com/no/such" });
    try testing.expectEqual(@as(u8, 1), none.code);
    try expectContains(none.err, "no kept files are filed under github.com/no/such");
}

test "unkeep: another machine's path whose kept copy has not arrived is refused, and every fact stays" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.keep(&.{".env"});
    const layout: kept.store.Layout = .{ .synced_root = f.ws.cfg.synced_root };
    try kept.store.writeFact(a, layout, "github.com/acme/widget", "000000000000000f", ".clasp.json", .file, "a" ** 64);
    try kept.store.writeHost(a, layout, "000000000000000f", "laptop");

    const got = try f.run(&.{".clasp.json"});
    try testing.expectEqual(@as(u8, 1), got.code);
    const qp = try ui.quotePath(a, app.envOf_current(), try f.path(".clasp.json"));
    try expectContains(got.err, try std.fmt.allocPrint(a, "kept on laptop (machine 000000000000000f), not here yet: waiting is the normal fix, until your cloud client downloads it; if it will never arrive, run holt unkeep {s} on laptop, or, if that machine is gone, retire it here - run: holt unkeep {s}, or holt keep --retire-machine 000000000000000f\n", .{ qp, qp }));
    const ks = try kept.store.loadKeyState(a, layout, "github.com/acme/widget");
    try testing.expectEqual(@as(usize, 1), ks.factsFor(".clasp.json").len);
    try testing.expect(!ks.isReleased(".clasp.json"));
}

test "unkeep: an interrupted take of an aside entry the record does not name names each entry of the path, and taking one settles it" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.keep(&.{".env"});
    const common = try std.fs.path.join(a, &.{ f.clone, ".git" });
    try kept.clone.addPending(a, common, .{ .tree = ".", .rel = ".env", .op = .take_aside, .worktree = f.clone });
    const got = try f.run(&.{".env"});
    try expectContains(got.err, "interrupted while taking an aside entry its record does not name; take the one you meant - run: holt keep --take-aside ");
    try testing.expect(std.mem.indexOf(u8, got.err, "<entry>") == null);
    try testing.expect(std.mem.indexOf(u8, got.err, "--take-local") == null);

    const layout: kept.store.Layout = .{ .synced_root = f.ws.cfg.synced_root };
    const entries = try kept.aside.findEntries(a, layout, "github.com/acme/widget", ".env", null);
    try testing.expect(entries.len > 0);
    const took = try f.keep(&.{ "--take-aside", entries[0] });
    try testing.expectEqual(@as(u8, 0), took.code);
    const synced = try testutil.runCmd(a, @import("sync.zig").command.run, f.ws, &.{});
    try testing.expectEqual(@as(u8, 0), synced.code);
}

test "unkeep --purge: without --yes, names the machines that have not run holt sync only when another machine kept the path" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.keep(&.{".env"});
    _ = try f.run(&.{".env"});
    const layout: kept.store.Layout = .{ .synced_root = f.ws.cfg.synced_root };
    try kept.store.writeFact(a, layout, "github.com/acme/widget", "000000000000000f", ".env", .file, "a" ** 64);
    try kept.store.writeHost(a, layout, "000000000000000f", "laptop");

    const asked = try f.run(&.{ "--purge", ".env" });
    try testing.expectEqual(@as(u8, 1), asked.code);
    try expectContains(asked.out, "000000000000000f (laptop)");
    try expectContains(asked.err, "a machine that has not run holt sync since the release still links the kept content");
    try expectContains(asked.err, try std.fmt.allocPrint(a, "run: holt unkeep --purge {s} --yes", .{try ui.quotePath(a, app.envOf_current(), try f.path(".env"))}));
}

test "unkeep on a retired machine warns once; a kept copy already gone says it removed a link only when one was here" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "x");
    try f.write(".clasp.json", "{}");
    try f.write("notes/a", "a");
    _ = try f.keep(&.{ ".env", ".clasp.json", "notes" });
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{"--retire-machine"})).code);

    const got = try f.run(&.{ ".env", ".clasp.json" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.err, "this machine was retired on "));

    try std.Io.Dir.cwd().deleteTree(fsutil.io(), try f.keptPath("notes"));
    try fsutil.removePath(try f.path("notes"));
    const gone = try f.run(&.{"notes"});
    try testing.expectEqual(@as(u8, 0), gone.code);
    try expectContains(gone.out, "was already gone: removed its record\n");
}

/// The content and hub root of a new project `acme/proj`.
const HubFx = struct { content: []const u8, hub: []const u8 };

fn hubFixture(f: *Fx) !HubFx {
    const a = f.a();
    try testutil.writeMarker(a, try f.ws.projectsRoot(a), "acme", "proj", .empty, .empty);
    const h: HubFx = .{
        .content = try std.fs.path.join(a, &.{ f.ws.cfg.synced_root, "projects", "acme", "proj" }),
        .hub = try std.fs.path.join(a, &.{ f.ws.cfg.hub_root, "acme", "proj" }),
    };
    try fsutil.ensureDir(h.hub);
    return h;
}

fn reconcileHub(f: *Fx) !void {
    const a = f.a();
    const p = switch (try f.ws.find(a, "acme/proj")) {
        .one => |p| p,
        else => return error.TestUnexpectedResult,
    };
    _ = try hub_mod.reconcile(a, &f.ws, &p, false);
}

test "unkeep: an entry kept at a hub root moves into the project's docs, and the hub links it only through docs" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    try fsutil.ensureDir(try fsutil.joinSlashy(a, h.content, "docs"));
    const entry = try fsutil.joinSlashy(a, h.hub, "notes.md");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "hello\n" });
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);

    const got = try f.run(&.{entry});
    try testing.expectEqual(@as(u8, 0), got.code);
    const moved = try fsutil.joinSlashy(a, h.content, "docs/notes.md");
    try expectContains(got.out, try std.fmt.allocPrint(a, "moved notes.md into the project's docs: {s}\n", .{try fsutil.contractTilde(a, app.envOf_current(), moved)}));
    try testing.expectEqualStrings("hello\n", try kept.content.readSmall(a, moved));
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try fsutil.joinSlashy(a, h.content, "notes.md")));
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(a, entry));
    try reconcileHub(&f);
    try testing.expectEqual(fsutil.LinkState.missing, try fsutil.linkState(a, entry));
    try testing.expectEqualStrings("hello\n", try kept.content.readSmall(a, try fsutil.joinSlashy(a, h.hub, "docs/notes.md")));
}

test "unkeep: a hub entry whose name docs already has is refused, and both stay" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    try fsutil.ensureDir(try fsutil.joinSlashy(a, h.content, "docs"));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, h.content, "docs/notes.md"), .data = "old" });
    const entry = try fsutil.joinSlashy(a, h.hub, "notes.md");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "new" });
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);

    const got = try f.run(&.{entry});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "docs already has notes.md; refusing to overwrite");
    try testing.expectEqualStrings("old", try kept.content.readSmall(a, try fsutil.joinSlashy(a, h.content, "docs/notes.md")));
    try testing.expectEqualStrings("new", try kept.content.readSmall(a, try fsutil.joinSlashy(a, h.content, "notes.md")));
    try testing.expectEqualStrings("new", try kept.content.readSmall(a, entry));
}

test "unkeep: anything at the hub entry's name in docs, a dangling link included, is refused" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    try fsutil.ensureDir(try fsutil.joinSlashy(a, h.content, "docs"));
    const dangling = try fsutil.joinSlashy(a, h.content, "docs/notes.md");
    try kept.content.createLink(try fsutil.joinSlashy(a, h.content, "nowhere"), dangling, .file);
    const entry = try fsutil.joinSlashy(a, h.hub, "notes.md");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "new" });
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);

    const got = try f.run(&.{entry});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "docs already has notes.md; refusing to overwrite");
    try testing.expectEqual(kept.content.Entry.symlink, try kept.content.entryAt(dangling));
    try testing.expectEqualStrings("new", try kept.content.readSmall(a, try fsutil.joinSlashy(a, h.content, "notes.md")));
}

test "unkeep: a hub link to anything but the content entry of its name is not kept" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    try fsutil.ensureDir(try fsutil.joinSlashy(a, h.content, "docs"));
    const in_docs = try fsutil.joinSlashy(a, h.content, "docs/foo");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = in_docs, .data = "docs" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, h.content, "foo"), .data = "content" });
    const entry = try fsutil.joinSlashy(a, h.hub, "foo");
    try kept.content.createLink(in_docs, entry, .file);

    const got = try f.run(&.{entry});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "it is not kept");
    try testing.expectEqualStrings("docs", try kept.content.readSmall(a, in_docs));
    try testing.expectEqualStrings("content", try kept.content.readSmall(a, try fsutil.joinSlashy(a, h.content, "foo")));
}

test "unkeep: a hub entry kept under one Unicode normalization is unkept by another, and moves under the content's spelling" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    const nfd = "caf\u{0065}\u{0301}.md";
    const nfc = "caf\u{00e9}.md";
    const entry = try fsutil.joinSlashy(a, h.hub, nfd);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "accent" });
    {
        var d = try std.Io.Dir.openDirAbsolute(fsutil.io(), h.hub, .{ .iterate = true });
        defer d.close(fsutil.io());
        var it = d.iterate();
        var kept_form = false;
        while (try it.next(fsutil.io())) |e| {
            if (std.mem.eql(u8, e.name, nfd)) kept_form = true;
        }
        if (!kept_form) return error.SkipZigTest;
    }
    if (!fsutil.exists(try fsutil.joinSlashy(a, h.hub, nfc))) return error.SkipZigTest;
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);

    const got = try f.run(&.{try fsutil.joinSlashy(a, h.hub, nfc)});
    try testing.expectEqual(@as(u8, 0), got.code);
    var d = try std.Io.Dir.openDirAbsolute(fsutil.io(), try fsutil.joinSlashy(a, h.content, "docs"), .{ .iterate = true });
    defer d.close(fsutil.io());
    var it = d.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (try it.next(fsutil.io())) |e| try names.append(a, try a.dupe(u8, e.name));
    try testing.expectEqual(@as(usize, 1), names.items.len);
    try testing.expectEqualStrings(nfd, names.items[0]);
    try testing.expectEqualStrings("accent", try kept.content.readSmall(a, try fsutil.joinSlashy(a, h.content, try std.mem.concat(a, u8, &.{ "docs/", nfd }))));
}

test "unkeep: a hub entry is unkept by any name the filesystem resolves to it, and moves under the content's spelling" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    const stored = "stra\u{00df}e.md";
    const typed = "Strasse.md";
    const entry = try fsutil.joinSlashy(a, h.hub, stored);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "eszett" });
    if (!try kept.content.knownSameFile(a, entry, try fsutil.joinSlashy(a, h.hub, typed))) return error.SkipZigTest;
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);

    const got = try f.run(&.{try fsutil.joinSlashy(a, h.hub, typed)});
    try testing.expectEqual(@as(u8, 0), got.code);
    var d = try std.Io.Dir.openDirAbsolute(fsutil.io(), try fsutil.joinSlashy(a, h.content, "docs"), .{ .iterate = true });
    defer d.close(fsutil.io());
    var it = d.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (try it.next(fsutil.io())) |e| try names.append(a, try a.dupe(u8, e.name));
    try testing.expectEqual(@as(usize, 1), names.items.len);
    try testing.expectEqualStrings(stored, names.items[0]);
}

test "unkeep: an iCloud placeholder for the hub entry's name in docs is refused" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    try fsutil.ensureDir(try fsutil.joinSlashy(a, h.content, "docs"));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, h.content, "docs/.notes.md.icloud"), .data = "" });
    const entry = try fsutil.joinSlashy(a, h.hub, "notes.md");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "new" });
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);

    const got = try f.run(&.{entry});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "docs already has notes.md; refusing to overwrite");
    try testing.expectEqualStrings("new", try kept.content.readSmall(a, try fsutil.joinSlashy(a, h.content, "notes.md")));
}

test "unkeep: a hub entry gone from the content once the project lock is held is refused" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    const entry = try fsutil.joinSlashy(a, h.hub, "notes.md");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "new" });
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);

    remove_before_lock_for_test = try fsutil.joinSlashy(a, h.content, "notes.md");
    defer remove_before_lock_for_test = null;
    const got = try f.run(&.{entry});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "it is no longer in the project's synced content");
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try fsutil.joinSlashy(a, h.content, "docs/notes.md")));
}

test "unkeep: a hub conflict the reconcile after the move reports is printed after the move, and exits 1" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    const entry = try fsutil.joinSlashy(a, h.hub, "notes.md");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "hello\n" });
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);
    const hub_docs = try fsutil.joinSlashy(a, h.hub, "docs");
    try fsutil.ensureDir(hub_docs);

    const got = try f.run(&.{entry});
    try testing.expectEqual(@as(u8, 1), got.code);
    const moved = try fsutil.joinSlashy(a, h.content, "docs/notes.md");
    try expectContains(got.out, try std.fmt.allocPrint(a, "moved notes.md into the project's docs: {s}\n  conflict: {s}\n", .{ try fsutil.contractTilde(a, app.envOf_current(), moved), try fsutil.contractTilde(a, app.envOf_current(), hub_docs) }));
    try testing.expectEqualStrings("hello\n", try kept.content.readSmall(a, moved));
}

test "unkeep: the names of the project's layout are refused at a hub root" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    for (project_mod.content_dirs) |d| try fsutil.ensureDir(try fsutil.joinSlashy(a, h.content, d));
    try reconcileHub(&f);
    for ([_][]const u8{ "docs", "assets", "links", "code", marker.marker_basename }) |name| {
        const got = try f.run(&.{try fsutil.joinSlashy(a, h.hub, name)});
        try testing.expectEqual(@as(u8, 1), got.code);
        try expectContains(got.err, "it is part of the project's layout");
    }
    for (project_mod.content_dirs) |d| try testing.expectEqual(kept.content.Entry.dir, try kept.content.entryAt(try fsutil.joinSlashy(a, h.content, d)));
    try testing.expect(fsutil.exists(try fsutil.joinSlashy(a, h.content, marker.marker_basename)));
}

test "unkeep: with no docs yet, the entry's move creates docs and the hub links it; a hub link not yet made is no obstacle" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    const entry = try fsutil.joinSlashy(a, h.hub, "notes.md");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "hello\n" });
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);
    try fsutil.removePath(entry);

    const got = try f.run(&.{entry});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("hello\n", try kept.content.readSmall(a, try fsutil.joinSlashy(a, h.content, "docs/notes.md")));
    switch (try fsutil.linkState(a, try fsutil.joinSlashy(a, h.hub, "docs"))) {
        .symlink => |t| try testing.expect(try fsutil.targetsEqual(a, t, try fsutil.joinSlashy(a, h.content, "docs"))),
        else => return error.TestUnexpectedResult,
    }
}

test "unkeep --purge: a hub entry is refused, since the kept store never holds one" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const h = try hubFixture(&f);
    const entry = try fsutil.joinSlashy(a, h.hub, "notes.md");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = entry, .data = "x" });
    try testing.expectEqual(@as(u8, 0), (try f.keep(&.{entry})).code);
    const got = try f.run(&.{ "--purge", entry });
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "hub-root entries are never in the kept store, so there is nothing to purge");
    try testing.expectEqualStrings("x", try kept.content.readSmall(a, try fsutil.joinSlashy(a, h.content, "notes.md")));
}
