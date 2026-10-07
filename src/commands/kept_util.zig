//! What `keep` and `unkeep` share: the kept-store context a command runs
//! against, where a path the user names lives (directly at a project's hub
//! root, inside a clone or linked worktree, or neither), the kept store's
//! first-use confirmation, and the wording of the kept store's refusals.

const std = @import("std");
const app = @import("../app.zig");
const ui = @import("../ui.zig");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const kept = @import("../kept.zig");
const project_mod = @import("../project.zig");
const kept_hints = @import("kept_hints.zig");
const kept_hooks = @import("kept_hooks.zig");

/// The kept-store context of the command's workspace and this machine.
pub fn keptCtx(ctx: *app.Ctx) !kept.Ctx {
    const ws = ctx.context.?.ws;
    const env = app.envOf(ctx);
    return .{
        .alloc = ctx.alloc,
        .env = env,
        .layout = .{ .synced_root = ws.cfg.synced_root },
        .code_root = ws.cfg.code_root,
        .machine_id = try kept.machine.load(ctx.alloc, env),
        .retired_notice = retiredNotice(ctx),
    };
}

/// The run's warning to a retired machine (`kept.RetiredNotice`), printing
/// on this command's error stream.
pub fn retiredNotice(ctx: *app.Ctx) ?*kept.RetiredNotice {
    const n = ctx.context.?.retired_notice orelse return null;
    n.err = ctx.err;
    n.words = kept_hints.retiredWarning;
    return n;
}

/// `path` as a hint names it: tilde-contracted and quoted for a shell.
pub fn q(ctx: *app.Ctx, path: []const u8) ![]const u8 {
    return ui.quotePath(ctx.alloc, app.envOf(ctx), path);
}

/// `path` as a line the user reads names it: tilde-contracted, each
/// control character shown as `\xHH` (`ui.printable`).
pub fn show(ctx: *app.Ctx, path: []const u8) ![]const u8 {
    return ui.printable(ctx.alloc, try app.tilde(ctx, path));
}

/// What a line says in place of a command for a file not kept whose name
/// holds a control character, which neither a pasted command nor a keep
/// can name: a review on a terminal can still skip it.
pub const control_words = "the name holds a control character: rename it, or skip it (holt keep --review)";

/// `control_words` for a name holding a line break, which no skip pattern
/// can name either.
pub const line_break_words = "the name holds a line break, which neither a keep nor a skip pattern can name: rename it";

/// What a hint says in place of its commands for a path holding a control
/// character, which no pasted command can name.
pub const control_hint_words = "the name holds a control character, which no pasted command can name: rename it";

/// What a line says for the file not kept at `path`, whose name holds a
/// control character.
pub fn controlWords(path: []const u8) []const u8 {
    return if (std.mem.indexOfAny(u8, path, "\n\r") != null) line_break_words else control_words;
}

/// Whether `s` holds a control character.
pub fn hasControl(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

/// Where a path the user named lives.
pub const Where = union(enum) {
    /// Directly at a project's hub root.
    hub: struct { project: project_mod.Project, abs: []const u8 },
    /// Inside a clone or linked worktree whose clone is under `code_root`:
    /// the path's `/`-joined place under the working tree's top.
    repo: struct { c: kept.clone.Clone, rel: []const u8, abs: []const u8 },
    /// Neither; the reason is printed.
    refused,
};

fn toSlash(alloc: std.mem.Allocator, native: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, native);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, out, std.fs.path.sep, '/');
    return out;
}

/// The project whose hub root is `dir` (a real path), if any.
fn hubAt(ctx: *app.Ctx, dir: []const u8) !?project_mod.Project {
    const a = ctx.alloc;
    const ws = ctx.context.?.ws;
    const hub_real = try fsutil.realPathOrSelf(a, ws.cfg.hub_root);
    if (!fsutil.pathIsInside(dir, hub_real) or dir.len == hub_real.len) return null;
    var parts = std.mem.splitScalar(u8, dir[hub_real.len + 1 ..], std.fs.path.sep);
    const org = parts.next() orelse return null;
    const name = parts.next() orelse return null;
    if (parts.next() != null or org.len == 0 or name.len == 0) return null;
    return switch (try ws.find(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ org, name }))) {
        .one => |p| if (std.mem.eql(u8, try fsutil.realPathOrSelf(a, p.hub_path), dir)) p else null,
        else => null,
    };
}

/// Where `raw` lives, judged by its parent directory alone, the way hub
/// keep always has: the path itself is never followed, so a link at it is
/// judged as a link. A parent directly at a project's hub root is hub
/// mode; one inside a clone or linked worktree is repo mode. The path's
/// place in the working tree is taken as the path spells it below the
/// nearest directory above it holding `.git`, when that is the working
/// tree git finds from the parent (so a symlinked component inside the
/// working tree is seen as one) or the parent lies in the kept store
/// (through a kept directory's link); otherwise from the parent's real
/// location. A parent elsewhere in the synced folder or the hub tree is
/// refused. A clone that is a
/// submodule, lies inside another repository under `code_root`, has no key
/// under `code_root`, or has its files elsewhere is refused with the
/// reason, as is anything else. `verb` names the command in the reasons.
pub fn locate(ctx: *app.Ctx, raw: []const u8, verb: []const u8) !Where {
    const a = ctx.alloc;
    const ws = ctx.context.?.ws;
    const abs = try fsutil.toAbsolute(a, raw);
    const parent = std.fs.path.dirname(abs) orelse {
        try ctx.err.print("holt: cannot {s} {s}: not a file or directory inside a clone or a hub root\n", .{ verb, abs });
        return .refused;
    };
    const parent_real = try fsutil.realPathOrSelf(a, parent);
    if (try hubAt(ctx, parent_real)) |p| return .{ .hub = .{ .project = p, .abs = abs } };

    const top = try kept.clone.enclosing(a, parent);
    const kept_real = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ ws.cfg.synced_root, "kept" }));
    const into_kept = top != null and fsutil.pathIsInside(parent_real, kept_real);
    if (!into_kept and (fsutil.pathIsInside(parent_real, try fsutil.realPathOrSelf(a, ws.cfg.synced_root)) or fsutil.pathIsInside(parent_real, try fsutil.realPathOrSelf(a, ws.cfg.hub_root)))) {
        try refuseOutside(ctx, abs, parent_real, verb);
        return .refused;
    }
    const real_top = if (into_kept) top else try kept.clone.enclosing(a, parent_real);
    const c = kept.clone.inspect(a, real_top orelse parent_real, ws.cfg.code_root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try refuseOutside(ctx, abs, parent_real, verb);
            return .refused;
        },
    };
    const rel: []const u8 = blk: {
        if (top) |t| if (std.mem.eql(u8, try fsutil.realPathOrSelf(a, t), c.worktree)) break :blk try toSlash(a, abs[t.len + 1 ..]);
        if (!fsutil.pathIsInside(parent_real, c.worktree)) {
            try refuseOutside(ctx, abs, parent_real, verb);
            return .refused;
        }
        const base = std.fs.path.basename(abs);
        if (parent_real.len == c.worktree.len) break :blk try toSlash(a, base);
        break :blk try toSlash(a, try std.fs.path.join(a, &.{ parent_real[c.worktree.len + 1 ..], base }));
    };

    const sup = try git.runInRepoScoped(a, &.{ "rev-parse", "--show-superproject-working-tree" }, c.worktree);
    if (sup.status == 0 and std.mem.trim(u8, sup.stdout, " \t\r\n").len > 0) {
        try ctx.err.print("holt: cannot {s} {s}: it is inside the submodule {s}, whose files cannot be kept (skip them with: holt keep --review {s})\n", .{ verb, try show(ctx, abs), try show(ctx, c.worktree), try q(ctx, try fsutil.realPathOrSelf(a, std.mem.trim(u8, sup.stdout, " \t\r\n"))) });
        return .refused;
    }
    const code_real = try fsutil.realPathOrSelf(a, ws.cfg.code_root);
    var up: ?[]const u8 = std.fs.path.dirname(c.main);
    while (up) |d| : (up = std.fs.path.dirname(d)) {
        if (!fsutil.pathIsInside(d, code_real) or d.len == code_real.len) break;
        if (try kept.content.entryAt(try std.fs.path.join(a, &.{ d, ".git" })) != .absent) {
            try ctx.err.print("holt: cannot {s} {s}: it is inside the nested repository {s} of {s}\n", .{ verb, try show(ctx, abs), try show(ctx, c.main), try show(ctx, d) });
            return .refused;
        }
    }
    if (c.key == null) {
        if (c.worktreeElsewhere()) {
            try ctx.err.print("holt: cannot {s} {s}: git finds the files of {s} in {s} (core.worktree); kept files need the working tree beside its .git\n", .{ verb, try show(ctx, abs), try show(ctx, c.main), try show(ctx, c.main_toplevel) });
        } else if (std.mem.eql(u8, try show(ctx, c.main), "~") or fsutil.pathIsInside(code_real, c.main)) {
            try ctx.err.print("holt: cannot {s} {s}: it is not inside a clone under code_root {s}; the repository around it, {s}, is not a clone holt keeps files of\n", .{ verb, try show(ctx, abs), try show(ctx, ws.cfg.code_root), try show(ctx, c.main) });
        } else {
            try ctx.err.print("holt: cannot {s} {s}: the clone {s} is not under code_root {s} (hint: holt repo adopt {s})\n", .{ verb, try show(ctx, abs), try show(ctx, c.main), try show(ctx, ws.cfg.code_root), try q(ctx, c.main) });
        }
        return .refused;
    }
    return .{ .repo = .{ .c = c, .rel = rel, .abs = abs } };
}

fn refuseOutside(ctx: *app.Ctx, abs: []const u8, parent_real: []const u8, verb: []const u8) !void {
    const ws = ctx.context.?.ws;
    const a = ctx.alloc;
    const hub_real = try fsutil.realPathOrSelf(a, ws.cfg.hub_root);
    const synced_real = try fsutil.realPathOrSelf(a, ws.cfg.synced_root);
    const why = if (fsutil.pathIsInside(parent_real, synced_real))
        "it is already in the synced folder"
    else if (fsutil.pathIsInside(parent_real, hub_real))
        "a hub entry can be kept only directly at the project's hub root"
    else
        "it is neither inside a clone or linked worktree nor directly at a project's hub root";
    try ctx.err.print("holt: cannot {s} {s}: {s}\n", .{ verb, try show(ctx, abs), why });
}

/// The synced root holt's links point into when `kept/` is absent here
/// and a clone's working tree links into another synced root's `kept/`
/// (`kept_hooks.Store.elsewhere`): the backend was switched without
/// copying it. Null otherwise.
pub fn keptElsewhere(ctx: *app.Ctx) !?[]const u8 {
    const ws = ctx.context.?.ws;
    const a = ctx.alloc;
    if (try kept.content.entryAt(try std.fs.path.join(a, &.{ ws.cfg.synced_root, "kept" })) != .absent) return null;
    return switch (try kept_hooks.storeState(ctx, try ws.listClones(a))) {
        .elsewhere => |root| root,
        else => null,
    };
}

/// Refuses, naming where `kept/` is and where to copy it, when the
/// backend was switched without copying it (`keptElsewhere`); returns
/// whether it refused.
pub fn refuseElsewhere(ctx: *app.Ctx) !bool {
    const root = (try keptElsewhere(ctx)) orelse return false;
    try ctx.err.print("holt: {s}", .{try kept_hooks.elsewhereLine(ctx, root)});
    return true;
}

/// Whether creating `kept/` asks first (`ensureStore`): it is absent and
/// the synced root holds projects, so a keep without a terminal needs
/// `--yes`.
pub fn storeNeedsYes(ctx: *app.Ctx, k: kept.Ctx) !bool {
    if (try kept.content.entryAt(try k.layout.keptDir(ctx.alloc)) != .absent) return false;
    return (try ctx.context.?.ws.list(ctx.alloc)).len > 0;
}

/// Creates `kept/` when absent, as the first write of kept files does.
/// When the synced root already holds projects, another machine may keep
/// files the backend has not downloaded yet, so creating it asks first;
/// `yes` answers, and without a terminal and without `yes` it refuses and
/// names `retry`, the command to run once the backend is done. Returns
/// whether `kept/` is there to write to.
pub fn ensureStore(ctx: *app.Ctx, k: kept.Ctx, yes: bool, retry: []const u8) !bool {
    const a = ctx.alloc;
    const ws = ctx.context.?.ws;
    const kept_dir = try k.layout.keptDir(a);
    if (try kept.content.entryAt(kept_dir) != .absent) return true;
    if ((try ws.list(a)).len > 0 and !yes) {
        const backend = backendName(ctx);
        if (!ui.stdinIsTerminal()) {
            try ctx.err.print("holt: no kept/ found in {s}: if another machine keeps files, wait for {s} to finish downloading; then, to create a new kept store, run: {s}\n", .{ try show(ctx, ws.cfg.synced_root), backend, retry });
            return false;
        }
        const msg = try std.fmt.allocPrint(a, "No kept/ found; if another machine keeps files, wait for {s} to finish downloading. Create a new kept store?", .{backend});
        if (!try ui.confirm(ctx.out, msg)) {
            try ctx.out.writeAll("no kept store created\n");
            return false;
        }
    }
    _ = kept.patterns.createStore(a, k.layout) catch |err| switch (err) {
        error.SyncedRootMissing => {
            try ctx.err.print("holt: the synced folder {s} does not exist; kept files need it\n", .{try show(ctx, ws.cfg.synced_root)});
            return false;
        },
        else => return err,
    };
    try ctx.out.print("created the kept store {s}\n", .{try show(ctx, kept_dir)});
    return true;
}

/// The backend the synced root is on, as lines name it.
pub fn backendName(ctx: *app.Ctx) []const u8 {
    return ctx.context.?.ws.cfg.backend orelse "your cloud client";
}

/// Prints why `verb` refused `abs`, the path `rel` of the clone `c`, with
/// `KeptElsewhere`: which machine's content has not arrived, and the ways
/// out (`kept_hints.notArrived`), `retry` among them.
pub fn refuseNotArrived(ctx: *app.Ctx, k: kept.Ctx, c: kept.clone.Clone, rel: []const u8, verb: []const u8, abs: []const u8, retry: []const u8) !void {
    const a = ctx.alloc;
    const fact: ?kept.store.Fact = blk: {
        const key = c.key orelse break :blk null;
        const ks = kept.store.loadKeyState(a, k.layout, key) catch break :blk null;
        const kc = try k.layout.copyPath(a, key, rel);
        const hash: ?kept.content.Hash = if (try kept.content.entryAt(kc) == .absent) null else kept.content.hashPath(a, kc) catch null;
        break :blk kept.place.awaitedFact(k, key, ks.factsFor(rel), hash) catch null;
    };
    const f = fact orelse {
        try ctx.err.print("holt: cannot {s} {s}: kept on another machine, not here yet; wait for {s} to download it, then run: {s}\n", .{ verb, try show(ctx, abs), backendName(ctx), retry });
        return;
    };
    const h = try kept_hints.notArrived(ctx, f.machine, try q(ctx, abs), retry, null);
    try ctx.err.print("holt: cannot {s} {s}: {s}\n", .{ verb, try show(ctx, abs), try kept_hints.renderDash(a, h) });
}

/// The machine `id` as lines name it: its id and, in parentheses, its host
/// label and `this machine` for this one.
pub fn machineLabel(ctx: *app.Ctx, k: kept.Ctx, id: []const u8) ![]const u8 {
    const host = (kept.store.readHost(ctx.alloc, k.layout, id) catch null) orelse "host unknown";
    const here = if (std.mem.eql(u8, id, k.machine_id)) ", this machine" else "";
    return std.fmt.allocPrint(ctx.alloc, "{s} ({s}{s})", .{ id, try ui.printable(ctx.alloc, host), here });
}

/// Words for a place `place.Hidden` reports as never copied.
pub fn whyWords(why: kept.sweep.Why) []const u8 {
    return switch (why) {
        .nested_repository => "a nested repository",
        .parent_not_dir => "under a parent that is not a real directory",
        .dot_git => "a path with a .git component",
        .not_copyable => "a symlink holt did not make, or a special file",
        .tree_unreadable => "in a working tree that cannot be read",
        .failed => "cannot be set aside",
    };
}

/// Prints what keep or a take found the block hiding in any working tree:
/// each place set aside, with its entry, and each place that could not be.
pub fn printHidden(ctx: *app.Ctx, hidden: []const kept.place.Hidden) !void {
    for (hidden) |h| {
        const at = try h.found.path(ctx.alloc);
        if (h.entry) |e| {
            try ctx.out.print("set aside {s}, which holt's block hides from git: aside entry {s}\n", .{ try show(ctx, at), e });
            for (h.skipped) |sk| try ctx.out.print("  not copied: {s} ({s})\n", .{ sk.path, @tagName(sk.why) });
        } else {
            try ctx.err.print("holt: {s} is hidden from git by holt's block and not copied: {s}{s}{s}\n", .{ try show(ctx, at), whyWords(h.found.why orelse .failed), if (h.found.detail != null) ": " else "", h.found.detail orelse "" });
        }
    }
}

/// Human size: bytes, KiB, MiB, or GiB.
pub fn size(alloc: std.mem.Allocator, n: u64) ![]const u8 {
    const units = [_][]const u8{ "KiB", "MiB", "GiB" };
    if (n < 1024) return std.fmt.allocPrint(alloc, "{d} B", .{n});
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    v /= 1024;
    while (v >= 1024 and i + 1 < units.len) : (i += 1) v /= 1024;
    return std.fmt.allocPrint(alloc, "{d:.1} {s}", .{ v, units[i] });
}

/// The bytes of regular files at `path`, a file or a directory tree, never
/// following a link.
pub fn bytesAt(alloc: std.mem.Allocator, path: []const u8) !u64 {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(fsutil.io(), path, .{ .follow_symlinks = false }) catch return 0;
    if (st.kind == .file) return st.size;
    if (st.kind != .directory) return 0;
    var d = cwd.openDir(fsutil.io(), path, .{ .iterate = true }) catch return 0;
    defer d.close(fsutil.io());
    var walker = try d.walk(alloc);
    defer walker.deinit();
    var total: u64 = 0;
    while (walker.next(fsutil.io()) catch null) |e| {
        if (e.kind != .file) continue;
        const fst = d.statFile(fsutil.io(), e.path, .{ .follow_symlinks = false }) catch continue;
        total += fst.size;
    }
    return total;
}

/// A refusal from the kept store, worded for the user: why `err` stopped a
/// command. Null for an error with no wording of its own, which
/// the caller reports by name.
pub fn reason(ctx: *app.Ctx, err: anyerror) !?[]const u8 {
    const a = ctx.alloc;
    return switch (err) {
        error.GitTooOld => try kept.clone.gitTooOld(a),
        error.CloneStateUnwritable => "the clone's holt state directory (.git/holt) cannot be written",
        error.InvalidPath => "the name is not one a kept path may have (a .holt- name, a .git component, a control character, a backslash, or invalid UTF-8)",
        error.Collision => "it equals another kept path under case folding or Unicode normalization",
        error.GitReadsUnlinked => kept.paths.Invalid.git_reads_unlinked.describe(),
        error.NestedKey => "it would enter or contain the kept files of a nested repo",
        error.Tracked => "git tracks it (on this branch or in the index)",
        error.ParentNotDir => "a parent directory is a symlink or not a directory",
        error.LinkedElsewhere => "it is a holt link to another kept location (run: holt sync)",
        error.FileNotFound => "no such file or directory",
        error.NotRegular => "it is not a regular file or directory, or holds a symlink or special file",
        error.KeptElsewhere => "kept on another machine, not downloaded yet",
        error.NoSymlinkPrivilege => "this machine cannot create symlinks (on Windows, turn on Developer Mode)",
        error.KeySuperseded => "the repo's kept files moved to a later identity (run: holt sync)",
        error.AwaitingPromote => "the clone is awaiting promote: its local repo was promoted on another machine",
        error.WorktreeElsewhere => "git finds the clone's files in another directory (core.worktree)",
        error.NotUnderCodeRoot => "the clone is not under code_root",
        error.RootRequired => "the repo has no commit yet: commit once first",
        error.LocalMismatch => "the clone is a different repo than the one its local/ key was made for",
        error.UnknownRecordVersion => "the kept store's record for the repo has a version this holt does not know (run: holt upgrade)",
        error.KeyDirNotEmpty => "the repo's directory in the kept store holds files but no record",
        error.WorktreeListFailed => "the clone's working trees cannot be read",
        error.TempStranded => "a temporary an interrupted write left beside it cannot be settled (check it with git status)",
        error.GitFailed => "git cannot list the clone's index or HEAD",
        error.MalformedPending => "the clone's record of interrupted writes (.git/holt/pending) cannot be read",
        error.ChangedDuringLink => "it changed while it was being linked; run the command again",
        error.KeptOnlineOnly => "the kept copy is online-only here; download it first",
        error.KeptNotRegular => "the kept copy is not a regular file or directory",
        error.KeptMissing => "the kept copy is not here (deleted elsewhere, or not synced yet)",
        error.NotKept => "it is not kept",
        error.OtherWritePending => "another interrupted write of it is recorded (run: holt sync)",
        error.AsideVerifyFailed => "its aside copy does not verify",
        error.OnlineOnly => "it is online-only here; download it first",
        error.MatcherFailed => "the skip and auto pattern lists cannot be matched",
        error.NotAClone => "not inside a clone",
        error.NestsInKept => "it would lie inside a kept directory, or hold a kept path",
        error.InvalidLine => "its name holds a line break, which no pattern line can hold",
        else => null,
    };
}

/// Prints `holt: cannot <verb> <abs>: <reason>`.
pub fn refuse(ctx: *app.Ctx, verb: []const u8, abs: []const u8, err: anyerror) !void {
    const why = (try reason(ctx, err)) orelse @errorName(err);
    try ctx.err.print("holt: cannot {s} {s}: {s}\n", .{ verb, try show(ctx, abs), why });
}

/// Reconciles the working tree at `worktree` in apply mode and prints what
/// it did at each of `rels`, each place reconcile could not settle with
/// the hint every command gives for it (`kept_hints.forItem`), returning
/// whether any of them is left unsettled.
pub fn reconcileAndShow(ctx: *app.Ctx, k: kept.Ctx, worktree: []const u8, rels: []const []const u8) !bool {
    const alloc = ctx.alloc;
    const index = try kept.store.loadIndex(alloc, k.layout);
    const report = kept.reconcile.reconcile(k, &index, worktree, .apply) catch |err| {
        try ctx.err.print("holt: could not link {s}: {s} (run: holt sync)\n", .{ try show(ctx, worktree), (try reason(ctx, err)) orelse @errorName(err) });
        return true;
    };
    var unsettled = false;
    for (report.items) |item| {
        if (item.worktree != null or !kept.paths.contains(rels, item.rel)) continue;
        const at = try fsutil.joinSlashy(alloc, worktree, item.rel);
        switch (item.outcome) {
            .linked, .relinked, .ok, .retargeted => try ctx.out.print("linked {s}\n", .{try show(ctx, at)}),
            .released_converted => try ctx.out.print("released {s}: it is a regular copy now\n", .{try show(ctx, at)}),
            .released_local => try ctx.out.print("released {s}: the local content there is left alone\n", .{try show(ctx, at)}),
            .temp_settled => {},
            .tracked => try ctx.out.print("not linked: {s} is tracked on this branch\n", .{try show(ctx, at)}),
            else => {
                const h = try kept_hints.forItem(ctx, worktree, report.resolved orelse report.key, k.layout.synced_root, item);
                try ctx.err.print("holt: {s}: {s}\n", .{ try show(ctx, at), try kept_hints.renderDash(alloc, h) });
            },
        }
        if (item.unsettled) unsettled = true;
    }
    return unsettled;
}

/// The working directory.
pub fn cwdPath(alloc: std.mem.Allocator) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return alloc.dupe(u8, buf[0..try std.process.currentPath(fsutil.io(), &buf)]);
}
