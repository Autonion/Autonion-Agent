import 'package:flutter/foundation.dart';
import '../../../core/services/logging_service.dart';
import '../models/automation_tier.dart';
import '../services/desktop_agent_service.dart';
import '../services/python_bridge_service.dart';
import '../services/agent_run.dart';
import '../../ai/services/ai_service.dart';

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
        return _agent.lastError ?? 'Error';
    }
  }

  bool _running = false;
  bool _cancelRequested = false;
  bool get isRunning => _running || _agent.status == AgentStatus.running;
  bool get isComplete =>
      !_cancelRequested && _agent.status == AgentStatus.complete;
  bool get isBridgeReady => _bridge.isReady;
  bool get hasError => _agent.status == AgentStatus.error;
  String? get lastError => _agent.lastError;

  /// The action history from the most recent task execution.
  List<Map<String, dynamic>> get lastActionHistory => _agent.actionHistory;

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

  Future<void> runGoal(
    String goal, {
    void Function(String)? onProgress,
    String? conversationContext,
    bool allowBrowser = true,
    AgentRun? run,
    Future<AiService> Function()? resolveAi,
  }) async {
    if (isRunning) throw StateError('Another desktop task is still running.');
    _running = true;
    _cancelRequested = false;
    notifyListeners();
    try {
      final initialization = _bridge.init();
      await (run?.wait<void>(initialization) ?? initialization);
      run?.check();
      if (_cancelRequested) throw AgentCancelledException();
      if (!isBridgeReady) {
        throw PythonBridgeException('Python bridge is not ready.');
      }
      await _agent.runTask(
        goal,
        tier: _tier,
        onProgress: onProgress,
        conversationContext: conversationContext,
        allowBrowser: allowBrowser,
        run: run,
        resolveAi: resolveAi,
      );
      if (_cancelRequested) throw AgentCancelledException();
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  void stop() {
    _cancelRequested = true;
    _agent.stop();
    // Interrupt the worker as well as the model loop; queued input must not
    // survive cancellation and execute during the next task.
    _bridge.stop();
    notifyListeners();
  }
}
