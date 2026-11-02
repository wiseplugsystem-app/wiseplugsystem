// Unit tests for the plug's store-and-forward (event_store.h). Build and run on a PC:
//   g++ -std=c++17 -o event_store_test test/event_store_test.cpp && ./event_store_test
#include "../arduino/wiseplug_esp32/event_store.h"
#include <assert.h>
#include <stdio.h>
#include <vector>

// The flash file, in memory. `failAfter` makes the next write stop halfway
// (a power cut during the write).
struct MemoryIO : StoreIO {
  std::vector<uint8_t> bytes;
  int failAfter = -1;
  explicit MemoryIO(size_t size) : bytes(size, 0xFF) {}
  bool read(uint32_t offset, void* data, uint32_t size) override {
    if (offset + size > bytes.size()) return false;
    memcpy(data, bytes.data() + offset, size); return true;
  }
  bool write(uint32_t offset, const void* data, uint32_t size) override {
    if (offset + size > bytes.size()) return false;
    uint32_t n = failAfter >= 0 ? uint32_t(failAfter) : size;
    memcpy(bytes.data() + offset, data, n < size ? n : size);
    failAfter = -1; return true;
  }
};

using Store = EventStore<64, 4>;
static uint32_t pushText(Store& s, const char* text, bool critical = false, uint8_t kind = 1) {
  return s.push(kind, critical, text, uint32_t(strlen(text) + 1));
}
static const char* textAt(Store& s, int32_t slot, uint32_t* seq = nullptr) {
  static char buffer[64]; uint8_t kind; uint32_t n, sq;
  assert(s.read(slot, kind, sq, buffer, n));
  if (seq) *seq = sq;
  return buffer;
}

int main() {
  {  // In order, oldest first; deleted only when the server confirms.
    MemoryIO io(64 * 4); Store s; assert(s.begin(&io));
    assert(pushText(s, "a") == 1 && pushText(s, "b") == 2 && pushText(s, "c") == 3);
    int32_t slots[4]; assert(s.oldest(slots, 4) == 3);
    assert(strcmp(textAt(s, slots[0]), "a") == 0 && strcmp(textAt(s, slots[2]), "c") == 0);
    assert(s.done(slots[0]) && s.pending() == 2);
    assert(s.oldest(slots, 1) == 1 && strcmp(textAt(s, slots[0]), "b") == 0);
  }
  {  // A reboot (power cut) keeps what was waiting, and numbers continue.
    MemoryIO io(64 * 4);
    { Store s; s.begin(&io); pushText(s, "a"); pushText(s, "b"); int32_t x; s.oldest(&x, 1); s.done(x); }
    Store s; assert(s.begin(&io));
    assert(s.pending() == 1);
    int32_t slot; uint32_t seq; assert(s.oldest(&slot, 1) == 1);
    assert(strcmp(textAt(s, slot, &seq), "b") == 0 && seq == 2);
    assert(pushText(s, "c") == 3);  // never reuses a number
  }
  {  // A power cut in the middle of a write: that record is ignored, the rest survive.
    MemoryIO io(64 * 4);
    { Store s; s.begin(&io); pushText(s, "kept"); io.failAfter = 20; pushText(s, "half written"); }
    Store s; s.begin(&io);
    assert(s.pending() == 1);
    int32_t slot; s.oldest(&slot, 1); assert(strcmp(textAt(s, slot), "kept") == 0);
  }
  {  // Full: the oldest non-critical record makes room; safety records stay.
    MemoryIO io(64 * 4); Store s; s.begin(&io);
    pushText(s, "cutoff 1", true); pushText(s, "usage 1"); pushText(s, "usage 2"); pushText(s, "cutoff 2", true);
    pushText(s, "usage 3");  // replaces "usage 1"
    assert(s.dropped() == 1 && s.droppedCritical() == 0 && s.pending() == 4);
    int32_t slots[4]; s.oldest(slots, 4);
    assert(strcmp(textAt(s, slots[0]), "cutoff 1") == 0 && strcmp(textAt(s, slots[1]), "usage 2") == 0);
    pushText(s, "cutoff 3", true); pushText(s, "cutoff 4", true);  // replace "usage 2", "usage 3"
    pushText(s, "cutoff 5", true);  // only safety records left: the oldest goes
    assert(s.dropped() == 4 && s.droppedCritical() == 1);
    s.oldest(slots, 4);
    assert(strcmp(textAt(s, slots[0]), "cutoff 2") == 0 && strcmp(textAt(s, slots[3]), "cutoff 5") == 0);
  }
  {  // Too big for a slot: refused, nothing changes.
    MemoryIO io(64 * 4); Store s; s.begin(&io);
    char big[100] = {}; assert(s.push(1, false, big, sizeof big) == 0 && s.pending() == 0);
  }
  {  // Uploading a batch of 2 out of 3, then a reboot: the third is still next.
    MemoryIO io(64 * 4);
    { Store s; s.begin(&io); pushText(s, "1"); pushText(s, "2"); pushText(s, "3");
      int32_t slots[2]; s.oldest(slots, 2); s.done(slots[0]); s.done(slots[1]); }
    Store s; s.begin(&io); int32_t slot; s.oldest(&slot, 1);
    assert(s.pending() == 1 && strcmp(textAt(s, slot), "3") == 0);
  }
  printf("event_store_test: all tests passed\n");
  return 0;
}
