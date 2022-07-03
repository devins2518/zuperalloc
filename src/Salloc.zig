const std = @import("std");
const Zalloc = @import("Zalloc.zig");
const utils = @import("utils.zig");
const static_bin_info = @import("static_bin.zig").static_bin_info;
const Self = @This();
const BinNumber = utils.BinNumber;
const Mutex = std.Thread.Mutex;

const max_objects_per_folio = 2048;
const folio_bitmap_n_words = max_objects_per_folio / 64;

dsbi: struct {
    lists: DynamicSmallBinInfo align(4096) = .{ .b = [_]?*PerFolio{null} ** 11920 },
    fullest_offset: [utils.first_large_bin_number]u16 = [_]u16{0} ** utils.first_large_bin_number,
} = .{},
small_locks: [utils.first_large_bin_number]Mutex = [_]Mutex{.{}} ** utils.first_large_bin_number,

const SmallChunkHeader = struct {
    list: [512]PerFolio = [_]PerFolio{.{}} ** 512,
};

const PerFolio = struct {
    next: ?*PerFolio align(64) = null,
    prev: ?*PerFolio = null,
    in_use_bitmap: [folio_bitmap_n_words]u64 = [_]u64{0} ** folio_bitmap_n_words,
};

const DynamicSmallBinInfo = packed union {
    b: [11920]?*PerFolio,
    per: packed struct {
        // zig fmt: off
        b0:  [514]?*PerFolio = [_]PerFolio{null} **  514,
        b1: [2050]?*PerFolio = [_]PerFolio{null} ** 2050,
        b2: [1026]?*PerFolio = [_]PerFolio{null} ** 1026,
        b3: [2050]?*PerFolio = [_]PerFolio{null} ** 2050,
        b4:  [258]?*PerFolio = [_]PerFolio{null} **  258,
        b5: [1026]?*PerFolio = [_]PerFolio{null} ** 1026,
        b6:  [514]?*PerFolio = [_]PerFolio{null} **  514,
        b7: [1026]?*PerFolio = [_]PerFolio{null} ** 1026,
        b8:  [130]?*PerFolio = [_]PerFolio{null} **  130,
        b9:  [514]?*PerFolio = [_]PerFolio{null} **  514,
        b10: [258]?*PerFolio = [_]PerFolio{null} **  258,
        b11: [514]?*PerFolio = [_]PerFolio{null} **  514,
        b12:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b13: [258]?*PerFolio = [_]PerFolio{null} **  258,
        b14: [130]?*PerFolio = [_]PerFolio{null} **  130,
        b15: [258]?*PerFolio = [_]PerFolio{null} **  258,
        b16:  [34]?*PerFolio = [_]PerFolio{null} **   34,
        b17: [130]?*PerFolio = [_]PerFolio{null} **  130,
        b18:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b19: [130]?*PerFolio = [_]PerFolio{null} **  130,
        b20:  [18]?*PerFolio = [_]PerFolio{null} **   18,
        b21:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b22:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b23:  [10]?*PerFolio = [_]PerFolio{null} **   10,
        b24:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b25:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b26:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b27:   [6]?*PerFolio = [_]PerFolio{null} **    6,
        b28:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b29:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b30:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b31:   [4]?*PerFolio = [_]PerFolio{null} **    4,
        b32:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b33:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b34:   [3]?*PerFolio = [_]PerFolio{null} **    3,
        b35:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b36:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b37:   [3]?*PerFolio = [_]PerFolio{null} **    3,
        b38:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        b39:  [66]?*PerFolio = [_]PerFolio{null} **   66,
        // zig fmt: on
    },
};

fn verifySmallInvariants(self: *Self) void {
    _ = self;
}

pub fn smallAlloc(self: *Self, zalloc: *Zalloc, bin: BinNumber, len: usize) ?[]u8 {
    self.verifySmallInvariants();
    std.debug.assert(bin < utils.first_large_bin_number);
    const offset = dynamicSmallBinOffset(bin);
    const obj_per_folio = static_bin_info[bin].objects_per_folio;
    const obj_size = static_bin_info[bin].object_size;
    const folio_per_chunk = static_bin_info[bin].folios_per_chunk;
    while (true) {
        const fullest = @atomicLoad(u16, &self.dsbi.fullest_offset[bin], .Acquire);
        if (fullest == 0) {
            const chunk = zalloc.chunk_mgr.mmapChunkAlignedBlock(1) orelse return null;
            const b_and_s = utils.binAndSizeToBinAndSize(bin, 0);
            zalloc.chunk_infos[utils.addressToChunkNumber(chunk)].bin_and_size = b_and_s;

            const chunk_header = @ptrCast(*SmallChunkHeader, chunk);
            var i: usize = 0;
            while (i < folio_per_chunk) : (i += 1) {
                var w: usize = 0;
                const div = std.math.divCeil(u16, obj_per_folio, 64) catch unreachable;
                while (w < div) : (w += 1)
                    chunk_header.list[i].in_use_bitmap[w] = 0;

                chunk_header.list[i].prev = if (i == 0) null else &chunk_header.list[i - 1];
                chunk_header.list[i].next = if (i + 1 == folio_per_chunk) null else &chunk_header.list[i + 1];
            }
            _ = utils.atomically(
                bool,
                &self.small_locks[bin],
                "small_malloc_add_pages_from_new_chunk",
                Self.predoSmallAllocAddPagesFromNewChunk,
                Self.doSmallAllocAddPagesFromNewChunk,
                .{ self, bin, offset, chunk_header },
            );
        }

        self.verifySmallInvariants();
        const result = utils.atomically(
            ?[*]u8,
            &self.small_locks[bin],
            "small_malloc",
            Self.predoSmallAlloc,
            Self.doSmallAlloc,
            .{ self, bin, offset, @truncate(u32, obj_size) },
        );
        self.verifySmallInvariants();

        if (result) |ptr| {
            std.debug.assert(utils.binFromBinAndSize(zalloc.chunk_infos[utils.addressToChunkNumber(ptr)].bin_and_size) == bin);
            return ptr[0..len];
        }
    }
}

fn predoSmallAlloc(_: anytype, _: anytype, _: anytype, _: anytype) void {
    @panic("todo");
}
fn doSmallAlloc(self: *Self, bin: BinNumber, offset: u32, obj_size: u32) ?[*]u8 {
    const fullest = self.dsbi.fullest_offset[bin];
    if (fullest == 0) return null;

    const obj_per_folio = static_bin_info[bin].objects_per_folio;
    var fetch_offset = fullest;
    var result_pp = self.dsbi.lists.b[offset + fetch_offset];
    if (fullest == obj_per_folio and result_pp == null) {
        fetch_offset += 1;
        result_pp = self.dsbi.lists.b[offset + fetch_offset];
    }

    std.debug.assert(result_pp != null);

    const next = result_pp.?.next;
    self.dsbi.lists.b[offset + fetch_offset] = next;

    if (next) |n|
        n.prev = null;

    const old_head_below = self.dsbi.lists.b[offset + fullest - 1];
    result_pp.?.next = old_head_below;
    if (old_head_below) |o_h_b|
        o_h_b.prev = result_pp;
    self.dsbi.lists.b[offset + fullest - 1] = result_pp;

    if (fullest > 1)
        self.dsbi.fullest_offset[bin] = fullest - 1
    else {
        var use_new_fullest: u32 = 0;
        var new_fullest: u32 = 1;
        while (new_fullest < obj_per_folio + 2) : (new_fullest += 1) {
            if (self.dsbi.lists.b[offset + new_fullest] != null) {
                if (new_fullest == obj_per_folio + 1)
                    new_fullest = obj_per_folio;
                use_new_fullest = new_fullest;
                break;
            }
        }
        self.dsbi.fullest_offset[bin] = @truncate(u16, use_new_fullest);
    }

    const w_max = std.math.divCeil(u16, static_bin_info[bin].objects_per_folio, 64) catch unreachable;
    var w: usize = 0;
    while (w < w_max) : (w += 1) {
        const bw = result_pp.?.in_use_bitmap[w];
        if (bw != std.math.maxInt(u64)) {
            const bwbar = ~bw;
            const bit_to_set = @clz(u64, bwbar);
            result_pp.?.in_use_bitmap[w] = bw | (@as(u64, 1) << @truncate(u6, bit_to_set));

            const chunk_addr: u64 = @ptrToInt(utils.addressToChunkAddress(result_pp.?));
            const wasted_off: u64 = @as(u64, static_bin_info[bin].overhead_pages_per_chunk) * utils.page_size;
            const folio_num: u64 = utils.offsetInChunk(result_pp.?) / @sizeOf(PerFolio);
            const folio_size: u64 = static_bin_info[bin].folio_size;
            const folio_off: u64 = folio_num * folio_size;
            const obj_off: u64 = (w * 64 + bit_to_set) * obj_size;
            return @intToPtr([*]u8, chunk_addr + wasted_off + folio_off + obj_off);
        }
    }
    unreachable;
}

fn predoSmallAllocAddPagesFromNewChunk(self: *Self, bin: BinNumber, offset: u32, chunk_header: *SmallChunkHeader) void {
    const folio_per_chunk = static_bin_info[bin].folios_per_chunk;
    const obj_per_folio = static_bin_info[bin].objects_per_folio;
    utils.prefetchWrite(&self.dsbi.lists.b[offset + obj_per_folio + 1]);
    utils.prefetchWrite(&chunk_header.list[folio_per_chunk - 1].next);
    if (self.dsbi.fullest_offset[bin] == 0)
        utils.prefetchWrite(&self.dsbi.fullest_offset[bin]);
}

fn doSmallAllocAddPagesFromNewChunk(self: *Self, bin: BinNumber, offset: u32, chunk_header: *SmallChunkHeader) bool {
    const folio_per_chunk = static_bin_info[bin].folios_per_chunk;
    const obj_per_folio = static_bin_info[bin].objects_per_folio;
    const old_head = self.dsbi.lists.b[offset + obj_per_folio + 1];
    self.dsbi.lists.b[offset + obj_per_folio + 1] = &chunk_header.list[0];
    chunk_header.list[folio_per_chunk - 1].next = old_head;
    if (self.dsbi.fullest_offset[bin] == 0)
        self.dsbi.fullest_offset[bin] = obj_per_folio;
    return true;
}

fn dynamicSmallBinOffset(bin: BinNumber) u32 {
    const offsets = [_]u32{
        0,     514,   2564,  3590,  5640,  5898,  6924,  7438,
        8464,  8594,  9108,  9366,  9880,  9946,  10204, 10334,
        10592, 10626, 10756, 10822, 10952, 10970, 11036, 11102,
        11112, 11178, 11244, 11310, 11316, 11382, 11448, 11514,
        11518, 11584, 11650, 11653, 11719, 11785, 11788, 11854,
    };
    return offsets[bin];
}

test "static analysis" {
    std.testing.refAllDecls(Self);
}
