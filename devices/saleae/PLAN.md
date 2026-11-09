# sal plan

Goal: complete coverage of what Logic 2 can do, plus analysis Saleae's tools do not
offer, exposed through a CLI and an efficient MCP server.

Hardware is an accepted test dependency. The yardstick is complete functionality
coverage: every capability gets a `sal` command and a live test against `testgen`.

Every phase ships with the layers in CLAUDE.md under Testing, and is done when
`make test`, `make verify` and `make coverage` all pass. `make mutation` is slow, so it
runs on demand rather than every phase.

## Done

Foundation: gRPC client, `sal status`, `sal capture` with per-channel summaries, binary
export parser, the `testgen` board, and the test layers.

Phase 1, cancellation: Ctrl-C, SIGTERM or task cancellation stops and closes the capture
and removes temp files.

Phase 2, decoders: `sal decode uart|spi|i2c` with every analyzer setting, paged rows, and
issue counts. `testgen` selects each format and fault over USB serial. Logic 2 flags
framing and parity errors but reports nothing for a wrong baud rate, so phase 4 has to
work that out from timing.

Phase 3, capture modes: digital triggers with pulse widths and linked channels, manual
capture, glitch filters, trim and the buffer limit, on both `capture` and `decode`.

Phase 4, channel identification: `sal identify` names each bus from timing, then confirms
it with Logic 2's decoders on the same capture. All 40,320 relabelings of the recorded
channels are identified offline, `testgen`'s random mode checks UART blind, and a run
with three pairs of probes physically swapped was identified correctly.

Phase 5, analog: `sal capture --analog` records analog alone or with digital, on the same
channels if wanted, and reports levels, frequency and duty.

Phase 6, files and exports: `--save` and `--load` on every capturing command, raw CSV,
data table and legacy exports, and high level analyzers. Saving and reloading gives an
identical summary, and Logic 2's own CSV matches the binary parser. Uses 14 of the 16
RPCs. The two left remove an analyzer, which a capture that closes when done never needs.

Phase 7, MCP server: `sal mcp` offers `status`, `capture`, `decode` and `identify`, using
the CLI's own parsing. Its tool list is about 10 KB against 168 KB for Saleae's server.
Cancellation reaches a running capture, and a closed client cannot leave one running.

Phase 8, cross-channel analysis: `sal analyze latency`, `setup-hold` and `activity`, also
offered as the `analyze` MCP tool. They give delays between edges, data timing around a
clock, and when each channel is busy.

Timeline: `sal timeline` and the `timeline` MCP tool show what channels did over a window,
with analog and decoded data lined up, and draw HTML or SVG straight from the data.

## Next

Grow the analysis from real debugging sessions. Once a few reports exist, write a small
skill for choosing windows and writing up findings. The drawing stays in `sal`, so an
LLM directs the tool but never draws a waveform itself.

## Not scheduled

- Report the schema problems to Saleae at https://contact.saleae.com.
- Testing other Saleae devices, once there is one to test.
