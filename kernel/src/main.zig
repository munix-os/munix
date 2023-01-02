const std = @import("std");
const limine = @import("limine");
const logger = std.log.scoped(.main);

// modules
pub const arch = @import("x86_64/arch.zig");
pub const acpi = @import("acpi.zig");
pub const pmm = @import("pmm.zig");
pub const vmm = @import("vmm.zig");
pub const smp = @import("smp.zig");
pub const sched = @import("sched.zig");

pub export var terminal_request: limine.TerminalRequest = .{};
var log_buffer: [16 * 4096]u8 = undefined;
var log_lock = smp.SpinLock{};
var limine_terminal_cr3: u64 = 0;

pub var g_alloc = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true, .MutexType = smp.SpinLock }){};
pub var allocator = g_alloc.allocator();

pub const os = .{
    .heap = .{
        .page_allocator = std.mem.Allocator{
            .ptr = &pmm.page_allocator,
            .vtable = &std.mem.Allocator.VTable{
                .alloc = pmm.PageAllocator.alloc,
                .resize = pmm.PageAllocator.resize,
                .free = pmm.PageAllocator.free,
            },
        },
    },
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log_lock.acq();
    defer log_lock.rel();

    var buffer = std.io.fixedBufferStream(&log_buffer);
    var writer = buffer.writer();

    if (scope != .default) {
        switch (level) {
            .warn => {
                writer.print("{s}: (\x1b[33mwarn\x1b[0m) ", .{@tagName(scope)}) catch unreachable;
            },
            .err => {
                writer.print("{s}: (\x1b[31merr\x1b[0m) ", .{@tagName(scope)}) catch unreachable;
            },
            else => {
                writer.print("{s}: ", .{@tagName(scope)}) catch unreachable;
            },
        }
    }

    writer.print(fmt ++ "\n", args) catch unreachable;

    var old_pagetable: u64 = arch.paging.saveSpace();
    defer arch.paging.loadSpace(old_pagetable);
    arch.paging.loadSpace(limine_terminal_cr3);

    if (terminal_request.response) |resp| {
        resp.write(null, buffer.getWritten());
    }
}

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, return_addr: ?usize) noreturn {
    _ = stack_trace;
    _ = return_addr;

    std.log.err("\n<-------------- \x1b[31mKERNEL PANIC\x1b[0m -------------->", .{});
    std.log.err("The munix kernel panicked with the following message...", .{});
    std.log.err("    \"{s}\"", .{message});
    std.log.err("Stacktrace: ", .{});

    var stack_iter = std.debug.StackIterator.init(@returnAddress(), @frameAddress());
    while (stack_iter.next()) |addr| {
        std.log.err("    > 0x{X:0>16} (??:0)", .{addr});
    }

    while (true) {
        asm volatile ("hlt");
    }
}

fn handleTimer(frame: *arch.trap.TrapFrame) callconv(.C) void {
    _ = frame;
    logger.info("ping!", .{});
    arch.ic.submitEoi(0x30);
    arch.ic.oneshot(0x30, 1000);
}

export fn entry() callconv(.C) noreturn {
    limine_terminal_cr3 = arch.paging.saveSpace();
    logger.info("hello from munix!", .{});

    // setup the essentials
    arch.setupCpu();
    pmm.init();
    vmm.init();
    acpi.init();

    // boot all other cores, before entering the scheduler with them
    arch.trap.setHandler(sched.reschedule, 0x30);
    smp.init();
    logger.err("init complete, end of kernel reached!", .{});
    sched.enter();

    while (true) {}
}
