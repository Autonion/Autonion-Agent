#include "prelogin_auth.h"
#include <cassert>
#include <iostream>

int main() {
  autonion::CompanionTrust trust;
  assert(autonion::ParseCompanionTrust("v1\nphone-a\tc2VjcmV0LWE=\nphone-b\tc2VjcmV0LWI=\n", &trust));
  assert(autonion::IsTrustedCompanion(trust, "phone-a", "c2VjcmV0LWE="));
  assert(!autonion::IsTrustedCompanion(trust, "phone-a", "c2VjcmV0LWI="));
  assert(!autonion::IsTrustedCompanion(trust, "unknown", "c2VjcmV0LWE="));
  assert(!autonion::IsTrustedCompanion(trust, "phone-a", ""));
  assert(autonion::ParseCompanionTrust("v1\nphone-b\tc2VjcmV0LWI=\n", &trust));
  assert(!autonion::IsTrustedCompanion(trust, "phone-a", "c2VjcmV0LWE="));
  assert(autonion::IsTrustedCompanion(trust, "phone-b", "c2VjcmV0LWI="));
  assert(!autonion::ParseCompanionTrust("v1\nphone-a\tYWJj\nphone-a\tZGVm\n", &trust));
  assert(!autonion::ParseCompanionTrust("v2\n", &trust));
  assert(!autonion::ParseCompanionTrust("v1\nphone-a\t\n", &trust));
  assert(autonion::ParseCompanionTrust("v1\n", &trust));
  assert(trust.empty());
  std::cout << "Pre-login trust tests passed\n";
}
