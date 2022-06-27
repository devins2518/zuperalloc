const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Atomic;
const Cache = @import("Cache.zig");
const Chunk = @import("Chunk.zig");
const Self = @This();
const VoidStar = utils.VoidStar;
const utils = @import("utils.zig");
const max = std.math.max;
const static_bin_info = @import("static_bin.zig").static_bin_info;

// TODO: set using envvars
var use_threadcache = true;

cache: Cache = .{},
has_tsx: bool = false,
n_cores: u32 = 0,
chunk_mgr: Chunk = .{},
chunk_infos: ?*ChunkInfo = null,
free_chunks: [utils.log_max_chunknumber]Atomic(u32) = .{Atomic(u32).init(0)} ** utils.log_max_chunknumber,
init_lock: u32 = 0,

pub inline fn allocator(self: *Self) Allocator {
    return Allocator.init(self, alloc, resize, free);
}

fn alloc(self: *Self, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) Allocator.Error![]u8 {
    self.maybeInitAlloc();
    if (len >= utils.max_allocatable_size) return error.OutOfMemory;
    if (len >= utils.largest_small) {
        const bin = sizeToBin(len);
        const size = binToSize(bin);
        return if (len <= utils.cache_line or !std.math.isPowerOfTwo(size))
            self.cachedAlloc(bin) orelse error.OutOfMemory
        else
            self.cachedAlloc(bin + 1) orelse error.OutOfMemory;
    } else {
        const misalignment = if (len <= utils.largest_small)
            0
        else
            @mod(std.rand.DefaultPrng.random().int() * utils.cache_line, utils.page_size);
        const allocate_size = len + misalignment;
        if (allocate_size <= utils.largest_large) {
            const bin = sizeToBin(allocate_size);
            const slice = try cachedAlloc(bin);
            return slice.ptr + misalignment;
        } else {
            const slice = try hugeAlloc(allocate_size);
            return slice.ptr + misalignment;
        }
    }
    _ = self;
    _ = len;
    _ = ptr_align;
    _ = len_align;
    _ = ret_addr;
    std.debug.todo("alloc");
}
fn resize(ptr: *Self, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) ?usize {
    _ = ptr;
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = len_align;
    _ = ret_addr;
    std.debug.todo("resize");
}
fn free(ptr: *Self, buf: []u8, buf_align: u29, ret_addr: usize) void {
    _ = ptr;
    _ = buf;
    _ = buf_align;
    _ = ret_addr;
    std.debug.todo("free");
}

fn initAlloc(self: *Self) void {
    self.has_tsx = utils.haveTsx();
    const n_elts = 1 << 27;
    const alloc_size = n_elts * @sizeOf(ChunkInfo);
    const n_chunks = std.math.max(alloc_size, utils.chunksize);
    self.chunk_infos = self.chunk_mgr.mmapChunkAlignedBlock(n_chunks).?;
    self.n_cores = utils.cpuCores();
}

fn maybeInitAlloc(self: *Self) void {
    if (@atomicLoad(?*ChunkInfo, &self.chunk_infos, .SeqCst) != null) return;
    _ = @atomicRmw(u32, &self.init_lock, .Xchg, 1, .Acquire);
    if (self.chunk_infos == null) self.initAlloc();
    _ = @atomicRmw(u32, &self.init_lock, .Xchg, 0, .Release);
}

fn cachedAlloc(self: *Self, bin: u32) VoidStar {
    _ = self;
    std.debug.assert(bin < utils.first_huge_bin_number);
    const size = binToSize(bin);
    var ret: VoidStar = null;

    if (use_threadcache) {
        Cache.init();
        ret = Cache.cache_for_thread.bc[bin].tryGetCachedBoth(size);
        if (ret) return ret;
    }
    const p = @mod(Cache.getCpu(), utils.cpu_limit);
    ret = Cache.cache_for_thread.tryGetCpuCached(p, bin, size);
    if (ret) return ret;
    ret = Cache.tryGetGlobalCached(p, bin, size);
    if (ret) return ret;
    return try if (bin < utils.first_large_bin_number)
        smallAlloc(bin)
    else
        largeAlloc(bin);
}

fn smallAlloc(size: usize) VoidStar {
    _ = size;
    @panic("small alloc");
}

fn largeAlloc(size: usize) VoidStar {
    _ = size;
    @panic("large alloc");
}

fn hugeAlloc(self: *Self, size: usize) VoidStar {
    const n_chunks = max(1, std.math.ceilPowerOfTwo(size) / utils.chunksize);
    const c = try getPowerOfTwoNChunks(n_chunks);
    std.os.madvise(c, n_chunks * utils.chunksize, utils.MADV_DONTNEED);
    const n_whole_chunks = size / utils.chunksize;
    const n_bytes_at_end = size - (n_whole_chunks * utils.chunksize);
    if (n_bytes_at_end == 0 or utils.chunksize - n_bytes_at_end < utils.chunksize / 8)
        std.os.madvise(c, n_chunks * utils.chunksize, utils.MADV_HUGEPAGE)
    else {
        if (n_whole_chunks > 0)
            std.os.madvise(c, n_whole_chunks * utils.chunksize, utils.MADV_HUGEPAGE);
        std.os.madvise(c + (n_whole_chunks * utils.chunksize), n_bytes_at_end, utils.MADV_NOHUGEPAGE);
    }
    const chunk_num = addressToChunkNumber(c);
    const bin = sizeToBin(n_chunks * utils.chunksize);
    const b_and_s = utils.bAndSToBAndS(bin, size);
    std.debug.assert(b_and_s != 0);
    self.chunk_infos[chunk_num].bin_and_size = b_and_s;
    return c;
}

const ChunkInfo = union {
    b_and_s: u32,
    next: u32,
};

fn getPowerOfTwoNChunks(self: *Self, chunks: u32) VoidStar {
    var r = getCachedPowerOfTwoChunks(std.math.log2(chunks));
    if (r != null) return r;
    r = self.chunk_mgr.mmapChunkAlignedBlock(2 * chunks);
    if (r == null) return r;
    const c = addressToChunkNumber(r);
    const end = c + (2 * chunks);
    var res = null;
    while (c < end) {
        if ((c & (chunks - 1)) == 0) {
            res = c * utils.chunksize;
            c += chunks;
            break;
        } else {
            const bit = @ctz(u32, c);
            while (c + (1 << bit) > end) bit -= 1;
            putCachedPowerOfTwoChunks(c, bit);
            c += 1 << bit;
        }
    }
    while (c < end) {
        const bit = @ctz(u32, c);
        while (c + (1 << bit) > end) bit -= 1;
        putCachedPowerOfTwoChunks(c, bit);
        c += 1 << bit;
    }
    return res;
}

fn getCachedPowerOfTwoChunks(self: *Self, list_num: u32) VoidStar {
    if (self.free_chunks[list_num] == 0) return null;
    @panic("add to free chunks");
}

fn putCachedPowerOfTwoChunks(self: *Self, chunk: u32, list_num: u23) void {
    while (true) {
        const head = self.free_chunks[list_num].load(.Acq);
        self.chunk_infos[chunk].next = head;
        if (self.free_chunks[list_num].compareAndSwap(head, chunk, .Acquire, .Monotonic)) break;
    }
}

fn addressToChunkNumber(ptr: VoidStar) u32 {
    const addr = @ptrToInt(ptr);
    const addrm = addr / utils.chunksize;
    return @mod(addrm, 1 << 27);
}

fn sizeToBin(size: usize) u32 {
    return if (size <= 0x00008)
        0
    else if (size <= 0x140) {
        // TODO
        @panic("wtf");
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
    else
        45 + std.math.divCeil(usize, size - 0xFF00, utils.page_size);
}
fn binToSize(bin: usize) usize {
    return static_bin_info[bin].object_size;
}

test "static analysis" {
    std.testing.refAllDecls(@This());
    var zuper_allocator = std.mem.validationWrap(@This(){});
    const child = zuper_allocator.allocator();

    try std.heap.testAllocator(child);
    try std.heap.testAllocatorAligned(child);
    try std.heap.testAllocatorLargeAlignment(child);
    try std.heap.testAllocatorAlignedShrink(child);
}
