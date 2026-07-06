//! Dynamic shell-completion engine for the declarative command framework.
//! Given the words typed so far, it decides what is being completed - a
//! subcommand name, a positional slot, or a flag - and emits candidates plus
//! one directive line the generated shell scripts act on. The engine itself
//! is generic over the command table; the only holt-specific part is
//! `candidatesFor`, the source that turns a `.dynamic` key (project, org,
//! repo, ...) into real values by querying the workspace. Splitting the two
//! keeps the framework core ready to extract as a standalone library.

const std = @import("std");
const cli = @import("cli.zig");
const workspace = @import("workspace.zig");
const marker = @import("marker.zig");
const fsutil = @import("fsutil.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

/// Tells the generated shell script how to treat the candidate list.
pub const Directive = enum {
    /// Normal completion: append a space after a unique match.
    default,
    /// Do not append a space (an org prefix the user keeps typing, `acme/`).
    nospace,
    /// Emit no candidates; let the shell complete filesystem paths itself.
    files,

    pub fn tag(self: Directive) []const u8 {
        return @tagName(self);
    }
};

pub const Result = struct {
    directive: Directive,
    candidates: []const []const u8,
};

/// Prints the completion reply for `words` (every token after the program
/// name, the last being the possibly-empty word under the cursor): a
/// directive line, then one candidate per line. Never fails the shell - a
/// broken workspace just yields no dynamic candidates.
pub fn reply(alloc: std.mem.Allocator, table: []const cli.Command, words: []const []const u8, ws: ?*const workspace.Workspace, w: *std.Io.Writer) !void {
    const r = try compute(alloc, table, words, ws);
    try w.print("{s}\n", .{r.directive.tag()});
    for (r.candidates) |c| try w.print("{s}\n", .{c});
}

/// The engine. `words[0]` is the (maybe partial) command name; a bare-command
/// completion has `words.len <= 1`.
pub fn compute(alloc: std.mem.Allocator, table: []const cli.Command, words: []const []const u8, ws: ?*const workspace.Workspace) !Result {
    if (words.len <= 1) {
        const prefix = if (words.len == 1) words[0] else "";
        return .{ .directive = .default, .candidates = try commandNames(alloc, table, prefix) };
    }

    const cmd = findCommand(table, words[0]) orelse return empty();

    // A subcommand group (org, config): if the second word names a sub, defer
    // to it for the rest; otherwise complete the sub-name itself.
    if (cmd.subcommands.len > 0) {
        if (words.len == 2) return .{ .directive = .default, .candidates = try commandNames(alloc, cmd.subcommands, words[1]) };
        if (findCommand(cmd.subcommands, words[1])) |sub| return computeFor(alloc, sub, words[2..], ws);
        return empty();
    }

    return computeFor(alloc, cmd, words[1..], ws);
}

/// Completion within a single (sub)command: `rest` is the args after the
/// command name, the last being the word under the cursor.
fn computeFor(alloc: std.mem.Allocator, cmd: cli.Command, rest: []const []const u8, ws: ?*const workspace.Workspace) !Result {
    const cur = rest[rest.len - 1];
    const prior = rest[0 .. rest.len - 1];

    // A dash-led word completes flag names, not a positional value.
    if (cur.len > 0 and cur[0] == '-') {
        return .{ .directive = .default, .candidates = try flagNames(alloc, cmd.flags, cur) };
    }

    // The word right after a value-taking flag completes that flag's value,
    // not a positional (`--org <cur>`).
    if (prior.len > 0) {
        if (pendingValueFlag(prior[prior.len - 1], cmd.flags)) |f| {
            return resolve(alloc, f.value, cur, null, ws);
        }
    }

    const slot = positionalSlot(prior, cmd.flags);
    const spec = argSpec(cmd, slot) orelse return empty();
    return resolve(alloc, spec, cur, lastPositional(prior, cmd.flags), ws);
}

/// Turns one completion spec into candidates filtered by the current word.
fn resolve(alloc: std.mem.Allocator, spec: cli.Complete, cur: []const u8, prev: ?[]const u8, ws: ?*const workspace.Workspace) !Result {
    switch (spec) {
        .none => return empty(),
        .files => return .{ .directive = .files, .candidates = &.{} },
        .choices => |cs| return .{ .directive = .default, .candidates = try filterPrefix(alloc, cs, cur) },
        .dynamic => |key| {
            // A `<project>/<repo>@<branch>` selector (for `h`/`holt path`)
            // completes the repo's worktree branches after the '@'.
            if (std.mem.eql(u8, key, "project_repo")) {
                if (std.mem.indexOfScalar(u8, cur, '@')) |at| {
                    const branches = worktreeBranchCandidates(alloc, cur[0..at], ws) catch &.{};
                    return .{ .directive = .default, .candidates = try filterPrefix(alloc, branches, cur) };
                }
            }
            const all = candidatesFor(alloc, key, prev, ws) catch &.{};
            const directive: Directive = if (std.mem.eql(u8, key, "org")) .nospace else .default;
            return .{ .directive = directive, .candidates = try filterPrefix(alloc, all, cur) };
        },
    }
}

/// The declared value-flag that `tok` names when it is a bare `--long`/`-s`
/// awaiting a value (not the self-contained `--long=v`). Null otherwise.
fn pendingValueFlag(tok: []const u8, flags: []const cli.Flag) ?cli.Flag {
    if (std.mem.indexOfScalar(u8, tok, '=') != null) return null;
    for (flags) |f| {
        if (!f.takes_value) continue;
        if (std.mem.startsWith(u8, tok, "--") and std.mem.eql(u8, tok[2..], f.long)) return f;
        if (f.short) |s| {
            if (tok.len == 2 and tok[0] == '-' and tok[1] == s) return f;
        }
    }
    return null;
}

/// The completer for positional slot `slot`, reusing a final variadic slot for
/// any slot past the end. Null when there is nothing to complete there.
fn argSpec(cmd: cli.Command, slot: usize) ?cli.Complete {
    if (cmd.args.len == 0) return null;
    if (slot < cmd.args.len) return cmd.args[slot].complete;
    const last = cmd.args[cmd.args.len - 1];
    return if (last.variadic) last.complete else null;
}

fn empty() Result {
    return .{ .directive = .default, .candidates = &.{} };
}

fn commandNames(alloc: std.mem.Allocator, table: []const cli.Command, prefix: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (table) |c| {
        if (hasPrefixIgnoreCase(c.name, prefix)) try out.append(alloc, c.name);
    }
    return out.toOwnedSlice(alloc);
}

fn flagNames(alloc: std.mem.Allocator, flags: []const cli.Flag, cur: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (flags) |f| {
        const long = try std.fmt.allocPrint(alloc, "--{s}", .{f.long});
        if (hasPrefixIgnoreCase(long, cur)) try out.append(alloc, long);
    }
    return out.toOwnedSlice(alloc);
}

fn filterPrefix(alloc: std.mem.Allocator, all: []const []const u8, cur: []const u8) ![]const []const u8 {
    if (cur.len == 0) return all;
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |c| {
        if (hasPrefixIgnoreCase(c, cur)) try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

fn hasPrefixIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (prefix.len > s.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// How many positional args appear in `prior`, so the cursor word is the
/// next slot. A declared value-flag consumes the token after it, so that
/// value is not miscounted as a positional.
fn positionalSlot(prior: []const []const u8, flags: []const cli.Flag) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < prior.len) : (i += 1) {
        const tok = prior[i];
        if (tok.len > 0 and tok[0] == '-') {
            if (std.mem.indexOfScalar(u8, tok, '=') != null) continue; // --k=v is self-contained
            if (flagTakesValue(flags, tok)) i += 1; // skip the value token
            continue;
        }
        count += 1;
    }
    return count;
}

/// The last positional value in `prior` - context for a slot that completes
/// against an earlier arg (a repo depends on its project). Null if none.
fn lastPositional(prior: []const []const u8, flags: []const cli.Flag) ?[]const u8 {
    var last: ?[]const u8 = null;
    var i: usize = 0;
    while (i < prior.len) : (i += 1) {
        const tok = prior[i];
        if (tok.len > 0 and tok[0] == '-') {
            if (std.mem.indexOfScalar(u8, tok, '=') != null) continue;
            if (flagTakesValue(flags, tok)) i += 1;
            continue;
        }
        last = tok;
    }
    return last;
}

fn flagTakesValue(flags: []const cli.Flag, tok: []const u8) bool {
    for (flags) |f| {
        if (std.mem.startsWith(u8, tok, "--") and std.mem.eql(u8, tok[2..], f.long)) return f.takes_value;
        if (f.short) |s| {
            if (tok.len == 2 and tok[0] == '-' and tok[1] == s) return f.takes_value;
        }
    }
    return false;
}

fn findCommand(table: []const cli.Command, name: []const u8) ?cli.Command {
    for (table) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// The app's dynamic completion categories, named in a command schema as
/// `comp.cat(.org)`. A typed enum, not a bare string: a schema typo is "not a
/// member of Category" (compile error), and `candidatesFor` switches over it
/// exhaustively so a new category cannot be added without a source for it.
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
};

/// Builds a schema field's completion spec from a typed `Category`. The
/// framework carries it as a string key thereafter (its engine is generic),
/// but the schema and the source both speak the enum, so neither can drift.
pub fn cat(c: Category) cli.Complete {
    return .{ .dynamic = @tagName(c) };
}

// App-specific source: turns a `.dynamic` completion key into candidate values
// by querying the workspace. This is the one holt-coupled function; the engine
// above is generic. `prev` is the preceding positional (a project, for a repo
// category). A null or unreadable workspace yields no candidates.
fn candidatesFor(alloc: std.mem.Allocator, key: []const u8, prev: ?[]const u8, ws: ?*const workspace.Workspace) ![]const []const u8 {
    const w = ws orelse return &.{};
    const category = std.meta.stringToEnum(Category, key) orelse return &.{};

    switch (category) {
        .project, .project_repo => {
            const all = try w.list(alloc);
            var out: std.ArrayList([]const u8) = .empty;
            for (all) |p| {
                try out.append(alloc, try p.qualified(alloc));
                try out.append(alloc, p.name);
            }
            return out.toOwnedSlice(alloc);
        },
        .org => {
            const all = try w.list(alloc);
            var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (all) |p| try seen.put(alloc, p.org, {});
            var out: std.ArrayList([]const u8) = .empty;
            for (seen.keys()) |org| try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}/", .{org}));
            return out.toOwnedSlice(alloc);
        },
        .repo => {
            const project = prev orelse return &.{};
            const found = try w.find(alloc, project);
            const p = switch (found) {
                .one => |one| one,
                else => return &.{},
            };
            var out: std.ArrayList([]const u8) = .empty;
            for (p.marker.repos.keys()) |name| try out.append(alloc, name);
            return out.toOwnedSlice(alloc);
        },
        .local_repo => {
            const all = try w.list(alloc);
            var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (all) |p| {
                for (p.marker.repos.keys()) |name| {
                    const url = p.marker.repos.get(name).?;
                    if (std.mem.startsWith(u8, url, "local:")) try seen.put(alloc, url["local:".len..], {});
                }
            }
            var out: std.ArrayList([]const u8) = .empty;
            for (seen.keys()) |name| try out.append(alloc, name);
            return out.toOwnedSlice(alloc);
        },
        .backend => {
            var out: std.ArrayList([]const u8) = .empty;
            for (w.cfg.presets) |preset| try out.append(alloc, preset.name);
            return out.toOwnedSlice(alloc);
        },
        .archived => return archivedQueries(alloc, w),
    }
}

/// Worktree-branch candidates for a `<project>/<repo>@<branch>` selector: each
/// worktree under the repo's `<clone>@worktrees` dir, as a full
/// `<repo_sel>@<branch>` token (slashy branches kept, since git owns that tree).
fn worktreeBranchCandidates(alloc: std.mem.Allocator, repo_sel: []const u8, ws: ?*const workspace.Workspace) ![]const []const u8 {
    const w = ws orelse return &.{};
    const slash = std.mem.lastIndexOfScalar(u8, repo_sel, '/') orelse return &.{};

    const p = switch (try w.find(alloc, repo_sel[0..slash])) {
        .one => |one| one,
        else => return &.{},
    };

    const repo_query = repo_sel[slash + 1 ..];
    var member: ?[]const u8 = null;
    for (p.marker.repos.keys()) |name| {
        if (std.mem.eql(u8, name, repo_query)) {
            member = name;
            break;
        }
    }
    const repo_name = member orelse return &.{};

    const id = p.repoIdentity(alloc, repo_name) catch return &.{};
    const clone_path = try id.clonePath(alloc, w.cfg.code_root);
    const worktrees_dir = try std.fmt.allocPrint(alloc, "{s}@worktrees", .{clone_path});

    var out: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.openDirAbsolute(fsutil.io(), worktrees_dir, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
    defer dir.close(fsutil.io());
    var walker = try dir.walkSelectively(alloc);
    defer walker.deinit();
    while (try walker.next(fsutil.io())) |entry| {
        if (entry.kind != .directory) continue;
        const full = try std.fs.path.join(alloc, &.{ worktrees_dir, entry.path });
        if (fsutil.exists(try std.fs.path.join(alloc, &.{ full, ".git" }))) {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}@{s}", .{ repo_sel, entry.path }));
        } else {
            try walker.enter(fsutil.io(), entry);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// "org/name" for every archived project (a marker under `<synced>/archive`).
fn archivedQueries(alloc: std.mem.Allocator, ws: *const workspace.Workspace) ![]const []const u8 {
    const root = try ws.archiveRoot(alloc);
    var out: std.ArrayList([]const u8) = .empty;

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
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ org_entry.name, name_entry.name }));
        }
    }
    return out.toOwnedSlice(alloc);
}

test "worktreeBranchCandidates: a repo's worktrees become <repo>@<branch> tokens" {
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
    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "proj", .{ .version = 1, .org = "acme", .name = "proj", .repos = repos });

    // Stage a worktree at <clone>@worktrees/feature/x (a .git file marks a leaf).
    const clone_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "holt-test.invalid", "acme", "backend" });
    const leaf = try std.fs.path.join(arena, &.{ try std.fmt.allocPrint(arena, "{s}@worktrees", .{clone_path}), "feature", "x" });
    try fsutil.ensureDir(leaf);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ leaf, ".git" }), .data = "gitdir: x\n" });

    const cands = try worktreeBranchCandidates(arena, "proj/backend", &ws);
    try testing.expectEqual(@as(usize, 1), cands.len);
    try testing.expectEqualStrings("proj/backend@feature/x", cands[0]);
}
