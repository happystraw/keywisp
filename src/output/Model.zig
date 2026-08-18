const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

const protocol = @import("protocol");

pub const Entry = @import("Model/Entry.zig");
const Keyboard = @import("Model/Keyboard.zig");
pub const Keymap = Keyboard.Keymap;
pub const Modifiers = @import("Model/Modifiers.zig");

const repetition_threshold = 3;

const Model = @This();

entries: []Entry,
start: usize = 0,
len: usize = 0,
modifiers: Modifiers = .{},
repetition: usize = 0,
collapse_repetitions: bool,

keyboard: Keyboard,
gpa: Allocator,

pub const Change = enum { none, changed };
pub const Options = struct {
    capacity: usize = 64,
    keymap: Keymap = .environment,
    collapse_repetitions: bool = true,
};

pub const InitError = Allocator.Error || Keyboard.InitError || error{InvalidCapacity};

pub const View = struct {
    first: []const Entry,
    second: []const Entry,

    pub const Iterator = struct {
        view: View,
        index: usize = 0,

        pub fn next(self: *Iterator) ?*const Entry {
            if (self.index >= self.view.len()) return null;
            defer self.index += 1;
            return self.view.at(self.index);
        }
    };

    pub fn len(self: View) usize {
        return self.first.len + self.second.len;
    }

    pub fn at(self: View, index: usize) *const Entry {
        std.debug.assert(index < self.len());
        return if (index < self.first.len)
            &self.first[index]
        else
            &self.second[index - self.first.len];
    }

    pub fn iterator(self: View) Iterator {
        return .{ .view = self };
    }
};

pub fn init(gpa: Allocator, options: Options) InitError!Model {
    if (options.capacity == 0) return error.InvalidCapacity;
    var keyboard = try Keyboard.init(options.keymap);
    errdefer keyboard.deinit();
    return .{
        .entries = try gpa.alloc(Entry, options.capacity),
        .collapse_repetitions = options.collapse_repetitions,
        .keyboard = keyboard,
        .gpa = gpa,
    };
}

pub fn deinit(self: *Model) void {
    self.clear();
    self.keyboard.deinit();
    self.gpa.free(self.entries);
    self.* = undefined;
}

pub fn setSerializedKeymap(self: *Model, text: [:0]const u8) Keyboard.InitError!void {
    try self.keyboard.setSerializedKeymap(text);
    self.modifiers = .{};
    self.repetition = 0;
}

/// Returns a read-only borrowed view of the internal history.
/// After calling `handle`, `clear`, or `deinit`, existing View, Iterator, or Entry pointers must not be used.
pub fn view(self: *const Model) View {
    const first_len = @min(self.len, self.entries.len - self.start);
    return .{
        .first = self.entries[self.start .. self.start + first_len],
        .second = self.entries[0 .. self.len - first_len],
    };
}

pub fn clear(self: *Model) void {
    for (0..self.len) |offset| {
        self.entries[(self.start + offset) % self.entries.len].deinit(self.gpa);
    }
    self.start = 0;
    self.len = 0;
    self.repetition = 0;
}

fn append(self: *Model, entry: Entry) void {
    if (self.len == self.entries.len) {
        self.entries[self.start].deinit(self.gpa);
        self.start = (self.start + 1) % self.entries.len;
        self.len -= 1;
    }
    self.entries[(self.start + self.len) % self.entries.len] = entry;
    self.len += 1;
}

fn last(self: *Model) ?*Entry {
    if (self.len == 0) return null;
    return &self.entries[(self.start + self.len - 1) % self.entries.len];
}

pub fn handle(self: *Model, event: protocol.Event) Allocator.Error!Change {
    return switch (event) {
        .keyboard => |keyboard| blk: {
            var name_buffer: [64]u8 = undefined;
            var text_buffer: [64]u8 = undefined;
            self.keyboard.update(keyboard);
            const keysym = self.keyboard.keysym(keyboard.code);
            const name = Keyboard.name(keysym, &name_buffer) orelse break :blk .none;
            if (self.modifiers.update(name, keyboard.state != .released)) break :blk .none;
            if (keyboard.state == .released) break :blk .none;
            break :blk self.record(name, Keyboard.text(keysym, &text_buffer));
        },
        .pointer => |pointer_event| blk: {
            const name: []const u8 = switch (pointer_event) {
                .button => |button| button: {
                    if (button.state == .released) break :blk .none;
                    break :button switch (button.code) {
                        .left => "MouseLeft",
                        .right => "MouseRight",
                        .middle => "MouseMiddle",
                        .side => "MouseSide",
                        .extra => "MouseExtra",
                        .forward => "MouseForward",
                        .back => "MouseBack",
                        .task => "MouseTask",
                        else => {
                            log.warn("unknown pointer button code: {d}", .{@intFromEnum(button.code)});
                            break :blk .none;
                        },
                    };
                },
                .scroll => |scroll| switch (scroll) {
                    .up => "ScrollUp",
                    .down => "ScrollDown",
                    .left => "ScrollLeft",
                    .right => "ScrollRight",
                },
            };
            break :blk self.record(name, "");
        },
    };
}

fn record(self: *Model, name: []const u8, text: []const u8) Allocator.Error!Change {
    if (!self.collapse_repetitions) {
        self.append(try Entry.init(self.gpa, self.modifiers, name, text));
        return .changed;
    }

    if (self.last()) |last_entry| {
        if (last_entry.sameInput(self.modifiers, name, text)) {
            self.repetition += 1;
            if (self.repetition > repetition_threshold) {
                last_entry.repetition = self.repetition - repetition_threshold + 1;
                return .changed;
            }
        } else {
            self.repetition = 1;
        }
    } else {
        self.repetition = 1;
    }
    self.append(try Entry.init(self.gpa, self.modifiers, name, text));
    return .changed;
}

test "preserves repeated inputs when repetition collapsing is disabled" {
    var model = try Model.init(std.testing.allocator, .{
        .capacity = 3,
        .collapse_repetitions = false,
    });
    defer model.deinit();

    for (0..4) |_| {
        try std.testing.expectEqual(Change.changed, try model.record("d", "d"));
    }

    const entries = model.view();
    try std.testing.expectEqual(3, entries.len());
    for (0..entries.len()) |index| {
        const entry = entries.at(index);
        try std.testing.expectEqualStrings("d", entry.name);
        try std.testing.expectEqualStrings("d", entry.text);
        try std.testing.expectEqual(1, entry.repetition);
    }
}
