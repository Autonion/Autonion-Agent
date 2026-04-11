import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/config/platform_config.dart';
import '../../../core/services/logging_service.dart';
import '../../browser_automation/services/browser_launcher_service.dart';
import '../../clipboard/services/clipboard_sync_service.dart';
import '../../triggers/services/trigger_rule_service.dart';
import '../services/device_info_service.dart';
import '../services/discovery_service.dart';
import '../services/websocket_service.dart';

/// Orchestrates all connection-related services and exposes reactive state.
///
/// This replaces the old main.dart monolith — services are started/stopped
/// from here and UI reads state from this provider.
class ConnectionProvider extends ChangeNotifier {
  final LoggingService _log;
  final WebSocketService _ws;
  final DiscoveryService _discovery;
  final DeviceInfoService _deviceInfo;
  final BrowserLauncherService _browser;
  final ClipboardSyncService _clipboard;
  final TriggerRuleService _triggers;

  bool _isRunning = false;
  int? _port;
  StreamSubscription? _commandSub;
  StreamSubscription<String>? _clipboardSub;

  bool get isRunning => _isRunning;
  int? get port => _port;
  DeviceInfoService get deviceInfo => _deviceInfo;
  WebSocketService get ws => _ws;
  BrowserLauncherService get browser => _browser;

  ConnectionProvider({
    required LoggingService loggingService,
    required WebSocketService webSocketService,
    required DiscoveryService discoveryService,
    required DeviceInfoService deviceInfoService,
    required BrowserLauncherService browserLauncherService,
    required ClipboardSyncService clipboardSyncService,
    required TriggerRuleService triggerRuleService,
  })  : _log = loggingService,
        _ws = webSocketService,
        _discovery = discoveryService,
        _deviceInfo = deviceInfoService,
        _browser = browserLauncherService,
        _clipboard = clipboardSyncService,
        _triggers = triggerRuleService;

  /// Wire all inter-service dependencies and start everything.
  Future<void> startServices() async {
    if (_isRunning) return;
    _log.info('APP', 'Starting services...');

    try {
      // Wire logging into subordinate services
      _ws.setLoggingService(_log);
      _discovery.setLoggingService(_log);
      _browser.setLoggingService(_log);
      _clipboard.setLoggingService(_log);
      _clipboard.setWebSocketService(_ws);
      _clipboard.setDeviceInfoService(_deviceInfo);
      _triggers.setLoggingService(_log);
      _triggers.setWebSocketService(_ws);

      // Detect browsers (desktop only)
      if (PlatformConfig.isDesktop) {
        await _browser.detectBrowsers();
      }

      // 1. Start WebSocket Server
      _port = await _ws.startServer();
      _log.info('APP', 'WebSocket Server started on port $_port');

      // 2. Start mDNS Advertising
      await _discovery.startAdvertising(_port!);
      _log.info('APP', 'mDNS Advertising started');

      // 3. Listen for commands
      _commandSub = _ws.commandStream.listen(_executeCommand);

      // 4. Start clipboard polling
      _clipboard.startPolling();

      // 5. Start trigger rule listening
      _triggers.startListening();

      _isRunning = true;
      notifyListeners();
    } catch (e) {
      _log.error('APP', 'Error starting services: $e');
    }
  }

  Future<void> stopServices() async {
    if (!_isRunning) return;
    _log.info('APP', 'Stopping services...');
    _clipboard.stopPolling();
    await _discovery.stopAdvertising();
    await _ws.stopServer();
    await _commandSub?.cancel();
    await _clipboardSub?.cancel();
    _isRunning = false;
    _port = null;
    notifyListeners();
    _log.info('APP', 'Services stopped');
  }

  /// Route incoming WebSocket commands.
  Future<void> _executeCommand(Map<String, dynamic> command) async {
    // Natural language prompts → forward to extension
    if (command.containsKey('prompt')) {
      await _handlePrompt(command);
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
        _triggers.handleRegisterTriggers(payload ?? {});
        return;
      } else if (command['source'] == 'extension') {
        _handleExtensionMessage(command);
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
            _log.info('CMD', 'Launched $urlString');
          } else {
            _log.warn('CMD', 'Could not launch $urlString');
          }
        }
        break;
      default:
        if (command.containsKey('source') && command['source'] == 'extension') {
          _handleExtensionMessage(command);
        } else {
          _log.debug('CMD', 'Unknown command: $action / ${command['type']}');
        }
    }
  }

  Future<void> _handlePrompt(Map<String, dynamic> command) async {
    final prompt = command['prompt'];
    _log.info('CMD', 'Received prompt: "$prompt"');

    if (!_ws.hasExtensionClient) {
      _log.info('CMD', 'Extension not connected — launching browser...');
      final launched = await _ensureBrowserRunning();
      if (!launched) {
        _log.error('CMD', 'Could not launch browser or extension did not connect');
        return;
      }
    }

    _ws.broadcastEvent({
      'type': 'execute_prompt',
      'payload': command,
      'target': 'extension',
    });
    _log.info('CMD', 'Forwarded prompt to Browser Extension');
  }

  void _handleExtensionMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    switch (type) {
      case 'execution_status':
        _log.info('EXT', '${message['status']}: ${message['message'] ?? ''}');
        break;
      case 'execution_result':
        _log.info('EXT', 'Complete: ${message['status']} (${message['steps_executed']} steps)');
        break;
      case 'kill_switch_ack':
        _log.info('EXT', 'Kill switch acknowledged');
        break;
      case 'rule_triggered':
        _triggers.handleRuleTriggered(message);
        break;
      default:
        _log.debug('EXT', 'Message: $type');
    }
  }

  Future<void> _handleClipboardSync(Map<String, dynamic>? payload) async {
    final text = payload?['text'] as String?;
    if (text == null || text.isEmpty) return;
    await _clipboard.writeFromRemote(text);
  }

  Future<bool> _ensureBrowserRunning() async {
    final launched = await _browser.launchBrowser();
    if (!launched) return false;
    if (_ws.hasExtensionClient) return true;

    _log.info('CMD', 'Waiting for extension to connect (up to 15s)...');
    try {
      await _ws.extensionConnectionStream
          .where((c) => c)
          .first
          .timeout(const Duration(seconds: 15));
      _log.info('CMD', 'Extension connected after browser launch!');
      return true;
    } catch (_) {
      _log.warn('CMD', 'Extension did not connect within 15 seconds');
      return false;
    }
  }

  @override
  void dispose() {
    stopServices();
    super.dispose();
  }
}
