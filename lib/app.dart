import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'core/config/platform_config.dart';
import 'core/di/service_locator.dart';
import 'core/services/logging_service.dart';
import 'features/desktop_automation/providers/flow_builder_provider.dart';
import 'features/desktop_automation/services/accessibility_tree_service.dart';
import 'features/desktop_automation/services/flow_execution_service.dart';
import 'features/desktop_automation/services/flow_storage_service.dart';
import 'features/desktop_automation/services/python_bridge_service.dart';
import 'ui/theme/app_theme.dart';
import 'ui/app_shell.dart';

/// The root MaterialApp widget for Autonion Agent.
class AutonionApp extends StatelessWidget {
  const AutonionApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Only provide FlowBuilderProvider on desktop where the services exist
    if (PlatformConfig.isDesktop) {
      return ChangeNotifierProvider(
        create: (_) => FlowBuilderProvider(
          storage: getIt<FlowStorageService>(),
          execution: getIt<FlowExecutionService>(),
          a11y: getIt<AccessibilityTreeService>(),
          bridge: getIt<PythonBridgeService>(),
          log: getIt<LoggingService>(),
        ),
        child: MaterialApp(
          title: 'Autonion Agent',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark,
          home: const AppShell(),
        ),
      );
    }

    return MaterialApp(
      title: 'Autonion Agent',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const AppShell(),
    );
  }
}
