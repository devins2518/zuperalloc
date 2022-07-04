const utils = @import("utils.zig");

const prid_cache_time = 128;

// TODO: kinda smelly
var partitioned_footprint: [utils.cpu_limit]u64 = .{0} ** utils.cpu_limit;
threadlocal var prid: ProcessorId = .{};

const ProcessorId = struct {
    cpu_id: u32 align(64) = 0,
    count: u32 = 0,
};

fn checkCpuId() void {
    if (@mod(prid.count, prid_cache_time) == 0)
        prid.cpu_id = @mod(utils.sched_getcpu(), utils.cpu_limit);
    prid.count += 1;
}

pub fn addToFootprint(d: i64) void {
    checkCpuId();
    // ??
    _ = @atomicRmw(u64, &partitioned_footprint[prid.cpu_id], .Add, @bitCast(u64, d), .SeqCst);
}

pub fn getFootprint() u64 {
    var sum: u64 = 0;
    var i: u32 = 0;
    while (i < utils.cpu_limit) : (i += 1) {
        sum += partitioned_footprint[i];
    }
    return sum;
}
