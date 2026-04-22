import 'dart:async';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../../../core/services/logging_service.dart';
import '../../connection/services/websocket_service.dart';
import '../../connection/services/device_info_service.dart';

/// Bidirectional clipboard sync between desktop and connected devices.
class ClipboardSyncService {
  LoggingService? _loggingService;
  WebSocketService? _webSocketService;
  DeviceInfoService? _deviceInfoService;

  Timer? _pollTimer;
  String? _lastClipboardText;
  bool _suppressNext = false;
  bool _isRunning = false;

  final StreamController<String> _syncController = StreamController.broadcast();
  Stream<String> get clipboardSyncStream => _syncController.stream;

  void setLoggingService(LoggingService service) => _loggingService = service;
  void setWebSocketService(WebSocketService service) =>
      _webSocketService = service;
  void setDeviceInfoService(DeviceInfoService service) =>
      _deviceInfoService = service;

  void _log(String message) => _loggingService?.info('Clipboard', message);

  void startPolling() {
    if (_isRunning) return;
    _isRunning = true;
    _readCurrentClipboard().then((text) {
      _lastClipboardText = text;
      _log(
        'Polling started (seeded: ${text != null ? "${text.length} chars" : "empty"})',
      );
    });
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollClipboard(),
    );
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isRunning = false;
    _log('Polling stopped');
  }

  Future<String?> _readCurrentClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } catch (_) {
      return null;
    }
  }

  Future<void> _pollClipboard() async {
    final current = await _readCurrentClipboard();
    if (current == null) return;

    if (current == _lastClipboardText) {
      if (_suppressNext) _suppressNext = false;
      return;
    }

    _lastClipboardText = current;

    if (_suppressNext) {
      _suppressNext = false;
      return;
    }
    if (current.trim().isEmpty) return;
    _sendClipboardToRemote(current);
  }

  void _sendClipboardToRemote(String text) {
    if (_webSocketService == null) return;
    final message = {
      'id': const Uuid().v4(),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'type': 'clipboard.text_copied',
      'sourceDeviceId': _deviceInfoService?.deviceId ?? 'unknown',
      'payload': {'text': text},
    };
    _webSocketService!.broadcastEvent(message);
    final preview = text.length > 50 ? '${text.substring(0, 50)}...' : text;
    _log('Sent to remote: "$preview"');
  }

  Future<void> writeFromRemote(String text) async {
    try {
      _suppressNext = true;
      _lastClipboardText = text;
      await Clipboard.setData(ClipboardData(text: text));
      final preview = text.length > 50 ? '${text.substring(0, 50)}...' : text;
      _log('Synced from remote: "$preview"');
      _syncController.add(text);
    } catch (e) {
      _suppressNext = false;
      _log('Failed to write from remote: $e');
    }
  }

  void dispose() {
    stopPolling();
    _syncController.close();
  }
}
