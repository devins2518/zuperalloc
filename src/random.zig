const std = @import("std");
const mix: u64 = 0xdaba0b6eb09322e3;

fn mix64(z: u64) u64 {
    var y = z;
    y = (y ^ (y >> 32)) *% mix;
    y = (y ^ (y >> 32)) *% mix;
    return y ^ (y >> 32);
}

threadlocal var rv: u64 align(64) = 0;

pub fn prandom() u64 {
    rv += 1;
    return mix64(@ptrToInt(&rv) + rv);
}

test "static analysis" {
    std.testing.refAllDecls(@This());
}
