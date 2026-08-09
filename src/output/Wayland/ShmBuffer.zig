//! wl_shm buffer lifecycle: memfd → ftruncate → mmap → wl_shm_pool →
//! wl_buffer → cairo image surface/cairo_t. Ownership belongs to the Renderer;
//! deinit releases in reverse creation order; failure paths roll back with errdefer.

const std = @import("std");
const system = std.posix.system;

const project = @import("project");
const wl = @import("wayland").client.wl;

const Cairo = @import("cairo.zig").Cairo;

const ShmBuffer = @This();

pub const InitError = error{
    ShmFileFailed,
    TruncateFailed,
    MmapFailed,
    PoolFailed,
    BufferFailed,
    CairoFailed,
};

buffer: *wl.Buffer,
surface: *Cairo.Surface,
cairo: *Cairo,
data: []align(std.heap.page_size_min) u8,
width: i32,
height: i32,

pub fn init(shm: *wl.Shm, width: i32, height: i32, format: wl.Shm.Format) InitError!ShmBuffer {
    std.debug.assert(width > 0 and height > 0);
    const stride = std.math.mul(i32, width, 4) catch return error.BufferFailed;
    const size = std.math.mul(i32, stride, height) catch return error.BufferFailed;

    const fd = std.posix.memfd_create(project.name, std.posix.MFD.CLOEXEC) catch return error.ShmFileFailed;
    defer _ = system.close(fd);

    if (std.posix.errno(system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.TruncateFailed;

    const data = std.posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch return error.MmapFailed;
    errdefer std.posix.munmap(data);

    const pool = shm.createPool(fd, size) catch return error.PoolFailed;
    defer pool.destroy();

    const buffer = pool.createBuffer(0, width, height, stride, format) catch return error.BufferFailed;
    errdefer buffer.destroy();

    const surface = Cairo.Surface.image(data.ptr, .argb32, width, height, stride) catch return error.CairoFailed;
    errdefer surface.destroy();

    const cairo = Cairo.create(surface) catch return error.CairoFailed;

    return .{
        .buffer = buffer,
        .surface = surface,
        .cairo = cairo,
        .data = data,
        .width = width,
        .height = height,
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
