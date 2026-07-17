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

# July 17: Power tree done

Found a bunch of stuff that I wired wrong such as the TPS63020 FB loop wired wrong, its PG was tied to ground so you couldn't read the status, the I2C bus wasn't actually tied correctly and I had to learn about what it actually is and it's so interesting how little pieces of sillicon are so smart man. Anyways, there's also other stuff that was tied wrong and I had to check a bunch of datasheets and checked every pin, every connection and every wire and hopefully it's good now, bc if I do anything wrong here I'll basically have PCB that aren't gonna be able to get powered. and holy moly this schematic is getting huge

<img width="4698" height="3326" alt="SCH_Schematic1_1-P1_2026-07-16" src="https://github.com/user-attachments/assets/6fc7bd76-85c2-48a5-bb75-413a97b8a0ff" />

**Total Time spent: 2 hours**


