const std = @import("std");
const Cairo = @import("cairo.zig").Cairo;
const Metrics = @import("pango.zig").Metrics;

const KeyCache = @This();

// Keep cache retention bounded even with large fonts or changing repeat counts.
const max_bytes = 64 * 1024 * 1024;
const max_entries = 64;

/// Fractional device-pixel origin. Bitmaps may only be reused at the same phase.
pub const Phase = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub fn at(x: f64, y: f64, scale: u32) Phase {
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
    phase: Phase,

    pub const Insets = struct { left: f64 = 0, right: f64 = 0, top: f64 = 0, bottom: f64 = 0 };
    pub const InitError = Cairo.CreateError || error{BufferSizeOverflow};

    pub fn init(width: f64, height: f64, scale: u32, insets: Insets, phase: Phase) InitError!Bitmap {
        // One extra device pixel protects antialiased edges and strokes.
        const left = try pixels(insets.left, scale) + 1;
        const top = try pixels(insets.top, scale) + 1;
        const factor = @as(f64, @floatFromInt(scale)) / 120.0;
        const w = @as(i64, try pixels(width + phase.x / factor, scale)) + left + try pixels(insets.right, scale) + 1;
        const h = @as(i64, try pixels(height + phase.y / factor, scale)) + top + try pixels(insets.bottom, scale) + 1;
        if (w > std.math.maxInt(i32) / 4 or h > std.math.maxInt(i32)) return error.BufferSizeOverflow;
        return .{
            .surface = try Cairo.Surface.createImage(@intCast(w), @intCast(h)),
            .width = @intCast(w),
            .height = @intCast(h),
            .origin_x = left,
            .origin_y = top,
            .phase = phase,
        };
    }

    fn pixels(logical: f64, scale: u32) error{BufferSizeOverflow}!i32 {
        const result = @ceil(logical * @as(f64, @floatFromInt(scale)) / 120.0);
        if (!std.math.isFinite(result) or result < 0 or result >= std.math.maxInt(i32)) return error.BufferSizeOverflow;
        return @intFromFloat(result);
    }

    pub fn deinit(self: Bitmap) void {
        self.surface.destroy();
    }

    pub fn share(self: Bitmap) Bitmap {
        var shared = self;
        shared.surface = self.surface.reference();
        return shared;
    }

    pub fn copy(self: Bitmap) Cairo.CreateError!Bitmap {
        var result = self;
        result.surface = try Cairo.Surface.createImage(self.width, self.height);
        errdefer result.deinit();
        const cairo = try Cairo.create(result.surface);
        defer cairo.destroy();
        cairo.setOperator(.source);
        cairo.setSourceSurface(self.surface, 0, 0);
        cairo.paint();
        return result;
    }

    pub fn bytes(self: Bitmap) usize {
        return @as(usize, @intCast(self.width)) * @as(usize, @intCast(self.height)) * 4;
    }

    pub fn paint(self: Bitmap, cairo: *Cairo, x: f64, y: f64, scale: u32) void {
        self.paintMasked(cairo, x, y, scale, null);
    }

    pub fn paintMasked(self: Bitmap, cairo: *Cairo, x: f64, y: f64, scale: u32, coverage: ?Bitmap) void {
        cairo.save();
        defer cairo.restore();
        // Rasterize at the original fractional origin, then blit without resampling.
        const factor = @as(f64, @floatFromInt(scale)) / 120.0;
        const left = @floor(x * factor) - @as(f64, @floatFromInt(self.origin_x));
        const top = @floor(y * factor) - @as(f64, @floatFromInt(self.origin_y));
        cairo.identityMatrix();
        cairo.rectangle(left, top, @floatFromInt(self.width), @floatFromInt(self.height));
        cairo.clip();
        if (coverage) |mask| {
            // SOURCE operations may erase the frame even when their color is translucent.
            cairo.setOperator(.dest_out);
            cairo.setSourceSurface(mask.surface, left, top);
            cairo.paint();
            cairo.setOperator(.add);
        } else {
            cairo.setOperator(.over);
        }
        cairo.setSourceSurface(self.surface, left, top);
        cairo.paint();
    }
};

pub const Key = struct {
    pub const Face = struct {
        bitmap: Bitmap,
        coverage: ?Bitmap,

        pub fn paint(self: Face, cairo: *Cairo, x: f64, y: f64, scale: u32) void {
            self.bitmap.paintMasked(cairo, x, y, scale, self.coverage);
        }
    };

    text: [:0]u8,
    metrics: Metrics,
    width: f64,
    phase: Phase,
    background: ?Bitmap = null,
    background_coverage: ?Bitmap = null,
    shadow: ?Bitmap = null,
    // Only historical keys retain a complete image, in the normal text color.
    face: ?Face = null,
    next: ?*Key = null,

    pub fn bytes(self: *const Key) usize {
        var size: usize = 0;
        if (self.background) |bitmap| size += bitmap.bytes();
        if (self.background_coverage) |bitmap| size += bitmap.bytes();
        if (self.shadow) |bitmap| size += bitmap.bytes();
        if (self.face) |value| {
            size += value.bitmap.bytes();
            if (value.coverage) |mask| size += mask.bytes();
        }
        return size;
    }

    pub fn setPhase(self: *Key, phase: Phase) void {
        if (std.meta.eql(self.phase, phase)) return;
        self.clearImages();
        self.phase = phase;
    }

    fn clearImages(self: *Key) void {
        if (self.background) |bitmap| bitmap.deinit();
        if (self.background_coverage) |bitmap| bitmap.deinit();
        if (self.shadow) |bitmap| bitmap.deinit();
        if (self.face) |value| {
            value.bitmap.deinit();
            if (value.coverage) |mask| mask.deinit();
        }
        self.background = null;
        self.background_coverage = null;
        self.shadow = null;
        self.face = null;
    }

    fn destroy(self: *Key, gpa: std.mem.Allocator) void {
        self.clearImages();
        gpa.free(self.text);
        gpa.destroy(self);
    }
};

head: ?*Key = null,

pub fn clear(self: *KeyCache, gpa: std.mem.Allocator) void {
    while (self.head) |key| {
        self.head = key.next;
        key.destroy(gpa);
    }
}

pub fn find(self: *KeyCache, text: []const u8, phase: ?Phase) ?*Key {
    var link = &self.head;
    while (link.*) |key| {
        if (std.mem.eql(u8, key.text, text) and (phase == null or std.meta.eql(key.phase, phase.?))) {
            link.* = key.next;
            key.next = self.head;
            self.head = key;
            return key;
        }
        link = &key.next;
    }
    return null;
}

pub fn insert(self: *KeyCache, gpa: std.mem.Allocator, text: []const u8, metrics: Metrics, width: f64, phase: Phase) std.mem.Allocator.Error!*Key {
    const key = try gpa.create(Key);
    errdefer gpa.destroy(key);
    key.* = .{ .text = try gpa.dupeZ(u8, text), .metrics = metrics, .width = width, .phase = phase, .next = self.head };
    self.shareShapes(key);
    self.head = key;
    return key;
}

// Geometry is independent of the label; share immutable rasterized shapes.
pub fn shareShapes(self: *KeyCache, key: *Key) void {
    var item = self.head;
    while (item) |other| : (item = other.next) {
        if (other == key or other.width != key.width or !std.meta.eql(other.phase, key.phase)) continue;
        if (key.background == null) {
            if (other.background) |bitmap| key.background = bitmap.share();
            if (other.background_coverage) |bitmap| key.background_coverage = bitmap.share();
        }
        if (key.shadow == null) {
            if (other.shadow) |bitmap| key.shadow = bitmap.share();
        }
        if (key.background != null and key.shadow != null) break;
    }
}

pub fn trim(self: *KeyCache, gpa: std.mem.Allocator, reserved_bytes: usize) void {
    var bytes: usize = reserved_bytes;
    var count: usize = 0;
    var link = &self.head;
    while (link.*) |key| {
        bytes += key.bytes(); // Shared surfaces are conservatively counted per key.
        count += 1;
        if (bytes > max_bytes or count > max_entries) {
            var tail: KeyCache = .{ .head = key };
            link.* = null;
            tail.clear(gpa);
            return;
        }
        link = &key.next;
    }
}

test "least recently used keys are evicted and oversized bitmaps are not retained" {
    var cache: KeyCache = .{};
    defer cache.clear(std.testing.allocator);
    const metrics: Metrics = .{ .width = 1, .height = 1, .baseline = 1, .font_size = 1 };
    for (0..max_entries + 1) |index| {
        var buffer: [32]u8 = undefined;
        _ = try cache.insert(std.testing.allocator, try std.fmt.bufPrint(&buffer, "{d}", .{index}), metrics, 1, .{});
    }
    const oldest = cache.find("0", null).?;
    cache.trim(std.testing.allocator, 0);
    try std.testing.expectEqual(oldest, cache.find("0", null).?);
    try std.testing.expect(cache.find("1", null) == null);
    cache.clear(std.testing.allocator);
    const large = try cache.insert(std.testing.allocator, "large", metrics, 1, .{});
    // Use a small real surface but simulate its retention size to avoid a huge test allocation.
    large.background = try Bitmap.init(1, 1, 120, .{}, .{});
    large.background.?.width = 4096;
    large.background.?.height = 4097;
    cache.trim(std.testing.allocator, 0);
    try std.testing.expect(cache.head == null);
    const first = try cache.insert(std.testing.allocator, "first", metrics, 1, .{});
    first.background = try Bitmap.init(1, 1, 120, .{}, .{});
    const second = try cache.insert(std.testing.allocator, "second", metrics, 1, .{});
    second.background = try Bitmap.init(1, 1, 120, .{}, .{});
    cache.trim(std.testing.allocator, max_bytes - second.bytes());
    try std.testing.expectEqual(second, cache.head.?);
    try std.testing.expect(second.next == null);
}
