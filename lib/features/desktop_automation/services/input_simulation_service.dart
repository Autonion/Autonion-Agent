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

  Future<void> execute(DesktopAction action) async {
    _log.info('InputService', 'Executing action: ${action.type}');

    await _bridge.sendCommand('execute_action', {
      'type': action.type,
      'targetIndex': action.targetIndex,
      'text': action.text,
      'direction': action.direction,
      'keys': action.keys,
    });
  }
}
