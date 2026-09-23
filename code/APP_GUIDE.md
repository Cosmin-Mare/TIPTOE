# TIPTOE app — build guide

This guide describes the phone app: what it has to do, how it should behave, and how it talks to the TIPTOE hardware. The exact wire format (UUIDs, framing, every JSON message and command) is in **[APP_PROTOCOL.md](APP_PROTOCOL.md)**. This file covers the rest: architecture, behaviour, screens, edge cases.

---

## 1. The system in one picture

```
 [Node 1] ─┐
 [Node 2] ─┼── LoRa (always, long range, small photos)
 [Node 3] ─┤   ESP-NOW (only when near the handheld AND its Wi-Fi is on, full-res photos)
           ▼
     [Handheld]  ← same TIPTOE PCB, role "handheld", carried by you
           │
           ├── BLE (always connected): alerts, status, small photos, commands
           └── Wi-Fi AP "TIPTOE-HH" (on demand): fast downloads, full-res photos
           ▼
       [Phone app]
```

Four facts shape the whole app:

1. **The app only talks to the handheld.** It never connects to outdoor nodes directly, with one exception: a node's walk-up maintenance mode (§9).
2. **Outdoor nodes sleep almost all the time.** They wake on motion or on a heartbeat timer (default every 30 min). A command for a node waits on the handheld until that node next wakes up. The app must make this delay visible, never hide it.
3. **The handheld is the source of truth.** It keeps the event archive and the latest status of every node. The phone keeps a local copy for speed and offline viewing, and syncs whenever it reconnects.
4. **The handheld doesn't know the time until the phone tells it.** Send the time on every connection.

---

## 2. Suggested stack (React Native)

| Need | Library | Notes |
|---|---|---|
| BLE | `react-native-ble-plx` | Works in bare RN or Expo with a dev build and config plugin. Values are base64. |
| Joining the handheld's Wi-Fi | `react-native-wifi-reborn` | Android `WifiNetworkSpecifier`, iOS `NEHotspotConfiguration` |
| Local database | `op-sqlite` / `expo-sqlite` (or WatermelonDB) | events, nodes, pending commands |
| Photo files | `react-native-fs` / `expo-file-system` | JPEGs on disk, DB stores paths |
| Notifications | `@notifee/react-native` | Local notifications, grouping, big-picture style, Android foreground service |
| Background BLE (Android) | foreground service via notifee | Keeps the connection alive when the app is backgrounded |
| State | Zustand / Redux Toolkit | One store fed by a single BLE service |

Architecture: one **`HandheldService`** singleton owns the BLE connection, the stream parser, the command/response matching and the Wi-Fi flow. Screens never touch BLE directly. They read from the store and DB and call service methods.

---

## 3. Permissions and platform setup

**Android**
- `BLUETOOTH_SCAN` (with `neverForLocation`) and `BLUETOOTH_CONNECT` on Android 12+. On Android ≤ 11, `ACCESS_FINE_LOCATION` instead.
- `POST_NOTIFICATIONS` (Android 13+).
- `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_CONNECTED_DEVICE` (Android 14+) for the background connection.
- `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE`. Some Android versions also want location permission to connect to a specific Wi-Fi network.

**iOS**
- `NSBluetoothAlwaysUsageDescription`.
- Background mode **`bluetooth-central`**, so alerts keep arriving while the app is in the background. Use ble-plx `restoreStateIdentifier` so iOS can relaunch the app for BLE events.
- **Hotspot Configuration** capability (entitlement), for joining `TIPTOE-HH`.
- **`NSLocalNetworkUsageDescription`.** Without it, HTTP to `192.168.4.1` fails silently on iOS 14+.

---

## 4. Connection lifecycle

```
IDLE → SCANNING → CONNECTING → MTU → PAIRING → SUBSCRIBING → SYNCING → LIVE
          ↑                                                         │
          └────────────── RECONNECTING (backoff) ←──── disconnect ──┘
```

| Step | What to do |
|---|---|
| Scan | Filter on service UUID `7a1e0001-…`, name `TIPTOE-HH`. Remember the device id after the first pairing and reconnect to it directly. |
| Connect | `connectToDevice(id, { requestMTU: 517 })`. Also call `requestMTU` on Android. |
| Pairing | The handheld starts pairing itself, and the OS shows its own passkey dialog. The user enters the 6-digit PIN once, and the bond is remembered. The app only needs to tell the user the PIN is in the firmware's `secrets.h` (or printed on the handheld). |
| Subscribe | Monitor the TX characteristic `7a1e0003-…`. |
| Sync | (1) `time` with the phone's clock. (2) The handheld sends `handheld`, `nodes` and `wifi` by itself, so store them. (3) Catch up on events (§6). |
| Live | Handle pushed messages. Send `time` again every hour. |
| Reconnect | Exponential backoff: 1 s, 2 s, 5 s, 10 s, then every 30 s. **Reset the stream parser buffer on every disconnect.** |

**If pairing fails** (the user entered a wrong PIN, or the handheld was re-flashed and lost its bonds), the handheld drops the connection. Tell the user to "Forget TIPTOE-HH" in the phone's Bluetooth settings and try again.

---

## 5. BLE stream parser

Notifications are **one continuous byte stream**. A frame can span many notifications, and a notification can end one frame and start the next.

```ts
// frame = [type u8][len u32 LE][payload]
class StreamParser {
  private buf = new Uint8Array(0);

  push(chunk: Uint8Array, onFrame: (type: number, payload: Uint8Array) => void) {
    this.buf = concat(this.buf, chunk);
    while (this.buf.length >= 5) {
      const type = this.buf[0];
      const len = this.buf[1] | (this.buf[2] << 8) | (this.buf[3] << 16) | (this.buf[4] << 24);
      if (len < 0 || len > 4_000_000) { this.reset(); return; }   // desync guard
      if (this.buf.length < 5 + len) return;                       // wait for more bytes
      onFrame(type, this.buf.subarray(5, 5 + len));
      this.buf = this.buf.slice(5 + len);
    }
  }
  reset() { this.buf = new Uint8Array(0); }
}

function onFrame(type: number, p: Uint8Array) {
  if (type === 1) handleJson(JSON.parse(utf8Decode(p)));
  else if (type === 2) {
    const seq = p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24);
    const full = p[4] === 1;
    saveJpeg(seq, full, p.subarray(5));   // write to disk, update DB, refresh UI
  }
}
```

Use a growable buffer, or a list of chunks plus a total length, rather than concatenating on every notification. Full-res images over BLE can be 300 KB+.

**Commands and responses.** Give every command a `rid`: an incrementing number. Keep a map `rid → {resolve, reject, timeout}`. Responses (`t:"resp"`, and list replies like `nodes`/`events`) echo the `rid`. Time out after 5 s (30 s for `get_image`). One write per command, **write-with-response**, max 512 bytes.

---

## 6. Local data model and sync

```sql
handheld(id, fw, soc, vbat_mv, charge, ntc, wifi, time_synced, fs_free_kb, lora_budget_ms, updated_at)

nodes(node_id PK, name, last_seen_at, rssi, snr, via, armed, soc, vbat_mv, charge, ntc, temp_c,
      qi_mv, hw_ok, fw, event_count, fs_free_kb, heartbeat_min, cooldown_s, jpeg_quality,
      framesize, ir_mode, ir_luma, pending_count, status_json)

events(seq PK, node_id, event_id, trigger, time, received, ir, sound_peak_db, sound_rms_db,
       luma, soc, width, height, via, rssi, has_image, full, bytes,
       small_path NULL, full_path NULL, hires_on_node, camera_failed, no_budget, seen BOOL)

pending(id, node_id, cmd, key, value, created_at)   -- the app's mirror of what's queued
```

- **Node names are app-only.** The firmware only knows numeric IDs (1–254). Let the user name them ("Garden", "Gate") and store the names locally.
- **`seq` is the key for events.** It's the handheld's archive id. `event_id` is per-node and can repeat after a node is reset.
- **Catch-up after reconnecting:** request `{"cmd":"events","limit":50}` and insert anything newer than your highest stored `seq`. If all 50 are new, page with `before` = the oldest seq you received, until you reach known ground. Then request `get_image` (small) for recent events that have `has_image` but no `small_path`, limited to the last ~20 to save time.
- **Archive pruning:** the handheld deletes its oldest events when its flash fills up. The phone may keep them longer. Mark events whose `seq` is no longer on the handheld as "phone only".

---

## 7. Screens

**Onboarding**
1. Explain the system in two sentences, then request permissions.
2. Scan for and pair the handheld (PIN).
3. List the nodes the handheld already knows about, and let the user name each one.
4. Set up notifications.

**Home / dashboard**
- Handheld card: battery, charging, connection state, Wi-Fi on/off.
- A card per node:
  - name, online state (§8.3)
  - battery % and charging icon
  - signal bars from RSSI (≥ −90 good, −90…−110 ok, < −110 weak)
  - last seen ("4 min ago")
  - armed toggle
  - a "motion" badge (§8.1)
  - pending-command count with an ETA
- Most recent events strip with thumbnails.

**Timeline**
- All events, newest first, filterable by node and date.
- Thumbnail, node name, time, trigger (motion / snapshot / button), IR icon, sound level, a "full-res available" badge.
- Unseen events highlighted.

**Event detail**
- Photo, pinch-to-zoom.
- Metadata: time, node, trigger, IR on/off, sound peak/RMS (show dBFS as a simple meter), light level, battery at the time, received via LoRa/ESP-NOW, RSSI.
- Actions: **Get full-res** (§8.5), share, delete (`delete_event`), "Take a new snapshot from this node".

**Node detail**
- Full status: battery, voltage, charge state, Qi input voltage, charger temperature state, temperature, firmware, uptime, free storage, hardware health (decode `hw_ok`, §8.4).
- Config editor: armed, heartbeat, cooldown, JPEG quality, photo size, IR mode and threshold, audio length, TX power, send image, keep full-res locally, B/W under IR. Each field shows its **confirmed** value and any **pending** value (§8.2).
- Actions: snapshot, request status, reboot, maintenance mode, clear node storage, cancel pending commands.
- The node's event history.

**Handheld**
- Battery, time sync, LoRa duty-cycle budget left, free storage, firmware.
- Wi-Fi on/off.
- "Forget / re-pair" help.

**Settings**
- Notification preferences per node (all / motion only / none, quiet hours).
- Units, how long to keep photos on the phone, a debug log view (raw frames), export.

---

## 8. Behaviour rules

### 8.1 Motion alerts and notifications
- A **`event`** message is the alert. It arrives within about a second of the PIR firing, before the photo.
  - Show a notification immediately: "Motion — Garden", with IR/sound info in the body.
  - Group notifications per node. Use a stable notification id per node plus event, so it can be updated later.
- When the matching **`image`** arrives (same `node` + `event_id`), update that notification to the big-picture style with the thumbnail. For LoRa photos that's roughly 10–20 s later; for ESP-NOW, a few seconds.
- If `camera_failed` is set, say so ("Motion — camera error").
- If `no_budget` is set, say "photo kept on the node (radio limit reached)".
- **Motion badge:** a node shows "motion" for 60 s after its last `event`. During continuous motion, nodes send extra header-only events at most every 10 s, which keeps the badge on.
- Throttle notification sound: at most one alert sound per node per minute. Later events update the existing notification silently.

### 8.2 Commands are queued, not instant
- After a `set`/`snapshot`/etc., show the command as **pending** with an ETA, for example "Applies at next check-in, ≈ 12 min". Estimate it as `last_seen + heartbeat_min − now` (or "within 1 min" if a motion event is likely).
- The handheld pushes **`pending`** counts. When a node's count drops to 0 **and** a fresh `status` arrives with the new values in `config`, mark the change **confirmed**. Nodes send a status right after applying settings.
- For settings, update the UI optimistically but in a distinct "pending" style, and roll it back if a later `status` shows the old value after the pending count reached 0.
- **`snapshot`:** the result arrives as a normal `event` with `trigger:"snapshot"`. Link it to the request in the UI ("Snapshot from Gate arrived").
- **`cancel`** clears everything queued for a node. Offer it on the pending indicator.
- Suggest lowering `heartbeat_min` (e.g. 5–10) in the UI if the user wants faster control, and say that it costs battery.

### 8.3 Online / offline
- A node is **online** if `age_s < heartbeat_min × 60 × 2.5 + 60`.
- Otherwise it's **late**. After 4 missed heartbeats it's **offline**; notify once.
- A `hello_node` message means the node just powered up or rebooted. Show a subtle notice in its log ("Gate restarted").

### 8.4 Health warnings (per node, shown on the card and as optional notifications)

| Condition | Message |
|---|---|
| `soc < 20` and not charging | Battery low |
| `soc < 5` | Battery critical — node has stopped watching |
| `ntc` = `cold` / `hot` | Too cold/hot to charge — charging paused |
| `ntc` = `warm` / `cool` | Charging at reduced rate (temperature) |
| `qi_mv > 4000` | On Qi pad (charging source present) |
| `hw_ok` missing bit 8 | Camera problem |
| `hw_ok` missing bit 16 | Microphone problem |
| `hw_ok` missing bit 32 | Camera power rail problem |
| `hw_ok` missing bits 1/2/4/64 | Board fault (expander / charger / fuel gauge / flash) |
| `fs_free_kb < 1500` | Node storage nearly full (oldest local photos being deleted) |
| RSSI < −115 or SNR < −10 | Weak link — consider moving the node or handheld |

`hw_ok` bits: 1 expander, 2 charger, 4 fuel gauge, 8 camera, 16 mic, 32 camera power rail, 64 flash.

The handheld itself sends a `warning` before it shuts down on a critical battery. Show that as a high-priority notification.

### 8.5 Full-resolution photos
There are three ways a full-res photo can reach you:

1. **Already on the handheld** (`full:true`, sent over ESP-NOW). Two ways to fetch it:
   - **Over Wi-Fi (fast, preferred):** `wifi on` → join `TIPTOE-HH` → `GET /img?seq=N&full=1` → save → leave the network → `wifi off`.
   - **Over BLE (no network switch, slower):** `get_image` with `full:true`, and show progress from bytes received versus `bytes` in the response. That's roughly 5–20 s for 200–350 KB.
2. **Only on the node** (`hires_on_node:true`, sent over LoRa small). The current firmware can't pull an old full-res photo from a node remotely. Tell the user: "The full photo is stored on the node. Turn on Near mode and walk up to the node, or open its maintenance mode." Future photos arrive full-res automatically while Near mode is on.
3. **Near mode:** a toggle that switches the handheld's Wi-Fi on. While it's on:
   - nodes close to the handheld send **full-res photos over ESP-NOW** automatically
   - the handheld uses ~100 mA more, so show a warning
   - it turns itself off after 10 min without activity; reflect that in the UI when the `wifi` message says `on:false`.

### 8.6 Joining the handheld's Wi-Fi
- Get the SSID and password from the `wifi` message. Don't hard-code them.
- **Android:** request the network with `WifiNetworkSpecifier`, then **bind the app's process to that network** so HTTP goes to `192.168.4.1` while mobile data still carries the internet. Release the binding when done.
- **iOS:** `NEHotspotConfiguration` with `joinOnce: true`. The user sees a system prompt the first time. The Local Network permission must be granted.
- Always send `wifi off` after a transfer, to save the handheld's battery.

### 8.7 Time
- Send `{"cmd":"time","unix":<seconds>}` on every connect and every hour.
- Event `time` is 0 if the node had never been synced when the event happened. In that case, show `received` (handheld time) instead, marked "≈".

---

## 9. Talking to a node directly (maintenance mode)

This is for setup, diagnostics, firmware updates, and pulling a node's own archive (full-res photos and audio).

- Trigger it with the `maintenance` command (applies at the next check-in) or by pressing the node's BOOT button.
- The node opens Wi-Fi AP **`TIPTOE-<node id>`** (password `TIPTOE_MAINT_AP_PASS`), at `http://192.168.4.1`. It closes after 10 minutes idle.
- Node endpoints:

| | |
|---|---|
| `GET /api/status` | full status + config JSON |
| `GET /api/events` | `[{id, meta, hi, wav}]` (node-local event ids) |
| `GET /ev/<id>.jpg`, `/ev/<id>_hi.jpg`, `/ev/<id>.wav` | small photo, full-res photo, audio |
| `GET /snapshot.jpg?ir=0|1` | live photo (1024×768) |
| `POST /api/config` (form fields, same keys as `set`) | change settings immediately |
| `POST /api/exit` | close maintenance mode, node goes back to sleep |
| `POST /update` (multipart `fw`) | OTA firmware update |

The app can offer a **"Visit node"** flow: send `maintenance` → wait for the node to check in → join `TIPTOE-<id>` → browse the node's archive → import full-res photos and audio into the phone's event records (match by node + `event_id`) → `POST /api/exit`.

---

## 10. Errors and edge cases

| Situation | Behaviour |
|---|---|
| `resp` with `ok:false` | Show the `error` field. For `set`, the key name or value was rejected. |
| No response within the timeout | Mark the command failed and allow retry. Don't assume it wasn't queued: check `pending` counts after reconnecting. |
| BLE drops mid-image | Parser reset. Re-request with `get_image` on reconnect. |
| Handheld rebooted | `uptime_s` resets. Pending commands on the handheld are **lost** (they live in RAM), so re-send anything still pending in the app's mirror after checking `pending` counts. |
| Event received twice | Use `seq` as the unique key. `image` and `events` can overlap after a reconnect. |
| Node reset its event counter | `event_id` may repeat for a node. Always key on `seq`. |
| Handheld flash full | The oldest events are deleted there. The phone keeps its own copies. |
| Duty-cycle budget low | Show `lora_budget_ms` on the handheld screen. When exhausted, nodes keep photos locally and send `no_budget` events. |

---

## 11. Security notes

- **BLE:** passkey pairing with MITM protection; everything is encrypted after bonding. Keep the PIN out of the app bundle; the user types it into the OS dialog.
- **Wi-Fi passwords** come over the encrypted BLE link. Don't log them, and don't store them longer than needed.
- **Unit-to-unit traffic** is AES-GCM with a shared network key that's baked into firmware. The app never sees it.

---

## 12. Developing without hardware

Build a **mock handheld** inside the app (debug-only): a fake `HandheldService` that emits the same framed stream. Example payloads from APP_PROTOCOL.md:
- `handheld` and `nodes` on connect
- a `status` every 30 s
- an `event` followed ~10 s later by an `image` plus a type-2 frame with a bundled test JPEG
- `pending` updates after commands

This lets you build every screen and the notification logic before the boards exist.

Test checklist once hardware is on the desk:
- [ ] First pairing, then reconnect after the app is killed, after Bluetooth is toggled, and after the handheld reboots
- [ ] Motion alert with the phone locked (Android foreground service / iOS background mode)
- [ ] A LoRa photo arrives and decodes; the full-res pull works over both BLE and Wi-Fi
- [ ] Commands: pending → delivered → confirmed by status; cancel works
- [ ] Near mode: a node near the handheld sends full-res over ESP-NOW; Wi-Fi auto-off after 10 min is reflected in the UI
- [ ] Catch-up sync after the phone was out of range for hours
- [ ] Walk-up maintenance flow and OTA

---

## 13. Not in the firmware yet (possible later additions)

- Remotely fetching an **old** full-res photo from a node on demand. Today that needs Near mode at event time, or maintenance mode.
- Node names stored on the handheld (today they're app-only).
- OTA for outdoor nodes pushed from the app through the handheld.
- A handheld settings command (Wi-Fi idle timeout, BLE PIN change).
- Persisting pending commands on the handheld across reboots.

If the app needs any of these, they're firmware changes. Note the need and they can be added.
