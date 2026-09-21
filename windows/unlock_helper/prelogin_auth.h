#pragma once
#include <map>
#include <sstream>
#include <string>

namespace autonion {
using CompanionTrust = std::map<std::string, std::string>;

// Versioned, complete snapshots. Secrets in this envelope are base64 encoded;
// the service encrypts the whole envelope with DPAPI before persisting it.
inline bool ParseCompanionTrust(const std::string& text, CompanionTrust* result) {
  if (!result || text.size() > 48 * 1024) return false;
  CompanionTrust parsed;
  std::istringstream input(text);
  std::string line;
  if (!std::getline(input, line) || line != "v1") return false;
  while (std::getline(input, line)) {
    const auto separator = line.find('\t');
    if (separator == std::string::npos || separator == 0 || separator > 128) return false;
    const auto id = line.substr(0, separator);
    const auto secret = line.substr(separator + 1);
    if (secret.empty() || secret.size() > 2048 || id.find_first_of("\r\n\t") != std::string::npos ||
        secret.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=") != std::string::npos ||
        !parsed.emplace(id, secret).second) return false;
  }
  *result = std::move(parsed);
  return true;
}

inline bool IsTrustedCompanion(const CompanionTrust& trust, const std::string& id, const std::string& secret) {
  const auto found = trust.find(id);
  if (found == trust.end() || secret.empty() || secret.size() != found->second.size()) return false;
  unsigned int difference = 0;
  for (size_t i = 0; i < secret.size(); ++i) {
    difference |= static_cast<unsigned char>(secret[i]) ^ static_cast<unsigned char>(found->second[i]);
  }
  return difference == 0;
}
}  // namespace autonion
