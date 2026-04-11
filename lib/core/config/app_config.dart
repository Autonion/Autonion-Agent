/// Global application constants and configuration.
class AppConfig {
  AppConfig._();

  // ── Networking ───────────────────────────────────────────
  static const int defaultWebSocketPort = 4545;
  static const String webSocketPath = '/automation';
  static const String mdnsServiceType = '_myautomation._tcp';

  // ── Timeouts ─────────────────────────────────────────────
  static const Duration extensionConnectTimeout = Duration(seconds: 15);
  static const Duration clipboardPollInterval = Duration(seconds: 1);

  // ── App Info ─────────────────────────────────────────────
  static const String appName = 'Autonion Agent';
  static const String appVersion = '2.0.0';

  // ── System Tray ──────────────────────────────────────────
  static const String trayIconPath = 'assets/icons/tray_icon.ico';
  static const String trayTooltip = 'Autonion Agent — Running';
}
