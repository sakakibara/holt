//! `holt keep`: keeps what does not sync. A path directly at a project's hub
//! root moves into the project's synced content with a symlink left behind;
//! a path inside a clone or linked worktree becomes a kept file, linked
//! from the kept store. `--review` walks the candidates, `--take-local`,
//! `--take-kept`, and `--take-aside` settle a kept path whose copies
//! differ, `--prune-aside` removes aside entries, and `--from` copies the
//! kept files of a key a repo left behind.

const std = @import("std");
const cli = @import("cli");
const app = @import("../app.zig");
const ui = @import("../ui.zig");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const project_mod = @import("../project.zig");
const kept = @import("../kept.zig");
const util = @import("kept_util.zig");
const kept_hooks = @import("kept_hooks.zig");
const kept_hints = @import("kept_hints.zig");
const testutil = @import("../testutil.zig");
const testing = std.testing;

const Spec = struct {
    review: cli.Flag(.{ .help = "walk the files not kept in the clone at <path> (default: the working directory's; at a hub root, its entries and member clones), asking what to do with each" }),
    all: cli.Flag(.{ .help = "with --review: every clone and hub root" }),
    take_local: cli.Opt([]const u8, .{ .value_name = "path", .complete = app.cat(.kept_path), .help = "make the local content at <path> the kept copy, then link it" }),
    take_kept: cli.Opt([]const u8, .{ .value_name = "path", .complete = app.cat(.kept_path), .help = "set the local content at <path> aside, then link the kept copy" }),
    take_aside: cli.Opt([]const u8, .{ .value_name = "entry", .complete = app.cat(.aside_entry), .help = "make an aside entry the kept copy of its path" }),
    prune_aside: cli.Flag(.{ .help = "remove the aside entries nothing still needs whose stamp and arrival here are both more than 30 days old, or the entries named (asks unless --yes)" }),
    older_than: cli.Opt(u32, .{ .value_name = "days", .help = "with --prune-aside: only entries older than <days> days" }),
    retire_machine: cli.Flag(.{ .help = "record the machine <machine-id> (default: this one) as retired, so its records so far no longer block keep, --take-local, or unkeep" }),
    unretire_machine: cli.Flag(.{ .help = "remove the retirement of the machine <machine-id> (default: this one), so its records block again" }),
    from: cli.Opt([]const u8, .{ .value_name = "old key", .complete = app.cat(.kept_key), .help = "copy the kept files of a key a renamed or transferred repo left behind into the clone at <path> (default: the working directory's)" }),
    yes: cli.Flag(.{ .short = 'y', .help = "answer yes: keep more than 10 MiB, create the kept store, remove aside entries" }),
    paths: cli.Rest(.{ .complete = app.cat(.keep_arg), .help = "the files or directories to keep, with --retire-machine or --unretire-machine the machine id, or with --prune-aside the aside entries" }),
};

pub const command = app.command(Spec, .{
    .name = "keep",
    .summary = "Keep files that do not sync: hub-root entries and files git does not carry",
    .usage = "holt keep <path>... | --review [<path>] [--all] | --take-local <path> | --take-kept <path> | --take-aside <entry> | --prune-aside [--older-than <days>] [<entry>...] | --from <old key> [<path>] | --retire-machine [<machine-id>] | --unretire-machine [<machine-id>]",
    .group = .create,
    .needs_context = true,
    .exclusive = &.{.{
        .any_of = &.{ "review", "take_local", "take_kept", "take_aside", "prune_aside", "from", "retire_machine", "unretire_machine" },
        .why = "each is a mode of its own",
    }},
    .requires = &.{
        .{ .field = "all", .all_of = &.{"review"} },
        .{ .field = "older_than", .all_of = &.{"prune_aside"} },
    },
    .details =
    \\A path directly at a project's hub root moves into the project's
    \\synced content and a symlink takes its place. A path inside a clone or
    \\linked worktree is kept in <synced_root>/kept/<host>/<owner>/<repo>/
    \\(kept/local/<name>/ for a repo with no remote) and linked from the
    \\clone on every machine; a directory is kept whole, and a file alone.
    \\Anything holt replaces or removes is first copied to an aside entry in
    \\kept/.holt-aside/. A .gitignore, .gitattributes, or .mailmap file, in
    \\any spelling git takes for one, is refused: git reads it only as a
    \\regular file, never through a link. A directory holding one is kept
    \\whole.
    \\
    \\--review asks about each file not kept. For a file in a clone: keep,
    \\keep everywhere, skip, skip everywhere, or quit, or only skip or quit
    \\when its name holds a control character. With --all, first, for a
    \\pattern files in several repos share: keep everywhere, skip everywhere,
    \\review each, or quit. The first prompt, when it is one of these, also
    \\offers never ask again, which turns kept files off. For content holt's
    \\block hides that holt holds nowhere else: take local, take kept, or
    \\quit. For a file inside a submodule, or one keep refuses because git
    \\reads it only as a regular file: skip, skip everywhere, or quit.
    \\For an entry at a hub root: keep, skip everywhere, or quit. A name
    \\holding a line break is left as it is, or at a hub root offered keep
    \\or quit.
    \\
    \\--prune-aside removes the aside entries nothing still needs. It spares
    \\an entry whose stamp or arrival here (its directory's modification
    \\time) is less than 30 days old, one that is not here whole, which may
    \\still be arriving, one an unsettled kept path names, one --take-kept
    \\filled in the last 30 days, and a side of a path two machines kept
    \\with different content, saying why. Naming entries removes those
    \\alone, spared or not, but a side two machines kept and one with no
    \\manifest written in the last day; a named entry a purge names, or
    \\whose manifest says a purge set it aside, needs --yes, since another
    \\machine may still restore from it.
    \\
    \\--retire-machine records a machine that will write no more as retired:
    \\a kept path another machine's record names is taken to be on its way
    \\from that machine, which blocks keep, --take-local, and unkeep until
    \\it arrives, and the records a retired machine had when it was retired
    \\never do. Run it last on a machine being retired, once holt doctor
    \\--retire passes, or name a dead machine's id (holt doctor --retire
    \\lists them) from another. The retirement covers the records the
    \\machine has then; a record it writes later blocks again, and
    \\--unretire-machine undoes it. On a machine with no kept-file records
    \\it says there is nothing to retire.
    \\
    \\Examples:
    \\  holt keep .clasp.json .superpowers
    \\  holt keep --review --all
    \\  holt keep --take-local .env
    ,
}, run);

/// The most `holt keep <path>` keeps without asking.
const ask_above: u64 = kept.candidates.auto_max_bytes;

fn run(ctx: *app.Ctx, a: cli.Args(Spec)) anyerror!u8 {
    const value_mode = a.take_local != null or a.take_kept != null or a.take_aside != null;
    if (value_mode and a.paths.len > 0) return app.usageError(ctx, "--take-local, --take-kept, and --take-aside take no other path", .{});
    if ((a.review or a.from != null) and a.paths.len > 1) return app.usageError(ctx, "{s} takes at most one path", .{if (a.review) "--review" else "--from"});
    if ((a.retire_machine or a.unretire_machine) and a.paths.len > 1) return app.usageError(ctx, "{s} takes at most one machine id", .{if (a.retire_machine) "--retire-machine" else "--unretire-machine"});
    if (!a.review and !value_mode and !a.prune_aside and a.from == null and !a.retire_machine and !a.unretire_machine and a.paths.len == 0) return app.usageError(ctx, "keep needs a <path>, or one of --review, --take-local, --take-kept, --take-aside, --prune-aside, --from", .{});
    if (try util.refuseElsewhere(ctx)) return 1;
    if (a.retire_machine or a.unretire_machine) {
        const id = if (a.paths.len > 0) a.paths[0] else null;
        return if (a.retire_machine) retireMachine(ctx, id) else unretireMachine(ctx, id);
    }
    if (a.review) return review(ctx, a.paths, a.all, a.yes);
    if (a.take_local) |p| return take(ctx, p, .local, null);
    if (a.take_kept) |p| return take(ctx, p, .kept, null);
    if (a.take_aside) |e| return takeAside(ctx, e);
    if (a.prune_aside) return pruneAside(ctx, a.older_than, a.yes, a.paths);
    if (a.from) |old| return from(ctx, old, if (a.paths.len > 0) a.paths[0] else null);

    var failed = false;
    for (a.paths) |p| {
        if (!try keepOne(ctx, p, a.yes)) failed = true;
    }
    return if (failed) 1 else 0;
}

fn keepOne(ctx: *app.Ctx, raw: []const u8, yes: bool) !bool {
    return switch (try util.locate(ctx, raw, "keep")) {
        .refused => false,
        .hub => |h| keepHub(ctx, h.project, h.abs),
        .repo => |r| keepRepo(ctx, r.c, r.rel, r.abs, yes, null),
    };
}

/// Hub keep: moves the loose entry `abs` at `p`'s hub root into the
/// project's synced content and leaves a symlink at the hub root.
fn keepHub(ctx: *app.Ctx, p: project_mod.Project, abs: []const u8) !bool {
    const alloc = ctx.alloc;
    const base = std.fs.path.basename(abs);
    if (std.mem.eql(u8, base, "code") or std.mem.eql(u8, base, marker.marker_basename)) {
        try ctx.err.print("holt: {s} is reserved and cannot be kept\n", .{base});
        return false;
    }
    switch (try fsutil.linkState(alloc, abs)) {
        .missing => {
            try ctx.err.print("holt: no such entry {s}\n", .{try app.tilde(ctx, abs)});
            return false;
        },
        .symlink => {
            try ctx.out.print("already kept: {s}\n", .{base});
            return true;
        },
        .other => {},
    }

    const dest = try std.fs.path.join(alloc, &.{ p.content_path, base });
    if (fsutil.exists(dest)) {
        try ctx.err.print("holt: content already has {s}; refusing to overwrite\n", .{base});
        return false;
    }

    var lock = try projectlock.acquire(alloc, app.envOf(ctx), p.content_path);
    defer lock.release();

    try fsutil.moveTree(alloc, abs, dest);
    const dest_stat = try std.Io.Dir.cwd().statFile(fsutil.io(), dest, .{});
    const result = try fsutil.replaceLink(dest, abs, dest_stat.kind == .directory);

    try ctx.out.print("kept {s} -> content\n", .{base});
    if (result == .skipped_unprivileged) {
        try ctx.err.print("holt: warning: {s} is in content but not surfaced at the hub root (needs Developer Mode for file links); run \"holt sync\" after enabling it\n", .{base});
    }
    return true;
}

/// The key the clone `c`'s files live in, as the store resolves it, or its
/// own key when the store cannot say.
fn resolvedKey(k: kept.Ctx, index: *const kept.store.KeyIndex, c: kept.clone.Clone) ![]const u8 {
    const own = c.key.?;
    const roots = kept.clone.rootCommits(k.alloc, c.main) catch return own;
    return switch (try kept.store.resolve(k.alloc, k.layout, index, own, roots)) {
        .own, .awaiting_promote => own,
        .successor => |s| s,
    };
}

/// A kept directory a path lies inside.
const KeptDir = struct {
    /// Its place in the working tree.
    abs: []const u8,
    /// Whether it is holt's link to its kept copy here, and the kept copy
    /// is there.
    linked: bool,
};

/// The kept directory above `rel` in `c`'s key, if `rel` lies inside one.
fn insideKeptDir(k: kept.Ctx, index: *const kept.store.KeyIndex, c: kept.clone.Clone, rel: []const u8) !?KeptDir {
    const a = k.alloc;
    const key = try resolvedKey(k, index, c);
    const ks = try kept.store.loadKeyState(a, k.layout, key);
    const dir = kept.ops.keptDirAbove(ks, rel) orelse return null;
    const abs = try fsutil.joinSlashy(a, c.worktree, dir);
    const target = try k.layout.copyPath(a, key, dir);
    const right = try kept.link.parentsReal(a, c.worktree, dir) and try kept.link.classify(a, abs, target, &.{key}, try kept.store.syncedRoots(a, k.layout), dir) == .right;
    return .{ .abs = abs, .linked = right and try kept.content.entryAt(target) == .dir };
}

/// Whether keeping `abs`, of `bytes`, may go ahead: at most `ask_above`,
/// `yes`, or a yes on a terminal. Without a terminal it refuses and says
/// so.
fn sizeAllowed(ctx: *app.Ctx, abs: []const u8, bytes: u64, yes: bool) !bool {
    if (bytes <= ask_above or yes) return true;
    const shown = try util.size(ctx.alloc, bytes);
    if (!ui.stdinIsTerminal()) {
        try ctx.err.print("holt: {s} holds {s}, more than 10 MiB; to keep it, run: holt keep --yes {s}\n", .{ try util.show(ctx, abs), shown, try util.q(ctx, abs) });
        return false;
    }
    const msg = try std.fmt.allocPrint(ctx.alloc, "{s} holds {s}, more than 10 MiB. Keep it?", .{ try util.show(ctx, abs), shown });
    if (try ui.confirm(ctx.out, msg)) return true;
    try ctx.out.print("not kept: {s}\n", .{try util.show(ctx, abs)});
    return false;
}

/// Keeps `rel` of the working tree `c`, under the locks the caller holds
/// when `held` is set, reporting a refusal; returns whether it is kept.
fn keepRepo(ctx: *app.Ctx, c: kept.clone.Clone, rel: []const u8, abs: []const u8, yes: bool, held: ?kept.Held) !bool {
    const alloc = ctx.alloc;
    const k = try util.keptCtx(ctx);
    kept.clone.requireGit(alloc) catch |err| {
        try util.refuse(ctx, "keep", abs, err);
        return false;
    };
    var index = try kept.store.loadIndex(alloc, k.layout);
    if (try insideKeptDir(k, &index, c, rel)) |dir| {
        if (dir.linked) {
            try ctx.out.print("already kept: {s} is inside the kept directory {s}\n", .{ try util.show(ctx, abs), try util.show(ctx, dir.abs) });
            return true;
        }
        const qd = try util.q(ctx, dir.abs);
        try ctx.err.print("holt: cannot keep {s}: it is inside the kept directory {s}, which is not linked here (to make what is here the kept copy, run: holt keep --take-local {s}; to link the kept copy instead, run: holt keep --take-kept {s})\n", .{ try util.show(ctx, abs), try util.show(ctx, dir.abs), qd, qd });
        return false;
    }
    if (try kept.content.entryAt(abs) == .absent) {
        try util.refuse(ctx, "keep", abs, error.FileNotFound);
        return false;
    }
    if (!try sizeAllowed(ctx, abs, try util.bytesAt(alloc, abs), yes)) return false;
    if (!try util.ensureStore(ctx, k, yes, try std.fmt.allocPrint(alloc, "holt keep --yes {s}", .{try util.q(ctx, abs)}))) return false;
    index = try kept.store.loadIndex(alloc, k.layout);

    var found: Found = .{};
    const got = kept.place.keepPath(k, &index, c.worktree, rel, .{ .invalid_names = &found.invalid, .would_hide = &found.would_hide, .differs = &found.differs, .negation = &found.negation, .held = held }) catch |err| {
        try reportKeepError(ctx, k, &index, c, rel, abs, err, found);
        return false;
    };
    switch (got.status) {
        .already_kept => try ctx.out.print("already kept: {s}\n", .{try util.show(ctx, abs)}),
        .kept => try ctx.out.print("kept {s} -> {s}\n", .{ try util.show(ctx, abs), try util.show(ctx, try k.layout.copyPath(alloc, c.key.?, rel)) }),
    }
    try printKeepNotes(ctx, got.temp_entry, got.exec_not_kept, got.staging_left, got.hidden, abs);
    return true;
}

fn printKeepNotes(ctx: *app.Ctx, temp_entry: ?[]const u8, exec_not_kept: bool, left: []const kept.place.Left, hidden: []const kept.place.Hidden, abs: []const u8) !void {
    if (temp_entry) |e| try ctx.out.print("an interrupted write's temporary beside {s} is in aside entry {s}\n", .{ try util.show(ctx, abs), e });
    if (exec_not_kept) try ctx.err.print("holt: executable bit not kept: the kept store refused it for {s}\n", .{try util.show(ctx, abs)});
    for (left) |l| try ctx.err.print("holt: staging left in place: {s} ({s})\n", .{ try util.show(ctx, l.slot), l.reason });
    try util.printHidden(ctx, hidden);
}

/// What a refused keep or take names, beside its error.
const Found = struct {
    invalid: []const []const u8 = &.{},
    would_hide: []const kept.place.Hidden = &.{},
    differs: []const []const u8 = &.{},
    negation: kept.clone.Negation = .{ .source = "", .line = "", .pattern = "" },
};

fn reportKeepError(ctx: *app.Ctx, k: kept.Ctx, index: *const kept.store.KeyIndex, c: kept.clone.Clone, rel: []const u8, abs: []const u8, err: anyerror, found: Found) !void {
    const alloc = ctx.alloc;
    const shown = try util.show(ctx, abs);
    const invalid = found.invalid;
    const would_hide = found.would_hide;
    switch (err) {
        error.KeptCopyDiffers => if (found.differs.len > 0) {
            try ctx.err.print("holt: cannot keep {s}: its kept directory holds different content at:\n", .{shown});
            const ks = try kept.store.loadKeyState(alloc, k.layout, try resolvedKey(k, index, c));
            for (found.differs) |d| {
                const at = try fsutil.joinSlashy(alloc, c.worktree, d);
                const settle = if (ks.factsFor(d).len > 0) at else if (ks.factsFor(rel).len > 0) abs else null;
                if (settle) |sp| {
                    try ctx.err.print("  {s} (run: holt keep --take-local {s}, or holt keep --take-kept {s})\n", .{ try util.show(ctx, at), try util.q(ctx, sp), try util.q(ctx, sp) });
                } else try ctx.err.print("  {s}\n", .{try util.show(ctx, at)});
            }
        } else try ctx.err.print("holt: cannot keep {s}: the kept copy holds different content (run: holt keep --take-local {s}, or holt keep --take-kept {s})\n", .{ shown, try util.q(ctx, abs), try util.q(ctx, abs) }),
        error.SymlinkNotHolts => {
            const target = (try kept.content.readLink(alloc, abs)) orelse "?";
            try ctx.err.print("holt: cannot keep {s}: it is a symlink holt did not make (-> {s})\n", .{ shown, target });
        },
        error.InvalidName => {
            try ctx.err.print("holt: cannot keep {s}: it holds names a kept path may not have (a .holt- name, a nested repository's .git, a control character, a backslash, or names equal under case folding or Unicode normalization):\n", .{shown});
            for (invalid) |n| try ctx.err.print("  {s}\n", .{try util.show(ctx, try fsutil.joinSlashy(alloc, abs, n))});
        },
        error.NotRegular => {
            if (try kept.content.entryAt(abs) == .dir) {
                try ctx.err.print("holt: cannot keep {s}: it holds a symlink or special file:\n", .{shown});
                const part = try kept.content.treeFilesPartial(alloc, abs, false, try kept.clone.ignoresCase(alloc, c.worktree));
                for (part.skipped) |sk| try ctx.err.print("  {s} ({s})\n", .{ try util.show(ctx, try fsutil.joinSlashy(alloc, abs, sk.path)), @tagName(sk.why) });
            } else try util.refuse(ctx, "keep", abs, err);
        },
        error.Tracked => {
            if (try kept.content.entryAt(abs) == .dir) {
                try ctx.err.print("holt: cannot keep {s}: git tracks files inside it; name the untracked files instead:\n", .{shown});
                const res = try git.runInRepoScoped(alloc, &.{ "ls-files", "-z", "--others", "--", try std.fmt.allocPrint(alloc, ":(literal){s}/", .{rel}) }, c.worktree);
                var queries: std.ArrayList(kept.patterns.Query) = .empty;
                var it = std.mem.splitScalar(u8, res.stdout, 0);
                while (it.next()) |f| if (f.len > 0) try queries.append(alloc, .{ .path = f });
                const skip_text = try std.mem.concat(alloc, u8, &.{ try kept.patterns.globalText(alloc, k.layout, .skip, null), try kept.patterns.repoSkipText(alloc, k.layout, try resolvedKey(k, index, c), null) });
                const skipped = try kept.patterns.match(k, skip_text, queries.items);
                for (queries.items, skipped) |qq, sk| {
                    if (sk != null) continue;
                    try ctx.err.print("  holt keep {s}\n", .{try util.q(ctx, try fsutil.joinSlashy(alloc, c.worktree, qq.path))});
                }
            } else try util.refuse(ctx, "keep", abs, err);
        },
        error.WouldHide => {
            try ctx.err.print("holt: cannot keep {s}: its line in the clone's exclude block would hide what cannot be set aside:\n", .{shown});
            for (would_hide) |h| {
                const detail = h.found.detail orelse "";
                try ctx.err.print("  {s}: {s}{s}{s}\n", .{ try util.show(ctx, try h.found.path(alloc)), util.whyWords(h.found.why orelse .failed), if (detail.len > 0) ": " else "", detail });
            }
        },
        error.Negated => {
            const h = try kept_hints.negated(ctx, found.negation, abs);
            try ctx.err.print("holt: cannot keep {s}: {s}\n", .{ shown, try kept_hints.render(alloc, h) });
        },
        error.NestedKey => {
            const nk = try kept.store.nestedKeyAt(alloc, index, c.key.?, rel);
            try ctx.err.print("holt: cannot keep {s}: it would {s} the kept files of the nested repo {s}\n", .{ shown, if (nk != null and nk.?.contains) "contain" else "enter", if (nk) |n| n.key else "?" });
        },
        error.AwaitingPromote => try ctx.err.print("holt: cannot keep {s}: the clone is awaiting promote (run: holt repo promote {s})\n", .{ shown, try ui.shellQuote(alloc, std.fs.path.basename(c.key.?)) }),
        error.KeptElsewhere => try util.refuseNotArrived(ctx, k, c, rel, "keep", abs, try std.fmt.allocPrint(alloc, "holt keep {s}", .{try util.q(ctx, abs)})),
        error.GitReadsUnlinked => if (try kept.content.entryAt(abs) == .symlink) {
            try ctx.err.print("holt: cannot keep {s}: {s} (if an older holt kept it, run: holt unkeep {s})\n", .{ shown, (try util.reason(ctx, err)).?, try util.q(ctx, abs) });
        } else try util.refuse(ctx, "keep", abs, err),
        else => try util.refuse(ctx, "keep", abs, err),
    }
}

const Which = enum { local, kept };

fn take(ctx: *app.Ctx, raw: []const u8, which: Which, held: ?kept.Held) !u8 {
    const alloc = ctx.alloc;
    const flag = if (which == .local) "--take-local" else "--take-kept";
    const verb = if (which == .local) "take the local copy of" else "take the kept copy of";
    const r = switch (try util.locate(ctx, raw, verb)) {
        .refused => return 1,
        .hub => |h| {
            try ctx.err.print("holt: cannot {s} {s}: it is at a hub root, kept in synced content with no kept copy to settle\n", .{ verb, try util.show(ctx, h.abs) });
            return 1;
        },
        .repo => |r| r,
    };
    const k = try util.keptCtx(ctx);
    var index = try kept.store.loadIndex(alloc, k.layout);
    var found: Found = .{};
    const opts: kept.ops.TakeOptions = .{ .invalid_names = &found.invalid, .would_hide = &found.would_hide, .held = held };
    const got = (if (which == .local) kept.ops.takeLocal(k, &index, r.c.worktree, r.rel, opts) else kept.ops.takeKept(k, &index, r.c.worktree, r.rel, opts)) catch |err| {
        switch (err) {
            error.NotKept => {
                if (try insideKeptDir(k, &index, r.c, r.rel)) |dir| {
                    try ctx.err.print("holt: cannot {s} {s}: it is inside the kept directory {s} (run: holt keep {s} {s})\n", .{ verb, try util.show(ctx, r.abs), try util.show(ctx, dir.abs), flag, try util.q(ctx, dir.abs) });
                } else {
                    try ctx.err.print("holt: cannot {s} {s}: it is not kept (run: holt keep {s})\n", .{ verb, try util.show(ctx, r.abs), try util.q(ctx, r.abs) });
                }
            },
            error.FileNotFound => try ctx.err.print("holt: cannot {s} {s}: there is no local content there (run: holt sync to link it)\n", .{ verb, try util.show(ctx, r.abs) }),
            error.KeptElsewhere => try util.refuseNotArrived(ctx, k, r.c, r.rel, verb, r.abs, try std.fmt.allocPrint(alloc, "holt keep {s} {s}", .{ flag, try util.q(ctx, r.abs) })),
            else => try reportKeepError(ctx, k, &index, r.c, r.rel, r.abs, err, found),
        }
        return 1;
    };
    switch (got.status) {
        .already_linked => try ctx.out.print("already linked: {s}\n", .{try util.show(ctx, r.abs)}),
        .taken => {
            if (which == .local) {
                try ctx.out.print("took the local copy of {s} as the kept copy, and linked it\n", .{try util.show(ctx, r.abs)});
                if (got.kept_entry) |e| try ctx.out.print("the kept copy it replaced is in aside entry {s}\n", .{e});
            } else {
                try ctx.out.print("linked {s} to its kept copy\n", .{try util.show(ctx, r.abs)});
                if (got.local_entry) |e| try ctx.out.print("the local copy is in aside entry {s}\n", .{e});
            }
        },
    }
    try printKeepNotes(ctx, got.temp_entry, got.exec_not_kept, got.staging_left, got.hidden, r.abs);
    return 0;
}

fn takeAside(ctx: *app.Ctx, stamp: []const u8) !u8 {
    const alloc = ctx.alloc;
    const k = try util.keptCtx(ctx);
    var index = try kept.store.loadIndex(alloc, k.layout);
    const here = try fsutil.realPathOrSelf(alloc, try util.cwdPath(alloc));
    const cwd = (try kept.clone.enclosing(alloc, here)) orelse here;
    const got = kept.ops.takeAside(k, &index, stamp, cwd) catch |err| {
        const why: []const u8 = switch (err) {
            error.NoSuchEntry => "no such aside entry",
            error.AsideUnverified => "its data no longer matches its manifest",
            error.AsideOnlineOnly => "its data is online-only here; download it first",
            error.Unplaceable => "it names a key or path a kept copy may not have",
            error.AsidePartial => "it left out some of what was there, so it is not a whole copy",
            error.AsideStaged => "it holds a version git's index staged, in its index/ (copy it back by hand)",
            error.NotKept => "the repo it names has no kept files here",
            else => (try util.reason(ctx, err)) orelse @errorName(err),
        };
        try ctx.err.print("holt: cannot take aside entry {s}: {s}\n", .{ stamp, why });
        return 1;
    };
    try ctx.out.print("made aside entry {s} the kept copy of {s} in {s}\n", .{ stamp, got.rel, got.key });
    if (got.kept_entry) |e| try ctx.out.print("the kept copy it replaced is in aside entry {s}\n", .{e});
    for (got.staging_left) |l| try ctx.err.print("holt: staging left in place: {s} ({s})\n", .{ try util.show(ctx, l.slot), l.reason });

    const c = kept.clone.inspect(alloc, cwd, k.code_root) catch null;
    if (c) |cl| if (cl.key) |_| {
        if (std.mem.eql(u8, try resolvedKey(k, &index, cl), got.key)) {
            return if (try util.reconcileAndShow(ctx, k, cl.worktree, &.{got.rel})) 1 else 0;
        }
    };
    try ctx.out.print("run holt sync to link it in the clones of {s}\n", .{got.key});
    return 0;
}

/// The aside entries an unsettled kept path of any clone's working tree
/// names, as a plan-mode reconcile reports them; null, after saying which,
/// when a working tree cannot be judged.
fn referencedEntries(ctx: *app.Ctx, index: *const kept.store.KeyIndex) !?kept.ops.Referenced {
    const alloc = ctx.alloc;
    var scratch: kept.RunScratch = undefined;
    const pc = try kept_hooks.planCtx(ctx, &scratch);
    defer scratch.deinit();
    var out: kept.ops.Referenced = .{};
    var ok = true;
    for (try ctx.context.?.ws.listClones(alloc)) |cp| {
        const c = kept.clone.inspect(alloc, cp, pc.code_root) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.NotAClone => continue,
            else => {
                try ctx.err.print("holt: cannot tell which aside entries {s} needs ({s})\n", .{ try util.show(ctx, cp), @errorName(err) });
                ok = false;
                continue;
            },
        };
        const trees = kept.clone.worktrees(alloc, c) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try ctx.err.print("holt: cannot tell which aside entries {s} needs ({s})\n", .{ try util.show(ctx, cp), @errorName(err) });
                ok = false;
                continue;
            },
        };
        for (trees) |t| {
            if (!t.readable()) continue;
            const rep = kept.reconcile.reconcile(pc, index, t.path, .plan) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    try ctx.err.print("holt: cannot tell which aside entries {s} needs ({s})\n", .{ try util.show(ctx, t.path), @errorName(err) });
                    ok = false;
                    continue;
                },
            };
            try kept.ops.unsettledEntries(alloc, rep, &out);
        }
    }
    return if (ok) out else null;
}

/// `--prune-aside`: removes the aside entries `named`, or when none are
/// named every entry older than `kept.ops.young_days` days that no
/// unsettled kept path names and no `--take-kept` of the last
/// `kept.ops.taken_days` days filled (`kept.ops.AsideInfo.held`), only those
/// older than `older_than` days when given. Without `yes` it
/// asks, and refuses without a terminal.
fn pruneAside(ctx: *app.Ctx, older_than: ?u32, yes: bool, named: []const []const u8) !u8 {
    const alloc = ctx.alloc;
    const k = try util.keptCtx(ctx);
    const index = try kept.store.loadIndex(alloc, k.layout);
    const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(fsutil.io()).nanoseconds, std.time.ns_per_ms));
    const referenced = (try referencedEntries(ctx, &index)) orelse if (named.len == 0) {
        try ctx.err.print("holt: nothing removed; name the entries to remove, or settle what cannot be judged first\n", .{});
        return 1;
    } else kept.ops.Referenced{};
    const all = try kept.ops.asideEntries(k, &index, now_ms, &referenced, .verified);
    for (named) |n| {
        for (all) |e| {
            if (std.mem.eql(u8, e.stamp, n)) break;
        } else {
            try ctx.err.print("holt: no aside entry {s}\n", .{n});
            return 1;
        }
    }

    var chosen: std.ArrayList(kept.ops.AsideInfo) = .empty;
    var total: u64 = 0;
    for (all) |e| {
        const is_named = kept.paths.contains(named, e.stamp);
        if (named.len > 0 and !is_named) continue;
        if (older_than) |days| {
            const t = e.time_ms orelse continue;
            if (now_ms - t <= @as(i64, days) * std.time.ms_per_day) continue;
        }
        const anyway = try std.fmt.allocPrint(alloc, "holt keep --prune-aside {s}{s}", .{ try ui.shellQuote(alloc, e.stamp), if (yes or e.purge) " --yes" else "" });
        if (e.held) |why| if (!(is_named and why.yields())) {
            const q_stamp = try ui.shellQuote(alloc, e.stamp);
            try ctx.out.print("kept aside entry {s}: {s}\n", .{ e.stamp, switch (why) {
                .two_machines => try std.fmt.allocPrint(alloc, "it holds one side of a path two machines kept with different content (to keep this side, run: holt keep --take-aside {s})", .{q_stamp}),
                .recent => "it has no readable manifest and may still be being written",
                .unsettled => try std.fmt.allocPrint(alloc, "a kept path not yet settled names it (to remove it anyway, run: {s})", .{anyway}),
                .taken => try std.fmt.allocPrint(alloc, "holt keep --take-kept set content aside into it within the last {d} days (to remove it anyway, run: {s})", .{ kept.ops.taken_days, anyway }),
                .young => try kept_hints.youngAside(alloc, anyway),
                .partial => try std.fmt.allocPrint(alloc, "it is not here whole (its manifest is missing or unreadable, or its content does not match it or cannot be read), so it may still be arriving (to remove it anyway, run: {s})", .{anyway}),
            } });
            continue;
        };
        if (is_named and e.purge and !yes) {
            try ctx.out.print("kept aside entry {s}: a purge set it aside, and another machine may still restore from it (to remove it anyway, run: holt keep --prune-aside {s} --yes)\n", .{ e.stamp, try ui.shellQuote(alloc, e.stamp) });
            continue;
        }
        try chosen.append(alloc, e);
        total += e.bytes;
    }
    if (chosen.items.len == 0) {
        try ctx.out.writeAll("no aside entries to remove\n");
        return 0;
    }
    for (chosen.items) |e| {
        if (e.manifest) |m| {
            try ctx.out.print("  {s}  {s} {s}  {s}\n", .{ e.stamp, m.key, m.rel, try util.size(alloc, e.bytes) });
        } else try ctx.out.print("  {s}  (no manifest)  {s}\n", .{ e.stamp, try util.size(alloc, e.bytes) });
    }
    const summary = try std.fmt.allocPrint(alloc, "{d} aside entr{s} ({s})", .{ chosen.items.len, if (chosen.items.len == 1) "y" else "ies", try util.size(alloc, total) });
    if (!yes) {
        if (!ui.stdinIsTerminal()) {
            var again: std.ArrayList(u8) = .empty;
            try again.appendSlice(alloc, "holt keep --prune-aside");
            if (older_than) |d| try again.print(alloc, " --older-than {d}", .{d});
            for (named) |n| try again.print(alloc, " {s}", .{try ui.shellQuote(alloc, n)});
            try again.appendSlice(alloc, " --yes");
            try ctx.err.print("holt: not removing {s} without a terminal; to remove {s}, run: {s}\n", .{ summary, if (chosen.items.len == 1) "it" else "them", again.items });
            return 1;
        }
        if (!try ui.confirm(ctx.out, try std.fmt.allocPrint(alloc, "Remove {s}?", .{summary}))) {
            try ctx.out.writeAll("nothing removed\n");
            return 0;
        }
    }
    var removed: usize = 0;
    for (chosen.items) |e| {
        if (try kept.ops.pruneEntry(k, e)) {
            removed += 1;
        } else try ctx.out.print("kept aside entry {s}: it changed since it was listed\n", .{e.stamp});
    }
    try ctx.out.print("removed {d} aside entr{s}\n", .{ removed, if (removed == 1) "y" else "ies" });
    return 0;
}

fn from(ctx: *app.Ctx, old_key: []const u8, raw: ?[]const u8) !u8 {
    const alloc = ctx.alloc;
    const k = try util.keptCtx(ctx);
    const given = try fsutil.realPathOrSelf(alloc, try fsutil.toAbsolute(alloc, raw orelse try util.cwdPath(alloc)));
    const path = (try kept.clone.enclosing(alloc, given)) orelse given;
    var index = try kept.store.loadIndex(alloc, k.layout);
    var conflicts: []const []const u8 = &.{};
    var missing: []const []const u8 = &.{};
    const got = kept.ops.takeFrom(k, &index, path, old_key, .{ .conflicts = &conflicts, .missing = &missing }) catch |err| {
        const lead = try std.fmt.allocPrint(alloc, "holt: cannot copy the kept files of {s} into {s}", .{ old_key, try util.show(ctx, path) });
        switch (err) {
            error.NoSuchKey => try ctx.err.print("{s}: no kept files are filed under {s}\n", .{ lead, old_key }),
            error.SameKey => try ctx.err.print("{s}: it is the clone's own key\n", .{lead}),
            error.RootMismatch => try ctx.err.print("{s}: the clone's history lacks the root commit {s} records, so it is another repo\n", .{ lead, old_key }),
            error.OldKeyNoRoot => try ctx.err.print("{s}: {s} records no root commit, so the clone cannot be matched to it\n", .{ lead, old_key }),
            error.NestsInKept => {
                try ctx.err.print("{s}: these paths would lie inside a kept directory of the clone, or hold one of its kept paths:\n", .{lead});
                for (conflicts) |m| try ctx.err.print("  {s}\n", .{m});
            },
            error.OldCopyMissing => {
                try ctx.err.print("{s}: these kept copies are not here (wait for {s} to download them):\n", .{ lead, util.backendName(ctx) });
                for (missing) |m| try ctx.err.print("  {s}\n", .{m});
            },
            error.Conflict => {
                try ctx.err.print("{s}: these paths are in both with different content, or cannot be compared here:\n", .{lead});
                for (conflicts) |m| try ctx.err.print("  {s}\n", .{m});
            },
            error.NotAClone => try ctx.err.print("{s}: not inside a clone\n", .{lead}),
            else => try ctx.err.print("{s}: {s}\n", .{ lead, (try util.reason(ctx, err)) orelse @errorName(err) }),
        }
        return 1;
    };
    for (got.copied) |rel| try ctx.out.print("copied {s} from {s}\n", .{ rel, old_key });
    for (got.present) |rel| try ctx.out.print("already kept with the same content: {s}\n", .{rel});
    const c = try kept.clone.inspect(alloc, path, k.code_root);
    const unsettled = try util.reconcileAndShow(ctx, k, c.worktree, got.copied);
    try ctx.out.print("{s} stays in the kept store; once no clone needs it, run: holt unkeep --repo {s}\n", .{ old_key, try ui.shellQuote(alloc, old_key) });
    return if (unsettled) 1 else 0;
}

/// `--retire-machine`: records `id`, or this machine when null, as retired
/// in the kept store (`store.writeRetired`), covering the facts it has now,
/// dated today and naming this host. This machine, when no fact was
/// written from it, has nothing to retire, which is said; another id no
/// fact was written from (no host label recorded) is refused, naming the
/// machines that have one.
fn retireMachine(ctx: *app.Ctx, id: ?[]const u8) !u8 {
    const alloc = ctx.alloc;
    const k = try util.keptCtx(ctx);
    const target = id orelse k.machine_id;
    if (!kept.machine.valid(target)) {
        try ctx.err.print("holt: cannot retire {s}: not a machine id (16 lowercase hex digits; holt doctor --retire lists them)\n", .{target});
        return 2;
    }
    if (std.mem.eql(u8, target, k.machine_id) and try kept.store.readHost(alloc, k.layout, target) == null) {
        try ctx.out.writeAll("this machine has no kept-file records: there is nothing to retire\n");
        return 0;
    }
    if (try kept.content.entryAt(try k.layout.keptDir(alloc)) == .absent) {
        try ctx.err.print("holt: cannot retire {s}: there is no kept store at {s}\n", .{ target, try util.show(ctx, try k.layout.keptDir(alloc)) });
        return 1;
    }
    const index = try kept.store.loadIndex(alloc, k.layout);
    if (try kept.store.readHost(alloc, k.layout, target) == null) {
        try ctx.err.print("holt: cannot retire {s}: no machine with this id has written kept files\n", .{target});
        var known: usize = 0;
        for (try kept.store.machines(alloc, k.layout, &index)) |m| {
            if (m.host == null) continue;
            if (known == 0) try ctx.err.writeAll("machines that have:\n");
            known += 1;
            try ctx.err.print("  {s}\n", .{try util.machineLabel(ctx, k, m.id)});
        }
        if (known == 0) try ctx.err.writeAll("no machine has written kept files yet\n");
        return 1;
    }
    var buf: [kept.machine.host_name_max]u8 = undefined;
    const host = kept.machine.hostName(&buf);
    const date = try kept.store.today(alloc);
    try kept.store.writeRetired(alloc, k.layout, &index, target, date, host, k.machine_id);
    try ctx.out.print("retired machine {s} on {s}: its records so far no longer block keep, --take-local, or unkeep\n", .{ try util.machineLabel(ctx, k, target), try kept.store.shownDate(alloc, date) });
    return 0;
}

/// `--unretire-machine`: removes the retirement of `id`, or of this
/// machine when null (`store.removeRetired`).
fn unretireMachine(ctx: *app.Ctx, id: ?[]const u8) !u8 {
    const alloc = ctx.alloc;
    const k = try util.keptCtx(ctx);
    const target = id orelse k.machine_id;
    if (!kept.machine.valid(target)) {
        try ctx.err.print("holt: cannot unretire {s}: not a machine id (16 lowercase hex digits; holt doctor --retire lists them)\n", .{target});
        return 2;
    }
    if (!try kept.store.removeRetired(alloc, k.layout, target)) {
        try ctx.err.print("holt: machine {s} is not retired\n", .{try util.machineLabel(ctx, k, target)});
        return 1;
    }
    try ctx.out.print("machine {s} is no longer retired: its records block keep, --take-local, and unkeep again until their content arrives\n", .{try util.machineLabel(ctx, k, target)});
    return 0;
}

/// One thing `--review` asks about.
const Item = struct {
    /// `hidden`: content holt's block hides from git that holt holds
    /// nowhere else, at a kept path or in a temporary beside one; only a
    /// take (or, for a temporary, `holt sync`) settles it. `unsettled`:
    /// such content at a kept path whose state reconcile reports as other
    /// than a differing local copy; it is named with its hint (`hint`),
    /// never asked about, and not a file not kept. `unlinked`: a file git
    /// reads only as a regular file, which can only be skipped.
    kind: enum { repo, submodule, unlinked, hub, hidden, unsettled },
    /// The clone's working tree, or the hub root.
    root: []const u8,
    /// The clone the item is in; null for a hub entry.
    c: ?kept.clone.Clone = null,
    project: ?project_mod.Project = null,
    rel: []const u8,
    abs: []const u8,
    dir: bool,
    bytes: u64,
    /// The line an answer for every repo adds (`patterns.everywhereLine`);
    /// empty when no pattern can name the path (`patternable`).
    everywhere: []const u8,
    /// For `hidden`: the content is in a temporary an interrupted write
    /// left beside the path.
    temp: bool = false,
    /// For `hidden`: an aside entry holding the same content.
    held_by: ?[]const u8 = null,
    /// For `unsettled`: the hint every command gives for the path.
    hint: []const u8 = "",
    done: bool = false,

    /// Whether a pattern line can name the path: a line feed or carriage
    /// return in it would make the line more than one.
    fn patternable(it: Item) bool {
        return it.everywhere.len > 0;
    }
};

/// The line an answer for every repo adds for `rel`, or empty when no
/// pattern line can name it.
fn everywhereFor(alloc: std.mem.Allocator, rel: []const u8, dir: bool) ![]const u8 {
    if (std.mem.indexOfAny(u8, rel, "\n\r") != null) return "";
    return kept.patterns.everywhereLine(alloc, rel, dir);
}

const Review = struct {
    ctx: *app.Ctx,
    k: kept.Ctx,
    yes: bool,
    /// The command that reruns the review answering yes.
    retry: []const u8,
    items: std.ArrayList(Item) = .empty,
    /// Whether the next prompt is the first, which offers `never`.
    first: bool = true,
    /// Whether `kept/` is known to be there to write to.
    store_ok: bool = false,
    /// Every clone the review lists, for counting the repos a pattern for
    /// every repo would match.
    listed: std.ArrayList(Listed) = .empty,
    /// The candidates of clones the review did not list, by the main
    /// working tree, once listed to count matches.
    others: std.StringArrayHashMapUnmanaged([]const kept.patterns.Query) = .empty,
    failed: bool = false,
    /// The clone's and its key's locks, when a deleter holds them for the
    /// review it offers (`reviewHeld`): every write goes on under them.
    held: ?kept.Held = null,

    /// The candidates of one working tree, by the main working tree of its
    /// clone.
    const Listed = struct { main: []const u8, rels: []const kept.patterns.Query };

    fn store(r: *Review) !bool {
        if (r.store_ok) return true;
        r.store_ok = try util.ensureStore(r.ctx, r.k, r.yes, r.retry);
        return r.store_ok;
    }
};

const Answer = enum { keep, keep_everywhere, skip, skip_everywhere, review_each, take_local, take_kept, quit, never };

/// Asks until one of `allowed` is given; `quit` at end of input.
fn askAnswer(r: *Review, question: []const u8, allowed: []const Answer) !Answer {
    const a = r.ctx.alloc;
    var menu: std.ArrayList(u8) = .empty;
    for (allowed, 0..) |ans, i| {
        if (i > 0) try menu.appendSlice(a, ", ");
        try menu.appendSlice(a, switch (ans) {
            .keep => "[k]eep",
            .keep_everywhere => "keep [e]verywhere",
            .skip => "[s]kip",
            .skip_everywhere => "skip e[v]erywhere",
            .review_each => "[r]eview each",
            .take_local => "take [l]ocal",
            .take_kept => "take kep[t]",
            .quit => "[q]uit",
            .never => "[n]ever ask again",
        });
    }
    const msg = try std.fmt.allocPrint(a, "{s}: {s}?", .{ question, menu.items });
    while (true) {
        const line = (try ui.ask(a, r.ctx.out, msg)) orelse return .quit;
        const got: ?Answer = if (eqlAny(line, &.{ "k", "keep" }))
            .keep
        else if (eqlAny(line, &.{ "e", "keep everywhere" }))
            .keep_everywhere
        else if (eqlAny(line, &.{ "s", "skip" }))
            .skip
        else if (eqlAny(line, &.{ "v", "skip everywhere" }))
            .skip_everywhere
        else if (eqlAny(line, &.{ "r", "review each" }))
            .review_each
        else if (eqlAny(line, &.{ "l", "take local" }))
            .take_local
        else if (eqlAny(line, &.{ "t", "take kept" }))
            .take_kept
        else if (eqlAny(line, &.{ "q", "quit" }))
            .quit
        else if (eqlAny(line, &.{ "n", "never", "never ask again" }))
            .never
        else
            null;
        if (got) |g| for (allowed) |ok| if (ok == g) return g;
    }
}

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.ascii.eqlIgnoreCase(s, o)) return true;
    return false;
}

fn withNever(r: *Review, a: std.mem.Allocator, base: []const Answer) ![]const Answer {
    if (!r.first) return base;
    return std.mem.concat(a, Answer, &.{ base, &.{.never} });
}

/// `--review`: lists the candidates of the clones and hub roots it covers,
/// keeping what an auto pattern names, and asks about each. Creates nothing
/// until the first answer that writes; without a terminal it prints each
/// candidate with its command and exits 1 when there are any.
fn review(ctx: *app.Ctx, raw_paths: []const []const u8, all: bool, yes: bool) !u8 {
    const alloc = ctx.alloc;
    const ws = ctx.context.?.ws;
    const k = try util.keptCtx(ctx);
    kept.clone.requireGit(alloc) catch {
        try ctx.err.print("holt: {s}\n", .{try kept.clone.gitTooOld(alloc)});
        return 1;
    };
    var r: Review = .{ .ctx = ctx, .k = k, .yes = yes, .retry = "holt keep --review --all --yes" };
    r.store_ok = try kept.content.entryAt(try k.layout.keptDir(alloc)) != .absent;

    var clones: std.ArrayList([]const u8) = .empty;
    var hubs: std.ArrayList(project_mod.Project) = .empty;
    if (all) {
        try clones.appendSlice(alloc, try ws.listClones(alloc));
        try hubs.appendSlice(alloc, try ws.list(alloc));
    } else {
        const target = try fsutil.realPathOrSelf(alloc, try fsutil.toAbsolute(alloc, if (raw_paths.len > 0) raw_paths[0] else try util.cwdPath(alloc)));
        r.retry = try std.fmt.allocPrint(alloc, "holt keep --review --yes {s}", .{try util.q(ctx, target)});
        if (try hubOf(ctx, target)) |p| {
            try hubs.append(alloc, p);
            for (p.marker.entries) |*e| {
                const src = e.source orelse continue;
                const cp = try src.id().clonePath(alloc, ws.cfg.code_root);
                if (fsutil.exists(cp)) try clones.append(alloc, cp);
            }
        } else {
            const top = (try kept.clone.enclosing(alloc, target)) orelse target;
            const c = kept.clone.inspect(alloc, top, ws.cfg.code_root) catch {
                try ctx.err.print("holt: cannot review {s}: it is neither inside a clone nor a project's hub root\n", .{try util.show(ctx, target)});
                return 1;
            };
            if (c.key == null) {
                try ctx.err.print("holt: cannot review {s}: the clone {s} is not under code_root {s}\n", .{ try util.show(ctx, target), try util.show(ctx, c.main), try util.show(ctx, ws.cfg.code_root) });
                return 1;
            }
            try clones.append(alloc, c.worktree);
        }
    }

    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (clones.items) |cp| {
        const real = try fsutil.realPathOrSelf(alloc, cp);
        if (seen.contains(real)) continue;
        try seen.put(alloc, real, {});
        try listClone(&r, real);
    }
    for (hubs.items) |p| try listHub(&r, p);

    const items = r.items.items;
    if (items.len == 0) {
        try ctx.out.writeAll("nothing to review: every file is kept, skipped, or tracked\n");
        return if (r.failed) 1 else 0;
    }
    if (!ui.stdinIsTerminal()) {
        const keep_cmd = if (try util.storeNeedsYes(ctx, r.k)) "holt keep --yes" else "holt keep";
        var not_kept: usize = 0;
        for (items) |it| {
            if (it.kind != .unsettled) not_kept += 1;
            if (it.kind != .unsettled and util.hasControl(it.abs)) {
                try ctx.out.print("not kept: {s} ({s}): {s}\n", .{ try util.show(ctx, it.abs), try util.size(alloc, it.bytes), util.controlWords(it.abs) });
                continue;
            }
            switch (it.kind) {
                .repo => try ctx.out.print("not kept: {s} ({s}) - run: {s} {s}\n", .{ try util.show(ctx, it.abs), try util.size(alloc, it.bytes), keep_cmd, try util.q(ctx, it.abs) }),
                .hub => try ctx.out.print("not kept: {s} ({s}) - run: holt keep {s}\n", .{ try util.show(ctx, it.abs), try util.size(alloc, it.bytes), try util.q(ctx, it.abs) }),
                .submodule => try ctx.out.print("not kept: {s} ({s}), inside a submodule, can only be skipped - in a terminal, run: holt keep --review {s}\n", .{ try util.show(ctx, it.abs), try util.size(alloc, it.bytes), try util.q(ctx, it.root) }),
                .unlinked => try ctx.out.print("not kept: {s} ({s}), which git reads only as a regular file, can only be skipped - in a terminal, run: holt keep --review {s}\n", .{ try util.show(ctx, it.abs), try util.size(alloc, it.bytes), try util.q(ctx, it.root) }),
                .hidden => try printHiddenItem(ctx, it),
                .unsettled => try printUnsettledItem(ctx, it),
            }
        }
        if (not_kept > 0) try ctx.out.print("{d} file{s} not kept\n", .{ not_kept, if (not_kept == 1) "" else "s" });
        return 1;
    }

    if (all) {
        if (try askGroups(&r)) |code| return code;
    }
    for (items) |*it| {
        if (it.done) continue;
        if (try askItem(&r, it)) |code| return code;
    }
    return if (r.failed) 1 else 0;
}

/// The review a deleter offers before it refuses (`deleter.Review`): asks
/// about every candidate of the clone of the working tree at `path`, as
/// `holt keep --review <path>` on a terminal does, keeping, skipping, and
/// taking under the locks the deleter holds (`held`), until each is
/// answered or the user quits.
pub fn reviewHeld(ctx: *app.Ctx, k: kept.Ctx, index: *const kept.store.KeyIndex, path: []const u8, held: ?kept.Held) anyerror!void {
    _ = index;
    var r: Review = .{ .ctx = ctx, .k = k, .yes = false, .retry = try std.fmt.allocPrint(ctx.alloc, "holt keep --review --yes {s}", .{try util.q(ctx, path)}), .held = held };
    r.store_ok = try kept.content.entryAt(try k.layout.keptDir(ctx.alloc)) != .absent;
    try listClone(&r, path);
    for (r.items.items) |*it| {
        if (it.done) continue;
        if (try askItem(&r, it) != null) return;
    }
}

/// A `hidden` item without a terminal: what holds it, and the commands
/// that settle it.
fn printHiddenItem(ctx: *app.Ctx, it: Item) !void {
    const alloc = ctx.alloc;
    if (it.temp) {
        try ctx.out.print("not kept: an interrupted write left content beside {s}, hidden from git by holt's block and held nowhere else ({s}) - run: holt sync\n", .{ try util.show(ctx, it.abs), try util.size(alloc, it.bytes) });
        return;
    }
    if (untakeable(it)) {
        try ctx.out.print("not kept: {s} ({s}) {s}; {s}, so it cannot be taken\n", .{ try util.show(ctx, it.abs), try util.size(alloc, it.bytes), try heldWords(alloc, it), kept.paths.Invalid.git_reads_unlinked.describe() });
        return;
    }
    const qp = try util.q(ctx, it.abs);
    try ctx.out.print("not kept: {s} ({s}) {s} - run: holt keep --take-local {s}, or holt keep --take-kept {s}\n", .{ try util.show(ctx, it.abs), try util.size(alloc, it.bytes), try heldWords(alloc, it), qp, qp });
}

/// Whether `it` is hidden content at a file git reads only as a regular
/// file, which no take may link.
fn untakeable(it: Item) bool {
    return it.kind == .hidden and !it.temp and kept.paths.keepable(it.rel) == .git_reads_unlinked;
}

/// Where a `hidden` item's content is besides the working tree.
fn heldWords(alloc: std.mem.Allocator, it: Item) ![]const u8 {
    const e = it.held_by orelse return "is hidden from git by holt's block and held nowhere else";
    return std.fmt.allocPrint(alloc, "is hidden from git by holt's block; aside entry {s} also holds it", .{e});
}

/// An `unsettled` item: the path and the hint every command gives for it.
fn printUnsettledItem(ctx: *app.Ctx, it: Item) !void {
    try ctx.out.print("not linked: {s}: {s}\n", .{ try util.show(ctx, it.abs), it.hint });
}

/// The project whose hub root is `dir`, a real path.
fn hubOf(ctx: *app.Ctx, dir: []const u8) !?project_mod.Project {
    const alloc = ctx.alloc;
    for (try ctx.context.?.ws.list(alloc)) |p| {
        if (std.mem.eql(u8, try fsutil.realPathOrSelf(alloc, p.hub_path), dir)) return p;
    }
    return null;
}

fn listClone(r: *Review, path: []const u8) !void {
    const ctx = r.ctx;
    const alloc = ctx.alloc;
    const c = kept.clone.inspect(alloc, path, r.k.code_root) catch |err| {
        try ctx.err.print("holt: cannot list {s}: {s}\n", .{ try util.show(ctx, path), (try util.reason(ctx, err)) orelse @errorName(err) });
        r.failed = true;
        return;
    };
    const index = try kept.store.loadIndex(alloc, r.k.layout);
    var too_large: []const u8 = "";
    const got = kept.candidates.listAll(r.k, &index, c, .{ .auto = true, .list_too_large = &too_large, .held = r.held }) catch |err| {
        if (err == error.MatcherFailed and too_large.len > 0) {
            try ctx.err.print("holt: cannot list {s}: the pattern list {s} is larger than 1 MiB\n", .{ try util.show(ctx, path), try util.show(ctx, too_large) });
        } else try ctx.err.print("holt: cannot list {s}: {s}\n", .{ try util.show(ctx, path), (try util.reason(ctx, err)) orelse @errorName(err) });
        r.failed = true;
        return;
    };
    for (got.unlisted) |u| {
        try ctx.err.print("holt: cannot list the working tree {s}: {s}\n", .{ try util.show(ctx, u.worktree), if (u.problem) |p| @tagName(p) else u.detail orelse "unknown" });
        r.failed = true;
    }
    var plans: std.StringArrayHashMapUnmanaged(kept.reconcile.Report) = .empty;
    for (got.listings) |l| {
        const lc = if (std.mem.eql(u8, l.worktree, c.worktree)) c else kept.clone.inspect(alloc, l.worktree, r.k.code_root) catch |err| {
            try ctx.err.print("holt: cannot list {s}: {s}\n", .{ try util.show(ctx, l.worktree), (try util.reason(ctx, err)) orelse @errorName(err) });
            r.failed = true;
            continue;
        };
        var queries: std.ArrayList(kept.patterns.Query) = .empty;
        for (l.auto_kept) |ak| {
            try ctx.out.print("kept automatically: {s} (matches '{s}')\n", .{ try util.show(ctx, try fsutil.joinSlashy(alloc, l.worktree, ak.rel)), ak.pattern });
            try util.printHidden(ctx, ak.outcome.hidden);
        }
        for (l.nested) |n| try ctx.out.print("not kept: {s} is a nested repository; it is left as it is\n", .{try util.show(ctx, try fsutil.joinSlashy(alloc, l.worktree, n.repo))});
        for (l.submodules_failed) |s| {
            try ctx.err.print("holt: cannot list the submodule {s}\n", .{try util.show(ctx, try fsutil.joinSlashy(alloc, l.worktree, s))});
            r.failed = true;
        }
        for (l.candidates) |cand| {
            const abs = try fsutil.joinSlashy(alloc, l.worktree, cand.rel);
            if (std.mem.eql(u8, cand.rel, ".")) {
                const h = cand.hidden orelse continue;
                try ctx.err.print("holt: {s} could not be judged: {s}{s}{s}\n", .{ try util.show(ctx, l.worktree), util.whyWords(h.why orelse .failed), if (h.detail != null) ": " else "", h.detail orelse "" });
                r.failed = true;
                continue;
            }
            if (cand.auto) |miss| if (miss.why == .too_large) {
                try ctx.out.print("not kept automatically: {s} matches '{s}' but holds more than 10 MiB\n", .{ try util.show(ctx, abs), miss.pattern });
            };
            const dir = cand.entry == .dir;
            if (cand.hidden) |h| {
                if (cand.at_kept_path) {
                    if (plans.get(l.worktree) == null) try plans.put(alloc, l.worktree, kept.reconcile.reconcile(r.k, &index, l.worktree, .plan) catch kept.reconcile.Report{});
                    const report = plans.get(l.worktree).?;
                    const unsettled = for (report.items) |i| {
                        if (i.unsettled and i.worktree == null and std.mem.eql(u8, i.rel, cand.rel)) break i;
                    } else null;
                    if (unsettled) |i| if (i.outcome != .local_differs) {
                        const hint = try kept_hints.forItem(ctx, l.worktree, report.resolved orelse report.key, r.k.layout.synced_root, i);
                        try r.items.append(alloc, .{ .kind = .unsettled, .root = l.worktree, .c = lc, .rel = cand.rel, .abs = abs, .dir = dir, .bytes = 0, .everywhere = "", .hint = try kept_hints.renderDash(alloc, hint) });
                        continue;
                    };
                }
                try r.items.append(alloc, .{
                    .kind = .hidden,
                    .root = l.worktree,
                    .c = lc,
                    .rel = cand.rel,
                    .abs = abs,
                    .dir = dir,
                    .bytes = try util.bytesAt(alloc, try h.path(alloc)),
                    .everywhere = "",
                    .temp = h.temp != null,
                    .held_by = if (h.temp == null) try heldBy(r.k, lc, cand.rel, try h.path(alloc)) else null,
                });
                continue;
            }
            try queries.append(alloc, .{ .path = cand.rel, .dir = dir });
            try r.items.append(alloc, .{
                .kind = if (cand.submodule != null or cand.submodule_uninitialized) .submodule else if (cand.git_reads_unlinked) .unlinked else .repo,
                .root = l.worktree,
                .c = lc,
                .rel = cand.rel,
                .abs = abs,
                .dir = dir,
                .bytes = try util.bytesAt(alloc, abs),
                .everywhere = try everywhereFor(alloc, cand.rel, dir),
            });
        }
        try r.listed.append(alloc, .{ .main = lc.main, .rels = queries.items });
    }
}

/// The first aside entry of the clone `c`'s key holding the content at
/// `path`, the place `rel` of it; null when none does.
fn heldBy(k: kept.Ctx, c: kept.clone.Clone, rel: []const u8, path: []const u8) !?[]const u8 {
    const key = c.key orelse return null;
    const h = kept.content.hashPath(k.alloc, path) catch return null;
    const found = kept.aside.findEntries(k.alloc, k.layout, key, rel, &h.hex) catch return null;
    return if (found.len > 0) found[0] else null;
}

fn listHub(r: *Review, p: project_mod.Project) !void {
    const ctx = r.ctx;
    const alloc = ctx.alloc;
    var names: std.ArrayList([]const u8) = .empty;
    var queries: std.ArrayList(kept.patterns.Query) = .empty;
    {
        var dir = std.Io.Dir.openDirAbsolute(fsutil.io(), p.hub_path, .{ .iterate = true }) catch return;
        defer dir.close(fsutil.io());
        var it = dir.iterate();
        while (try it.next(fsutil.io())) |e| {
            if (e.kind == .sym_link) continue;
            if (std.mem.eql(u8, e.name, "code") or std.mem.eql(u8, e.name, marker.marker_basename)) continue;
            if (std.mem.eql(u8, e.name, ".git")) continue;
            try names.append(alloc, try alloc.dupe(u8, e.name));
            try queries.append(alloc, .{ .path = names.items[names.items.len - 1], .dir = e.kind == .directory });
        }
    }
    std.mem.sort([]const u8, names.items, {}, kept.paths.lessThan);
    for (names.items, 0..) |n, i| queries.items[i] = .{ .path = n, .dir = try kept.content.entryAt(try std.fs.path.join(alloc, &.{ p.hub_path, n })) == .dir };
    const skipped = kept.patterns.hubSkipped(r.k, queries.items, null) catch |err| {
        try ctx.err.print("holt: cannot list {s}: {s}\n", .{ try util.show(ctx, p.hub_path), (try util.reason(ctx, err)) orelse @errorName(err) });
        r.failed = true;
        return;
    };
    for (names.items, queries.items, skipped) |n, qq, s| {
        if (s) continue;
        const abs = try std.fs.path.join(alloc, &.{ p.hub_path, n });
        try r.items.append(alloc, .{ .kind = .hub, .root = p.hub_path, .project = p, .rel = n, .abs = abs, .dir = qq.dir, .bytes = try util.bytesAt(alloc, abs), .everywhere = try everywhereFor(alloc, n, qq.dir) });
    }
}

/// `--all`: asks once for each pattern for every repo that candidates in
/// more than one repo share. Returns an exit code when the review ends.
fn askGroups(r: *Review) !?u8 {
    const alloc = r.ctx.alloc;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    const items = r.items.items;
    for (items) |it| {
        if (it.kind != .repo or it.done or !it.patternable() or util.hasControl(it.abs) or seen.contains(it.everywhere)) continue;
        try seen.put(alloc, it.everywhere, {});
        var repos: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (items) |o| if (o.kind == .repo and std.mem.eql(u8, o.everywhere, it.everywhere)) try repos.put(alloc, o.c.?.main, {});
        if (repos.count() < 2) continue;
        const others = try otherMatches(r, it.everywhere, repos.keys());
        const question = try std.fmt.allocPrint(alloc, "{s} in {d} repos (keep everywhere also matches {d} other repo{s})", .{ it.everywhere, repos.count(), others, if (others == 1) "" else "s" });
        const ans = try askAnswer(r, question, try withNever(r, alloc, &.{ .keep_everywhere, .skip_everywhere, .review_each, .quit }));
        const was_first = r.first;
        r.first = false;
        switch (ans) {
            .never => if (was_first) return try never(r),
            .quit => return if (r.failed) 1 else 0,
            .review_each => {},
            .keep_everywhere => {
                if (!try r.store()) return 1;
                var any = false;
                for (items) |*o| {
                    if (o.kind != .repo or o.done or !std.mem.eql(u8, o.everywhere, it.everywhere)) continue;
                    if (try keepItem(r, o)) any = true;
                }
                if (any) try addEverywhere(r, .auto, it.everywhere, others);
            },
            .skip_everywhere => {
                if (!try r.store()) return 1;
                try addEverywhere(r, .skip, it.everywhere, 0);
                markSame(r, it.everywhere);
            },
            else => unreachable,
        }
    }
    return null;
}

fn markSame(r: *Review, line: []const u8) void {
    for (r.items.items) |*o| {
        if ((o.kind == .repo or o.kind == .submodule or o.kind == .unlinked) and std.mem.eql(u8, o.everywhere, line)) o.done = true;
    }
}

fn never(r: *Review) !u8 {
    const ctx = r.ctx;
    const off = try std.fs.path.join(ctx.alloc, &.{ r.k.layout.synced_root, ".holt-kept-off" });
    kept.store.createExclusive(ctx.alloc, off, "Present because kept files were turned off; remove this file to be offered them again.\n") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try ctx.out.print("kept files turned off: holt will not offer them again (remove {s} to turn them back on)\n", .{try util.show(ctx, off)});
    return 0;
}

/// Asks about one candidate. Returns an exit code when the review ends.
fn askItem(r: *Review, it: *Item) !?u8 {
    const ctx = r.ctx;
    const alloc = ctx.alloc;
    const shown = try util.show(ctx, it.abs);
    const size = try util.size(alloc, it.bytes);
    const kind = if (it.dir) "directory" else "file";
    const mains: []const []const u8 = if (it.c) |cl| &.{cl.main} else &.{};
    if (it.kind == .unsettled) {
        it.done = true;
        try printUnsettledItem(ctx, it.*);
        return null;
    }
    if (it.kind == .hidden and it.temp) {
        it.done = true;
        try ctx.out.print("{s}: an interrupted write left content beside it, hidden from git by holt's block and held nowhere else ({s}); run: holt sync\n", .{ shown, size });
        return null;
    }
    if (untakeable(it.*)) {
        it.done = true;
        try ctx.out.print("{s} ({s}, {s}) {s}; {s}, so it cannot be taken; it is left as it is\n", .{ shown, kind, size, try heldWords(alloc, it.*), kept.paths.Invalid.git_reads_unlinked.describe() });
        return null;
    }
    if (it.kind == .submodule and !it.patternable()) {
        it.done = true;
        try ctx.out.print("{s}: inside a submodule, and its name holds a line break no pattern can name, so it cannot be skipped; it is left as it is\n", .{shown});
        return null;
    }
    const control = it.kind == .repo and util.hasControl(it.abs);
    if (control and !it.patternable()) {
        it.done = true;
        try ctx.out.print("{s}: {s}; it is left as it is\n", .{ shown, util.line_break_words });
        return null;
    }
    var others: usize = 0;
    const question = if (control) try std.fmt.allocPrint(alloc, "{s} ({s}, {s}; the name holds a control character, so it can only be skipped)", .{ shown, kind, size }) else switch (it.kind) {
        .hidden => try std.fmt.allocPrint(alloc, "{s} ({s}, {s}) {s}", .{ shown, kind, size, try heldWords(alloc, it.*) }),
        .repo => if (it.patternable()) blk: {
            others = try otherMatches(r, it.everywhere, mains);
            break :blk try std.fmt.allocPrint(alloc, "{s} ({s}, {s}; keep everywhere also matches {d} other repo{s})", .{ shown, kind, size, others, if (others == 1) "" else "s" });
        } else try std.fmt.allocPrint(alloc, "{s} ({s}, {s})", .{ shown, kind, size }),
        .unlinked => try std.fmt.allocPrint(alloc, "{s} ({s}, {s}; {s}, so it cannot be kept)", .{ shown, kind, size, kept.paths.Invalid.git_reads_unlinked.describe() }),
        else => try std.fmt.allocPrint(alloc, "{s} ({s}, {s})", .{ shown, kind, size }),
    };
    const choices: []const Answer = if (control) &.{ .skip, .quit } else switch (it.kind) {
        .repo => if (it.patternable()) &.{ .keep, .keep_everywhere, .skip, .skip_everywhere, .quit } else &.{ .keep, .quit },
        .submodule => &.{ .skip, .skip_everywhere, .quit },
        .unlinked => if (it.patternable()) &.{ .skip, .skip_everywhere, .quit } else &.{ .skip, .quit },
        .hub => if (it.patternable()) &.{ .keep, .skip_everywhere, .quit } else &.{ .keep, .quit },
        .hidden => &.{ .take_local, .take_kept, .quit },
        .unsettled => unreachable,
    };
    const ans = try askAnswer(r, question, if (it.kind == .repo) try withNever(r, alloc, choices) else choices);
    const was_first = r.first;
    r.first = false;
    it.done = true;
    switch (ans) {
        .never => if (was_first) return try never(r),
        .quit => return if (r.failed) 1 else 0,
        .keep => {
            if (it.kind == .hub) {
                if (!try keepHub(ctx, it.project.?, it.abs)) r.failed = true;
            } else {
                if (!try r.store()) return 1;
                _ = try keepItem(r, it);
            }
        },
        .keep_everywhere => {
            if (!try r.store()) return 1;
            if (try keepItem(r, it)) {
                try addEverywhere(r, .auto, it.everywhere, others);
                for (r.items.items) |*o| {
                    if (o.done or o.kind != .repo or !std.mem.eql(u8, o.everywhere, it.everywhere)) continue;
                    if (try keepItem(r, o)) try ctx.out.print("kept automatically: {s} (matches '{s}')\n", .{ try util.show(ctx, o.abs), it.everywhere });
                    o.done = true;
                }
            }
        },
        .skip => {
            if (!try r.store()) return 1;
            const index = try kept.store.loadIndex(alloc, r.k.layout);
            const key = kept.ops.ensureCloneKey(r.k, &index, it.root, r.held) catch |err| {
                try util.refuse(ctx, "skip", it.abs, err);
                r.failed = true;
                return null;
            };
            const line = try kept.patterns.anchoredLine(alloc, it.rel);
            try echoLine(ctx, line, try kept.patterns.addLine(alloc, r.k.layout, r.k.machine_id, key, .skip, line), try r.k.layout.keyDir(alloc, key));
        },
        .skip_everywhere => {
            if (!try r.store()) return 1;
            try addEverywhere(r, .skip, it.everywhere, 0);
            markSame(r, it.everywhere);
        },
        .take_local => if (try take(ctx, it.abs, .local, r.held) != 0) {
            r.failed = true;
        },
        .take_kept => if (try take(ctx, it.abs, .kept, r.held) != 0) {
            r.failed = true;
        },
        .review_each => unreachable,
    }
    return null;
}

fn echoLine(ctx: *app.Ctx, line: []const u8, file: ?[]const u8, dir: []const u8) !void {
    if (file) |f| {
        try ctx.out.print("added '{s}' to {s}\n", .{ try ui.printable(ctx.alloc, line), try util.show(ctx, f) });
    } else try ctx.out.print("'{s}' is already in the lists under {s}\n", .{ try ui.printable(ctx.alloc, line), try util.show(ctx, dir) });
}

/// Adds `line` to the list `l` for every repo, echoing it; for an auto
/// pattern that matches files in `others` other repos, says when they are
/// kept.
fn addEverywhere(r: *Review, l: kept.patterns.List, line: []const u8, others: usize) !void {
    const ctx = r.ctx;
    const alloc = ctx.alloc;
    try echoLine(ctx, line, try kept.patterns.addLine(alloc, r.k.layout, r.k.machine_id, null, l, line), try r.k.layout.keptDir(alloc));
    if (l == .auto and others > 0) try ctx.out.print("the files '{s}' matches in {d} other repo{s} are kept automatically at the next holt sync\n", .{ line, others, if (others == 1) "" else "s" });
}

/// How many clones in the code tree, but those whose main working trees
/// are `except`, hold a candidate `line` matches in any working tree:
/// those the review listed as it listed them, the rest listed now.
fn otherMatches(r: *Review, line: []const u8, except: []const []const u8) !usize {
    const alloc = r.ctx.alloc;
    const ws = r.ctx.context.?.ws;
    var listed: std.StringArrayHashMapUnmanaged(std.ArrayList(kept.patterns.Query)) = .empty;
    for (r.listed.items) |l| {
        const gop = try listed.getOrPut(alloc, l.main);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.appendSlice(alloc, l.rels);
    }
    const index = try kept.store.loadIndex(alloc, r.k.layout);
    var n: usize = 0;
    for (try ws.listClones(alloc)) |cp| {
        const real = try fsutil.realPathOrSelf(alloc, cp);
        if (kept.paths.contains(except, real)) continue;
        const queries = if (listed.get(real)) |got| got.items else if (r.others.get(real)) |got| got else blk: {
            const c = kept.clone.inspect(alloc, real, r.k.code_root) catch continue;
            const got = kept.candidates.list(r.k, &index, c.worktree, .{}) catch continue;
            var qs: std.ArrayList(kept.patterns.Query) = .empty;
            for (got.candidates) |cand| if (cand.hidden == null) try qs.append(alloc, .{ .path = cand.rel, .dir = cand.entry == .dir });
            try r.others.put(alloc, real, qs.items);
            break :blk qs.items;
        };
        const hits = kept.patterns.match(r.k, line, queries) catch continue;
        for (hits) |h| if (h != null) {
            n += 1;
            break;
        };
    }
    return n;
}

/// Keeps a review item, reporting a refusal; returns whether it is kept.
fn keepItem(r: *Review, it: *Item) !bool {
    it.done = true;
    const c = it.c orelse return false;
    const ok = try keepRepo(r.ctx, c, it.rel, it.abs, r.yes, r.held);
    if (!ok) r.failed = true;
    return ok;
}

// Tests

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

    fn keptPath(f: *Fx, rel: []const u8) ![]const u8 {
        return fsutil.joinSlashy(f.a(), try std.fs.path.join(f.a(), &.{ f.ws.cfg.synced_root, "kept", "github.com", "acme", "widget" }), rel);
    }

    fn linked(f: *Fx, rel: []const u8) !bool {
        const raw = (try kept.content.readLink(f.a(), try f.path(rel))) orelse return false;
        return std.mem.eql(u8, raw, try f.keptPath(rel));
    }

    fn run(f: *Fx, argv: []const []const u8) !testutil.RunResult {
        return testutil.runCmd(f.a(), command.run, f.ws, argv);
    }

    fn deinit(f: *Fx) void {
        std.process.setCurrentPath(fsutil.io(), f.orig_cwd) catch {};
        testing.allocator.free(f.orig_cwd);
        ui.stdin_for_test = null;
        ui.stdin_terminal_for_test = null;
        f.env.restore();
        f.sb.deinit();
        f.arena_state.deinit();
    }
};

/// A workspace under a sandbox with one clone at
/// `code/github.com/acme/widget`, ignoring `.env`, `*.local`, and `notes/`,
/// holt's machine-local state inside the sandbox, and the working directory
/// in the clone.
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
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try f.path(".gitignore"), .data = ".env\n*.local\nnotes/\nbig.bin\n" });
    try testutil.runGit(&f.sb, f.clone, &.{ "add", ".gitignore" });
    try testutil.runGit(&f.sb, f.clone, &.{ "commit", "-q", "-m", "ignore" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    f.orig_cwd = try testing.allocator.dupe(u8, buf[0..try std.process.currentPath(fsutil.io(), &buf)]);
    try std.process.setCurrentPath(fsutil.io(), f.clone);
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (contains(hay, needle)) return;
    std.debug.print("expected to find:\n  {s}\nin:\n{s}\n", .{ needle, hay });
    return error.TestUnexpectedResult;
}

test "keep: a repo file is kept and linked, creating the kept store; again it is already kept" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "SECRET=1\n");

    const got = try f.run(&.{".env"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, "created the kept store");
    try expectContains(got.out, "kept ");
    try testing.expect(try f.linked(".env"));
    try testing.expect(fsutil.exists(try std.fs.path.join(f.a(), &.{ f.ws.cfg.synced_root, "kept", ".holt-skip" })));

    const again = try f.run(&.{".env"});
    try testing.expectEqual(@as(u8, 0), again.code);
    try expectContains(again.out, "already kept: ");
}

test "keep: several paths at once, a directory whole, and a path inside it names it" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write("a.local", "a");
    try f.write("notes/one.md", "1");
    try f.write("notes/two.md", "2");

    const got = try f.run(&.{ "a.local", "notes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(try f.linked("a.local"));
    try testing.expect(try f.linked("notes"));
    const inner = try f.run(&.{"notes/one.md"});
    try testing.expectEqual(@as(u8, 0), inner.code);
    try expectContains(inner.out, "is inside the kept directory");
}

test "keep: refuses a tracked file, and a directory with a tracked file names the untracked ones" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write("cfg/tracked.txt", "t");
    try f.write("cfg/local.txt", "l");
    try testutil.runGit(&f.sb, f.clone, &.{ "add", "cfg/tracked.txt" });
    try testutil.runGit(&f.sb, f.clone, &.{ "commit", "-q", "-m", "cfg" });

    const file = try f.run(&.{"cfg/tracked.txt"});
    try testing.expectEqual(@as(u8, 1), file.code);
    try expectContains(file.err, "git tracks it");
    const dir = try f.run(&.{"cfg"});
    try testing.expectEqual(@as(u8, 1), dir.code);
    try expectContains(dir.err, "name the untracked files instead");
    try expectContains(dir.err, try std.fmt.allocPrint(f.a(), "holt keep {s}", .{try ui.quotePath(f.a(), app.envOf_current(), try f.path("cfg/local.txt"))}));
    try testing.expectEqual(kept.content.Entry.dir, try kept.content.entryAt(try f.path("cfg")));
}

test "keep: refuses a path a .gitignore negation un-ignores, naming the line; once it is gone, the keep in the refusal succeeds and git does not see the link" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write("sub/.gitignore", "!secret.local\n");
    try f.write("sub/secret.local", "s");
    try f.write("mine.local", "m");
    const exclude = try std.fs.path.join(a, &.{ f.clone, ".git", "info", "exclude" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = exclude, .data = "!mine.local\n" });

    const abs = try f.path("sub/secret.local");
    const qp = try ui.quotePath(a, app.envOf_current(), abs);
    const refused = try f.run(&.{"sub/secret.local"});
    try testing.expectEqual(@as(u8, 1), refused.code);
    const line = try std.fmt.allocPrint(a, "{s}:1:!secret.local", .{try fsutil.contractTilde(a, app.envOf_current(), try f.path("sub/.gitignore"))});
    try expectContains(refused.err, try std.fmt.allocPrint(a, "holt: cannot keep {s}: {s} un-ignores it, and holt's block cannot hide it from git past that line; remove or narrow the line, then keep it (run: holt keep {s})\n", .{ try fsutil.contractTilde(a, app.envOf_current(), abs), line, qp }));
    try testing.expectEqual(kept.content.Entry.file, try kept.content.entryAt(abs));

    try testing.expectEqual(@as(u8, 0), (try f.run(&.{"mine.local"})).code);
    try testing.expect(try f.linked("mine.local"));

    try f.write("sub/.gitignore", "");
    try testing.expectEqual(@as(u8, 0), (try f.run(&.{abs})).code);
    try testing.expect(try f.linked("sub/secret.local"));
    const st = try git.runInRepoScoped(a, &.{ "status", "--porcelain", "--untracked-files=all" }, f.clone);
    try testing.expect(!contains(st.stdout, "secret.local"));
    try testing.expect(!contains(st.stdout, "mine.local"));
}

test "keep: refuses a foreign symlink naming its target, a symlinked parent, a nested repository, and a reserved name" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write("real/x.local", "x");
    try kept.content.createLink(try f.path("real/x.local"), try f.path("link.local"), .file);
    const got = try f.run(&.{"link.local"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "symlink holt did not make (-> ");

    try kept.content.createLink(try f.path("real"), try f.path("via"), .dir);
    const parent = try f.run(&.{"via/x.local"});
    try testing.expectEqual(@as(u8, 1), parent.code);
    try expectContains(parent.err, "a parent directory is a symlink");

    try f.write("tools/inner/.git/HEAD", "ref: refs/heads/main\n");
    try f.write("tools/inner/secret.local", "s");
    const nested_dir = try f.run(&.{"tools"});
    try testing.expectEqual(@as(u8, 1), nested_dir.code);
    try expectContains(nested_dir.err, "holds names a kept path may not have");

    const inner = try fsutil.joinSlashy(a, f.clone, "sub/repo");
    try fsutil.ensureDir(inner);
    try testutil.runGit(&f.sb, inner, &.{ "init", "-q" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, inner, "x.local"), .data = "x" });
    const nested = try f.run(&.{try fsutil.joinSlashy(a, inner, "x.local")});
    try testing.expectEqual(@as(u8, 1), nested.code);
    try expectContains(nested.err, "nested repository");

    try f.write(".holt-x", "x");
    const reserved = try f.run(&.{".holt-x"});
    try testing.expectEqual(@as(u8, 1), reserved.code);
    try expectContains(reserved.err, "not one a kept path may have");
}

test "keep: refuses a file git reads only as a regular file, writing no block line, pending record, or fact; a link there names unkeep" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    try testing.expectEqual(@as(u8, 0), (try f.run(&.{".env"})).code);
    const exclude = try std.fs.path.join(a, &.{ f.clone, ".git", "info", "exclude" });
    const before = try kept.content.readSmall(a, exclude);
    try f.write("sub/.gitignore", "*.tmp\n");

    const abs = try f.path("sub/.gitignore");
    const got = try f.run(&.{"sub/.gitignore"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, try std.fmt.allocPrint(a, "holt: cannot keep {s}: git reads it only as a regular file, never through a link\n", .{try fsutil.contractTilde(a, app.envOf_current(), abs)}));
    try testing.expect(!contains(got.err, "unkeep"));
    try testing.expectEqualStrings(before, try kept.content.readSmall(a, exclude));
    try testing.expectEqual(@as(usize, 0), (try kept.clone.readPending(a, try std.fs.path.join(a, &.{ f.clone, ".git" }))).len);
    const ks = try kept.store.loadKeyState(a, .{ .synced_root = f.ws.cfg.synced_root }, "github.com/acme/widget");
    try testing.expectEqual(@as(usize, 0), ks.factsFor("sub/.gitignore").len);
    try testing.expectEqual(kept.content.Entry.file, try kept.content.entryAt(abs));

    try f.write("real/.mailmap", "A <a@example.com>\n");
    const link_abs = try f.path(".mailmap");
    try kept.content.createLink(try f.path("real/.mailmap"), link_abs, .file);
    const linked = try f.run(&.{".mailmap"});
    try testing.expectEqual(@as(u8, 1), linked.code);
    try expectContains(linked.err, try std.fmt.allocPrint(a, "holt: cannot keep {s}: git reads it only as a regular file, never through a link (if an older holt kept it, run: holt unkeep {s})\n", .{ try fsutil.contractTilde(a, app.envOf_current(), link_abs), try ui.quotePath(a, app.envOf_current(), link_abs) }));
    try testing.expectEqualStrings(before, try kept.content.readSmall(a, exclude));
}

test "keep --take-kept and --take-local: refuse a file git reads only as a regular file that an older holt kept, and link nothing" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    try testing.expectEqual(@as(u8, 0), (try f.run(&.{".env"})).code);
    const k = try keptCtxOf(&f);
    const kp = try f.keptPath("a/.gitignore");
    try fsutil.ensureDir(std.fs.path.dirname(kp).?);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = kp, .data = "*.tmp\n" });
    const h = try kept.content.hashPath(a, kp);
    try kept.store.writeFact(a, k.layout, "github.com/acme/widget", k.machine_id, "a/.gitignore", .file, &h.hex);
    try f.write("a/.gitignore", "*.log\n");

    for ([_][]const u8{ "--take-kept", "--take-local" }) |flag| {
        const got = try f.run(&.{ flag, "a/.gitignore" });
        try testing.expectEqual(@as(u8, 1), got.code);
        try expectContains(got.err, "git reads it only as a regular file, never through a link");
        try testing.expectEqual(kept.content.Entry.file, try kept.content.entryAt(try f.path("a/.gitignore")));
        try testing.expectEqualStrings("*.log\n", try kept.content.readSmall(a, try f.path("a/.gitignore")));
        try testing.expectEqualStrings("*.tmp\n", try kept.content.readSmall(a, kp));
    }
}

test "keep: more than 10 MiB asks on a terminal, refuses without one, and --yes answers" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const big = try a.alloc(u8, ask_above + 1);
    @memset(big, 'x');
    try f.write("big.bin", big);

    ui.stdin_terminal_for_test = false;
    const no_tty = try f.run(&.{"big.bin"});
    try testing.expectEqual(@as(u8, 1), no_tty.code);
    try expectContains(no_tty.err, try std.fmt.allocPrint(a, "more than 10 MiB; to keep it, run: holt keep --yes {s}", .{try ui.quotePath(a, app.envOf_current(), try f.path("big.bin"))}));
    try testing.expect(!try f.linked("big.bin"));

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "n\n";
    const declined = try f.run(&.{"big.bin"});
    try testing.expectEqual(@as(u8, 1), declined.code);
    try expectContains(declined.out, "Keep it? [y/N]");
    try testing.expect(!try f.linked("big.bin"));

    ui.stdin_for_test = "y\n";
    const asked = try f.run(&.{"big.bin"});
    try testing.expectEqual(@as(u8, 0), asked.code);
    try testing.expect(try f.linked("big.bin"));

    try std.Io.Dir.cwd().deleteFile(fsutil.io(), try f.path("big.bin"));
    try f.write("big2.local", big);
    ui.stdin_terminal_for_test = false;
    const yes = try f.run(&.{ "--yes", "big2.local" });
    try testing.expectEqual(@as(u8, 0), yes.code);
    try testing.expect(try f.linked("big2.local"));
}

test "keep: the first store asks when the synced root holds projects, refuses without a terminal, and --yes creates it" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try testutil.writeMarker(f.a(), try f.ws.projectsRoot(f.a()), "acme", "proj", .empty, .empty);
    try f.write(".env", "x");

    ui.stdin_terminal_for_test = false;
    const refused = try f.run(&.{".env"});
    try testing.expectEqual(@as(u8, 1), refused.code);
    try expectContains(refused.err, "no kept/ found");
    try expectContains(refused.err, try std.fmt.allocPrint(f.a(), "to create a new kept store, run: holt keep --yes {s}", .{try ui.quotePath(f.a(), app.envOf_current(), try f.path(".env"))}));
    try testing.expect(!fsutil.exists(try std.fs.path.join(f.a(), &.{ f.ws.cfg.synced_root, "kept" })));

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "n\n";
    const declined = try f.run(&.{".env"});
    try testing.expectEqual(@as(u8, 1), declined.code);
    try expectContains(declined.out, "No kept/ found; if another machine keeps files, wait for your cloud client to finish downloading. Create a new kept store? [y/N]");

    ui.stdin_terminal_for_test = false;
    const yes = try f.run(&.{ "-y", ".env" });
    try testing.expectEqual(@as(u8, 0), yes.code);
    try testing.expect(try f.linked(".env"));
}

test "keep: a kept copy with different content names the take commands with the quoted path" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "one");
    _ = try f.run(&.{".env"});
    try std.Io.Dir.cwd().deleteFile(fsutil.io(), try f.path(".env"));
    try f.write(".env", "two");
    const got = try f.run(&.{".env"});
    try testing.expectEqual(@as(u8, 1), got.code);
    const qp = try ui.quotePath(f.a(), app.envOf_current(), try f.path(".env"));
    try expectContains(got.err, try std.fmt.allocPrint(f.a(), "holt keep --take-local {s}, or holt keep --take-kept {s}", .{ qp, qp }));
    if (ui.native_shell == .posix) try testing.expect(std.mem.startsWith(u8, qp, "~/"));
}

test "keep: outside any clone or hub root is refused with the reason" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const elsewhere = try std.fs.path.join(f.a(), &.{ f.sb.root, "synced", "loose.txt" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = elsewhere, .data = "x" });
    const got = try f.run(&.{elsewhere});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "already in the synced folder");
    try testing.expect(fsutil.exists(elsewhere));
}

test "keep: a clone outside code_root is refused with the adopt hint" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const outside = try std.fs.path.join(a, &.{ f.sb.root, "loose-clone" });
    try fsutil.ensureDir(outside);
    try testutil.runGit(&f.sb, outside, &.{ "init", "-q" });
    const file = try std.fs.path.join(a, &.{ outside, "x.env" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = file, .data = "x" });
    const got = try f.run(&.{file});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "is not under code_root");
    try expectContains(got.err, try std.fmt.allocPrint(a, "holt repo adopt {s}", .{try ui.quotePath(a, app.envOf_current(), try fsutil.realPathOrSelf(a, outside))}));
}

test "keep: a path in a linked worktree keeps under the clone's key" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const wt = try std.fs.path.join(a, &.{ f.ws.cfg.code_root, "github.com", "acme", "widget@worktrees", "side" });
    try testutil.runGit(&f.sb, f.clone, &.{ "worktree", "add", "-q", wt, "-b", "side" });
    const file = try std.fs.path.join(a, &.{ wt, ".env" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = file, .data = "wt" });
    const got = try f.run(&.{file});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("wt", try kept.content.readSmall(a, try f.keptPath(".env")));
}

test "keep --take-local and --take-kept: settle a path whose local copy differs; a path not kept names keep" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "kept");
    _ = try f.run(&.{".env"});
    try std.Io.Dir.cwd().deleteFile(fsutil.io(), try f.path(".env"));
    try f.write(".env", "local");

    const local = try f.run(&.{ "--take-local", ".env" });
    try testing.expectEqual(@as(u8, 0), local.code);
    try expectContains(local.out, "took the local copy");
    try expectContains(local.out, "the kept copy it replaced is in aside entry ");
    try testing.expectEqualStrings("local", try kept.content.readSmall(f.a(), try f.keptPath(".env")));

    try std.Io.Dir.cwd().deleteFile(fsutil.io(), try f.path(".env"));
    try f.write(".env", "discard me");
    const kept_ = try f.run(&.{ "--take-kept", ".env" });
    try testing.expectEqual(@as(u8, 0), kept_.code);
    try expectContains(kept_.out, "the local copy is in aside entry ");
    try testing.expect(try f.linked(".env"));
    try testing.expectEqualStrings("local", try kept.content.readSmall(f.a(), try f.path(".env")));

    const again = try f.run(&.{ "--take-kept", ".env" });
    try expectContains(again.out, "already linked");

    try f.write("new.local", "n");
    const not = try f.run(&.{ "--take-local", "new.local" });
    try testing.expectEqual(@as(u8, 1), not.code);
    try expectContains(not.err, try std.fmt.allocPrint(f.a(), "it is not kept (run: holt keep {s})", .{try ui.quotePath(f.a(), app.envOf_current(), try f.path("new.local"))}));
    const bad = try f.run(&.{ "--take-local", ".env", "other" });
    try testing.expectEqual(@as(u8, 2), bad.code);
}

test "keep --take-aside: makes an entry the kept copy and links it here; a bad entry is refused" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "first");
    _ = try f.run(&.{".env"});
    try f.write(".env", "second");
    const k = try keptCtxOf(&f);
    const e = (try kept.aside.findEntries(a, k.layout, "github.com/acme/widget", ".env", &(try kept.content.hashPath(a, try writeTmp(&f, "first"))).hex))[0];

    const got = try f.run(&.{ "--take-aside", e });
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, "made aside entry ");
    try expectContains(got.out, "linked ");
    try testing.expectEqualStrings("first", try kept.content.readSmall(a, try f.path(".env")));

    const none = try f.run(&.{ "--take-aside", "no-such" });
    try testing.expectEqual(@as(u8, 1), none.code);
    try expectContains(none.err, "no such aside entry");
}

fn keptCtxOf(f: *Fx) !kept.Ctx {
    const env = app.envOf_current();
    return .{ .alloc = f.a(), .env = env, .layout = .{ .synced_root = f.ws.cfg.synced_root }, .code_root = f.ws.cfg.code_root, .machine_id = try kept.machine.load(f.a(), env) };
}

fn writeTmp(f: *Fx, data: []const u8) ![]const u8 {
    const p = try std.fs.path.join(f.a(), &.{ f.sb.root, "probe" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = p, .data = data });
    return p;
}

test "keep --prune-aside: spares an entry an unsettled kept path names, and one --take-kept filled, until named" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "kept");
    _ = try f.run(&.{".env"});
    try fsutil.removePath(try f.path(".env"));
    try f.write(".env", "local");
    const k = try keptCtxOf(&f);
    var index = try kept.store.loadIndex(a, k.layout);
    const rep = try kept.reconcile.reconcile(k, &index, f.clone, .apply);
    const item = rep.find(".env", .local_differs).?;
    const held = item.entry.?;

    const spared = try f.run(&.{ "--prune-aside", "--yes" });
    try testing.expectEqual(@as(u8, 0), spared.code);
    try expectContains(spared.out, try std.fmt.allocPrint(a, "kept aside entry {s}: a kept path not yet settled names it (to remove it anyway, run: holt keep --prune-aside {s} --yes)\n", .{ held, held }));
    try testing.expect(try kept.aside.readManifest(a, k.layout, held) != null);

    try testing.expectEqual(@as(u8, 0), (try f.run(&.{ "--take-kept", ".env" })).code);
    index = try kept.store.loadIndex(a, k.layout);
    const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(fsutil.io()).nanoseconds, std.time.ns_per_ms));
    var taken: ?[]const u8 = null;
    for (try kept.ops.asideEntries(k, &index, now_ms, &kept.ops.Referenced{}, .verified)) |e| if (e.held == .taken) {
        taken = e.stamp;
    };
    const again = try f.run(&.{ "--prune-aside", "--yes" });
    try expectContains(again.out, try std.fmt.allocPrint(a, "kept aside entry {s}: holt keep --take-kept set content aside into it within the last 30 days", .{taken.?}));
    try testing.expect(try kept.aside.readManifest(a, k.layout, taken.?) != null);

    const named = try f.run(&.{ "--prune-aside", taken.?, "--yes" });
    try testing.expectEqual(@as(u8, 0), named.code);
    try expectContains(named.out, "removed 1 aside entry\n");
    try testing.expect(try kept.aside.readManifest(a, k.layout, taken.?) == null);
}

test "keep --prune-aside: spares entries less than 30 days old unless named; lists, asks on a terminal, refuses without one, --yes removes, --older-than filters" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const aside_dir = try std.fs.path.join(f.a(), &.{ f.ws.cfg.synced_root, "kept", ".holt-aside" });

    const old = try f.run(&.{ "--prune-aside", "--older-than", "1" });
    try testing.expectEqual(@as(u8, 0), old.code);
    try expectContains(old.out, "no aside entries to remove");

    const young = try f.run(&.{ "--prune-aside", "--yes" });
    try testing.expectEqual(@as(u8, 0), young.code);
    try expectContains(young.out, ": it is less than 30 days old, and another machine or an unfinished operation may still need it (to remove it anyway, run: holt keep --prune-aside ");
    try expectContains(young.out, "no aside entries to remove");
    try testutil.ageAsideEntries(f.a(), f.ws.cfg.synced_root);

    ui.stdin_terminal_for_test = false;
    const no_tty = try f.run(&.{"--prune-aside"});
    try testing.expectEqual(@as(u8, 1), no_tty.code);
    try expectContains(no_tty.err, "holt: not removing 1 aside entry (1 B) without a terminal; to remove it, run: holt keep --prune-aside --yes\n");

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "n\n";
    const declined = try f.run(&.{"--prune-aside"});
    try expectContains(declined.out, "nothing removed");

    const yes = try f.run(&.{ "--prune-aside", "--yes" });
    try testing.expectEqual(@as(u8, 0), yes.code);
    try expectContains(yes.out, "removed 1 aside entry");
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), aside_dir, .{ .iterate = true });
    defer d.close(fsutil.io());
    var it = d.iterate();
    try testing.expect(try it.next(fsutil.io()) == null);
    const usage = try f.run(&.{ "--older-than", "3" });
    try testing.expectEqual(@as(u8, 2), usage.code);
}

/// The name of the one aside entry of `f`'s store.
fn onlyEntry(f: *Fx) ![]const u8 {
    var d = try std.Io.Dir.cwd().openDir(fsutil.io(), try std.fs.path.join(f.a(), &.{ f.ws.cfg.synced_root, "kept", ".holt-aside" }), .{ .iterate = true });
    defer d.close(fsutil.io());
    var it = d.iterate();
    const e = (try it.next(fsutil.io())) orelse return error.TestUnexpectedResult;
    const name = try f.a().dupe(u8, e.name);
    if (try it.next(fsutil.io()) != null) return error.TestUnexpectedResult;
    return name;
}

test "keep --prune-aside: without names, an old entry not here whole is spared, since it may still be arriving, and the hinted command removes it" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const k = try keptCtxOf(&f);
    try std.Io.Dir.cwd().deleteTree(fsutil.io(), try std.fs.path.join(a, &.{ try k.layout.asideDir(a), try onlyEntry(&f), "data" }));
    try testutil.ageAsideEntries(a, f.ws.cfg.synced_root);
    const stamp = try onlyEntry(&f);

    const spared = try f.run(&.{ "--prune-aside", "--yes" });
    try testing.expectEqual(@as(u8, 0), spared.code);
    try expectContains(spared.out, try std.fmt.allocPrint(a, "kept aside entry {s}: it is not here whole (its manifest is missing or unreadable, or its content does not match it or cannot be read), so it may still be arriving (to remove it anyway, run: holt keep --prune-aside {s} --yes)\n", .{ stamp, stamp }));
    try expectContains(spared.out, "no aside entries to remove");
    try testing.expect(try kept.aside.readManifest(a, k.layout, stamp) != null);

    const named = try f.run(&.{ "--prune-aside", stamp, "--yes" });
    try testing.expectEqual(@as(u8, 0), named.code);
    try expectContains(named.out, "removed 1 aside entry\n");
    try testing.expect(try kept.aside.readManifest(a, k.layout, stamp) == null);
}

test "keep --prune-aside: a named entry a purge names needs --yes, even on a terminal, since another machine may still restore from it" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const stamp = try onlyEntry(&f);
    const k = try keptCtxOf(&f);
    try kept.store.writePurged(a, k.layout, "github.com/acme/widget", .{ .rel = "gone.txt", .entry = stamp });

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "y\n";
    const refused = try f.run(&.{ "--prune-aside", stamp });
    try expectContains(refused.out, try std.fmt.allocPrint(a, "kept aside entry {s}: a purge set it aside, and another machine may still restore from it (to remove it anyway, run: holt keep --prune-aside {s} --yes)\n", .{ stamp, stamp }));
    try testing.expect(try kept.aside.readManifest(a, k.layout, stamp) != null);

    const named = try f.run(&.{ "--prune-aside", stamp, "--yes" });
    try testing.expectEqual(@as(u8, 0), named.code);
    try expectContains(named.out, "removed 1 aside entry\n");
    try testing.expect(try kept.aside.readManifest(a, k.layout, stamp) == null);
    try testing.expect(try kept.store.isPruned(a, k.layout, stamp));
}

test "keep --prune-aside: the remove-anyway hint for an entry a purge names carries --yes, so running it removes the entry" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const stamp = try onlyEntry(&f);
    const k = try keptCtxOf(&f);
    try kept.store.writePurged(a, k.layout, "github.com/acme/widget", .{ .rel = "gone.txt", .entry = stamp });

    const spared = try f.run(&.{"--prune-aside"});
    try testing.expectEqual(@as(u8, 0), spared.code);
    const lead = "(to remove it anyway, run: ";
    const at = std.mem.indexOf(u8, spared.out, lead) orelse return error.TestUnexpectedResult;
    const rest = spared.out[at + lead.len ..];
    const hint = rest[0..std.mem.indexOf(u8, rest, ")\n").?];
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "holt keep --prune-aside {s} --yes", .{stamp}), hint);
    var args = std.mem.tokenizeScalar(u8, hint["holt keep ".len..], ' ');
    var argv: std.ArrayList([]const u8) = .empty;
    while (args.next()) |x| try argv.append(a, x);
    const removed = try f.run(argv.items);
    try expectContains(removed.out, "removed 1 aside entry\n");
    try testing.expect(try kept.aside.readManifest(a, k.layout, stamp) == null);
}

test "keep --prune-aside: a named entry whose own manifest says a purge set it aside needs --yes and is recorded pruned, before the purge's mark has synced" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const stamp = try onlyEntry(&f);
    const k = try keptCtxOf(&f);
    const manifest = try std.fs.path.join(a, &.{ try k.layout.asideDir(a), stamp, "manifest" });
    const text = try kept.content.readSmall(a, manifest);
    const reason = (try kept.aside.readManifest(a, k.layout, stamp)).?.reason;
    const was = try std.fmt.allocPrint(a, "\"reason\": \"{s}\"", .{reason});
    try testing.expect(std.mem.indexOf(u8, text, was) != null);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = manifest, .data = try std.mem.replaceOwned(u8, a, text, was, "\"reason\": \"purged\"") });
    try testing.expectEqualStrings("purged", (try kept.aside.readManifest(a, k.layout, stamp)).?.reason);

    const refused = try f.run(&.{ "--prune-aside", stamp });
    try expectContains(refused.out, try std.fmt.allocPrint(a, "kept aside entry {s}: a purge set it aside, and another machine may still restore from it (to remove it anyway, run: holt keep --prune-aside {s} --yes)\n", .{ stamp, stamp }));
    try testing.expect(try kept.aside.readManifest(a, k.layout, stamp) != null);

    const named = try f.run(&.{ "--prune-aside", stamp, "--yes" });
    try expectContains(named.out, "removed 1 aside entry\n");
    try testing.expect(try kept.store.isPruned(a, k.layout, stamp));
}

test "keep --prune-aside and doctor: an old aside entry whose data cannot be read is reported as not here whole, never a failure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const k = try keptCtxOf(&f);
    try testutil.ageAsideEntries(a, f.ws.cfg.synced_root);
    const stamp = try onlyEntry(&f);
    const data = try std.fs.path.join(a, &.{ try k.layout.asideDir(a), stamp, "data" });
    const proc = @import("../proc.zig");
    const rc = try proc.runEnv(a, &.{ "/bin/sh", "-c", "/usr/bin/find \"$0\" -type f -exec /bin/chmod 000 {} +", data }, null, null);
    try testing.expectEqual(@as(u8, 0), rc.status);
    defer _ = proc.runEnv(a, &.{ "/bin/chmod", "-R", "u+rwX", data }, null, null) catch {};
    const probe = try proc.runEnv(a, &.{ "/bin/sh", "-c", "/usr/bin/find \"$0\" -type f -exec /bin/cat {} +", data }, null, null);
    if (probe.status == 0) return error.SkipZigTest;

    const pruned = try f.run(&.{ "--prune-aside", "--yes" });
    try testing.expectEqual(@as(u8, 0), pruned.code);
    try expectContains(pruned.out, try std.fmt.allocPrint(a, "kept aside entry {s}: it is not here whole", .{stamp}));
    _ = try testutil.runCmd(a, @import("doctor.zig").command.run, f.ws, &.{});
    try testing.expect(try kept.aside.readManifest(a, k.layout, stamp) != null);
}

test "keep --from: copies a left-behind key's kept files and names unkeep --repo" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const k = try keptCtxOf(&f);
    try fsutil.ensureDir(try k.layout.keptDir(a));
    const old = "github.com/old/widget";
    const root = (try kept.clone.defaultRoot(a, f.clone)).?;
    try kept.store.createExclusive(a, try k.layout.reserved(a, old, kept.store.record_basename), try std.fmt.allocPrint(a, "{{\"version\": 1, \"root\": \"{s}\"}}", .{root}));
    const copy = try k.layout.copyPath(a, old, ".env");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = copy, .data = "old" });
    const h = try kept.content.hashPath(a, copy);
    try kept.store.writeFact(a, k.layout, old, "000000000000000f", ".env", .file, &h.hex);

    const got = try f.run(&.{ "--from", old });
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, "copied .env from github.com/old/widget");
    try expectContains(got.out, "linked ");
    try expectContains(got.out, "holt unkeep --repo github.com/old/widget");
    try testing.expect(try f.linked(".env"));

    const none = try f.run(&.{ "--from", "github.com/no/such" });
    try testing.expectEqual(@as(u8, 1), none.code);
    try expectContains(none.err, "no kept files are filed under");
}

test "keep --review without a terminal lists each candidate with its command and exits 1" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "x");
    try f.write("app.local", "y");
    ui.stdin_terminal_for_test = false;
    const got = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.out, try std.fmt.allocPrint(f.a(), "run: holt keep {s}", .{try ui.quotePath(f.a(), app.envOf_current(), try f.path(".env"))}));
    try expectContains(got.out, "2 files not kept");
    try testing.expect(!fsutil.exists(try std.fs.path.join(f.a(), &.{ f.ws.cfg.synced_root, "kept" })));
}

test "keep --review without a terminal names keep --yes while kept/ is absent in a synced folder holding projects, and that keep settles it" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try testutil.writeMarker(a, try f.ws.projectsRoot(a), "acme", "proj", .empty, .empty);
    try f.write(".env", "x");
    ui.stdin_terminal_for_test = false;
    const got = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 1), got.code);
    const p = try ui.quotePath(a, app.envOf_current(), try f.path(".env"));
    try expectContains(got.out, try std.fmt.allocPrint(a, " - run: holt keep --yes {s}\n", .{p}));
    const kept_ = try f.run(&.{ "--yes", try f.path(".env") });
    try testing.expectEqual(@as(u8, 0), kept_.code);
    try testing.expect(try f.linked(".env"));
    try expectContains((try f.run(&.{"--review"})).out, "nothing to review");
}

test "keep --review without a terminal shows a name holding a control character safely and names no command for it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write("a\x1b[2Jb.local", "y");
    ui.stdin_terminal_for_test = false;
    const got = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOfScalar(u8, got.out, 0x1b) == null);
    try expectContains(got.out, "a\\x1b[2Jb.local (1 B): the name holds a control character: rename it, or skip it (holt keep --review)\n");
    try testing.expect(!contains(got.out, "run: holt keep"));
}

test "keep --review on a terminal offers only skip for a name holding a control character, and the skip settles it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write("a\x01b.local", "y");
    try f.write("c\x01d.local", "z");
    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "k\ne\ns\ns\n";
    const got = try f.run(&.{ "--review", "--all" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, "a\\x01b.local (file, 1 B; the name holds a control character, so it can only be skipped): [s]kip, [q]uit, [n]ever ask again?");
    try testing.expect(!contains(got.out, "[k]eep"));
    try testing.expect(!contains(got.out, "keep [e]verywhere"));
    try testing.expect(!contains(got.err, "cannot keep"));
    try expectContains(got.out, "added '/a\\x01b.local' to ");
    try testing.expect(std.mem.indexOfScalar(u8, got.out, 0x01) == null);
    try testing.expectEqualStrings("/a\x01b.local\n/c\x01d.local\n", try kept.patterns.repoSkipText(f.a(), .{ .synced_root = f.ws.cfg.synced_root }, "github.com/acme/widget", null));
    try expectContains((try f.run(&.{"--review"})).out, "nothing to review");
}

test "keep --review on a terminal: keep, skip, quit; kept/ is created at the first answer that writes" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    try f.write("app.local", "y");
    try f.write("z.local", "z");
    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "bogus\nk\ns\nq\n";
    const got = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, "[n]ever ask again");
    try testing.expect(try f.linked(".env"));
    try expectContains(got.out, "added '/app.local' to ");
    const skip = try kept.patterns.repoSkipText(a, .{ .synced_root = f.ws.cfg.synced_root }, "github.com/acme/widget", null);
    try testing.expectEqualStrings("/app.local\n", skip);
    try testing.expect(!try f.linked("z.local"));

    ui.stdin_terminal_for_test = false;
    const after = try f.run(&.{"--review"});
    try expectContains(after.out, "1 file not kept");
}

test "keep --review: keep everywhere adds an auto pattern, skip everywhere a skip pattern, never turns kept files off" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    try f.write("app.local", "y");
    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "e\nv\n";
    const got = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, ".env (file, 1 B; keep everywhere also matches 0 other repos): [k]eep, keep [e]verywhere");
    try expectContains(got.out, "added '.env' to ");
    try expectContains(got.out, "added 'app.local' to ");
    const layout: kept.store.Layout = .{ .synced_root = f.ws.cfg.synced_root };
    try testing.expect(contains(try kept.patterns.globalText(a, layout, .auto, null), "\n.env\n"));
    try testing.expect(contains(try kept.patterns.globalText(a, layout, .skip, null), "\napp.local\n"));

    try f.write("third.local", "t");
    ui.stdin_for_test = "n\n";
    const off = try f.run(&.{"--review"});
    try expectContains(off.out, "kept files turned off");
    try testing.expect(fsutil.exists(try std.fs.path.join(a, &.{ f.ws.cfg.synced_root, ".holt-kept-off" })));
}

test "keep --review: never ask again is accepted as the prompt spells it" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "never ask again\n";
    const got = try f.run(&.{"--review"});
    try expectContains(got.out, "[n]ever ask again?");
    try expectContains(got.out, "kept files turned off");
    try testing.expect(fsutil.exists(try std.fs.path.join(a, &.{ f.ws.cfg.synced_root, ".holt-kept-off" })));
}

test "keep --review --all groups a pattern shared by repos; a hub root's entries are offered" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const bare2 = try testutil.makeBareRepo(&f.sb, "gadget.git");
    defer f.sb.alloc.free(bare2);
    const other = try fsutil.joinSlashy(a, f.ws.cfg.code_root, "github.com/acme/gadget");
    try testutil.runGit(&f.sb, null, &.{ "clone", "-q", bare2, other });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, other, ".git/info/exclude"), .data = ".env\n" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, other, ".env"), .data = "g" });
    try f.write(".env", "w");
    try testutil.writeMarker(a, try f.ws.projectsRoot(a), "acme", "proj", .empty, .empty);
    const hub = try std.fs.path.join(a, &.{ f.ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(try std.fs.path.join(a, &.{ f.ws.cfg.synced_root, "projects", "acme", "proj" }));
    try fsutil.ensureDir(hub);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ hub, "notes.md" }), .data = "n" });

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "e\ny\nk\n";
    const got = try f.run(&.{ "--review", "--all" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, ".env in 2 repos (keep everywhere also matches 0 other repos): keep [e]verywhere, skip e[v]erywhere, [r]eview each, [q]uit, [n]ever ask again?");
    try testing.expect(try f.linked(".env"));
    try testing.expectEqual(kept.content.Entry.symlink, try kept.content.entryAt(try fsutil.joinSlashy(a, other, ".env")));
    try testing.expectEqual(kept.content.Entry.symlink, try kept.content.entryAt(try std.fs.path.join(a, &.{ hub, "notes.md" })));
}

test "keep --review: a file git reads only as a regular file is offered skip, skip everywhere, and quit, saying why, and --all groups it nowhere" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const bare2 = try testutil.makeBareRepo(&f.sb, "gadget.git");
    defer f.sb.alloc.free(bare2);
    const other = try fsutil.joinSlashy(a, f.ws.cfg.code_root, "github.com/acme/gadget");
    try testutil.runGit(&f.sb, null, &.{ "clone", "-q", bare2, other });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, other, ".git/info/exclude"), .data = ".gitattributes\n" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, other, ".gitattributes"), .data = "g" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, f.clone, ".git/info/exclude"), .data = ".gitattributes\n" });
    try f.write(".gitattributes", "w");

    ui.stdin_terminal_for_test = false;
    const listed = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 1), listed.code);
    try expectContains(listed.out, try std.fmt.allocPrint(a, "not kept: {s} (1 B), which git reads only as a regular file, can only be skipped - in a terminal, run: holt keep --review {s}\n", .{ try fsutil.contractTilde(a, app.envOf_current(), try f.path(".gitattributes")), try ui.quotePath(a, app.envOf_current(), f.clone) }));

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "v\n";
    const got = try f.run(&.{ "--review", "--all" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(!contains(got.out, "in 2 repos"));
    try expectContains(got.out, "/.gitattributes (file, 1 B; git reads it only as a regular file, never through a link, so it cannot be kept): [s]kip, skip e[v]erywhere, [q]uit?");
    try testing.expect(!contains(got.out, "[k]eep"));
    try testing.expect(!contains(got.out, "[n]ever"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.out, "[s]kip"));
    try testing.expect(contains(try kept.patterns.globalText(a, .{ .synced_root = f.ws.cfg.synced_root }, .skip, null), "\n.gitattributes\n"));
    try testing.expectEqual(kept.content.Entry.file, try kept.content.entryAt(try f.path(".gitattributes")));
    try testing.expectEqual(kept.content.Entry.file, try kept.content.entryAt(try fsutil.joinSlashy(a, other, ".gitattributes")));
}

test "keep --review: a candidate in a linked worktree is kept from that working tree" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const wt = try std.fs.path.join(a, &.{ f.ws.cfg.code_root, "github.com", "acme", "widget@worktrees", "side" });
    try testutil.runGit(&f.sb, f.clone, &.{ "worktree", "add", "-q", wt, "-b", "side" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ wt, ".env" }), .data = "from the linked tree" });
    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "k\n";
    const got = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("from the linked tree", try kept.content.readSmall(a, try f.keptPath(".env")));
    try testing.expectEqual(kept.content.Entry.symlink, try kept.content.entryAt(try std.fs.path.join(a, &.{ wt, ".env" })));
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try f.path(".env")));
}

test "keep: hub mode moves a loose hub file into content and leaves a symlink; again it is already kept" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try testutil.writeMarker(a, try f.ws.projectsRoot(a), "acme", "proj", .empty, .empty);
    const content = try std.fs.path.join(a, &.{ f.ws.cfg.synced_root, "projects", "acme", "proj" });
    const hub = try std.fs.path.join(a, &.{ f.ws.cfg.hub_root, "acme", "proj" });
    try fsutil.ensureDir(hub);
    const loose = try std.fs.path.join(a, &.{ hub, "notes.md" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = loose, .data = "hello\n" });
    try std.process.setCurrentPath(fsutil.io(), hub);

    const got = try f.run(&.{"notes.md"});
    try testing.expectEqual(@as(u8, 0), got.code);
    switch (try fsutil.linkState(a, loose)) {
        .symlink => |t| try testing.expectEqualStrings(try std.fs.path.join(a, &.{ content, "notes.md" }), t),
        else => return error.TestUnexpectedResult,
    }
    const again = try f.run(&.{"notes.md"});
    try testing.expectEqual(@as(u8, 0), again.code);
    try expectContains(again.out, "already kept");

    const reserved = try f.run(&.{"code"});
    try testing.expectEqual(@as(u8, 1), reserved.code);
    try expectContains(reserved.err, "reserved");
    const missing = try f.run(&.{"does-not-exist.md"});
    try testing.expectEqual(@as(u8, 1), missing.code);
    try expectContains(missing.err, "no such entry");

    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ content, "dup.md" }), .data = "existing\n" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ hub, "dup.md" }), .data = "loose\n" });
    const dup = try f.run(&.{"dup.md"});
    try testing.expectEqual(@as(u8, 1), dup.code);
    try expectContains(dup.err, "already has");

    const assets = try std.fs.path.join(a, &.{ hub, "assets" });
    try fsutil.ensureDir(assets);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ assets, "logo.png" }), .data = "b" });
    const dir = try f.run(&.{"assets"});
    try testing.expectEqual(@as(u8, 0), dir.code);
    try testing.expect(fsutil.exists(try std.fs.path.join(a, &.{ content, "assets", "logo.png" })));

    const deeper = try std.fs.path.join(a, &.{ hub, "sub" });
    try fsutil.ensureDir(deeper);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ deeper, "x" }), .data = "x" });
    const deep = try f.run(&.{"sub/x"});
    try testing.expectEqual(@as(u8, 1), deep.code);
    try expectContains(deep.err, "directly at the project's hub root");
}

test "keep: an org named kept is an org like any other" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try testutil.writeMarker(f.a(), try f.ws.projectsRoot(f.a()), "kept", "x", .empty, .empty);
    try f.write(".env", "x");
    const got = try f.run(&.{ "--yes", ".env" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(try f.linked(".env"));
}

test "keep: a file inside a kept directory whose link is gone here is not already kept; the take commands for the directory are named" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write("notes/one.md", "1");
    _ = try f.run(&.{"notes"});
    try fsutil.removePath(try f.path("notes"));
    try f.write("notes/new.md", "only here");

    const got = try f.run(&.{"notes/new.md"});
    try testing.expectEqual(@as(u8, 1), got.code);
    const qd = try ui.quotePath(f.a(), app.envOf_current(), try f.path("notes"));
    try expectContains(got.err, "which is not linked here");
    try expectContains(got.err, try std.fmt.allocPrint(f.a(), "holt keep --take-local {s}", .{qd}));
    try expectContains(got.err, try std.fmt.allocPrint(f.a(), "holt keep --take-kept {s}", .{qd}));
    try testing.expect(!contains(got.out, "already kept"));
    try testing.expectEqualStrings("only here", try kept.content.readSmall(f.a(), try f.path("notes/new.md")));
}

test "keep --review: content the block hides at a kept path is offered only the takes, and without a terminal names them" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "kept");
    _ = try f.run(&.{".env"});
    try std.Io.Dir.cwd().deleteFile(fsutil.io(), try f.path(".env"));
    try f.write(".env", "broken link, new content");
    const qp = try ui.quotePath(f.a(), app.envOf_current(), try f.path(".env"));

    ui.stdin_terminal_for_test = false;
    const listed = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 1), listed.code);
    try expectContains(listed.out, try std.fmt.allocPrint(f.a(), "run: holt keep --take-local {s}, or holt keep --take-kept {s}", .{ qp, qp }));
    try testing.expect(!contains(listed.out, try std.fmt.allocPrint(f.a(), "run: holt keep {s}\n", .{qp})));

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "s\ne\nk\n";
    const refused = try f.run(&.{"--review"});
    try expectContains(refused.out, "hidden from git by holt's block and held nowhere else: take [l]ocal, take kep[t], [q]uit?");
    try testing.expect(!contains(refused.out, "[s]kip"));
    try testing.expectEqualStrings("", try kept.patterns.repoSkipText(f.a(), .{ .synced_root = f.ws.cfg.synced_root }, "github.com/acme/widget", null));
    try testing.expectEqualStrings("kept", try kept.content.readSmall(f.a(), try f.keptPath(".env")));

    _ = try testutil.runCmd(f.a(), @import("sync.zig").command.run, f.ws, &.{});
    const again = try f.run(&.{"--review"});
    try expectContains(again.out, "is hidden from git by holt's block; aside entry ");
    try expectContains(again.out, " also holds it: take [l]ocal, take kep[t], [q]uit?");

    ui.stdin_for_test = "l\n";
    const took = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 0), took.code);
    try testing.expect(try f.linked(".env"));
    try testing.expectEqualStrings("broken link, new content", try kept.content.readSmall(f.a(), try f.keptPath(".env")));
}

test "keep --review: a name holding a line break is offered nothing, since neither a keep nor a pattern can name it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write("x\n!.env.local", "x");
    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "e\nv\ns\nq\n";
    const got = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try expectContains(got.out, "!.env.local: the name holds a line break, which neither a keep nor a skip pattern can name: rename it; it is left as it is\n");
    try testing.expect(!contains(got.out, "[k]eep"));
    try testing.expect(!fsutil.exists(try std.fs.path.join(f.a(), &.{ f.ws.cfg.synced_root, "kept" })));
}

test "keep --review --all: keep everywhere adds no auto pattern when every keep fails" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    const bare2 = try testutil.makeBareRepo(&f.sb, "gadget.git");
    defer f.sb.alloc.free(bare2);
    const other = try fsutil.joinSlashy(a, f.ws.cfg.code_root, "github.com/acme/gadget");
    try testutil.runGit(&f.sb, null, &.{ "clone", "-q", bare2, other });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, other, ".git/info/exclude"), .data = "big.bin\n" });
    const big = try a.alloc(u8, ask_above + 1);
    @memset(big, 'x');
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, other, "big.bin"), .data = big });
    try f.write("big.bin", big);

    ui.stdin_terminal_for_test = true;
    ui.stdin_for_test = "e\nn\nn\nq\n";
    const got = try f.run(&.{ "--review", "--all" });
    try expectContains(got.out, "big.bin in 2 repos");
    try testing.expect(!contains(try kept.patterns.globalText(a, .{ .synced_root = f.ws.cfg.synced_root }, .auto, null), "big.bin"));
    try testing.expect(!contains(got.out, "added 'big.bin'"));
}

test "keep: the hint for a directory with a tracked file leaves out what the skip patterns name" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write("cfg/tracked.txt", "t");
    try f.write("cfg/local.txt", "l");
    try f.write("cfg/node_modules/dep/index.js", "d");
    try testutil.runGit(&f.sb, f.clone, &.{ "add", "cfg/tracked.txt" });
    try testutil.runGit(&f.sb, f.clone, &.{ "commit", "-q", "-m", "cfg" });
    const got = try f.run(&.{"cfg"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, try std.fmt.allocPrint(f.a(), "holt keep {s}", .{try ui.quotePath(f.a(), app.envOf_current(), try f.path("cfg/local.txt"))}));
    try testing.expect(!contains(got.err, "node_modules"));
}

test "sync: a path another machine kept whose copy has not arrived names the aside entry holding the local content before the ways out" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const k = try keptCtxOf(&f);
    try kept.store.writeFact(a, k.layout, "github.com/acme/widget", "000000000000000f", "a.local", .file, "a" ** 64);
    try kept.store.writeHost(a, k.layout, "000000000000000f", "laptop");
    try f.write("a.local", "mine");

    const synced = try testutil.runCmd(a, @import("sync.zig").command.run, f.ws, &.{});
    try testing.expectEqual(@as(u8, 1), synced.code);
    const entries = try kept.aside.findEntries(a, k.layout, "github.com/acme/widget", "a.local", null);
    try testing.expectEqual(@as(usize, 1), entries.len);
    const qp = try ui.quotePath(a, app.envOf_current(), try f.path("a.local"));
    try expectContains(synced.out, try std.fmt.allocPrint(a, "not linked: {s}: kept on laptop (machine 000000000000000f), not here yet, and its local content is set aside in aside entry {s}: waiting is the normal fix, until your cloud client downloads it; if it will never arrive, run holt unkeep {s} on laptop, or, if that machine is gone, retire it here - run: holt sync, or holt keep --retire-machine 000000000000000f\n", .{ qp, entries[0], qp }));
}

test "keep: a path only a retired machine kept, whose content an aside entry holds, hints taking that entry before giving the path up, and the take settles it" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const k = try keptCtxOf(&f);
    const key = "github.com/acme/widget";
    const src = try writeTmp(&f, "the laptop's copy");
    const e = try kept.aside.setAside(a, k.layout, "000000000000000f", key, "a.local", src, .kept_missing);
    try kept.store.writeFact(a, k.layout, key, "000000000000000f", "a.local", .file, &(try kept.content.hashFile(a, src)));
    try kept.store.writeHost(a, k.layout, "000000000000000f", "laptop");
    try testing.expectEqual(@as(u8, 0), (try f.run(&.{ "--retire-machine", "000000000000000f" })).code);

    const qp = try ui.quotePath(a, app.envOf_current(), try f.path("a.local"));
    const synced = try testutil.runCmd(a, @import("sync.zig").command.run, f.ws, &.{});
    try testing.expectEqual(@as(u8, 1), synced.code);
    try expectContains(synced.out, try std.fmt.allocPrint(a, "not linked: {s}: kept copy gone, and only a retired machine kept it; aside entry {s} holds its content: take it back, or give the path up - run: holt keep --take-aside {s}, or holt unkeep {s}\n", .{ qp, e.stamp, e.stamp, qp }));

    try testing.expectEqual(@as(u8, 0), (try f.run(&.{ "--take-aside", e.stamp })).code);
    try testing.expectEqual(@as(u8, 0), (try testutil.runCmd(a, @import("sync.zig").command.run, f.ws, &.{})).code);
    try testing.expectEqualStrings("the laptop's copy", try kept.content.readSmall(a, try f.path("a.local")));
}

test "keep: another machine's path whose kept copy has not arrived is refused, --yes included, and --take-local waits too" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const k = try keptCtxOf(&f);
    try kept.store.writeFact(a, k.layout, "github.com/acme/widget", "000000000000000f", "a.local", .file, "a" ** 64);
    try kept.store.writeHost(a, k.layout, "000000000000000f", "laptop");
    try f.write("a.local", "mine");

    const got = try f.run(&.{ "--yes", "a.local" });
    try testing.expectEqual(@as(u8, 1), got.code);
    const qp = try ui.quotePath(a, app.envOf_current(), try f.path("a.local"));
    const why = try std.fmt.allocPrint(a, "kept on laptop (machine 000000000000000f), not here yet: waiting is the normal fix, until your cloud client downloads it; if it will never arrive, run holt unkeep {s} on laptop, or, if that machine is gone, retire it here", .{qp});
    try expectContains(got.err, try std.fmt.allocPrint(a, "{s} - run: holt keep {s}, or holt keep --retire-machine 000000000000000f\n", .{ why, qp }));
    try testing.expect(!contains(got.err, "--yes"));
    try testing.expect(!try f.linked("a.local"));

    const take_ = try f.run(&.{ "--take-local", "a.local" });
    try testing.expectEqual(@as(u8, 1), take_.code);
    try expectContains(take_.err, try std.fmt.allocPrint(a, "{s} - run: holt keep --take-local {s}, or holt keep --retire-machine 000000000000000f\n", .{ why, qp }));
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try f.keptPath("a.local")));
    try testing.expectEqualStrings("mine", try kept.content.readSmall(a, try f.path("a.local")));

    const synced = try testutil.runCmd(a, @import("sync.zig").command.run, f.ws, &.{});
    try testing.expectEqual(@as(u8, 1), synced.code);
    try expectContains(synced.out, try std.fmt.allocPrint(a, "not linked: {s}: kept on laptop (machine 000000000000000f), not here yet, and its local content is set aside in aside entry ", .{qp}));
    try expectContains(synced.out, "- run: holt sync, or holt keep --retire-machine 000000000000000f\n");
    try testing.expect(!contains(synced.out, "not kept"));

    ui.stdin_terminal_for_test = false;
    const reviewed = try f.run(&.{"--review"});
    try testing.expectEqual(@as(u8, 1), reviewed.code);
    try expectContains(reviewed.out, try std.fmt.allocPrint(a, "not linked: {s}: {s} - run: holt sync, or holt keep --retire-machine 000000000000000f\n", .{ try fsutil.contractTilde(a, app.envOf_current(), try f.path("a.local")), why }));
    try testing.expect(!contains(reviewed.out, "not kept"));
    try testing.expect(!contains(reviewed.out, "--take-kept"));

    try testing.expectEqual(@as(u8, 0), (try f.run(&.{ "--retire-machine", "000000000000000f" })).code);
    const after = try testutil.runCmd(a, @import("sync.zig").command.run, f.ws, &.{});
    try expectContains(after.out, try std.fmt.allocPrint(a, "run: holt keep --take-local {s}\n", .{qp}));
    try testing.expectEqual(@as(u8, 0), (try f.run(&.{ "--take-local", "a.local" })).code);
    try testing.expectEqual(@as(u8, 0), (try testutil.runCmd(a, @import("sync.zig").command.run, f.ws, &.{})).code);
    try testing.expect(try f.linked("a.local"));
}

test "keep: a path inside a repository that is no clone, such as one at the home directory, is refused plainly, never with an adopt hint" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try testutil.runGit(&f.sb, f.sb.root, &.{ "init", "-q" });
    const loose = try std.fs.path.join(f.a(), &.{ f.sb.root, "notes.txt" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = loose, .data = "n" });
    const got = try f.run(&.{loose});
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "is not inside a clone under code_root");
    try testing.expect(!contains(got.err, "repo adopt"));
}

test "keep: a directory holding holt's link to a kept file is kept whole, taking the file in" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write("notes/a.md", "a");
    _ = try f.run(&.{"notes/a.md"});
    try f.write("notes/b.md", "b");
    const got = try f.run(&.{"notes"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(try f.linked("notes"));
    try testing.expectEqualStrings("a", try kept.content.readSmall(f.a(), try f.keptPath("notes/a.md")));
    try testing.expectEqualStrings("b", try kept.content.readSmall(f.a(), try f.keptPath("notes/b.md")));
}

test "keep --retire-machine records this machine, or a machine named by id, as retired in the kept store" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const k = try keptCtxOf(&f);

    const mine = try f.run(&.{"--retire-machine"});
    try testing.expectEqual(@as(u8, 0), mine.code);
    var host_buf: [kept.machine.host_name_max]u8 = undefined;
    try expectContains(mine.out, try std.fmt.allocPrint(a, "retired machine {s} ({s}, this machine) on {s} UTC: its records so far no longer block keep, --take-local, or unkeep\n", .{ k.machine_id, kept.machine.hostName(&host_buf), try kept.store.today(a) }));
    try testing.expectEqualStrings(try kept.store.today(a), (try kept.store.readRetired(a, k.layout, k.machine_id)).?.date);

    try kept.store.writeHost(a, k.layout, "00000000000000ff", "old-laptop");
    const other = try f.run(&.{ "--retire-machine", "00000000000000ff" });
    try testing.expectEqual(@as(u8, 0), other.code);
    try expectContains(other.out, "retired machine 00000000000000ff (old-laptop) on ");
    try testing.expect(try kept.store.readRetired(a, k.layout, "00000000000000ff") != null);
    try testing.expectEqual(@as(u8, 2), (try f.run(&.{ "--retire-machine", "not-an-id" })).code);
    try testing.expectEqual(@as(u8, 2), (try f.run(&.{ "--retire-machine", "--review" })).code);
}

test "keep --retire-machine refuses an id no machine wrote kept files from, naming the machines that did, and writes nothing" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const k = try keptCtxOf(&f);

    const got = try f.run(&.{ "--retire-machine", "00000000000000fe" });
    try testing.expectEqual(@as(u8, 1), got.code);
    try expectContains(got.err, "cannot retire 00000000000000fe: no machine with this id has written kept files");
    var host_buf: [kept.machine.host_name_max]u8 = undefined;
    try expectContains(got.err, try std.fmt.allocPrint(a, "  {s} ({s}, this machine)\n", .{ k.machine_id, kept.machine.hostName(&host_buf) }));
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try kept.store.machineDir(a, k.layout, "00000000000000fe")));
}

test "keep --unretire-machine removes a retirement, and refuses a machine that is not retired" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    const a = f.a();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    const k = try keptCtxOf(&f);
    try testing.expectEqual(@as(u8, 0), (try f.run(&.{"--retire-machine"})).code);

    const got = try f.run(&.{"--unretire-machine"});
    try testing.expectEqual(@as(u8, 0), got.code);
    var host_buf: [kept.machine.host_name_max]u8 = undefined;
    try expectContains(got.out, try std.fmt.allocPrint(a, "machine {s} ({s}, this machine) is no longer retired", .{ k.machine_id, kept.machine.hostName(&host_buf) }));
    try testing.expect(try kept.store.readRetired(a, k.layout, k.machine_id) == null);
    const again = try f.run(&.{ "--unretire-machine", k.machine_id });
    try testing.expectEqual(@as(u8, 1), again.code);
    try expectContains(again.err, "is not retired");
    try testing.expectEqual(@as(u8, 2), (try f.run(&.{ "--unretire-machine", "--retire-machine" })).code);
}

test "keep on a retired machine warns once that its new kept changes count again" {
    var f: Fx = undefined;
    try fixture(&f);
    defer f.deinit();
    try f.write(".env", "x");
    _ = try f.run(&.{".env"});
    try testing.expectEqual(@as(u8, 0), (try f.run(&.{"--retire-machine"})).code);

    try f.write("a.local", "a");
    try f.write("b.local", "b");
    const got = try f.run(&.{ "a.local", "b.local" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.err, "this machine was retired on "));
    try expectContains(got.err, "; its new kept changes count again");
    try testing.expect(!contains((try f.run(&.{".env"})).err, "was retired"));
}

test "keep, unkeep, review, the takes, doctor --retire, and restore: after a backend switch that left kept/ behind, each names where kept/ is and where to copy it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try @import("../kept_cmd.zig").TestWorld.init(a, &sb, true);
    defer w.deinit();
    for (try w.ws.list(a)) |p| _ = try @import("../hub.zig").reconcile(a, &w.ws, &p, false);
    try w.keep(a, ".clasp.json", "{}\n");
    const env = try w.write(a, ".env", "E=1\n");

    var moved = w.ws;
    moved.cfg.synced_root = try std.fs.path.join(a, &.{ sb.root, "new-synced" });
    try fsutil.copyTree(a, try std.fs.path.join(a, &.{ w.ws.cfg.synced_root, "projects" }), try std.fs.path.join(a, &.{ moved.cfg.synced_root, "projects" }));
    for (try moved.list(a)) |p| _ = try @import("../hub.zig").reconcile(a, &moved, &p, false);
    const line = try std.fmt.allocPrint(a, "holt: kept/ is at {s}: copy it to {s}\n", .{ try ui.quotePath(a, app.envOf_current(), w.ws.cfg.synced_root), try ui.quotePath(a, app.envOf_current(), moved.cfg.synced_root) });
    const clasp = try fsutil.joinSlashy(a, w.clone, ".clasp.json");
    const unkeep_cmd = @import("unkeep.zig").command;

    ui.stdin_terminal_for_test = false;
    defer ui.stdin_terminal_for_test = null;
    const runs = [_]struct { cmd: *const fn (ctx: *app.Ctx) anyerror!u8, argv: []const []const u8 }{
        .{ .cmd = command.run, .argv = &.{ env, "--yes" } },
        .{ .cmd = command.run, .argv = &.{ "--review", w.clone } },
        .{ .cmd = command.run, .argv = &.{ "--take-local", clasp } },
        .{ .cmd = command.run, .argv = &.{ "--take-kept", clasp } },
        .{ .cmd = command.run, .argv = &.{ "--take-aside", "20260101T000000.000Z-000000000000000f-00000000" } },
        .{ .cmd = unkeep_cmd.run, .argv = &.{clasp} },
    };
    for (runs) |r| {
        const got = try testutil.runCmd(a, r.cmd, moved, r.argv);
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expectEqualStrings(line, got.err);
    }
    try testing.expectEqual(kept.content.Entry.absent, try kept.content.entryAt(try std.fs.path.join(a, &.{ moved.cfg.synced_root, "kept" })));

    const retire = try testutil.runCmd(a, @import("doctor.zig").command.run, moved, &.{"--retire"});
    try testing.expectEqual(@as(u8, 1), retire.code);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "retire: nothing exists only on this machine: FAIL\n  {s}\n", .{line["holt: ".len .. line.len - 1]}), retire.out);
    const restored = try testutil.runCmd(a, @import("restore.zig").command.run, moved, &.{});
    try testing.expect(contains(restored.out, line["holt: ".len..]));
    try testing.expect(!contains(restored.out, "linked 0 kept files"));

    try fsutil.copyTree(a, try std.fs.path.join(a, &.{ w.ws.cfg.synced_root, "kept" }), try std.fs.path.join(a, &.{ moved.cfg.synced_root, "kept" }));
    try testing.expectEqual(@as(u8, 0), (try testutil.runCmd(a, @import("sync.zig").command.run, moved, &.{})).code);
    try testing.expectEqual(@as(u8, 0), (try testutil.runCmd(a, command.run, moved, &.{ env, "--yes" })).code);
}
