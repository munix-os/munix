const std = @import("std");
const smp = @import("root").smp;
const lapic = @import("lapic.zig");
const logger = std.log.scoped(.arch);

// modules
pub const trap = @import("trap.zig");
pub const paging = @import("paging.zig");
pub const cpu = @import("cpu.zig");

// globals
pub var ic = lapic.LapicController{};
var gdt_lock = smp.SpinLock{};
var gdt_table = GDT{};

pub const Descriptor = extern struct {
    size: u16 align(1),
    ptr: u64 align(1),
};

pub const Irql = enum(u4) {
    passive,
    active,
    nopreempt,
};

const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
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

const GDT = extern struct {
    entries: [9]u64 align(1) = .{
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

        // 64-bit user code/data
        0x00AFFA000000FFFF,
        0x008FF2000000FFFF,
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

        // Reloading the GDT clears the GS base, so take
        // note of the current value here for later...
        var gs_base = rdmsr(0xC0000101);

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

        wrmsr(0xC0000101, gs_base);
    }
};

pub fn intrEnabled() bool {
    var eflags = asm volatile (
        \\pushf
        \\pop %[result]
        : [result] "=r" (-> u64),
    );

    return ((eflags & 0x200) != 0);
}

pub fn setIntrMode(enabled: bool) void {
    if (enabled) {
        asm volatile ("sti");
    } else {
        asm volatile ("cli");
    }
}

pub fn setIrql(level: Irql) void {
    asm volatile ("mov %[level], %%cr8"
        :
        : [level] "r" (@enumToInt(level)),
    );
}

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
        : [tss] "r" (@as(u16, 0x48)),
        : "memory"
    );
}

pub fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdtsc"
        : [_] "={eax}" (low),
          [_] "={edx}" (high),
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

pub inline fn wrcr4(value: usize) void {
    asm volatile ("mov %[val], %%cr4"
        :
        : [val] "r" (value),
        : "memory"
    );
}

pub inline fn rdcr4() usize {
    return asm volatile ("mov %%cr4, %[result]"
        : [result] "=r" (-> u64),
        :
        : "memory"
    );
}

pub inline fn wrcr0(value: usize) void {
    asm volatile ("mov %[val], %%cr4"
        :
        : [val] "r" (value),
        : "memory"
    );
}

pub inline fn rdcr0() usize {
    return asm volatile ("mov %%cr4, %[result]"
        : [result] "=r" (-> u64),
        :
        : "memory"
    );
}

pub fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = 0;
    var ebx: u32 = 0;
    var ecx: u32 = 0;
    var edx: u32 = 0;

    asm volatile (
        \\cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
        : "memory"
    );

    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

pub fn setupCpu() void {
    gdt_table.load();
    trap.load();
    cpu.init();
}

//pub fn setupCpu() void {
//    logger.info("performing early cpu init...", .{});
//    trap.init();
//
//    setupAP();
//}
