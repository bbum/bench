# bench

Command line tools and MCP servers that let you, or an AI agent, work with real lab
instruments: capture signals, decode buses, and measure what hardware is actually doing.

The rule throughout is that **precise tools do the measuring and the LLM provides the
direction**. An agent decides what to look at. The numbers, decoded bytes and drawings all
come from deterministic code working on real captures, so they can be checked and repeated.

| Tool | Hardware | What it does |
|------|----------|--------------|
| [`sal`](devices/saleae) | Saleae logic analyzers, tested on the Logic Pro 8 | Capture digital and analog, decode UART, SPI and I2C, work out what is wired to each channel, measure timing, draw timelines |
| [`ow`](devices/owon) | Owon SDS oscilloscopes, tested on the SDS7102V | Capture the display and waveforms over LAN, and parse saved captures |

Each is a single macOS binary that works from the command line and as an MCP server over
stdio. Run builds and tests from the tool's own directory.

## Highlights

- **Figure out the wiring.** `sal identify` works out which channel is SDA, which is the SPI
  clock, and what baud a UART runs at, from timing alone. It then proves its guess by decoding
  the same capture, and says plainly what timing cannot show.
- **Replies an agent can use.** `sal`'s MCP tools describe themselves in about 10 KB, against
  168 KB for Saleae's own server, and return data inline instead of pointing at files.
- **Drawings from data.** `sal timeline` writes HTML or SVG straight from the capture, with
  decoded bytes lined up under the signal. No model draws a waveform.
- **Scope access without a vendor API.** Owon's network protocol is undocumented, so `ow`
  is built on a [reverse-engineered description of it](devices/owon/PROTOCOL.md).
- **Tested against real signals.** `sal`'s tests include an ESP8266 known-answer generator, a
  blind test that puts random signals on every pin, and SQLite-style fuzzing, fault injection
  and mutation testing. See [how it is tested](devices/saleae/README.md#how-it-is-tested).

## Layout

```
devices/
  owon/     ow: Owon SDS oscilloscopes
  saleae/   sal: Saleae logic analyzers
    testgen/   ESP8266 firmware that generates known signals to test against
```

MIT, see [LICENSE](LICENSE).
