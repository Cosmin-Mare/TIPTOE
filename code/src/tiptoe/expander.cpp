#include "expander.h"
#include <Wire.h>
#include "board.h"

namespace expander {

// P0,P1,P3,P7 high (inputs / unused), P4 high (radio out of reset), IR/RXEN/TXEN low.
static constexpr uint8_t DEFAULTS = (1 << 0) | (1 << 1) | (1 << 3) | (1 << xbit::LORA_NRST) | (1 << 7);
static uint8_t s_out = DEFAULTS;
static bool s_ok = false;

static bool push() {
  Wire.beginTransmission(i2caddr::EXPANDER);
  Wire.write(s_out);
  return Wire.endTransmission() == 0;
}

bool begin() {
  s_out = DEFAULTS;
  s_ok = push();
  return s_ok;
}

bool ok() { return s_ok; }

bool write(uint8_t bit, bool level) {
  uint8_t prev = s_out;
  if (level) s_out |= (1 << bit);
  else s_out &= ~(1 << bit);
  if (prev == s_out && s_ok) return true;
  s_ok = push();
  return s_ok;
}

uint8_t readAll() {
  if (Wire.requestFrom(i2caddr::EXPANDER, (uint8_t)1) != 1) {
    s_ok = false;
    return 0xFF;
  }
  return Wire.read();
}

bool read(uint8_t bit) { return (readAll() >> bit) & 1; }

uint8_t shadow() { return s_out; }

}  // namespace expander
