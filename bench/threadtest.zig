const iters = 50;
const objs = 30000;
const threads = 1;
const work = 0;
const size = 1;

const Foo = struct {
    x: usize,
    y: usize,

    fn init() @This() {
        return .{ .x = 14, .y = 29 };
    }
};

fn worker() void {
    var a = [_]Foo{Foo.init()} ** (objs / threads);
    _ = a;
}

pub fn bench() void {}
