const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // バージョンはbuild.zig.zonから取得（単一ソースオブトルース）
    const version = @import("build.zig.zon").version;

    // リリースビルド時はデバッグ情報を削除
    const strip = b.option(bool, "strip", "Strip debug info") orelse (optimize != .Debug);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    // バージョンをビルドオプションとして渡す
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    exe_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "ze",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
