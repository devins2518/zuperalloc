const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();

pub fn alloc(self: *Self) Allocator.Error![]u8 {}

pub fn deinit(_: *Self) void {}
