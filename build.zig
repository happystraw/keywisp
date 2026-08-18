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
            .{ .name = "wayland", .module = createWaylandModule(b, options) },
        },
    });
    output_mod.linkSystemLibrary("cairo", .{});
    output_mod.linkSystemLibrary("pango", .{});
    output_mod.linkSystemLibrary("pangocairo", .{});
    output_mod.linkSystemLibrary("gobject-2.0", .{});
    output_mod.linkSystemLibrary("wayland-client", .{});
    output_mod.linkSystemLibrary("xkbcommon", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
        .strip = switch (options.optimize) {
            .ReleaseSafe, .ReleaseFast => true,
            else => null,
        },
        .imports = &.{
            .{ .name = "project", .module = project_mod },
            .{ .name = "protocol", .module = protocol_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "output", .module = output_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = project_name,
        .root_module = exe_mod,
        .use_llvm = if (options.optimize == .Debug) true else null,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", b.fmt("Run {s}", .{project_name})).dependOn(&run_cmd.step);

    addTests(b, exe_mod, input_mod, output_mod);
    addExamples(b, options, input_mod, output_mod);
}

fn addTests(b: *std.Build, exe_mod: *std.Build.Module, input_mod: *std.Build.Module, output_mod: *std.Build.Module) void {
    const test_step = b.step("test", "Run all tests");

    const exe_tests = b.addTest(.{ .root_module = exe_mod, .use_llvm = true });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    b.step("test-exe", "Run executable tests").dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const input_tests = b.addTest(.{ .root_module = input_mod, .use_llvm = true });
    const run_input_tests = b.addRunArtifact(input_tests);
    b.step("test-input", "Run input tests").dependOn(&run_input_tests.step);
    test_step.dependOn(&run_input_tests.step);

    const output_tests = b.addTest(.{ .root_module = output_mod, .use_llvm = true });
    const run_output_tests = b.addRunArtifact(output_tests);
    b.step("test-output", "Run output tests").dependOn(&run_output_tests.step);
    test_step.dependOn(&run_output_tests.step);
}

fn addExamples(b: *std.Build, options: Options, input_mod: *std.Build.Module, output_mod: *std.Build.Module) void {
    const examples = [_]struct {
        name: []const u8,
        dependency: *std.Build.Module,
        description: []const u8,
    }{
        .{ .name = "input", .dependency = input_mod, .description = "Build the /dev/input example" },
        .{ .name = "output", .dependency = output_mod, .description = "Build the stdout output example" },
    };

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = options.target,
            .optimize = options.optimize,
        });
        example_mod.addImport(example.name, example.dependency);

        const exe = b.addExecutable(.{
            .name = b.fmt("{s}-example", .{example.name}),
            .root_module = example_mod,
            .use_llvm = true,
        });
        const install = b.addInstallArtifact(exe, .{});
        b.step(b.fmt("example-{s}", .{example.name}), example.description).dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step(b.fmt("run-example-{s}", .{example.name}), b.fmt("Run the {s} example", .{example.name})).dependOn(&run.step);
    }
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
