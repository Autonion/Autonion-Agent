import 'package:flutter_test/flutter_test.dart';
import 'package:autonion_cross_device/core/services/logging_service.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/unlock_service_pipe.dart';

void main() {
  test('test provisioning credential and identity directly via pipe', () async {
    final log = LoggingService();
    final pipe = UnlockServicePipe(log: log);
    
    final idRes = await pipe.provisionIdentity(
      deviceId: 'Guru-Device',
      deviceName: 'Guru',
    );
    print('provisionIdentity result: $idRes');

    final res = await pipe.provisionUnlockCredential(
      flowId: 'a2da41c6-3767-42da-9676-cb5b02a97500',
      flowName: 'unlock',
      nodeId: 'node_123',
      password: 'test_password',
    );
    print('provisionUnlockCredential result: $res');
  });
}
