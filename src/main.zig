const std = @import("std");
const cli = @import("cli.zig");
const completion = @import("completion.zig");
const testutil = @import("testutil.zig");
const marker = @import("marker.zig");
const workspace = @import("workspace.zig");
const testing = std.testing;
const version_cmd = @import("commands/version.zig");
const init_cmd = @import("commands/init.zig");
const setup_cmd = @import("commands/setup.zig");
const path_cmd = @import("commands/path.zig");
const list_cmd = @import("commands/list.zig");
const new_cmd = @import("commands/new.zig");
const add_cmd = @import("commands/add.zig");
const get_cmd = @import("commands/get.zig");
const create_cmd = @import("commands/create.zig");
const rm_cmd = @import("commands/rm.zig");
const alias_cmd = @import("commands/alias.zig");
const sync_cmd = @import("commands/sync.zig");
const restore_cmd = @import("commands/restore.zig");
const doctor_cmd = @import("commands/doctor.zig");
const promote_cmd = @import("commands/promote.zig");
const archive_cmd = @import("commands/archive.zig");
const delete_cmd = @import("commands/delete.zig");
const rename_cmd = @import("commands/rename.zig");
const org_cmd = @import("commands/org.zig");
const backup_cmd = @import("commands/backup.zig");
const info_cmd = @import("commands/info.zig");
const status_cmd = @import("commands/status.zig");
const backends_cmd = @import("commands/backends.zig");
const backend_cmd = @import("commands/backend.zig");
const recent_cmd = @import("commands/recent.zig");
const adopt_cmd = @import("commands/adopt.zig");
const keep_cmd = @import("commands/keep.zig");
const edit_cmd = @import("commands/edit.zig");
const config_cmd = @import("commands/config.zig");
const run_cmd = @import("commands/run.zig");
const upgrade_cmd = @import("commands/upgrade.zig");
const worktree_cmd = @import("commands/worktree.zig");

pub const command_table = [_]cli.Command{
    path_cmd.command,
    list_cmd.command,
    init_cmd.command,
    setup_cmd.command,
    new_cmd.command,
    add_cmd.command,
    get_cmd.command,
    create_cmd.command,
    rm_cmd.command,
    alias_cmd.command,
    adopt_cmd.command,
    keep_cmd.command,
    info_cmd.command,
    status_cmd.command,
    backends_cmd.command,
    recent_cmd.command,
    sync_cmd.command,
    restore_cmd.command,
    doctor_cmd.command,
    promote_cmd.command,
    rename_cmd.command,
    org_cmd.command,
    archive_cmd.command,
    backup_cmd.command,
    edit_cmd.command,
    worktree_cmd.command,
    backend_cmd.command,
    config_cmd.command,
    run_cmd.command,
    version_cmd.command,
    upgrade_cmd.command,
    delete_cmd.command,
};

pub fn main(init: std.process.Init) u8 {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.debug.print("holt: failed to read command line arguments\n", .{});
        return 1;
    };
    return cli.dispatch(init.gpa, argv[1..], &command_table);
}

test {
    _ = @import("json");
    _ = @import("toml");
    _ = @import("fsutil.zig");
    _ = @import("identity.zig");
    _ = @import("config.zig");
    _ = @import("diag.zig");
    _ = @import("marker.zig");
    _ = @import("proc.zig");
    _ = @import("git.zig");
    _ = @import("recover.zig");
    _ = @import("project.zig");
    _ = @import("workspace.zig");
    _ = @import("hub.zig");
    _ = @import("doctor.zig");
    _ = @import("testutil.zig");
    _ = @import("cli.zig");
    _ = @import("app.zig");
    _ = @import("completion_source.zig");
    _ = @import("ui.zig");
    _ = @import("shell.zig");
    _ = @import("commands/common.zig");
    _ = @import("commands/version.zig");
    _ = @import("commands/init.zig");
    _ = @import("commands/setup.zig");
    _ = @import("commands/path.zig");
    _ = @import("commands/list.zig");
    _ = @import("commands/new.zig");
    _ = @import("commands/add.zig");
    _ = @import("commands/get.zig");
    _ = @import("commands/create.zig");
    _ = @import("commands/rm.zig");
    _ = @import("commands/alias.zig");
    _ = @import("commands/sync.zig");
    _ = @import("commands/restore.zig");
    _ = @import("commands/doctor.zig");
    _ = @import("commands/promote.zig");
    _ = @import("commands/archive.zig");
    _ = @import("commands/delete.zig");
    _ = @import("commands/rename.zig");
    _ = @import("commands/org.zig");
    _ = @import("commands/backup.zig");
    _ = @import("commands/info.zig");
    _ = @import("commands/status.zig");
    _ = @import("commands/backends.zig");
    _ = @import("commands/backend.zig");
    _ = @import("commands/recent.zig");
    _ = @import("commands/adopt.zig");
    _ = @import("commands/keep.zig");
    _ = @import("commands/edit.zig");
    _ = @import("commands/config.zig");
    _ = @import("commands/run.zig");
    _ = @import("commands/upgrade.zig");
    _ = @import("commands/worktree.zig");
    _ = @import("integration_test.zig");
}

const CoverageAllow = struct { cmd: []const u8, field: []const u8 };

fn coverageAllowed(allow: []const CoverageAllow, cmd: []const u8, field: []const u8) bool {
    for (allow) |a| {
        if (std.mem.eql(u8, a.cmd, cmd) and std.mem.eql(u8, a.field, field)) return true;
    }
    return false;
}

/// Checks one command's own positionals and value-flags (not its
/// subcommands - the caller walks those separately) against the allowlist,
/// appending a description of each uncovered slot to `gaps`. `path` is the
/// command's allowlist/report key: its bare name at the top level, or
/// "<parent> <sub>" for a subcommand, so a subcommand slot cannot alias a
/// same-named top-level one.
fn coverageCheckCommand(alloc: std.mem.Allocator, command: cli.Command, path: []const u8, allow: []const CoverageAllow, gaps: *std.ArrayList([]const u8)) !void {
    for (command.args) |a| {
        if (a.variadic) continue;
        if (a.complete != .none) continue;
        if (coverageAllowed(allow, path, a.name)) continue;
        try gaps.append(alloc, try std.fmt.allocPrint(alloc, "{s}.{s} (positional, no completion)", .{ path, a.name }));
    }
    for (command.flags) |f| {
        if (!f.takes_value) continue;
        if (f.value != .none) continue;
        if (coverageAllowed(allow, path, f.long)) continue;
        try gaps.append(alloc, try std.fmt.allocPrint(alloc, "{s} --{s} (value flag, no completion)", .{ path, f.long }));
    }
}

test "coverage: every command positional and value-flag completes or is allowlisted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Intentionally free-form or numeric slots with no candidate set to
    // complete against - honest gaps, not oversights.
    const allow = [_]CoverageAllow{
        .{ .cmd = "alias", .field = "name" }, // a new alias is invented
        .{ .cmd = "rename", .field = "new_name" }, // a new name is invented
        .{ .cmd = "upgrade", .field = "version" }, // free-form version string
        .{ .cmd = "status", .field = "jobs" }, // numeric concurrency count
        .{ .cmd = "recent", .field = "count" }, // numeric result count
        .{ .cmd = "recent", .field = "jobs" }, // numeric concurrency count
        .{ .cmd = "restore", .field = "jobs" }, // numeric concurrency count
        .{ .cmd = "doctor", .field = "jobs" }, // numeric concurrency count
        .{ .cmd = "run", .field = "jobs" }, // numeric concurrency count
        .{ .cmd = "create", .field = "spec" }, // a new repo name / url the user types
    };

    var gaps: std.ArrayList([]const u8) = .empty;

    for (command_table) |c| {
        try coverageCheckCommand(arena, c, c.name, &allow, &gaps);
        for (c.subcommands) |sub| {
            const path = try std.fmt.allocPrint(arena, "{s} {s}", .{ c.name, sub.name });
            try coverageCheckCommand(arena, sub, path, &allow, &gaps);
        }
    }

    if (gaps.items.len > 0) {
        std.debug.print("uncovered completion fields ({d}):\n", .{gaps.items.len});
        for (gaps.items) |g| std.debug.print("  {s}\n", .{g});
        return error.UncoveredField;
    }
}

fn containsCandidate(candidates: []const completion.Candidate, value: []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, c.value, value)) return true;
    }
    return false;
}

fn findCandidate(candidates: []const completion.Candidate, value: []const u8) ?completion.Candidate {
    for (candidates) |c| {
        if (std.mem.eql(u8, c.value, value)) return c;
    }
    return null;
}

/// Seeds `ws` with a multi-project, multi-org fixture reused across the
/// integration tests below: an org with a repo-less project ("acme/widget"),
/// an org with a project carrying both a remote and a `local:` repo
/// ("acme/proj"), and an org that only exists in the archive ("gone/old").
fn seedCompletionFixture(alloc: std.mem.Allocator, ws: *const workspace.Workspace) !void {
    try testutil.writeMarker(alloc, try ws.projectsRoot(alloc), "acme", "widget", .{ .version = marker.marker_version, .org = "acme", .name = "widget", .repos = .empty });

    var repos: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try repos.put(alloc, "backend", "https://example.com/acme/backend.git");
    try repos.put(alloc, "tool", "local:tool");
    try testutil.writeMarker(alloc, try ws.projectsRoot(alloc), "acme", "proj", .{ .version = marker.marker_version, .org = "acme", .name = "proj", .repos = repos });

    try testutil.writeMarker(alloc, try ws.archiveRoot(alloc), "gone", "old", .{ .version = marker.marker_version, .org = "gone", .name = "old", .repos = .empty });
}

test "integration: bare command and subcommand-group completion against the real command_table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    const ws_ptr: ?*const workspace.Workspace = &ws;
    try seedCompletionFixture(arena, &ws);

    // A bare command name completes off the real 31-entry table, with or
    // without a workspace - command names never need one.
    const bare = try completion.compute(arena, &command_table, &.{"inf"}, ws_ptr);
    try testing.expect(containsCandidate(bare.candidates, "info"));
    const bare_no_ws = try completion.compute(arena, &command_table, &.{"inf"}, null);
    try testing.expect(containsCandidate(bare_no_ws.candidates, "info"));

    // Subcommand groups: `org` and `config` each offer their real sub-names.
    const org_subs = try completion.compute(arena, &command_table, &.{ "org", "" }, ws_ptr);
    try testing.expect(containsCandidate(org_subs.candidates, "rename"));
    const config_subs = try completion.compute(arena, &command_table, &.{ "config", "" }, ws_ptr);
    try testing.expect(containsCandidate(config_subs.candidates, "edit"));

    // A subcommand's own positional (`org rename <old_org>`) resolves an
    // `org` category, archive-inclusive: "gone" only exists in the archive.
    const org_rename_old = try completion.compute(arena, &command_table, &.{ "org", "rename", "" }, ws_ptr);
    try testing.expect(containsCandidate(org_rename_old.candidates, "acme/"));
    try testing.expect(containsCandidate(org_rename_old.candidates, "gone/"));
}

test "integration: project/repo/backend_seed categories carry real descriptions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    const ws_ptr: ?*const workspace.Workspace = &ws;
    try seedCompletionFixture(arena, &ws);

    // `info`'s project positional carries the project's org as description.
    var out: std.Io.Writer.Allocating = .init(arena);
    try completion.reply(arena, &command_table, &.{ "info", "wid" }, ws_ptr, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "widget\tacme") != null);

    // `rm`'s second positional (repo) resolves off the first (project) and
    // carries each repo's clone-state description - no git involved.
    const repo_got = try completion.compute(arena, &command_table, &.{ "rm", "acme/proj", "" }, ws_ptr);
    const backend_cand = findCandidate(repo_got.candidates, "backend") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("missing", backend_cand.description.?);
    const tool_cand = findCandidate(repo_got.candidates, "tool") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("local", tool_cand.description.?);

    // `setup --backend` lists the builtin seeds even with a null workspace
    // (the fresh-install path, before config.toml exists).
    const seed_got = try completion.compute(arena, &command_table, &.{ "setup", "--backend", "" }, null);
    const dropbox_cand = findCandidate(seed_got.candidates, "dropbox") orelse return error.TestUnexpectedResult;
    try testing.expect(dropbox_cand.description != null);

    // `run --repo` completes off the preceding project positional.
    const run_got = try completion.compute(arena, &command_table, &.{ "run", "acme/proj", "--repo", "back" }, ws_ptr);
    try testing.expect(containsCandidate(run_got.candidates, "backend"));

    // A glued `--org=<partial>` on `list` completes the flag's value.
    const list_got = try completion.compute(arena, &command_table, &.{ "list", "--org=ac" }, ws_ptr);
    try testing.expect(containsCandidate(list_got.candidates, "acme/"));
}

test "list --repos appears in list's flag-name completion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try completion.compute(arena, &command_table, &.{ "list", "--" }, null);
    var found = false;
    for (got.candidates) |c| {
        if (std.mem.eql(u8, c.value, "--repos")) found = true;
    }
    try testing.expect(found);
}

test "integration: a broken (null) workspace still replies with the directive line and no candidates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(arena);
    try completion.reply(arena, &command_table, &.{ "info", "wid" }, null, &out.writer);
    try testing.expectEqualStrings("default\n", out.written());
}

test "integration: adopt disambiguation, subsequence matching, and flag de-dup on the real table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);
    const ws_ptr: ?*const workspace.Workspace = &ws;
    try seedCompletionFixture(arena, &ws);

    // `adopt`'s first positional (real spec: a project OR a clone path): a
    // path-shaped word defers to file completion, a bare word completes
    // projects.
    const adopt_path = try completion.compute(arena, &command_table, &.{ "adopt", "./checkouts/wi" }, ws_ptr);
    try testing.expectEqual(completion.Directive.files, adopt_path.directive);
    const adopt_proj = try completion.compute(arena, &command_table, &.{ "adopt", "wid" }, ws_ptr);
    try testing.expectEqual(completion.Directive.default, adopt_proj.directive);
    try testing.expect(containsCandidate(adopt_proj.candidates, "widget"));

    // Subsequence matching: "wdgt" is an abbreviation of "widget", so it
    // resolves the same on TAB as it would on Enter.
    const subseq = try completion.compute(arena, &command_table, &.{ "info", "wdgt" }, ws_ptr);
    try testing.expect(containsCandidate(subseq.candidates, "widget"));

    // Flag-name de-dup: an already-present flag is not re-offered. `--json` is
    // on the line, so completing `--j` offers `--jobs` but not `--json`.
    const flags = try completion.compute(arena, &command_table, &.{ "status", "--json", "--j" }, ws_ptr);
    try testing.expect(containsCandidate(flags.candidates, "--jobs"));
    try testing.expect(!containsCandidate(flags.candidates, "--json"));
}
