import 'dart:io';
import 'package:tray_manager/tray_manager.dart';
import '../../../core/services/logging_service.dart';

/// Manages the system tray icon and context menu (desktop-only).
class SystemTrayService with TrayListener {
  LoggingService? _loggingService;
  Function()? _onShowWindow;
  Function()? _onQuit;

  void setLoggingService(LoggingService service) => _loggingService = service;
  void setCallbacks({Function()? onShowWindow, Function()? onQuit}) {
    _onShowWindow = onShowWindow;
    _onQuit = onQuit;
  }

  void _log(String message) => _loggingService?.info('Tray', message);

  /// Initialise the tray icon and context menu.
  Future<void> init() async {
    trayManager.addListener(this);

    // Set the tray icon
    String iconPath;
    if (Platform.isWindows) {
      iconPath = 'assets/icons/tray_icon.ico';
    } else if (Platform.isMacOS) {
      iconPath = 'assets/icons/tray_icon.png';
    } else {
      iconPath = 'assets/icons/tray_icon.png';
    }

    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip('Autonion Agent — Running');

    final menu = Menu(
      items: [
        MenuItem(key: 'show', label: 'Show Autonion'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit'),
      ],
    );

    await trayManager.setContextMenu(menu);
    _log('System tray initialised');
  }

  @override
  void onTrayIconMouseDown() {
    _onShowWindow?.call();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _onShowWindow?.call();
        break;
      case 'quit':
        _onQuit?.call();
        break;
    }
  }

  Future<void> dispose() async {
    trayManager.removeListener(this);
  }
}
