PREFIX ?= ~/.local
BINDIR ?= $(PREFIX)/bin
CONFIG ?= release
GENERATED := Sources/sal/Generated

.PHONY: build install proto clean

build:
	swift build -c $(CONFIG)

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
