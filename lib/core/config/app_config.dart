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
  static const String appVersion = '2.0.5';

  /// Minimum Android Companion version required for full compatibility.
  static const String minRequiredCompanionVersion = '1.1.0';

  /// Compare two semver strings. Returns:
  ///  -1 if a < b, 0 if a == b, 1 if a > b
  static int compareVersions(String a, String b) {
    final pa = a.split('.').map(int.tryParse).toList();
    final pb = b.split('.').map(int.tryParse).toList();
    for (int i = 0; i < 3; i++) {
      final va = (i < pa.length ? pa[i] : null) ?? 0;
      final vb = (i < pb.length ? pb[i] : null) ?? 0;
      if (va < vb) return -1;
      if (va > vb) return 1;
    }
    return 0;
  }

  // ── System Tray ──────────────────────────────────────────
  static const String trayIconPath = 'assets/icons/tray_icon.ico';
  static const String trayTooltip = 'Autonion Agent — Running';
}
