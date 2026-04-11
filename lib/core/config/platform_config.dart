import 'dart:io';

/// Platform-aware feature gating.
///
/// Desktop platforms get full feature set (browser automation, system tray,
/// desktop automation stubs). Mobile/other platforms get connection-only mode.
class PlatformConfig {
  PlatformConfig._();

  /// True on Windows, macOS, or Linux.
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// True on Android or iOS.
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Browser extension is only supported on desktop (Chrome/Edge/Brave).
  static bool get supportsExtension => isDesktop;

  /// System tray is desktop-only.
  static bool get supportsSystemTray => isDesktop;

  /// Desktop automation is desktop-only.
  static bool get supportsDesktopAutomation => isDesktop;

  /// Human-readable platform name.
  static String get platformName {
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    return 'Unknown';
  }
}
