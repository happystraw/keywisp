pub const codes = @import("protocol/codes.zig");

pub const Event = union(enum) {
    pub const Keyboard = struct {
        pub const State = enum { pressed, released };

        code: codes.Key,
        state: Keyboard.State,
    };

    pub const Pointer = union(enum) {
        pub const Button = struct {
            pub const State = enum { pressed, released };

            code: codes.Pointer.Button,
            state: Button.State,
        };

        pub const Scroll = enum { up, down, left, right };

        pub const State = union(enum) {
            button: Button.State,
            scroll,
        };

        button: Button,
        scroll: Scroll,

        pub fn state(self: Pointer) Pointer.State {
            return switch (self) {
                .button => |button| .{ .button = button.state },
                .scroll => .scroll,
            };
        }
    };

    pub const State = union(enum) {
        keyboard: Keyboard.State,
        pointer: Pointer.State,
    };

    keyboard: Keyboard,
    pointer: Pointer,

    pub fn state(self: Event) Event.State {
        return switch (self) {
            .keyboard => |keyboard| .{ .keyboard = keyboard.state },
            .pointer => |pointer| .{ .pointer = pointer.state() },
        };
    }
};
