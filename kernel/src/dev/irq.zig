const std = @import("std");
const trap = @import("root").arch.trap;
const smp = @import("root").smp;
const allocator = @import("root").allocator;
const sink = std.log.scoped(.irq);

pub const IRQ_MASKED: u8 = 0b0001;
pub const IRQ_PENDING: u8 = 0b0010;
pub const IRQ_INSERVICE: u8 = 0b0100;
pub const IRQ_SMPSAFE: u8 = 0b1000;

const IrqAction = enum {
    nothing,
    onlyEoi,
    maskAndEoi,
};

pub const IrqHandler = struct {
    context: ?*anyopaque = null,
    func: *const fn (*IrqHandler, *trap.TrapFrame) void,
    pin: *IrqPin,
};

pub const IrqPin = struct {
    handlers: std.ArrayList(IrqHandler) = undefined,
    lock: smp.SpinLock = .{},
    action: IrqAction = .nothing,

    priv_data: *anyopaque = undefined,
    name: []const u8 = undefined,
    flags: u8 = 0,

    setMask: *const fn (*IrqPin, bool) void = undefined,
    program: *const fn (*IrqPin, bool, bool) IrqAction = undefined,
    eoi: *const fn (*IrqPin) void = undefined,

    pub fn lockFreeTrigger(self: *IrqPin, frame: *trap.TrapFrame, can_modify: bool) void {
        if (self.flags & IRQ_MASKED) {
            sink.warn("hardware race condition detected for pin \"{s}\"!", .{self.name});
            self.eoi();
            return;
        }

        switch (self.action) {
            .onlyEoi => {
                self.eoi();
            },
            .maskAndEoi => {
                self.setMask(true);
                if (can_modify) {
                    self.flags |= IRQ_MASKED;
                }
                self.eoi();
            },
            .nothing => unreachable,
        }

        self.callHandlers(frame);

        if (self.action == .maskAndEoi) {
            self.setMask(false);
            if (can_modify) {
                self.flags &= ~IRQ_MASKED;
            }
        }
    }

    pub fn callHandlers(self: *IrqPin, frame: *trap.TrapFrame) void {
        for (self.handlers.items) |hnd| {
            hnd.func(frame);
        }
    }

    pub fn trigger(self: *IrqPin, frame: *trap.TrapFrame) void {
        if (@atomicLoad(u8, &self.flags, .SeqCst) & IRQ_SMPSAFE) {
            // take the lock-free fastpath
            self.lockFreeTrigger(frame, false);
            return;
        }

        self.lock.acq();
        defer self.lock.rel();

        self.lockFreeTrigger(frame, true);
    }

    pub fn setup(self: *IrqPin, name: []const u8, level: bool, high_trig: bool) void {
        self.name = name;
        self.action = self.program(level, high_trig);
        self.handlers = std.ArrayList(IrqHandler).init(allocator());
    }

    pub fn attach(self: *IrqPin, handler: *IrqHandler) void {
        handler.pin = self;
        self.handlers.append(&handler.link);
    }
};

pub const IrqSlot = struct {
    pin: ?*IrqPin = null,
    active: bool = false,

    pub fn trigger(self: *IrqSlot, frame: *trap.TrapFrame) void {
        std.debug.assert(self.pin != null);

        self.pin.?.trigger(frame);
    }

    pub fn link(self: *IrqSlot, pin: *IrqPin) void {
        std.debug.assert(self.pin == null);

        self.pin = pin;
        self.active = true;
    }
};
