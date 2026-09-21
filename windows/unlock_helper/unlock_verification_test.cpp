#include "unlock_verification.h"
#include <cassert>
#include <iostream>

int main() {
  using namespace autonion;
  uint64_t time = 0;
  auto clock = [&] { return time; };
  auto sleep = [&](uint64_t delay) { time += delay; };
  auto state = SessionSnapshot{1, LockState::locked, true, true};
  assert(!WaitForUnlockedSession(1, 500, [&] { return state; }, clock, sleep));
  assert(time == 500); // Wrong password/zero Enter must not become success on timeout.
  time = 0;
  assert(WaitForUnlockedSession(1, 500, [&] {
    if (time >= 200) state.lock_state = LockState::unlocked;
    return state;
  }, clock, sleep));
  assert(time == 200); // Includes a successful desktop transition after zero Enter events.
  assert(!IsUnlockedSession(state, 2));
  state.has_user = false;
  assert(!IsUnlockedSession(state, 1)); // Pre-login station is not an authenticated desktop.
  state.has_user = true; state.active = false;
  assert(!IsUnlockedSession(state, 1));
  state.active = true; state.lock_state = LockState::unknown;
  assert(!IsUnlockedSession(state, 1));
  assert(!IsUnlockedSession(state, UINT32_MAX));
  std::cout << "Unlock state verification tests passed\n";
}
