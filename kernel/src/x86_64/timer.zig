const std = @import("std");
const arch = @import("arch.zig");
const apic = @import("apic.zig");
const smp = @import("../smp.zig");
const irq = @import("../dev/irq.zig");
const clock = @import("../dev/clock.zig");

const sink = std.log.scoped(.timer);
const allocator = @import("root").allocator;

var cpu_tsc_tc: clock.TimeCounter = .{
    .name = "x86 Timestamp Counter",
    .quality = 900,
    .bits = 64,
    .frequency = 0,
    .priv = undefined,
    .getValue = undefined,
};

var lapic_tmr_evt: clock.EventTimer = .{
    .name = "x86 Local APIC Timer",
    .quality = 900,
    .priv = undefined,
    .handler = null,
    .arm = lapicTimerArm,
    .disarm = lapicTimerDisarm,
};

var using_deadline = false;

pub fn tscReadAmd(tc: *clock.TimeCounter) u64 {
    _ = tc;
    asm volatile ("mfence" ::: "memory");
    return @call(.always_inline, arch.rdtsc, .{});
}

pub fn tscReadIntel(tc: *clock.TimeCounter) u64 {
    _ = tc;
    asm volatile ("lfence" ::: "memory");
    return @call(.always_inline, arch.rdtsc, .{});
}

pub fn setupTsc() !bool {
    if (arch.cpuid(0, 0).ebx == 0x756E6547) { // 'Genu'
        cpu_tsc_tc.getValue = &tscReadIntel;
    } else if (arch.cpuid(0, 0).ebx == 0x68747541) { // 'Auth'
        cpu_tsc_tc.getValue = &tscReadAmd;
    } else {
        return false; // unknown CPU brand
    }

    if ((arch.cpuid(0x80000007, 0).edx & 0x100) != 0x100) {
        return false; // no support for invariant TSC
    }

    var freq = caliTscCpuid15h() orelse caliTscPit();

    sink.info("total core frequency is {}.{}{} GHz", .{
        freq / 1000000,
        (freq / 100000) % 10,
        (freq / 10000) % 10,
    });

    cpu_tsc_tc.frequency = freq;
    return true;
}

pub fn lapicTimerArm(evt: *clock.EventTimer, timeslice: u64) void {
    var freq = blk: {
        if (using_deadline) {
            break :blk cpu_tsc_tc.frequency;
        } else {
            break :blk smp.getCoreInfo().lapic_freq;
        }
    };

    var deadline = clock.nanosToTicks(timeslice, freq);
    lapicTimerDisarm(evt);

    if (using_deadline) {
        var lvt = apic.ic.read(apic.LocalApic.REG_LVT_TIMER);
        apic.ic.write(apic.LocalApic.REG_LVT_TIMER, lvt | (1 << 18));
        arch.wrmsr(0x6E0, deadline);
    } else {
        apic.ic.write(apic.LocalApic.REG_TIMER_INIT, @truncate(u32, deadline));
    }

    const pin = evt.handler.?.pin;
    pin.setMask(pin, false);
}

pub fn lapicTimerDisarm(evt: *clock.EventTimer) void {
    const pin = evt.handler.?.pin;

    apic.ic.write(apic.LocalApic.REG_TIMER_INIT, 0);
    pin.setMask(pin, true);
}

pub fn lapicTimerCali(arg: ?*anyopaque) void {
    const lapic = apic.LocalApic;
    var self = apic.ic;
    _ = arg;

    // on certain platforms (simics and some KVM machines), the
    // timer starts counting as soon as the APIC is enabled.
    // therefore, we must stop the timer before calibration...
    self.write(lapic.REG_TIMER_INIT, 0);

    // calibrate the APIC timer (using a 10ms sleep)
    self.write(lapic.REG_TIMER_DIV, 0x3);
    self.write(lapic.REG_LVT_TIMER, 0xFF | (1 << 16));
    self.write(lapic.REG_TIMER_INIT, std.math.maxInt(u32));
    clock.wait(1000000);

    // set the frequency, then set the timer back to a disabled state
    smp.getCoreInfo().lapic_freq = std.math.maxInt(u32) - self.read(lapic.REG_TIMER_COUNT);
    self.write(lapic.REG_TIMER_INIT, 0);
    self.write(lapic.REG_LVT_TIMER, (1 << 16));

    if (smp.isBsp())
        sink.info("{} is the LAPIC freq", .{smp.getCoreInfo().lapic_freq});
}

pub fn init() !void {
    // var lvt = apic.ic.getLvtPin(.timer);

    if (try setupTsc())
        try clock.register(&cpu_tsc_tc);

    // check for TSC deadline, which is far better than
    // the LAPIC timer's default oneshot mode
    if (arch.cpuid(0x1, 0x0).ecx & (1 << 24) != 0)
        using_deadline = true;

    if (!using_deadline)
        smp.broadcast(lapicTimerCali, null, null);
    // lapic_tmr_evt.handler = try allocator().create(irq.IrqHandler);
    // try lvt.attach(lapic_tmr_evt.handler.?);
}

//
// The below code is derived from the ACRN Hypervisor:
//   Link: https://github.com/projectacrn/acrn-hypervisor
//   License: BSD-3-Clause
//
// Copyright (C) 2021 Intel Corporation.
//

fn caliTscCpuid15h() ?u64 {
    var max_leaf: u32 = arch.cpuid(0, 0).eax;

    if (max_leaf >= 0x15) {
        var cpu_data = arch.cpuid(0x15, 0);
        if ((cpu_data.eax != 0) and (cpu_data.ebx != 0)) {
            std.log.info("HERE!!!!", .{});
            return ((@intCast(u64, cpu_data.ecx) * cpu_data.ebx) / cpu_data.eax) / 1000;
        }
    }

    return null;
}

fn caliTscPit() u64 {
    //
    // Constants for PIT calibration
    //
    const PIT_TICK_RATE = 1193182;
    const PIT_TARGET = 0x3FFF;
    const PIT_MAX_COUNT = 0xFFFF;

    var max_cal_ms: u32 = ((PIT_MAX_COUNT - PIT_TARGET) * 1000) / PIT_TICK_RATE;
    var cal_ms: u32 = std.math.min(20, max_cal_ms);

    //
    // Assume the 8254 delivers 18.2 ticks per second when 16 bits fully
    // wrap.  This is about 1.193MHz or a clock period of 0.8384uSec
    //
    var initial_pit: u32 = ((cal_ms * PIT_TICK_RATE) / 1000) + PIT_TARGET;
    var initial_pit_high: u8 = @truncate(u8, initial_pit >> 8);
    var initial_pit_low: u8 = @truncate(u8, initial_pit);

    //
    // Port 0x43 ==> Control word write; Data 0x30 ==> Select Counter 0,
    // Read/Write least significant byte first, mode 0, 16 bits.
    //
    arch.out(u8, 0x43, 0x30);
    arch.out(u8, 0x40, initial_pit_low); // Write LSB
    arch.out(u8, 0x40, initial_pit_high); // Write MSB

    var current_tsc: u64 = arch.rdtsc();
    var current_pit: u16 = 0;

    // Let the counter count down to PIT_TARGET
    while (true) {
        //
        // Port 0x43 ==> Control word write; 0x00 ==> Select
        // Counter 0, Counter Latch Command, Mode 0; 16 bits
        //
        arch.out(u8, 0x43, 0x00);

        current_pit = @intCast(u16, arch.in(u8, 0x40)); // Read LSB
        current_pit |= @intCast(u16, arch.in(u8, 0x40)) << 8; // Read MSB

        if (current_pit <= PIT_TARGET) break;
    }

    current_tsc = arch.rdtsc() - current_tsc;
    return current_tsc / cal_ms;
}
