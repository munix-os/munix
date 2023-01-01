const atomic = @import("std").atomic;
const arch = @import("root").arch;
const AtomicType = atomic.Atomic;

pub const SpinLock = struct {
    lock_bits: AtomicType(u32) = .{ .value = 0 },
    refcount: AtomicType(usize) = .{ .value = 0 },
    lock_level: arch.Irql = .critical,
    level: arch.Irql = undefined,
    holder: i32 = -1,

    pub fn acq(self: *SpinLock) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);

        // SpinLocks in munix work in terms of IRQ
        // levels, rather than the coneventional method
        // of completly disabling IRQs. This means that a
        // select amount of IRQs can be recived while
        // in a spinlock, such as panic IPIs
        var current = arch.getIrql();
        arch.setIrql(self.lock_level);

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
            if (self.lock_bits.swap(1, .Acquire) == 0) {
                // 'self.lock_bits.swap' translates to a XCHG
                break;
            }

            while (self.lock_bits.fetchAdd(0, .Monotonic) != 0) {
                // IRQs can be recived while waiting
                // for the lock to be available...
                arch.setIrql(current);
                atomic.spinLoopHint();
                arch.setIrql(self.lock_level);
            }
        }

        _ = self.refcount.fetchSub(1, .Monotonic);
        atomic.compilerFence(.Acquire);
        self.lock_level = current;
    }

    pub fn rel(self: *SpinLock) void {
        self.lock_bits.store(0, .Release);
        atomic.compilerFence(.Release);
        arch.setIrql(self.level);
    }

    // wrappers for zig stdlib
    pub inline fn lock(self: *SpinLock) void {
        self.acq();
    }
    pub inline fn unlock(self: *SpinLock) void {
        self.rel();
    }
};
