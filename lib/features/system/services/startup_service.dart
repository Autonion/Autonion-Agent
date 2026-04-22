import 'dart:io';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/logging_service.dart';

/// Manages launch-at-login registration.
class StartupService {
  static const String _prefKey = 'launch_at_startup_enabled';
  LoggingService? _loggingService;
  bool _enabled = false;

  bool get isEnabled => _enabled;

  void setLoggingService(LoggingService service) => _loggingService = service;
  void _log(String message) => _loggingService?.info('Startup', message);

  /// Initialise and read the persisted preference.
  Future<void> init() async {
    launchAtStartup.setup(
      appName: 'Autonion Agent',
      appPath: Platform.resolvedExecutable,
      args: const ['--startup'],
    );

    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefKey) ?? false;

    // Sync with OS registration
    final isRegistered = await launchAtStartup.isEnabled();
    if (_enabled) {
      // Always call enable to ensure the registry key has the latest arguments (e.g. --startup)
      await launchAtStartup.enable();
    } else if (!_enabled && isRegistered) {
      await launchAtStartup.disable();
    }

    _log('Launch at startup: ${_enabled ? "enabled" : "disabled"}');
  }

  /// Toggle launch-at-startup.
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    if (enabled) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, enabled);
    _log('Launch at startup ${enabled ? "enabled" : "disabled"}');
  }
}
