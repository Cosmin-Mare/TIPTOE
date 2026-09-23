// LoRa link: encryption, RX window, duty-cycle budget, image transfer (node side) and
// raw frame RX/TX (handheld side).
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "protocol.h"

namespace lora {

struct Cmd {
  uint8_t op;
  uint8_t key;
  uint32_t value;
};

struct Reply {
  bool received = false;
  uint8_t flags = 0;
  uint32_t unix_time = 0;
  uint8_t bitmap[proto::BITMAP_BYTES] = {};
  uint8_t espnow_channel = 0;
  uint8_t espnow_mac[6] = {};
  uint8_t n_missing = 0;
  uint16_t missing[proto::ESPNOW_MAX_MISSING] = {};
  uint8_t n_cmds = 0;
  Cmd cmds[8];
  float rssi = 0, snr = 0;
};

bool begin(int8_t txPower);
bool ok();
void sleep();                         // radio to sleep, NSS held high through deep sleep

// ---- node side ----
bool send(uint8_t type, const void* payload, size_t len, Reply* reply = nullptr);
bool sendEvent(proto::Event& ev, const uint8_t* jpeg, size_t len, Reply* lastReply);
bool parseReply(const uint8_t* p, int n, Reply& r);
void noteReply(const Reply& r);       // apply time sync + remember the handheld's ESP-NOW advert

// The handheld's ESP-NOW advert from the last reply, if still fresh.
bool handheldEspNow(uint8_t& channel, uint8_t mac[6]);
void clearHandheldEspNow();

// ---- handheld side ----
bool rxStart();
int rxPoll(uint8_t* buf, float& rssi, float& snr);   // -1 nothing, 0 bad packet, >0 frame length
bool txRaw(const uint8_t* frame, size_t len);         // blocking TX, then caller re-arms RX

// Duty cycle (EU868 g3 = 10 %). Budget tracked in RTC memory across deep sleep.
uint32_t airtimeMs(size_t payloadLen);
bool budgetAllows(uint32_t ms);
uint32_t budgetLeftMs();

// Monotonic seconds (survives deep sleep and time sync jumps)
uint32_t monoSeconds();
void applyTime(uint32_t unix);
bool timeSynced();

float lastRssi();
float lastSnr();

}  // namespace lora
