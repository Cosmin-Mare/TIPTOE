// Copy to src/common/secrets.h and fill in. secrets.h is git-ignored.
// Every unit (outdoor nodes and the handheld) must be flashed with the same values.
#pragma once

// Unit-to-unit encryption key (LoRa + ESP-NOW). Generate one:
//   python3 -c "import os;print(', '.join('0x%02x'%b for b in os.urandom(16)))"
#define TIPTOE_NETWORK_KEY {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, \
                            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}

// Handheld: 6-digit BLE passkey your phone asks for when pairing the first time.
#define TIPTOE_BLE_PASSKEY 123456

// Handheld: password of the Wi-Fi access point the app switches on for big transfers (>= 8 chars).
#define TIPTOE_HH_AP_PASS "change-me-too"

// Outdoor node: password of the walk-up maintenance access point (BOOT button) (>= 8 chars).
#define TIPTOE_MAINT_AP_PASS "change-me-please"
