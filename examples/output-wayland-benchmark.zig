const std = @import("std");
const output = @import("output");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const theme = args.next() orelse "wisp-light";
    const scale_percent = try std.fmt.parseInt(u32, args.next() orelse "100", 10);
    const frames = try std.fmt.parseInt(usize, args.next() orelse "300", 10);
    const font = args.next() orelse "Sans Bold 16";
    if (args.next() != null or frames == 0 or scale_percent < 25 or scale_percent > 400)
        return error.InvalidArguments;
    var appearance = output.Wayland.Appearance.themed(if (std.mem.eql(u8, theme, "dark"))
        .dark
    else if (std.mem.eql(u8, theme, "wisp-light"))
        .wisp_light
    else
        return error.InvalidTheme);
    appearance.style.font = font;

    var wayland = try output.Wayland.init(std.heap.c_allocator, appearance);
    defer wayland.deinit();
    if (wayland.client.layer.viewport == null and scale_percent % 100 != 0)
        return error.FractionalScalingUnavailable;
    const scale = (scale_percent * 120 + 50) / 100;
    const Model = @TypeOf(wayland.model);
    var entries: [32]Model.Entry = undefined;
    var count: usize = 0;
    var state: u32 = 0x31415926;
    var kinds = [_]u8{0} ** 12 ++ [_]u8{1} ** 5 ++ [_]u8{2} ** 3;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    var waits: usize = 0;

    for (0..frames) |frame| {
        if (frame % kinds.len == 0) {
            var remaining = kinds.len;
            while (remaining > 1) {
                remaining -= 1;
                state = state *% 1664525 +% 1013904223;
                std.mem.swap(u8, &kinds[remaining], &kinds[state % (remaining + 1)]);
            }
        }
        // Start a new history periodically to exercise buffer resizing and reuse.
        if (frame % 75 == 0) count = 0;
        state = state *% 1664525 +% 1013904223;
        const kind = kinds[frame % kinds.len];
        if (kind == 2 and count > 0) {
            entries[count - 1].repetition += 1;
        } else {
            if (count == entries.len) {
                std.mem.copyForwards(Model.Entry, entries[0 .. entries.len - 1], entries[1..]);
                count -= 1;
            }
            const index = state % alphabet.len;
            entries[count] = .{ .modifiers = .{}, .name = "A", .text = alphabet[index..][0..1] };
            if (kind == 1) {
                _ = entries[count].modifiers.update("Control_L", true);
                if (state & 0x100 != 0) _ = entries[count].modifiers.update("Shift_L", true);
                if (state & 0x200 != 0) _ = entries[count].modifiers.update("Alt_L", true);
            }
            count += 1;
        }

        const keys: Model.View = .{ .first = entries[0..count], .second = &.{} };
        // Keep the requested scale fixed instead of using the desktop's current scale.
        while (try wayland.renderer.render(keys, .{ .scale = scale, .subpixel = .default }) == .deferred) {
            waits += 1;
            try wayland.flush();
            var fds = [_]std.posix.pollfd{.{
                .fd = wayland.fd(),
                .events = std.posix.POLL.IN | if (wayland.needsFlush()) @as(i16, std.posix.POLL.OUT) else 0,
                .revents = 0,
            }};
            if (try std.posix.poll(&fds, 5000) == 0) return error.BufferReleaseTimeout;
            if (fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0)
                return error.WaylandDisconnected;
            if (fds[0].revents & std.posix.POLL.OUT != 0) try wayland.flush();
            if (fds[0].revents & std.posix.POLL.IN != 0) try wayland.client.dispatch();
        }
        // Drain protocol events without triggering an extra render at desktop scale.
        if (wayland.client.display.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
    }
    std.debug.print("Submitted {d} frames; theme={s}, scale={d}%, font={s}, buffer waits={d}\n", .{ frames, theme, scale_percent, font, waits });
}
