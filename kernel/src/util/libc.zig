pub usingnamespace @cImport({
    @cInclude("sys/stat.h");
});

pub const TimeSpec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

pub const Stat = extern struct {
    st_dev: u64,
    st_mode: i32,
    st_ino: u64,
    st_nlink: i32,
    st_uid: i32,
    st_gid: i32,
    st_rdev: u64,
    st_atim: TimeSpec,
    st_mtim: TimeSpec,
    st_ctim: TimeSpec,
    st_size: i64,
    st_blocks: i64,
    st_blksize: i64,
};
