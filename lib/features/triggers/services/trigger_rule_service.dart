import 'dart:async';
import '../../../core/services/logging_service.dart';
import '../../connection/services/websocket_service.dart';

/// Manages trigger rules registered by Android.
/// Stores rules in-memory and forwards them to the browser extension.
/// Relays `rule_triggered` events from extension back to Android.
class TriggerRuleService {
  LoggingService? _loggingService;
  WebSocketService? _webSocketService;
  StreamSubscription<bool>? _extensionSub;

  List<Map<String, dynamic>> _rules = [];
  List<Map<String, dynamic>> get rules => List.unmodifiable(_rules);

  void setLoggingService(LoggingService service) => _loggingService = service;
  void setWebSocketService(WebSocketService service) =>
      _webSocketService = service;

  void _log(String message) => _loggingService?.info('Triggers', message);

  void startListening() {
    _extensionSub?.cancel();
    _extensionSub = _webSocketService?.extensionConnectionStream.listen((
      connected,
    ) {
      if (connected) resendRulesToExtension();
    });
  }

  void handleRegisterTriggers(Map<String, dynamic> payload) {
    final rulesData = payload['rules'] as List<dynamic>?;
    if (rulesData == null || rulesData.isEmpty) {
      _log('No rules in payload');
      return;
    }
    _rules = rulesData.cast<Map<String, dynamic>>();
    _log('Registered ${_rules.length} trigger rule(s)');
    _forwardRulesToExtension();
  }

  void _forwardRulesToExtension() {
    _webSocketService?.broadcastEvent({
      'type': 'register_triggers',
      'payload': {'rules': _rules},
      'target': 'extension',
    });
    _log('Forwarded ${_rules.length} rules to extension');
  }

  void resendRulesToExtension() {
    if (_rules.isEmpty) return;
    _log('Re-sending ${_rules.length} rules (reconnect)');
    _forwardRulesToExtension();
  }

  void handleRuleTriggered(Map<String, dynamic> message) {
    final ruleId = message['payload']?['rule_id'] ?? message['rule_id'];
    if (ruleId == null) return;
    _log('Rule triggered: $ruleId — forwarding to Android');
    _webSocketService?.broadcastEvent({
      'type': 'rule_triggered',
      'payload': {'rule_id': ruleId},
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void dispose() {
    _extensionSub?.cancel();
  }
}
