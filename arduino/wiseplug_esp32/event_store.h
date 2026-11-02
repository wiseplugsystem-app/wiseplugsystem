// Store-and-forward for the plug's reports: every report is written to flash
// first and deleted only once the server has confirmed it, so Wi-Fi outages
// and reboots (power cuts, a watchdog restart) lose nothing.
// Pure C++ (no Arduino APIs): unit-tested in test/event_store_test.cpp.
//
// The store is a file of `capacity` fixed-size slots. Each slot holds one
// record: a header (sequence number, kind, flags, length, CRC) and its
// payload. A record is written in one piece; a power cut halfway leaves a
// slot whose CRC does not match, which is treated as empty. Deleting a record
// rewrites only its header with the DONE flag, which the CRC does not cover.
// At start the slots are scanned to find what is still waiting, oldest
// (lowest sequence number) first.
//
// When every slot is waiting, a new record replaces the oldest non-critical
// one (e.g. a usage summary); a critical one (a safety cutoff or warning) is
// replaced only when nothing else is left. Both are counted as dropped.
#pragma once
#include <stdint.h>
#include <string.h>

// Where the slots live: a file on the ESP32, memory in the tests.
struct StoreIO {
  virtual bool read(uint32_t offset, void* data, uint32_t size) = 0;
  virtual bool write(uint32_t offset, const void* data, uint32_t size) = 0;
  virtual ~StoreIO() = default;
};

inline uint32_t storeCrc32(const uint8_t* data, uint32_t size, uint32_t crc = 0xFFFFFFFFu) {
  for (uint32_t i = 0; i < size; ++i) {
    crc ^= data[i];
    for (int k = 0; k < 8; ++k) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
  }
  return crc;
}

template <uint32_t SLOT_SIZE, uint32_t CAPACITY>
class EventStore {
 public:
  static constexpr uint32_t MAGIC = 0x57505331;  // "WPS1"
  static constexpr uint8_t CRITICAL = 1, DONE = 2;
  struct Header {
    uint32_t magic, seq;
    uint8_t kind, flags;
    uint16_t size;
    uint32_t crc;  // over seq, kind, the CRITICAL flag, size and payload
  };
  static constexpr uint32_t MAX_PAYLOAD = SLOT_SIZE - sizeof(Header);
  static_assert(SLOT_SIZE > sizeof(Header), "slot too small");

  // Reads every slot header. Returns false if the storage cannot be read.
  bool begin(StoreIO* io) {
    io_ = io; nextSeq_ = 1; pending_ = 0;
    uint8_t buffer[SLOT_SIZE];
    for (uint32_t i = 0; i < CAPACITY; ++i) {
      state_[i] = EMPTY;
      if (!io_->read(i * SLOT_SIZE, buffer, SLOT_SIZE)) return false;
      Header h; memcpy(&h, buffer, sizeof h);
      if (h.magic != MAGIC || h.size > MAX_PAYLOAD || h.crc != crcOf(h, buffer + sizeof h)) continue;
      seq_[i] = h.seq; critical_[i] = h.flags & CRITICAL;
      if (h.seq >= nextSeq_) nextSeq_ = h.seq + 1;  // numbers never repeat
      if (!(h.flags & DONE)) { state_[i] = PENDING; ++pending_; }
    }
    return true;
  }

  // Saves a record. Returns its sequence number (0 if it could not be written).
  uint32_t push(uint8_t kind, bool critical, const void* payload, uint32_t size) {
    if (!io_ || size > MAX_PAYLOAD) return 0;
    int32_t slot = freeSlot();
    if (slot < 0) {  // full: drop the oldest non-critical record, else the oldest
      slot = oldestPending(false);
      if (slot < 0) slot = oldestPending(true);
      ++dropped_; if (critical_[slot]) ++droppedCritical_;
      state_[slot] = EMPTY; --pending_;
    }
    uint8_t buffer[SLOT_SIZE] = {};
    Header h{MAGIC, nextSeq_, kind, uint8_t(critical ? CRITICAL : 0), uint16_t(size), 0};
    memcpy(buffer + sizeof h, payload, size);
    h.crc = crcOf(h, buffer + sizeof h);
    memcpy(buffer, &h, sizeof h);
    if (!io_->write(uint32_t(slot) * SLOT_SIZE, buffer, sizeof h + size)) return 0;
    seq_[slot] = nextSeq_; critical_[slot] = critical; state_[slot] = PENDING; ++pending_;
    return nextSeq_++;
  }

  // The `max` oldest waiting records' slots, oldest first. Returns how many.
  uint32_t oldest(int32_t* slots, uint32_t max) const {
    uint32_t n = 0, after = 0;
    while (n < max) {
      int32_t best = -1;
      for (uint32_t i = 0; i < CAPACITY; ++i) {
        if (state_[i] == PENDING && seq_[i] > after && (best < 0 || seq_[i] < seq_[best])) best = int32_t(i);
      }
      if (best < 0) break;
      slots[n++] = best; after = seq_[best];
    }
    return n;
  }

  // Reads the record in `slot`. Returns false if it is not waiting or unreadable.
  bool read(int32_t slot, uint8_t& kind, uint32_t& seq, void* payload, uint32_t& size) {
    if (slot < 0 || uint32_t(slot) >= CAPACITY || state_[slot] != PENDING) return false;
    uint8_t buffer[SLOT_SIZE];
    if (!io_->read(uint32_t(slot) * SLOT_SIZE, buffer, SLOT_SIZE)) return false;
    Header h; memcpy(&h, buffer, sizeof h);
    if (h.magic != MAGIC || h.seq != seq_[slot] || h.crc != crcOf(h, buffer + sizeof h)) return false;
    kind = h.kind; seq = h.seq; size = h.size;
    memcpy(payload, buffer + sizeof h, h.size);
    return true;
  }

  // The server has the record in `slot`: it is deleted (its slot is free).
  bool done(int32_t slot) {
    if (slot < 0 || uint32_t(slot) >= CAPACITY || state_[slot] != PENDING) return false;
    Header h;
    if (!io_->read(uint32_t(slot) * SLOT_SIZE, &h, sizeof h)) return false;
    h.flags |= DONE;
    if (!io_->write(uint32_t(slot) * SLOT_SIZE, &h, sizeof h)) return false;
    state_[slot] = FREE; --pending_;
    return true;
  }

  uint32_t pending() const { return pending_; }
  uint32_t capacity() const { return CAPACITY; }
  uint32_t dropped() const { return dropped_; }                   // since start
  uint32_t droppedCritical() const { return droppedCritical_; }   // of those, safety records

 private:
  enum : uint8_t { EMPTY, FREE, PENDING };  // FREE: delivered (DONE), reusable
  static uint32_t crcOf(const Header& h, const uint8_t* payload) {
    uint8_t meta[11];
    memcpy(meta, &h.seq, 4); meta[4] = h.kind; meta[5] = h.flags & CRITICAL;
    memcpy(meta + 6, &h.size, 2); meta[8] = 'W'; meta[9] = 'P'; meta[10] = 'S';
    return storeCrc32(payload, h.size > MAX_PAYLOAD ? 0 : h.size, storeCrc32(meta, sizeof meta));
  }
  int32_t freeSlot() const {
    for (uint32_t i = 0; i < CAPACITY; ++i) if (state_[i] != PENDING) return int32_t(i);
    return -1;
  }
  int32_t oldestPending(bool critical) const {
    int32_t best = -1;
    for (uint32_t i = 0; i < CAPACITY; ++i) {
      if (state_[i] == PENDING && critical_[i] == critical && (best < 0 || seq_[i] < seq_[best])) best = int32_t(i);
    }
    return best;
  }

  StoreIO* io_ = nullptr;
  uint32_t seq_[CAPACITY] = {};
  uint8_t state_[CAPACITY] = {};
  bool critical_[CAPACITY] = {};
  uint32_t nextSeq_ = 1, pending_ = 0, dropped_ = 0, droppedCritical_ = 0;
};
