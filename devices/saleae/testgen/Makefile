# Known-answer signal generator firmware. The toolchain installs under ./arduino/.

CORE_VERSION := 3.1.2
FQBN := esp8266:esp8266:nodemcuv2:baud=460800,eesz=4M
BUILD_DIR := build

# Only matches the CP2102 bridge, never an Espressif native-USB board.
PORT ?= $(firstword $(wildcard /dev/cu.usbserial*))
CONFIG := $(CURDIR)/arduino-cli.yaml
ACLI := arduino-cli --config-file "$(CONFIG)"

.PHONY: setup build flash monitor clean

setup:
	$(ACLI) core update-index
	$(ACLI) core install esp8266:esp8266@$(CORE_VERSION)

build:
	$(ACLI) compile --fqbn "$(FQBN)" --build-path "$(CURDIR)/$(BUILD_DIR)" .

flash: build
	$(ACLI) upload --fqbn "$(FQBN)" --port "$(PORT)" --input-dir "$(CURDIR)/$(BUILD_DIR)" .

monitor:
	$(ACLI) monitor --port "$(PORT)" --config baudrate=115200

clean:
	rm -rf $(BUILD_DIR)
