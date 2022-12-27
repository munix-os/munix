const std = @import("std");
const limine = @import("limine");
const vmm = @import("root").vmm;
const sink = std.log.scoped(.acpi);

pub const XSDP = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem: [6]u8,
    revision: u8,
    rsdt: u32,
    length: u32,
    xsdt: u64,
    ext_checksum: u8,
};

pub const Header = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oem: [6]u8 align(1),
    oem_table: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),

    fn getContents(self: *Header) []const u8 {
        return @ptrCast([*]const u8, self)[0..self.length][@sizeOf(Header)..];
    }
};

pub export var rsdp_request: limine.RsdpRequest = .{};
var xsdt: ?*Header = null;
var rsdt: ?*Header = null;

fn getEntries(comptime T: type, header: *Header) []align(1) const T {
    return std.mem.bytesAsSlice(T, header.getContents());
}

fn printTable(sdt: *Header) void {
    // real hw systems are packed with SSDT tables (upwards of 14)
    // beacuse of this, skip printing SSDTs so the kernel logs
    // aren't cluttered
    if (std.mem.eql(u8, "SSDT", &sdt.signature)) {
        return;
    }

    // zig fmt: off
    sink.info("\t* [{s}]: 0x{X:0>16}, Length: {d:0>3}, Revision: {}", .{
        sdt.signature, @ptrToInt(sdt), sdt.length, sdt.revision
    });
    // zig fmt: on
}

fn mapTable(base: u64, length: usize) void {
    var aligned_base: u64 = std.mem.alignBackward(base, 0x200000);
    var aligned_length: usize = std.mem.alignForward(length, 0x200000);
    var table_flags = vmm.MapFlags{ .read = true, .cache_type = .uncached };

    var i: usize = 0;
    while (i < aligned_length) : (i += 0x200000) {
        vmm.kernel_pagemap.unmapPage(aligned_base + i);
        vmm.kernel_pagemap.mapPage(table_flags, aligned_base + i, vmm.fromHigherHalf(aligned_base + i), true);
    }
}

pub fn getTable(signature: []const u8) ?*Header {
    if (xsdt) |x| {
        for (getEntries(u64, x)) |ent| {
            var entry = @intToPtr(*Header, vmm.toHigherHalf(ent));
            if (std.mem.eql(u8, signature[0..4], entry.signature)) {
                return entry;
            }
        }
    } else {
        for (getEntries(u32, rsdt.?)) |ent| {
            var entry = @intToPtr(*Header, vmm.toHigherHalf(ent));
            if (std.mem.eql(u8, signature[0..4], entry.signature)) {
                return entry;
            }
        }
    }

    return null;
}

pub fn init() void {
    if (rsdp_request.response) |resp| {
        var xsdp = @intToPtr(*align(1) const XSDP, @ptrToInt(resp.address));
        mapTable(@ptrToInt(xsdp), xsdp.length);

        if (xsdp.revision >= 2 and xsdp.xsdt != 0) {
            xsdt = @intToPtr(*Header, vmm.toHigherHalf(xsdp.xsdt));
            mapTable(vmm.toHigherHalf(xsdp.xsdt), xsdt.?.length);
        } else {
            rsdt = @intToPtr(*Header, vmm.toHigherHalf(@intCast(usize, xsdp.rsdt)));
            mapTable(vmm.toHigherHalf(xsdp.rsdt), rsdt.?.length);
        }

        if (xsdt) |x| {
            var num_tables = (x.length - @sizeOf(Header)) / 8;
            sink.info("dumping {} tables...", .{num_tables});

            for (getEntries(u64, x)) |ent| {
                var entry = @intToPtr(*Header, vmm.toHigherHalf(ent));
                mapTable(@ptrToInt(entry), entry.length);
                printTable(entry);
            }
        } else {
            var num_tables = (rsdt.?.length - @sizeOf(Header)) / 4;
            sink.info("dumping {} tables...", .{num_tables});

            for (getEntries(u32, rsdt.?)) |ent| {
                var entry = @intToPtr(*Header, vmm.toHigherHalf(ent));
                mapTable(@ptrToInt(entry), entry.length);
                printTable(entry);
            }
        }
    }
}
