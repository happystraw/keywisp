const std = @import("std");
const protocol = @import("protocol");

pub const LibInput = opaque {
    const Interface = extern struct {
        open_restricted: *const fn (path: [*:0]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int,
        close_restricted: *const fn (fd: std.posix.fd_t, user_data: ?*anyopaque) callconv(.c) void,
    };

    const Event = opaque {
        const Keyboard = opaque {
            const KeyState = enum(c_int) { released = 0, pressed = 1, _ };
            const getKey = ffi.libinput.libinput_event_keyboard_get_key;
            const getKeyState = ffi.libinput.libinput_event_keyboard_get_key_state;
        };

        const Pointer = opaque {
            const ButtonState = enum(c_int) { released = 0, pressed = 1, _ };
            const Axis = enum(c_int) { vertical = 0, horizontal = 1, _ };
            const getButton = ffi.libinput.libinput_event_pointer_get_button;
            const getButtonState = ffi.libinput.libinput_event_pointer_get_button_state;
            const hasAxis = ffi.libinput.libinput_event_pointer_has_axis;
            const getScrollValue = ffi.libinput.libinput_event_pointer_get_scroll_value;

            fn getScroll(self: *Pointer) ?protocol.Event.Pointer.Scroll {
                const vertical = if (self.hasAxis(.vertical) != 0) self.getScrollValue(.vertical) else 0;
                const horizontal = if (self.hasAxis(.horizontal) != 0) self.getScrollValue(.horizontal) else 0;
                if (vertical == 0 and horizontal == 0) return null;
                if (@abs(vertical) >= @abs(horizontal)) return if (vertical < 0) .up else .down;
                return if (horizontal < 0) .left else .right;
            }
        };

        const Type = enum(c_int) {
            none = 0,
            keyboard_key = 300,
            pointer_button = 402,
            pointer_scroll_wheel = 404,
            _,
        };
        const getType = ffi.libinput.libinput_event_get_type;

        const destroy = ffi.libinput.libinput_event_destroy;
        const getKeyboard = ffi.libinput.libinput_event_get_keyboard_event;
        const getPointer = ffi.libinput.libinput_event_get_pointer_event;
    };

    pub const Options = struct { seat: [:0]const u8 = "seat0", udev: ?*Udev = null };
    pub const NewError = error{ UdevCreateFailed, ContextCreateFailed, AssignSeatFailed };
    pub fn new(options: Options) NewError!*LibInput {
        const udev_ctx = options.udev orelse Udev.new() orelse return error.UdevCreateFailed;
        defer if (options.udev == null) {
            udev_ctx.release();
        };

        const context = ffi.libinput.libinput_udev_create_context(&DeviceAccess.interface, null, udev_ctx) orelse
            return error.ContextCreateFailed;
        errdefer context.release();

        if (ffi.libinput.libinput_udev_assign_seat(context, options.seat.ptr) != 0)
            return error.AssignSeatFailed;
        return context;
    }

    pub fn release(self: *LibInput) void {
        _ = ffi.libinput.libinput_unref(self);
    }

    pub const fd = ffi.libinput.libinput_get_fd;

    pub const DispatchError = error{DispatchFailed};
    pub fn dispatch(self: *LibInput) DispatchError!void {
        if (ffi.libinput.libinput_dispatch(self) != 0) return error.DispatchFailed;
    }

    pub fn next(self: *LibInput) ?protocol.Event {
        while (ffi.libinput.libinput_get_event(self)) |raw| {
            defer raw.destroy();
            switch (raw.getType()) {
                .keyboard_key => {
                    const keyboard = raw.getKeyboard() orelse continue;
                    const state: protocol.Event.Keyboard.State = switch (keyboard.getKeyState()) {
                        .pressed => .pressed,
                        .released => .released,
                        _ => continue,
                    };
                    return .{
                        .keyboard = .{
                            .code = @enumFromInt(keyboard.getKey()),
                            .state = state,
                        },
                    };
                },
                .pointer_button => {
                    const pointer = raw.getPointer() orelse continue;
                    const state: protocol.Event.Pointer.Button.State = switch (pointer.getButtonState()) {
                        .pressed => .pressed,
                        .released => .released,
                        _ => continue,
                    };
                    return .{
                        .pointer = .{
                            .button = .{
                                .code = @enumFromInt(pointer.getButton()),
                                .state = state,
                            },
                        },
                    };
                },
                .pointer_scroll_wheel => {
                    const pointer = raw.getPointer() orelse continue;
                    const scroll = pointer.getScroll() orelse continue;
                    return .{ .pointer = .{ .scroll = scroll } };
                },
                else => continue,
            }
        }
        return null;
    }
};

pub const Udev = opaque {
    pub const new = ffi.udev.udev_new;

    pub fn release(self: *Udev) void {
        _ = ffi.udev.udev_unref(self);
    }
};

const DeviceAccess = struct {
    fn open(path: [*:0]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
        _ = user_data;
        var open_flags: std.c.O = @bitCast(flags);
        open_flags.CLOEXEC = true;
        open_flags.NONBLOCK = true;
        const rc = std.c.open(path, open_flags, @as(std.c.mode_t, 0));
        const err = std.c.errno(rc);
        return if (err == .SUCCESS) rc else -@as(c_int, @intFromEnum(err));
    }

    fn close(fd: std.posix.fd_t, user_data: ?*anyopaque) callconv(.c) void {
        _ = user_data;
        _ = std.c.close(fd);
    }

    const interface: LibInput.Interface = .{
        .open_restricted = open,
        .close_restricted = close,
    };
};

const ffi = struct {
    const udev = struct {
        extern fn udev_new() ?*Udev;
        extern fn udev_unref(udev: *Udev) ?*Udev;
    };

    const libinput = struct {
        extern fn libinput_udev_create_context(interface: *const LibInput.Interface, user_data: ?*anyopaque, udev: *Udev) ?*LibInput;
        extern fn libinput_udev_assign_seat(libinput: *LibInput, seat_id: [*:0]const u8) c_int;
        extern fn libinput_get_fd(libinput: *LibInput) std.posix.fd_t;
        extern fn libinput_dispatch(libinput: *LibInput) c_int;
        extern fn libinput_get_event(libinput: *LibInput) ?*LibInput.Event;
        extern fn libinput_event_destroy(event: *LibInput.Event) void;
        extern fn libinput_event_get_type(event: *LibInput.Event) LibInput.Event.Type;
        extern fn libinput_event_get_keyboard_event(event: *LibInput.Event) ?*LibInput.Event.Keyboard;
        extern fn libinput_event_get_pointer_event(event: *LibInput.Event) ?*LibInput.Event.Pointer;
        extern fn libinput_event_keyboard_get_key(event: *LibInput.Event.Keyboard) u32;
        extern fn libinput_event_keyboard_get_key_state(event: *LibInput.Event.Keyboard) LibInput.Event.Keyboard.KeyState;
        extern fn libinput_event_pointer_get_button(event: *LibInput.Event.Pointer) u32;
        extern fn libinput_event_pointer_get_button_state(event: *LibInput.Event.Pointer) LibInput.Event.Pointer.ButtonState;
        extern fn libinput_event_pointer_has_axis(event: *LibInput.Event.Pointer, axis: LibInput.Event.Pointer.Axis) c_int;
        extern fn libinput_event_pointer_get_scroll_value(event: *LibInput.Event.Pointer, axis: LibInput.Event.Pointer.Axis) f64;
        extern fn libinput_unref(libinput: *LibInput) ?*LibInput;
    };
};
