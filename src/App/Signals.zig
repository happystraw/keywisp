const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;

const protocol = @import("protocol");

const Signals = @This();

fd: posix.fd_t,

pub fn init() !Signals {
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, .USR1);
    posix.sigaddset(&mask, .USR2);
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);
    return .{
        .fd = try posix.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK),
    };
}

pub fn deinit(self: *Signals) void {
    _ = self.read() catch null;
    _ = std.c.close(self.fd);
}

/// Standard signals are not ordered. If both are pending, prefer pausing.
pub fn read(self: *Signals) !?protocol.Event.Command {
    var pending: ?protocol.Event.Command = null;
    while (true) {
        var info: linux.signalfd_siginfo = undefined;
        const size = posix.read(self.fd, std.mem.asBytes(&info)) catch |err| switch (err) {
            error.WouldBlock => return pending,
            else => return err,
        };
        assert(size == @sizeOf(linux.signalfd_siginfo));
        if (info.signo == @intFromEnum(posix.SIG.USR1)) {
            pending = .{ .recording = .disabled };
        } else if (info.signo == @intFromEnum(posix.SIG.USR2) and pending == null) {
            pending = .{ .recording = .enabled };
        }
    }
}
