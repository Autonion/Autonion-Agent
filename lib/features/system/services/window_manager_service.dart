import 'dart:ui';
import 'package:window_manager/window_manager.dart';
import '../../../core/services/logging_service.dart';

/// Manages the desktop window: prevent close, hide/show, size, position.
class WindowManagerService with WindowListener {
  LoggingService? _loggingService;
  bool _isVisible = true;

  bool get isVisible => _isVisible;

  void setLoggingService(LoggingService service) => _loggingService = service;
  void _log(String message) => _loggingService?.info('Window', message);

  /// Initialise the window manager and intercept the close button.
  Future<void> init() async {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1100, 750),
      minimumSize: Size(800, 550),
      center: true,
      title: 'Autonion Agent',
      titleBarStyle: TitleBarStyle.normal,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    // Prevent the default close — instead hide to tray
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    _log('Window manager initialised');
  }

  @override
  void onWindowClose() async {
    // Instead of quitting, hide to tray
    await hide();
    _log('Window hidden to tray (close intercepted)');
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
    _isVisible = true;
    _log('Window shown');
  }

  Future<void> hide() async {
    await windowManager.hide();
    _isVisible = false;
  }

  /// Actually quit the app (called from tray "Quit" menu).
  Future<void> forceClose() async {
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  Future<void> dispose() async {
    windowManager.removeListener(this);
  }
}
