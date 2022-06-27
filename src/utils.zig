const std = @import("std");
const Self = @This();
pub const page_size = std.mem.page_size;
pub const cache_line = std.atomic.cache_line;
pub const log_chunksize: u64 = 21;
pub const chunksize: u64 = 1 << log_chunksize;
pub const log_max_chunknumber = 27;
pub const null_chunknumber = 0;
pub const cachelines_per_page: u64 = page_size / cache_line;
pub const max_allocatable_size: u64 = (chunksize << 27) - 1;
pub const largest_small = 14272;
pub const largest_large = 1044480;
pub const first_large_bin_number = 40;
pub const first_huge_bin_number = 47;
pub const VoidStar = ?[]u8;
pub const cpu_limit = 128;
pub usingnamespace @cImport({
    @cInclude("sys/mman.h");
    @cInclude("pthread.h");
    @cInclude("unistd.h");
    @cInclude("sched.h");
});

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

pub fn cpuCores() u32 {
    return Self.sysconf(Self._SC_NPROCESSORS_ONLN);
}

pub fn bAndSToBAndS(bin: u32, size: usize) u32 {
    const n_pages = std.math.divCeil(usize, size, page_size);
    if (n_pages < (1 << 24)) {
        return 1 + bin + (1 << 7) + (n_pages << 8);
    } else {
        return 1 + bin + (std.math.divCeil(size, chunksize) << 8);
    }
}

pub fn offsetInChunk(ptr: VoidStar) u64 {
    return @mod(@ptrToInt(ptr), chunksize);
}
