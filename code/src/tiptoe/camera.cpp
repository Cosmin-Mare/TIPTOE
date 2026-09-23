#include "camera.h"
#include <Arduino.h>
#include <Wire.h>
#include "board.h"
#include "esp_camera.h"
#include "expander.h"
#include "img_converters.h"

#ifndef TIPTOE_CAM_VFLIP
#define TIPTOE_CAM_VFLIP 1        // flip to match how the module sits in the enclosure
#endif
#ifndef TIPTOE_CAM_HMIRROR
#define TIPTOE_CAM_HMIRROR 0
#endif

namespace camera {

static constexpr framesize_t HIRES = FRAMESIZE_QXGA;   // 2048x1536, OV3660 native

static bool s_inited = false;

// The SCCB driver leaves the pads as open-drain with internal pull-ups to 3.3 V. Once the
// camera rails are off, that would back-feed the sensor — park them as plain inputs.
void releasePins() {
  pinMode(pins::CAM_SDA, INPUT);
  pinMode(pins::CAM_SCL, INPUT);
}
static uint16_t s_pid = 0;

static bool init(framesize_t maxSize, uint8_t quality) {
  camera_config_t c = {};
  c.pin_pwdn = -1;                // PWDN hard-wired low
  c.pin_reset = -1;               // RESETB pulled up to VOUT
  c.pin_xclk = pins::CAM_XCLK;
  c.pin_sccb_sda = pins::CAM_SDA; // dedicated SCCB bus on I2C port 1 (Wire keeps port 0)
  c.pin_sccb_scl = pins::CAM_SCL;
  c.sccb_i2c_port = 1;
  c.pin_d7 = pins::CAM_D9;
  c.pin_d6 = pins::CAM_D8;
  c.pin_d5 = pins::CAM_D7;
  c.pin_d4 = pins::CAM_D6;
  c.pin_d3 = pins::CAM_D5;
  c.pin_d2 = pins::CAM_D4;
  c.pin_d1 = pins::CAM_D3;
  c.pin_d0 = pins::CAM_D2;
  c.pin_vsync = pins::CAM_VSYNC;
  c.pin_href = pins::CAM_HREF;
  c.pin_pclk = pins::CAM_PCLK;
  c.xclk_freq_hz = 20000000;
  c.ledc_timer = LEDC_TIMER_0;
  c.ledc_channel = LEDC_CHANNEL_0;
  c.pixel_format = PIXFORMAT_JPEG;
  c.frame_size = maxSize;         // buffers are sized for this; smaller sizes set later
  c.jpeg_quality = quality;
  c.fb_count = 2;
  c.fb_location = CAMERA_FB_IN_PSRAM;
  c.grab_mode = CAMERA_GRAB_LATEST;

  esp_err_t err = esp_camera_init(&c);
  if (err != ESP_OK) {
    log_e("esp_camera_init: 0x%x", err);
    return false;
  }
  sensor_t* s = esp_camera_sensor_get();
  if (!s) {
    esp_camera_deinit();
    return false;
  }
  s_pid = s->id.PID;
  if (s_pid != OV3660_PID) log_w("sensor PID 0x%04x (expected OV3660 0x3660)", s_pid);
  s->set_vflip(s, TIPTOE_CAM_VFLIP);
  s->set_hmirror(s, TIPTOE_CAM_HMIRROR);
  if (s_pid == OV3660_PID) {      // Espressif's recommended OV3660 tuning
    s->set_brightness(s, 1);
    s->set_saturation(s, -2);
  }
  s_inited = true;
  return true;
}

static void deinit() {
  if (s_inited) esp_camera_deinit();
  s_inited = false;
  releasePins();
}

static void discard(int n) {
  for (int i = 0; i < n; i++) {
    camera_fb_t* fb = esp_camera_fb_get();
    if (fb) esp_camera_fb_return(fb);
  }
}

static bool grab(Image& out) {
  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) return false;
  out.data = (uint8_t*)ps_malloc(fb->len);
  if (!out.data) {
    esp_camera_fb_return(fb);
    return false;
  }
  memcpy(out.data, fb->buf, fb->len);
  out.len = fb->len;
  out.width = fb->width;
  out.height = fb->height;
  esp_camera_fb_return(fb);
  return true;
}

static uint8_t meanLuma(const Image& img) {
  size_t px = size_t(img.width) * img.height;
  uint8_t* rgb = (uint8_t*)ps_malloc(px * 3);
  if (!rgb) return 128;
  uint8_t luma = 128;
  if (fmt2rgb888(img.data, img.len, PIXFORMAT_JPEG, rgb)) {
    uint64_t sum = 0;
    for (size_t i = 0; i < px * 3; i += 3) sum += (uint32_t(rgb[i]) * 29 + rgb[i + 1] * 150 + rgb[i + 2] * 77) >> 8;
    luma = uint8_t(sum / px);
  }
  free(rgb);
  return luma;
}

Result capture(uint8_t framesize, uint8_t quality, uint8_t irMode, uint8_t irLuma, bool hires, bool grayIr) {
  Result r;
  delay(30);   // VOUT -> 2.8 V / 1.5 V LDOs -> sensor POR + RESETB RC
  if (!init(hires ? HIRES : (framesize_t)framesize, quality)) return r;
  r.sensor_pid = s_pid;
  sensor_t* s = esp_camera_sensor_get();
  s->set_framesize(s, (framesize_t)framesize);
  s->set_quality(s, quality);

  bool ir = irMode == 1;
  discard(4);  // let AEC/AWB settle
  if (irMode == 2) {
    Image probe;
    if (grab(probe)) {
      r.luma = meanLuma(probe);
      ir = r.luma < irLuma;
      release(probe);
    }
  }
  if (ir) {
    expander::write(xbit::IR_LED, true);
    if (grayIr) s->set_special_effect(s, 2);   // grayscale — IR makes colour useless anyway
    discard(4);
    r.ir_used = true;
  }

  r.ok = grab(r.lora);

  if (hires) {
    s->set_framesize(s, HIRES);
    s->set_quality(s, 12);   // ~150-350 KB at 2048x1536
    discard(2);
    grab(r.hires);
  }

  expander::write(xbit::IR_LED, false);
  deinit();
  return r;
}

Image snapshot(uint8_t framesize, uint8_t quality, bool ir) {
  Image img;
  delay(30);
  if (!init(HIRES, quality)) return img;
  sensor_t* s = esp_camera_sensor_get();
  s->set_framesize(s, (framesize_t)framesize);
  if (ir) expander::write(xbit::IR_LED, true);
  discard(4);
  grab(img);
  expander::write(xbit::IR_LED, false);
  deinit();
  return img;
}

bool probe(uint16_t* pid) {
  delay(30);
  bool ok = init(FRAMESIZE_QVGA, 12);
  if (pid) *pid = s_pid;
  deinit();
  return ok;
}

void release(Image& img) {
  free(img.data);
  img = Image();
}

void release(Result& r) {
  release(r.lora);
  release(r.hires);
}

}  // namespace camera
