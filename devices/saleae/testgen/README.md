# testgen

ESP8266 firmware that loops over fixed traffic, so a capture can be checked against
exactly what was sent. Logic level is 3.3 V. Board labels are for NodeMCU and D1 mini.

```
make setup    # one time, installs the toolchain under ./arduino/
make flash
```

| Channel | Signal   | GPIO | Label | Expected                                  |
|---------|----------|------|-------|-------------------------------------------|
| 0       | PWM      | 12   | D6    | 1 kHz, 25% duty, software-timed           |
| 1       | Sync     | 16   | D0    | 13-18 us high at the start of each cycle  |
| 2       | UART TX  | 2    | D4    | `TESTGEN UART\n`, 115200 8N1              |
| 3       | SPI CLK  | 14   | D5    | 1 MHz, mode 0, MSB first                  |
| 4       | SPI MOSI | 13   | D7    | `A5 5A 00 FF 12 34`                       |
| 5       | SPI CS   | 15   | D8    | Active low around the frame               |
| 6       | I2C SDA  | 4    | D2    | Write to `0x42`: `DE AD BE EF`, all ACKed |
| 7       | I2C SCL  | 5    | D1    | About 55 kHz, bit-banged                  |

Each cycle sends sync, UART, SPI, then I2C, followed by a 20 ms gap. The firmware
drives the I2C ACK bits itself because the bus has no receiver.
