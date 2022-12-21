const logger = @import("std").log.scoped(.arch);
pub const trap = @import("trap.zig");
pub const Descriptor = extern struct { size: u16 align(1), ptr: u64 align(1) };

const GDT = struct {
    entries: [7]u64 = .{
        // null entry
        0x0000000000000000,

        // 16-bit kernel code/data
        0x00009a000000ffff,
        0x000093000000ffff,

        // 32-bit kernel code/data
        0x00cf9a000000ffff,
        0x00cf93000000ffff,

        // 64-bit kernel code/data
        0x00af9b000000ffff,
        0x00af93000000ffff,
    },

    pub fn load(self: *const GDT) void {
        const gdtr = Descriptor{
            .size = @as(u16, @sizeOf(GDT) - 1),
            .ptr = @ptrToInt(self),
        };

        asm volatile (
            \\lgdtq %[gdtr]
            \\push $0x28
            \\lea 1f(%%rip), %%rax
            \\push %%rax
            \\lretq
            \\1:
            \\mov $0x30, %%eax
            \\mov %%eax, %%ds
            \\mov %%eax, %%es
            \\mov %%eax, %%fs
            \\mov %%eax, %%gs
            \\mov %%eax, %%ss
            :
            : [gdtr] "*p" (&gdtr),
            : "rax", "rcx", "memory"
        );
    }
};

const gdt_table = GDT{};

pub fn setupCpu() void {
    logger.info("performing early cpu init...", .{});
    gdt_table.load();
    trap.init();
}
