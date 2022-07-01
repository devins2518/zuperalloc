const std = @import("std");
const static_bin_info = @import("static_bin.zig").static_bin_info;
const target = std.zig.CrossTarget{};
const isLinux = target.isLinux();
const Mutex = std.Thread.Mutex;
pub const page_size = std.mem.page_size;
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
        std.debug.assert(@This().pthread_cpu_number_np(&ret) == 0);
        break :blk @truncate(u32, ret);
    };
}
pub const BinNumber = u32;
pub const ChunkNumber = u32;
pub const BinAndSize = u32;

// Taken from compiler_rt/atomics.zig
pub fn haveTsx() bool {
    const builtin = @import("builtin");
    const arch = builtin.cpu.arch;
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
    const n_pages = std.math.divCeil(usize, len, page_size) catch unreachable;
    return if (n_pages < (1 << 24))
        @truncate(BinAndSize, 1 + bin + (1 << 7) + (n_pages << 8))
    else
        @truncate(BinAndSize, 1 + bin + ((std.math.divCeil(usize, len, chunk_size) catch unreachable) << 8));
}

pub fn binFromBinAndSize(b_and_t: BinAndSize) u32 {
    std.debug.assert((b_and_t & 127) != 0);
    return (b_and_t & 127) - 1;
}

pub fn addressToChunkAddress(ptr: anytype) [*]u8 {
    std.debug.assert(@typeInfo(@TypeOf(ptr)) == .Pointer);
    const p = if (@typeInfo(@TypeOf(ptr)).Pointer.size == .Slice)
        ptr.ptr
    else
        ptr;
    return @intToPtr([*]u8, @ptrToInt(p) & ~(chunk_size - 1));
}
