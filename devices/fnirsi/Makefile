PREFIX ?= ~/.local
BINDIR ?= $(PREFIX)/bin
CONFIG ?= release

.PHONY: build test verify coverage install clean

build:
	swift build -c $(CONFIG)

# Offline: a fake meter stands in for the hardware.
test:
	swift test

# End-to-end check against the FNB58 on USB.
verify:
	swift build
	FNB58_LIVE=1 swift test --filter LiveTests

# Region coverage of hand-written code, including the live tests.
coverage:
	swift build
	FNB58_LIVE=1 swift test --enable-code-coverage
	xcrun llvm-cov report \
		.build/debug/fnb58PackageTests.xctest/Contents/MacOS/fnb58PackageTests \
		-instr-profile=.build/debug/codecov/default.profdata \
		-ignore-filename-regex='(\.build|Tests)/'

install: build
	@mkdir -p $(BINDIR)
	@rm -f $(BINDIR)/fnb58
	cp .build/$(CONFIG)/fnb58 $(BINDIR)/

clean:
	swift package clean
