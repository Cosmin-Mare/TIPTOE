#include "storage.h"
#include <LittleFS.h>
#include <vector>

namespace storage {

static bool s_ok = false;

bool begin() {
  s_ok = LittleFS.begin(true, "/fs", 10, "spiffs");
  if (s_ok && !LittleFS.exists("/ev")) LittleFS.mkdir("/ev");
  return s_ok;
}

bool ok() { return s_ok; }

size_t freeBytes() { return s_ok ? LittleFS.totalBytes() - LittleFS.usedBytes() : 0; }

bool writeFile(const String& path, const uint8_t* a, size_t alen, const uint8_t* b, size_t blen) {
  if (!s_ok) return false;
  File f = LittleFS.open(path, "w");
  if (!f) return false;
  bool ok = f.write(a, alen) == alen;
  if (ok && b && blen) ok = f.write(b, blen) == blen;
  f.close();
  if (!ok) LittleFS.remove(path);
  return ok;
}

bool writeText(const String& path, const String& text) {
  return writeFile(path, (const uint8_t*)text.c_str(), text.length());
}

static std::vector<uint32_t> eventIds() {
  std::vector<uint32_t> ids;
  File dir = LittleFS.open("/ev");
  if (!dir) return ids;
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
    String n = f.name();
    if (n.endsWith(".txt")) ids.push_back(n.toInt());
  }
  std::sort(ids.begin(), ids.end());
  return ids;
}

void prune(size_t minFree) {
  if (!s_ok) return;
  auto ids = eventIds();
  for (uint32_t id : ids) {
    if (freeBytes() >= minFree) break;
    for (const char* suf : {".jpg", "_hi.jpg", ".wav", ".txt"}) LittleFS.remove("/ev/" + String(id) + suf);
  }
}

void clear() {
  if (!s_ok) return;
  File dir = LittleFS.open("/ev");
  std::vector<String> names;
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) names.push_back(String("/ev/") + f.name());
  dir.close();
  for (auto& n : names) LittleFS.remove(n);
}

void list(Print& out) {
  if (!s_ok) {
    out.println("fs not mounted");
    return;
  }
  File dir = LittleFS.open("/ev");
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) out.printf("  %-16s %8u\n", f.name(), (unsigned)f.size());
  out.printf("free %u KB of %u KB\n", (unsigned)(freeBytes() / 1024), (unsigned)(LittleFS.totalBytes() / 1024));
}

String listJson() {
  String j = "[";
  auto ids = eventIds();
  for (int i = (int)ids.size() - 1, n = 0; i >= 0 && n < 100; i--, n++) {
    String base = "/ev/" + String(ids[i]);
    String meta;
    File f = LittleFS.open(base + ".txt");
    if (f) {
      meta = f.readString();
      f.close();
    }
    meta.replace("\"", "'");
    meta.replace("\n", "; ");
    if (j.length() > 1) j += ",";
    j += "{\"id\":" + String(ids[i]) + ",\"meta\":\"" + meta + "\",\"hi\":" +
         (LittleFS.exists(base + "_hi.jpg") ? "true" : "false") + ",\"wav\":" +
         (LittleFS.exists(base + ".wav") ? "true" : "false") + "}";
  }
  return j + "]";
}

}  // namespace storage
