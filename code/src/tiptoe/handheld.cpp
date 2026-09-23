#include "handheld.h"
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <esp_sleep.h>
#include <esp_task_wdt.h>
#include <vector>
#include "board.h"
#include "config.h"
#include "link.h"
#include "power.h"
#include "protocol.h"
#include "secrets.h"
#include "storage.h"

namespace handheld {

static const uint8_t KEY[16] = TIPTOE_NETWORK_KEY;
static Preferences s_prefs;
static uint32_t s_seq = 0;   // handheld-wide event sequence number (the app's event id)

static const char* CFG_NAMES[] = {nullptr,      "armed",   "heartbeat_min", "cooldown_s", "jpeg_quality",
                                  "framesize",  "ir_mode", "ir_luma",       "audio_ms",   "tx_power",
                                  "send_image", "hires_local", "grayscale_ir"};
static constexpr int N_CFG = sizeof(CFG_NAMES) / sizeof(CFG_NAMES[0]);

struct PendingCmd {
  uint8_t op, key;
  uint32_t value;
};

struct Node {
  bool seen = false;
  uint32_t last_ctr = 0;
  bool ctr_loaded = false;
  std::vector<PendingCmd> cmds;
  // image being assembled
  uint16_t evt = 0, total = 0, chunk = 0;
  uint8_t* buf = nullptr;
  size_t last_len = 0;
  std::vector<uint8_t> have;
  uint32_t started = 0;
  Via via = VIA_LORA;
  proto::Event meta = {};
  bool meta_valid = false;
  // last contact
  String status;             // last status JSON object
  uint32_t last_ms = 0;
  float rssi = 0, snr = 0;
  Via last_via = VIA_LORA;
};
static Node s_nodes[256];

struct Done {                // completed transfer, stored after the reply went out
  uint8_t node;
  uint8_t* buf;
  size_t len;
  bool full;
  proto::Event meta;
  bool meta_valid;
  Via via;
  float rssi;
};
static std::vector<Done> s_done;

// ------------------------------------------------------------------------------------ helpers
static const char* viaName(Via v) { return v == VIA_ESPNOW ? "espnow" : "lora"; }

static uint32_t loadCtr(uint8_t id) {
  Node& n = s_nodes[id];
  if (!n.ctr_loaded) {
    char k[6];
    snprintf(k, sizeof(k), "c%u", id);
    n.last_ctr = s_prefs.getUInt(k, 0);
    n.ctr_loaded = true;
  }
  return n.last_ctr;
}

static void persistCtr(uint8_t id) {
  char k[6];
  snprintf(k, sizeof(k), "c%u", id);
  s_prefs.putUInt(k, s_nodes[id].last_ctr);
}

static uint32_t nowUnix() { return lora::timeSynced() ? (uint32_t)time(nullptr) : 0; }

void push(const String& json) { hhble::pushJson(json); }

static void pushPending(uint8_t id) {
  push("{\"t\":\"pending\",\"node\":" + String(id) + ",\"count\":" + String(s_nodes[id].cmds.size()) + "}");
}

static void queueCmd(uint8_t id, uint8_t op, uint8_t key = 0, uint32_t value = 0) {
  auto& q = s_nodes[id].cmds;
  if (op == proto::CMD_SET)   // newest value for a key wins
    for (auto it = q.begin(); it != q.end();) it = (it->op == op && it->key == key) ? q.erase(it) : it + 1;
  else
    for (auto it = q.begin(); it != q.end();) it = (it->op == op) ? q.erase(it) : it + 1;
  if (q.size() < 8) q.push_back({op, key, value});
  pushPending(id);
}

// ------------------------------------------------------------------------------------ replies
static size_t buildReply(uint8_t id, uint32_t ctr, Via via, uint8_t flags, const uint8_t* bitmap,
                         const uint16_t* missing, uint8_t nMissing, bool withCmds, uint8_t* out) {
  uint8_t pl[proto::MAX_PAYLOAD];
  const size_t maxPl = (via == VIA_ESPNOW ? proto::ESPNOW_FRAME_MAX : proto::MAX_FRAME) - proto::HDR_LEN - proto::TAG_LEN;
  size_t o = sizeof(proto::ReplyHdr);
  uint32_t t = nowUnix();
  if (t) {
    flags |= proto::RF_HAS_TIME;
    memcpy(pl + o, &t, 4);
    o += 4;
  }
  if (bitmap) {
    flags |= proto::RF_HAS_BITMAP;
    memcpy(pl + o, bitmap, proto::BITMAP_BYTES);
    o += proto::BITMAP_BYTES;
  }
  if (hhwifi::on()) {   // advertise ESP-NOW so nearby nodes send full-res photos directly
    flags |= proto::RF_ESPNOW;
    pl[o++] = hhwifi::channel();
    hhwifi::apMac(pl + o);
    o += 6;
  }
  if (missing) {
    flags |= proto::RF_MISSING;
    pl[o++] = nMissing;
    memcpy(pl + o, missing, 2 * nMissing);
    o += 2 * nMissing;
  }
  uint8_t n = 0;
  auto& q = s_nodes[id].cmds;
  if (withCmds) {
    while (!q.empty() && o + 6 <= maxPl && n < 8) {
      PendingCmd c = q.front();
      pl[o++] = c.op;
      if (c.op == proto::CMD_SET) {
        pl[o++] = c.key;
        memcpy(pl + o, &c.value, 4);
        o += 4;
      }
      q.erase(q.begin());
      n++;
    }
    if (n) pushPending(id);
  }
  proto::ReplyHdr h{flags, n};
  memcpy(pl, &h, sizeof(h));
  return proto::seal(KEY, 1, id, proto::DN_REPLY, ctr, pl, o, out);
}

// ------------------------------------------------------------------------------------ JSON
static void statusToJson(const proto::Status& s, JsonDocument& d) {
  static const char* chg[] = {"not charging", "pre-charge", "fast charging", "charged"};
  static const char* ntc[] = {"normal", "?", "warm", "cool", "?", "cold", "hot", "?"};
  d["fw"] = String(s.fw_major) + "." + String(s.fw_minor);
  d["armed"] = s.armed;
  if (s.soc_x10 != 0xFFFF) d["soc"] = s.soc_x10 / 10.0;
  d["vbat_mv"] = s.vbat_mv;
  d["crate_pct_h"] = s.crate_x10 / 10.0;
  d["charge"] = chg[s.charge_state & 3];
  d["ntc"] = ntc[s.charger_fault & 7];
  d["charger_fault"] = s.charger_fault;
  d["qi_mv"] = s.vbus_mv;
  d["temp_c"] = s.temp_c;
  d["node_rssi"] = s.last_rssi;
  d["event_count"] = s.event_count;
  d["uptime_s"] = s.uptime_s;
  d["fs_free_kb"] = s.fs_free_kb;
  d["hw_ok"] = s.hw_ok;
  JsonObject c = d["config"].to<JsonObject>();
  c["armed"] = s.armed;
  c["heartbeat_min"] = s.heartbeat_min;
  c["cooldown_s"] = s.cooldown_s;
  c["jpeg_quality"] = s.jpeg_quality;
  c["framesize"] = s.framesize;
  c["ir_mode"] = s.ir_mode;
  c["ir_luma"] = s.ir_luma;
  c["audio_ms"] = s.audio_ms;
  c["tx_power"] = s.tx_power;
  c["send_image"] = s.send_image;
  c["hires_local"] = s.hires_local;
  c["grayscale_ir"] = s.grayscale_ir;
}

static void eventToJson(uint8_t node, const proto::Event& e, JsonDocument& d) {
  d["node"] = node;
  d["event_id"] = e.event_id;
  d["trigger"] = e.trigger == proto::TRIG_PIR ? "pir" : e.trigger == proto::TRIG_SNAPSHOT ? "snapshot" : "button";
  d["time"] = e.unix_time;
  d["ir"] = bool(e.flags & proto::EVF_IR_USED);
  d["camera_failed"] = bool(e.flags & proto::EVF_CAM_FAIL);
  d["no_budget"] = bool(e.flags & proto::EVF_NO_BUDGET);
  d["hires_on_node"] = bool(e.flags & proto::EVF_HIRES_SAVED);
  d["sound_peak_db"] = e.sound_peak_db;
  d["sound_rms_db"] = e.sound_rms_db;
  d["luma"] = e.luma;
  d["soc"] = e.soc;
  d["width"] = e.width;
  d["height"] = e.height;
  d["img_len"] = e.img_len;
}

String handheldJson() {
  power::Info p = power::read(false);
  JsonDocument d;
  d["t"] = "handheld";
  d["fw"] = String(FW_MAJOR) + "." + String(FW_MINOR);
  if (p.soc >= 0) d["soc"] = p.soc;
  d["vbat_mv"] = p.vbat_mv;
  d["charge"] = power::chargeStateStr(p.chg_state);
  d["ntc"] = power::ntcFaultStr(p.fault);
  d["wifi"] = hhwifi::on();
  d["time_synced"] = lora::timeSynced();
  d["uptime_s"] = millis() / 1000;
  d["fs_free_kb"] = storage::freeBytes() / 1024;
  d["lora_budget_ms"] = lora::budgetLeftMs();
  d["lora_ok"] = lora::ok();
  String s;
  serializeJson(d, s);
  return s;
}

String nodesJson() {
  JsonDocument d;
  d["t"] = "nodes";
  JsonArray a = d["nodes"].to<JsonArray>();
  for (int id = 1; id < 255; id++) {
    Node& n = s_nodes[id];
    if (!n.seen && n.status.isEmpty()) continue;
    JsonObject o = a.add<JsonObject>();
    o["node"] = id;
    o["age_s"] = n.last_ms ? (millis() - n.last_ms) / 1000 : -1;
    o["rssi"] = n.rssi;
    o["snr"] = n.snr;
    o["via"] = viaName(n.last_via);
    o["pending"] = n.cmds.size();
    if (!n.status.isEmpty()) {
      JsonDocument st;
      if (!deserializeJson(st, n.status)) o["status"] = st;
    }
  }
  String s;
  serializeJson(d, s);
  return s;
}

// ------------------------------------------------------------------------------------ archive
static void pruneFor(size_t need) {
  const size_t reserve = 1500 * 1024;
  if (storage::freeBytes() >= need + reserve) return;
  std::vector<uint32_t> seqs;
  File dir = LittleFS.open("/hh");
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
    String nm = f.name();
    if (nm.startsWith("e") && nm.endsWith(".json")) seqs.push_back(nm.substring(1).toInt());
  }
  dir.close();
  std::sort(seqs.begin(), seqs.end());
  for (uint32_t s : seqs) {
    if (storage::freeBytes() >= need + reserve) break;
    String b = "/hh/e" + String(s);
    LittleFS.remove(b + ".json");
    LittleFS.remove(b + ".jpg");
    LittleFS.remove(b + "f.jpg");
  }
}

String imagePath(uint32_t seq, bool full) {
  String b = "/hh/e" + String(seq);
  if (full && LittleFS.exists(b + "f.jpg")) return b + "f.jpg";
  if (LittleFS.exists(b + ".jpg")) return b + ".jpg";
  if (LittleFS.exists(b + "f.jpg")) return b + "f.jpg";
  return "";
}

String eventsJson(int node, int limit, uint32_t before) {
  std::vector<uint32_t> seqs;
  File dir = LittleFS.open("/hh");
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
    String nm = f.name();
    if (nm.startsWith("e") && nm.endsWith(".json")) {
      uint32_t s = nm.substring(1).toInt();
      if (!before || s < before) seqs.push_back(s);
    }
  }
  dir.close();
  std::sort(seqs.rbegin(), seqs.rend());
  String out = "{\"t\":\"events\",\"events\":[";
  int n = 0;
  for (uint32_t s : seqs) {
    if (n >= limit) break;
    File f = LittleFS.open("/hh/e" + String(s) + ".json");
    if (!f) continue;
    String j = f.readString();
    f.close();
    if (node > 0 && j.indexOf("\"node\":" + String(node) + ",") < 0) continue;
    if (n++) out += ",";
    out += j;
  }
  return out + "]}";
}

static void storeDone(Done& d) {
  uint32_t seq = ++s_seq;
  s_prefs.putUInt("seq", s_seq);
  JsonDocument j;
  j["seq"] = seq;
  if (d.meta_valid) eventToJson(d.node, d.meta, j);
  else j["node"] = d.node;
  j["received"] = nowUnix();
  j["via"] = viaName(d.via);
  j["rssi"] = d.rssi;
  j["image"] = d.len > 0;
  j["full"] = d.full;
  j["bytes"] = d.len;
  String js;
  serializeJson(j, js);

  if (storage::ok()) {
    pruneFor(d.len + js.length());
    String b = "/hh/e" + String(seq);
    if (d.len) storage::writeFile(b + (d.full ? "f.jpg" : ".jpg"), d.buf, d.len);
    storage::writeText(b + ".json", js);
  }
  push("{\"t\":\"image\"," + js.substring(1));   // same fields, tagged as a new archived event
  // Small (LoRa) photos go to the phone right away; full-res ones are pulled on demand.
  if (d.len && !d.full && d.len <= 64 * 1024) hhble::pushImage(seq, false, d.buf, d.len);
  free(d.buf);
  d.buf = nullptr;
}

// ------------------------------------------------------------------------------------ frames
static void freeImage(Node& n) {
  free(n.buf);
  n.buf = nullptr;
  n.total = 0;
  n.last_len = 0;
  n.have.clear();
}

static void startImage(Node& n, uint16_t evt, uint16_t total, Via via) {
  uint16_t chunk = via == VIA_ESPNOW ? proto::ESPNOW_CHUNK : proto::CHUNK_DATA;
  uint16_t maxc = via == VIA_ESPNOW ? proto::ESPNOW_MAX_CHUNKS : proto::MAX_CHUNKS;
  if (n.buf && n.evt == evt && n.total == total && n.chunk == chunk) return;
  freeImage(n);
  if (!total || total > maxc) return;
  n.buf = (uint8_t*)ps_malloc(size_t(total) * chunk);
  if (!n.buf) return;
  n.evt = evt;
  n.total = total;
  n.chunk = chunk;
  n.via = via;
  n.started = millis();
  n.have.assign((total + 7) / 8, 0);
}

size_t onFrame(const uint8_t* in, size_t len, Via via, const uint8_t* mac, float rssi, float snr, uint8_t* out) {
  proto::Header h;
  uint8_t pl[proto::MAX_PAYLOAD];
  int n = proto::open(KEY, 0, in, len, h, pl);
  if (n < 0 || h.node == 0 || h.node == 0xFF) return 0;
  uint8_t id = h.node;
  Node& nd = s_nodes[id];
  if (h.ctr <= loadCtr(id)) return 0;   // replay or stale
  nd.last_ctr = h.ctr;
  nd.seen = true;
  nd.last_ms = millis();
  nd.last_via = via;
  if (via == VIA_LORA) {
    nd.rssi = rssi;
    nd.snr = snr;
  }
  (void)mac;

  switch (h.type) {
    case proto::UP_HELLO:
    case proto::UP_STATUS: {
      if (n < (int)sizeof(proto::Status)) return 0;
      proto::Status s;
      memcpy(&s, pl, sizeof(s));
      JsonDocument d;
      statusToJson(s, d);
      String st;
      serializeJson(d, st);
      nd.status = st;
      if (storage::ok()) storage::writeText("/hh/n" + String(id) + ".json", st);
      JsonDocument m;
      m["t"] = h.type == proto::UP_HELLO ? "hello_node" : "status";
      m["node"] = id;
      m["reason"] = s.reset_reason;
      m["rssi"] = rssi;
      m["snr"] = snr;
      m["via"] = viaName(via);
      m["status"] = d;
      String ms;
      serializeJson(m, ms);
      push(ms);
      persistCtr(id);
      return buildReply(id, h.ctr, via, 0, nullptr, nullptr, 0, true, out);
    }

    case proto::UP_EVENT: {
      if (n < (int)sizeof(proto::Event)) return 0;
      proto::Event e;
      memcpy(&e, pl, sizeof(e));
      nd.meta = e;
      nd.meta_valid = true;
      JsonDocument d;
      d["t"] = "event";
      eventToJson(id, e, d);
      d["via"] = viaName(via);
      d["rssi"] = rssi;
      d["incoming_image"] = e.chunks > 0;
      String s;
      serializeJson(d, s);
      push(s);   // the motion alert — goes out before any image data arrives
      if (e.chunks) {
        startImage(nd, e.event_id, e.chunks, via);
        return 0;
      }
      s_done.push_back({id, nullptr, 0, false, e, true, via, rssi});   // header-only event
      persistCtr(id);
      return buildReply(id, h.ctr, via, 0, nullptr, nullptr, 0, true, out);
    }

    case proto::UP_CHUNK: {
      if (n <= (int)sizeof(proto::ChunkHdr)) return 0;
      proto::ChunkHdr c;
      memcpy(&c, pl, sizeof(c));
      startImage(nd, c.event_id, c.total, via);   // no-op if already assembling this event
      if (!nd.buf || c.event_id != nd.evt || c.idx >= nd.total) return 0;
      size_t dlen = n - sizeof(c);
      if (dlen > nd.chunk) return 0;
      memcpy(nd.buf + size_t(c.idx) * nd.chunk, pl + sizeof(c), dlen);
      nd.have[c.idx / 8] |= 1 << (c.idx % 8);
      if (c.idx == nd.total - 1) nd.last_len = dlen;
      return 0;
    }

    case proto::UP_EVENT_END: {
      if (n < (int)sizeof(proto::EventEnd)) return 0;
      proto::EventEnd e;
      memcpy(&e, pl, sizeof(e));
      persistCtr(id);
      if (!nd.buf || nd.evt != e.event_id) {
        if (via == VIA_LORA) {   // lost everything (e.g. handheld rebooted mid-transfer): resend all
          uint8_t all[proto::BITMAP_BYTES];
          memset(all, 0xFF, sizeof(all));
          return buildReply(id, h.ctr, via, 0, all, nullptr, 0, false, out);
        }
        return buildReply(id, h.ctr, via, 0, nullptr, nullptr, 0, false, out);   // node falls back to LoRa
      }
      uint16_t miss[proto::ESPNOW_MAX_MISSING];
      uint8_t bitmap[proto::BITMAP_BYTES] = {};
      int m = 0;
      for (uint16_t i = 0; i < nd.total; i++) {
        if (nd.have[i / 8] & (1 << (i % 8))) continue;
        if (via == VIA_LORA) bitmap[i / 8] |= 1 << (i % 8);
        else if (m < proto::ESPNOW_MAX_MISSING) miss[m] = i;
        m++;
      }
      if (m) {
        if (via == VIA_LORA) return buildReply(id, h.ctr, via, 0, bitmap, nullptr, 0, e.round >= 4, out);
        return buildReply(id, h.ctr, via, 0, nullptr, miss, (uint8_t)min(m, (int)proto::ESPNOW_MAX_MISSING), false, out);
      }
      size_t total = size_t(nd.total - 1) * nd.chunk + nd.last_len;
      bool metaOk = nd.meta_valid && nd.meta.event_id == nd.evt;
      s_done.push_back({id, nd.buf, total, nd.via == VIA_ESPNOW, nd.meta, metaOk, nd.via, nd.rssi});
      nd.buf = nullptr;   // ownership moved to s_done
      freeImage(nd);
      return buildReply(id, h.ctr, via, proto::RF_COMPLETE, nullptr, nullptr, 0, true, out);
    }
  }
  return 0;
}

// ------------------------------------------------------------------------------------ app API
static bool nodeTargets(JsonDocument& d, std::vector<uint8_t>& ids) {
  int node = d["node"] | -1;
  if (node == 0) {
    for (int i = 1; i < 255; i++)
      if (s_nodes[i].seen || !s_nodes[i].status.isEmpty()) ids.push_back(i);
    return true;
  }
  if (node < 1 || node > 254) return false;
  ids.push_back(node);
  return true;
}

String appCommand(const char* json, size_t len, bool fromBle) {
  JsonDocument d, r;
  if (deserializeJson(d, json, len)) return "{\"t\":\"resp\",\"ok\":false,\"error\":\"bad json\"}";
  String cmd = d["cmd"] | "";
  r["t"] = "resp";
  r["cmd"] = cmd;
  if (!d["rid"].isNull()) r["rid"] = d["rid"];
  bool ok = true;
  String raw;   // pre-serialized payload to return instead of r

  if (cmd == "hello" || cmd == "nodes") {
    raw = nodesJson();
  } else if (cmd == "handheld") {
    raw = handheldJson();
  } else if (cmd == "time") {
    uint32_t t = d["unix"] | 0;
    lora::applyTime(t);
    ok = lora::timeSynced();
  } else if (cmd == "events") {
    raw = eventsJson(d["node"] | 0, constrain((int)(d["limit"] | 20), 1, 100), d["before"] | 0);
  } else if (cmd == "get_image") {
    uint32_t seq = d["seq"] | 0;
    String path = imagePath(seq, d["full"] | false);
    File f = path.length() ? LittleFS.open(path) : File();
    if (!f) ok = false;
    else if (!fromBle) {
      r["url"] = "/img?seq=" + String(seq) + "&full=" + String((d["full"] | false) ? 1 : 0);
    } else {
      size_t sz = f.size();
      uint8_t* b = (uint8_t*)ps_malloc(sz);
      if (b && f.read(b, sz) == sz) {
        hhble::pushImage(seq, path.endsWith("f.jpg"), b, sz);
        r["bytes"] = sz;
      } else ok = false;
      free(b);
    }
    if (f) f.close();
  } else if (cmd == "delete_event") {
    String b = "/hh/e" + String((uint32_t)(d["seq"] | 0));
    ok = LittleFS.remove(b + ".json");
    LittleFS.remove(b + ".jpg");
    LittleFS.remove(b + "f.jpg");
  } else if (cmd == "set") {
    std::vector<uint8_t> ids;
    String key = d["key"] | "";
    int k = 0;
    for (int i = 1; i < N_CFG; i++)
      if (key == CFG_NAMES[i]) k = i;
    ok = k && nodeTargets(d, ids) && !d["value"].isNull();
    if (ok)
      for (uint8_t id : ids) queueCmd(id, proto::CMD_SET, k, (uint32_t)(d["value"].as<long>()));
    r["queued_for"] = ids.size();
  } else if (cmd == "snapshot" || cmd == "reboot" || cmd == "maintenance" || cmd == "status" || cmd == "clear") {
    uint8_t op = cmd == "snapshot" ? proto::CMD_SNAPSHOT : cmd == "reboot" ? proto::CMD_REBOOT
               : cmd == "maintenance" ? proto::CMD_MAINTENANCE : cmd == "status" ? proto::CMD_STATUS
               : proto::CMD_CLEAR_STORAGE;
    std::vector<uint8_t> ids;
    ok = nodeTargets(d, ids);
    if (ok)
      for (uint8_t id : ids) queueCmd(id, op);
    r["queued_for"] = ids.size();
  } else if (cmd == "cancel") {
    std::vector<uint8_t> ids;
    ok = nodeTargets(d, ids);
    for (uint8_t id : ids) {
      s_nodes[id].cmds.clear();
      pushPending(id);
    }
  } else if (cmd == "wifi") {
    hhwifi::setOn(d["on"] | false);
    raw = hhwifi::infoJson();
  } else {
    ok = false;
    r["error"] = "unknown cmd";
  }

  if (raw.length()) {
    // Tag list/info payloads with the request id so the app can match them up.
    if (!d["rid"].isNull()) {
      JsonDocument x;
      if (!deserializeJson(x, raw)) {
        x["rid"] = d["rid"];
        raw = "";
        serializeJson(x, raw);
      }
    }
    return raw;
  }
  r["ok"] = ok;
  String s;
  serializeJson(r, s);
  return s;
}

// ------------------------------------------------------------------------------------ main loop
static void loadArchive() {
  if (!LittleFS.exists("/hh")) LittleFS.mkdir("/hh");
  File dir = LittleFS.open("/hh");
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
    String nm = f.name();
    if (nm.startsWith("n") && nm.endsWith(".json")) {
      int id = nm.substring(1).toInt();
      if (id > 0 && id < 255) s_nodes[id].status = f.readString();
    }
  }
}

[[noreturn]] static void shutdownCritical() {
  push("{\"t\":\"warning\",\"msg\":\"handheld battery critical, shutting down\"}");
  uint32_t t0 = millis();
  while (millis() - t0 < 1500) hhble::loop();
  hhwifi::setOn(false);
  lora::sleep();
  esp_sleep_enable_ext1_wakeup(1ULL << pins::BTN_BOOT, ESP_EXT1_WAKEUP_ANY_LOW);
  esp_deep_sleep_start();
}

[[noreturn]] void run() {
  Serial.printf("TIPTOE handheld, fw %d.%d\n", FW_MAJOR, FW_MINOR);
  s_prefs.begin("hh", false);
  s_seq = s_prefs.getUInt("seq", 0);
  loadArchive();
  lora::rxStart();
  hhble::begin();

  uint32_t lastStatus = 0, lastBattery = 0;
  int criticalCount = 0;
  bool btnPrev = true;
  for (;;) {
    esp_task_wdt_reset();

    uint8_t in[proto::MAX_FRAME + 1], out[proto::MAX_FRAME];
    float rssi, snr;
    int n = lora::rxPoll(in, rssi, snr);
    if (n > 0) {
      size_t r = onFrame(in, n, VIA_LORA, nullptr, rssi, snr, out);
      if (r) {
        delay(proto::REPLY_DELAY_MS);
        lora::txRaw(out, r);
        lora::rxStart();
      }
    }

    hhwifi::loop();
    hhble::loop();

    while (!s_done.empty()) {   // storage happens after the reply went out
      Done d = s_done.front();
      s_done.erase(s_done.begin());
      storeDone(d);
    }

    uint32_t now = millis();
    for (int id = 1; id < 255; id++) {   // abandoned transfers
      Node& nd = s_nodes[id];
      if (nd.buf && now - nd.started > 5 * 60 * 1000) freeImage(nd);
    }

    if (now - lastStatus > 60000) {
      lastStatus = now;
      push(handheldJson());
    }
    if (now - lastBattery > 30000) {
      lastBattery = now;
      power::Info p = power::read(false);
      bool charging = p.chg_state == proto::CHG_PRE || p.chg_state == proto::CHG_FAST;
      criticalCount = (p.gauge_ok && p.soc >= 0 && p.soc < 3 && !charging) ? criticalCount + 1 : 0;
      if (criticalCount >= 2) shutdownCritical();
    }

    bool btn = digitalRead(pins::BTN_BOOT);   // BOOT button toggles Wi-Fi
    if (!btn && btnPrev) hhwifi::setOn(!hhwifi::on());
    btnPrev = btn;

    delay(1);
  }
}

}  // namespace handheld
