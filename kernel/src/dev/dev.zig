// modules
pub const acpi = @import("acpi.zig");
pub const irq = @import("irq.zig");
pub const clock = @import("clock.zig");

pub fn init() !void {
    try clock.init();
    try acpi.init();
}
