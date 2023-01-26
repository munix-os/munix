const std = @import("std");
const smp = @import("root").smp;
const pmm = @import("root").pmm;
const vmm = @import("root").vmm;
const sink = std.log.sink(.sched);

// tuneable parameters to the scheduler
const DEFAULT_TIMESLICE = 20;
const PRIO_MIN = -20;
const PRIO_MAX = 20;
const RQ_PRIO_COUNT = 64;
const RQ_PPQ = 4;

pub const TIMER_VECTOR = 0x20;
const PRI_MIN_TIMESHARE = 88;
const PRI_MAX_TIMESHARE = PRI_MIN_IDLE - 1;
const PRI_MIN_IDLE = 224;
const PRI_MAX = 255; // Lowest priority.
const PRI_MAX_IDLE = PRI_MAX;

const SCHED_PRI_NRESV = PRIO_MAX - PRIO_MIN;
const PRI_TIMESHARE_RANGE = PRI_MAX_TIMESHARE - PRI_MIN_TIMESHARE + 1;
const PRI_INTERACT_RANGE = (PRI_TIMESHARE_RANGE - SCHED_PRI_NRESV) / 2;
const PRI_BATCH_RANGE = PRI_TIMESHARE_RANGE - PRI_INTERACT_RANGE;

const PRI_MIN_INTERACT = PRI_MIN_TIMESHARE;
const PRI_MAX_INTERACT = PRI_MIN_TIMESHARE + PRI_INTERACT_RANGE - 1;
const PRI_MIN_BATCH = PRI_MIN_TIMESHARE + PRI_INTERACT_RANGE;
const PRI_MAX_BATCH = PRI_MAX_TIMESHARE;
const PRI_MIN_KERN = 48;
const PRI_MIN_REALTIME = 16;
const PRI_MAX_ITHD = PRI_MIN_REALTIME - 1;

const SRQ_BORING = 0x0000; // No special circumstances.
const SRQ_YIELDING = 0x0001; // We are yielding (from mi_switch).
const SRQ_OURSELF = 0x0002; // It is ourself (from mi_switch).
const SRQ_INTR = 0x0004; // It is probably urgent.
const SRQ_PREEMPTED = 0x0008; // has been preempted.. be kind
const SRQ_BORROWING = 0x0010; // Priority updated due to prio_lend
const SRQ_HOLD = 0x0020; // Return holding original td lock
const SRQ_HOLDTD = 0x0040; // Return holding td lock

const TDF_NOLOAD = 0x00040000; // Ignore during load avg calculations.

const SCHED_SLICE_DEFAULT_DIVISOR = 10; // ~94 ms, 12 stathz ticks.
const SCHED_SLICE_MIN_DIVISOR = 6;

pub const TdState = enum {
    inactive,
    inhibited,
    can_run,
    runq,
    running,
};

var sched_slice: u32 = 10;
var sched_slice_min: u32 = 1;

pub const Thread = struct {
    link: std.TailQueue(void).Node = undefined,
    cpu: u32,
    priority: u8,
    rqindex: u32,

    // scheduler metrics
    runtime: u32,
    slptime: u32,
};

pub const RunQueue = struct {
    bits: [RQ_PRIO_COUNT / 16]u16 = std.mem.zeroes([RQ_PRIO_COUNT / 16]u16),
    queues: [RQ_PRIO_COUNT]std.TailQueue(void) = std.mem.zeroes([RQ_PRIO_COUNT]std.TailQueue(void)),

    inline fn setbit(self: *RunQueue, index: u32) void {
        self.bits[index / 16] |= (1 << (index % 16));
    }

    inline fn clrbit(self: *RunQueue, index: u32) void {
        self.bits[index / 16] &= ~@as(u16, 1 << (index % 16));
    }

    fn findbit(self: *RunQueue) ?u32 {
        var i: usize = 0;

        while (i < RQ_PRIO_COUNT / 16) : (i += 1) {
            var idx = ffs(self.bits[i]);
            if (idx != 0) {
                return idx + (i * 16);
            }
        }

        return null;
    }

    fn findbitFrom(self: *RunQueue, pri: u8) ?u32 {
        // TODO(cleanbaja): find a way to use ffs for this
        var i: usize = 0;

        while (i < 64) : (i += 1) {
            var idx = (i + pri) % 64;

            if (self.bits[idx / 16] & (1 << (idx % 16)) != 0)
                return idx;
        }

        return null;
    }

    pub fn addWithPri(self: *RunQueue, thrd: *Thread, pri: u8, preempted: bool) void {
        std.debug.assert(pri < RQ_PRIO_COUNT);
        thrd.rqindex = pri;
        self.setbit(pri);

        if (preempted) {
            self.queues[pri].prepend(&thrd.link);
        } else {
            self.queues[pri].append(&thrd.link);
        }
    }

    pub fn add(self: *RunQueue, thrd: *Thread, preempted: bool) void {
        self.addWithPri(thrd, thrd.priority / RQ_PPQ, preempted);
    }

    pub fn removeWithIdx(self: *RunQueue, thrd: *Thread, idx: ?*u8) void {
        var pri = thrd.rqindex;
        std.debug.assert(pri < RQ_PRIO_COUNT);
        _ = self.queues[pri].popFirst();

        if (self.queues[pri].first == null) {
            self.clrbit(pri);

            if (idx) |i| {
                i.* = (pri + 1) % RQ_PRIO_COUNT;
            }
        }
    }

    pub inline fn remove(self: *RunQueue, thread: *Thread) void {
        self.removeWithIdx(thread, null);
    }

    pub fn choose(self: *RunQueue) ?*Thread {
        var pri: ?u32 = self.findbit();

        while (pri) |p| : (pri = self.findbit()) {
            var thrd = self.queues[p].first;
            std.debug.assert(thrd != null);

            return @fieldParentPtr(Thread, "link", thrd);
        }

        return null;
    }

    pub fn chooseFrom(self: *RunQueue, idx: u8) ?*Thread {
        var pri: ?u32 = self.findbitFrom(idx);

        while (pri) |p| : (pri = self.findbitFrom(idx)) {
            var thrd = self.queues[p].first;
            std.debug.assert(thrd != null);

            return @fieldParentPtr(Thread, "link", thrd);
        }

        return null;
    }
};

pub const ThreadQueue = struct {
    lock: smp.SpinLock = .{},
    realtime: RunQueue = .{},
    timeshare: RunQueue = .{},
    idle: RunQueue = .{},
    idx: u8 = 0,
    ridx: u8 = 0,
    load: u32 = 0,
    sysload: u32 = 0,
    lowpri: u32 = 0,
    switchcnt: u32 = 0,
    oldswitchcnt: u32 = 0,
    owepreempt: bool = false,
    can_transfer: u32 = 0,
    cur_thread: *Thread = undefined,
    cpu_idle: u32 = 0,

    pub fn addRunq(self: *ThreadQueue, thrd: *Thread, flags: u32) void {
        std.debug.assert(self.lock.isLocked());

        var prio = thrd.priority;
        thrd.status = TdState.runq;

        if (prio < PRI_MIN_BATCH) {
            thrd.runq = &self.realtime;
        } else if (prio <= PRI_MAX_BATCH) {
            thrd.runq = &self.timeshare;

            std.debug.assert(prio <= PRI_MAX_BATCH and prio >= PRI_MIN_BATCH);

            if (flags & (SRQ_BORROWING | SRQ_PREEMPTED) == 0) {
                prio = RQ_PRIO_COUNT * (prio - PRI_MIN_BATCH) / PRI_BATCH_RANGE;
                prio = (prio + self.idt) % RQ_PRIO_COUNT;

                // this shortens the queue by one, so we can
                // have a one slot difference while waiting for
                // threads to drain...
                if (self.ridx != self.idx and prio == self.ridx)
                    prio = @truncate(u8, prio - 1) % RQ_PRIO_COUNT;
            }

            thrd.runq.addWithPri(thrd, prio, flags & SRQ_PREEMPTED == 0);
            return;
        } else {
            prio = self.ridx;
        }

        thrd.runq.add(thrd, flags & SRQ_PREEMPTED == 0);
    }

    pub fn remRunq(self: *ThreadQueue, thrd: *Thread) void {
        std.debug.assert(self.lock.isLocked());

        if (thrd.runq == null) {
            sink.info("remRunq: thread at 0x{X} has a null runq!", .{@ptrToInt(thrd)});
            return;
        }

        if (thrd.runq == &self.timeshare) {
            if (self.idx != self.ridx) {
                thrd.runq.removeWithIdx(thrd, &self.ridx);
            } else {
                thrd.runq.removeWithIdx(thrd, null);
            }
        } else {
            thrd.runq.remove(thrd);
        }
    }

    pub fn loadAdd(self: *ThreadQueue, thrd: *Thread) void {
        std.debug.assert(self.lock.isLocked());
        self.load += 1;

        if (thrd.flags & TDF_NOLOAD == 0)
            self.sysload += 1;
    }

    pub fn loadRem(self: *ThreadQueue, thrd: *Thread) void {
        std.debug.assert(self.lock.isLocked());
        std.debug.assert(self.load != 0);
        self.load -= 1;

        if (thrd.flags & TDF_NOLOAD == 0)
            self.sysload -= 1;
    }

    pub inline fn slice(self: *ThreadQueue) u32 {
        var load: u32 = self.sysload - 1;
        if (load >= SCHED_SLICE_MIN_DIVISOR)
            return (sched_slice_min);
        if (load <= 1)
            return (sched_slice);
        return (sched_slice / load);
    }
};

fn ffs(x: anytype) std.math.Log2IntCeil(@TypeOf(x)) {
    if (x == 0) return 0;
    return @ctz(x) + 1;
}

pub fn createKernelStack() ?u64 {
    if (pmm.allocPages(4)) |page| {
        return vmm.toHigherHalf(page + 4 * std.mem.page_size);
    } else {
        return null;
    }
}
