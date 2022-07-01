const std = @import("std");
const utils = @import("utils.zig");
const Mutex = std.Thread.Mutex;
const Self = @This();
const BinNumber = utils.BinNumber;

const global_cache_depth = 8;
const per_cpu_cache_bytecount_limit: u64 = 1024 * 1024;
const thread_cache_bytecount_limit: u64 = 2 * 4096;

pub threadlocal var cached_cpu: u32 = 0;
pub threadlocal var cached_cpu_count: u32 = 0;
pub threadlocal var cache_for_thread: CpuCache = .{};
// Needed to run destructors for threadlocal caches
pub threadlocal var cache_inited: bool = false;

var key: utils.pthread_key_t = 0;

cpu_cache: [utils.cpu_limit]CpuCache = [_]CpuCache{.{}} ** utils.cpu_limit,
cpu_cache_locks: [utils.cpu_limit][utils.first_huge_bin_number]Mutex =
    [_][utils.first_huge_bin_number]Mutex{[_]Mutex{.{}} ** utils.first_huge_bin_number} ** utils.cpu_limit,
global_cache: GlobalCache = .{},
global_cache_locks: [utils.first_huge_bin_number]Mutex = [_]Mutex{.{}} ** utils.first_huge_bin_number,
// TODO get type
once: @TypeOf(std.once(makeKey)) = std.once(makeKey),
use_threadcache: bool = true,

pub fn init(self: *Self) void {
    if (!cache_inited) {
        cache_inited = true;
        self.once.call();
    }
    if (utils.pthread_setspecific(key, &cache_inited) != 0) @panic("pthread_setspecific failure");
}

fn makeKey() void {
    if (utils.pthread_key_create(&key, deinitThreadlocals) != 0) @panic("pthread_key_create failure");
}

pub fn deinitThreadlocals(v: ?*anyopaque) callconv(.C) void {
    std.debug.assert(v == @ptrCast(?*anyopaque, &cache_inited));

    var bin: usize = 0;
    while (bin < utils.first_huge_bin_number) : (bin += 1) {
        var j: usize = 0;
        while (j < 2) : (j += 1) {
            while (cache_for_thread.bin_caches[bin].cached_objs[j].head) |_| {
                @panic("todo");
            }
        }
    }
}

fn smallFree(_: *anyopaque) void {
    @panic("todo");
}
fn largeFree(_: *anyopaque) void {
    @panic("todo");
}

pub fn getCpu() u32 {
    if (@mod(cached_cpu_count, 16) == 0) cached_cpu = (utils.sched_getcpu());
    cached_cpu_count += 1;
    return cached_cpu;
}

const Node = struct {
    next: ?*Node,
};

const ObjCache = struct {
    bytecount: u64 align(32) = 0,
    head: ?*Node = null,
    tail: ?*Node = null,

    pub fn tryGetCached(self: *@This(), len: usize) ?[]u8 {
        const result = self.head orelse return null;
        self.bytecount -= len;
        self.head = result.next;

        return @ptrCast(
            [*]align(utils.page_size) u8,
            @alignCast(utils.page_size, result),
        )[0..len];
    }

    fn collectObjsForThreadCache(self: *@This(), first_n_objs: *@This(), len: usize) void {
        if (self.bytecount < thread_cache_bytecount_limit) {
            first_n_objs.* = self.*;
            self.* = .{};
        } else {
            first_n_objs.head = self.head;
            var ptr = self.head;
            var bytecount = len;
            while (bytecount < thread_cache_bytecount_limit) {
                bytecount += len;
                std.debug.assert(ptr != null);
                ptr = ptr.?.next;
            }
            std.debug.assert(ptr != null);
            first_n_objs.tail = ptr;
            first_n_objs.bytecount = bytecount;
            self.head = ptr.?.next;
            if (self.head == null) self.tail = null;
            self.bytecount -= bytecount;
            ptr.?.next = null;
        }
    }
};

const BinCache = struct {
    cached_objs: [2]ObjCache align(64) = [_]ObjCache{.{}} ** 2,

    pub fn tryGetCachedBoth(self: *@This(), len: usize) ?[]u8 {
        const r = self.cached_objs[0].tryGetCached(len) orelse
            self.cached_objs[1].tryGetCached(len);
        return r;
    }

    fn predoRemoveCpuCache(self: *@This(), cached_obj: *ObjCache) void {
        utils.prefetchWrite(self);
        utils.prefetchWrite(cached_obj);
    }

    // TODO: return void?
    fn doRemoveCpuCache(self: *@This(), cached_obj: *ObjCache) bool {
        if (self.cached_objs[0].head) {
            cached_obj.* = self.cached_objs[0];
            self.cached_objs[0] = .{};
        } else if (self.cached_objs[1].head) {
            cached_obj.* = self.cached_objs[1];
            self.cached_objs[1] = .{};
        } else {
            cached_obj.* = .{};
        }
        return true;
    }

    fn predoAddCacheToCpu(self: *@This(), cached_obj: *const ObjCache) void {
        std.debug.assert(cached_obj.head != null);
        const bytes0 = self.cached_objs[0].bytecount;
        const bytes1 = self.cached_objs[1].bytecount;
        utils.prefetchWrite(self);
        utils.prefetchRead(cached_obj);
        if (bytes0 != 0 and bytes1 != 0) {
            if (bytes0 <= bytes1)
                utils.prefetchWrite(self.cached_objs[0].tail)
            else
                utils.prefetchWrite(self.cached_objs[1].tail);
        }
    }

    // TODO: return void?
    fn doAddCacheToCpu(self: *@This(), cached_obj: *const ObjCache) bool {
        const bytes0 = self.cached_objs[0].bytecount;
        const bytes1 = self.cached_objs[1].bytecount;
        if (bytes0 == 0) {
            self.cached_objs[0] = cached_obj.*;
        } else if (bytes1 == 0) {
            self.cached_objs[1] = cached_obj.*;
        } else if (bytes0 <= bytes1) {
            self.cached_objs[0].tail.?.next = cached_obj.head;
            self.cached_objs[0].tail = cached_obj.tail;
            self.cached_objs[0].bytecount += cached_obj.bytecount;
        } else {
            self.cached_objs[1].tail.?.next = cached_obj.head;
            self.cached_objs[1].tail = cached_obj.tail;
            self.cached_objs[1].bytecount += cached_obj.bytecount;
        }
        return true;
    }

    fn predoFetchOneFromCpu(self: *@This(), _: usize) void {
        for (self.cached_objs) |obj| {
            const result = obj.head;
            if (result) |res| {
                utils.prefetchWrite(obj);
                utils.prefetchRead(res);
                return;
            }
        }
    }

    fn doFetchOneFromCpu(self: *@This(), len: usize) ?[]u8 {
        for (self.cached_objs) |*obj| {
            const result = obj.head;
            if (result) |res| {
                obj.bytecount -= len;
                const next = res.next;
                obj.head = next;
                if (next == null) obj.tail = null;
                return @ptrCast(
                    [*]align(utils.page_size) u8,
                    @alignCast(utils.page_size, res),
                )[0..len];
            }
        }
        return null;
    }

    fn predoGetGlobalCache(self: *@This(), global_bin_cache: *GlobalBinCache, _: usize) void {
        const n = @atomicLoad(u8, &global_bin_cache.nonempty_caches, .Acquire);
        if (n > 0) {
            const result = if (global_bin_cache.cached_objects[n - 1].head) |res| res else return;
            const next = result.next;
            if (next != null) {
                const co0 = self.cached_objs[0];
                const co1 = self.cached_objs[1];
                const co = if (co0.bytecount < co1.bytecount) co0 else co1;
                if (co.head == null) {
                    _ = @atomicLoad(?*Node, &self.cached_objs[n - 1].tail, .Acquire);
                    utils.prefetchWrite(co.tail);
                } else {
                    _ = @atomicLoad(?*Node, &self.cached_objs[n - 1].tail.?.next, .Acquire);
                    utils.prefetchWrite(self.cached_objs[n - 1].tail.?.next);
                }
                utils.prefetchWrite(co.head);
            }
            utils.prefetchWrite(&global_bin_cache.nonempty_caches);
        }
    }

    fn doGetGlobalCache(self: *@This(), global_bin_cache: *GlobalBinCache, len: usize) ?[]u8 {
        const n = global_bin_cache.nonempty_caches;
        if (n > 0) {
            const result = global_bin_cache.cached_objects[n - 1].head;
            const next = result.?.next;
            if (next != null) {
                const co0 = &self.cached_objs[0];
                const co1 = &self.cached_objs[1];
                const co = if (co0.bytecount < co1.bytecount) co0 else co1;
                const co_head = co.head;
                if (co_head == null)
                    co.tail = global_bin_cache.cached_objects[n - 1].tail
                else
                    global_bin_cache.cached_objects[n - 1].tail.?.next = co_head;
                co.head = next;
                co.bytecount = global_bin_cache.cached_objects[n - 1].bytecount - len;
            }
            global_bin_cache.nonempty_caches = n - 1;
            return @ptrCast([*]u8, result)[0..len];
        } else return null;
    }

    fn predoRemoveCacheFromCpu(self: *@This(), cached_obj: *ObjCache) void {
        utils.prefetchWrite(self);
        utils.prefetchWrite(cached_obj);
    }

    fn doRemoveCacheFromCpu(self: *@This(), cached_obj: *ObjCache) bool {
        if (self.cached_objs[0].head != null) {
            cached_obj.* = self.cached_objs[0];
            self.cached_objs[0] = .{};
        } else if (self.cached_objs[1].head != null) {
            cached_obj.* = self.cached_objs[1];
            self.cached_objs[1] = .{};
        } else {
            cached_obj.* = .{};
        }
        return true;
    }
};

const GlobalBinCache = struct {
    nonempty_caches: u8 align(64) = 0,
    cached_objects: [global_cache_depth]ObjCache = [_]ObjCache{.{}} ** global_cache_depth,
};

const GlobalCache = struct {
    bin_cache: [utils.first_huge_bin_number]GlobalBinCache = [_]GlobalBinCache{.{}} ** utils.first_huge_bin_number,
};

const CpuCache = struct {
    bin_caches: [utils.first_huge_bin_number]BinCache align(64) = [_]BinCache{.{}} ** utils.first_huge_bin_number,
};

pub fn tryGetCpuCached(self: *Self, proc: usize, bin: BinNumber, len: usize) ?[]u8 {
    if (self.use_threadcache) {
        self.init();
        const tc = &cache_for_thread.bin_caches[bin];
        const cc = &self.cpu_cache[proc].bin_caches[bin];

        var co: ObjCache = undefined;
        _ = utils.atomically(
            bool,
            &self.cpu_cache_locks[proc][bin],
            "remove_a_cache_from_cpu",
            BinCache.predoRemoveCacheFromCpu,
            BinCache.doRemoveCacheFromCpu,
            .{ cc, &co },
        );
        const result = if (co.head) |h| h else return null;
        co.head = result.next;
        co.bytecount -= len;

        {
            const first_n_objects = undefined;
            collectObjectsForThreadCache(co, first_n_objects, len);

            if (tc.cached_objs[0].head == null)
                tc.cached_objs[0] = first_n_objects
            else {
                std.debug.assert(tc.cached_objs[1].head == null);
                tc.cached_objs[1] = first_n_objects;
            }
        }

        if (co.head != null)
            _ = utils.atomically(
                bool,
                &self.cpu_cache_locks[proc][bin],
                "add_a_cache_to_cpu",
                BinCache.predoAddCacheToCpu,
                BinCache.doAddCacheToCpu,
                .{ cc, &co },
            );

        return @ptrCast([*]u8, result)[0..len];
    } else {
        return utils.atomically(
            ?[]u8,
            &self.cpu_cache_locks[proc][bin],
            "fetch_one_from_cpu",
            BinCache.predoFetchOneFromCpu,
            BinCache.doFetchOneFromCpu,
            .{ &self.cpu_cache[proc].bin_caches[bin], len },
        );
    }
}

fn collectObjectsForThreadCache(_: anytype, _: anytype, _: anytype) void {}

pub fn tryGetGlobalCached(self: *Self, proc: usize, bin: BinNumber, len: usize) ?[]u8 {
    return utils.atomically2(
        ?[]u8,
        &self.global_cache_locks[bin],
        &self.cpu_cache_locks[proc][bin],
        "get_global_cached",
        BinCache.predoGetGlobalCache,
        BinCache.doGetGlobalCache,
        .{ &self.cpu_cache[proc].bin_caches[bin], &self.global_cache.bin_cache[bin], len },
    );
}

fn tryPutCached(obj: *Node, cached_obj: *ObjCache, len: usize, cache_size: usize) bool {
    const bytes = cached_obj.bytecount;
    if (bytes < cache_size) {
        const head = cached_obj.head;
        obj.next = head;
        cached_obj.head = obj;
        if (head == null) {
            cached_obj.bytecount = len;
            cached_obj.tail = obj;
        } else cached_obj.bytecount = bytes + len;
        return true;
    } else return false;
}

fn tryPutCachedBoth(obj: *Node, bin_cache: BinCache, len: usize, cache_size: usize) bool {
    return (tryPutCached(obj, bin_cache.cached_objs[0], len, cache_size) or
        tryPutCached(obj, bin_cache.cached_objs[1], len, cache_size));
}

fn predoTryPutIntoCpuCachePart(obj: *Node, t_cached_obj: *ObjCache, c_cached_obj: *ObjCache) bool {
    const old_bytes = c_cached_obj.bytecount;
    if (old_bytes < per_cpu_cache_bytecount_limit) {
        obj.next = t_cached_obj.head;
        utils.prefetchWrite(t_cached_obj.tail);
        utils.prefetchWrite(t_cached_obj);
        utils.prefetchWrite(c_cached_obj);
        return true;
    } else return false;
}

fn predoTryPutIntoCpuCache(obj: *Node, t_cached_obj: *ObjCache, bin_cache: *BinCache, _: usize) void {
    if (!predoTryPutIntoCpuCachePart(obj, t_cached_obj, bin_cache.cached_objs[0]))
        predoTryPutIntoCpuCachePart(obj, t_cached_obj, bin_cache.cached_objs[1]);
    return;
}

fn tryPutIntoCpuCachePart(obj: *Node, t_cached_obj: *ObjCache, c_cached_obj: *ObjCache, len: usize) bool {
    const old_bytes = c_cached_obj.bytecount;
    const old_head = c_cached_obj.head;
    if (old_bytes < per_cpu_cache_bytecount_limit) {
        obj.next = t_cached_obj.head;

        std.debug.assert(t_cached_obj.tail != null);
        t_cached_obj.tail.?.next = old_head;

        c_cached_obj.bytecount = old_bytes + t_cached_obj.bytecount + len;
        c_cached_obj.head = obj;
        if (old_head == null) c_cached_obj.tail = t_cached_obj.tail;

        t_cached_obj.bytecount = 0;
        t_cached_obj.head = null;
        t_cached_obj.tail = null;

        return true;
    }
    return false;
}

fn doPutIntoCpuCache(obj: *Node, t_cached_obj: *ObjCache, bin_cache: *BinCache, len: usize) void {
    if (!tryPutIntoCpuCachePart(obj, t_cached_obj, bin_cache.cached_objs[0], len) or
        tryPutIntoCpuCachePart(obj, t_cached_obj, bin_cache.cached_objs[1], len))
        return true
    else
        return false;
}

fn predoPutOneIntoCpuCache(obj: *Node, bin_cache: *BinCache, _: usize) void {
    inline for (bin_cache.cached_objs) |b_obj| {
        const old_bytes = b_obj.bytecount;
        if (old_bytes < per_cpu_cache_bytecount_limit) {
            const old_head = b_obj.head;
            obj.next = old_head;
            utils.prefetchWrite(&b_obj.bytecount);
            return;
        }
    }
}

fn doPutOneIntoCpuCache(obj: *Node, bin_cache: BinCache, len: usize) bool {
    inline for (bin_cache.cached_ojbs) |b_obj| {
        const old_bytes = b_obj.bytecount;
        if (old_bytes < per_cpu_cache_bytecount_limit) {
            const old_head = b_obj.head;
            if (old_head == null) b_obj.tail = obj;
            b_obj.head = obj;
            b_obj.bytecount = old_bytes + len;
            obj.next = old_head;

            return true;
        }
    }
    return false;
}

fn tryPutIntoCpuCache(self: *Self, obj: *Node, processor: u32, bin: BinNumber, len: usize) bool {
    _ = obj;
    _ = processor;
    _ = bin;
    _ = len;
    if (self.use_threadcache) {
        self.init();
        @panic("atomically");
    } else @panic("atomically");
}

fn predoPutIntoGlobalCache(obj: *Node, bin_cache: *BinCache, global_bin_cache: *GlobalBinCache, _: usize) void {
    const g_num = @atomicLoad(u8, global_bin_cache.nonempty_caches, .Acquire);
    const old_bytes = @atomicLoad(u64, bin_cache.cached_objs[0].bytecount, .Acquire);
    if (g_num < global_cache_depth and old_bytes >= per_cpu_cache_bytecount_limit) {
        obj.next = bin_cache.cached_objs[0].head;
        _ = @atomicLoad(u64, global_bin_cache.cached_objects[g_num].bytecount, .Acquire);
        utils.prefetchWrite(&global_bin_cache.cached_objects[g_num]);
        utils.prefetchWrite(&bin_cache.cached_objects[0]);
        utils.prefetchWrite(&global_bin_cache.nonempty_caches);
    }
}

fn doPutIntoGlobalCache(obj: *Node, bin_cache: *BinCache, global_bin_cache: *GlobalBinCache, len: usize) bool {
    const g_num = global_bin_cache.nonempty_caches;
    const old_bytes = bin_cache.cached_objs[0].bytecount;

    if (g_num < global_cache_depth and old_bytes >= per_cpu_cache_bytecount_limit) {
        obj.next = bin_cache.cached_objs[0].bytecount;
        global_bin_cache.cached_objects[g_num].bytecount = old_bytes + len;
        global_bin_cache.cached_objects[g_num].head = obj;
        global_bin_cache.cached_objects[g_num].tail = bin_cache.cached_objs[0].tail;

        global_bin_cache.nonempty_caches = g_num + 1;

        bin_cache.cached_objs[0] = .{};
        return true;
    }
    return false;
}

fn tryPutIntoGlobalCache(obj: *Node, proc: u32, bin: BinNumber, len: usize) bool {
    _ = obj;
    _ = proc;
    _ = bin;
    _ = len;
    @panic("todo");
}

fn cachedFree(self: *Self, buf: []u8, bin: BinNumber) void {
    std.debug.assert(bin < utils.first_huge_bin_number);
    const size = utils.binToSize(bin);

    if (self.use_threadcache) {
        self.init();
        if (tryPutCachedBoth(
            @ptrCast(*Node, buf.ptr),
            cache_for_thread.bin_caches[bin],
            size,
            thread_cache_bytecount_limit,
        )) return;
    }

    const p = @mod(getCpu(), utils.cpu_limit);
    if (tryPutIntoCpuCache(@ptrCast(*Node, buf.ptr), p, bin, size) or
        tryPutIntoGlobalCache(@ptrCast(*Node, buf.ptr), p, bin, size)) return;

    if (bin < utils.first_large_bin_number)
        smallFree(buf)
    else
        largeFree(buf);
}

test "static analysis" {
    std.testing.refAllDecls(Self);

    try std.testing.expect(@alignOf(BinCache) == 64);
    try std.testing.expect(@alignOf(CpuCache) == 64);
}
