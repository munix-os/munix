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

pub const TSS = extern struct {
    unused0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    unused1: u64 align(1) = 0,
    ist1: u64 align(1) = 0,
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    unused2: u64 align(1) = 0,
    iopb: u32 align(1) = 0,
};

const TSSDescriptor = extern struct {
    length: u16 align(1),
    base_low: u16 align(1),
    base_mid: u8 align(1),
    flags: u16 align(1),
    base_high: u8 align(1),
    base_ext: u32 align(1),
    reserved: u32 align(1) = 0,
};

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
    tss_desc: TSSDescriptor = .{
        .length = 104,
        .base_low = 0,
        .base_mid = 0,
        .flags = 0b10001001,
        .base_high = 0,
        .base_ext = 0,
        .reserved = 0,
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

pub fn loadTSS(tss: *TSS) void {
    gdt_lock.acq();
    defer gdt_lock.rel();

    var addr: u64 = @ptrToInt(tss);

    gdt_table.tss_desc.base_low = @truncate(u16, addr);
    gdt_table.tss_desc.base_mid = @truncate(u8, addr >> 16);
    gdt_table.tss_desc.flags = 0b10001001;
    gdt_table.tss_desc.base_high = @truncate(u8, addr >> 24);
    gdt_table.tss_desc.base_ext = @truncate(u32, addr >> 32);

    asm volatile ("ltr %[tss]"
        :
        : [tss] "r" (@as(u16, 0x38)),
        : "memory"
    );
}

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
var gdt_lock = @import("root").smp.SpinLock{};

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
