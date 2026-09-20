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
    busy: bool = false,

    fn listener(buffer: *wl.Buffer, event: wl.Buffer.Event, self: *Frame) void {
        _ = buffer;
        switch (event) {
            .release => self.busy = false,
        }
    }
};

context: drawing.Context,
gpa: Allocator,
shm: *wl.Shm,
target: *LayerSurface,
frames: [2]?*Frame = .{ null, null },

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
    for (self.frames) |slot| {
        if (slot) |frame| {
            frame.buffer.deinit();
            self.gpa.destroy(frame);
        }
    }
}

fn prepareFrame(self: *Renderer, width: i32, height: i32) !?*Frame {
    const crop = self.target.viewport != null;
    for (&self.frames) |*slot| {
        if (slot.*) |frame| {
            if (frame.busy) continue;
            const capacity_width = if (crop) @max(frame.buffer.width, width) else width;
            const capacity_height = if (crop) @max(frame.buffer.height, height) else height;
            if (capacity_width != frame.buffer.width or capacity_height != frame.buffer.height) {
                const buffer = try ShmBuffer.init(self.shm, capacity_width, capacity_height);
                frame.buffer.deinit();
                frame.buffer = buffer;
                frame.buffer.setListener(*Frame, Frame.listener, frame);
            }
            return frame;
        }
        // Preallocate only on first use; later allocations grow to the actual need.
        const scale = self.context.font.settings.scale;
        const reserved_width = if (crop)
            try scaledSize(try surfaceSize(@as(f64, @floatFromInt(self.context.style.max_width))), scale)
        else
            width;
        const reserved_height = if (crop) try scaledSize(try surfaceSize(self.context.geometry.panel_height), scale) else height;
        const frame = try self.gpa.create(Frame);
        errdefer self.gpa.destroy(frame);
        frame.* = .{ .buffer = try .init(self.shm, @max(width, reserved_width), @max(height, reserved_height)) };
        frame.buffer.setListener(*Frame, Frame.listener, frame);
        slot.* = frame;
        return frame;
    }
    return null;
}

pub const RenderResult = enum { submitted, deferred };

pub fn render(self: *Renderer, keys: Model.View, settings: pango.FontContext.Settings) !RenderResult {
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

    // 2. Reuse a released slot; viewports allow preallocation and growth without shrinking.
    const frame = (try self.prepareFrame(buffer_width, buffer_height)) orelse return .deferred;

    // 3. Draw only the visible area of the larger allocation.
    try self.paint(frame.buffer.cairo, layout, buffer_width, buffer_height);

    // 4. Size changed → request a new layer surface size.
    if (new_w != target.width or new_h != target.height) {
        target.setSize(new_w, new_h);
    }

    // 5. Commit.
    if (target.viewport) |viewport| {
        std.debug.assert(buffer_width <= std.math.maxInt(i24) and buffer_height <= std.math.maxInt(i24));
        viewport.setSource(.fromInt(0), .fromInt(0), .fromInt(@intCast(buffer_width)), .fromInt(@intCast(buffer_height)));
        viewport.setDestination(logical_width, logical_height);
        target.surface.setBufferScale(1);
    } else {
        target.surface.setBufferScale(@intCast(scale / 120));
    }
    target.surface.attach(frame.buffer.buffer, 0, 0);
    target.surface.damageBuffer(0, 0, buffer_width, buffer_height);
    frame.busy = true;
    target.surface.commit();
    return .submitted;
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

fn paint(self: *Renderer, cairo: *Cairo, layout: PanelLayout, buffer_width: i32, buffer_height: i32) !void {
    const context = &self.context;
    const style = context.style;
    const geometry = &context.geometry;

    cairo.save();
    defer cairo.restore();
    cairo.identityMatrix();
    cairo.rectangle(0, 0, @floatFromInt(buffer_width), @floatFromInt(buffer_height));
    cairo.clip();
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

test "busy frame slots wait for release before reuse" {
    const gpa = std.testing.allocator;
    var target: LayerSurface = .{ .surface = undefined, .layer_surface = undefined };
    var renderer = try Renderer.init(gpa, Appearance.themed(.dark).style, undefined, &target, .{ .scale = 120, .subpixel = .default });
    defer renderer.context.deinit(gpa);
    var frames = [_]Frame{
        .{ .buffer = undefined, .busy = true },
        .{ .buffer = undefined, .busy = true },
    };
    renderer.frames = .{ &frames[0], &frames[1] };
    try std.testing.expect((try renderer.prepareFrame(80, 80)) == null);
    // An idle slot with sufficient storage must not access shm or reallocate.
    frames[0].buffer.width = 80;
    frames[0].buffer.height = 80;
    Frame.listener(undefined, .release, &frames[0]);
    try std.testing.expectEqual(&frames[0], (try renderer.prepareFrame(80, 80)).?);
    try std.testing.expect(frames[1].busy);
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
                try renderer.paint(cairo, try renderer.measure(view, &measurements), width, height);
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
    try std.testing.expectError(error.CacheBudgetExceeded, renderer.paint(cairo, layout, 1, 1));
}
