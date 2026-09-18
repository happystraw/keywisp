const std = @import("std");
const Allocator = std.mem.Allocator;

const wl = @import("wayland").client.wl;

const format = @import("../format.zig");
const Model = @import("../Model.zig");
const Entry = Model.Entry;
const Appearance = @import("Appearance.zig");
const Cairo = @import("cairo.zig").Cairo;
const LayerSurface = @import("LayerSurface.zig");
const pango = @import("pango.zig");
const ShmBuffer = @import("ShmBuffer.zig");

const Renderer = @This();

const Layout = struct {
    panel_padding: i32,
    key_padding_horizontal: i32,
    key_padding_vertical: i32,
    key_gap: i32,
    key_height: i32,
    key_radius: u32,
    key_depth: i32,
    key_top_slope: f64,
    key_shadow_blur: i32,
    key_shadow_offset_x: i32,
    key_shadow_offset_y: i32,
    key_shadow_left: i32,
    key_shadow_right: i32,
    key_shadow_top: i32,
    key_shadow_bottom: i32,

    fn init(font_metrics: pango.Metrics, style: Appearance.Style) Layout {
        const text_height = font_metrics.height;
        const key_padding_horizontal = style.key_padding_horizontal orelse fraction(text_height, 4);
        const key_padding_vertical = style.key_padding_vertical orelse fraction(text_height, 4);
        const key_depth = style.key_depth orelse fraction(font_metrics.font_size, 2);
        const depth: f64 = @floatFromInt(key_depth);
        const face_inset = @min(depth * 0.35, @as(f64, @floatFromInt(key_padding_vertical)) * 0.5);
        const key_shadow_blur = style.key_shadow_blur orelse fraction(text_height, 4);
        const key_shadow_offset_x = style.key_shadow_offset_x orelse fraction(text_height, 16);
        const key_shadow_offset_y = style.key_shadow_offset_y orelse fraction(text_height, 16);
        const shadow = style.key_shadow_color.a != 0;
        return .{
            .panel_padding = style.panel_padding orelse fraction(text_height, 3),
            .key_padding_horizontal = key_padding_horizontal,
            .key_padding_vertical = key_padding_vertical,
            .key_gap = style.key_gap orelse fraction(text_height, 4),
            .key_height = text_height + key_padding_vertical * 2 + key_depth,
            .key_radius = style.key_radius orelse @intCast(fraction(font_metrics.font_size, 2)),
            .key_depth = key_depth,
            // Keep the face height while sharing the slopes in a 1:2 ratio.
            .key_top_slope = (depth + face_inset * 2.0) / 3.0,
            .key_shadow_blur = key_shadow_blur,
            .key_shadow_offset_x = key_shadow_offset_x,
            .key_shadow_offset_y = key_shadow_offset_y,
            .key_shadow_left = if (shadow) @max(0, key_shadow_blur - key_shadow_offset_x) else 0,
            .key_shadow_right = if (shadow) @max(0, key_shadow_blur + key_shadow_offset_x) else 0,
            .key_shadow_top = if (shadow) @max(0, key_shadow_blur - key_shadow_offset_y) else 0,
            .key_shadow_bottom = if (shadow) @max(0, key_shadow_blur + key_shadow_offset_y) else 0,
        };
    }

    fn keyWidth(self: Layout, text_metrics: pango.Metrics) i32 {
        return @max(self.key_height, text_metrics.width + self.key_padding_horizontal * 2);
    }

    fn panelWidth(self: Layout, content_width: i32) i32 {
        return content_width + self.panel_padding * 2 + self.key_shadow_left + self.key_shadow_right;
    }

    fn panelHeight(self: Layout) i32 {
        return self.key_height + self.panel_padding * 2 + self.key_shadow_top + self.key_shadow_bottom;
    }

    fn fraction(value: i32, divisor: i32) i32 {
        return @max(1, @divFloor(value - 1, divisor) + 1);
    }
};

pub const Options = struct {
    keys: Model.View,
    scale: i32,
    subpixel: Cairo.SubpixelOrder,
};

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

style: Appearance.Style,
shm: *wl.Shm,
target: *LayerSurface,
pending_frames: ?*Frame = null,

gpa: Allocator,

pub fn init(gpa: Allocator, style: Appearance.Style, shm: *wl.Shm, target: *LayerSurface) Renderer {
    return .{
        .gpa = gpa,
        .style = style,
        .shm = shm,
        .target = target,
    };
}

pub fn deinit(self: *Renderer) void {
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

pub const RenderError = ShmBuffer.InitError || Cairo.CreateError || format.Error || error{TextRenderingFailed};
pub fn render(self: *Renderer, options: Options) RenderError!void {
    const style = self.style;
    const target = self.target;
    const scale = if (options.scale > 0) options.scale else 1;

    // 1. Measure the content in logical pixels.
    const measure_surface = try Cairo.Surface.recording(.color_alpha, null);
    defer measure_surface.destroy();
    const measure_cairo = try Cairo.create(measure_surface);
    defer measure_cairo.destroy();
    try drawing.setup(measure_cairo, scale, options.subpixel);

    const font_metrics = pango.text.measure(measure_cairo, style.font, "yT") catch return error.TextRenderingFailed;
    const layout = Layout.init(font_metrics, style);

    const end = options.keys.len();
    const bounds: struct { first: usize, width: i32, height: i32 } = blk: {
        var first = end;
        var width: i32 = 1;
        while (first > 0) {
            const index = first - 1;
            const text_metrics = try metrics.entry(measure_cairo, style.font, options.keys.at(index));
            const key_width = layout.keyWidth(text_metrics);
            const next_width = if (first == end)
                layout.panelWidth(key_width)
            else
                key_width + layout.key_gap + width;

            if (first != end and next_width > style.max_width) break;
            first = index;
            width = next_width;
        }
        break :blk .{
            .first = first,
            .width = width,
            .height = if (first == end) 1 else layout.panelHeight(),
        };
    };

    const new_w: u32 = @intCast(bounds.width);
    const new_h: u32 = @intCast(bounds.height);
    const buffer_width = std.math.mul(i32, bounds.width, scale) catch return error.BufferSizeOverflow;
    const buffer_height = std.math.mul(i32, bounds.height, scale) catch return error.BufferSizeOverflow;

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
    const buffer_cairo = frame.buffer.cairo;
    buffer_cairo.setOperator(.clear);
    buffer_cairo.paint();
    buffer_cairo.setOperator(.source);
    try drawing.setup(buffer_cairo, scale, options.subpixel);

    if (bounds.first < end) {
        const panel_border_width: f64 = @floatFromInt(style.panel_border_width);
        const panel_inset = panel_border_width / 2.0;
        drawing.roundedRectangle(
            buffer_cairo,
            panel_inset,
            panel_inset,
            @as(f64, @floatFromInt(bounds.width)) - panel_border_width,
            @as(f64, @floatFromInt(bounds.height)) - panel_border_width,
            @floatFromInt(style.panel_radius),
        );
        drawing.setSourceColor(buffer_cairo, style.panel_background);
        drawing.fillAndStroke(buffer_cairo, style.panel_border_color, panel_border_width);

        const y = layout.panel_padding + layout.key_shadow_top;
        // Paint every shadow first so it cannot cover an adjacent keycap.
        if (style.key_shadow_color.a != 0) {
            var shadow_x = layout.panel_padding + layout.key_shadow_left;
            for (bounds.first..end) |key| {
                const text_metrics = try metrics.entry(measure_cairo, style.font, options.keys.at(key));
                const width = layout.keyWidth(text_metrics);
                drawing.shadow(buffer_cairo, shadow_x, y, width, layout, style);
                shadow_x += width + layout.key_gap;
            }
        }

        var x = layout.panel_padding + layout.key_shadow_left;
        var key = bounds.first;
        while (key < end) : (key += 1) {
            const entry = options.keys.at(key);
            var display_buf: format.Buffer = undefined;
            const display_text = try format.entry(entry, &display_buf);
            const text_metrics = pango.text.measure(measure_cairo, style.font, display_text) catch
                return error.TextRenderingFailed;
            const width = layout.keyWidth(text_metrics);
            try drawing.keycap(buffer_cairo, x, y, width, layout, style);

            drawing.setSourceColor(buffer_cairo, if (key + 1 == end) style.text_highlight_color else style.text_color);
            buffer_cairo.moveTo(
                @floatFromInt(x + @divTrunc(width - text_metrics.width, 2)),
                @as(f64, @floatFromInt(y + layout.key_padding_vertical + font_metrics.baseline - text_metrics.baseline)) +
                    (@as(f64, @floatFromInt(layout.key_depth)) - layout.key_top_slope) / 2.0,
            );
            pango.text.draw(buffer_cairo, style.font, display_text) catch return error.TextRenderingFailed;

            x += width + layout.key_gap;
        }
    }

    frame.next = self.pending_frames;
    self.pending_frames = frame;
    frame.buffer.setListener(*Frame, Frame.listener, frame);

    // 5. Commit.
    target.surface.setBufferScale(scale);
    target.surface.attach(frame.buffer.buffer, 0, 0);
    target.surface.damageBuffer(0, 0, frame.buffer.width, frame.buffer.height);
    target.surface.commit();
}

const drawing = struct {
    fn keycap(cairo: *Cairo, x: i32, y: i32, width: i32, layout: Layout, style: Appearance.Style) Cairo.CreateError!void {
        cairo.save();
        defer cairo.restore();

        const left: f64 = @floatFromInt(x);
        const top: f64 = @floatFromInt(y);
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(layout.key_height);
        const radius: f64 = @floatFromInt(layout.key_radius);

        if (layout.key_depth == 0) {
            roundedRectangle(cairo, left, top, w, h, radius);
            setSourceColor(cairo, style.key_background);
            fillAndStroke(cairo, style.key_border_color, @floatFromInt(style.key_border_width));
            return;
        }

        cairo.setOperator(.over);
        const depth: f64 = @floatFromInt(layout.key_depth);
        const inset_x = layout.key_top_slope * 1.5;
        const face_left = left + inset_x;
        const face_top = top + layout.key_top_slope;
        const face_right = left + w - inset_x;
        const face_bottom = top + h - layout.key_top_slope * 2.0;

        cairo.save();
        roundedRectangle(cairo, left, top, w, h, radius);
        cairo.clip();
        const outer_radius = @min(radius, @min(w, h) / 2.0);
        const face_radius = @min(radius * 0.8, @min(face_right - face_left, face_bottom - face_top) / 2.0);
        const Point = struct { x: f64, y: f64 };
        // Clockwise from the upper-right corner. Each arc joins two flat slopes.
        const outer = [_]Point{
            .{ .x = left + w - outer_radius, .y = top + outer_radius },
            .{ .x = left + w - outer_radius, .y = top + h - outer_radius },
            .{ .x = left + outer_radius, .y = top + h - outer_radius },
            .{ .x = left + outer_radius, .y = top + outer_radius },
        };
        const inner = [_]Point{
            .{ .x = face_right - face_radius, .y = face_top + face_radius },
            .{ .x = face_right - face_radius, .y = face_bottom - face_radius },
            .{ .x = face_left + face_radius, .y = face_bottom - face_radius },
            .{ .x = face_left + face_radius, .y = face_top + face_radius },
        };
        const directions = [_]Point{
            .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 0 },
            .{ .x = 0, .y = 1 },  .{ .x = -1, .y = 0 },
        };
        const colors = sideColors(style.key_background, layout.key_shadow_offset_x, layout.key_shadow_offset_y);
        const mesh = try Cairo.Mesh.create();
        defer mesh.destroy();
        const arc_control = 0.5522847498307936; // Cubic approximation of a quarter circle.
        for (0..4) |corner| {
            const next = (corner + 1) % 4;
            const from = directions[corner];
            const to = directions[next];
            const o = outer[corner];
            const i = inner[corner];
            if (outer_radius > 0) {
                mesh.beginPatch();
                mesh.moveTo(o.x + outer_radius * from.x, o.y + outer_radius * from.y);
                mesh.curveTo(
                    o.x + outer_radius * (from.x + arc_control * to.x),
                    o.y + outer_radius * (from.y + arc_control * to.y),
                    o.x + outer_radius * (to.x + arc_control * from.x),
                    o.y + outer_radius * (to.y + arc_control * from.y),
                    o.x + outer_radius * to.x,
                    o.y + outer_radius * to.y,
                );
                mesh.lineTo(i.x + face_radius * to.x, i.y + face_radius * to.y);
                mesh.curveTo(
                    i.x + face_radius * (to.x + arc_control * from.x),
                    i.y + face_radius * (to.y + arc_control * from.y),
                    i.x + face_radius * (from.x + arc_control * to.x),
                    i.y + face_radius * (from.y + arc_control * to.y),
                    i.x + face_radius * from.x,
                    i.y + face_radius * from.y,
                );
                mesh.lineTo(o.x + outer_radius * from.x, o.y + outer_radius * from.y);
                meshColor(mesh, 0, colors[corner]);
                meshColor(mesh, 1, colors[next]);
                meshColor(mesh, 2, colors[next]);
                meshColor(mesh, 3, colors[corner]);
                mesh.endPatch();
            }
            // Constant color between the tangent points of adjacent corners.
            mesh.beginPatch();
            mesh.moveTo(o.x + outer_radius * to.x, o.y + outer_radius * to.y);
            mesh.lineTo(outer[next].x + outer_radius * to.x, outer[next].y + outer_radius * to.y);
            mesh.lineTo(inner[next].x + face_radius * to.x, inner[next].y + face_radius * to.y);
            mesh.lineTo(i.x + face_radius * to.x, i.y + face_radius * to.y);
            mesh.lineTo(o.x + outer_radius * to.x, o.y + outer_radius * to.y);
            for (0..4) |index| meshColor(mesh, @intCast(index), colors[next]);
            mesh.endPatch();
        }
        try mesh.check();
        cairo.setSource(mesh);
        cairo.paint();

        roundedRectangle(cairo, face_left, face_top, face_right - face_left, face_bottom - face_top, radius * 0.8);
        setSourceColor(cairo, style.key_background);
        fillAndStroke(cairo, shade(style.key_background, 0.08), @min(1.0, depth / 3.0));
        cairo.restore();

        if (style.key_border_width > 0) {
            roundedRectangle(cairo, left, top, w, h, radius);
            setSourceColor(cairo, style.key_border_color);
            cairo.setLineWidth(@floatFromInt(style.key_border_width));
            cairo.stroke();
        }
    }

    fn meshColor(mesh: *Cairo.Mesh, corner: u32, color: Appearance.Color) void {
        mesh.setCornerColorRgba(
            corner,
            @as(f64, @floatFromInt(color.r)) / 255.0,
            @as(f64, @floatFromInt(color.g)) / 255.0,
            @as(f64, @floatFromInt(color.b)) / 255.0,
            @as(f64, @floatFromInt(color.a)) / 255.0,
        );
    }

    fn shadow(cairo: *Cairo, x: i32, y: i32, width: i32, layout: Layout, style: Appearance.Style) void {
        cairo.save();
        defer cairo.restore();
        // Build a soft silhouette in its own group, then composite it over the panel.
        cairo.pushGroup();
        cairo.setOperator(.source);
        const layers: usize = if (layout.key_shadow_blur > 0) 16 else 1;
        const blur: f64 = @floatFromInt(layout.key_shadow_blur);
        const left = @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(layout.key_shadow_offset_x));
        const top = @as(f64, @floatFromInt(y)) + @as(f64, @floatFromInt(layout.key_shadow_offset_y));
        for (0..layers) |layer| {
            const strength = @as(f64, @floatFromInt(layer + 1)) / @as(f64, @floatFromInt(layers));
            const spread = blur * (1.0 - strength);
            roundedRectangle(cairo, left - spread, top - spread, @as(f64, @floatFromInt(width)) + spread * 2, @as(f64, @floatFromInt(layout.key_height)) + spread * 2, @as(f64, @floatFromInt(layout.key_radius)) + spread);
            var color = style.key_shadow_color;
            color.a = @intFromFloat(@as(f64, @floatFromInt(color.a)) * strength * strength);
            setSourceColor(cairo, color);
            cairo.fill();
        }
        cairo.popGroupToSource();
        cairo.setOperator(.over);
        cairo.paint();
    }

    fn sideColors(color: Appearance.Color, shadow_x: i32, shadow_y: i32) [4]Appearance.Color {
        // Sides are clockwise: top, right, bottom, left. Light opposes the shadow.
        const vertical: usize = if (shadow_y >= 0) 0 else 2;
        const horizontal: usize = if (shadow_x >= 0) 3 else 1;
        // Equal offsets (including zero) favor vertical lighting.
        const order: [4]usize = if (@abs(shadow_y) >= @abs(shadow_x))
            .{ vertical, horizontal, (horizontal + 2) % 4, (vertical + 2) % 4 }
        else
            .{ horizontal, vertical, (vertical + 2) % 4, (horizontal + 2) % 4 };
        const dark = @as(u16, color.r) + color.g + color.b < 3 * 128;
        const amounts: [4]f64 = if (dark) .{ 0.18, 0.07, -0.12, -0.36 } else .{ -0.04, -0.13, -0.22, -0.34 };
        var colors: [4]Appearance.Color = undefined;
        for (order, amounts) |side, amount| colors[side] = shade(color, amount);
        return colors;
    }

    fn shade(color: Appearance.Color, amount: f64) Appearance.Color {
        // Blend toward white for highlights and black for shaded faces.
        const factor = 1.0 - @abs(amount);
        const highlight = @max(0, amount) * 255.0;
        return .{
            .r = @intFromFloat(@as(f64, @floatFromInt(color.r)) * factor + highlight),
            .g = @intFromFloat(@as(f64, @floatFromInt(color.g)) * factor + highlight),
            .b = @intFromFloat(@as(f64, @floatFromInt(color.b)) * factor + highlight),
            .a = color.a,
        };
    }

    fn roundedRectangle(cairo: *Cairo, x: f64, y: f64, width: f64, height: f64, radius: f64) void {
        if (radius <= 0) {
            cairo.rectangle(x, y, width, height);
            return;
        }
        const r = @min(radius, @min(width / 2.0, height / 2.0));
        const half_pi = std.math.pi / 2.0;
        cairo.newSubPath();
        cairo.arc(x + width - r, y + r, r, -half_pi, 0);
        cairo.arc(x + width - r, y + height - r, r, 0, half_pi);
        cairo.arc(x + r, y + height - r, r, half_pi, std.math.pi);
        cairo.arc(x + r, y + r, r, std.math.pi, std.math.pi + half_pi);
        cairo.closePath();
    }

    fn fillAndStroke(cairo: *Cairo, border: Appearance.Color, border_width: f64) void {
        if (border_width == 0) {
            cairo.fill();
            return;
        }
        cairo.fillPreserve();
        setSourceColor(cairo, border);
        cairo.setLineWidth(border_width);
        cairo.stroke();
    }

    fn setSourceColor(cairo: *Cairo, color: Appearance.Color) void {
        cairo.setSourceRgba(
            @as(f64, @floatFromInt(color.r)) / 255.0,
            @as(f64, @floatFromInt(color.g)) / 255.0,
            @as(f64, @floatFromInt(color.b)) / 255.0,
            @as(f64, @floatFromInt(color.a)) / 255.0,
        );
    }

    fn setup(
        cairo: *Cairo,
        scale: i32,
        subpixel: Cairo.SubpixelOrder,
    ) !void {
        const factor: f64 = @floatFromInt(scale);
        cairo.scale(factor, factor);
        cairo.setAntialias(.best);
        const fo = try Cairo.FontOptions.create();
        defer fo.destroy();
        fo.setHintStyle(.full);
        fo.setAntialias(.subpixel);
        fo.setSubpixelOrder(subpixel);
        cairo.setFontOptions(fo);
    }
};

const metrics = struct {
    fn entry(
        cairo: *Cairo,
        font: [:0]const u8,
        value: *const Entry,
    ) (format.Error || error{TextRenderingFailed})!pango.Metrics {
        var display_buf: format.Buffer = undefined;
        const display_text = try format.entry(value, &display_buf);
        return pango.text.measure(cairo, font, display_text) catch error.TextRenderingFailed;
    }
};

test "keycap side brightness follows the opposite shadow direction" {
    const cases = [_]struct { x: i32, y: i32, brightest_first: [4]usize }{
        .{ .x = 1, .y = 2, .brightest_first = .{ 0, 3, 1, 2 } },
        .{ .x = 2, .y = 1, .brightest_first = .{ 3, 0, 2, 1 } },
        .{ .x = -1, .y = 2, .brightest_first = .{ 0, 1, 3, 2 } },
        .{ .x = -2, .y = 1, .brightest_first = .{ 1, 0, 2, 3 } },
        .{ .x = -1, .y = -2, .brightest_first = .{ 2, 1, 3, 0 } },
        .{ .x = -2, .y = -1, .brightest_first = .{ 1, 2, 0, 3 } },
        .{ .x = 1, .y = -2, .brightest_first = .{ 2, 3, 1, 0 } },
        .{ .x = 2, .y = -1, .brightest_first = .{ 3, 2, 0, 1 } },
        .{ .x = 0, .y = 1, .brightest_first = .{ 0, 3, 1, 2 } },
        .{ .x = 0, .y = -1, .brightest_first = .{ 2, 3, 1, 0 } },
        .{ .x = 1, .y = 0, .brightest_first = .{ 3, 0, 2, 1 } },
        .{ .x = -1, .y = 0, .brightest_first = .{ 1, 0, 2, 3 } },
        .{ .x = 1, .y = 1, .brightest_first = .{ 0, 3, 1, 2 } },
        .{ .x = 0, .y = 0, .brightest_first = .{ 0, 3, 1, 2 } },
    };
    for ([_]Appearance.Theme{ .wisp_dark, .wisp_light }) |theme| {
        const background = Appearance.themed(theme).style.key_background;
        for (cases) |case| {
            const colors = drawing.sideColors(background, case.x, case.y);
            const order = case.brightest_first;
            for (order[0..3], order[1..4]) |brighter, darker| {
                try std.testing.expect(colors[brighter].r > colors[darker].r);
                try std.testing.expect(colors[brighter].g > colors[darker].g);
                try std.testing.expect(colors[brighter].b > colors[darker].b);
            }
            for (colors) |color| try std.testing.expectEqual(background.a, color.a);
        }
    }
}
