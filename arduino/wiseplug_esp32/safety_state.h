#pragma once
#include <stdint.h>

// Pure state machine: all time is monotonic milliseconds, independent of NTP.
enum class SocketState { Idle, Sampling, Active, Warning, LockedOut, Disabled };
struct SafetyState {
  SocketState state = SocketState::Idle;
  uint32_t revision = 0;
  uint64_t started = 0, deadline = 0, warningStarted = 0;
  bool runtimeWarning = false;
  void begin(uint64_t now, uint32_t ceilingSeconds) {
    state = SocketState::Sampling; started = now;
    deadline = now + uint64_t(ceilingSeconds) * 1000;
    runtimeWarning = false; ++revision;
  }
  bool tick(uint64_t now, uint32_t maxRunTime) {
    if (state == SocketState::Sampling || state == SocketState::Active) {
      runtimeWarning = now - started >= uint64_t(maxRunTime) * 1000;
      if (now >= deadline) {
        state = SocketState::Warning; warningStarted = now; ++revision;
        return true;
      }
    }
    if (state == SocketState::Warning && now - warningStarted >= 60000) {
      state = SocketState::LockedOut; ++revision; return true;
    }
    return false;
  }
  bool overrideRuntime(uint64_t now, uint32_t seconds) {
    if (state != SocketState::Warning || now - warningStarted >= 60000 ||
        seconds == 0 || seconds > 3600) return false;
    deadline = now + uint64_t(seconds) * 1000;
    state = SocketState::Active; ++revision; return true;
  }
  bool remotePower(bool on) {
    if (state == SocketState::LockedOut || state == SocketState::Warning) return false;
    // An ON request while running must never restart the runtime timer.
    if (on && state == SocketState::Disabled) { state = SocketState::Idle; ++revision; }
    if (!on && state != SocketState::Disabled) { state = SocketState::Disabled; ++revision; }
    return true;
  }
  void physicalPress() {
    state = (state == SocketState::LockedOut || state == SocketState::Disabled)
        ? SocketState::Idle : SocketState::Disabled;
    ++revision;
  }
};
