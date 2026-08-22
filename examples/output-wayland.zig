const std = @import("std");
const posix = std.posix;

const output = @import("output");

pub fn main(init: std.process.Init) !void {
    var wayland = try output.Wayland.init(init.gpa, .{});
    defer wayland.deinit();

    try wayland.handle(.{ .keyboard = .{ .code = .left_control, .state = .pressed } });
    try wayland.handle(.{ .keyboard = .{ .code = .c, .state = .pressed } });
    try wayland.handle(.{ .pointer = .{ .button = .{ .code = .left, .state = .pressed } } });
    try wayland.handle(.{ .pointer = .{ .scroll = .up } });

    try init.io.sleep(.fromMilliseconds(500), .awake);
}
