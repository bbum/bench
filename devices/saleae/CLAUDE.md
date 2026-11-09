# CLAUDE.md

`sal` drives Saleae logic analyzers through Logic 2's gRPC automation server. It is
a CLI today and will grow an MCP server. First target is the Logic Pro 8.

Status: `sal status` and `sal capture` (timed digital capture with a per-channel
summary) work. Protocol decoding and MCP are not built yet.

## Build

```
swift build
make test        # offline, uses a recorded testgen capture
make verify      # live end-to-end check; needs Logic 2 and the testgen board
make build       # release
make install     # release -> ~/.local/bin/sal
make proto       # regenerate Sources/sal/Generated; needs protoc
```

Logic 2 must be running with the automation server on (Settings > Automation, or
launch with `--automation`). It listens on 127.0.0.1:10430.

## Testing

Tested the way SQLite is. New parsing or analysis code ships with all of these:

- **Coverage:** `make coverage` reports region coverage of hand-written code. Swift
  tooling has no MC/DC or branch data, so regions are the measure.
- **Mutation:** `make mutation` injects bugs from `tools/mutation_test.py` one at a
  time, and the offline tests must catch each. Add mutants for new logic.
- **Boundaries:** test both sides of every threshold.
- **Corrupt input:** every truncation, every header byte value, hostile values in every
  field, and seeded random corruption. Must reject or summarize, never trap.
- **Differential:** an independently written oracle checks summaries on every 12-slot
  edge pattern, generated signals and real captures.
- **Fault injection:** every Logic 2 call fails, alone and in every combination.
  Started captures must close and temp files must go.
- **Hardware:** `make verify` checks a live capture of `testgen`.
- **Regressions:** every bug found gets a test.

## Why it is built this way

- **Why not just Saleae's MCP (port 10530):** every tool repeats the same 10.6 KB
  schema block (168 KB total, about 10 KB needed), has no enums or `oneOf`, and
  returns data only as files on disk.
- **gRPC has no in-memory path either.** All 16 RPCs are unary and exports only
  write files. Fast analysis means exporting binary to a temp directory and
  memory-mapping it in-process.
- **Why `grpc-swift`:** the server speaks cleartext HTTP/2. `URLSession` falls back
  to HTTP/1.1 and the server drops the connection, and Network.framework has no
  public HTTP/2 API. Uses the Network.framework-based NIO transport.

## Landmines

- Analyzer setting names appear in neither the MCP schema nor the proto. They must
  match the names in Logic 2's UI. Confirmed working on Logic 2.4.48, as channel
  numbers unless noted:
  - `Async Serial`: `Input Channel`, `Bit Rate (Bits/s)` (a number)
  - `SPI`: `Clock`, `MOSI`, `Enable`
  - `I2C`: `SDA`, `SCL`
- The deployment target is macOS 27.0 because the current toolchain rejects 27.2.
- Binary exports: this Logic Pro 8 on Logic 2.4.48 produces format V0 (confirmed by
  capture). Saleae says the device will move to a chunked V1, so check the version
  field and reject anything unknown.
- `testgen/` is an ESP8266 known-answer signal source. Its README has the wiring and
  the expected values for each channel.
- `proto/` is a verbatim copy of upstream. See `proto/UPSTREAM`.
