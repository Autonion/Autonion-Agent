#pragma once
#include <cstdint>

namespace autonion {
enum class LockState { unknown, locked, unlocked };
struct SessionSnapshot {
  uint32_t session_id = UINT32_MAX;
  LockState lock_state = LockState::unknown;
  bool active = false;
  bool has_user = false;
};
inline bool IsUnlockedSession(const SessionSnapshot& state, uint32_t expected_session) {
  return expected_session != UINT32_MAX && state.session_id == expected_session &&
      state.active && state.has_user && state.lock_state == LockState::unlocked;
}

// Input delivery is not authentication. Only an observed unlocked session succeeds.
template <class Query, class Clock, class Sleep>
bool WaitForUnlockedSession(uint32_t session_id, uint64_t timeout_ms,
                           Query query, Clock now, Sleep sleep) {
  const auto started = now();
  while (true) {
    if (IsUnlockedSession(query(), session_id)) return true;
    const auto elapsed = now() - started;
    if (elapsed >= timeout_ms) return false;
    sleep(timeout_ms - elapsed < 100 ? timeout_ms - elapsed : 100);
  }
}
}  // namespace autonion
