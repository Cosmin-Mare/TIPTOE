// TIPTOE rev1 pin map — derived from Netlist_Schematic1_2026-09-22.net
#pragma once
#include <stdint.h>

#define FW_MAJOR 1
#define FW_MINOR 2

namespace pins {
// Main I2C bus (10k pull-ups R6/R7 to 3V3): PCF8574 (0x20), BQ25895 (0x6A), MAX17048 (0x36).
constexpr int I2C_SDA = 8;
constexpr int I2C_SCL = 9;
constexpr int EXP_INT = 38;          // PCF8574 INT# (R17 pull-up). Not an RTC pin -> no deep-sleep wake.

constexpr int VOUT_EN = 2;           // TPS63020 EN (R18 100k pull-down). VOUT feeds camera LDOs, mic, IR LEDs.
constexpr int PIR = 3;               // HC-SR501 OUT, active high (RTC GPIO -> ext0 wake)
constexpr int BTN_BOOT = 0;          // IO0 button, active low (RTC GPIO -> ext1 wake)

// E22-900M22S (SX1262)
constexpr int LORA_MOSI = 10;
constexpr int LORA_MISO = 11;
constexpr int LORA_SCK = 12;
constexpr int LORA_NSS = 13;
constexpr int LORA_BUSY = 14;
constexpr int LORA_DIO1 = 21;

// ICS-43434 I2S mic (L/R tied to VOUT -> right slot)
constexpr int MIC_SCK = 1;
constexpr int MIC_WS = 47;
constexpr int MIC_SD = 48;

// OV3660 on 24-pin FPC. Rails: CAM 2.8V (AVDD via bead, DOVDD) and CAM 1.5V (DVDD), both
// LDOs fed from VOUT. PWDN hard-wired to GND, RESETB pulled up to CAM 2.8V with an RC delay.
// SCCB on its own pins (UART0 TXD0/RXD0) via 1k series R, 4.7k pull-ups to CAM 2.8V.
constexpr int CAM_SDA = 43;   // TXD0 — driven by ROM/boot on every reset; released to input in setup()
constexpr int CAM_SCL = 44;   // RXD0
constexpr int CAM_XCLK = 39;
constexpr int CAM_PCLK = 16;
constexpr int CAM_VSYNC = 42;
constexpr int CAM_HREF = 41;
constexpr int CAM_D9 = 40;   // Y9
constexpr int CAM_D8 = 18;
constexpr int CAM_D7 = 17;
constexpr int CAM_D6 = 15;
constexpr int CAM_D5 = 6;
constexpr int CAM_D4 = 4;
constexpr int CAM_D3 = 5;
constexpr int CAM_D2 = 7;    // Y2
}  // namespace pins

// PCF8574 bit assignment
namespace xbit {
constexpr uint8_t GAUGE_ALRT = 0;    // in, MAX17048 ALRT# (active low)
constexpr uint8_t IR_LED = 2;        // out, AO3400 gate via 100R (high = IR on)
constexpr uint8_t VOUT_PG = 3;       // in, TPS63020 PG (high = good)
constexpr uint8_t LORA_NRST = 4;     // out, SX1262 reset (low = reset)
constexpr uint8_t LORA_RXEN = 5;     // out
constexpr uint8_t LORA_TXEN = 6;     // out
// P1, P7 unconnected
}  // namespace xbit

namespace i2caddr {
constexpr uint8_t EXPANDER = 0x20;
constexpr uint8_t GAUGE = 0x36;
constexpr uint8_t CHARGER = 0x6A;
constexpr uint8_t CAMERA = 0x3C;    // on the camera's own SCCB bus (GPIO43/44)
}  // namespace i2caddr
