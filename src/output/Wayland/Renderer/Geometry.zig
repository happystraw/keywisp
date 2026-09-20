const Appearance = @import("../Appearance.zig");
const pango = @import("../pango.zig");

const Geometry = @This();

// Panel
panel_radius: f64,
panel_padding: f64,
panel_horizontal_space: f64,
panel_height: f64,

// Keycap
key_gap: f64,
key_height: f64,
key_min_width: f64,
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

pub fn init(font_metrics: pango.Layout.Metrics, font_size: f64, style: *const Appearance.Style) Geometry {
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
    const text_height: f64 = @floatFromInt(font_metrics.height);

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
        .panel_radius = panel_radius,
        .panel_padding = panel_padding,
        .panel_horizontal_space = panel_horizontal_space,
        .panel_height = panel_height,

        .key_gap = key_gap,
        .key_height = key_height,
        .key_min_width = key_min_width,
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

pub fn keycapWidth(self: *const Geometry, text_width: i32) f64 {
    return @max(self.key_min_width, @as(f64, @floatFromInt(text_width)) + self.key_padding_horizontal * 2 + (self.key_depth.left + self.key_depth.right));
}

pub fn textPosition(self: *const Geometry, width: f64, text_metrics: pango.Layout.Metrics) struct { x: f64, y: f64 } {
    return .{
        .x = self.key_depth.left + ((width - @as(f64, @floatFromInt(text_metrics.width))) - self.key_depth.left - self.key_depth.right) / 2.0,
        .y = self.key_text_baseline - text_metrics.baseline,
    };
}

pub fn panelWidth(self: *const Geometry, content_width: f64) f64 {
    return content_width + self.panel_horizontal_space;
}

fn fraction(value: f64, divisor: f64) f64 {
    return @max(1, @ceil(value / divisor));
}
