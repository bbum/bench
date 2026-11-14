# testgen

ESP32-S3 firmware that loops over fixed traffic, so a capture can be checked against
exactly what was sent. Logic level is 3.3 V. The board is an ESP32-S3 DevKitC-1 (clone),
plugged in by the port labelled USB, the native one, not COM. Its RGB LED breathes through
the colours while it runs. The ESP8266 version is in git history before firmware v6.

```
make setup    # one time, installs the toolchain under ./arduino/
make flash
```

`./port` finds the board by its USB serial number, which is its MAC, so other Espressif
boards such as the knob are never opened. A new board's MAC goes in `boards`. The ROM
shows it as soon as the board is in download mode. A board running other firmware may need
BOOT held while RST is tapped for its first flash, and then RST alone afterwards.

All eight channels are side by side on the left header (USB ports at the bottom), from
the fourth pin down. Connect a Logic ground to any GND pin.

| Channel | Signal   | GPIO | Expected                                  |
|---------|----------|------|-------------------------------------------|
| 0       | PWM      | 4    | 1 kHz, 25% duty, hardware LEDC            |
| 1       | Sync     | 5    | 13-18 us high at the start of each cycle   |
| 2       | UART TX  | 6    | `TESTGEN UART\n`, 115200 8N1              |
| 3       | SPI CLK  | 7    | 1 MHz, mode 0, MSB first                  |
| 4       | SPI MOSI | 15   | `A5 5A 00 FF 12 34`                       |
| 5       | SPI CS   | 16   | Active low around the frame               |
| 6       | I2C SDA  | 17   | Write to `0x42`: `DE AD BE EF`, all ACKed |
| 7       | I2C SCL  | 18   | Bit-banged, 5 us half periods plus overhead |

Each cycle sends sync, UART, SPI, then I2C, followed by a 20 ms gap. The firmware
drives the I2C ACK bits itself because the bus has no receiver.

## Modes

Sending one character over USB serial at 115200 selects a mode, and the board replies
`mode <key>`. Opening the port usually resets the board to `c`, but closing it does not, so
send `c` when done. Modes other than `c` bit-bang UART and SPI, send the same bytes as above,
and stop the PWM.

| Key | UART                                 | SPI                     | I2C                        |
|-----|--------------------------------------|-------------------------|----------------------------|
| `c` | 8N1, hardware                        | Mode 0, hardware        | Clean                      |
| `a` | 7 data bits, 2 stop bits             | Mode 1                  | Clean                      |
| `b` | 8E1                                  | Mode 2                  | Clean                      |
| `d` | 8O1                                  | Mode 3                  | Clean                      |
| `e` | 8N, 1.5 stop bits                    | LSB first               | Clean                      |
| `g` | 8N1, MSB first                       | 16-bit words            | Clean                      |
| `h` | 8N1, inverted                        | Enable active high      | Clean                      |
| `i` | 9 data bits, ninth set on first only | Mode 0                  | Clean                      |
| `f` | 8N1: `41`, `42` with a bad stop, `43`| Mode 0                  | `AD` NACKed, then `0x43` unanswered |
| `p` | 8E1: `44`, `45` with wrong parity    | Mode 0                  | Clean                      |
| `r` | Random baud, parity, stop bits, inversion and 32 bytes | Mode 0 | Clean                |

`x` plays a scenario, which puts any signal on any pin, several at once. See below.

`r` first replies with the choices, as `random baud=57600 parity=E stop=2 inverted=1 data=<hex>`,
so a test can compare them with what a blind analysis of the wires concludes. `R` is the
same at a nominal 921600 baud. The bit-banged signal jitters by up to a quarter of a bit
there. Its rate is within 0.1% of nominal, but every low pulse is about 36 ns long, so an
average of pulse widths reads it 2% slow.

## Scenarios

`x` puts the board into scenario mode. It answers `ready`, and then takes one line:

```
GAPMS|SIGNAL|SIGNAL|...
```

Every signal's edges go onto one timeline, which is played against the CPU cycle counter
with interrupts off, so signals overlap and their timing is exact to a fraction of a
microsecond. A cycle plays the timeline and then waits `GAPMS`. The board answers
`scenario N edges M`, or `scenario bad` if a field is wrong or there are more than 1800
edges. `tools/blind_test.py` writes these lines and keeps the answers, so
`make blind ARGS="--runs 40"` scores `sal identify` blind.

Fields are comma separated and positional. Channels are 0 to 7, or -1 for a line that is
not wired. `OFFSET` is microseconds into the cycle at which the signal starts.

| Signal | Fields |
|--------|--------|
| UART | `u,CH,OFFSET,BAUD,PARITY,STOPHALVES,INVERTED,HEX` |
| SPI | `s,CLK,MOSI,MISO,CS,OFFSET,CPOL,CPHA,HALFUS,CSHIGH,SETUPUS,PAUSEUS,RELEASED,HEX,REPLYHEX` |
| I2C | `i,SDA,SCL,OFFSET,HALFUS,ADDRESS,HEX` |
| PWM | `w,CH,HZ,DUTYPERCENT` |
| Pulse | `p,CH,OFFSET,WIDTHUS,IDLEHIGH` |
| Noise | `n,CH,OFFSET,COUNT,MAXUS,IDLEHIGH` |
| Clock burst | `b,CH,OFFSET,PULSES,HALFUS` |
| Idle | `d,CH,LEVEL` |

SPI data moves a few CPU cycles after the clock edge that shifts it, as it does out of a
peripheral. `SETUPUS` is how long the enable is asserted before the clock starts, and
`PAUSEUS` an idle stretch between bytes. MISO sends `REPLYHEX`, and with `RELEASED` it is
driven low while enabled and high otherwise, like a line let go to a pull-up. I2C's SDA
changes a quarter of a half period after SCL falls, at most 1 us. Noise is drawn afresh
each cycle. PWM runs from the LEDC hardware throughout and disturbs nothing else. Interrupts come
back on whenever the next edge is over 1 ms away, because the interrupt watchdog would
fire after 300 ms without them.
