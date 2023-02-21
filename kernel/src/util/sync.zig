const atomic = @import("std").atomic;
const arch = @import("root").arch;

pub const SpinMutex = struct {
    irq_aware: bool = true,
    irq_state: bool = false,
    serving: u32 = 0,
    next: u32 = 0,

    pub fn lock(self: *SpinMutex) void {
        var ticket = @atomicRmw(u32, &self.next, .Add, 1, .Monotonic);
        var irq_state = arch.intrEnabled();

        if (self.irq_aware) {
            arch.setIntrMode(false);
        }

        while (@atomicLoad(u32, &self.serving, .Acquire) != ticket) {
            if (irq_state and self.irq_aware) {
                arch.setIntrMode(true);
                atomic.spinLoopHint();
                arch.setIntrMode(false);
            } else {
                atomic.spinLoopHint();
            }
        }

        if (self.irq_aware) {
            self.irq_state = irq_state;
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        var irq_state = self.irq_state and self.irq_aware;
        var cur = @atomicLoad(u32, &self.serving, .Monotonic);
        @atomicStore(u32, &self.serving, cur + 1, .Release);

        if (irq_state)
            arch.setIntrMode(true);
    }
};
