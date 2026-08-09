const std = @import("std");
const posix = std.posix;

const Poller = @This();

pollfds: [2]posix.pollfd,
count: usize,

pub const Ready = struct {
    input: bool = false,
    output_readable: bool = false,
    output_writable: bool = false,
};

pub const WaitError = posix.PollError || error{InvalidFd};

pub fn init(input_fd: posix.fd_t, output_fd: ?posix.fd_t) Poller {
    var self: Poller = .{
        .pollfds = undefined,
        .count = 1,
    };
    self.pollfds[0] = pollfd(input_fd);
    if (output_fd) |fd| {
        self.pollfds[1] = pollfd(fd);
        self.count = 2;
    }
    return self;
}

pub fn setOutputWritable(self: *Poller, enabled: bool) void {
    if (self.count != 2) return;
    self.pollfds[1].events = @as(i16, posix.POLL.IN) |
        if (enabled) @as(i16, posix.POLL.OUT) else 0;
}

pub fn wait(self: *Poller, timeout_ms: i32) WaitError!Ready {
    std.debug.assert(timeout_ms >= -1);
    _ = try posix.poll(self.pollfds[0..self.count], timeout_ms);
    for (self.pollfds[0..self.count]) |fd| {
        if ((fd.revents & posix.POLL.NVAL) != 0) return error.InvalidFd;
    }

    return .{
        .input = isReadable(self.pollfds[0].revents),
        .output_readable = self.count == 2 and isReadable(self.pollfds[1].revents),
        .output_writable = self.count == 2 and isWritable(self.pollfds[1].revents),
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
