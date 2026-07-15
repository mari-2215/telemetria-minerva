#pragma once

#include <Arduino.h>

namespace minerva {

constexpr uint8_t kProtocolVersion = 1;
constexpr uint16_t kMaxPayloadBytes = 1024;

enum class MessageType : uint8_t {
  Telemetry = 1,
  Event = 2,
  Heartbeat = 3,
  Ack = 4,
};

uint16_t crc16Ccitt(const uint8_t* data, size_t length, uint16_t initial = 0xFFFF);

bool writeFrame(
    Stream& output,
    MessageType messageType,
    uint32_t sequence,
    uint32_t monotonicMs,
    const uint8_t* payload,
    uint16_t payloadLength);

}  // namespace minerva

