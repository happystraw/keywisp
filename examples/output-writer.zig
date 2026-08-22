const std = @import("std");

const output = @import("output");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    var output_writer = try output.Writer.init(init.gpa, &writer.interface, .{});
    defer output_writer.deinit();

    try output_writer.handle(.{ .keyboard = .{ .code = .left_control, .state = .pressed } });
    try output_writer.handle(.{ .keyboard = .{ .code = .c, .state = .pressed } });
    try output_writer.handle(.{ .pointer = .{ .button = .{ .code = .left, .state = .pressed } } });
    try output_writer.handle(.{ .pointer = .{ .scroll = .up } });
}
