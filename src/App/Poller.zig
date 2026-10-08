const std = @import("std");
const posix = std.posix;

const Poller = @This();

pollfds: [3]posix.pollfd,

pub const Ready = struct {
    signals: bool = false,
    input: bool = false,
    output_readable: bool = false,
    output_writable: bool = false,
};

pub fn init(input_fd: posix.fd_t, output_fd: ?posix.fd_t, signals_fd: ?posix.fd_t) Poller {
    return .{
        .pollfds = .{
            pollfd(input_fd),
            pollfd(signals_fd orelse -1),
            pollfd(output_fd orelse -1),
        },
    };
}

pub fn setOutputWritable(self: *Poller, enabled: bool) void {
    self.pollfds[2].events = @as(i16, posix.POLL.IN) |
        if (enabled) @as(i16, posix.POLL.OUT) else 0;
}

pub const WaitError = posix.PollError || error{ InvalidInputFd, InvalidOutputFd, InvalidSignalsFd };
pub fn wait(self: *Poller, timeout_ms: i32) WaitError!Ready {
    std.debug.assert(timeout_ms >= -1);
    _ = try posix.poll(&self.pollfds, timeout_ms);
    for (self.pollfds, 0..) |fd, index| {
        if ((fd.revents & posix.POLL.NVAL) != 0)
            return switch (index) {
                0 => error.InvalidInputFd,
                1 => error.InvalidSignalsFd,
                else => error.InvalidOutputFd,
            };
    }

    return .{
        .input = isReadable(self.pollfds[0].revents),
        .signals = isReadable(self.pollfds[1].revents),
        .output_readable = isReadable(self.pollfds[2].revents),
        .output_writable = isWritable(self.pollfds[2].revents),
    };
}

fn pollfd(fd: posix.fd_t) posix.pollfd {
    return .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
}

fn isReadable(revents: i16) bool {
    return (revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP)) != 0;
}

fn isWritable(revents: i16) bool {
    return (revents & posix.POLL.OUT) != 0;
}
