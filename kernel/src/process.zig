const sched = @import("root").sched;
const paging = @import("root").arch.paging;
const vmm = @import("root").vmm;
const pmm = @import("root").pmm;
const vfs = @import("root").vfs;
const std = @import("std");

const allocator = @import("root").allocator;
const sink = std.log.scoped(.proc);
const MAX_PID_COUNT = 8192;

pub const Process = struct {
    parent: ?*Process,
    pid: u32 = 0,
    pagemap: *paging.PageMap,
    cwd: *vfs.VfsNode,
    threads: std.ArrayList(*sched.Thread),
    children: std.ArrayList(*Process),
    tid_counter: u32 = 0,
};

pub var kernel_process: Process = undefined;
var process_table: std.AutoHashMap(u32, *Process) = undefined;
var pid_bitmap: pmm.Bitmap = undefined;

const ElfImage = struct {
    dyld_path: ?[]u8 = null,
    phdr: u64 = 0,
    entry: u64 = 0,
    phnum: usize = 0,
};

fn loadImage(proc: *Process, image_path: []const u8, base: u64) !ElfImage {
    var image = try vfs.resolve(proc.cwd, image_path);
    var image_file = vfs.VStream.init(image);

    var elf_header = try std.elf.Header.read(&image_file);
    var phdrs = elf_header.program_header_iterator(&image_file);
    var result: ElfImage = .{};

    while (try phdrs.next()) |p| {
        switch (p.p_type) {
            std.elf.PT_INTERP => {
                var linker_path = try allocator().alloc(u8, p.p_filesz);
                const termed_str = @ptrCast([*:0]u8, linker_path);
                _ = try image.vtable.read(image, @ptrCast([*]u8, linker_path), p.p_offset, p.p_filesz);

                result.dyld_path = termed_str[0..std.mem.len(termed_str)];
            },
            std.elf.PT_PHDR => result.phdr = p.p_vaddr + base,
            std.elf.PT_LOAD => {
                var misalign = p.p_vaddr & (std.mem.page_size - 1);
                var map_flags: vmm.MapFlags = .{ .read = true, .user = true };

                if (p.p_flags & std.elf.PF_W != 0)
                    map_flags.write = true;

                if (p.p_flags & std.elf.PF_X != 0)
                    map_flags.exec = true;

                const n_pages = std.mem.alignForward(p.p_memsz + misalign, std.mem.page_size) / std.mem.page_size;
                const pbase = pmm.allocPages(n_pages) orelse return error.OutOfMemory;
                const vbase = std.mem.alignBackward(p.p_vaddr, std.mem.page_size) + base;

                var i: u64 = 0;
                while (i < n_pages) : (i += 1) {
                    proc.pagemap.mapPage(
                        map_flags,
                        vbase + (i * std.mem.page_size),
                        pbase + (i * std.mem.page_size),
                        false,
                    );
                }

                const mem = @intToPtr([*]u8, vmm.toHigherHalf(pbase + misalign));
                _ = try image.vtable.read(image, mem, p.p_offset, p.p_filesz);
            },
            else => continue,
        }
    }

    result.entry = elf_header.entry + base;
    result.phnum = elf_header.phnum;
    return result;
}

pub fn createProcess(parent: ?*Process, exe_path: []const u8, starting_dir: *vfs.VfsNode) !*Process {
    var process = try allocator().create(Process);
    var pagemap = try vmm.createPagemap();

    errdefer allocator().destroy(process);
    errdefer allocator().destroy(pagemap);

    process.* = .{
        .parent = parent,
        .pagemap = pagemap,
        .cwd = starting_dir,
        .threads = std.ArrayList(*sched.Thread).init(allocator()),
        .children = std.ArrayList(*Process).init(allocator()),
    };

    if (pid_bitmap.findFreeRange(1, 1)) |pid| {
        process.pid = @truncate(u32, pid);
        try process_table.put(@truncate(u32, pid), process);
        if (parent) |p| {
            try p.children.append(process);
        }
    } else {
        return error.OutOfPIDs;
    }

    var file = try loadImage(process, exe_path, 0);
    if (file.dyld_path != null) {
        var ld_file = try loadImage(process, file.dyld_path.?, 0x4000_0000);
        _ = ld_file;
    }

    return process;
}

pub fn init() void {
    process_table = std.AutoHashMap(u32, *Process).init(allocator());
    kernel_process = .{
        .parent = null,
        .pagemap = &vmm.kernel_pagemap,
        .cwd = &vfs.root,
        .threads = std.ArrayList(*sched.Thread).init(allocator()),
        .children = std.ArrayList(*Process).init(allocator()),
    };

    var pid_bitmap_mem = allocator().alloc(u8, MAX_PID_COUNT / 8) catch unreachable;
    pid_bitmap = .{
        .bits = @ptrCast([*]u8, pid_bitmap_mem),
        .size = MAX_PID_COUNT,
    };

    pid_bitmap.mark(0);
}
