#include <winsock2.h>
#include <windows.h>
#include <sddl.h>
#include <tlhelp32.h>
#include <wincrypt.h>
#include <ws2tcpip.h>
#include <wtsapi32.h>

#include <algorithm>
#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

const DWORD kWaitTimeoutMs = 15000;
const DWORD kPipeBufferSize = 65536;
const DWORD kPreloginWebSocketPort = 4545;
const DWORD kMdnsPort = 5353;
const char* kMdnsServiceTypeName = "_myautomation._tcp.local";
const ACCESS_MASK kDesktopAllAccess = 0x01FF;
const wchar_t* kServiceName = L"AutonionUnlockHelper";
const wchar_t* kServiceDisplayName = L"Autonion Unlock Helper";
const wchar_t* kPipeName = L"\\\\.\\pipe\\AutonionUnlockHelper";
const wchar_t* kDefaultRequestPath = L"C:\\ProgramData\\Autonion Agent\\Unlock\\request.json";
const wchar_t* kDefaultStatusPath = L"C:\\ProgramData\\Autonion Agent\\Unlock\\status.json";
const wchar_t* kCredentialDirectoryName = L"Service";
const wchar_t* kCredentialFlowsDirectoryName = L"Flows";

SERVICE_STATUS_HANDLE g_service_status_handle = nullptr;
SERVICE_STATUS g_service_status{};
HANDLE g_service_stop_event = nullptr;
HANDLE g_prelogin_stop_event = nullptr;
HANDLE g_prelogin_listener_thread = nullptr;
HANDLE g_prelogin_mdns_thread = nullptr;
SOCKET g_prelogin_listen_socket = INVALID_SOCKET;
SOCKET g_prelogin_mdns_socket = INVALID_SOCKET;
std::vector<HANDLE> g_prelogin_client_threads;
std::vector<SOCKET> g_prelogin_client_sockets;
SRWLOCK g_prelogin_lock = SRWLOCK_INIT;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return L"";
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                  static_cast<int>(value.size()), nullptr, 0);
  if (count <= 0) return L"";
  std::wstring out(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), out.data(), count);
  return out;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return "";
  int count = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                  static_cast<int>(value.size()), nullptr, 0,
                                  nullptr, nullptr);
  if (count <= 0) return "";
  std::string out(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      out.data(), count, nullptr, nullptr);
  return out;
}

std::wstring QuoteArg(const std::wstring& value) {
  std::wstring out = L"\"";
  size_t slash_count = 0;
  for (wchar_t ch : value) {
    if (ch == L'\\') {
      slash_count++;
      out.push_back(ch);
    } else if (ch == L'\"') {
      out.append(slash_count + 1, L'\\');
      out.push_back(ch);
      slash_count = 0;
    } else {
      slash_count = 0;
      out.push_back(ch);
    }
  }
  out.append(slash_count, L'\\');
  out.push_back(L'\"');
  return out;
}

std::string JsonEscape(const std::string& value) {
  std::ostringstream out;
  for (unsigned char ch : value) {
    switch (ch) {
      case '"': out << "\\\""; break;
      case '\\': out << "\\\\"; break;
      case '\b': out << "\\b"; break;
      case '\f': out << "\\f"; break;
      case '\n': out << "\\n"; break;
      case '\r': out << "\\r"; break;
      case '\t': out << "\\t"; break;
      default:
        if (ch < 0x20) {
          const char* hex = "0123456789abcdef";
          out << "\\u00" << hex[(ch >> 4) & 0x0f] << hex[ch & 0x0f];
        } else {
          out << ch;
        }
    }
  }
  return out.str();
}

bool WriteTextFile(const fs::path& path, const std::string& text) {
  std::error_code ec;
  fs::create_directories(path.parent_path(), ec);
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  if (!file) return false;
  file.write(text.data(), static_cast<std::streamsize>(text.size()));
  return file.good();
}

std::string ReadTextFile(const fs::path& path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) return "";
  std::ostringstream buffer;
  buffer << file.rdbuf();
  return buffer.str();
}

void WriteStatus(const fs::path& path, bool success, const std::string& message,
                 const std::string& request_id, const std::string& log) {
  std::ostringstream json;
  json << "{\n"
       << "  \"success\": " << (success ? "true" : "false") << ",\n"
       << "  \"requestId\": \"" << JsonEscape(request_id) << "\",\n"
       << "  \"message\": \"" << JsonEscape(message) << "\",\n"
       << "  \"log\": \"" << JsonEscape(log) << "\"\n"
       << "}\n";
  WriteTextFile(path, json.str());
}

std::string ExtractJsonString(const std::string& json, const std::string& key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return "";
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos) return "";
  pos = json.find('"', pos + 1);
  if (pos == std::string::npos) return "";
  ++pos;

  std::string out;
  while (pos < json.size()) {
    char ch = json[pos++];
    if (ch == '"') break;
    if (ch != '\\') {
      out.push_back(ch);
      continue;
    }
    if (pos >= json.size()) break;
    char esc = json[pos++];
    switch (esc) {
      case '"': out.push_back('"'); break;
      case '\\': out.push_back('\\'); break;
      case '/': out.push_back('/'); break;
      case 'b': out.push_back('\b'); break;
      case 'f': out.push_back('\f'); break;
      case 'n': out.push_back('\n'); break;
      case 'r': out.push_back('\r'); break;
      case 't': out.push_back('\t'); break;
      default: out.push_back(esc); break;
    }
  }
  return out;
}

bool ExtractJsonBool(const std::string& json, const std::string& key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return false;
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos) return false;
  ++pos;
  while (pos < json.size()) {
    char ch = json[pos];
    if (ch != ' ' && ch != '\t' && ch != '\r' && ch != '\n') break;
    ++pos;
  }
  return json.compare(pos, 4, "true") == 0;
}

std::string Base64Decode(const std::string& input) {
  static const int kInvalid = -1;
  int table[256];
  for (int& value : table) value = kInvalid;
  const char* alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  for (int i = 0; alphabet[i]; ++i) table[static_cast<unsigned char>(alphabet[i])] = i;

  std::string out;
  int value = 0;
  int bits = -8;
  for (unsigned char ch : input) {
    if (ch == '=') break;
    if (table[ch] == kInvalid) continue;
    value = (value << 6) + table[ch];
    bits += 6;
    if (bits >= 0) {
      out.push_back(static_cast<char>((value >> bits) & 0xff));
      bits -= 8;
    }
  }
  return out;
}

std::string Base64Encode(const std::vector<uint8_t>& input) {
  static const char* alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((input.size() + 2) / 3) * 4);
  for (size_t i = 0; i < input.size(); i += 3) {
    uint32_t b0 = input[i];
    uint32_t b1 = (i + 1 < input.size()) ? input[i + 1] : 0;
    uint32_t b2 = (i + 2 < input.size()) ? input[i + 2] : 0;
    uint32_t triple = (b0 << 16) | (b1 << 8) | b2;
    out.push_back(alphabet[(triple >> 18) & 0x3f]);
    out.push_back(alphabet[(triple >> 12) & 0x3f]);
    out.push_back(i + 1 < input.size() ? alphabet[(triple >> 6) & 0x3f] : '=');
    out.push_back(i + 2 < input.size() ? alphabet[triple & 0x3f] : '=');
  }
  return out;
}

std::vector<uint8_t> BytesFromString(const std::string& value) {
  return std::vector<uint8_t>(value.begin(), value.end());
}

std::string StringFromBytes(const std::vector<uint8_t>& value) {
  return std::string(value.begin(), value.end());
}

std::wstring GetArgValue(const std::vector<std::wstring>& args, const std::wstring& name,
                         const std::wstring& fallback) {
  for (size_t i = 0; i + 1 < args.size(); ++i) {
    if (args[i] == name) return args[i + 1];
  }
  return fallback;
}

bool HasArg(const std::vector<std::wstring>& args, const std::wstring& name) {
  for (const auto& arg : args) {
    if (arg == name) return true;
  }
  return false;
}

bool EnablePrivilege(const wchar_t* name) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_PRIVILEGES tp{};
  tp.PrivilegeCount = 1;
  if (!LookupPrivilegeValueW(nullptr, name, &tp.Privileges[0].Luid)) {
    CloseHandle(token);
    return false;
  }
  tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
  AdjustTokenPrivileges(token, FALSE, &tp, sizeof(tp), nullptr, nullptr);
  DWORD error = GetLastError();
  CloseHandle(token);
  return error == ERROR_SUCCESS;
}

DWORD FindActiveWinlogonPid() {
  DWORD active_session = WTSGetActiveConsoleSessionId();
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) return 0;

  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  DWORD pid = 0;
  if (Process32FirstW(snap, &entry)) {
    do {
      if (_wcsicmp(entry.szExeFile, L"winlogon.exe") != 0) continue;
      DWORD session = 0;
      if (ProcessIdToSessionId(entry.th32ProcessID, &session) && session == active_session) {
        pid = entry.th32ProcessID;
        break;
      }
    } while (Process32NextW(snap, &entry));
  }
  CloseHandle(snap);
  return pid;
}

std::wstring GetModulePath() {
  std::wstring path(MAX_PATH, L'\0');
  DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  while (length == path.size() && GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
    path.resize(path.size() * 2, L'\0');
    length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  }
  path.resize(length);
  return path;
}

std::string LastErrorMessage(const std::string& prefix) {
  DWORD error = GetLastError();
  return prefix + " (Win32 " + std::to_string(error) + ")";
}

fs::path GetProgramDataUnlockDir() {
  wchar_t buffer[MAX_PATH]{};
  DWORD length = GetEnvironmentVariableW(L"ProgramData", buffer, MAX_PATH);
  fs::path base = (length > 0 && length < MAX_PATH)
                      ? fs::path(buffer)
                      : fs::path(L"C:\\ProgramData");
  return base / L"Autonion Agent" / L"Unlock";
}

std::string SafeFilePart(const std::string& value) {
  std::string out;
  for (char ch : value) {
    const bool ok = (ch >= 'a' && ch <= 'z') ||
                    (ch >= 'A' && ch <= 'Z') ||
                    (ch >= '0' && ch <= '9') ||
                    ch == '-' || ch == '_';
    if (ok) out.push_back(ch);
  }
  if (!out.empty()) return out;
  return "request_" + std::to_string(GetCurrentProcessId()) + "_" +
         std::to_string(GetTickCount64());
}

std::string MakePipeResponse(bool success, const std::string& request_id,
                             const std::string& message,
                             const std::string& log,
                             int helper_exit_code = 0) {
  std::ostringstream json;
  if (success) {
    json << "{\n"
         << "  \"success\": true,\n"
         << "  \"data\": {\n"
         << "    \"status\": \"unlock_input_sent\",\n"
         << "    \"via\": \"windows_service_helper\",\n"
         << "    \"requestId\": \"" << JsonEscape(request_id) << "\",\n"
         << "    \"message\": \"" << JsonEscape(message) << "\",\n"
         << "    \"helperExitCode\": " << helper_exit_code << ",\n"
         << "    \"log\": \"" << JsonEscape(log) << "\"\n"
         << "  }\n"
         << "}\n";
  } else {
    json << "{\n"
         << "  \"success\": false,\n"
         << "  \"error\": \"" << JsonEscape(message) << "\",\n"
         << "  \"data\": {\n"
         << "    \"via\": \"windows_service_helper\",\n"
         << "    \"requestId\": \"" << JsonEscape(request_id) << "\",\n"
         << "    \"log\": \"" << JsonEscape(log) << "\"\n"
         << "  }\n"
         << "}\n";
  }
  return json.str();
}

fs::path GetCredentialRootDir() {
  return GetProgramDataUnlockDir() / kCredentialDirectoryName;
}

fs::path GetCredentialFlowsDir() {
  return GetCredentialRootDir() / kCredentialFlowsDirectoryName;
}

bool ApplySystemAdminOnlyDacl(const fs::path& path) {
  PSECURITY_DESCRIPTOR security_descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;GA;;;SY)(A;;GA;;;BA)", SDDL_REVISION_1,
          &security_descriptor, nullptr)) {
    return false;
  }
  BOOL ok = SetFileSecurityW(path.c_str(), DACL_SECURITY_INFORMATION,
                             security_descriptor);
  LocalFree(security_descriptor);
  return ok == TRUE;
}

bool EnsureSecureCredentialDirectory() {
  std::error_code ec;
  fs::path root = GetCredentialRootDir();
  fs::path flows = GetCredentialFlowsDir();
  fs::create_directories(flows, ec);
  if (ec) return false;
  return ApplySystemAdminOnlyDacl(root) && ApplySystemAdminOnlyDacl(flows);
}

bool ProtectSecret(const std::string& secret, std::string* encrypted_b64) {
  if (!encrypted_b64) return false;
  std::vector<uint8_t> bytes = BytesFromString(secret);
  DATA_BLOB input{};
  input.pbData = bytes.data();
  input.cbData = static_cast<DWORD>(bytes.size());
  DATA_BLOB output{};
  if (!CryptProtectData(&input, L"Autonion pre-login unlock credential",
                        nullptr, nullptr, nullptr, CRYPTPROTECT_LOCAL_MACHINE,
                        &output)) {
    return false;
  }
  std::vector<uint8_t> encrypted(output.pbData, output.pbData + output.cbData);
  LocalFree(output.pbData);
  *encrypted_b64 = Base64Encode(encrypted);
  return true;
}

bool UnprotectSecret(const std::string& encrypted_b64, std::string* secret) {
  if (!secret) return false;
  std::string encrypted_raw = Base64Decode(encrypted_b64);
  if (encrypted_raw.empty()) return false;
  DATA_BLOB input{};
  input.pbData = reinterpret_cast<BYTE*>(encrypted_raw.data());
  input.cbData = static_cast<DWORD>(encrypted_raw.size());
  DATA_BLOB output{};
  if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, 0, &output)) {
    return false;
  }
  *secret = std::string(reinterpret_cast<char*>(output.pbData),
                        reinterpret_cast<char*>(output.pbData) + output.cbData);
  LocalFree(output.pbData);
  return true;
}

fs::path CredentialPathForFlow(const std::string& flow_id) {
  return GetCredentialFlowsDir() / fs::path(Utf8ToWide(SafeFilePart(flow_id) + ".json"));
}

fs::path CredentialIdentityPath() {
  return GetCredentialRootDir() / L"identity.json";
}

std::string StorePreloginIdentity(const std::string& request) {
  const std::string request_id = ExtractJsonString(request, "requestId");
  const std::string device_id = ExtractJsonString(request, "deviceId");
  const std::string device_name = ExtractJsonString(request, "deviceName");
  if (device_id.empty() || device_name.empty()) {
    return MakePipeResponse(false, request_id,
                            "Pre-login identity provisioning requires deviceId and deviceName", "");
  }
  if (!EnsureSecureCredentialDirectory()) {
    return MakePipeResponse(false, request_id,
                            "Could not prepare secure pre-login identity directory", "");
  }

  std::ostringstream json;
  json << "{\n"
       << "  \"version\": 1,\n"
       << "  \"deviceId\": \"" << JsonEscape(device_id) << "\",\n"
       << "  \"deviceName\": \"" << JsonEscape(device_name) << "\"\n"
       << "}\n";

  fs::path identity_path = CredentialIdentityPath();
  if (!WriteTextFile(identity_path, json.str()) ||
      !ApplySystemAdminOnlyDacl(identity_path)) {
    return MakePipeResponse(false, request_id,
                            "Could not write pre-login identity", "");
  }

  return MakePipeResponse(true, request_id, "prelogin_identity_saved", "");
}

bool LoadPreloginIdentity(std::string* device_id, std::string* device_name) {
  const std::string json = ReadTextFile(CredentialIdentityPath());
  if (json.empty()) return false;
  std::string loaded_id = ExtractJsonString(json, "deviceId");
  std::string loaded_name = ExtractJsonString(json, "deviceName");
  if (loaded_id.empty() || loaded_name.empty()) return false;
  if (device_id) *device_id = loaded_id;
  if (device_name) *device_name = loaded_name;
  return true;
}

std::string StorePreloginCredential(const std::string& request) {
  const std::string request_id = ExtractJsonString(request, "requestId");
  const std::string flow_id = ExtractJsonString(request, "flowId");
  const std::string node_id = ExtractJsonString(request, "nodeId");
  const std::string flow_name = ExtractJsonString(request, "flowName");
  const std::string password_b64 = ExtractJsonString(request, "passwordB64");
  if (flow_id.empty() || node_id.empty() || password_b64.empty()) {
    return MakePipeResponse(false, request_id,
                            "Pre-login unlock provisioning requires flowId, nodeId, and password", "");
  }
  if (!EnsureSecureCredentialDirectory()) {
    return MakePipeResponse(false, request_id,
                            "Could not prepare secure pre-login credential directory", "");
  }

  const std::string password = Base64Decode(password_b64);
  std::string encrypted_password;
  if (password.empty() || !ProtectSecret(password, &encrypted_password)) {
    return MakePipeResponse(false, request_id,
                            "Could not encrypt pre-login unlock credential", "");
  }

  std::ostringstream json;
  json << "{\n"
       << "  \"version\": 1,\n"
       << "  \"flowId\": \"" << JsonEscape(flow_id) << "\",\n"
       << "  \"nodeId\": \"" << JsonEscape(node_id) << "\",\n"
       << "  \"flowName\": \"" << JsonEscape(flow_name) << "\",\n"
       << "  \"passwordDpapiB64\": \"" << JsonEscape(encrypted_password) << "\"\n"
       << "}\n";

  fs::path credential_path = CredentialPathForFlow(flow_id);
  if (!WriteTextFile(credential_path, json.str()) ||
      !ApplySystemAdminOnlyDacl(credential_path)) {
    return MakePipeResponse(false, request_id,
                            "Could not write pre-login unlock credential", "");
  }

  return MakePipeResponse(true, request_id, "prelogin_unlock_credential_saved", "");
}

std::string DeletePreloginCredential(const std::string& request) {
  const std::string request_id = ExtractJsonString(request, "requestId");
  const std::string flow_id = ExtractJsonString(request, "flowId");
  if (flow_id.empty()) {
    return MakePipeResponse(false, request_id,
                            "Pre-login unlock delete requires flowId", "");
  }
  std::error_code ec;
  fs::remove(CredentialPathForFlow(flow_id), ec);
  return MakePipeResponse(true, request_id, "prelogin_unlock_credential_deleted", "");
}

bool LoadPreloginCredential(const std::string& flow_id, std::string* password,
                            std::string* flow_name, std::string* node_id) {
  const std::string json = ReadTextFile(CredentialPathForFlow(flow_id));
  if (json.empty()) return false;
  if (flow_name) *flow_name = ExtractJsonString(json, "flowName");
  if (node_id) *node_id = ExtractJsonString(json, "nodeId");
  const std::string encrypted = ExtractJsonString(json, "passwordDpapiB64");
  return UnprotectSecret(encrypted, password);
}

std::vector<std::string> ListProvisionedFlowCredentials() {
  std::vector<std::string> entries;
  std::error_code ec;
  fs::path dir = GetCredentialFlowsDir();
  if (!fs::exists(dir, ec)) return entries;
  for (const auto& entry : fs::directory_iterator(dir, ec)) {
    if (ec) break;
    if (!entry.is_regular_file(ec)) continue;
    std::string json = ReadTextFile(entry.path());
    if (!json.empty()) entries.push_back(json);
  }
  return entries;
}

void AppendLog(std::ostringstream& log, const std::string& line) {
  log << line << '\n';
}

UINT SendVk(WORD vk, std::ostringstream& log) {
  INPUT input[2]{};
  input[0].type = INPUT_KEYBOARD;
  input[0].ki.wVk = vk;
  input[1].type = INPUT_KEYBOARD;
  input[1].ki.wVk = vk;
  input[1].ki.dwFlags = KEYEVENTF_KEYUP;
  UINT sent = SendInput(2, input, sizeof(INPUT));
  std::ostringstream line;
  line << "send_vk(0x" << std::hex << static_cast<int>(vk) << ") -> " << std::dec << sent;
  AppendLog(log, line.str());
  return sent;
}

UINT SendChar(wchar_t ch) {
  INPUT input[2]{};
  input[0].type = INPUT_KEYBOARD;
  input[0].ki.wScan = ch;
  input[0].ki.dwFlags = KEYEVENTF_UNICODE;
  input[1].type = INPUT_KEYBOARD;
  input[1].ki.wScan = ch;
  input[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
  return SendInput(2, input, sizeof(INPUT));
}

bool SwitchToInputDesktop(std::ostringstream& log, const char* label) {
  HDESK desktop = OpenInputDesktop(0, TRUE, kDesktopAllAccess);
  if (!desktop) {
    std::ostringstream line;
    line << "WARN: OpenInputDesktop(" << label << ") failed: " << GetLastError();
    AppendLog(log, line.str());
    desktop = OpenDesktopW(L"Winlogon", 0, TRUE, kDesktopAllAccess);
  }
  if (!desktop) {
    AppendLog(log, "ERROR: could not open input or Winlogon desktop");
    return false;
  }
  if (!SetThreadDesktop(desktop)) {
    std::ostringstream line;
    line << "ERROR: SetThreadDesktop(" << label << ") failed: " << GetLastError();
    AppendLog(log, line.str());
    CloseDesktop(desktop);
    return false;
  }
  AppendLog(log, std::string("OK: switched desktop ") + label);
  // Do not close the desktop handle after SetThreadDesktop; the thread is using it.
  return true;
}

int RunChild(const fs::path& request_path, const fs::path& status_path) {
  std::ostringstream log;
  const std::string request = ReadTextFile(request_path);
  if (request.empty()) {
    WriteStatus(status_path, false, "Unlock request file is missing or empty", "", log.str());
    return 2;
  }

  const std::string request_id = ExtractJsonString(request, "requestId");
  const std::string password_b64 = ExtractJsonString(request, "passwordB64");
  const std::wstring password = Utf8ToWide(Base64Decode(password_b64));

  std::error_code ec;
  fs::remove(request_path, ec);

  if (password.empty()) {
    WriteStatus(status_path, false, "Unlock password is empty", request_id, log.str());
    return 3;
  }

  AppendLog(log, "OK: helper child started");
  if (!SwitchToInputDesktop(log, "initial")) {
    WriteStatus(status_path, false, "Could not switch to lock-screen input desktop", request_id, log.str());
    return 4;
  }

  AppendLog(log, "Step 1: dismissing lock overlay");
  SendVk(VK_ESCAPE, log);
  Sleep(2000);

  if (!SwitchToInputDesktop(log, "after_escape")) {
    WriteStatus(status_path, false, "Could not re-acquire lock-screen input desktop", request_id, log.str());
    return 5;
  }

  AppendLog(log, "Step 2: typing password");
  size_t typed = 0;
  for (size_t i = 0; i < password.size(); ++i) {
    UINT sent = SendChar(password[i]);
    if (sent == 2) {
      ++typed;
    } else {
      std::ostringstream line;
      line << "ERROR: char " << (i + 1) << " SendInput returned " << sent;
      AppendLog(log, line.str());
    }
    Sleep(50);
  }
  {
    std::ostringstream line;
    line << "chars sent: " << typed << "/" << password.size();
    AppendLog(log, line.str());
  }
  if (typed != password.size()) {
    WriteStatus(status_path, false, "Unlock helper did not send all password characters", request_id, log.str());
    return 6;
  }

  Sleep(300);
  AppendLog(log, "Step 3: pressing Enter");
  UINT enter_sent = SendVk(VK_RETURN, log);
  if (enter_sent != 2) {
    std::ostringstream line;
    line << "WARN: Enter key returned " << enter_sent << "; continuing because password characters were sent";
    AppendLog(log, line.str());
  }
  Sleep(3000);

  AppendLog(log, "OK: unlock finished");
  WriteStatus(status_path, true, "unlock_input_sent", request_id, log.str());
  return 0;
}

int RunParent(const fs::path& request_path, const fs::path& status_path) {
  const std::string request = ReadTextFile(request_path);
  const std::string request_id = ExtractJsonString(request, "requestId");

  EnablePrivilege(SE_DEBUG_NAME);
  EnablePrivilege(SE_IMPERSONATE_NAME);
  EnablePrivilege(SE_TCB_NAME);
  EnablePrivilege(SE_ASSIGNPRIMARYTOKEN_NAME);

  DWORD winlogon_pid = FindActiveWinlogonPid();
  if (!winlogon_pid) {
    WriteStatus(status_path, false, "Could not find winlogon.exe in the active console session", request_id, "");
    return 10;
  }

  HANDLE winlogon = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, winlogon_pid);
  if (!winlogon) {
    winlogon = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, winlogon_pid);
  }
  if (!winlogon) {
    WriteStatus(status_path, false, LastErrorMessage("OpenProcess(winlogon) failed"), request_id, "");
    return 11;
  }

  HANDLE token = nullptr;
  if (!OpenProcessToken(winlogon, TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY | TOKEN_QUERY, &token)) {
    CloseHandle(winlogon);
    WriteStatus(status_path, false, LastErrorMessage("OpenProcessToken(winlogon) failed"), request_id, "");
    return 12;
  }

  HANDLE primary = nullptr;
  if (!DuplicateTokenEx(token, TOKEN_ALL_ACCESS, nullptr, SecurityImpersonation,
                        TokenPrimary, &primary)) {
    CloseHandle(token);
    CloseHandle(winlogon);
    WriteStatus(status_path, false, LastErrorMessage("DuplicateTokenEx failed"), request_id, "");
    return 13;
  }
  CloseHandle(token);
  CloseHandle(winlogon);

  // Set the token's session to the active console session so the child
  // process runs in the user's interactive session, not Session 0
  // (where this scheduled-task parent runs).
  DWORD active_session = WTSGetActiveConsoleSessionId();
  if (!SetTokenInformation(primary, TokenSessionId,
                           &active_session, sizeof(active_session))) {
    DWORD err = GetLastError();
    WriteStatus(status_path, false,
                "SetTokenInformation(TokenSessionId) failed (Win32 " +
                std::to_string(err) + ")",
                request_id, "");
    CloseHandle(primary);
    return 13;
  }

  std::wstring exe = GetModulePath();
  std::wstring cmd = QuoteArg(exe) + L" --child --request " +
                     QuoteArg(request_path.wstring()) + L" --status " +
                     QuoteArg(status_path.wstring());
  std::vector<wchar_t> cmd_buffer(cmd.begin(), cmd.end());
  cmd_buffer.push_back(L'\0');

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.lpDesktop = const_cast<LPWSTR>(L"winsta0\\Winlogon");
  PROCESS_INFORMATION pi{};

  // Use CreateProcessAsUserW: since we run as SYSTEM we have
  // SeAssignPrimaryTokenPrivilege + SeTcbPrivilege, and this API
  // respects the token's session ID (set above), placing the child
  // in the user's interactive session where the lock screen lives.
  BOOL ok = CreateProcessAsUserW(primary, exe.c_str(), cmd_buffer.data(),
                                  nullptr, nullptr, FALSE,
                                  CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                                  nullptr, nullptr, &si, &pi);
  DWORD create_error = GetLastError();
  CloseHandle(primary);
  if (!ok) {
    WriteStatus(status_path, false,
                "CreateProcessAsUserW failed (Win32 " + std::to_string(create_error) + ")",
                request_id, "");
    return 14;
  }

  DWORD wait = WaitForSingleObject(pi.hProcess, kWaitTimeoutMs);
  if (wait == WAIT_TIMEOUT) {
    TerminateProcess(pi.hProcess, 1);
    WaitForSingleObject(pi.hProcess, 2000);
    WriteStatus(status_path, false, "Unlock helper child timed out", request_id, "");
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 15;
  }

  DWORD exit_code = 0;
  GetExitCodeProcess(pi.hProcess, &exit_code);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  return static_cast<int>(exit_code);
}

bool IsPipeClientAllowed(HANDLE pipe, std::string* reason) {
  if (!ImpersonateNamedPipeClient(pipe)) {
    if (reason) {
      *reason = "ImpersonateNamedPipeClient failed (Win32 " +
                std::to_string(GetLastError()) + ")";
    }
    return false;
  }

  bool allowed = false;
  HANDLE token = nullptr;
  if (OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &token)) {
    DWORD token_session = 0;
    DWORD needed = 0;
    if (GetTokenInformation(token, TokenSessionId, &token_session,
                            sizeof(token_session), &needed)) {
      DWORD active_session = WTSGetActiveConsoleSessionId();
      allowed = active_session != 0xFFFFFFFF && token_session == active_session;
      if (!allowed && reason) {
        *reason = "client session " + std::to_string(token_session) +
                  " is not active console session " +
                  std::to_string(active_session);
      }
    } else if (reason) {
      *reason = "GetTokenInformation(TokenSessionId) failed (Win32 " +
                std::to_string(GetLastError()) + ")";
    }
    CloseHandle(token);
  } else if (reason) {
    *reason = "OpenThreadToken failed (Win32 " +
              std::to_string(GetLastError()) + ")";
  }

  RevertToSelf();
  return allowed;
}

std::string ReadPipeMessage(HANDLE pipe) {
  std::vector<char> buffer(kPipeBufferSize);
  DWORD bytes_read = 0;
  if (!ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()),
                &bytes_read, nullptr) || bytes_read == 0) {
    return "";
  }
  return std::string(buffer.data(), buffer.data() + bytes_read);
}

bool WritePipeText(HANDLE pipe, const std::string& text) {
  size_t offset = 0;
  while (offset < text.size()) {
    size_t remaining = text.size() - offset;
    DWORD chunk = remaining > 32768 ? 32768 : static_cast<DWORD>(remaining);
    DWORD bytes_written = 0;
    if (!WriteFile(pipe, text.data() + offset, chunk, &bytes_written, nullptr) ||
        bytes_written == 0) {
      return false;
    }
    offset += bytes_written;
  }
  return true;
}

std::string HandleServiceUnlockRequest(const std::string& request) {
  const std::string action = ExtractJsonString(request, "action");
  if (action == "storePreloginIdentity") {
    return StorePreloginIdentity(request);
  }
  if (action == "storePreloginCredential") {
    return StorePreloginCredential(request);
  }
  if (action == "deletePreloginCredential") {
    return DeletePreloginCredential(request);
  }

  const std::string request_id = ExtractJsonString(request, "requestId");
  const std::string password_b64 = ExtractJsonString(request, "passwordB64");
  if (request_id.empty()) {
    return MakePipeResponse(false, "", "Unlock request is missing requestId", "");
  }
  if (password_b64.empty()) {
    return MakePipeResponse(false, request_id, "Unlock request is missing password", "");
  }

  std::error_code ec;
  fs::path request_dir = GetProgramDataUnlockDir() / L"Requests";
  fs::create_directories(request_dir, ec);
  if (ec) {
    return MakePipeResponse(false, request_id,
                            "Could not create unlock request directory: " + ec.message(), "");
  }

  const std::string file_part = SafeFilePart(request_id);
  fs::path request_path = request_dir / fs::path(Utf8ToWide(file_part + ".request.json"));
  fs::path status_path = request_dir / fs::path(Utf8ToWide(file_part + ".status.json"));
  fs::remove(status_path, ec);

  if (!WriteTextFile(request_path, request)) {
    return MakePipeResponse(false, request_id, "Could not write unlock request file", "");
  }

  int exit_code = RunParent(request_path, status_path);
  fs::remove(request_path, ec);

  const std::string status = ReadTextFile(status_path);
  fs::remove(status_path, ec);
  if (status.empty()) {
    return MakePipeResponse(false, request_id,
                            "Unlock service produced no status (helper exit code " +
                                std::to_string(exit_code) + ")",
                            "", exit_code);
  }

  const std::string status_request_id = ExtractJsonString(status, "requestId");
  const std::string message = ExtractJsonString(status, "message");
  const std::string log = ExtractJsonString(status, "log");
  if (!status_request_id.empty() && status_request_id != request_id) {
    return MakePipeResponse(false, request_id,
                            "Unlock service received mismatched helper status", log,
                            exit_code);
  }

  if (ExtractJsonBool(status, "success")) {
    return MakePipeResponse(true, request_id,
                            message.empty() ? "unlock_input_sent" : message,
                            log, exit_code);
  }

  return MakePipeResponse(false, request_id,
                          message.empty() ? "Unlock helper failed" : message,
                          log, exit_code);
}


std::string TrimAscii(const std::string& value) {
  size_t start = 0;
  while (start < value.size() &&
         (value[start] == ' ' || value[start] == '\t' ||
          value[start] == '\r' || value[start] == '\n')) {
    ++start;
  }
  size_t end = value.size();
  while (end > start &&
         (value[end - 1] == ' ' || value[end - 1] == '\t' ||
          value[end - 1] == '\r' || value[end - 1] == '\n')) {
    --end;
  }
  return value.substr(start, end - start);
}

bool HeaderNameEquals(const std::string& line, const std::string& name) {
  if (line.size() < name.size() + 1 || line[name.size()] != ':') return false;
  for (size_t i = 0; i < name.size(); ++i) {
    char a = line[i];
    char b = name[i];
    if (a >= 'A' && a <= 'Z') a = static_cast<char>(a - 'A' + 'a');
    if (b >= 'A' && b <= 'Z') b = static_cast<char>(b - 'A' + 'a');
    if (a != b) return false;
  }
  return true;
}

std::string ExtractHttpHeader(const std::string& request, const std::string& name) {
  size_t start = 0;
  while (start < request.size()) {
    size_t end = request.find("\r\n", start);
    if (end == std::string::npos) end = request.size();
    std::string line = request.substr(start, end - start);
    if (HeaderNameEquals(line, name)) {
      return TrimAscii(line.substr(name.size() + 1));
    }
    if (end == request.size()) break;
    start = end + 2;
  }
  return "";
}

std::string UtcTimestamp() {
  SYSTEMTIME st{};
  GetSystemTime(&st);
  char buffer[40]{};
  std::snprintf(buffer, sizeof(buffer), "%04u-%02u-%02uT%02u:%02u:%02uZ",
                st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
  return buffer;
}

bool SocketSendAll(SOCKET client, const void* data, size_t length) {
  const char* cursor = static_cast<const char*>(data);
  while (length > 0) {
    int chunk = static_cast<int>(std::min<size_t>(length, 32768));
    int sent = send(client, cursor, chunk, 0);
    if (sent <= 0) return false;
    cursor += sent;
    length -= static_cast<size_t>(sent);
  }
  return true;
}

bool SocketSendText(SOCKET client, const std::string& text) {
  return SocketSendAll(client, text.data(), text.size());
}

bool RecvExact(SOCKET client, uint8_t* data, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    int received = recv(client, reinterpret_cast<char*>(data + offset),
                        static_cast<int>(length - offset), 0);
    if (received <= 0) return false;
    offset += static_cast<size_t>(received);
  }
  return true;
}

bool Sha1Digest(const std::string& input, std::vector<uint8_t>* digest) {
  if (!digest) return false;
  HCRYPTPROV provider = 0;
  HCRYPTHASH hash = 0;
  if (!CryptAcquireContextW(&provider, nullptr, nullptr, PROV_RSA_FULL,
                            CRYPT_VERIFYCONTEXT)) {
    return false;
  }
  if (!CryptCreateHash(provider, CALG_SHA1, 0, 0, &hash)) {
    CryptReleaseContext(provider, 0);
    return false;
  }
  BOOL ok = CryptHashData(hash,
                          reinterpret_cast<const BYTE*>(input.data()),
                          static_cast<DWORD>(input.size()), 0);
  if (ok) {
    DWORD length = 20;
    digest->assign(length, 0);
    ok = CryptGetHashParam(hash, HP_HASHVAL, digest->data(), &length, 0);
    digest->resize(length);
  }
  CryptDestroyHash(hash);
  CryptReleaseContext(provider, 0);
  return ok == TRUE;
}

std::string WebSocketAcceptKey(const std::string& client_key) {
  std::vector<uint8_t> digest;
  if (!Sha1Digest(client_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", &digest)) {
    return "";
  }
  return Base64Encode(digest);
}

bool ReadHttpUpgradeRequest(SOCKET client, std::string* request) {
  if (!request) return false;
  request->clear();
  char buffer[1024];
  while (request->size() < 16384) {
    int received = recv(client, buffer, sizeof(buffer), 0);
    if (received <= 0) return false;
    request->append(buffer, buffer + received);
    if (request->find("\r\n\r\n") != std::string::npos) return true;
  }
  return false;
}

bool SendWebSocketFrame(SOCKET client, uint8_t opcode, const std::string& payload) {
  std::vector<uint8_t> frame;
  frame.reserve(payload.size() + 14);
  frame.push_back(static_cast<uint8_t>(0x80 | (opcode & 0x0f)));
  if (payload.size() <= 125) {
    frame.push_back(static_cast<uint8_t>(payload.size()));
  } else if (payload.size() <= 0xffff) {
    frame.push_back(126);
    frame.push_back(static_cast<uint8_t>((payload.size() >> 8) & 0xff));
    frame.push_back(static_cast<uint8_t>(payload.size() & 0xff));
  } else {
    frame.push_back(127);
    uint64_t length = static_cast<uint64_t>(payload.size());
    for (int shift = 56; shift >= 0; shift -= 8) {
      frame.push_back(static_cast<uint8_t>((length >> shift) & 0xff));
    }
  }
  frame.insert(frame.end(), payload.begin(), payload.end());
  return SocketSendAll(client, frame.data(), frame.size());
}

bool SendWebSocketText(SOCKET client, const std::string& payload) {
  return SendWebSocketFrame(client, 0x1, payload);
}

bool ReceiveWebSocketText(SOCKET client, std::string* message) {
  if (!message) return false;
  message->clear();

  while (true) {
    uint8_t header[2]{};
    if (!RecvExact(client, header, 2)) return false;
    const bool fin = (header[0] & 0x80) != 0;
    const uint8_t opcode = header[0] & 0x0f;
    const bool masked = (header[1] & 0x80) != 0;
    uint64_t length = header[1] & 0x7f;

    if (length == 126) {
      uint8_t extended[2]{};
      if (!RecvExact(client, extended, 2)) return false;
      length = (static_cast<uint64_t>(extended[0]) << 8) | extended[1];
    } else if (length == 127) {
      uint8_t extended[8]{};
      if (!RecvExact(client, extended, 8)) return false;
      length = 0;
      for (uint8_t byte : extended) length = (length << 8) | byte;
    }

    if (length > 1024 * 1024) return false;

    uint8_t mask[4]{};
    if (masked && !RecvExact(client, mask, 4)) return false;

    std::string payload(static_cast<size_t>(length), '\0');
    if (length > 0 &&
        !RecvExact(client, reinterpret_cast<uint8_t*>(payload.data()),
                   static_cast<size_t>(length))) {
      return false;
    }
    if (masked) {
      for (size_t i = 0; i < payload.size(); ++i) {
        payload[i] = static_cast<char>(payload[i] ^ mask[i % 4]);
      }
    }

    if (opcode == 0x8) return false; // Close frame
    if (opcode == 0x9) {
      // Binary ping frame from OkHttp: reply with pong (0xA) and continue loop
      SendWebSocketFrame(client, 0xA, payload);
      continue;
    }
    if (opcode == 0xA) {
      // Pong response: ignore and continue waiting for text
      continue;
    }
    if (!fin || opcode != 0x1) return false;

    *message = payload;
    return true;
  }
}

bool CompleteWebSocketHandshake(SOCKET client, const std::string& request) {
  if (request.rfind("GET /automation ", 0) != 0 &&
      request.rfind("GET /automation?", 0) != 0) {
    SocketSendText(client, "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
    return false;
  }

  const std::string key = ExtractHttpHeader(request, "Sec-WebSocket-Key");
  const std::string accept = WebSocketAcceptKey(key);
  if (key.empty() || accept.empty()) {
    SocketSendText(client, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    return false;
  }

  std::ostringstream response;
  response << "HTTP/1.1 101 Switching Protocols\r\n"
           << "Upgrade: websocket\r\n"
           << "Connection: Upgrade\r\n"
           << "Sec-WebSocket-Accept: " << accept << "\r\n\r\n";
  return SocketSendText(client, response.str());
}

std::string FlowListResponseJson(const std::string& transaction_id) {
  std::ostringstream json;
  json << "{\"type\":\"flow_list_response\","
       << "\"transactionId\":\"" << JsonEscape(transaction_id) << "\","
       << "\"flows\":[";

  bool first = true;
  for (const std::string& credential_json : ListProvisionedFlowCredentials()) {
    const std::string flow_id = ExtractJsonString(credential_json, "flowId");
    if (flow_id.empty()) continue;
    const std::string flow_name = ExtractJsonString(credential_json, "flowName");
    if (!first) json << ",";
    first = false;
    json << "{"
         << "\"id\":\"" << JsonEscape(flow_id) << "\","
         << "\"name\":\"" << JsonEscape(flow_name.empty() ? "Pre-login Unlock" : flow_name) << "\","
         << "\"description\":\"Pre-login unlock only\","
         << "\"nodeCount\":1,"
         << "\"target\":\"desktop\","
         << "\"createdAt\":\"" << UtcTimestamp() << "\","
         << "\"updatedAt\":\"" << UtcTimestamp() << "\","
         << "\"tags\":[\"prelogin\"],"
         << "\"triggerType\":\"manual\","
         << "\"version\":1"
         << "}";
  }

  json << "],\"prelogin\":true,\"timestamp\":\"" << UtcTimestamp() << "\"}";
  return json.str();
}

void SendFlowWebSocketResponse(SOCKET client, const std::string& transaction_id,
                               const std::string& flow_id, const std::string& status,
                               const std::string& message, int step = -1,
                               int total = -1, bool is_final = false) {
  std::ostringstream json;
  json << "{\"type\":\"flow_trigger_response\","
       << "\"transactionId\":\"" << JsonEscape(transaction_id) << "\","
       << "\"flowId\":\"" << JsonEscape(flow_id) << "\","
       << "\"status\":\"" << JsonEscape(status) << "\","
       << "\"message\":\"" << JsonEscape(message) << "\"";
  if (step >= 0) json << ",\"currentStep\":" << step;
  if (total >= 0) json << ",\"totalSteps\":" << total;
  json << ",\"isFinal\":" << (is_final ? "true" : "false")
       << ",\"prelogin\":true"
       << ",\"timestamp\":\"" << UtcTimestamp() << "\"}";
  SendWebSocketText(client, json.str());
}

std::string MakePreloginRequestId() {
  return "prelogin_" + std::to_string(GetCurrentProcessId()) + "_" +
         std::to_string(GetTickCount64());
}

bool TriggerPreloginUnlockFlow(SOCKET client, const std::string& transaction_id,
                               const std::string& flow_id) {
  std::string password;
  std::string flow_name;
  std::string node_id;
  if (!LoadPreloginCredential(flow_id, &password, &flow_name, &node_id)) {
    SendFlowWebSocketResponse(client, transaction_id, flow_id, "failed",
                              "Pre-login unlock credential is not provisioned",
                              0, 1, true);
    return false;
  }

  SendFlowWebSocketResponse(client, transaction_id, flow_id, "started",
                            "Running pre-login unlock", 0, 1, false);

  const std::string request_id = MakePreloginRequestId();
  const std::string password_b64 = Base64Encode(BytesFromString(password));
  password.assign(password.size(), '\0');

  std::ostringstream request;
  request << "{\"requestId\":\"" << JsonEscape(request_id) << "\","
          << "\"flowId\":\"" << JsonEscape(flow_id) << "\","
          << "\"nodeId\":\"" << JsonEscape(node_id) << "\","
          << "\"passwordB64\":\"" << JsonEscape(password_b64) << "\"}";

  const std::string response = HandleServiceUnlockRequest(request.str());
  if (ExtractJsonBool(response, "success")) {
    SendFlowWebSocketResponse(client, transaction_id, flow_id, "completed",
                              "Pre-login unlock input sent", 1, 1, true);
    return true;
  }

  std::string error = ExtractJsonString(response, "error");
  if (error.empty()) error = "Pre-login unlock failed";
  SendFlowWebSocketResponse(client, transaction_id, flow_id, "failed", error,
                            1, 1, true);
  return false;
}

void HandlePreloginWebSocketMessage(SOCKET client, const std::string& message,
                                    bool* should_stop_after_success) {
  const std::string type = ExtractJsonString(message, "type");
  const std::string transaction_id = ExtractJsonString(message, "transactionId");
  if (type == "ping") {
    std::ostringstream json;
    json << "{\"type\":\"pong\",\"prelogin\":true,\"timestamp\":\""
         << UtcTimestamp() << "\"}";
    SendWebSocketText(client, json.str());
    return;
  }
  if (type == "client_info") {
    return;
  }
  if (type == "list_flows") {
    SendWebSocketText(client, FlowListResponseJson(transaction_id));
    return;
  }
  if (type == "trigger_flow") {
    const std::string flow_id = ExtractJsonString(message, "flowId");
    if (flow_id.empty()) {
      SendFlowWebSocketResponse(client, transaction_id, flow_id, "failed",
                                "No flowId provided", 0, 1, true);
      return;
    }
    if (TriggerPreloginUnlockFlow(client, transaction_id, flow_id) &&
        should_stop_after_success) {
      *should_stop_after_success = true;
    }
    return;
  }
}

bool IsConsoleSessionUnlocked() {
  DWORD session_id = WTSGetActiveConsoleSessionId();
  if (session_id == 0xFFFFFFFF) return false;

  LPWSTR buffer = nullptr;
  DWORD bytes_returned = 0;
  if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, session_id,
                                  WTSSessionInfoEx, &buffer, &bytes_returned)) {
    if (buffer && bytes_returned >= sizeof(WTSINFOEXW)) {
      WTSINFOEXW* info = reinterpret_cast<WTSINFOEXW*>(buffer);
      if (info->Level == 1) {
        ULONG flags = info->Data.WTSInfoExLevel1.SessionFlags;
        WTSFreeMemory(buffer);
        // WTS_SESSIONSTATE_LOCK = 0, WTS_SESSIONSTATE_UNLOCK = 1
        return flags == WTS_SESSIONSTATE_UNLOCK;
      }
    }
    if (buffer) WTSFreeMemory(buffer);
  }
  return false;
}

void HandlePreloginClient(SOCKET client, HANDLE stop_event) {
  DWORD timeout_ms = 1000;
  setsockopt(client, SOL_SOCKET, SO_RCVTIMEO,
             reinterpret_cast<const char*>(&timeout_ms), sizeof(timeout_ms));

  std::string request;
  if (!ReadHttpUpgradeRequest(client, &request) ||
      !CompleteWebSocketHandshake(client, request)) {
    return;
  }

  std::ostringstream ack;
  ack << "{\"type\":\"connection_ack\","
      << "\"status\":\"connected\","
      << "\"agent\":\"autonion-prelogin\","
      << "\"version\":\"2.0.5\","
      << "\"prelogin\":true,"
      << "\"timestamp\":\"" << UtcTimestamp() << "\","
      << "\"server_info\":{\"port\":" << kPreloginWebSocketPort << ",\"clients\":1}}";
  SendWebSocketText(client, ack.str());

  bool should_stop_after_success = false;
  while (!should_stop_after_success &&
         WaitForSingleObject(stop_event, 0) == WAIT_TIMEOUT &&
         WaitForSingleObject(g_service_stop_event, 0) == WAIT_TIMEOUT &&
         !IsConsoleSessionUnlocked()) {
    std::string message;
    if (!ReceiveWebSocketText(client, &message)) {
      int error = WSAGetLastError();
      if (error == WSAETIMEDOUT || error == WSAEWOULDBLOCK) continue;
      break;
    }
    HandlePreloginWebSocketMessage(client, message, &should_stop_after_success);
  }

  if (should_stop_after_success && g_prelogin_stop_event) {
    SetEvent(g_prelogin_stop_event);
  }
}

struct PreloginClientParams {
  SOCKET client;
  HANDLE stop_event;
};

DWORD WINAPI PreloginClientWorkerThread(LPVOID parameter) {
  PreloginClientParams* params = static_cast<PreloginClientParams*>(parameter);
  SOCKET client = params->client;
  HANDLE stop_event = params->stop_event;
  delete params;

  HandlePreloginClient(client, stop_event);

  shutdown(client, SD_BOTH);
  closesocket(client);

  AcquireSRWLockExclusive(&g_prelogin_lock);
  g_prelogin_client_sockets.erase(
      std::remove(g_prelogin_client_sockets.begin(),
                  g_prelogin_client_sockets.end(), client),
      g_prelogin_client_sockets.end());
  ReleaseSRWLockExclusive(&g_prelogin_lock);

  return 0;
}


uint16_t ReadNetworkU16(const uint8_t* data) {
  return static_cast<uint16_t>((data[0] << 8) | data[1]);
}

void WriteNetworkU16(std::vector<uint8_t>* out, uint16_t value) {
  out->push_back(static_cast<uint8_t>((value >> 8) & 0xff));
  out->push_back(static_cast<uint8_t>(value & 0xff));
}

void WriteNetworkU32(std::vector<uint8_t>* out, uint32_t value) {
  out->push_back(static_cast<uint8_t>((value >> 24) & 0xff));
  out->push_back(static_cast<uint8_t>((value >> 16) & 0xff));
  out->push_back(static_cast<uint8_t>((value >> 8) & 0xff));
  out->push_back(static_cast<uint8_t>(value & 0xff));
}

std::string LowerAscii(std::string value) {
  for (char& ch : value) {
    if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
  }
  return value;
}

std::string SanitizeMdnsLabel(const std::string& value) {
  std::string out;
  bool previous_dash = false;
  for (unsigned char ch : value) {
    bool ok = (ch >= 'a' && ch <= 'z') ||
              (ch >= 'A' && ch <= 'Z') ||
              (ch >= '0' && ch <= '9');
    if (ok) {
      out.push_back(static_cast<char>(ch));
      previous_dash = false;
    } else if (!previous_dash && !out.empty()) {
      out.push_back('-');
      previous_dash = true;
    }
  }
  while (!out.empty() && out.back() == '-') out.pop_back();
  if (out.empty()) out = "Autonion";
  if (out.size() > 50) out.resize(50);
  return out;
}

std::string GetComputerNameLabel() {
  char buffer[MAX_COMPUTERNAME_LENGTH + 1]{};
  DWORD size = static_cast<DWORD>(sizeof(buffer));
  if (GetComputerNameA(buffer, &size) && size > 0) {
    return SanitizeMdnsLabel(std::string(buffer, buffer + size));
  }
  return "Autonion";
}

struct PreloginIdentity {
  std::string device_id;
  std::string device_name;
};

PreloginIdentity GetPreloginIdentity() {
  PreloginIdentity identity;
  if (!LoadPreloginIdentity(&identity.device_id, &identity.device_name)) {
    identity.device_name = GetComputerNameLabel();
    identity.device_id = "prelogin-" + identity.device_name;
  }
  identity.device_name = SanitizeMdnsLabel(identity.device_name);
  if (identity.device_id.empty()) identity.device_id = "prelogin-" + identity.device_name;
  return identity;
}

std::string GetMdnsServiceInstanceName(const PreloginIdentity& identity) {
  return identity.device_name + "._myautomation._tcp.local";
}

std::string GetMdnsHostName(const PreloginIdentity& identity) {
  return LowerAscii(identity.device_name) + "-autonion.local";
}

bool DnsReadName(const uint8_t* packet, size_t packet_length, size_t* offset,
                 std::string* name, int depth = 0) {
  if (!offset || !name || depth > 8) return false;
  size_t cursor = *offset;
  std::string out;
  bool jumped = false;

  while (cursor < packet_length) {
    uint8_t length = packet[cursor++];
    if (length == 0) {
      if (!jumped) *offset = cursor;
      *name = out;
      return true;
    }
    if ((length & 0xC0) == 0xC0) {
      if (cursor >= packet_length) return false;
      uint16_t pointer = static_cast<uint16_t>(((length & 0x3f) << 8) | packet[cursor++]);
      if (pointer >= packet_length) return false;
      if (!jumped) *offset = cursor;
      size_t pointed_offset = pointer;
      std::string suffix;
      if (!DnsReadName(packet, packet_length, &pointed_offset, &suffix, depth + 1)) {
        return false;
      }
      if (!out.empty() && !suffix.empty()) out.push_back('.');
      out += suffix;
      *name = out;
      return true;
    }
    if ((length & 0xC0) != 0 || cursor + length > packet_length) return false;
    if (!out.empty()) out.push_back('.');
    out.append(reinterpret_cast<const char*>(packet + cursor),
               reinterpret_cast<const char*>(packet + cursor + length));
    cursor += length;
  }
  return false;
}

void DnsWriteName(std::vector<uint8_t>* out, const std::string& name) {
  size_t start = 0;
  while (start < name.size()) {
    size_t dot = name.find('.', start);
    size_t end = (dot == std::string::npos) ? name.size() : dot;
    size_t length = end - start;
    if (length > 63) length = 63;
    out->push_back(static_cast<uint8_t>(length));
    out->insert(out->end(), name.begin() + static_cast<ptrdiff_t>(start),
                name.begin() + static_cast<ptrdiff_t>(start + length));
    if (dot == std::string::npos) break;
    start = dot + 1;
  }
  out->push_back(0);
}

void DnsWriteRecordHeader(std::vector<uint8_t>* out, const std::string& name,
                          uint16_t type, uint16_t dns_class, uint32_t ttl,
                          uint16_t data_length) {
  DnsWriteName(out, name);
  WriteNetworkU16(out, type);
  WriteNetworkU16(out, dns_class);
  WriteNetworkU32(out, ttl);
  WriteNetworkU16(out, data_length);
}

std::vector<uint8_t> DnsNamePayload(const std::string& name) {
  std::vector<uint8_t> payload;
  DnsWriteName(&payload, name);
  return payload;
}

void AddPtrRecord(std::vector<uint8_t>* out, const std::string& name,
                  const std::string& target) {
  std::vector<uint8_t> payload = DnsNamePayload(target);
  DnsWriteRecordHeader(out, name, 12, 1, 120,
                       static_cast<uint16_t>(payload.size()));
  out->insert(out->end(), payload.begin(), payload.end());
}

void AddSrvRecord(std::vector<uint8_t>* out, const std::string& name,
                  uint16_t port, const std::string& host) {
  std::vector<uint8_t> payload;
  WriteNetworkU16(&payload, 0);
  WriteNetworkU16(&payload, 0);
  WriteNetworkU16(&payload, port);
  DnsWriteName(&payload, host);
  DnsWriteRecordHeader(out, name, 33, 0x8001, 120,
                       static_cast<uint16_t>(payload.size()));
  out->insert(out->end(), payload.begin(), payload.end());
}

void AddTxtRecord(std::vector<uint8_t>* out, const std::string& name,
                  const std::vector<std::string>& values) {
  std::vector<uint8_t> payload;
  for (const std::string& value : values) {
    size_t length = std::min<size_t>(value.size(), 255);
    payload.push_back(static_cast<uint8_t>(length));
    payload.insert(payload.end(), value.begin(), value.begin() + static_cast<ptrdiff_t>(length));
  }
  DnsWriteRecordHeader(out, name, 16, 0x8001, 120,
                       static_cast<uint16_t>(payload.size()));
  out->insert(out->end(), payload.begin(), payload.end());
}

void AddARecord(std::vector<uint8_t>* out, const std::string& name, in_addr address) {
  DnsWriteRecordHeader(out, name, 1, 0x8001, 120, 4);
  const uint8_t* bytes = reinterpret_cast<const uint8_t*>(&address.s_addr);
  out->insert(out->end(), bytes, bytes + 4);
}

bool GetPrimaryIpv4Address(in_addr* address, std::string* address_text) {
  if (!address) return false;
  char hostname[256]{};
  if (gethostname(hostname, sizeof(hostname)) != 0) return false;

  addrinfo hints{};
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  addrinfo* results = nullptr;
  if (getaddrinfo(hostname, nullptr, &hints, &results) != 0) return false;

  bool found = false;
  in_addr candidate{};
  std::string candidate_text;
  bool candidate_found = false;

  for (addrinfo* item = results; item != nullptr; item = item->ai_next) {
    sockaddr_in* ipv4 = reinterpret_cast<sockaddr_in*>(item->ai_addr);
    uint32_t host_order = ntohl(ipv4->sin_addr.s_addr);
    uint32_t first_byte = (host_order >> 24) & 0xff;
    uint32_t second_byte = (host_order >> 16) & 0xff;

    // Skip loopback (127.0.0.0/8), unspecified (0.0.0.0), and link-local APIPA (169.254.0.0/16)
    if (first_byte == 127 || first_byte == 0) continue;
    if (first_byte == 169 && second_byte == 254) continue;

    char buffer[INET_ADDRSTRLEN]{};
    inet_ntop(AF_INET, &ipv4->sin_addr, buffer, sizeof(buffer));

    // Check if this is private LAN (192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12)
    bool is_lan = (first_byte == 192 && second_byte == 168) ||
                  (first_byte == 10) ||
                  (first_byte == 172 && second_byte >= 16 && second_byte <= 31);

    if (is_lan) {
      *address = ipv4->sin_addr;
      if (address_text) *address_text = buffer;
      found = true;
      break;
    } else if (!candidate_found) {
      candidate = ipv4->sin_addr;
      candidate_text = buffer;
      candidate_found = true;
    }
  }
  freeaddrinfo(results);

  if (!found && candidate_found) {
    *address = candidate;
    if (address_text) *address_text = candidate_text;
    found = true;
  }

  return found;
}

std::vector<uint8_t> BuildMdnsResponse(const std::vector<std::string>& question_names,
                                       in_addr local_address,
                                       const std::string& local_address_text) {
  const PreloginIdentity identity = GetPreloginIdentity();
  const std::string service_instance_name = GetMdnsServiceInstanceName(identity);
  const std::string host_name = GetMdnsHostName(identity);
  const std::string service_instance_name_lower = LowerAscii(service_instance_name);
  const std::string host_name_lower = LowerAscii(host_name);

  bool include_service_enum = false;
  bool include_service = false;
  bool include_instance = false;
  bool include_host = false;

  for (const std::string& question : question_names) {
    const std::string name = LowerAscii(question);
    if (name == "_services._dns-sd._udp.local") include_service_enum = true;
    if (name == kMdnsServiceTypeName) include_service = true;
    if (name == service_instance_name_lower) include_instance = true;
    if (name == host_name_lower) include_host = true;
  }

  if (!include_service_enum && !include_service && !include_instance && !include_host) {
    return {};
  }

  std::vector<uint8_t> answers;
  uint16_t answer_count = 0;
  if (include_service_enum) {
    AddPtrRecord(&answers, "_services._dns-sd._udp.local", kMdnsServiceTypeName);
    ++answer_count;
  }
  if (include_service || include_service_enum) {
    AddPtrRecord(&answers, kMdnsServiceTypeName, service_instance_name);
    ++answer_count;
    include_instance = true;
  }
  if (include_instance) {
    AddSrvRecord(&answers, service_instance_name,
                 static_cast<uint16_t>(kPreloginWebSocketPort), host_name);
    ++answer_count;
    AddTxtRecord(&answers, service_instance_name, {
      "agent=autonion-prelogin",
      "prelogin=true",
      "version=2.0.5",
      "device_name=" + identity.device_name,
      "device_id=" + identity.device_id,
      "platform=windows",
      "host=" + local_address_text,
      "ws_port=" + std::to_string(kPreloginWebSocketPort),
      "ws_path=/automation",
    });
    ++answer_count;
    include_host = true;
  }
  if (include_host) {
    AddARecord(&answers, host_name, local_address);
    ++answer_count;
  }

  std::vector<uint8_t> response;
  WriteNetworkU16(&response, 0);
  WriteNetworkU16(&response, 0x8400);
  WriteNetworkU16(&response, 0);
  WriteNetworkU16(&response, answer_count);
  WriteNetworkU16(&response, 0);
  WriteNetworkU16(&response, 0);
  response.insert(response.end(), answers.begin(), answers.end());
  return response;
}

void SendMdnsPacket(SOCKET mdns_socket, const std::vector<uint8_t>& packet) {
  if (packet.empty()) return;
  sockaddr_in destination{};
  destination.sin_family = AF_INET;
  destination.sin_port = htons(static_cast<u_short>(kMdnsPort));
  inet_pton(AF_INET, "224.0.0.251", &destination.sin_addr);
  sendto(mdns_socket, reinterpret_cast<const char*>(packet.data()),
         static_cast<int>(packet.size()), 0,
         reinterpret_cast<sockaddr*>(&destination), sizeof(destination));
}

void SendMdnsAnnouncement(SOCKET mdns_socket, in_addr local_address,
                          const std::string& local_address_text) {
  std::vector<std::string> names = {kMdnsServiceTypeName};
  SendMdnsPacket(mdns_socket, BuildMdnsResponse(names, local_address, local_address_text));
}

void ProcessMdnsQuery(SOCKET mdns_socket, in_addr local_address,
                      const std::string& local_address_text) {
  uint8_t buffer[1500]{};
  sockaddr_in remote{};
  int remote_length = sizeof(remote);
  int received = recvfrom(mdns_socket, reinterpret_cast<char*>(buffer), sizeof(buffer), 0,
                          reinterpret_cast<sockaddr*>(&remote), &remote_length);
  if (received < 12) return;

  uint16_t question_count = ReadNetworkU16(buffer + 4);
  size_t offset = 12;
  std::vector<std::string> question_names;
  for (uint16_t i = 0; i < question_count && offset < static_cast<size_t>(received); ++i) {
    std::string name;
    if (!DnsReadName(buffer, static_cast<size_t>(received), &offset, &name)) return;
    if (offset + 4 > static_cast<size_t>(received)) return;
    uint16_t type = ReadNetworkU16(buffer + offset);
    offset += 4;
    if (type == 1 || type == 12 || type == 16 || type == 33 || type == 255) {
      question_names.push_back(name);
    }
  }

  SendMdnsPacket(mdns_socket,
                 BuildMdnsResponse(question_names, local_address, local_address_text));
}

SOCKET CreateMdnsSocket() {
  SOCKET mdns_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (mdns_socket == INVALID_SOCKET) return INVALID_SOCKET;

  BOOL reuse = TRUE;
  setsockopt(mdns_socket, SOL_SOCKET, SO_REUSEADDR,
             reinterpret_cast<const char*>(&reuse), sizeof(reuse));

  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  address.sin_port = htons(static_cast<u_short>(kMdnsPort));
  if (bind(mdns_socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == SOCKET_ERROR) {
    closesocket(mdns_socket);
    return INVALID_SOCKET;
  }

  ip_mreq membership{};
  inet_pton(AF_INET, "224.0.0.251", &membership.imr_multiaddr);
  membership.imr_interface.s_addr = htonl(INADDR_ANY);
  setsockopt(mdns_socket, IPPROTO_IP, IP_ADD_MEMBERSHIP,
             reinterpret_cast<const char*>(&membership), sizeof(membership));

  unsigned char ttl = 255;
  setsockopt(mdns_socket, IPPROTO_IP, IP_MULTICAST_TTL,
             reinterpret_cast<const char*>(&ttl), sizeof(ttl));
  return mdns_socket;
}

DWORD WINAPI PreloginMdnsThread(LPVOID parameter) {
  HANDLE stop_event = static_cast<HANDLE>(parameter);

  while (WaitForSingleObject(stop_event, 0) == WAIT_TIMEOUT &&
         WaitForSingleObject(g_service_stop_event, 0) == WAIT_TIMEOUT &&
         !IsConsoleSessionUnlocked()) {
    in_addr local_address{};
    std::string local_address_text;
    if (!GetPrimaryIpv4Address(&local_address, &local_address_text)) {
      Sleep(1500);
      continue;
    }

    SOCKET mdns_socket = CreateMdnsSocket();
    if (mdns_socket == INVALID_SOCKET) {
      Sleep(1500);
      continue;
    }

    AcquireSRWLockExclusive(&g_prelogin_lock);
    g_prelogin_mdns_socket = mdns_socket;
    ReleaseSRWLockExclusive(&g_prelogin_lock);

    // Send initial announcement
    SendMdnsAnnouncement(mdns_socket, local_address, local_address_text);
    ULONGLONG last_announcement = GetTickCount64();

    while (WaitForSingleObject(stop_event, 0) == WAIT_TIMEOUT &&
           WaitForSingleObject(g_service_stop_event, 0) == WAIT_TIMEOUT &&
           !IsConsoleSessionUnlocked()) {
      fd_set read_set;
      FD_ZERO(&read_set);
      FD_SET(mdns_socket, &read_set);
      timeval timeout{};
      timeout.tv_sec = 1;
      timeout.tv_usec = 0;
      int ready = select(0, &read_set, nullptr, nullptr, &timeout);

      if (ready == SOCKET_ERROR) {
        // Socket error (e.g. network interface reset / power cycle) -> recreate socket
        break;
      }

      if (ready > 0 && FD_ISSET(mdns_socket, &read_set)) {
        ProcessMdnsQuery(mdns_socket, local_address, local_address_text);
      }

      // Periodic beacon announcement every 20 seconds to prevent TTL expiry on Android
      ULONGLONG now = GetTickCount64();
      if (now - last_announcement >= 20000) {
        // Re-check IP in case DHCP assigned a new one
        in_addr current_addr{};
        std::string current_addr_text;
        if (GetPrimaryIpv4Address(&current_addr, &current_addr_text)) {
          if (current_addr.s_addr != local_address.s_addr) {
            // IP address changed! Recreate socket for new IP
            local_address = current_addr;
            local_address_text = current_addr_text;
            break;
          }
        }
        SendMdnsAnnouncement(mdns_socket, local_address, local_address_text);
        last_announcement = now;
      }
    }

    AcquireSRWLockExclusive(&g_prelogin_lock);
    if (g_prelogin_mdns_socket == mdns_socket) {
      g_prelogin_mdns_socket = INVALID_SOCKET;
    }
    ReleaseSRWLockExclusive(&g_prelogin_lock);

    closesocket(mdns_socket);
    Sleep(500);
  }

  return 0;
}

DWORD WINAPI PreloginWebSocketListenerThread(LPVOID parameter) {
  HANDLE stop_event = static_cast<HANDLE>(parameter);

  while (WaitForSingleObject(stop_event, 0) == WAIT_TIMEOUT &&
         WaitForSingleObject(g_service_stop_event, 0) == WAIT_TIMEOUT &&
         !IsConsoleSessionUnlocked()) {
    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) {
      Sleep(1500);
      continue;
    }

    BOOL reuse = TRUE;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR,
               reinterpret_cast<const char*>(&reuse), sizeof(reuse));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(static_cast<u_short>(kPreloginWebSocketPort));

    if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == SOCKET_ERROR ||
        listen(listener, SOMAXCONN) == SOCKET_ERROR) {
      closesocket(listener);
      Sleep(1500);
      continue;
    }

    AcquireSRWLockExclusive(&g_prelogin_lock);
    g_prelogin_listen_socket = listener;
    ReleaseSRWLockExclusive(&g_prelogin_lock);

    while (WaitForSingleObject(stop_event, 0) == WAIT_TIMEOUT &&
           WaitForSingleObject(g_service_stop_event, 0) == WAIT_TIMEOUT &&
           !IsConsoleSessionUnlocked()) {
      fd_set read_set;
      FD_ZERO(&read_set);
      FD_SET(listener, &read_set);
      timeval timeout{};
      timeout.tv_sec = 1;
      timeout.tv_usec = 0;
      int ready = select(0, &read_set, nullptr, nullptr, &timeout);
      if (ready == SOCKET_ERROR) {
        // Socket error (e.g. network interface reset / power cycle) -> recreate listener
        break;
      }
      if (ready <= 0) continue;

      if (FD_ISSET(listener, &read_set)) {
        SOCKET client = accept(listener, nullptr, nullptr);
        if (client != INVALID_SOCKET) {
          AcquireSRWLockExclusive(&g_prelogin_lock);
          g_prelogin_client_sockets.push_back(client);
          ReleaseSRWLockExclusive(&g_prelogin_lock);

          PreloginClientParams* params = new PreloginClientParams{client, stop_event};
          HANDLE client_thread = CreateThread(nullptr, 0, PreloginClientWorkerThread,
                                              params, 0, nullptr);
          if (client_thread) {
            AcquireSRWLockExclusive(&g_prelogin_lock);
            g_prelogin_client_threads.push_back(client_thread);
            ReleaseSRWLockExclusive(&g_prelogin_lock);
          } else {
            delete params;
            shutdown(client, SD_BOTH);
            closesocket(client);
            AcquireSRWLockExclusive(&g_prelogin_lock);
            g_prelogin_client_sockets.erase(
                std::remove(g_prelogin_client_sockets.begin(),
                            g_prelogin_client_sockets.end(), client),
                g_prelogin_client_sockets.end());
            ReleaseSRWLockExclusive(&g_prelogin_lock);
          }
        }
      }
    }

    AcquireSRWLockExclusive(&g_prelogin_lock);
    if (g_prelogin_listen_socket == listener) {
      g_prelogin_listen_socket = INVALID_SOCKET;
    }
    ReleaseSRWLockExclusive(&g_prelogin_lock);

    closesocket(listener);
    Sleep(500);
  }

  return 0;
}

void StartPreloginWebSocketServerIfNeeded() {
  if (IsConsoleSessionUnlocked()) return;

  AcquireSRWLockExclusive(&g_prelogin_lock);
  if (g_prelogin_listener_thread || g_prelogin_mdns_thread) {
    ReleaseSRWLockExclusive(&g_prelogin_lock);
    return;
  }

  WSADATA wsa{};
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
    ReleaseSRWLockExclusive(&g_prelogin_lock);
    return;
  }

  HANDLE stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!stop_event) {
    WSACleanup();
    ReleaseSRWLockExclusive(&g_prelogin_lock);
    return;
  }

  g_prelogin_stop_event = stop_event;
  g_prelogin_listener_thread = CreateThread(nullptr, 0, PreloginWebSocketListenerThread,
                                            stop_event, 0, nullptr);
  g_prelogin_mdns_thread = CreateThread(nullptr, 0, PreloginMdnsThread,
                                        stop_event, 0, nullptr);
  ReleaseSRWLockExclusive(&g_prelogin_lock);
}

void StopPreloginWebSocketServer() {
  HANDLE stop_event = nullptr;
  HANDLE listener_thread = nullptr;
  HANDLE mdns_thread = nullptr;
  std::vector<HANDLE> client_threads;
  std::vector<SOCKET> client_sockets;

  AcquireSRWLockExclusive(&g_prelogin_lock);
  stop_event = g_prelogin_stop_event;
  listener_thread = g_prelogin_listener_thread;
  mdns_thread = g_prelogin_mdns_thread;
  client_threads = g_prelogin_client_threads;
  client_sockets = g_prelogin_client_sockets;

  g_prelogin_stop_event = nullptr;
  g_prelogin_listener_thread = nullptr;
  g_prelogin_mdns_thread = nullptr;
  g_prelogin_client_threads.clear();
  g_prelogin_client_sockets.clear();

  if (stop_event) SetEvent(stop_event);

  // Close listening and mDNS sockets to unblock select() immediately
  if (g_prelogin_listen_socket != INVALID_SOCKET) {
    closesocket(g_prelogin_listen_socket);
    g_prelogin_listen_socket = INVALID_SOCKET;
  }
  if (g_prelogin_mdns_socket != INVALID_SOCKET) {
    closesocket(g_prelogin_mdns_socket);
    g_prelogin_mdns_socket = INVALID_SOCKET;
  }

  // Close all client sockets to unblock recv() immediately
  for (SOCKET s : client_sockets) {
    if (s != INVALID_SOCKET) {
      shutdown(s, SD_BOTH);
      closesocket(s);
    }
  }
  ReleaseSRWLockExclusive(&g_prelogin_lock);

  // Wait for listener and mdns threads to exit (clean join)
  std::vector<HANDLE> wait_handles;
  if (listener_thread) wait_handles.push_back(listener_thread);
  if (mdns_thread) wait_handles.push_back(mdns_thread);
  for (HANDLE th : client_threads) {
    if (th) wait_handles.push_back(th);
  }

  if (!wait_handles.empty()) {
    WaitForMultipleObjects(static_cast<DWORD>(wait_handles.size()),
                           wait_handles.data(), TRUE, 3000);
    for (HANDLE h : wait_handles) CloseHandle(h);
  }

  if (stop_event) CloseHandle(stop_event);
  WSACleanup();
}

void ProcessPipeClient(HANDLE pipe) {
  const std::string request = ReadPipeMessage(pipe);
  if (request.empty()) {
    WritePipeText(pipe, MakePipeResponse(false, "", "Unlock request was empty", ""));
    return;
  }

  std::string rejection_reason;
  if (!IsPipeClientAllowed(pipe, &rejection_reason)) {
    const std::string request_id = ExtractJsonString(request, "requestId");
    std::string message = "Unlock service rejected request outside the active desktop session";
    if (!rejection_reason.empty()) {
      message += ": " + rejection_reason;
    }
    WritePipeText(pipe, MakePipeResponse(false, request_id, message, ""));
    return;
  }

  WritePipeText(pipe, HandleServiceUnlockRequest(request));
}

HANDLE CreateUnlockPipe() {
  PSECURITY_DESCRIPTOR security_descriptor = nullptr;
  SECURITY_ATTRIBUTES security_attributes{};
  SECURITY_ATTRIBUTES* security_attributes_ptr = nullptr;

  if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)", SDDL_REVISION_1,
          &security_descriptor, nullptr)) {
    security_attributes.nLength = sizeof(security_attributes);
    security_attributes.lpSecurityDescriptor = security_descriptor;
    security_attributes.bInheritHandle = FALSE;
    security_attributes_ptr = &security_attributes;
  }

  HANDLE pipe = CreateNamedPipeW(
      kPipeName,
      PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
      1,
      kPipeBufferSize,
      kPipeBufferSize,
      0,
      security_attributes_ptr);

  if (security_descriptor) LocalFree(security_descriptor);
  return pipe;
}

void PublishServiceStatus(DWORD state, DWORD win32_exit_code = NO_ERROR,
                          DWORD wait_hint = 0) {
  static DWORD checkpoint = 1;
  if (!g_service_status_handle) return;

  g_service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_service_status.dwCurrentState = state;
  g_service_status.dwControlsAccepted = state == SERVICE_RUNNING
      ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN |
            SERVICE_ACCEPT_POWEREVENT | SERVICE_ACCEPT_SESSIONCHANGE
      : 0;
  g_service_status.dwWin32ExitCode = win32_exit_code;
  g_service_status.dwServiceSpecificExitCode = 0;
  g_service_status.dwWaitHint = wait_hint;
  g_service_status.dwCheckPoint =
      (state == SERVICE_RUNNING || state == SERVICE_STOPPED) ? 0 : checkpoint++;

  SetServiceStatus(g_service_status_handle, &g_service_status);
}

void WakeServicePipe() {
  HANDLE pipe = CreateFileW(kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (pipe != INVALID_HANDLE_VALUE) CloseHandle(pipe);
}

DWORD WINAPI ServiceControlHandlerEx(DWORD control, DWORD event_type,
                                    LPVOID event_data, LPVOID context) {
  (void)event_data;
  (void)context;

  if (control == SERVICE_CONTROL_SESSIONCHANGE) {
    if (IsConsoleSessionUnlocked()) {
      StopPreloginWebSocketServer();
    } else {
      StartPreloginWebSocketServerIfNeeded();
    }
    return NO_ERROR;
  }

  if (control == SERVICE_CONTROL_POWEREVENT) {
    if (event_type == PBT_APMSUSPEND) {
      StopPreloginWebSocketServer();
    } else if (event_type == PBT_APMRESUMEAUTOMATIC ||
               event_type == PBT_APMRESUMESUSPEND) {
      if (!IsConsoleSessionUnlocked()) {
        StartPreloginWebSocketServerIfNeeded();
      }
    }
    return NO_ERROR;
  }

  if (control != SERVICE_CONTROL_STOP && control != SERVICE_CONTROL_SHUTDOWN) {
    return ERROR_CALL_NOT_IMPLEMENTED;
  }

  PublishServiceStatus(SERVICE_STOP_PENDING, NO_ERROR, 3000);
  StopPreloginWebSocketServer();
  if (g_service_stop_event) SetEvent(g_service_stop_event);
  WakeServicePipe();
  return NO_ERROR;
}

void RunServicePipeLoop(HANDLE stop_event) {
  while (WaitForSingleObject(stop_event, 0) == WAIT_TIMEOUT) {
    HANDLE pipe = CreateUnlockPipe();
    if (pipe == INVALID_HANDLE_VALUE) {
      Sleep(1000);
      continue;
    }

    BOOL connected = ConnectNamedPipe(pipe, nullptr) ? TRUE :
                     (GetLastError() == ERROR_PIPE_CONNECTED);
    if (connected && WaitForSingleObject(stop_event, 0) == WAIT_TIMEOUT) {
      ProcessPipeClient(pipe);
      FlushFileBuffers(pipe);
    }

    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
  }
}

void WINAPI ServiceMain(DWORD argc, wchar_t* argv[]) {
  (void)argc;
  (void)argv;
  g_service_status_handle = RegisterServiceCtrlHandlerExW(
      kServiceName, ServiceControlHandlerEx, nullptr);
  if (!g_service_status_handle) return;

  PublishServiceStatus(SERVICE_START_PENDING, NO_ERROR, 3000);
  g_service_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!g_service_stop_event) {
    PublishServiceStatus(SERVICE_STOPPED, GetLastError(), 0);
    return;
  }

  PublishServiceStatus(SERVICE_RUNNING);
  StartPreloginWebSocketServerIfNeeded();
  RunServicePipeLoop(g_service_stop_event);
  StopPreloginWebSocketServer();

  CloseHandle(g_service_stop_event);
  g_service_stop_event = nullptr;
  PublishServiceStatus(SERVICE_STOPPED);
}

int RunService() {
  SERVICE_TABLE_ENTRYW service_table[] = {
      {const_cast<LPWSTR>(kServiceName), ServiceMain},
      {nullptr, nullptr},
  };
  if (!StartServiceCtrlDispatcherW(service_table)) {
    return static_cast<int>(GetLastError());
  }
  return 0;
}

bool StopServiceAndWait(SC_HANDLE service, DWORD timeout_ms) {
  SERVICE_STATUS_PROCESS status{};
  DWORD bytes_needed = 0;
  if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
                            reinterpret_cast<LPBYTE>(&status), sizeof(status),
                            &bytes_needed)) {
    return false;
  }
  if (status.dwCurrentState == SERVICE_STOPPED) return true;

  SERVICE_STATUS basic_status{};
  if (!ControlService(service, SERVICE_CONTROL_STOP, &basic_status)) {
    DWORD error = GetLastError();
    if (error != ERROR_SERVICE_NOT_ACTIVE) return false;
  }

  DWORD deadline = GetTickCount() + timeout_ms;
  do {
    Sleep(250);
    if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
                              reinterpret_cast<LPBYTE>(&status), sizeof(status),
                              &bytes_needed)) {
      return false;
    }
    if (status.dwCurrentState == SERVICE_STOPPED) return true;
  } while (GetTickCount() < deadline);

  return false;
}

int StartInstalledService(SC_HANDLE service) {
  if (StartServiceW(service, 0, nullptr)) return 0;
  DWORD error = GetLastError();
  if (error == ERROR_SERVICE_ALREADY_RUNNING) return 0;
  std::fwprintf(stderr, L"StartService failed: %lu\n", error);
  return static_cast<int>(error);
}

// Runs a netsh advfirewall command silently. Returns true on success.
bool RunNetsh(const std::wstring& args) {
  std::wstring cmd = L"netsh advfirewall firewall " + args;
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    return false;
  }
  WaitForSingleObject(pi.hProcess, 10000);
  DWORD exit_code = 1;
  GetExitCodeProcess(pi.hProcess, &exit_code);
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  return exit_code == 0;
}

// Creates Windows Firewall rules so the pre-login service can accept inbound
// mDNS queries (UDP 5353) and WebSocket connections (TCP 4545).
// Uses profile=any so rules apply regardless of NLA network classification,
// which is critical during pre-login when Windows may categorize the network
// as Public or Unidentified before the user has logged in.
void ConfigureFirewallRules() {
  std::wstring exe_path = GetModulePath();

  // Delete any existing rules first (idempotent reinstall)
  RunNetsh(L"delete rule name=\"Autonion Unlock Helper (WebSocket)\"");
  RunNetsh(L"delete rule name=\"Autonion Unlock Helper (mDNS In)\"");
  RunNetsh(L"delete rule name=\"Autonion Unlock Helper (mDNS Out)\"");
  RunNetsh(L"delete rule name=\"Autonion Unlock Helper (Service)\"");

  // Port-based inbound TCP 4545 (WebSocket) - profile=any
  RunNetsh(L"add rule name=\"Autonion Unlock Helper (WebSocket)\" "
           L"dir=in action=allow protocol=TCP localport=4545 profile=any "
           L"description=\"Allows Android companion to connect to Autonion pre-login WebSocket\"");

  // Port-based inbound UDP 5353 (mDNS queries) - profile=any
  RunNetsh(L"add rule name=\"Autonion Unlock Helper (mDNS In)\" "
           L"dir=in action=allow protocol=UDP localport=5353 profile=any "
           L"description=\"Allows mDNS queries to reach Autonion pre-login service\"");

  // Outbound UDP 5353 (mDNS announcements) - profile=any
  RunNetsh(L"add rule name=\"Autonion Unlock Helper (mDNS Out)\" "
           L"dir=out action=allow protocol=UDP remoteport=5353 profile=any "
           L"description=\"Allows Autonion pre-login service to send mDNS announcements\"");

  // Program-based rule as belt-and-suspenders
  std::wstring prog_rule = L"add rule name=\"Autonion Unlock Helper (Service)\" "
                           L"dir=in action=allow profile=any program=\"" + exe_path + L"\" "
                           L"description=\"Allows all inbound connections to Autonion unlock helper service\"";
  RunNetsh(prog_rule);
}

int InstallService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr,
                                     SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
  if (!manager) {
    std::fwprintf(stderr, L"OpenSCManager failed: %lu\n", GetLastError());
    return 1;
  }

  std::wstring binary_path = QuoteArg(GetModulePath()) + L" --service";
  bool service_existed = false;
  SC_HANDLE service = CreateServiceW(
      manager,
      kServiceName,
      kServiceDisplayName,
      SERVICE_CHANGE_CONFIG | SERVICE_QUERY_STATUS | SERVICE_START | SERVICE_STOP | DELETE,
      SERVICE_WIN32_OWN_PROCESS,
      SERVICE_AUTO_START,
      SERVICE_ERROR_NORMAL,
      binary_path.c_str(),
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      nullptr);

  if (!service && GetLastError() == ERROR_SERVICE_EXISTS) {
    service_existed = true;
    service = OpenServiceW(manager, kServiceName,
                           SERVICE_CHANGE_CONFIG | SERVICE_QUERY_STATUS |
                               SERVICE_START | SERVICE_STOP | DELETE);
    if (service && !ChangeServiceConfigW(service, SERVICE_NO_CHANGE,
                                         SERVICE_AUTO_START, SERVICE_NO_CHANGE,
                                         binary_path.c_str(), nullptr, nullptr,
                                         nullptr, nullptr, nullptr,
                                         kServiceDisplayName)) {
      std::fwprintf(stderr, L"ChangeServiceConfig failed: %lu\n", GetLastError());
      CloseServiceHandle(service);
      CloseServiceHandle(manager);
      return 1;
    }
  }

  if (!service) {
    std::fwprintf(stderr, L"CreateService/OpenService failed: %lu\n", GetLastError());
    CloseServiceHandle(manager);
    return 1;
  }

  SERVICE_DESCRIPTIONW description{};
  description.lpDescription = const_cast<LPWSTR>(
      L"Autonion Agent LocalSystem helper for lock-screen unlock automation.");
  ChangeServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION, &description);

  // Configure firewall rules while we still have admin elevation
  ConfigureFirewallRules();

  if (service_existed && !StopServiceAndWait(service, 10000)) {
    std::fwprintf(stderr, L"Could not stop existing unlock service before restart\n");
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return 1;
  }

  int start_result = StartInstalledService(service);
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return start_result == 0 ? 0 : 1;
}

int UninstallService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) {
    std::fwprintf(stderr, L"OpenSCManager failed: %lu\n", GetLastError());
    return 1;
  }

  SC_HANDLE service = OpenServiceW(manager, kServiceName,
                                   SERVICE_STOP | DELETE | SERVICE_QUERY_STATUS);
  if (!service) {
    DWORD error = GetLastError();
    CloseServiceHandle(manager);
    return error == ERROR_SERVICE_DOES_NOT_EXIST ? 0 : 1;
  }

  StopServiceAndWait(service, 10000);

  BOOL deleted = DeleteService(service);
  DWORD delete_error = GetLastError();
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  if (!deleted && delete_error != ERROR_SERVICE_MARKED_FOR_DELETE) return 1;
  return 0;
}

}  // namespace

int wmain(int argc, wchar_t* argv[]) {
  std::vector<std::wstring> args;
  for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);

  fs::path request_path(GetArgValue(args, L"--request", kDefaultRequestPath));
  fs::path status_path(GetArgValue(args, L"--status", kDefaultStatusPath));

  if (HasArg(args, L"--install-service")) {
    return InstallService();
  }
  if (HasArg(args, L"--uninstall-service")) {
    return UninstallService();
  }
  if (HasArg(args, L"--service")) {
    return RunService();
  }
  if (HasArg(args, L"--child")) {
    return RunChild(request_path, status_path);
  }
  return RunParent(request_path, status_path);
}
