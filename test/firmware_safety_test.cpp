#include "../arduino/wiseplug_esp32/safety_state.h"
#include <assert.h>
int main() {
  SafetyState s;
  s.begin(1000, 2); s.state = SocketState::Active;
  assert(!s.tick(2999, 1)); assert(s.runtimeWarning);
  assert(s.tick(3000, 1)); assert(s.state == SocketState::Warning);
  assert(!s.tick(62999, 1));
  assert(!s.overrideRuntime(63000, 900)); // exact expiry is rejected
  assert(s.tick(63000, 1)); assert(s.state == SocketState::LockedOut);
  assert(!s.remotePower(true)); assert(!s.remotePower(false));
  assert(!s.overrideRuntime(64000, 900));
  s.physicalPress(); assert(s.state == SocketState::Idle);
  s.begin(100000, 1); s.state = SocketState::Active;
  assert(s.remotePower(true)); assert(s.deadline == 101000);
  s.tick(101000, 1); assert(!s.overrideRuntime(101001, 0));
  assert(!s.overrideRuntime(101001, 3601));
  assert(s.overrideRuntime(160999, 900)); assert(s.deadline == 1060999);
  assert(!s.overrideRuntime(161000, 900)); // replay cannot extend again
  s.tick(1060999, 1); assert(s.state == SocketState::Warning);
  s.tick(1120999, 1); assert(s.state == SocketState::LockedOut);
  // A monotonic clock beyond millis() wrap still enforces the deadline.
  s.physicalPress(); s.begin(0xffffffffULL - 500, 1); s.state = SocketState::Active;
  s.tick(0xffffffffULL + 500, 1); assert(s.state == SocketState::Warning);
  return 0;
}
