// PCF8574 driver. Quasi-bidirectional: writing 1 = weak pull-up (also "input"), 0 = strong low.
#pragma once
#include <stdint.h>

namespace expander {
bool begin();                    // writes safe defaults; returns true if chip ACKs
bool ok();
bool write(uint8_t bit, bool level);
bool read(uint8_t bit);          // reads the pin (inputs must have been written 1)
uint8_t readAll();
uint8_t shadow();
}  // namespace expander
