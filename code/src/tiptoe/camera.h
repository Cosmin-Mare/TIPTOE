// OV3660 capture pipeline (auto IR, optional full-res local copy).
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace camera {

struct Image {
  uint8_t* data = nullptr;   // PSRAM, caller frees with camera::release()
  size_t len = 0;
  uint16_t width = 0, height = 0;
};

struct Result {
  bool ok = false;
  Image lora;                // small JPEG for the radio
  Image hires;               // optional full-res JPEG for local storage
  uint8_t luma = 0;          // mean luma of the IR-off probe frame
  bool ir_used = false;
  uint16_t sensor_pid = 0;
};

// Rail (VOUT) must already be on. Initializes, captures, de-initializes the camera.
Result capture(uint8_t framesize, uint8_t quality, uint8_t irMode, uint8_t irLuma, bool hires,
               bool grayscaleIr);
// Single frame for the web UI.
Image snapshot(uint8_t framesize, uint8_t quality, bool ir);
bool probe(uint16_t* pid);   // init + read sensor id + deinit
void releasePins();         // GPIO43/44 -> high-Z inputs (call early on every boot)
void release(Image& img);
void release(Result& r);

}  // namespace camera
