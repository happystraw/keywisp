const std = @import("std");
const Args = std.process.Args;
const ArgIterator = Args.Iterator;

const project = @import("project");

const App = @import("App.zig");
const Output = @import("App/Output.zig");
const WaylandOptions = Output.WaylandOptions;
const WriterOptions = Output.WriterOptions;
const Color = WaylandOptions.Color;
const Position = WaylandOptions.Position;
const Theme = WaylandOptions.Theme;

pub const USAGE =
    "usage: " ++ project.name ++
    \\ [options]
    \\
    \\general:
    \\  -s, --stdout                    write events to stdout instead of Wayland
    \\  -t, --timeout MS                clear after inactivity; 0 disables (default: 1500)
    \\  -B, --pointer-buttons           show pointer button presses
    \\  -S, --pointer-scroll            show pointer scroll events
    \\  -h, --help                      show this help
    \\  -V, --version                   show version information
    \\
    \\wayland:
    \\  --theme THEME                   dark, light, wisp-dark, or wisp-light
    \\                                  (default: dark)
    \\                                  explicit appearance options override the theme
    \\  -p, --position POSITION         center, top, bottom, left, right, or a corner
    \\                                  corners: top-left, top-right,
    \\                                           bottom-left, bottom-right
    \\  -m, --margin PX                 distance from the anchored edge(s)
    \\  -w, --max-width PX              panel width limit (must be > 0)
    \\                                  rounding may add 1px; the newest key is always shown in full
    \\  -f, --font FONT                 Pango font description
    \\  --panel-padding PX              padding between panel and keycaps
    \\  --key-padding-horizontal PX     horizontal padding inside the keycap face
    \\  --key-padding-vertical PX       vertical padding inside the keycap face
    \\  --key-gap PX                    gap between keycaps
    \\
    \\  --panel-background COLOR        panel background color
    \\  --panel-border-color COLOR      panel border color
    \\  --panel-border-width PX         panel border width; 0 disables border
    \\  --panel-radius PX               panel corner radius; 0 makes corners sharp
    \\
    \\  --key-background COLOR          key background color
    \\  --key-border-color COLOR        key outer border color
    \\  --key-border-width PX           key outer border width; 0 disables outer border
    \\  --key-radius PX                 key corner radius; 0 makes corners sharp
    \\  --key-depth PX[,PX...]          1-4 comma-separated slope sizes; 0 makes it flat
    \\                                  1: all; 2: vertical,horizontal; 3: top,horizontal,bottom
    \\                                  4: top,right,bottom,left
    \\  --key-shadow-color COLOR        shadow color; alpha 00 disables shadow
    \\  --key-shadow-blur PX            shadow softness; 0 makes it sharp
    \\  --key-shadow-offset-x PX        horizontal shadow offset; may be negative
    \\  --key-shadow-offset-y PX        vertical shadow offset; may be negative
    \\
    \\  --text-color COLOR              previous key text color
    \\  --text-highlight-color COLOR    newest key text color
    \\
    \\  --no-collapse-repetitions       show repeated inputs as separate keycaps
    \\
    \\stdout:
    \\  --stdout-history COUNT          entries in each line (default: 1; must be > 0)
    \\  --stdout-emit-clear             emit an empty line when history clears
    \\
    \\PX:    logical pixels; decimals allowed; --margin and --max-width require integers
    \\       values must be non-negative, except shadow offsets
    \\FONT:  Pango font description (default: "Sans Bold 16")
    \\COLOR: RRGGBB or RRGGBBAA (FF is opaque, 00 is transparent)
    \\
    ;

pub const VERSION = project.name ++ " " ++ project.version;

pub const Backend = std.meta.Tag(Output.Options);

pub const RunOptions = struct {
    app: App.Options = .{},
    output: Output.Options = .{ .wayland = .{} },
};

pub const Diagnostic = struct {
    kind: Kind,
    option: []const u8 = "",
    value: []const u8 = "",
    backend: Backend = .wayland,

    pub const Kind = enum {
        unknown_option,
        missing_value,
        unexpected_value,
        invalid_value,
        wrong_backend,
    };

    pub fn write(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .unknown_option => try writer.print("unknown option: {s}\n", .{self.option}),
            .missing_value => try writer.print("option '{s}' requires an argument\n", .{self.option}),
            .unexpected_value => try writer.print("option '{s}' does not take an argument\n", .{self.option}),
            .invalid_value => try writer.print("invalid value for '{s}': {s}\n", .{ self.option, self.value }),
            .wrong_backend => switch (self.backend) {
                .writer => try writer.print("option '{s}' requires --stdout\n", .{self.option}),
                .wayland => try writer.print("option '{s}' is unavailable with --stdout\n", .{self.option}),
            },
        }
    }
};

pub const ParseResult = union(enum) {
    help,
    version,
    run: RunOptions,
    diagnostic: Diagnostic,
};

pub fn parse(args: Args) ParseResult {
    var options: RunOptions = .{
        .output = switch (scan(args)) {
            .output => |output| output,
            .help => return .{ .help = {} },
            .version => return .{ .version = {} },
            .diagnostic => |diagnostic| return .{ .diagnostic = diagnostic },
        },
    };

    var iterator = args.iterate();
    _ = iterator.skip();
    while (iterator.next()) |arg| {
        const option = Option.init(arg);
        if (!std.mem.startsWith(u8, arg, "-")) return .{
            .diagnostic = option.unknown(),
        };

        if (isOption(option.name, "--timeout", "-t")) {
            const value = option.value orelse iterator.next() orelse
                return .{ .diagnostic = option.missingValue() };
            const timeout_ms = parseInt(i32, value) orelse
                return .{ .diagnostic = option.invalidValue(value) };
            if (timeout_ms < 0) return .{ .diagnostic = option.invalidValue(value) };
            options.app.timeout_ms = timeout_ms;
            continue;
        }
        if (isOption(option.name, "--pointer-buttons", "-B")) {
            if (option.rejectValue()) |diagnostic| return .{ .diagnostic = diagnostic };
            options.app.pointer.buttons = true;
            continue;
        }
        if (isOption(option.name, "--pointer-scroll", "-S")) {
            if (option.rejectValue()) |diagnostic| return .{ .diagnostic = diagnostic };
            options.app.pointer.scroll = true;
            continue;
        }
        if (writer_options.get(option.name)) |writer_option| {
            switch (options.output) {
                .wayland => return .{ .diagnostic = option.wrongBackend(.writer) },
                .writer => |*options_writer| {
                    if (applyWriterOption(options_writer, writer_option, option, &iterator)) |diagnostic|
                        return .{ .diagnostic = diagnostic };
                },
            }
        } else if (wayland_options.get(option.name)) |wayland_option| {
            switch (options.output) {
                .wayland => |*appearance| {
                    if (applyWaylandOption(appearance, wayland_option, option, &iterator)) |diagnostic|
                        return .{ .diagnostic = diagnostic };
                },
                .writer => return .{ .diagnostic = option.wrongBackend(.wayland) },
            }
        } else {
            return .{ .diagnostic = option.unknown() };
        }
    }
    return .{ .run = options };
}

const ScanResult = union(enum) {
    help,
    version,
    output: Output.Options,
    diagnostic: Diagnostic,
};

fn scan(args: Args) ScanResult {
    var stdout = false;
    var theme: Theme = .dark;
    var diagnostic: ?Diagnostic = null;

    var iterator = args.iterate();
    _ = iterator.skip();
    while (iterator.next()) |arg| {
        if (isOption(arg, "--help", "-h")) return .{ .help = {} };
        if (isOption(arg, "--version", "-V")) return .{ .version = {} };

        const option = Option.init(arg);
        if (isOption(option.name, "--stdout", "-s")) {
            if (option.rejectValue()) |invalid| {
                if (diagnostic == null) diagnostic = invalid;
            } else {
                stdout = true;
            }
            continue;
        }

        if (!std.mem.eql(u8, option.name, "--theme")) continue;
        const value = option.value orelse value: {
            const next = iterator.next() orelse {
                if (diagnostic == null) diagnostic = option.missingValue();
                continue;
            };
            if (isOption(next, "--help", "-h")) return .{ .help = {} };
            if (isOption(next, "--version", "-V")) return .{ .version = {} };
            break :value next;
        };
        if (parseTheme(value)) |selected| {
            theme = selected;
        } else if (diagnostic == null) {
            diagnostic = option.invalidValue(value);
        }
    }

    if (diagnostic) |invalid| return .{ .diagnostic = invalid };
    if (stdout) return .{ .output = .{ .writer = .{} } };
    return .{ .output = .{ .wayland = WaylandOptions.themed(theme) } };
}

const StyleOption = std.meta.FieldEnum(WaylandOptions.Style);
const WaylandOption = union(enum) { theme, position, margin, no_collapse_repetitions, style: StyleOption };
const wayland_options = std.StaticStringMap(WaylandOption).initComptime(.{
    .{ "--theme", .theme },
    .{ "--position", .position },
    .{ "-p", .position },
    .{ "--margin", .margin },
    .{ "-m", .margin },
    .{ "--font", WaylandOption{ .style = .font } },
    .{ "-f", WaylandOption{ .style = .font } },
    .{ "--max-width", WaylandOption{ .style = .max_width } },
    .{ "-w", WaylandOption{ .style = .max_width } },
    .{ "--panel-padding", WaylandOption{ .style = .panel_padding } },
    .{ "--key-padding-horizontal", WaylandOption{ .style = .key_padding_horizontal } },
    .{ "--key-padding-vertical", WaylandOption{ .style = .key_padding_vertical } },
    .{ "--key-gap", WaylandOption{ .style = .key_gap } },
    .{ "--panel-background", WaylandOption{ .style = .panel_background } },
    .{ "--panel-border-color", WaylandOption{ .style = .panel_border_color } },
    .{ "--panel-border-width", WaylandOption{ .style = .panel_border_width } },
    .{ "--panel-radius", WaylandOption{ .style = .panel_radius } },
    .{ "--key-background", WaylandOption{ .style = .key_background } },
    .{ "--key-border-color", WaylandOption{ .style = .key_border_color } },
    .{ "--key-border-width", WaylandOption{ .style = .key_border_width } },
    .{ "--key-radius", WaylandOption{ .style = .key_radius } },
    .{ "--key-depth", WaylandOption{ .style = .key_depth } },
    .{ "--key-shadow-color", WaylandOption{ .style = .key_shadow_color } },
    .{ "--key-shadow-blur", WaylandOption{ .style = .key_shadow_blur } },
    .{ "--key-shadow-offset-x", WaylandOption{ .style = .key_shadow_offset_x } },
    .{ "--key-shadow-offset-y", WaylandOption{ .style = .key_shadow_offset_y } },
    .{ "--text-color", WaylandOption{ .style = .text_color } },
    .{ "--text-highlight-color", WaylandOption{ .style = .text_highlight_color } },
    .{ "--no-collapse-repetitions", .no_collapse_repetitions },
});
fn applyWaylandOption(
    appearance: *WaylandOptions,
    kind: WaylandOption,
    option: Option,
    args: *ArgIterator,
) ?Diagnostic {
    if (kind == .no_collapse_repetitions) {
        if (option.rejectValue()) |diagnostic| return diagnostic;
        appearance.collapse_repetitions = false;
        return null;
    }

    const value = option.value orelse args.next() orelse return option.missingValue();
    switch (kind) {
        .no_collapse_repetitions => unreachable,
        .theme => {},
        .position => appearance.position = parsePosition(value) orelse return option.invalidValue(value),
        .margin => {
            const margin = parseInt(i32, value) orelse return option.invalidValue(value);
            if (margin < 0) return option.invalidValue(value);
            appearance.margin = margin;
        },
        .style => |style| switch (style) {
            .font => appearance.style.font = value,
            .max_width => {
                const max_width = parseInt(i32, value) orelse return option.invalidValue(value);
                if (max_width <= 0) return option.invalidValue(value);
                appearance.style.max_width = max_width;
            },
            .panel_padding => appearance.style.panel_padding = parseSpacing(value) orelse return option.invalidValue(value),
            .key_padding_horizontal => appearance.style.key_padding_horizontal = parseSpacing(value) orelse return option.invalidValue(value),
            .key_padding_vertical => appearance.style.key_padding_vertical = parseSpacing(value) orelse return option.invalidValue(value),
            .key_gap => appearance.style.key_gap = parseSpacing(value) orelse return option.invalidValue(value),
            .panel_background => appearance.style.panel_background = parseColor(value) orelse return option.invalidValue(value),
            .panel_border_color => appearance.style.panel_border_color = parseColor(value) orelse return option.invalidValue(value),
            .panel_border_width => appearance.style.panel_border_width = parseSpacing(value) orelse return option.invalidValue(value),
            .panel_radius => appearance.style.panel_radius = parseSpacing(value) orelse return option.invalidValue(value),
            .key_background => appearance.style.key_background = parseColor(value) orelse return option.invalidValue(value),
            .key_border_color => appearance.style.key_border_color = parseColor(value) orelse return option.invalidValue(value),
            .key_border_width => appearance.style.key_border_width = parseSpacing(value) orelse return option.invalidValue(value),
            .key_radius => appearance.style.key_radius = parseSpacing(value) orelse return option.invalidValue(value),
            .key_depth => appearance.style.key_depth = parseDepth(value) orelse return option.invalidValue(value),
            .key_shadow_color => appearance.style.key_shadow_color = parseColor(value) orelse return option.invalidValue(value),
            .key_shadow_blur => appearance.style.key_shadow_blur = parseSpacing(value) orelse return option.invalidValue(value),
            .key_shadow_offset_x => appearance.style.key_shadow_offset_x = parsePixels(value) orelse return option.invalidValue(value),
            .key_shadow_offset_y => appearance.style.key_shadow_offset_y = parsePixels(value) orelse return option.invalidValue(value),
            .text_color => appearance.style.text_color = parseColor(value) orelse return option.invalidValue(value),
            .text_highlight_color => appearance.style.text_highlight_color = parseColor(value) orelse return option.invalidValue(value),
        },
    }
    return null;
}

const WriterOption = option_enum: {
    const fields = std.meta.fieldNames(WriterOptions);
    const Tag = std.math.IntFittingRange(0, fields.len);
    var names: [fields.len + 1][]const u8 = undefined;
    var values: [fields.len + 1]Tag = undefined;
    names[0] = "stdout";
    values[0] = 0;
    for (fields, 1..) |name, i| {
        names[i] = name;
        values[i] = i;
    }
    break :option_enum @Enum(Tag, .exhaustive, &names, &values);
};
const writer_options = std.StaticStringMap(WriterOption).initComptime(.{
    .{ "--stdout", .stdout },
    .{ "-s", .stdout },
    .{ "--stdout-history", .history },
    .{ "--stdout-emit-clear", .emit_clear },
});
fn applyWriterOption(
    options: *WriterOptions,
    kind: WriterOption,
    option: Option,
    args: *ArgIterator,
) ?Diagnostic {
    switch (kind) {
        .stdout => {},
        .history => {
            const value = option.value orelse args.next() orelse return option.missingValue();
            const count = parseInt(usize, value) orelse return option.invalidValue(value);
            if (count == 0) return option.invalidValue(value);
            options.history = count;
        },
        .emit_clear => {
            if (option.rejectValue()) |diagnostic| return diagnostic;
            options.emit_clear = true;
        },
    }
    return null;
}

const Option = struct {
    name: []const u8,
    value: ?[:0]const u8,

    fn init(arg: [:0]const u8) Option {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq|
            return .{ .name = arg[0..eq], .value = arg[eq + 1 .. :0] };
        return .{ .name = arg, .value = null };
    }

    fn rejectValue(self: Option) ?Diagnostic {
        if (self.value == null) return null;
        return self.unexpectedValue();
    }

    fn unknown(self: Option) Diagnostic {
        return .{ .kind = .unknown_option, .option = self.name };
    }

    fn unexpectedValue(self: Option) Diagnostic {
        return .{ .kind = .unexpected_value, .option = self.name };
    }

    fn missingValue(self: Option) Diagnostic {
        return .{ .kind = .missing_value, .option = self.name };
    }

    fn invalidValue(self: Option, value: []const u8) Diagnostic {
        return .{ .kind = .invalid_value, .option = self.name, .value = value };
    }

    fn wrongBackend(self: Option, backend: Backend) Diagnostic {
        return .{ .kind = .wrong_backend, .option = self.name, .backend = backend };
    }
};

fn parseColor(value: []const u8) ?Color {
    if (value.len != 6 and value.len != 8) return null;
    const color = std.fmt.parseInt(u32, value, 16) catch return null;
    return .rgba(if (value.len == 6) (color << 8) | 0xFF else color);
}

fn parseInt(comptime T: type, value: []const u8) ?T {
    return std.fmt.parseInt(T, value, 10) catch null;
}

fn parseDepth(value: []const u8) ?WaylandOptions.Depth {
    var parts = std.mem.splitScalar(u8, value, ',');
    var sizes: [4]f64 = undefined;
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count == sizes.len) return null;
        const size = parseSpacing(std.mem.trim(u8, part, " \t")) orelse return null;
        sizes[count] = size;
        count += 1;
    }
    return .{
        .top = sizes[0],
        .right = if (count > 1) sizes[1] else sizes[0],
        .bottom = if (count > 2) sizes[2] else sizes[0],
        .left = if (count > 3) sizes[3] else if (count > 1) sizes[1] else sizes[0],
    };
}

fn parsePixels(value: []const u8) ?f64 {
    const pixels = std.fmt.parseFloat(f64, value) catch return null;
    return if (std.math.isFinite(pixels)) pixels else null;
}

fn parseSpacing(value: []const u8) ?f64 {
    const spacing = parsePixels(value) orelse return null;
    return if (spacing >= 0) spacing else null;
}

const positions = std.StaticStringMap(Position).initComptime(.{
    .{ "center", .center },
    .{ "top", .top },
    .{ "top-left", .top_left },
    .{ "top-right", .top_right },
    .{ "bottom", .bottom },
    .{ "bottom-left", .bottom_left },
    .{ "bottom-right", .bottom_right },
    .{ "left", .left },
    .{ "right", .right },
});

fn parsePosition(value: []const u8) ?Position {
    return positions.get(value);
}

const themes = std.StaticStringMap(Theme).initComptime(.{
    .{ "dark", .dark },
    .{ "light", .light },
    .{ "wisp-dark", .wisp_dark },
    .{ "wisp-light", .wisp_light },
});

fn parseTheme(value: []const u8) ?Theme {
    return themes.get(value);
}

fn isOption(name: []const u8, long: []const u8, short: []const u8) bool {
    return std.mem.eql(u8, name, long) or std.mem.eql(u8, name, short);
}

test "help takes precedence" {
    try std.testing.expect(parse(.{ .vector = &.{
        "test-cli",
        "--theme=unknown",
        "--stdout=yes",
        "--theme",
        "--help",
    } }) == .help);
}

test "version takes precedence" {
    try std.testing.expect(parse(.{ .vector = &.{
        "test-cli",
        "--theme",
        "--version",
    } }) == .version);
}

test "short options" {
    const options = switch (parse(.{ .vector = &.{
        "test-cli",
        "-t=250",
        "-p",
        "center",
        "-m=8",
        "-f",
        "Sans 14",
        "-w",
        "480",
        "-B",
        "-S",
    } })) {
        .run => |options| options,
        else => return error.UnexpectedResult,
    };
    try std.testing.expectEqual(250, options.app.timeout_ms);
    try std.testing.expect(options.app.pointer.buttons);
    try std.testing.expect(options.app.pointer.scroll);
    const appearance = switch (options.output) {
        .wayland => |appearance| appearance,
        .writer => return error.UnexpectedBackend,
    };
    try std.testing.expectEqual(Position.center, appearance.position);
    try std.testing.expectEqual(8, appearance.margin);
    try std.testing.expectEqualStrings("Sans 14", appearance.style.font);
    try std.testing.expectEqual(480, appearance.style.max_width);

    const stdout = switch (parse(.{ .vector = &.{ "test-cli", "-s" } })) {
        .run => |run_options| run_options,
        else => return error.UnexpectedResult,
    };
    try std.testing.expect(stdout.output == .writer);
    try std.testing.expect(parse(.{ .vector = &.{ "test-cli", "-h" } }) == .help);
    try std.testing.expect(parse(.{ .vector = &.{ "test-cli", "-V" } }) == .version);
}

test "defaults" {
    const options = switch (parse(.{ .vector = &.{"test-cli"} })) {
        .run => |options| options,
        else => return error.UnexpectedResult,
    };
    try std.testing.expectEqual(App.Options{}, options.app);
    switch (options.output) {
        .wayland => |appearance| {
            const expected = WaylandOptions.themed(.dark);
            try std.testing.expectEqual(expected.style.panel_background, appearance.style.panel_background);
            try std.testing.expect(appearance.collapse_repetitions);
        },
        .writer => return error.UnexpectedBackend,
    }
}

test "Wayland options override the selected theme" {
    const options = switch (parse(.{ .vector = &.{
        "test-cli",
        "--no-collapse-repetitions",
        "--theme=dark",
        "--theme",
        "light",
        "--panel-background",
        "123456",
        "--panel-border-color=ABCDEF80",
        "--position",
        "top-right",
        "--panel-padding=8",
        "--key-padding-horizontal=10",
        "--key-padding-vertical=5",
        "--key-gap=4",
        "--key-depth=5",
        "--key-shadow-color=00000060",
        "--key-shadow-blur=6",
        "--key-shadow-offset-x=-2",
        "--key-shadow-offset-y=3",
    } })) {
        .run => |options| options,
        else => return error.UnexpectedResult,
    };

    const appearance = switch (options.output) {
        .wayland => |appearance| appearance,
        .writer => return error.UnexpectedBackend,
    };
    try std.testing.expectEqual(Color.rgba(0x123456FF), appearance.style.panel_background);
    try std.testing.expect(!appearance.collapse_repetitions);
    try std.testing.expectEqual(Color.rgba(0xABCDEF80), appearance.style.panel_border_color);
    try std.testing.expectEqual(0x12, appearance.style.panel_background.r);
    try std.testing.expectEqual(0x34, appearance.style.panel_background.g);
    try std.testing.expectEqual(0x56, appearance.style.panel_background.b);
    try std.testing.expectEqual(0xFF, appearance.style.panel_background.a);
    try std.testing.expectEqual(WaylandOptions.themed(.light).style.text_highlight_color, appearance.style.text_highlight_color);
    try std.testing.expectEqual(Position.top_right, appearance.position);
    try std.testing.expectEqual(8, appearance.style.panel_padding);
    try std.testing.expectEqual(10, appearance.style.key_padding_horizontal);
    try std.testing.expectEqual(5, appearance.style.key_padding_vertical);
    try std.testing.expectEqual(4, appearance.style.key_gap);
    try std.testing.expectEqualDeep(WaylandOptions.Depth.uniform(5), appearance.style.key_depth.?);
    try std.testing.expectEqual(Color.rgba(0x00000060), appearance.style.key_shadow_color);
    try std.testing.expectEqual(6, appearance.style.key_shadow_blur);
    try std.testing.expectEqual(-2, appearance.style.key_shadow_offset_x);
    try std.testing.expectEqual(3, appearance.style.key_shadow_offset_y);
}

test "stdout options may precede stdout" {
    const options = switch (parse(.{ .vector = &.{
        "test-cli",
        "--stdout-history",
        "3",
        "--pointer-scroll",
        "--stdout",
        "--stdout-emit-clear",
    } })) {
        .run => |options| options,
        else => return error.UnexpectedResult,
    };

    try std.testing.expect(options.app.pointer.scroll);
    switch (options.output) {
        .wayland => return error.UnexpectedBackend,
        .writer => |writer| {
            try std.testing.expectEqual(3, writer.history);
            try std.testing.expect(writer.emit_clear);
        },
    }
}

test "integer boundaries" {
    const options = switch (parse(.{ .vector = &.{
        "test-cli",
        "--timeout=2147483647",
        "--max-width=1",
        "--margin=0",
    } })) {
        .run => |options| options,
        else => return error.UnexpectedResult,
    };
    try std.testing.expectEqual(std.math.maxInt(i32), options.app.timeout_ms);

    const no_timeout = switch (parse(.{ .vector = &.{ "test-cli", "--timeout=0" } })) {
        .run => |run_options| run_options,
        else => return error.UnexpectedResult,
    };
    try std.testing.expectEqual(0, no_timeout.app.timeout_ms);

    inline for (.{
        .{ "--timeout", "-1" },
        .{ "--max-width", "0" },
        .{ "--panel-radius", "-1" },
        .{ "--panel-padding", "-1" },
        .{ "--key-padding-horizontal", "-1" },
        .{ "--key-padding-vertical", "-1" },
        .{ "--key-gap", "-1" },
        .{ "--key-depth", "-1" },
        .{ "--key-shadow-blur", "-1" },
    }) |case| {
        const diagnostic = switch (parse(.{ .vector = &.{ "test-cli", case[0], case[1] } })) {
            .diagnostic => |diagnostic| diagnostic,
            else => return error.UnexpectedResult,
        };
        try std.testing.expectEqual(Diagnostic.Kind.invalid_value, diagnostic.kind);
        try std.testing.expectEqualStrings(case[0], diagnostic.option);
    }
}

test "diagnostics" {
    inline for (.{
        .{ &.{ "test-cli", "--bogus" }, Diagnostic.Kind.unknown_option, "--bogus" },
        .{ &.{ "test-cli", "--theme" }, Diagnostic.Kind.missing_value, "--theme" },
        .{ &.{ "test-cli", "--theme=unknown" }, Diagnostic.Kind.invalid_value, "--theme" },
        .{ &.{ "test-cli", "--panel-background=#123456" }, Diagnostic.Kind.invalid_value, "--panel-background" },
        .{ &.{ "test-cli", "--stdout=yes" }, Diagnostic.Kind.unexpected_value, "--stdout" },
        .{ &.{ "test-cli", "--no-collapse-repetitions=false" }, Diagnostic.Kind.unexpected_value, "--no-collapse-repetitions" },
        .{ &.{ "test-cli", "--no-collapse-repetitions", "--stdout" }, Diagnostic.Kind.wrong_backend, "--no-collapse-repetitions" },
    }) |case| {
        const diagnostic = switch (parse(.{ .vector = case[0] })) {
            .diagnostic => |diagnostic| diagnostic,
            else => return error.UnexpectedResult,
        };
        try std.testing.expectEqual(case[1], diagnostic.kind);
        try std.testing.expectEqualStrings(case[2], diagnostic.option);
    }
}

test "backend-specific options require the matching backend" {
    const writer = switch (parse(.{ .vector = &.{
        "test-cli",
        "--stdout-history",
        "2",
    } })) {
        .diagnostic => |diagnostic| diagnostic,
        else => return error.UnexpectedResult,
    };
    try std.testing.expectEqual(Diagnostic.Kind.wrong_backend, writer.kind);
    try std.testing.expectEqual(Backend.writer, writer.backend);

    const wayland = switch (parse(.{ .vector = &.{
        "test-cli",
        "--stdout",
        "--position",
        "top",
    } })) {
        .diagnostic => |diagnostic| diagnostic,
        else => return error.UnexpectedResult,
    };
    try std.testing.expectEqual(Diagnostic.Kind.wrong_backend, wayland.kind);
    try std.testing.expectEqual(Backend.wayland, wayland.backend);
}

test "key depth expands one to four sizes and overrides themes in either order" {
    const cases = [_]struct { value: [:0]const u8, expected: WaylandOptions.Depth }{
        .{ .value = "0", .expected = .uniform(0) },
        .{ .value = "4", .expected = .uniform(4) },
        .{ .value = "4,8", .expected = .{ .top = 4, .right = 8, .bottom = 4, .left = 8 } },
        .{ .value = "4,8,6", .expected = .{ .top = 4, .right = 8, .bottom = 6, .left = 8 } },
        .{ .value = "1,2,3,4", .expected = .{ .top = 1, .right = 2, .bottom = 3, .left = 4 } },
        .{ .value = "0, 0.25, 2.5, 4.75", .expected = .{ .top = 0, .right = 0.25, .bottom = 2.5, .left = 4.75 } },
    };
    for (cases) |case| {
        for ([_][:0]const u8{ "dark", "light", "wisp-dark", "wisp-light" }) |theme| {
            const orders = [_][5][*:0]const u8{
                .{ "test-cli", "--key-depth", case.value.ptr, "--theme", theme.ptr },
                .{ "test-cli", "--theme", theme.ptr, "--key-depth", case.value.ptr },
            };
            for (orders) |args| {
                const options = switch (parse(.{ .vector = &args })) {
                    .run => |options| options,
                    else => return error.UnexpectedResult,
                };
                try std.testing.expectEqualDeep(case.expected, options.output.wayland.style.key_depth.?);
            }
        }
    }
}

test "key depth rejects malformed and nonfinite sizes" {
    for ([_][:0]const u8{ "", ",", "1,", ",1", "1,,2", "1,2,3,4,5", "1:2:3:4", "1 2", "-1", "1,-2", "nan", "inf", "1,inf", "1e999", "4px" }) |value| {
        const diagnostic = switch (parse(.{ .vector = &.{ "test-cli", "--key-depth", value } })) {
            .diagnostic => |diagnostic| diagnostic,
            else => return error.UnexpectedResult,
        };
        try std.testing.expectEqual(Diagnostic.Kind.invalid_value, diagnostic.kind);
        try std.testing.expectEqualStrings("--key-depth", diagnostic.option);
    }
}

test "pixel styles accept decimals while margin and max width remain integers" {
    inline for (.{
        .{ "--panel-padding", "panel_padding" },
        .{ "--panel-radius", "panel_radius" },
        .{ "--panel-border-width", "panel_border_width" },
        .{ "--key-padding-horizontal", "key_padding_horizontal" },
        .{ "--key-padding-vertical", "key_padding_vertical" },
        .{ "--key-gap", "key_gap" },
        .{ "--key-radius", "key_radius" },
        .{ "--key-border-width", "key_border_width" },
        .{ "--key-shadow-blur", "key_shadow_blur" },
        .{ "--key-shadow-offset-x", "key_shadow_offset_x" },
        .{ "--key-shadow-offset-y", "key_shadow_offset_y" },
    }) |option| {
        const options = switch (parse(.{ .vector = &.{ "test-cli", option[0], "1.25" } })) {
            .run => |options| options,
            else => return error.UnexpectedResult,
        };
        try std.testing.expectEqual(1.25, @field(options.output.wayland.style, option[1]));
        for ([_][*:0]const u8{ "nan", "inf", "1e999" }) |value| {
            const result = parse(.{ .vector = &.{ "test-cli", option[0], value } });
            try std.testing.expectEqual(Diagnostic.Kind.invalid_value, result.diagnostic.kind);
        }
    }
    for ([_][*:0]const u8{ "--margin", "--max-width" }) |option| {
        const result = parse(.{ .vector = &.{ "test-cli", option, "1.25" } });
        try std.testing.expectEqual(Diagnostic.Kind.invalid_value, result.diagnostic.kind);
    }
    const offsets = parse(.{ .vector = &.{ "test-cli", "--key-shadow-offset-x=-1.25", "--key-shadow-offset-y=-0.5" } }).run.output.wayland.style;
    try std.testing.expectEqual(-1.25, offsets.key_shadow_offset_x);
    try std.testing.expectEqual(-0.5, offsets.key_shadow_offset_y);
}
