const std = @import("std");
const utils = @import("utils.zig");
const PerFolio = @import("Salloc.zig").PerFolio;
const Ki = 1024;
const Me = Ki * Ki;
pub const static_bin_info: [74]StaticBin align(64) = blk: {
    var array = [_]StaticBin{undefined} ** 74;
    var i = 0;

    var prev_non_aligned_size = 8;
    var k = 8;
    while (true) : (k *= 2) outer: {
        var c = 4;
        while (c <= 7) : (c += 1) {
            const objsize = (c * k) / 4;
            if (objsize > 4 * utils.cache_line)
                break :outer;
            const bin = StaticBin.from(.small, objsize);
            if (objsize == 8 or (isPowerOfTwo(objsize) and objsize > utils.cache_line)) {} else {
                prev_non_aligned_size = objsize;
            }
            array[i] = bin;
            i += 1;
        }
    }
    break :blk array;
};

const BinSize = enum { small, large, huge };
pub const StaticBin = struct {
    const Self = @This();
    object_size: u64,
    folio_size: u64,
    objects_per_folio: u16,
    folios_per_chunk: u16,
    overhead_pages_per_chunk: u8,
    object_division_shift_magic: u6,
    folio_division_shift_magic: u6,
    object_division_multiply_magic: u64,
    folio_division_multiply_magic: u64,

    fn calculateFolioSize(comptime obj_size: comptime_int) comptime_int {
        return if (obj_size > utils.chunk_size)
            obj_size
        else if (isPowerOfTwo(obj_size)) blk: {
            break :blk if (obj_size < utils.page_size)
                utils.page_size
            else
                obj_size;
        } else if (obj_size > 16 * 1024)
            obj_size
        else if (obj_size > 256)
            (obj_size / utils.cache_line) * utils.page_size
        else if (obj_size > utils.page_size)
            obj_size
        else
            return lcm(obj_size, utils.page_size);
    }

    fn calculateOverheadPagesPerChunk(comptime cat: BinSize, comptime folio_size: comptime_int) comptime_int {
        return switch (cat) {
            .huge => 0,
            .large => 1,
            .small => utils.ceil(@sizeOf(PerFolio) * (utils.chunk_size / folio_size), utils.page_size),
        };
    }

    fn calculateShiftMagic(comptime d: comptime_int) comptime_int {
        return if (d > utils.chunk_size)
            1
        else if (isPowerOfTwo(d))
            ceilLog2(d)
        else
            32 + ceilLog2(d);
    }

    fn calculateMultiplyMagic(comptime d: comptime_int) comptime_int {
        return if (d > utils.chunk_size)
            1
        else if (isPowerOfTwo(d))
            1
        else
            (d - 1 + (1 << calculateShiftMagic(d))) / d;
    }

    fn from(comptime cat: BinSize, comptime obj_size: comptime_int) Self {
        const folio_size = calculateFolioSize(obj_size);
        const overhead_pages_per_chunk = calculateOverheadPagesPerChunk(cat, folio_size);
        const folios_per_chunk = if (obj_size < utils.chunk_size)
            (utils.chunk_size - overhead_pages_per_chunk * utils.page_size) / folio_size
        else
            1;
        return .{
            .object_size = obj_size,
            .folio_size = folio_size,
            .objects_per_folio = folio_size / obj_size,
            .folios_per_chunk = folios_per_chunk,
            .overhead_pages_per_chunk = overhead_pages_per_chunk,
            .object_division_shift_magic = calculateShiftMagic(obj_size),
            .folio_division_shift_magic = calculateShiftMagic(folio_size),
            .object_division_multiply_magic = calculateMultiplyMagic(obj_size),
            .folio_division_multiply_magic = calculateMultiplyMagic(folio_size),
        };
    }
};

fn isPowerOfTwo(comptime x: comptime_int) bool {
    return (x & (x - 1)) == 0;
}

fn lcm(comptime a: comptime_int, comptime b: comptime_int) comptime_int {
    const g = gcd(a, b);
    return (a / g) * b;
}

fn gcd(comptime a: comptime_int, comptime b: comptime_int) comptime_int {
    return if (a == 0)
        b
    else if (b == 0 or a == b)
        a
    else if (a < b)
        gcd(a, @mod(b, a))
    else
        gcd(b, @mod(a, b));
}

fn ceilLog2(comptime c: comptime_int) comptime_int {
    var result = if (isPowerOfTwo(c)) 0 else 1;
    var d = c;
    while (d > 1) {
        result += 1;
        d = d >> 1;
    }
    return result;
}
