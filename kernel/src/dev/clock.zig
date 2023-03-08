const std = @import("std");
const arch = @import("root").arch;
const allocator = @import("root").allocator;
const sync = @import("../util/sync.zig");

const atomic = std.atomic;

// zig fmt: off
pub const TimeCounter = struct {
    name: []const u8,    // name of counter
    quality: u16,        // represents how good is this counter
    bits: u16,           // how wide (in bits) is the counter register
    mask: u64,           // mask constructed from 'bits'
    frequency: u64,      // frequency of counter in ticks per millesecond (KHz)
    priv: *anyopaque,    // private context of counter

    // returns the current value of this timecounter
    getValue: *const fn (*TimeCounter) u64,
};

// zig fmt: on
var counters: std.ArrayList(*TimeCounter) = undefined;
var counter_lock: sync.SpinMutex = .{};
var cur_tc: ?*TimeCounter = undefined;

pub fn init() !void {
    counters = std.ArrayList(*TimeCounter).init(allocator());
}

pub fn register(tc: *TimeCounter) !void {
    counter_lock.lock();
    defer counter_lock.unlock();

    try counters.append(tc);

    if (cur_tc == null or tc.quality > cur_tc.?.quality)
        cur_tc = tc;
}

fn timeToTicks(ns: u64) u64 {
    var tc = cur_tc.?;
    var new_freq = tc.frequency / 1000000;

    if (new_freq == 0) {
        // timer doesn't run fast enough, convert ns to ms
        var ms = ns / 1000000;

        // 1 ms is the bottom-line wait time
        if (ms == 0)
            ms = 1;

        return ms * tc.frequency;
    } else {
        return new_freq * ns;
    }
}

pub fn wait(ns: u64) void {
    var tc = cur_tc.?;
    var shift: u65 = @as(u65, 1) << @truncate(u7, tc.bits);
    var target: u64 = timeToTicks(ns);

    // find out how many 'remaining' ticks to wait after 'n' overflows
    var n: u65 = target / shift;
    var remaining: u65 = target % shift;

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
    var new_ticks: u64 = 0;
    while (n > 0) {
        new_ticks = tc.getValue(tc);
        if (new_ticks < cur_ticks) {
            n -= 1;
        }
        cur_ticks = new_ticks;
    }

    // finally, wait the 'remaining' ticks out
    while (remaining > cur_ticks) {
        new_ticks = tc.getValue(tc);
        if (new_ticks < cur_ticks) {
            break;
        }
        cur_ticks = new_ticks;
    }
}
