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

        button: Button,
        scroll: Scroll,
    };

    pub const Command = union(enum) {
        pub const RecordingState = enum { enabled, disabled };

        recording: RecordingState,
    };

    keyboard: Keyboard,
    pointer: Pointer,
    command: Command,
};
