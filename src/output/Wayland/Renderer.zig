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

    fn init(text_height: i32, style: Appearance.Style) Layout {
        const key_padding_vertical = style.key_padding_vertical orelse fraction(text_height, 4);
        return .{
            .panel_padding = style.panel_padding orelse fraction(text_height, 3),
            .key_padding_horizontal = style.key_padding_horizontal orelse fraction(text_height, 2),
            .key_padding_vertical = key_padding_vertical,
            .key_gap = style.key_gap orelse fraction(text_height, 4),
            .key_height = text_height + key_padding_vertical * 2,
        };
    }

    fn keyWidth(self: Layout, text_metrics: pango.Metrics) i32 {
        return @max(self.key_height, text_metrics.width + self.key_padding_horizontal * 2);
    }

    fn panelWidth(self: Layout, content_width: i32) i32 {
        return content_width + self.panel_padding * 2;
    }

    fn panelHeight(self: Layout) i32 {
        return self.key_height + self.panel_padding * 2;
    }

    fn fraction(value: i32, divisor: i32) i32 {
        return @max(1, @divTrunc(value + divisor - 1, divisor));
    }
};

pub const RenderError = Allocator.Error || ShmBuffer.InitError || format.Error || error{ CairoFailed, TextFailed };

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

pub fn render(self: *Renderer, options: Options) RenderError!void {
    const style = self.style;
    const target = self.target;
    const scale = if (options.scale > 0) options.scale else 1;

    // 1. Measure the content in logical pixels.
    const measure_surface = Cairo.Surface.recording(.color_alpha, null) catch return error.CairoFailed;
    defer measure_surface.destroy();
    const measure_cairo = Cairo.create(measure_surface) catch return error.CairoFailed;
    defer measure_cairo.destroy();
    try drawing.setup(measure_cairo, scale, options.subpixel);

    const font_metrics = pango.text.measure(measure_cairo, style.font, "yT") catch return error.TextFailed;
    const layout = Layout.init(font_metrics.height, style);

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
    const buffer_width = std.math.mul(i32, bounds.width, scale) catch return error.BufferFailed;
    const buffer_height = std.math.mul(i32, bounds.height, scale) catch return error.BufferFailed;

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

        var x = layout.panel_padding;
        var key = bounds.first;
        while (key < end) : (key += 1) {
            const entry = options.keys.at(key);
            var display_buf: format.Buffer = undefined;
            const display_text = try format.entry(entry, &display_buf);
            const text_metrics = pango.text.measure(measure_cairo, style.font, display_text) catch return error.TextFailed;
            const width = layout.keyWidth(text_metrics);
            const y = layout.panel_padding;

            drawing.roundedRectangle(
                buffer_cairo,
                @floatFromInt(x),
                @floatFromInt(y),
                @floatFromInt(width),
                @floatFromInt(layout.key_height),
                @floatFromInt(style.key_radius),
            );
            drawing.setSourceColor(buffer_cairo, style.key_background);
            drawing.fillAndStroke(buffer_cairo, style.key_border_color, @floatFromInt(style.key_border_width));

            drawing.setSourceColor(buffer_cairo, if (key + 1 == end) style.text_color else style.history_color);
            buffer_cairo.moveTo(
                @floatFromInt(x + @divTrunc(width - text_metrics.width, 2)),
                @floatFromInt(y + layout.key_padding_vertical + font_metrics.baseline - text_metrics.baseline),
            );
            pango.text.draw(buffer_cairo, style.font, display_text) catch return error.TextFailed;

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

    fn setup(cairo: *Cairo, scale: i32, subpixel: Cairo.SubpixelOrder) error{CairoFailed}!void {
        const factor: f64 = @floatFromInt(scale);
        cairo.scale(factor, factor);
        cairo.setAntialias(.best);
        const fo = Cairo.FontOptions.create() catch return error.CairoFailed;
        defer fo.destroy();
        fo.setHintStyle(.full);
        fo.setAntialias(.subpixel);
        fo.setSubpixelOrder(subpixel);
        cairo.setFontOptions(fo);
    }
};

const metrics = struct {
    fn entry(cairo: *Cairo, font: [:0]const u8, value: *const Entry) (format.Error || error{TextFailed})!pango.Metrics {
        var display_buf: format.Buffer = undefined;
        const display_text = try format.entry(value, &display_buf);
        return pango.text.measure(cairo, font, display_text) catch error.TextFailed;
    }
};
