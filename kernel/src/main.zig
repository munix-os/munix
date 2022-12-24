const std = @import("std");
const limine = @import("limine");
const logger = std.log.scoped(.main);

// modules
pub const arch = @import("x86_64/arch.zig");
pub const pmm = @import("pmm.zig");
pub const vmm = @import("vmm.zig");

pub export var terminal_request: limine.TerminalRequest = .{};
var bytes: [16 * 4096]u8 = undefined;
var limine_terminal_cr3: u64 = 0;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buffer = std.io.fixedBufferStream(&bytes);
    var writer = buffer.writer();

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

    writer.print(fmt ++ "\n", args) catch unreachable;

    var old_pagetable: u64 = arch.paging.saveSpace();
    defer arch.paging.loadSpace(old_pagetable);
    arch.paging.loadSpace(limine_terminal_cr3);

    if (terminal_request.response) |resp| {
        resp.write(null, buffer.getWritten());
    }
}

export fn entry() callconv(.C) noreturn {
    limine_terminal_cr3 = arch.paging.saveSpace();
    logger.info("hello from munix!", .{});

    arch.setupCpu();
    pmm.init();
    vmm.init();
    logger.warn("init complete, end of kernel reached!", .{});

    while (true) {
        asm volatile ("hlt");
    }
}
