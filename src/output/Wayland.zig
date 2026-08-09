const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol");

const Model = @import("Model.zig");
const Cairo = @import("Wayland/cairo.zig").Cairo;
const Client = @import("Wayland/Client.zig");
const Renderer = @import("Wayland/Renderer.zig");

const Wayland = @This();

pub const Appearance = @import("Wayland/Appearance.zig");

pub const InitError = Client.InitError || Model.InitError;

model: Model,
client: *Client,
renderer: Renderer,
flush_pending: bool,

pub fn init(gpa: Allocator, appearance: Appearance) InitError!Wayland {
    const client = try Client.create(gpa, appearance.position, appearance.margin);
    errdefer client.destroy();
    var model = try Model.init(gpa, .{ .keymap = .{ .serialized = client.serializedKeymap() } });
    errdefer model.deinit();
    return .{
        .model = model,
        .client = client,
        .renderer = .init(gpa, appearance.style, client.shm.?, &client.layer),
        .flush_pending = false,
    };
}

pub fn deinit(self: *Wayland) void {
    self.model.deinit();
    self.renderer.deinit();
    self.client.destroy();
}

pub fn fd(self: *const Wayland) c_int {
    return self.client.display.getFd();
}

pub fn dispatch(self: *Wayland) !void {
    const display = self.client.display;
    if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    self.renderer.reap();
    if (self.client.event_error) |err| return err;
    const changes = self.client.takeChanges();
    if (changes.keymap)
        try self.model.setSerializedKeymap(self.client.serializedKeymap());
    if (changes.render)
        try render(self);
    try self.flush();
}

pub fn handle(self: *Wayland, event: protocol.Event) !void {
    if (try self.model.handle(event) != .changed) return;
    try self.render();
    try self.flush();
}

pub fn clear(self: *Wayland) !void {
    self.model.clear();
    try self.render();
    try self.flush();
}

pub fn needsFlush(self: *const Wayland) bool {
    return self.flush_pending;
}

pub fn flush(self: *Wayland) !void {
    switch (self.client.display.flush()) {
        .SUCCESS => self.flush_pending = false,
        .AGAIN => self.flush_pending = true,
        else => return error.FlushFailed,
    }
}

fn render(self: *Wayland) !void {
    try self.renderer.render(.{
        .keys = self.model.view(),
        .scale = self.client.scale(),
        .subpixel = subpixelToCairo(self.client.subpixel()),
    });
}

fn subpixelToCairo(subpixel: anytype) Cairo.SubpixelOrder {
    return switch (subpixel) {
        .horizontal_rgb => .rgb,
        .horizontal_bgr => .bgr,
        .vertical_rgb => .vrgb,
        .vertical_bgr => .vbgr,
        else => .default,
    };
}
