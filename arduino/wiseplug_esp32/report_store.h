// The plug's report stores (see event_store.h and the STORE AND FORWARD
// section of wiseplug_esp32.ino): their size, where their slots live, and
// what each stored report carries. Types only, so the Arduino builder's
// automatic function declarations can use them.
#pragma once
#include <LittleFS.h>
#include <array>
#include <atomic>
#include <map>
#include <string.h>
#include "event_store.h"

constexpr uint32_t STORE_SLOT_BYTES = 256, STORE_SLOTS = 256;  // 64 KB per store
constexpr uint32_t UPLOAD_BATCH = 8;  // reports per request
using ReportStore = EventStore<STORE_SLOT_BYTES, STORE_SLOTS>;
enum : uint8_t { KIND_EVENT = 1, KIND_NOTICE = 2, KIND_SESSION = 3, KIND_SAFETY = 4 };

// The store's slots in a file on the flash data partition.
class FileIO : public StoreIO {
 public:
  bool open(const char* path, uint32_t size) {
    if (LittleFS.exists(path)) {
      File f = LittleFS.open(path, "r");
      bool right = f && f.size() == size;
      f.close();
      if (!right) LittleFS.remove(path);  // another layout: start afresh
    }
    if (!LittleFS.exists(path)) {
      File f = LittleFS.open(path, "w");
      if (!f) return false;
      uint8_t zeros[256] = {};
      for (uint32_t n = 0; n < size; n += sizeof zeros) {
        if (f.write(zeros, sizeof zeros) != sizeof zeros) { f.close(); return false; }
      }
      f.close();
    }
    file_ = LittleFS.open(path, "r+");
    return bool(file_);
  }
  bool read(uint32_t offset, void* data, uint32_t size) override {
    return file_.seek(offset) && file_.read(static_cast<uint8_t*>(data), size) == size;
  }
  bool write(uint32_t offset, const void* data, uint32_t size) override {
    if (!file_.seek(offset) || file_.write(static_cast<const uint8_t*>(data), size) != size) return false;
    file_.flush();
    return true;
  }
 private:
  File file_;
};
// Fallback if the flash cannot be used: a few slots in RAM (lost on restart),
// so reports still reach the server as they did before the store existed.
class RamIO : public StoreIO {
 public:
  bool read(uint32_t offset, void* data, uint32_t size) override {
    auto it = slots_.find(offset / STORE_SLOT_BYTES);
    if (it == slots_.end()) memset(data, 0, size);
    else memcpy(data, it->second.data() + offset % STORE_SLOT_BYTES, size);
    return true;
  }
  bool write(uint32_t offset, const void* data, uint32_t size) override {
    uint32_t slot = offset / STORE_SLOT_BYTES;
    if (!slots_.count(slot) && slots_.size() >= 16) return false;  // RAM is short
    memcpy(slots_[slot].data() + offset % STORE_SLOT_BYTES, data, size);
    return true;
  }
 private:
  std::map<uint32_t, std::array<uint8_t, STORE_SLOT_BYTES>> slots_;
};

// What the app shows about each store (written by its task, read by the Firebase task).
struct StoreStats {
  std::atomic<uint32_t> pending{0}, dropped{0}, droppedSafety{0};
  std::atomic<bool> onFlash{false};
};

struct StoredBoot { char boot[20]; };  // in front of every stored report
