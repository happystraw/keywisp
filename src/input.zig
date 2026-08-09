const libinput = @import("input/libinput.zig");
pub const LibInput = libinput.LibInput;
pub const Udev = libinput.Udev;

test {
    _ = libinput;
}
