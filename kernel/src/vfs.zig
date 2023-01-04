const std = @import("std");
const zeroes = std.mem.zeroes;

// modules
const tmpfs = @import("fs/tmpfs.zig");
const types = @import("types.zig");

pub const VfsError = error{
    OutOfMemory,
    InvalidParams,
};

pub const VTable = struct {
    read: *const fn (node: *VfsNode, buffer: [*]u8, offset: u64, length: usize) VfsError!usize,
    write: *const fn (node: *VfsNode, buffer: [*]const u8, offset: u64, length: usize) VfsError!usize,
    close: *const fn (node: *VfsNode) void,
};

pub const FsVTable = struct {
    name: []const u8,
    open: *const fn (mode: i32, create: bool) VfsError!*VfsNode,
    mount: *const fn (parent_mount: *VfsNode, source: ?*VfsNode) VfsError!void,
};

pub const VfsNode = struct {
    name: [196]u8,
    stat: types.Stat,
    mountpoint: ?*VfsNode,
    children: std.ArrayList(*VfsNode),
    context: *anyopaque,

    vtable: *const VTable,
    fs: *const FsVTable,
};

var root: VfsNode = undefined;
const fs_list = [_]*const FsVTable{
    &tmpfs.fs_vtable,
};

fn flatten(node: *VfsNode) *VfsNode {
    if (node.mountpoint) |mp| {
        return mp;
    } else {
        return node;
    }
}

fn find_filesystem(fsname: []const u8) !*const FsVTable {
    for (fs_list) |fs| {
        if (std.mem.eql(u8, fs.name, fsname)) {
            return fs;
        }
    }

    return error.FsNotFound;
}

pub fn resolve(path: []const u8) !*VfsNode {
    // TODO(cleanbaja): sanity check the path
    var cur: *VfsNode = flatten(&root);
    var iter = std.mem.split(u8, path, "/");

    while (iter.next()) |elem| {
        if (elem.len == 0) {
            continue;
        }

        for (cur.children.items) |file| {
            if (std.mem.eql(u8, &file.name, elem)) {
                cur = flatten(file);
                break;
            }
        }

        return error.FileNotFound;
    }

    return cur;
}

pub fn mount(dest: []const u8, src: ?[]const u8, fsname: []const u8) !void {
    _ = src;
    var dest_node = try resolve(dest);
    //var src_node = blk: {
    //    if (src) |path| {
    //        break :blk try resolve(path);
    //    } else {
    //        break :blk null;
    //    }
    //};

    var fs_ops: *const FsVTable = try find_filesystem(fsname);
    try fs_ops.mount(dest_node, null);
}

pub fn init() void {
    // fill in the root vfs node
    root.name[0] = '/';
    root.stat = zeroes(types.Stat);
    root.stat.st_mode = types.StatFlags.S_IFDIR;

    // then mount tmpfs on '/'
    mount("/", null, "tmpfs") catch unreachable;
}
