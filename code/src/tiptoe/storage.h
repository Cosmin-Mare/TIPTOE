// Local event archive on LittleFS (~9.8 MB): /ev/<id>.jpg, /ev/<id>_hi.jpg, /ev/<id>.wav, /ev/<id>.txt
#pragma once
#include <Arduino.h>

namespace storage {
bool begin();
bool ok();
bool writeFile(const String& path, const uint8_t* a, size_t alen, const uint8_t* b = nullptr, size_t blen = 0);
bool writeText(const String& path, const String& text);
void prune(size_t minFreeBytes = 1500 * 1024);
size_t freeBytes();
void clear();
void list(Print& out);
String listJson();
}  // namespace storage
