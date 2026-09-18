const wl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const zwlr = @import("wayland").client.zwlr;

const LayerSurface = @This();

pub const Options = struct {
    anchor: zwlr.LayerSurfaceV1.Anchor = .{},
    margin: i32 = 0,
    namespace: [:0]const u8,
    viewporter: ?*wp.Viewporter = null,
    fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
};

surface: *wl.Surface,
layer_surface: *zwlr.LayerSurfaceV1,
viewport: ?*wp.Viewport = null,
fractional_scale: ?*wp.FractionalScaleV1 = null,
preferred_scale: ?u32 = null,
width: u32 = 0,
height: u32 = 0,

/// Creates an overlay layer surface with an empty input region.
pub fn init(compositor: *wl.Compositor, layer_shell: *zwlr.LayerShellV1, options: Options) !LayerSurface {
    const surface = try compositor.createSurface();
    errdefer surface.destroy();
    var viewport: ?*wp.Viewport = null;
    errdefer if (viewport) |value| value.destroy();
    var fractional_scale: ?*wp.FractionalScaleV1 = null;
    errdefer if (fractional_scale) |value| value.destroy();
    if (options.viewporter != null and options.fractional_scale_manager != null) {
        viewport = try options.viewporter.?.getViewport(surface);
        fractional_scale = try options.fractional_scale_manager.?.getFractionalScale(surface);
    }
    const layer_surface = try layer_shell.getLayerSurface(surface, null, .overlay, options.namespace.ptr);
    errdefer layer_surface.destroy();
    const region = try compositor.createRegion();
    surface.setInputRegion(region);
    region.destroy();
    layer_surface.setAnchor(options.anchor);
    layer_surface.setMargin(options.margin, options.margin, options.margin, options.margin);
    layer_surface.setExclusiveZone(-1);
    layer_surface.setSize(1, 1);
    surface.commit();
    return .{
        .surface = surface,
        .layer_surface = layer_surface,
        .viewport = viewport,
        .fractional_scale = fractional_scale,
    };
}

pub fn deinit(self: *LayerSurface) void {
    if (self.fractional_scale) |value| value.destroy();
    if (self.viewport) |value| value.destroy();
    self.layer_surface.destroy();
    self.surface.destroy();
}

pub fn setSize(self: *LayerSurface, width: u32, height: u32) void {
    self.layer_surface.setSize(width, height);
}
