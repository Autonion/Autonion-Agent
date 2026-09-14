import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'app.dart';
import 'core/config/platform_config.dart';
import 'core/di/service_locator.dart';
import 'core/services/logging_service.dart';
import 'features/connection/providers/connection_provider.dart';
import 'features/connection/services/device_info_service.dart';
import 'features/system/services/startup_service.dart';
import 'features/system/services/system_tray_service.dart';
import 'features/system/services/update_service.dart';
import 'features/system/services/window_manager_service.dart';
import 'features/desktop_automation/providers/desktop_automation_provider.dart';
import 'features/desktop_automation/services/secure_credential_service.dart';
import 'features/desktop_automation/services/flow_storage_service.dart';
import 'features/desktop_automation/services/unlock_service_pipe.dart';
import 'features/desktop_automation/services/unlock_admin_service.dart';
import 'features/desktop_automation/models/desktop_flow_models.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final isStartup = args.contains('--startup');

  // ── 1. Register all services via DI ─────────────────────
  await setupServiceLocator();

  final log = getIt<LoggingService>();
  log.info('APP', 'Autonion Agent starting...');
  log.info('APP', 'Platform: ${PlatformConfig.platformName}');

  // If launched with Administrator privileges on Windows, ensure the
  // unlock helper service and firewall rules are installed and running.
  if (PlatformConfig.isDesktop && Platform.isWindows) {
    final unlockAdmin = getIt<UnlockAdminService>();
    if (unlockAdmin.isRunningAsAdmin()) {
      log.info('APP', 'Running with Administrator privileges.');
      final isConfigured = await unlockAdmin.isUnlockServiceConfigured();
      if (!isConfigured) {
        log.info('APP', 'Elevated run: configuring Autonion Unlock Helper service...');
        final ok = await unlockAdmin.setupUnlockService();
        if (ok) {
          log.info('APP', 'Autonion Unlock Helper service configured successfully.');
        } else {
          log.warn('APP', 'Autonion Unlock Helper service auto-configuration failed.');
        }
      }
    }
  }

  // ── 2. Desktop-only: Window manager & System tray ───────
  WindowManagerService? windowService;
  if (PlatformConfig.isDesktop) {
    // Window manager (intercepts close → hide to tray)
    windowService = getIt<WindowManagerService>();
    windowService.setLoggingService(log);
    await windowService.init(isStartup: isStartup);

    // System tray
    final trayService = getIt<SystemTrayService>();
    trayService.setLoggingService(log);
    trayService.setCallbacks(
      onShowWindow: () => windowService!.show(),
      onQuit: () async {
        // Stop all services before quitting
        await getIt<ConnectionProvider>().stopServices();
        await windowService!.forceClose();
        exit(0);
      },
    );
    await trayService.init();

    // Launch-at-startup
    final startupService = getIt<StartupService>();
    startupService.setLoggingService(log);
    await startupService.init();
  }

  // ── 3. Start connections immediately; defer only heavy Python startup ──
  final connectionProvider = getIt<ConnectionProvider>();
  await connectionProvider.startServices();

  if (PlatformConfig.isDesktop) {
    unawaited(_syncPreloginUnlockFlowsDirect(log));
    if (isStartup) {
      Future.delayed(const Duration(seconds: 8), () => _initDesktopBridge(log));
    } else {
      unawaited(_initDesktopBridge(log));
    }
  }

  // ── 4. Run the app ──────────────────────────────────────
  runApp(AutonionApp(args: args));

  // ── 5. Check for updates (non-blocking) ─────────────────
  final updateService = getIt<UpdateService>();
  updateService.setLoggingService(log);
  updateService.checkForUpdate();

  // ── 6. Re-enforce hidden state after Flutter renders ────
  // Flutter's rendering pipeline can briefly flash the window;
  // this ensures it stays hidden when launched via --startup.
  if (isStartup && windowService != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowService!.ensureHiddenIfStartup();
    });
  }
}

/// Init the Python bridge for desktop automation features (screenshots,
/// accessibility tree, etc.). This is independent of flow provisioning.
Future<void> _initDesktopBridge(LoggingService log) async {
  try {
    final desktopAutomationProvider = getIt<DesktopAutomationProvider>();
    await desktopAutomationProvider.initBridge();
    if (!desktopAutomationProvider.isBridgeReady) {
      log.warn('APP', 'Python bridge is not ready');
    }
  } catch (e) {
    log.error('APP', 'Failed to auto-init Python bridge: $e');
  }
}

/// Sync unlock flows directly to the AutonionUnlockHelper service via
/// named pipe. This bypasses the Python bridge entirely — no venv, no
/// pip install, no subprocess — so it works reliably on every startup.
Future<void> _syncPreloginUnlockFlowsDirect(LoggingService log) async {
  if (!Platform.isWindows || !PlatformConfig.isDesktop) return;

  final pipe = getIt<UnlockServicePipe>();
  final storage = getIt<FlowStorageService>();
  final credentials = getIt<SecureCredentialService>();
  final deviceInfo = getIt<DeviceInfoService>();

  try {
    // Check if the service pipe is reachable (retry up to 3 times if initializing)
    var available = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (await pipe.isServiceAvailable()) {
        available = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 1500));
    }

    if (!available) {
      log.warn(
        'APP',
        'Pre-login unlock sync skipped: '
            'AutonionUnlockHelper service pipe not available after retries',
      );
      return;
    }

    // Provision device identity so mDNS uses the right name.
    await pipe.provisionIdentity(
      deviceId: deviceInfo.deviceId,
      deviceName: deviceInfo.deviceName,
    );

    final flows = await storage.listFlows();
    var provisioned = 0;
    var skipped = 0;
    var failed = 0;

    for (final flow in flows) {
      final unlockNodes = flow.nodes
          .where((node) => node.nodeType == DesktopFlowNodeType.unlock)
          .toList(growable: false);
      if (unlockNodes.isEmpty) continue;

      var provisionedFlow = false;
      for (final node in unlockNodes) {
        final password = await credentials.getUnlockPassword(node.id);
        if (password == null || password.isEmpty) continue;

        try {
          final ok = await pipe.provisionUnlockCredential(
            flowId: flow.id,
            flowName: flow.name,
            nodeId: node.id,
            password: password,
          );
          if (ok) {
            provisioned++;
            provisionedFlow = true;
          } else {
            failed++;
          }
        } catch (e) {
          failed++;
          log.warn(
            'APP',
            'Failed to sync pre-login unlock for flow "${flow.name}": $e',
          );
        }
        break; // Only provision the first unlock node per flow.
      }

      if (!provisionedFlow) {
        skipped++;
      }
    }

    log.info(
      'APP',
      'Pre-login unlock sync finished: $provisioned provisioned, '
          '$skipped missing password, $failed failed',
    );
  } catch (e) {
    log.warn('APP', 'Pre-login unlock sync failed: $e');
  }
}
