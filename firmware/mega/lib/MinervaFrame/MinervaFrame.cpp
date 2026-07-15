#include "MinervaFrame.h"

namespace minerva {
namespace {

void putU16Le(uint8_t* target, uint16_t value) {
  target[0] = static_cast<uint8_t>(value & 0xFF);
  target[1] = static_cast<uint8_t>((value >> 8) & 0xFF);
}

void putU32Le(uint8_t* target, uint32_t value) {
  target[0] = static_cast<uint8_t>(value & 0xFF);
  target[1] = static_cast<uint8_t>((value >> 8) & 0xFF);
  target[2] = static_cast<uint8_t>((value >> 16) & 0xFF);
  target[3] = static_cast<uint8_t>((value >> 24) & 0xFF);
}

uint16_t updateCrc(uint16_t crc, uint8_t byte) {
  crc ^= static_cast<uint16_t>(byte) << 8;
  for (uint8_t bit = 0; bit < 8; ++bit) {
    crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021)
                         : static_cast<uint16_t>(crc << 1);
  }
  return crc;
}

}  // namespace

uint16_t crc16Ccitt(const uint8_t* data, size_t length, uint16_t initial) {
  uint16_t crc = initial;
  for (size_t index = 0; index < length; ++index) {
    crc = updateCrc(crc, data[index]);
  }
  return crc;
}

bool writeFrame(
    Stream& output,
    MessageType messageType,
    uint32_t sequence,
    uint32_t monotonicMs,
    const uint8_t* payload,
    uint16_t payloadLength) {
  if (payloadLength > kMaxPayloadBytes || (payloadLength > 0 && payload == nullptr)) {
    return false;
  }

  uint8_t header[14] = {0xA5, 0x5A, kProtocolVersion, static_cast<uint8_t>(messageType)};
  putU16Le(header + 4, payloadLength);
  putU32Le(header + 6, sequence);
  putU32Le(header + 10, monotonicMs);

  uint16_t crc = crc16Ccitt(header + 2, sizeof(header) - 2);
  crc = crc16Ccitt(payload, payloadLength, crc);
  uint8_t checksum[2];
  putU16Le(checksum, crc);

  return output.write(header, sizeof(header)) == sizeof(header) &&
         output.write(payload, payloadLength) == payloadLength &&
         output.write(checksum, sizeof(checksum)) == sizeof(checksum);
}

}  // namespace minerva

