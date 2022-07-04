const Self = @This();

pub fn hugeAlloc(_: *Self, _: usize) ?[]u8 {
    @panic("todo");
}

pub fn hugeFree(_: *Self, _: anytype) void {
    @panic("todo");
}
