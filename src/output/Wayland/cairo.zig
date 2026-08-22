const std = @import("std");

pub const Cairo = opaque {
    pub const Operator = enum(c_int) { clear = 0, source = 1, _ };
    pub const Antialias = enum(c_int) { subpixel = 3, best = 6, _ };
    pub const HintStyle = enum(c_int) { full = 4, _ };
    pub const SubpixelOrder = enum(c_int) { default = 0, rgb = 1, bgr = 2, vrgb = 3, vbgr = 4, _ };
    pub const Content = enum(c_int) { color_alpha = 0x3000, _ };
    pub const Format = enum(c_int) { argb32 = 0, _ };
    pub const CreateError = std.mem.Allocator.Error || error{CairoInitializationFailed};
    pub const Status = enum(c_int) {
        success = 0,
        no_memory = 1,
        _,

        fn toError(self: Status) ?CreateError {
            return switch (self) {
                .success => null,
                .no_memory => error.OutOfMemory,
                else => error.CairoInitializationFailed,
            };
        }
    };

    pub const Rectangle = extern struct { x: f64, y: f64, width: f64, height: f64 };

    pub const Surface = opaque {
        pub const destroy = ffi.cairo.cairo_surface_destroy;
        pub const status = ffi.cairo.cairo_surface_status;

        pub fn recording(content: Content, extents: ?*const Rectangle) CreateError!*Surface {
            const surface = ffi.cairo.cairo_recording_surface_create(content, extents);
            const err = surface.status().toError() orelse return surface;
            surface.destroy();
            return err;
        }

        pub fn image(data: [*]u8, format: Format, width: i32, height: i32, stride: i32) CreateError!*Surface {
            const surface = ffi.cairo.cairo_image_surface_create_for_data(data, format, width, height, stride);
            const err = surface.status().toError() orelse return surface;
            surface.destroy();
            return err;
        }
    };

    pub const FontOptions = opaque {
        pub fn create() CreateError!*FontOptions {
            const options = ffi.cairo.cairo_font_options_create();
            const err = ffi.cairo.cairo_font_options_status(options).toError() orelse return options;
            ffi.cairo.cairo_font_options_destroy(options);
            return err;
        }

        pub const destroy = ffi.cairo.cairo_font_options_destroy;
        pub const setHintStyle = ffi.cairo.cairo_font_options_set_hint_style;
        pub const setAntialias = ffi.cairo.cairo_font_options_set_antialias;
        pub const setSubpixelOrder = ffi.cairo.cairo_font_options_set_subpixel_order;
    };

    pub fn create(surface: *Surface) CreateError!*Cairo {
        const cairo = ffi.cairo.cairo_create(surface);
        const err = cairo.status().toError() orelse return cairo;
        cairo.destroy();
        return err;
    }
    pub const destroy = ffi.cairo.cairo_destroy;
    pub const status = ffi.cairo.cairo_status;
    pub const save = ffi.cairo.cairo_save;
    pub const restore = ffi.cairo.cairo_restore;
    pub const scale = ffi.cairo.cairo_scale;
    pub const setOperator = ffi.cairo.cairo_set_operator;

    pub const setSourceRgba = ffi.cairo.cairo_set_source_rgba;
    pub const paint = ffi.cairo.cairo_paint;
    pub const setAntialias = ffi.cairo.cairo_set_antialias;
    pub const setFontOptions = ffi.cairo.cairo_set_font_options;
    pub const rectangle = ffi.cairo.cairo_rectangle;
    pub const newSubPath = ffi.cairo.cairo_new_sub_path;
    pub const arc = ffi.cairo.cairo_arc;
    pub const closePath = ffi.cairo.cairo_close_path;
    pub const fillPreserve = ffi.cairo.cairo_fill_preserve;
    pub const fill = ffi.cairo.cairo_fill;
    pub const setLineWidth = ffi.cairo.cairo_set_line_width;
    pub const stroke = ffi.cairo.cairo_stroke;
    pub const moveTo = ffi.cairo.cairo_move_to;
};

const ffi = struct {
    const cairo = struct {
        extern fn cairo_create(surface: *Cairo.Surface) *Cairo;
        extern fn cairo_destroy(cairo: *Cairo) void;
        extern fn cairo_status(cairo: *Cairo) Cairo.Status;
        extern fn cairo_save(cairo: *Cairo) void;
        extern fn cairo_restore(cairo: *Cairo) void;
        extern fn cairo_scale(cairo: *Cairo, x: f64, y: f64) void;
        extern fn cairo_set_operator(cairo: *Cairo, op: Cairo.Operator) void;
        extern fn cairo_set_source_rgba(cairo: *Cairo, r: f64, g: f64, b: f64, a: f64) void;
        extern fn cairo_paint(cairo: *Cairo) void;
        extern fn cairo_set_antialias(cairo: *Cairo, aa: Cairo.Antialias) void;
        extern fn cairo_font_options_create() *Cairo.FontOptions;
        extern fn cairo_font_options_destroy(options: *Cairo.FontOptions) void;
        extern fn cairo_font_options_status(options: *Cairo.FontOptions) Cairo.Status;
        extern fn cairo_font_options_set_hint_style(options: *Cairo.FontOptions, style: Cairo.HintStyle) void;
        extern fn cairo_font_options_set_antialias(options: *Cairo.FontOptions, aa: Cairo.Antialias) void;
        extern fn cairo_font_options_set_subpixel_order(options: *Cairo.FontOptions, order: Cairo.SubpixelOrder) void;
        extern fn cairo_set_font_options(cairo: *Cairo, options: *const Cairo.FontOptions) void;
        extern fn cairo_rectangle(cairo: *Cairo, x: f64, y: f64, width: f64, height: f64) void;
        extern fn cairo_new_sub_path(cairo: *Cairo) void;
        extern fn cairo_arc(cairo: *Cairo, xc: f64, yc: f64, radius: f64, angle1: f64, angle2: f64) void;
        extern fn cairo_close_path(cairo: *Cairo) void;
        extern fn cairo_fill(cairo: *Cairo) void;
        extern fn cairo_fill_preserve(cairo: *Cairo) void;
        extern fn cairo_set_line_width(cairo: *Cairo, width: f64) void;
        extern fn cairo_stroke(cairo: *Cairo) void;
        extern fn cairo_move_to(cairo: *Cairo, x: f64, y: f64) void;
        extern fn cairo_recording_surface_create(content: Cairo.Content, extents: ?*const Cairo.Rectangle) *Cairo.Surface;
        extern fn cairo_surface_destroy(surface: *Cairo.Surface) void;
        extern fn cairo_surface_status(surface: *Cairo.Surface) Cairo.Status;
        extern fn cairo_image_surface_create_for_data(data: [*]u8, format: Cairo.Format, width: i32, height: i32, stride: i32) *Cairo.Surface;
    };
};
