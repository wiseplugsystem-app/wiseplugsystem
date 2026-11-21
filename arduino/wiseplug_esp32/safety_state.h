#pragma once
#include <stdint.h>

// Pure state machine: all time is monotonic milliseconds, independent of NTP.
enum class SocketState { Idle, Sampling, Active, Warning, LockedOut, Disabled };
// The safe-time warning: 60 s for the user plus 3 s for the message to reach
// the phone, so the app's countdown always starts at 60 (it shows at most 60)
// and reaches 0 exactly at the cut-off.
constexpr uint64_t WARNING_MS = 63000;
struct SafetyState {
  SocketState state = SocketState::Idle;
  uint32_t revision = 0;
  uint64_t started = 0, deadline = 0, warningStarted = 0;
  bool runtimeWarning = false;
  bool overridden = false;  // running on time the user granted past the limit
  // How many times "Keep it on" extended this run (the limit is max_overrides).
  uint32_t overrideCount = 0;
  // Off after a safety reset: the outlet stays off until the user turns it on
  // again on purpose (the app asks first), so a reset never restarts the
  // appliance that just hit its limit.
  bool resetHold = false;
  void begin(uint64_t now, uint32_t ceilingSeconds) {
    state = SocketState::Sampling; started = now;
    deadline = now + uint64_t(ceilingSeconds) * 1000;
    runtimeWarning = overridden = false; overrideCount = 0; ++revision;
  }
  bool tick(uint64_t now, uint32_t maxRunTime) {
    if (state == SocketState::Sampling || state == SocketState::Active) {
      runtimeWarning = now - started >= uint64_t(maxRunTime) * 1000;
      if (now >= deadline) {
        state = SocketState::Warning; warningStarted = now; ++revision;
        return true;
      }
    }
    if (state == SocketState::Warning && now - warningStarted >= WARNING_MS) {
      state = SocketState::LockedOut; ++revision; return true;
    }
    return false;
  }
  // maxOverrides: how many extensions one run may have (no limit if left out).
  bool overrideRuntime(uint64_t now, uint32_t seconds, uint32_t maxOverrides = UINT32_MAX) {
    if (state != SocketState::Warning || now - warningStarted >= WARNING_MS ||
        seconds == 0 || seconds > 86400 || overrideCount >= maxOverrides) return false;
    deadline = now + uint64_t(seconds) * 1000;
    state = SocketState::Active; overridden = true; ++overrideCount; ++revision; return true;
  }
  bool remotePower(bool on) {
    if (state == SocketState::LockedOut || state == SocketState::Warning) return false;
    // An ON request while running must never restart the runtime timer.
    if (on && state == SocketState::Disabled) { state = SocketState::Idle; resetHold = false; ++revision; }
    if (!on && state != SocketState::Disabled) { state = SocketState::Disabled; ++revision; }
    return true;
  }
  // The user answered the warning with "Turn off now": the outlet switches
  // off but is NOT locked; the app's switch turns it back on (thesis,
  // Chapter III). Only an unanswered warning locks the outlet.
  bool userTurnOff() {
    if (state != SocketState::Warning) return false;
    state = SocketState::Disabled; resetHold = false; runtimeWarning = overridden = false; ++revision;
    return true;
  }
  // App-requested reset: clears the safety trip but keeps the outlet OFF
  // (resetHold). Power comes back only with a separate TURN_ON.
  bool remoteReset() {
    if (state != SocketState::Warning && state != SocketState::LockedOut) return false;
    state = SocketState::Disabled; resetHold = true; runtimeWarning = overridden = false; ++revision;
    return true;
  }
  // The plug's own button: someone is standing at it, so it switches on.
  void physicalPress() {
    state = (state == SocketState::LockedOut || state == SocketState::Disabled)
        ? SocketState::Idle : SocketState::Disabled;
    resetHold = false; ++revision;
  }
};
