const std = @import("std");
const limine = @import("limine");
const smp = @import("root").smp;
const zeroes = std.mem.zeroes;
const sink = std.log.scoped(.vfs);
const allocator = @import("root").allocator;

// modules
const tmpfs = @import("fs/tmpfs.zig");
const types = @import("types.zig");

pub const VfsError = error{
    OutOfMemory,
    InvalidPath,
    InvalidParams,
    FileNotDir,
    FileNotExist,
};

pub const VTable = struct {
    read: *const fn (node: *VfsNode, buffer: [*]u8, offset: u64, length: usize) VfsError!usize,
    write: *const fn (node: *VfsNode, buffer: [*]const u8, offset: u64, length: usize) VfsError!usize,
    close: *const fn (node: *VfsNode) void,
};

pub const FsVTable = struct {
    create: *const fn (parent: *VfsNode, name: []const u8, st: types.Stat) VfsError!*VfsNode,
};

pub const Filesystem = struct {
    vtable: *const FsVTable,
    context: *anyopaque,
};

pub const VfsNode = struct {
    name: []const u8 = undefined,
    stat: types.Stat = undefined,
    children: std.ArrayList(*VfsNode) = undefined,
    parent: *VfsNode = undefined,

    vtable: *const VTable = undefined,
    fs: *const Filesystem = undefined,
    mountpoint: ?*VfsNode = null,
    inode: ?*anyopaque = null,
    lock: smp.SpinLock = .{},

    pub fn isDir(self: *VfsNode) bool {
        if ((self.stat.st_mode & types.StatFlags.S_IFDIR) != 0) {
            return true;
        } else {
            return false;
        }
    }

    pub fn flatten(self: *VfsNode) *VfsNode {
        if (self.mountpoint) |new_root| {
            return new_root;
        } else {
            return self;
        }
    }

    pub fn find(self: *VfsNode, path: []const u8) ?*VfsNode {
        std.debug.assert(self.isDir());

        if (std.mem.eql(u8, path, ".")) {
            return self;
        } else if (std.mem.eql(u8, path, "..")) {
            return self.parent;
        }

        self.lock.acq();
        defer self.lock.rel();

        for (self.children.items) |file| {
            if (std.mem.eql(u8, file.name, path)) {
                // TODO(cleanbaja): handle symlinks
                return file;
            }
        }

        return null;
    }
};

pub const VStream = struct {
    node: *VfsNode,
    offset: u64,

    pub const ReaderError = VfsError || std.os.PReadError || error{OutOfMemory} || error{NotImplemented};
    pub const SeekError = error{};
    pub const GetSeekPosError = error{};

    pub const SeekableStream = std.io.SeekableStream(
        *VStream,
        SeekError,
        GetSeekPosError,
        VStream.seekTo,
        VStream.seekBy,
        VStream.getPosFn,
        VStream.getEndPosFn,
    );
    pub const Reader = std.io.Reader(
        *VStream,
        ReaderError,
        VStream.read,
    );

    pub fn init(nd: *VfsNode) @This() {
        return @This(){
            .node = nd,
            .offset = 0,
        };
    }

    fn seekTo(self: *VStream, offset: u64) SeekError!void {
        self.offset = offset;
    }

    fn seekBy(self: *VStream, offset: i64) SeekError!void {
        self.offset +%= @bitCast(u64, offset);
    }

    fn getPosFn(self: *VStream) GetSeekPosError!u64 {
        return self.offset;
    }

    fn getEndPosFn(self: *VStream) GetSeekPosError!u64 {
        _ = self;

        return 0;
    }

    fn read(self: *VStream, buffer: []u8) ReaderError!usize {
        return try self.node.vtable.read(
            self.node,
            @ptrCast([*]u8, buffer),
            self.offset,
            buffer.len,
        );
    }

    pub fn seekableStream(self: *VStream) SeekableStream {
        return .{ .context = self };
    }

    pub fn reader(self: *VStream) Reader {
        return .{ .context = self };
    }
};

pub fn createNode(
    parent_dir: ?*VfsNode,
    pathname: []const u8,
    st: types.Stat,
    fs: *const Filesystem,
    vtable: *const VTable,
    add: bool,
) !*VfsNode {
    var new_node = try allocator().create(VfsNode);
    errdefer allocator().destroy(new_node);

    var parent: *VfsNode = root.flatten();
    if (parent_dir) |p| {
        parent = p.flatten();
    }

    new_node.* = .{
        .name = pathname,
        .parent = parent,
        .stat = st,
        .fs = fs,
        .vtable = vtable,
    };

    if (new_node.isDir()) {
        new_node.children = std.ArrayList(*VfsNode).init(allocator());

        var dot_dir = try allocator().create(VfsNode);
        var dotdot_dir = try allocator().create(VfsNode);

        dot_dir.* = .{
            .name = ".",
            .stat = st,
            .fs = fs,
            .vtable = vtable,
            .parent = new_node,
        };

        dotdot_dir.* = .{
            .name = "..",
            .stat = parent.stat,
            .fs = fs,
            .vtable = vtable,
            .parent = new_node,
        };

        try new_node.children.append(dot_dir);
        try new_node.children.append(dotdot_dir);
    }

    if (add) {
        parent.lock.acq();
        defer parent.lock.rel();

        try parent.children.append(new_node);
    }

    return new_node;
}

pub fn resolve(parent: ?*VfsNode, path: []const u8) !*VfsNode {
    if (path.len == 0) {
        return error.InvalidParams;
    }

    var cur: *VfsNode = undefined;
    var iter = std.mem.split(u8, path, "/");

    if (parent == null or path[0] == '/') {
        cur = root.flatten();
    } else {
        cur = parent.?.flatten();
    }

    while (iter.next()) |elem| {
        if (elem.len == 0) {
            continue;
        }

        if (!cur.isDir()) {
            return error.InvalidPath;
        }

        if (cur.find(elem)) |next| {
            cur = next.flatten();
        } else {
            return error.FileNotFound;
        }
    }

    return cur;
}

pub fn createDeepNode(
    parent_dir: ?*VfsNode,
    pathname: []const u8,
    st: types.Stat,
    fs: *Filesystem,
    vtable: *const VTable,
) !*VfsNode {
    var cur: *VfsNode = undefined;
    if (parent_dir) |p| {
        cur = p.flatten();
    } else {
        cur = root.flatten();
    }

    var iter = std.mem.split(u8, pathname, "/");
    var stat = std.mem.zeroes(types.Stat);

    while (iter.next()) |elem| {
        if (!cur.isDir()) {
            return error.InvalidPath;
        }

        var result = cur.find(elem);

        if (result == null) {
            if (iter.rest().len > 0) {
                stat.st_mode = cur.stat.st_mode;
                result = try createNode(cur, elem, stat, cur.fs, cur.vtable, true);
            } else {
                result = try createNode(cur, elem, st, fs, vtable, true);
            }
        }

        cur = result.?.flatten();
    }

    return cur;
}

pub fn mount(target: *VfsNode, st: types.Stat, fs: *const Filesystem, vtable: *const VTable) !void {
    if (!target.isDir()) {
        return error.FileNotDir;
    }

    target.mountpoint = try createNode(target.parent, target.name, st, fs, vtable, false);
}

pub const CpioReader = struct {
    bytes: []u8 = undefined,
    offset: u64 = 0,
    complete: bool = false,

    pub const Entry = struct {
        dev: u32 = 0,
        devmajor: u32,
        devminor: u32,
        ino: u32,
        mode: u32,
        uid: u32,
        gid: u32,
        nlink: u32,
        rdev: u32 = 0,
        rdevmajor: u32,
        rdevminor: u32,
        mtime: u64,
        filesize: usize,
        name: []const u8 = undefined,
        file: []u8 = undefined,
    };

    const Version = enum(u8) {
        old,
        portable_ascii,
        new_ascii,
        crc,
    };

    pub fn init(file: []u8) CpioReader {
        return .{
            .bytes = file,
        };
    }

    fn peek16(self: *CpioReader) u16 {
        return self.bytes[self.offset] | (@as(u16, self.bytes[self.offset + 1]) << 8);
    }

    fn readStr32(self: *CpioReader) u32 {
        var ret = std.fmt.parseInt(u32, self.bytes[self.offset .. self.offset + 8], 16) catch unreachable;
        self.offset += 8;
        return ret;
    }

    pub fn getVersion(self: *CpioReader) Version {
        const OLD_MAGIC: u16 = 0o070_707;
        const PORTABLE_MAGIC: []const u8 = "070707";
        const NEW_ASCII_MAGIC: []const u8 = "070701";
        const CRC_MAGIC: []const u8 = "070702";

        // NOTE: we don't support old format encoded in big endian
        if (self.peek16() == OLD_MAGIC) {
            return .old;
        } else if (std.mem.eql(u8, self.bytes[self.offset .. self.offset + 6], PORTABLE_MAGIC)) {
            return .portable_ascii;
        } else if (std.mem.eql(u8, self.bytes[self.offset .. self.offset + 6], NEW_ASCII_MAGIC)) {
            return .new_ascii;
        } else if (std.mem.eql(u8, self.bytes[self.offset .. self.offset + 6], CRC_MAGIC)) {
            return .crc;
        } else {
            @panic("unable to find CPIO version!");
        }
    }

    pub fn parseNewAsciiOrCrc(self: *CpioReader) Entry {
        self.offset += 6;

        var ent: Entry = .{
            .ino = self.readStr32(),
            .mode = self.readStr32(),
            .uid = self.readStr32(),
            .gid = self.readStr32(),
            .nlink = self.readStr32(),
            .mtime = @as(u64, self.readStr32()),
            .filesize = self.readStr32(),
            .devmajor = self.readStr32(),
            .devminor = self.readStr32(),
            .rdevmajor = self.readStr32(),
            .rdevminor = self.readStr32(),
        };

        var namesize = self.readStr32();
        _ = self.readStr32(); // skip crc

        ent.name = self.bytes[self.offset .. self.offset + namesize - 1];
        self.offset += namesize;
        self.offset += ((4 - self.offset % 4) % 4);

        ent.file = self.bytes[self.offset .. self.offset + ent.filesize];
        self.offset += ent.filesize;
        self.offset += ((4 - self.offset % 4) % 4);

        return ent;
    }

    pub fn next(self: *CpioReader) ?Entry {
        if (self.complete) {
            return null;
        }

        var entry = ent: {
            switch (self.getVersion()) {
                .old, .portable_ascii => {
                    sink.warn("parsing \"old\" or \"portable_ascii\" CPIO variants is unsupported!", .{});
                    return null;
                },
                .new_ascii, .crc => {
                    break :ent self.parseNewAsciiOrCrc();
                },
            }
        };

        if (std.mem.eql(u8, entry.name, "TRAILER!!!")) {
            self.complete = true;
            return null;
        } else {
            return entry;
        }
    }
};

pub export var mods_request: limine.ModuleRequest = .{};
pub var root: VfsNode = undefined;

pub fn init() void {
    // fill in the root vfs node
    root.name = "/";
    root.stat = zeroes(types.Stat);
    root.stat.st_mode = types.StatFlags.S_IFDIR;

    // create tmpfs context
    var context = allocator().create(tmpfs.TmpfsContext) catch unreachable;
    var filesystem = allocator().create(Filesystem) catch unreachable;
    filesystem.context = context;
    filesystem.vtable = &tmpfs.fs_vtable;
    context.device = 1;

    // mount tmpfs to '/'
    mount(&root, root.stat, filesystem, &tmpfs.vtable) catch unreachable;

    if (mods_request.response) |resp| {
        var mod = resp.modules()[0];
        var reader = CpioReader.init(mod.address[0..mod.size]);
        var stat = std.mem.zeroes(types.Stat);

        sink.info("initrd format is \"{s}\"", .{@tagName(reader.getVersion())});

        while (reader.next()) |file| {
            stat.st_mode = @intCast(i32, file.mode);
            stat.st_nlink = @intCast(i32, file.nlink);
            stat.st_size = @intCast(i64, file.filesize);
            var node = createDeepNode(null, file.name, stat, filesystem, &tmpfs.vtable) catch unreachable;

            var inode = allocator().create(tmpfs.TmpfsInode) catch unreachable;
            inode.base = file.file;
            inode.bytes = file.filesize;
            node.inode = inode;
        }
    }
}
