# TIPTOE handheld ↔ app protocol

The phone only ever talks to the **handheld**: a TIPTOE unit set to `role handheld`. The handheld listens to the outdoor nodes over LoRa (and ESP-NOW when its Wi-Fi is on), keeps an archive, and exposes it over:

- **BLE**, always on: live alerts, status, small photos, commands.
- **Wi-Fi access point**, on demand: fast HTTP access to the archive and full-resolution photos.

```
outdoor nodes ──LoRa (always) / ESP-NOW (when near + handheld Wi-Fi on)──▶ handheld ──BLE / Wi-Fi──▶ phone app
```

## 1. BLE

| | UUID |
|---|---|
| Service | `7a1e0001-5c1d-4b8e-9f00-7469707430e0` |
| RX, the app **writes** commands | `7a1e0002-5c1d-4b8e-9f00-7469707430e0` |
| TX, the app **subscribes** to notifications | `7a1e0003-5c1d-4b8e-9f00-7469707430e0` |

The device advertises as **`TIPTOE-HH`**, with the service UUID in the advertisement, so you can scan with a service filter.

### Connecting

1. Connect, then **request MTU 517**. Android needs `requestMTU(517)`; iOS negotiates by itself.
2. The handheld starts pairing right away. The phone asks for a **6-digit passkey** (`TIPTOE_BLE_PASSKEY` in `secrets.h`). After that the bond is remembered.
3. Subscribe to TX notifications.
4. The handheld then sends `handheld`, `nodes` and `wifi` messages on its own. Send `{"cmd":"time","unix":<now>}` straight away. This is the only time source in the system: the handheld passes it on to every node.

Nothing is sent, and no command is accepted, until the link is encrypted and authenticated.

In React Native, `react-native-ble-plx` handles all of this. Values are base64 in that library.

### TX stream framing (handheld → app)

Treat the notifications as **one continuous byte stream**. Append each notification's bytes to a buffer and cut frames out of it:

```
[type: u8][length: u32 little-endian][payload: length bytes]
```

| type | payload |
|---|---|
| `1` | UTF-8 JSON object (see §3) |
| `2` | Image: `[seq: u32 LE][full: u8][JPEG bytes…]` |

A frame can span many notifications, and one notification can contain the end of one frame and the start of the next. Notifications arrive in order and reliably, so a simple buffer-and-parse loop is enough.

### RX (app → handheld)

Write **one JSON command per write** (≤ 512 bytes), using write-with-response. Every command may carry a `"rid"` (any number or string), which is echoed back in the response so you can match them up.

## 2. Commands

| Command | Example | Response |
|---|---|---|
| `hello` / `nodes` | `{"cmd":"nodes"}` | `nodes` message |
| `handheld` | `{"cmd":"handheld"}` | `handheld` message |
| `time` | `{"cmd":"time","unix":1758630000}` | `{"t":"resp","cmd":"time","ok":true}` |
| `events` | `{"cmd":"events","node":3,"limit":20,"before":120}` | `events` message. `node` 0 or omitted = all nodes; `before` = page by seq |
| `get_image` | `{"cmd":"get_image","seq":57,"full":true}` | `resp` with `bytes`, then a **type-2 frame** with the JPEG. `full:true` falls back to the small photo if no full-res one exists |
| `delete_event` | `{"cmd":"delete_event","seq":57}` | `resp` |
| `set` | `{"cmd":"set","node":3,"key":"armed","value":0}` | `resp` with `queued_for` |
| `snapshot` | `{"cmd":"snapshot","node":3}` | `resp` with `queued_for` |
| `status` | `{"cmd":"status","node":3}` | node sends a fresh status |
| `reboot` | `{"cmd":"reboot","node":3}` | |
| `maintenance` | `{"cmd":"maintenance","node":3}` | node opens its own Wi-Fi AP `TIPTOE-<id>` (walk-up setup / OTA) |
| `clear` | `{"cmd":"clear","node":3}` | node wipes its local archive |
| `cancel` | `{"cmd":"cancel","node":3}` | drops commands still queued for that node |
| `wifi` | `{"cmd":"wifi","on":true}` | `wifi` message with the credentials |

`"node": 0` means **all known nodes**.

**Node commands are queued.** Outdoor nodes sleep, so a command waits on the handheld and is delivered in the reply to that node's next transmission: its heartbeat (default every 30 min, `heartbeat_min`) or its next event. The `pending` message tells you what's still waiting. For quicker delivery, lower `heartbeat_min`; it costs a little battery on the node.

Keys for `set`:

| key | range | meaning |
|---|---|---|
| `armed` | 0/1 | PIR events on/off |
| `heartbeat_min` | 1–1440 | status interval |
| `cooldown_s` | 0–3600 | min seconds between photo events |
| `jpeg_quality` | 4–63 | LoRa photo quality (lower = better/bigger) |
| `framesize` | 0–10 | LoRa photo size (esp32-camera framesize; 5 = QVGA 320×240, 8 = VGA, 10 = XGA). Larger sizes are rejected |
| `ir_mode` | 0/1/2 | IR off / always / auto |
| `ir_luma` | 0–255 | auto-IR brightness threshold |
| `audio_ms` | 0–5000 | sound sample length per event |
| `tx_power` | -9–22 | LoRa dBm |
| `send_image` | 0/1 | send photos at all |
| `hires_local` | 0/1 | node keeps a full-res copy in its own flash |
| `grayscale_ir` | 0/1 | B/W when IR is on |

## 3. Messages (handheld → app)

Every JSON message has a `"t"` field.

**`event`**: the motion alert. It's sent the moment the node's event header arrives, before any image data.
```json
{"t":"event","node":3,"event_id":41,"trigger":"pir","time":1758630123,"ir":true,"camera_failed":false,
 "no_budget":false,"hires_on_node":true,"sound_peak_db":-23,"sound_rms_db":-41,"luma":18,"soc":76,
 "width":2048,"height":1536,"img_len":231904,"via":"espnow","rssi":0,"incoming_image":true}
```

**`image`**: an event was archived; `seq` is its id in the handheld archive. For LoRa photos (`full:false`, ≤ 64 KB) a **type-2 frame with the JPEG follows automatically**. Full-res ESP-NOW photos are not pushed: fetch them with `get_image` over BLE (slow) or over HTTP with Wi-Fi on (fast).
```json
{"t":"image","seq":57,"node":3,"event_id":41,"trigger":"pir","time":1758630123,"received":1758630131,
 "via":"lora","rssi":-97.5,"image":true,"full":false,"bytes":6123, "...event fields..."}
```

**`status`** / **`hello_node`**: a node's heartbeat, or its first message after a power-up. `rssi`/`snr` are measured at the handheld (LoRa).
```json
{"t":"status","node":3,"reason":4,"rssi":-101,"snr":6.5,"via":"lora",
 "status":{"fw":"1.2","armed":1,"soc":76.4,"vbat_mv":3981,"crate_pct_h":-0.4,"charge":"not charging",
           "ntc":"normal","charger_fault":0,"qi_mv":0,"temp_c":21,"node_rssi":-95,"event_count":12,
           "uptime_s":86400,"fs_free_kb":8120,"hw_ok":127,
           "config":{"armed":1,"heartbeat_min":30,"cooldown_s":30,"jpeg_quality":14,"framesize":5,"ir_mode":2,"ir_luma":40,"audio_ms":1500,"tx_power":22,"send_image":1,"hires_local":1,"grayscale_ir":1}}}
```
`hw_ok` bits: 1 expander, 2 charger, 4 fuel gauge, 8 camera, 16 mic, 32 camera power rail, 64 flash.

**`nodes`**: every node the handheld knows about.
```json
{"t":"nodes","nodes":[{"node":3,"age_s":412,"rssi":-101,"snr":6.5,"via":"lora","pending":0,"status":{...}}]}
```

**`events`**: archive page, newest first. Each entry has the same fields as `image`.

**`pending`**: `{"t":"pending","node":3,"count":1}`

**`handheld`**: the handheld's own state, sent on connect and every 60 s.
```json
{"t":"handheld","fw":"1.2","soc":88.1,"vbat_mv":4052,"charge":"not charging","ntc":"normal","wifi":false,
 "time_synced":true,"uptime_s":5321,"fs_free_kb":9400,"lora_budget_ms":298211,"lora_ok":true}
```

**`wifi`**: `{"t":"wifi","on":true,"ssid":"TIPTOE-HH","pass":"…","ip":"192.168.4.1","port":80,"channel":1}`

**`resp`**: `{"t":"resp","cmd":"set","ok":true,"queued_for":1,"rid":7}`

**`warning`**: e.g. handheld battery critical, just before it powers down.

## 4. Wi-Fi (on demand)

Send `{"cmd":"wifi","on":true}` over BLE, or press the handheld's BOOT button. You get a `wifi` message with the SSID and password. Join that network from the app:
- Android: `WifiNetworkSpecifier` / `react-native-wifi-reborn` `connectToProtectedSSID`. Android keeps mobile data for the internet.
- iOS: `NEHotspotConfiguration`.

While Wi-Fi is on, nodes near the handheld send their **full-res photos over ESP-NOW** (`via:"espnow"`, `full:true`) instead of the small LoRa version. Wi-Fi turns itself off after 10 minutes without activity, or when you send `{"cmd":"wifi","on":false}`. Leave it off normally, because it costs the handheld about 100 mA.

HTTP API at `http://192.168.4.1`:

| | |
|---|---|
| `GET /api/nodes` | same as the `nodes` message |
| `GET /api/handheld` | same as the `handheld` message |
| `GET /api/events?node=3&limit=50&before=120` | same as the `events` message |
| `GET /img?seq=57&full=1` | JPEG |
| `POST /api/cmd` (body = command JSON) | same commands as BLE (`get_image` returns a `url` instead of pushing bytes) |

## 5. Things to design the app around

- **Latency.**
  - Motion alerts reach the phone within a second or two of the PIR firing, over LoRa or ESP-NOW.
  - A LoRa photo (~6 KB) needs ~10–15 s more.
  - A full-res ESP-NOW photo needs a few seconds.
- **The handheld is the archive.** The phone can be disconnected and catch up later with `events` + `get_image`. Each node also keeps its own full-res photos and audio; you get at those with the node's maintenance mode.
- **Battery estimates** (rough, to be measured):
  - Handheld: about 30–40 mA with BLE + LoRa listening, so ~2–3 days on a 2000 mAh cell; with Wi-Fi on, about +100 mA.
  - Nodes: weeks to months, depending on how many events they record.
