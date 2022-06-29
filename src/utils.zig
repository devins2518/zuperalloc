const std = @import("std");
const static_bin_info = @import("static_bin.zig").static_bin_info;
const target = std.zig.CrossTarget{};
const isLinux = target.isLinux();
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
pub const sched_getcpu = if (isLinux)
    @cImport({
        @cInclude("sched.h");
    }).sched_getcpu
else
    // TODO: Port from https://stackoverflow.com/questions/33745364/sched-getcpu-equivalent-for-os-x
    struct {
        fn f() u32 {
            return 0;
            // @panic("todo");
        }
    }.f;
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
