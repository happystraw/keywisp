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

pub const Style = struct {
    panel_background: Color = .rgba(0x191724F2),
    panel_border_color: Color = .rgba(0x6E6A86FF),
    panel_border_width: u32 = 2,
    panel_radius: u32 = 12,
    key_background: Color = .rgba(0x1F1D2EFF),
    key_border_color: Color = .rgba(0x403D52FF),
    key_border_width: u32 = 1,
    key_radius: u32 = 7,
    text_color: Color = .rgba(0xC4A7E7FF),
    history_color: Color = .rgba(0x908CAAFF),
    font: [:0]const u8 = "Sans Bold 16",
    max_width: i32 = 600,
    panel_padding: ?i32 = null,
    key_padding_horizontal: ?i32 = null,
    key_padding_vertical: ?i32 = null,
    key_gap: ?i32 = null,
};

position: Position = .bottom,
margin: i32 = 24,
style: Style = .{},

pub const Theme = enum {
    dark,
    light,
    wisp_dark,
    wisp_light,
};

pub fn themed(theme: Theme) Appearance {
    return .{
        .style = switch (theme) {
            .dark => .{},
            .light => .{
                .panel_background = .rgba(0xFAF4EDF2),
                .panel_border_color = .rgba(0x9893A5FF),
                .key_background = .rgba(0xFFFAF3FF),
                .key_border_color = .rgba(0xF2E9E1FF),
                .text_color = .rgba(0x907AA9FF),
                .history_color = .rgba(0x797593FF),
            },
            .wisp_dark => .{
                .panel_background = .rgba(0x00000000),
                .panel_border_color = .rgba(0x6E6A86C0),
                .panel_border_width = 0,
                .key_background = .rgba(0x1F1D2EE6),
                .key_border_color = .rgba(0x6E6A86C0),
                .text_color = .rgba(0xC4A7E7FF),
                .history_color = .rgba(0x908CAAFF),
            },
            .wisp_light => .{
                .panel_background = .rgba(0x00000000),
                .panel_border_color = .rgba(0x9893A5C0),
                .panel_border_width = 0,
                .key_background = .rgba(0xFFFAF3E8),
                .key_border_color = .rgba(0x9893A5C0),
                .text_color = .rgba(0x907AA9FF),
                .history_color = .rgba(0x797593FF),
            },
        },
    };
}
