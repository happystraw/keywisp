const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const system = std.posix.system;

const project = @import("project");
const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;

const LayerSurface = @import("LayerSurface.zig");
const Outputs = @import("Outputs.zig");
const Position = @import("Appearance.zig").Position;

const Client = @This();

pub const State = struct {
    pub const Changes = struct { keymap: bool = false, render: bool = false };
    pub const Error = Allocator.Error || error{ UnsupportedCompositorVersion, LayerSurfaceClosed };

    err: ?Error = null,
    changes: Changes = .{},

    fn fail(self: *State, err: Error) void {
        if (self.err == null) self.err = err; // first wins
    }

    fn takeError(self: *State) ?Error {
        defer self.err = null;
        return self.err;
    }

    pub fn takeChanges(self: *State) Changes {
        defer self.changes = .{};
        return self.changes;
    }
};

gpa: Allocator,
display: *wl.Display,
registry: *wl.Registry,
state: State = .{},

compositor: ?*wl.Compositor = null,
shm: ?*wl.Shm = null,
layer_shell: ?*zwlr.LayerShellV1 = null,

seat: ?*wl.Seat = null,
keyboard: ?*wl.Keyboard = null,
keymap: ?[:0]u8 = null,

outputs: Outputs,

layer: LayerSurface,

pub const InitError = RoundtripError || error{
    WaylandConnectFailed,
    CompositorNotAdvertised,
    ShmNotAdvertised,
    SeatNotAdvertised,
    LayerShellNotAdvertised,
    KeyboardCapabilityUnavailable,
    KeymapUnavailable,
};

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
    self.display = wl.Display.connect(null) catch return error.WaylandConnectFailed;
    errdefer self.display.disconnect();
    errdefer self.outputs.deinit();
    errdefer if (self.keymap) |keymap| gpa.free(keymap);

    self.registry = try self.display.getRegistry();
    errdefer self.registry.destroy();
    _ = self.registry.setListener(*Client, listeners.registry, self);
    try self.roundtrip();

    if (self.compositor == null) return error.CompositorNotAdvertised;
    if (self.shm == null) return error.ShmNotAdvertised;
    if (self.seat == null) return error.SeatNotAdvertised;
    if (self.layer_shell == null) return error.LayerShellNotAdvertised;

    errdefer self.releaseSeat();
    _ = self.seat.?.setListener(*Client, listeners.seat, self);
    try self.roundtrip();
    if (self.keyboard == null) return error.KeyboardCapabilityUnavailable;
    try self.roundtrip();
    if (self.keymap == null) return error.KeymapUnavailable;

    self.layer = try LayerSurface.init(self.compositor.?, self.layer_shell.?, .{
        .anchor = position.anchor(),
        .margin = margin,
        .namespace = project.name ++ "-keys",
    });
    errdefer self.layer.deinit();

    _ = self.layer.layer_surface.setListener(*Client, listeners.layerSurface, self);
    _ = self.layer.surface.setListener(*Client, listeners.surface, self);
    try self.roundtrip();
    self.state.changes = .{};
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

pub const DispatchError = Allocator.Error || error{ LayerSurfaceClosed, WaylandDispatchFailed };

pub fn dispatch(self: *Client) DispatchError!void {
    if (self.display.dispatch() != .SUCCESS) return error.WaylandDispatchFailed;
    const err = self.state.takeError() orelse return;
    switch (err) {
        error.UnsupportedCompositorVersion => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
        error.LayerSurfaceClosed => return error.LayerSurfaceClosed,
    }
}

const RoundtripError = State.Error || error{WaylandRoundtripFailed};

fn roundtrip(self: *Client) RoundtripError!void {
    if (self.display.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
    if (self.state.takeError()) |err| return err;
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
                        client.state.fail(error.UnsupportedCompositorVersion);
                        return;
                    };
                    client.compositor = proxy.bind(ev.name, wl.Compositor, version) catch |err| {
                        client.state.fail(err);
                        return;
                    };
                } else if (isInterface(ev.interface, wl.Shm)) {
                    if (client.shm != null) return;
                    const version = negotiatedVersion(wl.Shm, ev.version, 1) orelse return;
                    client.shm = proxy.bind(ev.name, wl.Shm, version) catch |err| {
                        client.state.fail(err);
                        return;
                    };
                } else if (isInterface(ev.interface, wl.Seat)) {
                    const version = negotiatedVersion(wl.Seat, ev.version, 1) orelse return;
                    if (client.seat == null) {
                        client.seat = proxy.bind(ev.name, wl.Seat, version) catch |err| {
                            client.state.fail(err);
                            return;
                        };
                    }
                } else if (isInterface(ev.interface, zwlr.LayerShellV1)) {
                    if (client.layer_shell != null) return;
                    const version = negotiatedVersion(zwlr.LayerShellV1, ev.version, 1) orelse return;
                    client.layer_shell = proxy.bind(ev.name, zwlr.LayerShellV1, version) catch |err| {
                        client.state.fail(err);
                        return;
                    };
                } else if (isInterface(ev.interface, wl.Output)) {
                    const version = negotiatedVersion(wl.Output, ev.version, 2) orelse return;
                    const output_proxy = proxy.bind(ev.name, wl.Output, version) catch |err| {
                        client.state.fail(err);
                        return;
                    };
                    _ = client.outputs.add(ev.name, output_proxy) catch |err| {
                        Outputs.release(output_proxy);
                        client.state.fail(err);
                        return;
                    };
                    _ = output_proxy.setListener(*Client, listeners.output, client);
                }
            },
            .global_remove => |ev| {
                if (client.outputs.remove(ev.name)) client.state.changes.render = true;
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
                const keyboard_proxy = proxy.getKeyboard() catch |err| {
                    client.state.fail(err);
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
            else => {},
        }
    }

    fn updateKeymap(client: *Client, format: wl.Keyboard.KeymapFormat, fd: std.posix.fd_t, size: u32) void {
        defer _ = system.close(fd);
        if (format != .xkb_v1) {
            log.warn("Failed to update keymap: unsupported format {d}.", .{@intFromEnum(format)});
            return;
        }
        if (size == 0) {
            log.warn("Failed to update keymap: empty keymap.", .{});
            return;
        }

        const mapped = std.posix.mmap(
            null,
            @intCast(size),
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch |err| {
            log.warn("Failed to map keymap: {s}.", .{@errorName(err)});
            return;
        };
        defer std.posix.munmap(mapped);

        const text = client.gpa.dupeSentinel(u8, mapped[0 .. mapped.len - 1], 0) catch |err| {
            log.warn("Failed to copy keymap: {s}.", .{@errorName(err)});
            return;
        };
        if (client.keymap) |old| client.gpa.free(old);
        client.keymap = text;
        client.state.changes.keymap = true;
    }

    fn surface(proxy: *wl.Surface, event: wl.Surface.Event, client: *Client) void {
        _ = proxy;
        switch (event) {
            .enter => |ev| if (ev.output) |output_proxy| {
                if (client.outputs.setCurrent(output_proxy)) client.state.changes.render = true;
            },
            .leave => |ev| if (ev.output) |output_proxy| {
                if (client.outputs.clearCurrent(output_proxy)) client.state.changes.render = true;
            },
        }
    }

    fn layerSurface(proxy: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, client: *Client) void {
        switch (event) {
            .configure => |ev| {
                if (ev.width != client.layer.width or ev.height != client.layer.height) {
                    client.layer.width = ev.width;
                    client.layer.height = ev.height;
                    client.state.changes.render = true;
                }
                proxy.ackConfigure(ev.serial);
            },
            .closed => client.state.fail(error.LayerSurfaceClosed),
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
        if (changed and client.outputs.current == tracked) client.state.changes.render = true;
    }
};
