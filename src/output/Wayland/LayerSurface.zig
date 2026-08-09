const wl = @import("wayland").client.wl;
const zwlr = @import("wayland").client.zwlr;

const LayerSurface = @This();

pub const Options = struct {
    anchor: zwlr.LayerSurfaceV1.Anchor = .{},
    margin: i32 = 0,
    namespace: [:0]const u8,
};

surface: *wl.Surface,
layer_surface: *zwlr.LayerSurfaceV1,
width: u32 = 0,
height: u32 = 0,

pub const InitError = error{
    CreateSurfaceFailed,
    GetLayerSurfaceFailed,
    CreateInputRegionFailed,
};

/// Creates an overlay layer surface with an empty input region.
pub fn init(compositor: *wl.Compositor, layer_shell: *zwlr.LayerShellV1, options: Options) InitError!LayerSurface {
    const surface = compositor.createSurface() catch return error.CreateSurfaceFailed;
    errdefer surface.destroy();
    const layer_surface = layer_shell.getLayerSurface(surface, null, .overlay, options.namespace.ptr) catch return error.GetLayerSurfaceFailed;
    errdefer layer_surface.destroy();
    const region = compositor.createRegion() catch return error.CreateInputRegionFailed;
    surface.setInputRegion(region);
    region.destroy();
    layer_surface.setAnchor(options.anchor);
    layer_surface.setMargin(options.margin, options.margin, options.margin, options.margin);
    layer_surface.setExclusiveZone(-1);
    layer_surface.setSize(1, 1);
    surface.commit();
    return .{ .surface = surface, .layer_surface = layer_surface };
}

pub fn deinit(self: *LayerSurface) void {
    self.layer_surface.destroy();
    self.surface.destroy();
}

pub fn setSize(self: *LayerSurface, width: u32, height: u32) void {
    self.layer_surface.setSize(width, height);
}
