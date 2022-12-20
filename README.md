# Munix

munix is my (new) attempt at writing a proper unix clone, without straying away for a month (or two)
to add completly unnecessary and complicated features.

## Building

To build/run the kernel and to generate images, run the following...

```bash
$ # Kernel + ISO
$ make && make run
$ # Kernel + HDD
$ make all-hdd && make run-hdd
$ # Kernel + HDD + UEFI
$ make all-hdd && make run-hdd-uefi
```

**NOTE: the latest stage 2/3 Zig compiler is required to build munix! (instructions [here](https://github.com/ziglang/zig/wiki/Building-Zig-From-Source))**
