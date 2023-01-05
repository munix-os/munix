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
    var ctx = @ptrCast(*align(1) TmpfsContext, node.context);
    var len = length;

    if ((offset + length) > (ctx.n_pages * pmm.PAGE_SIZE)) {
        if (offset > (ctx.n_pages * pmm.PAGE_SIZE)) {
            return error.InvalidParams;
        } else {
            len = (ctx.n_pages * pmm.PAGE_SIZE) - offset;
        }
    }

    var data = @intToPtr([*]const u8, vmm.toHigherHalf(ctx.base + offset));
    std.mem.copy(u8, buffer[0..len], data[0..len]);
    return len;
}

fn tmpfs_write(node: *vfs.VfsNode, buffer: [*]const u8, offset: u64, length: usize) vfs.VfsError!usize {
    var ctx = @ptrCast(*align(1) TmpfsContext, node.context);

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
    node.stat.st_size += @intCast(i64, length);
    return length;
}

fn tmpfs_close(node: *vfs.VfsNode) void {
    // TODO: implement close for tmpfs (if needed?)
    _ = node;
}

fn tmpfs_create(name: []const u8, mode: i32) vfs.VfsError!*vfs.VfsNode {
    const allocator = @import("root").allocator;
    var context = try allocator.create(TmpfsContext);
    errdefer allocator.destroy(context);

    var result = try vfs.createNode(name, (mode & ~@as(i32, StatFlags.S_IFMT)) | StatFlags.S_IFREG);

    result.vtable = &vtable;
    result.fs = &fs_vtable;
    result.stat.st_blksize = 512;
    result.stat.st_mode = (mode & ~@as(i32, StatFlags.S_IFMT)) | StatFlags.S_IFREG;
    result.stat.st_nlink = 1;

    context.base = pmm.allocPages(1) orelse return error.OutOfMemory;
    context.n_pages = 1;
    result.context = context;
    return result;
}

fn tmpfs_mount(parent_mount: *vfs.VfsNode, source: ?*vfs.VfsNode) vfs.VfsError!void {
    _ = source; // tmpfs doesn't depend on devices

    var node = try vfs.createNode(parent_mount.name, types.StatFlags.S_IFDIR);
    node.vtable = &vtable;
    node.fs = &fs_vtable;
    parent_mount.mountpoint = node;
}

fn tmpfs_mkdir(parent_dir: *vfs.VfsNode, basename: []const u8) vfs.VfsError!*vfs.VfsNode {
    _ = parent_dir;
    var dir = try vfs.createNode(basename, types.StatFlags.S_IFDIR);

    dir.vtable = &vtable;
    dir.fs = &fs_vtable;
    return dir;
}

const vtable: vfs.VTable = .{
    .read = &tmpfs_read,
    .write = &tmpfs_write,
    .close = &tmpfs_close,
};

pub const fs_vtable: vfs.FsVTable = .{
    .name = "tmpfs",
    .mount = &tmpfs_mount,
    .mkdir = &tmpfs_mkdir,
    .create = &tmpfs_create,
};
