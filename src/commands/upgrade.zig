//! `holt upgrade [<version>] [--yes]`: compares the running build against a
//! GitHub release of sakakibara/holt (the latest, or an explicit tag),
//! downloads that release's platform tarball, and atomically replaces the
//! running binary with the `holt` it contains. A fetched `latest` only
//! installs when it is strictly newer than the running build, so it never
//! auto-downgrades; an explicit `<version>` installs unless it names the same
//! version, so an explicit downgrade is allowed. Version selection and the
//! tag compares (`latestTag`, `isNewer`, `versionsEqual`) are pure and unit
//! tested directly against fixture JSON; the download/extract/replace goes
//! through `curl`, `tar`, and the filesystem, exercised end to end via
//! `file://` fixtures and three env-var seams (`HOLT_UPGRADE_API`,
//! `HOLT_UPGRADE_DOWNLOAD_BASE`, `HOLT_UPGRADE_TARGET_BIN`) so tests never
//! touch the real network or the real test binary.

const std = @import("std");
const Env = @import("env").Env;
const builtin = @import("builtin");
const json = @import("json");
const build_options = @import("build_options");
const cli = @import("cli");
const app = @import("../app.zig");
const proc = @import("../proc.zig");
const ui = @import("../ui.zig");
const fsutil = @import("../fsutil.zig");
const testing = std.testing;
const testutil = @import("../testutil.zig");

const Spec = struct {
    version: cli.spec.Pos([]const u8, .{ .optional = true, .help = "install this version instead of the latest release" }),
    yes: cli.spec.Flag(.{ .help = "skip the confirmation prompt" }),
};

pub const command = app.command(Spec, .{
    .name = "upgrade",
    .summary = "Download and install a newer holt release",
    .usage = "holt upgrade [<version>] [--yes]",
    .group = .system,
    .details =
    \\Example:
    \\  holt upgrade --yes
    ,
    .needs_context = false,
}, run);

const default_api_url = "https://api.github.com/repos/sakakibara/holt/releases/latest";
const default_download_base = "https://github.com/sakakibara/holt/releases/download";

fn run(ctx: *app.Ctx, a: cli.args.Args(Spec)) anyerror!u8 {
    const version_arg = a.version;
    const auto_yes = a.yes;
    const alloc = ctx.alloc;

    const env = app.envOf(ctx);

    const explicit = version_arg != null;
    const tag = if (version_arg) |v|
        (if (std.mem.startsWith(u8, v, "v")) v else try std.fmt.allocPrint(alloc, "v{s}", .{v}))
    else blk: {
        const api_url = try envOrDefault(alloc, env, "HOLT_UPGRADE_API", default_api_url);
        const body = fetch(alloc, api_url) catch |err| switch (err) {
            error.OutOfMemory, error.CurlNotFound => return err,
            else => "",
        };
        break :blk (try latestTag(alloc, body)) orelse {
            try ctx.out.writeAll("no releases found\n");
            return 0;
        };
    };

    const up_to_date = if (explicit)
        versionsEqual(build_options.version, tag)
    else
        !isNewer(build_options.version, tag);

    if (up_to_date) {
        try ctx.out.print("holt {s} is up to date\n", .{build_options.version});
        return 0;
    }

    const asset = assetName(alloc, builtin.target.os.tag, builtin.target.cpu.arch) catch |err| switch (err) {
        error.UnsupportedPlatform => {
            try ctx.err.writeAll("holt: upgrade is not supported on this platform\n");
            return 1;
        },
        else => return err,
    };

    const target_path = env.getAlloc(alloc, "HOLT_UPGRADE_TARGET_BIN") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try std.process.executablePathAlloc(fsutil.io(), alloc),
        else => return err,
    };

    if (!auto_yes) {
        const prompt = try std.fmt.allocPrint(alloc, "Upgrade holt {s} -> {s}?", .{ build_options.version, tag });
        if (!try ui.confirm(ctx.out, prompt)) {
            try ctx.out.writeAll("upgrade cancelled\n");
            return 0;
        }
    }

    const download_base = try envOrDefault(alloc, env, "HOLT_UPGRADE_DOWNLOAD_BASE", default_download_base);
    const url = try downloadUrl(alloc, download_base, tag, asset);

    const tmp_dir = try makeTempDir(alloc, app.envOf(ctx));
    defer std.Io.Dir.cwd().deleteTree(fsutil.io(), tmp_dir) catch {};

    const is_zip = builtin.os.tag == .windows;
    const archive_name: []const u8 = if (is_zip) "asset.zip" else "asset.tar.gz";
    const archive_path = try std.fs.path.join(alloc, &.{ tmp_dir, archive_name });
    const dl_res = proc.run(alloc, &.{ "curl", "-fsSL", "-o", archive_path, url }, null) catch |err| switch (err) {
        error.FileNotFound => return error.CurlNotFound,
        else => return err,
    };
    if (dl_res.status != 0) {
        try ctx.err.print("holt: download failed: {s} ({s})\n", .{ tag, url });
        return 1;
    }

    extractArchive(archive_path, tmp_dir, is_zip) catch {
        try ctx.err.writeAll("holt: extract failed\n");
        return 1;
    };

    const extracted_bin = try std.fs.path.join(alloc, &.{ tmp_dir, assetBinaryName(builtin.os.tag) });
    if (!fsutil.exists(extracted_bin)) {
        try ctx.err.writeAll("holt: extracted archive did not contain a holt binary\n");
        return 1;
    }

    try replaceBinary(alloc, target_path, extracted_bin);

    try ctx.out.print("upgraded to {s}\n", .{tag});
    return 0;
}

/// Reads `key` from `environ`, falling back to `default` only when the
/// variable is unset (any other error, e.g. invalid encoding, propagates).
fn envOrDefault(alloc: std.mem.Allocator, env: Env, key: []const u8, default: []const u8) ![]const u8 {
    return env.get(alloc, key) orelse default;
}

/// Thin wrapper around a `curl` subprocess; a nonzero exit (network error,
/// 404, anything) surfaces as `error.FetchFailed` so `run` can fold it into
/// the same "no releases found" degrade path as a malformed body.
fn fetch(alloc: std.mem.Allocator, url: []const u8) ![]const u8 {
    const res = proc.run(alloc, &.{ "curl", "-fsSL", url }, null) catch |err| switch (err) {
        error.FileNotFound => return error.CurlNotFound,
        else => return err,
    };
    if (res.status != 0) return error.FetchFailed;
    return res.stdout;
}

/// Extracts `tag_name` from a GitHub releases-API JSON body. Null (not an
/// error) covers every "nothing to report" shape - an empty body, a 404's
/// `{"message":"Not Found"}`, and malformed JSON alike - so `run` degrades
/// the same way regardless of cause.
pub fn latestTag(alloc: std.mem.Allocator, body: []const u8) !?[]const u8 {
    if (body.len == 0) return null;

    const Payload = struct { tag_name: []const u8 };
    const parsed = json.parseInto(Payload, alloc, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    return parsed.tag_name;
}

/// True if `latest` (optionally "v"-prefixed) outranks `current` as a
/// dotted numeric version. A component that isn't a number (or is absent)
/// counts as 0, so a malformed tag can only ever compare as "not newer",
/// never crash the comparison.
pub fn isNewer(current: []const u8, latest: []const u8) bool {
    const c = if (std.mem.startsWith(u8, current, "v")) current[1..] else current;
    const l = if (std.mem.startsWith(u8, latest, "v")) latest[1..] else latest;

    var cit = std.mem.splitScalar(u8, c, '.');
    var lit = std.mem.splitScalar(u8, l, '.');

    while (true) {
        const cp = cit.next();
        const lp = lit.next();
        if (cp == null and lp == null) return false;

        const cv: u32 = if (cp) |s| std.fmt.parseInt(u32, s, 10) catch 0 else 0;
        const lv: u32 = if (lp) |s| std.fmt.parseInt(u32, s, 10) catch 0 else 0;
        if (cv != lv) return lv > cv;
    }
}

/// True if `current` and `tag` (each optionally "v"-prefixed) name the same
/// version, byte-for-byte once the prefix is stripped.
fn versionsEqual(current: []const u8, tag: []const u8) bool {
    const c = if (std.mem.startsWith(u8, current, "v")) current[1..] else current;
    const t = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    return std.mem.eql(u8, c, t);
}

pub const AssetNameError = error{UnsupportedPlatform} || std.mem.Allocator.Error;

/// Names the release asset for `os_tag`/`arch`: `holt-windows-<arch>.zip` on
/// Windows, `holt-<os>-<arch>.tar.gz` on macOS/Linux. Any platform outside
/// the combos holt ships for is `error.UnsupportedPlatform`.
pub fn assetName(alloc: std.mem.Allocator, os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) AssetNameError![]const u8 {
    const os_name: []const u8 = switch (os_tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => return error.UnsupportedPlatform,
    };
    const arch_name: []const u8 = switch (arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return error.UnsupportedPlatform,
    };
    const ext: []const u8 = if (os_tag == .windows) "zip" else "tar.gz";
    return std.fmt.allocPrint(alloc, "holt-{s}-{s}.{s}", .{ os_name, arch_name, ext });
}

/// The binary's name inside the release archive: `holt.exe` on Windows,
/// `holt` elsewhere.
pub fn assetBinaryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) "holt.exe" else "holt";
}

/// Extracts `archive_path` into `dest_dir` in process. A `.zip` (Windows) via
/// `std.zip`; a `.tar.gz` (unix) via gzip-decompress + `std.tar` - no
/// external `tar` binary required.
fn extractArchive(archive_path: []const u8, dest_dir: []const u8, is_zip: bool) !void {
    const io = fsutil.io();
    var dest = try std.Io.Dir.openDirAbsolute(io, dest_dir, .{});
    defer dest.close(io);
    var file = try std.Io.Dir.openFileAbsolute(io, archive_path, .{});
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    if (is_zip) {
        try std.zip.extract(dest, &file_reader, .{});
    } else {
        var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &flate_buf);
        try std.tar.extract(io, dest, &decompress.reader, .{});
    }
}

/// `<base>/<tag>/<asset>`, the GitHub release-asset download URL layout.
pub fn downloadUrl(alloc: std.mem.Allocator, base: []const u8, tag: []const u8, asset: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ base, tag, asset });
}

const temp_name_random_bytes = 12;
const temp_name_len = std.base64.url_safe.Encoder.calcSize(temp_name_random_bytes);

/// Creates a fresh `holt-upgrade-<random>` directory under the platform temp
/// location to stage the downloaded archive in. Caller deletes it when done.
fn makeTempDir(alloc: std.mem.Allocator, env: Env) ![]const u8 {
    const base = try fsutil.tempDir(alloc, env);

    var random_bytes: [temp_name_random_bytes]u8 = undefined;
    fsutil.io().random(&random_bytes);
    var name_buf: [temp_name_len]u8 = undefined;
    const suffix = std.base64.url_safe.Encoder.encode(&name_buf, &random_bytes);
    const dir_name = try std.fmt.allocPrint(alloc, "holt-upgrade-{s}", .{suffix});

    const path = try std.fs.path.join(alloc, &.{ base, dir_name });
    try fsutil.ensureDir(path);
    return path;
}

/// Swaps `target_path` for the contents of `new_binary_path`: writes the new
/// bytes to a sibling `<target_path>.new` with mode 0755, then puts it in
/// place at `target_path`. `target_path` is never touched until the staged
/// copy is fully written, so a failure reading or writing it leaves the
/// original binary at `target_path` completely intact - no half-written
/// target, nothing left missing.
///
/// On POSIX this is one atomic rename onto `target_path`. On Windows the
/// running `target_path` is locked and can't be renamed over, but it can be
/// renamed aside: `target_path` -> `<target_path>.old`, then
/// `<target_path>.new` -> `target_path`. If that second rename fails, the
/// `.old` is restored so `target_path` is never left missing; if it
/// succeeds, the now-locked `.old` is left for a later run to reap.
pub fn replaceBinary(alloc: std.mem.Allocator, target_path: []const u8, new_binary_path: []const u8) !void {
    const io = fsutil.io();
    const staged_path = try std.fmt.allocPrint(alloc, "{s}.new", .{target_path});

    installBinary(io, alloc, new_binary_path, staged_path) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
        return err;
    };

    if (builtin.os.tag == .windows) {
        const old_path = try std.fmt.allocPrint(alloc, "{s}.old", .{target_path});
        std.Io.Dir.deleteFileAbsolute(io, old_path) catch {};
        std.Io.Dir.renameAbsolute(target_path, old_path, io) catch |err| {
            std.Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
            return err;
        };
        std.Io.Dir.renameAbsolute(staged_path, target_path, io) catch |err| {
            std.Io.Dir.renameAbsolute(old_path, target_path, io) catch {};
            std.Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
            return err;
        };
    } else {
        std.Io.Dir.renameAbsolute(staged_path, target_path, io) catch |err| {
            std.Io.Dir.deleteFileAbsolute(io, staged_path) catch {};
            return err;
        };
    }
}

fn installBinary(io: std.Io, alloc: std.mem.Allocator, new_binary_path: []const u8, staged_path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, new_binary_path, alloc, .unlimited);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staged_path, .data = bytes });
    // On Windows a .exe is executable by extension; no chmod is needed or possible.
    if (builtin.os.tag != .windows) {
        try std.Io.Dir.cwd().setFilePermissions(io, staged_path, std.Io.File.Permissions.fromMode(0o755), .{});
    }
}

test "latestTag: extracts tag_name, ignoring unrelated fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try latestTag(arena, "{\"tag_name\":\"v0.2.0\",\"draft\":false,\"assets\":[]}");
    try testing.expectEqualStrings("v0.2.0", got.?);
}

test "latestTag: a 404 body, empty body, and malformed JSON all degrade to null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(try latestTag(arena, "{\"message\":\"Not Found\",\"documentation_url\":\"https://x\"}") == null);
    try testing.expect(try latestTag(arena, "") == null);
    try testing.expect(try latestTag(arena, "not json at all") == null);
}

test "isNewer: newer, equal, and older tags compare correctly, with or without a v prefix" {
    try testing.expect(isNewer("0.1.0", "v0.2.0"));
    try testing.expect(isNewer("0.1.0", "0.2.0"));
    try testing.expect(!isNewer("0.2.0", "v0.2.0"));
    try testing.expect(!isNewer("0.2.0", "v0.1.0"));
    try testing.expect(isNewer("1.9.0", "1.10.0"));
}

test "isNewer: a malformed latest tag never crashes, just isn't newer" {
    try testing.expect(!isNewer("0.1.0", "not-a-version"));
    try testing.expect(!isNewer("0.1.0", ""));
}

test "assetName: the four supported os/arch combos name the right tarball, anything else is unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("holt-macos-aarch64.tar.gz", try assetName(arena, .macos, .aarch64));
    try testing.expectEqualStrings("holt-macos-x86_64.tar.gz", try assetName(arena, .macos, .x86_64));
    try testing.expectEqualStrings("holt-linux-aarch64.tar.gz", try assetName(arena, .linux, .aarch64));
    try testing.expectEqualStrings("holt-linux-x86_64.tar.gz", try assetName(arena, .linux, .x86_64));
    try testing.expectError(error.UnsupportedPlatform, assetName(arena, .freebsd, .x86_64));
    try testing.expectError(error.UnsupportedPlatform, assetName(arena, .linux, .riscv64));
}

test "assetName: windows is a .zip, unix is a .tar.gz" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("holt-windows-x86_64.zip", try assetName(arena, .windows, .x86_64));
    try testing.expectEqualStrings("holt-windows-aarch64.zip", try assetName(arena, .windows, .aarch64));
    try testing.expectEqualStrings("holt-macos-aarch64.tar.gz", try assetName(arena, .macos, .aarch64));
    try testing.expectEqualStrings("holt-linux-x86_64.tar.gz", try assetName(arena, .linux, .x86_64));
}

test "assetBinaryName: holt.exe on windows, holt elsewhere" {
    try testing.expectEqualStrings("holt.exe", assetBinaryName(.windows));
    try testing.expectEqualStrings("holt", assetBinaryName(.macos));
    try testing.expectEqualStrings("holt", assetBinaryName(.linux));
}

test "extractArchive: unpacks a gzip tar into the destination" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const srcdir = try std.fs.path.join(arena, &.{ root, "src" });
    try fsutil.ensureDir(srcdir);
    const dest = try std.fs.path.join(arena, &.{ root, "dest" });
    try fsutil.ensureDir(dest);

    if (builtin.os.tag == .windows) {
        // GNU tar on windows-latest misparses the C:\ drive-letter path and
        // silently fails to write the archive, and .tar.gz isn't the format
        // holt extracts on Windows anyway; stage the same .zip fixture the
        // e2e tests use via stageFakeReleaseAsset and exercise the .zip arm
        // of extractArchive instead.
        const archive = try std.fs.path.join(arena, &.{ root, "a.zip" });
        try stageFakeReleaseAsset(arena, srcdir, archive, "BINARY");

        try extractArchive(archive, dest, true);

        const out = try std.fs.path.join(arena, &.{ dest, "holt.exe" });
        try testing.expectEqualStrings("BINARY", try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), out, arena, .unlimited));
    } else {
        // Build a real holt-*.tar.gz containing a file named "holt" via the
        // system tar (this is the FIXTURE, not the code under test), then
        // extract it in process and assert the file lands in dest.
        try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(arena, &.{ srcdir, "holt" }), .data = "BINARY" });
        const archive = try std.fs.path.join(arena, &.{ root, "a.tar.gz" });
        _ = try proc.run(arena, &.{ "tar", "-C", srcdir, "-czf", archive, "holt" }, null);

        try extractArchive(archive, dest, false);

        const out = try std.fs.path.join(arena, &.{ dest, "holt" });
        try testing.expectEqualStrings("BINARY", try std.Io.Dir.cwd().readFileAlloc(fsutil.io(), out, arena, .unlimited));
    }
}

test "downloadUrl: joins base, tag, and asset with slashes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try downloadUrl(arena, "https://example.invalid/download", "v1.2.3", "holt-macos-aarch64.tar.gz");
    try testing.expectEqualStrings("https://example.invalid/download/v1.2.3/holt-macos-aarch64.tar.gz", got);
}

test "replaceBinary: swaps in the new binary's bytes; leaves the old image aside on Windows, none on POSIX" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const target_path = try std.fs.path.join(arena, &.{ root, "target" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_path, .data = "OLD" });
    const new_path = try std.fs.path.join(arena, &.{ root, "new" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = new_path, .data = "NEW" });

    try replaceBinary(arena, target_path, new_path);

    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, target_path, arena, .unlimited);
    try testing.expectEqualStrings("NEW", got);

    if (builtin.os.tag != .windows) {
        const st = try std.Io.Dir.cwd().statFile(testing.io, target_path, .{});
        try testing.expectEqual(@as(std.posix.mode_t, 0o755), st.permissions.toMode() & 0o777);
    }

    const old_path = try std.fmt.allocPrint(arena, "{s}.old", .{target_path});
    if (builtin.os.tag == .windows) {
        // The locked running image can't be deleted, only renamed aside; a
        // later run reaps it, so replaceBinary intentionally leaves it here.
        try testing.expect(fsutil.exists(old_path));
    } else {
        try testing.expect(!fsutil.exists(old_path));
    }
}

test "replaceBinary: a missing new binary leaves the original target intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const target_path = try std.fs.path.join(arena, &.{ root, "target" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_path, .data = "OLD" });
    const missing_new_path = try std.fs.path.join(arena, &.{ root, "does-not-exist" });

    try testing.expectError(error.FileNotFound, replaceBinary(arena, target_path, missing_new_path));

    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, target_path, arena, .unlimited);
    try testing.expectEqualStrings("OLD", got);

    const old_path = try std.fmt.allocPrint(arena, "{s}.old", .{target_path});
    try testing.expect(!fsutil.exists(old_path));
}

test "replaceBinary: a failure staging the new binary leaves the original target intact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const bin_dir = try std.fs.path.join(arena, &.{ root, "bin" });
    try fsutil.ensureDir(bin_dir);
    const target_path = try std.fs.path.join(arena, &.{ bin_dir, "target" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_path, .data = "OLD" });

    const new_path = try std.fs.path.join(arena, &.{ root, "new" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = new_path, .data = "NEW" });

    var root_dir = try std.Io.Dir.cwd().openDir(testing.io, root, .{ .iterate = true });
    defer root_dir.close(testing.io);

    // Mode bits don't gate access on Windows, so this whole simulation
    // (and the failure it induces) only applies on POSIX.
    if (builtin.os.tag != .windows) {
        // Strips write permission from bin_dir so writing the staged
        // "<target>.new" file fails before the atomic rename is ever reached.
        try root_dir.setFilePermissions(testing.io, "bin", std.Io.File.Permissions.fromMode(0o555), .{});
        defer root_dir.setFilePermissions(testing.io, "bin", std.Io.File.Permissions.fromMode(0o755), .{}) catch {};

        try testing.expectError(error.AccessDenied, replaceBinary(arena, target_path, new_path));

        const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, target_path, arena, .unlimited);
        try testing.expectEqualStrings("OLD", got);

        const staged_path = try std.fmt.allocPrint(arena, "{s}.new", .{target_path});
        try testing.expect(!fsutil.exists(staged_path));
    }
}

test "run: a release matching the current version reports up to date" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const fixture_path = try std.fs.path.join(arena, &.{ root, "release.json" });
    const content = try std.fmt.allocPrint(arena, "{{\"tag_name\":\"v{s}\"}}", .{build_options.version});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = fixture_path, .data = content });

    const url = try std.fmt.allocPrint(arena, "file://{s}", .{fixture_path});
    const override = try testutil.EnvScope.install(arena, &.{.{ "HOLT_UPGRADE_API", url }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, null, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "up to date") != null);
}

test "run: an explicit version argument equal to the current version reports up to date without a fetch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try testutil.runCmd(arena, command.run, null, &.{build_options.version});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "up to date") != null);
}

test "run: an unreachable HOLT_UPGRADE_API degrades cleanly to no releases found" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const url = try std.fmt.allocPrint(arena, "file://{s}/does-not-exist.json", .{root});
    const override = try testutil.EnvScope.install(arena, &.{.{ "HOLT_UPGRADE_API", url }});
    defer override.restore();

    const got = try testutil.runCmd(arena, command.run, null, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expectEqualStrings("no releases found\n", got.out);
}

/// Stages a fake release asset at `asset_path` containing `assetBinaryName`
/// with `contents`, matching what the real release pipeline serves for the
/// current platform: a `.tar.gz` with a `holt` entry via the system `tar` on
/// unix, a `.zip` with a `holt.exe` entry via PowerShell `Compress-Archive`
/// on Windows (`std.zip` cannot write archives, and a bare `tar` on
/// windows-latest may resolve to GNU tar, which cannot write zip).
fn stageFakeReleaseAsset(arena: std.mem.Allocator, pkg_dir: []const u8, asset_path: []const u8, contents: []const u8) !void {
    const bin_name = assetBinaryName(builtin.os.tag);
    const bin_path = try std.fs.path.join(arena, &.{ pkg_dir, bin_name });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = bin_path, .data = contents });

    if (builtin.os.tag == .windows) {
        const cmd = try std.fmt.allocPrint(arena, "Compress-Archive -Path '{s}' -DestinationPath '{s}' -Force", .{ bin_path, asset_path });
        const res = try proc.run(arena, &.{ "powershell", "-NoProfile", "-Command", cmd }, null);
        try testing.expectEqual(@as(u8, 0), res.status);
    } else {
        const res = try proc.run(arena, &.{ "tar", "-czf", asset_path, "-C", pkg_dir, bin_name }, null);
        try testing.expectEqual(@as(u8, 0), res.status);
    }
}

test "run: a newer release fetched via HOLT_UPGRADE_API downloads, extracts, and installs the binary with --yes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const tag = "v99.0.0";

    const bin_dir = try std.fs.path.join(arena, &.{ root, "bin" });
    try fsutil.ensureDir(bin_dir);
    const target_bin = try std.fs.path.join(arena, &.{ bin_dir, "holt" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_bin, .data = "OLD" });

    const asset = try assetName(arena, builtin.target.os.tag, builtin.target.cpu.arch);
    const pkg_dir = try std.fs.path.join(arena, &.{ root, "pkg" });
    try fsutil.ensureDir(pkg_dir);

    const dl_dir = try std.fs.path.join(arena, &.{ root, "dl", tag });
    try fsutil.ensureDir(dl_dir);
    const asset_path = try std.fs.path.join(arena, &.{ dl_dir, asset });
    try stageFakeReleaseAsset(arena, pkg_dir, asset_path, "NEW");

    const release_path = try std.fs.path.join(arena, &.{ root, "release.json" });
    const release_body = try std.fmt.allocPrint(arena, "{{\"tag_name\":\"{s}\"}}", .{tag});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = release_path, .data = release_body });

    const api_url = try std.fmt.allocPrint(arena, "file://{s}", .{release_path});
    const download_root = try std.fs.path.join(arena, &.{ root, "dl" });
    const download_base = try std.fmt.allocPrint(arena, "file://{s}", .{download_root});

    const api_override = try testutil.EnvScope.install(arena, &.{.{ "HOLT_UPGRADE_API", api_url }});
    defer api_override.restore();
    const download_override = try testutil.EnvScope.install(arena, &.{.{ "HOLT_UPGRADE_DOWNLOAD_BASE", download_base }});
    defer download_override.restore();
    const target_override = try testutil.EnvScope.install(arena, &.{.{ "HOLT_UPGRADE_TARGET_BIN", target_bin }});
    defer target_override.restore();

    const got = try testutil.runCmd(arena, command.run, null, &.{"--yes"});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "upgraded") != null);

    const installed = try std.Io.Dir.cwd().readFileAlloc(testing.io, target_bin, arena, .unlimited);
    try testing.expectEqualStrings("NEW", installed);
}

test "run: a fetched latest that is not newer than the current build reports up to date without installing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const release_path = try std.fs.path.join(arena, &.{ root, "release.json" });
    const release_body = try std.fmt.allocPrint(arena, "{{\"tag_name\":\"v{s}\"}}", .{build_options.version});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = release_path, .data = release_body });

    const target_bin = try std.fs.path.join(arena, &.{ root, "target" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_bin, .data = "OLD" });

    const api_url = try std.fmt.allocPrint(arena, "file://{s}", .{release_path});
    const api_override = try testutil.EnvScope.install(arena, &.{.{ "HOLT_UPGRADE_API", api_url }});
    defer api_override.restore();
    const target_override = try testutil.EnvScope.install(arena, &.{.{ "HOLT_UPGRADE_TARGET_BIN", target_bin }});
    defer target_override.restore();

    const got = try testutil.runCmd(arena, command.run, null, &.{});
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "up to date") != null);

    const untouched = try std.Io.Dir.cwd().readFileAlloc(testing.io, target_bin, arena, .unlimited);
    try testing.expectEqualStrings("OLD", untouched);
}

test "run: an explicit older version installs, allowing a downgrade with --yes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const tag = "v0.0.1";

    const bin_dir = try std.fs.path.join(arena, &.{ root, "bin" });
    try fsutil.ensureDir(bin_dir);
    const target_bin = try std.fs.path.join(arena, &.{ bin_dir, "holt" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = target_bin, .data = "OLD" });

    const asset = try assetName(arena, builtin.target.os.tag, builtin.target.cpu.arch);
    const pkg_dir = try std.fs.path.join(arena, &.{ root, "pkg" });
    try fsutil.ensureDir(pkg_dir);

    const dl_dir = try std.fs.path.join(arena, &.{ root, "dl", tag });
    try fsutil.ensureDir(dl_dir);
    const asset_path = try std.fs.path.join(arena, &.{ dl_dir, asset });
    try stageFakeReleaseAsset(arena, pkg_dir, asset_path, "NEW");

    const download_root = try std.fs.path.join(arena, &.{ root, "dl" });
    const download_base = try std.fmt.allocPrint(arena, "file://{s}", .{download_root});
    const download_override = try testutil.EnvScope.install(arena, &.{.{ "HOLT_UPGRADE_DOWNLOAD_BASE", download_base }});
    defer download_override.restore();
    const target_override = try testutil.EnvScope.install(arena, &.{.{ "HOLT_UPGRADE_TARGET_BIN", target_bin }});
    defer target_override.restore();

    const got = try testutil.runCmd(arena, command.run, null, &.{ tag, "--yes" });
    try testing.expectEqual(@as(u8, 0), got.code);
    try testing.expect(std.mem.indexOf(u8, got.out, "upgraded") != null);

    const installed = try std.Io.Dir.cwd().readFileAlloc(testing.io, target_bin, arena, .unlimited);
    try testing.expectEqualStrings("NEW", installed);
}
