//! `holt create <spec> [-p <project>]`: make a git repo from scratch.
//! A bare <spec> ("foo") is a LOCAL repo at <code_root>/local/foo with no
//! origin; a URL/shorthand ("owner/repo", a full git url) is a remote-destined
//! repo at its identity path with `origin` set (nothing pushed). Without -p the
//! repo is standalone (no marker, no hub); with -p it is attached as a project
//! member. The repo is left commitless (plain `git init`); its path is printed.

const std = @import("std");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const common = @import("common.zig");
const identity = @import("../identity.zig");
const marker = @import("../marker.zig");
const projectlock = @import("../projectlock.zig");
const hub = @import("../hub.zig");
const git = @import("../git.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    spec: args.Pos([]const u8, .{ .help = "a name for a local repo, or a git url / owner/repo shorthand for a remote-destined one" }),
    project: args.Opt([]const u8, .{ .short = 'p', .value_name = "project", .complete = comp.cat(.project), .help = "attach the new repo as a member of this project" }),
};

pub const command = args.command(Spec, .{
    .name = "create",
    .about = "Create a git repo from scratch",
    .usage = "holt create <spec> [-p <project>]",
    .group = .create,
    .details =
    \\Runs `git init` (no initial commit). A bare <spec> makes a local repo at
    \\<code_root>/local/<name>; a url or owner/repo shorthand makes one at its
    \\identity path with origin set (nothing is pushed). Without -p the repo is
    \\standalone; with -p it is added as a member of <project>. The created
    \\path is the sole line on stdout, so `cd $(holt create foo)` works.
    \\
    \\Example:
    \\  holt create scratch
    \\  holt create acme/widget
    \\  holt create tool -p myproject
    ,
    .needs_workspace = true,
}, run);

/// Classifies <spec>: a recognized url/shorthand yields its identity and the
/// expanded origin url; a bare word yields a local identity and null url.
const Target = struct { id: identity.Identity, origin: ?[]const u8 };

fn classify(alloc: std.mem.Allocator, spec: []const u8) !Target {
    const url = identity.expand(alloc, spec) catch |err| switch (err) {
        error.UnrecognizedUrl => return .{ .id = identity.local(spec), .origin = null },
        else => return err,
    };
    return .{ .id = try identity.fromUrl(alloc, url), .origin = url };
}

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const ws = ctx.ws.?;
    const alloc = ctx.alloc;

    const target = try classify(alloc, a.spec);
    const clone_path = try target.id.clonePath(alloc, ws.cfg.code_root);

    const res = try git.run(alloc, &.{ "git", "init", "-q", "-b", "main", clone_path }, null);
    if (res.status != 0) {
        const cause = std.mem.trim(u8, res.stderr, " \t\r\n");
        try ctx.err_w.print("holt: git init failed at {s}: {s}\n", .{ clone_path, cause });
        return 1;
    }

    try ctx.out.print("{s}\n", .{clone_path});
    return 0;
}

test "run: a bare name creates a local repo at code_root/local/<name>, prints the path, no marker or hub" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    const ws = try testutil.testWorkspace(arena, sb.root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"scratch"});
    try testing.expectEqual(@as(u8, 0), got.code);

    const expected_path = try std.fs.path.join(arena, &.{ ws.cfg.code_root, "local", "scratch" });
    // stdout is the created path (sole line).
    try testing.expectEqualStrings(expected_path, std.mem.trim(u8, got.out, " \t\r\n"));
    // It is a git repo (has a .git) ...
    try testing.expect(fsutil.exists(try std.fs.path.join(arena, &.{ expected_path, ".git" })));
    // ... but commitless (unborn HEAD): no commit reachable from HEAD.
    try testing.expect(!try git.isCompleteClone(arena, expected_path));
    // No marker and no hub for a standalone create.
    const marker_path = try std.fs.path.join(arena, &.{ ws.cfg.synced_root, "projects", "local", "scratch", marker.marker_basename });
    try testing.expect(!fsutil.exists(marker_path));
}
