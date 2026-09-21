# Autonion Windows DNS-SD patch

Based on `nsd_windows` 3.0.1 from https://github.com/sebastianhaberey/nsd.
The upstream license is retained in `LICENSE`. Only the Windows implementation
is overridden in the application's `pubspec.yaml`; the parent Dart API is unchanged.

DNS-SD callbacks now enqueue their completion work on a message-only window created
on Flutter's platform thread. This serializes context-map access and channel
messages, including callbacks delivered during cancellation. Native operations
retain their context until the final callback. Shutdown drops queued Flutter work,
releases returned DNS resources, and removes late registrations. Failed registration
emits one failure event. An in-flight deregistration is not submitted twice at shutdown.

`windows/test/callback_thread_test.cpp` uses a real Windows message loop, worker
threads, Flutter's codec, a recording messenger, and injected DNS operations.
It does not advertise test services or interact with device credentials.
Run it through the application's `tools/run_connection_native_tests.ps1` after
a Debug Windows build has generated the Flutter wrapper libraries.

References:

- https://docs.flutter.dev/platform-integration/platform-channels#channels-and-platform-threading
- https://learn.microsoft.com/en-us/windows/win32/api/windns/nf-windns-dnsservicebrowsecancel
