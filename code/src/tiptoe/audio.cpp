#include "audio.h"
#include <Arduino.h>
#include <driver/i2s.h>
#include <math.h>
#include "board.h"

namespace audio {

static TaskHandle_t s_task = nullptr;
static SemaphoreHandle_t s_done = nullptr;
static Result s_res;
static uint32_t s_ms = 0;
static bool s_keep = false;

static constexpr i2s_port_t PORT = I2S_NUM_0;
static constexpr uint32_t SETTLE_MS = 120;   // mic start-up + DC settle, discarded

static bool i2sBegin() {
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX);
  cfg.sample_rate = SAMPLE_RATE;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;   // read both slots, pick the live one
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.intr_alloc_flags = ESP_INTR_FLAG_LEVEL1;
  cfg.dma_buf_count = 6;
  cfg.dma_buf_len = 256;
  if (i2s_driver_install(PORT, &cfg, 0, nullptr) != ESP_OK) return false;
  i2s_pin_config_t p = {};
  p.mck_io_num = I2S_PIN_NO_CHANGE;
  p.bck_io_num = pins::MIC_SCK;
  p.ws_io_num = pins::MIC_WS;
  p.data_out_num = I2S_PIN_NO_CHANGE;
  p.data_in_num = pins::MIC_SD;
  if (i2s_set_pin(PORT, &p) != ESP_OK) {
    i2s_driver_uninstall(PORT);
    return false;
  }
  return true;
}

static void task(void*) {
  Result r;
  if (!i2sBegin()) {
    s_res = r;
    xSemaphoreGive(s_done);
    vTaskDelete(nullptr);
    return;
  }
  const size_t total = (SAMPLE_RATE * s_ms) / 1000;
  const size_t settle = (SAMPLE_RATE * SETTLE_MS) / 1000;
  int32_t* raw = (int32_t*)ps_malloc((total + settle) * 2 * sizeof(int32_t));
  size_t frames = 0;
  if (raw) {
    const size_t want = (total + settle) * 2 * sizeof(int32_t);
    size_t got = 0;
    uint32_t t0 = millis();
    while (got < want && millis() - t0 < s_ms + SETTLE_MS + 1000) {
      size_t n = 0;
      i2s_read(PORT, (uint8_t*)raw + got, min<size_t>(4096, want - got), &n, pdMS_TO_TICKS(200));
      got += n;
    }
    frames = got / (2 * sizeof(int32_t));
  }
  i2s_driver_uninstall(PORT);

  if (raw && frames > settle + 100) {
    // pick the slot with more energy (ICS-43434 L/R=VDD -> right, but slot order varies by driver)
    double e[2] = {0, 0};
    for (size_t i = settle; i < frames; i++)
      for (int c = 0; c < 2; c++) {
        double v = raw[i * 2 + c] >> 8;
        e[c] += v * v;
      }
    int ch = e[1] >= e[0] ? 1 : 0;
    size_t n = frames - settle;
    double mean = 0;
    for (size_t i = settle; i < frames; i++) mean += raw[i * 2 + ch] >> 8;
    mean /= n;
    double sq = 0, peak = 0;
    if (s_keep) r.pcm = (int16_t*)ps_malloc(n * sizeof(int16_t));
    for (size_t i = 0; i < n; i++) {
      double v = double(raw[(settle + i) * 2 + ch] >> 8) - mean;   // 24-bit, DC removed
      sq += v * v;
      if (fabs(v) > peak) peak = fabs(v);
      if (r.pcm) r.pcm[i] = (int16_t)constrain((long)(v / 256.0), -32768L, 32767L);
    }
    const double FS = 8388608.0;
    double rms = sqrt(sq / n);
    r.peak_db = peak > 0 ? 20 * log10(peak / FS) : -120;
    r.rms_db = rms > 0 ? 20 * log10(rms / FS) : -120;
    r.samples = r.pcm ? n : 0;
    r.channel = ch;
    r.ok = e[ch] > 0;
  }
  free(raw);
  s_res = r;
  xSemaphoreGive(s_done);
  vTaskDelete(nullptr);
}

bool start(uint32_t ms, bool keepPcm) {
  if (!s_done) s_done = xSemaphoreCreateBinary();
  if (ms == 0) return false;
  s_ms = ms;
  s_keep = keepPcm;
  s_res = Result();
  return xTaskCreatePinnedToCore(task, "mic", 6144, nullptr, 3, &s_task, 0) == pdPASS;
}

Result wait(uint32_t timeoutMs) {
  Result r;
  if (s_done && xSemaphoreTake(s_done, pdMS_TO_TICKS(timeoutMs)) == pdTRUE) r = s_res;
  return r;
}

void release(Result& r) {
  free(r.pcm);
  r.pcm = nullptr;
  r.samples = 0;
}

void wavHeader(const Result& r, uint8_t h[44]) {
  uint32_t data = r.samples * 2, rate = SAMPLE_RATE, byteRate = SAMPLE_RATE * 2, riff = 36 + data;
  memcpy(h, "RIFF", 4); memcpy(h + 4, &riff, 4); memcpy(h + 8, "WAVEfmt ", 8);
  uint32_t fmtLen = 16; uint16_t pcm = 1, ch = 1, align = 2, bits = 16;
  memcpy(h + 16, &fmtLen, 4); memcpy(h + 20, &pcm, 2); memcpy(h + 22, &ch, 2);
  memcpy(h + 24, &rate, 4); memcpy(h + 28, &byteRate, 4); memcpy(h + 32, &align, 2);
  memcpy(h + 34, &bits, 2); memcpy(h + 36, "data", 4); memcpy(h + 40, &data, 4);
}

}  // namespace audio
