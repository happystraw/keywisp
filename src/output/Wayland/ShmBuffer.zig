//! wl_shm buffer lifecycle: memfd → ftruncate → mmap → wl_shm_pool →
//! wl_buffer → cairo image surface/cairo_t. Ownership belongs to the Renderer;
//! deinit releases in reverse creation order; failure paths roll back with errdefer.

const std = @import("std");
const system = std.posix.system;

const project = @import("project");
const wl = @import("wayland").client.wl;

const Cairo = @import("cairo.zig").Cairo;

const ShmBuffer = @This();

buffer: *wl.Buffer,
surface: *Cairo.Surface,
cairo: *Cairo,
data: []align(std.heap.page_size_min) u8,
width: i32,
height: i32,

pub const InitError = std.posix.MemFdCreateError || std.posix.MMapError || ResizeError || Cairo.CreateError || error{BufferSizeOverflow};
pub fn init(shm: *wl.Shm, width: i32, height: i32, format: wl.Shm.Format) InitError!ShmBuffer {
    std.debug.assert(width > 0 and height > 0);
    const stride = std.math.mul(i32, width, 4) catch return error.BufferSizeOverflow;
    const size = std.math.mul(i32, stride, height) catch return error.BufferSizeOverflow;

    const fd = try std.posix.memfd_create(project.name, std.posix.MFD.CLOEXEC);
    defer _ = system.close(fd);

    try resize(fd, size);

    const data = try std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(data);

    const pool = try shm.createPool(fd, size);
    defer pool.destroy();

    const buffer = try pool.createBuffer(0, width, height, stride, format);
    errdefer buffer.destroy();

    const surface = try Cairo.Surface.image(data.ptr, .argb32, width, height, stride);
    errdefer surface.destroy();

    const cairo = try Cairo.create(surface);

    return .{
        .buffer = buffer,
        .surface = surface,
        .cairo = cairo,
        .data = data,
        .width = width,
        .height = height,
    };
}

const ResizeError = std.mem.Allocator.Error || error{ NoSpaceLeft, SharedMemoryResizeFailed };
fn resize(fd: std.posix.fd_t, size: i32) ResizeError!void {
    while (true) switch (std.posix.errno(system.ftruncate(fd, @intCast(size)))) {
        .SUCCESS => return,
        .INTR => {},
        .NOSPC => return error.NoSpaceLeft,
        .NOMEM => return error.OutOfMemory,
        .BADF => unreachable,
        else => return error.SharedMemoryResizeFailed,
    };
}

pub fn setListener(
    self: *ShmBuffer,
    comptime T: type,
    listener: *const fn (buffer: *wl.Buffer, event: wl.Buffer.Event, data: T) void,
    data: T,
) void {
    self.buffer.setListener(T, listener, data);
}

pub fn deinit(self: *ShmBuffer) void {
    self.cairo.destroy();
    self.surface.destroy();
    self.buffer.destroy();
    std.posix.munmap(self.data);
    self.* = undefined;
}
