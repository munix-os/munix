const std = @import("std");
const trap = @import("root").arch.trap;
const allocator = @import("root").allocator;

const smp = @import("../smp.zig");
const sync = @import("../util/sync.zig");

// zig fmt: off
pub const IRQ_MASKED:    u8 = 0b00001;
pub const IRQ_DISABLED:  u8 = 0b00010;
pub const IRQ_PENDING:   u8 = 0b00100;
pub const IRQ_INSERVICE: u8 = 0b01000;
pub const IRQ_SMPSAFE:   u8 = 0b10000;

// zig fmt: on
pub const IrqType = enum {
    none,
    edge,
    level,
    smpirq,
};

pub const IrqHandler = struct {
    priv_data: ?*anyopaque = null,
    func: *const fn (*IrqHandler, *trap.TrapFrame) void,
    pin: *IrqPin,
};

pub const IrqPin = struct {
    handlers: std.ArrayList(IrqHandler) = undefined,
    context: *anyopaque = undefined,
    name: []const u8 = undefined,

    lock: sync.SpinMutex = .{},
    kind: IrqType = .none,
    flags: u8 = 0,

    setMask: *const fn (*IrqPin, bool) void = undefined,
    configure: *const fn (*IrqPin, bool, bool) IrqType = undefined,
    eoi: *const fn (*IrqPin) void = undefined,

    fn handleIrqSmp(self: *IrqPin, frame: *trap.TrapFrame) void {
        for (self.handlers.items) |hnd| {
            hnd.func(frame);
        }
    }

    fn handleIrq(self: *IrqPin, frame: *trap.TrapFrame) void {
        self.flags &= ~IRQ_PENDING;
        self.flags |= IRQ_INSERVICE;
        self.lock.unlock();

        handleIrqSmp(frame);

        self.lock.lock();
        self.flags &= ~IRQ_INSERVICE;
    }

    pub fn trigger(self: *IrqPin, frame: *trap.TrapFrame) void {
        if (@atomicLoad(IrqType, &self.kind, .SeqCst) == .smpirq) {
            // take the SMP fastpath
            self.handleIrqSmp(frame);

            self.eoi();
            return;
        }

        self.lock.lock();

        switch (self.kind) {
            .level => {
                self.setMask(true);
                self.eoi();

                if (self.flags & IRQ_DISABLED != 0) {
                    self.flags |= IRQ_PENDING;
                    self.lock.unlock();
                    return;
                }

                self.handleIrq(frame);

                if (self.flags & (IRQ_DISABLED | IRQ_MASKED) == 0)
                    self.setMask(false);

                self.lock.unlock();
            },
            .edge => {
                if (self.flags & IRQ_DISABLED != 0 or
                    self.handlers.items.len == 0)
                {
                    self.flags |= IRQ_PENDING;
                    self.setMask(true);
                    self.eoi();

                    self.lock.unlock();
                    return;
                }

                self.eoi();
                self.handleIrq();
            },
            else => @panic("unknown IRQ type!"),
        }
    }

    pub fn setup(self: *IrqPin, name: []const u8, level: bool, high_trig: bool) void {
        self.name = name;
        self.kind = self.configure(level, high_trig);
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

//pub export fn drainSoftIrqs() callconv(.C) void {
//    while (smp.getCoreInfo().softirqs.pop()) |item| {
//        var irq = @fieldParentPtr();
//    }
//}
