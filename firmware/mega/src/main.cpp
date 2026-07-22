#include <Arduino.h>
#include <ArduinoJson.h>
#include <DHT.h>
#include <Servo.h>
#include <TinyGPSPlus.h>
#include <Wire.h>
#include <Adafruit_ADXL345_U.h>
#include <Adafruit_Sensor.h>

#include <MinervaFrame.h>

namespace {

// Receptor FlySky do Azimutal.
// Todos os quatro sinais usam interrupcao externa no Mega 2560:
//   CH4 -> D2  : joystick horizontal, direcao +/-45 graus
//   CH3 -> D3  : selecao travada de frente/re do pod
//   CH2 -> D18 : potencia do propulsor
//   CH1 -> D19 : latch fisico START/STOP do piloto automatico
constexpr uint8_t kRudderInputPin = 2;
constexpr uint8_t kDirectionInputPin = 3;
constexpr uint8_t kPropulsionInputPin = 18;
constexpr uint8_t kAutopilotLatchInputPin = 19;

constexpr uint8_t kServo1Pin = 9;
constexpr uint8_t kEscPin = 10;
constexpr uint8_t kServo2Pin = 11;

// D18 e D19 ficam reservados ao receptor.
// O GPS permanece na Serial2, D16/D17.
constexpr uint8_t kLm35Pin = A0;
constexpr uint8_t kCurrentPin = A3;
constexpr uint8_t kVoltagePin = A4;
constexpr uint8_t kDhtPin = 22;
constexpr uint8_t kWaterPin = 23;

constexpr uint16_t kRcMinUs = 1000;
constexpr uint16_t kRcCenterUs = 1500;
constexpr uint16_t kRcMaxUs = 2000;
constexpr uint16_t kRcDeadbandUs = 35;
constexpr uint32_t kRcTimeoutUs = 120000UL;

constexpr float kDirectionSelectThreshold = 0.35F;
constexpr uint32_t kDirectionConfirmMs = 180UL;
constexpr uint16_t kPropulsionStartInputUs = 1600;
constexpr uint32_t kPropulsionArmNeutralMs = 500UL;

constexpr uint16_t kLatchHighUs = 1700;
constexpr uint32_t kLatchDebounceMs = 250;

constexpr float kForwardCenterDeg = 45.0F;
constexpr float kReverseCenterDeg = 225.0F;
constexpr float kRudderMaxDeg = 45.0F;
constexpr float kSafePodDeg = kForwardCenterDeg;
constexpr float kServoMaxStepDeg = 1.8F;

// Calibrar cada servo sem helice e sem forcar o batente mecanico.
constexpr uint16_t kServo1MinUs = 500;
constexpr uint16_t kServo1MaxUs = 2500;
constexpr bool kServo1Inverted = false;
constexpr uint16_t kServo2MinUs = 500;
constexpr uint16_t kServo2MaxUs = 2500;
constexpr bool kServo2Inverted = false;

// ESC medido no Azimutal:
//   1500 us = neutro
//   1600 us = inicio de movimento
//   2500 us = maximo
constexpr uint16_t kEscStopUs = 1500;
constexpr uint16_t kEscStartUs = 1600;
constexpr uint16_t kEscMaxUs = 2500;
constexpr uint16_t kEscMaxStepUs = 6;

constexpr uint32_t kControlIntervalMs = 10;
constexpr uint32_t kDhtIntervalMs = 2000;
constexpr uint32_t kManualTelemetryIntervalMs = 500;
constexpr uint32_t kActiveTelemetryIntervalMs = 200;

constexpr float kAdcReferenceV = 5.0F;
constexpr float kVoltageDividerRatio = 5.0F;
constexpr float kAcsZeroV = 2.5F;
constexpr float kAcsSensitivityVPerA = 0.185F;
constexpr float kCriticalBatteryV = 10.8F;
constexpr char kBoatId[] = "azimutal-01";

constexpr uint16_t kRxPayloadCapacity = 384;
constexpr uint8_t kRxHeaderBytes = 12;

enum class ControlMode : uint8_t { Manual, Auto, Failsafe };

struct RcChannel {
  uint8_t pin;
  volatile uint32_t riseUs;
  volatile uint16_t pulseUs;
  volatile uint32_t lastPulseUs;
};

struct RcSnapshot {
  uint16_t rudderUs;
  uint16_t directionUs;
  uint16_t propulsionUs;
  uint16_t latchUs;
  uint32_t rudderLastUs;
  uint32_t directionLastUs;
  uint32_t propulsionLastUs;
  uint32_t latchLastUs;
};

struct AutopilotState {
  bool hasCommand;
  uint32_t commandSequence;
  uint32_t receivedAtMs;
  uint16_t validForMs;
  float targetPodDeg;
  float throttleNorm;
  char missionId[33];
  uint16_t waypointIndex;
};

RcChannel rudderChannel = {kRudderInputPin, 0, kRcCenterUs, 0};
RcChannel directionChannel = {kDirectionInputPin, 0, kRcCenterUs, 0};
RcChannel propulsionChannel = {kPropulsionInputPin, 0, kRcCenterUs, 0};
RcChannel latchChannel = {kAutopilotLatchInputPin, 0, kRcMinUs, 0};

Servo servo1;
Servo servo2;
Servo esc;
DHT dht(kDhtPin, DHT11);
TinyGPSPlus gps;
Adafruit_ADXL345_Unified accelerometer(34501);

bool accelerometerReady = false;
bool rcHealthy = false;
bool rcStateInitialized = false;
bool failsafeActive = true;
bool invalidCommandAlarm = false;
bool commandTimeoutLatched = false;

bool reverseDirection = false;
bool pendingReverseDirection = false;
bool directionCandidateActive = false;
uint32_t directionCandidateSinceMs = 0;
float directionNormalized = 0.0F;

bool propulsionArmed = false;
bool propulsionNeutralTimerActive = false;
uint32_t propulsionNeutralSinceMs = 0;

bool autopilotLatched = false;
bool latchWasHigh = false;
uint32_t lastLatchToggleMs = 0;
ControlMode controlMode = ControlMode::Failsafe;

float currentPodDeg = kSafePodDeg;
float targetPodDeg = kSafePodDeg;
float rudderNormalized = 0.0F;
float throttleNormalized = 0.0F;
uint16_t currentServo1Us = 0;
uint16_t currentServo2Us = 0;
uint16_t currentEscUs = kEscStopUs;
float cachedAirTempC = NAN;
float cachedHumidityPct = NAN;

AutopilotState autopilot = {false, 0, 0, 0, kSafePodDeg, 0.0F, "", 0};
float autopilotStabilityFactor = 1.0F;
float autopilotSteeringNorm = 0.0F;
char autopilotDriveDirection[8] = "forward";
char autopilotManeuver[33] = "idle";

uint32_t txSequence = 0;
uint32_t lastControlMs = 0;
uint32_t lastTelemetryMs = 0;
uint32_t lastDhtMs = 0;

uint8_t telemetryPayload[minerva::kMaxPayloadBytes];
char auxiliaryPayload[256];
JsonDocument telemetryDocument;
JsonDocument commandDocument;

float clampFloat(float value, float low, float high) {
  if (value < low) return low;
  if (value > high) return high;
  return value;
}

uint16_t clampU16(int value, uint16_t low, uint16_t high) {
  if (value < static_cast<int>(low)) return low;
  if (value > static_cast<int>(high)) return high;
  return static_cast<uint16_t>(value);
}

float approachFloat(float current, float target, float step) {
  const float delta = target - current;
  if (fabs(delta) <= step) return target;
  return current + (delta > 0.0F ? step : -step);
}

uint16_t approachU16(uint16_t current, uint16_t target, uint16_t step) {
  if (current < target) return static_cast<uint16_t>(min(static_cast<uint32_t>(target), static_cast<uint32_t>(current) + step));
  if (current > target) return static_cast<uint16_t>(max(static_cast<int32_t>(target), static_cast<int32_t>(current) - step));
  return current;
}

uint16_t readU16Le(const uint8_t* source) {
  return static_cast<uint16_t>(source[0]) | static_cast<uint16_t>(source[1]) << 8;
}

uint32_t readU32Le(const uint8_t* source) {
  return static_cast<uint32_t>(source[0]) |
         static_cast<uint32_t>(source[1]) << 8 |
         static_cast<uint32_t>(source[2]) << 16 |
         static_cast<uint32_t>(source[3]) << 24;
}

uint16_t updateCrc(uint16_t crc, uint8_t byte) {
  crc ^= static_cast<uint16_t>(byte) << 8;
  for (uint8_t bit = 0; bit < 8; ++bit) {
    crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021)
                         : static_cast<uint16_t>(crc << 1);
  }
  return crc;
}

const char* modeName(ControlMode mode) {
  switch (mode) {
    case ControlMode::Manual: return "manual";
    case ControlMode::Auto: return "auto";
    default: return "failsafe";
  }
}

void sendJsonFrame(minerva::MessageType type, const char* payload) {
  const size_t length = strlen(payload);
  if (length == 0 || length > minerva::kMaxPayloadBytes) return;
  minerva::writeFrame(
      Serial, type, txSequence++, millis(), reinterpret_cast<const uint8_t*>(payload),
      static_cast<uint16_t>(length));
}

void sendEvent(const char* eventCode) {
  snprintf(
      auxiliaryPayload, sizeof(auxiliaryPayload),
      "{\"schema_version\":1,\"boat_id\":\"%s\",\"event\":\"%s\",\"mode\":\"%s\"}",
      kBoatId, eventCode, modeName(controlMode));
  sendJsonFrame(minerva::MessageType::Event, auxiliaryPayload);
}

void sendAck(uint32_t commandSequence, bool accepted, const char* reason) {
  snprintf(
      auxiliaryPayload, sizeof(auxiliaryPayload),
      "{\"command_sequence\":%lu,\"accepted\":%s,\"reason\":\"%s\"}",
      static_cast<unsigned long>(commandSequence), accepted ? "true" : "false", reason);
  sendJsonFrame(minerva::MessageType::Ack, auxiliaryPayload);
}

void captureChannel(RcChannel& channel) {
  const uint32_t nowUs = micros();
  if (digitalRead(channel.pin) == HIGH) {
    channel.riseUs = nowUs;
    return;
  }
  const uint32_t widthUs = nowUs - channel.riseUs;
  if (widthUs >= 800UL && widthUs <= 2200UL) {
    channel.pulseUs = static_cast<uint16_t>(widthUs);
    channel.lastPulseUs = nowUs;
  }
}

void onRudderChange() { captureChannel(rudderChannel); }
void onDirectionChange() { captureChannel(directionChannel); }
void onPropulsionChange() { captureChannel(propulsionChannel); }
void onLatchChange() { captureChannel(latchChannel); }

RcSnapshot readRcSnapshot() {
  RcSnapshot value;
  noInterrupts();
  value.rudderUs = rudderChannel.pulseUs;
  value.directionUs = directionChannel.pulseUs;
  value.propulsionUs = propulsionChannel.pulseUs;
  value.latchUs = latchChannel.pulseUs;
  value.rudderLastUs = rudderChannel.lastPulseUs;
  value.directionLastUs = directionChannel.lastPulseUs;
  value.propulsionLastUs = propulsionChannel.lastPulseUs;
  value.latchLastUs = latchChannel.lastPulseUs;
  interrupts();
  return value;
}

bool pulseHealthy(uint16_t pulseUs, uint32_t lastPulseUs, uint32_t nowUs) {
  return lastPulseUs != 0 && nowUs - lastPulseUs <= kRcTimeoutUs && pulseUs >= 900 && pulseUs <= 2100;
}

bool driveChannelsHealthy(const RcSnapshot& value, uint32_t nowUs) {
  return pulseHealthy(value.rudderUs, value.rudderLastUs, nowUs) &&
         pulseHealthy(value.directionUs, value.directionLastUs, nowUs) &&
         pulseHealthy(value.propulsionUs, value.propulsionLastUs, nowUs);
}

bool latchChannelHealthy(const RcSnapshot& value, uint32_t nowUs) {
  return pulseHealthy(value.latchUs, value.latchLastUs, nowUs);
}

float normalizeRc(uint16_t pulseUs) {
  const int centered =
      static_cast<int>(pulseUs) - static_cast<int>(kRcCenterUs);
  if (abs(centered) <= static_cast<int>(kRcDeadbandUs)) return 0.0F;
  if (centered < 0) {
    return clampFloat(
        static_cast<float>(centered + kRcDeadbandUs) /
            static_cast<float>(
                kRcCenterUs - kRcMinUs - kRcDeadbandUs),
        -1.0F,
        0.0F);
  }
  return clampFloat(
      static_cast<float>(centered - kRcDeadbandUs) /
          static_cast<float>(
              kRcMaxUs - kRcCenterUs - kRcDeadbandUs),
      0.0F,
      1.0F);
}

void updateDirectionLatch(float vertical, uint32_t nowMs) {
  bool hasCandidate = false;
  bool candidateReverse = reverseDirection;

  if (vertical <= -kDirectionSelectThreshold) {
    candidateReverse = true;
    hasCandidate = true;
  } else if (vertical >= kDirectionSelectThreshold) {
    candidateReverse = false;
    hasCandidate = true;
  }

  if (!hasCandidate || candidateReverse == reverseDirection) {
    directionCandidateActive = false;
    return;
  }

  if (!directionCandidateActive ||
      pendingReverseDirection != candidateReverse) {
    pendingReverseDirection = candidateReverse;
    directionCandidateSinceMs = nowMs;
    directionCandidateActive = true;
    return;
  }

  if (nowMs - directionCandidateSinceMs >= kDirectionConfirmMs) {
    reverseDirection = pendingReverseDirection;
    directionCandidateActive = false;
    sendEvent(
        reverseDirection
            ? "DIRECTION_REVERSE"
            : "DIRECTION_FORWARD");
  }
}

float manualPodAngle(float horizontal) {
  const float deflection = horizontal * kRudderMaxDeg;
  if (reverseDirection) {
    return clampFloat(
        kReverseCenterDeg - deflection,
        0.0F,
        270.0F);
  }
  return clampFloat(
      kForwardCenterDeg + deflection,
      0.0F,
      270.0F);
}

float normalizePropulsion(uint16_t pulseUs) {
  if (pulseUs < kPropulsionStartInputUs) return 0.0F;
  const float fraction =
      static_cast<float>(pulseUs - kPropulsionStartInputUs) /
      static_cast<float>(kRcMaxUs - kPropulsionStartInputUs);
  return clampFloat(fraction, 0.0F, 1.0F);
}

uint16_t manualPropulsionToEscUs(uint16_t pulseUs) {
  if (pulseUs < kPropulsionStartInputUs) return kEscStopUs;
  const float fraction = normalizePropulsion(pulseUs);
  return clampU16(
      lroundf(
          kEscStartUs +
          fraction *
              static_cast<float>(kEscMaxUs - kEscStartUs)),
      kEscStartUs,
      kEscMaxUs);
}

uint16_t autopilotThrottleToEscUs(float throttle) {
  const float normalized = clampFloat(throttle, 0.0F, 1.0F);
  if (normalized <= 0.0F) return kEscStopUs;
  return clampU16(
      lroundf(
          kEscStartUs +
          normalized *
              static_cast<float>(kEscMaxUs - kEscStartUs)),
      kEscStartUs,
      kEscMaxUs);
}

void resetManualPropulsionArming() {
  propulsionArmed = false;
  propulsionNeutralTimerActive = false;
  propulsionNeutralSinceMs = 0;
}

void updateManualPropulsionArming(
    uint16_t propulsionUs,
    uint32_t nowMs) {
  if (propulsionArmed) return;

  const bool neutral =
      propulsionUs <= kRcCenterUs + kRcDeadbandUs;
  if (!neutral) {
    propulsionNeutralTimerActive = false;
    return;
  }

  if (!propulsionNeutralTimerActive) {
    propulsionNeutralTimerActive = true;
    propulsionNeutralSinceMs = nowMs;
    return;
  }

  if (nowMs - propulsionNeutralSinceMs >=
      kPropulsionArmNeutralMs) {
    propulsionArmed = true;
    propulsionNeutralTimerActive = false;
    sendEvent("PROPULSION_ARMED");
  }
}

ControlMode requestedMode(bool healthy) {
  if (!healthy) return ControlMode::Failsafe;
  return autopilotLatched
      ? ControlMode::Auto
      : ControlMode::Manual;
}

void updateAutopilotLatch(
    const RcSnapshot& value,
    uint32_t nowMs,
    bool driveHealthy) {
  const bool latchHealthy =
      latchChannelHealthy(value, micros());
  const bool latchHigh =
      latchHealthy && value.latchUs >= kLatchHighUs;

  if (!driveHealthy || !latchHealthy) {
    if (autopilotLatched) {
      sendEvent("AUTOPILOT_LATCH_RELEASED");
    }
    autopilotLatched = false;
    autopilot.hasCommand = false;
    currentEscUs = kEscStopUs;
    esc.writeMicroseconds(currentEscUs);
    latchWasHigh = false;
    return;
  }

  if (latchHigh &&
      !latchWasHigh &&
      nowMs - lastLatchToggleMs >= kLatchDebounceMs) {
    autopilotLatched = !autopilotLatched;
    lastLatchToggleMs = nowMs;
    autopilot.hasCommand = false;
    commandTimeoutLatched = false;
    currentEscUs = kEscStopUs;
    esc.writeMicroseconds(currentEscUs);
    sendEvent(
        autopilotLatched
            ? "AUTOPILOT_LATCHED"
            : "AUTOPILOT_UNLATCHED");
  }

  latchWasHigh = latchHigh;
}

uint16_t angleToServoUs(float logicalAngle, uint16_t minimum, uint16_t maximum, bool inverted) {
  float angle = clampFloat(logicalAngle, 0.0F, 270.0F);
  if (inverted) angle = 270.0F - angle;
  const float fraction = angle / 270.0F;
  return clampU16(lroundf(minimum + fraction * static_cast<float>(maximum - minimum)), minimum, maximum);
}

float readAveragedAdc(uint8_t pin, uint8_t samples = 8) {
  uint32_t total = 0;
  for (uint8_t index = 0; index < samples; ++index) total += analogRead(pin);
  return static_cast<float>(total) / samples;
}

float adcToVolts(float value) { return value * kAdcReferenceV / 1023.0F; }

bool gpsValidForAutopilot() {
  return gps.location.isValid() && gps.location.age() <= 2000UL;
}

bool commandFresh(uint32_t nowMs) {
  return autopilot.hasCommand && nowMs - autopilot.receivedAtMs <= autopilot.validForMs;
}

void rejectCommand(uint32_t sequence, const char* reason) {
  invalidCommandAlarm = true;
  sendAck(sequence, false, reason);
  sendEvent("COMMAND_REJECTED");
}

void handleAutopilotPayload(const uint8_t* payload, uint16_t length, uint32_t frameSequence) {
  commandDocument.clear();
  const DeserializationError error = deserializeJson(commandDocument, payload, length);
  if (error) {
    rejectCommand(frameSequence, "invalid_json");
    return;
  }

  JsonVariant sequenceValue = commandDocument["command_sequence"];
  JsonVariant podValue = commandDocument["target_pod_deg"];
  JsonVariant throttleValue = commandDocument["throttle_norm"];
  JsonVariant validValue = commandDocument["valid_for_ms"];
  JsonVariant missionValue = commandDocument["mission_id"];
  JsonVariant waypointValue = commandDocument["waypoint_index"];
  if (!sequenceValue.is<uint32_t>() || !podValue.is<float>() || !throttleValue.is<float>() ||
      !validValue.is<uint16_t>() || !missionValue.is<const char*>() || !waypointValue.is<uint16_t>()) {
    rejectCommand(frameSequence, "invalid_values");
    return;
  }

  const uint32_t commandSequence = sequenceValue.as<uint32_t>();
  const float pod = podValue.as<float>();
  const float throttle = throttleValue.as<float>();
  const uint16_t validFor = validValue.as<uint16_t>();
  const char* mission = missionValue.as<const char*>();
  const size_t missionLength = mission == nullptr ? 0 : strlen(mission);
  if (!isfinite(pod) || !isfinite(throttle) || pod < 0.0F || pod > 270.0F ||
      throttle < 0.0F || throttle > 1.0F || validFor < 50 || validFor > 1000 ||
      missionLength == 0 || missionLength > 32) {
    rejectCommand(commandSequence, "invalid_values");
    return;
  }
  if (controlMode != ControlMode::Auto) {
    rejectCommand(commandSequence, "not_in_auto_mode");
    return;
  }
  if (!rcHealthy) {
    rejectCommand(commandSequence, "rc_unhealthy");
    return;
  }
  if (!autopilotLatched) {
    rejectCommand(commandSequence, "autopilot_not_latched");
    return;
  }
  if (autopilot.hasCommand && static_cast<int32_t>(commandSequence - autopilot.commandSequence) <= 0) {
    rejectCommand(commandSequence, "stale_sequence");
    return;
  }

  autopilot.hasCommand = true;
  autopilot.commandSequence = commandSequence;
  autopilot.receivedAtMs = millis();
  autopilot.validForMs = validFor;
  autopilot.targetPodDeg = pod;
  autopilot.throttleNorm = throttle;
  memcpy(autopilot.missionId, mission, missionLength);
  autopilot.missionId[missionLength] = '\0';
  autopilot.waypointIndex = waypointValue.as<uint16_t>();

  JsonVariant stabilityValue = commandDocument["stability_factor"];
  JsonVariant steeringValue = commandDocument["steering_norm"];
  autopilotStabilityFactor =
      stabilityValue.is<float>() || stabilityValue.is<int>()
          ? clampFloat(stabilityValue.as<float>(), 0.0F, 1.0F)
          : 1.0F;
  autopilotSteeringNorm =
      steeringValue.is<float>() || steeringValue.is<int>()
          ? clampFloat(steeringValue.as<float>(), -1.0F, 1.0F)
          : 0.0F;

  const char* driveDirection =
      commandDocument["drive_direction"] | "forward";
  const char* maneuver = commandDocument["maneuver"] | "cruise";
  strncpy(
      autopilotDriveDirection,
      driveDirection,
      sizeof(autopilotDriveDirection) - 1);
  autopilotDriveDirection[sizeof(autopilotDriveDirection) - 1] = '\0';
  strncpy(
      autopilotManeuver,
      maneuver,
      sizeof(autopilotManeuver) - 1);
  autopilotManeuver[sizeof(autopilotManeuver) - 1] = '\0';

  invalidCommandAlarm = false;
  commandTimeoutLatched = false;
  sendAck(commandSequence, true, "ok");
  sendEvent("COMMAND_ACCEPTED");
}

class SerialFrameDecoder {
 public:
  void feed(uint8_t byte) {
    switch (state_) {
      case State::PreambleA5:
        if (byte == 0xA5) state_ = State::Preamble5A;
        break;
      case State::Preamble5A:
        if (byte == 0x5A) {
          headerIndex_ = 0;
          crc_ = 0xFFFF;
          state_ = State::Header;
        } else if (byte != 0xA5) {
          state_ = State::PreambleA5;
        }
        break;
      case State::Header:
        header_[headerIndex_++] = byte;
        crc_ = updateCrc(crc_, byte);
        if (headerIndex_ == kRxHeaderBytes) finishHeader();
        break;
      case State::Payload:
        payload_[payloadIndex_++] = byte;
        crc_ = updateCrc(crc_, byte);
        if (payloadIndex_ == payloadLength_) state_ = State::CrcLow;
        break;
      case State::CrcLow:
        receivedCrc_ = byte;
        state_ = State::CrcHigh;
        break;
      case State::CrcHigh:
        receivedCrc_ |= static_cast<uint16_t>(byte) << 8;
        finishFrame();
        break;
      case State::Skip:
        if (--skipRemaining_ == 0) {
          if (frameType_ == static_cast<uint8_t>(minerva::MessageType::AutopilotCommand)) {
            rejectCommand(frameSequence_, "payload_too_large");
          }
          reset();
        }
        break;
    }
  }

 private:
  enum class State : uint8_t { PreambleA5, Preamble5A, Header, Payload, CrcLow, CrcHigh, Skip };
  State state_ = State::PreambleA5;
  uint8_t header_[kRxHeaderBytes] = {};
  uint8_t payload_[kRxPayloadCapacity] = {};
  uint8_t headerIndex_ = 0;
  uint16_t payloadIndex_ = 0;
  uint16_t payloadLength_ = 0;
  uint16_t crc_ = 0xFFFF;
  uint16_t receivedCrc_ = 0;
  uint32_t skipRemaining_ = 0;
  uint32_t frameSequence_ = 0;
  uint8_t frameType_ = 0;

  void reset() { state_ = State::PreambleA5; }

  void finishHeader() {
    payloadLength_ = readU16Le(header_ + 2);
    frameSequence_ = readU32Le(header_ + 4);
    frameType_ = header_[1];
    if (header_[0] != minerva::kProtocolVersion) {
      reset();
      return;
    }
    if (payloadLength_ > kRxPayloadCapacity) {
      skipRemaining_ = static_cast<uint32_t>(payloadLength_) + 2UL;
      state_ = State::Skip;
      return;
    }
    payloadIndex_ = 0;
    state_ = payloadLength_ == 0 ? State::CrcLow : State::Payload;
  }

  void finishFrame() {
    if (receivedCrc_ != crc_) {
      if (frameType_ == static_cast<uint8_t>(minerva::MessageType::AutopilotCommand)) {
        rejectCommand(frameSequence_, "invalid_crc");
      }
      reset();
      return;
    }
    if (frameType_ == static_cast<uint8_t>(minerva::MessageType::AutopilotCommand)) {
      handleAutopilotPayload(payload_, payloadLength_, frameSequence_);
    }
    reset();
  }
};

SerialFrameDecoder serialDecoder;

void transitionMode(ControlMode nextMode) {
  if (nextMode == controlMode) return;

  const ControlMode previous = controlMode;
  controlMode = nextMode;
  sendEvent("MODE_CHANGED");

  if (previous == ControlMode::Auto) {
    sendEvent("AUTOPILOT_DISABLED");
  }
  if (nextMode == ControlMode::Auto) {
    sendEvent("AUTOPILOT_ENABLED");
  }

  autopilot.hasCommand = false;
  commandTimeoutLatched = false;
  currentEscUs = kEscStopUs;
  esc.writeMicroseconds(currentEscUs);

  // Ao retornar ao manual, CH2 deve ficar neutro por 500 ms.
  resetManualPropulsionArming();
}

void updateControl(uint32_t nowMs) {
  const RcSnapshot snapshot = readRcSnapshot();
  const uint32_t nowUs = micros();
  const bool healthy =
      driveChannelsHealthy(snapshot, nowUs);

  if (!rcStateInitialized || healthy != rcHealthy) {
    rcHealthy = healthy;
    rcStateInitialized = true;
    sendEvent(
        healthy
            ? "RC_SIGNAL_RECOVERED"
            : "RC_SIGNAL_LOST");
  } else {
    rcHealthy = healthy;
  }

  // CH1 decide MANUAL/AUTO. CH3 decide somente FRENTE/RE.
  updateAutopilotLatch(snapshot, nowMs, healthy);
  transitionMode(requestedMode(healthy));

  uint16_t requestedEscUs = kEscStopUs;
  float requestedPodDeg = kSafePodDeg;
  float requestedThrottle = 0.0F;
  float requestedRudder = 0.0F;
  bool safe = true;

  if (controlMode == ControlMode::Manual) {
    safe = false;

    requestedRudder = normalizeRc(snapshot.rudderUs);

    directionNormalized =
        normalizeRc(snapshot.directionUs);
    updateDirectionLatch(directionNormalized, nowMs);
    requestedPodDeg =
        manualPodAngle(requestedRudder);

    updateManualPropulsionArming(
        snapshot.propulsionUs,
        nowMs);
    if (propulsionArmed) {
      requestedThrottle =
          normalizePropulsion(snapshot.propulsionUs);
      requestedEscUs =
          manualPropulsionToEscUs(
              snapshot.propulsionUs);
    }
  } else if (controlMode == ControlMode::Auto) {
    const bool fresh = commandFresh(nowMs);

    if (!fresh &&
        autopilot.hasCommand &&
        !commandTimeoutLatched) {
      commandTimeoutLatched = true;
      sendEvent("COMMAND_TIMEOUT");
    }

    if (autopilotLatched &&
        fresh &&
        gpsValidForAutopilot()) {
      safe = false;
      requestedPodDeg = autopilot.targetPodDeg;
      requestedThrottle = autopilot.throttleNorm;
      requestedEscUs =
          autopilotThrottleToEscUs(
              requestedThrottle);
    }
  }

  if (safe) {
    requestedEscUs = kEscStopUs;
    requestedPodDeg = kSafePodDeg;
    requestedThrottle = 0.0F;
    requestedRudder = 0.0F;
  }

  failsafeActive = safe;
  targetPodDeg =
      clampFloat(requestedPodDeg, 0.0F, 270.0F);
  rudderNormalized = requestedRudder;
  throttleNormalized = requestedThrottle;

  currentEscUs =
      safe
          ? kEscStopUs
          : approachU16(
                currentEscUs,
                requestedEscUs,
                kEscMaxStepUs);

  currentPodDeg =
      approachFloat(
          currentPodDeg,
          targetPodDeg,
          kServoMaxStepDeg);

  currentServo1Us =
      angleToServoUs(
          currentPodDeg,
          kServo1MinUs,
          kServo1MaxUs,
          kServo1Inverted);
  currentServo2Us =
      angleToServoUs(
          currentPodDeg,
          kServo2MinUs,
          kServo2MaxUs,
          kServo2Inverted);

  servo1.writeMicroseconds(currentServo1Us);
  servo2.writeMicroseconds(currentServo2Us);
  esc.writeMicroseconds(currentEscUs);
}

void updateDht(uint32_t nowMs) {
  if (nowMs - lastDhtMs < kDhtIntervalMs) return;
  lastDhtMs = nowMs;
  const float temperature = dht.readTemperature();
  const float humidity = dht.readHumidity();
  if (!isnan(temperature)) cachedAirTempC = temperature;
  if (!isnan(humidity)) cachedHumidityPct = humidity;
}

void transmitTelemetry(uint32_t nowMs) {
  const RcSnapshot rc = readRcSnapshot();
  const float lm35V = adcToVolts(readAveragedAdc(kLm35Pin));
  const float batteryV = adcToVolts(readAveragedAdc(kVoltagePin)) * kVoltageDividerRatio;
  const float currentA = (adcToVolts(readAveragedAdc(kCurrentPin)) - kAcsZeroV) / kAcsSensitivityVPerA;
  const bool waterDetected = digitalRead(kWaterPin) == LOW;
  const bool fresh = commandFresh(nowMs);
  const bool gpsAlarm = controlMode == ControlMode::Auto && !gpsValidForAutopilot();
  const bool timeoutAlarm = controlMode == ControlMode::Auto && autopilot.hasCommand && !fresh;

  telemetryDocument.clear();
  telemetryDocument["schema_version"] = 1;
  telemetryDocument["boat_id"] = kBoatId;
  telemetryDocument["sequence"] = txSequence;
  telemetryDocument["recorded_at"] = "1970-01-01T00:00:00Z";
  JsonObject vessel = telemetryDocument["vessel"].to<JsonObject>();
  vessel["type"] = "azimuth";
  vessel["display_name"] = "Azimutal";

  if (gps.location.isValid()) {
    JsonObject position = telemetryDocument["position"].to<JsonObject>();
    position["latitude_deg"] = gps.location.lat();
    position["longitude_deg"] = gps.location.lng();
    if (gps.speed.isValid()) position["speed_mps"] = gps.speed.mps();
    if (gps.course.isValid()) position["course_deg"] = gps.course.deg();
    position["fix"] = 3;
    if (gps.hdop.isValid()) position["hdop"] = gps.hdop.hdop();
  }

  JsonObject power = telemetryDocument["power"].to<JsonObject>();
  power["battery_v"] = batteryV;
  power["current_a"] = currentA;
  power["power_w"] = batteryV * currentA;

  if (accelerometerReady) {
    sensors_event_t event;
    accelerometer.getEvent(&event);
    JsonObject motion = telemetryDocument["motion"].to<JsonObject>();
    motion["accel_x_mps2"] = event.acceleration.x;
    motion["accel_y_mps2"] = event.acceleration.y;
    motion["accel_z_mps2"] = event.acceleration.z;
  }

  JsonObject environment = telemetryDocument["environment"].to<JsonObject>();
  environment["electronics_temp_c"] = lm35V * 100.0F;
  if (!isnan(cachedAirTempC)) environment["air_temp_c"] = cachedAirTempC;
  if (!isnan(cachedHumidityPct)) environment["humidity_pct"] = cachedHumidityPct;
  environment["water_detected"] = waterDetected;

  JsonObject control = telemetryDocument["control"].to<JsonObject>();
  control["mode"] = modeName(controlMode);
  // A gravacao de rota e controlada pelo app/backend.
  control["recording_active"] = false;
  control["rc_healthy"] = rcHealthy;
  control["failsafe_active"] = failsafeActive;
  control["rudder_pwm_us"] = rc.rudderUs;          // CH4
  control["direction_pwm_us"] = rc.directionUs;    // CH3
  control["propulsion_pwm_us"] = rc.propulsionUs;  // CH2
  control["latch_pwm_us"] = rc.latchUs;            // CH1
  control["direction_reverse"] = reverseDirection;
  control["propulsion_armed"] = propulsionArmed;
  control["latch_channel_healthy"] =
      latchChannelHealthy(rc, micros());

  JsonObject autoState = telemetryDocument["autopilot"].to<JsonObject>();
  autoState["armed"] = controlMode == ControlMode::Auto;
  autoState["latched"] = autopilotLatched;
  autoState["enabled"] = controlMode == ControlMode::Auto && autopilotLatched;
  autoState["command_fresh"] = fresh;
  autoState["last_command_sequence"] = autopilot.commandSequence;
  autoState["command_age_ms"] = autopilot.hasCommand ? nowMs - autopilot.receivedAtMs : 0;
  autoState["target_pod_deg"] = autopilot.targetPodDeg;
  autoState["mission_id"] = autopilot.missionId;
  autoState["waypoint_index"] = autopilot.waypointIndex;
  autoState["stability_factor"] = autopilotStabilityFactor;
  autoState["maneuver"] = autopilotManeuver;

  JsonObject propulsion = telemetryDocument["propulsion"].to<JsonObject>();
  propulsion["pod_angle_deg"] = currentPodDeg;
  propulsion["target_pod_angle_deg"] = targetPodDeg;
  propulsion["rudder_norm"] = rudderNormalized;
  propulsion["steering_norm"] = autopilotSteeringNorm;
  propulsion["drive_direction"] =
      controlMode == ControlMode::Auto
          ? autopilotDriveDirection
          : (reverseDirection ? "reverse" : "forward");
  propulsion["throttle_norm"] = throttleNormalized;
  propulsion["servo1_pwm_us"] = currentServo1Us;
  propulsion["servo2_pwm_us"] = currentServo2Us;
  propulsion["esc_pwm_us"] = currentEscUs;
  propulsion["motor_on"] = currentEscUs > kEscStopUs + 15;

  JsonObject status = telemetryDocument["status"].to<JsonObject>();
  JsonArray alarms = status["alarms"].to<JsonArray>();
  if (!rcHealthy) alarms.add("RC_SIGNAL_LOST");
  if (timeoutAlarm) alarms.add("AUTOPILOT_COMMAND_TIMEOUT");
  if (invalidCommandAlarm) alarms.add("AUTOPILOT_INVALID_COMMAND");
  if (gpsAlarm) alarms.add("GPS_INVALID_IN_AUTO");
  if (!accelerometerReady) alarms.add("ADXL345_UNAVAILABLE");
  if (waterDetected) alarms.add("WATER_DETECTED");
  if (batteryV < kCriticalBatteryV) alarms.add("BATTERY_CRITICAL");
  const bool critical = !rcHealthy || timeoutAlarm || gpsAlarm || waterDetected || batteryV < kCriticalBatteryV;
  status["severity"] = critical ? "critical" : (invalidCommandAlarm || !accelerometerReady ? "warning" : "ok");

  // Mantem o quadro abaixo de 1024 bytes mesmo com todos os alarmes ativos.
  // Campos de diagnostico menos importantes sao removidos apenas quando necessario.
  if (measureJson(telemetryDocument) >= sizeof(telemetryPayload)) power.remove("power_w");
  if (measureJson(telemetryDocument) >= sizeof(telemetryPayload) && telemetryDocument["position"].is<JsonObject>()) {
    telemetryDocument["position"].as<JsonObject>().remove("hdop");
  }
  if (measureJson(telemetryDocument) >= sizeof(telemetryPayload)) environment.remove("air_temp_c");
  if (measureJson(telemetryDocument) >= sizeof(telemetryPayload)) environment.remove("humidity_pct");
  if (measureJson(telemetryDocument) >= sizeof(telemetryPayload)) telemetryDocument.remove("motion");
  if (measureJson(telemetryDocument) >= sizeof(telemetryPayload) && telemetryDocument["position"].is<JsonObject>()) {
    JsonObject position = telemetryDocument["position"].as<JsonObject>();
    position.remove("speed_mps");
    position.remove("course_deg");
  }

  const size_t length = serializeJson(telemetryDocument, telemetryPayload, sizeof(telemetryPayload));
  if (length == 0 || length >= sizeof(telemetryPayload)) return;
  minerva::writeFrame(
      Serial, minerva::MessageType::Telemetry, txSequence++, nowMs, telemetryPayload,
      static_cast<uint16_t>(length));
}

}  // namespace

void setup() {
  pinMode(kRudderInputPin, INPUT);
  pinMode(kDirectionInputPin, INPUT);
  pinMode(kPropulsionInputPin, INPUT);
  pinMode(kAutopilotLatchInputPin, INPUT);
  pinMode(kWaterPin, INPUT_PULLUP);

  Serial.begin(115200);   // USB: somente MinervaFrame binario, sem mensagens de debug.
  Serial2.begin(9600);    // GPS: RX2 D17 <- TX GPS; TX2 D16 -> RX GPS.
  Wire.begin();           // ADXL345: SDA D20, SCL D21.
  dht.begin();
  accelerometerReady = accelerometer.begin();
  if (accelerometerReady) accelerometer.setRange(ADXL345_RANGE_16_G);

  servo1.attach(kServo1Pin, kServo1MinUs, kServo1MaxUs);
  servo2.attach(kServo2Pin, kServo2MinUs, kServo2MaxUs);
  esc.attach(kEscPin, kEscStopUs, kEscMaxUs);
  currentServo1Us = angleToServoUs(currentPodDeg, kServo1MinUs, kServo1MaxUs, kServo1Inverted);
  currentServo2Us = angleToServoUs(currentPodDeg, kServo2MinUs, kServo2MaxUs, kServo2Inverted);
  servo1.writeMicroseconds(currentServo1Us);
  servo2.writeMicroseconds(currentServo2Us);
  esc.writeMicroseconds(kEscStopUs);

  attachInterrupt(
      digitalPinToInterrupt(kRudderInputPin),
      onRudderChange,
      CHANGE);
  attachInterrupt(
      digitalPinToInterrupt(kDirectionInputPin),
      onDirectionChange,
      CHANGE);
  attachInterrupt(
      digitalPinToInterrupt(kPropulsionInputPin),
      onPropulsionChange,
      CHANGE);
  attachInterrupt(
      digitalPinToInterrupt(kAutopilotLatchInputPin),
      onLatchChange,
      CHANGE);
}

void loop() {
  while (Serial2.available() > 0) gps.encode(Serial2.read());
  while (Serial.available() > 0) serialDecoder.feed(static_cast<uint8_t>(Serial.read()));

  const uint32_t nowMs = millis();
  if (nowMs - lastControlMs >= kControlIntervalMs) {
    lastControlMs = nowMs;
    updateControl(nowMs);
  }
  updateDht(nowMs);
  const uint32_t interval = controlMode == ControlMode::Manual ? kManualTelemetryIntervalMs : kActiveTelemetryIntervalMs;
  if (nowMs - lastTelemetryMs >= interval) {
    lastTelemetryMs = nowMs;
    transmitTelemetry(nowMs);
  }
}
