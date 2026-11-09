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
export parser, the `testgen` board, and the test layers. Uses 9 of the 16 RPCs.

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

## Phase 5: Analog

Analog capture, and analog with digital on the same channels.

- Proof: PWM on analog reads about 0 V and 3.3 V at the expected duty.

## Phase 6: Files and remaining exports

Save and load `.sal` files, CSV, data table and legacy exports, and high-level analyzers.

- Proof: save and reload gives an identical summary. Logic 2's own CSV acts as a second
  oracle for the binary parser.

## Phase 7: MCP server

Our own server over the same functions as the CLI: a small tool list, real enums and
`oneOf`, and results returned inline. Can move earlier if an agent needs `sal` sooner.

- Proof: the same known answers through the MCP interface. Measure the tool list size
  against Saleae's 168 KB.

## Phase 8: Cross-channel analysis

Latency between channels, setup and hold times, and bus activity. Grow this from real
debugging sessions.

## Not scheduled

- Rename the repo to `bench`, at any commit point. Covers `~/Developer/ow`, the GitHub
  repo, `origin`, the Roost project entry and the Claude memory folder.
- Report the schema problems to Saleae at https://contact.saleae.com.
- Testing other Saleae devices, once there is one to test.
