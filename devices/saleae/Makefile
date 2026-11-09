PREFIX ?= ~/.local
BINDIR ?= $(PREFIX)/bin
CONFIG ?= release
GENERATED := Sources/sal/Generated

.PHONY: build test verify coverage mutation blind install proto clean

build:
	swift build -c $(CONFIG)

# SAL_NO_LAUNCH keeps a failing test from ever starting Logic 2.
test:
	SAL_NO_LAUNCH=1 swift test

# End-to-end check against real hardware. Needs Logic 2 and the testgen board.
verify:
	swift build
	SAL_LIVE=1 swift test --filter LiveTests

# Injects bugs one at a time and requires the offline tests to catch each one. Works in a
# copy of the package, never in this tree. ARGS="Logic2App stalled" picks mutants.
mutation:
	python3 -I tools/mutation_test.py $(ARGS)

# Region coverage of hand-written code, including the live tests.
coverage:
	swift build
	SAL_LIVE=1 swift test --enable-code-coverage
	xcrun llvm-cov report \
		.build/debug/salTests.xctest/Contents/MacOS/salTests \
		-instr-profile=.build/debug/codecov/default.profdata \
		-ignore-filename-regex='(\.build|Generated|Tests)/'

# Scores sal identify against random signals on all 8 testgen pins. Needs Logic 2 and testgen.
blind:
	swift build
	python3 -I tools/blind_test.py $(ARGS)

install: build
	@mkdir -p $(BINDIR)
	@rm -f $(BINDIR)/sal
	cp .build/$(CONFIG)/sal $(BINDIR)/

# Regenerates checked-in Swift from proto/saleae.proto. Only needed when the proto
# changes. Requires protoc (brew install protobuf).
proto:
	swift build --product protoc-gen-swift
	swift build --product protoc-gen-grpc-swift-2
	@mkdir -p $(GENERATED)
	protoc --proto_path=proto saleae.proto \
		--plugin=protoc-gen-swift=.build/debug/protoc-gen-swift \
		--plugin=protoc-gen-grpc-swift-2=.build/debug/protoc-gen-grpc-swift-2 \
		--swift_opt=Visibility=Internal \
		--swift_out=$(GENERATED) \
		--grpc-swift-2_opt=Visibility=Internal,Server=false,Client=true \
		--grpc-swift-2_out=$(GENERATED)

clean:
	swift package clean
