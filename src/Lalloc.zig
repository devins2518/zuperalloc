const std = @import("std");
const foot = @import("footprint.zig");
const utils = @import("utils.zig");
const Mutex = std.Thread.Mutex;
const Self = @This();
const Zalloc = @import("Zalloc.zig");

const n_large_classes = utils.first_huge_bin_number - utils.first_large_bin_number;

free_large_objs: [n_large_classes]?*LargeObjListCell = [_]?*LargeObjListCell{null} ** n_large_classes,
large_lock: Mutex = .{},
footprint: Footprint = .{},

const LargeObjListCell = packed union {
    next: ?*LargeObjListCell,
    footprint: u32,
};

const Footprint = struct {
    partitioned_footprint: [utils.cpu_limit]u64 = .{0} ** utils.cpu_limit,
};

fn predoLargeAllocPop(free_head: *?*LargeObjListCell) void {
    const head = free_head.*;
    if (head) |h| {
        utils.prefetchWrite(free_head);
        utils.prefetchRead(h);
    }
}

fn doLargeAllocPop(free_head: *?*LargeObjListCell) ?*LargeObjListCell {
    const head = free_head.* orelse return null;
    free_head.* = head.next;
    return head;
}

pub fn largeAlloc(self: *Self, zalloc: *Zalloc, len: usize) ?[]u8 {
    const footprint = utils.page_size * utils.ceil(len, utils.page_size);
    const bin = utils.sizeToBin(len);
    const usable_size = utils.binToSize(bin);
    std.debug.assert(bin >= utils.first_large_bin_number);
    std.debug.assert(bin < utils.first_huge_bin_number);

    std.debug.print("\nbin: {}, free_large_obj: {}\n", .{ bin, self.free_large_objs[bin - utils.first_large_bin_number] });
    const free_head = &self.free_large_objs[bin - utils.first_large_bin_number];

    while (true) {
        var head = free_head.*;

        if (head != null) {
            head = utils.atomically(
                ?*LargeObjListCell,
                &self.large_lock,
                "large_malloc_pop",
                predoLargeAllocPop,
                doLargeAllocPop,
                .{free_head},
            ) orelse continue;

            head.?.footprint = @truncate(u32, footprint);
            foot.addToFootprint(@bitCast(i64, footprint));
            const chunk = utils.addressToChunkAddress(head.?);
            const chunk_as_list_cell = @ptrCast([*]LargeObjListCell, chunk);
            const offset = @ptrToInt(head) - @ptrToInt(chunk_as_list_cell);

            const addr = chunk + utils.offset_of_first_obj_in_large_chunk + offset * usable_size;
            std.debug.assert(utils.addressToChunkNumber(addr) == utils.addressToChunkNumber(chunk));
            std.debug.assert(utils.binFromBinAndSize(zalloc.chunk_infos[utils.addressToChunkNumber(addr)].bin_and_size) == bin);
            return addr[0..len];
        } else {
            const chunk = zalloc.chunk_mgr.mmapChunkAlignedBlock(1) orelse unreachable;
            const objs_per_chunk = (utils.chunk_size - utils.offset_of_first_obj_in_large_chunk) / usable_size;

            const size_of_header = objs_per_chunk * @sizeOf(LargeObjListCell);
            std.debug.assert(size_of_header <= utils.offset_of_first_obj_in_large_chunk);

            const entry = @ptrCast([*]LargeObjListCell, chunk);
            var i: usize = 0;
            while (i + 1 < objs_per_chunk) : (i += 1)
                entry[i].next = &entry[i + 1];

            const b_and_s = utils.binAndSizeToBinAndSize(bin, footprint);
            std.debug.assert(b_and_s != 0);
            zalloc.chunk_infos[utils.addressToChunkNumber(chunk)].bin_and_size = b_and_s;

            while (true) {
                const old_head = free_head.*;
                entry[objs_per_chunk - 1].next = old_head;
                if (@cmpxchgWeak(?*LargeObjListCell, free_head, old_head, &entry[0], .SeqCst, .SeqCst) == null)
                    break;
            }
        }
    }
}

fn largeFootprint(zalloc: *Zalloc, buf: []u8) usize {
    const b_and_s = zalloc.chunk_infos[utils.addressToChunkNumber(buf)].bin_and_size;
    std.debug.assert(b_and_s != 0);
    const bin = utils.binFromBinAndSize(b_and_s);
    std.debug.assert(utils.first_large_bin_number <= bin);
    std.debug.assert(bin < utils.first_huge_bin_number);
    const usable_size = utils.binToSize(bin);
    const offset = utils.offsetInChunk(buf);
    const obj_num = (offset - utils.offset_of_first_obj_in_large_chunk) / usable_size;
    const entries = @ptrCast([*]LargeObjListCell, utils.addressToChunkAddress(buf));
    const footprint = entries[obj_num].footprint;
    return footprint;
}

pub fn largeFree(self: *Self, zalloc: *Zalloc, buf: []u8) void {
    const b_and_s = zalloc.chunk_infos[utils.addressToChunkNumber(buf)].bin_and_size;
    std.debug.assert(b_and_s != 0);
    const bin = utils.binFromBinAndSize(b_and_s);
    std.debug.assert(utils.first_large_bin_number <= bin);
    std.debug.assert(bin < utils.first_huge_bin_number);
    const usable_size = utils.binToSize(bin);
    // TODO: just use buf.len?
    _ = utils.madvise(buf.ptr, usable_size, utils.MADV_DONTNEED);
    const offset = utils.offsetInChunk(buf);
    const obj_num = utils.divideOffsetByObjSize(offset - utils.offset_of_first_obj_in_large_chunk, bin);

    const entries = @ptrCast(
        [*]LargeObjListCell,
        @alignCast(@alignOf([*]LargeObjListCell), utils.addressToChunkAddress(buf.ptr)),
    );
    const footprint = entries[obj_num].footprint;
    foot.addToFootprint(-@as(i64, footprint));

    var head = &self.free_large_objs[bin - utils.first_large_bin_number];
    var end_idx = entries[obj_num];
    while (true) {
        const first = @atomicLoad(?*LargeObjListCell, head, .Acquire);
        end_idx.next = first;
        if (@cmpxchgWeak(?*LargeObjListCell, head, first, &end_idx, .SeqCst, .SeqCst) == null)
            break;
    }
}

test "static analysis" {
    std.testing.refAllDecls(Self);
}

test "large alloc" {
    const msize = 4 * utils.page_size;
    const fp = foot.getFootprint();
    var zally = Zalloc.init();
    var lally = &zally.lalloc;
    {
        const x = lally.largeAlloc(&zally, msize) orelse
            return error.TestFailed;
        std.debug.print("\npagesize: {}\n", .{utils.page_size});
        std.debug.print("\nxptr {*} offset {}\n", .{ x, utils.offsetInChunk(x) });
        try std.testing.expect(utils.offsetInChunk(x) == utils.offset_of_first_obj_in_large_chunk);

        const y = lally.largeAlloc(&zally, msize) orelse
            return error.TestFailed;
        std.debug.print("\nyptr {*} offset {}\n", .{ y, utils.offsetInChunk(y) });
        try std.testing.expect(utils.offsetInChunk(y) == utils.offset_of_first_obj_in_large_chunk + msize);

        const fy = largeFootprint(&zally, y);
        try std.testing.expect(fy == msize);

        try std.testing.expect(foot.getFootprint() - fp == @intCast(i64, 2 * msize));

        lally.largeFree(&zally, x);
        const z = lally.largeAlloc(&zally, msize) orelse
            return error.TestFailed;
        try std.testing.expect(z.ptr == x.ptr and z.len == x.len);

        lally.largeFree(&zally, y);
        lally.largeFree(&zally, z);
    }
}
