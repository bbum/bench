# Saleae

Tooling for Saleae logic analyzers. The Logic Pro 8 is the first target, and other
Saleae hardware is expected to follow.

`sal` talks to Logic 2's gRPC automation server, so Logic 2 must be running with
that server enabled.

```
swift build
.build/debug/sal status
```
