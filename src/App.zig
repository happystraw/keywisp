const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

const protocol = @import("protocol");
const LibInput = @import("input").LibInput;

const Deadline = @import("App/Deadline.zig");
const Output = @import("App/Output.zig");
const Poller = @import("App/Poller.zig");
const Signals = @import("App/Signals.zig");

const App = @This();

pub const Options = struct {
    signal_control: bool = false,
    timeout_ms: i32 = 1500,
    pointer: Pointer = .{ .buttons = false, .scroll = false },

    pub const Pointer = struct { buttons: bool, scroll: bool };
};

input: *LibInput,
output: Output,
signals: ?Signals,
options: Options,
deadline: Deadline,

io: std.Io,

pub fn initWayland(
    gpa: Allocator,
    io: std.Io,
    options: Options,
    appearance: Output.WaylandOptions,
) !App {
    var signals: ?Signals = if (options.signal_control) try Signals.init() else null;
    errdefer if (signals) |*value| value.deinit();

    var output = try Output.initWayland(gpa, appearance);
    errdefer output.deinit();

    const device = try LibInput.new(.{});
    errdefer device.release();

    return .{
        .options = options,
        .input = device,
        .output = output,
        .signals = signals,
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
    var signals: ?Signals = if (options.signal_control) try Signals.init() else null;
    errdefer if (signals) |*value| value.deinit();

    var output = try Output.initWriter(gpa, writer, writer_options);
    errdefer output.deinit();

    const device = try LibInput.new(.{});
    errdefer device.release();

    return .{
        .options = options,
        .input = device,
        .output = output,
        .signals = signals,
        .deadline = .init(options.timeout_ms),
        .io = io,
    };
}

pub fn deinit(self: *App) void {
    self.output.deinit();
    self.input.release();
    if (self.signals) |*signals| signals.deinit();
}

pub fn run(self: *App) !void {
    var poller = Poller.init(self.input.fd(), self.output.fd(), if (self.signals) |value| value.fd else null);

    while (true) {
        poller.setOutputWritable(self.output.needsFlush());
        const ready = try poller.wait(self.deadline.remainingMs(self.now()));

        if (ready.signals) if (try self.signals.?.read()) |command|
            try self.handleCommand(command);
        if (ready.input) try self.processInput();
        if (ready.output_readable) try self.output.onReadable();
        if (ready.output_writable) try self.output.onWritable();

        if (self.deadline.expired(self.now())) {
            try self.output.clear();
            self.deadline.disarm();
        }
    }
}

fn handleCommand(self: *App, command: protocol.Event.Command) !void {
    switch (command) {
        .recording => |state| {
            if (self.output.recordingState() == state) return;
            // Consume queued input before allowing new history or output.
            if (state == .enabled) try self.processInput();
        },
    }
    try self.output.handle(.{ .command = command });
    self.deadline.disarm();
    log.debug("recording {s}", .{@tagName(self.output.recordingState())});
}

fn processInput(self: *App) !void {
    try self.input.dispatch();
    while (self.input.next()) |event| {
        if (!self.accepts(event)) continue;
        try self.output.handle(event);
        if (self.output.recordingState() == .enabled and shouldResetTimeout(event)) self.deadline.arm(self.now());
    }
}

fn accepts(self: *const App, event: protocol.Event) bool {
    return switch (event) {
        .command => false,
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

fn shouldResetTimeout(event: protocol.Event) bool {
    return switch (event) {
        .command => false,
        .keyboard => |keyboard| keyboard.state == .pressed,
        .pointer => |pointer| switch (pointer) {
            .button => |button| button.state == .pressed,
            .scroll => true,
        },
    };
}
