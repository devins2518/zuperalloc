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
    lib.install();

    const main_tests = b.addTest("src/lib.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const bench_cmd_str = &[_][]const u8{
        "hyperfine",
        "-N",
        "./zig-out/bin/bench",
    };
    const bench_cmd = b.addSystemCommand(bench_cmd_str);
    bench_cmd.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
