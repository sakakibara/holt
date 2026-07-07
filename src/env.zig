//! Cross-platform environment access. holt reads a couple of env vars for
//! behavior toggles; the posix environ block API is not available on
//! Windows, so route reads through here.

const std = @import("std");

/// True iff `name` is present in the environment (any value, including
/// empty). `name` must be comptime-known: `std.process.Environ.containsConstant`
/// walks the Windows PEB directly (no allocation) for a comptime key, and
/// falls back to the posix environ scan otherwise.
pub fn has(comptime name: []const u8) bool {
    return std.Io.Threaded.global_single_threaded.environ.process_environ.containsConstant(name);
}

test "has: reflects presence" {
    // NO_COLOR is not something the test runner sets; PATH essentially always is.
    try std.testing.expect(has("PATH") or has("Path"));
}
