pub const Zalloc = @import("Zalloc.zig");

test "static analysis" {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("Chunk.zig");
    _ = @import("footprint.zig");
    _ = @import("Halloc.zig");
    _ = @import("Halloc.zig");
    _ = @import("Lalloc.zig");
    _ = @import("random.zig");
    _ = @import("Salloc.zig");
    _ = @import("static_bin.zig");
    _ = @import("utils.zig");
    _ = @import("Zalloc.zig");
}
