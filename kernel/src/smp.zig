const limine = @import("limine");
const target = @import("builtin").target;
const atomic = @import("std").atomic;
const arch = @import("root").arch;
const vmm = @import("root").vmm;
const pmm = @import("root").pmm;
const std = @import("std");
const smp = @import("root").smp;

const allocator = @import("root").allocator;
const sink = std.log.scoped(.smp);
const zeroInit = std.mem.zeroInit;
const AtomicType = atomic.Atomic;

pub const SpinLock = struct {
    lock_bits: AtomicType(u32) = .{ .value = 0 },
    refcount: AtomicType(usize) = .{ .value = 0 },
    intr_mode: bool = false,

    pub fn acq(self: *SpinLock) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);

        var current = arch.intrEnabled();
        arch.setIntrMode(false);

        while (true) {
            // ------------------------------------------------
            // x86 Instruction | Micro ops | Base Latency
            // ------------------------------------------------
            // XCHG                  8           23
            // LOCK XADD             9           18
            // LOCK CMPXCHG          10          18
            // LOCK CMPXCHG8B        20          19
            // ------------------------------------------------
            // We're optimizing for micro ops, since base
            // latency isn't consistent across CPU families.
            // Therefore, we go with the XCHG instruction...
            // ------------------------------------------------
            // Source: https://agner.org/optimize/instruction_tables.pdf
            //
            if (self.lock_bits.swap(1, .Acquire) == 0) {
                // 'self.lock_bits.swap' translates to a XCHG
                break;
            }

            while (self.lock_bits.fetchAdd(0, .Monotonic) != 0) {
                // IRQs can be recived while waiting
                // for the lock to be available...
                arch.setIntrMode(current);
                atomic.spinLoopHint();
                arch.setIntrMode(false);
            }
        }

        _ = self.refcount.fetchSub(1, .Monotonic);
        atomic.compilerFence(.Acquire);
        self.intr_mode = current;
    }

    pub fn rel(self: *SpinLock) void {
        self.lock_bits.store(0, .Release);
        atomic.compilerFence(.Release);
        arch.setIntrMode(self.intr_mode);
    }

    pub fn isLocked(self: *SpinLock) bool {
        return self.lock_bits.load(.Monotonic) == 1;
    }

    // wrappers for zig stdlib
    pub inline fn lock(self: *SpinLock) void {
        self.acq();
    }
    pub inline fn unlock(self: *SpinLock) void {
        self.rel();
    }
};

pub const CoreInfo = struct {
    processor_id: u32,
    lapic_id: u32,
    ticks_per_ms: u64 = 0,
    user_stack: u64 = 0,
    tss: arch.TSS = .{},
    is_bsp: bool = false,
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
var booted_cores: AtomicType(u16) = .{ .value = 1 };

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
    arch.setupCpu();
    arch.ic.enable();

    // load the TSS
    getCoreInfo().tss = zeroInit(arch.TSS, arch.TSS{
        .rsp0 = createKernelStack().?,
    });
    arch.loadTSS(&getCoreInfo().tss);

    // let BSP know we're done, then off we go!
    _ = booted_cores.fetchAdd(1, .Monotonic);
    while (true) {}
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

            arch.ic.setup();
            continue;
        }

        cpu.goto_address = &ap_entry;
    }

    while (booted_cores.load(.Monotonic) != resp.cpu_count) {}
}
