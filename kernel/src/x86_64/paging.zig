const vmm = @import("root").vmm;
const pmm = @import("root").pmm;

pub const PageMap = struct {
    root: u64 = undefined,

    pub fn load(self: *PageMap) void {
        loadSpace(self.root);
    }

    pub fn save(self: *PageMap) void {
        self.root = saveSpace();
    }

    pub fn mapPage(self: *PageMap, flags: vmm.MapFlags, virt: u64, phys: u64, huge: bool) void {
        var root: [*]u64 = @intToPtr([*]u64, vmm.toHigherHalf(self.root));

        // zig fmt: off
        var indices: [4]u64 = [_]u64{
            genIndex(virt, 39), genIndex(virt, 30),
            genIndex(virt, 21), genIndex(virt, 12)
        };
        // zig fmt: on

        // perform translation to pte
        // TODO(cleanbaja): don't just unwrap (handle the case of a OOM)
        root = getNextLevel(root, indices[0], true).?;
        root = getNextLevel(root, indices[1], true).?;

        if (huge) {
            root[indices[2]] = createPte(flags, phys, true);
        } else {
            root = getNextLevel(root, indices[2], true).?;
            root[indices[3]] = createPte(flags, phys, false);
        }
    }
};

inline fn genIndex(virt: u64, comptime shift: usize) u64 {
    return ((virt & (0x1FF << shift)) >> shift);
}

fn getNextLevel(level: [*]u64, index: usize, create: bool) ?[*]u64 {
    if ((level[index] & 1) == 0) {
        if (!create) {
            return null;
        }

        if (pmm.allocPages(1)) |table_ptr| {
            level[index] = table_ptr;
            level[index] |= 0b111;
        } else {
            return null;
        }
    }

    return @intToPtr([*]u64, vmm.toHigherHalf(level[index] & ~(@intCast(u64, 0x1ff))));
}

fn createPte(flags: vmm.MapFlags, phys_ptr: u64, huge: bool) u64 {
    var result: u64 = 1; // pages have to be readable to be present
    var pat_bit: u64 = blk: {
        if (huge) {
            break :blk (1 << 12);
        } else {
            break :blk (1 << 7);
        }
    };

    if (flags.write) {
        result |= (1 << 1);
    }

    if (!(flags.exec)) {
        result |= (1 << 63);
    }

    if (flags.user) {
        result |= (1 << 2);
    }

    if (huge) {
        result |= (1 << 7);
    }

    switch (flags.cache_type) {
        .uncached => {
            result |= (1 << 4) | (1 << 3);
            result &= ~pat_bit;
        },
        .write_combining => {
            result |= pat_bit | (1 << 4) | (1 << 3);
        },
        .write_protect => {
            result |= pat_bit | (1 << 4);
            result &= ~@intCast(u64, (1 << 3));
        },
        else => {},
    }

    result |= phys_ptr;
    return result;
}

pub inline fn invalidatePage(ptr: usize) void {
    asm volatile ("invlpg (%[virt])"
        :
        : [virt] "r" (ptr),
        : "memory"
    );
}

pub inline fn loadSpace(ptr: usize) void {
    asm volatile ("mov %[root], %%cr3"
        :
        : [root] "r" (ptr),
        : "memory"
    );
}
pub inline fn saveSpace() usize {
    return asm volatile ("mov %%cr3, %[old_cr3]"
        : [old_cr3] "=r" (-> u64),
        :
        : "memory"
    );
}
