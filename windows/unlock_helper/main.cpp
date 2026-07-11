#include <windows.h>
#include <tlhelp32.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

const DWORD kWaitTimeoutMs = 15000;
const ACCESS_MASK kDesktopAllAccess = 0x01FF;
const wchar_t* kDefaultRequestPath = L"C:\\ProgramData\\Autonion Agent\\Unlock\\request.json";
const wchar_t* kDefaultStatusPath = L"C:\\ProgramData\\Autonion Agent\\Unlock\\status.json";

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

  BOOL ok = CreateProcessWithTokenW(primary, LOGON_WITH_PROFILE, exe.c_str(),
                                    cmd_buffer.data(),
                                    CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                                    nullptr, nullptr, &si, &pi);
  DWORD create_error = GetLastError();
  CloseHandle(primary);
  if (!ok) {
    WriteStatus(status_path, false,
                "CreateProcessWithTokenW failed (Win32 " + std::to_string(create_error) + ")",
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

}  // namespace

int wmain(int argc, wchar_t* argv[]) {
  std::vector<std::wstring> args;
  for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);

  fs::path request_path(GetArgValue(args, L"--request", kDefaultRequestPath));
  fs::path status_path(GetArgValue(args, L"--status", kDefaultStatusPath));

  if (HasArg(args, L"--child")) {
    return RunChild(request_path, status_path);
  }
  return RunParent(request_path, status_path);
}
