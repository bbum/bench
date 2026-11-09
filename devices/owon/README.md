# ow

Captures screenshots and waveforms from an Owon SDS-series oscilloscope over LAN, from the
command line or as an MCP server, so an agent can look at real signals while debugging.

Verified on an SDS7102V. The rest of the SDS series is likely to work, but is untested.

## Install

Needs macOS 26 or later and Swift 6.2 or later. It uses only Apple's frameworks, plus
Swift Argument Parser.

```
make install     # builds and copies to ~/.local/bin/ow
```

## Usage

Tell it where the scope is, once:

```
ow config set host 10.0.1.230
```

Then:

```
ow status                     # identify the scope and summarize the current waveform
ow screen out.png             # capture the display, as PNG or BMP from the extension
ow data out.bin               # capture a waveform
ow memdepth out.bin           # capture a deep-memory waveform
ow bin --csv out.bin          # parse a saved capture and write out.csv beside it
```

Commands that talk to the scope take `--host` and `--port` for one-off use. `ow <command> --help` has the
details. Human-readable progress goes to stderr and parseable output to stdout. Set
`OW_DEBUG=1` for connection traces.

## MCP

```json
{
  "mcpServers": {
    "ow": { "command": "/Users/you/.local/bin/ow", "args": ["mcp"] }
  }
}
```

| Tool | What it does |
|------|--------------|
| `scope_status` | Probe and identify the scope. `quick=true` only checks TCP. |
| `capture_screenshot` | Capture the display and return a PNG inline, so a model can see it. |
| `capture_waveform` | Capture and parse. Returns summary statistics by default. `include_samples`, `decimate` and `deep_memory` ask for more. |
| `parse_bin_file` | Parse a saved `.bin` file. Same output as `capture_waveform`. |

`ow mcp scope_status capture_screenshot` enables only the tools you name.

## Things to know

- **Capture only.** The scope does not speak SCPI. There is no way to change its settings
  remotely, only to capture what it is showing.
- **One connection at a time.** Concurrent connections can lock the scope up until it is power
  cycled. `ow` runs requests one after another, but don't run two copies against one scope.
- **The protocol is reverse-engineered.** The vendor documents none of it. See
  [`PROTOCOL.md`](PROTOCOL.md) for the byte-level reference. Three commands are known:
  `STARTBMP`, `STARTBIN` and `STARTMEMDEPTH`, on TCP port 3000.
- **It connects through `/usr/bin/nc`.** That looks odd but is deliberate. On a Mac with two
  interfaces on the same subnet, the scope's network stack answers ARP on only one path, and
  third-party binaries are then refused a route that Apple's entitled tools can use. Launching
  `nc` costs about 5 ms against captures that take hundreds of milliseconds.

## Development

```
swift build
swift test       # parser tests against saved captures in test-data/
```

MIT, see [LICENSE](../../LICENSE).
