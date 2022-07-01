const std = @import("std");
const utils = @import("utils.zig");
const Atomic = std.atomic.Atomic;
const Self = @This();

total_mapped: Atomic(usize) = Atomic(usize).init(0),
unmapped: Atomic(usize) = Atomic(usize).init(0),

pub fn mmapSize(self: *Self, len: usize) ?[]align(utils.page_size) u8 {
    const r = std.os.mmap(
        null,
        len,
        utils.PROT_READ | utils.PROT_WRITE,
        utils.MAP_PRIVATE | utils.MAP_ANON | utils.MAP_NORESERVE,
        -1,
        0,
    ) catch return null;
    _ = self.total_mapped.fetchAdd(len, .SeqCst);
    return r;
}

fn unmap(self: *Self, buf: []u8) void {
    if (buf.len > 0) {
        std.os.munmap(@alignCast(utils.page_size, buf));
        _ = self.unmapped.fetchAdd(buf.len, .SeqCst);
    }
}

fn chunkCreateSlow(self: *Self, chunks: usize) ?[]align(utils.page_size) u8 {
    const total_size = (1 + chunks) * utils.chunk_size;
    const m = self.mmapSize(total_size) orelse return null;
    const m_offset = utils.offsetInChunk(m);
    if (m_offset == 0) {
        self.unmap(m[chunks * utils.chunk_size .. (chunks * utils.chunk_size) + utils.chunk_size]);
        return m;
    } else {
        const leading_useless = utils.chunk_size - m_offset;
        self.unmap(m[0..leading_useless]);
        const final_m = m[leading_useless..];
        self.unmap(m[chunks * utils.chunk_size .. (chunks * utils.chunk_size) + m_offset]);
        return final_m;
    }
}

pub fn mmapChunkAlignedBlock(self: *Self, chunks: usize) ?[]align(utils.page_size) u8 {
    const r = self.mmapSize(chunks * utils.chunk_size) orelse return null;
    if (utils.offsetInChunk(r) != 0) {
        self.unmap(r);
        return self.chunkCreateSlow(chunks);
    } else return r;
}

test "static analysis" {
    std.testing.refAllDecls(Self);
}
