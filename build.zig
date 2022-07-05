const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // b.use_stage1 = false;
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const bench = b.addExecutable("bench", "bench/main.zig");
    bench.addPackagePath("zalloc", "src/lib.zig");
    bench.setTarget(target);
    // bench.setBuildMode(.ReleaseFast);
    bench.install();

    const lib = b.addStaticLibrary("zalloc", "src/lib.zig");
    lib.setBuildMode(mode);
    lib.setTarget(target);
    lib.install();

    const main_tests = b.addTest("src/lib.zig");
    main_tests.setTarget(target);
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const bench_cmd = bench.run();
    bench_cmd.step.dependOn(&bench.install_step.?.step);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
