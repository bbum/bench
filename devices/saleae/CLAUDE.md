# CLAUDE.md

`sal` drives Saleae logic analyzers through Logic 2's gRPC automation server. It is
a CLI today and will grow an MCP server. First target is the Logic Pro 8.

Status: `sal status`, `sal capture` (digital capture with a per-channel summary) and
`sal decode uart|spi|i2c` (decoded rows with paging and issue counts) work, with timed,
manual and trigger captures and glitch filters. `sal identify` works out what is on
each channel, and `sal capture --analog` records analog with levels and duty. MCP is not built yet. See PLAN.md for the phases.

## Build

```
swift build
make test        # offline, uses a recorded testgen capture; about 40 s
make verify      # live end-to-end check; needs Logic 2 and testgen on USB
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
  time, and the offline tests must catch each. Add mutants for new logic. Takes 20
  minutes or more, so run it on demand, not routinely.
- **Boundaries:** test both sides of every threshold.
- **Corrupt input:** every truncation, every header byte value, hostile values in every
  field, and seeded random corruption. Must reject or summarize, never trap.
- **Differential:** an independently written oracle checks summaries on every 12-slot
  edge pattern, generated signals and real captures.
- **Fault injection:** every Logic 2 call fails, alone and in every combination.
  Started captures must close and temp files must go. The same holds when cancelled
  at every step.
- **Hardware:** `make verify` checks live captures of every `testgen` format and fault.
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
- Cancelling a capture must not cancel its cleanup, or the gRPC connection goes with it.
  `withCaptureCancellation` shields the work, and only the wait is interruptible.
- Data table columns vary with the data. `error` appears only when a row has one. In
  ASCII radix, cells hold real newlines. A wrong baud rate gets no error flag at all.
- UART `mp` and `mdb` modes read one address bit after Bits per Frame, so 9-bit address
  traffic is `--bits 8`.
- In a trigger capture, time zero is the trigger, and pre-trigger times are negative.
  Logic 2 ignores `trim_data_seconds` there, so `sal` refuses `--trim` with `--trigger`.
- A pulse trigger's maximum width of zero is taken literally and never fires.
- WaitCapture never returns if a trigger never fires, so `sal` applies its own timeout.
  Never call it on a manual capture.
- Reaching the buffer limit fails WaitCapture and CloseCapture. `make verify` does this
  on purpose, so a "Capture Stopped" dialog appearing in Logic 2 is expected.
- `sal identify` limits, which it reports as notes: timing cannot show MOSI from MISO,
  UART TX from RX, word size, stop bits or bit order, and idle lines show nothing.
- UART pauses between frames can be any length, so only time away from idle has to be
  whole bits. A capture opening mid-frame misdecodes until the next gap longer than a
  frame, so confirmation ignores rows before that gap.
- Mixed analog and digital captures accept only certain rate pairs, which vary with the
  channel set. 6.25 MS/s digital with 1.5625 MS/s analog works for every set tried, so
  it is the default. Logic 2's error lists the valid pairs.
- Adding an analyzer takes almost a second, so live tests should not add many.
- The deployment target is macOS 27.0 because the current toolchain rejects 27.2.
- Binary exports: this Logic Pro 8 on Logic 2.4.48 produces format V0 (confirmed by
  capture). Saleae says the device will move to a chunked V1, so check the version
  field and reject anything unknown.
- `testgen/` is an ESP8266 known-answer signal source. Its README has the wiring, the
  expected values for each channel, and the modes selected over USB serial. Opening
  the port usually resets the board and closing it does not, so tests select a mode
  and restore clean mode.
- `proto/` is a verbatim copy of upstream. See `proto/UPSTREAM`.
