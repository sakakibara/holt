//! Kept files: files git does not carry that live in the synced root under
//! `kept/<key>/` and are linked into every clone of their repo. This module
//! is the store, its markers, the `info/exclude` block, aside entries,
//! staging and placement, reconcile, the skip and auto pattern lists, and
//! candidates, and the explicit commands beside keep; commands build on
//! it.

const ctx_mod = @import("kept/ctx.zig");

pub const paths = @import("kept/paths.zig");
pub const content = @import("kept/content.zig");
pub const machine = @import("kept/machine.zig");
pub const store = @import("kept/store.zig");
pub const block = @import("kept/block.zig");
pub const aside = @import("kept/aside.zig");
pub const clone = @import("kept/clone.zig");
pub const link = @import("kept/link.zig");
pub const place = @import("kept/place.zig");
pub const sweep = @import("kept/sweep.zig");
pub const reconcile = @import("kept/reconcile.zig");
pub const patterns = @import("kept/patterns.zig");
pub const candidates = @import("kept/candidates.zig");
pub const ops = @import("kept/ops.zig");
pub const rekey = @import("kept/rekey.zig");

pub const Ctx = ctx_mod.Ctx;
pub const lockKey = ctx_mod.lockKey;
pub const lockKeys = ctx_mod.lockKeys;
pub const lockClone = ctx_mod.lockClone;
pub const Held = ctx_mod.Held;
pub const Lock = ctx_mod.Lock;
pub const KeyLocks = ctx_mod.Pair;
pub const lockAll = ctx_mod.lockAll;
pub const KeySet = ctx_mod.Set;
pub const RunScratch = ctx_mod.RunScratch;
pub const RetiredNotice = ctx_mod.RetiredNotice;

test {
    _ = paths;
    _ = content;
    _ = machine;
    _ = store;
    _ = block;
    _ = aside;
    _ = clone;
    _ = link;
    _ = place;
    _ = sweep;
    _ = reconcile;
    _ = patterns;
    _ = candidates;
    _ = ops;
    _ = rekey;
    _ = @import("kept/harness.zig");
    _ = ctx_mod;
    _ = @import("kept/scenarios.zig");
}
