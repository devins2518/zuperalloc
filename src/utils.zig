const std = @import("std");
const builtin = @import("builtin");
const target = std.zig.CrossTarget{};
const arch = target.cpu_arch orelse builtin.cpu.arch;
const isLinux = target.isLinux();
const static_bin_info = @import("static_bin.zig").static_bin_info;
const Mutex = std.Thread.Mutex;
pub const page_size: u64 = std.mem.page_size;
pub const cache_line = std.atomic.cache_line;
pub const log_chunk_size: u64 = 21;
pub const chunk_size: u64 = 1 << log_chunk_size;
pub const log_max_chunk_number = 27;
pub const null_chunk_number = 0;
pub const cache_lines_per_page: u64 = page_size / cache_line;
pub const max_allocatable_size: u64 = (chunk_size << 27) - 1;
pub const largest_small = 14272;
pub const largest_large = 1044480;
pub const first_large_bin_number = 40;
pub const first_huge_bin_number = 47;
pub const cpu_limit = 128;
pub const bin_number_limit = 74;
pub const offset_of_first_obj_in_large_chunk = page_size;
pub usingnamespace @cImport({
    @cInclude("pthread.h");
    @cInclude("sys/mman.h");
});
pub fn sched_getcpu() u32 {
    return if (isLinux)
        @cImport({
            @cInclude("sched.h");
        }).sched_getcpu()
    else blk: {
        var ret: usize = undefined;
        if (arch == .aarch64) {
            std.debug.assert(@This().pthread_cpu_number_np(&ret) == 0);
        } else {
            @panic("todo");
        }
        break :blk @truncate(u32, ret);
    };
}
pub const BinNumber = u32;
pub const ChunkNumber = u32;
pub const BinAndSize = u32;

// Taken from compiler_rt/atomics.zig
pub fn haveTsx() bool {
    return switch (arch) {
        .msp430, .avr, .bpfel, .bpfeb => false,
        .arm, .armeb, .thumb, .thumbeb =>
        // The ARM v6m ISA has no ldrex/strex and so it's impossible to do CAS
        // operations (unless we're targeting Linux, the kernel provides a way to
        // perform CAS operations).
        // XXX: The Linux code path is not implemented yet.
        !std.Target.arm.featureSetHas(builtin.cpu.features, .has_v6m),
        else => true,
    };
}

pub fn prefetchWrite(ptr: anytype) void {
    @prefetch(ptr, .{ .rw = .write });
}
pub fn prefetchRead(ptr: anytype) void {
    @prefetch(ptr, .{ .rw = .read });
}

pub fn binToSize(bin: BinNumber) usize {
    std.debug.assert(bin < bin_number_limit);
    return static_bin_info[bin].object_size;
}

pub fn sizeToBin(size: usize) BinNumber {
    if (size <= 8)
        return 0
    else if (size <= 320) {
        // bit hacking to calculate the bin number for the first group of small
        // bins.
        const nzeros: u32 = @clz(usize, size);
        const roundup: usize = size + (@as(u32, 1) << @truncate(u5, 61 - nzeros)) - 1;
        const nzeros2: u32 = @clz(usize, roundup);
        return @truncate(u32, 4 * (60 - nzeros2) + ((roundup >> @truncate(u6, 61 - nzeros2)) & 3));
    } else if (size <= 448)
        return 22
    else if (size <= 512)
        return 23
    else if (size <= 576)
        return 24
    else if (size <= 704)
        return 25
    else if (size <= 960)
        return 26
    else if (size <= 1024)
        return 27
    else if (size <= 1216)
        return 28
    else if (size <= 1472)
        return 29
    else if (size <= 1984)
        return 30
    else if (size <= 2048)
        return 31
    else if (size <= 2752)
        return 32
    else if (size <= 3904)
        return 33
    else if (size <= 4096)
        return 34
    else if (size <= 5312)
        return 35
    else if (size <= 7232)
        return 36
    else if (size <= 8192)
        return 37
    else if (size <= 10048)
        return 38
    else if (size <= 14272)
        return 39
    else if (size <= 16384)
        return 40
    else if (size <= 32768)
        return 41
    else if (size <= 65536)
        return 42
    else if (size <= 131072)
        return 43
    else if (size <= 258048)
        return 44
    else if (size <= 520192)
        return 45
    else if (size <= 1044480)
        return 46
    else if (size <= 2097152)
        return 47
    else
        // return 47 + lg_of_power_of_two(hyperceil(size)) - log_chunksize;
        return @truncate(u32, 47 + logPow2(hyperceil(size)) - log_chunk_size);
}

pub fn offsetInChunk(ptr: anytype) usize {
    std.debug.assert(@typeInfo(@TypeOf(ptr)) == .Pointer);
    const p = if (@typeInfo(@TypeOf(ptr)).Pointer.size == .Slice)
        ptr.ptr
    else
        ptr;
    return @mod(@ptrToInt(p), chunk_size);
}

// TODO: impl rtm for x86 (arm has tme but released in 2019 and probably sparsely implemented)
pub fn atomically(
    comptime T: type,
    lock: *Mutex,
    name: []const u8,
    predo_fn: anytype,
    do_fn: anytype,
    args: anytype,
) T {
    _ = name;
    _ = predo_fn;
    lock.lock();
    defer lock.unlock();
    return @call(.{}, do_fn, args);
}

pub fn atomically2(
    comptime T: type,
    lock0: *Mutex,
    lock1: *Mutex,
    name: []const u8,
    predo_fn: anytype,
    do_fn: anytype,
    args: anytype,
) T {
    _ = name;
    _ = predo_fn;
    lock0.lock();
    defer lock0.unlock();
    lock1.lock();
    defer lock1.unlock();
    return @call(.{}, do_fn, args);
}

pub fn addressToChunkNumber(ptr: anytype) ChunkNumber {
    std.debug.assert(@typeInfo(@TypeOf(ptr)) == .Pointer);
    const p = if (@typeInfo(@TypeOf(ptr)).Pointer.size == .Slice)
        ptr.ptr
    else
        ptr;
    const au = @ptrToInt((p));
    const am = au / chunk_size;
    return @truncate(ChunkNumber, @mod(am, 1 << 27));
}

pub fn binAndSizeToBinAndSize(bin: BinNumber, len: usize) BinAndSize {
    std.debug.assert(bin < 127);
    const n_pages = ceil(len, page_size);
    return if (n_pages < (1 << 24))
        @truncate(BinAndSize, 1 + bin + (1 << 7) + (n_pages << 8))
    else
        @truncate(BinAndSize, 1 + bin + (ceil(len, chunk_size) << 8));
}

pub fn binFromBinAndSize(b_and_s: BinAndSize) u32 {
    std.debug.assert((b_and_s & 127) != 0);
    return (b_and_s & 127) - 1;
}

pub fn addressToChunkAddress(ptr: anytype) [*]u8 {
    std.debug.assert(@typeInfo(@TypeOf(ptr)) == .Pointer);
    const p = if (@typeInfo(@TypeOf(ptr)).Pointer.size == .Slice)
        ptr.ptr
    else
        ptr;
    return @intToPtr([*]u8, @ptrToInt(p) & ~(chunk_size - 1));
}

pub fn divideOffsetByObjSize(offset: usize, bin: BinNumber) u32 {
    return @truncate(u32, (offset * static_bin_info[bin].object_division_multiply_magic) >>
        static_bin_info[bin].object_division_shift_magic);
}
pub fn divideOffsetByFolioSize(offset: usize, bin: BinNumber) u32 {
    return @truncate(u32, (offset * static_bin_info[bin].folio_division_multiply_magic) >>
        static_bin_info[bin].folio_division_shift_magic);
}

pub fn hyperceil(a: anytype) @TypeOf(a) {
    return std.math.ceilPowerOfTwoAssert(@TypeOf(a), a);
}

pub fn ceil(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return (a + b - 1) / b;
}

pub fn logPow2(a: anytype) @TypeOf(a) {
    return @ctz(@TypeOf(a), a);
}

// TEST
fn slowHyperceil(a: anytype) @TypeOf(a) {
    var r: @TypeOf(a) = 1;
    var b = a - 1;
    while (b > 0) {
        b /= 2;
        r *%= 2;
    }
    return r;
}
test "hyperceil" {
    {
        const a: u64 = 1;
        const expected: u64 = 1;
        try std.testing.expect(hyperceil(a) == slowHyperceil(a));
        try std.testing.expect(hyperceil(a) == expected);
    }
    {
        const a: u64 = 2;
        const expected: u64 = 2;
        try std.testing.expect(hyperceil(a) == slowHyperceil(a));
        try std.testing.expect(hyperceil(a) == expected);
    }
    {
        const a: u64 = 3;
        const expected: u64 = 4;
        try std.testing.expect(hyperceil(a) == slowHyperceil(a));
        try std.testing.expect(hyperceil(a) == expected);
    }
    {
        const a: u64 = 4;
        const expected: u64 = 4;
        try std.testing.expect(hyperceil(a) == slowHyperceil(a));
        try std.testing.expect(hyperceil(a) == expected);
    }
    {
        const a: u64 = 5;
        const expected: u64 = 8;
        try std.testing.expect(hyperceil(a) == slowHyperceil(a));
        try std.testing.expect(hyperceil(a) == expected);
    }
    var i: u32 = 3;
    while (i < 27) : (i += 1) {
        {
            const a: u64 = (@as(u64, 1) << @truncate(u6, i)) + 0;
            const expected: u64 = @as(u64, 1) << @truncate(u6, i);
            try std.testing.expect(hyperceil(a) == slowHyperceil(a));
            try std.testing.expect(hyperceil(a) == expected);
        }
        {
            const a: u64 = (@as(u64, 1) << @truncate(u6, i)) - 1;
            const expected: u64 = @as(u64, 1) << @truncate(u6, i);
            try std.testing.expect(hyperceil(a) == slowHyperceil(a));
            try std.testing.expect(hyperceil(a) == expected);
        }
        {
            const a: u64 = (@as(u64, 1) << @truncate(u6, i)) + 1;
            const expected: u64 = 2 * (@as(u64, 1) << @truncate(u6, i));
            try std.testing.expect(hyperceil(a) == slowHyperceil(a));
            try std.testing.expect(hyperceil(a) == expected);
        }
    }
}

test "sizeToBin" {
    var i: usize = 8;
    while (i <= largest_large) : (i += 1) {
        const g = sizeToBin(i);
        try std.testing.expect(g < first_huge_bin_number);
        try std.testing.expect(i <= static_bin_info[g].object_size);
        if (g > 0)
            try std.testing.expect(i > static_bin_info[g - 1].object_size)
        else
            try std.testing.expect(g == 0 and i == 8);
        const s = binToSize(g);
        try std.testing.expect(s >= i);
        try std.testing.expect(sizeToBin(s) == g);
    }
    i = largest_large + 1;
    while (i <= chunk_size) : (i += 1) {
        try std.testing.expect(sizeToBin(i) == first_huge_bin_number);
    }
    try std.testing.expect(binToSize(first_huge_bin_number - 1) < chunk_size);
    try std.testing.expect(binToSize(first_huge_bin_number) == chunk_size);
    try std.testing.expect(binToSize(first_huge_bin_number + 1) == chunk_size * 2);
    try std.testing.expect(binToSize(first_huge_bin_number + 2) == chunk_size * 4);
    var k: u32 = 0;
    while (k < 1000) : (k += 1) {
        const s = chunk_size * 10 + page_size * k;
        const b = sizeToBin(s);
        try std.testing.expect(sizeToBin(binToSize(b)) == b);
        try std.testing.expect(binToSize(sizeToBin(s)) == hyperceil(s));
    }

    // Verify that all the bins that are 256 or larger are multiples of a cache
    // line.
    i = 0;
    while (i <= first_huge_bin_number) : (i += 1) {
        const os = static_bin_info[i].object_size;
        try std.testing.expect(os < 256 or os % 64 == 0);
    }
}
