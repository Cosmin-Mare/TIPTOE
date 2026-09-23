// Handheld <-> phone over BLE (NimBLE). One service, two characteristics:
//   RX (write)  : the app writes one JSON command per write
//   TX (notify) : a byte stream of frames [type u8][len u32 LE][payload]
//                 type 1 = JSON (UTF-8), type 2 = image: [seq u32][full u8][jpeg bytes]
// Pairing: passkey (TIPTOE_BLE_PASSKEY), bonded, MITM-protected. Nothing is sent until the link
// is encrypted and authenticated.
#include <NimBLEDevice.h>
#include <deque>
#include <vector>
#include "board.h"
#include "handheld.h"
#include "secrets.h"

namespace hhble {

static const char* SVC_UUID = "7a1e0001-5c1d-4b8e-9f00-7469707430e0";
static const char* RX_UUID = "7a1e0002-5c1d-4b8e-9f00-7469707430e0";
static const char* TX_UUID = "7a1e0003-5c1d-4b8e-9f00-7469707430e0";

static NimBLEServer* s_server = nullptr;
static NimBLECharacteristic* s_tx = nullptr;
static volatile bool s_connected = false, s_secure = false, s_subscribed = false, s_greet = false;
static volatile uint16_t s_mtu = 23;

struct Msg {
  uint8_t* data;
  size_t len, off;
};
static std::deque<Msg> s_out;
static size_t s_outBytes = 0;
static constexpr size_t OUT_LIMIT = 3 * 1024 * 1024;   // PSRAM budget for queued notifications

static SemaphoreHandle_t s_inLock = nullptr;
static std::vector<std::string> s_in;

static void clearOut() {
  for (auto& m : s_out) free(m.data);
  s_out.clear();
  s_outBytes = 0;
}

static void enqueue(uint8_t type, const uint8_t* a, size_t alen, const uint8_t* b = nullptr, size_t blen = 0) {
  if (!ready()) return;
  size_t len = alen + blen;
  if (s_outBytes + len + 5 > OUT_LIMIT) return;   // phone not keeping up: drop
  uint8_t* d = (uint8_t*)ps_malloc(len + 5);
  if (!d) return;
  d[0] = type;
  d[1] = len & 0xFF;
  d[2] = (len >> 8) & 0xFF;
  d[3] = (len >> 16) & 0xFF;
  d[4] = (len >> 24) & 0xFF;
  memcpy(d + 5, a, alen);
  if (b && blen) memcpy(d + 5 + alen, b, blen);
  s_out.push_back({d, len + 5, 0});
  s_outBytes += len + 5;
}

class ServerCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, ble_gap_conn_desc* desc) override {
    s_connected = true;
    s_secure = false;
    s_subscribed = false;
    NimBLEDevice::startSecurity(desc->conn_handle);   // phone shows the passkey prompt right away
  }
  void onDisconnect(NimBLEServer*) override {
    s_connected = s_secure = s_subscribed = false;
    s_mtu = 23;
    // NimBLE stops advertising on connect and does not resume by itself.
    NimBLEDevice::startAdvertising();
  }
  void onMTUChange(uint16_t mtu, ble_gap_conn_desc*) override { s_mtu = mtu; }
  void onAuthenticationComplete(ble_gap_conn_desc* desc) override {
    s_secure = desc->sec_state.encrypted && desc->sec_state.authenticated;
    if (!s_secure) s_server->disconnect(desc->conn_handle);
    else s_greet = true;
  }
  uint32_t onPassKeyRequest() override { return TIPTOE_BLE_PASSKEY; }
  bool onConfirmPIN(uint32_t) override { return true; }
};

class RxCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    if (!s_secure) return;
    std::string v = c->getValue();
    xSemaphoreTake(s_inLock, portMAX_DELAY);
    if (s_in.size() < 16) s_in.push_back(v);
    xSemaphoreGive(s_inLock);
  }
};

class TxCb : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic*, ble_gap_conn_desc*, uint16_t subValue) override {
    s_subscribed = subValue != 0;
    if (s_subscribed) s_greet = true;
  }
};

void begin() {
  s_inLock = xSemaphoreCreateMutex();
  NimBLEDevice::init("TIPTOE-HH");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(517);
  NimBLEDevice::setSecurityAuth(true, true, true);   // bonding, MITM, secure connections
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);
  NimBLEDevice::setSecurityPasskey(TIPTOE_BLE_PASSKEY);

  s_server = NimBLEDevice::createServer();
  s_server->setCallbacks(new ServerCb());
  NimBLEService* svc = s_server->createService(SVC_UUID);
  NimBLECharacteristic* rx = svc->createCharacteristic(
      RX_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC | NIMBLE_PROPERTY::WRITE_AUTHEN, 512);
  rx->setCallbacks(new RxCb());
  s_tx = svc->createCharacteristic(TX_UUID, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ_ENC |
                                                NIMBLE_PROPERTY::READ_AUTHEN);
  s_tx->setCallbacks(new TxCb());
  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SVC_UUID);
  adv->setScanResponse(true);
  adv->start();
}

bool ready() { return s_connected && s_secure && s_subscribed; }

void pushJson(const String& json) { enqueue(1, (const uint8_t*)json.c_str(), json.length()); }

void pushImage(uint32_t seq, bool full, const uint8_t* data, size_t len) {
  uint8_t hdr[5];
  memcpy(hdr, &seq, 4);
  hdr[4] = full ? 1 : 0;
  enqueue(2, hdr, 5, data, len);
}

void loop() {
  if (!s_connected) {
    if (!s_out.empty()) clearOut();
    return;
  }

  // Incoming commands (run here, not in the BLE task)
  std::vector<std::string> in;
  xSemaphoreTake(s_inLock, portMAX_DELAY);
  in.swap(s_in);
  xSemaphoreGive(s_inLock);
  for (auto& cmd : in) pushJson(handheld::appCommand(cmd.data(), cmd.size(), true));

  if (s_greet && ready()) {   // fresh session: send the full picture
    s_greet = false;
    pushJson(handheld::handheldJson());
    pushJson(handheld::nodesJson());
    pushJson(hhwifi::infoJson());
  }

  // Paced notifications: ~1 per 4 ms keeps NimBLE's buffers from overflowing on any phone.
  static uint32_t last = 0;
  if (s_out.empty() || !ready() || millis() - last < 4) return;
  last = millis();
  Msg& m = s_out.front();
  size_t chunk = min<size_t>(s_mtu > 3 ? s_mtu - 3 : 20, m.len - m.off);
  s_tx->notify(m.data + m.off, chunk);
  m.off += chunk;
  if (m.off >= m.len) {
    s_outBytes -= m.len;
    free(m.data);
    s_out.pop_front();
  }
}

}  // namespace hhble
