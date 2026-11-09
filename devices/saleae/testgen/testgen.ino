// Known-answer signal generator for Saleae bring-up. See README.md for the expected
// capture. Targets a bare ESP8266 board with Wi-Fi off.

#include <ESP8266WiFi.h>
#include <SPI.h>

static const uint8_t PIN_PWM = 12;
static const uint8_t PIN_SYNC = 16;
static const uint8_t PIN_SDA = 4;
static const uint8_t PIN_SCL = 5;

static const char UART_MESSAGE[] = "TESTGEN UART\n";
// SPIClass::writeBytes reads 32-bit words, so this must be aligned.
alignas(4) static const uint8_t SPI_FRAME[] = {0xA5, 0x5A, 0x00, 0xFF, 0x12, 0x34};
static const uint8_t I2C_ADDRESS = 0x42;
static const uint8_t I2C_FRAME[] = {0xDE, 0xAD, 0xBE, 0xEF};

// Half of a ~100 kHz I2C clock period.
static const uint32_t I2C_HALF_PERIOD_US = 5;
static const uint32_t CYCLE_GAP_MS = 20;

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
static void i2cWriteByte(uint8_t value) {
  for (int bit = 7; bit >= 0; bit--) {
    i2cClockBit((value >> bit) & 1);
  }
  i2cClockBit(false);
}

static void sendI2C() {
  i2cStart();
  i2cWriteByte(I2C_ADDRESS << 1);
  for (uint8_t value : I2C_FRAME) {
    i2cWriteByte(value);
  }
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

static void pulseSync() {
  digitalWrite(PIN_SYNC, HIGH);
  delayMicroseconds(10);
  digitalWrite(PIN_SYNC, LOW);
}

void setup() {
  WiFi.mode(WIFI_OFF);
  WiFi.forceSleepBegin();

  Serial.begin(115200);
  Serial1.begin(115200);

  pinMode(PIN_SYNC, OUTPUT);
  digitalWrite(PIN_SYNC, LOW);
  pinMode(PIN_SDA, OUTPUT);
  pinMode(PIN_SCL, OUTPUT);
  digitalWrite(PIN_SDA, HIGH);
  digitalWrite(PIN_SCL, HIGH);

  SPI.begin();
  SPI.setHwCs(true);

  analogWriteRange(1000);
  analogWriteFreq(1000);
  analogWrite(PIN_PWM, 250);

  Serial.println();
  Serial.println("testgen v1 running");
}

void loop() {
  pulseSync();
  sendUART();
  sendSPI();
  sendI2C();
  delay(CYCLE_GAP_MS);
}
