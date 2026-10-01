//! The user's pattern lists: `.holt-skip` (never offered for keeping) and
//! `.holt-auto` (kept without asking), each read with the one-line files
//! holt adds beside it under `.holt-skip.d/` and `.holt-auto.d/`; their
//! seed; and git's own matcher run over them.

const std = @import("std");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const clone = @import("clone.zig");
const machine = @import("machine.zig");
const sweep = @import("sweep.zig");
const interrupt = @import("interrupt.zig");
const projectlock = @import("../projectlock.zig");
const ctx_mod = @import("ctx.zig");
const testing = std.testing;

const io = fsutil.io;
const Ctx = ctx_mod.Ctx;
const Layout = store.Layout;

pub const List = enum {
    skip,
    auto,

    /// The user's file of the list.
    pub fn basename(l: List) []const u8 {
        return switch (l) {
            .skip => ".holt-skip",
            .auto => ".holt-auto",
        };
    }

    /// The directory of one-line files holt adds for the user.
    pub fn addedDir(l: List) []const u8 {
        return switch (l) {
            .skip => ".holt-skip.d",
            .auto => ".holt-auto.d",
        };
    }

    fn seed(l: List) []const u8 {
        return switch (l) {
            .skip => skip_seed_text,
            .auto => auto_seed_text,
        };
    }
};

/// The seed of `kept/.holt-skip`: regenerable or transient content only.
pub const skip_seed = [_][]const u8{
    "node_modules/",  ".pnpm-store/", ".venv/",       "venv/",          "__pycache__/",
    ".pytest_cache/", ".ruff_cache/", ".mypy_cache/", ".tox/",          ".next/",
    ".nuxt/",         ".svelte-kit/", ".angular/",    ".astro/",        ".docusaurus/",
    ".output/",       ".vite/",       ".turbo/",      ".parcel-cache/", ".nx/",
    ".cache/",        ".expo/",       ".gradle/",     ".cxx/",          ".dart_tool/",
    "Pods/",          "DerivedData/", "xcuserdata/",  ".terraform/",    ".zig-cache/",
    "zig-out/",       "target/",      "dist/",        "build/",         "coverage/",
    "htmlcov/",       "*.egg-info/",  ".eslintcache", "*.tsbuildinfo",  "*.pyc",
    "*.o",            "*.class",      "*.log",        ".DS_Store",      "Thumbs.db",
};

/// The seed of `kept/.holt-auto`.
pub const auto_seed = [_][]const u8{".clasp.json"};

/// What holt writes to `kept/.holt-skip` when it creates the store.
pub const skip_seed_text = seedText(
    "# Seeded by holt; this file is yours to edit, and holt never writes it again.\n" ++
        "# Paths matching these gitignore patterns are never offered for keeping.\n",
    &skip_seed,
);

/// What holt writes to `kept/.holt-auto` when it creates the store.
pub const auto_seed_text = seedText(
    "# Seeded by holt; this file is yours to edit, and holt never writes it again.\n" ++
        "# Paths git ignores that match these gitignore patterns are kept without asking.\n",
    &auto_seed,
);

fn seedText(comptime header: []const u8, comptime lines: []const []const u8) []const u8 {
    comptime var out: []const u8 = header;
    inline for (lines) |l| out = out ++ l ++ "\n";
    return out;
}

/// Whether `createStore` made `kept/` or found it already there.
pub const Created = enum { created, exists };

/// Creates `kept/` under the synced root with the user's `.holt-skip` and
/// `.holt-auto` seeded (`skip_seed_text`, `auto_seed_text`): the store is
/// built whole in a sibling `kept.holt-tmp-<random>` and renamed into
/// place without replacing anything, so no process ever sees a `kept/`
/// missing a list. A `kept/` already there, or one another process puts
/// there first, is left as it is and nothing is seeded (the sibling is
/// removed), so a list the user removed stays removed. An interruption
/// before the rename leaves the sibling and no `kept/`.
/// `SyncedRootMissing` when the synced root is not a directory; it is
/// never created.
pub fn createStore(alloc: std.mem.Allocator, layout: Layout) !Created {
    const kept = try layout.keptDir(alloc);
    if (std.Io.Dir.cwd().openDir(io(), layout.synced_root, .{})) |opened| {
        var d = opened;
        d.close(io());
    } else |_| return error.SyncedRootMissing;
    if (try content.entryAt(kept) != .absent) return .exists;
    const suffix = content.randomSuffix();
    const tmp = try std.fs.path.join(alloc, &.{ layout.synced_root, try std.fmt.allocPrint(alloc, "kept.holt-tmp-{s}", .{&suffix}) });
    try std.Io.Dir.cwd().createDir(io(), tmp, .default_dir);
    for ([_]List{ .skip, .auto }) |l| {
        std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(alloc, &.{ tmp, l.basename() }), .data = l.seed(), .flags = .{ .exclusive = true } }) catch |err| {
            std.Io.Dir.cwd().deleteTree(io(), tmp) catch {};
            return err;
        };
    }
    try interrupt.check(.store_seeded);
    content.renameNoReplace(alloc, tmp, kept) catch |err| {
        std.Io.Dir.cwd().deleteTree(io(), tmp) catch {};
        return if (err == error.PathAlreadyExists) .exists else err;
    };
    return .created;
}

/// The patterns of `l` for every repo: the user's `kept/` file followed by
/// each file under its `.d` directory, in name order, each without a
/// leading UTF-8 byte order mark. Without `kept/`, the seed, as the store
/// would be created with. A file that is absent or cannot be read
/// contributes nothing, so a list that cannot be read skips nothing and
/// keeps nothing automatically. `MatcherFailed` when a file holds more than
/// `max_list_bytes`, with its path in `too_large` when given.
pub fn globalText(alloc: std.mem.Allocator, layout: Layout, l: List, too_large: ?*[]const u8) ![]const u8 {
    const kept = try layout.keptDir(alloc);
    if (try content.entryAt(kept) == .absent) return l.seed();
    return listIn(alloc, kept, l, too_large);
}

/// The skip patterns of the repo filed under `key`: its `kept/<key>/`
/// `.holt-skip` and `.holt-skip.d/` files, read as `globalText` reads the
/// user's.
pub fn repoSkipText(alloc: std.mem.Allocator, layout: Layout, key: []const u8, too_large: ?*[]const u8) ![]const u8 {
    return listIn(alloc, try layout.keyDir(alloc, key), .skip, too_large);
}

fn listIn(alloc: std.mem.Allocator, dir: []const u8, l: List, too_large: ?*[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendFile(alloc, &out, try std.fs.path.join(alloc, &.{ dir, l.basename() }), too_large);
    const added = try std.fs.path.join(alloc, &.{ dir, l.addedDir() });
    var names: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.cwd().openDir(io(), added, .{ .iterate = true }) catch null) |opened| {
        var d = opened;
        defer d.close(io());
        var it = d.iterate();
        while (it.next(io()) catch null) |e| {
            if (e.kind == .file) try names.append(alloc, try alloc.dupe(u8, e.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, paths.lessThan);
    for (names.items) |n| try appendFile(alloc, &out, try std.fs.path.join(alloc, &.{ added, n }), too_large);
    return out.items;
}

fn appendFile(alloc: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8, too_large: ?*[]const u8) !void {
    const read = std.Io.Dir.cwd().readFileAlloc(io(), path, alloc, .limited(max_list_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.StreamTooLong => {
            if (too_large) |t| t.* = path;
            return error.MatcherFailed;
        },
        else => return,
    };
    const bytes = if (std.mem.startsWith(u8, read, bom)) read[bom.len..] else read;
    try out.appendSlice(alloc, bytes);
    if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') try out.append(alloc, '\n');
}

/// The line `skip` and `unkeep` add to a repo's skip list for its path
/// `rel`: `/<rel>`, escaped for gitignore, which matches that path alone.
pub fn anchoredLine(alloc: std.mem.Allocator, rel: []const u8) ![]const u8 {
    return std.mem.concat(alloc, u8, &.{ "/", try paths.escapePattern(alloc, rel, false) });
}

/// The line an answer for every repo adds for the path `rel`: its name for
/// a path at the top of the working tree, which matches it at any depth,
/// or `**/<rel>` for a nested path, each escaped for gitignore and ending
/// in `/` for a directory.
pub fn everywhereLine(alloc: std.mem.Allocator, rel: []const u8, dir: bool) ![]const u8 {
    const nested = std.mem.indexOfScalar(u8, rel, '/') != null;
    const body = try paths.escapePattern(alloc, rel, !nested);
    return std.mem.concat(alloc, u8, &.{ if (nested) "**/" else "", body, if (dir) "/" else "" });
}

/// Adds `line` to the list `l` on the user's behalf: a new one-line file
/// under the `.d` directory of `kept/` (for every repo, `key` null) or of
/// `kept/<key>/`, named by a fresh stamp (`aside.newStamp`) and created
/// exclusively, so two machines adding lines never overwrite each other.
/// The user's own file is never written. Returns the new file's path, or
/// null when a line of the list (the user's file or an added one) already
/// reads `line`. The key's record must exist already, since holt never
/// creates a key directory that holds files before its record. A line
/// holding a line feed or carriage return would add lines no one asked
/// for, and is refused (`InvalidLine`).
pub fn addLine(alloc: std.mem.Allocator, layout: Layout, machine_id: []const u8, key: ?[]const u8, l: List, line: []const u8) !?[]const u8 {
    if (std.mem.indexOfAny(u8, line, "\n\r") != null) return error.InvalidLine;
    const base = if (key) |k| try layout.keyDir(alloc, k) else try layout.keptDir(alloc);
    if (key) |k| if (try store.readRecord(alloc, layout, k) == null) return error.NoKey;
    const existing = try listIn(alloc, base, l, null);
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, raw, "\r"), line)) return null;
    }
    const stamp = try @import("aside.zig").newStamp(alloc, machine_id);
    const path = try std.fs.path.join(alloc, &.{ base, l.addedDir(), stamp });
    try store.createExclusive(alloc, path, try std.mem.concat(alloc, u8, &.{ line, "\n" }));
    return path;
}

/// The most a pattern list file may hold.
pub const max_list_bytes = 1 << 20;

const bom = "\xEF\xBB\xBF";

/// A path asked of the matcher: `/`-joined, relative to the top of the
/// working tree (the superproject's, for a path inside a submodule), and
/// whether it is a directory, which patterns ending in `/` need.
pub const Query = struct { path: []const u8, dir: bool = false };

/// Where the matcher's git finds its global and system configuration: the
/// null device (Git for Windows reads this name as `NUL`), so nothing the
/// user configured, their global ignore file included, ever counts as a
/// skip or an auto pattern.
const null_device = "/dev/null";

/// For each of `queries`, in order, the pattern of `patterns` (gitignore
/// syntax, one per line) that matches it, or null when none does or the
/// last one to match is a negation: asked of git's own matcher, `git
/// check-ignore --no-index --stdin -z -v -n`, in a scratch repository
/// (`scratchRepo`) with an empty `info/exclude`, the
/// patterns in a file of its own named as `core.excludesFile`, and
/// `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` at the null device.
/// `core.ignorecase` is false, so a pattern matches the same names on every
/// machine. Each path is asked as `./<path>`, so a name starting with `:`
/// is never read as pathspec magic. A path with a component git treats as
/// `.git` matches nothing. `MatcherFailed` when the scratch repository or the run's files cannot be
/// made or git fails.
pub fn match(ctx: Ctx, patterns: []const u8, queries: []const Query) ![]const ?[]const u8 {
    const a = ctx.alloc;
    const out = try a.alloc(?[]const u8, queries.len);
    @memset(out, null);
    if (!hasPattern(patterns)) return out;

    var asked: std.ArrayList(usize) = .empty;
    var input: std.ArrayList(u8) = .empty;
    for (queries, 0..) |q, i| {
        if (q.path.len == 0 or paths.hasDotGit(q.path) or std.mem.indexOfScalar(u8, q.path, 0) != null) continue;
        try asked.append(a, i);
        try input.appendSlice(a, "./");
        try input.appendSlice(a, q.path);
        if (q.dir) try input.append(a, '/');
        try input.append(a, 0);
    }
    if (asked.items.len == 0) return out;

    const repo = try scratchRepo(ctx);
    const dirs = [_][]const u8{try sweep.scratchDir(a, ctx)};
    fsutil.ensureDir(dirs[0]) catch return error.MatcherFailed;
    const pattern_file = (try clone.writeRunFile(a, &dirs, ctx.machine_id, patterns)) orelse return error.MatcherFailed;
    defer fsutil.removePath(pattern_file) catch {};
    const input_file = (try clone.writeRunFile(a, &dirs, ctx.machine_id, input.items)) orelse return error.MatcherFailed;
    defer fsutil.removePath(input_file) catch {};

    const res = git.runInRepoScopedWith(a, &.{
        "-c",
        try std.fmt.allocPrint(a, "core.excludesFile={s}", .{pattern_file}),
        "-c",
        "core.ignorecase=false",
        "check-ignore",
        "--no-index",
        "--stdin",
        "-z",
        "-v",
        "-n",
    }, repo, .{ .set = &null_config, .stdin_path = input_file }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.MatcherFailed,
    };
    if (res.status > 1) return error.MatcherFailed;

    var fields = std.mem.splitScalar(u8, res.stdout, 0);
    for (asked.items) |i| {
        const source = fields.next() orelse return error.MatcherFailed;
        _ = fields.next() orelse return error.MatcherFailed;
        const pattern = fields.next() orelse return error.MatcherFailed;
        const path = fields.next() orelse return error.MatcherFailed;
        if (!std.mem.startsWith(u8, path, "./")) return error.MatcherFailed;
        const echoed = std.mem.trimEnd(u8, path[2..], "/");
        if (!std.mem.eql(u8, echoed, queries[i].path)) return error.MatcherFailed;
        if (source.len == 0 or pattern.len == 0 or pattern[0] == '!') continue;
        out[i] = pattern;
    }
    return out;
}

const null_config = [_][2][]const u8{
    .{ "GIT_CONFIG_GLOBAL", null_device },
    .{ "GIT_CONFIG_SYSTEM", null_device },
};

/// Whether `text` holds a line that is a pattern: neither blank nor a
/// comment.
pub fn hasPattern(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len > 0 and l[0] != '#') return true;
    }
    return false;
}

/// The matcher's scratch repository, `matcher` in holt's machine-local
/// state directory, with an empty `info/exclude`. On first use it is made
/// whole in a sibling `matcher.holt-tmp-<random>` and renamed into place,
/// under the lock `matcher.lock` there, so no process ever uses one half
/// made. Under that lock, a `matcher` without `.git/HEAD` and any sibling
/// an interrupted run left are removed first. For a command that only
/// reports (`Ctx.scratch`), while that one is absent, the run's own is
/// used instead, so nothing is made in the state directory.
fn scratchRepo(ctx: Ctx) ![]const u8 {
    const a = ctx.alloc;
    const state = try machine.stateDir(a, ctx.env);
    const repo = try std.fs.path.join(a, &.{ state, "matcher" });
    const exclude = try std.fs.path.join(a, &.{ repo, ".git", "info", "exclude" });
    if (!try scratchReady(a, repo)) {
        if (ctx.scratch) |s| return runScratchRepo(a, s);
        fsutil.ensureDir(state) catch return error.MatcherFailed;
        const lock = projectlock.acquireAt(try std.fs.path.join(a, &.{ state, "matcher.lock" })) catch return error.MatcherFailed;
        defer lock.release();
        if (!try scratchReady(a, repo)) try makeScratch(a, state, repo);
    }
    const current = content.readSmall(a, exclude) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (current == null or current.?.len > 0) {
        fsutil.ensureDir(std.fs.path.dirname(exclude).?) catch return error.MatcherFailed;
        fsutil.writeFileAtomic(a, exclude, "") catch return error.MatcherFailed;
    }
    return repo;
}

/// The matcher's scratch repository in the run's own directory, made
/// there on first use.
fn runScratchRepo(a: std.mem.Allocator, s: *ctx_mod.RunScratch) ![]const u8 {
    const repo = try std.fs.path.join(a, &.{ s.dir, "matcher" });
    while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    defer s.lock.unlock();
    if (!s.ready) {
        try makeScratch(a, s.dir, repo);
        s.ready = true;
    }
    return repo;
}

const scratch_tmp_prefix = "matcher.holt-tmp-";

fn scratchReady(a: std.mem.Allocator, repo: []const u8) !bool {
    return try content.entryAt(try std.fs.path.join(a, &.{ repo, ".git", "HEAD" })) == .file;
}

/// Makes the scratch repository `repo` in `state`, under `matcher.lock`.
fn makeScratch(a: std.mem.Allocator, state: []const u8, repo: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io(), state, .{ .iterate = true })) |opened| {
        var d = opened;
        defer d.close(io());
        var it = d.iterate();
        while (it.next(io()) catch null) |e| {
            if (std.mem.startsWith(u8, e.name, scratch_tmp_prefix)) d.deleteTree(io(), e.name) catch return error.MatcherFailed;
        }
    } else |_| return error.MatcherFailed;
    if (try content.entryAt(repo) != .absent) cwd.deleteTree(io(), repo) catch return error.MatcherFailed;
    const suffix = content.randomSuffix();
    const tmp = try std.fs.path.join(a, &.{ state, try std.fmt.allocPrint(a, scratch_tmp_prefix ++ "{s}", .{&suffix}) });
    fsutil.ensureDir(tmp) catch return error.MatcherFailed;
    const res = git.runInRepoScopedWith(a, &.{ "init", "-q" }, tmp, .{ .set = &null_config }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.MatcherFailed,
    };
    if (res.status != 0) return error.MatcherFailed;
    const exclude = try std.fs.path.join(a, &.{ tmp, ".git", "info", "exclude" });
    fsutil.ensureDir(std.fs.path.dirname(exclude).?) catch return error.MatcherFailed;
    fsutil.writeFileAtomic(a, exclude, "") catch return error.MatcherFailed;
    try interrupt.check(.matcher_made);
    content.renameNoReplace(a, tmp, repo) catch return error.MatcherFailed;
}

/// For each entry directly at a hub root, in order, whether the skip
/// patterns every repo shares (`globalText`) match it. `MatcherFailed` as
/// `globalText` and `match` fail, with an oversized list's path in
/// `too_large` when given.
pub fn hubSkipped(ctx: Ctx, entries: []const Query, too_large: ?*[]const u8) ![]const bool {
    const a = ctx.alloc;
    const got = try match(ctx, try globalText(a, ctx.layout, .skip, too_large), entries);
    const out = try a.alloc(bool, entries.len);
    for (got, out) |g, *o| o.* = g != null;
    return out;
}

const Fixture = @import("harness.zig").Fixture;

fn testCtx(f: *Fixture) !Ctx {
    const a = f.alloc();
    const map = try a.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(a);
    try map.put("HOME", f.root);
    try map.put("USERPROFILE", f.root);
    try map.put("XDG_STATE_HOME", try f.path("state"));
    return .{ .alloc = a, .env = .{ .map = map }, .layout = .{ .synced_root = try f.path("synced") }, .code_root = try f.path("code"), .machine_id = "0123456789abcdef" };
}

test "seed texts: headed by holt's comment, one pattern per line, exactly the seed" {
    try testing.expect(std.mem.startsWith(u8, skip_seed_text, "# Seeded by holt;"));
    try testing.expect(std.mem.indexOf(u8, skip_seed_text, "\nnode_modules/\n.pnpm-store/\n") != null);
    try testing.expect(std.mem.endsWith(u8, skip_seed_text, "\n.DS_Store\nThumbs.db\n"));
    try testing.expectEqual(@as(usize, 45), skip_seed.len);
    try testing.expect(std.mem.indexOf(u8, skip_seed_text, "\n*.o\n*.class\n*.log\n") != null);
    try testing.expect(std.mem.endsWith(u8, auto_seed_text, "\n.clasp.json\n"));
}

test "createStore: seeds both lists once; an existing kept/ is never seeded again, and a removed list stays removed" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const a = ctx.alloc;
    try fsutil.ensureDir(ctx.layout.synced_root);

    try testing.expectEqual(Created.created, try createStore(a, ctx.layout));
    const skip = try f.path("synced/kept/.holt-skip");
    try testing.expectEqualStrings(skip_seed_text, try content.readSmall(a, skip));
    try testing.expectEqualStrings(auto_seed_text, try content.readSmall(a, try f.path("synced/kept/.holt-auto")));

    _ = try f.write("synced/kept/.holt-skip", "mine\n");
    try fsutil.removePath(try f.path("synced/kept/.holt-auto"));
    try testing.expectEqual(Created.exists, try createStore(a, ctx.layout));
    try testing.expectEqualStrings("mine\n", try content.readSmall(a, skip));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try f.path("synced/kept/.holt-auto")));
    try testing.expectEqualStrings("", try globalText(a, ctx.layout, .auto, null));
}

test "globalText: the seed without kept/; the user's file then the added lines in name order once it exists" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const a = ctx.alloc;
    try testing.expectEqualStrings(skip_seed_text, try globalText(a, ctx.layout, .skip, null));
    try testing.expectEqualStrings(auto_seed_text, try globalText(a, ctx.layout, .auto, null));

    _ = try f.write("synced/kept/.holt-skip", "*.tmp");
    _ = try f.write("synced/kept/.holt-skip.d/2", "/b\n");
    _ = try f.write("synced/kept/.holt-skip.d/1", "/a\n");
    try testing.expectEqualStrings("*.tmp\n/a\n/b\n", try globalText(a, ctx.layout, .skip, null));
    try testing.expectEqualStrings("", try globalText(a, ctx.layout, .auto, null));

    _ = try f.write("synced/kept/github.com/acme/widget/.holt-skip.d/x", "/local.cfg\n");
    try testing.expectEqualStrings("/local.cfg\n", try repoSkipText(a, ctx.layout, "github.com/acme/widget", null));
}

test "addLine: one exclusive file per line under the list's directory, never a duplicate, never before the key's record" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const a = ctx.alloc;
    try fsutil.ensureDir(ctx.layout.synced_root);
    _ = try createStore(a, ctx.layout);
    const key = "github.com/acme/widget";

    try testing.expectError(error.NoKey, addLine(a, ctx.layout, ctx.machine_id, key, .skip, "/x"));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try ctx.layout.keyDir(a, key)));

    const first = (try addLine(a, ctx.layout, ctx.machine_id, null, .auto, ".env")).?;
    try testing.expect(std.mem.startsWith(u8, first, try std.fs.path.join(a, &.{ try ctx.layout.keptDir(a), ".holt-auto.d" })));
    try testing.expectEqualStrings(".env\n", try content.readSmall(a, first));
    try testing.expect(try addLine(a, ctx.layout, ctx.machine_id, null, .auto, ".env") == null);
    try testing.expect(try addLine(a, ctx.layout, ctx.machine_id, null, .auto, ".clasp.json") == null);
    try testing.expectEqualStrings(auto_seed_text ++ ".env\n", try globalText(a, ctx.layout, .auto, null));

    _ = try f.write("synced/kept/github.com/acme/widget/.holt-kept.json", "{\"version\": 1}");
    _ = (try addLine(a, ctx.layout, ctx.machine_id, key, .skip, "/local.cfg")).?;
    try testing.expectEqualStrings("/local.cfg\n", try repoSkipText(a, ctx.layout, key, null));
}

test "addLine: a line holding a line feed or carriage return is refused, so a name can never add lines of its own" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const a = ctx.alloc;
    try fsutil.ensureDir(ctx.layout.synced_root);
    _ = try createStore(a, ctx.layout);
    for ([_][]const u8{ try everywhereLine(a, "x\n!.env", false), try anchoredLine(a, "y\r.env"), "a\r\n*" }) |line| {
        try testing.expectError(error.InvalidLine, addLine(a, ctx.layout, ctx.machine_id, null, .skip, line));
        try testing.expectError(error.InvalidLine, addLine(a, ctx.layout, ctx.machine_id, null, .auto, line));
    }
    try testing.expectEqualStrings(skip_seed_text, try globalText(a, ctx.layout, .skip, null));
    try testing.expectEqualStrings(auto_seed_text, try globalText(a, ctx.layout, .auto, null));
}

test "anchoredLine and everywhereLine: the forms answers add, escaped so each matches exactly its path" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const a = ctx.alloc;
    try testing.expectEqualStrings("/a/\\[b\\]\\*", try anchoredLine(a, "a/[b]*"));
    try testing.expectEqualStrings(".env", try everywhereLine(a, ".env", false));
    try testing.expectEqualStrings("\\#notes/", try everywhereLine(a, "#notes", true));
    try testing.expectEqualStrings("**/android/app/google-services.json", try everywhereLine(a, "android/app/google-services.json", false));

    const pats = try std.mem.join(a, "\n", &.{ try anchoredLine(a, "a/[b]*"), try everywhereLine(a, "#notes", true), try everywhereLine(a, "android/app/g.json", false) });
    const qs = [_]Query{
        .{ .path = "a/[b]*" },
        .{ .path = "a/b" },
        .{ .path = "x/a/[b]*" },
        .{ .path = "deep/#notes", .dir = true },
        .{ .path = "#notes" },
        .{ .path = "mod/android/app/g.json" },
    };
    const got = try match(ctx, pats, &qs);
    try testing.expect(got[0] != null);
    try testing.expect(got[1] == null);
    try testing.expect(got[2] == null);
    try testing.expect(got[3] != null);
    try testing.expect(got[4] == null);
    try testing.expect(got[5] != null);
}

test "match: git's own rules, the last match deciding, directories only for patterns ending in `/`, and names byte for byte" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const pats = "node_modules/\n*.log\n!keep.log\n/top\n**/deep/x\nCache\n";
    const qs = [_]Query{
        .{ .path = "node_modules", .dir = true },
        .{ .path = "node_modules" },
        .{ .path = "a/node_modules/x.js" },
        .{ .path = "x.log" },
        .{ .path = "keep.log" },
        .{ .path = "top" },
        .{ .path = "a/top" },
        .{ .path = "q/deep/x" },
        .{ .path = "cache" },
        .{ .path = "sub/.git/x.log" },
        .{ .path = "nothing" },
    };
    const got = try match(ctx, pats, &qs);
    const want = [_]?[]const u8{ "node_modules/", null, "node_modules/", "*.log", null, "/top", null, "**/deep/x", null, null, null };
    for (want, got, 0..) |w, g, i| {
        if (w) |ws| {
            testing.expectEqualStrings(ws, g orelse "<none>") catch |err| {
                std.debug.print("query {d} ({s})\n", .{ i, qs[i].path });
                return err;
            };
        } else if (g) |gs| {
            std.debug.print("query {d} ({s}) matched {s}\n", .{ i, qs[i].path, gs });
            return error.TestUnexpectedResult;
        }
    }
    for (try match(ctx, "# only a comment\n\n", &qs)) |g| try testing.expect(g == null);
}

test "hubSkipped: the patterns every repo shares, the seed while kept/ is absent" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const entries = [_]Query{ .{ .path = ".DS_Store" }, .{ .path = "node_modules", .dir = true }, .{ .path = ".claude", .dir = true }, .{ .path = "notes.md" } };
    const seeded = try hubSkipped(ctx, &entries, null);
    try testing.expectEqualSlices(bool, &.{ true, true, false, false }, seeded);

    _ = try f.write("synced/kept/.holt-skip", "notes.md\n");
    _ = try f.write("synced/kept/.holt-skip.d/1", ".claude/\n");
    _ = try f.write("synced/kept/github.com/acme/widget/.holt-skip", ".DS_Store\n");
    try testing.expectEqualSlices(bool, &.{ false, false, true, true }, try hubSkipped(ctx, &entries, null));
}

test "match: a path starting with `:` is a name, never pathspec magic, for repo paths and hub entries" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const qs = [_]Query{ .{ .path = ":foo" }, .{ .path = ":!x" }, .{ .path = ":(" }, .{ .path = ":^" }, .{ .path = "foo" }, .{ .path = "a/:foo" } };
    const got = try match(ctx, "foo\n", &qs);
    const want = [_]?[]const u8{ null, null, null, null, "foo", null };
    for (want, got) |w, g| {
        if (w) |ws| try testing.expectEqualStrings(ws, g orelse "<none>") else try testing.expect(g == null);
    }
    const named = try match(ctx, ":foo\n", &qs);
    try testing.expectEqualStrings(":foo", named[0].?);
    try testing.expectEqualStrings(":foo", named[5].?);

    _ = try f.write("synced/kept/.holt-skip", ":foo\n:(\n");
    const entries = [_]Query{ .{ .path = ":foo" }, .{ .path = ":!x" }, .{ .path = ":(" }, .{ .path = "foo" } };
    try testing.expectEqualSlices(bool, &.{ true, false, true, false }, try hubSkipped(ctx, &entries, null));
    _ = try f.write("synced/kept/.holt-skip", "foo\n");
    try testing.expectEqualSlices(bool, &.{ false, false, false, true }, try hubSkipped(ctx, &entries, null));
}

test "globalText: a UTF-8 byte order mark at the start of a list file is not part of its first pattern" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const a = ctx.alloc;
    _ = try f.write("synced/kept/.holt-skip", "\xEF\xBB\xBF*.tmp\n");
    _ = try f.write("synced/kept/.holt-skip.d/1", "\xEF\xBB\xBF/a\n");
    try testing.expectEqualStrings("*.tmp\n/a\n", try globalText(a, ctx.layout, .skip, null));
    const got = try hubSkipped(ctx, &.{ .{ .path = "x.tmp" }, .{ .path = "a" } }, null);
    try testing.expectEqualSlices(bool, &.{ true, true }, got);
}

test "seed: object files and compiled classes are skipped, and a Wavefront model named .obj is not" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const got = try hubSkipped(ctx, &.{ .{ .path = "main.o" }, .{ .path = "Main.class" }, .{ .path = "model.obj" } }, null);
    try testing.expectEqualSlices(bool, &.{ true, true, false }, got);
}

test "createStore: refuses when the synced root does not exist, and never creates it" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    try testing.expectError(error.SyncedRootMissing, createStore(ctx.alloc, ctx.layout));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(ctx.layout.synced_root));
}

fn tmpSiblings(a: std.mem.Allocator, dir: []const u8, prefix: []const u8) !usize {
    var d = try std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true });
    defer d.close(io());
    var n: usize = 0;
    var it = d.iterate();
    while (try it.next(io())) |e| {
        if (std.mem.startsWith(u8, e.name, prefix)) n += 1;
    }
    _ = a;
    return n;
}

var race_kept: ?[]const u8 = null;

fn otherCreatesStore(p: interrupt.Point) void {
    if (p != .store_seeded) return;
    const kept = race_kept orelse return;
    std.Io.Dir.cwd().createDir(io(), kept, .default_dir) catch unreachable;
}

test "createStore: an interruption before the rename leaves no kept/, and a store another process makes first is left as it is" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const a = ctx.alloc;
    try fsutil.ensureDir(ctx.layout.synced_root);
    const kept = try ctx.layout.keptDir(a);

    interrupt.at = .store_seeded;
    try testing.expectError(error.Interrupted, createStore(a, ctx.layout));
    interrupt.at = null;
    try testing.expectEqual(content.Entry.absent, try content.entryAt(kept));
    try testing.expectEqual(Created.created, try createStore(a, ctx.layout));
    try testing.expectEqualStrings(skip_seed_text, try content.readSmall(a, try f.path("synced/kept/.holt-skip")));
    try testing.expectEqualStrings(auto_seed_text, try content.readSmall(a, try f.path("synced/kept/.holt-auto")));

    try std.Io.Dir.cwd().deleteTree(io(), kept);
    race_kept = kept;
    interrupt.hook = otherCreatesStore;
    defer {
        interrupt.hook = null;
        race_kept = null;
    }
    const before = try tmpSiblings(a, ctx.layout.synced_root, "kept.holt-tmp-");
    try testing.expectEqual(Created.exists, try createStore(a, ctx.layout));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try f.path("synced/kept/.holt-skip")));
    try testing.expectEqual(before, try tmpSiblings(a, ctx.layout.synced_root, "kept.holt-tmp-"));
}

test "match: the scratch repository appears only whole; an interrupted one is never used, and a half-made one is replaced" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const a = ctx.alloc;
    const state = try machine.stateDir(a, ctx.env);
    const repo = try std.fs.path.join(a, &.{ state, "matcher" });
    const qs = [_]Query{.{ .path = "x.log" }};

    interrupt.at = .matcher_made;
    try testing.expectError(error.Interrupted, match(ctx, "*.log\n", &qs));
    interrupt.at = null;
    try testing.expectEqual(content.Entry.absent, try content.entryAt(repo));
    try testing.expectEqual(@as(usize, 1), try tmpSiblings(a, state, "matcher.holt-tmp-"));

    try fsutil.ensureDir(try std.fs.path.join(a, &.{ repo, ".git", "objects" }));
    try testing.expectEqualStrings("*.log", (try match(ctx, "*.log\n", &qs))[0].?);
    try testing.expectEqual(@as(usize, 0), try tmpSiblings(a, state, "matcher.holt-tmp-"));
    try testing.expectEqualStrings("*.log", (try match(ctx, "*.log\n", &qs))[0].?);
}

test "globalText: a list file over the limit fails the matcher and names the file" {
    var f = try Fixture.init();
    defer f.deinit();
    const ctx = try testCtx(&f);
    const a = ctx.alloc;
    const big = try a.alloc(u8, max_list_bytes + 1);
    @memset(big, '#');
    const at = try f.write("synced/kept/.holt-skip.d/big", big);
    _ = try f.write("synced/kept/.holt-skip.d/exact", big[0..max_list_bytes]);
    var named: []const u8 = "";
    try testing.expectError(error.MatcherFailed, globalText(a, ctx.layout, .skip, &named));
    try testing.expectEqualStrings(at, named);
    try testing.expectError(error.MatcherFailed, hubSkipped(ctx, &.{.{ .path = "x" }}, null));
    try fsutil.removePath(at);
    _ = try globalText(a, ctx.layout, .skip, null);
}
