#include "espnow_link.h"
#include <Arduino.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_task_wdt.h>
#include <esp_wifi.h>
#include "config.h"
#include "secrets.h"

namespace espnow_link {

static const uint8_t KEY[16] = TIPTOE_NETWORK_KEY;
static uint8_t s_peer[6];
static bool s_up = false;
static uint32_t s_lastUpCtr = 0;

static SemaphoreHandle_t s_sent = nullptr, s_rx = nullptr;
static volatile bool s_sentOk = false;
static uint8_t s_rxBuf[proto::ESPNOW_FRAME_MAX];
static volatile int s_rxLen = 0;

static void onSent(const uint8_t*, esp_now_send_status_t status) {
  s_sentOk = status == ESP_NOW_SEND_SUCCESS;
  xSemaphoreGive(s_sent);
}

static void onRecv(const uint8_t* mac, const uint8_t* data, int len) {
  if (memcmp(mac, s_peer, 6) != 0 || len <= 0 || len > (int)sizeof(s_rxBuf)) return;
  memcpy(s_rxBuf, data, len);
  s_rxLen = len;
  xSemaphoreGive(s_rx);
}

bool begin(uint8_t channel, const uint8_t mac[6]) {
  if (!s_sent) s_sent = xSemaphoreCreateBinary();
  if (!s_rx) s_rx = xSemaphoreCreateBinary();
  memcpy(s_peer, mac, 6);
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);
  if (esp_now_init() != ESP_OK) {
    WiFi.mode(WIFI_OFF);
    return false;
  }
  esp_now_register_send_cb(onSent);
  esp_now_register_recv_cb(onRecv);
  esp_now_peer_info_t p = {};
  memcpy(p.peer_addr, mac, 6);
  p.channel = channel;
  p.ifidx = WIFI_IF_STA;
  p.encrypt = false;   // frames are already AES-GCM sealed
  if (esp_now_add_peer(&p) != ESP_OK) {
    end();
    return false;
  }
  s_up = true;
  return true;
}

void end() {
  esp_now_deinit();
  WiFi.mode(WIFI_OFF);
  s_up = false;
}

// One frame with MAC-level acknowledgement, retried a few times.
static bool rawSend(const uint8_t* frame, size_t len) {
  for (int attempt = 0; attempt < 4; attempt++) {
    xSemaphoreTake(s_sent, 0);
    if (esp_now_send(s_peer, frame, len) != ESP_OK) {
      delay(5);
      continue;
    }
    if (xSemaphoreTake(s_sent, pdMS_TO_TICKS(60)) == pdTRUE && s_sentOk) return true;
    delay(3 + attempt * 5);
  }
  return false;
}

bool send(uint8_t type, const void* payload, size_t len, lora::Reply* reply) {
  if (!s_up) return false;
  esp_task_wdt_reset();
  uint8_t frame[proto::ESPNOW_FRAME_MAX];
  if (proto::HDR_LEN + len + proto::TAG_LEN > sizeof(frame)) return false;
  uint32_t ctr = config::nextFrameCounter();
  size_t n = proto::seal(KEY, 0, config::cfg.node_id, type, ctr, (const uint8_t*)payload, len, frame);
  if (!n) return false;
  xSemaphoreTake(s_rx, 0);
  if (!rawSend(frame, n)) return false;
  s_lastUpCtr = ctr;
  if (!reply) return true;

  *reply = lora::Reply();
  uint32_t t0 = millis();
  while (millis() - t0 < proto::ESPNOW_REPLY_MS) {
    if (xSemaphoreTake(s_rx, pdMS_TO_TICKS(proto::ESPNOW_REPLY_MS)) != pdTRUE) break;
    proto::Header h;
    uint8_t pt[proto::ESPNOW_FRAME_MAX];
    int m = proto::open(KEY, 1, s_rxBuf, s_rxLen, h, pt);
    if (m >= 0 && h.type == proto::DN_REPLY && h.node == config::cfg.node_id && h.ctr == s_lastUpCtr) {
      reply->received = lora::parseReply(pt, m, *reply);
      lora::noteReply(*reply);
      return reply->received;
    }
  }
  return false;
}

bool sendEvent(proto::Event& ev, const uint8_t* jpeg, size_t len, lora::Reply* lastReply) {
  if (!s_up || !len) return false;
  uint32_t chunks = (len + proto::ESPNOW_CHUNK - 1) / proto::ESPNOW_CHUNK;
  if (chunks > proto::ESPNOW_MAX_CHUNKS) return false;
  ev.flags |= proto::EVF_ESPNOW;
  ev.img_len = len;
  ev.chunks = chunks;
  if (!espnow_link::send(proto::UP_EVENT, &ev, sizeof(ev))) return false;   // handheld not in range

  uint8_t buf[sizeof(proto::ChunkHdr) + proto::ESPNOW_CHUNK];
  auto sendChunk = [&](uint16_t i) -> bool {
    proto::ChunkHdr ch{ev.event_id, i, (uint16_t)chunks};
    size_t off = size_t(i) * proto::ESPNOW_CHUNK;
    size_t n = min(proto::ESPNOW_CHUNK, len - off);
    memcpy(buf, &ch, sizeof(ch));
    memcpy(buf + sizeof(ch), jpeg + off, n);
    return espnow_link::send(proto::UP_CHUNK, buf, sizeof(ch) + n);
  };

  int consecutiveFails = 0;
  for (uint16_t i = 0; i < chunks; i++) {
    if (sendChunk(i)) consecutiveFails = 0;
    else if (++consecutiveFails >= 5) return false;   // walked out of range
  }

  lora::Reply r;
  for (uint8_t round = 0; round < 10; round++) {
    proto::EventEnd end{ev.event_id, round};
    bool got = false;
    for (int t = 0; t < 3 && !got; t++) got = espnow_link::send(proto::UP_EVENT_END, &end, sizeof(end), &r);
    if (lastReply) *lastReply = r;
    if (!got) return false;
    if (r.flags & proto::RF_COMPLETE) return true;
    if (!(r.flags & proto::RF_MISSING) || r.n_missing == 0) return false;
    for (uint8_t k = 0; k < r.n_missing; k++)
      if (r.missing[k] < chunks) sendChunk(r.missing[k]);
  }
  return false;
}

}  // namespace espnow_link
