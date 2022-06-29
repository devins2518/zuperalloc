pub const Zalloc = @import("Zalloc.zig");

test "static analysis" {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("Zalloc.zig");
    _ = @import("utils.zig");
    _ = @import("Cache.zig");
}
