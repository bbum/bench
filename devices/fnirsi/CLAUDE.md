# CLAUDE.md

`fnb58` reads the FNIRSI FNB58 USB power meter (VID 0x2E3C, PID 0x5558) over IOHIDManager,
as a CLI and as an MCP server. See README.md for verbs and tools.

## Build

```
swift build
make test        # offline, against a fake meter; about 2 s
make verify      # live, needs the meter on USB; about 30 s
make coverage
make install     # release -> ~/.local/bin/fnb58
```

## Layout

- `Meter/Protocol.swift`: commands, CRC, report and sample decoding, the 0x03 device info.
- `Meter/HIDTransport.swift`: IOKit. `MeterTransport` and `MeterLink` let tests substitute
  `FakeLink` (Tests/Support.swift), which behaves like the meter: it answers 0x81, streams
  after the second 0x82, and stops when keepalives lapse.
- `Session.swift`: the actor owning the one stream: start, keepalive, watchdog, drain,
  captures, marks, raw dumps. CLI and MCP both go through it.
- `Capture/`: statistics, the CSV recorder and reader, window statistics.

## Testing

Same standard as `../saleae`: an independent oracle for statistics and CRC, both sides of
every boundary, every truncation and seeded corruption of reports and CSVs, fault
injection (every start command failing, unplug, stall, stream dying once, cancel), and a
regression test for every bug found. There is no mutation harness yet.

## Landmines

- **The meter wedges, and only a replug cures it.** Every SetReport then times out after
  5 s with kIOReturnTimeout (0xE00002D6), and no reports arrive, in any process. Causes
  seen here or reported by other tools:
  - Start commands sent back to back. Wait for the 0x03 reply to 0x81, then leave 50 ms
    (`FNB58.commandGap`) before each 0x82. Other tools use 10 to 50 ms.
  - Closing while reports are queued. `disconnect()` reads until 300 ms of silence, for
    up to 2.5 s.
  - USB reset or SetConfiguration (other tools). Never do either.
  - Scheduling the device on a dispatch queue rather than a run loop coincided with the
    first wedge here. `HIDLink` uses a run-loop thread, as the probe that worked did.
- **No stop command.** 0x84 and up are unverified on USB, and the trigger commands can
  raise VBUS on whatever is attached. Send only 0x81, 0x82 and 0x83.
- **The stream outlives its keepalives by about 1.5 s**, and a keepalive alone does not
  restart a stopped stream. So a stream already running at connect gets a keepalive, not
  0x81 (other tools say 0x81 can reboot a streaming meter). The watchdog in `tick()` runs
  the full start again after 500 ms without data, and the capture warns that samples were
  lost.
- **Stalls are judged on data reports only.** A meter that has stopped streaming still
  answers 0x81 with 0x03, which once kept a stalled capture alive forever.
- **Drop the first data report after starting.** Other tools saw garbage there on the
  FNB48.
- **Byte 12 is the temperature sign**: 1 positive, 0 negative, per other tools. This unit
  has only shown 1.
- **The 0x03 reply**: bytes 6–7 are the model (58), bytes 8–9 the firmware ×100 (118 =
  1.18, confirmed against the meter's screen). The rest is undecoded. This unit's 1.18 is
  newer than FNIRSI's download page (1.15 as of 2026-11), and the updater is Windows-only. `raw_dump` shows it.
- **The meter's HID descriptor** is one vendor interface on usage page 1, usage 0, with
  64-byte input and output reports and no report ID. Don't match on usage page 0xFF00:
  ioreg lists it only as a usage pair, and IOHIDManager matches nothing.
- **swift-testing buffers its output**, and `timeout` leaves `swiftpm-testing-helper`
  running and holding the build lock. If a test hangs, kill that process and run tests
  one at a time with `--filter`.

Prior art read for this: baryluk/fnirsi-usb-power-data-logger (issues 4, 7, 19),
yeckel/OpenFNB58, Randomblock1/fnirsi-usb-tool, deadbeefcafe/fnirsi-usb-tool,
dikeckaan/fnb58-web, manuel-rw/plug-monitor.
