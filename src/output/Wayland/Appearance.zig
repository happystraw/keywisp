const zwlr = @import("wayland").client.zwlr;
const Anchor = zwlr.LayerSurfaceV1.Anchor;

const Appearance = @This();

pub const Color = packed struct(u32) {
    a: u8,
    b: u8,
    g: u8,
    r: u8,

    pub fn rgba(value: u32) Color {
        return @bitCast(value);
    }
};

pub const Position = enum {
    center,
    top,
    top_left,
    top_right,
    bottom,
    bottom_left,
    bottom_right,
    left,
    right,

    pub fn anchor(position: Position) Anchor {
        return switch (position) {
            .center => .{},
            .top => .{ .top = true },
            .top_left => .{ .top = true, .left = true },
            .top_right => .{ .top = true, .right = true },
            .bottom => .{ .bottom = true },
            .bottom_left => .{ .bottom = true, .left = true },
            .bottom_right => .{ .bottom = true, .right = true },
            .left => .{ .left = true },
            .right => .{ .right = true },
        };
    }
};

pub const Depth = struct {
    top: f64,
    right: f64,
    bottom: f64,
    left: f64,

    pub fn uniform(value: f64) Depth {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
};

pub const Style = struct {
    max_width: i32 = 600,

    panel_background: Color,
    panel_border_color: Color,
    panel_border_width: f64 = 2,
    panel_radius: ?f64 = null,
    panel_padding: ?f64 = null,

    key_background: Color,
    key_border_color: Color,
    key_border_width: f64 = 1,
    key_radius: ?f64 = null,
    key_depth: ?Depth = null,
    key_padding_horizontal: ?f64 = null,
    key_padding_vertical: ?f64 = null,
    key_gap: ?f64 = null,

    key_shadow_color: Color,
    key_shadow_blur: ?f64 = null,
    key_shadow_offset_x: ?f64 = null,
    key_shadow_offset_y: ?f64 = null,

    font: [:0]const u8 = "Sans Bold 16",
    text_color: Color,
    text_highlight_color: Color,
};

position: Position = .bottom,
margin: i32 = 24,
collapse_repetitions: bool = true,
style: Style = themeStyle(.dark),

pub const Theme = enum {
    dark,
    light,
    wisp_dark,
    wisp_light,
};

pub fn themed(theme: Theme) Appearance {
    return .{ .style = themeStyle(theme) };
}

fn themeStyle(theme: Theme) Style {
    return switch (theme) {
        .dark => .{
            .panel_background = .rgba(0x191724F2),
            .panel_border_color = .rgba(0x6E6A86FF),
            .key_background = .rgba(0x1F1D2EFF),
            .key_border_color = .rgba(0x524D65FF),
            .key_depth = .uniform(0),
            .key_shadow_color = .rgba(0x00000000),
            .key_shadow_blur = 0,
            .key_shadow_offset_x = 0,
            .key_shadow_offset_y = 0,
            .text_color = .rgba(0x908CAAFF),
            .text_highlight_color = .rgba(0xC4A7E7FF),
        },
        .light => .{
            .panel_background = .rgba(0xFAF4EDF2),
            .panel_border_color = .rgba(0x9893A5FF),
            .key_background = .rgba(0xFFFAF3FF),
            .key_border_color = .rgba(0xDED3C8FF),
            .key_depth = .uniform(0),
            .key_shadow_color = .rgba(0x00000000),
            .key_shadow_blur = 0,
            .key_shadow_offset_x = 0,
            .key_shadow_offset_y = 0,
            .text_color = .rgba(0x797593FF),
            .text_highlight_color = .rgba(0x907AA9FF),
        },
        .wisp_dark => .{
            .panel_background = .rgba(0x00000000),
            .panel_border_color = .rgba(0x00000000),
            .panel_border_width = 0,
            .panel_padding = 0,
            .key_background = .rgba(0x363142FF),
            .key_border_color = .rgba(0x00000000),
            .key_border_width = 0,
            .key_shadow_color = .rgba(0x00000060),
            .text_color = .rgba(0xB2A8C0FF),
            .text_highlight_color = .rgba(0xE2D4FAFF),
        },
        .wisp_light => .{
            .panel_background = .rgba(0x00000000),
            .panel_border_color = .rgba(0x00000000),
            .panel_border_width = 0,
            .panel_padding = 0,
            .key_background = .rgba(0xF4EFE6FF),
            .key_border_color = .rgba(0x00000000),
            .key_border_width = 0,
            .key_shadow_color = .rgba(0x00000040),
            .text_color = .rgba(0x817787FF),
            .text_highlight_color = .rgba(0x70528FFF),
        },
    };
}
