---
title: "TIPTOE"
author: "Cosmin Mare"
description: "Multi-unit surveillance system with motion detection, night vision and multiple communication modes. Deployable and waterproof , it's the perfect awareness device and it comes with an app for alerts, photo snapshots and video + audio streaming."
created_at: "2026-06-28"
---

# July 5: Started working on the PCB

Started the project in easyEDA, wired a basic usb C to be able to flash the ESP, wired IO0 pin and reset pin and learned how to do all of these. Also, I asked for help in the slack (more like for a sanity check) and someone actually helped :D and told me that i wired a capacitor wrong and I figured it out by myself why it was wired wrong!! Anyways, I'm super happy with my progress given that it's my first time working with actual components on a PCB by myself.

I've also started watching basically the whole "The Engineering Mindset" channel on youtube but I'm not adding that to the time spent lmao
<img width="782" height="590" alt="Screenshot 2026-07-05 at 9 54 11 PM" src="https://github.com/user-attachments/assets/54daff59-28da-4785-8803-20a65fb3676c" />

**Total time spent: 2 hours**

# July 12: Almost finished wiring the Power stuff

Wired the Qi Receiver, caught some mistakes such as a 100nF capacitor that should've actually been 10nF. Wired the whole BQ25895 battery charger, added a MAX17048 fuel gauge, then when wanting to wire the ALRT# pin, I realized I don't actually have any more free GPIO pins on the ESP (did some calculations bc I haven't yet palced the components) so I added a PCF8574 IO Expander. Changed the generic ESP module I was working with to an actual model that I can order (N16R8). I'm again really happy with the progress and I feel like I learned A LOT about wiring a PCB and power management and GPIO management.

<img width="4698" height="3326" alt="SCH_Schematic1_1-P1_2026-07-12" src="https://github.com/user-attachments/assets/919f318f-d3ed-4c31-85bd-8a4925b0e542" />

**Total Time spent: 3 hours**
