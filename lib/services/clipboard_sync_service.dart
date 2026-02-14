import 'dart:async';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'logging_service.dart';
import 'websocket_service.dart';
import 'device_info_service.dart';

/// Bidirectional clipboard sync service.
/// - Polls the system clipboard every 1 second for changes
/// - Sends new clipboard content to Android via WebSocket
/// - Provides writeFromRemote() for incoming clipboard data with loop prevention
class ClipboardSyncService {
  LoggingService? _loggingService;
  WebSocketService? _webSocketService;
  DeviceInfoService? _deviceInfoService;

  Timer? _pollTimer;
  String? _lastClipboardText;
  bool _suppressNext = false; // Loop prevention flag
  bool _isRunning = false;

  // Stream to notify UI about clipboard sync events (for snackbar)
  final StreamController<String> _syncController = StreamController.broadcast();
  Stream<String> get clipboardSyncStream => _syncController.stream;

  void setLoggingService(LoggingService service) {
    _loggingService = service;
  }

  void setWebSocketService(WebSocketService service) {
    _webSocketService = service;
  }

  void setDeviceInfoService(DeviceInfoService service) {
    _deviceInfoService = service;
  }

  void _log(String message) {
    final logMsg = '[Clipboard] $message';
    print(logMsg);
    _loggingService?.log(logMsg);
  }

  /// Start polling the clipboard for changes.
  void startPolling() {
    if (_isRunning) return;
    _isRunning = true;

    // Seed with the current clipboard content so we don't send stale data on startup
    _readCurrentClipboard().then((text) {
      _lastClipboardText = text;
      _log('Clipboard polling started (seeded: ${text != null ? "${text.length} chars" : "empty"})');
    });

    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollClipboard());
  }

  /// Stop polling.
  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isRunning = false;
    _log('Clipboard polling stopped');
  }

  /// Read the current system clipboard text.
  Future<String?> _readCurrentClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } catch (e) {
      // Clipboard access can fail if another app holds the lock
      return null;
    }
  }

  /// Poll cycle: check if clipboard content changed.
  Future<void> _pollClipboard() async {
    final current = await _readCurrentClipboard();
    if (current == null) return; // Clipboard unavailable or empty

    // No change? Clear any pending suppress flag and skip.
    if (current == _lastClipboardText) {
      if (_suppressNext) {
        _suppressNext = false; // Consume the flag — remote write matched, no echo needed
      }
      return;
    }

    // Content changed!
    _lastClipboardText = current;

    // Check suppress flag (set by writeFromRemote to prevent loops)
    if (_suppressNext) {
      _suppressNext = false;
      _log('Suppressed outgoing sync (was written by remote)');
      return;
    }

    // Don't send empty or whitespace-only content
    if (current.trim().isEmpty) return;

    // Send to Android via WebSocket
    _sendClipboardToRemote(current);
  }

  /// Send clipboard text to all connected devices.
  void _sendClipboardToRemote(String text) {
    if (_webSocketService == null) return;

    final deviceId = _deviceInfoService?.deviceId ?? 'unknown';
    final message = {
      'id': const Uuid().v4(),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'type': 'clipboard.text_copied',
      'sourceDeviceId': deviceId,
      'payload': {
        'text': text,
      },
    };

    _webSocketService!.broadcastEvent(message);
    final preview = text.length > 50 ? '${text.substring(0, 50)}...' : text;
    _log('Sent clipboard to remote: "$preview"');
  }

  /// Write text received from a remote device to the local clipboard.
  /// Sets the suppress flag to prevent the next poll from echoing it back.
  Future<void> writeFromRemote(String text) async {
    try {
      // Set suppress BEFORE writing to avoid any race condition
      _suppressNext = true;
      _lastClipboardText = text; // Update tracking so poll sees no change

      await Clipboard.setData(ClipboardData(text: text));
      final preview = text.length > 50 ? '${text.substring(0, 50)}...' : text;
      _log('Clipboard synced from remote: "$preview"');
      _syncController.add(text); // Notify UI for snackbar
    } catch (e) {
      _suppressNext = false; // Reset on failure
      _log('Failed to write clipboard from remote: $e');
    }
  }

  void dispose() {
    stopPolling();
    _syncController.close();
  }
}
