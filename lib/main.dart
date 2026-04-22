import 'dart:io';
import 'package:flutter/material.dart';
import 'app.dart';
import 'core/config/platform_config.dart';
import 'core/di/service_locator.dart';
import 'core/services/logging_service.dart';
import 'features/connection/providers/connection_provider.dart';
import 'features/system/services/startup_service.dart';
import 'features/system/services/system_tray_service.dart';
import 'features/system/services/window_manager_service.dart';
import 'features/desktop_automation/providers/desktop_automation_provider.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final isStartup = args.contains('--startup');

  // ── 1. Register all services via DI ─────────────────────
  await setupServiceLocator();

  final log = getIt<LoggingService>();
  log.info('APP', 'Autonion Agent starting...');
  log.info('APP', 'Platform: ${PlatformConfig.platformName}');

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

  // ── 3. Auto-start connection services ───────────────────
  final connectionProvider = getIt<ConnectionProvider>();
  await connectionProvider.startServices();

  // ── Auto-start python bridge ────────────────────────────
  if (PlatformConfig.isDesktop) {
    try {
      final desktopAutomationProvider = getIt<DesktopAutomationProvider>();
      // Don't await it so we don't block the UI from showing up
      desktopAutomationProvider.initBridge();
    } catch (e) {
      log.error('APP', 'Failed to auto-init Python bridge: $e');
    }
  }

  // ── 4. Run the app ──────────────────────────────────────
  runApp(const AutonionApp());

  // ── 5. Re-enforce hidden state after Flutter renders ────
  // Flutter's rendering pipeline can briefly flash the window;
  // this ensures it stays hidden when launched via --startup.
  if (isStartup && windowService != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowService!.ensureHiddenIfStartup();
    });
  }
}
