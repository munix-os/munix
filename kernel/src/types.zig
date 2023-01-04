pub const StatFlags = struct {
    pub const S_IFMT = 0x0F000;
    pub const S_IFBLK = 0x06000;
    pub const S_IFCHR = 0x02000;
    pub const S_IFIFO = 0x01000;
    pub const S_IFREG = 0x08000;
    pub const S_IFDIR = 0x04000;
    pub const S_IFLNK = 0x0A000;
    pub const S_IFSOCK = 0x0C000;

    pub const S_IRWXU = 0o700;
    pub const S_IRUSR = 0o400;
    pub const S_IWUSR = 0o200;
    pub const S_IXUSR = 0o100;
    pub const S_IRWXG = 0o70;
    pub const S_IRGRP = 0o40;
    pub const S_IWGRP = 0o20;
    pub const S_IXGRP = 0o10;
    pub const S_IRWXO = 0o7;
    pub const S_IROTH = 0o4;
    pub const S_IWOTH = 0o2;
    pub const S_IXOTH = 0o1;
    pub const S_ISUID = 0o4000;
    pub const S_ISGID = 0o2000;
    pub const S_ISVTX = 0o1000;
};

pub const TimeSpec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

pub const Stat = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_mode: i32,
    st_nlink: i32,
    st_uid: i32,
    st_gid: i32,
    st_rdev: u64,
    st_size: i64,
    st_atim: TimeSpec,
    st_mtim: TimeSpec,
    st_ctim: TimeSpec,
    st_blksize: i64,
    st_blocks: i64,
};
