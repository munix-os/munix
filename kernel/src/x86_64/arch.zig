const logger = @import("std").log.scoped(.arch);
const std = @import("std");

// modules
pub const trap = @import("trap.zig");
pub const paging = @import("paging.zig");

// exports
pub var ic = @import("lapic.zig").LapicController{};

pub const Irql = enum(u4) {
    critical = 15,
    sched = 14,
    passive = 0,
};

pub fn setIrql(level: Irql) void {
    asm volatile ("mov %[irql], %%cr8\n"
        :
        : [irql] "r" (@as(u64, @enumToInt(level))),
        : "memory"
    );
}

pub fn getIrql() Irql {
    return @intToEnum(Irql, asm volatile ("mov %%cr8, %[irql]"
        : [irql] "=r" (-> u64),
    ));
}

const GDT = extern struct {
    entries: [7]u64 align(1) = .{
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
            .size = @sizeOf(GDT) - 1,
            .ptr = @ptrToInt(self),
        };

        asm volatile (
            \\lgdt %[gdtr]
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

pub fn rdmsr(reg: u64) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
        : [_] "{ecx}" (reg),
    );

    return @as(u64, low) | (@as(u64, high) << 32);
}

pub fn wrmsr(reg: u64, val: u64) void {
    asm volatile ("wrmsr"
        :
        : [_] "{eax}" (val & 0xFFFFFFFF),
          [_] "{edx}" (val >> 32),
          [_] "{ecx}" (reg),
    );
}

pub const Descriptor = extern struct { size: u16 align(1), ptr: u64 align(1) };
var gdt_table = GDT{};

pub fn setupAP() void {
    gdt_table.load();
    trap.load();
    setIrql(.passive);
}

pub fn setupCpu() void {
    logger.info("performing early cpu init...", .{});
    trap.init();

    setupAP();
}
