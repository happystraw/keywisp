const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol");

const Model = @import("Model.zig");
const format = @import("format.zig");

const Writer = @This();

writer: *std.Io.Writer,
model: Model,

options: Options,

pub const Options = struct {
    history: usize = 1,
    emit_clear: bool = false,
};

pub const InitError = Model.InitError;
pub fn init(gpa: Allocator, writer: *std.Io.Writer, options: Options) InitError!Writer {
    return .{
        .writer = writer,
        .model = try .init(gpa, .{ .capacity = options.history }),
        .options = options,
    };
}

pub fn deinit(self: *Writer) void {
    self.model.deinit();
}

pub const Error = Allocator.Error || std.Io.Writer.Error || format.Error;
pub fn handle(self: *Writer, event: protocol.Event) Error!void {
    try self.emitUpdate(try self.model.handle(event));
}

fn emitUpdate(self: *Writer, change: Model.Change) Error!void {
    if (change != .changed) return;

    var entries = self.model.view().iterator();
    var first = true;
    while (entries.next()) |entry| {
        if (!first) try self.writer.writeAll(" ");
        first = false;
        var buffer: format.Buffer = undefined;
        const text = try format.entry(entry, &buffer, .{ .show_repetition = false });
        try self.writer.writeAll(text);
    }
    try self.writer.writeAll("\n");
    try self.writer.flush();
}

pub fn clear(self: *Writer) Error!void {
    self.model.clear();
    if (!self.options.emit_clear) return;
    try self.writer.writeAll("\n");
    try self.writer.flush();
}
