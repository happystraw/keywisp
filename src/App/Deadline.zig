const std = @import("std");

const Deadline = @This();

timeout_ms: i32,
started_at: ?std.Io.Timestamp = null,

pub fn init(timeout_ms: i32) Deadline {
    std.debug.assert(timeout_ms >= 0);
    return .{ .timeout_ms = timeout_ms };
}

pub fn arm(self: *Deadline, now: std.Io.Timestamp) void {
    self.started_at = if (self.timeout_ms == 0) null else now;
}

pub fn disarm(self: *Deadline) void {
    self.started_at = null;
}

pub fn remainingMs(self: Deadline, now: std.Io.Timestamp) i32 {
    const started_at = self.started_at orelse return -1;
    const elapsed_ms = started_at.durationTo(now).toMilliseconds();
    const remaining_ms = @as(i64, self.timeout_ms) - elapsed_ms;
    if (remaining_ms <= 0) return 0;
    return @intCast(remaining_ms);
}

pub fn expired(self: Deadline, now: std.Io.Timestamp) bool {
    return self.started_at != null and self.remainingMs(now) == 0;
}
