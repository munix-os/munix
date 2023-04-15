const std = @import("std");
const sync = @import("../util/sync.zig");
const smp = @import("../smp.zig");

const trap = @import("root").arch.trap;
const allocator = @import("root").allocator;
const cpu_arch = @import("builtin").target.cpu.arch;

// zig fmt: off
pub const IRQ_MASKED:    u8 = 0b00001;
pub const IRQ_DISABLED:  u8 = 0b00010;
pub const IRQ_PENDING:   u8 = 0b00100;
pub const IRQ_INSERVICE: u8 = 0b01000;
pub const IRQ_SMPSAFE:   u8 = 0b10000;

pub const PASSIVE_LEVEL: u8 = 0;
pub const DPC_LEVEL:     u8 = 2;
pub const DEVICE_LEVEL:  u8 = 12;
pub const CLOCK_LEVEL:   u8 = 13;
pub const MAX_LEVEL:     u8 = 15;

//
// A minimum of 5 lazy DPCs must be queued
// for an IRQ to be dispatched
//
// zig fmt: on
pub const DPC_QUEUE_THRESH = 5;

pub const IrqType = enum {
    none,
    edge,
    level,
    smpirq,
};

pub const Dpc = struct {
    node: std.TailQueue(void).Node = undefined,
    func: *const fn (*anyopaque) void = undefined,
    arg: *anyopaque = undefined,
    lazy: bool = true,
    cpu: ?u32 = null,

    lock: ?*sync.SpinMutex = null,
};

pub const IrqHandler = struct {
    priv_data: ?*anyopaque = null,
    func: *const fn (*IrqHandler, *trap.TrapFrame) void,
    pin: *IrqPin,
};

pub const IrqPin = struct {
    handlers: std.ArrayList(*IrqHandler) = undefined,
    context: *anyopaque = undefined,
    name: []const u8 = undefined,

    lock: sync.SpinMutex = .{},
    kind: IrqType = .none,
    flags: u8 = 0,

    setMask: *const fn (self: *IrqPin, masked: bool) void = undefined,
    configure: *const fn (self: *IrqPin) void = undefined,
    eoi: *const fn (self: *IrqPin) void = undefined,

    fn handleIrqSmp(self: *IrqPin, frame: *trap.TrapFrame) void {
        for (self.handlers.items) |hnd| {
            hnd.func(hnd, frame);
        }
    }

    fn handleIrq(self: *IrqPin, frame: *trap.TrapFrame) void {
        self.flags &= ~IRQ_PENDING;
        self.flags |= IRQ_INSERVICE;
        self.lock.unlock();

        self.handleIrqSmp(frame);

        self.lock.lock();
        self.flags &= ~IRQ_INSERVICE;
    }

    pub fn trigger(self: *IrqPin, frame: *trap.TrapFrame) void {
        const setMask = self.setMask;
        const eoi = self.eoi;

        if (self.kind == .smpirq) {
            // take the SMP fastpath
            self.handleIrqSmp(frame);

            eoi(self);
            return;
        }

        self.lock.lock();

        switch (self.kind) {
            .level => {
                setMask(self, true);
                eoi(self);

                if (self.flags & IRQ_DISABLED != 0) {
                    self.flags |= IRQ_PENDING;
                    self.lock.unlock();
                    return;
                }

                self.handleIrq(frame);

                if (self.flags & (IRQ_DISABLED | IRQ_MASKED) == 0)
                    setMask(self, false);
            },
            .edge => {
                if (self.flags & IRQ_DISABLED != 0 or
                    self.handlers.items.len == 0)
                {
                    self.flags |= IRQ_PENDING;
                    setMask(self, true);
                    eoi(self);

                    self.lock.unlock();
                    return;
                }

                eoi(self);
                self.handleIrq(frame);
            },
            else => @panic("unknown IRQ type!"),
        }

        self.lock.unlock();
    }

    pub fn attach(self: *IrqPin, handler: *IrqHandler) !void {
        handler.pin = self;

        self.lock.lock();
        defer self.lock.unlock();

        if (self.kind == .none)
            self.configure(self);

        try self.handlers.append(handler);
    }

    pub fn init(self: *IrqPin, name: []const u8, context: ?*anyopaque) void {
        self.name = name;
        self.context = context orelse undefined;
        self.handlers = std.ArrayList(*IrqHandler).init(allocator());
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

pub fn getIrql() u16 {
    switch (cpu_arch) {
        .x86_64 => {
            return @truncate(u16, asm volatile ("mov %%cr8, %[level]"
                : [level] "=r" (-> u64),
            ));
        },
        else => @compileError("unsupported arch " ++ @tagName(cpu_arch) ++ "!"),
    }
}

pub fn setIrql(level: u16) void {
    switch (cpu_arch) {
        .x86_64 => {
            return asm volatile ("mov %[level], %%cr8"
                :
                : [level] "r" (@intCast(u64, level)),
            );
        },
        else => @compileError("unsupported arch " ++ @tagName(cpu_arch) ++ "!"),
    }
}

pub fn raiseIrql(irql: u16) u16 {
    const old = getIrql();
    std.debug.assert(old <= irql);

    if (old < irql)
        setIrql(irql);

    return old;
}

pub fn lowerIrql(irql: u16) u16 {
    const old = getIrql();
    std.debug.assert(old >= irql);

    if (old > irql)
        setIrql(irql);

    // TODO: dispatch pending DPCs
    return old;
}

pub fn flushDpcQueue(arg: ?*anyopaque) void {
    const irql = lowerIrql(DPC_LEVEL);
    var core_info = smp.getCoreInfo();
    _ = arg;

    while (@atomicLoad(u32, &core_info.dpc_count, .Monotonic) != 0) {
        core_info.dpc_lock.lock();

        while (true) {
            const dpc_ptr = core_info.dpc_queue.popFirst();
            if (dpc_ptr == null)
                break;

            var dpc = @fieldParentPtr(Dpc, "node", dpc_ptr.?);
            dpc.func(dpc.arg);
            dpc.lock = null;

            _ = @atomicRmw(u32, &core_info.dpc_count, .Sub, 1, .Monotonic);
        }

        core_info.dpc_lock.unlock();
    }

    _ = raiseIrql(irql);
}

pub fn queueDpc(dpc: *Dpc) bool {
    var core_info: *smp.CoreInfo = undefined;

    if (dpc.cpu) |c| {
        const cpu = smp.findCpu(c) orelse return false;
        core_info = cpu.data;
    } else {
        core_info = smp.getCoreInfo();
    }

    core_info.dpc_lock.lock();

    if (dpc.lock == null) {
        dpc.lock = &core_info.dpc_lock;
        core_info.dpc_count += 1;
        core_info.dpc_queue.append(&dpc.node);
        core_info.dpc_lock.unlock();

        if (!dpc.lazy or core_info.dpc_count >= DPC_QUEUE_THRESH) {
            if (core_info == smp.getCoreInfo()) {
                flushDpcQueue(null);
            } else {
                smp.broadcast(flushDpcQueue, null, dpc.cpu.?);
            }
        }

        return true;
    }

    return false;
}
