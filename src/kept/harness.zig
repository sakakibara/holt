//! Test-only: up to three simulated machines sharing one synced root. Each
//! machine has its own code root, state directory, and local copy of the
//! synced root; files under `kept/` travel between those copies only when a
//! test delivers them, so delivery can be delayed, reordered by path, or
//! withheld from a machine that is offline. A delivery overwrites what the
//! receiver has, as a cloud backend's last writer wins.

const std = @import("std");
const Env = @import("env").Env;
const fsutil = @import("../fsutil.zig");
const testutil = @import("../testutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const ctx_mod = @import("ctx.zig");
const place = @import("place.zig");
const store = @import("store.zig");
const reconcile_mod = @import("reconcile.zig");
const testing = std.testing;

const io = fsutil.io;

/// A throwaway directory and an arena for one unit test. Every path it
/// returns is absolute and lives in the arena.
pub const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,

    pub fn init() !Fixture {
        var f: Fixture = .{ .arena_state = .init(testing.allocator), .tmp = testing.tmpDir(.{}), .root = undefined };
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        f.root = try f.arena_state.allocator().dupe(u8, buf[0..try f.tmp.dir.realPath(testing.io, &buf)]);
        return f;
    }

    pub fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena_state.deinit();
    }

    pub fn alloc(f: *Fixture) std.mem.Allocator {
        return f.arena_state.allocator();
    }

    /// `rel`, `/`-separated, under the fixture's root.
    pub fn path(f: *Fixture, rel: []const u8) ![]u8 {
        return fsutil.joinSlashy(f.alloc(), f.root, rel);
    }

    /// Writes `data` at `rel`, creating parents, and returns its path.
    pub fn write(f: *Fixture, rel: []const u8, data: []const u8) ![]u8 {
        const p = try f.path(rel);
        if (std.fs.path.dirname(p)) |d| try fsutil.ensureDir(d);
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = data });
        return p;
    }
};

/// Whether names differing only in case are different files under `dir`,
/// as on Linux or a case-sensitive APFS volume.
pub fn caseSensitive(alloc: std.mem.Allocator, dir: []const u8) !bool {
    const probe = try std.fs.path.join(alloc, &.{ dir, "case-probe" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = probe, .data = "" });
    defer fsutil.removePath(probe) catch {};
    return try content.entryAt(try std.fs.path.join(alloc, &.{ dir, "CASE-PROBE" })) == .absent;
}

pub const repo_key = "github.com/acme/widget";
const machine_ids = [_][]const u8{ "000000000000000a", "000000000000000b", "000000000000000c" };
const names = [_][]const u8{ "a", "b", "c" };

pub const Machine = struct {
    name: []const u8,
    synced: []const u8,
    code: []const u8,
    clone: []const u8,
    ctx: ctx_mod.Ctx,

    pub fn path(m: *const Machine, rel: []const u8) ![]u8 {
        return fsutil.joinSlashy(m.ctx.alloc, m.clone, rel);
    }

    pub fn keptPath(m: *const Machine, rel: []const u8) ![]u8 {
        return m.ctx.layout.copyPath(m.ctx.alloc, repo_key, rel);
    }

    /// Writes `data` at `rel` in the clone, creating parents; through a
    /// link when one is there.
    pub fn write(m: *const Machine, rel: []const u8, data: []const u8) !void {
        const p = try m.path(rel);
        const parent = std.fs.path.dirname(p).?;
        if (fsutil.exists(parent) == false) try fsutil.ensureDir(parent);
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = data });
    }

    /// Replaces whatever is at `rel` with a new regular file, as a tool that
    /// saves by writing a new file and renaming it over the old one.
    pub fn saveByRename(m: *const Machine, rel: []const u8, data: []const u8) !void {
        const p = try m.path(rel);
        const tmp = try std.fmt.allocPrint(m.ctx.alloc, "{s}.save", .{p});
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = tmp, .data = data });
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), p, io());
    }

    pub fn read(m: *const Machine, rel: []const u8) ![]u8 {
        return content.readSmall(m.ctx.alloc, try m.path(rel));
    }

    pub fn entry(m: *const Machine, rel: []const u8) !content.Entry {
        return content.entryAt(try m.path(rel));
    }

    /// True when `rel` is a link to this machine's kept copy.
    pub fn linked(m: *const Machine, rel: []const u8) !bool {
        const raw = (try content.readLink(m.ctx.alloc, try m.path(rel))) orelse return false;
        return std.mem.eql(u8, raw, try m.keptPath(rel));
    }

    pub fn keep(m: *const Machine, rel: []const u8) !place.KeepOutcome {
        return keepIn(m.ctx, m.clone, rel);
    }

    pub fn reconcile(m: *const Machine) !reconcile_mod.Report {
        return reconcileIn(m.ctx, m.clone, .apply);
    }

    pub fn git(m: *const Machine, sb: *testutil.Sandbox, args: []const []const u8) !void {
        try testutil.runGit(sb, m.clone, args);
    }
};

/// `place.keepPath` as one command runs it: with an index loaded first.
pub fn keepIn(ctx: ctx_mod.Ctx, worktree: []const u8, rel: []const u8) !place.KeepOutcome {
    const index = try store.loadIndex(ctx.alloc, ctx.layout);
    return place.keepPath(ctx, &index, worktree, rel, .{});
}

/// `reconcile_mod.reconcile` as one command runs it: with an index loaded
/// first.
pub fn reconcileIn(ctx: ctx_mod.Ctx, worktree: []const u8, mode: reconcile_mod.Mode) !reconcile_mod.Report {
    const index = try store.loadIndex(ctx.alloc, ctx.layout);
    return reconcile_mod.reconcile(ctx, &index, worktree, mode);
}

const Snap = struct { dir: bool, hex: [64]u8 };
const SnapMap = std.StringHashMapUnmanaged(Snap);

pub const World = struct {
    a: std.mem.Allocator,
    sb: *testutil.Sandbox,
    bare: []const u8,
    machines: []Machine,
    /// What each sender last delivered to each receiver.
    delivered: [3][3]SnapMap = .{ .{ .empty, .empty, .empty }, .{ .empty, .empty, .empty }, .{ .empty, .empty, .empty } },
    offline: [3]bool = .{ false, false, false },

    /// `n` machines, each with a clone of one shared origin at the same
    /// place under its code root, so all of them file under `repo_key`.
    pub fn init(a: std.mem.Allocator, sb: *testutil.Sandbox, n: usize) !World {
        const bare_owned = try testutil.makeBareRepo(sb, "widget.git");
        defer sb.alloc.free(bare_owned);
        const bare = try a.dupe(u8, bare_owned);
        const machines = try a.alloc(Machine, n);
        for (machines, 0..) |*mach, i| {
            const root = try std.fs.path.join(a, &.{ sb.root, "machine", names[i] });
            const synced = try std.fs.path.join(a, &.{ root, "synced" });
            const code = try std.fs.path.join(a, &.{ root, "code" });
            const tmp = try std.fs.path.join(a, &.{ root, "tmp" });
            try fsutil.ensureDir(synced);
            try fsutil.ensureDir(tmp);
            const clone_path = try fsutil.joinSlashy(a, code, repo_key);
            try testutil.runGit(sb, null, &.{ "clone", "-q", bare, clone_path });

            const map = try a.create(std.process.Environ.Map);
            map.* = std.process.Environ.Map.init(a);
            try map.put("TMPDIR", tmp);
            try map.put("TEMP", tmp);
            try map.put("HOME", root);
            try map.put("USERPROFILE", root);
            try map.put("XDG_STATE_HOME", try std.fs.path.join(a, &.{ root, "state" }));
            mach.* = .{
                .name = names[i],
                .synced = synced,
                .code = code,
                .clone = try fsutil.realPathOrSelf(a, clone_path),
                .ctx = .{
                    .alloc = a,
                    .env = .{ .map = map },
                    .layout = .{ .synced_root = synced },
                    .code_root = code,
                    .machine_id = machine_ids[i],
                },
            };
        }
        return .{ .a = a, .sb = sb, .bare = bare, .machines = machines };
    }

    pub fn m(w: *World, i: usize) *Machine {
        return &w.machines[i];
    }

    fn snapshot(w: *World, i: usize, sub: []const u8) !SnapMap {
        var out: SnapMap = .empty;
        const kept = try std.fs.path.join(w.a, &.{ w.machines[i].synced, "kept" });
        var d = std.Io.Dir.cwd().openDir(io(), kept, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return out,
            else => return err,
        };
        defer d.close(io());
        var walker = try d.walk(w.a);
        defer walker.deinit();
        while (try walker.next(io())) |e| {
            const rel = try w.a.dupe(u8, e.path);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
            if (!under(rel, sub)) continue;
            switch (e.kind) {
                .directory => try out.put(w.a, rel, .{ .dir = true, .hex = @splat('0') }),
                .file => try out.put(w.a, rel, .{ .dir = false, .hex = try content.hashFile(w.a, try std.fs.path.join(w.a, &.{ kept, e.path })) }),
                else => {},
            }
        }
        return out;
    }

    fn under(rel: []const u8, sub: []const u8) bool {
        if (sub.len == 0) return true;
        if (std.mem.eql(u8, rel, sub)) return true;
        return rel.len > sub.len and std.mem.startsWith(u8, rel, sub) and rel[sub.len] == '/';
    }

    /// Delivers to machine `to` every change under `kept/<sub>` (all of
    /// `kept/` when `sub` is empty) that `from` has made since its last
    /// delivery there: new and changed files overwrite, deletions delete.
    /// What `to` receives counts as in step between the two, so `to`
    /// deleting it later reaches `from` as a deletion too.
    pub fn deliverPath(w: *World, from: usize, to: usize, sub: []const u8) !void {
        if (w.offline[from] or w.offline[to]) return error.Offline;
        const cur = try w.snapshot(from, sub);
        const prev = &w.delivered[from][to];
        const src_kept = try std.fs.path.join(w.a, &.{ w.machines[from].synced, "kept" });
        const dst_kept = try std.fs.path.join(w.a, &.{ w.machines[to].synced, "kept" });

        var changed: std.ArrayList([]const u8) = .empty;
        var it = cur.iterator();
        while (it.next()) |kv| {
            const old = prev.get(kv.key_ptr.*);
            if (old == null or old.?.dir != kv.value_ptr.dir or !std.mem.eql(u8, &old.?.hex, &kv.value_ptr.hex)) try changed.append(w.a, kv.key_ptr.*);
        }
        std.mem.sort([]const u8, changed.items, {}, paths.lessThan);
        for (changed.items) |rel| {
            const dst = try fsutil.joinSlashy(w.a, dst_kept, rel);
            const s = cur.get(rel).?;
            const existing = try content.entryAt(dst);
            if (s.dir) {
                if (existing != .dir and existing != .absent) try std.Io.Dir.cwd().deleteTree(io(), dst);
                try fsutil.ensureDir(dst);
            } else {
                if (existing == .dir) try std.Io.Dir.cwd().deleteTree(io(), dst);
                try fsutil.ensureDir(std.fs.path.dirname(dst).?);
                const bytes = try content.readSmall(w.a, try fsutil.joinSlashy(w.a, src_kept, rel));
                try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = dst, .data = bytes });
            }
        }

        var gone: std.ArrayList([]const u8) = .empty;
        var pit = prev.iterator();
        while (pit.next()) |kv| {
            if (under(kv.key_ptr.*, sub) and !cur.contains(kv.key_ptr.*)) try gone.append(w.a, kv.key_ptr.*);
        }
        std.mem.sort([]const u8, gone.items, {}, paths.lessThan);
        std.mem.reverse([]const u8, gone.items);
        for (gone.items) |rel| {
            const dst = try fsutil.joinSlashy(w.a, dst_kept, rel);
            if (prev.get(rel).?.dir) {
                std.Io.Dir.cwd().deleteDir(io(), dst) catch {};
            } else {
                fsutil.removePath(dst) catch {};
            }
            _ = prev.remove(rel);
        }
        const back = &w.delivered[to][from];
        for (gone.items) |rel| _ = back.remove(rel);
        var cit = cur.iterator();
        while (cit.next()) |kv| try prev.put(w.a, kv.key_ptr.*, kv.value_ptr.*);
        for (changed.items) |rel| try back.put(w.a, rel, cur.get(rel).?);
    }

    pub fn deliver(w: *World, from: usize, to: usize) !void {
        return w.deliverPath(from, to, "");
    }

    /// Delivers every online machine's changes to every other online
    /// machine, twice over so a change relayed through a third arrives.
    pub fn sync(w: *World) !void {
        for (0..2) |_| {
            for (0..w.machines.len) |from| {
                for (0..w.machines.len) |to| {
                    if (from == to or w.offline[from] or w.offline[to]) continue;
                    try w.deliver(from, to);
                }
            }
        }
    }
};

test "World: delivery is per sender and receiver, can be withheld, and carries deletions, the receiver's of what it received included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 3);

    const f = try std.fs.path.join(a, &.{ w.m(0).synced, "kept", "x", "f" });
    try fsutil.ensureDir(std.fs.path.dirname(f).?);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = f, .data = "one" });

    w.offline[2] = true;
    try testing.expectError(error.Offline, w.deliver(0, 2));
    try w.sync();
    const at_b = try std.fs.path.join(a, &.{ w.m(1).synced, "kept", "x", "f" });
    const at_c = try std.fs.path.join(a, &.{ w.m(2).synced, "kept", "x", "f" });
    try testing.expectEqualStrings("one", try content.readSmall(a, at_b));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(at_c));

    w.offline[2] = false;
    try std.Io.Dir.cwd().deleteFile(io(), f);
    try w.deliver(0, 1);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(at_b));
    try w.deliver(0, 2);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(at_c));

    const g = try std.fs.path.join(a, &.{ w.m(0).synced, "kept", "x", "g" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = g, .data = "from a" });
    try w.deliver(0, 1);
    try std.Io.Dir.cwd().deleteFile(io(), try std.fs.path.join(a, &.{ w.m(1).synced, "kept", "x", "g" }));
    try w.deliver(1, 0);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(g));
}
