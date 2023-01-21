const std = @import("std");
const acpi = @import("root").acpi;
const vmm = @import("root").vmm;
const smp = @import("root").smp;
const arch = @import("root").arch;
const sink = std.log.scoped(.apic);

const TimerMode = enum(u4) {
    tsc,
    lapic,
    unknown,
};

pub const LapicController = struct {
    mmio_base: u64 = 0xFFFF8000FEE00000,
    tsc_mode: TimerMode = .unknown,

    // general regs
    const REG_VER = 0x30;
    const REG_EOI = 0xB0;
    const REG_SPURIOUS = 0xF0;

    // timer regs
    const REG_TIMER_LVT = 0x320;
    const REG_TIMER_INIT = 0x380;
    const REG_TIMER_CNT = 0x390;
    const REG_TIMER_DIV = 0x3E0;

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

        // enable the APIC
        self.enable();

        // print TSC frequency (if we're using it)
        if (self.canUseTsc()) {
            var n = smp.getCoreInfo().ticks_per_ms / 1000;
            var d4 = (n % 10);
            var d3 = (n / 10) % 10;
            var d2 = (n / 100) % 10;
            var d1 = (n / 1000);

            sink.info("lapic: CPU frequency is {}.{}{}{} GHz", .{ d1, d2, d3, d4 });
        }
    }

    pub fn read(self: *LapicController, reg: u32) u32 {
        return @intToPtr(*volatile u32, self.mmio_base + reg).*;
    }

    pub fn write(self: *LapicController, reg: u32, value: u32) void {
        @intToPtr(*volatile u32, self.mmio_base + reg).* = value;
    }

    inline fn canUseTsc(self: *LapicController) bool {
        if (self.tsc_mode == .lapic) {
            return false;
        } else if (self.tsc_mode == .tsc) {
            return true;
        } else {
            if (arch.cpuid(0x1, 0).ecx & (1 << 24) == 0 and
                arch.cpuid(0x80000007, 0).edx & (1 << 8) == 0)
            {
                self.tsc_mode = .tsc;
                return true;
            } else {
                self.tsc_mode = .lapic;
                return false;
            }
        }
    }

    pub fn enable(self: *LapicController) void {
        // enable the APIC
        arch.wrmsr(0x1B, arch.rdmsr(0x1B) | (1 << 11));
        self.write(REG_SPURIOUS, self.read(REG_SPURIOUS) | (1 << 8) | 0xFF);

        if (self.canUseTsc()) {
            var initial = arch.rdtsc();

            // since AMD requires a "mfence" instruction to serialize the
            // TSC, and Intel requires a "lfence", use both here (not a big
            // deal since this is the only place where we need a serializing TSC)
            asm volatile ("mfence; lfence" ::: "memory");

            acpi.pmSleep(1000);
            var final = arch.rdtsc();
            asm volatile ("mfence; lfence" ::: "memory");

            smp.getCoreInfo().ticks_per_ms = final - initial;
        } else {
            // on certain platforms (simics and some KVM machines), the
            // timer starts counting as soon as the APIC is enabled.
            // therefore, we must stop the timer before calibration...
            self.write(REG_TIMER_INIT, 0);

            // calibrate the APIC timer (using a 10ms sleep)
            self.write(REG_TIMER_DIV, 0x3);
            self.write(REG_TIMER_LVT, 0xFF | (1 << 16));
            self.write(REG_TIMER_INIT, std.math.maxInt(u32));
            acpi.pmSleep(1000);

            // set the frequency, then set the timer back to a disabled state
            smp.getCoreInfo().ticks_per_ms = std.math.maxInt(u32) - self.read(REG_TIMER_CNT);
            self.write(REG_TIMER_INIT, 0);
            self.write(REG_TIMER_LVT, (1 << 16));
        }
    }

    pub fn submitEoi(self: *LapicController, irq: u8) void {
        _ = irq;
        self.write(REG_EOI, 0);
    }

    pub fn oneshot(self: *LapicController, vec: u8, ms: u64) void {
        // stop the timer
        self.write(REG_TIMER_INIT, 0);
        self.write(REG_TIMER_LVT, (1 << 16));

        // set the deadline, and off we go!
        var deadline = @truncate(u32, smp.getCoreInfo().ticks_per_ms * ms);

        if (self.canUseTsc()) {
            self.write(REG_TIMER_LVT, @as(u32, vec) | (1 << 18));
            arch.wrmsr(0x6E0, deadline);
        } else {
            self.write(REG_TIMER_LVT, vec);
            self.write(REG_TIMER_INIT, deadline);
        }
    }
};
