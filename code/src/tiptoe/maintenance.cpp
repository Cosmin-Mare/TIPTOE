#include "maintenance.h"
#include <Arduino.h>
#include <LittleFS.h>
#include <Update.h>
#include <WebServer.h>
#include <WiFi.h>
#include "app.h"
#include "board.h"
#include "camera.h"
#include "esp_camera.h"
#include "config.h"
#include "power.h"
#include "secrets.h"
#include "storage.h"

namespace maintenance {

static WebServer* srv = nullptr;
static uint32_t s_last = 0;
static bool s_exit = false;

static const char PAGE[] PROGMEM = R"HTML(<!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1">
<title>TIPTOE</title><style>body{font:15px system-ui;margin:16px;max-width:900px}h2{margin-top:28px}
table{border-collapse:collapse}td{padding:3px 10px 3px 0}input{width:90px}.ev{display:inline-block;margin:6px;vertical-align:top;font-size:12px;width:170px}
.ev img{width:160px;border-radius:6px;background:#ddd}button{padding:6px 12px}</style></head><body>
<h1>TIPTOE node <span id=nid></span></h1>
<table id=st></table>
<p><button onclick="snap()">Live snapshot</button> <button onclick="snap(1)">Snapshot + IR</button>
<button onclick="fetch('/api/exit',{method:'POST'}).then(()=>document.body.innerHTML='<h1>Sleeping.</h1>')">Exit &amp; sleep</button></p>
<img id=live style="max-width:100%">
<h2>Config</h2><form id=cf onsubmit="return save()"><table id=ct></table><button>Save</button></form>
<h2>Events</h2><div id=evs></div>
<h2>Firmware update</h2><form method=POST action=/update enctype=multipart/form-data><input type=file name=fw style="width:auto"> <button>Upload</button></form>
<script>
const K=['node_id','armed','heartbeat_min','cooldown_s','jpeg_quality','framesize','ir_mode','ir_luma','audio_ms','tx_power','send_image','hires_local','grayscale_ir'];
function snap(ir){document.getElementById('live').src='/snapshot.jpg?ir='+(ir?1:0)+'&t='+Date.now()}
async function load(){const s=await (await fetch('/api/status')).json();nid.textContent='#'+s.node_id;
st.innerHTML=Object.entries(s).filter(([k])=>!K.includes(k)).map(([k,v])=>`<tr><td>${k}</td><td><b>${v}</b></td></tr>`).join('');
ct.innerHTML=K.map(k=>`<tr><td>${k}</td><td><input name=${k} value="${s[k]}"></td></tr>`).join('');
const e=await (await fetch('/api/events')).json();
evs.innerHTML=e.map(x=>`<div class=ev><a href="/ev/${x.id}${x.hi?'_hi':''}.jpg"><img loading=lazy src="/ev/${x.id}.jpg"></a><br>#${x.id} ${x.wav?`<a href="/ev/${x.id}.wav">audio</a>`:''}<br>${x.meta}</div>`).join('')}
async function save(){await fetch('/api/config',{method:'POST',body:new URLSearchParams(new FormData(cf))});load();return false}
load();</script></body></html>)HTML";

static void touch() { s_last = millis(); }

static void handleStatus() {
  touch();
  power::Info pi = power::read(true);
  const NodeConfig& c = config::cfg;
  char b[1100];
  snprintf(b, sizeof(b),
           "{\"fw\":\"%d.%d\",\"node_id\":%u,\"armed\":%u,\"heartbeat_min\":%u,\"cooldown_s\":%u,\"jpeg_quality\":%u,"
           "\"framesize\":%u,\"ir_mode\":%u,\"ir_luma\":%u,\"audio_ms\":%u,\"tx_power\":%d,\"send_image\":%u,"
           "\"hires_local\":%u,\"grayscale_ir\":%u,\"soc\":%.1f,\"vbat_mv\":%u,\"crate_pct_h\":%.1f,"
           "\"charge\":\"%s\",\"input_power_good\":%d,\"vbus_mv\":%u,\"vsys_mv\":%u,\"ichg_ma\":%u,\"ts_pct\":%.1f,"
           "\"ntc\":\"%s\",\"chg_fault\":\"0x%02x\",\"temp_c\":%.1f,\"events\":%u,\"fs_free_kb\":%u,\"hw_mask\":\"0x%02x\","
           "\"pir\":%d,\"heap\":%u,\"psram_free\":%u}",
           FW_MAJOR, FW_MINOR, c.node_id, c.armed, c.heartbeat_min, c.cooldown_s, c.jpeg_quality, c.framesize,
           c.ir_mode, c.ir_luma, c.audio_ms, c.tx_power, c.send_image, c.hires_local, c.grayscale_ir, pi.soc,
           pi.vbat_mv, pi.crate, power::chargeStateStr(pi.chg_state), pi.power_good, pi.vbus_mv, pi.vsys_mv,
           pi.ichg_ma, pi.ts_pct, power::ntcFaultStr(pi.fault), pi.fault, temperatureRead(), app::eventCount(),
           (unsigned)(storage::freeBytes() / 1024), app::hwMask(), digitalRead(pins::PIR),
           (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getFreePsram());
  srv->send(200, "application/json", b);
}

static void handleConfig() {
  touch();
  static const struct { const char* name; uint8_t key; } map[] = {
      {"armed", proto::CFG_ARMED}, {"heartbeat_min", proto::CFG_HEARTBEAT_MIN}, {"cooldown_s", proto::CFG_COOLDOWN_S},
      {"jpeg_quality", proto::CFG_JPEG_QUALITY}, {"framesize", proto::CFG_FRAMESIZE}, {"ir_mode", proto::CFG_IR_MODE},
      {"ir_luma", proto::CFG_IR_LUMA}, {"audio_ms", proto::CFG_AUDIO_MS}, {"tx_power", proto::CFG_TX_POWER},
      {"send_image", proto::CFG_SEND_IMAGE}, {"hires_local", proto::CFG_HIRES_LOCAL},
      {"grayscale_ir", proto::CFG_GRAYSCALE_IR}};
  String bad;
  for (auto& m : map)
    if (srv->hasArg(m.name) && !config::set(m.key, (uint32_t)srv->arg(m.name).toInt())) bad += String(m.name) + " ";
  if (srv->hasArg("node_id") && !config::setNodeId(srv->arg("node_id").toInt())) bad += "node_id ";
  config::save();
  srv->send(bad.length() ? 400 : 200, "text/plain", bad.length() ? "invalid: " + bad : "ok");
}

static void handleSnapshot() {
  touch();
  bool ir = srv->arg("ir") == "1";
  power::voutOn();
  camera::Image img = camera::snapshot(FRAMESIZE_XGA, 10, ir);
  power::voutOff();
  if (!img.len) {
    srv->send(500, "text/plain", "camera failed");
    return;
  }
  srv->setContentLength(img.len);
  srv->send(200, "image/jpeg", "");
  srv->client().write(img.data, img.len);
  camera::release(img);
}

void run(uint32_t idleTimeoutMs) {
  char ssid[24];
  snprintf(ssid, sizeof(ssid), "TIPTOE-%u", config::cfg.node_id);
  WiFi.mode(WIFI_AP);
  WiFi.softAP(ssid, TIPTOE_MAINT_AP_PASS);
  Serial.printf("maintenance: AP \"%s\"  http://%s/\n", ssid, WiFi.softAPIP().toString().c_str());

  WebServer server(80);
  srv = &server;
  s_exit = false;
  server.on("/", [] { touch(); srv->send_P(200, "text/html", PAGE); });
  server.on("/api/status", handleStatus);
  server.on("/api/events", [] { touch(); srv->send(200, "application/json", storage::listJson()); });
  server.on("/api/config", HTTP_POST, handleConfig);
  server.on("/api/exit", HTTP_POST, [] { srv->send(200, "text/plain", "bye"); s_exit = true; });
  server.on("/snapshot.jpg", handleSnapshot);
  server.on(
      "/update", HTTP_POST,
      [] {
        bool ok = !Update.hasError();
        srv->send(200, "text/plain", ok ? "Update OK, rebooting" : "Update FAILED");
        delay(500);
        if (ok) ESP.restart();
      },
      [] {
        touch();
        HTTPUpload& u = srv->upload();
        if (u.status == UPLOAD_FILE_START) Update.begin(UPDATE_SIZE_UNKNOWN);
        else if (u.status == UPLOAD_FILE_WRITE) Update.write(u.buf, u.currentSize);
        else if (u.status == UPLOAD_FILE_END) Update.end(true);
      });
  server.serveStatic("/ev", LittleFS, "/ev");
  server.begin();

  touch();
  bool btnPrev = true;
  uint32_t start = millis();
  while (!s_exit && millis() - s_last < idleTimeoutMs) {
    server.handleClient();
    bool btn = digitalRead(pins::BTN_BOOT);
    if (!btn && btnPrev && millis() - start > 2000) s_exit = true;   // press again to leave
    btnPrev = btn;
    delay(2);
  }
  server.stop();
  srv = nullptr;
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_OFF);
}

}  // namespace maintenance
