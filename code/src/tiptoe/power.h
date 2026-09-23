// Power: BQ25895 charger, MAX17048 fuel gauge, TPS63020 switched 3V3 rail (VOUT).
#pragma once
#include <stdint.h>

namespace power {

struct Info {
  bool gauge_ok = false, charger_ok = false;
  float soc = -1;          // %
  uint16_t vbat_mv = 0;    // gauge (falls back to charger ADC)
  float crate = 0;         // %/h
  uint8_t chg_state = 0;   // proto::ChargeState
  uint8_t vbus_stat = 0;   // BQ25895 REG0B[7:5]
  bool power_good = false; // input source present
  uint8_t fault = 0;       // REG0C
  uint16_t vbus_mv = 0, vsys_mv = 0, ichg_ma = 0;
  float ts_pct = 0;
};

void begin(bool coldBoot);  // configure charger (watchdog off, limits) + gauge
Info read(bool runAdc = true);
const char* chargeStateStr(uint8_t s);
const char* ntcFaultStr(uint8_t fault);

// VOUT rail (camera, mic, IR LEDs)
bool voutOn(uint32_t timeoutMs = 50);  // returns true once TPS63020 PG is high
void voutOff();
bool voutIsOn();

// Charger raw register access (console)
bool chgRead(uint8_t reg, uint8_t& val);
bool chgWrite(uint8_t reg, uint8_t val);

}  // namespace power
