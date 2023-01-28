.POSIX:
.PHONY: all all-hdd run run-uefi run-hdd run-hdd-uefi

QEMU_COMMON_FLAGS = -cpu max --enable-kvm -M q35 -m 2G -smp 4

all: munix.iso

all-hdd: munix.hdd

run: munix.iso
	qemu-system-x86_64 $(QEMU_COMMON_FLAGS) -cdrom munix.iso

run-uefi: ovmf-x64 munix.iso
	qemu-system-x86_64 $(QEMU_COMMON_FLAGS) -bios ovmf-x64/OVMF.fd -cdrom munix.iso

run-hdd: munix.hdd
	qemu-system-x86_64 $(QEMU_COMMON_FLAGS) -hda munix.hdd

run-hdd-uefi: ovmf-x64 munix.hdd
	qemu-system-x86_64 $(QEMU_COMMON_FLAGS) -bios ovmf-x64/OVMF.fd -hda munix.hdd

ovmf-x64:
	mkdir -p ovmf-x64
	cd ovmf-x64 && curl -o OVMF-X64.zip https://efi.akeo.ie/OVMF/OVMF-X64.zip && unzip OVMF-X64.zip

limine:
	git clone https://github.com/limine-bootloader/limine.git --branch=v4.x-branch-binary --depth=1
	$(MAKE) -C limine

.PHONY: kernel clean distclean
kernel:
	$(MAKE) -C kernel

munix.iso: limine kernel
	rm -rf iso_root
	mkdir -p iso_root
	cp kernel/zig-out/bin/kernel \
		limine.cfg limine/limine.sys limine/limine-cd.bin limine/limine-cd-efi.bin iso_root/
	[ -f user/initrd.img ] && cp user/initrd.img iso_root/
	xorriso -as mkisofs -b limine-cd.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		--efi-boot limine-cd-efi.bin \
		-efi-boot-part --efi-boot-image --protective-msdos-label \
		iso_root -o munix.iso
	limine/limine-deploy munix.iso
	rm -rf iso_root

munix.hdd: limine kernel
	rm -f munix.hdd
	dd if=/dev/zero bs=1M count=0 seek=64 of=munix.hdd
	parted -s munix.hdd mklabel gpt
	parted -s munix.hdd mkpart ESP fat32 2048s 100%
	parted -s munix.hdd set 1 esp on
	limine/limine-deploy munix.hdd
	sudo losetup -Pf --show munix.hdd >loopback_dev
	sudo mkfs.fat -F 32 `cat loopback_dev`p1
	mkdir -p img_mount
	sudo mount `cat loopback_dev`p1 img_mount
	sudo mkdir -p img_mount/EFI/BOOT
	sudo cp -v kernel/zig-out/bin/kernel limine.cfg limine/limine.sys img_mount/
	sudo cp -v limine/BOOTX64.EFI img_mount/EFI/BOOT/
	[ -f user/initrd.img ] && sudo cp user/initrd.img img_mount/
	sync
	sudo umount img_mount
	sudo losetup -d `cat loopback_dev`
	sudo rm -rf loopback_dev img_mount

clean:
	rm -rf iso_root munix.iso munix.hdd
	$(MAKE) -C kernel clean

distclean: clean
	rm -rf limine ovmf-x64
	$(MAKE) -C kernel distclean
