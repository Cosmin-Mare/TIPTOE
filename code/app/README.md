# TIPTOE phone app

Flutter app for the handheld side of the TIPTOE PCB. Outdoor nodes are never contacted directly, except in walk-up maintenance mode. Behaviour and screens follow `APP_GUIDE.md`. The byte format follows `docs/APP_PROTOCOL.md`.

## Layout

```
lib/
  protocol/    BLE framing and JSON messages
  domain/      online/offline, health warnings, command ETAs
  data/        SQLite archive and JPEG files
  link/        BLE, simulated handheld, Wi-Fi join, HTTP
  services/    HandheldService (the only BLE owner) and notifications
  state/       the store screens read
  ui/          theme and shared widgets
  features/    onboarding, home, map, timeline, event, node, handheld, settings, simulation, maintenance
```

Screens call the store. The store calls `HandheldService`. The service owns the connection, the stream parser, and command matching.

## Review without a board

The first screen offers **Review with a simulation**. It is available in release builds, so someone reviewing the app does not need a PCB or a debug flag.

The simulation speaks the same framed protocol as the handheld. Suggested node names are Garden, Gate, and Shed. A guide then walks through:

- an online node, a late node, and an offline node with health warnings
- a map centered on the phone, where each camera can be placed and a motion alert turns its pin red
- a motion alert, then the photo a couple of seconds later
- a setting that stays pending until the node’s next check-in
- a camera failure and a duty-cycle limit
- Near mode, then fetching the full-resolution photo over Bluetooth

Leave the simulation from that guide or from Settings to pair a real handheld.

```bash
cd app
flutter run
```

## Run with the handheld

1. Flash a unit and set `role handheld` from the USB console.
2. Pair when the phone asks. The 6-digit PIN is `TIPTOE_BLE_PASSKEY` in the firmware's `secrets.h`. It is not compiled into the app.
3. Name the nodes. Names stay on the phone.

Full-resolution downloads join the `TIPTOE-HH` network from the `wifi` message, fetch `http://192.168.4.1/img`, then turn Wi-Fi off. On iOS this needs the Hotspot Configuration capability (`com.apple.developer.networking.HotspotConfiguration`) on the app identifier. Android binds the process to that network so mobile data can stay up.

Node maintenance (`Visit node`) uses `TIPTOE-<id>` and the maintenance password from firmware secrets.
