const std = @import("std");
const Allocator = std.mem.Allocator;
const Zalloc = @import("zalloc").Zalloc;
const Gpa = std.heap.GeneralPurposeAllocator(.{});
const Arena = std.heap.ArenaAllocator;
const Page = std.heap.page_allocator;
const Malloc = std.heap.c_allocator;

pub fn main() !void {
    // Init all
    var zally = Zalloc.init();
    var gally = Gpa{};
    var ally = Arena.init(std.heap.c_allocator);
    var pally = Page;
    var mally = Malloc;

    const alloc_n = 5;
    const allocs = [alloc_n]Allocator{
        zally.allocator(), gally.allocator(),
        ally.allocator(),  pally,
        mally,
    };
    const alloc_names = [_][]const u8{ "zalloc", "gpa", "arena", "page", "malloc" };

    const fn_n = 2;
    const fns = [fn_n]fn (Allocator) callconv(.Inline) void{ allocSingleSizeThenFree, allocDifferentSizeThenFree };
    const fn_names = [fn_n][]const u8{ "allocSingleSizeThenFree", "allocDifferentSizeThenFree" };

    const reps = 1 << 12;
    var timings: [fn_n][alloc_n][reps]u64 = [_][alloc_n][reps]u64{
        [_][reps]u64{[_]u64{0} ** reps} ** alloc_n,
    } ** fn_n;
    var k: u64 = 0;
    var now = try std.time.Timer.start();
    while (k < reps) : (k += 1) {
        for (allocs) |allocator, j| {
            inline for (fns) |f, i| {
                now.reset();
                f(allocator);
                timings[i][j][k] = now.lap();
            }
        }
    }
    for (timings) |f, f_i| {
        for (f) |alloc, alloc_i| {
            var sum: u64 = 0;
            for (alloc) |rep| sum += rep;
            std.debug.print(
                "{s: <26} took {: >6}ns with {s}\n",
                .{ fn_names[f_i], sum / reps, alloc_names[alloc_i] },
            );
        }
        std.debug.print("\n", .{});
    }

    // Deinit all
    _ = zally;
    std.debug.assert(!gally.deinit());
    ally.deinit();
    _ = pally;
    _ = mally;
}

inline fn allocSingleSizeThenFree(alloc: Allocator) void {
    const size = 512;
    var slice: []u8 = alloc.alloc(u8, size) catch unreachable;

    alloc.free(slice);
}

// TODO: random
inline fn allocDifferentSizeThenFree(alloc: Allocator) void {
    const n = 30;
    const sizes = [n]u32{
        134,  4038, 2430, 862,  3138, 585,
        3857, 2575, 2833, 1688, 2790, 3461,
        219,  3120, 2592, 3781, 2115, 922,
        1029, 893,  3956, 24,   547,  2863,
        2207, 578,  3944, 3800, 3324, 1876,
    };
    var slices: [n][]u8 = undefined;

    for (sizes) |size, i| {
        slices[i] = alloc.alloc(u8, size) catch unreachable;
    }
    for (slices) |slice| {
        alloc.free(slice);
    }
}
