import 'dart:async';
import '../../../core/services/logging_service.dart';
import '../../connection/services/websocket_service.dart';

/// Manages trigger rules registered by Android.
/// Stores rules in-memory and forwards them to the browser extension.
/// Relays `rule_triggered` events from extension back to Android.
class TriggerRuleService {
  static const String _globalRulesKey = '__global__';

  LoggingService? _loggingService;
  WebSocketService? _webSocketService;
  StreamSubscription<bool>? _extensionSub;

  final Map<String, List<Map<String, dynamic>>> _rulesByDevice = {};
  List<Map<String, dynamic>> get rules =>
      List.unmodifiable(_rulesByDevice.values.expand((rules) => rules));

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

  void handleRegisterTriggers(
    Map<String, dynamic> payload, {
    String? ownerDeviceId,
  }) {
    final rulesData = payload['rules'] as List<dynamic>?;
    final ownerKey = ownerDeviceId?.isNotEmpty == true
        ? ownerDeviceId!
        : _globalRulesKey;
    if (rulesData == null) {
      _log('No rules in payload');
      return;
    }

    if (rulesData.isEmpty) {
      _rulesByDevice.remove(ownerKey);
      _log('Cleared trigger rules for $ownerKey');
      _forwardRulesToExtension();
      return;
    }

    _rulesByDevice[ownerKey] = rulesData
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    _log(
      'Registered ${_rulesByDevice[ownerKey]!.length} trigger rule(s) for $ownerKey',
    );
    _forwardRulesToExtension();
  }

  void clearRulesForDevice(String deviceId) {
    if (_rulesByDevice.remove(deviceId) != null) {
      _log('Cleared trigger rules for revoked device $deviceId');
      _forwardRulesToExtension();
    }
  }

  void _forwardRulesToExtension() {
    final currentRules = rules;
    _webSocketService?.sendToExtension({
      'type': 'register_triggers',
      'payload': {'rules': currentRules},
      'target': 'extension',
    });
    _log('Forwarded ${currentRules.length} rules to extension');
  }

  void resendRulesToExtension() {
    if (rules.isEmpty) return;
    _log('Re-sending ${rules.length} rules (reconnect)');
    _forwardRulesToExtension();
  }

  void handleRuleTriggered(Map<String, dynamic> message) {
    final ruleId = message['payload']?['rule_id'] ?? message['rule_id'];
    if (ruleId == null) return;

    String? ownerKey;
    for (final entry in _rulesByDevice.entries) {
      if (entry.value.any(
        (rule) => rule['id']?.toString() == ruleId.toString(),
      )) {
        ownerKey = entry.key;
        break;
      }
    }

    if (ownerKey == null) {
      _log('Ignoring trigger for unknown or revoked rule: $ruleId');
      return;
    }

    final event = {
      'type': 'rule_triggered',
      'payload': {'rule_id': ruleId},
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    if (ownerKey == _globalRulesKey) {
      _log('Rule triggered: $ruleId — forwarding to all Android clients');
      _webSocketService?.broadcastEvent(event);
      return;
    }

    final sessions = _webSocketService?.getSessionsByDeviceId(ownerKey) ?? [];
    _log(
      'Rule triggered: $ruleId — forwarding to ${sessions.length} owner session(s)',
    );
    for (final session in sessions) {
      _webSocketService?.sendToClient(session.socket, event);
    }
  }

  void dispose() {
    _extensionSub?.cancel();
  }
}
