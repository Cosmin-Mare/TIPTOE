// Node application logic shared by the wake handler, console and web UI.
#pragma once
#include <stdint.h>
#include "link.h"
#include "protocol.h"

namespace app {

struct Pending {
  bool snapshot = false, status = false, maintenance = false, reboot = false, clear = false, cfg_changed = false;
};
extern Pending pending;

void initBus();
void initHardware(bool coldBoot);
uint8_t hwMask();
proto::Status buildStatus(uint8_t reason);
bool sendStatus(uint8_t type, uint8_t reason);
void runEvent(uint8_t trigger);
void handleReply(const lora::Reply& r);
void processPending();                 // runs snapshot/status/clear; leaves maintenance/reboot to caller
bool batteryCritical();
bool pirWarm();
void setPirWarm();
uint32_t coldBootMono();
uint16_t eventCount();

}  // namespace app
