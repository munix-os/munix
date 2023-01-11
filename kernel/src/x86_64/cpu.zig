const std = @import("std");
const arch = @import("root").arch;
const smp = @import("root").smp;
const sink = std.log.scoped(.cpu);
const trap = arch.trap;

const SaveType = enum {
    fxsave,
    xsave,
    xsaveopt,
    xsavec,
    xsaves,
};

// the combined bits of every supported XCR0 extension
const supported_mask = 0x602e7;

var fpu_storage_size: usize = 0;
var fpu_storage_align: usize = 0;
var fpu_mode: SaveType = undefined;

inline fn wrxcr(comptime reg: usize, value: u64) void {
    var edx: u32 = @truncate(u32, value >> 32);
    var eax: u32 = @truncate(u32, value);

    asm volatile ("xsetbv"
        :
        : [eax] "{eax}" (eax),
          [edx] "{edx}" (edx),
          [ecx] "{ecx}" (reg),
        : "memory"
    );
}

pub export fn handleSyscall(frame: *trap.TrapFrame) callconv(.C) void {
    sink.err("unsupported syscall #{}!", .{frame.rax});
    while (true) {}
}

pub fn fpuRestore(save_area: []const u8) void {
    std.debug.assert(@ptrToInt(save_area) % fpu_storage_align == 0);

    var rbfm = 0xffffffff;
    var rbfm_high = 0xffffffff;

    switch (fpu_mode) {
        .xsave, .xsavec, .xsaveopt => {
            asm volatile ("xrstorq (%[context])"
                :
                : [context] "r" (save_area),
                  [eax] "{eax}" (rbfm),
                  [edx] "{edx}" (rbfm_high),
                : "memory"
            );
        },
        .xsaves => {
            asm volatile ("xrstorsq (%[context])"
                :
                : [context] "r" (save_area),
                  [eax] "{eax}" (rbfm),
                  [edx] "{edx}" (rbfm_high),
                : "memory"
            );
        },
        .fxsave => {
            asm volatile ("fxrstorq (%[context])"
                :
                : [context] "r" (save_area),
                : "memory"
            );
        },
    }
}

pub fn fpuSave(save_area: []const u8) void {
    std.debug.assert(@ptrToInt(save_area) % fpu_storage_align == 0);

    var rbfm = 0xffffffff;
    var rbfm_high = 0xffffffff;

    switch (fpu_mode) {
        .xsave => {
            asm volatile ("xsaveq (%[context])"
                :
                : [context] "r" (save_area),
                  [eax] "{eax}" (rbfm),
                  [edx] "{edx}" (rbfm_high),
                : "memory"
            );
        },
        .xsavec => {
            asm volatile ("xsavecq (%[context])"
                :
                : [context] "r" (save_area),
                  [eax] "{eax}" (rbfm),
                  [edx] "{edx}" (rbfm_high),
                : "memory"
            );
        },
        .xsaves => {
            asm volatile ("xsavesq (%[context])"
                :
                : [context] "r" (save_area),
                  [eax] "{eax}" (rbfm),
                  [edx] "{edx}" (rbfm_high),
                : "memory"
            );
        },
        .xsaveopt => {
            asm volatile ("xsaveoptq (%[context])"
                :
                : [context] "r" (save_area),
                  [eax] "{eax}" (rbfm),
                  [edx] "{edx}" (rbfm_high),
                : "memory"
            );
        },
        .fxsave => {
            asm volatile ("fxsaveq (%[context])"
                :
                : [context] "r" (save_area),
                : "memory"
            );
        },
    }
}

pub fn setupFpu() void {
    // enable SSE & FXSAVE/FXRSTOR
    arch.wrcr4(arch.rdcr4() | (3 << 9));

    if (arch.cpuid(1, 0).ecx & (1 << 26) != 0) {
        arch.wrcr4(arch.rdcr4() | (1 << 18));
        fpu_storage_align = 64;
        fpu_mode = .xsave;

        var result = arch.cpuid(0xD, 1);
        if (result.eax & (1 << 0) != 0) {
            fpu_mode = .xsaveopt;
        }
        if (result.eax & (1 << 1) != 0) {
            fpu_mode = .xsavec;
        }
        if (result.eax & (1 << 3) != 0) {
            fpu_mode = .xsaves;
        }

        result = arch.cpuid(0xD, 0);
        wrxcr(0, @as(u64, result.eax) & supported_mask);

        if (smp.getCoreInfo().is_bsp) {
            sink.info("supported extensions bitmask: 0x{X}", .{result.eax});
        }

        switch (fpu_mode) {
            .xsave, .xsaveopt => {
                fpu_storage_size = result.ecx;
            },
            .xsavec, .xsaves => {
                fpu_storage_size = result.ebx;
            },
            else => {},
        }
    } else {
        fpu_storage_size = 512;
        fpu_storage_align = 16;
        fpu_mode = .fxsave;
    }

    if (smp.getCoreInfo().is_bsp) {
        sink.info(
            "using \"{s}\" instruction (with size={}) for FPU context management",
            .{ @tagName(fpu_mode), fpu_storage_size },
        );
    }
}

pub fn init() void {
    // setup the FPU first
    setupFpu();

    // set the CPU to a acceptable state
    arch.wrcr0((arch.rdcr0() & ~@as(u64, 1 << 2)) | 0b10);
    arch.wrcr4(arch.rdcr4() | (1 << 7));

    // enable pkeys (if supported)
    if (arch.cpuid(7, 0).ecx & (1 << 3) != 0) {
        arch.wrcr4(arch.rdcr4() | (1 << 22));
    }

    // enable umip (if supported)
    if (arch.cpuid(7, 0).ecx & (1 << 2) != 0) {
        arch.wrcr4(arch.rdcr4() | (1 << 11));
    }

    // enable syscall
    arch.wrmsr(0xC0000081, (@as(u64, 0x30 | 0b11) << 48) | ((@as(u64, 0x28) << 32)));
    arch.wrmsr(0xC0000082, @ptrToInt(&syscallEntry));
    arch.wrmsr(0xC0000080, arch.rdmsr(0xC0000080) | 1);
    arch.wrmsr(0xC0000084, ~@as(u32, 2));
}

fn syscallEntry() callconv(.Naked) void {
    // zig fmt: off
    asm volatile (
        // perform a swapgs and switch to the kernel stack 
        \\swapgs
        \\movq %rsp, %%gs:16
        \\movq %%gs:28, %rsp
        \\sti

        // create a fake trapframe header
        \\pushq $0x38
        \\pushq %%gs:16
        \\pushq %r11
        \\pushq $0x40
        \\pushq %rcx
        \\pushq $0
        \\pushq $0

        // push remaining registers
        \\push %r15
        \\push %r14
        \\push %r13
        \\push %r12
        \\push %r11
        \\push %r10
        \\push %r9
        \\push %r8
        \\push %rbp
        \\push %rdi
        \\push %rsi
        \\push %rdx
        \\push %rcx
        \\push %rbx
        \\push %rax
        \\cld

        // call the syscall handler
        \\mov %rsp, %rdi
        \\xor %rbp, %rbp
        \\call handleSyscall

        // pop the trapframe back into place
        \\pop %rax
        \\pop %rbx
        \\pop %rcx
        \\pop %rdx
        \\pop %rsi
        \\pop %rdi
        \\pop %rbp
        \\pop %r8
        \\pop %r9
        \\pop %r10
        \\pop %r11
        \\pop %r12
        \\pop %r13
        \\pop %r14
        \\pop %r15
        \\add $16, %rsp

        // restore the context back to place
        \\cli
        \\mov %rsp, %%gs:16
        \\swapgs
        \\sysretq
    );
    // zig fmt: on
}
