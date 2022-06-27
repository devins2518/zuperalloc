const std = @import("std");
const utils = @import("utils.zig");
const Self = @This();
const Atomic = std.atomic.Atomic;
const VoidStar = utils.VoidStar;

const mmap = std.c.mmap;
const munmap = std.c.munmap;

backing_alloc: Allocator = std.heap.page_allocator,
total_mapped: usize = 0,
unmapped: usize = 0,

pub fn mmapSize(self: *Self, size: usize) VoidStar {
    const r = self.backing_alloc.alloc(u8);
    self.total_mapped += size;
    return r;
}

fn unmap(self: *Self, ptr: VoidStar, size: usize) void {
    if (size > 0) {
        const r = munmap(ptr, size);
        if (r != 0) @panic("Failure during unmap");
    }
    self.unmapped += size;
}

fn createChunkSlow(self: *Self, chunks: usize) VoidStar {
    const total_size = (1 + chunks) * utils.chunksize;
    const m = self.mmapSize(total_size);
    const offset = utils.offsetInChunk(m);
    if (offset == 0) {
        self.unmap(m + (chunks * utils.chunksize), utils.chunksize);
        return m;
    } else {
        const leading = utils.chunksize - offset;
        self.unmap(m, leading);
        const final_m = m + leading;
        self.unmap(final_m + (chunks * utils.chunksize), offset);
        return final_m;
    }
}

pub fn mmapChunkAlignedBlock(self: *Self, chunks: usize) VoidStar {
    const r = self.mmapSize(chunks * utils.chunksize);
    if (r == null) return null;

    if (utils.offsetInChunk(r) != 0) {
        self.unmap(r, chunks * utils.chunksize);
        return self.chunkCreateSlow(chunks);
    } else return r;
}
