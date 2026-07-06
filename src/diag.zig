const std = @import("std");
const testing = std.testing;

/// Human-facing message for an error that a payload-less Zig error union
/// cannot carry. Callers that want the message pass a pointer; callers that
/// do not care pass null. Message memory is arena-owned (per-command arena).
pub const Diagnostic = struct {
    message: []const u8 = "",

    pub fn set(self: *Diagnostic, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        self.message = std.fmt.allocPrint(alloc, fmt, args) catch "out of memory";
    }
};

test "Diagnostic.set: formats and stores the message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: Diagnostic = .{};
    d.set(arena, "unknown value \"{s}\" (want {s})", .{ "dropbox", "icloud" });
    try testing.expect(std.mem.indexOf(u8, d.message, "dropbox") != null);
    try testing.expect(std.mem.indexOf(u8, d.message, "icloud") != null);
}
