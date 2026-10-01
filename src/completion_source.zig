//! Supplies dynamic shell-completion candidates: turns a `.dynamic`
//! completion key, plus the word under the cursor, into the final
//! `cli.complete.Result` (directive and filtered candidates). cli-zig's
//! engine does not post-filter a dynamic reply, so this hook owns filtering
//! itself against the word under the cursor.

const std = @import("std");
const cli = @import("cli");
const workspace = @import("workspace.zig");
const config = @import("config.zig");
const project = @import("project.zig");
const marker = @import("marker.zig");
const identity = @import("identity.zig");
const fsutil = @import("fsutil.zig");
const kept = @import("kept.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

const Directive = cli.complete.Directive;
const Candidate = cli.complete.Candidate;
const Result = cli.complete.Result;

/// The hook cli-zig calls for every `.dynamic` completion spec. Sees the
/// word under the cursor (`cur`) and owns the whole `Result`. `ctx` is
/// `anytype` (a `*HoltCli.Ctx`, though that type cannot be named here -
/// `Cli(cfg)` is still being built from this very hook) with a
/// `context: ?struct { ws: workspace.Workspace, .. }` field; a null context
/// (a broken or absent config) yields no candidates rather than failing the
/// shell.
pub fn resolveCompletion(alloc: std.mem.Allocator, key: []const u8, prev: ?[]const u8, cur: []const u8, ctx: anytype) anyerror!Result {
    const ws: ?*const workspace.Workspace = if (ctx.context) |*c| &c.ws else null;

    // A path-shaped word on any `.project`-category slot (every positional
    // and `-p` flag using it, across the whole command table) completes
    // filesystem paths instead of filtering project names: no project query
    // is ever path-shaped, so treating one as a path is always the more
    // useful reading. No `.project_repo` selector ever takes a bare path, so
    // it must stay out of this guard - otherwise a `<project>/<repo>@<branch>`
    // selector with 2+ slashes gets routed here before the '@'-branch
    // handler below ever sees it.
    if (std.mem.eql(u8, key, "project") and isPathShaped(cur)) {
        return .{ .directive = .files, .candidates = &.{} };
    }

    // A `<project>/<repo>@<branch>` selector (for `h`/`holt path`) completes
    // the repo's worktree branches after the '@'.
    if (std.mem.eql(u8, key, "project_repo")) {
        if (std.mem.indexOfScalar(u8, cur, '@')) |at| {
            const branches = worktreeBranchCandidates(alloc, cur[0..at], ws) catch &.{};
            return .{ .directive = .default, .candidates = try filterMatches(alloc, branches, cur) };
        }
    }

    if (std.mem.eql(u8, key, "keep_arg")) switch (keepArgMode()) {
        .files => return .{ .directive = .files, .candidates = &.{} },
        .entries => {
            const entries = candidatesFor(alloc, "aside_entry", prev, ws) catch &.{};
            return .{ .directive = .default, .candidates = try filterMatches(alloc, entries, cur) };
        },
        .machines, .retired => {},
    };

    const all = candidatesFor(alloc, key, prev, ws) catch &.{};
    const directive: Directive = if (std.mem.eql(u8, key, "org")) .nospace else .default;
    return .{ .directive = directive, .candidates = try filterMatches(alloc, all, cur) };
}

/// What `holt keep`'s arguments are, by the mode flag on the command line:
/// machine ids after `--retire-machine`, retired ones after
/// `--unretire-machine`, aside entries after `--prune-aside`, and
/// otherwise files.
const KeepArgMode = enum { files, machines, retired, entries };

fn keepArgMode() KeepArgMode {
    for (command_line) |word| {
        if (std.mem.eql(u8, word, "--retire-machine")) return .machines;
        if (std.mem.eql(u8, word, "--unretire-machine")) return .retired;
        if (std.mem.eql(u8, word, "--prune-aside")) return .entries;
    }
    return .files;
}

/// Whether `cur` looks like a filesystem path rather than an `org/name`
/// project query: a leading `./`, `/`, or `~`, a Windows drive letter
/// (`X:`), or more than one `/` (an `org/name` selector has exactly one).
fn isPathShaped(cur: []const u8) bool {
    if (cur.len == 0) return false;
    if (cur[0] == '/' or cur[0] == '~' or cur[0] == '.') return true;
    if (cur.len >= 2 and std.ascii.isAlphabetic(cur[0]) and cur[1] == ':') return true;
    var slashes: usize = 0;
    for (cur) |c| {
        if (c == '/') slashes += 1;
    }
    return slashes > 1;
}

/// Wraps plain values as descriptionless candidates, for sources that don't
/// (yet) carry an annotation.
fn plain(alloc: std.mem.Allocator, values: []const []const u8) ![]const Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    for (values) |v| try out.append(alloc, .{ .value = v });
    return out.toOwnedSlice(alloc);
}

fn hasPrefixIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (prefix.len > s.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// Match like the resolver: case-insensitive subsequence (smartcase: a query
/// with an uppercase letter matches case-sensitively). Prefix and exact
/// matches are subsequences too, so no separate check is needed for either.
fn matches(query: []const u8, target: []const u8) bool {
    if (query.len == 0) return true;
    const cased = for (query) |c| {
        if (std.ascii.isUpper(c)) break true;
    } else false;
    if (cased) return isSubsequence(query, target);
    return workspace.isSubsequenceIgnoreCase(query, target);
}

fn isSubsequence(query: []const u8, target: []const u8) bool {
    var qi: usize = 0;
    for (target) |tc| {
        if (qi == query.len) break;
        if (tc == query[qi]) qi += 1;
    }
    return qi == query.len;
}

/// Rank: 0 exact, 1 prefix, 2 subsequence; drop non-matches. Within a rank,
/// ties break on original index so ordering is deterministic regardless of
/// whether the sort implementation is stable. Matches (and ranks) on each
/// candidate's `.value`; its description rides along unchanged.
fn filterMatches(alloc: std.mem.Allocator, all: []const Candidate, cur: []const u8) ![]const Candidate {
    if (cur.len == 0) return all;
    const Ranked = struct { rank: u8, idx: usize, val: Candidate };
    var ranked: std.ArrayList(Ranked) = .empty;
    for (all, 0..) |c, i| {
        if (!matches(cur, c.value)) continue;
        const rank: u8 = if (std.ascii.eqlIgnoreCase(c.value, cur)) 0 else if (hasPrefixIgnoreCase(c.value, cur)) 1 else 2;
        try ranked.append(alloc, .{ .rank = rank, .idx = i, .val = c });
    }
    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn lt(_: void, a: Ranked, b: Ranked) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            return a.idx < b.idx;
        }
    }.lt);
    var out: std.ArrayList(Candidate) = .empty;
    for (ranked.items) |r| try out.append(alloc, r.val);
    return out.toOwnedSlice(alloc);
}

/// The app's dynamic completion categories, named in a command schema as
/// `.dynamic = @tagName(.org)`. A typed enum, not a bare string: a schema
/// typo is "not a member of Category" (compile error), and `candidatesFor`
/// switches over it exhaustively so a new category cannot be added without a
/// source for it.
pub const Category = enum {
    /// A project query: `org/name` and bare `name`.
    project,
    /// Same candidates as `project`; a distinct slot for a `<project>/<repo>`.
    project_repo,
    /// Existing org names (each with a trailing `/`, no-space).
    org,
    /// The member repos of the project named in the preceding positional.
    repo,
    /// Archived project queries.
    archived,
    /// Distinct `local:` repo names, for `promote`.
    local_repo,
    /// Configured backend preset names.
    backend,
    /// Builtin backend seeds (`holt setup --backend`), independent of config.
    backend_seed,
    /// A repo's existing worktree branches (bare, no `<repo>@` prefix).
    worktree_branch,
    /// The kept paths of the clone containing the working directory, below
    /// the working directory and relative to it.
    kept_path,
    /// The entries under `kept/.holt-aside/`, each described by the key
    /// and path it holds.
    aside_entry,
    /// The keys of the kept store.
    kept_key,
    /// The released paths of the clone containing the working directory,
    /// as `kept_path` gives kept ones.
    released_path,
    /// `holt keep`'s arguments: after `--retire-machine`, the ids of the
    /// machines the kept store records (`kept/.holt-machines`), each
    /// described by its host label; after `--unretire-machine`, those of
    /// them that are retired; after `--prune-aside`, the aside entries as
    /// `aside_entry` gives them; otherwise files.
    keep_arg,
};

/// This process's command line, for a completion that depends on a flag
/// given before the cursor: cli-zig passes a resolver only the preceding
/// positional.
pub var command_line: []const []const u8 = &.{};

/// Builds a schema field's completion spec from a typed `Category`. The
/// framework carries it as a string key thereafter (its engine is generic),
/// but the schema and this hook both speak the enum, so neither can drift.
pub fn cat(c: Category) cli.meta.Complete {
    return .{ .dynamic = @tagName(c) };
}

// App-specific source: turns a `.dynamic` completion key into candidate
// values by querying the workspace. `prev` is the preceding positional (a
// project, for a repo category). A null or unreadable workspace yields no
// candidates.
fn candidatesFor(alloc: std.mem.Allocator, key: []const u8, prev: ?[]const u8, ws: ?*const workspace.Workspace) ![]const Candidate {
    const category = std.meta.stringToEnum(Category, key) orelse return &.{};

    // Builtin seeds are fixed data, not config - offered even before a
    // config.toml exists, so `holt setup --backend <TAB>` works on a fresh
    // install where the workspace fails to load.
    if (category == .backend_seed) {
        var out: std.ArrayList(Candidate) = .empty;
        for (config.builtin_seeds) |seed| try out.append(alloc, .{ .value = seed.name, .description = seed.synced_root });
        return out.toOwnedSlice(alloc);
    }

    const w = ws orelse return &.{};

    switch (category) {
        .project, .project_repo => {
            const all = try w.list(alloc);
            var out: std.ArrayList(Candidate) = .empty;
            for (all) |p| {
                try out.append(alloc, .{ .value = try p.qualified(alloc), .description = p.org });
                try out.append(alloc, .{ .value = p.name, .description = p.org });
            }
            return out.toOwnedSlice(alloc);
        },
        .org => {
            const all = try w.list(alloc);
            var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (all) |p| try seen.put(alloc, p.org, {});
            for (try archivedOrgNames(alloc, w)) |org| try seen.put(alloc, org, {});
            var out: std.ArrayList([]const u8) = .empty;
            for (seen.keys()) |org| try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}/", .{org}));
            return plain(alloc, try out.toOwnedSlice(alloc));
        },
        .repo => {
            // With a project named ahead of the cursor, offer only its members.
            // Without one - `repo remove <repo> -p <project>` puts the project
            // after the cursor - offer every member name in the workspace, so
            // the slot still completes.
            if (prev) |project_query| {
                if (try oneProject(alloc, w, project_query)) |p| {
                    var out: std.ArrayList(Candidate) = .empty;
                    for (p.marker.entries) |*e| {
                        if (e.raw_source == null) continue;
                        try out.append(alloc, .{ .value = e.name, .description = repoState(alloc, e, w.cfg.code_root) });
                    }
                    return out.toOwnedSlice(alloc);
                }
            }
            const all = try w.list(alloc);
            var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (all) |p| {
                for (p.marker.entries) |*e| {
                    if (e.raw_source == null) continue;
                    try seen.put(alloc, e.name, {});
                }
            }
            var out: std.ArrayList([]const u8) = .empty;
            for (seen.keys()) |name| try out.append(alloc, name);
            return plain(alloc, try out.toOwnedSlice(alloc));
        },
        .local_repo => {
            const all = try w.list(alloc);
            var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (all) |p| {
                for (p.marker.entries) |*e| {
                    const src = e.source orelse continue;
                    const seg = switch (src) {
                        .local => |s| s,
                        .remote => continue,
                    };
                    try seen.put(alloc, seg.bytes, {});
                }
            }
            var out: std.ArrayList([]const u8) = .empty;
            for (seen.keys()) |name| try out.append(alloc, name);
            return plain(alloc, try out.toOwnedSlice(alloc));
        },
        .backend => {
            var out: std.ArrayList(Candidate) = .empty;
            for (w.cfg.presets) |preset| try out.append(alloc, .{ .value = preset.name, .description = preset.synced_root });
            return out.toOwnedSlice(alloc);
        },
        .archived => return archivedQueries(alloc, w),
        .worktree_branch => {
            const repo_sel = prev orelse return &.{};
            const full = try worktreeBranchCandidates(alloc, repo_sel, ws);
            const prefix_len = repo_sel.len + 1; // "<repo_sel>@"
            var out: std.ArrayList(Candidate) = .empty;
            for (full) |c| {
                if (c.value.len < prefix_len) continue;
                try out.append(alloc, .{ .value = c.value[prefix_len..], .description = c.description });
            }
            return out.toOwnedSlice(alloc);
        },
        .kept_path => return keptPathCandidates(alloc, w, .kept),
        .released_path => return keptPathCandidates(alloc, w, .released),
        .aside_entry => {
            const layout: kept.store.Layout = .{ .synced_root = w.cfg.synced_root };
            var out: std.ArrayList(Candidate) = .empty;
            var d = std.Io.Dir.cwd().openDir(fsutil.io(), try layout.asideDir(alloc), .{ .iterate = true }) catch return &.{};
            defer d.close(fsutil.io());
            var it = d.iterate();
            while (try it.next(fsutil.io())) |e| {
                if (e.kind != .directory) continue;
                const name = try alloc.dupe(u8, e.name);
                const m = kept.aside.readManifest(alloc, layout, name) catch null;
                const desc: ?[]const u8 = if (m) |man| try std.fmt.allocPrint(alloc, "{s} {s}", .{ man.key, man.rel }) else null;
                try out.append(alloc, .{ .value = name, .description = desc });
            }
            std.mem.sort(Candidate, out.items, {}, struct {
                fn lt(_: void, a: Candidate, b: Candidate) bool {
                    return std.mem.lessThan(u8, a.value, b.value);
                }
            }.lt);
            return out.toOwnedSlice(alloc);
        },
        .kept_key => {
            const index = try kept.store.loadIndex(alloc, .{ .synced_root = w.cfg.synced_root });
            return plain(alloc, index.keys);
        },
        .keep_arg => {
            const layout: kept.store.Layout = .{ .synced_root = w.cfg.synced_root };
            var out: std.ArrayList(Candidate) = .empty;
            var d = std.Io.Dir.cwd().openDir(fsutil.io(), try std.fs.path.join(alloc, &.{ try layout.keptDir(alloc), ".holt-machines" }), .{ .iterate = true }) catch return &.{};
            defer d.close(fsutil.io());
            var it = d.iterate();
            while (try it.next(fsutil.io())) |e| {
                if (e.kind != .directory or !kept.machine.valid(e.name)) continue;
                const id = try alloc.dupe(u8, e.name);
                if (keepArgMode() == .retired and (kept.store.readRetired(alloc, layout, id) catch null) == null) continue;
                try out.append(alloc, .{ .value = id, .description = kept.store.readHost(alloc, layout, id) catch null });
            }
            std.mem.sort(Candidate, out.items, {}, struct {
                fn lt(_: void, a: Candidate, b: Candidate) bool {
                    return std.mem.lessThan(u8, a.value, b.value);
                }
            }.lt);
            return out.toOwnedSlice(alloc);
        },
        .backend_seed => unreachable, // handled above, before a workspace is required
    }
}

/// The kept paths, or the released ones, of the clone containing the
/// working directory, in the key its files live in, that lie below the
/// working directory, written relative to it and, for kept paths,
/// described by their kind.
fn keptPathCandidates(alloc: std.mem.Allocator, w: *const workspace.Workspace, which: enum { kept, released }) ![]const Candidate {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = try fsutil.realPathOrSelf(alloc, buf[0..try std.process.currentPath(fsutil.io(), &buf)]);
    const c = try kept.clone.inspect(alloc, (try kept.clone.enclosing(alloc, cwd)) orelse return &.{}, w.cfg.code_root);
    const own = c.key orelse return &.{};
    const layout: kept.store.Layout = .{ .synced_root = w.cfg.synced_root };
    const index = try kept.store.loadIndex(alloc, layout);
    const key = switch (try kept.store.resolve(alloc, layout, &index, own, try kept.clone.rootCommits(alloc, c.main))) {
        .own, .awaiting_promote => own,
        .successor => |succ| succ,
    };
    const ks = try kept.store.loadKeyState(alloc, layout, key);
    var prefix: []const u8 = "";
    if (!std.mem.eql(u8, cwd, c.worktree)) {
        if (!fsutil.pathIsInside(cwd, c.worktree)) return &.{};
        const rel = try alloc.dupe(u8, cwd[c.worktree.len + 1 ..]);
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        prefix = try std.mem.concat(alloc, u8, &.{ rel, "/" });
    }
    var out: std.ArrayList(Candidate) = .empty;
    const rels = switch (which) {
        .kept => try ks.keptSet(alloc),
        .released => ks.released,
    };
    for (rels) |rel| {
        if (!std.mem.startsWith(u8, rel, prefix) or rel.len == prefix.len) continue;
        const facts = ks.factsFor(rel);
        try out.append(alloc, .{ .value = rel[prefix.len..], .description = if (facts.len > 0) @tagName(facts[0].kind) else null });
    }
    return out.toOwnedSlice(alloc);
}

/// The single project `query` names, or null when it matches none or many.
fn oneProject(alloc: std.mem.Allocator, w: *const workspace.Workspace, query: []const u8) !?project.Project {
    return switch (try w.find(alloc, query)) {
        .one => |p| p,
        else => null,
    };
}

/// A repo's clone state, for the `.repo` category's description: `"local"`
/// for a repo with no remote yet (a `local:` marker entry), else `"cloned"`
/// or `"missing"` depending on whether its clone path exists on disk. One
/// `fsutil.exists` check per repo - no git.
fn repoState(alloc: std.mem.Allocator, e: *const marker.Entry, code_root: []const u8) ?[]const u8 {
    const src = e.source orelse return null;
    const id = src.id();
    if (id.isLocal()) return "local";
    const clone_path = id.clonePath(alloc, code_root) catch return null;
    return if (fsutil.exists(clone_path)) "cloned" else "missing";
}

/// Worktree-branch candidates for a `<project>/<repo>@<branch>` selector:
/// each worktree under the repo's `<clone>@worktrees` dir, as a full
/// `<repo_sel>@<branch>` token (slashy branches kept, since git owns that
/// tree).
fn worktreeBranchCandidates(alloc: std.mem.Allocator, repo_sel: []const u8, ws: ?*const workspace.Workspace) ![]const Candidate {
    const w = ws orelse return &.{};
    const slash = std.mem.lastIndexOfScalar(u8, repo_sel, '/') orelse return &.{};

    const p = switch (try w.find(alloc, repo_sel[0..slash])) {
        .one => |one| one,
        else => return &.{},
    };

    const repo_query = repo_sel[slash + 1 ..];
    const member = p.marker.findRepo(repo_query) orelse return &.{};
    const src = member.source orelse return &.{};
    const clone_path = try src.id().clonePath(alloc, w.cfg.code_root);
    const worktrees_dir = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{clone_path});

    var out: std.ArrayList(Candidate) = .empty;
    var dir = std.Io.Dir.openDirAbsolute(fsutil.io(), worktrees_dir, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
    defer dir.close(fsutil.io());
    var walker = try dir.walkSelectively(alloc);
    defer walker.deinit();
    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind != .directory) continue;
        const full = try std.fs.path.join(alloc, &.{ worktrees_dir, entry.path });
        if (fsutil.exists(try std.fs.path.join(alloc, &.{ full, ".git" }))) {
            // Branch names namespace on '/' (git's own separator, not the
            // platform's); the walker reports nesting with the native
            // separator, so translate it back for a round-trippable token.
            const branch = if (std.fs.path.sep == '/') try alloc.dupe(u8, entry.path) else blk: {
                const buf = try alloc.dupe(u8, entry.path);
                std.mem.replaceScalar(u8, buf, std.fs.path.sep, '/');
                break :blk buf;
            };
            try out.append(alloc, .{ .value = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ repo_sel, branch }), .description = branch });
        } else {
            try walker.enter(fsutil.io(), entry);
        }
    }
    // The walk yields the filesystem's order, which differs across
    // filesystems, and `filterMatches` preserves input order for ties and for
    // an empty prefix -- so sort here, or the completion menu varies per
    // machine.
    std.mem.sort(Candidate, out.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            return std.mem.lessThan(u8, a.value, b.value);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

const ArchivedProject = struct { org: []const u8, name: []const u8 };

/// Every archived project (a marker under `<synced>/archive/<org>/<name>`).
/// `org`/`name` are duped: the directory iterators reuse their name buffers
/// across `next()`, so the raw entry slices do not outlive the walk.
fn archivedProjects(alloc: std.mem.Allocator, ws: *const workspace.Workspace) ![]const ArchivedProject {
    const root = try ws.archiveRoot(alloc);
    var out: std.ArrayList(ArchivedProject) = .empty;

    var root_dir = std.Io.Dir.openDirAbsolute(fsutil.io(), root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return &.{},
        else => return err,
    };
    defer root_dir.close(fsutil.io());

    var org_it = root_dir.iterate();
    while (try org_it.next(fsutil.io())) |org_entry| {
        if (org_entry.kind != .directory) continue;
        var org_dir = try root_dir.openDir(fsutil.io(), org_entry.name, .{ .iterate = true });
        defer org_dir.close(fsutil.io());
        var name_it = org_dir.iterate();
        while (try name_it.next(fsutil.io())) |name_entry| {
            if (name_entry.kind != .directory) continue;
            const marker_path = try std.fs.path.join(alloc, &.{ root, org_entry.name, name_entry.name, marker.marker_basename });
            if (!fsutil.exists(marker_path)) continue;
            try out.append(alloc, .{ .org = try alloc.dupe(u8, org_entry.name), .name = try alloc.dupe(u8, name_entry.name) });
        }
    }
    // Directory iteration order is the filesystem's; sort so archived-project
    // completions (and the org names derived from this list) read identically
    // on every machine.
    std.mem.sort(ArchivedProject, out.items, {}, struct {
        fn lt(_: void, a: ArchivedProject, b: ArchivedProject) bool {
            if (!std.mem.eql(u8, a.org, b.org)) return std.mem.lessThan(u8, a.org, b.org);
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

/// Distinct org dir names under the archive holding at least one archived
/// project - orgs an `org` completion must offer even when every project
/// under them has been archived (no active project keeps them alive in
/// `w.list`).
fn archivedOrgNames(alloc: std.mem.Allocator, ws: *const workspace.Workspace) ![]const []const u8 {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (try archivedProjects(alloc, ws)) |p| try seen.put(alloc, p.org, {});
    return alloc.dupe([]const u8, seen.keys());
}

/// "org/name" for every archived project.
fn archivedQueries(alloc: std.mem.Allocator, ws: *const workspace.Workspace) ![]const Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    for (try archivedProjects(alloc, ws)) |p| {
        try out.append(alloc, .{ .value = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ p.org, p.name }), .description = "archived" });
    }
    return out.toOwnedSlice(alloc);
}

// Tests below drive `resolveCompletion` directly with a minimal stand-in
// context (any struct with a `context: ?struct{ ws, .. }` field works, since
// the hook takes `ctx: anytype`).

const TestContext = struct { ws: workspace.Workspace };
const TestCtx = struct { context: ?TestContext };

fn noWs() TestCtx {
    return .{ .context = null };
}

fn withWs(ws: workspace.Workspace) TestCtx {
    return .{ .context = .{ .ws = ws } };
}

test "resolveCompletion: backend_seed lists the builtin seeds even with no context" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = noWs();
    const got = try resolveCompletion(arena, "backend_seed", null, "", &ctx);
    try testing.expectEqual(Directive.default, got.directive);
    try testing.expectEqual(config.builtin_seeds.len, got.candidates.len);
}

test "resolveCompletion: org filters and directs .nospace, including archive-only orgs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);
    try testutil.writeMarker(arena, try ws.archiveRoot(arena), "gone", "old", .empty, .empty);

    var ctx = withWs(ws);

    const got = try resolveCompletion(arena, "org", null, "", &ctx);
    try testing.expectEqual(Directive.nospace, got.directive);
    var found_acme = false;
    var found_gone = false;
    for (got.candidates) |c| {
        if (std.mem.eql(u8, c.value, "acme/")) found_acme = true;
        if (std.mem.eql(u8, c.value, "gone/")) found_gone = true;
    }
    try testing.expect(found_acme);
    try testing.expect(found_gone);

    const filtered = try resolveCompletion(arena, "org", null, "ac", &ctx);
    try testing.expectEqual(@as(usize, 1), filtered.candidates.len);
    try testing.expectEqualStrings("acme/", filtered.candidates[0].value);
}

test "resolveCompletion: repo completes off the preceding project positional" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try repos.put(arena, "frontend", "https://holt-test.invalid/acme/frontend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", repos, .empty);

    var ctx = withWs(ws);
    const got = try resolveCompletion(arena, "repo", "widget", "back", &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("backend", got.candidates[0].value);
}

test "resolveCompletion: a path-shaped current word on the project key falls back to file completion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .empty, .empty);

    var ctx = withWs(ws);

    const path_got = try resolveCompletion(arena, "project", null, "./checkouts/wi", &ctx);
    try testing.expectEqual(Directive.files, path_got.directive);
    try testing.expectEqual(@as(usize, 0), path_got.candidates.len);

    const proj_got = try resolveCompletion(arena, "project", null, "wid", &ctx);
    try testing.expectEqual(Directive.default, proj_got.directive);
    var found_widget = false;
    for (proj_got.candidates) |c| {
        if (std.mem.eql(u8, c.value, "widget")) found_widget = true;
    }
    try testing.expect(found_widget);

    const org_name_got = try resolveCompletion(arena, "project", null, "acme/wid", &ctx);
    try testing.expectEqual(Directive.default, org_name_got.directive);
    var found_qualified = false;
    for (org_name_got.candidates) |c| {
        if (std.mem.eql(u8, c.value, "acme/widget")) found_qualified = true;
    }
    try testing.expect(found_qualified);
}

test "resolveCompletion: project_repo with an '@' completes worktree branches filtered by the whole cur" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "backend" });
    const leaf = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "feature", "x" });
    try fsutil.ensureDir(leaf);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ leaf, ".git" }), .data = "gitdir: x\n" });

    var ctx = withWs(ws);

    // A qualified `org/project/repo@branch` selector reaches the '@' handler
    // (2+ slashes before the '@'), not the path-shape fallback that guards
    // only the `.project` key.
    const got = try resolveCompletion(arena, "project_repo", null, "proj/backend@feat", &ctx);
    try testing.expectEqual(Directive.default, got.directive);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("proj/backend@feature/x", got.candidates[0].value);
}

test "resolveCompletion: worktree_branch returns bare branch names for the preceding repo positional" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(arena, "backend", "https://holt-test.invalid/acme/backend");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "backend" });
    const leaf = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "feature", "x" });
    try fsutil.ensureDir(leaf);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ leaf, ".git" }), .data = "gitdir: x\n" });

    var ctx = withWs(ws);
    const got = try resolveCompletion(arena, "worktree_branch", "proj/backend", "", &ctx);
    try testing.expectEqual(@as(usize, 1), got.candidates.len);
    try testing.expectEqualStrings("feature/x", got.candidates[0].value);
}

test "candidatesFor: .repo offers every project's members when no project precedes it" {
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

    const got = try candidatesFor(arena, "repo", null, &ws);
    var saw = false;
    for (got) |c| {
        if (std.mem.eql(u8, c.value, "widget")) saw = true;
    }
    try testing.expect(saw);
}

test "candidatesFor: .local_repo offers a usable local name and skips a traversing one" {
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
    try repos.put(arena, "widget", "local:../../outside/victim");
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", repos, .empty);

    const got = try candidatesFor(arena, "local_repo", null, &ws);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("scratch", got[0].value);
}

test "resolveCompletion: an unresolvable context yields no candidates rather than failing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = noWs();
    const got = try resolveCompletion(arena, "project", null, "wid", &ctx);
    try testing.expectEqual(Directive.default, got.directive);
    try testing.expectEqual(@as(usize, 0), got.candidates.len);
}

test "resolveCompletion: kept paths below the working directory, released ones for --purge, aside entries with what they hold, and keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();

    const ws = try testutil.testWorkspace(arena, try arena.dupe(u8, sb.root));
    const bare = try testutil.makeBareRepo(&sb, "widget.git");
    defer testing.allocator.free(bare);
    const clone_path = try fsutil.joinSlashy(arena, ws.cfg.code_root, "github.com/acme/widget");
    try testutil.runGit(&sb, null, &.{ "clone", "-q", bare, clone_path });
    try fsutil.ensureDir(try fsutil.joinSlashy(arena, clone_path, "app/config"));

    const layout: kept.store.Layout = .{ .synced_root = ws.cfg.synced_root };
    const key = "github.com/acme/widget";
    const hex = "a" ** 64;
    try kept.store.createExclusive(arena, try layout.reserved(arena, key, kept.store.record_basename), "{\"version\": 1}\n");
    try kept.store.writeFact(arena, layout, key, "000000000000000a", ".env", .file, hex);
    try kept.store.writeFact(arena, layout, key, "000000000000000a", "app/config/local.json", .file, hex);
    try kept.store.writeFact(arena, layout, key, "000000000000000a", "gone", .file, hex);
    try kept.store.writeReleased(arena, layout, key, "gone");
    const source = try fsutil.joinSlashy(arena, clone_path, "README");
    const e = try kept.aside.setAside(arena, layout, "000000000000000a", key, ".env", source, .keep);

    var orig_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const orig = try testing.allocator.dupe(u8, orig_buf[0..try std.process.currentPath(fsutil.io(), &orig_buf)]);
    defer testing.allocator.free(orig);
    defer std.process.setCurrentPath(fsutil.io(), orig) catch {};

    var ctx = withWs(ws);
    try std.process.setCurrentPath(fsutil.io(), clone_path);
    const top = try resolveCompletion(arena, "kept_path", null, "", &ctx);
    try testing.expectEqual(@as(usize, 2), top.candidates.len);
    try testing.expectEqualStrings(".env", top.candidates[0].value);
    try testing.expectEqualStrings("file", top.candidates[0].description.?);
    try testing.expectEqualStrings("app/config/local.json", top.candidates[1].value);

    try std.process.setCurrentPath(fsutil.io(), try fsutil.joinSlashy(arena, clone_path, "app"));
    const below = try resolveCompletion(arena, "kept_path", null, "", &ctx);
    try testing.expectEqual(@as(usize, 1), below.candidates.len);
    try testing.expectEqualStrings("config/local.json", below.candidates[0].value);

    const entries = try resolveCompletion(arena, "aside_entry", null, "", &ctx);
    try testing.expectEqual(@as(usize, 1), entries.candidates.len);
    try testing.expectEqualStrings(e.stamp, entries.candidates[0].value);
    try testing.expectEqualStrings("github.com/acme/widget .env", entries.candidates[0].description.?);

    const keys = try resolveCompletion(arena, "kept_key", null, "acme", &ctx);
    try testing.expectEqual(@as(usize, 1), keys.candidates.len);
    try testing.expectEqualStrings(key, keys.candidates[0].value);

    try std.process.setCurrentPath(fsutil.io(), clone_path);
    const released = try resolveCompletion(arena, "released_path", null, "", &ctx);
    try testing.expectEqual(@as(usize, 1), released.candidates.len);
    try testing.expectEqualStrings("gone", released.candidates[0].value);

    try std.process.setCurrentPath(fsutil.io(), sb.root);
    try testing.expectEqual(@as(usize, 0), (try resolveCompletion(arena, "kept_path", null, "", &ctx)).candidates.len);
    try testing.expectEqual(@as(usize, 0), (try resolveCompletion(arena, "released_path", null, "", &ctx)).candidates.len);
}

test "resolveCompletion: holt keep completes files, machine ids with their hosts after --retire-machine, retired ones after --unretire-machine, and aside entries after --prune-aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, try arena.dupe(u8, sb.root));
    const layout: kept.store.Layout = .{ .synced_root = ws.cfg.synced_root };
    try kept.store.writeHost(arena, layout, "000000000000000a", "laptop");
    try kept.store.writeHost(arena, layout, "000000000000000b", "desktop");
    var ctx = withWs(ws);
    const saved = command_line;
    defer command_line = saved;

    command_line = &.{ "holt", "__complete", "keep", "" };
    try testing.expectEqual(Directive.files, (try resolveCompletion(arena, "keep_arg", null, "", &ctx)).directive);

    command_line = &.{ "holt", "__complete", "keep", "--retire-machine", "0" };
    const ids = try resolveCompletion(arena, "keep_arg", null, "0", &ctx);
    try testing.expectEqual(Directive.default, ids.directive);
    try testing.expectEqual(@as(usize, 2), ids.candidates.len);
    try testing.expectEqualStrings("000000000000000a", ids.candidates[0].value);
    try testing.expectEqualStrings("laptop", ids.candidates[0].description.?);
    try testing.expectEqualStrings("000000000000000b", ids.candidates[1].value);

    const index = try kept.store.loadIndex(arena, layout);
    try kept.store.writeRetired(arena, layout, &index, "000000000000000b", "2026-01-01", "laptop", "000000000000000a");
    command_line = &.{ "holt", "__complete", "keep", "--unretire-machine", "" };
    const retired = try resolveCompletion(arena, "keep_arg", null, "", &ctx);
    try testing.expectEqual(@as(usize, 1), retired.candidates.len);
    try testing.expectEqualStrings("000000000000000b", retired.candidates[0].value);
    try testing.expectEqualStrings("desktop", retired.candidates[0].description.?);

    const source = try std.fs.path.join(arena, &.{ sb.root, "env" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = source, .data = "x" });
    const e = try kept.aside.setAside(arena, layout, "000000000000000a", "github.com/acme/widget", ".env", source, .keep);
    command_line = &.{ "holt", "__complete", "keep", "--prune-aside", "" };
    const entries = try resolveCompletion(arena, "keep_arg", null, "", &ctx);
    try testing.expectEqual(Directive.default, entries.directive);
    try testing.expectEqual(@as(usize, 1), entries.candidates.len);
    try testing.expectEqualStrings(e.stamp, entries.candidates[0].value);
    try testing.expectEqualStrings("github.com/acme/widget .env", entries.candidates[0].description.?);
}
