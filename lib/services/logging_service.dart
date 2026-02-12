import 'package:flutter/foundation.dart';

class LoggingService extends ChangeNotifier {
  final List<String> _logs = [];

  List<String> get logs => _logs;

  void log(String message) {
    final timestamp = DateTime.now().toIso8601String().split('T')[1].split('.')[0];
    final logEntry = '[$timestamp] $message';
    _logs.add(logEntry);
    notifyListeners();
    if (kDebugMode) {
      print(logEntry);
    }
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }
}
