const std = @import("std");
const utils = @import("utils.zig");
const VoidStar = utils.VoidStar;
const Self = @This();

threadlocal var cache_inited: bool = false;
threadlocal var cache_for_thread: CpuCache = .{};
threadlocal var cached_cpu: u32 = 0;
threadlocal var cached_cpu_count: u32 = 0;

cached_objs: CachedObj = .{},
var key: utils.pthread_key_t = 0;
var once_control: utils.pthread_once_t = utils.PTHREAD_ONCE_INIT;

pub fn init() void {
    if (!cache_inited) {
        cache_inited = true;
        std.once(makeKey).call();
    }
    if (utils.pthread_setspecific(key, &cache_inited) != 0) @panic("pthread failure!");
}

fn deinit(self: ?*anyopaque) callconv(.C) void {
    _ = self;
}

fn makeKey() void {
    if (utils.pthread_key_create(&key, Self.deinit) != 0) @panic("pthread failure");
}

const LLNode = struct {
    next: ?*@This(),
};

const CachedObj = struct {
    bytecount: u64 align(32) = 0,
    head: ?*LLNode = null,
    tail: ?*LLNode = null,

    fn tryGetCached(self: *@This(), size: u64) VoidStar {
        const result = self.head;
        if (result) |res| {
            self.bytecount -= size;
            self.head = res.next;
        }
        return result;
    }
};

const BinCache align(64) = struct {
    oc: [2]CachedObj = [_]CachedObj{.{}} ** 2,

    pub fn tryGetCachedBoth(self: *@This(), size: u64) VoidStar {
        const r = self.oc[0].tryGetCached(size);
        return if (r != null)
            r
        else
            self.oc[1].tryGetCached(size);
    }
};

const CpuCache align(64) = struct {
    bc: [utils.first_huge_bin_number]BinCache = [_]BinCache{.{}} ** utils.first_huge_bin_number,
};

fn getCpu() u32 {
    cached_cpu_count += 1;
    if (@mod(cached_cpu_count, 16) == 0) cached_cpu = utils.sched_getcpu();
    return cached_cpu;
}

fn tryGetGlobalCached(proc: u32, bin: u32, size: u64) VoidStar {
    _ = proc;
    _ = bin;
    _ = size;
    @panic("trygetglobalcached");
}
