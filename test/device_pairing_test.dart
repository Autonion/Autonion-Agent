import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:autonion_cross_device/core/services/logging_service.dart';
import 'package:autonion_cross_device/features/connection/models/paired_device.dart';
import 'package:autonion_cross_device/features/connection/services/paired_device_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('PairedDevice model tests', () {
    test('serializes and deserializes correctly', () {
      final now = DateTime.now();
      final device = PairedDevice(
        id: 'dev-1234',
        name: "Guru's Pixel 8",
        secret: 'sec_test_token_abc_123',
        pairedAt: now,
        lastSeen: now,
        lastIp: '192.168.1.50',
      );

      final jsonStr = device.toJson();
      final decoded = PairedDevice.fromJson(jsonStr);

      expect(decoded.id, 'dev-1234');
      expect(decoded.name, "Guru's Pixel 8");
      expect(decoded.secret, 'sec_test_token_abc_123');
      expect(decoded.lastIp, '192.168.1.50');
    });

    test('copyWith works properly', () {
      final now = DateTime.now();
      final device = PairedDevice(
        id: 'dev-1',
        name: 'Device 1',
        secret: 'token1',
        pairedAt: now,
        lastSeen: now,
      );

      final updated = device.copyWith(
        name: 'Renamed Device',
        lastIp: '10.0.0.1',
      );
      expect(updated.id, 'dev-1');
      expect(updated.name, 'Renamed Device');
      expect(updated.secret, 'token1');
      expect(updated.lastIp, '10.0.0.1');
    });
  });

  group('PairedDeviceService logic tests', () {
    test('pair, verify, and revoke device', () async {
      final log = LoggingService();
      final service = PairedDeviceService(log: log);
      await service.init();

      final device = PairedDevice(
        id: 'phone-test-id',
        name: 'Test Phone',
        secret: 'super_secure_secret_token_123',
        pairedAt: DateTime.now(),
        lastSeen: DateTime.now(),
      );

      await service.pairDevice(device);

      final isPaired = await service.isDevicePaired(
        'phone-test-id',
        'super_secure_secret_token_123',
      );
      expect(isPaired, isTrue);

      final isWrongSecret = await service.isDevicePaired(
        'phone-test-id',
        'wrong_token',
      );
      expect(isWrongSecret, isFalse);

      final isUnknownDevice = await service.isDevicePaired(
        'unknown-id',
        'token',
      );
      expect(isUnknownDevice, isFalse);

      await service.revokeDevice('phone-test-id');
      final isStillPaired = await service.isDevicePaired(
        'phone-test-id',
        'super_secure_secret_token_123',
      );
      expect(isStillPaired, isFalse);
    });
  });
}
