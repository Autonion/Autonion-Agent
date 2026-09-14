#include "../nsd_windows.h"
#include <flutter/standard_method_codec.h>
#include <cassert>
#include <iostream>
#include <thread>
#include <crtdbg.h>

using namespace nsd_windows;
const auto& codec = flutter::StandardMethodCodec::GetInstance();
struct Messenger : flutter::BinaryMessenger {
  DWORD platform = GetCurrentThreadId();
  flutter::BinaryMessageHandler handler;
  mutable std::vector<std::string> events;
  void Send(const std::string&, const uint8_t* message, size_t length, flutter::BinaryReply) const override {
    assert(GetCurrentThreadId() == platform);
    events.push_back(codec.DecodeMethodCall(message, length)->method_name());
  }
  void SetMessageHandler(const std::string&, flutter::BinaryMessageHandler callback) override { handler = std::move(callback); }
  void Call(const std::string& method, const std::string& handle) {
    flutter::EncodableMap arguments{
        {"handle", handle}, {"service.name", "AutonionTest"}, {"service.type", "_myautomation._tcp"}, {"service.port", 4545}};
    auto bytes = codec.EncodeMethodCall(flutter::MethodCall<flutter::EncodableValue>(method,
        std::make_unique<flutter::EncodableValue>(arguments)));
    handler(bytes->data(), bytes->size(), [](const uint8_t*, size_t) {});
  }
};
struct Pending {
  PDNS_SERVICE_REGISTER_COMPLETE callback = nullptr;
  void* context = nullptr;
  DnsInstance instance;
};
Pending pending;
int registration_calls = 0;
DNS_SERVICE_BROWSE_CALLBACK* browse_callback = nullptr;
void* browse_context = nullptr;
DWORD WINAPI RegisterFake(PDNS_SERVICE_REGISTER_REQUEST request, PDNS_SERVICE_CANCEL) {
  ++registration_calls;
  pending = {request->pRegisterCompletionCallback, request->pQueryContext,
      DnsInstance(DnsServiceCopyInstance(request->pServiceInstance), DnsServiceFreeInstance)};
  return DNS_REQUEST_PENDING;
}
DWORD WINAPI CancelFake(PDNS_SERVICE_CANCEL) { return ERROR_SUCCESS; }
DNS_STATUS WINAPI BrowseCancelFake(PDNS_SERVICE_CANCEL) { return ERROR_SUCCESS; }
DNS_STATUS WINAPI BrowseFake(PDNS_SERVICE_BROWSE_REQUEST request, PDNS_SERVICE_CANCEL) {
  browse_callback = request->pBrowseCallback; browse_context = request->pQueryContext;
  return DNS_REQUEST_PENDING;
}
void Complete(DWORD status) {
  auto saved = pending;
  std::thread worker([saved, status] {
    saved.callback(status, saved.context, status == ERROR_SUCCESS ? DnsServiceCopyInstance(saved.instance.get()) : nullptr);
  });
  worker.join();
  pending = {};
}
void Pump() {
  MSG message;
  while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
}
std::unique_ptr<NsdWindows> Plugin(Messenger& messenger) {
  DnsApi api;
  api.Register = RegisterFake; api.DeRegister = RegisterFake; api.RegisterCancel = CancelFake;
  api.Browse = BrowseFake; api.BrowseCancel = BrowseCancelFake;
  return std::make_unique<NsdWindows>(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      &messenger, "com.haberey/nsd", &codec), api);
}

int main() {
  _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
  _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
  Messenger messenger;
  auto plugin = Plugin(messenger);
  messenger.Call("register", "one");
  Complete(ERROR_SUCCESS);
  assert(messenger.events.empty()); // Worker callbacks cannot send Flutter messages directly.
  Pump();
  assert(messenger.events == std::vector<std::string>{"onRegistrationSuccessful"});
  messenger.Call("unregister", "one");
  Complete(ERROR_SUCCESS); Pump();
  assert(messenger.events.back() == "onUnregistrationSuccessful");

  messenger.Call("register", "failure");
  auto count = messenger.events.size();
  Complete(ERROR_CANCELLED); Pump();
  assert(messenger.events.size() == count + 1);
  assert(messenger.events.back() == "onRegistrationFailed"); // Exactly one failure notification.

  messenger.Call("startDiscovery", "scan");
  auto* raw_browse = static_cast<DiscoveryContext*>(browse_context);
  std::weak_ptr<DiscoveryContext> browse_lifetime = raw_browse->nativeLease;
  messenger.Call("stopDiscovery", "scan");
  assert(!browse_lifetime.expired());
  count = messenger.events.size();
  std::thread cancelling([] { browse_callback(ERROR_CANCELLED, browse_context, nullptr); }); cancelling.join();
  Pump();
  assert(browse_lifetime.expired());
  assert(messenger.events.size() == count);

  messenger.Call("register", "late");
  std::weak_ptr<RegisterContext> lifetime = static_cast<RegisterContext*>(pending.context)->nativeLease;
  plugin.reset();
  assert(!lifetime.expired());
  Complete(ERROR_CANCELLED); Pump();
  assert(lifetime.expired());
  assert(messenger.events.size() == count);

  plugin = Plugin(messenger);
  messenger.Call("register", "queued");
  Complete(ERROR_CANCELLED);
  plugin.reset(); Pump();
  assert(messenger.events.size() == count); // No channel calls after engine shutdown.

  plugin = Plugin(messenger);
  messenger.Call("register", "closing"); Complete(ERROR_SUCCESS); Pump();
  messenger.Call("unregister", "closing");
  const auto calls_before_shutdown = registration_calls;
  plugin.reset();
  assert(registration_calls == calls_before_shutdown); // Never deregister an in-flight operation twice.
  Complete(ERROR_SUCCESS); Pump();
  std::cout << "DNS callback thread, cancellation, failure, and shutdown tests passed\n";
}
