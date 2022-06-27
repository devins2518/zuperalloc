const std = @import("std");
pub const Zalloc = if (@bitSizeOf(usize) >= 64)
    @import("Zalloc.zig")
else
    @compileError(
        \\Zalloc's design patterns exploit the fact that mapping virtual memory is 
        \\less expensive than mapping physical memory. This does not hold true for 
        \\32bit systems where virtual space is equal to physical space.
    );

test "static analysis" {
    _ = @import("Zalloc.zig");
    std.testing.refAllDecls(@This());
}
