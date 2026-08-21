import 'package:flutter_test/flutter_test.dart';
import 'package:autonion_cross_device/core/services/logging_service.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/unlock_service_pipe.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/unlock_admin_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LoggingService log;
  late UnlockServicePipe pipe;
  late UnlockAdminService adminService;

  setUp(() {
    log = LoggingService();
    pipe = UnlockServicePipe(log: log);
    adminService = UnlockAdminService(pipe: pipe, log: log);
  });

  group('UnlockAdminService tests', () {
    test('isRunningAsAdmin returns a boolean on Windows', () {
      final isAdmin = adminService.isRunningAsAdmin();
      expect(isAdmin, isA<bool>());
    });

    test('findUnlockHelperExe locates helper executable if present', () {
      final exe = adminService.findUnlockHelperExe();
      // On Windows build environment, it should either find an exe or return null
      if (exe != null) {
        expect(exe.existsSync(), isTrue);
      }
    });

    test('findUninstallerExe returns File or null safely', () {
      final uninstaller = adminService.findUninstallerExe();
      if (uninstaller != null) {
        expect(uninstaller.existsSync(), isTrue);
      }
    });

    test('isUnlockServiceConfigured returns a boolean', () async {
      final isConfigured = await adminService.isUnlockServiceConfigured();
      expect(isConfigured, isA<bool>());
    });
  });
}
