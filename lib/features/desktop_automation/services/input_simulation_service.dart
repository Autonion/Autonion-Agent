import '../../../core/services/logging_service.dart';
import '../models/desktop_action.dart';
import 'python_bridge_service.dart';

class InputSimulationService {
  final LoggingService _log;
  final PythonBridgeService _bridge;

  InputSimulationService({
    required LoggingService log,
    required PythonBridgeService bridge,
  }) : _log = log,
       _bridge = bridge;

  Future<Map<String, dynamic>> execute(DesktopAction action) async {
    _log.info('InputService', 'Executing action: ${action.type}');

    final result = await _bridge.sendCommand('execute_action', {
      'type': action.type,
      'targetIndex': action.targetIndex,
      'targetStableId': action.targetStableId,
      'endTargetIndex': action.endTargetIndex,
      'endTargetStableId': action.endTargetStableId,
      'x': action.x,
      'y': action.y,
      'endX': action.endX,
      'endY': action.endY,
      'path': action.path,
      'text': action.text,
      'appName': action.appName,
      'appPath': action.appPath,
      'direction': action.direction,
      'amount': action.amount,
      'keys': action.keys,
      'durationMs': action.durationMs,
      'button': action.button,
    });

    if (result is Map<String, dynamic>) {
      return result;
    }
    return {'status': 'executed', 'raw': result};
  }
}
