# TIPTOE

Multi-unit surveillance system with motion detection, night vision, and multiple communication modes. Deployable and waterproof — it's the perfect awareness device, with a companion app for alerts, photo snapshots, and video + audio streaming.

<img width="681" height="713" alt="Screenshot 2026-07-27 at 9 52 12 PM" src="https://github.com/user-attachments/assets/f539a92c-e7ee-4af4-881a-41a894f9701c" />
<img width="3840" height="1360" alt="schematics" src="https://github.com/user-attachments/assets/82500cba-a05f-4c69-9f4e-f034199c47a7" />


## Overview

TIPTOE is a custom surveillance device built around the ESP32-S3, designed for being deployed in any outside or inside environment relying on LoRa, esp now and wifi direct to talk to each other and to a receving device (a phone) through a mobile app interface (To be developed)

## Features

The device has wireless QI charging. It is designed to be fully waterproof and deployable on any surface (trees, ground, walls, etc) - Case to be designed for this. It also features a PIR sensor to detect presence, a camera to take snapshots or stream video and a mic to listen.

## Hardware

**Core**
- ESP32-S3-WROOM-1-N16R8 (main MCU)
- PCF8574T I/O expander (extra GPIO for peripherals)
**Power**
- P9025AC Qi wireless receiver -> BQ25895 battery charger -> TPS63020 buck-boost -> ME6211 LDO
- MAX17048 fuel gauge for battery monitoring
**Sensing & I/O**
- OV3660 camera (DVP bus)
- INMP441 digital microphone
- HC-SR501 PIR motion sensor (boosted to 5V via AP3602AKTR-G1)
- IR LEDs for night vision (switched via AO3400A MOSFET)
- E22-900M22S LoRa module for long-range communication

## Project Status

Currently on the first PCB prototype ready to be printed. There have been a few itterations throughout the design process, for which I recommend checking the JOURNAL.md file which was written in realtime throughout the design process and is left intentionally unpolished to show the raw process of developing such a device.

## Roadmap

Next steps would be confirming the prototype by testing it in person, Making a case for it with some art, and showcasing it in the hack club slack and also on other platforms such as hackaday.

## Repo contents
- JOURNAL.md - dated build log includes time spent working and screenshots from throughout the journe 
- BOM.xlsx - Bill of materials
- EASYEDA.epro2 - Easyeda Pro source file
- GERBER.zip - gerber file ready for printing
