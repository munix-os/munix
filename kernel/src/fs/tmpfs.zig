const std = @import("std");

const vfs = @import("../vfs.zig");
const pmm = @import("../pmm.zig");
const vmm = @import("../vmm.zig");
const types = @import("../util/libc.zig");
const allocator = @import("root").allocator;

// export so we can use for initramfs
pub const TmpfsContext = struct {
    device: u64 = 0,
    inode_counter: u64 = 0,
};

// same goes here
pub const TmpfsInode = struct {
    base: []u8,
    bytes: usize,
};

fn tmpfs_read(node: *vfs.VfsNode, buffer: [*]u8, offset: u64, length: usize) vfs.VfsError!usize {
    var inode = @ptrCast(*align(1) TmpfsInode, node.inode);
    var len = length;

    node.lock.lock();
    defer node.lock.unlock();

    if ((offset + length) > inode.bytes) {
        if (offset > inode.bytes) {
            return error.InvalidParams;
        } else {
            len = inode.bytes - offset;
        }
    }

    std.mem.copy(u8, buffer[0..len], inode.base[offset .. offset + len]);
    return len;
}

fn tmpfs_write(node: *vfs.VfsNode, buffer: [*]const u8, offset: u64, length: usize) vfs.VfsError!usize {
    var inode = @ptrCast(*align(1) TmpfsInode, node.inode);

    node.lock.lock();
    defer node.lock.unlock();

    if ((offset + length) > inode.bytes) {
        while ((offset + length) > inode.bytes) : (inode.bytes *= 2) {}

        node.stat.st_size = @intCast(i64, offset + length);
        inode.base = try allocator().realloc(inode.base, inode.bytes);
    }

    std.mem.copy(u8, inode.base[offset .. offset + length], buffer[0..length]);
    node.stat.st_size += @intCast(i64, length);
    return length;
}

fn tmpfs_close(node: *vfs.VfsNode) void {
    _ = node;
}

fn tmpfs_create(parent: *vfs.VfsNode, name: []const u8, stat: types.Stat) vfs.VfsError!*vfs.VfsNode {
    var context = @ptrCast(*align(1) TmpfsContext, parent.fs.context);
    var st = stat;

    var inode = try allocator().create(TmpfsInode);
    inode.bytes = 0;
    errdefer allocator().destroy(inode);

    context.inode_counter += 1;
    st.st_dev = context.device;
    st.st_ino = context.inode_counter;
    st.st_blksize = 4096;
    st.st_nlink = 1;

    var result = try vfs.createNode(parent, name, st, parent.fs, parent.vtable, true);
    result.inode = inode;
    return result;
}

pub const vtable: vfs.VTable = .{
    .read = &tmpfs_read,
    .write = &tmpfs_write,
    .close = &tmpfs_close,
};

pub const fs_vtable: vfs.FsVTable = .{
    .create = &tmpfs_create,
};
