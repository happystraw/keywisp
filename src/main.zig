const std = @import("std");
const log = std.log;
const Io = std.Io;

const App = @import("App.zig");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const io = init.io;

    const options: cli.RunOptions = switch (cli.parse(init.minimal.args)) {
        .run => |options| options,
        .help => {
            var buf: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writerStreaming(io, &buf);
            try writer.interface.writeAll(cli.USAGE);
            try writer.interface.flush();
            return;
        },
        .version => {
            var buf: [64]u8 = undefined;
            var writer = std.Io.File.stdout().writerStreaming(io, &buf);
            try writer.interface.writeAll(cli.VERSION ++ "\n");
            try writer.interface.flush();
            return;
        },
        .diagnostic => |diagnostic| {
            var buf: [256]u8 = undefined;
            var writer = std.Io.File.stderr().writerStreaming(io, &buf);
            try diagnostic.write(&writer.interface);
            try writer.interface.flush();
            return error.InvalidArguments;
        },
    };

    if (!hasReadableInputDevice(io, "/dev/input")) {
        log.err("Cannot access /dev/input. Ensure you are in the 'input' group:", .{});
        log.err("  sudo usermod -aG input $USER   (then log out and back in)", .{});
        return error.InputUnavailable;
    }

    switch (options.output) {
        .wayland => |appearance| {
            var app = try App.initWayland(gpa, io, options.app, appearance);
            defer app.deinit();
            app.run() catch |err| {
                // The compositor closed our layer surface; shut down cleanly.
                if (err == error.SurfaceClosed) return;
                return err;
            };
        },
        .writer => |writer_options| {
            ignoreBrokenPipe();
            var buffer: [4096]u8 = undefined;
            var writer = Io.File.stdout().writerStreaming(io, &buffer);

            var app = try App.initWriter(gpa, io, options.app, &writer.interface, writer_options);
            defer app.deinit();
            app.run() catch |err| {
                if (writer.err) |writer_error| {
                    // The downstream reader closed stdout; shut down cleanly.
                    if (writer_error == error.BrokenPipe) return;
                }
                return err;
            };
        },
    }
}

pub fn ignoreBrokenPipe() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &action, null);
}

pub fn hasReadableInputDevice(io: std.Io, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    return hasReadableEventFile(io, dir);
}

fn hasReadableEventFile(io: std.Io, dir: std.Io.Dir) bool {
    var iterator = dir.iterate();
    while (iterator.next(io) catch return false) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "event")) continue;
        const file = dir.openFile(io, entry.name, .{ .allow_directory = false }) catch continue;
        file.close(io);
        return true;
    }
    return false;
}

test {
    _ = App;
    _ = cli;
}
