//! Reconcile, keep, and the released rule exercised across simulated
//! machines sharing one synced root.

const std = @import("std");
const builtin = @import("builtin");
const fsutil = @import("../fsutil.zig");
const git = @import("../git.zig");
const testutil = @import("../testutil.zig");
const paths = @import("paths.zig");
const content = @import("content.zig");
const store = @import("store.zig");
const aside = @import("aside.zig");
const block = @import("block.zig");
const clone = @import("clone.zig");
const place = @import("place.zig");
const ops = @import("ops.zig");
const reconcile_mod = @import("reconcile.zig");
const harness = @import("harness.zig");
const interrupt = @import("interrupt.zig");
const ctx_mod = @import("ctx.zig");
const testing = std.testing;

const io = fsutil.io;
const World = harness.World;
const Machine = harness.Machine;
const key = harness.repo_key;

fn expectItem(report: reconcile_mod.Report, rel: []const u8, outcome: reconcile_mod.Outcome) !reconcile_mod.Item {
    if (report.find(rel, outcome)) |i| return i;
    std.debug.print("no {s} item for {s}; items:\n", .{ @tagName(outcome), rel });
    for (report.items) |i| std.debug.print("  {s}: state {?d} {s}\n", .{ i.rel, i.state, @tagName(i.outcome) });
    return error.TestUnexpectedResult;
}

fn gitStatus(m: *const Machine) ![]const u8 {
    const res = try git.runInRepo(m.ctx.alloc, &.{ "status", "--porcelain", "--untracked-files=all" }, m.clone);
    return res.stdout;
}

fn blockRels(m: *const Machine) ![]const []const u8 {
    const c = try clone.inspect(m.ctx.alloc, m.clone, m.ctx.code_root);
    return (try block.read(m.ctx.alloc, c.common_dir)).rels;
}

test "keep on A, restore on B: B links identical bytes after delivery, and an edit through B's link reaches A" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);

    try ma.write(".clasp.json", "{\"scriptId\": \"abc\"}");
    try ma.write(".superpowers/notes.md", "notes");
    try ma.write(".superpowers/deep/plan.md", "plan");
    _ = try ma.keep(".clasp.json");
    _ = try ma.keep(".superpowers");
    try testing.expect(try ma.linked(".clasp.json"));
    try testing.expect(try ma.linked(".superpowers"));
    try testing.expectEqualStrings("", try gitStatus(ma));
    try testing.expectEqual(.already_kept, (try ma.keep(".clasp.json")).status);

    try testing.expectEqual(reconcile_mod.Stop.store_absent, (try mb.reconcile()).stop);

    try w.deliver(0, 1);
    const rb = try mb.reconcile();
    try testing.expectEqual(reconcile_mod.Stop.none, rb.stop);
    try testing.expect((try expectItem(rb, ".clasp.json", .linked)).done);
    try testing.expect((try expectItem(rb, ".superpowers", .linked)).done);
    try testing.expectEqual(@as(usize, 0), rb.unsettledCount());
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try mb.read(".clasp.json"));
    try testing.expectEqualStrings("plan", try mb.read(".superpowers/deep/plan.md"));
    try testing.expectEqualStrings("", try gitStatus(mb));

    const again = try mb.reconcile();
    _ = try expectItem(again, ".clasp.json", .ok);
    try testing.expect(!again.block_written);

    try mb.write(".clasp.json", "{\"scriptId\": \"edited\"}");
    try mb.write(".superpowers/new.md", "created inside the kept directory");
    try w.deliver(1, 0);
    try testing.expectEqualStrings("{\"scriptId\": \"edited\"}", try ma.read(".clasp.json"));
    try testing.expectEqualStrings("created inside the kept directory", try ma.read(".superpowers/new.md"));
    try testing.expectEqual(@as(usize, 0), (try ma.reconcile()).unsettledCount());
}

/// Machines A and B each keep a different `.clasp.json` while B is offline;
/// C is online with A throughout.
fn keepOnTwoMachines(w: *World) !void {
    w.offline[1] = true;
    try w.m(0).write(".clasp.json", "from A");
    _ = try w.m(0).keep(".clasp.json");
    try w.deliver(0, 2);
    try w.m(1).write(".clasp.json", "from B");
    _ = try w.m(1).keep(".clasp.json");
    w.offline[1] = false;
}

/// After full delivery, every machine reports the two keeps with both
/// versions in aside and stays linked.
fn expectTwoMachinesEverywhere(w: *World) !void {
    try w.sync();
    for (w.machines) |*m| {
        const a = m.ctx.alloc;
        const item = try expectItem(try m.reconcile(), ".clasp.json", .two_machines);
        try testing.expect(item.unsettled);
        try testing.expectEqual(@as(usize, 2), item.entries.len);
        var seen_a = false;
        var seen_b = false;
        for (item.entries) |stamp| {
            const data = try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, stamp, ".clasp.json"));
            if (std.mem.eql(u8, data, "from A")) seen_a = true;
            if (std.mem.eql(u8, data, "from B")) seen_b = true;
        }
        try testing.expect(seen_a and seen_b);
        try testing.expect(try m.linked(".clasp.json"));
    }
}

test "two machines keep different content, facts delivered first: the first reconcile reports it with the aside entry it has" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 3);
    try keepOnTwoMachines(&w);

    try w.deliverPath(1, 0, key ++ "/.holt-paths");
    const item = try expectItem(try w.m(0).reconcile(), ".clasp.json", .two_machines);
    try testing.expect(item.unsettled);
    try testing.expectEqual(@as(usize, 1), item.entries.len);
    try testing.expectEqualStrings("from A", try w.m(0).read(".clasp.json"));
    try expectTwoMachinesEverywhere(&w);
}

test "two machines keep different content, content delivered first: nothing is reported until the facts arrive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 3);
    try keepOnTwoMachines(&w);

    try w.deliverPath(1, 0, key ++ "/.clasp.json");
    const early = try w.m(0).reconcile();
    _ = try expectItem(early, ".clasp.json", .ok);
    try testing.expectEqual(@as(usize, 0), early.unsettledCount());
    try testing.expectEqualStrings("from B", try w.m(0).read(".clasp.json"));

    try w.deliverPath(1, 0, key ++ "/.holt-paths");
    const item = try expectItem(try w.m(0).reconcile(), ".clasp.json", .two_machines);
    try testing.expectEqual(@as(usize, 1), item.entries.len);
    try expectTwoMachinesEverywhere(&w);
}

test "a rename-saving tool breaks the link: reconcile sets the new content aside once and leaves it; identical content is relinked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".clasp.json", "v1");
    _ = try m.keep(".clasp.json");
    try m.saveByRename(".clasp.json", "v2");

    const r = try m.reconcile();
    const item = try expectItem(r, ".clasp.json", .local_differs);
    try testing.expect(item.unsettled and item.done);
    try testing.expectEqualStrings("v2", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, ".clasp.json")));
    try testing.expectEqualStrings("v2", try m.read(".clasp.json"));
    try testing.expectEqualStrings("v1", try content.readSmall(a, try m.keptPath(".clasp.json")));
    try testing.expectEqualStrings("", try gitStatus(m));

    const again = try expectItem(try m.reconcile(), ".clasp.json", .local_differs);
    try testing.expectEqualStrings(item.entry.?, again.entry.?);

    try m.git(&sb, &.{ "clean", "-fdxq" });
    try testing.expectEqual(content.Entry.absent, try m.entry(".clasp.json"));
    try testing.expectEqualStrings("v2", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, ".clasp.json")));
    try testing.expect((try expectItem(try m.reconcile(), ".clasp.json", .linked)).done);

    try m.saveByRename(".clasp.json", "v1");
    try testing.expect((try expectItem(try m.reconcile(), ".clasp.json", .relinked)).done);
    try testing.expect(try m.linked(".clasp.json"));
}

test "a branch tracking the path: nothing is linked while it is tracked, a stray link there is removed, and switching back relinks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".clasp.json", "kept");
    _ = try m.keep(".clasp.json");

    try m.git(&sb, &.{ "checkout", "-q", "-b", "tracking" });
    try fsutil.removePath(try m.path(".clasp.json"));
    try m.write(".clasp.json", "committed");
    try m.git(&sb, &.{ "add", "-f", ".clasp.json" });
    try m.git(&sb, &.{ "commit", "-q", "-m", "track it" });

    const r = try m.reconcile();
    const t = try expectItem(r, ".clasp.json", .tracked);
    try testing.expect(!t.unsettled);
    try testing.expectEqualStrings("committed", try m.read(".clasp.json"));

    try fsutil.removePath(try m.path(".clasp.json"));
    try content.createLink(try m.keptPath(".clasp.json"), try m.path(".clasp.json"), .file);
    try testing.expect((try expectItem(try m.reconcile(), ".clasp.json", .tracked_link_removed)).done);
    try testing.expectEqual(content.Entry.absent, try m.entry(".clasp.json"));
    try m.git(&sb, &.{ "checkout", "-q", "--", ".clasp.json" });

    try m.git(&sb, &.{ "checkout", "-q", "main" });
    try testing.expectEqual(content.Entry.absent, try m.entry(".clasp.json"));
    try testing.expect((try expectItem(try m.reconcile(), ".clasp.json", .linked)).done);
    try testing.expectEqualStrings("kept", try m.read(".clasp.json"));
}

test "kept copy absent: a dangling link no fact names is removed and its line dropped; a kept copy deleted on the machine that kept it is not_arrived here, and local content set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);

    try ma.write(".clasp.json", "kept");
    try ma.write(".env", "secret");
    _ = try ma.keep(".clasp.json");
    _ = try ma.keep(".env");
    try w.deliver(0, 1);
    _ = try mb.reconcile();

    const c = try clone.inspect(a, mb.clone, mb.ctx.code_root);
    _ = try block.write(a, c.common_dir, &.{ ".clasp.json", ".env", ".stale" });
    try content.createLink(try mb.keptPath(".stale"), try mb.path(".stale"), .file);
    const r1 = try mb.reconcile();
    try testing.expect((try expectItem(r1, ".stale", .dangling_removed)).done);
    try testing.expectEqual(content.Entry.absent, try mb.entry(".stale"));
    try testing.expect(!paths.contains(try blockRels(mb), ".stale"));

    try std.Io.Dir.cwd().deleteFile(io(), try ma.keptPath(".clasp.json"));
    try std.Io.Dir.cwd().deleteFile(io(), try ma.keptPath(".env"));
    try w.deliver(0, 1);
    try fsutil.removePath(try mb.path(".env"));
    try mb.write(".env", "local only");

    const r2 = try mb.reconcile();
    const missing = try expectItem(r2, ".clasp.json", .not_arrived);
    try testing.expect(missing.unsettled);
    try testing.expectEqualStrings(ma.ctx.machine_id, missing.detail.?);
    try testing.expectEqual(content.Entry.symlink, try mb.entry(".clasp.json"));
    const local = try expectItem(r2, ".env", .not_arrived);
    try testing.expect(local.unsettled and local.done);
    try testing.expectEqualStrings("local only", try mb.read(".env"));
    try testing.expectEqualStrings("local only", try content.readSmall(a, try aside.dataPath(a, mb.ctx.layout, local.entry.?, ".env")));
    try testing.expect(paths.contains(try blockRels(mb), ".clasp.json"));
    try testing.expect(paths.contains(try blockRels(mb), ".env"));
    try testing.expectEqualStrings("", try gitStatus(mb));
}

test "links made under another synced root: retargeted when the old copy is gone or identical, set aside first when it differs, reported when the new root lacks it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("same", "s");
    try m.write("changed", "old");
    try m.write("gone", "g");
    try m.write("uncopied", "u");
    for ([_][]const u8{ "same", "changed", "gone", "uncopied" }) |rel| _ = try m.keep(rel);

    const new_root = try std.fs.path.join(a, &.{ sb.root, "machine", "a", "new-backend" });
    try content.copyRegular(a, try m.ctx.layout.keptDir(a), try std.fs.path.join(a, &.{ new_root, "kept" }));
    const old: store.Layout = m.ctx.layout;
    var moved = m.ctx;
    moved.layout = .{ .synced_root = new_root };
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try moved.layout.copyPath(a, key, "changed"), .data = "new" });
    try std.Io.Dir.cwd().deleteFile(io(), try old.copyPath(a, key, "gone"));
    try std.Io.Dir.cwd().deleteFile(io(), try moved.layout.copyPath(a, key, "uncopied"));
    try store.removeFacts(a, moved.layout, key, "gone");
    try store.writeFact(a, moved.layout, key, m.ctx.machine_id, "gone", .file, &(try content.hashPath(a, try moved.layout.copyPath(a, key, "same"))).hex);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try moved.layout.copyPath(a, key, "gone"), .data = "s" });

    const r = try harness.reconcileIn(moved, m.clone, .apply);
    try testing.expect((try expectItem(r, "same", .retargeted)).done);
    try testing.expect((try expectItem(r, "gone", .retargeted)).done);
    const differs = try expectItem(r, "changed", .old_differs);
    try testing.expect(differs.unsettled and differs.done);
    try testing.expectEqualStrings("old", try content.readSmall(a, try aside.dataPath(a, moved.layout, differs.entry.?, "changed")));
    try testing.expectEqualStrings("new", try m.read("changed"));
    const uncopied = try expectItem(r, "uncopied", .in_old_root);
    try testing.expectEqualStrings(old.synced_root, uncopied.detail.?);
    try testing.expectEqualStrings("old", try content.readSmall(a, try old.copyPath(a, key, "changed")));
    const want = try moved.layout.copyPath(a, key, "same");
    try testing.expectEqualStrings(want, (try content.readLink(a, try m.path("same"))).?);
}

test "a kept copy that is a symlink or of the wrong kind, and a link holt did not make, are never linked or replaced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("sym", "s");
    try m.write("kind", "k");
    try m.write("foreign", "f");
    for ([_][]const u8{ "sym", "kind", "foreign" }) |rel| _ = try m.keep(rel);

    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath("sym"));
    try content.createLink("/etc/hosts", try m.keptPath("sym"), .file);
    try fsutil.removePath(try m.path("sym"));
    try m.write("sym", "local");
    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath("kind"));
    try fsutil.ensureDir(try m.keptPath("kind"));
    try fsutil.removePath(try m.path("kind"));
    try fsutil.removePath(try m.path("foreign"));
    // Windows reads a link's target back with its own separator.
    const elsewhere = std.fs.path.sep_str ++ "somewhere" ++ std.fs.path.sep_str ++ "else";
    try content.createLink(elsewhere, try m.path("foreign"), .file);

    const r = try m.reconcile();
    const sym = try expectItem(r, "sym", .kept_not_regular);
    try testing.expect(sym.unsettled and sym.entry != null);
    try testing.expectEqualStrings("local", try m.read("sym"));
    try testing.expect((try expectItem(r, "kind", .kind_mismatch)).unsettled);
    try testing.expectEqual(content.Entry.absent, try m.entry("kind"));
    const foreign = try expectItem(r, "foreign", .foreign_link);
    try testing.expectEqualStrings(elsewhere, foreign.detail.?);
    try testing.expectEqualStrings(elsewhere, (try content.readLink(a, try m.path("foreign"))).?);
}

test "released: every machine turns its link into a regular copy, the kept content stays, and the line goes once no link is left" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);

    try ma.write(".clasp.json", "file");
    try ma.write(".superpowers/a.md", "dir");
    _ = try ma.keep(".clasp.json");
    _ = try ma.keep(".superpowers");
    try w.deliver(0, 1);
    _ = try mb.reconcile();

    try store.writeReleased(a, ma.ctx.layout, key, ".clasp.json");
    try store.writeReleased(a, ma.ctx.layout, key, ".superpowers");
    for ([_]*Machine{ ma, mb }, 0..) |m, i| {
        if (i == 1) try w.deliver(0, 1);
        const r = try m.reconcile();
        try testing.expect((try expectItem(r, ".clasp.json", .released_converted)).done);
        try testing.expect((try expectItem(r, ".superpowers", .released_converted)).done);
        try testing.expectEqual(content.Entry.file, try m.entry(".clasp.json"));
        try testing.expectEqual(content.Entry.dir, try m.entry(".superpowers"));
        try testing.expectEqualStrings("file", try m.read(".clasp.json"));
        try testing.expectEqualStrings("dir", try m.read(".superpowers/a.md"));
        try testing.expectEqualStrings("file", try content.readSmall(a, try m.keptPath(".clasp.json")));
        try testing.expectEqual(@as(usize, 0), (try blockRels(m)).len);
        const status = try gitStatus(m);
        try testing.expect(std.mem.indexOf(u8, status, "?? .clasp.json") != null);
        try testing.expect(std.mem.indexOf(u8, status, "?? .superpowers/a.md") != null);
        _ = try expectItem(try m.reconcile(), ".clasp.json", .released_local);
    }
}

test "block lines across working trees: a released path keeps its line while another working tree still links it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".clasp.json", "kept");
    _ = try m.keep(".clasp.json");
    const wt_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.clone).?, "widget@worktrees", "feature" });
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "feature", wt_path });
    const wt = try fsutil.realPathOrSelf(a, try std.fs.path.resolve(a, &.{wt_path}));

    try testing.expect((try expectItem(try harness.reconcileIn(m.ctx, wt, .apply), ".clasp.json", .linked)).done);

    try store.writeReleased(a, m.ctx.layout, key, ".clasp.json");
    _ = try expectItem(try m.reconcile(), ".clasp.json", .released_converted);
    try testing.expect(paths.contains(try blockRels(m), ".clasp.json"));
    _ = try expectItem(try harness.reconcileIn(m.ctx, wt, .apply), ".clasp.json", .released_converted);
    try testing.expect(!paths.contains(try blockRels(m), ".clasp.json"));
}

test "delivery order: a fact before its content links nothing and is not_arrived until the content arrives; content before its fact is an unknown file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 3);

    try w.m(0).write(".clasp.json", "kept");
    _ = try w.m(0).keep(".clasp.json");

    try w.deliverPath(0, 1, key ++ "/.holt-kept.json");
    try w.deliverPath(0, 1, key ++ "/.holt-paths");
    const early = try w.m(1).reconcile();
    const np = try expectItem(early, ".clasp.json", .not_arrived);
    try testing.expect(np.unsettled);
    try testing.expectEqualStrings(w.m(0).ctx.machine_id, np.detail.?);
    try testing.expectEqual(content.Entry.absent, try w.m(1).entry(".clasp.json"));
    try w.deliver(0, 1);
    try testing.expect((try expectItem(try w.m(1).reconcile(), ".clasp.json", .linked)).done);

    try w.deliverPath(0, 2, key ++ "/.holt-kept.json");
    try w.deliverPath(0, 2, key ++ "/.clasp.json");
    const r = try w.m(2).reconcile();
    try testing.expectEqual(@as(usize, 0), r.items.len);
    try testing.expectEqual(@as(usize, 1), r.unknown.len);
    try testing.expectEqualStrings(".clasp.json", r.unknown[0]);
    try testing.expectEqual(content.Entry.absent, try w.m(2).entry(".clasp.json"));
}

test "modes: plan writes nothing, fix links but never sets content aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const mb = w.m(1);

    try w.m(0).write("linkme", "l");
    try w.m(0).write("differs", "kept");
    _ = try w.m(0).keep("linkme");
    _ = try w.m(0).keep("differs");
    try w.deliver(0, 1);
    try mb.write("differs", "local");

    const plan = try harness.reconcileIn(mb.ctx, mb.clone, .plan);
    try testing.expect(!(try expectItem(plan, "linkme", .linked)).done);
    try testing.expect(!(try expectItem(plan, "differs", .local_differs)).done);
    try testing.expectEqual(content.Entry.absent, try mb.entry("linkme"));
    try testing.expectEqual(@as(usize, 0), (try blockRels(mb)).len);
    const local_hash = try content.hashPath(a, try mb.path("differs"));
    try testing.expectEqual(@as(usize, 0), (try aside.findEntries(a, mb.ctx.layout, key, "differs", &local_hash.hex)).len);

    const fix = try harness.reconcileIn(mb.ctx, mb.clone, .fix);
    try testing.expect((try expectItem(fix, "linkme", .linked)).done);
    const d = try expectItem(fix, "differs", .local_differs);
    try testing.expect(!d.done and d.entry == null and d.unsettled);
    try testing.expectEqual(@as(usize, 0), (try aside.findEntries(a, mb.ctx.layout, key, "differs", &local_hash.hex)).len);
}

test "store problems stop reconcile before it evaluates anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".clasp.json", "kept");
    _ = try m.keep(".clasp.json");
    try fsutil.removePath(try m.path(".clasp.json"));

    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const exclude = try block.excludePath(a, c.common_dir);
    const good = try content.readSmall(a, exclude);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = exclude, .data = block.begin_line ++ "\n" });
    try testing.expectEqual(reconcile_mod.Stop.block_unbalanced, (try m.reconcile()).stop);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = exclude, .data = good });

    const rec = try store.Layout.reserved(m.ctx.layout, a, key, store.record_basename);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = rec, .data = "{\"version\": 99}" });
    try testing.expectEqual(reconcile_mod.Stop.unknown_version, (try m.reconcile()).stop);
    try testing.expectEqual(content.Entry.absent, try m.entry(".clasp.json"));
}

test "keep interrupted at every point: the content stays in place, in kept, or in aside; reconcile reports or finishes it; rerunning keep finishes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;
    try m.write("seed", "creates the store");
    _ = try m.keep("seed");

    const cases = [_]struct { point: interrupt.Point, then: reconcile_mod.Outcome }{
        .{ .point = .keep_pending, .then = .interrupted },
        .{ .point = .keep_key, .then = .interrupted },
        .{ .point = .keep_block, .then = .interrupted },
        .{ .point = .aside_copied, .then = .interrupted },
        .{ .point = .aside_manifest, .then = .interrupted },
        .{ .point = .keep_aside, .then = .interrupted },
        .{ .point = .keep_fact, .then = .interrupted },
        .{ .point = .stage_copied, .then = .interrupted },
        .{ .point = .place_parents, .then = .interrupted },
        .{ .point = .keep_place, .then = .relinked },
        .{ .point = .link_moved, .then = .relinked },
        .{ .point = .link_created, .then = .ok },
        .{ .point = .keep_link, .then = .ok },
        .{ .point = .keep_clear, .then = .ok },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |as_dir| {
            const name = @tagName(case.point);
            const rel = try std.fmt.allocPrint(a, "{s}-{s}", .{ name, if (as_dir) "dir" else "file" });
            const probe = if (as_dir) try std.fmt.allocPrint(a, "{s}/inner", .{rel}) else rel;
            try m.write(probe, name);

            interrupt.at = case.point;
            try testing.expectError(error.Interrupted, m.keep(rel));
            interrupt.at = null;
            try testing.expect(try heldSomewhere(m, rel, probe, name));

            const r = try m.reconcile();
            const item = try expectItem(r, rel, case.then);
            if (case.then == .interrupted) {
                try testing.expect(item.unsettled);
                try testing.expectEqual(clone.Op.keep, item.op.?);
            }
            try testing.expectEqualStrings(name, try m.read(probe));

            _ = try m.keep(rel);
            _ = try expectItem(try m.reconcile(), rel, .ok);
            try testing.expect(try m.linked(rel));
            try testing.expectEqualStrings(name, try m.read(probe));
            try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, rel)));
        }
    }
    try testing.expectEqualStrings("", try gitStatus(m));
}

/// True when `data` is readable at `probe` of `rel` in the clone, in the
/// kept copy, or in a verified aside entry: somewhere an interruption left
/// it that holt can find again.
fn heldSomewhere(m: *const Machine, rel: []const u8, probe: []const u8, data: []const u8) !bool {
    const a = m.ctx.alloc;
    if (m.read(probe)) |got| {
        if (std.mem.eql(u8, got, data)) return true;
    } else |_| {}
    if (content.readSmall(a, try m.keptPath(probe))) |got| {
        if (std.mem.eql(u8, got, data)) return true;
    } else |_| {}
    const tmp = try m.path(try paths.tempRel(a, rel));
    const in_tmp = try fsutil.joinSlashy(a, tmp, probe[rel.len..]);
    if (content.readSmall(a, if (probe.len == rel.len) tmp else in_tmp)) |got| {
        if (std.mem.eql(u8, got, data)) return true;
    } else |_| {}
    var d = std.Io.Dir.cwd().openDir(io(), try m.ctx.layout.asideDir(a), .{ .iterate = true }) catch return false;
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        const m_ = (try aside.readManifest(a, m.ctx.layout, e.name)) orelse continue;
        if (!std.mem.eql(u8, m_.rel, rel) or try aside.verify(a, m.ctx.layout, e.name) != .ok) continue;
        if (content.readSmall(a, try aside.dataPath(a, m.ctx.layout, e.name, probe))) |got| {
            if (std.mem.eql(u8, got, data)) return true;
        } else |_| {}
    }
    return false;
}

/// Moves `old`'s kept content and markers into a new key `new` whose
/// record carries `root` and names `old`, and removes `old`, as a repo
/// identity change does.
fn moveKey(a: std.mem.Allocator, layout: store.Layout, old: []const u8, new: []const u8, root: []const u8) !void {
    try content.copyRegular(a, try layout.keyDir(a, old), try layout.keyDir(a, new));
    const record = try std.fmt.allocPrint(a, "{{\"root\": \"{s}\", \"version\": 1}}\n", .{root});
    try fsutil.writeFileAtomic(a, try layout.reserved(a, new, store.record_basename), record);
    try store.writeFrom(a, layout, new, old);
    try std.Io.Dir.cwd().deleteTree(io(), try layout.keyDir(a, old));
}

test "a successor key: a machine still on the old identity retargets without asking" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);

    try ma.write(".clasp.json", "kept");
    _ = try ma.keep(".clasp.json");
    try w.deliver(0, 1);
    _ = try mb.reconcile();

    const root = (try clone.defaultRoot(a, ma.clone)).?;
    try moveKey(a, ma.ctx.layout, key, "github.com/renamed/widget", root);
    try w.deliver(0, 1);

    const r = try mb.reconcile();
    try testing.expectEqualStrings("github.com/renamed/widget", r.resolved.?);
    try testing.expect((try expectItem(r, ".clasp.json", .retargeted)).done);
    const want = try mb.ctx.layout.copyPath(a, "github.com/renamed/widget", ".clasp.json");
    try testing.expectEqualStrings(want, (try content.readLink(a, try mb.path(".clasp.json"))).?);
    try testing.expectEqualStrings("kept", try mb.read(".clasp.json"));
}

test "a local key promoted elsewhere: the clone is awaiting promote and its link is reported, not removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    const local_path = try std.fs.path.join(a, &.{ m.code, "local", "scratch" });
    try fsutil.ensureDir(local_path);
    try testutil.runGit(&sb, local_path, &.{ "init", "-q" });
    try testutil.runGit(&sb, local_path, &.{ "commit", "-q", "--allow-empty", "-m", "first" });
    const local_clone = try fsutil.realPathOrSelf(a, local_path);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ local_clone, ".env" }), .data = "e" });
    _ = try harness.keepIn(m.ctx, local_clone, ".env");

    try moveKey(a, m.ctx.layout, "local/scratch", "github.com/acme/scratch", (try clone.defaultRoot(a, local_clone)).?);
    const r = try harness.reconcileIn(m.ctx, local_clone, .apply);
    const item = try expectItem(r, ".env", .awaiting_promote);
    try testing.expect(item.unsettled);
    try testing.expectEqualStrings("github.com/acme/scratch", item.detail.?);
    try testing.expectEqual(content.Entry.symlink, try content.entryAt(try std.fs.path.join(a, &.{ local_clone, ".env" })));
    try testing.expectError(error.AwaitingPromote, harness.keepIn(m.ctx, local_clone, ".env"));
}

test "an online-only kept copy is never read: no link is made to it and local content beside it cannot be compared" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("cloud", "c");
    try m.write("beside", "b");
    _ = try m.keep("cloud");
    _ = try m.keep("beside");
    for ([_][]const u8{ "cloud", "beside" }) |rel| {
        const kp = try m.keptPath(rel);
        try std.Io.Dir.cwd().deleteFile(io(), kp);
        const ph = try std.fs.path.join(a, &.{ std.fs.path.dirname(kp).?, try std.fmt.allocPrint(a, ".{s}.icloud", .{rel}) });
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = ph, .data = "placeholder" });
        try fsutil.removePath(try m.path(rel));
    }
    try m.write("beside", "local");

    const r = try m.reconcile();
    try testing.expect(!(try expectItem(r, "cloud", .online_only)).unsettled);
    try testing.expectEqual(content.Entry.absent, try m.entry("cloud"));
    const cc = try expectItem(r, "beside", .cannot_compare);
    try testing.expect(cc.unsettled and cc.entry != null);
    try testing.expectEqualStrings("local", try m.read("beside"));
}

/// `m`'s context under a new synced root at `<machine>/<name>`, holding a
/// copy of `m`'s whole `kept/` when `copy` is set and an empty `kept/`
/// otherwise, as after a backend switch.
fn switchedBackend(m: *const Machine, name: []const u8, copy: bool) !@TypeOf(m.ctx) {
    const a = m.ctx.alloc;
    const new_root = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.synced).?, name });
    const kept = try std.fs.path.join(a, &.{ new_root, "kept" });
    if (copy) try content.copyRegular(a, try m.ctx.layout.keptDir(a), kept) else try fsutil.ensureDir(kept);
    var moved = m.ctx;
    moved.layout = .{ .synced_root = new_root };
    return moved;
}

/// A clone at `<code>/local/<name>` with one commit and no remote.
fn localClone(m: *const Machine, sb: *testutil.Sandbox, name: []const u8) ![]const u8 {
    const a = m.ctx.alloc;
    const p = try std.fs.path.join(a, &.{ m.code, "local", name });
    try fsutil.ensureDir(p);
    try testutil.runGit(sb, p, &.{ "init", "-q" });
    try testutil.runGit(sb, p, &.{ "commit", "-q", "--allow-empty", "-m", "first" });
    return fsutil.realPathOrSelf(a, p);
}

test "a path equal to a tracked one under case folding is refused and left alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    if (try m.entry("readme") == .absent) try m.write("readme", "a separate file on a case-sensitive filesystem");
    try testing.expectError(error.Tracked, m.keep("readme"));
    try testing.expectEqual(content.Entry.file, try m.entry("README"));
    try testing.expectEqualStrings("hermetic seed commit\n", try content.readSmall(a, try m.path("README")));
}

test "a local key whose record is missing or names another repo: reconcile stops and removes its links, keep refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    const lc = try localClone(m, &sb, "scratch");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ lc, ".env" }), .data = "e" });
    _ = try harness.keepIn(m.ctx, lc, ".env");
    const rec_path = try m.ctx.layout.reserved(a, "local/scratch", store.record_basename);
    const rec = try content.readSmall(a, rec_path);

    try std.Io.Dir.cwd().deleteFile(io(), rec_path);
    const r = try harness.reconcileIn(m.ctx, lc, .apply);
    try testing.expectEqual(reconcile_mod.Stop.local_mismatch, r.stop);
    try testing.expect((try expectItem(r, ".env", .mismatch_link_removed)).done);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try std.fs.path.join(a, &.{ lc, ".env" })));
    try testing.expectEqualStrings("e", try content.readSmall(a, try m.ctx.layout.copyPath(a, "local/scratch", ".env")));

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = rec_path, .data = "{\"root\": \"" ++ "0" ** 40 ++ "\", \"version\": 1}\n" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ lc, ".other" }), .data = "o" });
    try testing.expectError(error.LocalMismatch, harness.keepIn(m.ctx, lc, ".other"));
    try testing.expectEqual(reconcile_mod.Stop.local_mismatch, (try harness.reconcileIn(m.ctx, lc, .apply)).stop);

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = rec_path, .data = rec });
    try testing.expect((try expectItem(try harness.reconcileIn(m.ctx, lc, .apply), ".env", .linked)).done);
}

test "a local key with no directory in the store is nothing to reconcile, never a mismatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".env", "e");
    _ = try m.keep(".env");
    const lc = try localClone(m, &sb, "fresh");
    for ([_]reconcile_mod.Mode{ .plan, .apply }) |mode| {
        const r = try harness.reconcileIn(m.ctx, lc, mode);
        try testing.expectEqual(reconcile_mod.Stop.none, r.stop);
        try testing.expectEqual(@as(usize, 0), r.unsettledCount());
    }
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try m.ctx.layout.keyDir(a, "local/fresh")));
}

test "after a backend switch, a link whose old copy still exists is reported and never removed, in apply and fix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".clasp.json", "kept");
    _ = try m.keep(".clasp.json");
    const moved = try switchedBackend(m, "new-backend", false);
    for ([_]reconcile_mod.Mode{ .fix, .apply }) |mode| {
        const r = try harness.reconcileIn(moved, m.clone, mode);
        const item = try expectItem(r, ".clasp.json", .in_old_root);
        try testing.expect(item.unsettled);
        try testing.expectEqualStrings(m.ctx.layout.synced_root, item.detail.?);
        try testing.expect(try m.linked(".clasp.json"));
    }
}

test "a relative link into another synced root is judged from the link's own directory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("rel", "kept");
    _ = try m.keep("rel");
    const moved = try switchedBackend(m, "new-backend", true);
    try std.Io.Dir.cwd().deleteFile(io(), try moved.layout.copyPath(a, key, "rel"));
    const up = try std.fs.path.relative(a, m.clone, null, m.clone, m.synced);
    try fsutil.removePath(try m.path("rel"));
    try content.createLink(try std.fmt.allocPrint(a, "{s}/kept/{s}/rel", .{ up, key }), try m.path("rel"), .file);

    const r = try harness.reconcileIn(moved, m.clone, .apply);
    _ = try expectItem(r, "rel", .in_old_root);
    try testing.expectEqualStrings("kept", try m.read("rel"));
}

test "a link of holt's shape into a folder the store never lived at is the user's: reported, never retargeted or removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("cfg", "kept");
    _ = try m.keep("cfg");
    const mine = try std.fs.path.join(a, &.{ try fsutil.joinSlashy(a, try std.fs.path.join(a, &.{ sb.root, "notes", "kept" }), key), "cfg" });
    try fsutil.ensureDir(std.fs.path.dirname(mine).?);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = mine, .data = "mine" });
    try fsutil.removePath(try m.path("cfg"));
    try content.createLink(mine, try m.path("cfg"), .file);

    const r = try m.reconcile();
    _ = try expectItem(r, "cfg", .foreign_link);
    try testing.expectEqualStrings(mine, (try content.readLink(a, try m.path("cfg"))).?);
    try testing.expectEqualStrings("mine", try content.readSmall(a, mine));

    const moved = try switchedBackend(m, "new-backend", true);
    try fsutil.removePath(try m.path("cfg"));
    try content.createLink(try m.keptPath("cfg"), try m.path("cfg"), .file);
    const again = try harness.reconcileIn(moved, m.clone, .apply);
    try testing.expect(again.find("cfg", .foreign_link) == null);
}

test "a path entering a nested key is refused by keep and never linked by reconcile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    const nested = key ++ "/Sub";
    try fsutil.ensureDir(try m.ctx.layout.keyDir(a, nested));
    try fsutil.writeFileAtomic(a, try m.ctx.layout.reserved(a, nested, store.record_basename), "{\"version\": 1}\n");
    try m.write("sub/x", "local");
    try testing.expectError(error.NestedKey, m.keep("sub/x"));

    try store.writeFact(a, m.ctx.layout, key, m.ctx.machine_id, "sub/x", .file, "a" ** 64);
    const r = try m.reconcile();
    const item = try expectItem(r, "sub/x", .invalid);
    try testing.expectEqualStrings("inside the nested key " ++ nested, item.detail.?);
    try testing.expect(item.unsettled and item.entry != null);
    try testing.expectEqualStrings("local", try m.read("sub/x"));
}

test "kept paths colliding with each other are invalid and their local content is set aside; a leftover line colliding with a kept path is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("notes.md", "kept");
    _ = try m.keep("notes.md");
    if (try m.entry("Notes.md") == .absent) try m.write("Notes.md", "separate on a case-sensitive filesystem");
    try testing.expectError(error.Collision, m.keep("Notes.md"));

    try m.write("readme.txt", "r");
    _ = try m.keep("readme.txt");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"Readme.txt"});
    const r1 = try m.reconcile();
    _ = try expectItem(r1, "readme.txt", .ok);
    try testing.expect(!(try expectItem(r1, "Readme.txt", .invalid)).unsettled);

    try store.writeFact(a, m.ctx.layout, key, "000000000000000b", "NOTES.md", .file, "b" ** 64);
    try fsutil.removePath(try m.path("notes.md"));
    try m.write("notes.md", "local");
    const r2 = try m.reconcile();
    const item = try expectItem(r2, "notes.md", .invalid);
    try testing.expect(item.unsettled and item.entry != null);
    try testing.expectEqualStrings("local", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, "notes.md")));
}

test "a record naming a file git reads only as a regular file is invalid: never linked, an older holt's link left in place, and once unkept the link becomes a regular copy" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("first.json", "kept by hand, so the key exists");
    _ = try m.keep("first.json");
    const kp = try m.keptPath("a/.mailmap");
    try fsutil.ensureDir(std.fs.path.dirname(kp).?);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = kp, .data = "A <a@example.com>\n" });
    const h = try content.hashPath(a, kp);
    try store.writeFact(a, m.ctx.layout, key, m.ctx.machine_id, "a/.mailmap", .file, &h.hex);
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"a/.mailmap"});

    const r1 = try m.reconcile();
    const item = try expectItem(r1, "a/.mailmap", .invalid);
    try testing.expectEqual(@as(?paths.Invalid, .git_reads_unlinked), item.invalid);
    try testing.expectEqual(content.Entry.absent, try m.entry("a/.mailmap"));
    try testing.expect(paths.contains(try blockRels(m), "a/.mailmap"));

    try fsutil.ensureDir(try m.path("a"));
    try content.createLink(kp, try m.path("a/.mailmap"), .file);
    _ = try expectItem(try m.reconcile(), "a/.mailmap", .invalid);
    try testing.expect(try m.linked("a/.mailmap"));

    const index = try store.loadIndex(a, m.ctx.layout);
    _ = try ops.unkeep(m.ctx, &index, m.clone, "a/.mailmap", .{});
    try testing.expect((try expectItem(try m.reconcile(), "a/.mailmap", .released_converted)).done);
    try testing.expectEqual(content.Entry.file, try m.entry("a/.mailmap"));
    try testing.expectEqualStrings("A <a@example.com>\n", try m.read("a/.mailmap"));
}

test "a retarget never points a link at an online-only kept copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("p", "kept");
    _ = try m.keep("p");
    const moved = try switchedBackend(m, "new-backend", true);
    const kp = try moved.layout.copyPath(a, key, "p");
    try std.Io.Dir.cwd().deleteFile(io(), kp);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(kp).?, ".p.icloud" }), .data = "placeholder" });
    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath("p"));
    const before = (try content.readLink(a, try m.path("p"))).?;

    _ = try expectItem(try harness.reconcileIn(moved, m.clone, .apply), "p", .online_only);
    try testing.expectEqualStrings(before, (try content.readLink(a, try m.path("p"))).?);
}

test "local content at a path no fact names, beside a kept copy, is set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.keptPath("stray"), .data = "in the store" });
    try m.write("stray", "local");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"stray"});

    const item = try expectItem(try m.reconcile(), "stray", .stray);
    try testing.expect(item.unsettled and item.entry != null);
    try testing.expectEqualStrings("local", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, "stray")));
    try testing.expectEqualStrings("local", try m.read("stray"));
}

test "an interrupted keep whose kept copy now differs is given up, and reconcile names the difference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    try m.write(".clasp.json", "mine");
    interrupt.at = .keep_fact;
    try testing.expectError(error.Interrupted, m.keep(".clasp.json"));
    interrupt.at = null;
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.keptPath(".clasp.json"), .data = "arrived from elsewhere" });

    try testing.expectError(error.KeptCopyDiffers, m.keep(".clasp.json"));
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try testing.expectEqual(@as(usize, 0), (try clone.readPending(a, c.common_dir)).len);
    const item = try expectItem(try m.reconcile(), ".clasp.json", .local_differs);
    try testing.expect(item.unsettled and item.entry != null);
    try testing.expectEqualStrings("mine", try m.read(".clasp.json"));
}

test "released: an interrupted conversion is finished by the next reconcile, with and without an exchange rename" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;
    defer content.no_exchange_for_test = false;

    const cases = [_]struct { rel: []const u8, dir: bool, point: interrupt.Point, no_exchange: bool }{
        .{ .rel = "file-copied", .dir = false, .point = .convert_copied, .no_exchange = false },
        .{ .rel = "dir-copied", .dir = true, .point = .convert_copied, .no_exchange = false },
        .{ .rel = "dir-swapped", .dir = true, .point = .convert_swapped, .no_exchange = false },
        .{ .rel = "dir-unlinked", .dir = true, .point = .convert_swapped, .no_exchange = true },
    };
    for (cases) |case| {
        const probe = if (case.dir) try std.fmt.allocPrint(a, "{s}/inner", .{case.rel}) else case.rel;
        try m.write(probe, case.rel);
        _ = try m.keep(case.rel);
        try store.writeReleased(a, m.ctx.layout, key, case.rel);

        content.no_exchange_for_test = case.no_exchange;
        interrupt.at = case.point;
        const r1 = try m.reconcile();
        interrupt.at = null;
        content.no_exchange_for_test = false;
        _ = try expectItem(r1, case.rel, .failed);

        const r2 = try m.reconcile();
        _ = try expectItem(r2, case.rel, .released_local);
        try testing.expectEqual(if (case.dir) content.Entry.dir else content.Entry.file, try m.entry(case.rel));
        try testing.expectEqualStrings(case.rel, try m.read(probe));
        try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, case.rel)));
        try testing.expect(!paths.contains(try blockRels(m), case.rel));
    }
}

test "released: an online-only kept copy is never copied, a gone target is taken from the current copy, and a foreign link is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("cloud/a", "a");
    try m.write("moved", "current");
    try m.write("theirs", "t");
    for ([_][]const u8{ "cloud", "moved", "theirs" }) |rel| {
        _ = try m.keep(rel);
        try store.writeReleased(a, m.ctx.layout, key, rel);
    }
    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath("cloud/a"));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.keptPath("cloud/.a.icloud"), .data = "placeholder" });
    const moved = try switchedBackend(m, "new-backend", true);
    for ([_][]const u8{ "cloud", "theirs" }) |rel| {
        try fsutil.removePath(try m.path(rel));
        try content.createLink(try moved.layout.copyPath(a, key, rel), try m.path(rel), if (std.mem.eql(u8, rel, "cloud")) .dir else .file);
    }
    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath("moved"));
    try fsutil.removePath(try m.path("theirs"));
    // Windows reads a link's target back with its own separator.
    const not_holts = std.fs.path.sep_str ++ "not" ++ std.fs.path.sep_str ++ "holts";
    try content.createLink(not_holts, try m.path("theirs"), .file);

    const r = try harness.reconcileIn(moved, m.clone, .apply);
    _ = try expectItem(r, "cloud", .online_only);
    try testing.expectEqual(content.Entry.symlink, try m.entry("cloud"));
    try testing.expect((try expectItem(r, "moved", .released_converted)).done);
    try testing.expectEqual(content.Entry.file, try m.entry("moved"));
    try testing.expectEqualStrings("current", try m.read("moved"));
    const foreign = try expectItem(r, "theirs", .foreign_link);
    try testing.expect(foreign.unsettled);
    try testing.expectEqualStrings(not_holts, (try content.readLink(a, try m.path("theirs"))).?);
}

test "without symlink privilege: keep moves nothing, and reconcile leaves content where it is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);
    defer content.no_symlinks_for_test = false;

    try ma.write("linkme", "l");
    try ma.write("same", "s");
    _ = try ma.keep("linkme");
    _ = try ma.keep("same");
    try w.deliver(0, 1);
    try mb.write("same", "s");
    try mb.write("new", "n");

    content.no_symlinks_for_test = true;
    try testing.expectError(error.NoSymlinkPrivilege, mb.keep("new"));
    const c = try clone.inspect(a, mb.clone, mb.ctx.code_root);
    try testing.expectEqual(@as(usize, 0), (try clone.readPending(a, c.common_dir)).len);
    try testing.expectEqualStrings("n", try mb.read("new"));

    const r = try mb.reconcile();
    content.no_symlinks_for_test = false;
    try testing.expect(!(try expectItem(r, "linkme", .no_symlink_privilege)).unsettled);
    _ = try expectItem(r, "same", .no_symlink_privilege);
    try testing.expectEqual(content.Entry.absent, try mb.entry("linkme"));
    try testing.expectEqual(content.Entry.file, try mb.entry("same"));
    try testing.expectEqualStrings("s", try mb.read("same"));
}

test "a bad earlier-identity marker is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    const bad_path = try std.fs.path.join(a, &.{ try m.ctx.layout.reserved(a, key, ".holt-from"), &paths.id("github.com/old/widget") });
    try fsutil.ensureDir(std.fs.path.dirname(bad_path).?);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = bad_path, .data = "{\"key\": \"github.com/other/widget\"}" });

    const r = try m.reconcile();
    for (r.bad) |b| {
        if (std.mem.eql(u8, b.path, bad_path)) break;
    } else return error.TestUnexpectedResult;
}

test "a failure at one path is that path's item; the other paths are still reconciled" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);

    try ma.write("ok", "o");
    _ = try ma.keep("ok");
    try w.deliver(0, 1);
    try fsutil.ensureDir(try mb.path("ro"));
    try content.createLink(try mb.keptPath("ro/stale"), try mb.path("ro/stale"), .file);
    const c = try clone.inspect(a, mb.clone, mb.ctx.code_root);
    try block.add(a, c.common_dir, &.{"ro/stale"});
    const ro = try mb.path("ro");
    try std.Io.Dir.cwd().setFilePermissions(io(), ro, @enumFromInt(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io(), ro, @enumFromInt(0o755), .{}) catch {};

    const r = try mb.reconcile();
    const failed = try expectItem(r, "ro/stale", .failed);
    try testing.expect(failed.unsettled);
    try testing.expect((try expectItem(r, "ok", .linked)).done);
}

test "a .holt- name inside a kept directory: keep refuses it, and reconcile never links a kept copy holding one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const ma = w.m(0);
    const mb = w.m(1);

    try ma.write("tool/.holt-kept.json", "{\"version\": 1}");
    try testing.expectError(error.InvalidName, ma.keep("tool"));
    try testing.expectEqualStrings("{\"version\": 1}", try ma.read("tool/.holt-kept.json"));

    try ma.write("notes/a.md", "a");
    _ = try ma.keep("notes");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try ma.keptPath("notes/.holt-paths"), .data = "arrived" });
    try w.deliver(0, 1);
    const item = try expectItem(try mb.reconcile(), "notes", .kept_reserved);
    try testing.expect(item.unsettled);
    try testing.expectEqualStrings(".holt-paths", item.detail.?);
    try testing.expectEqual(content.Entry.absent, try mb.entry("notes"));
}

fn chmod(path: []const u8, mode: u32) !void {
    try std.Io.Dir.cwd().setFilePermissions(io(), path, @enumFromInt(mode), .{});
}

test "outcomes that reach no state, and the released path with nothing to copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("gone", "g");
    _ = try m.keep("gone");
    try store.writeReleased(a, m.ctx.layout, key, "gone");
    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath("gone"));
    try store.writeFact(a, m.ctx.layout, key, "000000000000000b", "a/../b", .file, "b" ** 64);
    try m.write("f", "a file where a directory belongs");
    try store.writeFact(a, m.ctx.layout, key, "000000000000000b", "f/x", .file, "b" ** 64);

    const r = try m.reconcile();
    const inv = try expectItem(r, "a/../b", .invalid);
    try testing.expect(!inv.unsettled and inv.state == null);
    try testing.expectEqualStrings("'.' or '..' component", inv.detail.?);
    const pnd = try expectItem(r, "f/x", .parent_not_dir);
    try testing.expect(!pnd.unsettled and pnd.state == null);
    _ = try expectItem(r, "gone", .released_missing);
    try testing.expectEqual(content.Entry.symlink, try m.entry("gone"));
}

test "a link into another synced root whose old location cannot be read is reported and kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("odd", "o");
    _ = try m.keep("odd");
    const moved = try switchedBackend(m, "new-backend", true);
    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath("odd"));
    try content.createLink("/etc/hosts", try m.keptPath("odd"), .file);
    const odd = try expectItem(try harness.reconcileIn(moved, m.clone, .apply), "odd", .old_unreadable);
    try testing.expect(odd.unsettled);
    try testing.expectEqualStrings(try m.keptPath("odd"), (try content.readLink(a, try m.path("odd"))).?);
}

test "a link into another key of the chain that still holds the copy is reported and kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".clasp.json", "kept");
    _ = try m.keep(".clasp.json");
    const successor = "github.com/renamed/widget";
    const root = (try clone.defaultRoot(a, m.clone)).?;
    try fsutil.ensureDir(try m.ctx.layout.keyDir(a, successor));
    try fsutil.writeFileAtomic(a, try m.ctx.layout.reserved(a, successor, store.record_basename), try std.fmt.allocPrint(a, "{{\"root\": \"{s}\", \"version\": 1}}\n", .{root}));
    try store.writeFrom(a, m.ctx.layout, successor, key);
    try store.writeFact(a, m.ctx.layout, successor, m.ctx.machine_id, ".clasp.json", .file, "a" ** 64);

    const r = try m.reconcile();
    try testing.expectEqualStrings(successor, r.resolved.?);
    try testing.expect((try expectItem(r, ".clasp.json", .pending_move)).unsettled);
    try testing.expect(try m.linked(".clasp.json"));
}

test "local content that is not a regular file or directory is reported, not compared" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".superpowers/a.md", "a");
    _ = try m.keep(".superpowers");
    try fsutil.removePath(try m.path(".superpowers"));
    try m.write(".superpowers/a.md", "a");
    try content.createLink("/etc/hosts", try m.path(".superpowers/hosts"), .file);

    const item = try expectItem(try m.reconcile(), ".superpowers", .local_not_regular);
    try testing.expect(item.unsettled);
    try testing.expectEqual(content.Entry.dir, try m.entry(".superpowers"));
}

test "outside a non-cone sparse checkout nothing is linked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("out/tracked", "t");
    try m.git(&sb, &.{ "add", "out/tracked" });
    try m.git(&sb, &.{ "commit", "-q", "-m", "out" });
    try m.write("out/.env", "e");
    _ = try m.keep("out/.env");
    try fsutil.removePath(try m.path("out/.env"));
    try m.git(&sb, &.{ "sparse-checkout", "set", "--no-cone", "/README" });
    try testing.expectEqual(content.Entry.absent, try m.entry("out"));

    const item = try expectItem(try m.reconcile(), "out/.env", .outside_sparse);
    try testing.expect(!item.unsettled);
    try testing.expectEqual(content.Entry.absent, try m.entry("out"));
}

test "stops: no key for a clone outside the code root, and an unreadable store" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    const outside = try testutil.makeWorkClone(&sb, w.bare);
    defer testing.allocator.free(outside);
    try testing.expectEqual(reconcile_mod.Stop.no_key, (try harness.reconcileIn(m.ctx, outside, .apply)).stop);

    const kept = try m.ctx.layout.keptDir(a);
    try chmod(kept, 0o000);
    defer chmod(kept, 0o755) catch {};
    try testing.expectEqual(reconcile_mod.Stop.store_unreadable, (try reconcile_mod.reconcile(m.ctx, &store.KeyIndex{ .keys = &.{}, .successors = .empty, .bad = &.{} }, m.clone, .apply)).stop);
}

test "an aside that cannot be written is aside_failed, and the local content stays" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try m.saveByRename(".env", "changed");
    const asides = try m.ctx.layout.asideDir(a);
    try chmod(asides, 0o555);
    defer chmod(asides, 0o755) catch {};

    const item = try expectItem(try m.reconcile(), ".env", .aside_failed);
    try testing.expect(item.unsettled and item.entry == null);
    try testing.expectEqualStrings("changed", try m.read(".env"));
}

test "block lines are held while a working tree is prunable or the key's directory is missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".clasp.json", "kept");
    _ = try m.keep(".clasp.json");
    const wt_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.clone).?, "widget@worktrees", "feature" });
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "feature", wt_path });
    const wt = try fsutil.realPathOrSelf(a, try std.fs.path.resolve(a, &.{wt_path}));
    _ = try harness.reconcileIn(m.ctx, wt, .apply);

    try store.writeReleased(a, m.ctx.layout, key, ".clasp.json");
    _ = try expectItem(try m.reconcile(), ".clasp.json", .released_converted);
    try std.Io.Dir.cwd().deleteTree(io(), wt);
    _ = try m.reconcile();
    try testing.expect(paths.contains(try blockRels(m), ".clasp.json"));

    try m.git(&sb, &.{ "worktree", "prune" });
    _ = try m.reconcile();
    try testing.expect(!paths.contains(try blockRels(m), ".clasp.json"));

    try m.write("stale", "s");
    _ = try m.keep("stale");
    try store.writeReleased(a, m.ctx.layout, key, "stale");
    _ = try m.reconcile();
    try testing.expect(!paths.contains(try blockRels(m), "stale"));
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"stale"});
    const key_dir = try m.ctx.layout.keyDir(a, key);
    const hidden = try std.fmt.allocPrint(a, "{s}.away", .{key_dir});
    try std.Io.Dir.cwd().rename(key_dir, std.Io.Dir.cwd(), hidden, io());
    _ = try m.reconcile();
    try testing.expect(paths.contains(try blockRels(m), "stale"));
    try std.Io.Dir.cwd().rename(hidden, std.Io.Dir.cwd(), key_dir, io());
}

test "fix mode leaves tracked links, released links, and differing old locations alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    for ([_][]const u8{ "tracked", "released", "changed" }) |rel| {
        try m.write(rel, rel);
        _ = try m.keep(rel);
    }
    try fsutil.removePath(try m.path("tracked"));
    try m.write("tracked", "committed");
    try m.git(&sb, &.{ "add", "-f", "tracked" });
    try fsutil.removePath(try m.path("tracked"));
    try content.createLink(try m.keptPath("tracked"), try m.path("tracked"), .file);
    try store.writeReleased(a, m.ctx.layout, key, "released");
    const moved = try switchedBackend(m, "new-backend", true);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try moved.layout.copyPath(a, key, "changed"), .data = "new" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try moved.layout.copyPath(a, key, "released"), .data = "released" });

    const r = try harness.reconcileIn(moved, m.clone, .fix);
    try testing.expect(!(try expectItem(r, "tracked", .tracked_link_removed)).done);
    try testing.expectEqual(content.Entry.symlink, try m.entry("tracked"));
    try testing.expect(!(try expectItem(r, "released", .released_converted)).done);
    try testing.expectEqual(content.Entry.symlink, try m.entry("released"));
    const changed = try expectItem(r, "changed", .old_differs);
    try testing.expect(!changed.done and changed.entry == null);
    try testing.expectEqualStrings(try m.keptPath("changed"), (try content.readLink(a, try m.path("changed"))).?);
}

test "a retarget or an aside interrupted inside reconcile is finished by the next one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    try m.write("moving", "same");
    try m.write("differs", "kept");
    _ = try m.keep("moving");
    _ = try m.keep("differs");
    const moved = try switchedBackend(m, "new-backend", true);

    // Windows retargets a link by removing and recreating it, with no
    // temporary link to stop at.
    if (builtin.os.tag != .windows) {
        interrupt.at = .retarget_created;
        _ = try expectItem(try harness.reconcileIn(moved, m.clone, .apply), "moving", .failed);
        interrupt.at = null;
        try testing.expectEqual(content.Entry.symlink, try m.entry(try paths.tempRel(a, "moving")));
        const r = try harness.reconcileIn(moved, m.clone, .apply);
        try testing.expect((try expectItem(r, "moving", .retargeted)).done);
        try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, "moving")));
        try testing.expectEqualStrings(try moved.layout.copyPath(a, key, "moving"), (try content.readLink(a, try m.path("moving"))).?);
        try testing.expect(!paths.contains((try block.read(a, (try clone.inspect(a, m.clone, m.ctx.code_root)).common_dir)).temps, try paths.tempRel(a, "moving")));
    }

    try m.saveByRename("differs", "local edit");
    interrupt.at = .aside_copied;
    _ = try expectItem(try m.reconcile(), "differs", .aside_failed);
    interrupt.at = null;
    try testing.expectEqualStrings("local edit", try m.read("differs"));
    const item = try expectItem(try m.reconcile(), "differs", .local_differs);
    try testing.expect(item.done);
    try testing.expectEqual(aside.Check.ok, try aside.verify(a, m.ctx.layout, item.entry.?));
}

test "a path git lists only under another case is judged by what is on disk: a separate local edit there is set aside, not called tracked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;

    try m.write("notes.md", "kept");
    _ = try m.keep("notes.md");
    try m.git(&sb, &.{ "checkout", "-q", "-b", "upper" });
    try m.write("NOTES.md", "a tracked file of another name");
    try m.git(&sb, &.{ "add", "NOTES.md" });
    try m.git(&sb, &.{ "commit", "-q", "-m", "upper" });
    try m.saveByRename("notes.md", "local edit");

    const r = try m.reconcile();
    const item = try expectItem(r, "notes.md", .local_differs);
    try testing.expect(item.unsettled);
    try testing.expectEqualStrings("local edit", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, "notes.md")));
    try testing.expectEqualStrings("local edit", try m.read("notes.md"));
}

test "git failing to list the index stops reconcile: no link is removed and local content is set aside and reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("linked", "l");
    try m.write("edited", "kept");
    _ = try m.keep("linked");
    _ = try m.keep("edited");
    try m.saveByRename("edited", "local edit");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ c.common_dir, "index" }), .data = "not an index" });

    const r = try m.reconcile();
    try testing.expectEqual(reconcile_mod.Stop.git_failed, r.stop);
    try testing.expect(r.unsettledCount() > 0);
    try testing.expect(try m.linked("linked"));
    try testing.expect(r.find("linked", .stopped) == null);
    const item = try expectItem(r, "edited", .stopped);
    try testing.expect(item.unsettled);
    try testing.expectEqualStrings("local edit", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, "edited")));
    try testing.expectEqualStrings("local edit", try m.read("edited"));
    try testing.expectError(error.GitFailed, m.keep("new"));
}

test "every stop counts as unsettled and lists the local content it hides, set aside where the store can take it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try m.saveByRename(".env", "local edit");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const exclude = try block.excludePath(a, c.common_dir);
    const good_block = try content.readSmall(a, exclude);
    const rec_path = try m.ctx.layout.reserved(a, key, store.record_basename);
    const good_rec = try content.readSmall(a, rec_path);
    const kept = try m.ctx.layout.keptDir(a);

    const Case = struct { stop: reconcile_mod.Stop, aside: bool };
    for ([_]Case{
        .{ .stop = .store_absent, .aside = false },
        .{ .stop = .store_unreadable, .aside = false },
        .{ .stop = .unknown_version, .aside = true },
        .{ .stop = .block_unbalanced, .aside = true },
    }) |case| {
        const away = try std.fmt.allocPrint(a, "{s}.away", .{kept});
        switch (case.stop) {
            .store_absent => try std.Io.Dir.cwd().rename(kept, std.Io.Dir.cwd(), away, io()),
            .store_unreadable => try chmod(kept, 0o000),
            .unknown_version => try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = rec_path, .data = "{\"version\": 99}" }),
            .block_unbalanced => try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = exclude, .data = block.begin_line ++ "\n/.env\n" }),
            else => unreachable,
        }
        const empty: store.KeyIndex = .{ .keys = &.{}, .successors = .empty, .bad = &.{} };
        const r = reconcile_mod.reconcile(m.ctx, &empty, m.clone, .apply);
        switch (case.stop) {
            .store_absent => try std.Io.Dir.cwd().rename(away, std.Io.Dir.cwd(), kept, io()),
            .store_unreadable => try chmod(kept, 0o755),
            .unknown_version => try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = rec_path, .data = good_rec }),
            .block_unbalanced => try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = exclude, .data = good_block }),
            else => unreachable,
        }
        const report = try r;
        try testing.expectEqual(case.stop, report.stop);
        try testing.expect(report.unsettledCount() > 0);
        const item = try expectItem(report, ".env", .stopped);
        try testing.expect(item.unsettled);
        if (case.aside) {
            try testing.expectEqualStrings("local edit", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, ".env")));
        } else try testing.expect(item.entry == null);
        try testing.expectEqualStrings("local edit", try m.read(".env"));
    }

    const outside = try testutil.makeWorkClone(&sb, w.bare);
    defer testing.allocator.free(outside);
    const oc = try clone.inspect(a, outside, m.ctx.code_root);
    _ = try block.write(a, oc.common_dir, &.{".env"});
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ outside, ".env" }), .data = "outside" });
    const nk = try harness.reconcileIn(m.ctx, outside, .apply);
    try testing.expectEqual(reconcile_mod.Stop.no_key, nk.stop);
    try testing.expect(nk.unsettledCount() > 0);
    try testing.expect((try expectItem(nk, ".env", .stopped)).entry == null);

    const lc = try localClone(m, &sb, "scratch");
    for ([_][]const u8{ "linked", "edited" }) |rel| {
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ lc, rel }), .data = "kept" });
        _ = try harness.keepIn(m.ctx, lc, rel);
    }
    const edited = try std.fs.path.join(a, &.{ lc, "edited" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fmt.allocPrint(a, "{s}.save", .{edited}), .data = "local edit" });
    try std.Io.Dir.cwd().rename(try std.fmt.allocPrint(a, "{s}.save", .{edited}), std.Io.Dir.cwd(), edited, io());
    try std.Io.Dir.cwd().deleteFile(io(), try m.ctx.layout.reserved(a, "local/scratch", store.record_basename));
    const lm = try harness.reconcileIn(m.ctx, lc, .apply);
    try testing.expectEqual(reconcile_mod.Stop.local_mismatch, lm.stop);
    try testing.expect(lm.unsettledCount() > 0);
    _ = try expectItem(lm, "linked", .mismatch_link_removed);
    const li = try expectItem(lm, "edited", .stopped);
    try testing.expectEqualStrings("local edit", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, li.entry.?, "edited")));
}

test "unprotected: local content the block hides is listed whatever its state, unless it is holt's link, below one, identical to its kept copy, or tracked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    for ([_][]const u8{ "ok", "same", "differs", "missing", "released", "tracked", "foreign" }) |rel| {
        try m.write(rel, rel);
        _ = try m.keep(rel);
    }
    try m.write("dir/inner", "inside the kept directory");
    _ = try m.keep("dir");
    try m.saveByRename("same", "same");
    try m.saveByRename("differs", "edited");
    try std.Io.Dir.cwd().deleteFile(io(), try m.keptPath("missing"));
    try m.saveByRename("missing", "only here");
    try store.writeReleased(a, m.ctx.layout, key, "released");
    _ = try expectItem(try m.reconcile(), "released", .released_converted);
    try m.write("released", "changed after release");
    try fsutil.removePath(try m.path("tracked"));
    try m.write("tracked", "committed");
    try m.git(&sb, &.{ "add", "-f", "tracked" });
    try fsutil.removePath(try m.path("foreign"));
    try content.createLink("/somewhere/else", try m.path("foreign"), .file);
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{ "dir/inner", "stray" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.keptPath("stray"), .data = "in the store" });
    try m.write("stray", "local");
    try m.write("moving", "mid-keep");
    interrupt.at = .link_created;
    try testing.expectError(error.Interrupted, m.keep("moving"));
    interrupt.at = null;
    try m.write("moving", "edited through the new link");

    const index = try store.loadIndex(a, m.ctx.layout);
    const got = try reconcile_mod.unprotected(m.ctx, &index, m.clone);
    try testing.expect(!paths.contains(try blockRels(m), "released"));
    const want = [_][]const u8{ "differs", "foreign", "missing", "moving", "stray" };
    var rels: std.ArrayList([]const u8) = .empty;
    for (got) |u| try rels.append(a, u.rel);
    std.mem.sort([]const u8, rels.items, {}, paths.lessThan);
    try testing.expectEqual(want.len, rels.items.len);
    for (want, rels.items) |wr, gr| try testing.expectEqualStrings(wr, gr);
    for (got) |u| {
        if (std.mem.eql(u8, u.rel, "moving")) try testing.expectEqualStrings(try paths.tempRel(a, "moving"), u.temp.?);
        if (std.mem.eql(u8, u.rel, "foreign")) try testing.expectEqual(content.Entry.symlink, u.entry);
    }
}

test "keep refuses a directory holding a name a kept path may not have before writing anything, and names each entry" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const block_before = try content.readSmall(a, try block.excludePath(a, c.common_dir));
    try m.write("tool/ok", "fine");
    try m.write("tool/Icon\r", "a macOS folder icon");
    try m.write("tool/vendor/lib/.git/HEAD", "a nested repository");
    try m.write("tool/vendor/lib/.git/objects/x", "never listed");

    var names: []const []const u8 = &.{};
    const index = try store.loadIndex(a, m.ctx.layout);
    try testing.expectError(error.InvalidName, place.keepPath(m.ctx, &index, m.clone, "tool", .{ .invalid_names = &names }));
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("Icon\r", names[0]);
    try testing.expectEqualStrings("vendor/lib/.git", names[1]);
    try testing.expectEqual(@as(usize, 0), (try clone.readPending(a, c.common_dir)).len);
    try testing.expectEqualStrings(block_before, try content.readSmall(a, try block.excludePath(a, c.common_dir)));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try m.keptPath("tool")));
    try testing.expectEqual(content.Entry.dir, try m.entry("tool"));
}

test "keep refuses a key whose record it cannot use before recording anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.ctx.layout.reserved(a, key, store.record_basename), .data = "{\"version\": 99}" });
    try m.write(".env", "e");
    try testing.expectError(error.UnknownRecordVersion, m.keep(".env"));
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try testing.expectEqual(@as(usize, 0), (try clone.readPending(a, c.common_dir)).len);
    try testing.expect(!paths.contains(try blockRels(m), ".env"));
    try testing.expectEqualStrings("e", try m.read(".env"));
}

test "a leftover line equal to a kept path under case folding: a separate local file there is set aside, not settled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;

    try m.write("readme.txt", "kept");
    _ = try m.keep("readme.txt");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"Readme.txt"});
    try m.write("Readme.txt", "a separate file");

    const r = try m.reconcile();
    _ = try expectItem(r, "readme.txt", .ok);
    const item = try expectItem(r, "Readme.txt", .invalid);
    try testing.expect(item.unsettled);
    try testing.expectEqualStrings("a separate file", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, "Readme.txt")));
    try testing.expectEqualStrings("a separate file", try m.read("Readme.txt"));
}

test "a directory holding a nested key is refused by keep, and once a fact names it the key is content that is never linked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    const nested = key ++ "/sub/inner";
    try fsutil.ensureDir(try m.ctx.layout.keyDir(a, nested));
    try fsutil.writeFileAtomic(a, try m.ctx.layout.reserved(a, nested, store.record_basename), "{\"version\": 1}\n");
    try m.write("sub/x", "local");
    try testing.expectError(error.NestedKey, m.keep("sub"));
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try testing.expectEqual(@as(usize, 0), (try clone.readPending(a, c.common_dir)).len);

    try store.writeFact(a, m.ctx.layout, key, m.ctx.machine_id, "sub", .dir, "a" ** 64);
    try fsutil.removePath(try m.path("sub/x"));
    try std.Io.Dir.cwd().deleteDir(io(), try m.path("sub"));
    const item = try expectItem(try m.reconcile(), "sub", .kept_reserved);
    try testing.expectEqualStrings("inner/" ++ store.record_basename, item.detail.?);
    try testing.expectEqual(content.Entry.absent, try m.entry("sub"));
}

test "a temporary left beside a path that is now tracked is settled before the path is judged tracked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    try m.write("seed", "s");
    _ = try m.keep("seed");
    try m.write(".env", "only in the temporary");
    interrupt.at = .link_moved;
    try testing.expectError(error.Interrupted, m.keep(".env"));
    interrupt.at = null;
    try m.write(".env", "committed");
    try m.git(&sb, &.{ "add", "-f", ".env" });

    const r = try m.reconcile();
    const item = try expectItem(r, ".env", .temp_settled);
    try testing.expectEqualStrings("set_aside", item.detail.?);
    try testing.expectEqualStrings("only in the temporary", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, ".env")));
    _ = try expectItem(r, ".env", .tracked);
    try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, ".env")));
    try testing.expectEqualStrings("committed", try m.read(".env"));
}

test "an edit made through the link after keep or relink was interrupted is kept, and the old content set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    try m.write(".env", "original");
    interrupt.at = .link_created;
    try testing.expectError(error.Interrupted, m.keep(".env"));
    interrupt.at = null;
    try m.write(".env", "edited through the link");
    const again = try m.keep(".env");
    try testing.expectEqual(.already_kept, again.status);
    try testing.expectEqualStrings("original", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, again.temp_entry.?, ".env")));
    try testing.expect(try m.linked(".env"));
    try testing.expectEqualStrings("edited through the link", try m.read(".env"));
    try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, ".env")));
    const orig = try content.hashPath(a, try writeBeside(m, "probe-original", "original"));
    try testing.expect((try aside.findEntries(a, m.ctx.layout, key, ".env", &orig.hex)).len > 0);

    try m.write("cfg", "same");
    _ = try m.keep("cfg");
    try m.saveByRename("cfg", "same");
    interrupt.at = .link_created;
    _ = try expectItem(try m.reconcile(), "cfg", .failed);
    interrupt.at = null;
    try m.write("cfg", "edited after the relink");
    _ = try expectItem(try m.reconcile(), "cfg", .ok);
    try testing.expect(try m.linked("cfg"));
    try testing.expectEqualStrings("edited after the relink", try m.read("cfg"));
    try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, "cfg")));
    const same = try content.hashPath(a, try writeBeside(m, "probe-same", "same"));
    try testing.expect((try aside.findEntries(a, m.ctx.layout, key, "cfg", &same.hex)).len > 0);
}

/// Writes `data` beside the clone, outside git's view, and returns its
/// path, so a test can hash known content.
fn writeBeside(m: *const Machine, name: []const u8, data: []const u8) ![]const u8 {
    const p = try std.fs.path.join(m.ctx.alloc, &.{ std.fs.path.dirname(m.clone).?, name });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = p, .data = data });
    return p;
}

test "relinking identical content keeps its executable bit in the kept copy" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("run.sh", "#!/bin/sh\n");
    _ = try m.keep("run.sh");
    try chmod(try m.keptPath("run.sh"), 0o644);
    try m.saveByRename("run.sh", "#!/bin/sh\n");
    try chmod(try m.path("run.sh"), 0o755);
    try testing.expect((try expectItem(try m.reconcile(), "run.sh", .relinked)).done);
    const mode = @intFromEnum((try std.Io.Dir.cwd().statFile(io(), try m.keptPath("run.sh"), .{})).permissions);
    try testing.expectEqual(@as(@TypeOf(mode), 0o755), mode & 0o777);
}

test "a path the index lists only under another spelling, neither on disk: tracked where the filesystem folds names, linked where it does not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try fsutil.removePath(try m.path(".env"));
    try m.write(".ENV", "tracked under another spelling");
    try m.git(&sb, &.{ "add", "-f", ".ENV" });
    try fsutil.removePath(try m.path(".ENV"));

    const r = try m.reconcile();
    if (try harness.caseSensitive(a, m.clone)) {
        try testing.expect((try expectItem(r, ".env", .linked)).done);
    } else {
        _ = try expectItem(r, ".env", .tracked);
        try testing.expectEqual(content.Entry.absent, try m.entry(".env"));
    }
}

test "an invalid visited path: local content there is set aside and unsettled, and the block never hides it; a path outside the tree is only reported" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    try store.writeFact(a, m.ctx.layout, key, "000000000000000b", "a\\b", .file, "b" ** 64);
    try store.writeFact(a, m.ctx.layout, key, "000000000000000b", "../outside", .file, "b" ** 64);
    try m.write("a\\b", "only here");
    const outside = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.clone).?, "outside" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = outside, .data = "not the tree's" });

    const r = try m.reconcile();
    const item = try expectItem(r, "a\\b", .invalid);
    try testing.expect(item.unsettled);
    try testing.expectEqualStrings("only here", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, "a\\b")));
    try testing.expectEqualStrings("only here", try m.read("a\\b"));
    const out = try expectItem(r, "../outside", .invalid);
    try testing.expect(out.entry == null and !out.unsettled);

    const index = try store.loadIndex(a, m.ctx.layout);
    try testing.expectEqual(@as(usize, 0), (try reconcile_mod.unprotected(m.ctx, &index, m.clone)).len);
    try testing.expect(std.mem.indexOf(u8, try gitStatus(m), "?? \"a\\\\b\"") != null);
}

/// True when a verified aside entry for `rel` holds `data` at `probe`.
fn inAside(m: *const Machine, rel: []const u8, probe: []const u8, data: []const u8) !bool {
    const a = m.ctx.alloc;
    var d = std.Io.Dir.cwd().openDir(io(), try m.ctx.layout.asideDir(a), .{ .iterate = true }) catch return false;
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        const man = (try aside.readManifest(a, m.ctx.layout, e.name)) orelse continue;
        if (!std.mem.eql(u8, man.rel, rel) or try aside.verify(a, m.ctx.layout, e.name) != .ok) continue;
        if (content.readSmall(a, try aside.dataPath(a, m.ctx.layout, e.name, probe))) |got| {
            if (std.mem.eql(u8, got, data)) return true;
        } else |_| {}
    }
    return false;
}

test "a tool saving over the link an interrupted keep or relink left: the temporary is set aside and removed, and the new content is judged as local content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    try m.write("cfg", "same");
    _ = try m.keep("cfg");
    try m.saveByRename("cfg", "same");
    interrupt.at = .link_created;
    _ = try expectItem(try m.reconcile(), "cfg", .failed);
    interrupt.at = null;
    try m.saveByRename("cfg", "saved by a tool");
    for ([_][]const u8{ ".env", "by-keep" }) |rel| {
        try m.write(rel, "original");
        interrupt.at = .link_created;
        try testing.expectError(error.Interrupted, m.keep(rel));
        interrupt.at = null;
        try m.saveByRename(rel, "saved by a tool");
    }

    try testing.expectError(error.KeptCopyDiffers, m.keep("by-keep"));
    try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, "by-keep")));
    try testing.expect(try inAside(m, "by-keep", "by-keep", "original"));
    try testing.expectEqualStrings("saved by a tool", try m.read("by-keep"));

    const r = try m.reconcile();
    for ([_][]const u8{ ".env", "cfg" }) |rel| {
        const old = if (std.mem.eql(u8, rel, "cfg")) "same" else "original";
        try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, rel)));
        const settled = try expectItem(r, rel, .temp_settled);
        try testing.expectEqualStrings("set_aside", settled.detail.?);
        try testing.expectEqualStrings(old, try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, settled.entry.?, rel)));
        const item = try expectItem(r, rel, .local_differs);
        try testing.expect(item.unsettled);
        try testing.expectEqualStrings("saved by a tool", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, rel)));
        try testing.expectEqualStrings("saved by a tool", try m.read(rel));
    }
}

test "a stuck temporary at a path now tracked: the temporary and what is at the path are both set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("notes", "kept");
    _ = try m.keep("notes");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const temp = try paths.tempRel(a, "notes");
    try m.write(temp, "left by a write no record names");
    try block.add(a, c.common_dir, &.{temp});
    try fsutil.removePath(try m.path("notes"));
    try m.write("notes", "committed");
    try m.git(&sb, &.{ "add", "-f", "notes" });

    const r = try m.reconcile();
    try testing.expect(r.find("notes", .interrupted) == null);
    const stuck = try expectItem(r, "notes", .temp_stuck);
    try testing.expect(stuck.unsettled);
    try testing.expectEqualStrings(temp, stuck.detail.?);
    try testing.expectEqualStrings("left by a write no record names", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, stuck.entry.?, "notes")));
    const local = try expectItem(r, "notes", .temp_stuck_local);
    try testing.expect(local.unsettled);
    try testing.expectEqualStrings("committed", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, local.entry.?, "notes")));
    try testing.expectEqualStrings("committed", try m.read("notes"));
    try testing.expectEqualStrings("left by a write no record names", try m.read(temp));
}

test "released: a conversion's temporary beside local content is removed when it matches the kept copy and set aside otherwise, never left stuck" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    for ([_][]const u8{ "same", "changed" }) |rel| {
        try m.write(rel, "kept");
        _ = try m.keep(rel);
        try store.writeReleased(a, m.ctx.layout, key, rel);
        interrupt.at = .convert_copied;
        _ = try expectItem(try m.reconcile(), rel, .failed);
        interrupt.at = null;
        try fsutil.removePath(try m.path(rel));
        try m.write(rel, "local edit");
        if (std.mem.eql(u8, rel, "changed")) try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.keptPath(rel), .data = "kept, edited elsewhere" });

        const r = try m.reconcile();
        const item = try expectItem(r, rel, .temp_settled);
        try testing.expectEqualStrings("removed", item.detail.?);
        if (std.mem.eql(u8, rel, "same")) {
            try testing.expect(item.entry == null);
        } else try testing.expectEqualStrings("kept", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, rel)));
        try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, rel)));
        _ = try expectItem(r, rel, .released_local);
        try testing.expectEqualStrings("local edit", try m.read(rel));
    }
}

test "a pending record of a working tree git no longer lists: its temporary is set aside and the record cleared" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    try m.write("seed", "s");
    _ = try m.keep("seed");
    const wt_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.clone).?, "widget@worktrees", "feature" });
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "feature", wt_path });
    const wt = try fsutil.realPathOrSelf(a, try std.fs.path.resolve(a, &.{wt_path}));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ wt, "cfg" }), .data = "original" });
    interrupt.at = .link_moved;
    try testing.expectError(error.Interrupted, harness.keepIn(m.ctx, wt, "cfg"));
    interrupt.at = null;
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.keptPath("cfg"), .data = "edited through another link" });
    const temp = try fsutil.joinSlashy(a, wt, try paths.tempRel(a, "cfg"));
    try fsutil.removePath(try std.fs.path.join(a, &.{ wt, ".git" }));
    try m.git(&sb, &.{ "worktree", "prune" });

    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const plan = try harness.reconcileIn(m.ctx, m.clone, .plan);
    const planned = try expectItem(plan, "cfg", .orphan_temp);
    try testing.expect(!planned.done and planned.unsettled);
    try testing.expectEqual(@as(usize, 1), (try clone.readPending(a, c.common_dir)).len);

    const r = try m.reconcile();
    const item = try expectItem(r, "cfg", .orphan_temp);
    try testing.expect(item.done and !item.unsettled);
    try testing.expectEqualStrings(temp, item.detail.?);
    try testing.expectEqualStrings("original", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, "cfg")));
    try testing.expectEqual(@as(usize, 0), (try clone.readPending(a, c.common_dir)).len);
    try testing.expect(!paths.contains((try block.read(a, c.common_dir)).temps, try paths.tempRel(a, "cfg")));
    try testing.expectEqualStrings("original", try content.readSmall(a, temp));
}

test "a working tree settles and clears only its own pending records, and a temporary's line stays while any record names it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;
    const wt = try std.fmt.allocPrint(a, "{s}@worktrees/feature", .{m.clone});
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "feature", wt });

    try m.write(".env", "original");
    interrupt.at = .link_created;
    try testing.expectError(error.Interrupted, m.keep(".env"));
    try m.write("late", "late");
    interrupt.at = .keep_block;
    try testing.expectError(error.Interrupted, m.keep("late"));
    interrupt.at = null;
    try m.write(".env", "edited through the link");

    _ = try harness.reconcileIn(m.ctx, wt, .apply);
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const pend = try clone.readPending(a, c.common_dir);
    try testing.expectEqual(@as(usize, 2), pend.len);
    try testing.expect(paths.contains((try block.read(a, c.common_dir)).temps, try paths.tempRel(a, "late")));

    _ = try m.reconcile();
    try testing.expect(try m.linked(".env"));
    try testing.expectEqualStrings("edited through the link", try m.read(".env"));
    try testing.expectEqual(content.Entry.absent, try m.entry(try paths.tempRel(a, ".env")));
    try testing.expect(try inAside(m, ".env", ".env", "original"));
}

test "a kept copy whose filesystem refuses chmod: keep and relink still link, and report the executable bit not kept" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer content.chmod_fails_for_test = false;

    for ([_][]const u8{ "run.sh", "again.sh" }) |rel| {
        try m.write(rel, "#!/bin/sh\n");
        _ = try m.keep(rel);
        try chmod(try m.keptPath(rel), 0o644);
        try m.saveByRename(rel, "#!/bin/sh\n");
        try chmod(try m.path(rel), 0o755);
    }
    content.chmod_fails_for_test = true;
    const item = try expectItem(try m.reconcile(), "run.sh", .relinked);
    try testing.expect(item.done and item.exec_not_kept and !item.unsettled);
    try testing.expect(try m.linked("run.sh"));

    try fsutil.removePath(try m.path("again.sh"));
    try m.write("again.sh", "#!/bin/sh\n");
    try chmod(try m.path("again.sh"), 0o755);
    const k = try m.keep("again.sh");
    try testing.expect(k.status == .kept and k.exec_not_kept);
    try testing.expect(try m.linked("again.sh"));
}

test "unprotected: local content that differs from its kept copy only by an executable bit is listed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    for ([_][]const u8{ "run.sh", "plain.sh" }) |rel| {
        try m.write(rel, "#!/bin/sh\n");
        _ = try m.keep(rel);
        try chmod(try m.keptPath(rel), 0o644);
        try m.saveByRename(rel, "#!/bin/sh\n");
    }
    try chmod(try m.path("run.sh"), 0o755);
    try chmod(try m.path("plain.sh"), 0o644);

    const index = try store.loadIndex(a, m.ctx.layout);
    const got = try reconcile_mod.unprotected(m.ctx, &index, m.clone);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("run.sh", got[0].rel);
}

test "keep refuses a directory holding names equal under case folding or normalization, naming each" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;

    try m.write("tool/Readme", "one");
    try m.write("tool/README", "two");
    try m.write("tool/Sub/x", "x");
    try m.write("tool/sub/y", "y");
    try m.write("tool/ok/caf\u{e9}", "composed");
    try m.write("tool/ok/cafe\u{301}", "decomposed");
    try m.write("tool/ok/fine", "fine");
    if (try m.entry("tool/ok/cafe\u{301}") != .file or std.mem.eql(u8, try m.read("tool/ok/caf\u{e9}"), "decomposed")) return error.SkipZigTest;

    var names: []const []const u8 = &.{};
    const index = try store.loadIndex(a, m.ctx.layout);
    try testing.expectError(error.InvalidName, place.keepPath(m.ctx, &index, m.clone, "tool", .{ .invalid_names = &names }));
    const want = [_][]const u8{ "README", "Readme", "Sub", "ok/cafe\u{301}", "ok/caf\u{e9}", "sub" };
    try testing.expectEqual(want.len, names.len);
    for (want, names) |wn, got| try testing.expectEqualStrings(wn, got);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try m.keptPath("tool")));
}

var blocked_aside: []const u8 = "";

fn blockAsideAtLink(p: interrupt.Point) void {
    if (p != .keep_link) return;
    chmod(blocked_aside, 0o555) catch unreachable;
}

test "a keep that has linked is not failed by a staging slot it cannot clear: the slot is left in place and reported" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;
    defer interrupt.hook = null;
    defer content.no_exchange_for_test = false;

    try m.write("d/old", "old");
    _ = try m.keep("d");
    const replacement = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.clone).?, "replacement" });
    try fsutil.ensureDir(replacement);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ replacement, "new" }), .data = "new" });
    const staged = try place.stage(a, m.ctx.layout, m.ctx.machine_id, key, replacement);
    content.no_exchange_for_test = true;
    interrupt.at = .replace_moved_out;
    try testing.expectError(error.Interrupted, place.replaceKept(a, m.ctx.layout, m.ctx.machine_id, key, "d", staged));
    interrupt.at = null;
    content.no_exchange_for_test = false;
    const asides = try m.ctx.layout.asideDir(a);
    try std.Io.Dir.cwd().deleteTree(io(), asides);
    try fsutil.ensureDir(asides);

    try m.write("new", "n");
    blocked_aside = asides;
    interrupt.hook = blockAsideAtLink;
    defer chmod(asides, 0o755) catch {};
    const k = m.keep("new");
    interrupt.hook = null;
    try chmod(asides, 0o755);
    const got = try k;
    try testing.expectEqual(.kept, got.status);
    try testing.expect(try m.linked("new"));
    try testing.expectEqual(@as(usize, 1), got.staging_left.len);
    const slot = std.fs.path.dirname(staged.path).?;
    try testing.expectEqualStrings(slot, got.staging_left[0].slot);
    try testing.expectEqualStrings("old", try content.readSmall(a, try std.fs.path.join(a, &.{ slot, "old", "old" })));
}

/// The `hidden` item for `rel`, set aside and unsettled, whose entry holds
/// `data` at `probe`; then, after `git clean -fdx` has removed the local
/// copy, `data` is still in a verified aside entry.
fn expectSwept(m: *const Machine, sb: *testutil.Sandbox, r: reconcile_mod.Report, rel: []const u8, probe: []const u8, data: []const u8) !reconcile_mod.Item {
    return expectSweptAs(m, sb, r, rel, .hidden, probe, data);
}

/// `expectSwept` for content the sweep set aside for the unsettled item
/// with `outcome` that already reported the place.
fn expectSweptAs(m: *const Machine, sb: *testutil.Sandbox, r: reconcile_mod.Report, rel: []const u8, outcome: reconcile_mod.Outcome, probe: []const u8, data: []const u8) !reconcile_mod.Item {
    const a = m.ctx.alloc;
    const item = try expectItem(r, rel, outcome);
    try testing.expect(item.unsettled and item.entry != null);
    try testing.expectEqualStrings(data, try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, probe)));
    try m.git(sb, &.{ "clean", "-fdxq" });
    try testing.expectEqual(content.Entry.absent, try m.entry(item.detail orelse probe));
    try testing.expect(try inAside(m, rel, probe, data));
    return item;
}

var broken_record: []const u8 = "";

fn breakRecordAtLink(p: interrupt.Point) void {
    if (p != .keep_link) return;
    fsutil.removePath(broken_record) catch unreachable;
    fsutil.ensureDir(broken_record) catch unreachable;
}

test "a keep that has linked is not failed by a closing sweep that fails: the failure is reported in the outcome" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.hook = null;

    try m.write(".env", "kept");
    broken_record = try m.ctx.layout.reserved(a, key, store.record_basename);
    interrupt.hook = breakRecordAtLink;
    const k = try m.keep(".env");
    interrupt.hook = null;
    try testing.expectEqual(.kept, k.status);
    try testing.expect(try m.linked(".env"));
    const h = hiddenAt(k.hidden, m.clone, ".") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?@import("sweep.zig").Why, .failed), h.found.why);
    try testing.expect(h.entry == null and h.found.detail != null);
}

test "the closing sweep: a new file inside a kept directory a branch tracks is set aside, and git clean loses nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".superpowers/notes.md", "notes");
    _ = try m.keep(".superpowers");
    try m.git(&sb, &.{ "checkout", "-q", "-b", "tracking" });
    try fsutil.removePath(try m.path(".superpowers"));
    try m.write(".superpowers/tracked.md", "tracked");
    try m.git(&sb, &.{ "add", "-f", ".superpowers/tracked.md" });
    try m.git(&sb, &.{ "commit", "-q", "-m", "track it" });
    try m.write(".superpowers/new.md", "new work");

    const r = try m.reconcile();
    _ = try expectItem(r, ".superpowers", .tracked);
    _ = try expectSwept(m, &sb, r, ".superpowers", ".superpowers/new.md", "new work");
    try testing.expectEqualStrings("tracked", try m.read(".superpowers/tracked.md"));
}

test "the closing sweep: new content at a path HEAD tracks but the index no longer lists is set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("cfg.json", "kept");
    _ = try m.keep("cfg.json");
    try m.git(&sb, &.{ "checkout", "-q", "-b", "tracking" });
    try fsutil.removePath(try m.path("cfg.json"));
    try m.write("cfg.json", "committed");
    try m.git(&sb, &.{ "add", "-f", "cfg.json" });
    try m.git(&sb, &.{ "commit", "-q", "-m", "track it" });
    try m.git(&sb, &.{ "rm", "-q", "--cached", "cfg.json" });
    try m.write("cfg.json", "new content");

    const r = try m.reconcile();
    _ = try expectItem(r, "cfg.json", .tracked);
    _ = try expectSwept(m, &sb, r, "cfg.json", "cfg.json", "new content");
}

test "the closing sweep: content edited after a keep was interrupted once its line was written is set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    try m.write("seed", "s");
    _ = try m.keep("seed");
    for ([_]interrupt.Point{ .keep_block, .keep_aside }) |point| {
        const rel = @tagName(point);
        try m.write(rel, "original");
        interrupt.at = point;
        try testing.expectError(error.Interrupted, m.keep(rel));
        interrupt.at = null;
        try m.write(rel, "edited after");

        const r = try m.reconcile();
        try testing.expect(r.find(rel, .hidden) == null);
        _ = try expectSweptAs(m, &sb, r, rel, .interrupted, rel, "edited after");
    }
}

test "the closing sweep: a released path's edited local copy is set aside while another working tree holds its line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    for ([_][]const u8{ ".clasp.json", "notes" }) |rel| {
        try m.write(rel, "kept");
        _ = try m.keep(rel);
    }
    const wt_path = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.clone).?, "widget@worktrees", "feature" });
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "feature", wt_path });
    const wt = try fsutil.realPathOrSelf(a, try std.fs.path.resolve(a, &.{wt_path}));
    _ = try harness.reconcileIn(m.ctx, wt, .apply);

    try store.writeReleased(a, m.ctx.layout, key, ".clasp.json");
    _ = try expectItem(try m.reconcile(), ".clasp.json", .released_converted);
    try m.write(".clasp.json", "edited after release");
    const r1 = try m.reconcile();
    _ = try expectItem(r1, ".clasp.json", .released_local);
    try testing.expect(paths.contains(try blockRels(m), ".clasp.json"));
    _ = try expectSwept(m, &sb, r1, ".clasp.json", ".clasp.json", "edited after release");
    _ = try expectItem(try m.reconcile(), "notes", .linked);

    try store.writeReleased(a, m.ctx.layout, key, "notes");
    _ = try expectItem(try m.reconcile(), "notes", .released_converted);
    try std.Io.Dir.cwd().deleteTree(io(), wt);
    try m.write("notes", "edited while a working tree is prunable");
    const r2 = try m.reconcile();
    _ = try expectItem(r2, "notes", .released_local);
    _ = try expectSwept(m, &sb, r2, "notes", "notes", "edited while a working tree is prunable");
}

test "the closing sweep: a separate file at a leftover alias line is set aside when Windows cannot identify either file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;
    defer content.unknown_ids_for_test = false;

    try m.write("readme.txt", "kept");
    _ = try m.keep("readme.txt");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"Readme.txt"});
    try m.write("Readme.txt", "a separate file");

    content.unknown_ids_for_test = true;
    const r = try m.reconcile();
    content.unknown_ids_for_test = false;
    try testing.expect(!(try expectItem(r, "Readme.txt", .invalid)).unsettled);
    try testing.expect(try m.linked("readme.txt"));
    _ = try expectSwept(m, &sb, r, "Readme.txt", "Readme.txt", "a separate file");
}

test "the closing sweep: a temporary a state never reached is set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    for ([_][]const u8{ "notes.md", "cfg" }) |rel| {
        try m.write(rel, "kept");
        _ = try m.keep(rel);
    }
    try store.writeFact(a, m.ctx.layout, key, "000000000000000b", "NOTES.md", .file, "b" ** 64);
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try clone.addPending(a, c.common_dir, .{ .tree = c.tree, .rel = "cfg", .op = .take_local });
    for ([_][]const u8{ "notes.md", "cfg" }) |rel| {
        const temp = try paths.tempRel(a, rel);
        try m.write(temp, "only in the temporary");
        try block.add(a, c.common_dir, &.{temp});
    }

    const r = try m.reconcile();
    _ = try expectItem(r, "notes.md", .invalid);
    _ = try expectItem(r, "cfg", .interrupted);
    for ([_][]const u8{ "notes.md", "cfg" }) |rel| {
        const item = try expectSwept(m, &sb, r, rel, rel, "only in the temporary");
        try testing.expectEqualStrings(try paths.tempRel(a, rel), item.detail.?);
    }
}

test "the closing sweep reports without acting in plan and fix, and adds nothing a state already set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;

    try m.write("differs", "kept");
    try m.write("d/kept", "kept");
    _ = try m.keep("differs");
    _ = try m.keep("d");
    try m.saveByRename("differs", "edited");
    try m.git(&sb, &.{ "checkout", "-q", "-b", "tracking" });
    try fsutil.removePath(try m.path("d"));
    try m.write("d/tracked", "tracked");
    try m.git(&sb, &.{ "add", "-f", "d/tracked" });
    try m.git(&sb, &.{ "commit", "-q", "-m", "track d" });
    try m.write("d/new", "new work");
    try m.write("late", "original");
    interrupt.at = .keep_block;
    try testing.expectError(error.Interrupted, m.keep("late"));
    interrupt.at = null;

    for ([_]reconcile_mod.Mode{ .plan, .fix }) |mode| {
        const r = try harness.reconcileIn(m.ctx, m.clone, mode);
        const item = try expectItem(r, "d", .hidden);
        try testing.expect(item.unsettled and !item.done and item.entry == null);
        try testing.expect(r.find("differs", .hidden) == null);
        try testing.expect(r.find("late", .hidden) == null);
    }
    try testing.expect(!try inAside(m, "d", "d/new", "new work"));
    try testing.expect(!try asideNames(m, "late"));

    const r = try m.reconcile();
    const differs = try expectItem(r, "differs", .local_differs);
    try testing.expect(differs.entry != null);
    try testing.expect(r.find("differs", .hidden) == null);
    try testing.expect(r.find("late", .hidden) == null);
    const late = try expectItem(r, "late", .interrupted);
    try testing.expectEqualStrings("original", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, late.entry.?, "late")));
    try testing.expect((try expectItem(r, "d", .hidden)).done);
    const again = try m.reconcile();
    try testing.expectEqualStrings(late.entry.?, (try expectItem(again, "late", .interrupted)).entry.?);
}

test "unprotected: holt's link of another spelling, content under a symlinked parent, and a .git path are not listed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("readme.txt", "kept");
    _ = try m.keep("readme.txt");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"Readme.txt"});
    if (try m.entry("Readme.txt") == .absent) try content.createLink(try m.keptPath("readme.txt"), try m.path("Readme.txt"), .file);
    const elsewhere = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.clone).?, "elsewhere" });
    try fsutil.ensureDir(elsewhere);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ elsewhere, "a\\b" }), .data = "not the tree's" });
    try content.createLink(elsewhere, try m.path("ln"), .dir);
    try store.writeFact(a, m.ctx.layout, key, "000000000000000b", "ln/a\\b", .file, "b" ** 64);
    try store.writeFact(a, m.ctx.layout, key, "000000000000000b", ".git/config", .file, "b" ** 64);

    const index = try store.loadIndex(a, m.ctx.layout);
    const got = try reconcile_mod.unprotected(m.ctx, &index, m.clone);
    try testing.expectEqual(@as(usize, 0), got.len);

    const r = try m.reconcile();
    for ([_][]const u8{ "ln/a\\b", ".git/config" }) |rel| {
        const item = try expectItem(r, rel, .invalid);
        try testing.expect(!item.unsettled and item.entry == null);
        try testing.expect(!try asideNames(m, rel));
    }
}

test "a kept directory replaced by one holding a symlink: its regular files are set aside, the link is listed, and git clean loses nothing else" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("d/kept.md", "kept");
    _ = try m.keep("d");
    try fsutil.removePath(try m.path("d"));
    try m.write("d/notes.md", "only here");
    try m.write("d/deep/plan.md", "also only here");
    try content.createLink("/somewhere/else", try m.path("d/link"), .file);

    const r = try m.reconcile();
    const item = try expectItem(r, "d", .local_not_regular);
    try testing.expect(item.unsettled and item.done);
    try testing.expectEqual(@as(usize, 1), item.skipped.len);
    try testing.expectEqualStrings("d/link", item.skipped[0].path);
    try testing.expectEqual(content.Skip.symlink, item.skipped[0].why);
    try testing.expect(r.find("d", .hidden) == null);
    try testing.expectEqualStrings("only here", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, item.entry.?, "d/notes.md")));

    try m.git(&sb, &.{ "clean", "-fdxq" });
    try testing.expectEqual(content.Entry.absent, try m.entry("d"));
    try testing.expect(try inAside(m, "d", "d/notes.md", "only here"));
    try testing.expect(try inAside(m, "d", "d/deep/plan.md", "also only here"));
}

/// The real path of a new linked working tree of `m`'s clone on branch
/// `branch`, beside the clone.
fn addWorktree(m: *const Machine, sb: *testutil.Sandbox, branch: []const u8) ![]const u8 {
    const a = m.ctx.alloc;
    const p = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.clone).?, "widget@worktrees", branch });
    try m.git(sb, &.{ "worktree", "add", "-q", "-b", branch, p });
    return fsutil.realPathOrSelf(a, try std.fs.path.resolve(a, &.{p}));
}

test "a line holt adds hides another working tree's own copy: keep and reconcile set it aside first, and removing that working tree loses nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    const wt = try addWorktree(m, &sb, "feature");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ wt, ".env" }), .data = "the feature tree's own" });
    try m.write(".env", "the main tree's");
    const k = try m.keep(".env");
    try testing.expectEqual(@as(usize, 1), k.hidden.len);
    try testing.expectEqualStrings(wt, k.hidden[0].found.worktree);
    try testing.expectEqualStrings("the feature tree's own", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, k.hidden[0].entry.?, ".env")));
    try m.git(&sb, &.{ "worktree", "remove", wt });
    try testing.expectEqual(content.Entry.absent, try content.entryAt(wt));
    try testing.expect(try inAside(m, ".env", ".env", "the feature tree's own"));

    const later = try addWorktree(m, &sb, "later");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ later, ".env" }), .data = "made after the keep" });
    const r = try m.reconcile();
    const item = try expectItem(r, ".env", .hidden);
    try testing.expect(item.unsettled and item.done);
    try testing.expectEqualStrings(later, item.worktree.?);
    try m.git(&sb, &.{ "worktree", "remove", later });
    try testing.expect(try inAside(m, ".env", ".env", "made after the keep"));
}

test "the closing sweep: a new file in a kept directory's other spelling that a branch tracks is set aside, as git matches names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (try harness.caseSensitive(a, m.clone)) try m.git(&sb, &.{ "config", "core.ignorecase", "true" });

    try m.write("Dir/notes.md", "notes");
    _ = try m.keep("Dir");
    try m.git(&sb, &.{ "checkout", "-q", "-b", "tracking" });
    try fsutil.removePath(try m.path("Dir"));
    try m.write("dir/tracked.md", "tracked");
    try m.git(&sb, &.{ "add", "-f", "dir/tracked.md" });
    try m.git(&sb, &.{ "commit", "-q", "-m", "track it" });
    try m.write("dir/new.md", "new work");

    const r = try m.reconcile();
    _ = try expectSwept(m, &sb, r, "dir", "dir/new.md", "new work");
    try testing.expectEqualStrings("tracked", try m.read("dir/tracked.md"));
}

test "the closing sweep: a separate file git's core.ignorecase folds onto a kept path is set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;

    try m.write("config.json", "kept");
    _ = try m.keep("config.json");
    try m.git(&sb, &.{ "config", "core.ignorecase", "true" });
    try m.write("Config.json", "a separate file");

    const r = try m.reconcile();
    try testing.expect(try m.linked("config.json"));
    _ = try expectSwept(m, &sb, r, "Config.json", "Config.json", "a separate file");
}

test "the closing sweep: a separate file the user's global core.ignorecase folds onto a kept path is set aside, as the user's git would delete it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;

    const global = try std.fs.path.join(a, &.{ sb.root, "global.gitconfig" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = global, .data = "[core]\n\tignorecase = true\n" });
    const env = try testutil.EnvOverride.install(a, "GIT_CONFIG_GLOBAL", global);
    defer env.restore();

    try m.write("Config.json", "kept");
    _ = try m.keep("Config.json");
    try m.write("config.json", "a separate file");

    const r = try m.reconcile();
    try testing.expect(try m.linked("Config.json"));
    _ = try expectSwept(m, &sb, r, "config.json", "config.json", "a separate file");
}

test "an unreadable directory fails only its own paths: reconcile still reports, keeps their lines, and sweeps the rest" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("sub/.env", "kept inside a real directory");
    _ = try m.keep("sub/.env");
    try m.write("cache/a", "kept");
    _ = try m.keep("cache");
    try m.write("x", "kept");
    _ = try m.keep("x");
    try m.saveByRename("x", "edited");
    try fsutil.removePath(try m.path("cache"));
    try m.write("cache/secret", "only here, unreadable");
    const sub = try m.path("sub");
    const cache = try m.path("cache");
    try chmod(sub, 0o000);
    try chmod(cache, 0o000);
    defer chmod(sub, 0o755) catch {};
    defer chmod(cache, 0o755) catch {};
    if (std.Io.Dir.cwd().openDir(io(), sub, .{ .iterate = true })) |d| {
        d.close(io());
        return error.SkipZigTest;
    } else |_| {}

    const r = try m.reconcile();
    try testing.expect((try expectItem(r, "sub/.env", .failed)).unsettled);
    try testing.expect(r.find("cache", .ok) == null);
    var cache_reported = false;
    for (r.items) |i| {
        if (std.mem.eql(u8, i.rel, "cache") and i.unsettled) cache_reported = true;
    }
    try testing.expect(cache_reported);
    const x = try expectItem(r, "x", .local_differs);
    try testing.expectEqualStrings("edited", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, x.entry.?, "x")));
    for ([_][]const u8{ "sub/.env", "cache", "x" }) |rel| try testing.expect(paths.contains(try blockRels(m), rel));

    _ = try git.runInRepo(a, &.{ "clean", "-fdxq" }, m.clone);
    try testing.expect(try inAside(m, "x", "x", "edited"));
    try chmod(sub, 0o755);
    try chmod(cache, 0o755);
    try testing.expectEqualStrings("only here, unreadable", try m.read("cache/secret"));
}

test "a nested repository the block hides is reported and never copied into aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("tools/kept.md", "kept");
    _ = try m.keep("tools");
    try fsutil.removePath(try m.path("tools"));
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"vendor"});
    for ([_][]const u8{ "tools", "vendor" }) |rel| {
        try m.write(try std.fmt.allocPrint(a, "{s}/work.txt", .{rel}), "committed in the nested repository");
        try testutil.runGit(&sb, try m.path(rel), &.{ "init", "-q" });
    }

    const r = try m.reconcile();
    for ([_][]const u8{ "tools", "vendor" }) |rel| {
        const item = try expectItem(r, rel, .nested_repository);
        try testing.expect(item.unsettled and item.entry == null);
        try testing.expect(r.find(rel, .hidden) == null);
    }
    try testing.expectEqual(@as(?u8, 10), (try expectItem(r, "tools", .nested_repository)).state);
    try testing.expect(!try asideNames(m, "vendor"));
    try testing.expect(!try inAside(m, "tools", "tools/work.txt", "committed in the nested repository"));
    try m.git(&sb, &.{ "clean", "-fdxq" });
    try testing.expectEqualStrings("committed in the nested repository", try m.read("vendor/work.txt"));
}

test "a working tree that cannot be read is reported unsettled and holds its lines, and the others are still swept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try m.write("notes", "kept");
    _ = try m.keep("notes");
    const lost = try addWorktree(m, &sb, "lost");
    const other = try addWorktree(m, &sb, "other");
    try fsutil.removePath(try std.fs.path.join(a, &.{ lost, ".git" }));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ other, ".env" }), .data = "the other tree's own" });
    try store.writeReleased(a, m.ctx.layout, key, "notes");

    const r = try m.reconcile();
    const item = try expectItem(r, ".", .tree_unreadable);
    try testing.expect(item.unsettled);
    try testing.expectEqualStrings(lost, item.worktree.?);
    try testing.expectEqualStrings(other, (try expectItem(r, ".env", .hidden)).worktree.?);
    try testing.expect(try inAside(m, ".env", ".env", "the other tree's own"));
    try testing.expect(paths.contains(try blockRels(m), "notes"));
}

/// True when an aside entry's manifest names `rel`.
fn asideNames(m: *const Machine, rel: []const u8) !bool {
    const a = m.ctx.alloc;
    var d = std.Io.Dir.cwd().openDir(io(), try m.ctx.layout.asideDir(a), .{ .iterate = true }) catch return false;
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        const man = (try aside.readManifest(a, m.ctx.layout, e.name)) orelse continue;
        if (std.mem.eql(u8, man.rel, rel)) return true;
    }
    return false;
}

/// Keeps `.vscode/settings.json` in `m`'s main working tree while a linked
/// one holds its own copy inside an untracked `.vscode/`, then adds another
/// linked one with its own copy; each copy is set aside (by keep, then by
/// reconcile's closing sweep), so removing the linked trees loses nothing.
fn keepBesideLinkedVscode(m: *const Machine, sb: *testutil.Sandbox, tag: []const u8) !void {
    const a = m.ctx.alloc;
    const early = try addWorktree(m, sb, try std.fmt.allocPrint(a, "early-{s}", .{tag}));
    try fsutil.ensureDir(try fsutil.joinSlashy(a, early, ".vscode"));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, early, ".vscode/settings.json"), .data = "early tree's own" });
    try m.write(".vscode/settings.json", "the main tree's");
    const k = try m.keep(".vscode/settings.json");
    try testing.expectEqual(@as(usize, 1), k.hidden.len);
    try testing.expectEqualStrings("early tree's own", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, k.hidden[0].entry.?, ".vscode/settings.json")));

    const late = try addWorktree(m, sb, try std.fmt.allocPrint(a, "late-{s}", .{tag}));
    try fsutil.ensureDir(try fsutil.joinSlashy(a, late, ".vscode"));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, late, ".vscode/settings.json"), .data = "late tree's own" });
    const r = try m.reconcile();
    for ([_][]const u8{ early, late }) |wt| {
        const item = for (r.items) |i| {
            if (i.outcome == .hidden and i.worktree != null and std.mem.eql(u8, i.worktree.?, wt)) break i;
        } else return error.TestUnexpectedResult;
        try testing.expect(item.unsettled and item.entry != null);
    }

    for ([_][]const u8{ early, late }) |wt| try m.git(sb, &.{ "worktree", "remove", wt });
    try testing.expect(try inAside(m, ".vscode/settings.json", ".vscode/settings.json", "early tree's own"));
    try testing.expect(try inAside(m, ".vscode/settings.json", ".vscode/settings.json", "late tree's own"));
}

test "a linked tree's own file inside an untracked directory is set aside when the main tree keeps it, even by a listing that leaves it out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    clone.waive_git_check_for_test = true;
    defer clone.waive_git_check_for_test = false;
    defer clone.listing_for_test = null;

    for ([_]bool{ false, true }) |miss| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try World.init(a, &sb, 1);
        clone.listing_for_test = if (miss) &.{} else null;
        try keepBesideLinkedVscode(w.m(0), &sb, if (miss) "missed" else "listed");
    }
}

/// Puts a `git` first on PATH that runs the shell text `script` and then
/// hands its arguments to the real git; POSIX only. Undone by `restore`.
fn fakeGit(a: std.mem.Allocator, sb: *testutil.Sandbox, script: []const u8) !testutil.EnvOverride {
    const real_path = std.process.Environ.getPosix(std.Io.Threaded.global_single_threaded.environ.process_environ, "PATH") orelse "";
    var real_git: ?[]const u8 = null;
    var dirs = std.mem.splitScalar(u8, real_path, ':');
    while (dirs.next()) |d| {
        const candidate = try std.fs.path.join(a, &.{ d, "git" });
        if (try content.entryAt(candidate) != .absent) {
            real_git = candidate;
            break;
        }
    }
    const dir = try std.fs.path.join(a, &.{ sb.root, try std.fmt.allocPrint(a, "fake-git-{d}", .{sb.work_seq}) });
    sb.work_seq += 1;
    try fsutil.ensureDir(dir);
    const fake = try std.fs.path.join(a, &.{ dir, "git" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = fake, .data = try std.fmt.allocPrint(a, "#!/bin/sh\n{s}exec '{s}' \"$@\"\n", .{ script, real_git.? }) });
    try chmod(fake, 0o755);
    return testutil.EnvOverride.install(a, "PATH", try std.fmt.allocPrint(a, "{s}:{s}", .{ dir, real_path }));
}

test "every kept operation refuses a git older than 2.32, naming the version found" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    clone.waive_git_check_for_test = true;
    try m.write(".env", "kept");
    _ = try m.keep(".env");
    clone.waive_git_check_for_test = false;

    const env = try fakeGit(a, &sb, "if [ \"$1\" = \"--version\" ]; then echo 'git version 2.31.8'; exit 0; fi\n");
    defer env.restore();
    clone.forgetGitForTest();
    defer clone.forgetGitForTest();

    try testing.expectError(error.GitTooOld, m.reconcile());
    try testing.expectError(error.GitTooOld, harness.reconcileIn(m.ctx, m.clone, .plan));
    try m.write("other", "not kept");
    try testing.expectError(error.GitTooOld, m.keep("other"));
    const index = try store.loadIndex(a, m.ctx.layout);
    try testing.expectError(error.GitTooOld, reconcile_mod.unprotected(m.ctx, &index, m.clone));
    try testing.expectEqualStrings("kept files need git 2.32 or newer (found 2.31.8)", try clone.gitTooOld(a));
    try testing.expectEqualStrings("not kept", try m.read("other"));
}

/// Puts the gitignore line `line` into holt's block of `m`'s clone, as a
/// line holt did not write.
fn addForeignLine(m: *const Machine, line: []const u8) !void {
    const a = m.ctx.alloc;
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const file = try block.excludePath(a, c.common_dir);
    const text = try content.readSmall(a, file);
    const at = std.mem.indexOf(u8, text, block.begin_line ++ "\n").? + block.begin_line.len + 1;
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = file, .data = try std.mem.concat(a, u8, &.{ text[0..at], line, "\n", text[at..] }) });
    try testing.expect(paths.contains((try block.read(a, c.common_dir)).foreign, line));
}

test "the closing sweep: a directory a foreign line hides whole above a kept path is set aside with everything in it, and removing the working tree loses nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("tools/.env", "the main tree's");
    _ = try m.keep("tools/.env");
    try addForeignLine(m, "/tools/");
    const wt = try addWorktree(m, &sb, "feature");
    try fsutil.ensureDir(try fsutil.joinSlashy(a, wt, "tools"));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, "tools/.env"), .data = "the feature tree's own" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, "tools/notes"), .data = "notes only here" });

    const r = try m.reconcile();
    var found: ?reconcile_mod.Item = null;
    for (r.items) |i| {
        if (i.outcome != .hidden) continue;
        try testing.expect(i.worktree != null);
        if (std.mem.eql(u8, i.rel, "tools") and std.mem.eql(u8, i.worktree.?, wt)) found = i;
    }
    const item = found orelse return error.TestUnexpectedResult;
    try testing.expect(item.unsettled and item.entry != null);
    try testing.expect(try m.linked("tools/.env"));

    try m.git(&sb, &.{ "worktree", "remove", wt });
    try testing.expectEqual(content.Entry.absent, try content.entryAt(wt));
    try testing.expect(try inAside(m, "tools", "tools/notes", "notes only here"));
    try testing.expect(try inAside(m, "tools", "tools/.env", "the feature tree's own"));
}

test "a new kept line that would hide a nested repository in a linked working tree: keep refuses and writes nothing, and reconcile writes no such line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const m = w.m(0);

    const wt = try addWorktree(m, &sb, "feature");
    const nested = try fsutil.joinSlashy(a, wt, "tools");
    try fsutil.ensureDir(nested);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, nested, "work.txt"), .data = "committed in the nested repository" });
    try testutil.runGit(&sb, nested, &.{ "init", "-q" });
    try m.write("tools/notes.md", "the main tree's");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const exclude_before = try content.readSmall(a, try block.excludePath(a, c.common_dir));

    var places: []const place.Hidden = &.{};
    try testing.expectError(error.WouldHide, place.keepPath(m.ctx, &(try store.loadIndex(a, m.ctx.layout)), m.clone, "tools", .{ .would_hide = &places }));
    try testing.expectEqual(@as(usize, 1), places.len);
    try testing.expectEqualStrings(wt, places[0].found.worktree);
    try testing.expectEqualStrings("tools", places[0].found.rel);
    try testing.expectEqual(@as(?@import("sweep.zig").Why, .nested_repository), places[0].found.why);
    try testing.expectEqualStrings(exclude_before, try content.readSmall(a, try block.excludePath(a, c.common_dir)));
    try testing.expectEqual(@as(usize, 0), (try clone.readPending(a, c.common_dir)).len);
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try m.ctx.layout.keyDir(a, key)));
    try testing.expectEqual(content.Entry.dir, try m.entry("tools"));
    try testing.expect(!try asideNames(m, "tools"));

    try std.Io.Dir.cwd().deleteTree(io(), try m.path("tools"));
    const b = w.m(1);
    try b.write("tools/notes.md", "kept on b");
    _ = try b.keep("tools");
    try w.sync();
    const r = try m.reconcile();
    const refused = try expectItem(r, "tools", .line_refused);
    try testing.expect(refused.unsettled);
    const nr = try expectItem(r, "tools", .nested_repository);
    try testing.expectEqualStrings(wt, nr.worktree.?);
    try testing.expect(!paths.contains(try blockRels(m), "tools"));
    try testing.expectEqual(content.Entry.absent, try m.entry("tools"));

    try testutil.runGit(&sb, wt, &.{ "clean", "-fdxq" });
    try testing.expectEqualStrings("committed in the nested repository", try content.readSmall(a, try fsutil.joinSlashy(a, nested, "work.txt")));
}

test "the working trees cannot be read: reconcile stops unsettled, keep refuses before adding a line, and the deleters see a failure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "kept");
    _ = try m.keep(".env");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const exclude_before = try content.readSmall(a, try block.excludePath(a, c.common_dir));

    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try std.fs.path.join(a, &.{ c.common_dir, "worktrees" }), .data = "not a directory" });

    const r = try m.reconcile();
    try testing.expectEqual(reconcile_mod.Stop.worktrees_unknown, r.stop);
    try testing.expect(r.unsettledCount() > 0);
    try m.write("new", "not kept yet");
    try testing.expectError(error.WorktreeListFailed, m.keep("new"));
    try testing.expectEqualStrings(exclude_before, try content.readSmall(a, try block.excludePath(a, c.common_dir)));
    try testing.expectEqual(@as(usize, 0), (try clone.readPending(a, c.common_dir)).len);
    const index = try store.loadIndex(a, m.ctx.layout);
    var failed = false;
    for (try reconcile_mod.unprotected(m.ctx, &index, m.clone)) |u| {
        if (u.why == .failed and std.mem.eql(u8, u.rel, ".")) failed = true;
    }
    try testing.expect(failed);
}

test "a working tree git cannot list is a failed item that holds every line, and a keep whose line it might hide is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "kept");
    _ = try m.keep(".env");
    const wt = try addWorktree(m, &sb, "feature");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"stale"});
    const index_file = try fsutil.joinSlashy(a, c.common_dir, "worktrees/feature/index");
    const good_index = try content.readSmall(a, index_file);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = index_file, .data = "garbage" });

    const r = try m.reconcile();
    var failed = false;
    for (r.items) |i| {
        if (i.outcome == .failed and std.mem.eql(u8, i.rel, ".") and i.worktree != null and std.mem.eql(u8, i.worktree.?, wt)) {
            try testing.expect(i.unsettled);
            failed = true;
        }
    }
    try testing.expect(failed);
    try testing.expect(paths.contains(try blockRels(m), "stale"));

    try m.write("new", "not kept yet");
    const exclude_before = try content.readSmall(a, try block.excludePath(a, c.common_dir));
    var places: []const place.Hidden = &.{};
    try testing.expectError(error.WouldHide, place.keepPath(m.ctx, &(try store.loadIndex(a, m.ctx.layout)), m.clone, "new", .{ .would_hide = &places }));
    try testing.expectEqual(@as(usize, 1), places.len);
    try testing.expectEqualStrings(wt, places[0].found.worktree);
    try testing.expectEqual(@as(?@import("sweep.zig").Why, .failed), places[0].found.why);
    try testing.expectEqualStrings(exclude_before, try content.readSmall(a, try block.excludePath(a, c.common_dir)));

    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = index_file, .data = good_index });
    const again = try m.reconcile();
    try testing.expect(again.unsettledCount() == 0);
    try testing.expect(!paths.contains(try blockRels(m), "stale"));
    try m.git(&sb, &.{ "worktree", "remove", wt });
}

test "a probe an interrupted run left: an empty one is removed with its line and never set aside; one holding content is set aside" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "kept");
    _ = try m.keep(".env");
    const wt = try addWorktree(m, &sb, "feature");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const empty = try paths.probeName(a, "00000000000000aa".*);
    const full = try paths.probeName(a, "00000000000000bb".*);
    try block.add(a, c.common_dir, &.{ empty, full });
    try m.write(empty, "");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, empty), .data = "" });
    try m.write(full, "someone's content under a probe's name");

    const plan = try harness.reconcileIn(m.ctx, m.clone, .plan);
    for (plan.items) |i| {
        try testing.expect(!std.mem.eql(u8, i.detail orelse "", empty) and !std.mem.eql(u8, i.rel, empty));
    }

    const r = try m.reconcile();
    for (r.items) |i| {
        try testing.expect(!std.mem.eql(u8, i.detail orelse "", empty) and !std.mem.eql(u8, i.rel, empty));
    }
    try testing.expectEqual(content.Entry.absent, try m.entry(empty));
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try fsutil.joinSlashy(a, wt, empty)));
    const now = try block.read(a, c.common_dir);
    try testing.expect(!paths.contains(now.temps, empty));
    try testing.expect(paths.contains(now.temps, full));
    try testing.expect(!try asideNames(m, empty));
    _ = try expectSwept(m, &sb, r, full, full, "someone's content under a probe's name");
    try m.git(&sb, &.{ "worktree", "remove", wt });
}

test "plan mode on a read-only .git succeeds and writes nothing there, and never creates the clone's state directory" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "kept");
    _ = try m.keep(".env");
    const wt = try addWorktree(m, &sb, "feature");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, ".env"), .data = "the feature tree's own" });
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const state = try clone.stateDir(a, c.common_dir);
    clone.probe_at_root_for_test = true;
    defer clone.probe_at_root_for_test = false;

    for ([_]bool{ false, true }) |read_only| {
        try std.Io.Dir.cwd().deleteTree(io(), state);
        const git_dir = try fsutil.joinSlashy(a, m.clone, ".git");
        if (read_only) try runChmod(a, "a-w", git_dir);
        defer if (read_only) runChmod(a, "u+w", git_dir) catch {};
        if (read_only) {
            if (std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, git_dir, "probe"), .data = "" })) |_| return error.SkipZigTest else |_| {}
        }
        const before = try treeListing(a, git_dir);
        const root_before = try treeListing(a, m.clone);

        const r = try harness.reconcileIn(m.ctx, m.clone, .plan);
        try testing.expectEqual(reconcile_mod.Stop.none, r.stop);
        _ = try expectItem(r, ".env", .ok);
        var saw = false;
        for (r.items) |i| {
            if (i.outcome == .hidden and i.worktree != null and std.mem.eql(u8, i.worktree.?, wt)) saw = true;
        }
        try testing.expect(saw);
        try testing.expectEqual(content.Entry.absent, try content.entryAt(state));
        try testing.expectEqualStrings(before, try treeListing(a, git_dir));
        try testing.expectEqualStrings(root_before, try treeListing(a, m.clone));
    }
}

fn runChmod(a: std.mem.Allocator, how: []const u8, path: []const u8) !void {
    const res = try @import("../proc.zig").run(a, &.{ "chmod", "-R", how, path }, null);
    if (res.status != 0) return error.ChmodFailed;
}

/// Every entry under `root` with its size and modification time, one per
/// line in walk order: equal listings mean nothing under `root` changed.
fn treeListing(a: std.mem.Allocator, root: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var d = try std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true });
    defer d.close(io());
    var walker = try d.walk(a);
    defer walker.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io())) |e| try names.append(a, try a.dupe(u8, e.path));
    std.mem.sort([]const u8, names.items, {}, paths.lessThan);
    for (names.items) |n| {
        const st = try d.statFile(io(), n, .{ .follow_symlinks = false });
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{s} {d} {d}\n", .{ n, st.size, st.mtime.nanoseconds }));
    }
    return out.items;
}

/// The first item with `outcome` about the working tree `wt`.
fn itemIn(r: reconcile_mod.Report, outcome: reconcile_mod.Outcome, wt: []const u8) ?reconcile_mod.Item {
    return itemAt(r, outcome, wt, null);
}

/// The first item with `outcome` about `rel`, when given, in the working
/// tree `wt`.
fn itemAt(r: reconcile_mod.Report, outcome: reconcile_mod.Outcome, wt: []const u8, rel: ?[]const u8) ?reconcile_mod.Item {
    for (r.items) |i| {
        if (i.outcome != outcome or i.worktree == null or !std.mem.eql(u8, i.worktree.?, wt)) continue;
        if (rel == null or std.mem.eql(u8, i.rel, rel.?)) return i;
    }
    return null;
}

/// The first place of `hidden` in the working tree `wt` at `rel`.
fn hiddenAt(hidden: []const place.Hidden, wt: []const u8, rel: []const u8) ?place.Hidden {
    for (hidden) |h| {
        if (std.mem.eql(u8, h.found.worktree, wt) and std.mem.eql(u8, h.found.rel, rel)) return h;
    }
    return null;
}

test "a linked working tree git records but cannot find, moved away or locked and absent, is unsettled, holds its lines, and refuses new ones until it is back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    for ([_]bool{ false, true }) |locked| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try World.init(a, &sb, 1);
        const m = w.m(0);
        try m.write(".env", "the main tree's");
        _ = try m.keep(".env");
        const wt = try addWorktree(m, &sb, "away");
        try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, ".env"), .data = "the away tree's own" });
        if (locked) try m.git(&sb, &.{ "worktree", "lock", wt });
        const moved = try std.fmt.allocPrint(a, "{s}-moved", .{wt});
        try std.Io.Dir.cwd().rename(wt, std.Io.Dir.cwd(), moved, io());

        const r = try m.reconcile();
        const item = itemIn(r, .tree_unreadable, wt) orelse return error.TestUnexpectedResult;
        try testing.expect(item.unsettled);
        try testing.expectEqualStrings("absent", item.detail.?);
        try testing.expect(paths.contains(try blockRels(m), ".env"));
        try m.write("new", "not kept yet");
        var places: []const place.Hidden = &.{};
        try testing.expectError(error.WouldHide, place.keepPath(m.ctx, &(try store.loadIndex(a, m.ctx.layout)), m.clone, "new", .{ .would_hide = &places }));
        try testing.expectEqual(@as(usize, 1), places.len);
        try testing.expectEqualStrings(wt, places[0].found.worktree);
        try testing.expectEqual(@as(?@import("sweep.zig").Why, .tree_unreadable), places[0].found.why);

        const back = if (locked) wt else moved;
        if (locked) {
            try std.Io.Dir.cwd().rename(moved, std.Io.Dir.cwd(), wt, io());
        } else try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ m.clone, ".git", "worktrees", "away", "gitdir" }), .data = try std.fmt.allocPrint(a, "{s}/.git\n", .{moved}) });
        const again = try m.reconcile();
        const swept = itemIn(again, .hidden, back) orelse return error.TestUnexpectedResult;
        try testing.expect(swept.unsettled and swept.entry != null);
        try testing.expect(itemIn(again, .tree_unreadable, wt) == null);
        if (locked) try m.git(&sb, &.{ "worktree", "unlock", back });
        try m.git(&sb, &.{ "worktree", "remove", back });
        try testing.expectEqual(content.Entry.absent, try content.entryAt(back));
        try testing.expect(try inAside(m, ".env", ".env", "the away tree's own"));
    }
}

test "keep where git folds names on a case-sensitive filesystem: a separate file core.ignorecase folds onto the path is set aside before its line is written, and git clean loses nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;

    try m.git(&sb, &.{ "config", "core.ignorecase", "true" });
    try m.write("config.json", "kept");
    try m.write("Config.json", "a separate file");
    const k = try m.keep("config.json");
    const h = hiddenAt(k.hidden, m.clone, "Config.json") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a separate file", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, h.entry.?, "Config.json")));
    try testing.expect(try m.linked("config.json"));

    try m.git(&sb, &.{ "clean", "-fdXq" });
    try testing.expectEqual(content.Entry.absent, try m.entry("Config.json"));
    try testing.expect(try inAside(m, "Config.json", "Config.json", "a separate file"));
}

var late_path: []const u8 = "";

fn writeLate(p: interrupt.Point) void {
    if (p != .keep_pending) return;
    std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = late_path, .data = "made after the check" }) catch unreachable;
}

test "a file another working tree gains after keep checked what its line would hide is set aside by keep's closing sweep, and removing that tree loses nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.hook = null;

    const wt = try addWorktree(m, &sb, "feature");
    late_path = try fsutil.joinSlashy(a, wt, ".env");
    try m.write(".env", "the main tree's");
    interrupt.hook = writeLate;
    const k = try m.keep(".env");
    interrupt.hook = null;
    const h = hiddenAt(k.hidden, wt, ".env") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("made after the check", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, h.entry.?, ".env")));

    try m.git(&sb, &.{ "worktree", "remove", wt });
    try testing.expect(try inAside(m, ".env", ".env", "made after the check"));
}

test "keep's closing sweep sets aside what a line the user wrote in holt's block hides in another working tree, whatever path is kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    try addForeignLine(m, "*.secret");
    const wt = try addWorktree(m, &sb, "feature");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, "notes.secret"), .data = "only in the linked tree" });
    try m.write(".env", "the main tree's");
    const k = try m.keep(".env");
    const h = hiddenAt(k.hidden, wt, "notes.secret") orelse return error.TestUnexpectedResult;
    try testing.expect(h.entry != null);

    try m.git(&sb, &.{ "worktree", "remove", wt });
    try testing.expect(try inAside(m, "notes.secret", "notes.secret", "only in the linked tree"));
}

test "a linked working tree whose path holds a newline is found and swept like any other" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    const p = try std.fs.path.join(a, &.{ std.fs.path.dirname(m.clone).?, "widget@worktrees", "new\nline" });
    try m.git(&sb, &.{ "worktree", "add", "-q", "-b", "nl", p });
    const wt = try fsutil.realPathOrSelf(a, p);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, ".env"), .data = "the newline tree's own" });
    try m.write(".env", "the main tree's");
    const k = try m.keep(".env");
    try testing.expect(hiddenAt(k.hidden, wt, ".env") != null);
    try testing.expect(itemIn(try m.reconcile(), .hidden, wt) != null);

    try m.git(&sb, &.{ "worktree", "remove", wt });
    try testing.expectEqual(content.Entry.absent, try content.entryAt(wt));
    try testing.expect(try inAside(m, ".env", ".env", "the newline tree's own"));
}

/// A copy of the linked working tree `wt` beside it, as `cp -a` or a file
/// manager makes one: its `.git` still names `wt`'s record, so git records
/// the copy under no path of its own.
fn copyWorktree(m: *const Machine, wt: []const u8) ![]const u8 {
    const a = m.ctx.alloc;
    const copy = try std.fmt.allocPrint(a, "{s}-copy", .{wt});
    try content.copyRegular(a, wt, copy);
    return fsutil.realPathOrSelf(a, copy);
}

test "a copy of a linked working tree is reported as sharing git's record and is swept: what a foreign line hides and a separate file core.ignorecase folds onto a kept path are set aside, and git clean there loses nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    const sensitive = try harness.caseSensitive(a, m.clone);

    try m.write("config.json", "kept");
    _ = try m.keep("config.json");
    try addForeignLine(m, "*.secret");
    const wt = try addWorktree(m, &sb, "feature");
    const copy = try copyWorktree(m, wt);
    if (sensitive) try m.git(&sb, &.{ "config", "core.ignorecase", "true" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, copy, "notes.secret"), .data = "only in the copy" });
    if (sensitive) try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, copy, "Config.json"), .data = "a separate file" });

    const r = try harness.reconcileIn(m.ctx, copy, .apply);
    const note = try expectItem(r, ".", .tree_unrecorded);
    try testing.expect(!note.unsettled);
    try testing.expectEqualStrings(wt, note.detail.?);
    const secret = try expectItem(r, "notes.secret", .hidden);
    try testing.expect(secret.unsettled and secret.entry != null and secret.worktree == null);
    if (sensitive) {
        const twin = try expectItem(r, "Config.json", .hidden);
        try testing.expect(twin.unsettled and twin.entry != null);
    }

    try testutil.runGit(&sb, copy, &.{ "clean", "-fdXq" });
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try fsutil.joinSlashy(a, copy, "notes.secret")));
    try testing.expect(try inAside(m, "notes.secret", "notes.secret", "only in the copy"));
    if (sensitive) {
        try testing.expectEqual(content.Entry.absent, try content.entryAt(try fsutil.joinSlashy(a, copy, "Config.json")));
        try testing.expect(try inAside(m, "Config.json", "Config.json", "a separate file"));
    }
}

test "keep in a copy of a linked working tree sets aside, before its line is written, a separate file there that core.ignorecase folds onto the path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;

    const wt = try addWorktree(m, &sb, "feature");
    const copy = try copyWorktree(m, wt);
    try m.git(&sb, &.{ "config", "core.ignorecase", "true" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, copy, ".env"), .data = "kept" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, copy, ".ENV"), .data = "a separate file" });

    const k = try harness.keepIn(m.ctx, copy, ".env");
    const h = hiddenAt(k.hidden, copy, ".ENV") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a separate file", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, h.entry.?, ".ENV")));

    try testutil.runGit(&sb, copy, &.{ "clean", "-fdXq" });
    try testing.expectEqual(content.Entry.absent, try content.entryAt(try fsutil.joinSlashy(a, copy, ".ENV")));
    try testing.expect(try inAside(m, ".ENV", ".ENV", "a separate file"));
}

test "a linked working tree moved with plain mv: the tree git records is unsettled and the moved one, sharing its record, is reported and swept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    try addForeignLine(m, "*.secret");
    const wt = try addWorktree(m, &sb, "feature");
    const moved_path = try std.fmt.allocPrint(a, "{s}-moved", .{wt});
    try std.Io.Dir.cwd().rename(wt, std.Io.Dir.cwd(), moved_path, io());
    const moved = try fsutil.realPathOrSelf(a, moved_path);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, moved, "notes.secret"), .data = "only in the moved tree" });

    const r = try harness.reconcileIn(m.ctx, moved, .apply);
    try testing.expectEqualStrings(wt, (try expectItem(r, ".", .tree_unrecorded)).detail.?);
    try testing.expect((itemIn(r, .tree_unreadable, wt) orelse return error.TestUnexpectedResult).unsettled);
    const secret = try expectItem(r, "notes.secret", .hidden);
    try testing.expect(secret.entry != null and secret.worktree == null);
    try testutil.runGit(&sb, moved, &.{ "clean", "-fdXq" });
    try testing.expect(try inAside(m, "notes.secret", "notes.secret", "only in the moved tree"));
}

test "a kept path's new line that would hide a separate file core.ignorecase folds onto it in the working tree reconciled: fix refuses the line, apply sets the file aside first, and a symlink holt did not make refuses it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    for ([_]reconcile_mod.Mode{ .fix, .apply, .apply }, 0..) |mode, i| {
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try World.init(a, &sb, 2);
        const ma = w.m(0);
        const mb = w.m(1);
        if (!try harness.caseSensitive(a, mb.clone)) return error.SkipZigTest;
        try ma.write("config.json", "kept");
        _ = try ma.keep("config.json");
        try w.deliver(0, 1);
        try mb.git(&sb, &.{ "config", "core.ignorecase", "true" });
        const as_link = i == 2;
        if (as_link) {
            try content.createLink(try mb.path("elsewhere"), try mb.path("Config.json"), .file);
        } else try mb.write("Config.json", "B's separate file");

        const r = try harness.reconcileIn(mb.ctx, mb.clone, mode);
        if (mode == .apply and !as_link) {
            const item = try expectItem(r, "Config.json", .hidden);
            try testing.expect(item.done and item.entry != null);
            try testing.expect(try mb.linked("config.json"));
            try testing.expect(paths.contains(try blockRels(mb), "config.json"));
            try mb.git(&sb, &.{ "clean", "-fdXq" });
            try testing.expect(try inAside(mb, "Config.json", "Config.json", "B's separate file"));
            continue;
        }
        try testing.expectEqualStrings("config.json", (try expectItem(r, "config.json", .line_refused)).detail.?);
        if (as_link) _ = try expectItem(r, "Config.json", .hidden_not_copyable);
        try testing.expect(!paths.contains(try blockRels(mb), "config.json"));
        try testing.expectEqual(content.Entry.absent, try mb.entry("config.json"));
        try testing.expect(std.mem.indexOf(u8, try gitStatus(mb), "Config.json") != null);
    }
}

test "the clone's own lock serializes every writer of its state, whatever holt state directory each uses: apply, fix, and keep wait for it, plan does not, and a state directory that cannot be made refuses the writers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try m.write("new", "not kept yet");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const state = try clone.stateDir(a, c.common_dir);
    ctx_mod.lock_nonblocking_for_test = true;
    defer ctx_mod.lock_nonblocking_for_test = false;

    {
        const other = try @import("../projectlock.zig").acquireAt(try std.fs.path.join(a, &.{ state, "lock" }));
        defer other.release();
        try testing.expectError(error.WouldBlock, harness.reconcileIn(m.ctx, m.clone, .apply));
        try testing.expectError(error.WouldBlock, harness.reconcileIn(m.ctx, m.clone, .fix));
        try testing.expectError(error.WouldBlock, m.keep("new"));
        _ = try expectItem(try harness.reconcileIn(m.ctx, m.clone, .plan), ".env", .ok);
    }

    try std.Io.Dir.cwd().deleteTree(io(), state);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = state, .data = "not a directory" });
    try testing.expectError(error.CloneStateUnwritable, harness.reconcileIn(m.ctx, m.clone, .apply));
    try testing.expectError(error.CloneStateUnwritable, harness.reconcileIn(m.ctx, m.clone, .fix));
    try testing.expectError(error.CloneStateUnwritable, m.keep("new"));
}

test "a half-made worktree record and a file among the records hold no line and refuse none; the half-made record is reported as information" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const records = try std.fs.path.join(a, &.{ c.common_dir, "worktrees" });
    try fsutil.ensureDir(try std.fs.path.join(a, &.{ records, "half" }));
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try std.fs.path.join(a, &.{ records, "stray" }), .data = "not a record" });
    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try testing.expect(try m.linked(".env"));

    const r = try m.reconcile();
    const half = try expectItem(r, ".", .half_created_record);
    try testing.expect(!half.unsettled);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ records, "half" }), half.detail.?);
    try testing.expectEqual(@as(usize, 0), r.unsettledCount());
}

test "a clone whose main repository is bare: a linked working tree keeps and reconciles, and the bare repository is never judged as a working tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    const main = try fsutil.joinSlashy(a, m.code, "github.com/acme/tools");
    const common = try std.fs.path.join(a, &.{ main, ".git" });
    try testutil.runGit(&sb, null, &.{ "clone", "-q", "--bare", w.bare, common });
    const wt_path = try fsutil.joinSlashy(a, m.code, "github.com/acme/tools@worktrees/feature");
    try testutil.runGit(&sb, common, &.{ "worktree", "add", "-q", "-b", "feature", wt_path });
    const wt = try fsutil.realPathOrSelf(a, wt_path);
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, ".env"), .data = "kept" });

    const k = try harness.keepIn(m.ctx, wt, ".env");
    try testing.expectEqual(@as(usize, 0), k.hidden.len);
    const r = try harness.reconcileIn(m.ctx, wt, .apply);
    try testing.expectEqual(reconcile_mod.Stop.none, r.stop);
    try testing.expectEqual(@as(usize, 0), r.unsettledCount());
    _ = try expectItem(r, ".env", .ok);
}

test "a symlink holt did not make, in another working tree: a line that would hide it is refused by keep and reconcile, and one a line already hides is reported" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    const wt = try addWorktree(m, &sb, "feature");
    try content.createLink("/somewhere/else", try fsutil.joinSlashy(a, wt, ".env"), .file);
    try m.write(".env", "the main tree's");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const exclude_before = try content.readSmall(a, try block.excludePath(a, c.common_dir));

    var places: []const place.Hidden = &.{};
    try testing.expectError(error.WouldHide, place.keepPath(m.ctx, &(try store.loadIndex(a, m.ctx.layout)), m.clone, ".env", .{ .would_hide = &places }));
    try testing.expectEqual(@as(usize, 1), places.len);
    try testing.expectEqualStrings(wt, places[0].found.worktree);
    try testing.expectEqual(@as(?@import("sweep.zig").Why, .not_copyable), places[0].found.why);
    try testing.expectEqualStrings(exclude_before, try content.readSmall(a, try block.excludePath(a, c.common_dir)));

    try fsutil.removePath(try m.path(".env"));
    const b = w.m(1);
    try b.write(".env", "kept on b");
    _ = try b.keep(".env");
    try w.sync();
    const r = try m.reconcile();
    try testing.expect((try expectItem(r, ".env", .line_refused)).unsettled);
    try testing.expect((itemAt(r, .hidden_not_copyable, wt, ".env") orelse return error.TestUnexpectedResult).unsettled);
    try testing.expect(!paths.contains(try blockRels(m), ".env"));

    try content.createLink("/somewhere/else", try fsutil.joinSlashy(a, wt, "seed"), .file);
    const swept = try m.reconcile();
    const item = itemAt(swept, .hidden_not_copyable, wt, "seed") orelse return error.TestUnexpectedResult;
    try testing.expect(item.unsettled and item.entry == null);

    try testutil.runGit(&sb, wt, &.{ "clean", "-fdXq" });
    try testing.expectEqualStrings("/somewhere/else", (try content.readLink(a, try fsutil.joinSlashy(a, wt, ".env"))).?);
}

test "a clone whose core.worktree names another directory has no key: keep refuses and reconcile stops, touching nothing there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("seed", "s");
    _ = try m.keep("seed");
    const elsewhere = try fsutil.realPathOrSelf(a, try std.fs.path.join(a, &.{ sb.root, "elsewhere" }));
    try fsutil.ensureDir(elsewhere);
    const env_file = try std.fs.path.join(a, &.{ elsewhere, ".env" });
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = env_file, .data = "not the clone's" });
    try m.git(&sb, &.{ "config", "core.worktree", elsewhere });

    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try testing.expect(c.key == null and c.worktreeElsewhere());
    try testing.expectError(error.WorktreeElsewhere, m.keep(".env"));
    const r = try m.reconcile();
    try testing.expectEqual(reconcile_mod.Stop.worktree_elsewhere, r.stop);
    try testing.expectEqual(content.Entry.file, try content.entryAt(env_file));
    try testing.expect(!try asideNames(m, ".env"));
}

test "fix mode probes how the working tree's filesystem compares names, as apply does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    if (!try harness.caseSensitive(a, m.clone)) return error.SkipZigTest;
    clone.probe_at_root_for_test = true;
    defer clone.probe_at_root_for_test = false;

    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try fsutil.removePath(try m.path(".env"));
    try m.write(".ENV", "tracked under another spelling");
    try m.git(&sb, &.{ "add", "-f", ".ENV" });
    try fsutil.removePath(try m.path(".ENV"));
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try std.Io.Dir.cwd().deleteTree(io(), try clone.stateDir(a, c.common_dir));

    const r = try harness.reconcileIn(m.ctx, m.clone, .fix);
    try testing.expect((try expectItem(r, ".env", .linked)).done);
}

test "a probe of how names compare that fails in apply or fix is reported as information, and names are taken to fold both ways" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    clone.probe_at_root_for_test = true;
    defer clone.probe_at_root_for_test = false;

    try m.write(".env", "kept");
    _ = try m.keep(".env");
    try runChmod(a, "a-w", m.clone);
    defer runChmod(a, "u+w", m.clone) catch {};
    if (std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try m.path("probe"), .data = "" })) |_| return error.SkipZigTest else |_| {}
    try runChmod(a, "u+w", try m.path(".git"));

    for ([_]reconcile_mod.Mode{ .apply, .fix }) |mode| {
        const r = try harness.reconcileIn(m.ctx, m.clone, mode);
        const item = try expectItem(r, ".", .fold_unknown);
        try testing.expect(!item.unsettled and item.detail != null);
        try testing.expectEqual(@as(usize, 0), r.unsettledCount());
        _ = try expectItem(r, ".env", .ok);
    }
    try testing.expect((try harness.reconcileIn(m.ctx, m.clone, .plan)).find(".", .fold_unknown) == null);
}

test "a unit the block hides that holds a nested repository deeper: the repository is reported, and the rest is set aside and listed as a candidate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("first.md", "kept, so the key exists");
    _ = try m.keep("first.md");
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    try block.add(a, c.common_dir, &.{"vendor"});
    try m.write("vendor/notes.md", "only here");
    try m.write("vendor/repo/work.txt", "committed in the nested repository");
    try testutil.runGit(&sb, try m.path("vendor/repo"), &.{ "init", "-q" });

    const index = try store.loadIndex(a, m.ctx.layout);
    const l = try @import("candidates.zig").list(m.ctx, &index, m.clone, .{});
    try testing.expectEqual(@as(usize, 1), l.nested.len);
    try testing.expectEqualStrings("vendor/repo", l.nested[0].repo);
    try testing.expectEqual(@as(usize, 1), l.candidates.len);
    try testing.expectEqualStrings("vendor", l.candidates[0].rel);

    const r = try m.reconcile();
    const nr = try expectItem(r, "vendor/repo", .nested_repository);
    try testing.expect(nr.unsettled and nr.entry == null);
    const set_aside = for (r.items) |it| {
        if (std.mem.eql(u8, it.rel, "vendor") and it.entry != null) break true;
    } else false;
    try testing.expect(set_aside);
    try testing.expect(try inAside(m, "vendor", "vendor/notes.md", "only here"));
    try testing.expect(!try inAside(m, "vendor", "vendor/repo/work.txt", "committed in the nested repository"));
}

test "holt's link at a path no fact names while its kept copy exists is reported unsettled, and keep records it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".clasp.json", "{\"scriptId\": \"abc\"}");
    _ = try m.keep(".clasp.json");
    try store.removeFacts(a, m.ctx.layout, key, ".clasp.json");

    const r = try m.reconcile();
    try testing.expect((try expectItem(r, ".clasp.json", .unrecorded_link)).unsettled);
    try testing.expect(try m.linked(".clasp.json"));

    const again = try m.keep(".clasp.json");
    try testing.expect(again.status == .kept);
    try testing.expectEqual(@as(usize, 1), (try store.loadKeyState(a, m.ctx.layout, key)).factsFor(".clasp.json").len);
    try testing.expectEqual(@as(usize, 0), (try m.reconcile()).unsettledCount());
    try testing.expectEqualStrings("{\"scriptId\": \"abc\"}", try m.read(".clasp.json"));
}

test "plan mode takes no lock, so it never waits on a writer and creates no lock file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".clasp.json", "{\"scriptId\": \"abc\"}");
    _ = try m.keep(".clasp.json");
    try fsutil.removePath(try m.path(".clasp.json"));

    ctx_mod.lock_nonblocking_for_test = true;
    defer ctx_mod.lock_nonblocking_for_test = false;
    const c = try clone.inspect(a, m.clone, m.ctx.code_root);
    const clone_lock = try ctx_mod.lockClone(m.ctx, c.common_dir);
    defer clone_lock.release();
    const key_lock = try ctx_mod.lockKey(m.ctx, key);
    defer key_lock.release();
    var trace: std.ArrayList([]const u8) = .empty;
    ctx_mod.lock_trace_for_test = &trace;
    defer ctx_mod.lock_trace_for_test = null;

    const r = try harness.reconcileIn(m.ctx, m.clone, .plan);
    try testing.expect(r.find(".clasp.json", .linked) != null);
    try testing.expectEqual(@as(usize, 0), trace.items.len);
}

test "a directory keep over kept files another working tree links file by file proceeds: holt's links there are neither set aside nor refused" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("cfg/a.txt", "a");
    _ = try m.keep("cfg/a.txt");
    const wt = try addWorktree(m, &sb, "feature");
    _ = try harness.reconcileIn(m.ctx, wt, .apply);
    const wt_link = try fsutil.joinSlashy(a, wt, "cfg/a.txt");
    try testing.expectEqualStrings(try m.keptPath("cfg/a.txt"), (try content.readLink(a, wt_link)).?);

    try m.write("cfg/b.txt", "b");
    var places: []const place.Hidden = &.{};
    const got = try place.keepPath(m.ctx, &(try store.loadIndex(a, m.ctx.layout)), m.clone, "cfg", .{ .would_hide = &places });
    try testing.expect(got.status == .kept);
    for (got.hidden) |h| try testing.expect(!std.mem.eql(u8, h.found.worktree, wt));
    try testing.expectEqualStrings("a", try content.readSmall(a, wt_link));
}

test "a directory keep over a directory another working tree holds holt's links and its own files in: the files are set aside, the links are no refusal" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);

    try m.write("cfg/a.txt", "a");
    _ = try m.keep("cfg/a.txt");
    const wt = try addWorktree(m, &sb, "feature");
    _ = try harness.reconcileIn(m.ctx, wt, .apply);
    try fsutil.ensureDir(try fsutil.joinSlashy(a, wt, "cfg"));
    try std.Io.Dir.cwd().writeFile(fsutil.io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, "cfg/c.txt"), .data = "only in the feature tree" });

    try m.write("cfg/b.txt", "b");
    var places: []const place.Hidden = &.{};
    const got = try place.keepPath(m.ctx, &(try store.loadIndex(a, m.ctx.layout)), m.clone, "cfg", .{ .would_hide = &places });
    try testing.expect(got.status == .kept);
    var held = false;
    for (got.hidden) |h| {
        if (!std.mem.eql(u8, h.found.worktree, wt)) continue;
        try testing.expect(h.found.why == null);
        const e = h.entry orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("only in the feature tree", try content.readSmall(a, try aside.dataPath(a, m.ctx.layout, e, "cfg/c.txt")));
        held = true;
    }
    try testing.expect(held);
}

test "after a directory keep, a directory holding only holt's links to the kept files in it is replaced by the directory's link, on another machine and in another working tree" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 2);
    const m = w.m(0);
    const b = w.m(1);

    try m.write("cfg/a.txt", "a");
    _ = try m.keep("cfg/a.txt");
    const wt = try addWorktree(m, &sb, "feature");
    _ = try harness.reconcileIn(m.ctx, wt, .apply);
    try w.sync();
    _ = try b.reconcile();
    try testing.expect(try b.linked("cfg/a.txt"));

    try m.write("cfg/b.txt", "b");
    _ = try m.keep("cfg");
    try testing.expect(try m.linked("cfg"));
    try w.sync();

    const r = try b.reconcile();
    try testing.expect(r.find("cfg", .local_not_regular) == null);
    try testing.expect(try b.linked("cfg"));
    try testing.expectEqualStrings("b", try b.read("cfg/b.txt"));
    try testing.expectEqual(@as(usize, 0), r.unsettledCount());

    const rw = try harness.reconcileIn(m.ctx, wt, .apply);
    try testing.expectEqual(@as(usize, 0), rw.unsettledCount());
    try testing.expectEqualStrings(try m.keptPath("cfg"), (try content.readLink(a, try fsutil.joinSlashy(a, wt, "cfg"))).?);
}

test "replacing a directory of holt's links with the kept directory's link, interrupted at each point, is finished by the next reconcile" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    for ([_]interrupt.Point{ .link_moved, .link_created }) |point| {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var sb = try testutil.Sandbox.init(testing.allocator);
        defer sb.deinit();
        var w = try World.init(a, &sb, 2);
        const m = w.m(0);
        const b = w.m(1);
        defer interrupt.at = null;

        try m.write("cfg/a.txt", "a");
        _ = try m.keep("cfg/a.txt");
        try w.sync();
        _ = try b.reconcile();
        try m.write("cfg/b.txt", "b");
        _ = try m.keep("cfg");
        try w.sync();

        interrupt.at = point;
        const cut = try b.reconcile();
        interrupt.at = null;
        try testing.expectEqualStrings("Interrupted", (try expectItem(cut, "cfg", .failed)).detail.?);
        const r = try b.reconcile();
        try testing.expectEqual(@as(usize, 0), r.unsettledCount());
        try testing.expect(try b.linked("cfg"));
        try testing.expectEqualStrings("a", try b.read("cfg/a.txt"));
        try testing.expectEqual(content.Entry.absent, try b.entry(try paths.tempRel(a, "cfg")));
    }
}

/// Skips a test that relies on a directory's permissions refusing a
/// write: Windows has no such modes, and root ignores them.
fn requireModesEnforced() !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const euid = if (builtin.os.tag == .linux) std.os.linux.geteuid() else std.c.geteuid();
    if (euid == 0) return error.SkipZigTest;
}

/// Whether the working tree `worktree` has a pending record for `rel`.
fn hasPending(ctx: ctx_mod.Ctx, worktree: []const u8, rel: []const u8) !bool {
    const c = try clone.inspect(ctx.alloc, worktree, ctx.code_root);
    return clone.findPending(try clone.readPending(ctx.alloc, c.common_dir), c.tree, rel) != null;
}

fn blockTemps(m: *const Machine) ![]const []const u8 {
    const c = try clone.inspect(m.ctx.alloc, m.clone, m.ctx.code_root);
    return (try block.read(m.ctx.alloc, c.common_dir)).temps;
}

/// Keeps `rel` in `worktree` while the aside directory refuses writes,
/// expecting a real error rather than an interruption.
fn keepAsideRefused(m: *const Machine, worktree: []const u8, rel: []const u8) !void {
    const asides = try m.ctx.layout.asideDir(m.ctx.alloc);
    try fsutil.ensureDir(asides);
    try chmod(asides, 0o555);
    defer chmod(asides, 0o755) catch {};
    if (harness.keepIn(m.ctx, worktree, rel)) |_| {
        return error.TestUnexpectedResult;
    } else |err| try testing.expect(err != error.Interrupted);
}

/// Removes every aside entry of `rel`, so set-aside cannot reuse one.
fn removeAsideEntries(m: *const Machine, rel: []const u8) !void {
    const a = m.ctx.alloc;
    for (try aside.findEntries(a, m.ctx.layout, key, rel, null)) |stamp| {
        try std.Io.Dir.cwd().deleteTree(io(), try std.fs.path.join(a, &.{ try m.ctx.layout.asideDir(a), stamp }));
    }
}

test "a keep whose set-aside fails leaves the path as it was: no line, no pending record, and keeping again succeeds" {
    try requireModesEnforced();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write("seed", "creates the store");
    _ = try m.keep("seed");

    try m.write(".env", "mine");
    try keepAsideRefused(m, m.clone, ".env");
    try testing.expect(!paths.contains(try blockRels(m), ".env"));
    try testing.expect(!paths.contains(try blockTemps(m), try paths.tempRel(a, ".env")));
    try testing.expect(!try hasPending(m.ctx, m.clone, ".env"));
    try testing.expectEqualStrings("mine", try m.read(".env"));

    _ = try m.keep(".env");
    try testing.expect(try m.linked(".env"));
    try testing.expectEqualStrings("mine", try m.read(".env"));
}

test "a keep whose set-aside fails in a second working tree leaves the line another working tree's link needs" {
    try requireModesEnforced();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write(".env", "kept");
    _ = try m.keep(".env");
    const wt = try addWorktree(m, &sb, "feature");
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = try fsutil.joinSlashy(a, wt, ".env"), .data = "kept" });

    try removeAsideEntries(m, ".env");
    try keepAsideRefused(m, wt, ".env");
    try testing.expect(paths.contains(try blockRels(m), ".env"));
    try testing.expect(!try hasPending(m.ctx, wt, ".env"));
    try testing.expect(try m.linked(".env"));
    try testing.expectEqualStrings("", try gitStatus(m));
}

test "a re-run keep whose set-aside fails after an interrupted keep wrote its fact leaves that keep's line and pending record" {
    try requireModesEnforced();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    defer interrupt.at = null;
    try m.write("seed", "creates the store");
    _ = try m.keep("seed");

    try m.write(".env", "mine");
    interrupt.at = .keep_fact;
    try testing.expectError(error.Interrupted, m.keep(".env"));
    interrupt.at = null;

    try removeAsideEntries(m, ".env");
    try keepAsideRefused(m, m.clone, ".env");
    try testing.expect(paths.contains(try blockRels(m), ".env"));
    try testing.expect(paths.contains(try blockTemps(m), try paths.tempRel(a, ".env")));
    try testing.expect(try hasPending(m.ctx, m.clone, ".env"));

    _ = try m.keep(".env");
    try testing.expect(try m.linked(".env"));
    try testing.expectEqualStrings("mine", try m.read(".env"));
}

fn retiredWords(_: std.mem.Allocator, _: store.Retired) anyerror![]const u8 {
    return "retired";
}

test "a keep that fails after writing its fact is left interrupted, and keeping again finishes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write("seed", "creates the store");
    _ = try m.keep("seed");
    try store.writeRetired(a, m.ctx.layout, &(try store.loadIndex(a, m.ctx.layout)), m.ctx.machine_id, "2026-01-01", "host", m.ctx.machine_id);

    var failing: std.Io.Writer = .failing;
    var notice: ctx_mod.RetiredNotice = .{ .err = &failing, .words = retiredWords };
    m.ctx.retired_notice = &notice;
    defer m.ctx.retired_notice = null;
    try m.write(".env", "mine");
    try testing.expectError(error.WriteFailed, m.keep(".env"));
    m.ctx.retired_notice = null;

    try testing.expectEqual(@as(usize, 1), (try store.loadKeyState(a, m.ctx.layout, key)).factsFor(".env").len);
    try testing.expect(paths.contains(try blockRels(m), ".env"));
    try testing.expect(try hasPending(m.ctx, m.clone, ".env"));
    _ = try expectItem(try m.reconcile(), ".env", .interrupted);

    _ = try m.keep(".env");
    try testing.expect(try m.linked(".env"));
    try testing.expectEqualStrings("mine", try m.read(".env"));
}

test "a merge whose set-aside fails: the next reconcile links the absorbed paths again" {
    try requireModesEnforced();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var sb = try testutil.Sandbox.init(testing.allocator);
    defer sb.deinit();
    var w = try World.init(a, &sb, 1);
    const m = w.m(0);
    try m.write("notes/a", "A");
    _ = try m.keep("notes/a");
    try m.write("notes/sub/b", "B");

    try keepAsideRefused(m, m.clone, "notes");
    try testing.expect(!try m.linked("notes/a"));
    try testing.expect(!paths.contains(try blockRels(m), "notes"));
    try testing.expect(!try hasPending(m.ctx, m.clone, "notes"));

    _ = try m.reconcile();
    try testing.expect(try m.linked("notes/a"));
    try testing.expectEqualStrings("A", try m.read("notes/a"));
    try testing.expectEqualStrings("B", try m.read("notes/sub/b"));
}
