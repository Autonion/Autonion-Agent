/// Severity level for a log entry.
enum LogLevel { info, warning, error, debug }

/// A structured log entry with level, source tag, message, and timestamp.
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String source; // e.g. "WS", "mDNS", "CMD"
  final String message;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
  });

  /// Short time string for display: HH:mm:ss
  String get timeString {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// Formatted line for the log console.
  String get formatted => '[$timeString] [$source] $message';

  @override
  String toString() => formatted;
}
