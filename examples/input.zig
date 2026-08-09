const std = @import("std");
const posix = std.posix;

const input = @import("input");

pub fn main() !void {
    const device = try input.LibInput.new(.{});
    defer device.release();

    var pollfd = [_]posix.pollfd{.{ .fd = device.fd(), .events = posix.POLL.IN, .revents = 0 }};
    while (true) {
        _ = try posix.poll(&pollfd, -1);
        try device.dispatch();
        while (device.next()) |event| switch (event) {
            .keyboard => |keyboard| std.debug.print("keyboard code={s}({d}) state={s}\n", .{
                enumName(keyboard.code),
                @intFromEnum(keyboard.code),
                @tagName(keyboard.state),
            }),
            .pointer => |pointer| switch (pointer) {
                .button => |button| std.debug.print("pointer button={s}({d}) state={s}\n", .{
                    enumName(button.code),
                    @intFromEnum(button.code),
                    @tagName(button.state),
                }),
                .scroll => |scroll| std.debug.print("pointer scroll={s}\n", .{@tagName(scroll)}),
            },
        };
    }
}

fn enumName(value: anytype) []const u8 {
    return std.enums.tagName(@TypeOf(value), value) orelse "unknown";
}
