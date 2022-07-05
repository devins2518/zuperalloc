const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Atomic;
const Halloc = @import("Halloc.zig");
const Lalloc = @import("Lalloc.zig");
const Salloc = @import("Salloc.zig");
const Self = @This();

backing_alloc: Allocator = std.heap.page_allocator,
sally: Salloc = .{},
lally: Lalloc = .{},
hally: Halloc = .{},

pub fn init() Self {
    return .{};
}

pub fn deinit(self: *Self) void {
    self.sally.deinit();
    self.lally.deinit();
    self.hally.deinit();
}

pub fn allocator(self: *Self) Allocator {
    return Allocator.init(self, alloc, Allocator.NoResize(Self).noResize, Allocator.NoOpFree(Self).noOpFree);
}

// Zalloc uses three size categories to decide how to allocate the object: small, large, and huge.
fn alloc(self: *Self, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) Allocator.Error![]u8 {
    return self.backing_alloc.rawAlloc(len, ptr_align, len_align, ret_addr);
}

test "static analysis" {
    std.testing.refAllDecls(Self);
}

test "test allocator" {
    var zalloc = std.mem.validationWrap(Self.init());
    const child = zalloc.allocator();

    try std.heap.testAllocator(child);
    try std.heap.testAllocatorAligned(child);
    try std.heap.testAllocatorLargeAlignment(child);
    try std.heap.testAllocatorAlignedShrink(child);
}
