const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Atomic;
const Cache = @import("Cache.zig");
const Chunk = @import("Chunk.zig");
const Self = @This();
const Halloc = @import("Halloc.zig");
const Lalloc = @import("Lalloc.zig");
const Salloc = @import("Salloc.zig");
const rand = @import("random.zig");
const utils = @import("utils.zig");
const max_allocatable_size = (utils.chunk_size << 27) - 1;
const static_bin_info = @import("static_bin.zig").static_bin_info;
const ChunkInfo = Chunk.ChunkInfo;
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
halloc: Halloc = .{},
lalloc: Lalloc = .{},
salloc: Salloc = .{},

pub fn init() Self {
    const have_tsx = utils.haveTsx();

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

// TODO return []u8?
fn objectBase(self: *Self, buf: []u8) [*]u8 {
    const chunk = utils.addressToChunkNumber(buf.ptr);
    const b_and_s = self.chunk_infos[chunk].bin_and_size;
    std.debug.assert(b_and_s != 0);
    const bin = utils.binFromBinAndSize(b_and_s);
    return if (bin >= utils.first_huge_bin_number)
        utils.addressToChunkAddress(buf)
    else blk: {
        const wasted_offset = static_bin_info[bin].overhead_pages_per_chunk * utils.page_size;
        std.debug.assert(utils.offsetInChunk(buf) >= wasted_offset);
        const useful_offset = utils.offsetInChunk(buf) - wasted_offset;
        const folio_number = utils.divideOffsetByFolioSize(useful_offset, bin);
        const folio_mul = folio_number * static_bin_info[bin].folio_size;
        const offset_in_folio = useful_offset - folio_mul;
        const obj_num = utils.divideOffsetByObjSize(offset_in_folio, bin);
        break :blk @intToPtr([*]u8, chunk * utils.chunk_size + wasted_offset + folio_mul + obj_num * static_bin_info[bin].object_size);
    };
}

fn alloc(self: *Self, len: usize, _: u29, _: u29, _: usize) Allocator.Error![]u8 {
    if (len >= max_allocatable_size) return error.OutOfMemory;
    if (len < utils.largest_small) {
        const bin = utils.sizeToBin(len);
        const size = utils.binToSize(bin);
        return if (len <= utils.cache_line or std.math.isPowerOfTwo(size))
            (self.cachedAlloc(bin) orelse return error.OutOfMemory)[0..len]
        else
            (self.cachedAlloc(bin + 1) orelse return error.OutOfMemory)[0..len];
    } else {
        const misalignment: usize = if (len <= utils.largest_small)
            0
        else
            @mod(rand.prandom() *% utils.cache_line, utils.page_size);
        const allocate_size: usize = len + misalignment;
        if (allocate_size <= utils.largest_large) {
            const bin = utils.sizeToBin(allocate_size);
            const result = self.cachedAlloc(bin) orelse return error.OutOfMemory;
            return @intToPtr([*]u8, @ptrToInt(result.ptr) + misalignment)[0..len];
        } else {
            const result = self.halloc.hugeAlloc(allocate_size) orelse return error.OutOfMemory;
            return @intToPtr([*]u8, @ptrToInt(result.ptr) + misalignment)[0..len];
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
        cachedFree(self.objectBase(buf), bin)
    else
        self.halloc.hugeFree(buf.ptr);
}

fn cachedAlloc(self: *Self, bin: BinNumber) ?[]u8 {
    std.debug.assert(bin < utils.first_huge_bin_number);
    const len = utils.binToSize(bin);
    if (self.cache.use_threadcache) {
        const result = Cache.cache_for_thread.bin_caches[bin].tryGetCachedBoth(len);
        if (result) |res| return res;
    }

    const p = @mod(Cache.getCpu(), utils.cpu_limit);

    var result = self.cache.tryGetCpuCached(p, bin, len) orelse
        self.cache.tryGetGlobalCached(p, bin, len) orelse
        if (bin < utils.first_large_bin_number)
        self.salloc.smallAlloc(self, bin, len)
    else
        self.lalloc.largeAlloc(self, len);
    return result;
}

fn cachedFree(_: anytype, _: anytype) void {
    @panic("todo");
}

test "static analysis" {
    std.testing.refAllDecls(Self);
    var zalloc = std.mem.validationWrap(Self.init());
    const child = zalloc.allocator();
    // TODO
    _ = child;

    // try std.heap.testAllocator(child);
    // try std.heap.testAllocatorAligned(child);
    // try std.heap.testAllocatorLargeAlignment(child);
    // try std.heap.testAllocatorAlignedShrink(child);
}

test "objectBase" {
    var zally = @import("Zalloc.zig").init();
    const p = try zally.allocator().alloc(u8, 8193);
    try std.testing.expect(utils.offsetInChunk(zally.objectBase(p)) >= 4096);
}
