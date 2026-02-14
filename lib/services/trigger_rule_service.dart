import 'dart:async';
import 'logging_service.dart';
import 'websocket_service.dart';

/// Manages trigger rules registered by Android.
/// Stores rules in-memory and forwards them to the browser extension.
/// Relays `rule_triggered` events from extension back to Android.
class TriggerRuleService {
  LoggingService? _loggingService;
  WebSocketService? _webSocketService;
  StreamSubscription<bool>? _extensionSub;

  // In-memory rule storage
  List<Map<String, dynamic>> _rules = [];

  List<Map<String, dynamic>> get rules => List.unmodifiable(_rules);

  void setLoggingService(LoggingService service) {
    _loggingService = service;
  }

  void setWebSocketService(WebSocketService service) {
    _webSocketService = service;
  }

  /// Start listening for extension connection events.
  /// When the extension (re)connects, auto-resend any registered rules.
  void startListening() {
    _extensionSub?.cancel();
    _extensionSub = _webSocketService?.extensionConnectionStream.listen((connected) {
      if (connected) {
        resendRulesToExtension();
      }
    });
  }

  void _log(String message) {
    final logMsg = '[Triggers] $message';
    print(logMsg);
    _loggingService?.log(logMsg);
  }

  /// Handle `register_triggers` from Android.
  /// Stores rules and forwards them to the browser extension.
  void handleRegisterTriggers(Map<String, dynamic> payload) {
    final rulesData = payload['rules'] as List<dynamic>?;
    if (rulesData == null || rulesData.isEmpty) {
      _log('No rules in register_triggers payload');
      return;
    }

    _rules = rulesData.cast<Map<String, dynamic>>();
    _log('Registered ${_rules.length} trigger rule(s):');
    for (final rule in _rules) {
      final id = rule['id'] ?? 'unknown';
      final criteria = rule['criteria'] as Map<String, dynamic>?;
      _log('  Rule $id: ${criteria?['type']} = ${criteria?['value']}');
    }

    // Forward rules to the browser extension
    _forwardRulesToExtension();
  }

  /// Forward current rules to the extension via WebSocket.
  void _forwardRulesToExtension() {
    if (_webSocketService == null) {
      _log('WebSocketService not available, cannot forward rules');
      return;
    }

    _webSocketService!.broadcastEvent({
      'type': 'register_triggers',
      'payload': {
        'rules': _rules,
      },
      'target': 'extension',
    });
    _log('Forwarded ${_rules.length} rules to extension');
  }

  /// Re-send rules to extension (e.g. after extension reconnects).
  void resendRulesToExtension() {
    if (_rules.isEmpty) return;
    _log('Re-sending ${_rules.length} rules to extension (reconnect)');
    _forwardRulesToExtension();
  }

  /// Handle `rule_triggered` from the extension.
  /// Forwards it to Android (all connected clients).
  void handleRuleTriggered(Map<String, dynamic> message) {
    final ruleId = message['payload']?['rule_id'] ?? message['rule_id'];
    if (ruleId == null) {
      _log('rule_triggered with no rule_id, ignoring');
      return;
    }

    _log('Rule triggered: $ruleId — forwarding to Android');

    _webSocketService?.broadcastEvent({
      'type': 'rule_triggered',
      'payload': {
        'rule_id': ruleId,
      },
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
