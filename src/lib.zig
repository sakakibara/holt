//! Pure re-export of the internal modules the performance harness
//! (`bench/bench.zig`) needs. `bench/` is compiled as its own build module,
//! and Zig's module boundary rejects a `../src/...` relative import reaching
//! outside it; this file is the one thing that module imports by name, so it
//! can reach `src/`'s internals without main.zig itself exposing them.
pub const fsutil = @import("fsutil.zig");
pub const workspace = @import("workspace.zig");
pub const testutil = @import("testutil.zig");
pub const marker = @import("marker.zig");
pub const app = @import("app.zig");
pub const recent_cmd = @import("commands/recent.zig");
pub const status_cmd = @import("commands/status.zig");
pub const sync_cmd = @import("commands/sync.zig");
pub const doctor_cmd = @import("commands/doctor.zig");
