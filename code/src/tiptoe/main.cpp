// TIPTOE firmware entry point. role=handheld -> handheld::run() (never returns).
// role=node (default) -> wake, do one job, deep sleep.
//
// Wake sources
//   cold boot  -> hardware init, optional USB console, HELLO uplink, PIR warm-up (60 s)
//   PIR (IO3)  -> event: photo (auto IR) + sound level, archive to flash, send over LoRa
//   BOOT (IO0) -> Wi-Fi maintenance mode (web UI, archive, OTA)
//   timer      -> heartbeat status uplink (downlink commands arrive in its reply window)
#include <Arduino.h>
#include <driver/gpio.h>
#include <driver/rtc_io.h>
#include <esp_sleep.h>
#include <esp_task_wdt.h>
#include "app.h"
#include "camera.h"
#include "board.h"
#include "config.h"
#include "console.h"
#include "expander.h"
#include "handheld.h"
#include "link.h"
#include "maintenance.h"
#include "power.h"
#include "protocol.h"

static constexpr uint32_t PIR_WARMUP_S = 60;       // HC-SR501 settles after power-up
static constexpr uint32_t PIR_BUSY_RECHECK_S = 5;  // PIR still high -> re-check instead of ext0
RTC_DATA_ATTR static uint32_t rtc_next_heartbeat = 0;

static void scheduleHeartbeat() {
  uint32_t min = config::cfg.heartbeat_min;
  if (app::batteryCritical()) min = max<uint32_t>(min, 180);
  rtc_next_heartbeat = lora::monoSeconds() + min * 60;
}

[[noreturn]] static void goToSleep() {
  lora::sleep();
  power::voutOff();
  expander::write(xbit::IR_LED, false);

  // Hold the buck-boost off and NSS high through deep sleep.
  digitalWrite(pins::VOUT_EN, LOW);
  gpio_hold_en((gpio_num_t)pins::VOUT_EN);
  gpio_deep_sleep_hold_en();

  uint32_t now = lora::monoSeconds();
  uint32_t sleepS = rtc_next_heartbeat > now ? rtc_next_heartbeat - now : 1;
  bool pirHigh = digitalRead(pins::PIR);
  bool armPir = config::cfg.armed && app::pirWarm() && !app::batteryCritical();

  if (!app::pirWarm()) sleepS = min<uint32_t>(sleepS, PIR_WARMUP_S);
  if (armPir && pirHigh) sleepS = min<uint32_t>(sleepS, PIR_BUSY_RECHECK_S);   // wait for PIR hold time to end
  else if (armPir) esp_sleep_enable_ext0_wakeup((gpio_num_t)pins::PIR, 1);
  esp_sleep_enable_ext1_wakeup(1ULL << pins::BTN_BOOT, ESP_EXT1_WAKEUP_ANY_LOW);
  esp_sleep_enable_timer_wakeup(uint64_t(max<uint32_t>(sleepS, 1)) * 1000000ULL);

  log_i("sleep %us (pir %s)", sleepS, armPir ? (pirHigh ? "busy" : "armed") : "off");
  Serial.flush();
  esp_deep_sleep_start();
}

static void handleAfterReply() {
  app::processPending();
  if (app::pending.reboot) ESP.restart();
  if (app::pending.maintenance) {
    app::pending.maintenance = false;
    esp_task_wdt_delete(nullptr);
    maintenance::run();
    esp_task_wdt_add(nullptr);
  }
}

void setup() {
  // First thing: stop UART0 TX (GPIO43) from driving 3.3 V into the unpowered camera SCCB line.
  camera::releasePins();
  Serial.begin(115200);
  Serial.setTxTimeoutMs(0);   // don't block when no USB host is attached

  // Anything hanging (camera, radio, I2C) must not flatten the battery.
  esp_task_wdt_init(90, true);
  esp_task_wdt_add(nullptr);

  esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  bool cold = cause == ESP_SLEEP_WAKEUP_UNDEFINED;
  app::initHardware(cold);

  if (config::cfg.role == ROLE_HANDHELD) {
    if (cold && console::offer()) {
      esp_task_wdt_delete(nullptr);
      console::run();
      esp_task_wdt_add(nullptr);
      if (config::cfg.role != ROLE_HANDHELD) ESP.restart();
    }
    handheld::run();
  }

  switch (cause) {
    case ESP_SLEEP_WAKEUP_EXT0:   // PIR
      if (config::cfg.armed) app::runEvent(proto::TRIG_PIR);
      handleAfterReply();
      break;

    case ESP_SLEEP_WAKEUP_EXT1:   // BOOT button
      esp_task_wdt_delete(nullptr);
      maintenance::run();
      esp_task_wdt_add(nullptr);
      break;

    case ESP_SLEEP_WAKEUP_TIMER: {
      uint32_t now = lora::monoSeconds();
      if (!app::pirWarm() && now - app::coldBootMono() >= PIR_WARMUP_S) app::setPirWarm();
      // PIR was still high when we slept (hold time / continuous motion): treat as ongoing motion.
      if (config::cfg.armed && app::pirWarm() && !app::batteryCritical() && digitalRead(pins::PIR)) {
        app::runEvent(proto::TRIG_PIR);
        handleAfterReply();
      }
      if (now + 2 >= rtc_next_heartbeat) {
        app::sendStatus(proto::UP_STATUS, cause);
        scheduleHeartbeat();
        handleAfterReply();
      }
      break;
    }

    default: {                    // cold boot / reset button / brown-out
      if (console::offer()) {
        esp_task_wdt_delete(nullptr);
        console::run();
        esp_task_wdt_add(nullptr);
      }
      app::sendStatus(proto::UP_HELLO, (uint8_t)esp_reset_reason());
      scheduleHeartbeat();
      handleAfterReply();
      break;
    }
  }
  if (rtc_next_heartbeat == 0) scheduleHeartbeat();
  goToSleep();
}

void loop() {}
