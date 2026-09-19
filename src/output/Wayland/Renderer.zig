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
    // Rendering context
    scale: u32,
    subpixel: Cairo.SubpixelOrder,

    // Panel
    panel_radius: f64,
    panel_padding: f64,
    panel_horizontal_space: f64,
    panel_height: f64,

    // Keycap
    key_gap: f64,
    key_height: f64,
    key_min_width: f64,
    key_side_width: f64,
    key_depth: Appearance.Depth,
    key_radius: f64,

    // Keycap face
    key_padding_horizontal: f64,
    key_face_radius: f64,
    key_face_border_width: f64,
    key_text_baseline: f64,

    // Shadow
    key_shadow_blur: f64,
    key_shadow_offset_x: f64,
    key_shadow_offset_y: f64,
    key_shadow_left: f64,
    key_shadow_top: f64,

    fn init(cairo: *Cairo, style: Appearance.Style, scale: u32, subpixel: Cairo.SubpixelOrder) error{TextRenderingFailed}!Layout {
        // One keycap, not to scale (text bounds are Pango logical bounds):
        //
        //       <----------- keycapWidth(text) ----------->
        //       +----------------------------------------+  ^
        //       |             key_depth.top              |  |
        //       |    +------------------------------+    |  |
        //       |    |              Pv              |    |  |
        //       | L  | Ph  +------------------+  Ph | R  |  | key_height
        //       |    |     |       text       |     |    |  |
        //       |    |     +------------------+     |    |  |
        //       |    |              Pv              |    |  |
        //       |    +------------ face ------------+    |  |
        //       |            key_depth.bottom            |  |
        //       +----------------------------------------+  v
        //
        // L/R = key_depth.left/right; key_side_width = L + R.
        // Ph/Pv = horizontal/vertical padding around the reference alphabet line.
        // Labels share F's baseline within that centered line, including fallback glyphs.
        // Automatic horizontal padding keeps a square minimum sized from A-Z.
        // Explicit horizontal padding makes width follow the label and height independent.
        // Each depth component is a slope size in logical pixels.
        //
        // Panel placement (shadow space is reserved outside the keycaps):
        // | panel_padding | shadow_left | key | key_gap | key | shadow_right | panel_padding |
        // First key x = panel_padding + key_shadow_left.
        // Key y       = panel_padding + key_shadow_top.
        // Panel height = panel_padding + shadow_top + key_height + shadow_bottom + panel_padding.
        const font_metrics = pango.text.measureAlphabet(cairo, style.font) catch return error.TextRenderingFailed;

        const text_height: f64 = @floatFromInt(font_metrics.height);
        const font_size: f64 = @floatFromInt(font_metrics.font_size);

        const key_padding_horizontal = style.key_padding_horizontal orelse fraction(text_height, 4);
        const key_padding_vertical = style.key_padding_vertical orelse fraction(text_height, 7);
        const key_gap = style.key_gap orelse fraction(text_height, 4);
        const key_face_height = text_height + key_padding_vertical * 2;
        const key_depth = style.key_depth orelse blk: {
            const depth = @round(key_face_height / 3.0);
            const top = depth / 3.0;
            const side = @ceil(depth * 1.2) / 2.0;
            break :blk Appearance.Depth{ .top = top, .right = side, .bottom = top * 2.0, .left = side };
        };
        const key_side_width = key_depth.left + key_depth.right;
        const key_height = if (style.key_padding_horizontal == null) @max(
            key_face_height + key_depth.top + key_depth.bottom,
            @as(f64, @floatFromInt(font_metrics.width)) + key_padding_horizontal * 2 + key_side_width,
        ) else key_face_height + key_depth.top + key_depth.bottom;
        const key_min_width = if (style.key_padding_horizontal == null) key_height else 0;
        const key_radius = style.key_radius orelse font_size * 0.5;
        const key_face_radius = key_radius * 0.8;
        const key_face_border_width = @min(1.0, @max(key_depth.top, key_depth.right, key_depth.bottom, key_depth.left));
        const key_text_baseline = key_depth.top + (key_height - key_depth.top - key_depth.bottom - text_height) / 2.0 + font_metrics.baseline;

        const shadow = style.key_shadow_color.a != 0;
        const key_shadow_blur: f64 = style.key_shadow_blur orelse @min(key_height / 7.0, key_gap / 2.0);
        const key_shadow_offset_x: f64 = style.key_shadow_offset_x orelse key_height / 28.0;
        const key_shadow_offset_y: f64 = style.key_shadow_offset_y orelse key_height / 28.0;
        const key_shadow_left: f64 = if (shadow) @max(0, key_shadow_blur - key_shadow_offset_x) else 0;
        const key_shadow_right: f64 = if (shadow) @max(0, key_shadow_blur + key_shadow_offset_x) else 0;
        const key_shadow_top: f64 = if (shadow) @max(0, key_shadow_blur - key_shadow_offset_y) else 0;
        const key_shadow_bottom: f64 = if (shadow) @max(0, key_shadow_blur + key_shadow_offset_y) else 0;

        const panel_radius = style.panel_radius orelse font_size * 0.75;
        const panel_padding = style.panel_padding orelse fraction(text_height, 3);
        const panel_horizontal_space = panel_padding * 2 + key_shadow_left + key_shadow_right;
        const panel_height = key_height + panel_padding * 2 + key_shadow_top + key_shadow_bottom;

        return .{
            .scale = scale,
            .subpixel = subpixel,

            .panel_radius = panel_radius,
            .panel_padding = panel_padding,
            .panel_horizontal_space = panel_horizontal_space,
            .panel_height = panel_height,

            .key_gap = key_gap,
            .key_height = key_height,
            .key_min_width = key_min_width,
            .key_side_width = key_side_width,
            .key_depth = key_depth,
            .key_radius = key_radius,

            .key_padding_horizontal = key_padding_horizontal,
            .key_face_radius = key_face_radius,
            .key_face_border_width = key_face_border_width,
            .key_text_baseline = key_text_baseline,

            .key_shadow_blur = key_shadow_blur,
            .key_shadow_offset_x = key_shadow_offset_x,
            .key_shadow_offset_y = key_shadow_offset_y,
            .key_shadow_left = key_shadow_left,
            .key_shadow_top = key_shadow_top,
        };
    }

    fn keycapWidth(self: Layout, text_metrics: pango.Metrics) f64 {
        return @max(self.key_min_width, @as(f64, @floatFromInt(text_metrics.width)) + self.key_padding_horizontal * 2 + self.key_side_width);
    }

    fn textPosition(self: Layout, width: f64, text_metrics: pango.Metrics) struct { x: f64, y: f64 } {
        return .{
            .x = self.key_depth.left + ((width - @as(f64, @floatFromInt(text_metrics.width))) - self.key_depth.left - self.key_depth.right) / 2.0,
            .y = self.key_text_baseline - text_metrics.baseline,
        };
    }

    fn panelWidth(self: Layout, content_width: f64) f64 {
        return content_width + self.panel_horizontal_space;
    }

    fn pixelSize(value: f64) error{LayoutSizeOverflow}!i32 {
        if (!std.math.isFinite(value) or value < 0 or @ceil(value) > std.math.maxInt(i32)) return error.LayoutSizeOverflow;
        // Layer surface and viewport destinations require positive dimensions.
        return @max(1, @as(i32, @intFromFloat(@ceil(value))));
    }

    fn fraction(value: f64, divisor: f64) f64 {
        return @max(1, @ceil(value / divisor));
    }
};

pub const Options = struct {
    keys: Model.View,
    scale: u32,
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
measure_surface: *Cairo.Surface,
measure_cairo: *Cairo,
layout: Layout,
pending_frames: ?*Frame = null,

gpa: Allocator,

pub const InitError = Cairo.CreateError || error{TextRenderingFailed};
pub fn init(gpa: Allocator, style: Appearance.Style, shm: *wl.Shm, target: *LayerSurface, scale: u32, subpixel: Cairo.SubpixelOrder) InitError!Renderer {
    const effective_scale = if (scale > 0) scale else 120;
    const measure_surface = try Cairo.Surface.recording(.color_alpha, null);
    errdefer measure_surface.destroy();
    const measure_cairo = try Cairo.create(measure_surface);
    errdefer measure_cairo.destroy();
    try drawing.setup(measure_cairo, effective_scale, subpixel);

    const layout = try Layout.init(measure_cairo, style, effective_scale, subpixel);

    return .{
        .gpa = gpa,
        .style = style,
        .shm = shm,
        .target = target,
        .measure_surface = measure_surface,
        .measure_cairo = measure_cairo,
        .layout = layout,
    };
}

pub fn deinit(self: *Renderer) void {
    self.measure_cairo.destroy();
    self.measure_surface.destroy();
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

pub const RenderError = ShmBuffer.InitError || Cairo.CreateError || format.Error || error{ TextRenderingFailed, LayoutSizeOverflow };
pub fn render(self: *Renderer, options: Options) RenderError!void {
    const style = self.style;
    const target = self.target;
    const scale = if (options.scale > 0) options.scale else 120;

    // 1. Measure the content in logical pixels.
    const measure_cairo = self.measure_cairo;
    if (self.layout.scale != scale or self.layout.subpixel != options.subpixel) {
        try drawing.setup(measure_cairo, scale, options.subpixel);
        self.layout = try Layout.init(measure_cairo, style, scale, options.subpixel);
    }

    const layout = self.layout;

    const end = options.keys.len();
    const bounds: struct { first: usize, width: f64, height: f64 } = blk: {
        var first = end;
        var width: f64 = 1;
        while (first > 0) {
            const index = first - 1;
            const text_metrics = try metrics.entry(measure_cairo, style.font, options.keys.at(index));
            const key_width = layout.keycapWidth(text_metrics);
            const next_width = if (first == end)
                layout.panelWidth(key_width)
            else
                key_width + layout.key_gap + width;

            if (first != end and next_width >= @as(f64, @floatFromInt(style.max_width)) + 1.0) break;
            first = index;
            width = next_width;
        }
        break :blk .{
            .first = first,
            .width = width,
            .height = if (first == end) 1 else layout.panel_height,
        };
    };

    const logical_width = try Layout.pixelSize(bounds.width);
    const logical_height = try Layout.pixelSize(bounds.height);
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
    const buffer_cairo = frame.buffer.cairo;
    buffer_cairo.setOperator(.clear);
    buffer_cairo.paint();
    buffer_cairo.setOperator(.source);
    try drawing.setup(buffer_cairo, scale, options.subpixel);

    if (bounds.first < end) {
        const panel_border_width = style.panel_border_width;
        const panel_inset = panel_border_width / 2.0;
        drawing.roundedRectangle(
            buffer_cairo,
            panel_inset,
            panel_inset,
            bounds.width - panel_border_width,
            bounds.height - panel_border_width,
            layout.panel_radius,
        );
        drawing.setSourceColor(buffer_cairo, style.panel_background);
        drawing.fillAndStroke(buffer_cairo, style.panel_border_color, panel_border_width);

        const y = layout.panel_padding + layout.key_shadow_top;
        // Paint every shadow first so it cannot cover an adjacent keycap.
        if (style.key_shadow_color.a != 0) {
            var shadow_x = layout.panel_padding + layout.key_shadow_left;
            for (bounds.first..end) |key| {
                const text_metrics = try metrics.entry(measure_cairo, style.font, options.keys.at(key));
                const width = layout.keycapWidth(text_metrics);
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
            const width = layout.keycapWidth(text_metrics);
            try drawing.keycap(buffer_cairo, x, y, width, layout, style);

            drawing.setSourceColor(buffer_cairo, if (key + 1 == end) style.text_highlight_color else style.text_color);
            const text_position = layout.textPosition(width, text_metrics);
            buffer_cairo.moveTo(
                x + text_position.x,
                y + text_position.y,
            );
            pango.text.draw(buffer_cairo, style.font, display_text) catch return error.TextRenderingFailed;

            x += width + layout.key_gap;
        }
    }

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

fn scaledSize(logical_size: i32, scale_numerator: u32) error{BufferSizeOverflow}!i32 {
    const product = @as(u64, @intCast(logical_size)) * scale_numerator;
    return std.math.cast(i32, @max(1, (product + 60) / 120)) orelse error.BufferSizeOverflow;
}

const drawing = struct {
    fn keycap(cairo: *Cairo, x: f64, y: f64, width: f64, layout: Layout, style: Appearance.Style) Cairo.CreateError!void {
        cairo.save();
        defer cairo.restore();

        cairo.pushGroup();
        errdefer cairo.popGroupToSource();
        cairo.setOperator(.source);
        try paintKeycap(cairo, x, y, width, layout, style);
        cairo.popGroupToSource();

        cairo.setOperator(.over);
        cairo.paint();
    }

    fn paintKeycap(cairo: *Cairo, x: f64, y: f64, width: f64, layout: Layout, style: Appearance.Style) Cairo.CreateError!void {
        if (std.meta.eql(layout.key_depth, Appearance.Depth.uniform(0))) {
            roundedRectangle(cairo, x, y, width, layout.key_height, layout.key_radius);
            setSourceColor(cairo, style.key_background);
            fillAndStroke(cairo, style.key_border_color, style.key_border_width);
            return;
        }

        const face_left = x + layout.key_depth.left;
        const face_top = y + layout.key_depth.top;
        const face_right = x + width - layout.key_depth.right;
        const face_bottom = y + layout.key_height - layout.key_depth.bottom;

        cairo.save();
        errdefer cairo.restore();
        roundedRectangle(cairo, x, y, width, layout.key_height, layout.key_radius);
        cairo.clip();
        const outer_radius = @min(layout.key_radius, @min(width, layout.key_height) / 2.0);
        const face_radius = @min(layout.key_face_radius, @min(face_right - face_left, face_bottom - face_top) / 2.0);
        const Point = struct { x: f64, y: f64 };
        // Clockwise from the upper-right corner. Each arc joins two flat slopes.
        const outer = [_]Point{
            .{ .x = x + width - outer_radius, .y = y + outer_radius },
            .{ .x = x + width - outer_radius, .y = y + layout.key_height - outer_radius },
            .{ .x = x + outer_radius, .y = y + layout.key_height - outer_radius },
            .{ .x = x + outer_radius, .y = y + outer_radius },
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

        roundedRectangle(cairo, face_left, face_top, face_right - face_left, face_bottom - face_top, layout.key_face_radius);
        setSourceColor(cairo, style.key_background);
        fillAndStroke(cairo, shade(style.key_background, 0.08), layout.key_face_border_width);
        cairo.restore();

        if (style.key_border_width > 0) {
            roundedRectangle(cairo, x, y, width, layout.key_height, layout.key_radius);
            setSourceColor(cairo, style.key_border_color);
            cairo.setLineWidth(style.key_border_width);
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

    fn shadow(cairo: *Cairo, x: f64, y: f64, width: f64, layout: Layout, style: Appearance.Style) void {
        cairo.save();
        defer cairo.restore();
        // Build a soft silhouette in its own group, then composite it over the panel.
        cairo.pushGroup();
        cairo.setOperator(.source);
        const layers: usize = if (layout.key_shadow_blur > 0) 16 else 1;
        const blur = layout.key_shadow_blur;
        const left = x + layout.key_shadow_offset_x;
        const top = y + layout.key_shadow_offset_y;
        for (0..layers) |layer| {
            const strength = @as(f64, @floatFromInt(layer + 1)) / @as(f64, @floatFromInt(layers));
            const spread = blur * (1.0 - strength);
            roundedRectangle(cairo, left - spread, top - spread, width + spread * 2, layout.key_height + spread * 2, layout.key_radius + spread);
            var color = style.key_shadow_color;
            color.a = @intFromFloat(@as(f64, @floatFromInt(color.a)) * strength * strength);
            setSourceColor(cairo, color);
            cairo.fill();
        }
        cairo.popGroupToSource();
        cairo.setOperator(.over);
        cairo.paint();
    }

    fn sideColors(color: Appearance.Color, shadow_x: f64, shadow_y: f64) [4]Appearance.Color {
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
        scale: u32,
        subpixel: Cairo.SubpixelOrder,
    ) !void {
        cairo.identityMatrix();
        const factor = @as(f64, @floatFromInt(scale)) / 120.0;
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
        return pango.text.measure(cairo, font, display_text) catch return error.TextRenderingFailed;
    }
};

test "surface dimensions clamp zero, round fractions and reject overflow" {
    try std.testing.expectEqual(1, try Layout.pixelSize(0));
    try std.testing.expectEqual(101, try Layout.pixelSize(100.25));
    try std.testing.expectEqual(std.math.maxInt(i32), try Layout.pixelSize(std.math.maxInt(i32)));
    for ([_]f64{ -1, std.math.inf(f64), std.math.nan(f64), 2147483648 }) |value| {
        try std.testing.expectError(error.LayoutSizeOverflow, Layout.pixelSize(value));
    }
    try std.testing.expectEqual(1, try scaledSize(1, 30));
    // Exact half pixels must round up, including at 115% scaling.
    try std.testing.expectEqual(58, try scaledSize(50, 138));
    try std.testing.expectEqual(152, try scaledSize(101, 180));
    try std.testing.expectEqual(202, try scaledSize(101, 240));
    try std.testing.expectError(error.BufferSizeOverflow, scaledSize(std.math.maxInt(i32), 240));
    try std.testing.expectError(error.BufferSizeOverflow, scaledSize(std.math.maxInt(i32), std.math.maxInt(u32)));
}

test "fractional geometry survives until surface allocation" {
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    var style = Appearance.themed(.wisp_dark).style;
    style.key_depth = .{ .top = 0.25, .right = 1.125, .bottom = 0.5, .left = 2.25 };
    style.key_padding_horizontal = 3.125;
    style.key_padding_vertical = 2.25;
    style.key_gap = 2.5;
    style.panel_padding = 1.125;
    style.key_shadow_blur = 1.25;
    style.key_shadow_offset_x = -0.5;
    style.key_shadow_offset_y = 0.75;
    const layout = try Layout.init(cairo, style, 120, .default);
    const text = try pango.text.measure(cairo, style.font, "F");
    const width = layout.keycapWidth(text);
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(text.width)) + 9.625, width, 0.000001);
    try std.testing.expectEqual(1.75, layout.key_shadow_left);
    try std.testing.expectEqual(0.5, layout.key_shadow_top);
    try std.testing.expectEqual(layout.key_height + 4.75, layout.panel_height);
    const panel_width = layout.panelWidth(width * 3 + layout.key_gap * 2);
    try std.testing.expectApproxEqAbs(width * 3 + 9.75, panel_width, 0.000001);
    const pixels = try Layout.pixelSize(panel_width);
    try std.testing.expect(@as(f64, @floatFromInt(pixels)) >= panel_width);
    try std.testing.expect(@as(f64, @floatFromInt(pixels)) < panel_width + 1);
    var shifted = text;
    shifted.height += 17;
    shifted.baseline += 0.125;
    try std.testing.expectApproxEqAbs(layout.textPosition(width, text).y - 0.125, layout.textPosition(width, shifted).y, 0.000001);
}
