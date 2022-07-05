const std = @import("std");
pub const Zalloc = if (@bitSizeOf(usize) <= 32)
    @compileError(
        \\Zalloc is designed with 64-bit machines in mind. Many of its design choices rely 
        \\on the fact that virtual address space is cheap on 64-bit systems compared to 
        \\physical address space while it is just as expensive on 32-bit systems. One example 
        \\is the table used to keep track of chunk numbers: it is around 512Mb, yet it 
        \\will likely be only a few pages because pages are committed lazily. There are 
        \\no plans to support 32-bit systems at the moment.
    )
else
    @import("Zalloc.zig");

test "static analysis" {
    std.testing.refAllDecls(@This());
    _ = @import("Zalloc.zig");
}
