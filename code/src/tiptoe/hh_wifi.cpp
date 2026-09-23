// Handheld Wi-Fi on demand: access point + HTTP API for big transfers, and ESP-NOW reception so
// nearby nodes can push full-resolution photos. Turned on by the app (BLE "wifi" command) or the
// BOOT button; turns itself off after 10 minutes without activity.
#include <LittleFS.h>
#include <WebServer.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include "handheld.h"
#include "protocol.h"
#include "secrets.h"

namespace hhwifi {

static constexpr uint8_t CHANNEL = 1;
static constexpr uint32_t IDLE_OFF_MS = 10 * 60 * 1000;
static const char* SSID = "TIPTOE-HH";

static bool s_on = false;
static WebServer* s_http = nullptr;
static uint32_t s_activity = 0;
static QueueHandle_t s_q = nullptr;

struct Pkt {
  uint8_t mac[6];
  uint8_t len;
  uint8_t data[proto::ESPNOW_FRAME_MAX];
};

static void onRecv(const uint8_t* mac, const uint8_t* data, int len) {
  if (len <= 0 || len > (int)proto::ESPNOW_FRAME_MAX) return;
  Pkt p;
  memcpy(p.mac, mac, 6);
  p.len = len;
  memcpy(p.data, data, len);
  xQueueSend(s_q, &p, 0);
}

static void touch() { s_activity = millis(); }

bool on() { return s_on; }
uint8_t channel() { return CHANNEL; }
void apMac(uint8_t mac[6]) { esp_wifi_get_mac(WIFI_IF_AP, mac); }

String infoJson() {
  String s = "{\"t\":\"wifi\",\"on\":";
  s += s_on ? "true" : "false";
  if (s_on) {
    s += ",\"ssid\":\"" + String(SSID) + "\",\"pass\":\"" + String(TIPTOE_HH_AP_PASS) +
         "\",\"ip\":\"" + WiFi.softAPIP().toString() + "\",\"port\":80,\"channel\":" + String(CHANNEL);
  }
  return s + "}";
}

static void sendJson(const String& s) { s_http->send(200, "application/json", s); }

static void startHttp() {
  s_http = new WebServer(80);
  s_http->on("/api/nodes", [] { touch(); sendJson(handheld::nodesJson()); });
  s_http->on("/api/handheld", [] { touch(); sendJson(handheld::handheldJson()); });
  s_http->on("/api/events", [] {
    touch();
    int node = s_http->hasArg("node") ? s_http->arg("node").toInt() : 0;
    int limit = s_http->hasArg("limit") ? constrain((int)s_http->arg("limit").toInt(), 1, 500) : 50;
    uint32_t before = s_http->hasArg("before") ? s_http->arg("before").toInt() : 0;
    sendJson(handheld::eventsJson(node, limit, before));
  });
  s_http->on("/img", [] {
    touch();
    String p = handheld::imagePath(s_http->arg("seq").toInt(), s_http->arg("full") == "1");
    File f = p.length() ? LittleFS.open(p) : File();
    if (!f) {
      s_http->send(404, "text/plain", "not found");
      return;
    }
    s_http->streamFile(f, "image/jpeg");
    f.close();
  });
  s_http->on("/api/cmd", HTTP_POST, [] {
    touch();
    String body = s_http->arg("plain");
    sendJson(handheld::appCommand(body.c_str(), body.length(), false));
  });
  s_http->onNotFound([] { s_http->send(404, "text/plain", "TIPTOE handheld API: see APP_PROTOCOL.md"); });
  s_http->begin();
}

void setOn(bool want) {
  if (want == s_on) {
    if (want) touch();
    return;
  }
  if (!s_q) s_q = xQueueCreate(48, sizeof(Pkt));
  if (want) {
    WiFi.persistent(false);
    WiFi.mode(WIFI_AP);
    WiFi.softAP(SSID, TIPTOE_HH_AP_PASS, CHANNEL, 0, 4);
    if (esp_now_init() == ESP_OK) esp_now_register_recv_cb(onRecv);
    startHttp();
    s_on = true;
    touch();
  } else {
    if (s_http) {
      s_http->stop();
      delete s_http;
      s_http = nullptr;
    }
    esp_now_deinit();
    WiFi.softAPdisconnect(true);
    WiFi.mode(WIFI_OFF);
    s_on = false;
    xQueueReset(s_q);
  }
  handheld::push(infoJson());
}

static void ensurePeer(const uint8_t* mac) {
  if (esp_now_is_peer_exist(mac)) return;
  esp_now_peer_info_t p = {};
  memcpy(p.peer_addr, mac, 6);
  p.channel = 0;   // current channel
  p.ifidx = WIFI_IF_AP;
  p.encrypt = false;
  esp_now_add_peer(&p);
}

void loop() {
  if (!s_on) return;
  Pkt p;
  for (int i = 0; i < 64 && xQueueReceive(s_q, &p, 0) == pdTRUE; i++) {
    touch();
    uint8_t out[proto::ESPNOW_FRAME_MAX];
    size_t r = handheld::onFrame(p.data, p.len, handheld::VIA_ESPNOW, p.mac, 0, 0, out);
    if (r) {
      ensurePeer(p.mac);
      esp_now_send(p.mac, out, r);
    }
  }
  s_http->handleClient();
  if (WiFi.softAPgetStationNum() > 0) touch();
  if (millis() - s_activity > IDLE_OFF_MS) setOn(false);
}

}  // namespace hhwifi
