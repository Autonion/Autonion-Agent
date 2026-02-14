import 'dart:async';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'logging_service.dart';
import 'websocket_service.dart';
import 'browser_launcher_service.dart';
import 'clipboard_sync_service.dart';
import 'trigger_rule_service.dart';

class CommandExecutor {
  LoggingService? _loggingService;
  WebSocketService? _webSocketService;
  BrowserLauncherService? _browserLauncherService;
  ClipboardSyncService? _clipboardSyncService;
  TriggerRuleService? _triggerRuleService;

  void setLoggingService(LoggingService loggingService) {
    _loggingService = loggingService;
  }

  void setWebSocketService(WebSocketService webSocketService) {
    _webSocketService = webSocketService;
  }

  void setBrowserLauncherService(BrowserLauncherService service) {
    _browserLauncherService = service;
  }

  void setClipboardSyncService(ClipboardSyncService service) {
    _clipboardSyncService = service;
  }

  void setTriggerRuleService(TriggerRuleService service) {
    _triggerRuleService = service;
  }

  void _log(String message) {
    final logMsg = '[CMD] $message';
    print(logMsg);
    _loggingService?.log(logMsg);
  }

  Future<void> execute(Map<String, dynamic> command) async {
    // 1. Handle natural language prompts from Android
    if (command.containsKey('prompt')) {
      final prompt = command['prompt'];
      _log('Received prompt from Android: "$prompt"');
      
      // Forward to Browser Extension
      if (_webSocketService != null) {
        // Check if extension is connected; if not, launch the browser
        if (!_webSocketService!.hasExtensionClient) {
          _log('Extension not connected — attempting to launch browser...');
          final launched = await _ensureBrowserRunning();
          if (!launched) {
            _log('Error: Could not launch browser or extension did not connect');
            return;
          }
        }

        _webSocketService!.broadcastEvent({
          'type': 'execute_prompt',
          'payload': command,
          'target': 'extension',
        });
        _log('Forwarded prompt to Browser Extension');
      } else {
        _log('Error: WebSocketService not linked, cannot forward to extension');
      }
      return;
    }

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
      } else if (type == 'register_triggers') {
        _triggerRuleService?.handleRegisterTriggers(payload ?? {});
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
        // Handle messages from the Browser Extension
        if (command.containsKey('source') && command['source'] == 'extension') {
          _handleExtensionMessage(command);
        } else {
          _log('Unknown action $action or type ${command['type']}');
        }
    }
  }

  void _handleExtensionMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    final payload = message['payload'] as Map<String, dynamic>?;

    switch (type) {
      case 'url_trigger':
        final domain = payload?['domain'] ?? 'unknown';
        final category = payload?['category'] ?? 'other';
        _log('URL Trigger: $domain → $category');
        // If it's a meeting domain, would broadcast DND trigger to Android
        // For now, just log it - Android relay handled by WebSocketService.broadcastEvent
        break;

      case 'execution_status':
        final status = message['status'] ?? 'unknown';
        final msg = message['message'] ?? '';
        _log('Extension execution: [$status] $msg');
        break;

      case 'execution_result':
        final status = message['status'] ?? 'unknown';
        final stepsExecuted = message['steps_executed'] ?? 0;
        _log('Execution complete: $status ($stepsExecuted steps)');
        break;

      case 'kill_switch_ack':
        _log('Kill switch acknowledged by extension');
        break;

      case 'execute_desktop_actions':
        final steps = message['steps'] as List<dynamic>?;
        _log('Received ${steps?.length ?? 0} desktop-level actions (not yet supported in V1)');
        break;

      case 'rule_triggered':
        _triggerRuleService?.handleRuleTriggered(message);
        break;

      default:
        _log('Extension message: $type');
    }
  }

  Future<void> _handleClipboardSync(Map<String, dynamic>? payload) async {
    final text = payload?['text'] as String?;
    if (text == null || text.isEmpty) {
      _log('Clipboard sync: empty or null text, ignoring');
      return;
    }

    if (_clipboardSyncService != null) {
      await _clipboardSyncService!.writeFromRemote(text);
    } else {
      // Fallback: write directly (no loop prevention)
      try {
        await Clipboard.setData(ClipboardData(text: text));
        final preview = text.length > 50 ? '${text.substring(0, 50)}...' : text;
        _log('Clipboard synced (fallback): "$preview"');
      } catch (e) {
        _log('Clipboard sync failed: $e');
      }
    }
  }

  /// Launch the browser and wait for the extension to connect.
  /// Returns true if extension is connected after browser launch.
  Future<bool> _ensureBrowserRunning() async {
    if (_browserLauncherService == null) {
      _log('BrowserLauncherService not available');
      return false;
    }

    final launched = await _browserLauncherService!.launchBrowser();
    if (!launched) return false;

    if (_webSocketService == null) return false;

    // Already connected? (race condition: extension connected between check and launch)
    if (_webSocketService!.hasExtensionClient) return true;

    // Wait for extension to connect (timeout 15 seconds)
    _log('Waiting for extension to connect (up to 15s)...');
    try {
      await _webSocketService!.extensionConnectionStream
          .where((connected) => connected)
          .first
          .timeout(const Duration(seconds: 15));
      _log('Extension connected after browser launch!');
      return true;
    } catch (_) {
      _log('Timeout: Extension did not connect within 15 seconds');
      return false;
    }
  }

  void dispose() {
  }
}
