const std = @import("std");
const Allocator = std.mem.Allocator;
const system = std.posix.system;

const project = @import("project");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;

const LayerSurface = @import("LayerSurface.zig");
const Outputs = @import("Outputs.zig");
const Position = @import("Appearance.zig").Position;

const Client = @This();

pub const EventError = error{ UnsupportedInterfaces, OutOfMemory, KeymapFailed, SurfaceClosed };
pub const InitError = Allocator.Error || EventError || error{
    ConnectFailed,
    GetRegistryFailed,
    MissingInterfaces,
    MissingKeyboard,
    MissingKeymap,
    RoundtripFailed,
    LayerSurfaceFailed,
};

pub const Changes = struct { keymap: bool = false, render: bool = false };

gpa: Allocator,
display: *wl.Display,
registry: *wl.Registry,
event_error: ?EventError = null,
pending: Changes = .{},

compositor: ?*wl.Compositor = null,
shm: ?*wl.Shm = null,
layer_shell: ?*zwlr.LayerShellV1 = null,

seat: ?*wl.Seat = null,
keyboard: ?*wl.Keyboard = null,
keymap: ?[:0]u8 = null,

outputs: Outputs,

layer: LayerSurface,

pub fn create(gpa: Allocator, position: Position, margin: i32) InitError!*Client {
    const self = try gpa.create(Client);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .display = undefined,
        .registry = undefined,
        .outputs = .init(gpa),
        .layer = undefined,
    };
    errdefer self.outputs.deinit();
    errdefer if (self.keymap) |keymap| gpa.free(keymap);

    self.display = wl.Display.connect(null) catch return error.ConnectFailed;
    errdefer self.display.disconnect();

    self.registry = self.display.getRegistry() catch return error.GetRegistryFailed;
    errdefer self.registry.destroy();
    _ = self.registry.setListener(*Client, listeners.registry, self);
    if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    if (self.event_error) |err| return err;
    if (self.compositor == null or self.shm == null or self.seat == null or self.layer_shell == null)
        return error.MissingInterfaces;

    errdefer self.releaseSeat();
    _ = self.seat.?.setListener(*Client, listeners.seat, self);
    if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    if (self.keyboard == null) return error.MissingKeyboard;
    if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    if (self.event_error) |err| return err;
    if (self.keymap == null) return error.MissingKeymap;

    self.layer = LayerSurface.init(self.compositor.?, self.layer_shell.?, .{
        .anchor = position.anchor(),
        .margin = margin,
        .namespace = project.name ++ "-keys",
    }) catch return error.LayerSurfaceFailed;
    errdefer self.layer.deinit();

    _ = self.layer.layer_surface.setListener(*Client, listeners.layerSurface, self);
    _ = self.layer.surface.setListener(*Client, listeners.surface, self);
    if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    self.pending = .{};
    return self;
}

pub fn destroy(self: *Client) void {
    self.layer.deinit();
    self.releaseSeat();
    if (self.keymap) |keymap| self.gpa.free(keymap);
    self.outputs.deinit();
    self.registry.destroy();
    self.display.disconnect();
    self.gpa.destroy(self);
}

pub fn scale(self: *const Client) i32 {
    return if (self.outputs.current) |o| o.scale else 1;
}

pub fn subpixel(self: *const Client) wl.Output.Subpixel {
    return if (self.outputs.current) |o| o.subpixel else .unknown;
}

pub fn serializedKeymap(self: *const Client) [:0]const u8 {
    return self.keymap.?;
}

pub fn takeChanges(self: *Client) Changes {
    const changes = self.pending;
    self.pending = .{};
    return changes;
}

fn fail(self: *Client, err: EventError) void {
    if (err == error.SurfaceClosed) {
        self.event_error = err;
        return;
    }
    if (self.event_error) |current| {
        if (current != error.KeymapFailed) return;
    }
    self.event_error = err;
}

fn releaseSeat(self: *Client) void {
    self.releaseKeyboard();
    if (self.seat) |seat| {
        if (seat.getVersion() >= wl.Seat.release_since_version)
            seat.release()
        else
            seat.destroy();
        self.seat = null;
    }
}

fn releaseKeyboard(self: *Client) void {
    if (self.keyboard) |keyboard| {
        if (keyboard.getVersion() >= wl.Keyboard.release_since_version)
            keyboard.release()
        else
            keyboard.destroy();
        self.keyboard = null;
    }
}

const listeners = struct {
    fn registry(proxy: *wl.Registry, event: wl.Registry.Event, client: *Client) void {
        switch (event) {
            .global => |ev| {
                if (isInterface(ev.interface, wl.Compositor)) {
                    if (client.compositor != null) return;
                    const version = negotiatedVersion(wl.Compositor, ev.version, 4) orelse {
                        client.fail(error.UnsupportedInterfaces);
                        return;
                    };
                    client.compositor = proxy.bind(ev.name, wl.Compositor, version) catch null;
                } else if (isInterface(ev.interface, wl.Shm)) {
                    if (client.shm != null) return;
                    const version = negotiatedVersion(wl.Shm, ev.version, 1) orelse return;
                    client.shm = proxy.bind(ev.name, wl.Shm, version) catch null;
                } else if (isInterface(ev.interface, wl.Seat)) {
                    const version = negotiatedVersion(wl.Seat, ev.version, 1) orelse return;
                    if (client.seat == null) client.seat = proxy.bind(ev.name, wl.Seat, version) catch null;
                } else if (isInterface(ev.interface, zwlr.LayerShellV1)) {
                    if (client.layer_shell != null) return;
                    const version = negotiatedVersion(zwlr.LayerShellV1, ev.version, 1) orelse return;
                    client.layer_shell = proxy.bind(ev.name, zwlr.LayerShellV1, version) catch null;
                } else if (isInterface(ev.interface, wl.Output)) {
                    const version = negotiatedVersion(wl.Output, ev.version, 2) orelse return;
                    const output_proxy = proxy.bind(ev.name, wl.Output, version) catch return;
                    _ = client.outputs.add(ev.name, output_proxy) catch {
                        Outputs.release(output_proxy);
                        client.fail(error.OutOfMemory);
                        return;
                    };
                    _ = output_proxy.setListener(*Client, listeners.output, client);
                }
            },
            .global_remove => |ev| {
                if (client.outputs.remove(ev.name)) client.pending.render = true;
            },
        }
    }

    fn isInterface(name: [*:0]const u8, comptime T: type) bool {
        return std.mem.orderZ(u8, name, T.interface.name) == .eq;
    }

    fn negotiatedVersion(comptime T: type, advertised: u32, minimum: u32) ?u32 {
        if (advertised < minimum) return null;
        return @min(advertised, @as(u32, @intCast(T.interface.version)));
    }

    fn seat(proxy: *wl.Seat, event: wl.Seat.Event, client: *Client) void {
        switch (event) {
            .capabilities => |ev| {
                if (!ev.capabilities.keyboard) {
                    client.releaseKeyboard();
                    return;
                }
                if (client.keyboard != null) return;
                const keyboard_proxy = proxy.getKeyboard() catch {
                    client.fail(error.KeymapFailed);
                    return;
                };
                client.keyboard = keyboard_proxy;
                _ = keyboard_proxy.setListener(*Client, listeners.keyboard, client);
            },
            .name => {},
        }
    }

    fn keyboard(proxy: *wl.Keyboard, event: wl.Keyboard.Event, client: *Client) void {
        _ = proxy;
        switch (event) {
            .keymap => |ev| updateKeymap(client, ev.format, ev.fd, ev.size),
            .enter, .leave, .key, .modifiers, .repeat_info => {},
        }
    }

    fn updateKeymap(client: *Client, format: wl.Keyboard.KeymapFormat, fd: std.posix.fd_t, size: u32) void {
        defer _ = system.close(fd);
        if (format != .xkb_v1 or size == 0) {
            client.fail(error.KeymapFailed);
            return;
        }

        const mapped = std.posix.mmap(
            null,
            @intCast(size),
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch {
            client.fail(error.KeymapFailed);
            return;
        };
        defer std.posix.munmap(mapped);

        const text = client.gpa.dupeSentinel(u8, mapped[0 .. mapped.len - 1], 0) catch {
            client.fail(error.KeymapFailed);
            return;
        };
        if (client.keymap) |old| client.gpa.free(old);
        client.keymap = text;
        if (client.event_error) |err| {
            if (err == error.KeymapFailed) client.event_error = null;
        }
        client.pending.keymap = true;
    }

    fn surface(proxy: *wl.Surface, event: wl.Surface.Event, client: *Client) void {
        _ = proxy;
        switch (event) {
            .enter => |ev| if (ev.output) |output_proxy| {
                if (client.outputs.setCurrent(output_proxy)) client.pending.render = true;
            },
            .leave => |ev| if (ev.output) |output_proxy| {
                if (client.outputs.clearCurrent(output_proxy)) client.pending.render = true;
            },
        }
    }

    fn layerSurface(proxy: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, client: *Client) void {
        switch (event) {
            .configure => |ev| {
                if (ev.width != client.layer.width or ev.height != client.layer.height) {
                    client.layer.width = ev.width;
                    client.layer.height = ev.height;
                    client.pending.render = true;
                }
                proxy.ackConfigure(ev.serial);
            },
            .closed => client.fail(error.SurfaceClosed),
        }
    }

    fn output(proxy: *wl.Output, event: wl.Output.Event, client: *Client) void {
        const tracked = client.outputs.find(proxy) orelse return;
        var changed = false;
        switch (event) {
            .geometry => |ev| {
                changed = tracked.subpixel != ev.subpixel;
                tracked.subpixel = ev.subpixel;
            },
            .mode, .done => {},
            .scale => |ev| {
                changed = tracked.scale != ev.factor;
                tracked.scale = ev.factor;
            },
        }
        if (changed and client.outputs.current == tracked) client.pending.render = true;
    }
};
