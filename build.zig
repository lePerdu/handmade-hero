const std = @import("std");

pub fn build(b: *std.Build) void {
    // TODO: Extract linux-specific parts to sub-functions when supporting
    // other platforms
    const target = b.standardTargetOptions(.{
        .whitelist = &.{
            std.Target.Query{ .os_tag = .linux },
        },
    });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .Debug,
    });

    const game_mod = b.createModule(.{
        .root_source_file = b.path("src/game/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const game_lib = b.addLibrary(.{
        .name = "handmade-game",
        .root_module = game_mod,
        .linkage = .dynamic,
        .use_llvm = true,
    });

    const game_lib_install = b.addInstallArtifact(game_lib, .{});

    const xdg_shell_scan_c_source =
        b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    // TODO: Make path configurable
    xdg_shell_scan_c_source.addArg(
        "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
    );
    const xdg_shell_c_source =
        xdg_shell_scan_c_source.addOutputFileArg("xdg-shell-protocol.c");

    const xdg_shell_scan_c_header =
        b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    // TODO: Make path configurable
    xdg_shell_scan_c_header.addArg(
        "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
    );
    const xdg_shell_c_header =
        xdg_shell_scan_c_header.addOutputFileArg("xdg-shell-client-protocol.h");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addCSourceFile(.{ .file = xdg_shell_c_source });
    // TODO: dirname?
    exe_mod.addIncludePath(xdg_shell_c_header.dirname());
    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.linkSystemLibrary("asound", .{});

    const exe = b.addExecutable(.{
        .name = "handmade-hero",
        .root_module = exe_mod,
        .use_llvm = true,
    });

    const exe_install = b.addInstallArtifact(exe, .{});
    // TODO: Is this the right place to link the steps?
    exe_install.step.dependOn(&game_lib_install.step);
    b.getInstallStep().dependOn(&exe_install.step);

    const check_step = b.step("check", "Check compilation");
    check_step.dependOn(&game_lib.step);
    check_step.dependOn(&exe.step);

    const reload_step = b.step(
        "hot-reload",
        "Rebuild game dynalib library to be hot reloaded",
    );
    reload_step.dependOn(&game_lib_install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&game_lib_install.step);

    const run_step = b.step("run", "Run game");
    run_step.dependOn(&run_cmd.step);
}
