#include "console.h"
#include <Arduino.h>
#include <Wire.h>
#include "app.h"
#include "audio.h"
#include "board.h"
#include "camera.h"
#include "config.h"
#include "expander.h"
#include "link.h"
#include "maintenance.h"
#include "power.h"
#include "storage.h"

namespace console {

static const char HELP[] =
    "commands:\n"
    "  status            power/charger/gauge readout\n"
    "  selftest          probe every part on the board\n"
    "  i2c               scan the I2C bus\n"
    "  chg               dump BQ25895 registers\n"
    "  cfg               show config        set <key#> <value>   id <node_id>\n"
    "                    keys: 1 armed 2 heartbeat_min 3 cooldown_s 4 jpeg_quality 5 framesize\n"
    "                          6 ir_mode 7 ir_luma 8 audio_ms 9 tx_power 10 send_image 11 hires_local 12 grayscale_ir\n"
    "  snap              run a full event (capture, store, send)\n"
    "  send              send a status uplink and print the reply (node role)\n"
    "  mic               1 s sound level\n"
    "  ir on|off   vout on|off   pir\n"
    "  ls   clear        local event archive\n"
    "  maint             Wi-Fi maintenance mode\n"
    "  role node|handheld   switch this unit's role (reboots)\n"
    "  factory           reset config to defaults\n"
    "  exit | sleep      continue normal operation\n"
    "  reboot\n";

bool offer(uint32_t windowMs) {
  Serial.printf("\nTIPTOE fw %d.%d (%s) — press any key within %u s for the console\n", FW_MAJOR, FW_MINOR,
                config::roleName(), (unsigned)(windowMs / 1000));
  uint32_t t0 = millis();
  while (millis() - t0 < windowMs) {
    if (Serial.available()) {
      while (Serial.available()) Serial.read();
      return true;
    }
    delay(10);
  }
  return false;
}

static void printStatus() {
  power::Info p = power::read(true);
  Serial.printf("gauge %s  soc=%.1f%%  vbat=%umV  crate=%.1f%%/h\n", p.gauge_ok ? "ok" : "MISSING", p.soc, p.vbat_mv,
                p.crate);
  Serial.printf("charger %s  %s  input=%s(vbus_stat=%u) vbus=%umV vsys=%umV ichg=%umA ts=%.1f%% ntc=%s fault=0x%02x\n",
                p.charger_ok ? "ok" : "MISSING", power::chargeStateStr(p.chg_state), p.power_good ? "yes" : "no",
                p.vbus_stat, p.vbus_mv, p.vsys_mv, p.ichg_ma, p.ts_pct, power::ntcFaultStr(p.fault), p.fault);
  if ((p.fault & 7) == 6 && p.ts_pct < 30)
    Serial.println("  !! TS reads ~0%: check RT1 (REGN->TS) and the NTC. Charging is blocked while TS reads hot.");
  Serial.printf("expander 0x%02x (out 0x%02x)  PIR=%d  temp=%.1fC  mono=%us  synced=%d  budget_left=%ums\n",
                expander::readAll(), expander::shadow(), digitalRead(pins::PIR), temperatureRead(),
                (unsigned)lora::monoSeconds(), lora::timeSynced(), (unsigned)lora::budgetLeftMs());
}

static void i2cScan() {
  for (uint8_t a = 1; a < 127; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) Serial.printf("  0x%02x\n", a);
  }
}

void selftest() {
  auto res = [](const char* what, bool ok, const String& extra = "") {
    Serial.printf("  [%s] %s %s\n", ok ? " OK " : "FAIL", what, extra.c_str());
  };
  Serial.println("selftest:");
  res("PCF8574 @0x20", expander::begin());
  power::Info p = power::read(true);
  res("BQ25895 @0x6A", p.charger_ok, String("ntc=") + power::ntcFaultStr(p.fault));
  res("MAX17048 @0x36", p.gauge_ok, String(p.vbat_mv) + "mV " + String(p.soc, 1) + "%");
  bool pg = power::voutOn(100);
  res("TPS63020 VOUT PG", pg);
  uint16_t pid = 0;
  bool cam = camera::probe(&pid);
  char pidbuf[16];
  snprintf(pidbuf, sizeof(pidbuf), "pid=0x%04x", pid);
  res("camera", cam, cam ? pidbuf : "no sensor (check CAM 2.8V / CAM 1.5V rails and the FPC)");
  audio::start(500, false);
  audio::Result a = audio::wait(3000);
  res("ICS-43434 mic", a.ok, String(a.rms_db, 1) + " dBFS rms, slot " + String(a.channel));
  expander::write(xbit::IR_LED, true);
  delay(300);
  expander::write(xbit::IR_LED, false);
  res("IR LEDs pulsed 300 ms (check with a phone camera)", true);
  power::voutOff();
  res("SX1262", lora::ok() || lora::begin(config::cfg.tx_power));
  res("LittleFS", storage::ok(), String(storage::freeBytes() / 1024) + " KB free");
  res("PSRAM", psramFound(), String(ESP.getPsramSize() / 1024) + " KB");
  res("PIR input", true, String("level=") + digitalRead(pins::PIR));
}

void run() {
  Serial.print(HELP);
  String line;
  for (;;) {
    Serial.print("> ");
    line = "";
    for (;;) {
      if (Serial.available()) {
        char ch = Serial.read();
        if (ch == '\r' || ch == '\n') {
          if (line.length()) break;
          continue;
        }
        if (ch == 8 || ch == 127) {
          if (line.length()) line.remove(line.length() - 1);
          continue;
        }
        line += ch;
        Serial.print(ch);
      } else {
        delay(5);
      }
    }
    Serial.println();
    line.trim();
    int sp = line.indexOf(' ');
    String cmd = sp < 0 ? line : line.substring(0, sp);
    String arg = sp < 0 ? "" : line.substring(sp + 1);

    if (cmd == "help" || cmd == "?") Serial.print(HELP);
    else if (cmd == "status") printStatus();
    else if (cmd == "selftest") selftest();
    else if (cmd == "i2c") i2cScan();
    else if (cmd == "chg") {
      for (uint8_t r = 0; r <= 0x14; r++) {
        uint8_t v = 0;
        power::chgRead(r, v);
        Serial.printf("  REG%02X = 0x%02X\n", r, v);
      }
    } else if (cmd == "cfg") config::print();
    else if (cmd == "set") {
      int s2 = arg.indexOf(' ');
      bool ok = s2 > 0 && config::set(arg.substring(0, s2).toInt(), (uint32_t)arg.substring(s2 + 1).toInt());
      if (ok) config::save();
      Serial.println(ok ? "ok" : "invalid");
    } else if (cmd == "id") {
      bool ok = config::setNodeId(arg.toInt());
      if (ok) config::save();
      Serial.println(ok ? "ok" : "invalid (1..254)");
    } else if (cmd == "snap") app::runEvent(proto::TRIG_BUTTON);
    else if (cmd == "send") Serial.println(app::sendStatus(proto::UP_STATUS, 0xFF) ? "reply received" : "no reply");
    else if (cmd == "mic") {
      power::voutOn();
      audio::start(1000, false);
      audio::Result a = audio::wait(3000);
      power::voutOff();
      Serial.printf("ok=%d peak=%.1f dBFS rms=%.1f dBFS slot=%d\n", a.ok, a.peak_db, a.rms_db, a.channel);
    } else if (cmd == "ir") {
      if (arg == "on") power::voutOn();
      expander::write(xbit::IR_LED, arg == "on");
    } else if (cmd == "vout") {
      if (arg == "on") Serial.println(power::voutOn() ? "PG ok" : "PG low");
      else power::voutOff();
    } else if (cmd == "pir") Serial.println(digitalRead(pins::PIR));
    else if (cmd == "ls") storage::list(Serial);
    else if (cmd == "clear") storage::clear();
    else if (cmd == "maint") maintenance::run();
    else if (cmd == "factory") {
      uint8_t id = config::cfg.node_id;
      config::resetDefaults();
      config::cfg.node_id = id;
      config::save();
      Serial.println("defaults restored");
    } else if (cmd == "role") {
      if (arg == "node" || arg == "handheld") {
        config::cfg.role = arg == "handheld" ? ROLE_HANDHELD : ROLE_NODE;
        config::save();
        Serial.printf("role = %s, rebooting\n", config::roleName());
        delay(200);
        ESP.restart();
      } else Serial.printf("role is %s (use: role node | role handheld)\n", config::roleName());
    } else if (cmd == "reboot") ESP.restart();
    else if (cmd == "exit" || cmd == "sleep") return;
    else Serial.println("? (help)");
    app::processPending();
  }
}

}  // namespace console
