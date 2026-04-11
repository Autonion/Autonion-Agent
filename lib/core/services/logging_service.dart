import 'package:flutter/foundation.dart';
import '../../core/models/log_entry.dart';

/// Centralised logging service used by all features.
///
/// Stores structured [LogEntry] items and notifies listeners on change
/// so the UI can reactively display the log console.
class LoggingService extends ChangeNotifier {
  final List<LogEntry> _entries = [];
  static const int _maxEntries = 2000;

  /// All log entries (oldest first).
  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Legacy getter for backward compat (returns formatted strings).
  List<String> get logs => _entries.map((e) => e.formatted).toList();

  /// Total entry count.
  int get count => _entries.length;

  // ── Convenience loggers ──────────────────────────────────

  void info(String source, String message) =>
      _add(LogLevel.info, source, message);

  void warn(String source, String message) =>
      _add(LogLevel.warning, source, message);

  void error(String source, String message) =>
      _add(LogLevel.error, source, message);

  void debug(String source, String message) =>
      _add(LogLevel.debug, source, message);

  /// Legacy log method (maps to info level with 'APP' source).
  void log(String message) => info('APP', message);

  // ── Internal ─────────────────────────────────────────────

  void _add(LogLevel level, String source, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      source: source,
      message: message,
    );
    _entries.add(entry);

    // Cap the list to prevent memory bloat.
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }

    notifyListeners();

    if (kDebugMode) {
      // ignore:  avoid_print
      print(entry.formatted);
    }
  }

  void clearLogs() {
    _entries.clear();
    notifyListeners();
  }

  /// Filter entries by level.
  List<LogEntry> filtered(LogLevel level) =>
      _entries.where((e) => e.level == level).toList();

  /// Search entries by message substring.
  List<LogEntry> search(String query) => _entries
      .where((e) => e.message.toLowerCase().contains(query.toLowerCase()))
      .toList();
}
