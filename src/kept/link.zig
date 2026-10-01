//! The clone side of a kept path: which links are holt's, what sits at the
//! path, and whether every parent component is a real directory.

const std = @import("std");
const builtin = @import("builtin");
const fsutil = @import("../fsutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const testing = std.testing;

pub const Side = union(enum) {
    absent,
    /// A link to the kept copy of the path in the resolved key under the
    /// current synced root; carries the raw target.
    right: []const u8,
    /// holt's link to the path in another key of the chain or under
    /// another synced root; carries the raw target.
    holt: []const u8,
    /// A link holt did not make; carries the raw target.
    foreign: []const u8,
    /// A regular file, a directory, or something else.
    local: content.Entry,
};

/// The target, normalized to `/` separators, of a link found in a clone.
fn slashed(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const t = try fsutil.normalizeTarget(alloc, raw);
    if (builtin.os.tag != .windows) return t;
    const out = try alloc.dupe(u8, t);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn endsWithNormalized(alloc: std.mem.Allocator, s: []const u8, suffix: []const u8) bool {
    if (std.mem.endsWith(u8, s, suffix)) return true;
    const ns = paths.nfd(alloc, s) catch return false;
    const nx = paths.nfd(alloc, suffix) catch return false;
    return std.mem.endsWith(u8, ns, nx);
}

fn eqlNormalized(alloc: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const na = paths.nfd(alloc, a) catch return false;
    const nb = paths.nfd(alloc, b) catch return false;
    return std.mem.eql(u8, na, nb);
}

/// True when the link at `link_path`, whose raw target is `raw`, is holt's
/// (`rootOf`). Any other link is the user's, whatever its target's shape.
pub fn isHolt(alloc: std.mem.Allocator, link_path: []const u8, raw: []const u8, chain: []const []const u8, roots: []const []const u8, rel: []const u8) bool {
    return rootOf(alloc, link_path, raw, chain, roots, rel) != null;
}

/// Whether the directory `dir`, at `rel` of its working tree, holds
/// nothing but directories and holt's links (`isHolt` under `chain`), each
/// the link of the path it stands at, and at least one link: what another
/// machine or working tree holds of a directory kept file by file before
/// it was kept whole. Such links hold no content. False when anything
/// cannot be read.
pub fn onlyHoltLinks(alloc: std.mem.Allocator, dir: []const u8, chain: []const []const u8, roots: []const []const u8, rel: []const u8) !bool {
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(alloc, "");
    var any = false;
    while (pending.pop()) |sub| {
        const here = if (sub.len == 0) dir else try fsutil.joinSlashy(alloc, dir, sub);
        var d = std.Io.Dir.cwd().openDir(fsutil.io(), here, .{ .iterate = true }) catch return false;
        defer d.close(fsutil.io());
        var it = d.iterate();
        while (it.next(fsutil.io()) catch return false) |e| {
            const name = if (sub.len == 0) try alloc.dupe(u8, e.name) else try std.mem.concat(alloc, u8, &.{ sub, "/", e.name });
            switch (e.kind) {
                .directory => try pending.append(alloc, name),
                .sym_link => {
                    const lp = try fsutil.joinSlashy(alloc, dir, name);
                    const raw = (content.readLink(alloc, lp) catch return false) orelse return false;
                    if (!isHolt(alloc, lp, raw, chain, roots, try std.mem.concat(alloc, u8, &.{ rel, "/", name }))) return false;
                    any = true;
                },
                else => return false,
            }
        }
    }
    return any;
}

/// The synced root a holt link's target was made under: the link at
/// `link_path` with raw target `raw` is holt's when its target, taken from
/// the link's directory when relative, is `<root>/kept/<k>/<rel>` for a
/// key `k` in `chain` and a synced root `root` holt's store has lived at:
/// one in `roots` (the current one and every one the store records,
/// `store.syncedRoots`), or one whose own `kept/` records it
/// (`store.recordsRoot`), as after a backend switch that left `kept/`
/// behind; compared after Unicode normalization. That root is returned.
/// Null when the link is not holt's.
pub fn rootOf(alloc: std.mem.Allocator, link_path: []const u8, raw: []const u8, chain: []const []const u8, roots: []const []const u8, rel: []const u8) ?[]const u8 {
    const t = slashed(alloc, resolveTarget(alloc, link_path, raw) catch return null) catch return null;
    for (chain) |k| {
        const prefix = rootPrefix(alloc, t, k, rel) orelse continue;
        for (roots) |r| if (sameRoot(alloc, prefix, r)) return r;
        const native = alloc.dupe(u8, prefix) catch return null;
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, native, '/', std.fs.path.sep);
        if (store.recordsRoot(alloc, native) catch false) return native;
    }
    return null;
}

/// What the link at `link_path` with raw target `raw` would take for its
/// synced root were it holt's: its target, taken from the link's directory
/// when relative, with `/kept/<k>/<rel>` for a key `k` in `chain` dropped,
/// in native separators. Only the shape is judged; `rootOf` also asks
/// that the root be one the store has lived at.
pub fn shapeRoot(alloc: std.mem.Allocator, link_path: []const u8, raw: []const u8, chain: []const []const u8, rel: []const u8) ?[]const u8 {
    const t = slashed(alloc, resolveTarget(alloc, link_path, raw) catch return null) catch return null;
    for (chain) |k| {
        const prefix = rootPrefix(alloc, t, k, rel) orelse continue;
        const root = alloc.dupe(u8, prefix) catch return null;
        if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, root, '/', std.fs.path.sep);
        return root;
    }
    return null;
}

/// `t`, a `/`-separated target, without its `/kept/<k>/<rel>` ending,
/// compared after Unicode normalization; null when it does not end so.
fn rootPrefix(alloc: std.mem.Allocator, t: []const u8, k: []const u8, rel: []const u8) ?[]const u8 {
    const suffix = std.fmt.allocPrint(alloc, "/kept/{s}/{s}", .{ k, rel }) catch return null;
    if (!endsWithNormalized(alloc, t, suffix)) return null;
    var end = t.len;
    for (0..std.mem.count(u8, suffix, "/")) |_| end = std.mem.lastIndexOfScalar(u8, t[0..end], '/') orelse return null;
    return t[0..end];
}

/// True when two synced roots name the same directory, compared as link
/// targets are: separators and Unicode normalization aside.
pub fn sameRoot(alloc: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    const sa = slashed(alloc, a) catch return false;
    const sb = slashed(alloc, b) catch return false;
    return eqlNormalized(alloc, std.mem.trimEnd(u8, sa, "/"), std.mem.trimEnd(u8, sb, "/"));
}

/// The path the link at `link_path` with raw target `raw` names: `raw`
/// itself when absolute, else `raw` taken from the link's directory.
pub fn resolveTarget(alloc: std.mem.Allocator, link_path: []const u8, raw: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(raw)) return raw;
    return std.fs.path.resolve(alloc, &.{ std.fs.path.dirname(link_path) orelse ".", raw });
}

/// What is at `<worktree>/<rel>`, judged against the link target `want`.
pub fn classify(alloc: std.mem.Allocator, clone_path: []const u8, want: []const u8, chain: []const []const u8, roots: []const []const u8, rel: []const u8) !Side {
    const e = try content.entryAt(clone_path);
    if (e != .symlink) return if (e == .absent) .absent else .{ .local = e };
    const raw = (try content.readLink(alloc, clone_path)) orelse return .absent;
    if (try fsutil.targetsEqual(alloc, raw, want)) return .{ .right = raw };
    if (eqlNormalized(alloc, try slashed(alloc, raw), try slashed(alloc, want))) return .{ .right = raw };
    if (isHolt(alloc, clone_path, raw, chain, roots, rel)) return .{ .holt = raw };
    return .{ .foreign = raw };
}

/// True when every component between `worktree` and `rel`'s last one is a
/// real directory or absent, checked without following links.
pub fn parentsReal(alloc: std.mem.Allocator, worktree: []const u8, rel: []const u8) !bool {
    var cur: []const u8 = worktree;
    var it = std.mem.splitScalar(u8, rel, '/');
    var comp = it.next() orelse return true;
    while (it.next()) |next| {
        cur = try std.fs.path.join(alloc, &.{ cur, comp });
        switch (try content.entryAt(cur)) {
            .dir => {},
            .absent => return true,
            else => return false,
        }
        comp = next;
    }
    return true;
}

const Fixture = @import("harness.zig").Fixture;

fn pointAt(target: []const u8, lp: []const u8) !void {
    try fsutil.removePath(lp);
    try content.createLink(target, lp, .file);
}

test "classify and isHolt: the right link, a chain key's link, a recorded root's link, and the user's links of holt's shape" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const root = f.root;
    const layout: store.Layout = .{ .synced_root = try std.fs.path.join(a, &.{ root, "synced" }) };
    const other: store.Layout = .{ .synced_root = try std.fs.path.join(a, &.{ root, "old-backend" }) };
    const roots = [_][]const u8{ layout.synced_root, other.synced_root };
    const chain = [_][]const u8{ "github.com/new/widget", "github.com/old/widget" };
    const want = try layout.copyPath(a, chain[0], ".clasp.json");
    const lp = try std.fs.path.join(a, &.{ root, "link" });

    try testing.expect((try classify(a, lp, want, &chain, &roots, ".clasp.json")) == .absent);
    try content.createLink(want, lp, .file);
    try testing.expect((try classify(a, lp, want, &chain, &roots, ".clasp.json")) == .right);

    try pointAt(try layout.copyPath(a, chain[1], ".clasp.json"), lp);
    try testing.expect((try classify(a, lp, want, &chain, &roots, ".clasp.json")) == .holt);

    try pointAt(try other.copyPath(a, chain[0], ".clasp.json"), lp);
    try testing.expect((try classify(a, lp, want, &chain, &roots, ".clasp.json")) == .holt);
    try testing.expectEqualStrings(other.synced_root, rootOf(a, lp, (try content.readLink(a, lp)).?, &chain, &roots, ".clasp.json").?);
    try testing.expect((try classify(a, lp, want, &chain, roots[0..1], ".clasp.json")) == .foreign);

    const mine = try std.fs.path.join(a, &.{ root, "my-notes", "kept", chain[0], ".clasp.json" });
    try pointAt(mine, lp);
    try testing.expect((try classify(a, lp, want, &chain, &roots, ".clasp.json")) == .foreign);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "my-notes" }), shapeRoot(a, lp, mine, &chain, ".clasp.json").?);

    try pointAt(try other.copyPath(a, "github.com/unrelated/x", ".clasp.json"), lp);
    try testing.expect((try classify(a, lp, want, &chain, &roots, ".clasp.json")) == .foreign);
    try pointAt(try layout.copyPath(a, chain[0], "other.json"), lp);
    try testing.expect((try classify(a, lp, want, &chain, &roots, ".clasp.json")) == .foreign);

    try testing.expect(isHolt(a, "/l", "/x/kept/github.com/new/widget/caf\u{e9}", &chain, &.{"/x"}, "cafe\u{301}"));
    try testing.expect(!isHolt(a, "/l", "/x/kept/github.com/new/widget/caf\u{e9}", &chain, &.{"/y"}, "cafe\u{301}"));
}

test "rootOf: agrees with isHolt across normalization, resolves a relative target from the link's directory, and names the recorded root" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const chain = [_][]const u8{"github.com/new/widget"};
    try testing.expectEqualStrings("/Drive/root", rootOf(a, "/l", "/Drive/root/kept/github.com/new/widget/caf\u{e9}", &chain, &.{"/Drive/root"}, "cafe\u{301}").?);
    try testing.expectEqualStrings("/r", rootOf(a, "/l", "/r/kept/github.com/new/widget/d/e", &chain, &.{ "/q", "/r/" }, "d/e").?[0..2]);
    try testing.expectEqualStrings("/r", rootOf(a, "/r/clone/d/e", "../../kept/github.com/new/widget/d/e", &chain, &.{"/r"}, "d/e").?);
    try testing.expect(rootOf(a, "/l", "/r/kept/github.com/other/widget/d", &chain, &.{"/r"}, "d") == null);
    try testing.expect(sameRoot(a, "/Drive/caf\u{e9}", "/Drive/cafe\u{301}/"));
    try testing.expect(!sameRoot(a, "/Drive/a", "/Drive/b"));
}

test "parentsReal: refuses a symlinked or file parent, accepts absent and real ones" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.alloc();
    const root = f.root;

    try fsutil.ensureDir(try std.fs.path.join(a, &.{ root, "real", "sub" }));
    try content.createLink(try std.fs.path.join(a, &.{ root, "real" }), try std.fs.path.join(a, &.{ root, "ln" }), .dir);
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ root, "file" }), .data = "" });

    try testing.expect(try parentsReal(a, root, "top"));
    try testing.expect(try parentsReal(a, root, "real/sub/x"));
    try testing.expect(try parentsReal(a, root, "missing/deeper/x"));
    try testing.expect(!try parentsReal(a, root, "ln/sub/x"));
    try testing.expect(!try parentsReal(a, root, "file/x"));
}
