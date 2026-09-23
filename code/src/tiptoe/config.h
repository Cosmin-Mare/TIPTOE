// Persistent node configuration (NVS) + persistent counters.
#pragma once
#include <stdint.h>

struct NodeConfig {
  uint8_t node_id;          // 1..254, default derived from MAC
  uint8_t armed;
  uint16_t heartbeat_min;
  uint16_t cooldown_s;
  uint8_t jpeg_quality;
  uint8_t framesize;        // framesize_t for the LoRa image
  uint8_t ir_mode;          // 0 off, 1 on, 2 auto
  uint8_t ir_luma;
  uint16_t audio_ms;
  int8_t tx_power;
  uint8_t send_image;
  uint8_t hires_local;
  uint8_t grayscale_ir;
  uint8_t role;             // ROLE_NODE or ROLE_HANDHELD
};

enum Role : uint8_t { ROLE_NODE = 0, ROLE_HANDHELD = 1 };

namespace config {
extern NodeConfig cfg;
void load();
void save();
void resetDefaults();
// Apply a proto::CfgKey. Returns false for an unknown key or out-of-range value.
bool set(uint8_t key, uint32_t value);
bool setNodeId(uint8_t id);
const char* roleName();
void print();

// Uplink frame counter, reserved in NVS in blocks so a power loss never repeats a value.
uint32_t nextFrameCounter();
uint16_t nextEventId();
}  // namespace config
