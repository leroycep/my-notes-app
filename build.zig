const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    var apple_pie = std.build.Pkg{
        .name = "apple_pie",
        .source = .{ .path = "dep/apple_pie/src/apple_pie.zig" },
    };
    var sqlite3 = std.build.Pkg{
        .name = "sqlite3",
        .source = .{ .path = "dep/sqlite-zig/src/sqlite3.zig" },
    };

    if (b.env_map.get("zigPackages")) |zig_packages_env_var| {
        var packages_iter = std.mem.tokenize(u8, zig_packages_env_var, ": \n");
        while (packages_iter.next()) |package_kv_str| {
            var kv_iter = std.mem.split(u8, package_kv_str, "=");
            const key = kv_iter.next().?;
            const value = kv_iter.rest();

            if (std.mem.eql(u8, key, "apple_pie")) {
                apple_pie.source = .{ .path = value };
            } else if (std.mem.eql(u8, key, "sqlite3")) {
                sqlite3.source = .{ .path = value };
            }
        }
    }

    if (b.option([]const u8, "sqlite3.zig", "Path to sqlite3.zig")) |sqlite3_path| {
        sqlite3.source = .{ .path = sqlite3_path };
    }

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .musl,
        },
    });

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("my-notes-app-server", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();
    exe.addPackage(apple_pie);
    exe.addPackage(sqlite3);
    exe.linkLibC();
    if (b.env_map.get("sqlite3Src")) |sqlite3Src| {
        exe.addCSourceFile(sqlite3Src, &.{});
    }

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
