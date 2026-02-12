import 'dart:async';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'logging_service.dart';

class CommandExecutor {
  LoggingService? _loggingService;
  
  // Stream to notify UI about clipboard sync events (for snackbar)
  final StreamController<String> _clipboardSyncController = StreamController.broadcast();
  Stream<String> get clipboardSyncStream => _clipboardSyncController.stream;

  void setLoggingService(LoggingService loggingService) {
    _loggingService = loggingService;
  }

  void _log(String message) {
    final logMsg = '[CMD] $message';
    print(logMsg);
    _loggingService?.log(logMsg);
  }

  Future<void> execute(Map<String, dynamic> command) async {
    String? action = command['action'];
    Map<String, dynamic>? payload;

    if (command.containsKey('type')) {
      final type = command['type'] as String;
      payload = command['payload'] as Map<String, dynamic>?;
      
      if (type == 'open_url') {
        action = 'open_url';
      } else if (type == 'clipboard.text_copied') {
        await _handleClipboardSync(payload);
        return;
      }
    }

    final urlString = payload?['url'] ?? command['url'];

    switch (action) {
      case 'open_url':
        if (urlString != null) {
          final uri = Uri.parse(urlString);
          if (await canLaunchUrl(uri)) {
             await launchUrl(uri);
             _log('Launched $urlString');
          } else {
            _log('Could not launch $urlString');
          }
        }
        break;
      default:
        _log('Unknown action $action or type ${command['type']}');
    }
  }

  Future<void> _handleClipboardSync(Map<String, dynamic>? payload) async {
    final text = payload?['text'] as String?;
    if (text == null || text.isEmpty) {
      _log('Clipboard sync: empty or null text, ignoring');
      return;
    }

    try {
      await Clipboard.setData(ClipboardData(text: text));
      final preview = text.length > 50 ? '${text.substring(0, 50)}...' : text;
      _log('Clipboard synced: "$preview"');
      _clipboardSyncController.add(text);
    } catch (e) {
      _log('Clipboard sync failed: $e');
    }
  }

  void dispose() {
    _clipboardSyncController.close();
  }
}
