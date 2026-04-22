import '../../../core/services/logging_service.dart';
import '../models/automation_tier.dart';
import '../models/screen_state.dart';
import 'python_bridge_service.dart';

class AccessibilityTreeService {
  final LoggingService _log;
  final PythonBridgeService _bridge;

  AccessibilityTreeService({
    required LoggingService log,
    required PythonBridgeService bridge,
  }) : _log = log,
       _bridge = bridge;

  /// Retrieves the current screen state (tree + optional screenshot)
  Future<ScreenState> getScreenState(AutomationTier tier) async {
    _log.debug('A11yService', 'Requesting screen state (tier: ${tier.name})');

    final response = await _bridge.sendCommand('get_screen_state', {
      'tier': tier.name,
    });

    return ScreenState.fromJson(response);
  }
}
