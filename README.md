# TIPTOE

Multi-unit surveillance system with motion detection, night vision, and multiple communication modes. Deployable and waterproof — outdoor nodes report to a handheld, and the handheld talks to your phone.

| | |
|---|---|
| Hardware | [`PCB/`](PCB) schematics and gerbers, [`case/`](case) print files |
| Firmware and app | [`code/`](code) |
| Install the app | [Release v1.0.0](https://github.com/Cosmin-Mare/TIPTOE/releases/tag/v1.0.0) |
| Design log | [`JOURNAL.md`](JOURNAL.md) |

<img width="1920" height="1080" alt="Top Right" src="https://github.com/user-attachments/assets/e1624eaf-ebf7-4f8f-96db-b40d4a7baf02" />
<img width="1920" height="1080" alt="Top Right white nocase" src="https://github.com/user-attachments/assets/35f22d00-47d3-454c-bb44-0890de81267b" />

<img width="4440" height="1914" alt="tiptoe_schematics_v5" src="https://github.com/user-attachments/assets/20c38762-5f93-4be2-8575-d7d535b98d91" />



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

## Assembly

Getting from bare hardware to a running unit, end to end:

### 1. Fabricate & populate the board

- Gerbers: [`PCB/GERBER.zip`](PCB/GERBER.zip). Full BOM with LCSC part numbers: [`PCB/BOM.csv`](PCB/BOM.csv) (also below).
- Several parts are exposed-pad QFN/VQFN/WQFN packages (`BQ25895` WQFN-24, `TPS63020` VSON-14, `BQ51013B` VQFN-20, `MAX17048` TDFN-8) plus a 0.5 mm-pitch `ESP32-S3-WROOM-1` module and a 0.5 mm FPC camera connector — these need a stencil and reflow (or a hot-air rework station with real skill), not a hand iron alone. The straightforward path is to order PCB fab **and** SMT assembly together (e.g. JLCPCB PCBA) using the gerbers and the BOM/LCSC part numbers; leave through-hole parts (battery connector, PIR header, IR LEDs, buttons) for the assembly house to skip, and hand-solder those yourself afterward.
- You need at least 2 populated boards to test anything (one handheld + one node); the project targets 4 deployable units total. Every board is the *same* PCB — role is chosen later in firmware.

### 2. Connect the off-board modules

The BOM only places connectors on the PCB — three parts plug into those connectors and aren't optional for bring-up:

- **Camera** — an **OV3660** module, into the `Camera` FPC connector (`FPC-05F-24PH20`, 24-pin, 0.5mm pitch). Flip-lock connector: lift the tab, seat the FPC ribbon, press the tab back down.
- **PIR sensor** — an **HC-SR501** module, into the 3-pin `PIR` header (`HX PM2.54-1x3P`). Match GND/OUT/VCC to the silkscreen — it's a plain 2.54mm header, so it's easy to reverse.
- **Battery** — a single-cell Li-ion/LiPo pack terminated in a **JST-PH 2-pin** connector, into `BATTERY`. Mind polarity; the connector is keyed but double-check before first power-up. This is also how the board gets power to flash from, since USB-C is data-only (see below).

None of these three ship on the assembled board — order them separately and connect them before you flash.

### 3. Flash firmware

Each populated board runs the same firmware image. From [`code/`](code):

```bash
pip install platformio
cp src/common/secrets.example.h src/common/secrets.h     # then edit it
python3 -c "import os;print(', '.join('0x%02x'%b for b in os.urandom(16)))"   # paste into TIPTOE_NETWORK_KEY

pio run -t upload        # board must be running from battery or Qi (USB is data-only)
pio device monitor       # press a key within 3 s of boot for the console
```

- **USB-C is data-only by design** — the board must be powered from its battery or sitting on the Qi pad while you flash and use the console.
- From the console, set the role: `role handheld` on the unit you'll carry, `role node` (the default) on every outdoor unit. The unit reboots into the new role.
- Give each node a unique ID (`id 1`, `id 2`, …) from the console or its maintenance web UI.
- If a node is already asleep, hold BOOT, tap RST, release BOOT to force the ROM bootloader for the first flash. After that, firmware updates can go over Wi-Fi from the node's maintenance page.

Full firmware details, pin map, and console commands: [`code/README.md`](code/README.md).

### 4. First bring-up checklist

Run this on every board right after its first flash:

1. Power from battery, connect USB, reset, and press a key within 3 s → console.
2. `i2c` should list `0x20` (PCF8574), `0x36` (MAX17048), `0x6A` (BQ25895). The camera is on its own bus.
3. `selftest` checks the I/O expander, charger, fuel gauge, `VOUT` power-good, camera PID, mic level, IR pulse (watch through a phone camera — it's infrared), the SX1262 LoRa radio, flash, and PSRAM.
4. `status` shows charger state and the NTC reading; `chg` dumps the charger registers.
5. With the handheld powered on, `send` from a node should print `reply received`. `snap` runs a full event end-to-end.
6. `exit` → the node goes into normal sleep/wake operation.

### 5. Case & final assembly

- Case model: [`case/TIPTOE_Case.stp`](case/TIPTOE_Case.stp). Print or machine it, mount the populated PCB with the camera/PIR/IR LEDs aligned to the enclosure cutouts, and close it up for a node deployment.

### 6. Pair the app

- Install the app from [Release v1.0.0](https://github.com/Cosmin-Mare/TIPTOE/releases/tag/v1.0.0) (Android APK / iOS IPA), or run it from source — see [`code/app/README.md`](code/app/README.md).
- Pair with the handheld from the app. The BLE pairing PIN is `TIPTOE_BLE_PASSKEY`, set in the firmware's `secrets.h` — it isn't compiled into the app.
- No board yet? The app's first screen offers **Review with a simulation**, which walks through the whole flow without any hardware.

## Bill of Materials

Full sheet with LCSC links: [`PCB/BOM.csv`](PCB/BOM.csv).

| Qty | Designator(s) | Part / Value | LCSC # |
|---|---|---|---|
| 1 | 5VBoost | AP3602AKTR-G1 (PIR 5V boost) | [C460358](https://www.lcsc.com/product-detail/C460358.html) |
| 2 | ACM1, ACM2 | 22nF, C0603 | [C21122](https://www.lcsc.com/product-detail/C21122.html) |
| 1 | BATTERY | B2B-PH-K-S-GW (JST PH 2-pin) | [C5251182](https://www.lcsc.com/product-detail/C5251182.html) |
| 1 | Bat_Charger | BQ25895RTWT | [C2861263](https://www.lcsc.com/product-detail/C2861263.html) |
| 5 | BST1, BST2, C11, C12, C13 | 10nF, C0603 | [C100042](https://www.lcsc.com/product-detail/C100042.html) |
| 1 | Buck_Boost | TPS63020DSJR | [C15483](https://www.lcsc.com/product-detail/C15483.html) |
| 14 | C1, C5, C7, C15, C23, C25, C26, C27, C34, C36, C38, C39, DC1_ESP, DC2_ESP | 100nF, C0603 | [C14663](https://www.lcsc.com/product-detail/C14663.html) |
| 9 | C2, C3, C6, C9, C16, C17, C18, C21, C22 | 10uF, C1206 | [C9807](https://www.lcsc.com/product-detail/C9807.html) |
| 1 | C4 | 1nF, C0603 | [C106246](https://www.lcsc.com/product-detail/C106246.html) |
| 11 | C8, C19, C20, C24, C29, C30, C31, C32, C33, C35, C37 | 1uF, C1206 | [C90539](https://www.lcsc.com/product-detail/C90539.html) |
| 1 | C10 | 4.7uF, C1206 | [C29823](https://www.lcsc.com/product-detail/C29823.html) |
| 1 | C14 | 22uF, C1206 | [C5448922](https://www.lcsc.com/product-detail/C5448922.html) |
| 1 | C28 | 820pF, C0603 | [C107057](https://www.lcsc.com/product-detail/C107057.html) |
| 1 | Camera | FPC-05F-24PH20 (0.5mm 24P FPC) | [C2856805](https://www.lcsc.com/product-detail/C2856805.html) |
| 2 | CAM_SCL_PU, CAM_SDA_PU | 4.7kΩ, R0603 | [C23162](https://www.lcsc.com/product-detail/C23162.html) |
| 2 | CLAMP1, CLAMP2 | 470nF, C0603 | [C513577](https://www.lcsc.com/product-detail/C513577.html) |
| 1 | ESP | ESP32-S3-WROOM-1-N16R8 | [C2913202](https://www.lcsc.com/product-detail/C2913202.html) |
| 1 | Fuel_Gauge | MAX17048G+T10 | [C2682616](https://www.lcsc.com/product-detail/C2682616.html) |
| 2 | IO0, RST | TSD001A07526A (tactile button) | [C2888886](https://www.lcsc.com/product-detail/C2888886.html) |
| 1 | IOExpander | PCF8574T/TR | [C2987288](https://www.lcsc.com/product-detail/C2987288.html) |
| 4 | IR1, IR2, IR3, IR4 | IR333C-A (940nm IR LED) | [C5130](https://www.lcsc.com/product-detail/C5130.html) |
| 2 | L1, L2 | 2.2uH inductor | [C76855](https://www.lcsc.com/product-detail/C76855.html) |
| 1 | L3 | GZ1608D601TF (ferrite bead) | [C1002](https://www.lcsc.com/product-detail/C1002.html) |
| 1 | LORA | E22-900M22S (SX1262 LoRa module) | [C411293](https://www.lcsc.com/product-detail/C411293.html) |
| 1 | MIC | ICS-43434 (digital mic) | [C5656610](https://www.lcsc.com/product-detail/C5656610.html) |
| 1 | MSF_IR | AO3400A (IR LED MOSFET) | [C49195711](https://www.lcsc.com/product-detail/C49195711.html) |
| 1 | NTC | NCP18XH103F03RB (10k NTC) | [C13564](https://www.lcsc.com/product-detail/C13564.html) |
| 4 | PD_MSF, R11, R14, R18 | 100kΩ, R0603 | [C25803](https://www.lcsc.com/product-detail/C25803.html) |
| 1 | PIR | HX PM2.54-1x3P (PIR header) | [C22438153](https://www.lcsc.com/product-detail/C22438153.html) |
| 1 | QiCoil | 15uH Qi coil | [C3003210](https://www.lcsc.com/product-detail/C3003210.html) |
| 1 | QIPowerRec | BQ51013BRHLR | [C55663](https://www.lcsc.com/product-detail/C55663.html) |
| 11 | R1, R5, R6, R7, R8, R15, R16, R17, R21, RESETB_PU, R_IO0 | 10kΩ, R0603 | [C25804](https://www.lcsc.com/product-detail/C25804.html) |
| 4 | R2, R4, R9, R10 | 33Ω, R1206 | [C102174](https://www.lcsc.com/product-detail/C102174.html) |
| 1 | R3 | 68Ω, R0603 | [C27592](https://www.lcsc.com/product-detail/C27592.html) |
| 1 | R12 | 560kΩ, R0603 | [C23203](https://www.lcsc.com/product-detail/C23203.html) |
| 3 | R20, R24, R25 | 100Ω, R0603 | [C22775](https://www.lcsc.com/product-detail/C22775.html) |
| 1 | R22 | 470Ω, R0603 | [C23179](https://www.lcsc.com/product-detail/C23179.html) |
| 2 | R, R13 | 1kΩ, R0603 | [C126900](https://www.lcsc.com/product-detail/C126900.html) |
| 1 | RT1 | 5.1kΩ, R0603 | [C23186](https://www.lcsc.com/product-detail/C23186.html) |
| 1 | RT2 | 30kΩ, R0603 | [C100945](https://www.lcsc.com/product-detail/C100945.html) |
| 2 | R_CC5, R_CC6 | 5.1kΩ, R0402 | [C25905](https://www.lcsc.com/product-detail/C25905.html) |
| 2 | R_CC7, R_CC8 | 22Ω, R0402 | [C25092](https://www.lcsc.com/product-detail/C25092.html) |
| 1 | U4 | 47nF, C0805 | [C107154](https://www.lcsc.com/product-detail/C107154.html) |
| 1 | USBC | TYPE-C-31-M-12 (USB-C receptacle) | [C165948](https://www.lcsc.com/product-detail/C165948.html) |
| 1 | Voltage_Reg | ME6211C33M5G-N (3.3V LDO) | [C82942](https://www.lcsc.com/product-detail/C82942.html) |
| 1 | Voltage_Reg1.5V | TPLP5907MFX-1.5 (1.5V LDO, camera DVDD) | [C49451987](https://www.lcsc.com/product-detail/C49451987.html) |
| 1 | Voltage_Reg2.8V | LP5907MFX-2.8/NOPB (2.8V LDO, camera AVDD/DOVDD) | [C186700](https://www.lcsc.com/product-detail/C186700.html) |

Not on this sheet but needed to build a unit: an **HC-SR501 PIR module** and an **OV3660 camera module** (both connect via headers/FPC rather than being placed on the board), plus a single-cell Li-ion/LiPo battery with a JST-PH connector.

## Repo contents
- [`code/`](code) — firmware (`src/`), phone app (`app/`), and how to flash or run the simulation
- [`PCB/`](PCB) — `BOM.csv`, `TIPTOE.epro2`, `GERBER.zip`
- [`case/`](case) — `TiptoeCase_print.3mf`, `TiptoeCase_NO_PCB.stl`
- [`JOURNAL.md`](JOURNAL.md) — dated build log, including time spent and screenshots
