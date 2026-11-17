# fnb58

Reads the FNIRSI FNB58 USB power meter over USB HID, from the command line or as an MCP
server, so an agent can measure what a device draws while something happens.

Verified on an FNB58 with firmware 1.18. Needs macOS 27 and Swift 6.2. Uses only Apple's
frameworks (IOKit's IOHIDManager), plus Swift Argument Parser. No root and no driver detach.

## Install

```
make install     # release -> ~/.local/bin/fnb58
```

## CLI

```
fnb58 status                         # latest V, A, W, D+/D-, temperature
fnb58 capture 15 --label print       # 15 s at 100 samples/s, then a summary
fnb58 stats [file.csv] --from 4 --to 6   # statistics over a window of a saved capture
fnb58 raw --seconds 2                # every report, as hex
fnb58 mcp                            # MCP server over stdio
```

During `capture`, each line typed on standard input becomes a mark at that moment, and
Ctrl-C stops early and still summarizes. Add `--json` for machine-readable output,
`--serial` to choose between meters, and `--dir` for where CSVs go. The default is
`$FNB58_CAPTURE_DIR`, or `~/.local/share/fnb58/captures`. Set `FNB58_DEBUG=1` for a trace
of sends and stream changes.

## MCP

```
claude mcp add --scope user fnb58 -- ~/.local/bin/fnb58 mcp
```

| Tool | What it does |
|------|--------------|
| `status` | Connected or not, the latest reading, the model and firmware, and any running capture. |
| `capture(seconds, label?)` | Blocks for the capture, then returns the summary. |
| `start_capture(label?)` | Starts recording in the background and returns the CSV path. |
| `mark(note)` | Adds a timestamped note to the running capture. |
| `stop_capture()` | Ends the capture and returns the summary. |
| `window_stats(csv?, from_s?, to_s?)` | Summary over a window of a saved capture; the last capture by default. |
| `raw_dump(seconds?, limit?)` | Reports as hex, with counts by type. |

A summary has the duration, current mean, peak (and when), p99 and min, voltage min, max
and mean, power mean and peak, energy in mWh, charge in mAh, marks, warnings, and the CSV
path. A capture cut short by an unplug or a stalled meter comes back as a failed call
that still carries the summary, and the CSV keeps every sample up to then.

CSV columns: `t_s,voltage_V,current_A,power_W,dplus_V,dminus_V,temp_C,mark`. Times are
sample index ÷ 100, never wall clock. A row with only `t_s` and `mark` is a note. A JSON
copy of the summary sits beside each CSV.

## Things to know

- **One client at a time.** The meter has one stream. Don't run the CLI while the MCP
  server is capturing.
- **The meter can wedge.** It then refuses every command, and its screen may freeze, until
  it is replugged. `fnb58` avoids the known causes: see CLAUDE.md.
- **Closing takes about 1.6 s.** The meter keeps streaming for about 1.5 s after the last
  keepalive. Closing earlier leaves its buffer full, which other tools report freezes it,
  so `fnb58` reads until the meter falls silent.
- **The true rate may be 25 samples/s.** Reports come 25 times a second with 4 samples
  each, and the last three are often identical. Others report the same.
