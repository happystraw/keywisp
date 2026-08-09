const std = @import("std");
const Allocator = std.mem.Allocator;

const wl = @import("wayland").client.wl;

const Outputs = @This();

pub const Output = struct {
    name: u32,
    proxy: *wl.Output,
    scale: i32 = 1,
    subpixel: wl.Output.Subpixel = .unknown,
    next: ?*Output = null,
};

head: ?*Output = null,
current: ?*Output = null,

gpa: Allocator,

pub fn init(gpa: Allocator) Outputs {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Outputs) void {
    var out = self.head;
    while (out) |o| {
        const next = o.next;
        release(o.proxy);
        self.gpa.destroy(o);
        out = next;
    }
    self.head = null;
    self.current = null;
}

pub fn add(self: *Outputs, name: u32, proxy: *wl.Output) Allocator.Error!*Output {
    const output = try self.gpa.create(Output);
    output.* = .{ .name = name, .proxy = proxy };
    var link = &self.head;
    while (link.*) |o| link = &o.next;
    link.* = output;
    return output;
}

pub fn find(self: *Outputs, proxy: *wl.Output) ?*Output {
    var out = self.head;
    while (out) |o| {
        if (o.proxy == proxy) return o;
        out = o.next;
    }
    return null;
}

pub fn setCurrent(self: *Outputs, proxy: *wl.Output) bool {
    const current = self.find(proxy);
    if (self.current == current) return false;
    self.current = current;
    return true;
}

pub fn clearCurrent(self: *Outputs, proxy: *wl.Output) bool {
    const current = self.current orelse return false;
    if (current.proxy != proxy) return false;
    self.current = null;
    return true;
}

pub fn remove(self: *Outputs, name: u32) bool {
    var link = &self.head;
    while (link.*) |output| {
        if (output.name != name) {
            link = &output.next;
            continue;
        }
        link.* = output.next;
        const was_current = self.current == output;
        if (was_current) self.current = null;
        release(output.proxy);
        self.gpa.destroy(output);
        return was_current;
    }
    return false;
}

pub fn release(proxy: *wl.Output) void {
    if (proxy.getVersion() >= wl.Output.release_since_version)
        proxy.release()
    else
        proxy.destroy();
}
