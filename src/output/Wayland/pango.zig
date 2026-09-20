const std = @import("std");

const Cairo = @import("cairo.zig").Cairo;

const pango_scale: c_int = 1024;

pub const CreateError = error{CreateFailed};

const Rectangle = extern struct { x: c_int = 0, y: c_int = 0, width: c_int = 0, height: c_int = 0 };
const Matrix = extern struct { xx: f64, xy: f64 = 0, yx: f64 = 0, yy: f64, x0: f64 = 0, y0: f64 = 0 };
const FontMap = opaque {};
const Context = opaque {
    fn create() CreateError!*Context {
        const map = ffi.pangocairo.pango_cairo_font_map_get_default() orelse return error.CreateFailed;
        return ffi.pango.pango_font_map_create_context(map) orelse error.CreateFailed;
    }

    fn destroy(self: *Context) void {
        ffi.gobject.g_object_unref(@ptrCast(self));
    }
};

pub const Layout = opaque {
    pub const Metrics = struct { width: i32, height: i32, baseline: f64 };

    fn create(context: *Context, font: *const FontDescription, content: []const u8) CreateError!*Layout {
        const layout = ffi.pango.pango_layout_new(context) orelse return error.CreateFailed;
        ffi.pango.pango_layout_set_font_description(layout, font);
        ffi.pango.pango_layout_set_text(layout, content.ptr, @intCast(content.len));
        return layout;
    }

    pub fn destroy(self: *Layout) void {
        ffi.gobject.g_object_unref(@ptrCast(self));
    }

    pub fn metrics(self: *Layout) Metrics {
        var logical: Rectangle = undefined;
        ffi.pango.pango_layout_get_pixel_extents(self, null, &logical);
        return .{
            .width = logical.width,
            .height = logical.height,
            .baseline = @as(f64, @floatFromInt(ffi.pango.pango_layout_get_baseline(self))) / pango_scale,
        };
    }

    pub fn draw(self: *Layout, cairo: *Cairo) void {
        ffi.pangocairo.pango_cairo_show_layout(cairo, self);
    }
};

const FontDescription = opaque {
    fn create(font: [:0]const u8) CreateError!*FontDescription {
        return ffi.pango.pango_font_description_from_string(font) orelse error.CreateFailed;
    }
    const destroy = ffi.pango.pango_font_description_free;
};

pub const FontContext = struct {
    pub const Settings = struct {
        /// Positive scale numerator, with a denominator of 120.
        scale: u32,
        subpixel: Cairo.SubpixelOrder,

        pub fn eql(self: Settings, other: Settings) bool {
            return self.scale == other.scale and self.subpixel == other.subpixel;
        }
    };
    pub const InitError = CreateError || Cairo.CreateError;

    font: *FontDescription,
    font_size: f64,
    font_options: *Cairo.FontOptions,
    context: *Context,
    settings: Settings,

    pub fn init(font_name: [:0]const u8, settings: Settings) InitError!FontContext {
        const font = try FontDescription.create(font_name);
        errdefer font.destroy();
        const options = try Cairo.FontOptions.create();
        errdefer options.destroy();
        options.setHintStyle(.full);
        options.setAntialias(.subpixel);
        options.setSubpixelOrder(settings.subpixel);
        const context = try Context.create();
        errdefer context.destroy();
        ffi.pangocairo.pango_cairo_context_set_resolution(context, -1);
        const factor = @as(f64, @floatFromInt(settings.scale)) / 120.0;
        const matrix: Matrix = .{ .xx = factor, .yy = factor };
        ffi.pango.pango_context_set_matrix(context, &matrix);
        ffi.pangocairo.pango_cairo_context_set_font_options(context, options);
        return .{
            .font = font,
            .font_size = @as(f64, @floatFromInt(ffi.pango.pango_font_description_get_size(font))) / pango_scale,
            .font_options = options,
            .context = context,
            .settings = settings,
        };
    }

    pub fn deinit(self: *FontContext) void {
        self.context.destroy();
        self.font_options.destroy();
        self.font.destroy();
        self.* = undefined;
    }

    /// Apply the same output settings to frame and cache drawing contexts.
    pub fn setupCairo(self: *const FontContext, cairo: *Cairo) void {
        cairo.identityMatrix();
        const factor = @as(f64, @floatFromInt(self.settings.scale)) / 120.0;
        cairo.scale(factor, factor);
        cairo.setAntialias(.best);
        cairo.setFontOptions(self.font_options);
    }

    pub fn createLayout(self: *const FontContext, content: []const u8) CreateError!*Layout {
        return .create(self.context, self.font, content);
    }

    pub fn measureAlphabet(self: *const FontContext) CreateError!Layout.Metrics {
        const layout = try self.createLayout("");
        defer layout.destroy();
        var result: Layout.Metrics = .{ .width = 0, .height = 0, .baseline = 0 };
        for ("ABCDEFGHIJKLMNOPQRSTUVWXYZ") |letter| {
            ffi.pango.pango_layout_set_text(layout, &.{letter}, 1);
            const measured = layout.metrics();
            result.width = @max(result.width, measured.width);
            result.height = @max(result.height, measured.height);
            if (letter == 'F') result.baseline = measured.baseline;
        }
        return result;
    }
};

const ffi = struct {
    const pango = struct {
        extern fn pango_font_map_create_context(map: *FontMap) ?*Context;
        extern fn pango_context_set_matrix(context: *Context, matrix: *const Matrix) void;
        extern fn pango_layout_new(context: *Context) ?*Layout;
        extern fn pango_font_description_from_string(str: [*:0]const u8) ?*FontDescription;
        extern fn pango_font_description_get_size(desc: *const FontDescription) c_int;
        extern fn pango_layout_set_font_description(layout: *Layout, desc: *const FontDescription) void;
        extern fn pango_font_description_free(desc: *FontDescription) void;
        extern fn pango_layout_set_text(layout: *Layout, text: [*]const u8, length: c_int) void;
        extern fn pango_layout_get_pixel_extents(layout: *Layout, ink_rect: ?*Rectangle, logical_rect: ?*Rectangle) void;
        extern fn pango_layout_get_baseline(layout: *Layout) c_int;
    };

    const pangocairo = struct {
        extern fn pango_cairo_font_map_get_default() ?*FontMap;
        extern fn pango_cairo_context_set_font_options(context: *Context, options: *const Cairo.FontOptions) void;
        extern fn pango_cairo_context_set_resolution(context: *Context, dpi: f64) void;
        extern fn pango_cairo_show_layout(cairo: *Cairo, layout: *Layout) void;
    };

    const gobject = struct {
        extern fn g_object_unref(object: *anyopaque) void;
    };
};
