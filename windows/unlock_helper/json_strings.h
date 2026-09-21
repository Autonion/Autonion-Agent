#pragma once
#include <cstdint>
#include <string>

namespace autonion {
namespace json_detail {
inline bool ReadHexQuad(const std::string& json, size_t& position, uint32_t& value) {
  if (json.size() - position < 4) return false;
  value = 0;
  for (int digit = 0; digit < 4; ++digit) {
    const char ch = json[position++];
    const int hex = ch >= '0' && ch <= '9' ? ch - '0' :
        ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 :
        ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : -1;
    if (hex < 0) return false;
    value = (value << 4) | static_cast<uint32_t>(hex);
  }
  return true;
}

inline void AppendUtf8(std::string& result, uint32_t codepoint) {
  if (codepoint <= 0x7f) result.push_back(static_cast<char>(codepoint));
  else if (codepoint <= 0x7ff) {
    result.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
    result.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else if (codepoint <= 0xffff) {
    result.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
    result.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    result.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else {
    result.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
    result.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
    result.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    result.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  }
}

inline bool ReadString(const std::string& json, size_t& position, std::string& result) {
  if (position >= json.size() || json[position++] != '"') return false;
  result.clear();
  while (position < json.size()) {
    const unsigned char ch = static_cast<unsigned char>(json[position++]);
    if (ch == '"') return true;
    if (ch < 0x20) return false;
    if (ch != '\\') { result.push_back(static_cast<char>(ch)); continue; }
    if (position == json.size()) return false;
    switch (json[position++]) {
      case '"': result.push_back('"'); break;
      case '\\': result.push_back('\\'); break;
      case '/': result.push_back('/'); break;
      case 'b': result.push_back('\b'); break;
      case 'f': result.push_back('\f'); break;
      case 'n': result.push_back('\n'); break;
      case 'r': result.push_back('\r'); break;
      case 't': result.push_back('\t'); break;
      case 'u': {
        uint32_t codepoint = 0;
        if (!ReadHexQuad(json, position, codepoint)) return false;
        if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
          if (json.size() - position < 6 || json[position] != '\\' || json[position + 1] != 'u') return false;
          position += 2;
          uint32_t low = 0;
          if (!ReadHexQuad(json, position, low) || low < 0xdc00 || low > 0xdfff) return false;
          codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + low - 0xdc00;
        } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) return false;
        AppendUtf8(result, codepoint);
        break;
      }
      default: return false;
    }
  }
  return false;
}

inline void SkipWhitespace(const std::string& json, size_t& position) {
  while (position < json.size() && (json[position] == ' ' || json[position] == '\t' ||
      json[position] == '\n' || json[position] == '\r')) ++position;
}
}  // namespace json_detail

// Decode string properties, including Gson's HTML-safe Unicode escapes.
// Walk whole string tokens so a key-like value cannot consume the next property.
inline std::string ExtractJsonString(const std::string& json, const std::string& key) {
  size_t position = 0;
  while (position < json.size()) {
    if (json[position] != '"') { ++position; continue; }
    std::string token;
    if (!json_detail::ReadString(json, position, token)) return "";
    json_detail::SkipWhitespace(json, position);
    if (token != key || position == json.size() || json[position] != ':') continue;
    ++position;
    json_detail::SkipWhitespace(json, position);
    std::string value;
    return json_detail::ReadString(json, position, value) ? value : "";
  }
  return "";
}
}  // namespace autonion
