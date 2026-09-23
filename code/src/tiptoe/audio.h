// ICS-43434 capture on a background task (runs while the camera works).
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace audio {

constexpr uint32_t SAMPLE_RATE = 16000;

struct Result {
  bool ok = false;
  float peak_db = -120, rms_db = -120;   // dBFS
  int16_t* pcm = nullptr;                // mono 16-bit, PSRAM (free with release)
  size_t samples = 0;
  int channel = -1;                      // which I2S slot carried data (0/1)
};

bool start(uint32_t ms, bool keepPcm);   // VOUT must be on
Result wait(uint32_t timeoutMs);
void release(Result& r);
// Build a WAV header for r (44 bytes)
void wavHeader(const Result& r, uint8_t out[44]);

}  // namespace audio
