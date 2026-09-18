const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

const protocol = @import("protocol");

const Model = @import("Model.zig");
const Cairo = @import("Wayland/cairo.zig").Cairo;
const Client = @import("Wayland/Client.zig");
const Renderer = @import("Wayland/Renderer.zig");

const Wayland = @This();

pub const Appearance = @import("Wayland/Appearance.zig");

model: Model,
client: *Client,
renderer: Renderer,
flush_pending: bool,
dirty: bool = false,

pub fn init(gpa: Allocator, appearance: Appearance) !Wayland {
    const client = try Client.create(gpa, appearance.position, appearance.margin);
    errdefer client.destroy();
    var model = try Model.init(gpa, .{
        .keymap = .{ .serialized = client.serializedKeymap() },
        .collapse_repetitions = appearance.collapse_repetitions,
    });
    errdefer model.deinit();
    return .{
        .model = model,
        .client = client,
        .renderer = try .init(
            gpa,
            appearance.style,
            client.shm.?,
            &client.layer,
            client.scale(),
            subpixelToCairo(client.subpixel()),
        ),
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
    try self.client.dispatch();
    const changes = self.client.state.takeChanges();
    if (changes.keymap)
        try self.model.setSerializedKeymap(self.client.serializedKeymap());
    if (changes.render) {
        // Actual configure/output changes invalidate the old drawing schedule.
        self.client.layer.cancelFrame();
        self.dirty = true;
    }
    // Either callback completion or buffer release may make the latest view drawable.
    try self.tryRender();
    try self.flush();
}

pub fn handle(self: *Wayland, event: protocol.Event) !void {
    if (try self.model.handle(event) != .changed) return;
    self.dirty = true;
    try self.tryRender();
    try self.flush();
}

pub fn clear(self: *Wayland) !void {
    self.model.clear();
    self.client.layer.cancelFrame();
    self.dirty = true;
    try self.tryRender();
    try self.flush();
}

pub fn needsFlush(self: *const Wayland) bool {
    return self.flush_pending;
}

pub const FlushError = error{WaylandFlushFailed};
pub fn flush(self: *Wayland) FlushError!void {
    switch (self.client.display.flush()) {
        .SUCCESS => self.flush_pending = false,
        .AGAIN => self.flush_pending = true,
        else => return error.WaylandFlushFailed,
    }
}

fn tryRender(self: *Wayland) !void {
    if (!self.dirty or self.client.layer.frame_callback != null or !self.renderer.canRender()) return;
    const result = try self.renderer.render(.{
        .keys = self.model.view(),
        .scale = self.client.scale(),
        .subpixel = subpixelToCairo(self.client.subpixel()),
    });
    if (result == .submitted) self.dirty = false;
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

test {
    _ = Client;
    _ = Renderer;
}

test "pending frame callbacks coalesce inputs without borrowing an old model view" {
    var client: Client = undefined;
    // Never dispatched/destroyed: this sentinel only marks an outstanding callback.
    var callback_token: u8 = 0;
    client.layer.frame_callback = @ptrCast(&callback_token);
    var wayland: Wayland = undefined;
    wayland.client = &client;
    wayland.dirty = true;
    try wayland.tryRender();
    try std.testing.expect(wayland.dirty);
    wayland.dirty = false;
    try wayland.tryRender();
    try std.testing.expect(!wayland.dirty);
}
