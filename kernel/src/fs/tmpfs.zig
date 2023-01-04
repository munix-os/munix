const allocator = @import("root").allocator;
const types = @import("../types.zig");
const vfs = @import("root").vfs;
const pmm = @import("root").pmm;
const vmm = @import("root").vmm;
const std = @import("std");
const StatFlags = types.StatFlags;

const TmpfsContext = struct {
    base: u64,
    n_pages: usize,
};

fn tmpfs_read(node: *vfs.VfsNode, buffer: [*]u8, offset: u64, length: usize) vfs.VfsError!usize {
    var ctx = @ptrCast(TmpfsContext, node.context);

    if ((offset + length) > (ctx.n_pages * pmm.PAGE_SIZE)) {
        if (offset > (ctx.n_pages * pmm.PAGE_SIZE)) {
            return error.InavlidParams;
        } else {
            length = (ctx.n_pages * pmm.PAGE_SIZE) - offset;
        }
    }

    var data = @intToPtr([*]const u8, vmm.toHigherHalf(ctx.base + offset));
    std.mem.copy(u8, buffer[0..length], data[0..length]);
    return length;
}

fn tmpfs_write(node: *vfs.VfsNode, buffer: [*]const u8, offset: u64, length: usize) vfs.VfsError!usize {
    var ctx = @ptrCast(TmpfsContext, node.context);

    if ((offset + length) > (ctx.n_pages * pmm.PAGE_SIZE)) {
        var old_pagecount = ctx.n_pages;

        while ((offset + length) > (ctx.n_pages * pmm.PAGE_SIZE)) {
            ctx.n_pages += 1;
        }

        var new_mem = pmm.allocPages(ctx.n_pages) orelse return error.OutOfMemory;
        std.mem.copy(
            u8,
            @intToPtr([*]u8, vmm.toHigherHalf(new_mem))[0..(old_pagecount * pmm.PAGE_SIZE)],
            @intToPtr([*]const u8, vmm.toHigherHalf(ctx.base))[0..(old_pagecount * pmm.PAGE_SIZE)],
        );

        pmm.freePages(ctx.base, old_pagecount);
        ctx.base = new_mem;
    }

    var data = @intToPtr([*]u8, vmm.toHigherHalf(ctx.base + offset));
    std.mem.copy(u8, data[0..length], buffer[0..length]);
    node.stat.st_size += length;
    return length;
}

fn tmpfs_close(node: *vfs.VfsNode) void {
    // TODO: implement close for tmpfs (if needed?)
    _ = node;
}

fn tmpfs_open(mode: i32, create: bool) vfs.VfsError!*vfs.VfsNode {
    if (!create) return error.InvalidParams;

    var result = try allocator.create(vfs.VfsNode);
    var context = try allocator.create(TmpfsContext);
    defer allocator.destroy(context);
    defer allocator.destroy(result);

    result.vtable = &vtable;
    result.stat = std.mem.zeroes(types.Stat);
    result.stat.st_blksize = 512;
    result.stat.st_mode = (mode & ~StatFlags.S_IFMT) | StatFlags.S_IFREG;
    result.stat.st_nlink = 1;

    context.base = pmm.allocPages(1) orelse return error.OutOfMemory;
    context.n_pages = 1;
    result.context = context;

    return result;
}

fn tmpfs_mount(parent_mount: *vfs.VfsNode, source: ?*vfs.VfsNode) vfs.VfsError!void {
    _ = source; // tmpfs doesn't depend on devices

    var root_node = try allocator.create(vfs.VfsNode);
    defer allocator.destroy(root_node);

    root_node.stat = std.mem.zeroes(types.Stat);
    root_node.stat.st_mode = types.StatFlags.ST_IFDIR;
    root_node.children = std.ArrayList(vfs.VfsNode).init(allocator);
    parent_mount.mountpoint = root_node;
}

const vtable: vfs.VTable = .{
    .read = &tmpfs_read,
    .write = &tmpfs_write,
    .close = &tmpfs_close,
};

pub const fs_vtable: vfs.FsVTable = .{
    .name = "tmpfs",
    .open = &tmpfs_open,
    .mount = &tmpfs_mount,
};
