const std = @import("std");
const zeroes = std.mem.zeroes;
const sink = std.log.scoped(.vfs);

// modules
const tmpfs = @import("fs/tmpfs.zig");
const types = @import("types.zig");

pub const VfsError = error{
    OutOfMemory,
    InvalidPath,
    InvalidParams,
    FileNotExist,
};

pub const ResolveFlags = struct {
    pub const NO_DEREF_SYMLINKS = 0x1;
    pub const PARTIAL = 0x2;
};

pub const VTable = struct {
    read: *const fn (node: *VfsNode, buffer: [*]u8, offset: u64, length: usize) VfsError!usize,
    write: *const fn (node: *VfsNode, buffer: [*]const u8, offset: u64, length: usize) VfsError!usize,
    close: *const fn (node: *VfsNode) void,
};

pub const FsVTable = struct {
    name: []const u8,
    create: *const fn (name: []const u8, mode: i32) VfsError!*VfsNode,
    mount: *const fn (parent_mount: *VfsNode, source: ?*VfsNode) VfsError!void,
    mkdir: *const fn (parent_dir: *VfsNode, basename: []const u8) VfsError!*VfsNode,
};

pub const VfsNode = struct {
    name: []const u8 = undefined,
    stat: types.Stat = undefined,
    children: std.ArrayList(*VfsNode) = undefined,
    mountpoint: ?*VfsNode = null,
    context: ?*anyopaque = null,

    vtable: *const VTable = undefined,
    fs: *const FsVTable = undefined,
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

pub fn createNode(pathname: []const u8, flags: i32) !*VfsNode {
    const allocator = @import("root").allocator;
    var new_node = try allocator.create(VfsNode);
    errdefer allocator.destroy(new_node);

    new_node.* = .{};
    new_node.name = pathname;
    new_node.stat = std.mem.zeroes(types.Stat);
    new_node.stat.st_mode = flags;

    if ((flags & types.StatFlags.S_IFDIR) != 0) {
        new_node.children = std.ArrayList(*VfsNode).init(allocator);
    }

    return new_node;
}

pub fn resolve(parent: ?*VfsNode, path: []const u8, flags: i32) !*VfsNode {
    // TODO(cleanbaja): sanity check the path
    var cur: *VfsNode = undefined;
    var iter = std.mem.split(u8, path, "/");

    if (parent) |ptr| {
        cur = flatten(ptr);
    } else {
        cur = flatten(&root);
    }

    while (iter.next()) |elem| {
        var new_cur: ?*VfsNode = null;

        if (elem.len == 0 or std.mem.eql(u8, elem, ".")) {
            continue;
        }

        for (cur.children.items) |file| {
            if (std.mem.eql(u8, file.name, elem)) {
                new_cur = flatten(file);

                if (new_cur.?.stat.st_mode & types.StatFlags.S_IFDIR == 0) {
                    return error.InvalidPath;
                } else {
                    break;
                }
            }
        }

        if (new_cur) |c| {
            cur = c;
        } else {
            if (flags & ResolveFlags.PARTIAL != 0) {
                return cur;
            } else if (new_cur == null) {
                return error.FileNotFound;
            }
        }
    }

    return cur;
}

pub fn getBasename(path: []const u8) ?[]const u8 {
    var iter = std.mem.split(u8, path, "/");
    var result: ?[]const u8 = null;

    while (iter.next()) |piece| {
        result = piece;
    }

    return result;
}

pub fn mkdir(parent: ?*VfsNode, path: []const u8) !void {
    var parent_node = try resolve(parent, path, ResolveFlags.PARTIAL);
    var basename = getBasename(path) orelse return error.InvalidPath;

    try parent_node.children.append(try parent_node.fs.mkdir(parent_node, basename));
}

pub fn open(parent: ?*VfsNode, path: []const u8, create: bool) !*VfsNode {
    return resolve(parent, path, 0) catch {
        if (!create) {
            return error.FileNotExist;
        }

        var parent_node = try resolve(parent, path, ResolveFlags.PARTIAL);
        var basename = getBasename(path) orelse return error.InvalidPath;

        // TODO(cleanbaja): respect mode
        var result = try parent_node.fs.create(basename, 0);
        try parent_node.children.append(result);
        return result;
    };
}

pub fn mount(dest: []const u8, src: ?[]const u8, fsname: []const u8) !void {
    var dest_node = try resolve(null, dest, 0);
    var src_node = blk: {
        if (src) |path| {
            break :blk try resolve(null, path, 0);
        } else {
            break :blk null;
        }
    };

    var fs_ops: *const FsVTable = try find_filesystem(fsname);
    try fs_ops.mount(dest_node, src_node);

    if (src_node != null) {
        sink.info("mounted {s} to {s} \"{s}\"", .{ src.?, dest, fsname });
    } else {
        sink.info("mounted a \"{s}\" instance to {s}", .{ fsname, dest });
    }
}

pub fn init() void {
    // fill in the root vfs node
    root.name = "/";
    root.stat = zeroes(types.Stat);
    root.stat.st_mode = types.StatFlags.S_IFDIR;

    // then mount tmpfs on '/'
    mount("/", null, "tmpfs") catch unreachable;
}
