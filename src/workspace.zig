//! Enumerates the synced content tree (`projects/<org>/<name>/.holt.json`)
//! into `Project` values and resolves a user-typed query or a repo identity
//! back to one of them.

const std = @import("std");
const config = @import("config.zig");
const marker = @import("marker.zig");
const identity = @import("identity.zig");
const project_mod = @import("project.zig");
const fsutil = @import("fsutil.zig");
const diagnostic = @import("diag.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

const Project = project_mod.Project;

/// True when a directory name carries a cloud-sync conflict-copy signature.
/// Dropbox/OneDrive/iCloud rename a conflicting copy to something like
/// "proj (conflicted copy 2024-01-01)" or "proj (Case Conflict)"; holt must
/// not adopt such a directory as a real project (its name would leak the
/// suffix into a project identity, and `sync` would build a hub for it).
/// Both phrases are multi-word and effectively never occur in a chosen name,
/// so the match is a whole-phrase, case-insensitive substring test.
pub fn isConflictCopyName(name: []const u8) bool {
    return containsIgnoreCase(name, "conflicted copy") or containsIgnoreCase(name, "case conflict");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const FindResult = union(enum) {
    one: Project,
    none,
    ambiguous: []Project,
};

pub const Workspace = struct {
    cfg: config.Config,

    pub fn projectsRoot(self: Workspace, alloc: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.cfg.synced_root, "projects" });
    }

    pub fn archiveRoot(self: Workspace, alloc: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.cfg.synced_root, "archive" });
    }

    pub fn backupsRoot(self: Workspace, alloc: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.cfg.synced_root, "backups" });
    }

    /// Scans `<synced>/projects/<org>/<name>/.holt.json`. A marker that
    /// fails to parse is skipped with a warning printed to stderr rather
    /// than aborting the whole listing. Results are sorted by "org/name".
    pub fn list(self: Workspace, alloc: std.mem.Allocator) ![]Project {
        const entries = try self.scanProjects(alloc);

        var projects: std.ArrayList(Project) = .empty;
        for (entries) |entry| switch (entry) {
            .ok => |p| try projects.append(alloc, p),
            .failed => |f| std.debug.print("warning: skipping unparseable marker at {s}: {s}\n", .{ f.path, f.message }),
            .evicted => |e| std.debug.print("warning: {s}/{s} marker is evicted from local storage; open its folder to download it\n", .{ e.org, e.name }),
        };

        const items = try projects.toOwnedSlice(alloc);
        std.mem.sort(Project, items, {}, lessThanQualified);
        return items;
    }

    /// Absolute paths of every clone in the code tree, sorted. A clone is a
    /// directory holding a `.git` DIRECTORY; on finding one, it is emitted and
    /// not descended into. Worktrees (whose `.git` is a FILE) and
    /// `*.holt-tmp` staging dirs are skipped. No git is run; symlinks are not
    /// followed. A missing or unreadable code_root yields an empty slice.
    pub fn listClones(self: Workspace, alloc: std.mem.Allocator) ![]const []const u8 {
        const code_root = self.cfg.code_root;
        var out: std.ArrayList([]const u8) = .empty;

        var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), code_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return &.{},
            else => return err,
        };
        defer root_dir.close(fsutil.io());

        var walker = try root_dir.walkSelectively(alloc);
        defer walker.deinit();

        while (try walker.next(fsutil.io())) |entry| {
            if (entry.kind != .directory) continue;
            // Never descend into a worktree bucket - it holds no clones, only
            // checkouts whose `.git` is a file - or a clone-staging temp dir.
            if (std.mem.endsWith(u8, entry.basename, "@worktrees")) continue;
            if (std.mem.endsWith(u8, entry.basename, ".holt-tmp")) continue;

            const abs = try std.fs.path.join(alloc, &.{ code_root, entry.path });
            if (try hasGitDir(alloc, abs)) {
                // A clone: emit and do not recurse into it.
                try out.append(alloc, abs);
            } else {
                try walker.enter(fsutil.io(), entry);
            }
        }

        const items = try out.toOwnedSlice(alloc);
        std.mem.sort([]const u8, items, {}, lessThanPath);
        return items;
    }

    /// A project dir under `<synced>/projects/<org>/<name>` whose marker
    /// failed to parse: the path scanned and the diagnostic message.
    pub const MarkerFailure = struct { path: []const u8, message: []const u8 };

    /// A project dir whose marker is present in the cloud but evicted from
    /// local storage (an iCloud placeholder sits where the marker should be),
    /// so it cannot be read until downloaded.
    pub const EvictedMarker = struct { org: []const u8, name: []const u8, path: []const u8 };

    /// One `<synced>/projects/<org>/<name>` dir that has a marker file,
    /// either parsed into a `Project` or failed with the load diagnostic, or
    /// whose marker is evicted from local storage. A project dir with neither
    /// a marker nor an eviction placeholder never becomes an entry - it isn't
    /// a project yet.
    pub const MarkerScanEntry = union(enum) {
        ok: Project,
        failed: MarkerFailure,
        evicted: EvictedMarker,
    };

    /// Walks `<synced>/projects/<org>/<name>/.holt.json` for every project
    /// dir with a marker present, yielding a `MarkerScanEntry` per dir.
    /// Callers decide what to do with a failure: `list` warns and drops it,
    /// `doctor` collects it into a report.
    pub fn scanProjects(self: Workspace, alloc: std.mem.Allocator) ![]MarkerScanEntry {
        const root = try self.projectsRoot(alloc);

        var entries: std.ArrayList(MarkerScanEntry) = .empty;

        var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return &.{},
            else => return err,
        };
        defer root_dir.close(fsutil.io());

        var org_it = root_dir.iterate();
        while (try org_it.next(fsutil.io())) |org_entry| {
            if (org_entry.kind != .directory) continue;
            // A whole-org conflict copy ("acme (conflicted copy)") is never a
            // real org; skip it and its children rather than adopt a phantom.
            if (isConflictCopyName(org_entry.name)) continue;
            const org = try alloc.dupe(u8, org_entry.name);
            const org_path = try std.fs.path.join(alloc, &.{ root, org });

            var org_dir = try root_dir.openDir(fsutil.io(), org_entry.name, .{ .iterate = true });
            defer org_dir.close(fsutil.io());

            var proj_it = org_dir.iterate();
            while (try proj_it.next(fsutil.io())) |proj_entry| {
                if (proj_entry.kind != .directory) continue;
                if (isConflictCopyName(proj_entry.name)) continue;
                const name = try alloc.dupe(u8, proj_entry.name);
                const content_path = try std.fs.path.join(alloc, &.{ org_path, name });
                const marker_path = try std.fs.path.join(alloc, &.{ content_path, marker.marker_basename });
                if (!fsutil.exists(marker_path)) {
                    // No marker on disk: a project whose marker iCloud evicted
                    // is still real (surfaced as degraded), a bare dir is not.
                    if (marker.markerEvicted(alloc, content_path))
                        try entries.append(alloc, .{ .evicted = .{ .org = org, .name = name, .path = content_path } });
                    continue;
                }

                var diag: diagnostic.Diagnostic = .{};
                const m = marker.load(alloc, marker_path, &diag) catch {
                    try entries.append(alloc, .{ .failed = .{ .path = marker_path, .message = diag.message } });
                    continue;
                };

                const hub_path = try std.fs.path.join(alloc, &.{ self.cfg.hub_root, org, name });

                try entries.append(alloc, .{ .ok = .{
                    .org = org,
                    .name = name,
                    .content_path = content_path,
                    .hub_path = hub_path,
                    .marker = m,
                } });
            }
        }

        return entries.toOwnedSlice(alloc);
    }

    /// Resolves `query` to one project by matching it against each project's
    /// "org/name" and bare "name", in descending tier: exact > prefix >
    /// substring > subsequence. The first tier with any match decides; a
    /// unique match there wins, otherwise the matches are reported ambiguous.
    /// Matching is smartcase - case-insensitive unless the query contains an
    /// uppercase letter - and the subsequence tier breaks ties by the tightest
    /// span, so the closest fuzzy match still resolves uniquely. So `dtf`
    /// finds `dotfiles`, `wid` prefers a `widget` prefix over a looser fuzzy
    /// hit, and `acme/widget` matches the full path.
    pub fn find(self: Workspace, alloc: std.mem.Allocator, query: []const u8) !FindResult {
        const all = try self.list(alloc);
        const sensitive = hasUpperAscii(query);

        for ([_]MatchTier{ .exact, .prefix, .substring }) |tier| {
            var matches: std.ArrayList(Project) = .empty;
            for (all) |p| {
                if (try matchesTier(alloc, tier, query, p, sensitive)) try matches.append(alloc, p);
            }
            switch (matches.items.len) {
                0 => {},
                1 => return .{ .one = matches.items[0] },
                else => return .{ .ambiguous = try matches.toOwnedSlice(alloc) },
            }
        }

        var best_span: ?usize = null;
        var winners: std.ArrayList(Project) = .empty;
        for (all) |p| {
            const span = (try bestSubseqSpan(alloc, query, p, sensitive)) orelse continue;
            if (best_span == null or span < best_span.?) {
                best_span = span;
                winners.clearRetainingCapacity();
                try winners.append(alloc, p);
            } else if (span == best_span.?) {
                try winners.append(alloc, p);
            }
        }
        switch (winners.items.len) {
            0 => return .none,
            1 => return .{ .one = winners.items[0] },
            else => return .{ .ambiguous = try winners.toOwnedSlice(alloc) },
        }
    }

    /// True when `<synced>/projects/<org>/<name>/.holt.json` exists but
    /// fails to parse - the project directory is real, just corrupt, as
    /// opposed to no such project existing at all.
    pub fn hasMalformedMarker(self: Workspace, alloc: std.mem.Allocator, org: []const u8, name: []const u8) !bool {
        const marker_path = try std.fs.path.join(alloc, &.{ try self.projectsRoot(alloc), org, name, marker.marker_basename });
        if (!fsutil.exists(marker_path)) return false;
        _ = marker.load(alloc, marker_path, null) catch return true;
        return false;
    }

    /// Reverse lookup: every project with a marker repo entry resolving
    /// (local:-aware) to an Identity equal to `id`. A repo entry that fails
    /// to resolve to a valid identity is skipped, not fatal.
    pub fn projectsUsing(self: Workspace, alloc: std.mem.Allocator, id: identity.Identity) ![]Project {
        const all = try self.list(alloc);

        var matches: std.ArrayList(Project) = .empty;
        for (all) |p| {
            for (p.marker.repos.keys()) |repo_name| {
                const repo_id = p.repoIdentity(alloc, repo_name) catch continue;
                if (identity.Identity.eql(repo_id, id)) {
                    try matches.append(alloc, p);
                    break;
                }
            }
        }
        return matches.toOwnedSlice(alloc);
    }
};

fn lessThanQualified(_: void, a: Project, b: Project) bool {
    return switch (std.mem.order(u8, a.org, b.org)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.order(u8, a.name, b.name) == .lt,
    };
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// True iff `dir/.git` exists AND is a directory (a clone), false for a
/// missing `.git` or a `.git` file (a linked worktree/submodule).
fn hasGitDir(alloc: std.mem.Allocator, dir: []const u8) !bool {
    const git = try std.fs.path.join(alloc, &.{ dir, ".git" });
    var d = std.Io.Dir.openDirAbsolute(fsutil.io(), git, .{}) catch return false;
    d.close(fsutil.io());
    return true;
}

/// True if every byte of `query`, lowercased, appears in `target` in order
/// (not necessarily contiguously), also lowercased.
pub fn isSubsequenceIgnoreCase(query: []const u8, target: []const u8) bool {
    var qi: usize = 0;
    for (target) |tc| {
        if (qi == query.len) break;
        if (std.ascii.toLower(tc) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

// Tiered smartcase matching used by `find`.

const MatchTier = enum { exact, prefix, substring };

fn hasUpperAscii(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

fn eqlMaybe(a: []const u8, b: []const u8, sensitive: bool) bool {
    return if (sensitive) std.mem.eql(u8, a, b) else std.ascii.eqlIgnoreCase(a, b);
}

fn startsWithMaybe(hay: []const u8, prefix: []const u8, sensitive: bool) bool {
    if (prefix.len > hay.len) return false;
    return eqlMaybe(hay[0..prefix.len], prefix, sensitive);
}

fn containsMaybe(hay: []const u8, needle: []const u8, sensitive: bool) bool {
    return if (sensitive) std.mem.indexOf(u8, hay, needle) != null else containsIgnoreCase(hay, needle);
}

fn tierMatchOne(tier: MatchTier, needle: []const u8, hay: []const u8, sensitive: bool) bool {
    return switch (tier) {
        .exact => eqlMaybe(needle, hay, sensitive),
        .prefix => startsWithMaybe(hay, needle, sensitive),
        .substring => containsMaybe(hay, needle, sensitive),
    };
}

/// True if `query` matches a project's "org/name" or bare "name" at `tier`.
fn matchesTier(alloc: std.mem.Allocator, tier: MatchTier, query: []const u8, p: Project, sensitive: bool) !bool {
    const qualified = try p.qualified(alloc);
    return tierMatchOne(tier, query, qualified, sensitive) or tierMatchOne(tier, query, p.name, sensitive);
}

fn charEqMaybe(a: u8, b: u8, sensitive: bool) bool {
    return if (sensitive) a == b else std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// The length of the tightest window of `hay` that contains `query` as a
/// subsequence, or null if `query` is not a subsequence of `hay` at all. A
/// smaller span is a closer fuzzy match.
fn subseqSpan(query: []const u8, hay: []const u8, sensitive: bool) ?usize {
    if (query.len == 0) return 0;
    var best: ?usize = null;
    var start: usize = 0;
    while (start < hay.len) : (start += 1) {
        if (!charEqMaybe(hay[start], query[0], sensitive)) continue;
        var qi: usize = 1;
        var hi: usize = start + 1;
        while (hi < hay.len and qi < query.len) : (hi += 1) {
            if (charEqMaybe(hay[hi], query[qi], sensitive)) qi += 1;
        }
        if (qi == query.len) {
            const span = hi - start;
            if (best == null or span < best.?) best = span;
        }
    }
    return best;
}

/// The tightest subsequence span of `query` across a project's "org/name" and
/// bare "name", or null if it is a subsequence of neither.
fn bestSubseqSpan(alloc: std.mem.Allocator, query: []const u8, p: Project, sensitive: bool) !?usize {
    const qualified = try p.qualified(alloc);
    var best: ?usize = null;
    for ([_][]const u8{ qualified, p.name }) |cand| {
        if (subseqSpan(query, cand, sensitive)) |s| {
            if (best == null or s < best.?) best = s;
        }
    }
    return best;
}

fn testConfig(alloc: std.mem.Allocator, synced_root: []const u8) !config.Config {
    return .{
        .backend = null,
        .presets = &.{},
        .synced_root = try alloc.dupe(u8, synced_root),
        .code_root = try alloc.dupe(u8, ""),
        .hub_root = try std.fs.path.join(alloc, &.{ synced_root, "hub" }),
    };
}

fn emptyRepos() std.StringArrayHashMapUnmanaged([]const u8) {
    return .empty;
}

test "isConflictCopyName: matches cloud conflict signatures, leaves ordinary names alone" {
    try testing.expect(isConflictCopyName("proj (conflicted copy 2024-01-01)"));
    try testing.expect(isConflictCopyName("proj (Case Conflict)"));
    try testing.expect(isConflictCopyName("CONFLICTED COPY blah"));
    try testing.expect(!isConflictCopyName("widget"));
    try testing.expect(!isConflictCopyName("my-copy"));
    try testing.expect(!isConflictCopyName("conflict"));
    try testing.expect(!isConflictCopyName(""));
}

test "list: a conflict-copy project or org directory is never adopted as a project" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    const proot = try ws.projectsRoot(arena);
    try testutil.writeMarker(arena, proot, "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });
    // A whole-dir conflict copy of the project - marker and all, exactly what a
    // cloud client leaves behind.
    try testutil.writeMarker(arena, proot, "acme", "widget (conflicted copy 2024-01-01)", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });
    // A conflict copy of the whole org.
    try testutil.writeMarker(arena, proot, "acme (conflicted copy)", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });

    const got = try ws.list(arena);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("acme", got[0].org);
    try testing.expectEqualStrings("widget", got[0].name);
}

test "scanProjects: a dir whose marker is evicted becomes an evicted entry, not a project or a bare skip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    const proot = try ws.projectsRoot(arena);
    try testutil.writeMarker(arena, proot, "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });

    // A project dir with only the iCloud eviction placeholder where the marker
    // should be - real project, marker not downloaded.
    const evicted_dir = try std.fs.path.join(arena, &.{ proot, "acme", "gone" });
    try fsutil.ensureDir(evicted_dir);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ evicted_dir, marker.evicted_marker_basename }), .data = "" });

    const entries = try ws.scanProjects(arena);
    var ok_count: usize = 0;
    var evicted_count: usize = 0;
    for (entries) |e| switch (e) {
        .ok => ok_count += 1,
        .evicted => |m| {
            evicted_count += 1;
            try testing.expectEqualStrings("gone", m.name);
        },
        .failed => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 1), ok_count);
    try testing.expectEqual(@as(usize, 1), evicted_count);

    // list() surfaces only the readable project (the evicted one warns on stderr).
    try testing.expectEqual(@as(usize, 1), (try ws.list(arena)).len);
}

test "list: finds all orgs and projects, sorted by org/name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "zebra", "aardvark", .{ .version = 1, .org = "zebra", .name = "aardvark", .repos = emptyRepos() });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "gadget", .{ .version = 1, .org = "acme", .name = "gadget", .repos = emptyRepos() });

    const got = try ws.list(arena);

    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("acme", got[0].org);
    try testing.expectEqualStrings("gadget", got[0].name);
    try testing.expectEqualStrings("acme", got[1].org);
    try testing.expectEqualStrings("widget", got[1].name);
    try testing.expectEqualStrings("zebra", got[2].org);
    try testing.expectEqualStrings("aardvark", got[2].name);
}

test "list: a broken marker warns and is skipped, others still listed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "good", .{ .version = 1, .org = "acme", .name = "good", .repos = emptyRepos() });

    const broken_dir = try std.fs.path.join(arena, &.{ root, "projects", "acme", "broken" });
    try fsutil.ensureDir(broken_dir);
    const broken_marker = try std.fs.path.join(arena, &.{ broken_dir, marker.marker_basename });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = broken_marker, .data = "not json" });

    const got = try ws.list(arena);

    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("good", got[0].name);
}

test "find: exact org/name match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });

    const result = try ws.find(arena, "acme/widget");
    switch (result) {
        .one => |p| try testing.expectEqualStrings("widget", p.name),
        else => return error.TestUnexpectedResult,
    }
}

test "find: unique short name match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });

    const result = try ws.find(arena, "widget");
    switch (result) {
        .one => |p| try testing.expectEqualStrings("acme", p.org),
        else => return error.TestUnexpectedResult,
    }
}

test "find: ambiguous exact name reports all candidates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "other", "widget", .{ .version = 1, .org = "other", .name = "widget", .repos = emptyRepos() });

    const result = try ws.find(arena, "widget");
    switch (result) {
        .ambiguous => |cands| try testing.expectEqual(@as(usize, 2), cands.len),
        else => return error.TestUnexpectedResult,
    }
}

test "find: case-insensitive subsequence match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "dotfiles", .{ .version = 1, .org = "acme", .name = "dotfiles", .repos = emptyRepos() });

    const result = try ws.find(arena, "dtf");
    switch (result) {
        .one => |p| try testing.expectEqualStrings("dotfiles", p.name),
        else => return error.TestUnexpectedResult,
    }
}

test "find: a prefix match wins over a looser subsequence match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    // "wid" is a prefix of "widget" and only a scattered subsequence of
    // "worldwide-cdn" (w..i..d): the prefix tier decides, so widget wins
    // uniquely rather than the two being ambiguous.
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "worldwide-cdn", .{ .version = 1, .org = "acme", .name = "worldwide-cdn", .repos = emptyRepos() });

    switch (try ws.find(arena, "wid")) {
        .one => |p| try testing.expectEqualStrings("widget", p.name),
        else => return error.TestUnexpectedResult,
    }
}

test "find: smartcase - lowercase is case-insensitive, an uppercase letter makes it case-sensitive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "Widget", .{ .version = 1, .org = "acme", .name = "Widget", .repos = emptyRepos() });
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "other", "widget", .{ .version = 1, .org = "other", .name = "widget", .repos = emptyRepos() });

    // Lowercase query is case-insensitive: both names match exactly.
    switch (try ws.find(arena, "widget")) {
        .ambiguous => |c| try testing.expectEqual(@as(usize, 2), c.len),
        else => return error.TestUnexpectedResult,
    }
    // An uppercase letter forces case-sensitivity: only "Widget" matches.
    switch (try ws.find(arena, "Widget")) {
        .one => |p| try testing.expectEqualStrings("Widget", p.name),
        else => return error.TestUnexpectedResult,
    }
}

test "find: no match returns none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });

    const result = try ws.find(arena, "zzz");
    try testing.expectEqual(FindResult.none, result);
}

test "hasMalformedMarker: true for a corrupt marker, false for no such dir and for a healthy one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = emptyRepos() });

    const broken_dir = try std.fs.path.join(arena, &.{ root, "projects", "acme", "broken" });
    try fsutil.ensureDir(broken_dir);
    const broken_marker = try std.fs.path.join(arena, &.{ broken_dir, marker.marker_basename });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = broken_marker, .data = "not json" });

    try testing.expect(try ws.hasMalformedMarker(arena, "acme", "broken"));
    try testing.expect(!try ws.hasMalformedMarker(arena, "acme", "widget"));
    try testing.expect(!try ws.hasMalformedMarker(arena, "acme", "nonexistent"));
}

test "projectsUsing: returns both projects sharing one identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const ws: Workspace = .{ .cfg = try testConfig(arena, root) };

    var repos_a: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_a.put(arena, "shared", "https://github.com/acme/shared");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "fe", .{ .version = 1, .org = "acme", .name = "fe", .repos = repos_a });

    var repos_b: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos_b.put(arena, "shared", "git@github.com:acme/shared.git");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "dotfiles", .{ .version = 1, .org = "acme", .name = "dotfiles", .repos = repos_b });

    const id = try identity.fromUrl(arena, "https://github.com/acme/shared");
    const got = try ws.projectsUsing(arena, id);

    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("dotfiles", got[0].name);
    try testing.expectEqualStrings("fe", got[1].name);
}

test "listClones: returns every clone dir under code_root, sorted, excluding worktrees and temp dirs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    const code = ws.cfg.code_root;

    // A remote clone and a local clone: each a dir with a `.git` DIRECTORY.
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ code, "example.com", "acme", "backend", ".git" }));
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ code, "local", "mox", ".git" }));
    // A worktree: `.git` is a FILE, under a sibling `<repo>@worktrees` dir.
    const wt = try std.fs.path.join(arena, &.{ code, "example.com", "acme", "backend@worktrees", "feat" });
    try fsutil.ensureDir(wt);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ wt, ".git" }), .data = "gitdir: x\n" });
    // A clone-staging temp dir: skipped.
    try fsutil.ensureDir(try std.fs.path.join(arena, &.{ code, "example.com", "acme", "backend.holt-tmp", ".git" }));

    const clones = try ws.listClones(arena);
    try testing.expectEqual(@as(usize, 2), clones.len);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ code, "example.com", "acme", "backend" }), clones[0]);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ code, "local", "mox" }), clones[1]);
}

test "listClones: a missing code_root yields an empty list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root); // code_root under root, not created
    const clones = try ws.listClones(arena);
    try testing.expectEqual(@as(usize, 0), clones.len);
}
