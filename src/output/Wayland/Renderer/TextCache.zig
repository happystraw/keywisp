const std = @import("std");
const pango = @import("../pango.zig");

const TextCache = @This();

pub const Measurement = struct {
    layout: *pango.Layout,
    width: f64,
    offset_x: f64,
    offset_y: f64,
};

const Entry = struct {
    label: []const u8,
    measurement: Measurement,
    next: ?*Entry = null,

    fn destroy(self: *Entry, gpa: std.mem.Allocator) void {
        self.measurement.layout.destroy();
        gpa.free(self.label);
        gpa.destroy(self);
    }
};

entries: ?*Entry = null,
capacity: usize = 32,

pub fn clear(self: *TextCache, gpa: std.mem.Allocator) void {
    while (self.entries) |entry| {
        self.entries = entry.next;
        entry.destroy(gpa);
    }
}

/// Move a matching label to the head as the most recently used entry.
pub fn find(self: *TextCache, label: []const u8) ?*const Measurement {
    var link = &self.entries;
    while (link.*) |entry| {
        if (std.mem.eql(u8, entry.label, label)) {
            link.* = entry.next;
            entry.next = self.entries;
            self.entries = entry;
            return &entry.measurement;
        }
        link = &entry.next;
    }
    return null;
}

/// Copies the label and takes ownership of the Layout only on success.
pub fn insert(self: *TextCache, gpa: std.mem.Allocator, label: []const u8, measurement: Measurement) std.mem.Allocator.Error!*const Measurement {
    std.debug.assert(self.capacity > 0);
    const entry = try gpa.create(Entry);
    errdefer gpa.destroy(entry);
    entry.* = .{
        .label = try gpa.dupe(u8, label),
        .measurement = measurement,
        .next = self.entries,
    };
    self.entries = entry;
    self.evictExcess(gpa);
    return &entry.measurement;
}

fn evictExcess(self: *TextCache, gpa: std.mem.Allocator) void {
    var count: usize = 0;
    var link = &self.entries;
    while (link.*) |entry| {
        if (count == self.capacity) {
            link.* = entry.next;
            entry.destroy(gpa);
        } else {
            count += 1;
            link = &entry.next;
        }
    }
}
