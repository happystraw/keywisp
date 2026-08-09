const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol");
const output = @import("output");

pub const WaylandOptions = output.Wayland.Appearance;
pub const WriterOptions = output.Writer.Options;

const Output = @This();

backend: Backend,

pub const Options = union(enum) {
    wayland: WaylandOptions,
    writer: WriterOptions,
};

const Backend = union(enum) {
    wayland: output.Wayland,
    writer: output.Writer,
};

pub fn initWayland(gpa: Allocator, appearance: WaylandOptions) !Output {
    return .{ .backend = .{ .wayland = try .init(gpa, appearance) } };
}

pub fn initWriter(gpa: Allocator, writer: *std.Io.Writer, options: WriterOptions) !Output {
    return .{ .backend = .{ .writer = try .init(gpa, writer, options) } };
}

pub fn deinit(self: *Output) void {
    switch (self.backend) {
        .wayland => |*wayland| wayland.deinit(),
        .writer => |*writer| writer.deinit(),
    }
}

pub fn fd(self: *const Output) ?std.posix.fd_t {
    return switch (self.backend) {
        .wayland => |*wayland| wayland.fd(),
        .writer => null,
    };
}

pub fn onReadable(self: *Output) !void {
    switch (self.backend) {
        .wayland => |*wayland| try wayland.dispatch(),
        .writer => {},
    }
}

pub fn needsFlush(self: *const Output) bool {
    return switch (self.backend) {
        .wayland => |*wayland| wayland.needsFlush(),
        .writer => false,
    };
}

pub fn onWritable(self: *Output) !void {
    switch (self.backend) {
        .wayland => |*wayland| try wayland.flush(),
        .writer => {},
    }
}

pub fn handle(self: *Output, event: protocol.Event) !void {
    switch (self.backend) {
        .wayland => |*wayland| try wayland.handle(event),
        .writer => |*writer| try writer.handle(event),
    }
}

pub fn clear(self: *Output) !void {
    switch (self.backend) {
        .wayland => |*wayland| try wayland.clear(),
        .writer => |*writer| try writer.clear(),
    }
}
