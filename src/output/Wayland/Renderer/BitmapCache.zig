const std = @import("std");
const Cairo = @import("../cairo.zig").Cairo;
const pango = @import("../pango.zig");

const BitmapCache = @This();

/// Fractional offset within a physical pixel, in [0, 1) on each axis.
/// Cached images require matching offsets to preserve rasterization.
pub const PixelOffset = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub fn at(x: f64, y: f64, scale: u32) PixelOffset {
        const factor = @as(f64, @floatFromInt(scale)) / 120.0;
        return .{ .x = x * factor - @floor(x * factor), .y = y * factor - @floor(y * factor) };
    }
};

pub const Bitmap = struct {
    surface: *Cairo.Surface,
    width: i32,
    height: i32,
    origin_x: i32,
    origin_y: i32,

    pub const Insets = struct { left: f64 = 0, right: f64 = 0, top: f64 = 0, bottom: f64 = 0 };
    pub const InitError = Cairo.CreateError || error{ BufferSizeOverflow, CacheBudgetExceeded };

    pub fn init(width: f64, height: f64, scale: u32, insets: Insets, pixel_offset: PixelOffset, budget: usize) InitError!Bitmap {
        // One extra device pixel protects antialiased edges and strokes.
        const left = try pixels(insets.left, scale) + 1;
        const top = try pixels(insets.top, scale) + 1;
        const factor = @as(f64, @floatFromInt(scale)) / 120.0;
        const w = @as(i64, try pixels(width + pixel_offset.x / factor, scale)) + left + try pixels(insets.right, scale) + 1;
        const h = @as(i64, try pixels(height + pixel_offset.y / factor, scale)) + top + try pixels(insets.bottom, scale) + 1;
        if (w > std.math.maxInt(i32) / 4 or h > std.math.maxInt(i32)) return error.BufferSizeOverflow;
        if (@as(u64, @intCast(w)) * @as(u64, @intCast(h)) * 4 > budget) return error.CacheBudgetExceeded;
        return .{
            .surface = try .createImage(@intCast(w), @intCast(h)),
            .width = @intCast(w),
            .height = @intCast(h),
            .origin_x = left,
            .origin_y = top,
        };
    }

    fn pixels(logical: f64, scale: u32) error{BufferSizeOverflow}!i32 {
        const result = @ceil(logical * @as(f64, @floatFromInt(scale)) / 120.0);
        if (!std.math.isFinite(result) or result < 0 or result >= std.math.maxInt(i32)) return error.BufferSizeOverflow;
        return @intFromFloat(result);
    }

    pub fn createCairo(self: *const Bitmap, font: *const pango.FontContext, pixel_offset: PixelOffset) Cairo.CreateError!*Cairo {
        const cairo = try Cairo.create(self.surface);
        font.setupCairo(cairo);
        const factor = @as(f64, @floatFromInt(font.settings.scale)) / 120.0;
        cairo.translate((@as(f64, @floatFromInt(self.origin_x)) + pixel_offset.x) / factor, (@as(f64, @floatFromInt(self.origin_y)) + pixel_offset.y) / factor);
        cairo.setOperator(.source);
        return cairo;
    }

    pub fn deinit(self: Bitmap) void {
        self.surface.destroy();
    }

    pub fn bytes(self: *const Bitmap) usize {
        return @as(usize, @intCast(self.width)) * @as(usize, @intCast(self.height)) * 4;
    }

    pub fn paint(self: *const Bitmap, cairo: *Cairo, x: f64, y: f64, scale: u32) void {
        cairo.save();
        defer cairo.restore();
        const factor = @as(f64, @floatFromInt(scale)) / 120.0;
        const left = @floor(x * factor) - @as(f64, @floatFromInt(self.origin_x));
        const top = @floor(y * factor) - @as(f64, @floatFromInt(self.origin_y));
        cairo.identityMatrix();
        cairo.rectangle(left, top, @floatFromInt(self.width), @floatFromInt(self.height));
        cairo.clip();
        cairo.setOperator(.over);
        cairo.setSourceSurface(self.surface, left, top);
        cairo.paint();
    }
};

pub const Key = struct {
    kind: enum { shadow, background },
    width: f64,
    height: f64,
    pixel_offset: PixelOffset,
};

const Entry = struct {
    key: Key,
    bitmap: Bitmap,
    next: ?*Entry = null,

    fn destroy(self: *Entry, gpa: std.mem.Allocator) void {
        self.bitmap.deinit();
        gpa.destroy(self);
    }
};

entries: ?*Entry = null,
capacity: usize = 32,
max_bytes: usize = 64 * 1024 * 1024,

pub fn clear(self: *BitmapCache, gpa: std.mem.Allocator) void {
    while (self.entries) |entry| {
        self.entries = entry.next;
        entry.destroy(gpa);
    }
}

/// Move a matching bitmap to the head as the most recently used entry.
pub fn find(self: *BitmapCache, key: Key) ?*const Bitmap {
    var link = &self.entries;
    while (link.*) |entry| {
        if (std.meta.eql(entry.key, key)) {
            link.* = entry.next;
            entry.next = self.entries;
            self.entries = entry;
            return &entry.bitmap;
        }
        link = &entry.next;
    }
    return null;
}

pub const InsertError = std.mem.Allocator.Error || error{CacheBudgetExceeded};

/// Takes ownership only on success. The returned bitmap survives this insertion.
pub fn insert(self: *BitmapCache, gpa: std.mem.Allocator, key: Key, bitmap: Bitmap) InsertError!*const Bitmap {
    std.debug.assert(self.capacity > 0);
    if (bitmap.bytes() > self.max_bytes) return error.CacheBudgetExceeded;
    const entry = try gpa.create(Entry);
    entry.* = .{ .key = key, .bitmap = bitmap, .next = self.entries };
    self.entries = entry;
    self.evictExcess(gpa);
    return &entry.bitmap;
}

fn evictExcess(self: *BitmapCache, gpa: std.mem.Allocator) void {
    var bytes: usize = 0;
    var count: usize = 0;
    var link = &self.entries;
    while (link.*) |entry| {
        const size = entry.bitmap.bytes();
        if (size > self.max_bytes - bytes or count == self.capacity) {
            link.* = entry.next;
            entry.destroy(gpa);
        } else {
            bytes += size;
            count += 1;
            link = &entry.next;
        }
    }
}
