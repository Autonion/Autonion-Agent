import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

import '../../../core/services/logging_service.dart';
import 'unlock_service_pipe.dart';

// ── Win32 FFI Signatures (shell32.dll) ──────────────────────
final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');

typedef _IsUserAnAdmin_C = Int32 Function();
typedef _IsUserAnAdmin_Dart = int Function();
final _isUserAnAdmin =
    _shell32.lookupFunction<_IsUserAnAdmin_C, _IsUserAnAdmin_Dart>(
      'IsUserAnAdmin',
    );

typedef _ShellExecuteW_C =
    IntPtr Function(
      IntPtr hwnd,
      Pointer<Utf16> lpOperation,
      Pointer<Utf16> lpFile,
      Pointer<Utf16> lpParameters,
      Pointer<Utf16> lpDirectory,
      Int32 nShowCmd,
    );
typedef _ShellExecuteW_Dart =
    int Function(
      int hwnd,
      Pointer<Utf16> lpOperation,
      Pointer<Utf16> lpFile,
      Pointer<Utf16> lpParameters,
      Pointer<Utf16> lpDirectory,
      int nShowCmd,
    );
final _shellExecuteW =
    _shell32.lookupFunction<_ShellExecuteW_C, _ShellExecuteW_Dart>(
      'ShellExecuteW',
    );

/// Service for managing Administrator privileges, Windows Service installation,
/// and self-elevation for the Autonion Unlock Helper.
class UnlockAdminService {
  static const _tag = 'UnlockAdminService';

  final UnlockServicePipe _pipe;
  final LoggingService _log;

  UnlockAdminService({
    required UnlockServicePipe pipe,
    required LoggingService log,
  })  : _pipe = pipe,
        _log = log;

  /// Check whether the current application process has Administrator privileges.
  bool isRunningAsAdmin() {
    if (!Platform.isWindows) return false;
    try {
      return _isUserAnAdmin() != 0;
    } catch (e) {
      _log.warn(_tag, 'Failed to check admin status: $e');
      return false;
    }
  }

  /// Check whether the Autonion Unlock Helper service is installed and ready.
  ///
  /// Returns `true` if the service pipe is responding or the Windows Service
  /// is currently in a running state.
  Future<bool> isUnlockServiceConfigured() async {
    if (!Platform.isWindows) return false;

    // 1. Direct pipe check (fastest and most accurate)
    try {
      final pipeOk = await _pipe.isServiceAvailable();
      if (pipeOk) return true;
    } catch (_) {}

    // 2. Query Windows Service Control Manager via sc.exe
    try {
      final result = await Process.run(
        'sc.exe',
        ['query', 'AutonionUnlockHelper'],
        runInShell: true,
      );
      if (result.exitCode == 0) {
        final stdout = result.stdout.toString().toUpperCase();
        if (stdout.contains('RUNNING') || stdout.contains('START_PENDING')) {
          return true;
        }
      }
    } catch (e) {
      _log.warn(_tag, 'sc.exe query failed: $e');
    }

    return false;
  }

  /// Locate `autonion_unlock_helper.exe` on disk across production and development paths.
  File? findUnlockHelperExe() {
    final candidates = <String>[];

    // 1. Same directory as current executable (packaged/installed layout)
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add(path.join(exeDir, 'autonion_unlock_helper.exe'));

    // 2. Standard Program Files installation path
    candidates.add(
      r'C:\Program Files\Autonion Agent\autonion_unlock_helper.exe',
    );

    // 3. Development / build directories
    final currentDir = Directory.current.path;
    candidates.add(
      path.join(
        currentDir,
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
        'autonion_unlock_helper.exe',
      ),
    );
    candidates.add(
      path.join(
        currentDir,
        'build',
        'windows',
        'x64',
        'runner',
        'Debug',
        'autonion_unlock_helper.exe',
      ),
    );
    candidates.add(
      path.join(
        currentDir,
        'build',
        'windows',
        'x64',
        'unlock_helper',
        'Release',
        'autonion_unlock_helper.exe',
      ),
    );
    candidates.add(
      path.join(
        currentDir,
        'build',
        'windows',
        'x64',
        'unlock_helper',
        'Debug',
        'autonion_unlock_helper.exe',
      ),
    );
    candidates.add(
      path.join(
        currentDir,
        'build',
        'manual_unlock_helper',
        'autonion_unlock_helper.exe',
      ),
    );
    candidates.add(path.join(currentDir, 'autonion_unlock_helper.exe'));

    for (final candidatePath in candidates) {
      final file = File(candidatePath);
      if (file.existsSync()) {
        return file;
      }
    }

    return null;
  }

  /// Install and start the Autonion Unlock Helper Windows Service.
  ///
  /// Requires Administrator privileges. Installs the service under LocalSystem,
  /// sets up firewall rules for TCP 4545 and UDP 5353, and starts the service.
  Future<bool> setupUnlockService() async {
    if (!Platform.isWindows) return false;

    if (!isRunningAsAdmin()) {
      _log.warn(_tag, 'setupUnlockService called without admin privileges');
      return false;
    }

    final helperExe = findUnlockHelperExe();
    if (helperExe == null) {
      _log.error(_tag, 'autonion_unlock_helper.exe not found on system');
      return false;
    }

    _log.info(_tag, 'Installing unlock helper service via: ${helperExe.path}');
    try {
      final result = await Process.run(
        helperExe.path,
        ['--install-service'],
        runInShell: false,
      );

      if (result.exitCode != 0) {
        _log.error(
          _tag,
          '--install-service failed with code ${result.exitCode}: '
          '${result.stderr.toString().trim()}',
        );
        return false;
      }

      _log.info(_tag, 'Service installed. Verifying named pipe readiness...');

      // Wait up to 5 seconds for the service to start listening on the named pipe
      for (var attempt = 0; attempt < 5; attempt++) {
        await Future.delayed(const Duration(milliseconds: 1000));
        if (await _pipe.isServiceAvailable()) {
          _log.info(_tag, 'Autonion Unlock Helper service is ready and verified.');
          return true;
        }
      }

      // Check if service is at least running in SCM
      final isConfigured = await isUnlockServiceConfigured();
      if (isConfigured) {
        _log.info(_tag, 'Service is running in SCM.');
        return true;
      }

      _log.warn(_tag, 'Service installed but pipe not reachable yet.');
      return true;
    } catch (e) {
      _log.error(_tag, 'Failed to execute unlock helper service setup: $e');
      return false;
    }
  }

  /// Restarts the application with elevated Administrator privileges using Windows UAC (`runas`).
  ///
  /// If the user accepts the UAC prompt and the elevated process launches,
  /// this function cleanly exits the current process. Returns `false` if UAC was declined.
  Future<bool> restartAsAdmin({List<String>? arguments}) async {
    if (!Platform.isWindows) return false;

    final exePath = Platform.resolvedExecutable;
    final argsList = arguments ?? ['--open-flows'];
    final argsString = argsList.map((a) => '"$a"').join(' ');

    _log.info(_tag, 'Requesting elevation for: $exePath $argsString');

    final opPtr = 'runas'.toNativeUtf16();
    final filePtr = exePath.toNativeUtf16();
    final paramsPtr = argsString.toNativeUtf16();
    final dirPtr = Directory.current.path.toNativeUtf16();

    try {
      // 1 = SW_SHOWNORMAL
      final result = _shellExecuteW(
        0,
        opPtr,
        filePtr,
        paramsPtr,
        dirPtr,
        1,
      );

      // Return values > 32 indicate success in Win32 ShellExecute
      if (result > 32) {
        _log.info(_tag, 'Elevated process launched successfully. Exiting non-admin instance.');
        exit(0);
      } else {
        _log.warn(_tag, 'ShellExecuteW failed or was cancelled by user (result code: $result)');
        return false;
      }
    } catch (e) {
      _log.error(_tag, 'ShellExecuteW elevation error: $e');
      return false;
    } finally {
      calloc.free(opPtr);
      calloc.free(filePtr);
      calloc.free(paramsPtr);
      calloc.free(dirPtr);
    }
  }

  /// Locate the Inno Setup uninstaller `unins000.exe` if installed.
  File? findUninstallerExe() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidate1 = File(path.join(exeDir, 'unins000.exe'));
    if (candidate1.existsSync()) return candidate1;

    final candidate2 = File(r'C:\Program Files\Autonion Agent\unins000.exe');
    if (candidate2.existsSync()) return candidate2;

    return null;
  }

  /// Uninstall the Autonion Unlock Helper service and remove its firewall rules.
  Future<bool> uninstallUnlockService() async {
    if (!Platform.isWindows) return false;

    final helperExe = findUnlockHelperExe();
    if (helperExe == null) {
      _log.warn(_tag, 'autonion_unlock_helper.exe not found on system');
      return false;
    }

    _log.info(_tag, 'Uninstalling unlock helper service via: ${helperExe.path}');
    try {
      if (isRunningAsAdmin()) {
        final result = await Process.run(
          helperExe.path,
          ['--uninstall-service'],
          runInShell: false,
        );
        return result.exitCode == 0;
      } else {
        // Request elevation to run --uninstall-service
        final opPtr = 'runas'.toNativeUtf16();
        final filePtr = helperExe.path.toNativeUtf16();
        final paramsPtr = '--uninstall-service'.toNativeUtf16();
        final dirPtr = helperExe.parent.path.toNativeUtf16();
        try {
          final result = _shellExecuteW(
            0,
            opPtr,
            filePtr,
            paramsPtr,
            dirPtr,
            0, // 0 = SW_HIDE
          );
          return result > 32;
        } finally {
          calloc.free(opPtr);
          calloc.free(filePtr);
          calloc.free(paramsPtr);
          calloc.free(dirPtr);
        }
      }
    } catch (e) {
      _log.error(_tag, 'Failed to uninstall unlock helper service: $e');
      return false;
    }
  }

  /// Launch the application uninstaller or clean up background services.
  Future<bool> launchAppUninstaller() async {
    if (!Platform.isWindows) return false;

    final uninstaller = findUninstallerExe();
    if (uninstaller != null) {
      _log.info(_tag, 'Launching uninstaller: ${uninstaller.path}');
      final opPtr = 'open'.toNativeUtf16();
      final filePtr = uninstaller.path.toNativeUtf16();
      final paramsPtr = ''.toNativeUtf16();
      final dirPtr = uninstaller.parent.path.toNativeUtf16();
      try {
        final result = _shellExecuteW(0, opPtr, filePtr, paramsPtr, dirPtr, 1);
        if (result > 32) {
          exit(0);
        }
        return false;
      } finally {
        calloc.free(opPtr);
        calloc.free(filePtr);
        calloc.free(paramsPtr);
        calloc.free(dirPtr);
      }
    } else {
      // Fallback for dev / portable builds: remove service and open Windows Programs & Features
      await uninstallUnlockService();
      try {
        await Process.run('control.exe', ['appwiz.cpl'], runInShell: true);
      } catch (_) {}
      return true;
    }
  }
}
