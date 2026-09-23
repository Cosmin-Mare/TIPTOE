#include "config.h"
#include <Arduino.h>
#include <Preferences.h>
#include <esp_mac.h>
#include "esp_camera.h"
#include "protocol.h"

namespace config {

NodeConfig cfg;

// Survive deep sleep; re-synced from NVS on cold boot.
RTC_DATA_ATTR static uint32_t rtc_fcnt = 0;
RTC_DATA_ATTR static uint32_t rtc_fcnt_limit = 0;
RTC_DATA_ATTR static uint16_t rtc_event_id = 0;
RTC_DATA_ATTR static bool rtc_valid = false;

static constexpr uint32_t FCNT_BLOCK = 256;
static constexpr uint32_t CFG_MAGIC = 0x54505432;  // "TPT2" (bumped when NodeConfig changes)

static uint8_t defaultNodeId() {
  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  uint8_t id = mac[5];
  if (id == 0 || id == 0xFF) id = 1;
  return id;
}

void resetDefaults() {
  cfg.node_id = defaultNodeId();
  cfg.armed = 1;
  cfg.heartbeat_min = 30;
  cfg.cooldown_s = 30;
  cfg.jpeg_quality = 14;
  cfg.framesize = FRAMESIZE_QVGA;   // 320x240 -> ~5-9 KB -> 25-45 chunks
  cfg.ir_mode = 2;
  cfg.ir_luma = 40;
  cfg.audio_ms = 1500;
  cfg.tx_power = 22;
  cfg.send_image = 1;
  cfg.hires_local = 1;
  cfg.grayscale_ir = 1;
  cfg.role = ROLE_NODE;
}

void load() {
  resetDefaults();
  Preferences p;
  p.begin("tiptoe", true);
  if (p.getUInt("magic", 0) == CFG_MAGIC && p.getBytesLength("cfg") == sizeof(NodeConfig)) {
    p.getBytes("cfg", &cfg, sizeof(cfg));
  }
  if (!rtc_valid) {
    rtc_fcnt = p.getUInt("fcnt", 0);
    rtc_fcnt_limit = rtc_fcnt;         // force a new reservation on first use
    rtc_event_id = p.getUShort("evt", 0);
    rtc_valid = true;
  }
  p.end();
}

void save() {
  Preferences p;
  p.begin("tiptoe", false);
  p.putUInt("magic", CFG_MAGIC);
  p.putBytes("cfg", &cfg, sizeof(cfg));
  p.end();
}

const char* roleName() { return cfg.role == ROLE_HANDHELD ? "handheld" : "node"; }

bool setNodeId(uint8_t id) {
  if (id == 0 || id == 0xFF) return false;
  cfg.node_id = id;
  return true;
}

bool set(uint8_t key, uint32_t v) {
  switch (key) {
    case proto::CFG_ARMED: cfg.armed = v ? 1 : 0; return true;
    case proto::CFG_HEARTBEAT_MIN: if (v < 1 || v > 1440) return false; cfg.heartbeat_min = v; return true;
    case proto::CFG_COOLDOWN_S: if (v > 3600) return false; cfg.cooldown_s = v; return true;
    case proto::CFG_JPEG_QUALITY: if (v < 4 || v > 63) return false; cfg.jpeg_quality = v; return true;
    case proto::CFG_FRAMESIZE: if (v > FRAMESIZE_XGA) return false; cfg.framesize = v; return true;
    case proto::CFG_IR_MODE: if (v > 2) return false; cfg.ir_mode = v; return true;
    case proto::CFG_IR_LUMA: if (v > 255) return false; cfg.ir_luma = v; return true;
    case proto::CFG_AUDIO_MS: if (v > 5000) return false; cfg.audio_ms = v; return true;
    case proto::CFG_TX_POWER: if ((int32_t)v < -9 || (int32_t)v > 22) return false; cfg.tx_power = (int8_t)v; return true;
    case proto::CFG_SEND_IMAGE: cfg.send_image = v ? 1 : 0; return true;
    case proto::CFG_HIRES_LOCAL: cfg.hires_local = v ? 1 : 0; return true;
    case proto::CFG_GRAYSCALE_IR: cfg.grayscale_ir = v ? 1 : 0; return true;
  }
  return false;
}

void print() {
  Serial.printf("role=%s ", roleName());
  Serial.printf("node_id=%u armed=%u heartbeat_min=%u cooldown_s=%u\n", cfg.node_id, cfg.armed,
                cfg.heartbeat_min, cfg.cooldown_s);
  Serial.printf("jpeg_quality=%u framesize=%u ir_mode=%u ir_luma=%u audio_ms=%u\n", cfg.jpeg_quality,
                cfg.framesize, cfg.ir_mode, cfg.ir_luma, cfg.audio_ms);
  Serial.printf("tx_power=%d send_image=%u hires_local=%u grayscale_ir=%u\n", cfg.tx_power, cfg.send_image,
                cfg.hires_local, cfg.grayscale_ir);
}

uint32_t nextFrameCounter() {
  if (rtc_fcnt >= rtc_fcnt_limit) {
    rtc_fcnt_limit = rtc_fcnt + FCNT_BLOCK;
    Preferences p;
    p.begin("tiptoe", false);
    p.putUInt("fcnt", rtc_fcnt_limit);
    p.end();
  }
  return ++rtc_fcnt;
}

uint16_t nextEventId() {
  ++rtc_event_id;
  if (rtc_event_id == 0) rtc_event_id = 1;
  Preferences p;
  p.begin("tiptoe", false);
  p.putUShort("evt", rtc_event_id);
  p.end();
  return rtc_event_id;
}

}  // namespace config
