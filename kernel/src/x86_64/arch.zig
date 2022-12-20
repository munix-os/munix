const logger = @import("std").log.scoped(.arch);

const Descriptor = packed struct { size: u16, ptr: u64 };

const GDT = struct {
    entries: [7]u64,

    pub fn load(self: GDT) void {
        var gdtr = Descriptor{
            .size = @as(u16, @sizeOf(GDT) - 1),
            .ptr = @ptrToInt(&self),
        };

        asm volatile (
            \\lgdtq (%[gdtr])
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
            : [gdtr] "r" (&gdtr),
            : "rax", "memory"
        );
    }
};

pub fn setup_cpu() void {
    logger.info("setting up GDT..", .{});

    var gdt_table = GDT{
        .entries = [_]u64{
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
    };
    gdt_table.load();
}
