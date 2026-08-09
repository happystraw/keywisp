const Cairo = @import("cairo.zig").Cairo;

const Rectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

const scale: c_int = 1024;

pub const CreateError = error{CreateFailed};

pub const Metrics = struct {
    width: i32,
    height: i32,
    baseline: i32,
};

pub const Layout = opaque {
    fn create(cairo: *Cairo) CreateError!*Layout {
        return ffi.pangocairo.pango_cairo_create_layout(cairo) orelse error.CreateFailed;
    }
    fn destroy(self: *Layout) void {
        ffi.gobject.g_object_unref(@ptrCast(self));
    }
    const setFontDescription = ffi.pango.pango_layout_set_font_description;
    fn setText(self: *Layout, content: []const u8) void {
        ffi.pango.pango_layout_set_text(self, content.ptr, @intCast(content.len));
    }
    fn metrics(self: *Layout) Metrics {
        var logical: Rectangle = undefined;
        ffi.pango.pango_layout_get_pixel_extents(self, null, &logical);
        return .{
            .width = logical.width,
            .height = logical.height,
            .baseline = @divTrunc(ffi.pango.pango_layout_get_baseline(self), scale),
        };
    }
    fn show(self: *Layout, cairo: *Cairo) void {
        ffi.pangocairo.pango_cairo_show_layout(cairo, self);
    }
};

const FontDescription = opaque {
    fn create(font: [:0]const u8) CreateError!*FontDescription {
        return ffi.pango.pango_font_description_from_string(font) orelse error.CreateFailed;
    }
    const destroy = ffi.pango.pango_font_description_free;
};

pub const text = struct {
    pub fn measure(cairo: *Cairo, font: [:0]const u8, content: []const u8) CreateError!Metrics {
        const layout = try Layout.create(cairo);
        defer layout.destroy();
        const desc = try FontDescription.create(font);
        defer desc.destroy();
        layout.setFontDescription(desc);
        layout.setText(content);
        return layout.metrics();
    }

    pub fn draw(cairo: *Cairo, font: [:0]const u8, content: []const u8) CreateError!void {
        const layout = try Layout.create(cairo);
        defer layout.destroy();
        const desc = try FontDescription.create(font);
        defer desc.destroy();
        layout.setFontDescription(desc);
        layout.setText(content);
        layout.show(cairo);
    }
};

const ffi = struct {
    const pango = struct {
        extern fn pango_font_description_from_string(str: [*:0]const u8) ?*FontDescription;
        extern fn pango_layout_set_font_description(layout: *Layout, desc: *const FontDescription) void;
        extern fn pango_font_description_free(desc: *FontDescription) void;
        extern fn pango_layout_set_text(layout: *Layout, text: [*]const u8, length: c_int) void;
        extern fn pango_layout_get_pixel_extents(layout: *Layout, ink_rect: ?*Rectangle, logical_rect: ?*Rectangle) void;
        extern fn pango_layout_get_baseline(layout: *Layout) c_int;
    };

    const pangocairo = struct {
        extern fn pango_cairo_create_layout(cairo: *Cairo) ?*Layout;
        extern fn pango_cairo_show_layout(cairo: *Cairo, layout: *Layout) void;
    };

    const gobject = struct {
        extern fn g_object_unref(object: *anyopaque) void;
    };
};
