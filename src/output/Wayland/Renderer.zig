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
const KeyCache = @import("KeyCache.zig");
const Bitmap = KeyCache.Bitmap;

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
    busy: bool = false,

    fn listener(buffer: *wl.Buffer, event: wl.Buffer.Event, self: *Frame) void {
        _ = buffer;
        switch (event) {
            .release => self.busy = false,
        }
    }
};

style: Appearance.Style,
shm: *wl.Shm,
target: *LayerSurface,
measure_surface: *Cairo.Surface,
measure_cairo: *Cairo,
layout: Layout,
cache: KeyCache = .{},
active: KeyCache = .{},
// Heap-owned slots keep listener addresses stable when Renderer moves.
frames: [2]?*Frame = .{ null, null },

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
    self.cache.clear(self.gpa);
    self.active.clear(self.gpa);
    self.measure_cairo.destroy();
    self.measure_surface.destroy();
    for (self.frames) |slot| {
        if (slot) |frame| {
            frame.buffer.deinit();
            self.gpa.destroy(frame);
        }
    }
}

pub fn canRender(self: *const Renderer) bool {
    for (self.frames) |slot| {
        if (slot == null or !slot.?.busy) return true;
    }
    return false;
}

fn acquireFrame(self: *Renderer, width: i32, height: i32) RenderError!?*Frame {
    for (self.frames) |slot| {
        if (slot) |frame| {
            if (!frame.busy and frame.buffer.width == width and frame.buffer.height == height) return frame;
        }
    }
    for (&self.frames) |*slot| {
        if (slot.*) |frame| {
            if (frame.busy) continue;
            // Allocate first so a failed resize leaves the previous slot intact.
            const buffer = try ShmBuffer.init(self.shm, width, height, .argb8888);
            frame.buffer.deinit();
            frame.buffer = buffer;
            frame.buffer.setListener(*Frame, Frame.listener, frame);
            return frame;
        }
        const frame = try self.gpa.create(Frame);
        errdefer self.gpa.destroy(frame);
        frame.* = .{ .buffer = try ShmBuffer.init(self.shm, width, height, .argb8888) };
        frame.buffer.setListener(*Frame, Frame.listener, frame);
        slot.* = frame;
        return frame;
    }
    return null;
}

pub const RenderResult = enum { submitted, deferred };

pub const RenderError = ShmBuffer.InitError || Cairo.CreateError || format.Error || error{ TextRenderingFailed, LayoutSizeOverflow };
pub fn render(self: *Renderer, options: Options) RenderError!RenderResult {
    if (!self.canRender()) return .deferred;
    const style = self.style;
    const target = self.target;
    const scale = if (options.scale > 0) options.scale else 120;

    try self.updateLayout(scale, options.subpixel);
    defer {
        self.active.trim(self.gpa, 0);
        self.trimHistory();
    }
    const layout = self.layout;
    const end = options.keys.len();
    const active = try self.prepareKeys(options.keys);
    const bounds: struct { first: usize, width: f64, height: f64 } = blk: {
        var first = end;
        var width: f64 = 1;
        while (first > 0) {
            const index = first - 1;
            const cached = if (index + 1 == end) active.? else try self.cachedKey(options.keys.at(index), null);
            const key_width = cached.width;
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

    // 3. Reuse a released buffer; resize only an idle slot.
    const frame = (try self.acquireFrame(buffer_width, buffer_height)).?;

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
                const phase = KeyCache.Phase.at(shadow_x, y, scale);
                const cached = if (key + 1 == end) active.? else try self.cachedKey(options.keys.at(key), phase);
                if (key + 1 == end) cached.setPhase(phase);
                try self.paintShadow(buffer_cairo, cached, shadow_x, y);
                shadow_x += cached.width + layout.key_gap;
                self.trimHistory();
            }
        }

        var x = layout.panel_padding + layout.key_shadow_left;
        var key = bounds.first;
        while (key < end) : (key += 1) {
            const phase = KeyCache.Phase.at(x, y, scale);
            const cached = if (key + 1 == end) active.? else try self.cachedKey(options.keys.at(key), phase);
            if (key + 1 == end) {
                cached.setPhase(phase);
                try self.paintActive(buffer_cairo, cached, x, y);
            } else {
                try self.paintKey(buffer_cairo, cached, x, y);
            }
            x += cached.width + layout.key_gap;
            self.trimHistory();
        }
    }

    // 5. Commit.
    if (target.preferred_scale != null) {
        target.viewport.?.setDestination(logical_width, logical_height);
        target.surface.setBufferScale(1);
    } else {
        target.surface.setBufferScale(@intCast(scale / 120));
    }
    // An empty transparent surface must not leave a callback blocking its next show.
    if (end > 0) try target.requestFrame();
    target.surface.attach(frame.buffer.buffer, 0, 0);
    target.surface.damageBuffer(0, 0, frame.buffer.width, frame.buffer.height);
    frame.busy = true;
    target.surface.commit();
    return .submitted;
}

fn updateLayout(self: *Renderer, scale: u32, subpixel: Cairo.SubpixelOrder) RenderError!void {
    if (self.layout.scale == scale and self.layout.subpixel == subpixel) return;
    try drawing.setup(self.measure_cairo, scale, subpixel);
    const layout = try Layout.init(self.measure_cairo, self.style, scale, subpixel);
    self.cache.clear(self.gpa);
    self.active.clear(self.gpa);
    self.layout = layout;
}

fn trimHistory(self: *Renderer) void {
    const active_bytes = if (self.active.head) |key| key.bytes() else 0;
    self.cache.trim(self.gpa, active_bytes);
}

fn prepareKeys(self: *Renderer, keys: Model.View) RenderError!?*KeyCache.Key {
    const end = keys.len();
    if (end == 0) {
        self.active.clear(self.gpa);
        return null;
    }
    // Preserve the former active key's geometry before replacing its label.
    if (end > 1) _ = try self.cachedKey(keys.at(end - 2), null);
    var buffer: format.Buffer = undefined;
    const text = try format.entry(keys.at(end - 1), &buffer);
    if (self.active.find(text, null)) |key| return key;
    const text_metrics = pango.text.measure(self.measure_cairo, self.style.font, text) catch
        return error.TextRenderingFailed;
    var next: KeyCache = .{};
    const phase = if (self.active.head) |previous| previous.phase else KeyCache.Phase{};
    const key = try next.insert(self.gpa, text, text_metrics, self.layout.keycapWidth(text_metrics), phase);
    self.active.shareShapes(key);
    self.cache.shareShapes(key);
    self.active.clear(self.gpa);
    self.active = next;
    return key;
}

fn cachedKey(self: *Renderer, entry: *const Entry, phase: ?KeyCache.Phase) RenderError!*KeyCache.Key {
    var buffer: format.Buffer = undefined;
    const text = try format.entry(entry, &buffer);
    if (self.cache.find(text, phase)) |cached| return cached;
    // Placement variants share measurements, but never raster images at another phase.
    const measured = self.cache.find(text, null) orelse self.active.find(text, null);
    const text_metrics = if (measured) |key| key.metrics else pango.text.measure(self.measure_cairo, self.style.font, text) catch
        return error.TextRenderingFailed;
    const origin = phase orelse if (measured) |key| key.phase else KeyCache.Phase{};
    const key = try self.cache.insert(self.gpa, text, text_metrics, self.layout.keycapWidth(text_metrics), origin);
    self.active.shareShapes(key);
    return key;
}

fn bitmapContext(self: *const Renderer, bitmap: Bitmap) Cairo.CreateError!*Cairo {
    const cairo = try Cairo.create(bitmap.surface);
    errdefer cairo.destroy();
    try drawing.setup(cairo, self.layout.scale, self.layout.subpixel);
    const factor = @as(f64, @floatFromInt(self.layout.scale)) / 120.0;
    cairo.translate((@as(f64, @floatFromInt(bitmap.origin_x)) + bitmap.phase.x) / factor, (@as(f64, @floatFromInt(bitmap.origin_y)) + bitmap.phase.y) / factor);
    cairo.setOperator(.source);
    return cairo;
}

fn paintShadow(self: *Renderer, cairo: *Cairo, cached: *KeyCache.Key, x: f64, y: f64) RenderError!void {
    if (cached.shadow == null) {
        self.cache.shareShapes(cached);
        if (cached.shadow == null) {
            const layout = self.layout;
            const bitmap = try Bitmap.init(cached.width, layout.key_height, layout.scale, .{
                .left = layout.key_shadow_left,
                .right = @max(0, layout.key_shadow_blur + layout.key_shadow_offset_x),
                .top = layout.key_shadow_top,
                .bottom = @max(0, layout.key_shadow_blur + layout.key_shadow_offset_y),
            }, cached.phase);
            errdefer bitmap.deinit();
            const context = try self.bitmapContext(bitmap);
            defer context.destroy();
            drawing.shadow(context, 0, 0, cached.width, layout, self.style);
            cached.shadow = bitmap;
        }
    }
    cached.shadow.?.paint(cairo, x, y, self.layout.scale);
}

fn prepareBackground(self: *Renderer, cached: *KeyCache.Key) RenderError!void {
    self.cache.shareShapes(cached);
    if (cached.background == null) {
        const padding = self.style.key_border_width / 2.0;
        const bitmap = try Bitmap.init(cached.width, self.layout.key_height, self.layout.scale, .{
            .left = padding,
            .right = padding,
            .top = padding,
            .bottom = padding,
        }, cached.phase);
        errdefer bitmap.deinit();
        const context = try self.bitmapContext(bitmap);
        defer context.destroy();
        try drawing.keycap(context, 0, 0, cached.width, self.layout, self.style);
        // Flat keycaps use SOURCE, so translucent colors need a coverage mask.
        if (std.meta.eql(self.layout.key_depth, Appearance.Depth.uniform(0)) and (self.style.key_background.a != 255 or
            (self.style.key_border_width > 0 and self.style.key_border_color.a != 255)))
        {
            const mask = try Bitmap.init(cached.width, self.layout.key_height, self.layout.scale, .{
                .left = padding,
                .right = padding,
                .top = padding,
                .bottom = padding,
            }, cached.phase);
            errdefer mask.deinit();
            const mask_context = try self.bitmapContext(mask);
            defer mask_context.destroy();
            var opaque_style = self.style;
            opaque_style.key_background.a = 255;
            opaque_style.key_border_color.a = 255;
            try drawing.keycap(mask_context, 0, 0, cached.width, self.layout, opaque_style);
            cached.background_coverage = mask;
        }
        cached.background = bitmap;
    }
}

fn paintActive(self: *Renderer, cairo: *Cairo, key: *KeyCache.Key, x: f64, y: f64) RenderError!void {
    try self.prepareBackground(key);
    key.background.?.paintMasked(cairo, x, y, self.layout.scale, key.background_coverage);
    // The changing repeat label is drawn straight into the frame, never cached.
    cairo.save();
    defer cairo.restore();
    cairo.setOperator(.source);
    try self.drawText(cairo, key, x, y, self.style.text_highlight_color);
}

fn paintKey(self: *Renderer, cairo: *Cairo, cached: *KeyCache.Key, x: f64, y: f64) RenderError!void {
    if (cached.face) |face| {
        face.paint(cairo, x, y, self.layout.scale);
        return;
    }
    try self.prepareBackground(cached);
    const color = self.style.text_color;
    const face = try cached.background.?.copy();
    errdefer face.deinit();
    const context = try self.bitmapContext(face);
    defer context.destroy();
    try self.drawText(context, cached, 0, 0, color);
    var coverage: ?Bitmap = null;
    errdefer if (coverage) |mask| mask.deinit();
    if (self.style.key_background.a != 255 or color.a != 255 or
        (self.style.key_border_width > 0 and self.style.key_border_color.a != 255))
    {
        // Track how much of the frame the original SOURCE operations replace.
        // This differs from the result's alpha for translucent colors.
        const mask = try (cached.background_coverage orelse cached.background.?).copy();
        errdefer mask.deinit();
        const mask_context = try self.bitmapContext(mask);
        defer mask_context.destroy();
        try self.drawText(mask_context, cached, 0, 0, .rgba(0xFFFFFFFF));
        coverage = mask;
    }
    cached.face = .{ .bitmap = face, .coverage = coverage };
    cached.face.?.paint(cairo, x, y, self.layout.scale);
}

fn drawText(self: *const Renderer, cairo: *Cairo, cached: *const KeyCache.Key, x: f64, y: f64, color: Appearance.Color) RenderError!void {
    drawing.setSourceColor(cairo, color);
    const position = self.layout.textPosition(cached.width, cached.metrics);
    cairo.moveTo(x + position.x, y + position.y);
    pango.text.draw(cairo, self.style.font, cached.text) catch return error.TextRenderingFailed;
}

fn scaledSize(logical_size: i32, scale_numerator: u32) error{BufferSizeOverflow}!i32 {
    const product = @as(u64, @intCast(logical_size)) * scale_numerator;
    return std.math.cast(i32, @max(1, (product + 60) / 120)) orelse error.BufferSizeOverflow;
}

const drawing = struct {
    fn keycap(cairo: *Cairo, x: f64, y: f64, width: f64, layout: Layout, style: Appearance.Style) Cairo.CreateError!void {
        cairo.save();
        defer cairo.restore();

        if (std.meta.eql(layout.key_depth, Appearance.Depth.uniform(0))) {
            roundedRectangle(cairo, x, y, width, layout.key_height, layout.key_radius);
            setSourceColor(cairo, style.key_background);
            fillAndStroke(cairo, style.key_border_color, style.key_border_width);
            return;
        }

        cairo.setOperator(.over);
        const face_left = x + layout.key_depth.left;
        const face_top = y + layout.key_depth.top;
        const face_right = x + width - layout.key_depth.right;
        const face_bottom = y + layout.key_height - layout.key_depth.bottom;

        cairo.save();
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

test "buffer dimensions round fractional scales and preserve integer scales" {
    try std.testing.expectEqual(125, try scaledSize(100, 150));
    try std.testing.expectEqual(76, try scaledSize(101, 90));
    try std.testing.expectEqual(152, try scaledSize(101, 180));
    try std.testing.expectEqual(202, try scaledSize(101, 240));
    try std.testing.expectEqual(1, try scaledSize(1, 30));
    // 115% must round exact half pixels up, without floating-point error.
    try std.testing.expectEqual(58, try scaledSize(50, 138));
    try std.testing.expectError(error.BufferSizeOverflow, scaledSize(std.math.maxInt(i32), 240));
    try std.testing.expectEqual(35791394, try scaledSize(1, std.math.maxInt(u32)));
    try std.testing.expectError(error.BufferSizeOverflow, scaledSize(std.math.maxInt(i32), std.math.maxInt(u32)));
}

test "reused measurement context matches fresh layouts across output settings" {
    const selected = Appearance.themed(.wisp_light);
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const reused_cairo = try Cairo.create(surface);
    defer reused_cairo.destroy();
    const settings = [_]struct { scale: u32, subpixel: Cairo.SubpixelOrder }{
        .{ .scale = 120, .subpixel = .default },
        .{ .scale = 240, .subpixel = .default },
        .{ .scale = 240, .subpixel = .rgb },
        .{ .scale = 216, .subpixel = .bgr },
        .{ .scale = 240, .subpixel = .rgb },
    };
    for (settings) |setting| {
        const cairo = try Cairo.create(surface);
        defer cairo.destroy();
        try drawing.setup(cairo, setting.scale, setting.subpixel);
        try drawing.setup(reused_cairo, setting.scale, setting.subpixel);
        const actual = try Layout.init(reused_cairo, selected.style, setting.scale, setting.subpixel);
        const expected_text = try pango.text.measure(cairo, "Serif 128", "Ctrl+AW");
        try std.testing.expectEqualDeep(expected_text, try pango.text.measure(reused_cairo, "Serif 128", "Ctrl+AW"));
        try std.testing.expectEqualDeep(try Layout.init(cairo, selected.style, setting.scale, setting.subpixel), actual);
    }
}

test "default keycaps share a minimum width and keep text inside the face" {
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    for ([_]Appearance.Theme{ .dark, .light, .wisp_dark, .wisp_light }) |theme| {
        for ([_][:0]const u8{ "Sans Bold 12", "Sans Bold 16", "Serif 32", "Serif Italic 48", "Monospace 64", "Sans Bold 128" }) |font| {
            for ([_]u32{ 120, 168 }) |scale| {
                try drawing.setup(cairo, scale, .default);
                var selected = Appearance.themed(theme);
                selected.style.font = font;
                const layout = try Layout.init(cairo, selected.style, scale, .default);
                try std.testing.expectEqual(layout.key_height, layout.key_min_width);
                try std.testing.expect(layout.key_shadow_blur * 2.0 <= layout.key_gap);
                const face_height = layout.key_height - layout.key_depth.top - layout.key_depth.bottom;
                const face_width = layout.key_height - layout.key_side_width;
                if (std.meta.eql(layout.key_depth, Appearance.Depth.uniform(0))) {
                    try std.testing.expectEqual(@as(i32, 0), layout.key_side_width);
                    try std.testing.expectEqual(face_height, face_width);
                }
                if (theme == .wisp_dark or theme == .wisp_light) {
                    try std.testing.expect(face_width < face_height);
                }
                for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |letter| {
                    const measured = try pango.text.measure(cairo, font, &.{letter});
                    try std.testing.expectEqual(layout.key_height, layout.keycapWidth(measured));
                    try std.testing.expect(measured.width <= face_width);
                    const position = layout.textPosition(layout.key_height, measured);
                    const left = position.x - layout.key_depth.left;
                    const right = (layout.key_height - @as(f64, @floatFromInt(measured.width))) - layout.key_depth.right - position.x;
                    const top = position.y - layout.key_depth.top;
                    const bottom = (layout.key_height - @as(f64, @floatFromInt(measured.height))) - layout.key_depth.bottom - position.y;
                    try std.testing.expect(left >= layout.key_padding_horizontal);
                    try std.testing.expect(top >= 0);
                    try std.testing.expectApproxEqAbs(left, right, 0.000001);
                    try std.testing.expectApproxEqAbs(top, bottom, 0.000001);
                }
            }
        }
    }
}

test "labels with different font metrics share the F baseline across scales and face depths" {
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    for ([_][:0]const u8{ "Serif 16", "Serif 32", "Serif 64", "Serif 128", "Sans Bold 32" }) |font| {
        for ([_]u32{ 120, 168, 216, 240 }) |scale| {
            try drawing.setup(cairo, scale, .default);
            const reference = try pango.text.measure(cairo, font, "F");
            const alphabet = try pango.text.measureAlphabet(cairo, font);
            try std.testing.expectEqual(reference.baseline, alphabet.baseline);
            for ([_]Appearance.Theme{ .light, .wisp_light }) |theme| {
                var style = Appearance.themed(theme).style;
                style.font = font;
                for ([_]?Appearance.Depth{ style.key_depth, .{ .top = 0.25, .right = 1.125, .bottom = 3.5, .left = 2.25 } }) |depth| {
                    style.key_depth = depth;
                    const layout = try Layout.init(cairo, style, scale, .default);
                    const reference_position = layout.textPosition(layout.keycapWidth(reference), reference);
                    // The reference letter retains the previous centered-line position.
                    const centered_y = layout.key_depth.top + (layout.key_height - layout.key_depth.top - layout.key_depth.bottom - @as(f64, @floatFromInt(alphabet.height))) / 2.0;
                    try std.testing.expectApproxEqAbs(centered_y, reference_position.y, 0.000001);
                    for ([_][]const u8{ "A", "Mg", "yT", "↑", "↓", "←", "→", "↵", "⏎", "↩", "⌫", "😀", "👍🏽", "👩‍💻", "❤️", "Ctrl+↵", "Ctrl+😀", "A×128" }) |label| {
                        const measured = try pango.text.measure(cairo, font, label);
                        const width = layout.keycapWidth(measured);
                        const position = layout.textPosition(width, measured);
                        try std.testing.expectApproxEqAbs(reference_position.y + reference.baseline, position.y + measured.baseline, 0.000001);
                        const left = position.x - layout.key_depth.left;
                        const right = width - @as(f64, @floatFromInt(measured.width)) - layout.key_depth.right - position.x;
                        try std.testing.expectApproxEqAbs(left, right, 0.000001);
                    }
                    // A different line height must not move the baseline or round its fraction.
                    var fractional = reference;
                    fractional.height += 17;
                    fractional.baseline += 0.125;
                    const shifted = layout.textPosition(layout.keycapWidth(fractional), fractional);
                    try std.testing.expectApproxEqAbs(reference_position.y - 0.125, shifted.y, 0.000001);
                }
            }
        }
    }
}

test "formatted letters use the shared width while repetitions and labels can expand" {
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    const selected = Appearance.themed(.wisp_dark);
    try drawing.setup(cairo, 120, .default);
    const layout = try Layout.init(cairo, selected.style, 120, .default);
    var value: Entry = .{ .modifiers = .{}, .name = "a", .text = "a" };
    const letter = try metrics.entry(cairo, selected.style.font, &value);
    try std.testing.expectEqual(layout.key_height, layout.keycapWidth(letter));
    value.repetition = 123;
    const repeated = try metrics.entry(cairo, selected.style.font, &value);
    try std.testing.expect(layout.keycapWidth(repeated) > layout.key_height);
    value = .{ .modifiers = .{}, .name = "Control", .text = "" };
    const control = try metrics.entry(cairo, selected.style.font, &value);
    try std.testing.expectEqualDeep(try pango.text.measure(cairo, selected.style.font, "Ctrl+"), control);
}

test "keycap side brightness follows the opposite shadow direction" {
    const cases = [_]struct { x: f64, y: f64, brightest_first: [4]usize }{
        .{ .x = 1, .y = 2, .brightest_first = .{ 0, 3, 1, 2 } },
        .{ .x = 2, .y = 1, .brightest_first = .{ 3, 0, 2, 1 } },
        .{ .x = -1, .y = 2, .brightest_first = .{ 0, 1, 3, 2 } },
        .{ .x = -2, .y = 1, .brightest_first = .{ 1, 0, 2, 3 } },
        .{ .x = -1, .y = -2, .brightest_first = .{ 2, 1, 3, 0 } },
        .{ .x = -2, .y = -1, .brightest_first = .{ 1, 2, 0, 3 } },
        .{ .x = 1, .y = -2, .brightest_first = .{ 2, 3, 1, 0 } },
        .{ .x = 2, .y = -1, .brightest_first = .{ 3, 2, 0, 1 } },
        .{ .x = 1, .y = 1, .brightest_first = .{ 0, 3, 1, 2 } },
        .{ .x = 0, .y = 0, .brightest_first = .{ 0, 3, 1, 2 } },
        .{ .x = 0.25, .y = -0.5, .brightest_first = .{ 2, 3, 1, 0 } },
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

test "explicit geometry overrides every preset including zero values" {
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    try drawing.setup(cairo, 120, .default);
    for ([_]Appearance.Theme{ .dark, .light, .wisp_dark, .wisp_light }) |name| {
        var theme = Appearance.themed(name);
        const font_metrics = try pango.text.measureAlphabet(cairo, theme.style.font);
        theme.style.panel_radius = 0;
        theme.style.panel_padding = 0;
        theme.style.key_padding_horizontal = 0;
        theme.style.key_padding_vertical = 0;
        theme.style.key_gap = 0;
        theme.style.key_radius = 0;
        theme.style.key_shadow_blur = 0;
        theme.style.key_shadow_offset_x = 0;
        theme.style.key_shadow_offset_y = 0;
        for ([_]i32{ 0, 9 }) |depth| {
            theme.style.key_depth = .uniform(@floatFromInt(depth));
            const layout = try Layout.init(cairo, theme.style, 120, .default);
            try std.testing.expectEqualDeep(Appearance.Depth.uniform(@floatFromInt(depth)), layout.key_depth);
            try std.testing.expect(layout.key_height - depth * 2 >= font_metrics.height);
            if (depth == 0) {
                try std.testing.expectEqual(0, layout.key_side_width);
                try std.testing.expectEqual(0, layout.key_depth.top);
                try std.testing.expectEqual(0, layout.key_depth.bottom);
                try std.testing.expectEqual(0, layout.key_depth.left);
            }
            try std.testing.expectEqual(0, layout.panel_padding);
            try std.testing.expectEqual(0, layout.panel_radius);
            try std.testing.expectEqual(0, layout.key_padding_horizontal);
            try std.testing.expectEqual(0, layout.key_gap);
            try std.testing.expectEqual(0, layout.key_radius);
            try std.testing.expectEqual(0, layout.key_shadow_blur);
            try std.testing.expectEqual(0, layout.key_shadow_left);
            try std.testing.expectEqual(0, layout.key_shadow_top);
            try std.testing.expectEqual(layout.key_height, layout.panel_height);
            try std.testing.expectEqual(layout.key_height, layout.panelWidth(layout.key_height));
        }
        theme.style.key_shadow_blur = 9;
        const explicit_shadow = try Layout.init(cairo, theme.style, 120, .default);
        try std.testing.expectEqual(0, explicit_shadow.key_gap);
        try std.testing.expectEqual(9, explicit_shadow.key_shadow_blur);
    }
}

test "explicit padding and depth preserve exact padding and centered labels" {
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    try drawing.setup(cairo, 168, .default);
    var style = Appearance.themed(.wisp_dark).style;
    style.font = "Serif 32";
    const font_metrics = try pango.text.measureAlphabet(cairo, style.font);
    const cases = [_]struct { horizontal: f64, vertical: f64, depth: Appearance.Depth }{
        .{ .horizontal = 0, .vertical = 0, .depth = .uniform(0) },
        .{ .horizontal = 40, .vertical = 0, .depth = .uniform(4) },
        .{ .horizontal = 0, .vertical = 9, .depth = .uniform(1000) },
        .{ .horizontal = 7, .vertical = 3, .depth = .{ .top = 0, .right = 0.25, .bottom = 2.5, .left = 4.125 } },
        .{ .horizontal = 7, .vertical = 3, .depth = .{ .top = 15.25, .right = 0, .bottom = 0, .left = 0 } },
        .{ .horizontal = 7, .vertical = 3, .depth = .{ .top = 0, .right = 100.5, .bottom = 0, .left = 0 } },
    };
    for (cases) |case| {
        style.key_padding_horizontal = case.horizontal;
        style.key_padding_vertical = case.vertical;
        style.key_depth = case.depth;
        const layout = try Layout.init(cairo, style, 168, .default);
        try std.testing.expectEqualDeep(case.depth, layout.key_depth);
        try std.testing.expectEqual(0, layout.key_min_width);
        try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(font_metrics.height)) + case.vertical * 2 + case.depth.top + case.depth.bottom, layout.key_height, 0.000001);
        for ([_][]const u8{ "I", "A", "W", "Ctrl+Shift+Alt+A" }) |label| {
            const measured = try pango.text.measure(cairo, style.font, label);
            const width = layout.keycapWidth(measured);
            const position = layout.textPosition(width, measured);
            const left = position.x - case.depth.left;
            const right = width - @as(f64, @floatFromInt(measured.width)) - case.depth.right - position.x;
            const top = position.y - case.depth.top;
            const bottom = layout.key_height - @as(f64, @floatFromInt(measured.height)) - case.depth.bottom - position.y;
            try std.testing.expectApproxEqAbs(case.horizontal, left, 0.000001);
            try std.testing.expectApproxEqAbs(case.vertical, top, 0.000001);
            try std.testing.expectApproxEqAbs(left, right, 0.000001);
            try std.testing.expectApproxEqAbs(top, bottom, 0.000001);
            try drawing.keycap(cairo, 0, 0, width, layout, style);
        }
    }
}

test "explicit horizontal padding changes width without changing vertical geometry" {
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    for ([_]Appearance.Theme{ .light, .wisp_light }) |theme| {
        for ([_]u32{ 120, 168, 216, 240 }) |scale| {
            try drawing.setup(cairo, scale, .default);
            var style = Appearance.themed(theme).style;
            style.font = "Serif 32";
            const automatic = try Layout.init(cairo, style, scale, .default);
            const narrow = try pango.text.measure(cairo, style.font, "I");
            const wide = try pango.text.measure(cairo, style.font, "W");
            try std.testing.expectEqual(automatic.keycapWidth(narrow), automatic.keycapWidth(wide));
            style.key_padding_horizontal = 0;
            const zero = try Layout.init(cairo, style, scale, .default);
            try std.testing.expect(zero.keycapWidth(narrow) < zero.key_height);
            try std.testing.expect(zero.keycapWidth(narrow) < zero.keycapWidth(wide));
            for ([_]f64{ 0, 3.125, automatic.key_padding_horizontal, 200 }) |padding| {
                style.key_padding_horizontal = padding;
                const layout = try Layout.init(cairo, style, scale, .default);
                try std.testing.expectEqual(0, layout.key_min_width);
                try std.testing.expectEqual(zero.key_height, layout.key_height);
                try std.testing.expectEqual(zero.key_text_baseline, layout.key_text_baseline);
                try std.testing.expectEqual(zero.panel_height, layout.panel_height);
                try std.testing.expectEqual(zero.key_depth, layout.key_depth);
                try std.testing.expectEqual(zero.key_shadow_blur, layout.key_shadow_blur);
                try std.testing.expectEqual(zero.key_shadow_offset_y, layout.key_shadow_offset_y);
                try std.testing.expectApproxEqAbs(zero.keycapWidth(narrow) + padding * 2, layout.keycapWidth(narrow), 0.000001);
                try std.testing.expectApproxEqAbs(zero.keycapWidth(wide) + padding * 2, layout.keycapWidth(wide), 0.000001);
            }
        }
    }
}

test "zero-width keyboard text keeps a positive Wayland surface size" {
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    try drawing.setup(cairo, 120, .default);
    var style = Appearance.themed(.light).style;
    style.key_padding_horizontal = 0;
    style.panel_padding = 0;
    const Keyboard = @import("../Model/Keyboard.zig");
    var buffer: [64]u8 = undefined;
    const label = Keyboard.text(@enumFromInt(0x0100200c), &buffer);
    try std.testing.expectEqualStrings("\u{200c}", label);
    const measured = try pango.text.measure(cairo, style.font, label);
    const layout = try Layout.init(cairo, style, 120, .default);
    const panel_width = layout.panelWidth(layout.keycapWidth(measured));
    try std.testing.expectEqual(0, panel_width);
    try std.testing.expectEqual(1, try Layout.pixelSize(panel_width));
    try std.testing.expectError(error.LayoutSizeOverflow, Layout.pixelSize(-1));
}

test "oversized layouts fail when converting final surface dimensions" {
    const surface = try Cairo.Surface.recording(.color_alpha, null);
    defer surface.destroy();
    const cairo = try Cairo.create(surface);
    defer cairo.destroy();
    var style = Appearance.themed(.wisp_dark).style;
    for ([_]Appearance.Depth{
        .uniform(1e300),
        .{ .top = 1e300, .right = 0, .bottom = 0, .left = 0 },
        .{ .top = 0, .right = 1e300, .bottom = 0, .left = 0 },
    }) |depth| {
        style.key_depth = depth;
        const layout = try Layout.init(cairo, style, 120, .default);
        try std.testing.expectError(error.LayoutSizeOverflow, Layout.pixelSize(layout.panel_height));
        try std.testing.expectError(error.LayoutSizeOverflow, Layout.pixelSize(layout.panelWidth(layout.key_height)));
    }
}

test "fractional spacing survives layout until the final surface bounds" {
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
    style.key_radius = 3.25;
    style.panel_radius = 5.75;
    style.key_border_width = 0.5;
    style.key_shadow_blur = 1.25;
    style.key_shadow_offset_x = -0.5;
    style.key_shadow_offset_y = 0.75;
    const layout = try Layout.init(cairo, style, 120, .default);
    const text = try pango.text.measure(cairo, style.font, "Ctrl+Shift+Alt+W");
    const width = layout.keycapWidth(text);
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(text.width)) + 9.625, width, 0.000001);
    try std.testing.expectEqual(1.75, layout.key_shadow_left);
    try std.testing.expectEqual(0.5, layout.key_shadow_top);
    try std.testing.expectEqual(layout.key_height + 4.75, layout.panel_height);
    try std.testing.expectEqual(3.25, layout.key_radius);
    try std.testing.expectEqual(5.75, layout.panel_radius);
    const panel_width = layout.panelWidth(width * 3 + layout.key_gap * 2);
    try std.testing.expectApproxEqAbs(width * 3 + 9.75, panel_width, 0.000001);
    const pixels = try Layout.pixelSize(panel_width);
    try std.testing.expect(@as(f64, @floatFromInt(pixels)) >= panel_width);
    try std.testing.expect(@as(f64, @floatFromInt(pixels)) < panel_width + 1);
    try drawing.keycap(cairo, 1.125, 2.25, width, layout, style);
    try std.testing.expectEqual(101, try Layout.pixelSize(100.25));
    try std.testing.expectEqual(152, try scaledSize(101, 180));
}

const TestCanvas = struct {
    data: []u8,
    surface: *Cairo.Surface,
    cairo: *Cairo,

    fn init() !TestCanvas {
        const data = try std.testing.allocator.alloc(u8, 512 * 512 * 4);
        errdefer std.testing.allocator.free(data);
        @memset(data, 0);
        const surface = try Cairo.Surface.image(data.ptr, .argb32, 512, 512, 512 * 4);
        errdefer surface.destroy();
        return .{ .data = data, .surface = surface, .cairo = try Cairo.create(surface) };
    }

    fn deinit(self: TestCanvas) void {
        self.cairo.destroy();
        self.surface.destroy();
        std.testing.allocator.free(self.data);
    }

    fn reset(self: TestCanvas, scale: u32) !void {
        self.cairo.identityMatrix();
        self.cairo.setOperator(.source);
        self.cairo.setSourceRgba(0.2, 0.3, 0.4, 0.6);
        self.cairo.paint();
        try drawing.setup(self.cairo, scale, .default);
    }
};

test "historical and active keys preserve pixels without caching highlight images" {
    for ([_]Appearance.Theme{ .light, .dark, .wisp_light, .wisp_dark }) |theme| {
        for ([_]u32{ 120, 216, 240 }) |scale| {
            var renderer = try Renderer.init(std.testing.allocator, Appearance.themed(theme).style, undefined, undefined, scale, .default);
            defer renderer.deinit();
            var entry = try Entry.init(std.testing.allocator, .{}, "A", "A");
            defer entry.deinit(std.testing.allocator);
            const cached = try renderer.cachedKey(&entry, .{});
            const actual = try TestCanvas.init();
            defer actual.deinit();
            const expected = try TestCanvas.init();
            defer expected.deinit();
            for ([_]bool{ false, true, false }) |active| {
                const color = if (active) renderer.style.text_highlight_color else renderer.style.text_color;
                try actual.reset(scale);
                try expected.reset(scale);
                if (active) try renderer.paintActive(actual.cairo, cached, 20, 20) else try renderer.paintKey(actual.cairo, cached, 20, 20);
                try drawing.keycap(expected.cairo, 20, 20, cached.width, renderer.layout, renderer.style);
                try renderer.drawText(expected.cairo, cached, 20, 20, color);
                // Rasterizing a local bitmap can differ by a rounding unit at an edge.
                for (actual.data, expected.data) |a, b| {
                    try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 2);
                }
            }
            try std.testing.expect(cached.face != null);
        }
    }
}

test "active drawing preserves the historical face and scale changes clear caches" {
    var style = Appearance.themed(.wisp_light).style;
    style.text_highlight_color = style.text_color;
    var renderer = try Renderer.init(std.testing.allocator, style, undefined, undefined, 120, .default);
    defer renderer.deinit();
    var entry = try Entry.init(std.testing.allocator, .{}, "A", "A");
    defer entry.deinit(std.testing.allocator);
    const canvas = try TestCanvas.init();
    defer canvas.deinit();
    const cached = try renderer.cachedKey(&entry, .{});
    try renderer.paintShadow(canvas.cairo, cached, 20, 20);
    try renderer.paintKey(canvas.cairo, cached, 20, 20);
    const face = cached.face.?.bitmap.surface;
    try renderer.paintActive(canvas.cairo, cached, 40, 20);
    try std.testing.expectEqual(face, cached.face.?.bitmap.surface);
    try renderer.updateLayout(120, .default);
    try std.testing.expectEqual(cached, renderer.cache.head.?);
    try renderer.updateLayout(216, .default);
    try std.testing.expect(renderer.cache.head == null);
    try std.testing.expectEqual(216, renderer.layout.scale);
    const resized = try renderer.cachedKey(&entry, .{});
    try renderer.paintKey(canvas.cairo, resized, 20, 20);
    try renderer.updateLayout(216, .rgb);
    try std.testing.expect(renderer.cache.head == null);
}

test "labels share key geometry but repetition changes text and width" {
    var renderer = try Renderer.init(std.testing.allocator, Appearance.themed(.wisp_light).style, undefined, undefined, 120, .default);
    defer renderer.deinit();
    const canvas = try TestCanvas.init();
    defer canvas.deinit();
    var a = try Entry.init(std.testing.allocator, .{}, "A", "A");
    defer a.deinit(std.testing.allocator);
    const first = try renderer.cachedKey(&a, .{});
    try renderer.paintShadow(canvas.cairo, first, 20, 20);
    try renderer.paintKey(canvas.cairo, first, 20, 20);
    var b = try Entry.init(std.testing.allocator, .{}, "B", "B");
    defer b.deinit(std.testing.allocator);
    const second = try renderer.cachedKey(&b, .{});
    try std.testing.expectEqual(first.background.?.surface, second.background.?.surface);
    try std.testing.expectEqual(first.shadow.?.surface, second.shadow.?.surface);
    a.repetition = 1000;
    const repeated = try renderer.cachedKey(&a, .{});
    try std.testing.expectEqualStrings("A×1000", repeated.text);
    try std.testing.expect(repeated.width > first.width);
    try std.testing.expect(repeated.background == null and repeated.shadow == null);
    try std.testing.expectEqualStrings("A", first.text);
}

test "translucent custom key colors cache without changing SOURCE compositing" {
    for ([_]Appearance.Theme{ .light, .wisp_light }) |theme| {
        for ([_]u8{ 0, 80, 255 }) |alpha| {
            var style = Appearance.themed(theme).style;
            style.key_background.a = alpha;
            style.key_border_color.a = 80;
            style.key_border_width = 2;
            style.text_color.a = 100;
            style.text_highlight_color.a = 100;
            var renderer = try Renderer.init(std.testing.allocator, style, undefined, undefined, 120, .default);
            defer renderer.deinit();
            var entry = try Entry.init(std.testing.allocator, .{}, "A", "A");
            defer entry.deinit(std.testing.allocator);
            const cached = try renderer.cachedKey(&entry, .{});
            const actual = try TestCanvas.init();
            defer actual.deinit();
            const expected = try TestCanvas.init();
            defer expected.deinit();
            for ([_]bool{ true, false }) |active| {
                try actual.reset(120);
                try expected.reset(120);
                if (active) try renderer.paintActive(actual.cairo, cached, 20, 20) else try renderer.paintKey(actual.cairo, cached, 20, 20);
                try drawing.keycap(expected.cairo, 20, 20, cached.width, renderer.layout, style);
                try renderer.drawText(expected.cairo, cached, 20, 20, if (active) style.text_highlight_color else style.text_color);
                for (actual.data, expected.data) |a, b| {
                    try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 2);
                }
                try std.testing.expectEqual(!active, cached.face != null);
            }
        }
    }
}

test "cached shadows preserve overlap order and negative offsets" {
    for ([_]i32{ -12, 0, 12 }) |offset| {
        var style = Appearance.themed(.wisp_light).style;
        style.key_shadow_offset_x = offset;
        style.key_shadow_offset_y = offset;
        style.key_gap = 0;
        var renderer = try Renderer.init(std.testing.allocator, style, undefined, undefined, 240, .default);
        defer renderer.deinit();
        var entry = try Entry.init(std.testing.allocator, .{}, "A", "A");
        defer entry.deinit(std.testing.allocator);
        const cached = try renderer.cachedKey(&entry, .{});
        const actual = try TestCanvas.init();
        defer actual.deinit();
        const expected = try TestCanvas.init();
        defer expected.deinit();
        try actual.reset(240);
        try expected.reset(240);
        for ([_]f64{ 30, 30 + cached.width }) |x| {
            try renderer.paintShadow(actual.cairo, cached, x, 30);
            drawing.shadow(expected.cairo, x, 30, cached.width, renderer.layout, style);
        }
        for ([_]f64{ 30, 30 + cached.width }) |x| {
            try renderer.paintKey(actual.cairo, cached, x, 30);
            try drawing.keycap(expected.cairo, x, 30, cached.width, renderer.layout, style);
            try renderer.drawText(expected.cairo, cached, x, 30, style.text_color);
        }
        for (actual.data, expected.data) |a, b| {
            try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 2);
        }
    }
}

test "repeat updates only the active label and freezes its final state into history" {
    for ([_]Appearance.Theme{ .light, .wisp_light }) |theme| {
        var renderer = try Renderer.init(std.testing.allocator, Appearance.themed(theme).style, undefined, undefined, 120, .default);
        defer renderer.deinit();
        var model = try Model.init(std.testing.allocator, .{});
        defer model.deinit();
        const actual = try TestCanvas.init();
        defer actual.deinit();
        const expected = try TestCanvas.init();
        defer expected.deinit();
        var previous_background: ?Bitmap = null;
        defer if (previous_background) |bitmap| bitmap.deinit();
        var previous_shadow: ?Bitmap = null;
        defer if (previous_shadow) |bitmap| bitmap.deinit();
        var previous_width: f64 = 0;
        var saw_width_change = false;
        for (0..103) |i| {
            _ = try model.handle(.{ .keyboard = .{ .code = .a, .state = .pressed } });
            _ = try model.handle(.{ .keyboard = .{ .code = .a, .state = .released } });
            const view = model.view();
            try std.testing.expectEqual(@min(i + 1, 3), view.len());
            const entry = view.at(view.len() - 1);
            const repetition = if (i < 3) 1 else i - 1;
            try std.testing.expectEqual(repetition, entry.repetition);
            const active = (try renderer.prepareKeys(view)).?;
            var label: [64]u8 = undefined;
            const text = if (repetition == 1) "A" else try std.fmt.bufPrint(&label, "A×{d}", .{repetition});
            try std.testing.expectEqualStrings(text, active.text);
            try std.testing.expectEqual(active, (try renderer.prepareKeys(view)).?);
            try actual.reset(120);
            try expected.reset(120);
            try renderer.paintShadow(actual.cairo, active, 20, 20);
            drawing.shadow(expected.cairo, 20, 20, active.width, renderer.layout, renderer.style);
            try renderer.paintActive(actual.cairo, active, 20, 20);
            try drawing.keycap(expected.cairo, 20, 20, active.width, renderer.layout, renderer.style);
            try renderer.drawText(expected.cairo, active, 20, 20, renderer.style.text_highlight_color);
            try std.testing.expect(active.face == null);
            try std.testing.expect(active.next == null);
            if (renderer.cache.head) |history| {
                try std.testing.expectEqualStrings("A", history.text);
                try std.testing.expect(history.next == null);
            }
            if (previous_background) |prior| {
                if (previous_width == active.width) {
                    try std.testing.expectEqual(prior.surface, active.background.?.surface);
                    if (previous_shadow) |shadow| try std.testing.expectEqual(shadow.surface, active.shadow.?.surface);
                } else {
                    saw_width_change = true;
                }
                prior.deinit();
            }
            if (previous_shadow) |shadow| shadow.deinit();
            previous_background = active.background.?.share();
            previous_shadow = if (active.shadow) |shadow| shadow.share() else null;
            previous_width = active.width;
            for (actual.data, expected.data) |a, b| {
                try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 2);
            }
        }
        try std.testing.expect(saw_width_change);
        // Only the final repeat count enters history when another key arrives.
        _ = try model.handle(.{ .keyboard = .{ .code = .b, .state = .pressed } });
        const view = model.view();
        const active = (try renderer.prepareKeys(view)).?;
        try std.testing.expectEqualStrings("B", active.text);
        const folded = try renderer.cachedKey(view.at(view.len() - 2), .{});
        try std.testing.expectEqualStrings("A×101", folded.text);
        try std.testing.expectEqual(previous_background.?.surface, folded.background.?.surface);
        try actual.reset(120);
        try expected.reset(120);
        try renderer.paintKey(actual.cairo, folded, 20, 20);
        try drawing.keycap(expected.cairo, 20, 20, folded.width, renderer.layout, renderer.style);
        try renderer.drawText(expected.cairo, folded, 20, 20, renderer.style.text_color);
        for (actual.data, expected.data) |a, b| {
            try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 2);
        }
        const face = folded.face.?.bitmap.surface;
        try renderer.paintKey(actual.cairo, folded, 40, 20);
        try std.testing.expectEqual(face, folded.face.?.bitmap.surface);
        try renderer.updateLayout(216, .default);
        try std.testing.expect(renderer.cache.head == null and renderer.active.head == null);
        _ = try renderer.prepareKeys(model.view());
        try renderer.updateLayout(216, .rgb);
        try std.testing.expect(renderer.cache.head == null and renderer.active.head == null);
        _ = try renderer.prepareKeys(model.view());
        model.clear();
        try std.testing.expect(try renderer.prepareKeys(model.view()) == null);
        try std.testing.expect(renderer.active.head == null);
    }
}

test "cached fractional keycaps preserve placement, asymmetric faces and shadow overlap" {
    for ([_]Appearance.Theme{ .light, .wisp_light }) |theme| {
        for ([_]u32{ 120, 168, 180, 216, 240 }) |scale| {
            var style = Appearance.themed(theme).style;
            style.font = "Sans Bold 16";
            style.key_gap = 0.25;
            style.key_border_width = 0.5;
            style.key_radius = 3.25;
            style.key_padding_horizontal = 3.125;
            style.key_padding_vertical = 2.25;
            if (theme == .wisp_light) style.key_depth = .{ .top = 0.25, .right = 1.125, .bottom = 0.5, .left = 2.25 };
            style.key_shadow_blur = 1.25;
            style.key_shadow_offset_x = -0.5;
            style.key_shadow_offset_y = 0.75;
            var renderer = try Renderer.init(std.testing.allocator, style, undefined, undefined, scale, .default);
            defer renderer.deinit();
            var entry = try Entry.init(std.testing.allocator, .{}, "Super+P", "Super+P");
            defer entry.deinit(std.testing.allocator);
            const actual = try TestCanvas.init();
            defer actual.deinit();
            const expected = try TestCanvas.init();
            defer expected.deinit();
            for ([_]f64{ 20.125, 20.375, 20.125 }) |start| {
                try actual.reset(scale);
                try expected.reset(scale);
                const width = (try renderer.cachedKey(&entry, null)).width;
                const y = 20.25;
                const positions = [_]f64{ start, start + width + style.key_gap.? };
                for (positions) |x| {
                    const cached = try renderer.cachedKey(&entry, KeyCache.Phase.at(x, y, scale));
                    try renderer.paintShadow(actual.cairo, cached, x, y);
                    drawing.shadow(expected.cairo, x, y, width, renderer.layout, style);
                }
                for (positions, 0..) |x, i| {
                    const cached = try renderer.cachedKey(&entry, KeyCache.Phase.at(x, y, scale));
                    if (i == 0) try renderer.paintKey(actual.cairo, cached, x, y) else try renderer.paintActive(actual.cairo, cached, x, y);
                    try drawing.keycap(expected.cairo, x, y, width, renderer.layout, style);
                    try renderer.drawText(expected.cairo, cached, x, y, if (i == 0) style.text_color else style.text_highlight_color);
                }
                for (actual.data, expected.data) |a, b| {
                    try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 2);
                }
            }
        }
    }
}

test "repeat reuses active geometry at fractional origins and history retains phase variants" {
    var renderer = try Renderer.init(std.testing.allocator, Appearance.themed(.wisp_light).style, undefined, undefined, 168, .default);
    defer renderer.deinit();
    var model = try Model.init(std.testing.allocator, .{});
    defer model.deinit();
    const canvas = try TestCanvas.init();
    defer canvas.deinit();
    const phase = KeyCache.Phase.at(20.125, 20.25, 168);
    for (0..10) |_| {
        _ = try model.handle(.{ .keyboard = .{ .code = .a, .state = .pressed } });
        _ = try model.handle(.{ .keyboard = .{ .code = .a, .state = .released } });
    }
    const first = (try renderer.prepareKeys(model.view())).?;
    first.setPhase(phase);
    try renderer.prepareBackground(first);
    const saved = first.background.?.share();
    defer saved.deinit();
    const width = first.width;
    _ = try model.handle(.{ .keyboard = .{ .code = .a, .state = .pressed } });
    const repeated = (try renderer.prepareKeys(model.view())).?;
    try std.testing.expectEqual(width, repeated.width);
    try std.testing.expectEqualDeep(phase, repeated.phase);
    try std.testing.expectEqual(saved.surface, repeated.background.?.surface);
    _ = try model.handle(.{ .keyboard = .{ .code = .b, .state = .pressed } });
    _ = try renderer.prepareKeys(model.view());
    const historical = model.view().at(2);
    const one = try renderer.cachedKey(historical, phase);
    try renderer.paintKey(canvas.cairo, one, 20.125, 20.25);
    const face = one.face.?.bitmap.surface;
    const other_phase = KeyCache.Phase.at(20.375, 20.25, 168);
    const two = try renderer.cachedKey(historical, other_phase);
    try std.testing.expect(one != two);
    try std.testing.expect(two.background == null);
    try std.testing.expectEqual(face, (try renderer.cachedKey(historical, phase)).face.?.bitmap.surface);
}

test "two busy buffers defer without accessing the view and release makes a slot reusable" {
    var frames = [_]Frame{
        .{ .buffer = undefined, .busy = true },
        .{ .buffer = undefined, .busy = true },
    };
    var renderer: Renderer = undefined;
    renderer.frames = .{ &frames[0], &frames[1] };
    try std.testing.expectEqual(RenderResult.deferred, try renderer.render(undefined));
    try std.testing.expect((try renderer.acquireFrame(100, 50)) == null);
    Frame.listener(undefined, .release, &frames[0]);
    frames[0].buffer.width = 100;
    frames[0].buffer.height = 50;
    try std.testing.expect(renderer.canRender());
    try std.testing.expectEqual(&frames[0], (try renderer.acquireFrame(100, 50)).?);
    try std.testing.expect(frames[1].busy);
    frames[0].busy = true;
    Frame.listener(undefined, .release, &frames[1]);
    frames[1].buffer.width = 100;
    frames[1].buffer.height = 50;
    try std.testing.expectEqual(&frames[1], (try renderer.acquireFrame(100, 50)).?);
}
