const trap = @import("root").arch.trap;
const arch = @import("root").arch;
const smp = @import("root").smp;
const pmm = @import("root").pmm;
const vmm = @import("root").vmm;
const std = @import("std");

const allocator = @import("root").allocator;

pub const Thread = struct {
    id: usize,
    context: trap.TrapFrame,
    node: std.TailQueue(void).Node = undefined,
};

pub const TIMER_VECTOR = 0x30;
var thread_queue = std.TailQueue(void){};
var sched_lock = smp.SpinLock{};

fn getNextThread() *Thread {
    sched_lock.acq();

    if (thread_queue.popFirst()) |elem| {
        sched_lock.rel();
        return @fieldParentPtr(Thread, "node", elem);
    } else {
        sched_lock.rel();
        arch.ic.submitEoi(TIMER_VECTOR);
        arch.ic.oneshot(TIMER_VECTOR, 20);

        // TODO: space swap
        while (true) {}
    }
}

pub fn createKernelStack() ?u64 {
    if (pmm.allocPages(4)) |page| {
        return vmm.toHigherHalf(page + 4 * pmm.PAGE_SIZE);
    } else {
        return null;
    }
}

pub fn exit() noreturn {
    smp.getCoreInfo().cur_thread = null;

    arch.ic.oneshot(TIMER_VECTOR, 1);
    while (true) {}
}

pub fn reschedule(frame: *trap.TrapFrame) callconv(.C) void {
    var thread = getNextThread();

    if (smp.getCoreInfo().cur_thread) |old_thread| {
        old_thread.context = frame.*;

        sched_lock.acq();
        thread_queue.append(&old_thread.node);
        sched_lock.rel();
    }

    smp.getCoreInfo().cur_thread = thread;
    frame.* = thread.context;
    arch.ic.submitEoi(TIMER_VECTOR);
    arch.ic.oneshot(TIMER_VECTOR, 20);

    // TODO: space swap
}

pub fn enter() void {
    smp.getCoreInfo().tss.ist1 = createKernelStack().?;

    arch.ic.oneshot(TIMER_VECTOR, 20);
    asm volatile ("sti");
}
