//! `holt backup <project>`: tars the project's CONTENT dir into
//! `<synced>/backups/<org>-<name>-<timestamp>.tar.gz` via a `tar`
//! subprocess. Read-only: the content dir, hub, and clones are all left
//! untouched.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const args = @import("../args.zig");
const comp = @import("../completion.zig");
const common = @import("common.zig");
const marker = @import("../marker.zig");
const proc = @import("../proc.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    project: args.Pos([]const u8, .{ .complete = comp.cat(.project), .help = "the project to back up" }),
};

pub const command = args.command(Spec, .{
    .name = "backup",
    .about = "Tar a project's content dir into synced backups/",
    .usage = "holt backup <project>",
    .group = .maintain,
    .details =
    \\Example:
    \\  holt backup myproj
    ,
}, run);

/// "YYYYMMDD-HHMMSS" for `secs` (seconds since the Unix epoch), UTC.
fn formatTimestamp(alloc: std.mem.Allocator, secs: i64) ![]u8 {
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// Base name "{org}-{name}-{stamp}.tar.gz" under `backups_root`; if that path
/// is already taken (two backups landing in the same second), appends
/// "-2", "-3", ... until an unused path is found, so a same-second backup
/// never truncates an earlier one.
fn pickBackupPath(alloc: std.mem.Allocator, backups_root: []const u8, org: []const u8, name: []const u8, stamp: []const u8) ![]const u8 {
    var suffix: u32 = 1;
    while (true) : (suffix += 1) {
        const out_name = if (suffix == 1)
            try std.fmt.allocPrint(alloc, "{s}-{s}-{s}.tar.gz", .{ org, name, stamp })
        else
            try std.fmt.allocPrint(alloc, "{s}-{s}-{s}-{d}.tar.gz", .{ org, name, stamp, suffix });
        const out_path = try std.fs.path.join(alloc, &.{ backups_root, out_name });
        if (!fsutil.exists(out_path)) return out_path;
    }
}

/// Runs a `tar` invocation, retrying once with `--force-local` if it looks
/// like GNU tar misparsed a Windows drive-letter path ("C:\...") as a
/// `host:path` remote-archive spec ("Cannot connect to C: resolve failed") -
/// a long-standing GNU tar quirk that Git for Windows' bundled tar hits on
/// every plain `-f <drive>:\...` invocation. Windows' own bsdtar (bundled
/// since Windows 10) never had this bug and does not recognize the flag, so
/// it is added only on that exact failure, never unconditionally - a no-op
/// on POSIX, where the drive-letter shape never occurs and this never fires.
fn runTar(alloc: std.mem.Allocator, argv: []const []const u8) !proc.RunResult {
    const res = try proc.run(alloc, argv, null);
    if (builtin.os.tag != .windows or res.status == 0) return res;
    if (std.mem.indexOf(u8, res.stderr, "resolve failed") == null) return res;
    alloc.free(res.stdout);
    alloc.free(res.stderr);

    var retry: std.ArrayList([]const u8) = .empty;
    defer retry.deinit(alloc);
    try retry.append(alloc, argv[0]);
    try retry.append(alloc, "--force-local");
    try retry.appendSlice(alloc, argv[1..]);
    return proc.run(alloc, retry.items, null);
}

fn run(ctx: *cli.Ctx, a: args.Args(Spec)) anyerror!u8 {
    const project_query = a.project;

    const ws = ctx.ws.?;
    const alloc = ctx.alloc;

    const p = (try common.resolveOne(ctx, project_query)) orelse return 1;

    const backups_root = try ws.backupsRoot(alloc);
    try fsutil.ensureDir(backups_root);

    const now = std.Io.Clock.now(.real, fsutil.io());
    const secs: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
    const stamp = try formatTimestamp(alloc, secs);
    const out_path = try pickBackupPath(alloc, backups_root, p.org, p.name, stamp);

    const org_dir = std.fs.path.dirname(p.content_path) orelse return error.InvalidContentPath;

    // tar writes to a ".partial" sibling; only a fully successful tar is
    // renamed onto the real name. A failure (or a SIGKILL/power loss mid-tar,
    // where the error path never runs) thus leaves at most a ".partial" that
    // never masquerades as a complete backup under the real name.
    const partial_path = try std.fmt.allocPrint(alloc, "{s}.partial", .{out_path});
    const res = runTar(alloc, &.{ "tar", "-czf", partial_path, "-C", org_dir, p.name }) catch |err| switch (err) {
        error.FileNotFound => return error.TarNotFound,
        else => return err,
    };
    if (res.status != 0) {
        std.Io.Dir.cwd().deleteFile(fsutil.io(), partial_path) catch {};
        try ctx.err_w.print("holt: tar failed: {s}\n", .{res.stderr});
        return 1;
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.rename(partial_path, cwd, out_path, fsutil.io());

    try ctx.out.print("backed up {s}/{s} -> {s}\n", .{ p.org, p.name, out_path });
    return 0;
}

test "formatTimestamp: renders a fixed instant as YYYYMMDD-HHMMSS in UTC" {
    // 2024-01-02T03:04:05Z
    const got = try formatTimestamp(testing.allocator, 1704164645);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("20240102-030405", got);
}

test "pickBackupPath: a same-second collision gets a -2 suffix, leaving the first file untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const backups_root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const first = try pickBackupPath(arena, backups_root, "acme", "widget", "20240102-030405");
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = first, .data = "first backup\n" });

    const second = try pickBackupPath(arena, backups_root, "acme", "widget", "20240102-030405");
    try testing.expect(!std.mem.eql(u8, first, second));
    try testing.expect(std.mem.endsWith(u8, second, "-2.tar.gz"));

    const first_contents = try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), first, arena, .unlimited);
    try testing.expectEqualStrings("first backup\n", first_contents);
    try testing.expect(!fsutil.exists(second));
}

test "run: creates a tar.gz under backups/ whose contents list the marker" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "backed up acme/widget ->") != null);

    const backups_root = try ws.backupsRoot(arena);
    var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), backups_root, .{ .iterate = true });
    defer dir.close(fsutil.io());
    var it = dir.iterate();
    const entry = (try it.next(fsutil.io())) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, entry.name, "acme-widget-"));
    try testing.expect(std.mem.endsWith(u8, entry.name, ".tar.gz"));

    const tar_path = try std.fs.path.join(arena, &.{ backups_root, entry.name });
    const list_res = try runTar(arena, &.{ "tar", "-tzf", tar_path });
    try testing.expectEqual(@as(u8, 0), list_res.status);
    try testing.expect(std.mem.indexOf(u8, list_res.stdout, marker.marker_basename) != null);
}

test "run: a tar failure removes the partial tarball instead of leaving a truncated backup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    try testutil.writeMarker(arena, try ws.projectsRoot(arena), "acme", "widget", .{ .version = 1, .org = "acme", .name = "widget", .repos = .empty });

    // An unreadable file inside the content dir makes tar exit nonzero after
    // it has already opened (and started writing) its output archive. Mode
    // bits don't gate access on Windows, so this simulation is POSIX-only.
    const secret_rel = "synced/projects/acme/widget/secret";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = secret_rel, .data = "top secret\n" });
    if (builtin.os.tag != .windows) {
        try tmp.dir.setFilePermissions(testing.io, secret_rel, std.Io.File.Permissions.fromMode(0o000), .{});
        defer tmp.dir.setFilePermissions(testing.io, secret_rel, std.Io.File.Permissions.fromMode(0o644), .{}) catch {};

        const got = try testutil.runCmd(arena, command.run, ws, &.{"acme/widget"});
        try testing.expectEqual(@as(u8, 1), got.code);
        try testing.expect(std.mem.indexOf(u8, got.err, "tar failed") != null);

        const backups_root = try ws.backupsRoot(arena);
        var dir = try std.Io.Dir.cwd().openDir(fsutil.io(), backups_root, .{ .iterate = true });
        defer dir.close(fsutil.io());
        var it = dir.iterate();
        try testing.expect((try it.next(fsutil.io())) == null);
    }
}

test "run: no matching project exits 1 and reports on stderr" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const ws = try testutil.testWorkspace(arena, root);

    const got = try testutil.runCmd(arena, command.run, ws, &.{"nope"});
    try testing.expectEqual(@as(u8, 1), got.code);
    try testing.expect(std.mem.indexOf(u8, got.err, "nope") != null);
}
