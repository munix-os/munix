const std = @import("std");
const limine = @import("limine");
const sink = std.log.scoped(.acpi);

const vmm = @import("../vmm.zig");
const clock = @import("clock.zig");
const allocator = @import("root").allocator;

pub const GenericAddress = extern struct {
    base_type: u8 align(1),
    bit_width: u8 align(1),
    bit_offset: u8 align(1),
    access_size: u8 align(1),
    base: u64 align(1),

    fn read(self: GenericAddress, comptime T: type) T {
        if (self.base_type == 0) { // MMIO
            return @intToPtr(*align(1) volatile T, self.base).*;
        } else {
            return switch (T) {
                u8 => asm volatile ("inb %[port], %[result]"
                    : [result] "={al}" (-> T),
                    : [port] "N{dx}" (@truncate(u16, self.base)),
                ),
                u16 => asm volatile ("inw %[port], %[result]"
                    : [result] "={ax}" (-> T),
                    : [port] "N{dx}" (@truncate(u16, self.base)),
                ),
                u32 => asm volatile ("inl %[port], %[result]"
                    : [result] "={eax}" (-> T),
                    : [port] "N{dx}" (@truncate(u16, self.base)),
                ),
                else => @compileError("unsupported type for PIO read ->" ++ @typeName(T)),
            };
        }
    }
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

    pub fn getContents(self: *Header) []const u8 {
        return @ptrCast([*]const u8, self)[0..self.length][@sizeOf(Header)..];
    }
};

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

pub const FADT = extern struct {
    firmware_control: u32 align(1),
    dsdt: u32 align(1),
    reserved: u8 align(1),
    profile: u8 align(1),
    sci_irq: u16 align(1),
    smi_command_port: u32 align(1),
    acpi_enable: u8 align(1),
    acpi_disable: u8 align(1),
    s4bios_req: u8 align(1),
    pstate_control: u8 align(1),
    pm1a_event_blk: u32 align(1),
    pm1b_event_blk: u32 align(1),
    pm1a_control_blk: u32 align(1),
    pm1b_control_blk: u32 align(1),
    pm2_control_blk: u32 align(1),
    pm_timer_blk: u32 align(1),
    gpe0_blk: u32 align(1),
    gpe1_blk: u32 align(1),
    pm1_event_length: u8 align(1),
    pm1_control_length: u8 align(1),
    pm2_control_length: u8 align(1),
    pm_timer_length: u8 align(1),
    gpe0_length: u8 align(1),
    gpe1_length: u8 align(1),
    gpe1_base: u8 align(1),
    cstate_control: u8 align(1),
    worst_c2_latency: u16 align(1),
    worst_c3_latency: u16 align(1),
    flush_size: u16 align(1),
    flush_stride: u16 align(1),
    duty_offset: u8 align(1),
    duty_width: u8 align(1),
    day_alarm: u8 align(1),
    month_alarm: u8 align(1),
    century: u8 align(1),
    iapc_boot_flags: u16 align(1),
    reserved2: u8 align(1),
    flags: u32 align(1),
    reset_register: GenericAddress align(1),
    reset_command: u8 align(1),
    arm_boot_flags: u16 align(1),
    minor_version: u8 align(1),
    x_firmware_control: u64 align(1),
    x_dsdt: u64 align(1),
    x_pm1a_event_blk: GenericAddress align(1),
    x_pm1b_event_blk: GenericAddress align(1),
    x_pm1a_control_blk: GenericAddress align(1),
    x_pm1b_control_blk: GenericAddress align(1),
    x_pm2_control_blk: GenericAddress align(1),
    x_pm_timer_blk: GenericAddress align(1),
    x_gpe0_blk: GenericAddress align(1),
    x_gpe1_blk: GenericAddress align(1),
};

var acpi_pm_tc: clock.TimeCounter = .{
    .name = "ACPI PM Timer",
    .quality = 600,
    .bits = 0,
    .mask = 0,
    .frequency = 3580,
    .priv = undefined,
    .getValue = &pmTimerRead,
};

pub export var rsdp_request: limine.RsdpRequest = .{};
var xsdt: ?*Header = null;
var rsdt: ?*Header = null;

fn getEntries(comptime T: type, header: *Header) []align(1) const T {
    return std.mem.bytesAsSlice(T, header.getContents());
}

fn pmTimerRead(tc: *clock.TimeCounter) u64 {
    var timer_block = @ptrCast(*align(1) GenericAddress, tc.priv);
    return @intCast(u64, timer_block.read(u32));
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

pub fn getTable(signature: []const u8) ?*Header {
    if (xsdt) |x| {
        for (getEntries(u64, x)) |ent| {
            var entry = @intToPtr(*Header, vmm.toHigherHalf(ent));
            if (std.mem.eql(u8, signature[0..4], &entry.signature)) {
                return entry;
            }
        }
    } else {
        for (getEntries(u32, rsdt.?)) |ent| {
            var entry = @intToPtr(*Header, vmm.toHigherHalf(ent));
            if (std.mem.eql(u8, signature[0..4], &entry.signature)) {
                return entry;
            }
        }
    }

    return null;
}

pub fn init() !void {
    var resp = rsdp_request.response orelse return error.MissingBootInfo;

    // TODO(cleanbaja): find a way to fragment
    // pages, so that we can map acpi tables,
    // without modifying other pages
    var xsdp = @intToPtr(*align(1) const XSDP, @ptrToInt(resp.address));

    if (xsdp.revision >= 2 and xsdp.xsdt != 0) {
        xsdt = @intToPtr(*Header, vmm.toHigherHalf(xsdp.xsdt));
    } else {
        rsdt = @intToPtr(*Header, vmm.toHigherHalf(@intCast(usize, xsdp.rsdt)));
    }

    if (xsdt) |x| {
        var num_tables = (x.length - @sizeOf(Header)) / 8;
        sink.info("dumping {} tables...", .{num_tables});

        for (getEntries(u64, x)) |ent| {
            var entry = @intToPtr(*Header, vmm.toHigherHalf(ent));
            printTable(entry);
        }
    } else {
        var num_tables = (rsdt.?.length - @sizeOf(Header)) / 4;
        sink.info("dumping {} tables...", .{num_tables});

        for (getEntries(u32, rsdt.?)) |ent| {
            var entry = @intToPtr(*Header, vmm.toHigherHalf(ent));
            printTable(entry);
        }
    }

    // setup the ACPI timer
    if (getTable("FACP")) |fadt_sdt| {
        var fadt = @ptrCast(*align(1) const FADT, fadt_sdt.getContents()[0..]);
        var timer_block = try allocator().create(GenericAddress);

        if (xsdp.revision >= 2 and fadt.x_pm_timer_blk.base_type == 0) {
            timer_block.* = fadt.x_pm_timer_blk;
            timer_block.base = vmm.toHigherHalf(timer_block.base);
        } else {
            if (fadt.pm_timer_blk == 0 or fadt.pm_timer_length != 4) {
                @panic("ACPI Timer is unsupported/malformed");
            }

            timer_block.* = GenericAddress{
                .base = fadt.pm_timer_blk,
                .base_type = 1,
                .bit_width = 32,
                .bit_offset = 0,
                .access_size = 0,
            };
        }

        if ((fadt.flags & (1 << 8)) == 0) {
            acpi_pm_tc.bits = 32;
            acpi_pm_tc.mask = ~@as(u32, 0);
        } else {
            acpi_pm_tc.bits = 24;
            acpi_pm_tc.mask = ~@as(u24, 0);
        }

        if (timer_block.base_type == 0) {
            sink.info("detected MMIO acpi timer, with {}-bit counter width", .{acpi_pm_tc.bits});
        } else {
            sink.info("detected PIO (Port IO) acpi timer, with {}-bit counter width", .{acpi_pm_tc.bits});
        }

        acpi_pm_tc.priv = timer_block;
        try clock.register(&acpi_pm_tc);
    } else {
        return error.InvalidHardware;
    }
}
