//! Loads `~/.config/holt/config.toml`'s `[workspace]` table into a `Config`,
//! resolving the active backend against the file's `[backends]` presets and
//! tilde-expanding all three roots.
//! Every returned field is arena-owned; callers never free them individually.

const std = @import("std");
const toml = @import("toml");
const fsutil = @import("fsutil.zig");
const diagnostic = @import("diag.zig");
const testutil = @import("testutil.zig");
const testing = std.testing;

/// A user-defined `[backends.<name>]` entry: `name` is the sub-table key,
/// `synced_root` its raw (unexpanded) value.
pub const Preset = struct { name: []const u8, synced_root: []const u8 };

pub const Config = struct {
    /// Active backend name, or null when `synced_root` was set directly.
    backend: ?[]const u8,
    synced_root: []u8,
    code_root: []u8,
    hub_root: []u8,
    /// Every `[backends.*]` defined in the file, for the setup/backends/
    /// backend/config commands.
    presets: []Preset,
};

pub const icloud_default_synced_root = "~/Library/Mobile Documents/com~apple~CloudDocs/workspace";

/// `$XDG_CONFIG_HOME/holt/config.toml`, else `~/.config/holt/config.toml`.
/// The result is always absolute: an empty or relative `$XDG_CONFIG_HOME` is
/// invalid per the XDG spec and treated as unset (falling back to `$HOME`),
/// and a `$HOME` that is missing or itself relative errors `NoHomeDir` rather
/// than yielding a relative path that would later trip an `*Absolute` fs call.
pub fn configPath(alloc: std.mem.Allocator) ![]u8 {
    const environ = std.Io.Threaded.global_single_threaded.environ.process_environ;
    const xdg = std.process.Environ.getAlloc(environ, alloc, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    if (xdg) |x| {
        if (x.len > 0 and std.fs.path.isAbsolute(x))
            return std.fs.path.join(alloc, &.{ x, "holt", "config.toml" });
    }
    const home = fsutil.expandTilde(alloc, "~") catch return error.NoHomeDir;
    if (!std.fs.path.isAbsolute(home)) return error.NoHomeDir;
    return std.fs.path.join(alloc, &.{ home, ".config", "holt", "config.toml" });
}

/// A built-in backend suggestion offered by `holt setup`. Fixed-path clouds
/// (commented=false) are seeded as real, immediately usable presets;
/// account-suffix clouds (commented=true) can't ship a correct path, so they
/// are seeded as commented examples the user completes once.
pub const Seed = struct { name: []const u8, synced_root: []const u8, commented: bool };

pub const builtin_seeds: []const Seed = &.{
    .{ .name = "icloud", .synced_root = icloud_default_synced_root, .commented = false },
    .{ .name = "dropbox", .synced_root = "~/Dropbox/workspace", .commented = false },
    .{ .name = "nextcloud", .synced_root = "~/Nextcloud/workspace", .commented = false },
    .{ .name = "mega", .synced_root = "~/MEGA/workspace", .commented = false },
    .{ .name = "pcloud", .synced_root = "~/pCloud Drive/workspace", .commented = false },
    .{ .name = "gdrive", .synced_root = "~/Library/CloudStorage/GoogleDrive-ACCOUNT/My Drive/workspace", .commented = true },
    .{ .name = "onedrive", .synced_root = "~/Library/CloudStorage/OneDrive-ACCOUNT/workspace", .commented = true },
    .{ .name = "proton", .synced_root = "~/Library/CloudStorage/ProtonDrive-ACCOUNT/workspace", .commented = true },
    .{ .name = "box", .synced_root = "~/Library/CloudStorage/Box-Box/workspace", .commented = true },
};

/// Escapes `\` and `"` so `s` is safe to embed as a basic TOML string value.
/// Those are the two bytes that break a basic string; a filesystem path
/// never needs any other TOML escape. A no-op (and thus byte-identical
/// output) on POSIX, where paths carry neither byte. Caller owns the
/// returned memory.
pub fn tomlEscape(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '"' => try out.appendSlice(alloc, "\\\""),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

/// Renders a fresh `config.toml` body for `holt setup`: `active` picks the
/// backend preset (or, when null, `direct_root` is written as
/// workspace.synced_root instead - exactly one of the two is ever set). The
/// fixed-path seeds land as real `[backends.*]` entries; the account-suffix
/// ones as commented examples. Caller owns the returned memory.
pub fn renderConfig(alloc: std.mem.Allocator, active: ?[]const u8, direct_root: ?[]const u8, code_root: []const u8, hub_root: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;

    try w.writeAll(
        \\[workspace]
        \\# The active backend selects a preset from [backends] below. Or set
        \\# synced_root directly here instead of backend.
        \\
    );
    if (active) |name| {
        try w.print("backend = \"{s}\"\n", .{try tomlEscape(alloc, name)});
    } else {
        try w.print("synced_root = \"{s}\"\n", .{try tomlEscape(alloc, direct_root.?)});
    }
    try w.print("code_root = \"{s}\"\n", .{try tomlEscape(alloc, code_root)});
    try w.print("hub_root = \"{s}\"\n", .{try tomlEscape(alloc, hub_root)});

    try w.writeAll(
        \\
        \\# Presets: name -> the synced folder holt uses. Add your own; holt
        \\# never rewrites this section behind your back.
        \\
    );
    for (builtin_seeds) |seed| {
        if (seed.commented) continue;
        try w.print("[backends.{s}]\nsynced_root = \"{s}\"\n", .{ seed.name, try tomlEscape(alloc, seed.synced_root) });
    }

    try w.writeAll(
        \\
        \\# Account-specific clouds: fill in your account and uncomment to use.
        \\
    );
    for (builtin_seeds) |seed| {
        if (!seed.commented) continue;
        try w.print("# [backends.{s}]\n# synced_root = \"{s}\"\n", .{ seed.name, try tomlEscape(alloc, seed.synced_root) });
    }

    return aw.toOwnedSlice();
}

// Mirrors the on-disk [workspace] table before resolution: backend and
// synced_root are both optional since exactly one of them (or neither) is
// valid input, so validity is checked in load rather than at decode time.
// backends stays a raw toml.Value: its sub-table keys are user-defined, so
// there is no fixed Zig type to decode them into.
const Raw = struct {
    workspace: struct {
        backend: ?[]const u8 = null,
        synced_root: ?[]const u8 = null,
        code_root: []const u8 = "~/Code",
        hub_root: []const u8 = "~/Projects",
    },
    backends: ?toml.Value = null,
};

/// Parses `[backends]` into presets. Each entry must be a table with a
/// string `synced_root`; anything else is reported against the entry's name.
fn parsePresets(alloc: std.mem.Allocator, path: []const u8, backends: ?toml.Value, diag: ?*diagnostic.Diagnostic) ![]Preset {
    const v = backends orelse return &.{};
    if (v != .table) {
        if (diag) |d| d.set(alloc, "{s}: [backends] must be a table", .{path});
        return error.MalformedBackends;
    }

    var presets: std.ArrayList(Preset) = .empty;
    var it = v.table.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const synced_root = entry.value_ptr.*.getT([]const u8, "synced_root") orelse {
            if (diag) |d| d.set(alloc, "{s}: [backends.{s}] missing a string synced_root", .{ path, name });
            return error.MalformedBackends;
        };
        try presets.append(alloc, .{ .name = name, .synced_root = synced_root });
    }
    return presets.toOwnedSlice(alloc);
}

/// Parses the `[workspace]` and `[backends]` tables at `path`, resolves the
/// active synced_root (spec 3.2), and tilde-expands all three roots.
pub fn load(alloc: std.mem.Allocator, path: []const u8, diag: ?*diagnostic.Diagnostic) !Config {
    const src = std.Io.Dir.cwd().readFileAlloc(fsutil.io(), path, alloc, .limited(1 << 20)) catch |err| {
        if (diag) |d| d.set(alloc, "{s}: {s}", .{ path, @errorName(err) });
        return err;
    };

    var errs: std.ArrayList(toml.Diagnostic) = .empty;
    const raw = toml.parseInto(Raw, alloc, src, .{ .errors = &errs }) catch |err| {
        if (diag) |d| setLoadDiag(d, alloc, path, err, errs.items);
        return err;
    };
    const ws = raw.workspace;

    const presets = try parsePresets(alloc, path, raw.backends, diag);

    if (ws.backend != null and ws.synced_root != null) {
        if (diag) |d| d.set(alloc, "{s}: set either workspace.backend or workspace.synced_root, not both", .{path});
        return error.ConfigConflict;
    }

    const synced_root_raw = blk: {
        if (ws.backend) |name| {
            for (presets) |p| {
                if (std.mem.eql(u8, p.name, name)) break :blk p.synced_root;
            }
            if (diag) |d| d.set(alloc, "{s}: backend \"{s}\" is not defined in [backends]; add it or run \"holt setup\"", .{ path, name });
            return error.UnknownBackend;
        }
        if (ws.synced_root) |sr| break :blk sr;
        if (diag) |d| d.set(alloc, "{s}: no workspace.backend or workspace.synced_root set; run \"holt setup\"", .{path});
        return error.NoSyncedRoot;
    };

    const synced_root = try fsutil.expandTilde(alloc, synced_root_raw);
    const code_root = try fsutil.expandTilde(alloc, ws.code_root);
    const hub_root = try fsutil.expandTilde(alloc, ws.hub_root);
    try ensureAbsolute(diag, alloc, path, "synced_root", synced_root);
    try ensureAbsolute(diag, alloc, path, "code_root", code_root);
    try ensureAbsolute(diag, alloc, path, "hub_root", hub_root);
    try ensureDirOrAbsent(diag, alloc, path, "synced_root", synced_root);
    try ensureDirOrAbsent(diag, alloc, path, "code_root", code_root);
    try ensureDirOrAbsent(diag, alloc, path, "hub_root", hub_root);

    return .{
        .backend = ws.backend,
        .synced_root = synced_root,
        .code_root = code_root,
        .hub_root = hub_root,
        .presets = presets,
    };
}

/// Every root feeds directly into `openDirAbsolute`/`accessAbsolute`, which
/// assert an absolute path. A relative value - a relative literal in the
/// config, or a "~/..." expanded against a relative/unset $HOME - is caught
/// here as a clean diagnostic instead of a downstream panic.
fn ensureAbsolute(diag: ?*diagnostic.Diagnostic, alloc: std.mem.Allocator, path: []const u8, label: []const u8, value: []const u8) !void {
    if (std.fs.path.isAbsolute(value)) return;
    if (diag) |d| d.set(alloc, "{s}: {s} \"{s}\" is not an absolute path (check the config and $HOME)", .{ path, label, value });
    return error.RelativeRoot;
}

/// A root that does not exist yet is fine (a fresh machine or an unmounted
/// cloud). But a root that exists as a *file* would make every later
/// `openDirAbsolute` fail; catch that here as a clear diagnostic instead.
/// Statting rather than opening as a directory is what makes this
/// cross-platform: Windows does not surface `error.NotDir` from opening a
/// file as a directory the way POSIX does, so the kind has to be checked
/// directly. Any other access error is left for the operation that actually
/// needs the path to report in its own context.
fn ensureDirOrAbsent(diag: ?*diagnostic.Diagnostic, alloc: std.mem.Allocator, path: []const u8, label: []const u8, root: []const u8) !void {
    const st = std.Io.Dir.cwd().statFile(fsutil.io(), root, .{}) catch return;
    if (st.kind != .directory) {
        if (diag) |d| d.set(alloc, "{s}: {s} \"{s}\" exists but is not a directory", .{ path, label, root });
        return error.RootNotDirectory;
    }
}

/// Attributes a `toml.parseInto` failure to `path` with the most specific
/// reason available. `errs` is the diagnostic list `load` handed to
/// `parseInto`; the streaming fast path never touches it, so any entries
/// come from the canonical tree-decode rerun that produced `err`.
fn setLoadDiag(d: *diagnostic.Diagnostic, alloc: std.mem.Allocator, path: []const u8, err: anyerror, errs: []const toml.Diagnostic) void {
    if (err == error.MissingField and errs.len > 0) {
        const e = errs[0];
        const top_level = e.path == null or e.path.?.len == 0;
        if (top_level) {
            d.set(alloc, "{s}: no [workspace] table found", .{path});
            return;
        }
    }
    if (errs.len > 0) {
        d.set(alloc, "{s}: invalid TOML: {s}", .{ path, errs[0].message });
    } else {
        d.set(alloc, "{s}: invalid TOML: parse error", .{path});
    }
}

/// Loads the config at `configPath()`. There is no fallback: an absent
/// config file always errors `error.NoConfig` pointing at "holt setup",
/// never a guess at the synced_root (e.g. adopting an existing iCloud
/// container).
pub fn loadDefault(alloc: std.mem.Allocator, diag: ?*diagnostic.Diagnostic) !Config {
    const path = configPath(alloc) catch |err| {
        if (diag) |d| d.set(alloc, "cannot locate the holt config: set $HOME or $XDG_CONFIG_HOME to an absolute path", .{});
        return err;
    };
    return loadFromPath(alloc, path, diag);
}

/// Split out from `loadDefault` so tests can point at a fixture path
/// instead of the real config location.
fn loadFromPath(alloc: std.mem.Allocator, path: []const u8, diag: ?*diagnostic.Diagnostic) !Config {
    if (!fsutil.exists(path)) {
        if (diag) |d| d.set(alloc, "{s}: no holt config file; run \"holt setup\" to create one", .{path});
        return error.NoConfig;
    }
    return load(alloc, path, diag);
}

fn writeFixture(tmp: *testing.TmpDir, content: []const u8) ![]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.toml", .data = content });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    return std.fs.path.join(testing.allocator, &.{ root, "config.toml" });
}

test "load: backend mode resolves synced_root from the matching preset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\backend = "dropbox"
        \\
        \\[backends.dropbox]
        \\synced_root = "~/Dropbox/workspace"
        \\
    );
    defer testing.allocator.free(path);

    const cfg = try load(arena, path, null);
    try testing.expectEqualStrings("dropbox", cfg.backend.?);
    const home = try fsutil.expandTilde(arena, "~");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "Dropbox", "workspace" }), cfg.synced_root);
    try testing.expectEqual(@as(usize, 1), cfg.presets.len);
    try testing.expectEqualStrings("dropbox", cfg.presets[0].name);
}

test "load: direct mode uses synced_root with no backend" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\synced_root = "~/x"
        \\
    );
    defer testing.allocator.free(path);

    const cfg = try load(arena, path, null);
    try testing.expectEqual(@as(?[]const u8, null), cfg.backend);
    const home = try fsutil.expandTilde(arena, "~");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "x" }), cfg.synced_root);
}

test "load: a free-form backend name loads fine as long as its preset exists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\backend = "myserver"
        \\
        \\[backends.myserver]
        \\synced_root = "~/nas"
        \\
    );
    defer testing.allocator.free(path);

    const cfg = try load(arena, path, null);
    try testing.expectEqualStrings("myserver", cfg.backend.?);
    const home = try fsutil.expandTilde(arena, "~");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "nas" }), cfg.synced_root);
}

test "load: a backend with no matching preset errors UnknownBackend, naming the path and the backend" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\backend = "nope"
        \\
    );
    defer testing.allocator.free(path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.UnknownBackend, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, path) != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "nope") != null);
}

test "load: both backend and synced_root set errors ConfigConflict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\backend = "dropbox"
        \\synced_root = "~/x"
        \\
        \\[backends.dropbox]
        \\synced_root = "~/Dropbox/workspace"
        \\
    );
    defer testing.allocator.free(path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.ConfigConflict, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, path) != null);
}

test "load: neither backend nor synced_root set errors NoSyncedRoot, pointing at holt setup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\
    );
    defer testing.allocator.free(path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.NoSyncedRoot, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "holt setup") != null);
}

test "load: multiple backends all appear in presets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\backend = "dropbox"
        \\
        \\[backends.dropbox]
        \\synced_root = "~/Dropbox/workspace"
        \\
        \\[backends.work-gdrive]
        \\synced_root = "~/GDrive/holt"
        \\
    );
    defer testing.allocator.free(path);

    const cfg = try load(arena, path, null);
    try testing.expectEqual(@as(usize, 2), cfg.presets.len);
    var saw_dropbox = false;
    var saw_gdrive = false;
    for (cfg.presets) |p| {
        if (std.mem.eql(u8, p.name, "dropbox")) saw_dropbox = true;
        if (std.mem.eql(u8, p.name, "work-gdrive")) saw_gdrive = true;
    }
    try testing.expect(saw_dropbox);
    try testing.expect(saw_gdrive);
}

test "load: tilde-expands synced_root, code_root, and hub_root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\synced_root = "~/Sync"
        \\code_root = "~/dev"
        \\hub_root = "~/hub"
        \\
    );
    defer testing.allocator.free(path);

    const cfg = try load(arena, path, null);
    const home = try fsutil.expandTilde(arena, "~");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "Sync" }), cfg.synced_root);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "dev" }), cfg.code_root);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "hub" }), cfg.hub_root);
}

test "loadFromPath: a non-existent config path errors NoConfig, pointing at holt setup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    const absent_path = try std.fs.path.join(arena, &.{ root, "config.toml" });

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.NoConfig, loadFromPath(arena, absent_path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "holt setup") != null);
}

test "loadFromPath: an existing iCloud container never gets adopted when the config is absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fake_home = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    const override = try testutil.EnvOverride.install(arena, "HOME", fake_home);
    defer override.restore();

    const icloud_container = try fsutil.expandTilde(arena, icloud_default_synced_root);
    try fsutil.ensureDir(icloud_container);
    try testing.expect(fsutil.exists(icloud_container));

    const absent_path = try std.fs.path.join(arena, &.{ fake_home, "config.toml" });

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.NoConfig, loadFromPath(arena, absent_path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "holt setup") != null);
}

test "loadFromPath: an existing but malformed config propagates its error, never falls back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\backend = "nope"
        \\
    );
    defer testing.allocator.free(path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expect(fsutil.exists(path));
    try testing.expectError(error.UnknownBackend, loadFromPath(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "nope") != null);
}

test "builtin_seeds: 5 real fixed-path clouds, 4 commented account-suffix clouds" {
    var real: usize = 0;
    var commented: usize = 0;
    for (builtin_seeds) |seed| {
        if (seed.commented) commented += 1 else real += 1;
    }
    try testing.expectEqual(@as(usize, 5), real);
    try testing.expectEqual(@as(usize, 4), commented);
}

test "renderConfig: backend mode round-trips through load and lists the seeds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = try renderConfig(arena, "dropbox", null, "~/Code", "~/Projects");
    try testing.expect(std.mem.indexOf(u8, body, "backend = \"dropbox\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "[backends.dropbox]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "# [backends.gdrive]") != null);

    const path = try writeFixture(&tmp, body);
    defer testing.allocator.free(path);

    const cfg = try load(arena, path, null);
    try testing.expectEqualStrings("dropbox", cfg.backend.?);
    const home = try fsutil.expandTilde(arena, "~");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "Dropbox", "workspace" }), cfg.synced_root);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "Code" }), cfg.code_root);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "Projects" }), cfg.hub_root);
}

test "renderConfig: direct mode round-trips through load with no active backend" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = try renderConfig(arena, null, "~/custom", "~/Code", "~/Projects");
    try testing.expect(std.mem.indexOf(u8, body, "synced_root = \"~/custom\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "backend =") == null);

    const path = try writeFixture(&tmp, body);
    defer testing.allocator.free(path);

    const cfg = try load(arena, path, null);
    try testing.expectEqual(@as(?[]const u8, null), cfg.backend);
    const home = try fsutil.expandTilde(arena, "~");
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ home, "custom" }), cfg.synced_root);
}

test "load: malformed TOML syntax errors and the diag names the path and says invalid TOML" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\backend =
        \\
    );
    defer testing.allocator.free(path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.TomlParseError, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, path) != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "invalid TOML") != null);
}

test "load: a file with no [workspace] table errors, naming the missing table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp, "");
    defer testing.allocator.free(path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.MissingField, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, path) != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "no [workspace] table found") != null);
}

test "configPath: resolves under a holt directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const path = try configPath(arena_state.allocator());
    try testing.expect(std.mem.endsWith(u8, path, "holt" ++ std.fs.path.sep_str ++ "config.toml"));
}

test "configPath: an empty or relative XDG_CONFIG_HOME is treated as unset, still yielding an absolute path" {
    const default_suffix = ".config" ++ std.fs.path.sep_str ++ "holt" ++ std.fs.path.sep_str ++ "config.toml";
    for ([_][]const u8{ "", "relative/cfg" }) |bad_xdg| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", bad_xdg);
        defer override.restore();

        const path = try configPath(arena);
        try testing.expect(std.fs.path.isAbsolute(path));
        try testing.expect(std.mem.endsWith(u8, path, default_suffix));
    }
}

test "configPath: an absolute XDG_CONFIG_HOME is used verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const override = try testutil.EnvOverride.install(arena, "XDG_CONFIG_HOME", "/somewhere/cfg");
    defer override.restore();

    const path = try configPath(arena);
    try testing.expectEqualStrings("/somewhere/cfg/holt/config.toml", path);
}

test "load: a relative synced_root errors RelativeRoot instead of panicking downstream, naming the root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\synced_root = "relative/ws"
        \\
    );
    defer testing.allocator.free(path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.RelativeRoot, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "synced_root") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "absolute") != null);
}

test "load: a root that exists as a file errors RootNotDirectory instead of a bare NotDir, naming it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try arena.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);

    // A plain file where synced_root is supposed to be a directory.
    const file_root = try std.fs.path.join(arena, &.{ root, "not-a-dir" });
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = file_root, .data = "x" });

    const path = try writeFixture(&tmp, try std.fmt.allocPrint(arena, "[workspace]\nsynced_root = \"{s}\"\n", .{try tomlEscape(arena, file_root)}));
    defer testing.allocator.free(path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.RootNotDirectory, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "synced_root") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "not a directory") != null);
}

test "load: a relative code_root errors RelativeRoot, naming code_root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFixture(&tmp,
        \\[workspace]
        \\synced_root = "/abs/ws"
        \\code_root = "rel/code"
        \\
    );
    defer testing.allocator.free(path);

    var d: diagnostic.Diagnostic = .{};
    try testing.expectError(error.RelativeRoot, load(arena, path, &d));
    try testing.expect(std.mem.indexOf(u8, d.message, "code_root") != null);
}
