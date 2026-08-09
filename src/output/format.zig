const std = @import("std");

const Entry = @import("Model/Entry.zig");

const buffer_capacity = 512;
pub const Buffer = [buffer_capacity:0]u8;
pub const Error = error{NoSpaceLeft};
pub const Options = struct {
    show_repetition: bool = true,
};

const labels = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Return", "↵" },
    .{ "space", "Space" },
    .{ "Escape", "Esc" },
    .{ "Control", "Ctrl+" },
    .{ "Alt", "Alt+" },
    .{ "Shift", "Shift+" },
    .{ "Super", "Super+" },
    .{ "Tab", "Tab" },
    .{ "ISO_Left_Tab", "Tab" },
    .{ "BackSpace", "Bksp" },
    .{ "Delete", "Del" },
    .{ "Insert", "Ins" },
    .{ "Caps_Lock", "Caps" },
    .{ "Left", "←" },
    .{ "Up", "↑" },
    .{ "Down", "↓" },
    .{ "Right", "→" },
    .{ "Prior", "PgUp" },
    .{ "Next", "PgDn" },
    .{ "Print", "PrtSc" },
    .{ "Num_Lock", "Num" },
    .{ "Scroll_Lock", "Scroll" },
    .{ "KP_Delete", "." },
    .{ "KP_Insert", "0" },
    .{ "KP_End", "1" },
    .{ "KP_Down", "2" },
    .{ "KP_Next", "3" },
    .{ "KP_Left", "4" },
    .{ "KP_Begin", "5" },
    .{ "KP_Right", "6" },
    .{ "KP_Home", "7" },
    .{ "KP_Up", "8" },
    .{ "KP_Prior", "9" },
    .{ "KP_Enter", "↵" },
    .{ "MouseLeft", "[L]" },
    .{ "MouseRight", "[R]" },
    .{ "MouseMiddle", "[M]" },
    .{ "ScrollUp", "[↑]" },
    .{ "ScrollDown", "[↓]" },
    .{ "ScrollLeft", "[←]" },
    .{ "ScrollRight", "[→]" },
});

fn label(name: []const u8) []const u8 {
    return labels.get(name) orelse name;
}

pub fn entry(value: *const Entry, buffer: []u8, options: Options) Error![:0]const u8 {
    var used: usize = 0;
    var modifiers = value.modifiers.iterator();
    while (modifiers.next()) |name| {
        try append(buffer, &used, label(name));
    }

    const shown = if (value.text.len != 0) value.text else label(value.name);
    if (shown.len == 1 and std.ascii.isLower(shown[0])) {
        const upper = [_]u8{std.ascii.toUpper(shown[0])};
        try append(buffer, &used, &upper);
    } else {
        try append(buffer, &used, shown);
    }

    if (options.show_repetition and value.repetition > 1) {
        try append(buffer, &used, "ₓ");
        var count_buffer: [32]u8 = undefined;
        const digits = std.fmt.bufPrint(&count_buffer, "{d}", .{value.repetition}) catch unreachable;
        for (digits) |digit| try append(buffer, &used, subscript(digit));
    }

    buffer[used] = 0;
    return buffer[0..used :0];
}

fn append(buffer: []u8, used: *usize, value: []const u8) Error!void {
    const available = buffer.len - used.* - 1;
    if (value.len > available) return error.NoSpaceLeft;
    @memcpy(buffer[used.* .. used.* + value.len], value);
    used.* += value.len;
}

const subscripts = [_][]const u8{ "₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉" };
fn subscript(digit: u8) []const u8 {
    if (digit < '0' or digit > '9') return "";
    return subscripts[digit - '0'];
}
