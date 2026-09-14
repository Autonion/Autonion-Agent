#pragma once
#include <windows.h>
#include <cassert>
#include <deque>
#include <functional>
#include <mutex>
#include <stdexcept>

namespace nsd_windows {
// Created and closed on Flutter's platform thread. DNS worker threads only enqueue.
// A message-only window also works when the app has no visible top-level window.
class PlatformDispatcher {
 public:
  PlatformDispatcher() : thread_(GetCurrentThreadId()) {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"AutonionNsdPlatformDispatcher";
    if (!RegisterClassW(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
      throw std::runtime_error("Could not register NSD dispatcher window");
    window_ = CreateWindowExW(0, window_class.lpszClassName, L"", 0,
        0, 0, 0, 0, HWND_MESSAGE, nullptr, window_class.hInstance, this);
    if (!window_) throw std::runtime_error("Could not create NSD dispatcher window");
  }
  ~PlatformDispatcher() { if (window_) Close(); }
  PlatformDispatcher(const PlatformDispatcher&) = delete;
  PlatformDispatcher& operator=(const PlatformDispatcher&) = delete;

  bool Post(std::function<void()> callback) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!window_) return false;
    queue_.push_back(std::move(callback));
    if (!PostMessageW(window_, WM_APP + 1, 0, 0)) {
      auto rejected = std::move(queue_.back());
      queue_.pop_back();
      lock.unlock(); // Callback resources may have their own cleanup work.
      return false;
    }
    return true;
  }

  void Close() {
    assert(GetCurrentThreadId() == thread_);
    HWND window;
    std::deque<std::function<void()>> abandoned;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      window = window_;
      window_ = nullptr;
      abandoned.swap(queue_);
    }
    if (window) DestroyWindow(window);
    // Dropping queued tasks frees their DNS results without touching Flutter.
  }

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    auto* self = reinterpret_cast<PlatformDispatcher*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      self = static_cast<PlatformDispatcher*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
      SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    if (message == WM_APP + 1 && self) { self->Drain(); return 0; }
    return DefWindowProcW(window, message, wp, lp);
  }
  void Drain() {
    assert(GetCurrentThreadId() == thread_);
    while (true) {
      std::function<void()> callback;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!window_ || queue_.empty()) return;
        callback = std::move(queue_.front()); queue_.pop_front();
      }
      callback();
    }
  }
  DWORD thread_;
  HWND window_ = nullptr;
  std::mutex mutex_;
  std::deque<std::function<void()>> queue_;
};
}  // namespace nsd_windows
