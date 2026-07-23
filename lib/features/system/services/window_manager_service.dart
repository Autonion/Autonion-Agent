import 'dart:ui';
import 'package:window_manager/window_manager.dart';
import '../../../core/services/logging_service.dart';

/// Manages the desktop window: prevent close, hide/show, size, position.
class WindowManagerService with WindowListener {
  static const _normalSize = Size(1100, 750);
  static const _normalMinSize = Size(800, 550);
  static const _stuckOverlayMaxWidth = 500.0;
  static const _stuckOverlayMaxHeight = 300.0;

  LoggingService? _loggingService;
  bool _isVisible = true;
  bool _startedInBackground = false;

  bool get isVisible => _isVisible;

  void setLoggingService(LoggingService service) => _loggingService = service;
  void _log(String message) => _loggingService?.info('Window', message);

  /// Initialise the window manager and intercept the close button.
  Future<void> init({bool isStartup = false}) async {
    _startedInBackground = isStartup;
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: _normalSize,
      minimumSize: _normalMinSize,
      center: true,
      title: 'Autonion Agent',
      titleBarStyle: TitleBarStyle.normal,
      skipTaskbar: false,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      if (isStartup) {
        // Hide window AND remove from taskbar so it's fully in background
        await windowManager.setSkipTaskbar(true);
        await windowManager.hide();
        _isVisible = false;
        _log('Window manager initialised in background (startup)');
      } else {
        await windowManager.show();
        await windowManager.focus();
        _isVisible = true;
        _log('Window manager initialised');
      }
    });

    // Prevent the default close — instead hide to tray
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
  }

  /// Call after runApp() to re-enforce hidden state if started via --startup.
  /// Flutter's rendering pipeline can briefly flash the window after runApp().
  Future<void> ensureHiddenIfStartup() async {
    if (_startedInBackground && !_isVisible) {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
      _log('Re-enforced hidden state after runApp');
    }
  }

  @override
  void onWindowClose() async {
    // Instead of quitting, hide to tray
    await hide();
    _log('Window hidden to tray (close intercepted)');
  }

  Future<void> show() async {
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setResizable(true);
    await windowManager.setTitle('Autonion Agent');
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setMinimumSize(_normalMinSize);

    final bounds = await windowManager.getBounds();
    if (bounds.width < _stuckOverlayMaxWidth ||
        bounds.height < _stuckOverlayMaxHeight) {
      await windowManager.setSize(_normalSize);
      await windowManager.center();
    }

    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
    _isVisible = true;
    _log('Window shown');
  }

  Future<void> hide() async {
    await windowManager.setSkipTaskbar(true);
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
