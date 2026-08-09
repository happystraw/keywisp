const std = @import("std");

const wl = @import("wayland");

const manifest = @import("build.zig.zon");
const project_name = @tagName(manifest.name);

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *std.Build) void {
    const options: Options = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };
    const project_options = b.addOptions();
    project_options.addOption([]const u8, "name", project_name);
    project_options.addOption([]const u8, "version", manifest.version);
    const project_mod = project_options.createModule();

    const wayland_mod = createWaylandModule(b, options);
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = protocol_mod },
        },
    });
    input_mod.linkSystemLibrary("libinput", .{});
    input_mod.linkSystemLibrary("libudev", .{});

    const output_mod = b.addModule("output", .{
        .root_source_file = b.path("src/output.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "project", .module = project_mod },
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "wayland", .module = wayland_mod },
        },
    });
    output_mod.linkSystemLibrary("cairo", .{});
    output_mod.linkSystemLibrary("pango", .{});
    output_mod.linkSystemLibrary("pangocairo", .{});
    output_mod.linkSystemLibrary("gobject-2.0", .{});
    output_mod.linkSystemLibrary("wayland-client", .{});
    output_mod.linkSystemLibrary("xkbcommon", .{});

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "project", .module = project_mod },
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "output", .module = output_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = project_name,
        .root_module = main_mod,
        .use_llvm = if (options.optimize == .Debug) true else null,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", b.fmt("Run {s}", .{project_name})).dependOn(&run_cmd.step);

    const input_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/input.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    input_example_mod.addImport("input", input_mod);
    const input_example = b.addExecutable(.{
        .name = "input-example",
        .root_module = input_example_mod,
        .use_llvm = true,
    });
    const install_input_example = b.addInstallArtifact(input_example, .{});
    b.step("example-input", "Build the /dev/input example").dependOn(&install_input_example.step);

    const output_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/output.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    output_example_mod.addImport("output", output_mod);
    const output_example = b.addExecutable(.{
        .name = "output-example",
        .root_module = output_example_mod,
        .use_llvm = true,
    });
    const install_output_example = b.addInstallArtifact(output_example, .{});
    b.step("example-output", "Build the stdout output example").dependOn(&install_output_example.step);

    const main_tests = b.addTest(.{ .root_module = main_mod, .use_llvm = true });
    const input_tests = b.addTest(.{ .root_module = input_mod, .use_llvm = true });
    const output_tests = b.addTest(.{ .root_module = output_mod, .use_llvm = true });
    const run_main_tests = b.addRunArtifact(main_tests);
    const run_input_tests = b.addRunArtifact(input_tests);
    const run_output_tests = b.addRunArtifact(output_tests);

    const test_input_step = b.step("test-input", "Run input module tests");
    test_input_step.dependOn(&run_input_tests.step);
    const test_output_step = b.step("test-output", "Run output module tests");
    test_output_step.dependOn(&run_output_tests.step);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_input_tests.step);
    test_step.dependOn(&run_output_tests.step);
}

fn createWaylandModule(b: *std.Build, options: Options) *std.Build.Module {
    const scanner = wl.Scanner.create(b, .{});
    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 3);
    scanner.generate("wl_seat", 5);
    scanner.generate("zwlr_layer_shell_v1", 1);

    return b.createModule(.{
        .root_source_file = scanner.result,
        .target = options.target,
        .optimize = options.optimize,
    });
}
