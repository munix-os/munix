.POSIX:
.PHONY: distro-base

BUILD_DIR = build

all: initrd.img

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && xbstrap init ..

distro-base: $(BUILD_DIR)
	cd $(BUILD_DIR) && xbstrap install --all

initrd.img: distro-base
	cd $(BUILD_DIR)/system-root/ && find . | cpio -F ../initrd.cpio -oH newc
	gzip $(BUILD_DIR)/initrd.cpio && mv $(BUILD_DIR)/initrd.cpio.gz initrd.img
