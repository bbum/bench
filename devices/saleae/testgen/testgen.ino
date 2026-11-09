// Known-answer signal generator for Saleae bring-up. See README.md for the expected
// capture. Targets a bare ESP8266 board with Wi-Fi off.

#include <ESP8266WiFi.h>
#include <SPI.h>
#include <algorithm>
#include <core_esp8266_waveform.h>

static const uint8_t PIN_PWM = 12;
static const uint8_t PIN_SYNC = 16;
static const uint8_t PIN_SDA = 4;
static const uint8_t PIN_SCL = 5;
static const uint8_t PIN_UART = 2;
static const uint8_t SPI_PIN_CLK = 14;
static const uint8_t SPI_PIN_MOSI = 13;
static const uint8_t SPI_PIN_CS = 15;

static const char UART_MESSAGE[] = "TESTGEN UART\n";
// SPIClass::writeBytes reads 32-bit words, so this must be aligned.
alignas(4) static const uint8_t SPI_FRAME[] = {0xA5, 0x5A, 0x00, 0xFF, 0x12, 0x34};
static const uint8_t I2C_ADDRESS = 0x42;
static const uint8_t I2C_FRAME[] = {0xDE, 0xAD, 0xBE, 0xEF};

// Half of a ~100 kHz I2C clock period.
static const uint32_t I2C_HALF_PERIOD_US = 5;
static const uint32_t CYCLE_GAP_MS = 20;

static const uint32_t DEFAULT_UART_BIT_CYCLES = F_CPU / 115200;
static uint32_t uartBitCycles = DEFAULT_UART_BIT_CYCLES;

enum Fault { FAULT_NONE, FAULT_FRAMING_AND_NACK, FAULT_PARITY, FAULT_RANDOM };

struct UartFormat {
  uint8_t bits;
  char parity;  // 'N', 'E' or 'O'
  uint8_t stopHalves;
  bool msbFirst;
  bool inverted;
};

struct SpiFormat {
  bool cpol;
  bool cpha;
  bool msbFirst;
  uint8_t bits;
  bool csActiveHigh;
};

struct Variant {
  char key;
  UartFormat uart;
  SpiFormat spi;
  Fault fault;
};

// Declared here because Arduino generates prototypes above later definitions.
static const uint8_t MAX_SCENARIO_BYTES = 32;

struct ScenarioSignal {
  char kind;
  uint8_t pinA, pinB, pinC, pinD;
  // Microseconds into each cycle at which the signal starts.
  uint32_t offset;
  uint32_t numberA, numberB, numberC;
  bool flagA, flagB, flagC, flagD;
  char parity;
  uint8_t dataLength;
  uint8_t data[MAX_SCENARIO_BYTES];
  uint8_t replyLength;
  uint8_t reply[MAX_SCENARIO_BYTES];
};

// One change of pin levels, at a time counted in CPU cycles from the start of a cycle.
struct ScheduledEdge {
  uint32_t at;
  uint16_t set;
  uint16_t clear;
};

static const UartFormat FORMAT_8N1 = {8, 'N', 2, false, false};
static const SpiFormat FORMAT_SPI_DEFAULT = {false, false, true, 8, false};

// Selected over the USB serial port by sending the key. 'c' restores clean hardware
// traffic. See README.md for what each one sends.
static const Variant VARIANTS[] = {
    {'a', {7, 'N', 4, false, false}, {false, true, true, 8, false}, FAULT_NONE},
    {'b', {8, 'E', 2, false, false}, {true, false, true, 8, false}, FAULT_NONE},
    {'d', {8, 'O', 2, false, false}, {true, true, true, 8, false}, FAULT_NONE},
    {'e', {8, 'N', 3, false, false}, {false, false, false, 8, false}, FAULT_NONE},
    {'g', {8, 'N', 2, true, false}, {false, false, true, 16, false}, FAULT_NONE},
    {'h', {8, 'N', 2, false, true}, {false, false, true, 8, true}, FAULT_NONE},
    {'i', {9, 'N', 2, false, false}, FORMAT_SPI_DEFAULT, FAULT_NONE},
    {'f', FORMAT_8N1, FORMAT_SPI_DEFAULT, FAULT_FRAMING_AND_NACK},
    {'p', {8, 'E', 2, false, false}, FORMAT_SPI_DEFAULT, FAULT_PARITY},
};

static const uint32_t STANDARD_BAUDS[] = {1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800};
static const size_t RANDOM_PAYLOAD_SIZE = 32;
static uint8_t randomPayload[RANDOM_PAYLOAD_SIZE];
static Variant randomVariant = {'r', FORMAT_8N1, FORMAT_SPI_DEFAULT, FAULT_RANDOM};

static const Variant *activeVariant = nullptr;

static void i2cHalfPeriod() {
  delayMicroseconds(I2C_HALF_PERIOD_US);
}

static void i2cStart() {
  digitalWrite(PIN_SDA, LOW);
  i2cHalfPeriod();
  digitalWrite(PIN_SCL, LOW);
  i2cHalfPeriod();
}

static void i2cStop() {
  digitalWrite(PIN_SDA, LOW);
  i2cHalfPeriod();
  digitalWrite(PIN_SCL, HIGH);
  i2cHalfPeriod();
  digitalWrite(PIN_SDA, HIGH);
  i2cHalfPeriod();
}

static void i2cClockBit(bool level) {
  digitalWrite(PIN_SDA, level ? HIGH : LOW);
  i2cHalfPeriod();
  digitalWrite(PIN_SCL, HIGH);
  i2cHalfPeriod();
  digitalWrite(PIN_SCL, LOW);
}

// There is no receiver on this bus, so the generator drives the ACK bit itself.
static void i2cWriteByte(uint8_t value, bool ack = true) {
  for (int bit = 7; bit >= 0; bit--) {
    i2cClockBit((value >> bit) & 1);
  }
  i2cClockBit(!ack);
}

static void sendI2C() {
  i2cStart();
  i2cWriteByte(I2C_ADDRESS << 1);
  for (uint8_t value : I2C_FRAME) {
    i2cWriteByte(value);
  }
  i2cStop();
}

// A write whose last byte is NACKed, then an address nothing answers.
static void sendI2CWithNacks() {
  i2cStart();
  i2cWriteByte(I2C_ADDRESS << 1);
  i2cWriteByte(I2C_FRAME[0]);
  i2cWriteByte(I2C_FRAME[1], false);
  i2cStop();
  delayMicroseconds(50);
  i2cStart();
  i2cWriteByte((I2C_ADDRESS + 1) << 1, false);
  i2cStop();
}

static void sendSPI() {
  SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
  SPI.writeBytes(SPI_FRAME, sizeof(SPI_FRAME));
  SPI.endTransaction();
}

static void sendUART() {
  Serial1.write(reinterpret_cast<const uint8_t *>(UART_MESSAGE), sizeof(UART_MESSAGE) - 1);
  Serial1.flush();
}

// UART bit edges tolerate only a few microseconds, so this runs from RAM with direct
// register writes. A flash fetch would be late enough to corrupt a bit.
static uint8_t uartActivePin = PIN_UART;

static void IRAM_ATTR uartPin(bool high) {
  if (uartActivePin == 16) {
    GP16O = high ? 1 : 0;
  } else if (high) {
    GPOS = 1 << uartActivePin;
  } else {
    GPOC = 1 << uartActivePin;
  }
}

static void IRAM_ATTR uartLevel(const UartFormat &format, bool level, uint32_t &deadline, uint32_t cycles) {
  uartPin(level != format.inverted);
  deadline += cycles;
  while (static_cast<int32_t>(ESP.getCycleCount() - deadline) < 0) {
  }
}

static void IRAM_ATTR uartFrame(const UartFormat &format, uint16_t value, bool goodStop = true, bool goodParity = true) {
  noInterrupts();
  uint32_t deadline = ESP.getCycleCount();
  uartLevel(format, false, deadline, uartBitCycles);
  uint8_t ones = 0;
  for (uint8_t i = 0; i < format.bits; i++) {
    uint8_t index = format.msbFirst ? format.bits - 1 - i : i;
    bool bit = (value >> index) & 1;
    ones += bit;
    uartLevel(format, bit, deadline, uartBitCycles);
  }
  if (format.parity != 'N') {
    bool parity = ((ones & 1) != 0) != (format.parity == 'O');
    uartLevel(format, parity == goodParity, deadline, uartBitCycles);
  }
  uartLevel(format, goodStop, deadline, uartBitCycles * format.stopHalves / 2);
  uartPin(!format.inverted);
  interrupts();
  delayMicroseconds(30);
}

static void sendVariantUART(const Variant &variant) {
  const UartFormat &format = variant.uart;
  if (variant.fault == FAULT_FRAMING_AND_NACK) {
    uartFrame(format, 0x41);
    uartFrame(format, 0x42, false);
    delayMicroseconds(100);
    uartFrame(format, 0x43);
  } else if (variant.fault == FAULT_RANDOM) {
    for (uint8_t value : randomPayload) {
      uartFrame(format, value);
    }
  } else if (variant.fault == FAULT_PARITY) {
    uartFrame(format, 0x44);
    uartFrame(format, 0x45, true, false);
  } else {
    for (size_t i = 0; i < sizeof(UART_MESSAGE) - 1; i++) {
      // The ninth bit marks the first frame, for the address modes.
      uint16_t flag = format.bits == 9 && i == 0 ? 0x100 : 0;
      uartFrame(format, flag | static_cast<uint8_t>(UART_MESSAGE[i]));
    }
  }
}

static void spiHalfPeriod() {
  delayMicroseconds(2);
}

static void spiWord(const SpiFormat &format, uint16_t value) {
  for (uint8_t i = 0; i < format.bits; i++) {
    uint8_t index = format.msbFirst ? format.bits - 1 - i : i;
    bool bit = (value >> index) & 1;
    if (!format.cpha) {
      digitalWrite(SPI_PIN_MOSI, bit ? HIGH : LOW);
      spiHalfPeriod();
      digitalWrite(SPI_PIN_CLK, format.cpol ? LOW : HIGH);
      spiHalfPeriod();
      digitalWrite(SPI_PIN_CLK, format.cpol ? HIGH : LOW);
    } else {
      digitalWrite(SPI_PIN_CLK, format.cpol ? LOW : HIGH);
      digitalWrite(SPI_PIN_MOSI, bit ? HIGH : LOW);
      spiHalfPeriod();
      digitalWrite(SPI_PIN_CLK, format.cpol ? HIGH : LOW);
      spiHalfPeriod();
    }
  }
}

static void sendVariantSPI(const SpiFormat &format) {
  digitalWrite(SPI_PIN_CLK, format.cpol ? HIGH : LOW);
  digitalWrite(SPI_PIN_CS, format.csActiveHigh ? HIGH : LOW);
  spiHalfPeriod();
  if (format.bits == 16) {
    for (size_t i = 0; i + 1 < sizeof(SPI_FRAME); i += 2) {
      spiWord(format, (SPI_FRAME[i] << 8) | SPI_FRAME[i + 1]);
    }
  } else {
    for (uint8_t value : SPI_FRAME) {
      spiWord(format, value);
    }
  }
  spiHalfPeriod();
  digitalWrite(SPI_PIN_CS, format.csActiveHigh ? LOW : HIGH);
}

static void useHardwarePeripherals() {
  Serial1.begin(115200);
  SPI.begin();
  SPI.setHwCs(true);
  activeVariant = nullptr;
}

// Scenarios put any signal on any pin, and any number of them at once. A host chooses
// them and keeps the answer, so analysis of the wires can be scored blind. See
// tools/blind_test.py.
//
// Every signal's edges go onto one timeline, which is then played back against the CPU
// cycle counter with interrupts off. That is what lets signals overlap, and it makes
// their timing exact to a fraction of a microsecond.
static const uint8_t CHANNEL_PINS[8] = {12, 16, 2, 14, 13, 15, 4, 5};
static const uint8_t MAX_SCENARIO_SIGNALS = 8;
static ScenarioSignal scenario[MAX_SCENARIO_SIGNALS];
static uint8_t scenarioCount = 0;
static uint32_t scenarioGapMs = 20;

static const uint32_t CYCLES_PER_US = F_CPU / 1000000;
static const uint16_t MAX_EDGES = 1800;
static ScheduledEdge edges[MAX_EDGES];
static uint16_t edgeCount = 0;
static bool edgesOverflowed = false;
// Noise is drawn afresh each cycle, so a scenario with any is scheduled again each time.
static bool scenarioHasNoise = false;

// GPIO16 has a register of its own. GPIO0 carries no channel, so its bit stands in.
static const uint16_t GPIO16_BIT = 1;

static uint16_t pinBit(uint8_t pin) {
  return pin == 16 ? GPIO16_BIT : static_cast<uint16_t>(1 << pin);
}

static void addEdge(uint32_t at, uint8_t pin, bool high) {
  if (edgeCount == MAX_EDGES) {
    edgesOverflowed = true;
    return;
  }
  ScheduledEdge &edge = edges[edgeCount++];
  edge.at = at;
  edge.set = high ? pinBit(pin) : 0;
  edge.clear = high ? 0 : pinBit(pin);
}

static void stopAllWaveforms() {
  for (uint8_t pin : CHANNEL_PINS) {
    if (pin != 16) {
      stopWaveform(pin);
    }
  }
}

static void scheduleUart(const ScenarioSignal &signal) {
  const uint32_t bit = F_CPU / signal.numberA;
  const bool inverted = signal.flagA;
  uint32_t at = signal.offset * CYCLES_PER_US;
  for (uint8_t i = 0; i < signal.dataLength; i++) {
    uint8_t ones = 0;
    addEdge(at, signal.pinA, inverted);
    at += bit;
    for (uint8_t index = 0; index < 8; index++) {
      bool value = (signal.data[i] >> index) & 1;
      ones += value;
      addEdge(at, signal.pinA, value != inverted);
      at += bit;
    }
    if (signal.parity != 'N') {
      bool parity = ((ones & 1) != 0) != (signal.parity == 'O');
      addEdge(at, signal.pinA, parity != inverted);
      at += bit;
    }
    addEdge(at, signal.pinA, !inverted);
    // Not a whole number of bits to the next frame, as with a real sender.
    at += bit * signal.numberB / 2 + 30 * CYCLES_PER_US;
  }
}

// Data follows the clock edge that moves it by a couple of CPU cycles, as it does out of
// a hardware peripheral. MISO, when wired, sends its own bytes and may be let go to a
// pull-up between transfers. Bytes may be paused apart, which splits the clock into bursts.
static void scheduleSpi(const ScenarioSignal &signal) {
  const bool cpol = signal.flagA, cpha = signal.flagB, csHigh = signal.flagC, released = signal.flagD;
  const uint8_t clockPin = signal.pinA, mosi = signal.pinB, miso = signal.pinC, cs = signal.pinD;
  const uint32_t half = signal.numberA * CYCLES_PER_US;
  uint32_t at = signal.offset * CYCLES_PER_US;
  if (cs != 0xFF) {
    addEdge(at, cs, csHigh);
    if (miso != 0xFF && released) {
      addEdge(at + 4, miso, false);
    }
    at += signal.numberB * CYCLES_PER_US;
  }
  for (uint8_t i = 0; i < signal.dataLength; i++) {
    for (int bit = 7; bit >= 0; bit--) {
      bool out = (signal.data[i] >> bit) & 1;
      bool in = signal.replyLength > 0 && ((signal.reply[i % signal.replyLength] >> bit) & 1);
      uint32_t moves = cpha ? at + half : at;
      if (cpha) {
        addEdge(at + half, clockPin, !cpol);
      }
      addEdge(moves + 2, mosi, out);
      if (miso != 0xFF) {
        addEdge(moves + 4, miso, in);
      }
      if (!cpha) {
        addEdge(at + half, clockPin, !cpol);
      }
      addEdge(at + 2 * half, clockPin, cpol);
      at += 2 * half;
    }
    if (i + 1 < signal.dataLength) {
      at += signal.numberC * CYCLES_PER_US;
    }
  }
  if (cs != 0xFF) {
    at += half;
    addEdge(at, cs, !csHigh);
    if (miso != 0xFF && released) {
      addEdge(at + 4, miso, true);
    }
  }
}

static void scheduleI2cByte(const ScenarioSignal &signal, uint8_t value, uint32_t half, uint32_t hold, uint32_t &at) {
  for (int bit = 8; bit >= 0; bit--) {
    // The ninth bit is the ACK, which the generator drives low itself.
    bool level = bit > 0 && ((value >> (bit - 1)) & 1);
    addEdge(at + hold, signal.pinA, level);
    addEdge(at + half, signal.pinB, true);
    addEdge(at + 2 * half, signal.pinB, false);
    at += 2 * half;
  }
}

static void scheduleI2c(const ScenarioSignal &signal) {
  const uint32_t half = signal.numberA * CYCLES_PER_US;
  // SDA changes a little after SCL falls, as devices are required to allow for.
  const uint32_t hold = std::min<uint32_t>(half / 4, CYCLES_PER_US);
  uint32_t at = signal.offset * CYCLES_PER_US;
  addEdge(at, signal.pinA, false);
  at += half;
  addEdge(at, signal.pinB, false);
  scheduleI2cByte(signal, static_cast<uint8_t>(signal.numberB) << 1, half, hold, at);
  for (uint8_t i = 0; i < signal.dataLength; i++) {
    scheduleI2cByte(signal, signal.data[i], half, hold, at);
  }
  addEdge(at + hold, signal.pinA, false);
  addEdge(at + half, signal.pinB, true);
  addEdge(at + 2 * half, signal.pinA, true);
}

static void schedulePulse(const ScenarioSignal &signal) {
  uint32_t at = signal.offset * CYCLES_PER_US;
  addEdge(at, signal.pinA, !signal.flagA);
  addEdge(at + signal.numberA * CYCLES_PER_US, signal.pinA, signal.flagA);
}

static void scheduleNoise(const ScenarioSignal &signal) {
  uint32_t at = signal.offset * CYCLES_PER_US;
  bool level = signal.flagA;
  for (uint32_t i = 0; i < signal.numberA; i++) {
    level = !level;
    addEdge(at, signal.pinA, level);
    at += (1 + ESP.random() % signal.numberB) * CYCLES_PER_US;
  }
  addEdge(at, signal.pinA, signal.flagA);
}

static void scheduleClockBurst(const ScenarioSignal &signal) {
  const uint32_t half = signal.numberB * CYCLES_PER_US;
  uint32_t at = signal.offset * CYCLES_PER_US;
  for (uint32_t i = 0; i < signal.numberA; i++) {
    addEdge(at, signal.pinA, true);
    addEdge(at + half, signal.pinA, false);
    at += 2 * half;
  }
}

// Returns false if the scenario has more edges than there is room for.
static bool scheduleScenario() {
  edgeCount = 0;
  edgesOverflowed = false;
  for (uint8_t i = 0; i < scenarioCount; i++) {
    const ScenarioSignal &signal = scenario[i];
    switch (signal.kind) {
      case 'u': scheduleUart(signal); break;
      case 's': scheduleSpi(signal); break;
      case 'i': scheduleI2c(signal); break;
      case 'p': schedulePulse(signal); break;
      case 'n': scheduleNoise(signal); break;
      case 'b': scheduleClockBurst(signal); break;
      default: break;
    }
  }
  std::sort(edges, edges + edgeCount, [](const ScheduledEdge &a, const ScheduledEdge &b) { return a.at < b.at; });
  return !edgesOverflowed;
}

// Runs from RAM, because a flash fetch would be late enough to move an edge.
static void IRAM_ATTR playEdges() {
  noInterrupts();
  const uint32_t start = ESP.getCycleCount();
  for (uint16_t i = 0; i < edgeCount; i++) {
    const ScheduledEdge &edge = edges[i];
    while (static_cast<int32_t>(ESP.getCycleCount() - start - edge.at) < 0) {
    }
    const uint16_t set = edge.set & ~GPIO16_BIT, clear = edge.clear & ~GPIO16_BIT;
    if (set) {
      GPOS = set;
    }
    if (clear) {
      GPOC = clear;
    }
    if ((edge.set | edge.clear) & GPIO16_BIT) {
      GP16O = (edge.set & GPIO16_BIT) ? 1 : 0;
    }
  }
  interrupts();
}

static void playScenario() {
  if (scenarioHasNoise) {
    scheduleScenario();
  }
  playEdges();
  delay(scenarioGapMs);
}

static uint8_t hexNibble(char c) {
  return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
}

static uint8_t parseHex(const char *text, uint8_t *out) {
  uint8_t count = 0;
  while (text[0] && text[1] && count < MAX_SCENARIO_BYTES) {
    out[count++] = (hexNibble(text[0]) << 4) | hexNibble(text[1]);
    text += 2;
  }
  return count;
}

static uint8_t channelPin(const char *text) {
  int channel = atoi(text);
  return channel >= 0 && channel < 8 ? CHANNEL_PINS[channel] : 0xFF;
}

// Fields are comma separated, positional, and described with each kind below. OFFSET is
// microseconds into the cycle.
static bool parseScenarioSignal(char *text, ScenarioSignal &signal) {
  char *fields[16];
  uint8_t count = 0;
  char *saved = nullptr;
  for (char *field = strtok_r(text, ",", &saved); field && count < 16; field = strtok_r(nullptr, ",", &saved)) {
    fields[count++] = field;
  }
  if (count < 2) {
    return false;
  }
  memset(&signal, 0, sizeof(signal));
  signal.kind = fields[0][0];
  signal.pinA = channelPin(fields[1]);
  switch (signal.kind) {
    case 'u':  // u,CH,OFFSET,BAUD,PARITY,STOPHALVES,INVERTED,HEX
      if (count != 8) return false;
      signal.offset = atol(fields[2]);
      signal.numberA = atol(fields[3]);
      signal.parity = fields[4][0];
      signal.numberB = atol(fields[5]);
      signal.flagA = fields[6][0] == '1';
      signal.dataLength = parseHex(fields[7], signal.data);
      return signal.numberA > 0;
    case 's':  // s,CLK,MOSI,MISO or -1,CS or -1,OFFSET,CPOL,CPHA,HALFUS,CSHIGH,SETUPUS,PAUSEUS,RELEASED,HEX,REPLYHEX
      if (count != 15) return false;
      signal.pinB = channelPin(fields[2]);
      signal.pinC = channelPin(fields[3]);
      signal.pinD = channelPin(fields[4]);
      signal.offset = atol(fields[5]);
      signal.flagA = fields[6][0] == '1';
      signal.flagB = fields[7][0] == '1';
      signal.numberA = atol(fields[8]);
      signal.flagC = fields[9][0] == '1';
      signal.numberB = atol(fields[10]);
      signal.numberC = atol(fields[11]);
      signal.flagD = fields[12][0] == '1';
      signal.dataLength = parseHex(fields[13], signal.data);
      signal.replyLength = parseHex(fields[14], signal.reply);
      return signal.numberA > 0;
    case 'i':  // i,SDA,SCL,OFFSET,HALFUS,ADDRESS,HEX
      if (count != 7) return false;
      signal.pinB = channelPin(fields[2]);
      signal.offset = atol(fields[3]);
      signal.numberA = atol(fields[4]);
      signal.numberB = strtol(fields[5], nullptr, 16);
      signal.dataLength = parseHex(fields[6], signal.data);
      return signal.numberA > 0;
    case 'w':  // w,CH,HZ,DUTYPERCENT
      if (count != 4) return false;
      signal.numberA = atol(fields[2]);
      signal.numberB = atol(fields[3]);
      return signal.numberA > 0;
    case 'p':  // p,CH,OFFSET,WIDTHUS,IDLEHIGH
      if (count != 5) return false;
      signal.offset = atol(fields[2]);
      signal.numberA = atol(fields[3]);
      signal.flagA = fields[4][0] == '1';
      return true;
    case 'n':  // n,CH,OFFSET,COUNT,MAXUS,IDLEHIGH
      if (count != 6) return false;
      signal.offset = atol(fields[2]);
      signal.numberA = atol(fields[3]);
      signal.numberB = atol(fields[4]);
      signal.flagA = fields[5][0] == '1';
      return signal.numberB > 0;
    case 'b':  // b,CH,OFFSET,PULSES,HALFUS
      if (count != 5) return false;
      signal.offset = atol(fields[2]);
      signal.numberA = atol(fields[3]);
      signal.numberB = atol(fields[4]);
      return true;
    case 'd':  // d,CH,LEVEL
      if (count != 3) return false;
      signal.flagA = fields[2][0] == '1';
      return true;
    default:
      return false;
  }
}

static void applyIdleLevels() {
  for (uint8_t pin : CHANNEL_PINS) {
    pinMode(pin, OUTPUT);
    digitalWrite(pin, LOW);
  }
  scenarioHasNoise = false;
  for (uint8_t i = 0; i < scenarioCount; i++) {
    const ScenarioSignal &signal = scenario[i];
    switch (signal.kind) {
      case 'u': digitalWrite(signal.pinA, signal.flagA ? LOW : HIGH); break;
      case 's':
        digitalWrite(signal.pinA, signal.flagA ? HIGH : LOW);
        if (signal.pinC != 0xFF && signal.flagD) digitalWrite(signal.pinC, HIGH);
        if (signal.pinD != 0xFF) digitalWrite(signal.pinD, signal.flagC ? LOW : HIGH);
        break;
      case 'i':
        digitalWrite(signal.pinA, HIGH);
        digitalWrite(signal.pinB, HIGH);
        break;
      case 'n':
        scenarioHasNoise = true;
        digitalWrite(signal.pinA, signal.flagA ? HIGH : LOW);
        break;
      case 'p':
      case 'd': digitalWrite(signal.pinA, signal.flagA ? HIGH : LOW); break;
      default: break;
    }
  }
  for (uint8_t i = 0; i < scenarioCount; i++) {
    const ScenarioSignal &signal = scenario[i];
    if (signal.kind == 'w') {
      uint32_t period = 1000000UL / signal.numberA;
      uint32_t high = period * signal.numberB / 100;
      startWaveform(signal.pinA, high, period - high, 0);
    }
  }
}

// x, then once "ready" comes back, GAPMS|SIGNAL|SIGNAL... on one line. The line is only
// sent after the reply because it is longer than the UART's own buffer, and a cycle that
// is playing has interrupts off.
static void loadScenario() {
  Serial.println("ready");
  Serial.setTimeout(2000);
  String line = Serial.readStringUntil('\n');
  char *text = line.begin();
  char *saved = nullptr;
  char *field = strtok_r(text, "|", &saved);
  uint32_t gap = field ? atol(field) : 20;
  uint8_t count = 0;
  bool valid = field != nullptr;
  while (valid && (field = strtok_r(nullptr, "|", &saved)) != nullptr) {
    valid = count < MAX_SCENARIO_SIGNALS && parseScenarioSignal(field, scenario[count]);
    count++;
  }
  if (!valid || count == 0) {
    scenarioCount = 0;
    Serial.println("scenario bad");
    return;
  }
  stopAllWaveforms();
  activeVariant = nullptr;
  scenarioCount = count;
  scenarioGapMs = gap;
  applyIdleLevels();
  if (!scheduleScenario()) {
    scenarioCount = 0;
    Serial.println("scenario bad: too many edges");
    return;
  }
  Serial.print("scenario ");
  Serial.print(count);
  Serial.print(" edges ");
  Serial.println(edgeCount);
}

static void leaveScenario() {
  if (scenarioCount == 0) {
    return;
  }
  stopAllWaveforms();
  scenarioCount = 0;
  pinMode(PIN_SYNC, OUTPUT);
  digitalWrite(PIN_SYNC, LOW);
  pinMode(PIN_SDA, OUTPUT);
  pinMode(PIN_SCL, OUTPUT);
  digitalWrite(PIN_SDA, HIGH);
  digitalWrite(PIN_SCL, HIGH);
}

static void useVariant(const Variant &variant) {
  leaveScenario();
  // The PWM interrupt cannot be masked and would disturb bit-banged timing.
  analogWrite(PIN_PWM, 0);
  pinMode(PIN_UART, OUTPUT);
  digitalWrite(PIN_UART, variant.uart.inverted ? LOW : HIGH);
  pinMode(SPI_PIN_CLK, OUTPUT);
  pinMode(SPI_PIN_MOSI, OUTPUT);
  pinMode(SPI_PIN_CS, OUTPUT);
  digitalWrite(SPI_PIN_CS, variant.spi.csActiveHigh ? LOW : HIGH);
  uartBitCycles = DEFAULT_UART_BIT_CYCLES;
  activeVariant = &variant;
}

// Picks a baud rate, format and payload, then reports them so a test can check what a
// blind analysis of the wires concludes. Half the rates are not standard ones.
static void useRandomUart(bool fastest) {
  uint32_t baud = fastest
                      ? 921600
                      : (ESP.random() & 1)
                      ? STANDARD_BAUDS[ESP.random() % (sizeof(STANDARD_BAUDS) / sizeof(STANDARD_BAUDS[0]))]
                      : static_cast<uint32_t>(2400.0 * pow(2.0, (ESP.random() % 770) / 100.0));
  static const char PARITIES[] = {'N', 'E', 'O'};
  randomVariant.uart.parity = PARITIES[ESP.random() % 3];
  randomVariant.uart.stopHalves = (ESP.random() & 1) ? 4 : 2;
  randomVariant.uart.inverted = ESP.random() & 1;
  for (uint8_t &value : randomPayload) {
    value = ESP.random() & 0xFF;
  }
  useVariant(randomVariant);
  uartBitCycles = F_CPU / baud;

  Serial.printf("random baud=%u parity=%c stop=%u inverted=%u data=", baud, randomVariant.uart.parity,
                randomVariant.uart.stopHalves / 2, randomVariant.uart.inverted ? 1 : 0);
  for (uint8_t value : randomPayload) {
    Serial.printf("%02X", value);
  }
  Serial.println();
}

static void handleCommands() {
  while (Serial.available() > 0) {
    char key = static_cast<char>(Serial.read());
    if (key == 'x') {
      loadScenario();
      continue;
    }
    if (key == 'c') {
      leaveScenario();
      useHardwarePeripherals();
      // SPI.begin() takes this pin for MISO, and analogWrite will not take it back.
      pinMode(PIN_PWM, OUTPUT);
      analogWrite(PIN_PWM, 250);
      Serial.println("mode c");
      continue;
    }
    if (key == 'r' || key == 'R') {
      useRandomUart(key == 'R');
      Serial.print("mode ");
      Serial.println(key);
      continue;
    }
    for (const Variant &variant : VARIANTS) {
      if (variant.key == key) {
        useVariant(variant);
        Serial.print("mode ");
        Serial.println(key);
      }
    }
  }
}

static void pulseSync() {
  digitalWrite(PIN_SYNC, HIGH);
  delayMicroseconds(10);
  digitalWrite(PIN_SYNC, LOW);
}

void setup() {
  WiFi.mode(WIFI_OFF);
  WiFi.forceSleepBegin();

  // Scenario lines arrive while traffic is being bit-banged with interrupts held off.
  Serial.setRxBufferSize(1024);
  Serial.begin(115200);

  pinMode(PIN_SYNC, OUTPUT);
  digitalWrite(PIN_SYNC, LOW);
  pinMode(PIN_SDA, OUTPUT);
  pinMode(PIN_SCL, OUTPUT);
  digitalWrite(PIN_SDA, HIGH);
  digitalWrite(PIN_SCL, HIGH);

  useHardwarePeripherals();

  analogWriteRange(1000);
  analogWriteFreq(1000);
  analogWrite(PIN_PWM, 250);

  Serial.println();
  Serial.println("testgen v5 running");
}

void loop() {
  handleCommands();
  if (scenarioCount > 0) {
    playScenario();
    return;
  }
  pulseSync();
  if (activeVariant == nullptr) {
    sendUART();
    sendSPI();
    sendI2C();
  } else {
    sendVariantUART(*activeVariant);
    sendVariantSPI(activeVariant->spi);
    if (activeVariant->fault == FAULT_FRAMING_AND_NACK) {
      sendI2CWithNacks();
    } else {
      sendI2C();
    }
  }
  delay(CYCLE_GAP_MS);
}
