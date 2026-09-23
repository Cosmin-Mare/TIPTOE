#include "link.h"
#include <Arduino.h>
#include <RadioLib.h>
#include <SPI.h>
#include <driver/gpio.h>
#include <esp_task_wdt.h>
#include <sys/time.h>
#include "board.h"
#include "config.h"
#include "expander.h"
#include "secrets.h"

namespace lora {

static const uint8_t KEY[16] = TIPTOE_NETWORK_KEY;

// ---- RadioLib HAL that routes "virtual" pins >= XBASE to the PCF8574 ----
static constexpr uint32_t XBASE = 0x100;

class ExpanderHal : public ArduinoHal {
 public:
  explicit ExpanderHal(SPIClass& spi) : ArduinoHal(spi, SPISettings(8000000, MSBFIRST, SPI_MODE0)) {}
  void pinMode(uint32_t pin, uint32_t mode) override {
    if (pin == RADIOLIB_NC) return;
    if (pin >= XBASE) {
      if (mode != OUTPUT) expander::write(pin - XBASE, true);   // quasi-bidir "input" = weak high
      return;
    }
    ArduinoHal::pinMode(pin, mode);
  }
  void digitalWrite(uint32_t pin, uint32_t value) override {
    if (pin == RADIOLIB_NC) return;
    if (pin >= XBASE) {
      expander::write(pin - XBASE, value != 0);
      return;
    }
    ArduinoHal::digitalWrite(pin, value);
  }
  uint32_t digitalRead(uint32_t pin) override {
    if (pin == RADIOLIB_NC) return 0;
    if (pin >= XBASE) return expander::read(pin - XBASE);
    return ArduinoHal::digitalRead(pin);
  }
};

static SPIClass s_spi(FSPI);
static ExpanderHal s_hal(s_spi);
static Module s_mod(&s_hal, pins::LORA_NSS, pins::LORA_DIO1, XBASE + xbit::LORA_NRST, pins::LORA_BUSY);
static SX1262 s_radio(&s_mod);
static bool s_ok = false;
static uint32_t s_lastUpCtr = 0;

// ---- RTC state ----
RTC_DATA_ATTR static int64_t rtc_time_offset = 0;     // added to wall clock to get monotonic
RTC_DATA_ATTR static bool rtc_time_synced = false;
RTC_DATA_ATTR static uint32_t rtc_budget_window = 0;  // mono seconds at window start
RTC_DATA_ATTR static uint32_t rtc_budget_used_ms = 0;
RTC_DATA_ATTR static float rtc_rssi = 0, rtc_snr = 0;
RTC_DATA_ATTR static uint8_t rtc_hh_channel = 0;       // handheld ESP-NOW advert (0 = none)
RTC_DATA_ATTR static uint8_t rtc_hh_mac[6] = {};
RTC_DATA_ATTR static uint32_t rtc_hh_seen = 0;         // mono seconds

static constexpr uint32_t BUDGET_WINDOW_S = 3600;
static constexpr uint32_t BUDGET_MS = 300000;   // 300 s/h, under the 360 s (10 %) legal limit

uint32_t monoSeconds() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return uint32_t(int64_t(tv.tv_sec) + rtc_time_offset);
}

void applyTime(uint32_t unix) {
  if (unix < 1700000000UL) return;
  uint32_t mono = monoSeconds();
  struct timeval tv = {(time_t)unix, 0};
  settimeofday(&tv, nullptr);
  rtc_time_offset = int64_t(mono) - int64_t(unix);   // keep monotonic seconds continuous
  rtc_time_synced = true;
}

bool timeSynced() { return rtc_time_synced; }
float lastRssi() { return rtc_rssi; }
float lastSnr() { return rtc_snr; }

static void budgetRoll() {
  uint32_t now = monoSeconds();
  if (now < rtc_budget_window || now - rtc_budget_window >= BUDGET_WINDOW_S) {
    rtc_budget_window = now;
    rtc_budget_used_ms = 0;
  }
}
bool budgetAllows(uint32_t ms) {
  budgetRoll();
  return rtc_budget_used_ms + ms <= BUDGET_MS;
}
uint32_t budgetLeftMs() {
  budgetRoll();
  return BUDGET_MS > rtc_budget_used_ms ? BUDGET_MS - rtc_budget_used_ms : 0;
}

uint32_t airtimeMs(size_t payloadLen) {
  return (s_radio.getTimeOnAir(payloadLen + proto::HDR_LEN + proto::TAG_LEN) + 999) / 1000;
}

bool begin(int8_t txPower) {
  gpio_hold_dis((gpio_num_t)pins::LORA_NSS);
  s_spi.begin(pins::LORA_SCK, pins::LORA_MISO, pins::LORA_MOSI, -1);
  s_radio.setRfSwitchPins(XBASE + xbit::LORA_RXEN, XBASE + xbit::LORA_TXEN);
  int16_t st = s_radio.begin(proto::FREQ_MHZ, proto::BW_KHZ, proto::SF, proto::CR, proto::SYNC_WORD, txPower,
                             proto::PREAMBLE, 1.8f /* E22 TCXO on DIO3 */, false);
  if (st != RADIOLIB_ERR_NONE) {
    log_e("SX1262 begin failed: %d", st);
    s_ok = false;
    return false;
  }
  s_radio.setCurrentLimit(140);
  s_radio.setCRC(2);
  s_ok = true;
  return true;
}

bool ok() { return s_ok; }

void sleep() {
  if (s_ok) s_radio.sleep(false);
  expander::write(xbit::LORA_RXEN, false);
  expander::write(xbit::LORA_TXEN, false);
  // Keep NSS high in deep sleep: a floating NSS can wake the SX1262.
  pinMode(pins::LORA_NSS, OUTPUT);
  digitalWrite(pins::LORA_NSS, HIGH);
  gpio_hold_en((gpio_num_t)pins::LORA_NSS);
  s_ok = false;
}

bool parseReply(const uint8_t* p, int n, Reply& r) {
  if (n < (int)sizeof(proto::ReplyHdr)) return false;
  proto::ReplyHdr h;
  memcpy(&h, p, sizeof(h));
  int o = sizeof(h);
  r.flags = h.flags;
  if (h.flags & proto::RF_HAS_TIME) {
    if (o + 4 > n) return false;
    memcpy(&r.unix_time, p + o, 4);
    o += 4;
  }
  if (h.flags & proto::RF_HAS_BITMAP) {
    if (o + (int)proto::BITMAP_BYTES > n) return false;
    memcpy(r.bitmap, p + o, proto::BITMAP_BYTES);
    o += proto::BITMAP_BYTES;
  }
  if (h.flags & proto::RF_ESPNOW) {
    if (o + 7 > n) return false;
    r.espnow_channel = p[o];
    memcpy(r.espnow_mac, p + o + 1, 6);
    o += 7;
  }
  if (h.flags & proto::RF_MISSING) {
    if (o + 1 > n) return false;
    uint8_t cnt = min<uint8_t>(p[o++], proto::ESPNOW_MAX_MISSING);
    if (o + 2 * cnt > n) return false;
    memcpy(r.missing, p + o, 2 * cnt);
    r.n_missing = cnt;
    o += 2 * cnt;
  }
  r.n_cmds = 0;
  for (uint8_t i = 0; i < h.n_cmds && o < n && r.n_cmds < 8; i++) {
    Cmd c{p[o++], 0, 0};
    if (c.op == proto::CMD_SET) {
      if (o + 5 > n) break;
      c.key = p[o];
      memcpy(&c.value, p + o + 1, 4);
      o += 5;
    }
    r.cmds[r.n_cmds++] = c;
  }
  return true;
}

void noteReply(const Reply& r) {
  if (!r.received) return;
  if (r.flags & proto::RF_HAS_TIME) applyTime(r.unix_time);
  if (r.flags & proto::RF_ESPNOW) {
    rtc_hh_channel = r.espnow_channel;
    memcpy(rtc_hh_mac, r.espnow_mac, 6);
    rtc_hh_seen = monoSeconds();
  } else {
    rtc_hh_channel = 0;   // handheld says its Wi-Fi is off
  }
}

bool handheldEspNow(uint8_t& channel, uint8_t mac[6]) {
  if (!rtc_hh_channel || monoSeconds() - rtc_hh_seen > proto::ESPNOW_ADVERT_VALID_S) return false;
  channel = rtc_hh_channel;
  memcpy(mac, rtc_hh_mac, 6);
  return true;
}

void clearHandheldEspNow() { rtc_hh_channel = 0; }

// ---- handheld side: raw frames ----
bool rxStart() { return s_ok && s_radio.startReceive() == RADIOLIB_ERR_NONE; }

int rxPoll(uint8_t* buf, float& rssi, float& snr) {
  if (!s_ok || !digitalRead(pins::LORA_DIO1)) return -1;
  size_t len = s_radio.getPacketLength();
  int16_t st = s_radio.readData(buf, min(len, proto::MAX_FRAME));
  rssi = s_radio.getRSSI();
  snr = s_radio.getSNR();
  s_radio.startReceive();                 // re-arm immediately; the node streams chunks back-to-back
  return st == RADIOLIB_ERR_NONE ? (int)len : 0;
}

bool txRaw(const uint8_t* frame, size_t len) {
  if (!s_ok) return false;
  uint32_t air = airtimeMs(len - proto::HDR_LEN - proto::TAG_LEN);
  if (!budgetAllows(air)) return false;
  rtc_budget_used_ms += air;
  return s_radio.transmit(frame, len) == RADIOLIB_ERR_NONE;
}

static bool listen(Reply& r) {
  if (s_radio.startReceive() != RADIOLIB_ERR_NONE) return false;
  uint32_t t0 = millis();
  while (millis() - t0 < proto::RX_WINDOW_MS) {
    if (digitalRead(pins::LORA_DIO1)) {
      uint8_t buf[proto::MAX_FRAME];
      size_t len = s_radio.getPacketLength();
      int16_t st = s_radio.readData(buf, len);
      if (st == RADIOLIB_ERR_NONE) {
        proto::Header h;
        uint8_t pt[proto::MAX_PAYLOAD];
        int n = proto::open(KEY, 1, buf, len, h, pt);
        if (n >= 0 && h.type == proto::DN_REPLY && h.node == config::cfg.node_id && h.ctr == s_lastUpCtr) {
          r.received = parseReply(pt, n, r);
          r.rssi = rtc_rssi = s_radio.getRSSI();
          r.snr = rtc_snr = s_radio.getSNR();
          noteReply(r);
          s_radio.standby();
          return r.received;
        }
      }
      s_radio.startReceive();   // not for us / bad CRC: keep listening
    }
    delay(2);
  }
  s_radio.standby();
  return false;
}

bool send(uint8_t type, const void* payload, size_t len, Reply* reply) {
  if (!s_ok) return false;
  esp_task_wdt_reset();
  uint32_t air = airtimeMs(len);
  if (!budgetAllows(air)) {
    log_w("duty-cycle budget exhausted (%u ms left)", budgetLeftMs());
    return false;
  }
  uint8_t frame[proto::MAX_FRAME];
  uint32_t ctr = config::nextFrameCounter();
  size_t n = proto::seal(KEY, 0, config::cfg.node_id, type, ctr, (const uint8_t*)payload, len, frame);
  if (!n) return false;
  int16_t st = s_radio.transmit(frame, n);
  rtc_budget_used_ms += air;
  if (st != RADIOLIB_ERR_NONE) {
    log_e("tx failed: %d", st);
    return false;
  }
  s_lastUpCtr = ctr;
  if (reply) {
    *reply = Reply();
    return listen(*reply);
  }
  return true;
}

bool sendEvent(proto::Event& ev, const uint8_t* jpeg, size_t len, Reply* lastReply) {
  uint16_t chunks = len ? (len + proto::CHUNK_DATA - 1) / proto::CHUNK_DATA : 0;
  if (chunks > proto::MAX_CHUNKS) {
    log_w("image too big for LoRa (%u B)", (unsigned)len);
    chunks = 0;
  }
  // Worst case: header + all chunks + ~30 % resends + a few END frames
  uint32_t chunkAir = airtimeMs(sizeof(proto::ChunkHdr) + proto::CHUNK_DATA);
  uint32_t need = airtimeMs(sizeof(ev)) + chunks * chunkAir * 13 / 10 + 3 * airtimeMs(sizeof(proto::EventEnd));
  if (chunks && !budgetAllows(need)) {
    ev.flags |= proto::EVF_NO_BUDGET;
    chunks = 0;
  }
  ev.img_len = chunks ? len : 0;
  ev.chunks = chunks;

  Reply r;
  if (!chunks) {                    // header only: ask for a reply so commands can come down
    bool ok = send(proto::UP_EVENT, &ev, sizeof(ev), &r);
    if (lastReply) *lastReply = r;
    return ok && r.received;
  }
  send(proto::UP_EVENT, &ev, sizeof(ev));

  uint8_t buf[sizeof(proto::ChunkHdr) + proto::CHUNK_DATA];
  uint8_t missing[proto::BITMAP_BYTES];
  memset(missing, 0, sizeof(missing));
  for (uint16_t i = 0; i < chunks; i++) missing[i / 8] |= 1 << (i % 8);

  for (uint8_t round = 0; round < 5; round++) {
    for (uint16_t i = 0; i < chunks; i++) {
      if (!(missing[i / 8] & (1 << (i % 8)))) continue;
      proto::ChunkHdr ch{ev.event_id, i, chunks};
      size_t off = size_t(i) * proto::CHUNK_DATA;
      size_t n = min(proto::CHUNK_DATA, len - off);
      memcpy(buf, &ch, sizeof(ch));
      memcpy(buf + sizeof(ch), jpeg + off, n);
      if (!send(proto::UP_CHUNK, buf, sizeof(ch) + n)) {
        if (!budgetAllows(chunkAir)) return false;
      }
      delay(15);                                          // let the handheld re-arm RX
    }
    proto::EventEnd end{ev.event_id, round};
    bool got = false;
    for (int t = 0; t < 3 && !got; t++) got = send(proto::UP_EVENT_END, &end, sizeof(end), &r);
    if (lastReply) *lastReply = r;
    if (!got) return false;                               // handheld unreachable
    if (r.flags & proto::RF_COMPLETE) return true;
    if (!(r.flags & proto::RF_HAS_BITMAP)) return false;
    memcpy(missing, r.bitmap, sizeof(missing));
    int m = 0;
    for (uint16_t i = 0; i < chunks; i++) m += (missing[i / 8] >> (i % 8)) & 1;
    log_i("round %u: %d chunks missing", round, m);
    if (m == 0) return true;
  }
  return false;
}

}  // namespace lora
