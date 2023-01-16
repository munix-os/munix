const trap = @import("root").arch.trap;
const arch = @import("root").arch;
const proc = @import("root").proc;
const smp = @import("root").smp;
const pmm = @import("root").pmm;
const vmm = @import("root").vmm;

const allocator = @import("root").allocator;

pub const Thread = struct {
    link: Node,
    context: trap.TrapFrame,
    kernel_stack: u64,
    id: usize = 0,
    proc: *proc.Process,
};

pub const Node = struct {
    next: ?*Node = undefined,
};

pub fn Queue(comptime T: type, comptime member_name: []const u8) type {
    return struct {
        head: ?*Node = null,
        tail: ?*Node = null,
        lock: smp.SpinLock = .{},

        fn refToNode(ref: *T) *Node {
            return &@field(ref, member_name);
        }

        fn nodeToRef(node: *Node) *T {
            return @fieldParentPtr(T, member_name, node);
        }

        pub fn enqueue(self: *@This(), node: *T) void {
            self.lock.acq();
            defer self.lock.rel();

            const hook = refToNode(node);
            hook.next = null;

            if (self.tail) |tail_nonnull| {
                tail_nonnull.next = hook;
                self.tail = hook;
            } else {
                @import("std").debug.assert(self.head == null);
                self.head = hook;
                self.tail = hook;
            }
        }

        pub fn dequeue(self: *@This()) ?*T {
            self.lock.acq();
            defer self.lock.rel();

            if (self.head) |head_nonnull| {
                if (head_nonnull.next) |next| {
                    self.head = next;
                } else {
                    self.head = null;
                    self.tail = null;
                }
                return nodeToRef(head_nonnull);
            }
            return null;
        }
    };
}

pub const TIMER_VECTOR = 0x30;
var thread_list = Queue(Thread, "link"){};
var sched_lock = smp.SpinLock{};

pub fn exit() noreturn {
    smp.getCoreInfo().cur_thread = null;

    arch.ic.oneshot(TIMER_VECTOR, 1);
    while (true) {}
}

pub fn createKernelStack() ?u64 {
    if (pmm.allocPages(4)) |page| {
        return vmm.toHigherHalf(page + 4 * pmm.PAGE_SIZE);
    } else {
        return null;
    }
}

fn getNextThread() *Thread {
    sched_lock.acq();
    defer sched_lock.rel();

    if (thread_list.dequeue()) |elem| {
        return elem;
    } else {
        // set a new timer for later
        sched_lock.rel();
        arch.ic.submitEoi(TIMER_VECTOR);
        arch.ic.oneshot(TIMER_VECTOR, 20);

        vmm.kernel_pagemap.load();
        asm volatile ("sti");
        while (true) {}
    }
}

pub fn reschedule(frame: *trap.TrapFrame) callconv(.C) void {
    if (smp.getCoreInfo().cur_thread) |old_thread| {
        old_thread.context = frame.*;
        smp.getCoreInfo().cur_thread = null;

        sched_lock.acq();
        thread_list.enqueue(old_thread);
        sched_lock.rel();
    }

    var thread = getNextThread();
    smp.getCoreInfo().cur_thread = thread;
    smp.getCoreInfo().tss.rsp0 = thread.kernel_stack;

    frame.* = thread.context;
    thread.proc.pagemap.load();

    arch.ic.submitEoi(TIMER_VECTOR);
    arch.ic.oneshot(TIMER_VECTOR, 20);
}

pub fn spawnKernelThread(func: *const fn (u64) noreturn, arg: ?u64) !*Thread {
    const target = @import("builtin").target.cpu.arch;
    const mem = @import("std").mem;

    var thread = try allocator().create(Thread);
    thread.kernel_stack = createKernelStack() orelse return error.OutOfMemory;
    thread.context = mem.zeroes(trap.TrapFrame);
    errdefer allocator().destroy(thread);

    switch (target) {
        .x86_64 => {
            thread.context.rip = @ptrToInt(func);
            thread.context.rsp = thread.kernel_stack;
            thread.context.ss = 0x30;
            thread.context.cs = 0x28;
            thread.context.rflags = 0x202;

            if (arg) |elem| {
                thread.context.rdi = elem;
            }
        },
        else => {
            @panic("unsupported architecture " ++ @tagName(target) ++ "!");
        },
    }

    sched_lock.acq();
    thread_list.enqueue(thread);
    sched_lock.rel();

    return thread;
}

pub fn enter() void {
    smp.getCoreInfo().tss.ist1 = createKernelStack().?;

    arch.ic.oneshot(TIMER_VECTOR, 20);
    asm volatile ("sti");
}
