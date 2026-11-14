# Known-answer signal generator firmware for an ESP32-S3 DevKitC-1, flashed and driven
# over its native USB port. The toolchain installs under ./arduino/.

CORE_VERSION := 3.3.8
FQBN := esp32:esp32:esp32s3:USBMode=hwcdc,CDCOnBoot=cdc,CPUFreq=240,UploadSpeed=921600
BUILD_DIR := build

# ./port finds the board by its USB serial number, so the knob or any other Espressif
# board on the bus is never touched.
PORT ?= $(shell ./port)
CONFIG := $(CURDIR)/arduino-cli.yaml
ACLI := arduino-cli --config-file "$(CONFIG)"

.PHONY: setup build flash monitor clean

setup:
	$(ACLI) core update-index
	$(ACLI) core install esp32:esp32@$(CORE_VERSION)

build:
	$(ACLI) compile --fqbn "$(FQBN)" --build-path "$(CURDIR)/$(BUILD_DIR)" .

flash: build
	@test -n "$(PORT)" || { echo "testgen not found; see README.md, or pass PORT=/dev/cu..."; exit 1; }
	$(ACLI) upload --fqbn "$(FQBN)" --port "$(PORT)" --input-dir "$(CURDIR)/$(BUILD_DIR)" .

monitor:
	$(ACLI) monitor --port "$(PORT)" --config baudrate=115200

clean:
	rm -rf $(BUILD_DIR)
