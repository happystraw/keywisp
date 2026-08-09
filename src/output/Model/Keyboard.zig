const std = @import("std");

const protocol = @import("protocol");

const Keyboard = @This();

context: *xkb.Context,
keymap: *xkb.Keymap,
state: *xkb.State,

pub const Keymap = union(enum) {
    environment,
    serialized: [:0]const u8,
};

pub const InitError = error{ ContextFailed, KeymapFailed, StateFailed };
pub fn init(options: Keymap) InitError!Keyboard {
    const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
    errdefer context.unref();

    const keymap = switch (options) {
        .environment => xkb.Keymap.newFromNames(context, null, .no_flags),
        .serialized => |keymap_text| createFromSerialized(context, keymap_text),
    } orelse return error.KeymapFailed;
    errdefer keymap.unref();

    const state = xkb.State.new(keymap) orelse return error.StateFailed;
    return .{ .context = context, .keymap = keymap, .state = state };
}

pub fn deinit(self: *Keyboard) void {
    self.state.unref();
    self.keymap.unref();
    self.context.unref();
    self.* = undefined;
}

pub fn setSerializedKeymap(self: *Keyboard, keymap_text: [:0]const u8) InitError!void {
    const keymap = createFromSerialized(self.context, keymap_text) orelse return error.KeymapFailed;
    errdefer keymap.unref();
    const state = xkb.State.new(keymap) orelse return error.StateFailed;

    self.state.unref();
    self.keymap.unref();
    self.keymap = keymap;
    self.state = state;
}

pub fn update(self: *Keyboard, event: protocol.Event.Keyboard) void {
    const xkb_code: xkb.Keycode = @intFromEnum(event.code) + 8;
    _ = self.state.updateKey(xkb_code, if (event.state == .released) .up else .down);
}

pub fn keysym(self: *Keyboard, code: protocol.codes.Key) xkb.Keysym {
    return self.state.keyGetOneSym(@intFromEnum(code) + 8);
}

pub fn name(xkb_keysym: xkb.Keysym, buffer: *[64]u8) ?[]const u8 {
    const name_len = xkb.Keysym.getName(xkb_keysym, buffer, buffer.len);
    return if (name_len > 0 and @as(usize, @intCast(name_len)) < buffer.len)
        buffer[0..@intCast(name_len)]
    else
        null;
}

pub fn text(xkb_keysym: xkb.Keysym, buffer: *[64]u8) []const u8 {
    const text_size = xkb.Keysym.toUTF8(xkb_keysym, buffer, buffer.len);
    const text_len: usize = if (text_size > 0) @intCast(text_size - 1) else 0;
    const has_display_text = text_len > 0 and
        buffer[0] != ' ' and
        !std.ascii.isControl(buffer[0]);

    return if (has_display_text) buffer[0..text_len] else "";
}

fn createFromSerialized(context: *xkb.Context, keymap_text: [:0]const u8) ?*xkb.Keymap {
    if (keymap_text.len == 0) return null;
    return xkb.Keymap.newFromString(context, keymap_text.ptr, .text_v1, .no_flags);
}

const xkb = struct {
    const Keycode = u32;

    const Keysym = enum(u32) {
        const getName = ffi.xkbcommon.xkb_keysym_get_name;
        const toUTF8 = ffi.xkbcommon.xkb_keysym_to_utf8;

        _,
    };

    const KeyDirection = enum(c_int) { up = 0, down = 1, _ };

    const RuleNames = extern struct {
        rules: ?[*:0]const u8,
        model: ?[*:0]const u8,
        layout: ?[*:0]const u8,
        variant: ?[*:0]const u8,
        options: ?[*:0]const u8,
    };

    const Context = opaque {
        const Flags = enum(c_int) { no_flags = 0, _ };
        const new = ffi.xkbcommon.xkb_context_new;
        const unref = ffi.xkbcommon.xkb_context_unref;
    };

    const Keymap = opaque {
        const CompileFlags = enum(c_int) { no_flags = 0, _ };
        const Format = enum(c_int) { text_v1 = 1, text_v2 = 2, _ };

        const newFromNames = ffi.xkbcommon.xkb_keymap_new_from_names;
        const newFromString = ffi.xkbcommon.xkb_keymap_new_from_string;
        const unref = ffi.xkbcommon.xkb_keymap_unref;
    };

    const State = opaque {
        const Component = enum(c_int) { _ };

        const new = ffi.xkbcommon.xkb_state_new;
        const unref = ffi.xkbcommon.xkb_state_unref;
        const updateKey = ffi.xkbcommon.xkb_state_update_key;
        const keyGetOneSym = ffi.xkbcommon.xkb_state_key_get_one_sym;
    };
};

const ffi = struct {
    const xkbcommon = struct {
        extern fn xkb_context_new(flags: xkb.Context.Flags) ?*xkb.Context;
        extern fn xkb_context_unref(context: *xkb.Context) void;
        extern fn xkb_keymap_new_from_names(context: *xkb.Context, names: ?*const xkb.RuleNames, flags: xkb.Keymap.CompileFlags) ?*xkb.Keymap;
        extern fn xkb_keymap_new_from_string(context: *xkb.Context, string: [*:0]const u8, format: xkb.Keymap.Format, flags: xkb.Keymap.CompileFlags) ?*xkb.Keymap;
        extern fn xkb_keymap_unref(keymap: *xkb.Keymap) void;
        extern fn xkb_state_new(keymap: *xkb.Keymap) ?*xkb.State;
        extern fn xkb_state_unref(state: *xkb.State) void;
        extern fn xkb_state_update_key(state: *xkb.State, key: xkb.Keycode, direction: xkb.KeyDirection) xkb.State.Component;
        extern fn xkb_state_key_get_one_sym(state: *xkb.State, key: xkb.Keycode) xkb.Keysym;
        extern fn xkb_keysym_get_name(keysym: xkb.Keysym, buffer: [*]u8, size: usize) c_int;
        extern fn xkb_keysym_to_utf8(keysym: xkb.Keysym, buffer: [*]u8, size: usize) c_int;
    };
};
