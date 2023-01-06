.POSIX:
.PHONY: distro-base

BUILD_DIR = build

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && xbstrap init ..

distro-base: $(BUILD_DIR)
	cd $(BUILD_DIR) && xbstrap install --all
