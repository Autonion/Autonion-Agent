import 'package:get_it/get_it.dart';
import '../../core/config/platform_config.dart';
import '../../core/services/logging_service.dart';
import '../../features/ai/providers/ai_provider_notifier.dart';
import '../../features/browser_automation/services/browser_launcher_service.dart';
import '../../features/clipboard/services/clipboard_sync_service.dart';
import '../../features/connection/providers/connection_provider.dart';
import '../../features/connection/services/device_info_service.dart';
import '../../features/connection/services/discovery_service.dart';
import '../../features/connection/services/websocket_service.dart';
import '../../features/desktop_automation/providers/desktop_automation_provider.dart';
import '../../features/desktop_automation/services/accessibility_tree_service.dart';
import '../../features/desktop_automation/services/desktop_agent_service.dart';
import '../../features/desktop_automation/services/input_simulation_service.dart';
import '../../features/desktop_automation/services/python_bridge_service.dart';
import '../../features/system/services/startup_service.dart';
import '../../features/system/services/system_tray_service.dart';
import '../../features/system/services/window_manager_service.dart';
import '../../features/triggers/services/trigger_rule_service.dart';

final getIt = GetIt.instance;

/// Registers all services via GetIt for dependency injection.
///
/// Call [setupServiceLocator] once from `main()` after
/// `WidgetsFlutterBinding.ensureInitialized()`.
Future<void> setupServiceLocator() async {
  // ── Core (always registered) ────────────────────────────
  getIt.registerLazySingleton<LoggingService>(() => LoggingService());
  final log = getIt<LoggingService>();

  // ── Connection (always active) ──────────────────────────
  final deviceInfo = DeviceInfoService();
  await deviceInfo.init();
  getIt.registerSingleton<DeviceInfoService>(deviceInfo);

  getIt.registerLazySingleton<WebSocketService>(() => WebSocketService());
  getIt.registerLazySingleton<DiscoveryService>(
    () => DiscoveryService(getIt<DeviceInfoService>()),
  );
  getIt.registerLazySingleton<ClipboardSyncService>(
    () => ClipboardSyncService(),
  );
  getIt.registerLazySingleton<TriggerRuleService>(() => TriggerRuleService());

  // ── Browser Automation (desktop-only instances, but registered always for DI) ─
  getIt.registerLazySingleton<BrowserLauncherService>(
    () => BrowserLauncherService(),
  );

  // ── AI Integration ──────────────────────────────────────
  final aiProvider = AiProviderNotifier(log: log);
  await aiProvider.loadConfig();
  getIt.registerSingleton<AiProviderNotifier>(aiProvider);

  // ── System (desktop-only) ───────────────────────────────
  if (PlatformConfig.isDesktop) {
    getIt.registerLazySingleton<SystemTrayService>(() => SystemTrayService());
    getIt.registerLazySingleton<WindowManagerService>(
      () => WindowManagerService(),
    );
    getIt.registerLazySingleton<StartupService>(() => StartupService());

    // ── Desktop Automation (desktop-only) ─────────────────
    final pythonBridge = PythonBridgeService(log: log);
    getIt.registerSingleton<PythonBridgeService>(pythonBridge);

    final a11y = AccessibilityTreeService(log: log, bridge: pythonBridge);
    getIt.registerSingleton<AccessibilityTreeService>(a11y);

    final inputSim = InputSimulationService(log: log, bridge: pythonBridge);
    getIt.registerSingleton<InputSimulationService>(inputSim);

    final desktopAgent = DesktopAgentService(
      log: log,
      aiProvider: aiProvider,
      a11y: a11y,
      input: inputSim,
    );
    getIt.registerSingleton<DesktopAgentService>(desktopAgent);

    final desktopProvider = DesktopAutomationProvider(
      log: log,
      bridge: pythonBridge,
      agent: desktopAgent,
    );
    getIt.registerSingleton<DesktopAutomationProvider>(desktopProvider);
  }

  // ── Providers ───────────────────────────────────────────
  getIt.registerLazySingleton<ConnectionProvider>(
    () => ConnectionProvider(
      loggingService: log,
      webSocketService: getIt<WebSocketService>(),
      discoveryService: getIt<DiscoveryService>(),
      deviceInfoService: getIt<DeviceInfoService>(),
      browserLauncherService: getIt<BrowserLauncherService>(),
      clipboardSyncService: getIt<ClipboardSyncService>(),
      triggerRuleService: getIt<TriggerRuleService>(),
    ),
  );
}
