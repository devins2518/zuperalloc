const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Atomic;
const Cache = @import("Cache.zig");
const Chunk = @import("Chunk.zig");
const Self = @This();
const Salloc = @import("Salloc.zig");
const utils = @import("utils.zig");
const max_allocatable_size = (utils.chunk_size << 27) - 1;
const BinNumber = utils.BinNumber;
const ChunkNumber = utils.ChunkNumber;
const BinAndSize = utils.BinAndSize;

init_lock: u32 = 0,
chunk_infos: []ChunkInfo,
n_cores: usize,
use_transactions: bool = true,
do_predo: bool = true,
has_tsx: bool,
cache: Cache = .{},
chunk_mgr: Chunk = .{},
salloc: Salloc = .{},

const ChunkInfo = struct {
    bin_and_size: u32 = 0,
    REMOVE_ME: u32 = 0,
};

pub fn init() Self {
    const have_tsx = haveTSX();

    const n_elts: usize = 1 << 27;
    const alloc_size: usize = n_elts * @sizeOf(ChunkInfo);
    const n_chunks: usize = std.math.divCeil(usize, alloc_size, utils.chunk_size) catch unreachable;

    const n_cores = std.Thread.getCpuCount() catch unreachable;

    var self = Self{ .has_tsx = have_tsx, .n_cores = n_cores, .chunk_infos = undefined };
    const chunks_slice = self.chunk_mgr.mmapChunkAlignedBlock(n_chunks) orelse
        @panic("failed to create chunk info");
    // TODO: https://github.com/ziglang/zig/issues/7495
    self.chunk_infos = @ptrCast([]ChunkInfo, std.mem.bytesAsSlice(ChunkInfo, chunks_slice));
    self.cache.init();
    return self;
}

pub inline fn allocator(self: *Self) Allocator {
    return Allocator.init(self, alloc, Allocator.NoResize(Self).noResize, free);
}

fn sizeToBin(size: usize) BinNumber {
    return if (size <= 0x00008)
        0
    else if (size <= 0x00140) blk: {
        const nzeros = @clz(usize, size);
        const roundup = size + (@as(usize, 1) << @truncate(u6, 61 - nzeros)) - 1;
        const nzeros2 = @clz(usize, roundup);
        break :blk 4 * (60 - nzeros2) + @truncate(u32, (roundup >> @truncate(u6, 61 - nzeros2)) & 3);
    } else if (size <= 0x001C0)
        22
    else if (size <= 0x00200)
        23
    else if (size <= 0x002C0)
        24
    else if (size <= 0x00340)
        25
    else if (size <= 0x00400)
        26
    else if (size <= 0x00440)
        27
    else if (size <= 0x005C0)
        28
    else if (size <= 0x007C0)
        29
    else if (size <= 0x00800)
        30
    else if (size <= 0x00AC0)
        31
    else if (size <= 0x00F40)
        32
    else if (size <= 0x01000)
        33
    else if (size <= 0x014C0)
        34
    else if (size <= 0x01C40)
        35
    else if (size <= 0x02000)
        36
    else if (size <= 0x02740)
        37
    else if (size <= 0x037C0)
        38
    else if (size <= 0x04000)
        39
    else if (size <= 0x08000)
        40
    else if (size <= 0x10000)
        41
    else if (size <= 0x20000)
        42
    else if (size <= 0x3F000)
        43
    else if (size <= 0x7F000)
        44
    else if (size <= 520192)
        45
    else if (size <= 1044480)
        46
    else if (size <= 2097152)
        // Special case to handle the values between the
        // largest_large and chunksize/2
        47
    else
        47 + std.math.log2(hyperceil(size)) - @as(u32, utils.log_chunk_size);
}

fn hyperceil(_: anytype) u32 {
    @panic("todo");
}
fn cachedFree(_: anytype, _: anytype) void {
    @panic("todo");
}
fn objectBase(_: anytype) u32 {
    @panic("todo");
}
fn hugeFree(_: anytype) void {
    @panic("todo");
}

fn haveTSX() bool {
    // TODO
    return true;
}
fn hugeAlloc(_: usize) Allocator.Error![]u8 {
    @panic("todo");
}
fn mmapChunkAlignedBlock(comptime T: type, _: usize) []T {
    @panic("todo");
}

fn alloc(self: *Self, len: usize, _: u29, _: u29, _: usize) Allocator.Error![]u8 {
    if (len >= max_allocatable_size) return error.OutOfMemory;
    if (len < utils.largest_small) {
        std.debug.print("\nat file {s} fn: {s} line: {}\n", .{ @src().file, @src().fn_name, @src().line });
        const bin = sizeToBin(len);
        const size = utils.binToSize(bin);
        return if (len <= utils.cache_line or std.math.isPowerOfTwo(size))
            (self.cachedAlloc(bin) orelse return error.OutOfMemory)[0..len]
        else
            (self.cachedAlloc(bin + 1) orelse return error.OutOfMemory)[0..len];
    } else {
        std.debug.print("\nat file {s} fn: {s} line: {}\n", .{ @src().file, @src().fn_name, @src().line });
        var rand = std.rand.DefaultPrng.init(0);
        const misalignment: usize = if (len <= utils.largest_small)
            0
        else
            (rand.random().int(usize) * utils.cache_line) % utils.page_size;
        const allocate_size: usize = len + misalignment;
        if (allocate_size <= utils.largest_large) {
            std.debug.print("\nat file {s} fn: {s} line: {}\n", .{ @src().file, @src().fn_name, @src().line });
            const bin = sizeToBin(allocate_size);
            const result = self.cachedAlloc(bin) orelse return error.OutOfMemory;
            return result[misalignment .. misalignment + len];
        } else {
            std.debug.print("\nat file {s} fn: {s} line: {}\n", .{ @src().file, @src().fn_name, @src().line });
            const result = hugeAlloc(allocate_size) catch return error.OutOfMemory;
            return result[misalignment .. misalignment + len];
        }
    }
}
fn resize(self: *Self, buf: []u8, _: u29, new_len: usize, _: u29, _: usize) ?usize {
    _ = self;
    if (new_len >= max_allocatable_size)
        return null;
    if (buf.len > new_len) {
        return new_len;
    } else @panic("todo");
}
fn free(self: *Self, buf: []u8, _: u29, _: usize) void {
    const chunk_num = utils.addressToChunkNumber(buf.ptr);
    const bnt = self.chunk_infos[chunk_num].bin_and_size;
    if (bnt == 0) @panic("Attempted to free value which was not allocated using Zalloc!");
    const bin = utils.binFromBinAndSize(bnt);
    std.debug.assert(utils.offsetInChunk(buf.ptr) != 0 and bin != 0);
    if (bin < utils.first_huge_bin_number)
        cachedFree(objectBase(buf.ptr), bin)
    else
        hugeFree(buf.ptr);
}

fn cachedAlloc(self: *Self, bin: BinNumber) ?[]u8 {
    std.debug.print("\nat file {s} fn: {s} line: {}\n", .{ @src().file, @src().fn_name, @src().line });
    std.debug.assert(bin < utils.first_huge_bin_number);
    const len = utils.binToSize(bin);
    if (self.cache.use_threadcache) {
        const result = Cache.cache_for_thread.bin_caches[bin].tryGetCachedBoth(len);
        if (result) |res| return res;
    }

    std.debug.print("\nat file {s} fn: {s} line: {}\n", .{ @src().file, @src().fn_name, @src().line });
    const p = @mod(Cache.getCpu(), utils.cpu_limit);

    var result = self.cache.tryGetCpuCached(p, bin, len) orelse
        self.cache.tryGetGlobalCached(p, bin, len) orelse
        if (bin < utils.first_large_bin_number)
        self.salloc.smallAlloc(self, bin, len)
    else
        largeAlloc(len);
    return result;
}

fn largeAlloc(_: anytype) ?[]u8 {
    @panic("todo");
}

test "static analysis" {
    std.testing.refAllDecls(Self);
    var zalloc = std.mem.validationWrap(Self.init());
    const child = zalloc.allocator();

    try std.heap.testAllocator(child);
    // try std.heap.testAllocatorAligned(child);
    // try std.heap.testAllocatorLargeAlignment(child);
    // try std.heap.testAllocatorAlignedShrink(child);
}
