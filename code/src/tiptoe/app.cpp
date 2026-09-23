#include "app.h"
#include <Arduino.h>
#include <Wire.h>
#include <driver/gpio.h>
#include <driver/rtc_io.h>
#include <esp_sleep.h>
#include "audio.h"
#include "board.h"
#include "camera.h"
#include "config.h"
#include "espnow_link.h"
#include "expander.h"
#include "power.h"
#include "storage.h"

namespace app {

Pending pending;

RTC_DATA_ATTR static uint16_t rtc_event_count = 0;
RTC_DATA_ATTR static uint32_t rtc_last_image_mono = 0;
RTC_DATA_ATTR static uint32_t rtc_last_tx_mono = 0;
RTC_DATA_ATTR static uint32_t rtc_cold_mono = 0;
RTC_DATA_ATTR static bool rtc_pir_warm = false;
RTC_DATA_ATTR static bool rtc_cam_ok = true, rtc_mic_ok = true, rtc_pg_ok = true;
RTC_DATA_ATTR static float rtc_soc = 100;
RTC_DATA_ATTR static bool rtc_charging = false;

bool pirWarm() { return rtc_pir_warm; }
void setPirWarm() { rtc_pir_warm = true; }
uint32_t coldBootMono() { return rtc_cold_mono; }
uint16_t eventCount() { return rtc_event_count; }

void initBus() {
  Wire.begin(pins::I2C_SDA, pins::I2C_SCL, 100000);   // PCF8574 is a 100 kHz part
}

void initHardware(bool coldBoot) {
  gpio_hold_dis((gpio_num_t)pins::VOUT_EN);
  pinMode(pins::VOUT_EN, OUTPUT);
  digitalWrite(pins::VOUT_EN, LOW);
  // ext0/ext1 wake leaves these pads in RTC mode; hand them back to the digital GPIO matrix.
  rtc_gpio_deinit((gpio_num_t)pins::PIR);
  rtc_gpio_deinit((gpio_num_t)pins::BTN_BOOT);
  pinMode(pins::PIR, INPUT);
  pinMode(pins::BTN_BOOT, INPUT_PULLUP);
  pinMode(pins::EXP_INT, INPUT_PULLUP);
  pinMode(pins::LORA_DIO1, INPUT);

  initBus();
  if (!expander::begin()) log_e("PCF8574 not responding at 0x20");
  config::load();
  power::begin(coldBoot);
  storage::begin();
  if (coldBoot) {
    rtc_cold_mono = lora::monoSeconds();
    rtc_pir_warm = false;
    rtc_event_count = 0;
  }
  if (!lora::begin(config::cfg.tx_power)) log_e("radio init failed");
}

bool batteryCritical() { return rtc_soc < 5 && !rtc_charging; }

uint8_t hwMask() {
  uint8_t m = 0;
  power::Info pi = power::read(false);
  if (expander::ok()) m |= proto::HW_EXPANDER;
  if (pi.charger_ok) m |= proto::HW_CHARGER;
  if (pi.gauge_ok) m |= proto::HW_GAUGE;
  if (rtc_cam_ok) m |= proto::HW_CAMERA;
  if (rtc_mic_ok) m |= proto::HW_MIC;
  if (rtc_pg_ok) m |= proto::HW_VOUT_PG;
  if (storage::ok()) m |= proto::HW_FS;
  return m;
}

proto::Status buildStatus(uint8_t reason) {
  power::Info pi = power::read(true);
  if (pi.soc >= 0) rtc_soc = pi.soc;
  rtc_charging = pi.chg_state == proto::CHG_PRE || pi.chg_state == proto::CHG_FAST;
  proto::Status s = {};
  s.fw_major = FW_MAJOR;
  s.fw_minor = FW_MINOR;
  s.reset_reason = reason;
  s.armed = config::cfg.armed;
  s.soc_x10 = pi.soc >= 0 ? uint16_t(pi.soc * 10) : 0xFFFF;
  s.vbat_mv = pi.vbat_mv;
  s.crate_x10 = int16_t(pi.crate * 10);
  s.charge_state = pi.chg_state;
  s.charger_fault = pi.fault;
  s.vbus_mv = pi.vbus_mv;
  s.temp_c = (int8_t)constrain((int)temperatureRead(), -127, 127);
  s.last_rssi = (int8_t)constrain((int)lora::lastRssi(), -127, 0);
  s.last_snr = (int8_t)constrain((int)lora::lastSnr(), -127, 127);
  s.event_count = rtc_event_count;
  s.uptime_s = lora::monoSeconds() - rtc_cold_mono;
  s.fs_free_kb = uint16_t(min<size_t>(storage::freeBytes() / 1024, 65535));
  s.hw_ok = hwMask();
  const NodeConfig& c = config::cfg;
  s.heartbeat_min = c.heartbeat_min;
  s.cooldown_s = c.cooldown_s;
  s.jpeg_quality = c.jpeg_quality;
  s.framesize = c.framesize;
  s.ir_mode = c.ir_mode;
  s.ir_luma = c.ir_luma;
  s.audio_ms = c.audio_ms;
  s.tx_power = c.tx_power;
  s.send_image = c.send_image;
  s.hires_local = c.hires_local;
  s.grayscale_ir = c.grayscale_ir;
  return s;
}

void handleReply(const lora::Reply& r) {
  if (!r.received) return;
  for (uint8_t i = 0; i < r.n_cmds; i++) {
    const lora::Cmd& c = r.cmds[i];
    switch (c.op) {
      case proto::CMD_SET:
        if (config::set(c.key, c.value)) pending.cfg_changed = true;
        else log_w("rejected cfg key %u = %u", c.key, c.value);
        break;
      case proto::CMD_SNAPSHOT: pending.snapshot = true; break;
      case proto::CMD_REBOOT: pending.reboot = true; break;
      case proto::CMD_MAINTENANCE: pending.maintenance = true; break;
      case proto::CMD_STATUS: pending.status = true; break;
      case proto::CMD_CLEAR_STORAGE: pending.clear = true; break;
    }
  }
  if (pending.cfg_changed) {
    config::save();
    pending.cfg_changed = false;
    pending.status = true;   // report the new state back
  }
}

bool sendStatus(uint8_t type, uint8_t reason) {
  proto::Status s = buildStatus(reason);
  lora::Reply r;
  bool ok = lora::send(type, &s, sizeof(s), &r);
  rtc_last_tx_mono = lora::monoSeconds();
  handleReply(r);
  log_i("status sent=%d reply=%d rssi=%.0f", ok, r.received, r.rssi);
  return ok && r.received;
}

static String metaText(const proto::Event& ev, const camera::Result& cam, const audio::Result& aud) {
  char buf[256];
  snprintf(buf, sizeof(buf),
           "id=%u\ntrigger=%u\nunix=%u\nmono=%u\nluma=%u\nir=%u\nsound_peak_db=%.1f\nsound_rms_db=%.1f\n"
           "soc=%u\nw=%u\nh=%u\nflags=0x%02x\n",
           ev.event_id, ev.trigger, (unsigned)ev.unix_time, (unsigned)lora::monoSeconds(), cam.luma, cam.ir_used,
           aud.peak_db, aud.rms_db, ev.soc, cam.lora.width, cam.lora.height, ev.flags);
  return buf;
}

void runEvent(uint8_t trigger) {
  const NodeConfig& c = config::cfg;
  uint32_t now = lora::monoSeconds();
  proto::Event ev = {};
  ev.trigger = trigger;
  ev.unix_time = lora::timeSynced() ? (uint32_t)time(nullptr) : 0;
  power::Info pi = power::read(false);
  if (pi.soc >= 0) rtc_soc = pi.soc;
  ev.soc = uint8_t(rtc_soc);
  rtc_event_count++;

  bool cooldown = trigger == proto::TRIG_PIR && rtc_last_image_mono && now - rtc_last_image_mono < c.cooldown_s;
  if (cooldown) {
    // Motion keeps going: tell the handheld cheaply (header only), at most every 10 s.
    if (now - rtc_last_tx_mono >= 10) {
      ev.event_id = config::nextEventId();
      ev.sound_peak_db = ev.sound_rms_db = -120;
      lora::Reply r;
      lora::sendEvent(ev, nullptr, 0, &r);
      rtc_last_tx_mono = lora::monoSeconds();
      handleReply(r);
    }
    return;
  }

  ev.event_id = config::nextEventId();
  bool low = rtc_soc < 15 && !rtc_charging;
  uint8_t hhChannel = 0, hhMac[6];
  bool espnowPossible = c.send_image && !low && lora::handheldEspNow(hhChannel, hhMac);
  rtc_pg_ok = power::voutOn();
  bool micStarted = c.audio_ms > 0 && !low && audio::start(c.audio_ms, true);
  camera::Result cam = camera::capture(c.framesize, c.jpeg_quality, c.ir_mode, c.ir_luma,
                                       (c.hires_local || espnowPossible) && !low, c.grayscale_ir);
  audio::Result aud;
  if (micStarted) aud = audio::wait(c.audio_ms + 3000);
  power::voutOff();

  rtc_cam_ok = cam.ok;
  if (micStarted) rtc_mic_ok = aud.ok;
  ev.flags |= cam.ok ? 0 : proto::EVF_CAM_FAIL;
  ev.flags |= cam.ir_used ? proto::EVF_IR_USED : 0;
  ev.flags |= (micStarted && !aud.ok) ? proto::EVF_MIC_FAIL : 0;
  ev.flags |= cam.hires.len ? proto::EVF_HIRES_SAVED : 0;
  ev.sound_peak_db = aud.ok ? (int8_t)constrain((int)aud.peak_db, -120, 0) : -120;
  ev.sound_rms_db = aud.ok ? (int8_t)constrain((int)aud.rms_db, -120, 0) : -120;
  ev.luma = cam.luma;
  ev.width = cam.lora.width;
  ev.height = cam.lora.height;

  // Local archive first — it survives a failed radio transfer.
  if (storage::ok()) {
    storage::prune(cam.hires.len + cam.lora.len + aud.samples * 2 + 1500 * 1024);
    String base = "/ev/" + String(ev.event_id);
    if (cam.lora.len) storage::writeFile(base + ".jpg", cam.lora.data, cam.lora.len);
    if (cam.hires.len) storage::writeFile(base + "_hi.jpg", cam.hires.data, cam.hires.len);
    if (aud.samples) {
      uint8_t h[44];
      audio::wavHeader(aud, h);
      storage::writeFile(base + ".wav", h, 44, (const uint8_t*)aud.pcm, aud.samples * 2);
    }
    storage::writeText(base + ".txt", metaText(ev, cam, aud));
  }
  audio::release(aud);

  bool sendImg = c.send_image && cam.ok;
  lora::Reply r;
  bool sent = false;
  // Handheld nearby with Wi-Fi on: push the full-res photo over ESP-NOW (seconds, not minutes).
  if (sendImg && espnowPossible && espnow_link::begin(hhChannel, hhMac)) {
    const camera::Image& img = cam.hires.len ? cam.hires : cam.lora;
    proto::Event full = ev;
    full.width = img.width;
    full.height = img.height;
    sent = espnow_link::sendEvent(full, img.data, img.len, &r);
    espnow_link::end();
    if (!sent) lora::clearHandheldEspNow();   // out of range: don't try again until re-advertised
    log_i("event %u via ESP-NOW: %s (%u B)", ev.event_id, sent ? "ok" : "failed", (unsigned)img.len);
  }
  // Otherwise (or if that failed): small photo over LoRa.
  if (!sent) sent = lora::sendEvent(ev, sendImg ? cam.lora.data : nullptr, sendImg ? cam.lora.len : 0, &r);
  rtc_last_tx_mono = lora::monoSeconds();
  if (cam.ok) rtc_last_image_mono = now;
  log_i("event %u: cam=%d %ux%u %uB ir=%d luma=%u sound=%.0fdB sent=%d", ev.event_id, cam.ok, cam.lora.width,
        cam.lora.height, (unsigned)cam.lora.len, cam.ir_used, cam.luma, (float)ev.sound_peak_db, sent);
  camera::release(cam);
  handleReply(r);
}

void processPending() {
  for (int guard = 0; guard < 4; guard++) {
    if (pending.clear) {
      pending.clear = false;
      storage::clear();
    }
    if (pending.snapshot) {
      pending.snapshot = false;
      runEvent(proto::TRIG_SNAPSHOT);
      continue;
    }
    if (pending.status) {
      pending.status = false;
      sendStatus(proto::UP_STATUS, 0xFE);
      continue;
    }
    break;
  }
}

}  // namespace app
