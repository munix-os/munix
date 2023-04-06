const irq = @import("../dev/irq.zig");
const atomic = @import("std").atomic;

pub const SpinMutex = struct {
    bits: atomic.Atomic(u8) = .{ .value = 0 },
    irql: u16 = 0,

    fn lockInternal(self: *SpinMutex, old: u16, new: u16) void {
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
            //
            if (self.bits.swap(1, .Acquire) == 0) {
                // 'self.bits.swap' translates to a XCHG
                break;
            }

            while (self.bits.fetchAdd(0, .Monotonic) != 0) {
                // bump IRQL so we can recive higher prio
                // IRQs while waiting...
                irq.setIrql(old);

                atomic.spinLoopHint();
                irq.setIrql(new);
            }
        }

        atomic.compilerFence(.Acquire);
        self.irql = old;
    }

    pub fn lock(self: *SpinMutex) void {
        var old = irq.getIrql();
        irq.setIrql(irq.DPC_LEVEL);

        self.lockInternal(old, irq.DPC_LEVEL);
    }

    pub fn lockAt(self: *SpinMutex, level: u16) void {
        var old = irq.getIrql();
        irq.setIrql(level);

        self.lockInternal(old, level);
    }

    pub fn unlock(self: *SpinMutex) void {
        var irql = self.irql;
        self.bits.store(0, .Release);

        irq.setIrql(irql);
    }
};
