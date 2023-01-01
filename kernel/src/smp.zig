const atomic = @import("std").atomic;
const arch = @import("root").arch;
const AtomicType = atomic.Atomic;

pub const SpinLock = struct {
    lock_bits: AtomicType(u32) = .{ .value = 0 },
    refcount: AtomicType(usize) = .{ .value = 0 },
    holder: i32 = -1,

    pub fn lock(self: *SpinLock) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);

        while (true) {
            // ----------------------------------------------
            // x86 Instruction | Micro ops | Base Latency
            // ----------------------------------------------
            // XCHG                  8           23
            // LOCK XADD             9           18
            // LOCK CMPXCHG          10          18
            // LOCK CMPXCHG8B        20          19
            // ----------------------------------------------
            // According to the above table, the XCHG
            // instruction takes the fewest amount of micro
            // ops to complete, yet it has the highest base
            // latency. Since lower micro ops is the goal
            // here, I chose to go with XCHG.
            // ----------------------------------------------
            // Source: https://agner.org/optimize/instruction_tables.pdf
            if (self.lock_bits.swap(1, .Acquire) == 0) {
                // 'self.lock_bits.swap' translates to a XCHG
                break;
            }

            while (self.lock_bits.fetchAdd(0, .Monotonic) != 0) {
                atomic.spinLoopHint();
            }
        }

        _ = self.refcount.fetchSub(1, .Monotonic);

        // TODO(cleanbaja): determine whether a fence here is required, since
        // it has slight performance implications
        self.refcount.fence(.Acquire);
    }

    pub fn ilock(self: *SpinLock) u16 {
        arch.setIrql(.critical);
        self.lock();
        return @enumToInt(arch.getIrql());
    }

    pub fn rel(self: *SpinLock) void {
        self.lock_bits.store(0, .Release);
    }

    pub fn irel(self: *SpinLock, irql: u16) void {
        self.rel();
        arch.setIrql(@intToEnum(arch.Irql, irql));
    }
};
