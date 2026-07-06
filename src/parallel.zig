//! Bounded-concurrency parallel map for the multi-repo read commands. Spawns
//! at most `workerCount` OS threads that cooperatively claim task indices from
//! a shared atomic counter; each task writes its result into its own index
//! slot, so results stay in input order with no lock on the result array.
//!
//! Thread-safety invariant: every task runs `fn(context, arena, item) -> out`
//! where `arena` is that task's OWN allocator (one per task, backed by
//! std.heap.page_allocator, created and owned here). A task must allocate only
//! from its `arena` - never the caller's per-command arena, which is not
//! thread-safe. `context` and `items` are read-only inputs shared across
//! tasks. The git helpers a task calls are safe to invoke concurrently: each
//! builds a fresh std.Io.Threaded and only READS the immutable process-environ
//! singleton. Any memory a task's result references lives in that task's arena,
//! which stays alive until `Arenas.deinit`, so the caller must finish
//! rendering/copying every result on the main thread before deinit.

const std = @import("std");

/// Default cap used when the caller does not pass an explicit `-j`/`--jobs`.
pub const default_cap = 16;

/// Concurrency N = max(1, min(cap orelse default_cap, cpu_count, task_count)).
/// `cap == 1` forces a fully serial run (the oracle for the parallel path);
/// an explicit cap is still bounded by the CPU count. Zero tasks -> zero
/// workers.
pub fn workerCount(cap: ?usize, task_count: usize) usize {
    if (task_count == 0) return 0;
    const cpu = std.Thread.getCpuCount() catch 4;
    const configured = cap orelse default_cap;
    const bounded = @min(@min(configured, cpu), task_count);
    return @max(@as(usize, 1), bounded);
}

/// Owns the per-task arenas; the caller deinits it once every result has been
/// rendered or copied off the worker arenas on the main thread.
pub const Arenas = struct {
    arenas: []std.heap.ArenaAllocator,
    setup_alloc: std.mem.Allocator,

    pub fn deinit(self: *Arenas) void {
        for (self.arenas) |*a| a.deinit();
        self.setup_alloc.free(self.arenas);
    }
};

/// Runs `task` over every item with `workerCount(cap, items.len)` threads,
/// writing each result into `results[i]`. `results.len` must equal
/// `items.len`. `setup_alloc` (main-thread only) backs the arenas array and
/// the thread handles. Returns the arenas the caller must eventually deinit.
pub fn map(
    comptime Context: type,
    comptime Item: type,
    comptime Out: type,
    comptime task: fn (Context, std.mem.Allocator, Item) Out,
    setup_alloc: std.mem.Allocator,
    cap: ?usize,
    context: Context,
    items: []const Item,
    results: []Out,
) !Arenas {
    std.debug.assert(results.len == items.len);
    const n = items.len;

    const arenas = try setup_alloc.alloc(std.heap.ArenaAllocator, n);
    for (arenas) |*a| a.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer {
        for (arenas) |*a| a.deinit();
        setup_alloc.free(arenas);
    }

    const owned: Arenas = .{ .arenas = arenas, .setup_alloc = setup_alloc };
    if (n == 0) return owned;

    const Shared = struct {
        next: std.atomic.Value(usize) = .init(0),
        items: []const Item,
        results: []Out,
        arenas: []std.heap.ArenaAllocator,
        context: Context,

        fn run(self: *@This()) void {
            while (true) {
                const i = self.next.fetchAdd(1, .monotonic);
                if (i >= self.items.len) break;
                const arena = self.arenas[i].allocator();
                self.results[i] = task(self.context, arena, self.items[i]);
            }
        }
    };

    var shared: Shared = .{ .items = items, .results = results, .arenas = arenas, .context = context };

    const workers = workerCount(cap, n);
    if (workers <= 1) {
        shared.run();
        return owned;
    }

    // The main thread is one worker; spawn the other `workers - 1`. A failed
    // spawn is not fatal - the atomic claim counter still hands every task to
    // whichever threads did start (including this one).
    const threads = try setup_alloc.alloc(std.Thread, workers - 1);
    defer setup_alloc.free(threads);
    var spawned: usize = 0;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, Shared.run, .{&shared}) catch break;
        spawned += 1;
    }

    shared.run();

    for (threads[0..spawned]) |t| t.join();
    return owned;
}

const testing = std.testing;

test "workerCount: zero tasks yields zero, cap 1 stays serial, capped by task count" {
    try testing.expectEqual(@as(usize, 0), workerCount(null, 0));
    try testing.expectEqual(@as(usize, 1), workerCount(1, 100));
    try testing.expectEqual(@as(usize, 3), workerCount(8, 3));
}

test "map: squares every element in stable order at both serial and parallel caps" {
    const square = struct {
        fn f(_: void, arena: std.mem.Allocator, x: usize) usize {
            // Allocate from the task's own arena to exercise the invariant.
            const buf = arena.alloc(usize, 1) catch unreachable;
            buf[0] = x * x;
            return buf[0];
        }
    }.f;

    var items: [64]usize = undefined;
    for (&items, 0..) |*it, i| it.* = i;

    inline for (.{ @as(?usize, 1), @as(?usize, 8) }) |cap| {
        var results: [64]usize = undefined;
        var arenas = try map(void, usize, usize, square, testing.allocator, cap, {}, &items, &results);
        defer arenas.deinit();
        for (results, 0..) |r, i| try testing.expectEqual(i * i, r);
    }
}
