# TIPTOE firmware

One firmware image for every TIPTOE unit (rev1 PCB, `Netlist_Schematic1_2026-09-23.net`). Each unit runs in one of two roles:

- **node** (default): outdoor unit. Sleeps, wakes on motion, takes a photo and a sound sample, and reports to the handheld.
- **handheld**: the unit you carry. Stays awake, collects everything from the nodes, and serves your phone app over **BLE** (always) and **Wi-Fi** (on demand).

```
outdoor nodes ──LoRa 869.525 MHz (always) ─────────────────┐
              ──ESP-NOW (when near + handheld Wi-Fi is on)─┴─▶ handheld ──BLE / Wi-Fi AP──▶ phone app
```

No cloud, no router, no Home Assistant. Unit-to-unit frames are AES-128-GCM encrypted, and the BLE link is passkey-paired. The app-facing API is in **[docs/APP_PROTOCOL.md](docs/APP_PROTOCOL.md)**.

Set the role from the USB console: `role handheld` or `role node`. The unit reboots into the new role.

## Node role

The node spends almost all its time in deep sleep. Each wake does one job and goes back to sleep:

| Wake source | What happens |
|---|---|
| **PIR** (IO3, ext0) | VOUT on → OV3660 capture (auto IR from measured scene brightness) with the ICS-43434 recording at the same time → saves JPEG + full-res JPEG + WAV to flash → if the handheld recently said its Wi-Fi is on, sends the **full-res** photo over **ESP-NOW**; otherwise (or if that fails) the small photo over **LoRa** with selective-repeat retransmission → processes any commands in the reply. |
| **Timer** | Heartbeat status over LoRa (battery, charger, Qi input, temperature, RSSI, config). Commands queued on the handheld come down in the reply window. |
| **BOOT button** (IO0, ext1) | Maintenance mode: Wi-Fi AP `TIPTOE-<id>` with a web UI at `http://192.168.4.1/` (status, event archive with photos/audio, live snapshot ± IR, config, OTA firmware upload). Press the button again or leave it idle for 10 min to exit. |
| **Cold boot / reset** | 3 s window to open the USB console (press any key), then a HELLO uplink to the handheld. The PIR is ignored for the first 60 s while it warms up. |

Other behaviour:
- **Cooldown** (default 30 s). Motion during cooldown sends a header-only event, at most every 10 s. If the PIR is still high when the node goes to sleep, it re-checks every 5 s, so continuous motion keeps producing events.
- **Duty cycle.** Sub-band g3 (869.4–869.65 MHz) allows 10 % duty cycle at ≤500 mW ERP. The node tracks its airtime in RTC memory and caps itself at 300 s per hour. If an image won't fit in what's left, it's kept locally and the event goes out flagged `no_budget`.
- **Battery.** Below 15 % the node skips the full-res photo and the audio. Below 5 % (and not charging) it stops arming the PIR and sends a heartbeat every 3 h at most.
- **Security.** Every frame is AES-128-GCM with an 8-byte tag. The frame counter is persisted in blocks, so a power loss never repeats a nonce. The handheld rejects old counters, and the node only accepts a downlink that echoes the uplink it just sent.
- **Watchdog.** 90 s. A hung camera, radio or I2C bus can't keep the node awake and drain the battery.

### Pin map (from the netlist)

| Function | Pin |
|---|---|
| Main I2C SDA / SCL (PCF8574 0x20, MAX17048 0x36, BQ25895 0x6A) | IO8 / IO9 |
| Camera SCCB SDA / SCL (OV3660 0x3C, own bus, 1k series + 4.7k to CAM 2.8V) | IO43 (TXD0) / IO44 (RXD0) |
| TPS63020 EN (VOUT → camera 2.8 V / 1.5 V LDOs, mic, IR LED anodes) | IO2 |
| PIR out | IO3 |
| SX1262 MOSI/MISO/SCK/NSS/BUSY/DIO1 | IO10/11/12/13/14/21 |
| SX1262 NRST / RXEN / TXEN | PCF8574 P4 / P5 / P6 |
| IR LED MOSFET gate | PCF8574 P2 |
| TPS63020 PG / MAX17048 ALRT | PCF8574 P3 / P0 |
| PCF8574 INT# | IO38 |
| Mic SCK / WS / SD | IO1 / IO47 / IO48 |
| Camera XCLK, PCLK, VSYNC, HREF | IO39, IO16, IO42, IO41 |
| Camera D9..D2 | IO40, 18, 17, 15, 6, 4, 5, 7 |

The SX1262's RF-switch and reset lines sit on the PCF8574. A small RadioLib HAL subclass (`src/node/link.cpp`) maps "virtual" pins to the expander, so RadioLib drives them transparently.

## Hardware notes (rev1, 2026-09-23 netlist)

Fixed during the schematic review:
- **Charger temperature sensing.** The BQ25895's TS pin (the battery-temperature input) now has RT1 5.1k (REGN→TS), RT2 30k and a 10k NCP18 NTC. Charging runs from about 2 °C to 41 °C. Place the NTC against the cell, away from the charger, the inductors and the Qi coil.
- **Camera power.** AVDD comes from `CAM 2.8V` through a ferrite bead, DOVDD from `CAM 2.8V`, DVDD from `CAM 1.5V` (both LP5907-type LDOs fed from VOUT), and AGND is grounded. RESETB is pulled up to `CAM 2.8V` with an RC delay.
- **Camera I2C (SCCB).** It's on its own pins (GPIO43/44) with pull-ups to `CAM 2.8V`, so the main I2C bus is never loaded by an unpowered camera. **Keep the 1k series resistors between the ESP and the camera:** GPIO43 is UART0 TX, and the boot ROM drives it on every wake. The firmware releases GPIO43/44 to inputs as its first action.
- **IR LEDs.** The resistors are 33 Ω 1206, about 58 mA per LED (roughly 3× the light of the original 100 Ω).

By design:
- **USB-C VBUS isn't connected.** USB is data-only, so flash and use the console while the board runs from its battery or sits on the Qi pad. A flat battery recovers on the Qi pad, because the charger works without firmware. After the first flash, use Wi-Fi OTA from the maintenance page.

Minor points:
- PCF8574 INT# is on IO38, which isn't an RTC pin, so a fuel-gauge alert can't wake the chip. The firmware polls instead.
- The PCF8574 powers up with all pins high, so RXEN and TXEN are both high for a few ms until the firmware writes the defaults. This is harmless because the radio isn't transmitting.
- The mic is an **ICS-43434**. The firmware picks the live I2S slot automatically.

## Build and flash

```bash
pip install platformio
cp src/common/secrets.example.h src/common/secrets.h     # then edit it
python3 -c "import os;print(', '.join('0x%02x'%b for b in os.urandom(16)))"   # paste into TIPTOE_NETWORK_KEY

pio run -t upload        # board must be running from battery or Qi (USB is data-only)
pio device monitor       # press a key within 3 s of boot for the console; `role handheld` on the one you carry
```

If the node is already in deep sleep, hold BOOT, tap RST, release BOOT to enter the ROM bootloader. After the first flash you can also update over Wi-Fi from the maintenance page (upload `.pio/build/tiptoe/firmware.bin`).

**Give each node a unique ID.** The default comes from the MAC address's last byte. Set it explicitly from the console (`id 1`, `id 2`, …) or the web UI.

### First bring-up checklist

1. Power from battery, connect USB, reset, and press a key within 3 s → console.
2. `i2c` should list 0x20, 0x36 and 0x6A. The camera is on its own bus, so `selftest` checks it separately.
3. `selftest` checks the expander, charger, gauge, VOUT PG, camera PID, mic level, IR pulse (watch through a phone camera), SX1262, flash and PSRAM.
4. `status` shows the charger state and the NTC reading, and `chg` dumps the charger registers.
5. With the handheld running, `send` should print "reply received". `snap` runs a full event end to end.
6. `exit` → the node goes into normal sleep/wake operation.

## Handheld role

The handheld is the same PCB. It doesn't use the PIR, camera or mic, and it never deep-sleeps.

- **LoRa listens all the time.** The handheld receives node status, events and photos, and answers with the time plus any queued commands.
- **It keeps an archive** in its 9.8 MB of flash: every event's metadata plus the photo (LoRa small, or ESP-NOW full-res). The oldest entries are pruned automatically.
- **BLE (`TIPTOE-HH`)** pairs once with a passkey. It pushes motion alerts, status and small photos to the phone the moment they arrive, and accepts commands for any node. A command waits on the handheld until that node next checks in.
- **Wi-Fi comes on only when asked**, from the app or with the BOOT button. The access point `TIPTOE-HH` serves an HTTP API for fast archive and full-res downloads. While it's on, the handheld's replies tell nearby nodes to push full-res photos over ESP-NOW. It turns off after 10 minutes of inactivity.
- **Low battery:** below 3 % (and not charging) it warns the app and powers down. Press BOOT to wake it.
- **Estimated battery life:** ~30–40 mA with BLE + LoRa, so about 2–3 days on a 2000 mAh cell. Wi-Fi adds ~100 mA while it's on. These are estimates, to be measured on the real board.

## Tuning

| Setting | Default | Notes |
|---|---|---|
| `protocol.h` `SF` | 7 | A QVGA JPEG (~6 KB, ~30 chunks) takes ~12 s of airtime. SF9 has more range but ~4× the airtime. Every unit must match. |
| `framesize` / `jpeg_quality` | QVGA / 14 | This is the LoRa image. The full-res copy (2048×1536) stays in flash. |
| `ir_mode` / `ir_luma` | auto / 40 | IR turns on when the probe frame's mean luma is below the threshold, and the sensor switches to grayscale. |
| `TIPTOE_CHARGE_MA` | 512 | Keep at ≤0.5 C of your cell. |
| `TIPTOE_VREG_MV` | 4208 | 4100 is kinder to a cell sitting in the sun. |
| `TIPTOE_CAM_VFLIP/HMIRROR` | 1/0 | Match the camera's orientation in the enclosure. |

Build-time defines go in `build_flags`, and runtime settings go through the app (via the handheld), the console `set`, or a node's maintenance web UI.

## Layout

```
src/common/   protocol.h/.cpp (unit-to-unit frame format, AES-GCM), secrets.example.h
src/tiptoe/   main.cpp (role dispatch, node wake/sleep), board.h (pin map)
              node:     app.cpp (event/status logic), camera, audio, link (LoRa), espnow_link,
                        maintenance (walk-up Wi-Fi web UI + OTA)
              handheld: handheld.cpp (node table, archive, command queue, app API),
                        hh_ble.cpp (BLE service), hh_wifi.cpp (AP, HTTP, ESP-NOW RX)
              shared:   power (BQ25895/MAX17048/VOUT), expander (PCF8574), storage (LittleFS),
                        config (NVS), console (USB bench CLI + selftest)
docs/         APP_PROTOCOL.md — BLE/HTTP API for the phone app
app/          Flutter phone app. See app/README.md and APP_GUIDE.md
builds/       tiptoe-release.apk and tiptoe.ipa
```

What's verified: it compiles against Arduino-ESP32 2.0.17, RadioLib 7.7 and NimBLE-Arduino 1.4, and the frame encryption was round-trip and tamper tested on a PC. Nothing has run on the real board yet.
