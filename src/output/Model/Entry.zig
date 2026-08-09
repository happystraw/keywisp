const Entry = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Modifiers = @import("Modifiers.zig");

modifiers: Modifiers,
name: []const u8,
text: []const u8,
repetition: usize = 1,

pub fn init(gpa: Allocator, modifiers: Modifiers, name: []const u8, text: []const u8) Allocator.Error!Entry {
    const storage = try gpa.alloc(u8, name.len + text.len);
    @memcpy(storage[0..name.len], name);
    @memcpy(storage[name.len..], text);
    return .{
        .modifiers = modifiers,
        .name = storage[0..name.len],
        .text = storage[name.len..],
    };
}

pub fn deinit(self: *Entry, gpa: Allocator) void {
    gpa.free(self.name.ptr[0 .. self.name.len + self.text.len]);
    self.* = undefined;
}

pub fn sameInput(self: *const Entry, modifiers: Modifiers, name: []const u8, text: []const u8) bool {
    return std.meta.eql(self.modifiers, modifiers) and
        std.mem.eql(u8, self.name, name) and
        std.mem.eql(u8, self.text, text);
}
