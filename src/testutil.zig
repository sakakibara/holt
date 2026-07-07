//! Test-only sandbox and bare-repo factory shared by every module whose
//! tests need a real, disposable git repo. Every git command run through
//! this file uses a sanitized environment (`hermeticGitEnv`) so tests are
//! deterministic on any machine: GIT_CONFIG_GLOBAL/SYSTEM point at /dev/null
//! rather than the developer's real ~/.gitconfig, and identity/default-branch
//! are pinned with `-c` flags (which win over any config file precedence
//! still in effect), keeping tests deterministic regardless of the machine's
//! real ~/.gitconfig or credentials.

const std = @import("std");
const builtin = @import("builtin");
const proc = @import("proc.zig");
const fsutil = @import("fsutil.zig");
const marker = @import("marker.zig");
const workspace = @import("workspace.zig");
const cli = @import("cli.zig");
const testing = std.testing;

const identity_flags = [_][]const u8{
    "-c", "user.name=holt-test",
    "-c", "user.email=test@holt.invalid",
    "-c", "init.defaultBranch=main",
    "-c", "commit.gpgsign=false",
};

pub const HermeticEnv = struct {
    map: std.process.Environ.Map,

    pub fn deinit(self: *HermeticEnv) void {
        self.map.deinit();
    }
};

/// Copies the process's real environment, then overrides GIT_CONFIG_GLOBAL
/// and GIT_CONFIG_SYSTEM so git ignores the developer's real config files.
pub fn hermeticGitEnv(alloc: std.mem.Allocator) !HermeticEnv {
    const real_env = std.Io.Threaded.global_single_threaded.environ.process_environ;
    var map = try std.process.Environ.createMap(real_env, alloc);
    errdefer map.deinit();
    try map.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try map.put("GIT_CONFIG_SYSTEM", "/dev/null");
    return .{ .map = map };
}

pub const Sandbox = struct {
    tmp: testing.TmpDir,
    root: []u8,
    alloc: std.mem.Allocator,
    git_env: HermeticEnv,
    work_seq: usize = 0,

    pub fn init(alloc: std.mem.Allocator) !Sandbox {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const resolved = buf[0..try tmp.dir.realPath(testing.io, &buf)];
        const root = try alloc.dupe(u8, resolved);
        errdefer alloc.free(root);

        const git_env = try hermeticGitEnv(alloc);

        return .{ .tmp = tmp, .root = root, .alloc = alloc, .git_env = git_env };
    }

    pub fn deinit(self: *Sandbox) void {
        self.git_env.deinit();
        self.alloc.free(self.root);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn joinRoot(self: *Sandbox, name: []const u8) ![]u8 {
        return std.fs.path.join(self.alloc, &.{ self.root, name });
    }

    fn nextWorkName(self: *Sandbox, prefix: []const u8) ![]u8 {
        defer self.work_seq += 1;
        return std.fmt.allocPrint(self.alloc, "{s}-{d}", .{ prefix, self.work_seq });
    }
};

/// Runs `git` in `sb`'s hermetic environment with the identity flags applied,
/// discarding stdout/stderr. Returns `error.GitCommandFailed` (with stderr
/// printed for diagnosis) on a nonzero exit.
pub fn runGit(sb: *Sandbox, cwd: ?[]const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(sb.alloc);
    try argv.append(sb.alloc, "git");
    try argv.appendSlice(sb.alloc, &identity_flags);
    try argv.appendSlice(sb.alloc, args);

    const res = try proc.runEnv(sb.alloc, argv.items, cwd, &sb.git_env.map);
    defer sb.alloc.free(res.stdout);
    defer sb.alloc.free(res.stderr);
    if (res.status != 0) {
        std.debug.print("git command failed (status {d}): {s}\n", .{ res.status, res.stderr });
        return error.GitCommandFailed;
    }
}

/// `git init --bare` plus one commit pushed from a throwaway clone, so the
/// bare repo has a real `main` branch that later `makeWorkClone` calls track
/// automatically. Caller owns the returned path.
pub fn makeBareRepo(sb: *Sandbox, name: []const u8) ![]u8 {
    const bare_path = try sb.joinRoot(name);
    errdefer sb.alloc.free(bare_path);

    try runGit(sb, null, &.{ "init", "--bare", bare_path });

    const seed_name = try sb.nextWorkName("seed");
    defer sb.alloc.free(seed_name);
    const seed_path = try sb.joinRoot(seed_name);
    defer sb.alloc.free(seed_path);

    try runGit(sb, null, &.{ "clone", bare_path, seed_path });

    {
        var seed_dir = try std.Io.Dir.cwd().openDir(fsutil.io(), seed_path, .{});
        defer seed_dir.close(fsutil.io());
        try seed_dir.writeFile(fsutil.io(), .{ .sub_path = "README", .data = "hermetic seed commit\n" });
    }

    try runGit(sb, seed_path, &.{ "add", "README" });
    try runGit(sb, seed_path, &.{ "commit", "-m", "initial commit" });
    try runGit(sb, seed_path, &.{ "push", "origin", "main" });

    return bare_path;
}

/// Fresh `git clone` of `bare_path` into an auto-named directory inside the
/// sandbox. Caller owns the returned path.
pub fn makeWorkClone(sb: *Sandbox, bare_path: []const u8) ![]u8 {
    const name = try sb.nextWorkName("work");
    defer sb.alloc.free(name);
    const dest = try sb.joinRoot(name);
    errdefer sb.alloc.free(dest);

    try runGit(sb, null, &.{ "clone", bare_path, dest });

    return dest;
}

/// Writes a marker at `<parent_dir>/<org>/<name>/.holt.json`, creating any
/// missing directories. `parent_dir` must already be the fully-qualified
/// projects/archive directory (e.g. the result of `ws.projectsRoot(alloc)`
/// or `ws.archiveRoot(alloc)`) - this only joins `org`/`name` onto it.
pub fn writeMarker(alloc: std.mem.Allocator, parent_dir: []const u8, org: []const u8, name: []const u8, m: marker.Marker) !void {
    const dir_path = try std.fs.path.join(alloc, &.{ parent_dir, org, name });
    try fsutil.ensureDir(dir_path);
    const marker_path = try std.fs.path.join(alloc, &.{ dir_path, marker.marker_basename });
    try marker.save(&m, marker_path);
}

/// Local-backend workspace rooted under `<root>/{synced,code,hub}` - the
/// fixture shape most command tests build their workspace around.
pub fn testWorkspace(alloc: std.mem.Allocator, root: []const u8) !workspace.Workspace {
    return .{ .cfg = .{
        .backend = null,
        .presets = &.{},
        .synced_root = try std.fs.path.join(alloc, &.{ root, "synced" }),
        .code_root = try std.fs.path.join(alloc, &.{ root, "code" }),
        .hub_root = try std.fs.path.join(alloc, &.{ root, "hub" }),
    } };
}

/// Not exposed by `std.os.windows.kernel32` (0.16 only binds the calls the
/// standard library itself needs); this is the real Win32 entry point,
/// declared the same way the rest of that module declares one.
extern "kernel32" fn SetEnvironmentVariableW(
    lpName: ?[*:0]const u16,
    lpValue: ?[*:0]const u16,
) callconv(.winapi) std.os.windows.BOOL;

/// A saved process environment, swapped back in on `restore`. Used by
/// tests that need a command to see a different env var than the real
/// process has, without leaking the override past the test.
pub const EnvOverride = struct {
    original: std.process.Environ,
    windows: Windows,

    /// On Windows, `Environ.Block` resolves to `GlobalBlock` - a single
    /// `use_global` flag, not a data-carrying block - because the PEB
    /// environment can move whenever it's edited, so no long-lived pointer
    /// to it is valid. `process_environ` therefore always mirrors the live
    /// PEB there and swapping it (the POSIX approach) has no effect; the
    /// override instead mutates that same live block via the real
    /// `SetEnvironmentVariableW`, and restores it the same way.
    const Windows = if (builtin.os.tag == .windows) struct {
        key_w: [:0]const u16,
        prior_value_w: ?[:0]const u16,
    } else void;

    /// Overrides `key` to `value` (or removes it, if `value` is null) in
    /// the process environment. Returns the prior environment so the
    /// caller can restore it once done.
    pub fn install(alloc: std.mem.Allocator, key: []const u8, value: ?[]const u8) !EnvOverride {
        const singleton = std.Io.Threaded.global_single_threaded;
        const original = singleton.environ.process_environ;
        var map = try std.process.Environ.createMap(original, alloc);
        const prior_value_w: if (builtin.os.tag == .windows) ?[:0]const u16 else void = if (builtin.os.tag == .windows)
            (if (map.get(key)) |v| try std.unicode.wtf8ToWtf16LeAllocZ(alloc, v) else null)
        else {};
        if (value) |v| {
            try map.put(key, v);
        } else {
            _ = map.swapRemove(key);
        }
        if (builtin.os.tag == .windows) {
            const key_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, key);
            const value_w: ?[:0]const u16 = if (value) |v| try std.unicode.wtf8ToWtf16LeAllocZ(alloc, v) else null;
            if (!SetEnvironmentVariableW(key_w.ptr, if (value_w) |w| w.ptr else null).toBool())
                return error.SetEnvironmentVariableFailed;
            return .{ .original = original, .windows = .{ .key_w = key_w, .prior_value_w = prior_value_w } };
        } else {
            const block = try map.createPosixBlock(alloc, .{});
            singleton.environ.process_environ = .{ .block = block };
            return .{ .original = original, .windows = {} };
        }
    }

    pub fn restore(self: EnvOverride) void {
        if (builtin.os.tag == .windows) {
            _ = SetEnvironmentVariableW(
                self.windows.key_w.ptr,
                if (self.windows.prior_value_w) |w| w.ptr else null,
            );
        }
        std.Io.Threaded.global_single_threaded.environ.process_environ = self.original;
    }
};

pub const GitInsteadOfPair = struct { url: []const u8, bare: []const u8 };

/// Real remote hosts aren't reachable from a test sandbox, and
/// `identity.fromUrl` only accepts remote-shaped strings, never a bare
/// local path. Writes a `GIT_CONFIG_GLOBAL` file at `gitconfig_path` with
/// one `insteadOf` rule per pair, rewriting each fake url to a real
/// hermetic bare repo path for the process's git children.
pub fn gitInsteadOf(alloc: std.mem.Allocator, gitconfig_path: []const u8, pairs: []const GitInsteadOfPair) !EnvOverride {
    var content: std.ArrayList(u8) = .empty;
    for (pairs) |pair| {
        try content.appendSlice(alloc, try std.fmt.allocPrint(alloc, "[url \"{s}\"]\n\tinsteadOf = {s}\n", .{ pair.bare, pair.url }));
    }
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = gitconfig_path, .data = content.items });

    return EnvOverride.install(alloc, "GIT_CONFIG_GLOBAL", gitconfig_path);
}

pub const RunResult = struct { code: u8, out: []const u8, err: []const u8 };

/// Builds a `Ctx` around `argv` and `ws` (null for a command that doesn't
/// need a workspace) and calls `run_fn`, capturing its output into in-memory
/// buffers instead of real stdout/stderr.
pub fn runCmd(alloc: std.mem.Allocator, run_fn: *const fn (ctx: *cli.Ctx) anyerror!u8, ws: ?workspace.Workspace, argv: []const []const u8) !RunResult {
    var args = try cli.Args.init(alloc, argv);
    var out: std.Io.Writer.Allocating = .init(alloc);
    var err_w: std.Io.Writer.Allocating = .init(alloc);
    var ctx: cli.Ctx = .{ .alloc = alloc, .ws = ws, .args = &args, .out = &out.writer, .err_w = &err_w.writer };
    const code = try run_fn(&ctx);
    return .{ .code = code, .out = out.written(), .err = err_w.written() };
}
