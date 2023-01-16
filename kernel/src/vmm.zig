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

pub fn init() void {
    kernel_pagemap.root = pmm.allocPages(1).?;
    var map_flags: MapFlags = .{ .read = true, .write = true, .exec = true };

    // map some simple stuff
    if (kaddr_request.response) |r| {
        var pbase: usize = r.physical_base;
        var vbase: usize = r.virtual_base;
        var i: usize = 0;

        while (i < (0x400 * 0x1000)) : (i += 0x1000) {
            kernel_pagemap.mapPage(map_flags, vbase + i, pbase + i, false);
        }

        i = 0;
        map_flags.exec = false;
        while (i < @intCast(usize, (0x800 * 0x200000))) : (i += 0x200000) {
            kernel_pagemap.mapPage(map_flags, toHigherHalf(i), i, true);
        }
    }

    // them map everything else
    for (pmm.memmap_request.response.?.entries()) |ent| {
        if (ent.base + ent.length < @intCast(usize, (0x800 * 0x200000))) {
            continue;
        }

        var base: usize = std.mem.alignBackward(ent.base, 0x200000);
        var i: usize = 0;

        while (i < std.mem.alignForward(ent.length, 0x200000)) : (i += 0x200000) {
            kernel_pagemap.mapPage(map_flags, toHigherHalf(base + i), base + i, true);
        }
    }

    pmm.mapGlobalBitmap();
    kernel_pagemap.load();
}
