#include "power.h"
#include <Arduino.h>
#include <Wire.h>
#include "board.h"
#include "expander.h"
#include "protocol.h"

#ifndef TIPTOE_CHARGE_MA
#define TIPTOE_CHARGE_MA 512      // fast-charge current; keep <= 0.5C of your cell
#endif
#ifndef TIPTOE_VREG_MV
#define TIPTOE_VREG_MV 4208       // charge voltage; 4100 is kinder to a cell living outdoors
#endif
#ifndef TIPTOE_IINLIM_MA
#define TIPTOE_IINLIM_MA 1000     // also hard-capped by R22 (ILIM pin) at ~755 mA
#endif
#ifndef TIPTOE_VINDPM_MV
#define TIPTOE_VINDPM_MV 4400     // back off input current if the Qi output sags below this
#endif

namespace power {

static bool s_vout = false;

static bool rd(uint8_t addr, uint8_t reg, uint8_t* buf, uint8_t n) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(addr, n) != n) return false;
  for (uint8_t i = 0; i < n; i++) buf[i] = Wire.read();
  return true;
}
static bool wr(uint8_t addr, uint8_t reg, const uint8_t* buf, uint8_t n) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  for (uint8_t i = 0; i < n; i++) Wire.write(buf[i]);
  return Wire.endTransmission() == 0;
}

bool chgRead(uint8_t reg, uint8_t& v) { return rd(i2caddr::CHARGER, reg, &v, 1); }
bool chgWrite(uint8_t reg, uint8_t v) { return wr(i2caddr::CHARGER, reg, &v, 1); }

static bool gaugeRead16(uint8_t reg, uint16_t& v) {
  uint8_t b[2];
  if (!rd(i2caddr::GAUGE, reg, b, 2)) return false;
  v = (uint16_t(b[0]) << 8) | b[1];
  return true;
}
static bool gaugeWrite16(uint8_t reg, uint16_t v) {
  uint8_t b[2] = {uint8_t(v >> 8), uint8_t(v & 0xFF)};
  return wr(i2caddr::GAUGE, reg, b, 2);
}

static void configureCharger() {
  uint8_t v;
  if (!chgRead(0x14, v)) return;
  if (((v >> 3) & 0x7) != 0x7) log_w("REG14 PN=%u, expected 7 (BQ25895)", (v >> 3) & 7);

  // REG07: keep termination + safety timer, WATCHDOG=00 (disabled). With the watchdog on,
  // the charger reverts every setting below to defaults 40 s after we go to deep sleep.
  chgWrite(0x07, 0x8D);
  // REG02: ICO on, HVDCP/MaxCharge off, no automatic D+/D- detection (D+/D- not wired; input is Qi).
  chgWrite(0x02, 0x10);
  // REG00: EN_ILIM=1, IINLIM
  uint8_t iin = (TIPTOE_IINLIM_MA - 100) / 50;
  chgWrite(0x00, 0x40 | (iin & 0x3F));
  // REG0D: absolute VINDPM
  chgWrite(0x0D, 0x80 | (((TIPTOE_VINDPM_MV - 2600) / 100) & 0x7F));
  // REG04: ICHG (64 mA/LSB)
  chgWrite(0x04, (TIPTOE_CHARGE_MA / 64) & 0x7F);
  // REG06: VREG (16 mV/LSB from 3.840 V), BATLOWV=3.0 V, VRECHG=100 mV
  chgWrite(0x06, ((((TIPTOE_VREG_MV - 3840) / 16) & 0x3F) << 2) | 0x02);
  // REG03: CHG_CONFIG=1, SYS_MIN=3.5 V (default) — written explicitly
  chgWrite(0x03, 0x1A);
}

static void configureGauge(bool coldBoot) {
  uint16_t ver;
  if (!gaugeRead16(0x08, ver)) return;
  // CONFIG (0x0C): RCOMP default 0x97, ALRT threshold = 32 - ATHD -> alert at 10 %
  gaugeWrite16(0x0C, (0x97 << 8) | (32 - 10));
  // STATUS: clear reset indicator
  uint16_t st;
  if (gaugeRead16(0x1A, st)) gaugeWrite16(0x1A, st & ~0x0100);
  (void)coldBoot;
}

void begin(bool coldBoot) {
  configureCharger();
  configureGauge(coldBoot);
}

Info read(bool runAdc) {
  Info i;
  uint16_t vcell, soc, crate;
  if (gaugeRead16(0x02, vcell) && gaugeRead16(0x04, soc)) {
    i.gauge_ok = true;
    i.vbat_mv = uint16_t((uint32_t(vcell) * 5UL) / 64UL);   // 78.125 uV/LSB
    i.soc = soc / 256.0f;
    if (i.soc > 100) i.soc = 100;
    if (gaugeRead16(0x16, crate)) i.crate = int16_t(crate) * 0.208f;
  }

  uint8_t r;
  if (chgRead(0x0B, r)) {
    i.charger_ok = true;
    i.vbus_stat = r >> 5;
    i.chg_state = (r >> 3) & 3;
    i.power_good = (r >> 2) & 1;
    uint8_t f;
    chgRead(0x0C, f);            // first read returns latched faults
    chgRead(0x0C, f);            // second read = current state
    i.fault = f;
    if (runAdc) {
      chgWrite(0x02, 0x10 | 0x80);             // CONV_START one-shot
      uint32_t t0 = millis();
      while (millis() - t0 < 1200) {
        if (chgRead(0x02, r) && !(r & 0x80)) break;
        delay(10);
      }
      uint8_t adc[5];                          // 0x0E..0x12
      if (rd(i2caddr::CHARGER, 0x0E, adc, 5)) {
        uint16_t batv = 2304 + (adc[0] & 0x7F) * 20;
        i.vsys_mv = 2304 + (adc[1] & 0x7F) * 20;
        i.ts_pct = 21.0f + (adc[2] & 0x7F) * 0.465f;
        i.vbus_mv = (adc[3] & 0x80) ? 2600 + (adc[3] & 0x7F) * 100 : 0;
        i.ichg_ma = (adc[4] & 0x7F) * 50;
        if (!i.gauge_ok) i.vbat_mv = batv;
      }
      // Outdoor units sit in the field on battery. The charger status bits also go active
      // on a floating Qi input, so only a real pad voltage counts as charging.
      if (!(i.power_good && i.vbus_mv > 4000)) {
        i.chg_state = proto::CHG_NONE;
        i.vbus_mv = 0;
      }
    }
  }
  return i;
}

const char* chargeStateStr(uint8_t s) {
  switch (s) {
    case 1: return "pre-charge";
    case 2: return "fast-charge";
    case 3: return "done";
    default: return "not charging";
  }
}

const char* ntcFaultStr(uint8_t f) {
  switch (f & 7) {
    case 0: return "normal";
    case 2: return "warm";
    case 3: return "cool";
    case 5: return "cold";
    case 6: return "hot";
    default: return "?";
  }
}

bool voutOn(uint32_t timeoutMs) {
  pinMode(pins::VOUT_EN, OUTPUT);
  digitalWrite(pins::VOUT_EN, HIGH);
  s_vout = true;
  uint32_t t0 = millis();
  while (millis() - t0 < timeoutMs) {
    if (expander::read(xbit::VOUT_PG)) return true;
    delay(2);
  }
  // PG is only valid if the expander answers; still give the rail time to settle.
  delay(5);
  return expander::ok() ? expander::read(xbit::VOUT_PG) : true;
}

void voutOff() {
  expander::write(xbit::IR_LED, false);
  digitalWrite(pins::VOUT_EN, LOW);
  s_vout = false;
}

bool voutIsOn() { return s_vout; }

}  // namespace power
