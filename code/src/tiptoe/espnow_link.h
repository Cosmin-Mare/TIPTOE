// Node -> handheld over ESP-NOW. Used only when the handheld recently advertised that its Wi-Fi
// is on (in a LoRa reply); falls back to LoRa otherwise. Same encrypted frames as LoRa.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "link.h"

namespace espnow_link {
bool begin(uint8_t channel, const uint8_t handheldMac[6]);
void end();
bool send(uint8_t type, const void* payload, size_t len, lora::Reply* reply = nullptr);
// Full-res image transfer. Returns true only if the handheld confirmed the complete image.
bool sendEvent(proto::Event& ev, const uint8_t* jpeg, size_t len, lora::Reply* lastReply);
}  // namespace espnow_link
