const std = @import("std");
const limine = @import("limine");
const atomic = @import("std").atomic;
const arch = @import("root").arch;
const target = @import("builtin").target;

const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const smp = @import("smp.zig");
const irq = @import("dev/irq.zig");
const allocator = @import("root").allocator;

const sink = std.log.scoped(.smp);
const zeroInit = std.mem.zeroInit;

pub const CoreInfo = struct {
    processor_id: u32,
    lapic_id: u32,
    ticks_per_ms: u64 = 0,
    user_stack: u64 = 0,
    tss: arch.TSS = .{},
    is_bsp: bool = false,
    softirqs: std.TailQueue(void) = .{},
};

pub inline fn isBsp() bool {
    switch (target.cpu.arch) {
        .x86_64 => {
            // Since this function is called before
            // IA32_GS_BASE is set, make sure it exists
            // or assume we're the BSP
            if (arch.rdmsr(0xC0000101) == 0)
                return true;

            return getCoreInfo().is_bsp;
        },
        else => {
            @compileError("unsupported arch " ++ @tagName(target.cpu.arch) ++ "!");
        },
    }
}

pub inline fn getCoreId() u32 {
    return getCoreInfo().processor_id;
}

pub inline fn getCoreInfo() *CoreInfo {
    switch (target.cpu.arch) {
        .x86_64 => {
            return @intToPtr(*CoreInfo, arch.rdmsr(0xC0000101));
        },
        else => {
            @compileError("unsupported arch " ++ @tagName(target.cpu.arch) ++ "!");
        },
    }
}

pub inline fn setCoreInfo(ptr: *CoreInfo) void {
    switch (target.cpu.arch) {
        .x86_64 => {
            arch.wrmsr(0xC0000101, @ptrToInt(ptr));
        },
        else => {
            @compileError("unsupported arch " ++ @tagName(target.cpu.arch) ++ "!");
        },
    }
}

pub export var smp_request: limine.SmpRequest = .{};
var booted_cores: atomic.Atomic(u16) = .{ .value = 1 };

fn createCoreInfo(info: *limine.SmpInfo) !void {
    var coreinfo = try allocator().create(CoreInfo);

    coreinfo.* = .{
        .lapic_id = info.lapic_id,
        .processor_id = info.processor_id,
    };

    setCoreInfo(coreinfo);
}

pub export fn ap_entry(info: *limine.SmpInfo) callconv(.C) noreturn {
    // setup the important stuff
    vmm.kernel_pagemap.load();
    createCoreInfo(info) catch unreachable;
    arch.init();
    arch.ic.enable();

    // load the TSS
    getCoreInfo().tss = zeroInit(arch.TSS, arch.TSS{
        .rsp0 = createKernelStack().?,
    });
    arch.loadTSS(&getCoreInfo().tss);

    // let BSP know we're done, then off we go!
    _ = booted_cores.fetchAdd(1, .Monotonic);
    while (true) {
        asm volatile ("hlt");
    }
}

fn createKernelStack() ?u64 {
    if (pmm.allocPages(4)) |page| {
        return vmm.toHigherHalf(page + 4 * std.mem.page_size);
    } else {
        return null;
    }
}

pub fn init() !void {
    var resp = smp_request.response orelse return error.MissingBootInfo;

    sink.info("booting {} cores...", .{resp.cpu_count});

    for (resp.cpus()) |cpu| {
        if (cpu.lapic_id == resp.bsp_lapic_id) {
            try createCoreInfo(cpu);
            getCoreInfo().is_bsp = true;

            // load the TSS
            getCoreInfo().tss = zeroInit(arch.TSS, arch.TSS{});
            getCoreInfo().tss.rsp0 = createKernelStack().?;
            arch.loadTSS(&getCoreInfo().tss);

            try arch.ic.init();
            continue;
        }

        cpu.goto_address = &ap_entry;
    }

    while (booted_cores.load(.Monotonic) != resp.cpu_count) {}
}
