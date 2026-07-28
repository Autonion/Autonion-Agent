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
  Future<ScreenState> getScreenState(
    AutomationTier tier, {
    bool preferLastLaunchedApp = false,
    String? preferredAppName,
    String? preferredAppPath,
  }) async {
    _log.debug('A11yService', 'Requesting screen state (tier: ${tier.name})');

    final payload = <String, dynamic>{
      'tier': tier.name,
      if (preferLastLaunchedApp) 'preferLastLaunchedApp': true,
      if (preferredAppName != null && preferredAppName.isNotEmpty)
        'preferredAppName': preferredAppName,
      if (preferredAppPath != null && preferredAppPath.isNotEmpty)
        'preferredAppPath': preferredAppPath,
    };

    final response = await _bridge.sendCommand('get_screen_state', payload);

    return ScreenState.fromJson(response);
  }
}
