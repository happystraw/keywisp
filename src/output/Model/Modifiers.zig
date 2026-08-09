const std = @import("std");

const Modifiers = @This();

const Held = packed struct {
    left: bool = false,
    right: bool = false,

    fn active(self: Held) bool {
        return self.left or self.right;
    }
};

ctrl: Held = .{},
alt: Held = .{},
super: Held = .{},
shift: Held = .{},

pub fn update(self: *Modifiers, name: []const u8, pressed: bool) bool {
    if (std.mem.eql(u8, name, "Control_L"))
        self.ctrl.left = pressed
    else if (std.mem.eql(u8, name, "Control_R"))
        self.ctrl.right = pressed
    else if (std.mem.eql(u8, name, "Alt_L") or std.mem.eql(u8, name, "Meta_L"))
        self.alt.left = pressed
    else if (std.mem.eql(u8, name, "Alt_R") or std.mem.eql(u8, name, "Meta_R"))
        self.alt.right = pressed
    else if (std.mem.eql(u8, name, "Super_L"))
        self.super.left = pressed
    else if (std.mem.eql(u8, name, "Super_R"))
        self.super.right = pressed
    else if (std.mem.eql(u8, name, "Shift_L"))
        self.shift.left = pressed
    else if (std.mem.eql(u8, name, "Shift_R"))
        self.shift.right = pressed
    else
        return false;
    return true;
}

pub const Iterator = struct {
    modifiers: Modifiers,
    index: usize = 0,

    pub fn next(self: *Iterator) ?[]const u8 {
        while (self.index < 4) {
            const index = self.index;
            self.index += 1;
            const entry: struct { active: bool, name: []const u8 } = switch (index) {
                0 => .{ .active = self.modifiers.super.active(), .name = "Super" },
                1 => .{ .active = self.modifiers.ctrl.active(), .name = "Control" },
                2 => .{ .active = self.modifiers.shift.active(), .name = "Shift" },
                3 => .{ .active = self.modifiers.alt.active(), .name = "Alt" },
                else => unreachable,
            };
            if (entry.active) return entry.name;
        }
        return null;
    }
};

pub fn iterator(self: Modifiers) Iterator {
    return .{ .modifiers = self };
}

test "tracks both sides and iterates active modifiers in display order" {
    var modifiers: Modifiers = .{};
    try std.testing.expect(modifiers.update("Control_L", true));
    try std.testing.expect(modifiers.update("Control_R", true));
    try std.testing.expect(modifiers.update("Control_L", false));
    try std.testing.expect(modifiers.ctrl.active());
    try std.testing.expect(modifiers.update("Super_L", true));
    try std.testing.expect(modifiers.update("Alt_L", true));
    try std.testing.expect(!modifiers.update("a", true));

    var active = modifiers.iterator();
    try std.testing.expectEqualStrings("Super", active.next().?);
    try std.testing.expectEqualStrings("Control", active.next().?);
    try std.testing.expectEqualStrings("Alt", active.next().?);
    try std.testing.expect(active.next() == null);
}
