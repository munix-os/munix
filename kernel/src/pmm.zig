const std = @import("std");
const limine = @import("limine");
const smp = @import("root").smp;
const vmm = @import("root").vmm;
const sink = std.log.scoped(.pmm);
const PAGE_SIZE = std.mem.page_size;

pub const Bitmap = struct {
    bits: [*]u8,
    size: usize,
    last_free: usize = 0,

    fn check(self: *Bitmap, bit: usize) bool {
        return self.bits[bit / 8] & @as(u8, 1) << @intCast(u3, bit % 8) != 0;
    }

    pub fn mark(self: *Bitmap, bit: usize) void {
        self.bits[bit / 8] |= @as(u8, 1) << @intCast(u3, bit % 8);
    }

    fn markRange(self: *Bitmap, start: usize, length: usize) void {
        var i: usize = start;

        while (i < (start + length)) : (i += 1) {
            self.mark(i);
        }
    }

    fn clear(self: *Bitmap, bit: usize) void {
        self.bits[bit / 8] &= ~(@as(u8, 1) << @intCast(u3, bit % 8));
    }

    fn clearRange(self: *Bitmap, start: usize, length: usize) void {
        var i: usize = start;

        while (i < (start + length)) : (i += 1) {
            self.clear(i);
        }
    }

    pub fn findFreeRange(self: *Bitmap, count: usize, step_size: usize) ?u64 {
        var i: usize = std.mem.alignBackward(self.last_free, step_size);

        while (i < self.size * 8) : (i += step_size) {
            if (!self.check(i)) {
                var found = find_pages: {
                    var j: usize = 1;
                    while (j < count) : (j += 1) {
                        if (self.check(i + j)) {
                            break :find_pages false;
                        }
                    }
                    break :find_pages true;
                };

                if (found) {
                    self.last_free = i + count;
                    return i;
                }
            }
        }

        if (self.last_free != 0) {
            self.last_free = 0;
            return self.findFreeRange(count, step_size);
        } else {
            return null;
        }
    }
};

pub const PageAllocator = struct {
    base: u64 = 0xFFFF_EA00_0000_0000,

    pub fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ptr_align;
        _ = ret_addr;

        const pages = std.mem.alignForward(len, PAGE_SIZE);
        const self = @ptrCast(*PageAllocator, @alignCast(8, ctx));
        const old_base = self.base;

        var i: usize = 0;
        var map_flags = vmm.MapFlags{ .write = true };

        while (i < pages) : (i += 1) {
            const page = allocPages(1) orelse return null;

            vmm.kernel_pagemap.mapPage(
                map_flags,
                old_base + i * PAGE_SIZE,
                page,
                false,
            );
        }

        self.base += pages * PAGE_SIZE;

        return @ptrCast([*]u8, @intToPtr(*u8, old_base));
    }

    pub fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;

        return false;
    }

    pub fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
    }
};

pub export var memmap_request: limine.MemoryMapRequest = .{};
pub var page_allocator = PageAllocator{};
var global_bitmap: Bitmap = undefined;
var pmm_lock = smp.SpinLock{};

fn getKindName(kind: anytype) []const u8 {
    return switch (kind) {
        .usable => "usable",
        .reserved => "reserved",
        .acpi_reclaimable => "reclaimable (acpi)",
        .acpi_nvs => "acpi nvs",
        .bad_memory => "bad memory",
        .bootloader_reclaimable => "reclaimable (bootloader)",
        .kernel_and_modules => "kernel and modules",
        .framebuffer => "framebuffer",
    };
}

pub fn init() !void {
    var highest_addr: u64 = 0;
    var resp = memmap_request.response orelse return error.MissingBootInfo;

    sink.info("dumping memory map entries...", .{});

    // find highest addr (and dump memory map)
    for (resp.entries()) |ent| {
        sink.info(
            "\tBase: {X:0>16}, Length: {X:0>8}, Type: {s}",
            .{ ent.base, ent.length, getKindName(ent.kind) },
        );
        highest_addr = std.math.max(highest_addr, ent.base + ent.length);
    }

    // find the size of the bitmap
    var n_bits = highest_addr / PAGE_SIZE;
    var n_bytes = std.mem.alignForward((n_bits / 8), PAGE_SIZE);

    // find a entry that can hold the bitmap
    for (resp.entries()) |ent| {
        if (ent.length > n_bytes and ent.kind == .usable) {
            ent.base += n_bytes;
            ent.length -= n_bytes;

            global_bitmap.bits = @intToPtr([*]u8, vmm.toHigherHalf(ent.base));
            global_bitmap.size = n_bytes;
        }
    }

    // clear the bitmap to all 0xFFs (reserved)
    @memset(global_bitmap.bits, 0xFF, n_bytes);

    // mark usable ranges in the global_bitmap
    for (resp.entries()) |ent| {
        if (ent.kind == .usable) {
            global_bitmap.clearRange(ent.base / PAGE_SIZE, ent.length / PAGE_SIZE);
        }
    }

    // finally, mark the bitmap itself as used
    global_bitmap.markRange(vmm.fromHigherHalf(@ptrToInt(global_bitmap.bits)) / PAGE_SIZE, n_bytes / PAGE_SIZE);
}

pub fn allocPages(count: usize) ?u64 {
    pmm_lock.acq();
    defer pmm_lock.rel();

    return result: {
        if (global_bitmap.findFreeRange(count, 1)) |free_bit| {
            @memset(@intToPtr([*]u8, vmm.toHigherHalf(free_bit * PAGE_SIZE)), 0, 0x1000 * count);
            break :result free_bit * PAGE_SIZE;
        } else {
            break :result null;
        }
    };
}

pub fn allocHugePages(count: usize) ?u64 {
    pmm_lock.acq();
    defer pmm_lock.rel();

    return result: {
        if (global_bitmap.findFreeRange(count * 0x200, 0x200)) |free_bit| {
            @memset(@intToPtr([*]u8, vmm.toHigherHalf(free_bit * PAGE_SIZE)), 0, 0x200000 * count);
            break :result free_bit * PAGE_SIZE;
        } else {
            break :result null;
        }
    };
}

pub fn freePages(ptr: usize, count: usize) void {
    pmm_lock.acq();
    defer pmm_lock.rel();

    global_bitmap.clearRange(ptr / PAGE_SIZE, count);
}
