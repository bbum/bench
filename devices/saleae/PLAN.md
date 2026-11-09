# sal plan

Goal: complete coverage of what Logic 2 can do, plus analysis Saleae's tools do not
offer, exposed through a CLI and an efficient MCP server.

Hardware is an accepted test dependency. The yardstick is complete functionality
coverage: every capability gets a `sal` command and a live test against `testgen`.

Every phase ships with the layers in CLAUDE.md under Testing, and is done when
`make test`, `make verify`, `make coverage` and `make mutation` all pass.

## Done

Foundation: gRPC client, `sal status`, `sal capture` with per-channel summaries, binary
export parser, the `testgen` board, and the test layers. Uses 6 of the 16 RPCs.

## Phase 1: Cancellation

Ctrl-C or task cancellation closes the capture and removes temp files. Must be finished
before an MCP server can start long-running captures.

- Proof: interrupt a live capture, then confirm a new capture runs cleanly.

## Phase 2: Decoders

Run UART, SPI and I2C decoders and return decoded rows inline with paging. Cover every
analyzer setting, not just the defaults.

- Add a `testgen` fault mode with NACKs, framing errors and wrong baud rates, so tests
  prove faults are detected as well as clean traffic decoded.
- Proof: `make verify` compares actual bytes against what `testgen` sent.

## Phase 3: Capture modes

Digital trigger captures, manual start and stop, and glitch filters.

- Proof: trigger on the sync channel and check that traffic follows it. Filter below and
  above a known pulse width.

## Phase 4: Channel identification

Work out what is on each channel so miswired signals can be corrected in software, with
no replugging. Needs phase 2.

- I2C: SDA changes only while SCL is low, apart from start and stop.
- SPI: the clock has regular bursts in multiples of 8 cycles, CS frames them, and data
  changes in step with the clock.
- UART: idles high, and pulse widths are multiples of one bit time, which gives the baud
  rate.
- PWM and clocks: already detected as periodic.
- Confirm candidates by running decoders over the same capture and keeping the wiring
  that decodes cleanly.
- Report confidence and ambiguity. Never pick silently.
- Known limits: timing alone cannot separate MOSI from MISO or UART TX from RX, idle
  lines reveal nothing, and two buses of one type cannot be told apart.
- Proof: relabel the 8 recorded `testgen` channels and test all 40,320 wirings offline.
  Then confirm on real hardware with some jumpers actually swapped.

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
