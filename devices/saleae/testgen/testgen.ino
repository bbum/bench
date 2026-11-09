// Known-answer signal generator for Saleae bring-up. See README.md for the expected
// capture. Targets a bare ESP8266 board with Wi-Fi off.

#include <ESP8266WiFi.h>
#include <SPI.h>

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
static void IRAM_ATTR uartPin(bool high) {
  if (high) {
    GPOS = 1 << PIN_UART;
  } else {
    GPOC = 1 << PIN_UART;
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

static void useVariant(const Variant &variant) {
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
    if (key == 'c') {
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
  Serial.println("testgen v3 running");
}

void loop() {
  handleCommands();
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
