const std = @import("std");
const smp = @import("root").smp;
const pmm = @import("root").pmm;
const vmm = @import("root").vmm;
const arch = @import("root").arch;
const trap = arch.trap;
const sink = std.log.scoped(.sched);

// tuneable parameters to the scheduler
const DEFAULT_TIMESLICE = 20;
const PRIO_MIN = -20;
const PRIO_MAX = 20;
const RQ_PRIO_COUNT = 64;
const RQ_PPQ = 4;
const NOCPU = -1; // For when we aren't on a CPU.

pub const TIMER_VECTOR = 0x20;
const PRI_MIN_TIMESHARE = 88;
const PRI_MAX_TIMESHARE = PRI_MIN_IDLE - 1;
const PRI_MIN_IDLE = 224;
const PRI_MAX = 255; // Lowest priority.
const PRI_MAX_IDLE = PRI_MAX;
const MAX_CACHE_LEVELS = 2;

const SCHED_PRI_NRESV = PRIO_MAX - PRIO_MIN;
const SCHED_PRI_NHALF = (SCHED_PRI_NRESV / 2);
const SCHED_PRI_MIN = (PRI_MIN_BATCH + SCHED_PRI_NHALF);
const SCHED_PRI_MAX = (PRI_MAX_BATCH - SCHED_PRI_NHALF);
const SCHED_PRI_RANGE = SCHED_PRI_MAX - SCHED_PRI_MIN + 1;
const PRI_TIMESHARE_RANGE = PRI_MAX_TIMESHARE - PRI_MIN_TIMESHARE + 1;
const PRI_INTERACT_RANGE = (PRI_TIMESHARE_RANGE - SCHED_PRI_NRESV) / 2;
const PRI_BATCH_RANGE = PRI_TIMESHARE_RANGE - PRI_INTERACT_RANGE;
const SCHED_TICK_SECS = 10;
const SCHED_TICK_SHIFT = 10;

fn slpRunMax() i32 {
    return ((hz * 5) << SCHED_TICK_SHIFT);
}

fn schedTickTarg() i32 {
    return (hz * SCHED_TICK_SECS);
}

fn schedTickMax() i32 {
    return schedTickTarg() + hz;
}

const SWT_NONE = 0; // Unspecified switch.
const SWT_PREEMPT = 1; // Switching due to preemption.
const SWT_OWEPREEMPT = 2; // Switching due to owepreempt.
const SWT_TURNSTILE = 3; // Turnstile contention.
const SWT_SLEEPQ = 4; // Sleepq wait.
const SWT_SLEEPQTIMO = 5; // Sleepq timeout wait.
const SWT_RELINQUISH = 6; // yield call.
const SWT_NEEDRESCHED = 7; // NEEDRESCHED was set.
const SWT_IDLE = 8; // Switching from the idle thread.
const SWT_IWAIT = 9; // Waiting for interrupts.
const SWT_SUSPEND = 10; // Thread suspended.
const SWT_REMOTEPREEMPT = 11; // Remote processor preempted.
const SWT_REMOTEWAKEIDLE = 12; // Remote processor preempted idle.
const SWT_COUNT = 13; // Number of switch types.

const SW_VOL = 0x0100; // Voluntary switch.
const SW_INVOL = 0x0200; // Involuntary switch.
const SW_PREEMPT = 0x0400; // The invol switch is a preemption

const TSF_BOUND = 0x0001; // Thread can not migrate.
const TSF_XFERABLE = 0x0002; // Thread was added as transferable.

const TDF_NOLOAD = 0x00040000; // Ignore during load avg calculations.
const TDF_BORROWING = 0x00000001; // Thread is borrowing pri from another.
const TDF_IDLETD = 0x00000020; // This is a per-CPU idle thread.
const TDF_SCHED0 = 0x01000000; // Reserved for scheduler private use
const TDF_SCHED1 = 0x02000000; // Reserved for scheduler private use
const TDF_SCHED2 = 0x04000000; // Reserved for scheduler private use
const TDF_PICKCPU = TDF_SCHED0; // Thread should pick new CPU.
const TDF_SLICEEND = TDF_SCHED2; // Thread time slice is over.

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

const PRI_ITHD = 1; // Interrupt thread
const PRI_REALTIME = 2; // Real time thread
const PRI_TIMESHARE = 3; // Time share thread
const PRI_IDLE = 4; // Idle thread

const SCHED_SLICE_DEFAULT_DIVISOR = 10; // ~94 ms, 12 stathz ticks.
const SCHED_SLICE_MIN_DIVISOR = 6;
const SCHED_INTERACT_MAX = 100;
const SCHED_INTERACT_HALF = SCHED_INTERACT_MAX / 2;
const SCHED_INTERACT_THRESH = 30;
const SCHED_INTERACT = SCHED_INTERACT_THRESH;

var sched_slice: i32 = 10;
var sched_slice_min: i32 = 1;
var preempt_thresh: i32 = PRI_MIN_KERN;
var ticks: i32 = 0;
var tickincr: i32 = 0;
var blocked_lock: smp.SpinLock = .{};
var hz: i32 = 127;
var stathz: i32 = 127;
var affinity: i32 = 0;

pub const TdState = enum {
    inactive,
    inhibited,
    can_run,
    runq,
    running,
};

pub const SchedInfo = struct {
    cur_thrd: ?*Thread = null,
    tdq: ThreadQueue = .{},
    sched_ticks: i32 = 0,
    frame: usize = 0,
    switchtime: u64 = 0,
    switchticks: u64 = 0,
};

pub const Thread = struct {
    link: std.TailQueue(void).Node = undefined,
    mtx: smp.SpinLock = .{},

    ts_flags: i16, // TSF_* flags. */
    cpu: i32, // CPU that we have affinity for. */
    rltick: i32, // Real last tick, for affinity. */
    slice: i32, // Ticks of slice remaining. */
    slptime: u32, // Number of ticks we vol. slept */
    runtime: u16, // Number of ticks we were running */
    ltick: i32, // Last tick that we were running on */
    ftick: i32, // First tick that we were running on */
    ticks: i32, // Tick count */

    incruntime: i32, // Cpu ticks to transfer to proc. */
    pri_class: i32, // Scheduling class. */
    base_ithread_pri: i32,
    base_pri: i32, // Thread base kernel priority. */
    slptick: i32, // Time at sleep. */
    critnest: i32, // Critical section nest level. */
    swvoltick: i32, // Time at last SW_VOL switch. */
    swinvoltick: i32, // Time at last SW_INVOL switch. */
    inhibitors: u32, // Why can not run. */
    lastcpu: i32, // Last cpu we were on. */
    oncpu: i32, // Which cpu we are on. */
    priority: u8, // Thread active priority. */
    spinlock_count: i32,
    flags: u32,
    rqindex: i32, // Run queue index. */
    state: u32,
    user_pri: i32, // User pri from estcpu and nice. */
    base_user_pri: i32,
    lend_user_pri: i32,

    owepreempt: i32, //  Preempt on last critical_exit */
    spinlock_status: bool,
    sched_ast: i32,

    pub fn block(self: *Thread) void {
        var mtx = self.mtx;
        self.mtx = &blocked_lock;

        return mtx;
    }

    pub fn unblock(self: *Thread, new_lock: *smp.SpinLock) void {
        @atomicStore(usize, @ptrCast(*usize, &self.mtx), @ptrToInt(new_lock), .Release);
    }

    pub fn getAffinity(self: *Thread, t: i32) i32 {
        return (self.rltick > ticks - (t * affinity));
    }

    pub fn lock(self: *Thread) void {
        enterSchedLock();
        self.mtx.acq();
    }

    pub fn unlock(self: *Thread) void {
        self.mtx.rel();
        exitSchedLock();
    }

    pub fn isIdleThread(self: *Thread) bool {
        return (self.flags & TDF_IDLETD != 0);
    }
};

pub const RunQueue = struct {
    bits: [RQ_PRIO_COUNT / 16]u16 = std.mem.zeroes([RQ_PRIO_COUNT / 16]u16),
    queues: [RQ_PRIO_COUNT]std.TailQueue(void) = std.mem.zeroes([RQ_PRIO_COUNT]std.TailQueue(void)),

    inline fn setbit(self: *RunQueue, index: i32) void {
        self.bits[index / 16] |= (1 << (index % 16));
    }

    inline fn clrbit(self: *RunQueue, index: i32) void {
        self.bits[index / 16] &= ~@as(u16, 1 << (index % 16));
    }

    fn findbit(self: *RunQueue) ?i32 {
        var i: usize = 0;

        while (i < RQ_PRIO_COUNT / 16) : (i += 1) {
            var idx = ffs(self.bits[i]);
            if (idx != 0) {
                return idx + (i * 16);
            }
        }

        return null;
    }

    fn findbitFrom(self: *RunQueue, pri: u8) ?i32 {
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
        var pri: ?i32 = self.findbit();

        while (pri) |p| : (pri = self.findbit()) {
            var thrd = self.queues[p].first;
            std.debug.assert(thrd != null);

            return @fieldParentPtr(Thread, "link", thrd);
        }

        return null;
    }

    pub fn chooseFrom(self: *RunQueue, idx: u8) ?*Thread {
        var pri: ?i32 = self.findbitFrom(idx);

        while (pri) |p| : (pri = self.findbitFrom(idx)) {
            var thrd = self.queues[p].first;
            std.debug.assert(thrd != null);

            return @fieldParentPtr(Thread, "link", thrd);
        }

        return null;
    }
};

fn ffs(x: anytype) std.math.Log2IntCeil(@TypeOf(x)) {
    if (x == 0) return 0;
    return @ctz(x) + 1;
}

fn getTicks() u64 {
    // TODO(cleanbaja): tick subsystem
    return 0;
}

pub const ThreadQueue = struct {
    mtx: smp.SpinLock = .{},
    realtime: RunQueue = .{},
    timeshare: RunQueue = .{},
    idle: RunQueue = .{},
    idx: u8 = 0,
    ridx: u8 = 0,
    load: i32 = 0,
    sysload: i32 = 0,
    lowpri: i32 = 0,
    switchcnt: i32 = 0,
    oldswitchcnt: i32 = 0,
    owepreempt: bool = false,
    can_transfer: u32 = 0,
    cur_thread: *Thread = undefined,
    cpu_idle: i32 = 0,

    pub fn addRunq(self: *ThreadQueue, thrd: *Thread, flags: i32) void {
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

    pub fn addLoad(self: *ThreadQueue, thrd: *Thread) void {
        std.debug.assert(self.lock.isLocked());
        self.load += 1;

        if (thrd.flags & TDF_NOLOAD == 0)
            self.sysload += 1;
    }

    pub fn remLoad(self: *ThreadQueue, thrd: *Thread) void {
        std.debug.assert(self.lock.isLocked());
        std.debug.assert(self.load != 0);
        self.load -= 1;

        if (thrd.flags & TDF_NOLOAD == 0)
            self.sysload -= 1;
    }

    pub inline fn slice(self: *ThreadQueue) i32 {
        var load: i32 = self.sysload - 1;
        if (load >= SCHED_SLICE_MIN_DIVISOR)
            return sched_slice_min;
        if (load <= 1)
            return sched_slice;
        return @divTrunc(sched_slice, load);
    }

    pub fn setLowPri(self: *ThreadQueue, ctd: ?*Thread) void {
        std.debug.assert(self.lock.isLocked());
        var td: ?*Thread = undefined;
        var cur = ctd;

        if (cur == null)
            cur = self.cur_thread;

        td = self.choose();
        if (td == null or td.priority > cur.priority) {
            self.lowpri = cur.priority;
        } else {
            self.lowpri = td.priority;
        }
    }

    pub fn notify(self: *ThreadQueue, lowpri: i32) void {
        std.debug.assert(self.lock.isLocked());
        std.debug.assert(self.lowpri <= lowpri);

        //
        // If the queue is already awaiting a preempt, don't
        // start another one
        //
        if (self.owepreempt)
            return;

        //
        // Check to see if the newly added thread should
        // be able to preempt the current one...
        //
        if (!shouldPreempt(self.lowpri, lowpri, 1))
            return;

        //
        // The run queues have been updated, so any switch on the remote CPU
        // will satisfy the preemption request.
        //
        @fence(.SeqCst);
        self.owepreempt = 1;

        // TODO(cleanbaja): actually notify the CPU about the wakeup
    }

    pub fn choose(self: *ThreadQueue) ?*Thread {
        std.debug.assert(self.lock.isLocked());
        var thrd = self.realtime.choose();

        if (thrd) |t|
            return t;

        thrd = self.timeshare.chooseFrom(self.ridx);
        if (thrd) |t| {
            std.debug.assert(t.priority >= PRI_MIN_BATCH);
            return t;
        }

        thrd = self.idle.choose();
        if (thrd) |t| {
            std.debug.assert(t.priority >= PRI_MIN_IDLE);
            return t;
        }

        return null;
    }

    pub fn add(self: *ThreadQueue, thrd: *Thread, flags: i32) i32 {
        std.debug.assert(self.lock.isLocked());
        std.debug.assert(thrd.inhibitors == 0);
        std.debug.assert(thrd.canRun() or thrd.isRunning());

        var lowpri = self.lowpri;
        if (thrd.priority < lowpri)
            self.lowpri = thrd.priority;

        self.addRunq(thrd, flags);
        self.addLoad(thrd);

        return lowpri;
    }

    pub fn lock(self: *ThreadQueue) void {
        enterSchedLock();
        self.lock.acq();
    }
};

pub inline fn getSchedInfo() *SchedInfo {
    return &smp.getCoreInfo().sched_info;
}

pub inline fn getInfoOfCpu(cpu: u32) *SchedInfo {
    return &smp.getInfo(cpu).sched_info;
}

inline fn sliceThread(td: *Thread, queue: *ThreadQueue) i32 {
    if (td.pri_class == PRI_ITHD)
        return sched_slice;

    return queue.slice();
}

pub fn createKernelStack() ?u64 {
    if (pmm.allocPages(4)) |page| {
        return vmm.toHigherHalf(page + 4 * std.mem.page_size);
    } else {
        return null;
    }
}

inline fn shouldPreempt(pri: i32, cpri: i32, remote: i32) bool {
    //
    // If the new priority is lower than the current one, then it
    // isn't worth preempting
    //
    if (pri >= cpri)
        return false;

    //
    // Always preempt idle threads
    //
    if (cpri >= PRI_MIN_IDLE)
        return true;

    //
    // Don't preempt other threads if preemption is disabled
    //
    if (preempt_thresh == 0)
        return false;

    //
    // If we pass the threshold, then make preempting mandatory
    //
    if (pri <= preempt_thresh)
        return true;

    //
    // If the current thread is greater than interactive, with
    // non-interactive threads running, then preempt
    //
    if (remote and pri <= PRI_MAX_INTERACT and cpri > PRI_MAX_INTERACT)
        return true;

    return false;
}

pub fn hardclock(cnt: i32) void {
    var t = @ptrCast(*i32, &getSchedInfo().sched_ticks);
    var first_time = true;
    var newticks: i32 = 0;
    var global = ticks;
    t.* += cnt;

    while ((@cmpxchgStrong(i32, &ticks, global, t.*, .SeqCst, .SeqCst) == null) or first_time) {
        first_time = false;
        newticks = t.* - global;

        if (newticks <= 0) {
            if (newticks < -1)
                t.* = global - 1;

            newticks = 0;
            break;
        }
    }
}

inline fn enterCritical() void {
    getSchedInfo().cur_thrd.?.critnest += 1;
    @fence(.SeqCst);
}

inline fn exitCritical() void {
    var td = getSchedInfo().cur_thrd.?;
    std.debug.assert(td.critnest != 0);

    @fence(.SeqCst);
    td.critnest -= 1;
    @fence(.SeqCst);

    if (td.owepreempt != 0) {
        if (td.critnest != 0)
            return;
    }
}

inline fn enterSchedLock() void {
    var td = getSchedInfo().cur_thrd.?;

    if (td.spinlock_count == 0) {
        td.spinlock_status = arch.intrEnabled();
        if (td.spinlock_status)
            arch.setIntrMode(false);

        td.spinlock_count = 1;
        enterCritical();
    } else {
        td.spinlock_count += 1;
    }
}

inline fn exitSchedLock() void {
    var td = getSchedInfo().cur_thrd.?;

    td.spinlock_count -= 1;
    if (td.spinlock_count == 0) {
        exitCritical();
        if (td.spinlock_status)
            arch.setIntrMode(true);
    }
}

pub fn setcpu(td: *Thread, cpu: i32, flags: i32) *ThreadQueue {
    std.debug.assert(td.lock.isLocked());
    var tdq = getInfoOfCpu(cpu);
    td.cpu = cpu;

    //
    // If the locks are the same, don't do any more work
    //
    if (td.lock == &tdq.lock) {
        std.debug.assert(flags & SRQ_HOLD == 0);
        return tdq;
    }

    //
    // Otherwise, migrate the thread across
    //
    enterSchedLock();
    var mtx = td.block();
    if ((flags & SRQ_HOLD) == 0)
        mtx.rel();

    tdq.lock();
    td.unblock(&tdq.lock);
    exitSchedLock();
    return tdq;
}

fn interactScore(td: *Thread) i32 {
    var div: i32 = 0;

    //
    // The score is only needed if this is likely to be an interactive
    // task.  Don't go through the expense of computing it if there's
    // no chance.
    //
    if (SCHED_INTERACT_THRESH <= SCHED_INTERACT_HALF and
        td.runtime >= td.slptime)
        return SCHED_INTERACT_HALF;

    if (td.runtime > td.slptime) {
        div = std.math.max(1, td.runtime / SCHED_INTERACT_HALF);
        return SCHED_INTERACT_HALF +
            (SCHED_INTERACT_HALF - (td.slptime / div));
    }

    if (td.slptime > td.runtime) {
        div = std.math.max(1, td.slptime / SCHED_INTERACT_HALF);
        return td.runtime / div;
    }

    // runtime == slptime
    if (td.runtime)
        return SCHED_INTERACT_HALF;

    //
    // This can happen if slptime and runtime are 0.
    //
    return 0;
}

fn pickcpu(td: *Thread, flags: i32) i32 {
    var tdq: *ThreadQueue = undefined;
    var cpu: i32 = 0;

    var self = smp.getCoreId();
    //
    // Don't migrate a running thread from sched_switch().
    //
    if (flags & SRQ_OURSELF != 0)
        return td.cpu;
    //
    // Prefer to run interrupt threads on the processors that generate
    // the interrupt.
    //
    if (td.priority <= PRI_MAX_ITHD) {
        tdq = &getSchedInfo().tdq;
        if (tdq.lowpri >= PRI_MIN_IDLE) {
            return self;
        }
        td.cpu = self;
    } else {
        tdq = getInfoOfCpu(td.cpu);
        //
        // If the thread can run on the last cpu and the affinity has not
        // expired and it is idle, run it there.
        //
        if (@atomicLoad(u8, @ptrCast(*u8, &tdq.lowpri), .SeqCst) >= PRI_MIN_IDLE and td.affinity(2)) {
            return td.cpu;
        }
    }

    // Find least loaded cpu
    var currload = getInfoOfCpu(cpu).load;
    var i: usize = 0;
    cpu = 0;
    while (i < smp.getCpuCount()) : (i += 1) {
        tdq = &getInfoOfCpu(cpu).tdq;
        var load = tdq.load();
        if (load < currload) {
            currload = load;
            cpu = i;
        }
    }

    //
    // Compare the lowest loaded cpu to current cpu.
    //
    tdq = &getInfoOfCpu(cpu).tdq;
    if (getSchedInfo().tdq.lowpri > td.priority and
        @atomicLoad(u8, &tdq.lowpri, .SeqCst) < PRI_MIN_IDLE and
        getSchedInfo().tdq.load() <= tdq.load() + 1)
    {
        cpu = self;
    }
    return cpu;
}

fn userPrio(td: *Thread, prio: u8) void {
    // TODO(cleanbaja): implement this function properly
    td.base_user_pri = prio;
    td.user_pri = prio;
}

fn findPriority(td: *Thread) void {
    var pri: u32 = 0;
    var score: u32 = 0;

    if (td.pri_class != PRI_TIMESHARE)
        return;
    //
    // If the score is interactive we place the thread in the realtime
    // queue with a priority that is less than kernel and interrupt
    // priorities.  These threads are not subject to nice restrictions.
    //
    // Scores greater than this are placed on the normal timeshare queue
    // where the priority is partially decided by the most recent cpu
    // utilization and the rest is decided by nice value.
    //
    // The nice value of the process has a linear effect on the calculated
    // score.  Negative nice values make it easier for a thread to be
    // considered interactive.
    //
    score = std.math.max(0, interactScore(td));
    if (score < SCHED_INTERACT_THRESH) {
        pri = PRI_MIN_INTERACT;
        pri += (PRI_MAX_INTERACT - PRI_MIN_INTERACT + 1) * score /
            SCHED_INTERACT_THRESH;
        std.debug.assert(pri >= PRI_MIN_INTERACT and pri <= PRI_MAX_INTERACT);
    } else {
        pri = SCHED_PRI_MIN;
        if (td.ticks)
            pri += std.math.min(td.getPriTicks(), SCHED_PRI_RANGE - 1);

        std.debug.assert(pri >= PRI_MIN_BATCH and pri <= PRI_MAX_BATCH);
    }

    userPrio(td, pri);
}

fn updateInteract(td: *Thread) void {
    var sum: u32 = 0;

    sum = td.runtime + td.slptime;
    if (sum < slpRunMax())
        return;
    //
    // This only happens from two places:
    // 1) We have added an unusual amount of run time from fork_exit.
    // 2) We have added an unusual amount of sleep time from sched_sleep().
    //
    if (sum > slpRunMax() * 2) {
        if (td.runtime > td.slptime) {
            td.runtime = @intCast(u16, slpRunMax());
            td.slptime = 1;
        } else {
            td.slptime = slpRunMax();
            td.runtime = 1;
        }
        return;
    }
    //
    // If we have exceeded by more than 1/5th then the algorithm below
    // will not bring us back into range.  Dividing by two here forces
    // us into the range of [4/5 * SCHED_INTERACT_MAX, SCHED_INTERACT_MAX]
    //
    if (sum > (slpRunMax() / 5) * 6) {
        td.runtime /= 2;
        td.slptime /= 2;
        return;
    }
    td.runtime = (td.runtime / 5) * 4;
    td.slptime = (td.slptime / 5) * 4;
}

fn updatePctCpu(td: *Thread, run: i32) void {
    var t = ticks;

    //
    // The signed difference may be negative if the thread hasn't run for
    // over half of the ticks rollover period.
    //
    if (@intCast(u32, (t - td.ltick)) >= schedTickTarg()) {
        td.ticks = 0;
        td.ftick = t - schedTickTarg();
    } else if (t - td.ftick >= schedTickMax()) {
        td.ticks = @divTrunc(td.ticks, (td.ltick - td.ftick)) *
            (td.ltick - (t - schedTickTarg()));
        td.ftick = t - schedTickTarg();
    }
    if (run != 0)
        td.ticks += (t - td.ltick) << SCHED_TICK_SHIFT;
    td.ltick = t;
}

fn threadPriority(td: *Thread, prio: u8) void {
    var tdq: *ThreadQueue = undefined;
    var oldpri: i32 = 0;

    std.debug.assert(td.mtx.isLocked());
    if (td.priority == prio)
        return;
    //
    // If the priority has been elevated due to priority
    // propagation, we may have to move ourselves to a new
    // queue.  This could be optimized to not re-add in some
    // cases.
    //
    if (td.onRunq() and prio < td.priority) {
        removeThread(td);
        td.priority = prio;
        addThread(td, SRQ_BORROWING | SRQ_HOLDTD);
        return;
    }

    //
    // If the thread is currently running we may have to adjust the lowpri
    // information so other cpus are aware of our current priority.
    //
    if (td.isRunning()) {
        tdq = &getInfoOfCpu(td.cpu).tdq;
        oldpri = td.priority;
        td.priority = prio;

        if (prio < tdq.lowpri) {
            tdq.lowpri = prio;
        } else if (tdq.lowpri == oldpri) {
            tdq.setLowPri(td);
        }

        return;
    }

    td.priority = prio;
}

fn setPreempt(pri: i32) void {
    var ctd = getSchedInfo().cur_thrd;
    std.debug.assert(ctd.lock.isLocked());

    var cpri = ctd.priority;
    if (pri < cpri)
        ctd.sched_ast = 1;
    if (pri >= cpri or ctd.isInhibited())
        return;
    if (!shouldPreempt(pri, cpri, 0))
        return;

    ctd.owepreempt = 1;
}

fn addThread(td: *Thread, flags: i32) void {
    std.debug.assert(td.lock.isLocked());

    var tdq: *ThreadQueue = undefined;
    var lowpri: i32 = 0;
    var cpu: i32 = 0;

    //
    // Recalculate the priority before we select the target cpu or
    // run-queue.
    //
    if (td.pri_class == PRI_TIMESHARE)
        findPriority(td);

    //
    // Pick the destination cpu and if it isn't ours transfer to the
    // target cpu.
    //
    cpu = pickcpu(td, flags);
    tdq = setcpu(td, cpu, flags);
    lowpri = tdq.add(td, flags);

    if (cpu != smp.getCoreId()) {
        tdq.notify(lowpri);
    } else if (!(flags & SRQ_YIELDING)) {
        setPreempt(td.priority);
    }

    if (!(flags & SRQ_HOLDTD))
        td.unlock();
}

fn removeThread(td: *Thread) void {
    var tdq = &getInfoOfCpu(td.cpu).tdq;

    std.debug.assert(tdq.lock.isLocked());
    std.debug.assert(@ptrToInt(td.lock) == @ptrToInt(&tdq.lock));
    std.debug.assert(td.onRunq());

    tdq.remRunq(td);
    tdq.remLoad(td);
    td.state = .can_run;

    if (td.priority == tdq.lowpri)
        tdq.setLowPri(null);
}

pub fn lendPrio(td: *Thread, prio: u8) void {
    td.flags |= TDF_BORROWING;
    threadPriority(td, prio);
}

pub fn unlendPrio(td: *Thread, prio: u8) void {
    var base_pri: u8 = 0;

    if (td.base_pri >= PRI_MIN_TIMESHARE and td.base_pri <= PRI_MAX_TIMESHARE) {
        base_pri = td.user_pri;
    } else {
        base_pri = td.base_pri;
    }

    if (prio >= base_pri) {
        td.flags &= ~TDF_BORROWING;
        threadPriority(td, base_pri);
    } else {
        lendPrio(td, prio);
    }
}

fn setPrio(td: *Thread, prio: u8) void {
    // First, update the base priority.
    td.base_pri = prio;

    //
    // If the thread is borrowing another thread's priority, don't
    // ever lower the priority.
    //
    if (td.flags & TDF_BORROWING != 0 and td.priority < prio)
        return;

    // Change the real priority.
    threadPriority(td, prio);
}

fn lendUserPrio(td: *Thread, prio: u8) void {
    std.debug.assert(td.lock.isLocked());
    td.lend_user_pri = prio;
    td.user_pri = std.math.min(prio, td.base_user_pri);

    if (td.priority > td.user_pri) {
        setPrio(td, td.user_pri);
    } else if (td.priority != td.user_pri) {
        td.sched_ast = 1;
    }
}

//
// Like the above but first check if there is anything to do.
//
fn lendUserPrioCond(td: *Thread, prio: u8) void {
    if (td.lend_user_pri == prio or
        td.user_pri == std.math.min(prio, td.base_user_pri) or
        td.priority != td.user_pri)
        return;

    td.lock();
    lendUserPrio(td, prio);
    td.unlock();
}

fn switchMigrate(tdq: *ThreadQueue, td: *Thread, flags: i32) *smp.SpinLock {
    std.debug.assert((td.flags & TSF_BOUND) != 0);

    var lowpri: i32 = 0;
    var tdn = &getInfoOfCpu(td.cpu).tdq;
    tdq.remLoad(td);

    //
    // Do the lock dance required to avoid LOR.  We have an
    // extra spinlock nesting from switch() which will
    // prevent preemption while we're holding neither run-queue lock.
    //
    tdq.unlock();
    tdn.lock();
    lowpri = tdn.add(td, flags);
    tdn.notify(lowpri);
    tdn.unlock();
    tdq.lock();

    return &tdn.lock;
}

fn chooseThread() *Thread {
    var td = choose();
    td.state = .running;
    return td;
}

fn choose() *Thread {
    var tdq = &getSchedInfo().tdq;
    std.debug.assert(tdq.mtx.isLocked());
    var thrd = tdq.choose();

    if (thrd) |t| {
        tdq.remRunq(t);
        tdq.lowpri = t.priority;
    } else {
        tdq.lowpri = PRI_MAX_IDLE;
        thrd = &getSchedInfo().idle_thread;
    }

    tdq.tdq_curthread = thrd;
    return thrd;
}

fn swithd(td: *Thread, flags: i32) void {
    std.debug.assert(td.mtx.isLocked());
    var cpuid = smp.getCoreInfo();
    var tdq = &getSchedInfo().tdq;
    var srqflag: i32 = 0;

    updatePctCpu(td, 1);
    var pkcpu = (td.flags & TDF_PICKCPU) != 0;

    if (pkcpu) {
        td.rltick = ticks - affinity * MAX_CACHE_LEVELS;
    } else {
        td.rltick = ticks;
    }

    var preempted = (td.flags & TDF_SLICEEND) == 0 and (flags & SW_PREEMPT) != 0;
    td.lastcpu = td.oncpu;
    td.flags &= ~(TDF_PICKCPU | TDF_SLICEEND);
    td.sched_ast = 0;
    td.owepreempt = 0;

    @atomicStore(u8, &tdq.owepreempt, 0, .SeqCst);
    if (!td.isIdleThread())
        _ = @atomicRmw(i32, &tdq.switchcnt, .Add, 1, .SeqCst);

    //
    // Always block the thread lock so we can drop the tdq lock early.
    //
    var mtx = td.block();
    enterSchedLock();
    if (td.isIdleThread()) {
        std.debug.assert(@ptrToInt(mtx) == @ptrToInt(&tdq.mtx));
        td.state = .can_run;
    } else if (td.isRunning()) {
        std.debug.assert(@ptrToInt(mtx) == @ptrToInt(&tdq.mtx));
        srqflag = SRQ_OURSELF | SRQ_YIELDING;
        if (preempted) {
            srqflag |= SRQ_PREEMPTED;
        }

        if (pkcpu) {
            td.cpu = pickcpu(td, 0);
        }
        if (td.cpu == cpuid) {
            tdq.addRunq(td, srqflag);
        } else {
            mtx = switchMigrate(tdq, td, srqflag);
        }
    } else {
        // This thread must be going to sleep.
        if (@ptrToInt(mtx) != @ptrToInt(&tdq.mtx)) {
            mtx.rel();
            tdq.lock();
        }

        tdq.remLoad(td);

        // TODO: SMP optimizations
        // if (tdq.tdq_load == 0)
        //    tdq_trysteal(tdq);
    }

    //
    // We enter here with the thread blocked and assigned to the
    // appropriate cpu run-queue or sleep-queue and with the current
    // thread-queue locked.
    //
    std.debug.assert(tdq.mtx.isLocked());
    std.debug.assert(td == tdq.tdq_curthread);

    var newtd = chooseThread();
    updatePctCpu(newtd, 0);
    tdq.unlock();

    //
    // Call the MD code to switch contexts if necessary.
    //
    td.oncpu = NOCPU;
    performSwitch(td, newtd, mtx);
}

pub fn performSwitch(old: *Thread, new: *Thread, mtx: *smp.SpinLock) void {
    std.debug.assert(getSchedInfo().frame != 0);
    var ctx = @intToPtr(*trap.TrapFrame, getSchedInfo().frame);
    getSchedInfo().frame = 0;
    arch.ic.oneshot(TIMER_VECTOR, 10);

    std.debug.assert(new.critnest == 1);
    new.spinlock_count = 0;
    new.critnest = 0;

    // TODO(cleanbaja): fpu memes
    old.* = ctx.*;
    @atomicStore(usize, @ptrCast(*usize, &old.lock), @ptrToInt(mtx), .Release);
    while (@atomicLoad(usize, @ptrCast(*usize, &new.lock), .Acquire) == &blocked_lock) {}

    getSchedInfo().cur_thrd = new;
    new.oncpu = smp.getCoreId();

    ctx.* = new.*;
}

fn sleep(td: *Thread, prio: i32) void {
    _ = prio;

    std.debug.assert(td.mtx.isLocked());
    td.slptick = ticks;

    if (td.pri_class != PRI_TIMESHARE)
        return;
    if (td.priority > PRI_MIN_BATCH)
        setPrio(td, PRI_MIN_BATCH);
}

fn wakeup(td: *Thread, srqflags: i32) void {
    std.debug.assert(td.mtx.isLocked());

    //
    // If we slept for more than a tick update our interactivity and
    // priority.
    //
    var slptick = td.slptick;
    td.slptick = 0;
    if (slptick != 0 and slptick != ticks) {
        td.slptime += (ticks - slptick) << SCHED_TICK_SHIFT;
        updateInteract(td);
        updatePctCpu(td, 0);
    }

    //
    // When resuming an idle ithread, restore its base ithread
    // priority.
    //
    if (td.pri_class == PRI_ITHD and td.priority != td.base_ithread_pri)
        setPrio(td, td.base_ithread_pri);

    //
    // Reset the slice value since we slept and advanced the round-robin.
    //
    td.slice = 0;
    addThread(td, SRQ_BORING | srqflags);
}

fn preempt(td: *Thread) void {
    var tdq = &getSchedInfo().tdq;
    std.debug.assert(tdq.mtx.isLocked());
    td.lock();

    if (td.priority > tdq.lowpri) {
        if (td.critnest == 1) {
            var flags = SW_INVOL | SW_PREEMPT;
            if (td.isIdleThread()) {
                flags |= SWT_REMOTEWAKEIDLE;
            } else {
                flags |= SWT_REMOTEPREEMPT;
            }

            miSwitch(flags);

            // Switch dropped thread lock.
            return;
        }
        td.owepreempt = 1;
    } else {
        tdq.owepreempt = 0;
    }
    td.unlock();
}

fn clock(td: *Thread, cnt: i32) void {
    std.debug.assert(td.mtx.isLocked());
    var tdq = &getSchedInfo().tdq;

    // TODO(cleanbaja): load balancing

    //
    // Save the old switch count so we have a record of the last ticks
    // activity.   Initialize the new switch count based on our load.
    // If there is some activity seed it to reflect that.
    //
    tdq.oldswitchcnt = tdq.switchcnt;
    tdq.switchcnt = tdq.load;

    //
    // Advance the insert index once for each tick to ensure that all
    // threads get a chance to run.
    //
    if (tdq.idx == tdq.ridx) {
        tdq.idx = (tdq.idx + 1) % RQ_PRIO_COUNT;
        if ((tdq.timeshare.queues[tdq.ridx].first) == null)
            tdq.ridx = tdq.idx;
    }

    updatePctCpu(td, 1);
    if (td.isIdleThread())
        return;

    if (td.pri_class == PRI_TIMESHARE) {
        //
        // We used a tick; charge it to the thread so
        // that we can compute our interactivity.
        //
        td.runtime += @intCast(u16, tickincr * cnt);
        updateInteract(td);
        findPriority(td);
    }

    //
    // Force a context switch if the current thread has used up a full
    // time slice (default is 100ms).
    //
    td.slice += cnt;
    if (td.slice >= sliceThread(td, tdq)) {
        td.slice = 0;

        //
        // If an ithread uses a full quantum, demote its
        // priority and preempt it.
        //
        if (td.pri_class == PRI_ITHD) {
            td.owepreempt = 1;
            if (td.base_pri + RQ_PPQ < PRI_MAX_ITHD) {
                setPrio(td, @intCast(u8, td.base_pri + RQ_PPQ));
            }
        } else {
            td.sched_ast = 1;
            td.flags |= TDF_SLICEEND;
        }
    }
}

fn miSwitch(flags: i32) void {
    var td = getSchedInfo().cur_thread; // XXX

    std.debug.assert(td.mtx.isLocked());
    std.debug.assert(!td.onRunq());
    std.debug.assert(td.critnest == 1);
    std.debug.assert(flags & (SW_INVOL | SW_VOL) != 0);

    if (flags & SW_VOL) {
        td.swvoltick = ticks;
    } else {
        td.swinvoltick = ticks;
    }

    //
    // Compute the amount of time during which the current
    // thread was running, and add that to its total so far.
    //
    var new_switchtime = getTicks();
    var runtime = new_switchtime - getSchedInfo().switchtime;
    td.runtime += runtime;
    td.incruntime += runtime;

    getSchedInfo().switchtime = new_switchtime;
    getSchedInfo().switchticks = ticks;
    swithd(td, flags);
}

fn statclock(cnt: i32) void {
    var td = getSchedInfo().cur_thrd.?;
    td.lock();

    //
    // Compute the amount of time during which the current
    // thread was running, and add that to its total so far.
    //
    var new_switchtime = getTicks();
    var runtime = new_switchtime - getSchedInfo().switchtime;
    td.runtime += @truncate(u16, runtime);
    td.incruntime += @intCast(i32, runtime);
    getSchedInfo().switchtime = new_switchtime;

    clock(td, cnt);
    td.unlock();
}

pub fn reschedule(frame: *trap.TrapFrame) callconv(.C) void {
    getSchedInfo().frame = @ptrToInt(frame);
    arch.ic.oneshot(TIMER_VECTOR, 10);
    arch.ic.submitEoi(TIMER_VECTOR);

    hardclock(1);
    // statclock(1);

    // runSchedulerAst();
    sink.info("global ticks: {}, local_ticks: {}", .{ ticks, getSchedInfo().sched_ticks });
}

pub fn init() !void {
    arch.trap.setHandler(reschedule, TIMER_VECTOR);
    smp.getCoreInfo().tss.ist1 = createKernelStack() orelse return error.OutOfMemory;
    arch.ic.oneshot(TIMER_VECTOR, 10);
    asm volatile ("sti");
    while (true) {}
}
