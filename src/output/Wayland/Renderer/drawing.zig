const std = @import("std");
const Allocator = std.mem.Allocator;

const Appearance = @import("../Appearance.zig");
const Cairo = @import("../cairo.zig").Cairo;
const pango = @import("../pango.zig");
const BitmapCache = @import("BitmapCache.zig");
const Bitmap = BitmapCache.Bitmap;
const Geometry = @import("Geometry.zig");
const TextCache = @import("TextCache.zig");
const Measurement = TextCache.Measurement;

/// Owns the drawing configuration and reusable resources for one renderer.
pub const Context = struct {
    bitmaps: BitmapCache = .{},
    texts: TextCache = .{},
    font: pango.FontContext,
    geometry: Geometry,
    style: Appearance.Style,

    pub fn init(style: Appearance.Style, settings: pango.FontContext.Settings) !Context {
        var font = try pango.FontContext.init(style.font, settings);
        errdefer font.deinit();
        const geometry = Geometry.init(try font.measureAlphabet(), font.font_size, &style);
        return .{ .font = font, .geometry = geometry, .style = style };
    }

    pub inline fn setupCairo(self: *const Context, cairo: *Cairo) void {
        self.font.setupCairo(cairo);
    }

    pub fn deinit(self: *Context, gpa: Allocator) void {
        self.texts.clear(gpa);
        self.bitmaps.clear(gpa);
        self.font.deinit();
        self.* = undefined;
    }

    pub fn update(self: *Context, gpa: Allocator, settings: pango.FontContext.Settings) !void {
        if (self.font.settings.eql(settings)) return;
        var font = try pango.FontContext.init(self.style.font, settings);
        errdefer font.deinit();
        const geometry = Geometry.init(try font.measureAlphabet(), font.font_size, &self.style);
        self.texts.clear(gpa);
        self.bitmaps.clear(gpa);
        self.font.deinit();
        self.font = font;
        self.geometry = geometry;
    }
};

pub const primitives = struct {
    pub fn roundedRectangle(cairo: *Cairo, x: f64, y: f64, width: f64, height: f64, radius: f64) void {
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

    pub fn fillAndStroke(cairo: *Cairo, border: Appearance.Color, border_width: f64) void {
        if (border_width == 0) {
            cairo.fill();
            return;
        }
        cairo.fillPreserve();
        setSourceColor(cairo, border);
        cairo.setLineWidth(border_width);
        cairo.stroke();
    }

    pub fn setSourceColor(cairo: *Cairo, color: Appearance.Color) void {
        cairo.setSourceRgba(
            @as(f64, @floatFromInt(color.r)) / 255.0,
            @as(f64, @floatFromInt(color.g)) / 255.0,
            @as(f64, @floatFromInt(color.b)) / 255.0,
            @as(f64, @floatFromInt(color.a)) / 255.0,
        );
    }
};

pub const text = struct {
    pub fn measure(context: *Context, gpa: Allocator, label: []const u8) !*const Measurement {
        if (context.texts.find(label)) |cached| return cached;
        const layout = try context.font.createLayout(label);
        errdefer layout.destroy();
        const metrics = layout.metrics();
        const width = context.geometry.keycapWidth(metrics.width);
        const position = context.geometry.textPosition(width, metrics);
        return context.texts.insert(gpa, label, .{
            .layout = layout,
            .width = width,
            .offset_x = position.x,
            .offset_y = position.y,
        });
    }

    pub fn draw(cairo: *Cairo, measured: *const Measurement, x: f64, y: f64, color: Appearance.Color) void {
        cairo.save();
        defer cairo.restore();
        cairo.setOperator(.source);
        primitives.setSourceColor(cairo, color);
        cairo.moveTo(x + measured.offset_x, y + measured.offset_y);
        measured.layout.draw(cairo);
    }
};

pub const shadow = struct {
    pub fn draw(cairo: *Cairo, context: *Context, gpa: Allocator, width: f64, x: f64, y: f64) !void {
        const geometry = &context.geometry;
        const style = &context.style;
        if (style.key_shadow_color.a == 0) return;
        const scale = context.font.settings.scale;
        const key: BitmapCache.Key = .{
            .kind = .shadow,
            .width = width,
            .height = geometry.key_height,
            .pixel_offset = .at(x, y, scale),
        };
        const bitmap = context.bitmaps.find(key) orelse blk: {
            const bitmap = try Bitmap.init(width, geometry.key_height, scale, .{
                .left = geometry.key_shadow_left,
                .right = @max(0, geometry.key_shadow_blur + geometry.key_shadow_offset_x),
                .top = geometry.key_shadow_top,
                .bottom = @max(0, geometry.key_shadow_blur + geometry.key_shadow_offset_y),
            }, key.pixel_offset, context.bitmaps.max_bytes);
            errdefer bitmap.deinit();
            const bitmap_cairo = try bitmap.createCairo(&context.font, key.pixel_offset);
            defer bitmap_cairo.destroy();
            paint(bitmap_cairo, 0, 0, width, geometry, style);
            break :blk try context.bitmaps.insert(gpa, key, bitmap);
        };
        bitmap.paint(cairo, x, y, scale);
    }

    fn paint(cairo: *Cairo, x: f64, y: f64, width: f64, geometry: *const Geometry, style: *const Appearance.Style) void {
        cairo.save();
        defer cairo.restore();
        // Build a soft silhouette in its own group, then composite it over the panel.
        cairo.pushGroup();
        cairo.setOperator(.source);
        const layers: usize = if (geometry.key_shadow_blur > 0) 16 else 1;
        const blur = geometry.key_shadow_blur;
        const left = x + geometry.key_shadow_offset_x;
        const top = y + geometry.key_shadow_offset_y;
        for (0..layers) |layer| {
            const strength = @as(f64, @floatFromInt(layer + 1)) / @as(f64, @floatFromInt(layers));
            const spread = blur * (1.0 - strength);
            primitives.roundedRectangle(cairo, left - spread, top - spread, width + spread * 2, geometry.key_height + spread * 2, geometry.key_radius + spread);
            var color = style.key_shadow_color;
            color.a = @intFromFloat(@as(f64, @floatFromInt(color.a)) * strength * strength);
            primitives.setSourceColor(cairo, color);
            cairo.fill();
        }
        cairo.popGroupToSource();
        cairo.setOperator(.over);
        cairo.paint();
    }
};

pub const background = struct {
    pub fn draw(cairo: *Cairo, context: *Context, gpa: Allocator, width: f64, x: f64, y: f64) !void {
        const geometry = &context.geometry;
        const style = &context.style;
        const scale = context.font.settings.scale;
        const key: BitmapCache.Key = .{
            .kind = .background,
            .width = width,
            .height = geometry.key_height,
            .pixel_offset = .at(x, y, scale),
        };
        const bitmap = context.bitmaps.find(key) orelse blk: {
            const padding = style.key_border_width / 2.0;
            const bitmap = try Bitmap.init(width, geometry.key_height, scale, .{
                .left = padding,
                .right = padding,
                .top = padding,
                .bottom = padding,
            }, key.pixel_offset, context.bitmaps.max_bytes);
            errdefer bitmap.deinit();
            const bitmap_cairo = try bitmap.createCairo(&context.font, key.pixel_offset);
            defer bitmap_cairo.destroy();
            try paint(bitmap_cairo, 0, 0, width, geometry, style);
            break :blk try context.bitmaps.insert(gpa, key, bitmap);
        };
        bitmap.paint(cairo, x, y, scale);
    }

    fn paint(cairo: *Cairo, x: f64, y: f64, width: f64, geometry: *const Geometry, style: *const Appearance.Style) Cairo.CreateError!void {
        if (std.meta.eql(geometry.key_depth, Appearance.Depth.uniform(0))) {
            primitives.roundedRectangle(cairo, x, y, width, geometry.key_height, geometry.key_radius);
            primitives.setSourceColor(cairo, style.key_background);
            primitives.fillAndStroke(cairo, style.key_border_color, style.key_border_width);
            return;
        }

        const face_left = x + geometry.key_depth.left;
        const face_top = y + geometry.key_depth.top;
        const face_right = x + width - geometry.key_depth.right;
        const face_bottom = y + geometry.key_height - geometry.key_depth.bottom;

        cairo.save();
        errdefer cairo.restore();
        primitives.roundedRectangle(cairo, x, y, width, geometry.key_height, geometry.key_radius);
        cairo.clip();
        const outer_radius = @min(geometry.key_radius, @min(width, geometry.key_height) / 2.0);
        const face_radius = @min(geometry.key_face_radius, @min(face_right - face_left, face_bottom - face_top) / 2.0);
        const Point = struct { x: f64, y: f64 };
        // Clockwise from the upper-right corner. Each arc joins two flat slopes.
        const outer = [_]Point{
            .{ .x = x + width - outer_radius, .y = y + outer_radius },
            .{ .x = x + width - outer_radius, .y = y + geometry.key_height - outer_radius },
            .{ .x = x + outer_radius, .y = y + geometry.key_height - outer_radius },
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
        const colors = sideColors(style.key_background, geometry.key_shadow_offset_x, geometry.key_shadow_offset_y);
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

        primitives.roundedRectangle(cairo, face_left, face_top, face_right - face_left, face_bottom - face_top, geometry.key_face_radius);
        primitives.setSourceColor(cairo, style.key_background);
        primitives.fillAndStroke(cairo, shade(style.key_background, 0.08), geometry.key_face_border_width);
        cairo.restore();

        if (style.key_border_width > 0) {
            primitives.roundedRectangle(cairo, x, y, width, geometry.key_height, geometry.key_radius);
            primitives.setSourceColor(cairo, style.key_border_color);
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
};
