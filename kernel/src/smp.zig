const std = @import("std");
const limine = @import("limine");

const arch = @import("root").arch;
const atomic = @import("std").atomic;
const sync = @import("util/sync.zig");
const vmm = @import("vmm.zig");
const irq = @import("dev/irq.zig");

const allocator = @import("root").allocator;
const cpu_arch = @import("builtin").target.cpu.arch;
const sink = std.log.scoped(.smp);
const zeroInit = std.mem.zeroInit;

const PREBOOT_MAGIC = 0xF12ACF31;

pub const Cpu = struct {
    processor_id: u32 = 0,
    lapic_id: u32 = 0,
    is_bsp: bool = false,
    data: *CoreInfo = undefined,
};

pub const CoreInfo = struct {
    user_stack: u64 = 0,
    cpu: *Cpu = undefined,

    // DPC stuff
    dpc_queue: std.TailQueue(void) = .{},
    dpc_lock: sync.SpinMutex = .{},
    dpc_count: u32 = 0,

    // x86_64 specific stuff
    tss: arch.TSS = .{},
    lapic_freq: u32 = 0,
};

pub export var smp_request: limine.SmpRequest = .{};
var booted_cores: atomic.Atomic(u32) = .{ .value = 1 };
var cores: std.ArrayList(*Cpu) = undefined;
var num_cores: u32 = 0;

var smpcall_trigger: atomic.Atomic(u32) = .{ .value = 0 };
var smpcall_func: *const fn (?*anyopaque) void = undefined;
var smpcall_arg: ?*anyopaque = undefined;
var smp_lock = sync.SpinMutex{};

pub inline fn getCpuInfo() *Cpu {
    return getCoreInfo().cpu;
}

pub inline fn handleIpi() void {
    smpcall_func(smpcall_arg);
    _ = smpcall_trigger.fetchAdd(1, .Monotonic);
}

pub fn findCpu(cpu: u32) ?*Cpu {
    for (cores.items) |core| {
        if (core.processor_id == cpu)
            return core;
    }

    return null;
}

pub inline fn getCoreInfo() *CoreInfo {
    switch (cpu_arch) {
        .x86_64 => {
            return @intToPtr(*CoreInfo, arch.rdmsr(0xC0000101));
        },
        else => {
            @compileError("unsupported arch " ++ @tagName(cpu_arch) ++ "!");
        },
    }
}

pub inline fn setCoreInfo(ptr: *CoreInfo) void {
    switch (cpu_arch) {
        .x86_64 => {
            arch.wrmsr(0xC0000101, @ptrToInt(ptr));
        },
        else => {
            @compileError("unsupported arch " ++ @tagName(cpu_arch) ++ "!");
        },
    }
}

fn setupCore(info: *limine.SmpInfo) !void {
    var coreinfo = try allocator().create(CoreInfo);
    var cpu = try allocator().create(Cpu);

    errdefer allocator().destroy(coreinfo);
    errdefer allocator().destroy(cpu);

    cpu.* = zeroInit(Cpu, .{
        .processor_id = info.processor_id,
        .lapic_id = info.lapic_id,
        .data = coreinfo,
    });

    coreinfo.* = zeroInit(CoreInfo, .{ .cpu = cpu });
    arch.setupCore(coreinfo);
    try cores.append(cpu);

    setCoreInfo(coreinfo);
}

pub inline fn isBsp() bool {
    switch (cpu_arch) {
        .x86_64 => {
            // Since this function is called before
            // IA32_GS_BASE is set, make sure it exists
            // or assume we're the BSP
            if (arch.rdmsr(0xC0000101) == 0)
                return true;

            if (arch.rdmsr(0xC0000101) == PREBOOT_MAGIC)
                return false;

            return getCoreInfo().cpu.is_bsp;
        },
        else => {
            @compileError("unsupported arch " ++ @tagName(cpu_arch) ++ "!");
        },
    }
}

pub fn broadcast(func: *const fn (?*anyopaque) void, arg: ?*anyopaque, cpu: ?u32) void {
    smp_lock.lock();
    defer smp_lock.unlock();

    smpcall_func = func;
    smpcall_arg = arg;

    if (cpu_arch == .x86_64) {
        if (cpu != null) {
            const cpu_struct = findCpu(cpu.?) orelse return;
            arch.ic.submitIpi(cpu_struct.lapic_id);

            while (smpcall_trigger.load(.Monotonic) == 0) {
                atomic.spinLoopHint();
            }
        } else {
            // x86_64's APIC has support for sending a IPI to all CPUs
            // with one ICR write, so use that instead...
            arch.ic.submitIpi(null);
        }
    } else {
        @compileError("unsupported arch " ++ @tagName(cpu_arch) ++ "!");
    }

    smpcall_trigger.store(0, .Monotonic);
}

pub export fn ap_entry(info: *limine.SmpInfo) callconv(.C) noreturn {
    if (cpu_arch == .x86_64) {
        // write the magic value to IA32_GS_BASE so isBsp() works...
        arch.wrmsr(0xC0000101, PREBOOT_MAGIC);
    }

    // setup the basics for operation
    irq.setIrql(irq.DPC_LEVEL);
    vmm.kernel_pagemap.load();
    arch.init();
    setupCore(info) catch unreachable;

    // let BSP know we're done, then off we go!
    _ = booted_cores.fetchAdd(1, .Monotonic);

    while (true) {
        asm volatile ("sti; hlt");
    }
}

pub fn init() !void {
    var resp = smp_request.response orelse return error.MissingBootInfo;
    cores = std.ArrayList(*Cpu).init(allocator());
    num_cores = @truncate(u32, resp.cpu_count);

    sink.info("attempting to bring-up {} cores..", .{num_cores});

    // setup the BSP first...
    for (resp.cpus()) |cpu| {
        if (cpu.lapic_id == resp.bsp_lapic_id) {
            try setupCore(cpu);
            getCoreInfo().cpu.is_bsp = true;
            try arch.ic.init();

            continue;
        }
    }

    // then boot all APs...
    for (resp.cpus()) |cpu| {
        if (cpu.lapic_id == resp.bsp_lapic_id)
            continue;

        const count = booted_cores.load(.Monotonic);
        cpu.goto_address = &ap_entry;
        while (booted_cores.load(.Monotonic) == count) {}
    }
}
