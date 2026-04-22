#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <string>

#include "flutter_window.h"
#include "utils.h"

// Unique mutex name to enforce single-instance behavior.
constexpr const wchar_t kMutexName[] = L"Global\\AutonionAgentSingleInstance";
// Must match the title passed to window.Create() below.
constexpr const wchar_t kWindowTitle[] = L"autonion_cross_device";

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // ── Single-instance guard ───────────────────────────────
  // Try to create a named mutex. If it already exists, another
  // instance of the app is running – bring it to the foreground
  // and exit this duplicate process.
  HANDLE mutex = ::CreateMutexW(nullptr, FALSE, kMutexName);
  if (mutex == nullptr || ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // Another instance is running. Find its window and activate it.
    HWND existing = ::FindWindowW(nullptr, kWindowTitle);
    if (existing) {
      // If the window is minimized or hidden, restore it first.
      if (::IsIconic(existing) || !::IsWindowVisible(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
    }
    // Clean up and exit the duplicate instance.
    if (mutex) {
      ::CloseHandle(mutex);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Check if --startup flag is present (launch-at-login / system tray mode)
  bool start_hidden = std::any_of(
      command_line_arguments.begin(), command_line_arguments.end(),
      [](const std::string& arg) { return arg == "--startup"; });

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"autonion_cross_device", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::ReleaseMutex(mutex);
  ::CloseHandle(mutex);
  return EXIT_SUCCESS;
}
