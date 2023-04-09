// modules
pub const acpi = @import("acpi.zig");
pub const irq = @import("irq.zig");

pub fn init() !void {
    try acpi.init();
}
