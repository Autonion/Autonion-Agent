import 'package:flutter/foundation.dart';
import '../../../core/services/logging_service.dart';
import '../models/automation_tier.dart';
import '../services/desktop_agent_service.dart';
import '../services/python_bridge_service.dart';

/// Provider for managing desktop automation state.
class DesktopAutomationProvider extends ChangeNotifier {
  final LoggingService _log;
  final PythonBridgeService _bridge;
  final DesktopAgentService _agent;

  DesktopAutomationProvider({
    required LoggingService log,
    required PythonBridgeService bridge,
    required DesktopAgentService agent,
  }) : _log = log,
       _bridge = bridge,
       _agent = agent;

  AutomationTier _tier = AutomationTier.accessibilityOnly;
  AutomationTier get tier => _tier;

  String get statusText {
    if (!_bridge.isReady) return 'Bridge Not Ready';
    switch (_agent.status) {
      case AgentStatus.idle:
        return 'Idle';
      case AgentStatus.running:
        return 'Running...';
      case AgentStatus.complete:
        return 'Completed';
      case AgentStatus.error:
        return 'Error';
    }
  }

  bool get isRunning => _agent.status == AgentStatus.running;
  bool get isBridgeReady => _bridge.isReady;
  PythonBridgeService get bridge => _bridge;

  void setTier(AutomationTier t) {
    _tier = t;
    notifyListeners();
  }

  Future<void> initBridge() async {
    try {
      await _bridge.init();
      notifyListeners();
    } catch (e) {
      _log.error('AutomationProvider', 'Failed to init bridge: $e');
      notifyListeners();
    }
  }

  Future<void> runGoal(String goal, {void Function(String)? onProgress}) async {
    if (!isBridgeReady) {
      await initBridge();
      if (!isBridgeReady) return;
    }

    notifyListeners(); // status -> running
    await _agent.runTask(goal, tier: _tier, onProgress: onProgress);
    notifyListeners(); // status -> completed/error
  }

  void stop() {
    _agent.stop();
    notifyListeners();
  }
}
