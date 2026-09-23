// Handheld role: the TIPTOE unit you carry. Stays awake, listens to all outdoor nodes over LoRa
// (and ESP-NOW while its Wi-Fi is on), keeps an event archive, and serves the phone app over BLE
// (always) and Wi-Fi (on demand). See docs/APP_PROTOCOL.md for the app-facing API.
#pragma once
#include <Arduino.h>
#include <stddef.h>
#include <stdint.h>

namespace handheld {

enum Via : uint8_t { VIA_LORA = 0, VIA_ESPNOW = 1 };

[[noreturn]] void run();

// Process one unit-to-unit frame; writes a reply frame to out and returns its length (0 = none).
size_t onFrame(const uint8_t* in, size_t len, Via via, const uint8_t* mac, float rssi, float snr, uint8_t* out);

// App API (BLE writes and HTTP POST /api/cmd). Returns the JSON response.
String appCommand(const char* json, size_t len, bool fromBle);

// Helpers for the HTTP server
String nodesJson();
String eventsJson(int node, int limit, uint32_t before);
String imagePath(uint32_t seq, bool full);
String handheldJson();

// Push to the app over BLE (no-op when no phone is connected)
void push(const String& json);

}  // namespace handheld

namespace hhble {
void begin();
bool ready();                                     // phone connected, paired, subscribed
void pushJson(const String& json);
void pushImage(uint32_t seq, bool full, const uint8_t* data, size_t len);
void loop();                                      // runs queued app commands, paces notifications
}  // namespace hhble

namespace hhwifi {
void setOn(bool on);
bool on();
uint8_t channel();
void apMac(uint8_t mac[6]);
String infoJson();
void loop();                                      // HTTP, ESP-NOW RX, idle timeout
}  // namespace hhwifi
