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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 1. Register all services via DI ─────────────────────
  await setupServiceLocator();

  final log = getIt<LoggingService>();
  log.info('APP', 'Autonion Agent starting...');
  log.info('APP', 'Platform: ${PlatformConfig.platformName}');

  // ── 2. Desktop-only: Window manager & System tray ───────
  if (PlatformConfig.isDesktop) {
    // Window manager (intercepts close → hide to tray)
    final windowService = getIt<WindowManagerService>();
    windowService.setLoggingService(log);
    await windowService.init();

    // System tray
    final trayService = getIt<SystemTrayService>();
    trayService.setLoggingService(log);
    trayService.setCallbacks(
      onShowWindow: () => windowService.show(),
      onQuit: () async {
        // Stop all services before quitting
        await getIt<ConnectionProvider>().stopServices();
        await windowService.forceClose();
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

  // ── 4. Run the app ──────────────────────────────────────
  runApp(const AutonionApp());
}
