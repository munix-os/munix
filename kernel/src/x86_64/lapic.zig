const std = @import("std");
const acpi = @import("root").acpi;
const vmm = @import("root").vmm;
const smp = @import("root").smp;
const arch = @import("root").arch;
const sink = std.log.scoped(.apic);

pub const LapicController = struct {
    mmio_base: u64 = 0xFFFF8000FEE00000,
    ext_space_capable: bool = false,

    // general regs
    const REG_VER = 0x30;
    const REG_EOI = 0xB0;
    const REG_SPURIOUS = 0xF0;

    // timer regs
    const REG_TIMER_LVT = 0x320;
    const REG_TIMER_INIT = 0x380;
    const REG_TIMER_CNT = 0x390;
    const REG_TIMER_DIV = 0x3E0;

    // extended apic regs
    const REG_EAC_CONTROL = 0x410;
    const REG_EAC_SEOI = 0x420;

    pub fn setup(self: *LapicController) void {
        var mmio_base = vmm.toHigherHalf(arch.rdmsr(0x1B) & 0xFFFFF000);
        if (mmio_base != self.mmio_base) {
            sink.warn("mmio base 0x{X:0>16} is not the x86 default!", .{mmio_base});
            self.mmio_base = mmio_base;
        }

        // map the APIC as UC
        var aligned_base: u64 = std.mem.alignBackward(mmio_base, 0x200000);
        var map_flags = vmm.MapFlags{ .read = true, .write = true, .cache_type = .uncached };
        vmm.kernel_pagemap.unmapPage(aligned_base);
        vmm.kernel_pagemap.mapPage(map_flags, aligned_base, vmm.fromHigherHalf(aligned_base), true);

        if ((self.read(REG_VER) & (1 << 31)) != 0) {
            self.ext_space_capable = true;
            sink.info("APIC supports AMD specific ERS (Extended Register Space)", .{});
        }

        self.enable();
    }

    pub fn read(self: *LapicController, reg: u32) u32 {
        return @intToPtr(*volatile u32, self.mmio_base + reg).*;
    }

    pub fn write(self: *LapicController, reg: u32, value: u32) void {
        @intToPtr(*volatile u32, self.mmio_base + reg).* = value;
    }

    pub fn enable(self: *LapicController) void {
        if ((self.read(REG_VER) & (1 << 31)) != 0) {
            // enable SEOIs by setting bit 1 of EAC_CONTROL
            self.write(REG_EAC_CONTROL, self.read(REG_EAC_CONTROL) | (1 << 1));
        }

        // enable the APIC
        arch.wrmsr(0x1B, arch.rdmsr(0x1B) | (1 << 11));
        self.write(REG_SPURIOUS, self.read(REG_SPURIOUS) | (1 << 8) | 0xFF);

        // on certain platforms (simics and some KVM machines), the
        // timer starts counting as soon as the APIC is enabled.
        // therefore, we must stop the timer before calibration...
        self.write(REG_TIMER_INIT, 0);

        // calibrate the APIC timer (using a 10ms sleep)
        self.write(REG_TIMER_DIV, 0x3);
        self.write(REG_TIMER_LVT, 0xFF | (1 << 16));
        self.write(REG_TIMER_INIT, std.math.maxInt(u32));
        acpi.pmSleep(10);

        // set the frequency, then set the timer back to a disabled state
        smp.getCoreInfo().ticks_per_ms = (std.math.maxInt(u32) - self.read(REG_TIMER_CNT)) / @as(u64, 10);
        self.write(REG_TIMER_INIT, 0);
        self.write(REG_TIMER_LVT, (1 << 16));
    }

    pub fn submitEoi(self: *LapicController, irq: u8) void {
        if (self.ext_space_capable) {
            self.write(REG_EAC_SEOI, irq);
        } else {
            self.write(REG_EOI, 0);
        }
    }

    pub fn oneshot(self: *LapicController, vec: u8, ms: u64) void {
        // stop the timer
        self.write(REG_TIMER_INIT, 0);
        self.write(REG_TIMER_LVT, (1 << 16));

        // set the deadline, and off we go!
        var deadline = @truncate(u32, smp.getCoreInfo().ticks_per_ms * ms);
        self.write(REG_TIMER_LVT, vec);
        self.write(REG_TIMER_INIT, deadline);
    }
};
