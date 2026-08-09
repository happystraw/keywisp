const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol");
const LibInput = @import("input").LibInput;

const Deadline = @import("App/Deadline.zig");
const Output = @import("App/Output.zig");
const Poller = @import("App/Poller.zig");

const App = @This();

pub const Options = struct {
    timeout_ms: i32 = 1500,
    pointer: Pointer = .{ .buttons = false, .scroll = false },

    pub const Pointer = struct { buttons: bool, scroll: bool };
};

input: *LibInput,
output: Output,
options: Options,
deadline: Deadline,

io: std.Io,

pub fn initWayland(
    gpa: Allocator,
    io: std.Io,
    options: Options,
    appearance: Output.WaylandOptions,
) !App {
    var output = try Output.initWayland(gpa, appearance);
    errdefer output.deinit();

    const device = try LibInput.new(.{});
    errdefer device.release();

    return .{
        .options = options,
        .input = device,
        .output = output,
        .deadline = .init(options.timeout_ms),
        .io = io,
    };
}

pub fn initWriter(
    gpa: Allocator,
    io: std.Io,
    options: Options,
    writer: *std.Io.Writer,
    writer_options: Output.WriterOptions,
) !App {
    var output = try Output.initWriter(gpa, writer, writer_options);
    errdefer output.deinit();

    const device = try LibInput.new(.{});
    errdefer device.release();

    return .{
        .options = options,
        .input = device,
        .output = output,
        .deadline = .init(options.timeout_ms),
        .io = io,
    };
}

pub fn deinit(self: *App) void {
    self.output.deinit();
    self.input.release();
}

pub fn run(self: *App) !void {
    var poller = Poller.init(self.input.fd(), self.output.fd());

    while (true) {
        poller.setOutputWritable(self.output.needsFlush());
        const ready = try poller.wait(self.deadline.remainingMs(self.now()));

        if (ready.input) try self.processInput();
        if (ready.output_readable) try self.output.onReadable();
        if (ready.output_writable) try self.output.onWritable();

        if (self.deadline.expired(self.now())) {
            try self.output.clear();
            self.deadline.disarm();
        }
    }
}

fn processInput(self: *App) !void {
    try self.input.dispatch();
    while (self.input.next()) |event| {
        if (!self.accepts(event)) continue;
        try self.output.handle(event);
        if (refreshesTimeout(event)) self.deadline.arm(self.now());
    }
}

fn accepts(self: *const App, event: protocol.Event) bool {
    return switch (event) {
        .keyboard => true,
        .pointer => |pointer| switch (pointer) {
            .button => self.options.pointer.buttons,
            .scroll => self.options.pointer.scroll,
        },
    };
}

fn now(self: *const App) std.Io.Timestamp {
    return .now(self.io, .awake);
}

fn refreshesTimeout(event: protocol.Event) bool {
    return switch (event) {
        .keyboard => |keyboard| keyboard.state == .pressed,
        .pointer => |pointer| switch (pointer) {
            .button => |button| button.state == .pressed,
            .scroll => true,
        },
    };
}
