#include <Arduino.h>
#include <ArduinoJson.h>
#include <DHT.h>
#include <TinyGPSPlus.h>
#include <Wire.h>
#include <Adafruit_ADXL345_U.h>
#include <Adafruit_Sensor.h>

#include <MinervaFrame.h>

namespace {

// Pinagem obtida do esquema azimutal. ADXL345 usa I2C real do Mega: SDA 20/SCL 21.
constexpr uint8_t kLm35Pin = A0;
constexpr uint8_t kCurrentPin = A3;
constexpr uint8_t kVoltagePin = A4;
constexpr uint8_t kDhtPin = 22;
constexpr uint8_t kWaterPin = 23;
constexpr uint32_t kTelemetryIntervalMs = 500;

// Calibrar contra multimetro e fonte de corrente antes do ensaio.
constexpr float kAdcReferenceV = 5.0F;
constexpr float kVoltageDividerRatio = 5.0F;
constexpr float kAcsZeroV = 2.5F;
constexpr float kAcsSensitivityVPerA = 0.185F;  // ACS712-5A; alterar para o modulo usado.
constexpr float kCriticalBatteryV = 10.8F;

const char kBoatId[] = "azimutal-01";

DHT dht(kDhtPin, DHT11);
TinyGPSPlus gps;
Adafruit_ADXL345_Unified accelerometer(34501);
bool accelerometerReady = false;
uint32_t sequenceNumber = 0;
uint32_t lastTelemetryMs = 0;

// Estes estados devem ser atualizados pelo firmware azimutal no ponto de integracao.
float podAngleDeg = 45.0F;
float throttleNormalized = 0.0F;
bool rcHealthy = false;
bool failsafeActive = true;

float readAveragedAdc(uint8_t pin, uint8_t samples = 16) {
  uint32_t sum = 0;
  for (uint8_t index = 0; index < samples; ++index) {
    sum += analogRead(pin);
  }
  return static_cast<float>(sum) / samples;
}

float adcToVolts(float adc) {
  return adc * kAdcReferenceV / 1023.0F;
}

void addGps(JsonObject position) {
  if (!gps.location.isValid()) {
    position["fix"] = 0;
    return;
  }
  position["latitude_deg"] = gps.location.lat();
  position["longitude_deg"] = gps.location.lng();
  position["speed_mps"] = gps.speed.mps();
  position["course_deg"] = gps.course.deg();
  position["fix"] = 3;
  if (gps.hdop.isValid()) {
    position["hdop"] = gps.hdop.hdop();
  }
}

void addMotion(JsonObject motion) {
  if (!accelerometerReady) {
    return;
  }
  sensors_event_t event;
  accelerometer.getEvent(&event);
  motion["accel_x_mps2"] = event.acceleration.x;
  motion["accel_y_mps2"] = event.acceleration.y;
  motion["accel_z_mps2"] = event.acceleration.z;
}

void transmitTelemetry() {
  const float lm35V = adcToVolts(readAveragedAdc(kLm35Pin));
  const float batteryV = adcToVolts(readAveragedAdc(kVoltagePin)) * kVoltageDividerRatio;
  const float currentA = (adcToVolts(readAveragedAdc(kCurrentPin)) - kAcsZeroV) / kAcsSensitivityVPerA;
  const float humidity = dht.readHumidity();
  const float airTempC = dht.readTemperature();
  const bool waterDetected = digitalRead(kWaterPin) == LOW;

  JsonDocument document;
  document["schema_version"] = 1;
  document["boat_id"] = kBoatId;
  document["sequence"] = sequenceNumber;

  // Sem RTC, o Pi substitui este valor pelo horario de recepcao. GPS UTC sera integrado na fase seguinte.
  document["recorded_at"] = "1970-01-01T00:00:00Z";
  addGps(document["position"].to<JsonObject>());

  JsonObject power = document["power"].to<JsonObject>();
  power["battery_v"] = batteryV;
  power["current_a"] = currentA;
  power["power_w"] = batteryV * currentA;

  addMotion(document["motion"].to<JsonObject>());
  JsonObject environment = document["environment"].to<JsonObject>();
  environment["electronics_temp_c"] = lm35V * 100.0F;
  if (!isnan(airTempC)) environment["air_temp_c"] = airTempC;
  if (!isnan(humidity)) environment["humidity_pct"] = humidity;
  environment["water_detected"] = waterDetected;

  JsonObject propulsion = document["propulsion"].to<JsonObject>();
  propulsion["pod_angle_deg"] = podAngleDeg;
  propulsion["throttle_norm"] = throttleNormalized;
  propulsion["rc_healthy"] = rcHealthy;
  propulsion["failsafe_active"] = failsafeActive;

  JsonObject status = document["status"].to<JsonObject>();
  JsonArray alarms = status["alarms"].to<JsonArray>();
  const bool critical = waterDetected || batteryV < kCriticalBatteryV || !rcHealthy;
  status["severity"] = critical ? "critical" : "ok";
  if (waterDetected) alarms.add("WATER_DETECTED");
  if (batteryV < kCriticalBatteryV) alarms.add("BATTERY_CRITICAL");
  if (!rcHealthy) alarms.add("RC_SIGNAL_LOST");
  if (!accelerometerReady) alarms.add("ADXL345_UNAVAILABLE");

  uint8_t payload[minerva::kMaxPayloadBytes];
  const size_t payloadLength = serializeJson(document, payload, sizeof(payload));
  if (payloadLength == 0 || payloadLength >= sizeof(payload)) {
    return;
  }
  minerva::writeFrame(
      Serial,
      minerva::MessageType::Telemetry,
      sequenceNumber,
      millis(),
      payload,
      static_cast<uint16_t>(payloadLength));
  ++sequenceNumber;
}

}  // namespace

void setup() {
  pinMode(kWaterPin, INPUT_PULLUP);
  Serial.begin(115200);   // USB exclusivo para quadros binarios; nao imprimir debug aqui.
  Serial1.begin(9600);    // NEO-6M: RX1 pino 19, TX1 pino 18 no Mega.
  Wire.begin();           // SDA pino 20, SCL pino 21.
  dht.begin();
  accelerometerReady = accelerometer.begin();
  if (accelerometerReady) {
    accelerometer.setRange(ADXL345_RANGE_16_G);
  }
}

void loop() {
  while (Serial1.available()) {
    gps.encode(Serial1.read());
  }
  const uint32_t now = millis();
  if (now - lastTelemetryMs >= kTelemetryIntervalMs) {
    lastTelemetryMs = now;
    transmitTelemetry();
  }
}
