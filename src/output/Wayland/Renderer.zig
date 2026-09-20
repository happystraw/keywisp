const std = @import("std");
const Allocator = std.mem.Allocator;

const wl = @import("wayland").client.wl;

const format = @import("../format.zig");
const Model = @import("../Model.zig");
const Appearance = @import("Appearance.zig");
const LayerSurface = @import("LayerSurface.zig");
const pango = @import("pango.zig");
const drawing = @import("Renderer/drawing.zig");
const Cairo = @import("cairo.zig").Cairo;
const Measurement = @import("Renderer/TextCache.zig").Measurement;
const ShmBuffer = @import("ShmBuffer.zig");

const Renderer = @This();

const Frame = struct {
    buffer: ShmBuffer,
    released: bool = false,
    next: ?*Frame = null,

    fn listener(buffer: *wl.Buffer, event: wl.Buffer.Event, self: *Frame) void {
        _ = buffer;
        switch (event) {
            .release => self.released = true,
        }
    }
};

context: drawing.Context,
gpa: Allocator,
shm: *wl.Shm,
target: *LayerSurface,
pending_frames: ?*Frame = null,

pub fn init(
    gpa: Allocator,
    style: Appearance.Style,
    shm: *wl.Shm,
    target: *LayerSurface,
    settings: pango.FontContext.Settings,
) !Renderer {
    return .{
        .context = try .init(style, settings),
        .gpa = gpa,
        .shm = shm,
        .target = target,
    };
}

pub fn deinit(self: *Renderer) void {
    defer self.context.deinit(self.gpa);
    var frame = self.pending_frames;
    while (frame) |item| {
        const next = item.next;
        item.buffer.deinit();
        self.gpa.destroy(item);
        frame = next;
    }
}

pub fn reap(self: *Renderer) void {
    var link = &self.pending_frames;
    while (link.*) |frame| {
        if (!frame.released) {
            link = &frame.next;
            continue;
        }
        link.* = frame.next;
        frame.buffer.deinit();
        self.gpa.destroy(frame);
    }
}

pub fn render(self: *Renderer, keys: Model.View, settings: pango.FontContext.Settings) !void {
    const context = &self.context;
    const target = self.target;
    const scale = settings.scale;

    try context.update(self.gpa, settings);

    // 1. Select the visible keys and calculate the panel dimensions.
    var measurements: [Model.default_capacity]*const Measurement = undefined;
    const layout = try self.measure(keys, &measurements);

    const logical_width = try surfaceSize(layout.width);
    const logical_height = try surfaceSize(layout.height);
    const new_w: u32 = @intCast(logical_width);
    const new_h: u32 = @intCast(logical_height);
    const buffer_width = try scaledSize(logical_width, scale);
    const buffer_height = try scaledSize(logical_height, scale);

    // 2. Size changed → request a new layer surface size
    if (new_w != target.width or new_h != target.height) {
        target.setSize(new_w, new_h);
    }

    // 3. Create a frame buffer.
    const frame = try self.gpa.create(Frame);
    errdefer self.gpa.destroy(frame);
    frame.* = .{
        .buffer = try .init(
            self.shm,
            buffer_width,
            buffer_height,
            .argb8888,
        ),
    };
    errdefer frame.buffer.deinit();

    // 4. Draw directly into the frame buffer.
    try self.paint(frame.buffer.cairo, layout);

    frame.next = self.pending_frames;
    self.pending_frames = frame;
    frame.buffer.setListener(*Frame, Frame.listener, frame);

    // 5. Commit.
    if (target.preferred_scale != null) {
        target.viewport.?.setDestination(logical_width, logical_height);
        target.surface.setBufferScale(1);
    } else {
        target.surface.setBufferScale(@intCast(scale / 120));
    }
    target.surface.attach(frame.buffer.buffer, 0, 0);
    target.surface.damageBuffer(0, 0, frame.buffer.width, frame.buffer.height);
    target.surface.commit();
}

const PanelLayout = struct { keys: []const *const Measurement, width: f64, height: f64 };

fn measure(self: *Renderer, keys: Model.View, measurements: []*const Measurement) !PanelLayout {
    const context = &self.context;
    const style = context.style;
    const geometry = &context.geometry;
    const end = keys.len();
    std.debug.assert(end <= measurements.len and end <= context.texts.capacity);
    var first = end;
    var width: f64 = 1;
    while (first > 0) {
        const index = first - 1;
        var label_buffer: format.Buffer = undefined;
        const label = try format.entry(keys.at(index), &label_buffer);
        const cached = try drawing.text.measure(context, self.gpa, label);
        const key_width = cached.width;
        const next_width = if (first == end)
            geometry.panelWidth(key_width)
        else
            key_width + geometry.key_gap + width;

        if (first != end and next_width >= @as(f64, @floatFromInt(style.max_width)) + 1.0) break;
        measurements[index] = cached;
        first = index;
        width = next_width;
    }
    return .{
        .keys = measurements[first..end],
        .width = width,
        .height = if (first == end) 1 else geometry.panel_height,
    };
}

fn paint(self: *Renderer, cairo: *Cairo, layout: PanelLayout) !void {
    const context = &self.context;
    const style = context.style;
    const geometry = &context.geometry;
    cairo.setOperator(.clear);
    cairo.paint();
    cairo.setOperator(.source);
    context.setupCairo(cairo);

    if (layout.keys.len != 0) {
        if (style.panel_background.a != 0 or style.panel_border_color.a != 0 or geometry.panel_padding != 0) {
            const panel_border_width = style.panel_border_width;
            const panel_inset = panel_border_width / 2.0;
            drawing.primitives.roundedRectangle(
                cairo,
                panel_inset,
                panel_inset,
                layout.width - panel_border_width,
                layout.height - panel_border_width,
                geometry.panel_radius,
            );
            drawing.primitives.setSourceColor(cairo, style.panel_background);
            drawing.primitives.fillAndStroke(cairo, style.panel_border_color, panel_border_width);
        }

        const y = geometry.panel_padding + geometry.key_shadow_top;
        // Paint every shadow first so it cannot cover an adjacent keycap.
        if (style.key_shadow_color.a != 0) {
            var shadow_x = geometry.panel_padding + geometry.key_shadow_left;
            for (layout.keys) |cached| {
                try drawing.shadow.draw(cairo, context, self.gpa, cached.width, shadow_x, y);
                shadow_x += cached.width + geometry.key_gap;
            }
        }

        var x = geometry.panel_padding + geometry.key_shadow_left;
        for (layout.keys, 0..) |cached, index| {
            try drawing.background.draw(cairo, context, self.gpa, cached.width, x, y);
            drawing.text.draw(cairo, cached, x, y, if (index + 1 == layout.keys.len) style.text_highlight_color else style.text_color);
            x += cached.width + geometry.key_gap;
        }
    }
}

fn surfaceSize(value: f64) error{LayoutSizeOverflow}!i32 {
    const size = @ceil(value);
    if (!std.math.isFinite(value) or value < 0 or size > std.math.maxInt(i32)) return error.LayoutSizeOverflow;
    // Layer surface and viewport destinations require positive dimensions.
    return @max(1, @as(i32, @intFromFloat(size)));
}

fn scaledSize(logical_size: i32, scale_numerator: u32) error{BufferSizeOverflow}!i32 {
    const product = @as(u64, @intCast(logical_size)) * scale_numerator;
    return std.math.cast(i32, @max(1, (product + 60) / 120)) orelse error.BufferSizeOverflow;
}

test "surface dimensions clamp zero, round fractions and reject overflow" {
    try std.testing.expectEqual(1, try surfaceSize(0));
    try std.testing.expectEqual(101, try surfaceSize(100.25));
    try std.testing.expectEqual(std.math.maxInt(i32), try surfaceSize(std.math.maxInt(i32)));
    for ([_]f64{ -0.25, std.math.inf(f64), std.math.nan(f64), 2147483648 }) |value| {
        try std.testing.expectError(error.LayoutSizeOverflow, surfaceSize(value));
    }
    try std.testing.expectEqual(1, try scaledSize(1, 30));
    // Exact half pixels must round up, including at 115% scaling.
    try std.testing.expectEqual(58, try scaledSize(50, 138));
    try std.testing.expectEqual(152, try scaledSize(101, 180));
    try std.testing.expectEqual(202, try scaledSize(101, 240));
    try std.testing.expectError(error.BufferSizeOverflow, scaledSize(std.math.maxInt(i32), 240));
    try std.testing.expectError(error.BufferSizeOverflow, scaledSize(std.math.maxInt(i32), std.math.maxInt(u32)));
}

test "visible keys handle empty history, width limits and full capacity" {
    const gpa = std.testing.allocator;
    var style = Appearance.themed(.wisp_dark).style;
    style.key_gap = 0;
    style.panel_padding = 0;
    style.key_shadow_color.a = 0;
    // Measurement does not access Wayland objects.
    var renderer = try Renderer.init(gpa, style, undefined, undefined, .{ .scale = 120, .subpixel = .default });
    defer renderer.deinit();
    var measurements: [Model.default_capacity]*const Measurement = undefined;

    const empty = try renderer.measure(.{ .first = &.{}, .second = &.{} }, &measurements);
    try std.testing.expectEqual(0, empty.keys.len);
    try std.testing.expectEqual(@as(f64, 1), empty.width);
    try std.testing.expectEqual(@as(f64, 1), empty.height);

    const entries = [_]Model.Entry{
        .{ .modifiers = .{}, .name = "A", .text = "A" },
        .{ .modifiers = .{}, .name = "B", .text = "B" },
    };
    // Also exercise a history view split across the ring buffer boundary.
    const keys: Model.View = .{ .first = entries[0..1], .second = entries[1..] };
    const full = try renderer.measure(keys, &measurements);
    try std.testing.expectEqual(2, full.keys.len);
    const newest = full.keys[1];
    renderer.context.style.max_width = try surfaceSize(full.width);
    try std.testing.expectEqual(2, (try renderer.measure(keys, &measurements)).keys.len);
    renderer.context.style.max_width -= 1;
    const clipped = try renderer.measure(keys, &measurements);
    try std.testing.expectEqual(1, clipped.keys.len);
    try std.testing.expectEqual(newest, clipped.keys[0]);

    renderer.context.style.max_width = 1;
    const oversized = try renderer.measure(keys, &measurements);
    try std.testing.expectEqual(1, oversized.keys.len);
    try std.testing.expectEqual(newest, oversized.keys[0]);
    try std.testing.expect(oversized.width > 1);

    renderer.context.style.max_width = std.math.maxInt(i32);
    var history: [Model.default_capacity]Model.Entry = undefined;
    for (0..2) |batch| {
        for (&history, 0..) |*entry, index| entry.* = .{
            .modifiers = .{},
            .name = "A",
            .text = "A",
            .repetition = batch * history.len + index + 1,
        };
        const layout = try renderer.measure(.{ .first = &history, .second = &.{} }, &measurements);
        try std.testing.expectEqual(history.len, layout.keys.len);
        // Every retained layout must remain usable after all cache insertions.
        for (layout.keys) |measured| try std.testing.expect(measured.layout.metrics().width > 0);
    }
    renderer.context.texts.clear(gpa);
    renderer.context.texts.capacity = 1;
    try std.testing.expectEqual(1, (try renderer.measure(.{ .first = entries[1..], .second = &.{} }, &measurements)).keys.len);
}

test "cached painting matches cold painting after output settings change" {
    const gpa = std.testing.allocator;
    var style = Appearance.themed(.wisp_dark).style;
    style.key_gap = 0;
    style.panel_padding = 1.125;
    style.key_background.a = 160;
    var renderer = try Renderer.init(gpa, style, undefined, undefined, .{ .scale = 120, .subpixel = .default });
    defer renderer.deinit();
    const entries = [_]Model.Entry{
        .{ .modifiers = .{}, .name = "A", .text = "A" },
        .{ .modifiers = .{ .ctrl = .{ .left = true } }, .name = "C", .text = "C", .repetition = 12 },
    };
    const keys: Model.View = .{ .first = &entries, .second = &.{} };
    var measurements: [Model.default_capacity]*const Measurement = undefined;
    for ([_]pango.FontContext.Settings{
        .{ .scale = 150, .subpixel = .rgb },
        .{ .scale = 150, .subpixel = .bgr },
        .{ .scale = 240, .subpixel = .bgr },
    }) |settings| {
        try renderer.context.update(gpa, settings);
        try std.testing.expect(renderer.context.texts.entries == null);
        try std.testing.expect(renderer.context.bitmaps.entries == null);
        renderer.context.bitmaps.capacity = 4;
        const layout = try renderer.measure(keys, &measurements);
        const width = try scaledSize(try surfaceSize(layout.width), settings.scale);
        const height = try scaledSize(try surfaceSize(layout.height), settings.scale);
        const data = try gpa.alloc(u8, @intCast(width * height * 4));
        defer gpa.free(data);
        const expected = try gpa.alloc(u8, data.len);
        defer gpa.free(expected);
        for (0..4) |pass| {
            if (pass == 2) {
                renderer.context.bitmaps.clear(gpa);
                renderer.context.bitmaps.capacity = 1;
            }
            @memset(data, 0xa5);
            {
                const surface = try Cairo.Surface.image(data.ptr, .argb32, width, height, width * 4);
                defer surface.destroy();
                const cairo = try Cairo.create(surface);
                defer cairo.destroy();
                const view = if (pass == 3) Model.View{ .first = &.{}, .second = &.{} } else keys;
                try renderer.paint(cairo, try renderer.measure(view, &measurements));
                try std.testing.expectEqual(Cairo.Status.success, cairo.status());
            }
            switch (pass) {
                0 => {
                    try std.testing.expect(!std.mem.allEqual(u8, data, 0));
                    @memcpy(expected, data);
                },
                1, 2 => try std.testing.expectEqualSlices(u8, expected, data),
                3 => try std.testing.expect(std.mem.allEqual(u8, data, 0)),
                else => unreachable,
            }
        }
        try std.testing.expect(renderer.context.bitmaps.entries.?.next == null);
    }

    renderer.context.bitmaps.clear(gpa);
    const surface = try Cairo.Surface.createImage(1, 1);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    const layout = try renderer.measure(keys, &measurements);
    renderer.context.bitmaps.capacity = 1;
    renderer.context.bitmaps.max_bytes = 1;
    try std.testing.expectError(error.CacheBudgetExceeded, renderer.paint(cairo, layout));
}
