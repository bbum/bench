# sal

Drives Saleae logic analyzers from the command line or as an MCP server: capture digital and
analog, decode UART, SPI and I2C, work out what is wired to each channel, measure timing, and
draw timelines. Tested on a Logic Pro 8 with Logic 2.4.48.

## Install

Needs macOS 27 and Swift 6.2 or later, plus [Logic 2](https://www.saleae.com/downloads/).
`sal` starts Logic 2 itself when it is not running, in the background and with its automation
server on, then connects to `127.0.0.1:10430`. Every command takes `--host` and `--port` to use
another address, and `--no-launch` to leave starting Logic 2 to you. `SAL_NO_LAUNCH=1` in the
environment does the same for every command.

```
make install     # builds and copies to ~/.local/bin/sal
sal status
```

## Commands

| Command | What it does |
|---------|--------------|
| `sal status` | Show the Logic 2 version, connected devices, and how much memory Logic 2 is using. |
| `sal app start\|stop\|restart` | Start, quit or restart Logic 2. |
| `sal capture` | Capture and summarize each channel: frequency, duty, pulse widths, analog levels. |
| `sal identify` | Work out what is on each channel, including UART baud rates. |
| `sal decode uart\|spi\|i2c` | Decode a bus into rows, with counts of framing errors, parity errors, NACKs and SPI clock errors. |
| `sal analyze latency\|setup-hold\|activity` | Measure timing across channels. |
| `sal timeline` | Show activity over a time window, or draw it as HTML or SVG. |
| `sal mcp` | Run as an MCP server over stdio. |

Run `sal <command> --help` for every option. Most take `--json`.

### Don't know the wiring? Ask

```
$ sal identify
UART  signal=2  confirmed: pulse widths are multiples of 8.675 us, 311 frames decoded cleanly
  sal decode uart --channel 2 --baud 115200
SPI  clock=3 enable=5 mosi=4  confirmed: 25 clock bursts in multiples of 8, data in step, 150 words decoded
  sal decode spi --clock 3 --mosi 4 --enable 5
I2C  scl=7 sda=6  confirmed: 25 transactions of whole 9-clock bytes, 25 addresses decoded
  sal decode i2c --sda 6 --scl 7
CH0  1000.17 Hz, 25.05% duty
CH1  45.21 Hz, 0.06% duty
```

The printed commands are ready to run, and also work as timeline overlays.

### Decode a bus

```
$ sal decode uart --channel 2 --baud 115200 --limit 3
0.00607674  data  data="0x41"
0.00619476  data  data="0x42"  error="framing"
0.00641352  data  data="0x43"
Rows 1-3 of 24, issues: framing: 8
```

Issue counts always cover every row, so paging cannot hide a fault. Every setting Logic 2's
analyzers offer is available, including parity, stop bits, SPI mode and address modes.

### Capture when something happens

Every capturing command shares the same options:

```
sal capture --trigger 1:rising --duration 0.05                # time zero is the trigger
sal capture --trigger 5:low --pulse-min 30us --pulse-max 70us # only pulses in that range
sal capture --trigger 1:rising --link 5:high                  # only while CH5 is high
sal capture --manual                                          # run until Ctrl-C, keep the data
sal capture --glitch 2:1us                                    # ignore pulses under 1 us
sal capture --channels none --analog 0-1                      # analog only
```

Saved captures work anywhere a live one does, with no hardware attached:

```
sal capture --save board.sal
sal decode i2c --sda 6 --scl 7 --load board.sal
sal identify --load board.sal
```

Decode can also run [high level analyzers](https://support.saleae.com/extensions/high-level-analyzers)
with `--hla` and export Logic 2's CSV formats. Capture can export raw CSV.

### Measure timing

```
$ sal analyze latency --from 1:rising --to 1:falling          # a pulse's width
min 13.400 us, max 13.400 us, mean 13.400 us, stddev 0 ns, 19 samples

$ sal analyze setup-hold --clock 3:rising --data 4 --rate 250M --min-setup 100ns
CH4 setup: min 496 ns, max 500 ns, mean 500 ns, stddev 1 ns, 408 samples
CH4 hold: min 500 ns, max 504 ns, mean 500 ns, stddev 1 ns, 391 samples

$ sal analyze activity --gap 200us
CH2  5.17% busy, 17 bursts of 1.119 ms on average, longest idle 21.005 ms
```

### Draw a timeline

```
sal timeline --trigger 1:rising --duration 0.004 --from 0 --to 1.25ms \
  --overlay "uart --channel 2 --baud 115200" --radix ascii \
  --html cycle.html --title "One cycle"
```

The output is drawn directly from the capture, with decoded bytes lined up beneath their
signal and protocol errors in red. It's a self-contained page that follows light and dark mode.

## MCP

```json
{
  "mcpServers": {
    "sal": { "command": "/Users/you/.local/bin/sal", "args": ["mcp"] }
  }
}
```

Add `"--port", "10431"` or `"--host", "..."` to `args` if Logic 2 isn't at its default address.
A tool call can also pass `host` and `port` for itself.

Six tools: `status`, `capture`, `decode`, `identify`, `analyze` and `timeline`. They go through
the same parser as the command line, so they accept the same things and fail the same way.

- **Small.** The tool list is about 10 KB. Saleae's own server sends 168 KB, because it repeats
  a 10.6 KB schema block in every tool, and it returns data only as files on disk.
- **Inline results.** Rows are paged and timelines are thinned to a sensible size. Files are only
  written when asked for.
- **Safe to interrupt.** The server keeps reading while a capture runs, so a cancellation reaches
  it. Captures stop and close, temp files go, and a client that disconnects can't leave one
  running. Calls run one at a time, because Logic 2 runs one capture at a time.

## When Logic 2 hangs

Logic 2 can run out of memory under automation. Work on a capture swells its window process by a
gigabyte or more for a while, and a capture that is never closed stays in memory. After 518
captures in 23 hours it had reached 5.8 GB and stopped answering, while still accepting
connections. `sal` plans for that:

- **A health check first.** Every command asks Logic 2 a trivial question before giving it work.
  A Logic 2 that is not running and one that has hung are told apart and reported within 5
  seconds, each with the command that fixes it.
- **A limit on every call.** Calls that change state get 30 seconds and calls that move data get
  5 minutes. A timed capture gets its own length plus 30 seconds. Nothing waits forever.
- **`sal status` weighs it.** It prints Logic 2's memory and uptime, and every command warns once
  that passes 3 GB.
- **`sal app restart`** quits Logic 2, kills it if it will not go, and starts it again.
  `--if-needed` does so only when Logic 2 is hung or over 3 GB. The blind test runs that between
  scenarios, and restarts once more if a scenario finds Logic 2 hung.

A hung Logic 2 is never restarted unasked, because captures open in it are lost.

## How identification works

`sal identify` captures every channel, then looks only at when each edge happened. Channels are
tried in order of how strict the test is, and each channel can only be claimed once. The quiet
before a channel's first edge and after its last counts as evidence too: it shows the idle
level, and it tells a transfer the capture window cut in half from a whole one.

**I2C** looks at every pair of lines that rest high. SDA falling while SCL is high is a start,
and SDA rising while SCL is high is a stop. Between them, a transaction must have a whole number
of 9-clock bytes, plus the one SCL rise of the stop itself, and SDA must actually change while
SCL is low. That last rule matters, because an SPI enable line around a clock that idles high
makes identical start and stop shapes, but never moves in between. SDA itself cannot be periodic,
or two PWMs could pass as a bus. When SDA changes in the very sample SCL falls, which a low
sample rate makes common, that is data, since starts and stops keep clear of SCL edges.
Transactions the window cuts are not counted at all, and 80% of the rest must fit.

**SPI** looks for a clock: a regular period, though not necessarily 50% duty, split into bursts
wherever a gap exceeds 4 times the median spacing, with whole bursts being multiples of 8 pulses.
Bursts the window cuts say nothing either way, so one transfer alone is enough, and a pause of a
clock period or so between bytes is allowed for. Around the bursts:
- The **enable** holds one level through every burst and never moves inside one. Between bursts
  it either stays put or lets go and is asserted again, and it is let go for longer than it is
  held with no clock running. How long before the clock it is asserted does not matter. A line
  that merely pulses between transfers, or a UART that logs each one, fails these.
- **Data** lines change during bursts, each time after the same clock edge and by the same
  delay. A line that only ever changes between bytes, as chip select and a display's D/C line
  do, is reported as a control line instead.
- **CPOL** is the clock's resting level.
- **CPHA** comes from which clock edge the data changes after.

**UART** starts by finding one bit's duration: the shortest width that repeats often enough that
a stray glitch cannot pose as a bit. The bit time is then the slope of a line fitted through
pulse width against bit count, because an edge that is slow one way adds the same skew to every
pulse, and a plain ratio would count that as bit time.
- A line whose edges keep step with another channel's clock is clocked data, whatever its pulse
  widths look like, and is not a UART.
- Only pulses **away from idle** have to be whole numbers of bits. A pause between frames can be
  any length.
- Multi-bit pulses must really occur, at least two and one in twenty, which rules out a bare
  clock even when an interrupt has stretched a pulse or two.
- A run too long for any frame rules the channel out.
- The result gives the baud rate, snapped to a standard value only within 2%. The idle level
  gives the polarity.

**What's left** is reported as periodic with its frequency and duty, idle with its level, or
unidentified.

**Confirmation** then runs Logic 2's own decoder on the same capture. UART timing cannot show
parity, so `sal` tries each parity, and each polarity if needed. It keeps the first that decodes
cleanly, or the best one if at most 5% of frames have errors, since a real line can spoil a few.
A capture that opens mid-frame decodes wrongly until the next gap longer than a frame, so
confirmation ignores those rows, and the last row, which the window can cut short. At least 4
frames must be left to check: the wrong parity gets through one frame in two, so fewer could
pass by luck, and then the bus keeps the confidence timing gave it, with a note. SPI needs 4
words and no error rows, which is how Logic 2 reports a clock resting at the wrong level. I2C
needs an address. The evidence says how much was decoded.

### What it cannot tell you

Reported as notes, never guessed silently:

- MOSI from MISO, and UART TX from RX. They look the same.
- Word size, stop bits and bit order. They don't show in timing.
- Which of two identical buses is which.
- Anything about an idle line.
- Clocked data with no pause in the clock to frame it, such as a capture that sits inside one
  long transfer. It is reported as clocked, and the clock as periodic.

**"Confirmed" means the decoder agreed with at least four frames, not that the bytes are right.**
7-bit UART can confirm as 8-bit with wrong values. A UART whose data has no multi-bit pulses, and
an I2C transaction of address 0 with all-zero data, are too featureless to identify.

## How the measurements work

**Captures** never go through a text format. Logic 2 writes its binary export to a temp directory
and `sal` memory-maps it, validating every field and that edge times strictly increase. A capture
is closed on every path, including failures and cancellation, because Logic 2 holds it in memory
until then.

**Latency** pairs each start edge with the first matching edge after it and before the next start.
A start with no partner is counted, not dropped. The same channel with opposite edges gives pulse
width.

**Setup and hold** measure, around each clock edge, how long since the data last changed and until
it next changes. Only changes within one clock period count, so idle gaps don't skew the numbers.

**Activity** groups edges no further apart than `--gap` into bursts. Pick a gap larger than the
spacing inside what you consider one burst.

**Timelines** give each channel exact low and high segments. When there are more edges than the
limit, runs of pulses too short to see merge into active spans with exact start and end times and
an edge count. Anything long enough to see stays exact, so activity can't vanish. Analog keeps the
min and max of each step, so spikes survive. Drawn files always use full detail, even when the
data returned to an agent is thinned.

**Analog** summaries find two levels by averaging samples either side of the midpoint. Frequency
and duty come from threshold crossings with 10% hysteresis, so noise cannot add edges. A swing
under 0.2 V is treated as a steady level. Mixed captures accept only certain rate pairs, so `sal`
defaults to 6.25 MS/s digital with 1.5625 MS/s analog, and Logic 2's error lists the valid ones.

## How it is tested

Instrument tools are only useful if you can trust them, so this is tested the way SQLite is.

| Layer | What it checks | Run with |
|-------|----------------|----------|
| Fuzzing and corrupt input | Every truncation, hostile values in every field, seeded random bytes. Must reject or summarize, never crash. | `make test` |
| Independent oracles | Summaries, timing and CSV parsing checked against separately written calculations. | `make test` |
| Fault injection | Every Logic 2 call fails, alone and in combination, and when cancelled at each step. Captures must close and temp files must go. | `make test` |
| Exhaustive wiring | All 40,320 ways of wiring 8 recorded channels are identified correctly. | `make test` |
| Known answers on hardware | Live captures of [`testgen`](testgen), an ESP8266 that generates exact traffic and faults. | `make verify` |
| Second oracle | Logic 2's own CSV must match the binary parser on every edge and sample. | `make verify` |
| Coverage | Region coverage of hand-written code, including hardware tests. | `make coverage` |
| Mutation | Injects bugs one at a time into a copy of the source, and the tests must catch each. It is slow, so run it on demand. | `make mutation` |
| Blind test | Random signals on all 8 pins, scored against an answer key `sal` never sees. | `make blind` |

### The blind test

`tools/blind_test.py` generates random scenarios from a seed and tells `testgen` to play them:
UART at random rates and formats, SPI in every mode with and without an enable, with MISO, with
bytes paused apart and the enable asserted early, I2C, PWM, pulses, noise, bare clock bursts
including ones that are whole bytes long, and idle lines, shuffled across the pins. In three
scenarios out of four the signals overlap in time, as buses on a real board do. `sal identify`
then gets only the wires, and is scored in full detail, so a UART with the wrong parity doesn't
count as right.

```
make blind ARGS="--runs 100 --seed 12"                      # record and score
python3 -I tools/blind_test.py --seed 12 --replay           # re-score, no board needed
```

Every capture is kept in `.blind/seed-N` with its answer key beside it. Scoring a saved capture
is repeatable, so a change to the analysis can be checked in minutes without the hardware, and
the key is a file rather than something worked out again from the seed, so old captures stay
scoreable when the scenarios change.

Two sets of 100 scenarios are kept. Seed 7 is the earlier firmware's signals, bit-banged and
played one after another: 605 of 605 signals right. Seed 12 is the current firmware's, exact
and overlapping: 586 of 590, with every signal right in 97 scenarios. The three that are not:

- An odd-parity UART whose six bytes all had a parity bit of 1. That is a clean 8N1 stream with
  an extra stop bit, and nothing in the capture says otherwise.
- A pulse that happened to go high 240 us before every SPI transfer and low 68 us after it, which
  was taken for an active-high enable. By timing, that is what an enable is.
- A UART at 115200 beside two PWMs. The board's waveform interrupt delays edges by up to 8 us,
  most of a bit at that rate, and `sal` rightly reported the decode as uncertain. Scenarios now
  keep UART at or under 57600 when PWM is present.

The test hardware is `testgen`, whose signals have limits of their own. Its bit-banged 921600
baud mode jitters by up to a quarter of a bit, and every low pulse is about 36 ns long, which an
average of pulse widths reads as 2% slow.

## Development

```
swift build
make test        # offline, about 40 seconds
make verify      # live, needs Logic 2 and testgen on USB
make proto       # regenerate the gRPC code, needs protoc
```

`sal` uses `grpc-swift` because Logic 2's server speaks cleartext HTTP/2, which neither
`URLSession` nor Network.framework can do directly. Why it's built this way, and the
surprises found along the way, are in [`CLAUDE.md`](CLAUDE.md). What's next is in
[`PLAN.md`](PLAN.md).

MIT, see [LICENSE](../../LICENSE).
