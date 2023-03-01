const limine = @import("limine");
const paging = @import("root").arch.paging;
const allocator = @import("root").allocator;
const pmm = @import("root").pmm;
const std = @import("std");

pub const CacheMode = enum(u4) { uncached, write_combining, write_protect, write_back };

pub const MapFlags = packed struct {
    read: bool = false,
    write: bool = false,
    exec: bool = false,
    user: bool = false,

    cache_type: CacheMode = .write_back,
    _padding: u24 = 0,
};

pub export var kaddr_request: limine.KernelAddressRequest = .{};
pub const DEFAULT_HIGHER_HALF: u64 = 0xFFFF800000000000;
pub var kernel_pagemap = paging.PageMap{};

pub fn toHigherHalf(ptr: usize) usize {
    return ptr + DEFAULT_HIGHER_HALF;
}

pub fn fromHigherHalf(ptr: usize) usize {
    return ptr - DEFAULT_HIGHER_HALF;
}

pub fn createPagemap() !*paging.PageMap {
    var result = try allocator().create(paging.PageMap);
    result.* = .{ .root = pmm.allocPages(1) orelse return error.OutOfMemory };

    // copy over the higher half
    var higher_half = @intToPtr([*]u64, toHigherHalf(result.root + (256 * @sizeOf(u64))));
    var kernel_half = @intToPtr([*]u64, toHigherHalf(kernel_pagemap.root + (256 * @sizeOf(u64))));
    var i: u64 = 256;

    while (i < 512) : (i += 1) {
        higher_half[i] = kernel_half[i];
    }

    return result;
}

fn mapKernelSection(
    comptime name: []const u8,
    kaddr_response: *limine.KernelAddressResponse,
    map_flags: MapFlags,
) void {
    const begin = @extern(*u8, .{ .name = name ++ "_begin" });
    const end = @extern(*u8, .{ .name = name ++ "_end" });

    const begin_aligned = std.mem.alignBackward(@ptrToInt(begin), 0x1000);
    const end_aligned = std.mem.alignForward(@ptrToInt(end), 0x1000);
    const physical = begin_aligned - kaddr_response.virtual_base + kaddr_response.physical_base;
    const size = std.mem.alignForward(end_aligned - begin_aligned, 0x1000);

    for (0..size / 0x1000) |i| {
        kernel_pagemap.mapPage(map_flags, begin_aligned + i * 0x1000, physical + i * 0x1000, false);
    }
}

pub fn init() !void {
    kernel_pagemap.root = pmm.allocPages(1) orelse return error.OutOfMemory;

    // map some simple stuff
    var resp = kaddr_request.response orelse return error.MissingBootInfo;

    mapKernelSection("text", resp, .{ .read = true, .write = false, .exec = true });
    mapKernelSection("data", resp, .{ .read = true, .write = true, .exec = false });
    mapKernelSection("rodata", resp, .{ .read = true, .write = false, .exec = false });

    for (0..0x800) |i| {
        kernel_pagemap.mapPage(.{ .read = true, .write = true, .exec = false }, toHigherHalf(i * 0x200000), i * 0x200000, true);
    }

    // them map everything else
    for (pmm.memmap_request.response.?.entries()) |ent| {
        if (ent.base + ent.length < @intCast(usize, (0x800 * 0x200000))) {
            continue;
        }

        const base = std.mem.alignBackward(ent.base, 0x200000);
        const pages = std.mem.alignForward(ent.length, 0x200000) / 0x200000;

        for (0..pages) |i| {
            kernel_pagemap.mapPage(.{ .read = true, .write = true, .exec = false }, toHigherHalf(base + i * 0x200000), base + i * 0x200000, true);
        }
    }

    kernel_pagemap.load();
}
