// TIPTOE unit-to-unit protocol (outdoor nodes <-> handheld), carried over LoRa or ESP-NOW.
//
// Every frame on air:
//   [ver:1][node:1][type:1][ctr:4 LE]  <- header, authenticated (AAD), not encrypted
//   [payload: N bytes]                 <- AES-128-GCM encrypted
//   [tag: 8 bytes]
//
// Nonce (12 B) = [dir][node][0 0 0 0 0 0][ctr LE 4]
//   uplink   (node -> handheld): dir=0, ctr = node frame counter (strictly increasing, persisted)
//   downlink (handheld -> node): dir=1, ctr = the uplink ctr being answered. The node only
//   accepts a downlink echoing the uplink it just sent, so replays are useless, and the
//   handheld answers each uplink ctr at most once (it rejects non-increasing counters and
//   persists the last one), so a nonce is never reused.
// The same frames travel over LoRa (<=255 B) and ESP-NOW (<=250 B); the frame counter is shared.
#pragma once
#include <stdint.h>
#include <stddef.h>

namespace proto {

constexpr uint8_t VERSION = 1;
constexpr size_t HDR_LEN = 7;
constexpr size_t TAG_LEN = 8;
constexpr size_t MAX_FRAME = 255;
constexpr size_t MAX_PAYLOAD = MAX_FRAME - HDR_LEN - TAG_LEN;   // 240
constexpr size_t CHUNK_DATA = 200;                              // image bytes per chunk
constexpr uint16_t MAX_CHUNKS = 240;                            // 48 KB max image over LoRa
constexpr size_t BITMAP_BYTES = (MAX_CHUNKS + 7) / 8;           // 30

// ---- Radio settings (EU868 sub-band g3: 869.40-869.65 MHz, 10% duty, <=500 mW ERP) ----
constexpr float FREQ_MHZ = 869.525f;
constexpr float BW_KHZ = 125.0f;
constexpr uint8_t SF = 7;                 // SF7: ~6 KB image in ~12 s. Use 9 for range (x4 airtime)
constexpr uint8_t CR = 5;                 // 4/5
constexpr uint8_t SYNC_WORD = 0x12;       // private network
constexpr uint16_t PREAMBLE = 8;
constexpr uint32_t REPLY_DELAY_MS = 40;   // handheld waits this long before answering on LoRa
constexpr uint32_t RX_WINDOW_MS = 1500;   // node listens this long for a reply

// ---- ESP-NOW (used when the node is close to the handheld and the handheld's Wi-Fi is on) ----
constexpr size_t ESPNOW_FRAME_MAX = 250;
constexpr size_t ESPNOW_CHUNK = 224;                            // 7 + 6 + 224 + 8 = 245 B frame
constexpr uint16_t ESPNOW_MAX_CHUNKS = 4096;                    // ~900 KB, enough for full-res JPEGs
constexpr uint32_t ESPNOW_REPLY_MS = 400;
constexpr uint8_t ESPNOW_MAX_MISSING = 80;                      // indices per RF_MISSING reply
constexpr uint32_t ESPNOW_ADVERT_VALID_S = 600;                 // node trusts an advert this long

enum MsgType : uint8_t {
  // uplink
  UP_HELLO = 0x01,        // cold boot
  UP_STATUS = 0x02,       // heartbeat / on-demand status
  UP_EVENT = 0x03,        // motion event header (image follows if img_len > 0)
  UP_CHUNK = 0x04,        // image chunk
  UP_EVENT_END = 0x05,    // all chunks sent, please report missing ones
  // downlink
  DN_REPLY = 0x81,
};

enum Trigger : uint8_t { TRIG_PIR = 1, TRIG_SNAPSHOT = 2, TRIG_BUTTON = 3 };

enum EventFlags : uint8_t {
  EVF_IR_USED = 0x01,
  EVF_CAM_FAIL = 0x02,
  EVF_NO_BUDGET = 0x04,   // image not sent: duty-cycle budget exhausted (kept locally)
  EVF_HIRES_SAVED = 0x08,
  EVF_MIC_FAIL = 0x10,
  EVF_ESPNOW = 0x20,      // image travels over ESP-NOW (full-res, ESPNOW_CHUNK-sized chunks)
};

enum ChargeState : uint8_t { CHG_NONE = 0, CHG_PRE = 1, CHG_FAST = 2, CHG_DONE = 3 };

// Config keys usable in downlink commands (values are uint32)
enum CfgKey : uint8_t {
  CFG_ARMED = 1,           // 0/1
  CFG_HEARTBEAT_MIN = 2,   // minutes between status uplinks
  CFG_COOLDOWN_S = 3,      // min seconds between image events
  CFG_JPEG_QUALITY = 4,    // 4..63 (lower = better, bigger)
  CFG_FRAMESIZE = 5,       // esp32-camera framesize_t for the LoRa image
  CFG_IR_MODE = 6,         // 0 off, 1 always, 2 auto
  CFG_IR_LUMA = 7,         // auto-IR threshold on 0..255 mean luma
  CFG_AUDIO_MS = 8,        // mic capture length
  CFG_TX_POWER = 9,        // dBm, -9..22
  CFG_SEND_IMAGE = 10,     // 0/1
  CFG_HIRES_LOCAL = 11,    // 0/1 also store a full-res JPEG in flash
  CFG_GRAYSCALE_IR = 12,   // 0/1 switch sensor to B/W when IR is on
};

enum Command : uint8_t {
  CMD_SET = 0x01,          // + key(1) + value(4)
  CMD_SNAPSHOT = 0x10,     // take and send a picture now
  CMD_REBOOT = 0x11,
  CMD_MAINTENANCE = 0x12,  // start Wi-Fi AP + web UI
  CMD_STATUS = 0x13,       // send a status uplink right away
  CMD_CLEAR_STORAGE = 0x14,
};

enum ReplyFlags : uint8_t {
  RF_HAS_TIME = 0x01,
  RF_HAS_BITMAP = 0x02,    // missing-chunk bitmap follows (bit=1 -> missing)
  RF_COMPLETE = 0x04,      // image fully received
  RF_ESPNOW = 0x08,        // handheld's Wi-Fi is on: channel(1) + AP MAC(6) follow
  RF_MISSING = 0x10,       // ESP-NOW transfer: count(1) + uint16 idx[count] of missing chunks follow
};

#pragma pack(push, 1)
struct Header {
  uint8_t ver;
  uint8_t node;
  uint8_t type;
  uint32_t ctr;
};

struct Status {            // UP_HELLO and UP_STATUS payload
  uint8_t fw_major, fw_minor;
  uint8_t reset_reason;    // esp_reset_reason_t (HELLO) / wake cause (STATUS)
  uint8_t armed;
  uint16_t soc_x10;        // 0.1 %
  uint16_t vbat_mv;
  int16_t crate_x10;       // 0.1 %/h, +charging
  uint8_t charge_state;    // ChargeState
  uint8_t charger_fault;   // BQ25895 REG0C
  uint16_t vbus_mv;        // Qi receiver output as seen by charger (0 = none)
  int8_t temp_c;           // ESP32 internal sensor (rough enclosure temp)
  int8_t last_rssi;        // of last downlink
  int8_t last_snr;
  uint16_t event_count;
  uint32_t uptime_s;       // since cold boot, across deep sleeps
  uint16_t fs_free_kb;
  uint8_t hw_ok;           // bitmask of HwBit
  // config echo (so the handheld / app show current settings)
  uint16_t heartbeat_min;
  uint16_t cooldown_s;
  uint8_t jpeg_quality;
  uint8_t framesize;
  uint8_t ir_mode;
  uint8_t ir_luma;
  uint16_t audio_ms;
  int8_t tx_power;
  uint8_t send_image;
  uint8_t hires_local;
  uint8_t grayscale_ir;
};

enum HwBit : uint8_t {
  HW_EXPANDER = 0x01, HW_CHARGER = 0x02, HW_GAUGE = 0x04, HW_CAMERA = 0x08,
  HW_MIC = 0x10, HW_VOUT_PG = 0x20, HW_FS = 0x40,
};

struct Event {             // UP_EVENT payload
  uint16_t event_id;
  uint8_t trigger;         // Trigger
  uint8_t flags;           // EventFlags
  uint32_t unix_time;      // 0 if never synced
  int8_t sound_peak_db;    // dBFS
  int8_t sound_rms_db;     // dBFS
  uint8_t luma;            // mean luma of probe frame
  uint8_t soc;             // %
  uint16_t width, height;
  uint32_t img_len;        // 0 = no image follows
  uint16_t chunks;
};

struct ChunkHdr {          // UP_CHUNK payload = ChunkHdr + data
  uint16_t event_id;
  uint16_t idx;
  uint16_t total;          // so the handheld copes with a missed UP_EVENT
};

struct EventEnd {
  uint16_t event_id;
  uint8_t round;
};

// DN_REPLY payload = ReplyHdr [+time 4] [+bitmap BITMAP_BYTES] [+espnow 7] [+missing 1+2n] [+cmds]
struct ReplyHdr {
  uint8_t flags;           // ReplyFlags
  uint8_t n_cmds;
};
#pragma pack(pop)

static_assert(sizeof(Status) <= MAX_PAYLOAD, "status too big");
static_assert(sizeof(ChunkHdr) + CHUNK_DATA <= MAX_PAYLOAD, "chunk too big");
static_assert(HDR_LEN + sizeof(ChunkHdr) + ESPNOW_CHUNK + TAG_LEN <= ESPNOW_FRAME_MAX, "espnow chunk too big");

// Encrypt payload and build a frame into out (size >= HDR_LEN+len+TAG_LEN). Returns frame length or 0.
size_t seal(const uint8_t key[16], uint8_t dir, uint8_t node, uint8_t type, uint32_t ctr,
            const uint8_t* payload, size_t len, uint8_t* out);

// Verify+decrypt a frame. On success fills hdr, writes plaintext to payload, returns payload length (>=0).
// Returns -1 on bad length/version, -2 on authentication failure.
int open(const uint8_t key[16], uint8_t dir, const uint8_t* frame, size_t frame_len, Header& hdr,
         uint8_t* payload);

}  // namespace proto
