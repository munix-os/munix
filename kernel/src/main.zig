const std = @import("std");
const limine = @import("limine");
const logger = std.log.scoped(.main);

// imports
pub const arch = @import("x86_64/arch.zig");
const sync = @import("util/sync.zig");
const dev = @import("dev/dev.zig");
const smp = @import("smp.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const vfs = @import("vfs.zig");

var g_alloc = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true, .MutexType = sync.SpinMutex }){};
pub export var terminal_request: limine.TerminalRequest = .{};

pub inline fn allocator() std.mem.Allocator {
    return g_alloc.allocator();
}

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

var log_buffer: [16 * 4096]u8 = undefined;
var limine_terminal_cr3: u64 = 0;
var log_lock = sync.SpinMutex{};

pub const std_options = struct {
    pub const log_level = .info;
    pub const logFn = log;
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime fmt: []const u8,
    args: anytype,
) void {
    log_lock.lock();
    defer log_lock.unlock();

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

export fn entry() callconv(.C) noreturn {
    limine_terminal_cr3 = arch.paging.saveSpace();
    dev.irq.setIrql(dev.irq.DPC_LEVEL);

    logger.info("hello from munix!", .{});

    kernel_main() catch |e| {
        logger.err("init failed with error: {any}", .{e});
    };

    logger.warn("init complete, end of kernel reached!", .{});
    while (true) {
        asm volatile ("hlt");
    }
}

fn kernel_main() !void {
    arch.init();
    try pmm.init();
    try vmm.init();
    try dev.init();
    try smp.init();
}
