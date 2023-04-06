const std = @import("std");
const atomic = std.atomic;

const arch = @import("root").arch;
const allocator = @import("root").allocator;
const sync = @import("../util/sync.zig");
const irq = @import("irq.zig");

// zig fmt: off
pub const TimeCounter = struct {
    name: []const u8,    // name of counter
    quality: u16,        // represents how good this counter is
    bits: u16,           // how wide (in bits) is the counter register
    frequency: u64,      // frequency of counter in ticks per millesecond (KHz)
    priv: *anyopaque,    // private context of counter

    // returns the current value of this timecounter
    getValue: *const fn (*TimeCounter) u64,
};

pub const EventTimer = struct {
    name: []const u8,          // name of counter
    quality: u16,              // represents how good this counter it
    priv: *anyopaque,          // private context of counter
    handler: ?*irq.IrqHandler, // IRQ handler for the timer's IRQ

    // activates the timer hardware
    arm: *const fn (*EventTimer, u64) void,

    // disables the timer hardware
    disarm: *const fn (*EventTimer) void,
};

// zig fmt: on
var counters: std.ArrayList(*TimeCounter) = undefined;
var timers: std.ArrayList(*EventTimer) = undefined;
var cur_tc: ?*TimeCounter = undefined;
var cur_evt: ?*EventTimer = undefined;
var obj_lock: sync.SpinMutex = .{};

pub fn init() !void {
    counters = std.ArrayList(*TimeCounter).init(allocator());
    timers = std.ArrayList(*EventTimer).init(allocator());
}

pub fn register(item: anytype) !void {
    obj_lock.lock();
    defer obj_lock.unlock();

    if (std.meta.Child(@TypeOf(item)) == TimeCounter) {
        const tc = @ptrCast(*TimeCounter, item);
        try counters.append(tc);

        if (cur_tc == null or tc.quality > cur_tc.?.quality)
            cur_tc = tc;
    } else if (std.meta.Child(@TypeOf(item)) == EventTimer) {
        const evt = @ptrCast(*EventTimer, item);
        try timers.append(evt);

        if (cur_evt == null or evt.quality > cur_evt.?.quality)
            cur_evt = evt;
    } else {
        @compileError("unknown type passed to register()");
    }
}

pub fn nanosToTicks(ns: u64, freq: u64) u64 {
    var new_freq = freq / 1000000;

    if (new_freq == 0) {
        // timer doesn't run fast enough, convert ns to ms
        var ms = ns / 1000000;

        // 1 ms is the bottom-line wait time
        if (ms == 0)
            ms = 1;

        return ms * freq;
    } else {
        return new_freq * ns;
    }
}

pub fn wait(ns: u64) void {
    var tc = cur_tc.?;
    var target = nanosToTicks(ns, tc.frequency);

    if (tc.bits >= 64) {
        // counters 64-bit or wider don't overflow in a *very* long time
        target += tc.getValue(tc);

        while (tc.getValue(tc) < target) {
            atomic.spinLoopHint();
        }
    } else if (tc.bits <= 32) {
        var shift: u64 = @as(u64, 1) << @truncate(u6, tc.bits);

        // find out how many 'remaining' ticks to wait after 'n' overflows
        var n: u64 = target / shift;
        var remaining: u64 = target % shift;

        // bump 'remaining' to reflect current timer state
        var cur_ticks = tc.getValue(tc);
        remaining += cur_ticks;

        // adjust 'n' to reflect current timer state
        if (remaining < cur_ticks) {
            n += 1;
        } else {
            n += remaining / shift;
            remaining = remaining % shift;
        }

        // next, wait for 'n' overflows to happen
        var new_ticks: u32 = 0;
        while (n > 0) {
            new_ticks = @truncate(u32, tc.getValue(tc));
            if (new_ticks < cur_ticks) {
                n -= 1;
            }
            cur_ticks = new_ticks;
        }

        // finally, wait the 'remaining' ticks out
        while (remaining > cur_ticks) {
            new_ticks = @truncate(u32, tc.getValue(tc));
            if (new_ticks < cur_ticks) {
                break;
            }
            cur_ticks = new_ticks;
        }
    } else {
        @panic("timer uses non-standard bit width (32 < width < 64)");
    }
}
