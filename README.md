# TIPTOE

Multi-unit surveillance system with motion detection, night vision, and multiple communication modes. Deployable and waterproof — outdoor nodes report to a handheld, and the handheld talks to your phone.

| | |
|---|---|
| Hardware | [`PCB/`](PCB) schematics and gerbers, [`case/`](case) print files |
| Firmware and app | [`code/`](code) |
| Install the app | [Release v1.0.0](https://github.com/Cosmin-Mare/TIPTOE/releases/tag/v1.0.0) |
| Design log | [`JOURNAL.md`](JOURNAL.md) |

<img width="2160" height="2271" alt="3D_PCB4_2026-09-22" src="https://github.com/user-attachments/assets/f74dbc18-8acc-482d-9448-abb8332f6adc" />
<img width="2160" height="2271" alt="PCB_Back" src="https://github.com/user-attachments/assets/0670f556-60f5-4ae9-8500-404d0d544ac2" />
<img width="4440" height="1984" alt="tiptoe_schematics_v4" src="https://github.com/user-attachments/assets/3fc36ef3-6b2b-4815-8b5e-708897cfeec0" />


## Overview

TIPTOE is a custom surveillance device built around the ESP32-S3, designed for being deployed in any outside or inside environment relying on LoRa, esp now and wifi direct to talk to each other and to a receving device (a phone) through the mobile app in `code/app`.

## Features

The device has wireless Qi charging. It is designed to be fully waterproof and deployable on any surface (trees, ground, walls, etc). Print files for the case are in [`case/`](case). It also features a PIR sensor to detect presence, a camera to take snapshots, and a mic to listen.

## Hardware

**Core**
- ESP32-S3-WROOM-1-N16R8 (main MCU)
- PCF8574T I/O expander (extra GPIO for peripherals)
**Power**
- P9025AC Qi wireless receiver -> BQ25895 battery charger -> TPS63020 buck-boost -> ME6211 LDO
- MAX17048 fuel gauge for battery monitoring
**Sensing & I/O**
- OV3660 camera (DVP bus)
- ICS-43434 digital microphone
- HC-SR501 PIR motion sensor (boosted to 5V via AP3602AKTR-G1)
- IR LEDs for night vision (switched via AO3400A MOSFET)
- E22-900M22S LoRa module for long-range communication

## Project Status

The first PCB revision is in [`PCB/`](PCB), with firmware and the phone app in [`code/`](code). [`JOURNAL.md`](JOURNAL.md) was written in realtime throughout the design process and is left unpolished on purpose, so the raw process stays visible.

## Roadmap

Next steps would be confirming the prototype by testing it in person, Making a case for it with some art, and showcasing it in the hack club slack and also on other platforms such as hackaday.

## Repo contents
- [`code/`](code) — firmware (`src/`), phone app (`app/`), and how to flash or run the simulation
- [`PCB/`](PCB) — `BOM.csv`, `TIPTOE.epro2`, `GERBER.zip`
- [`case/`](case) — `TiptoeCase_print.3mf`, `TiptoeCase_NO_PCB.stl`
- [`JOURNAL.md`](JOURNAL.md) — dated build log, including time spent and screenshots
