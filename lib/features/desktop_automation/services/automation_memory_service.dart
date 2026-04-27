import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Record of a completed automation goal for persistent history.
class GoalRecord {
  final String command;
  final String outcome;
  final bool success;
  final int timestamp;
  final String? appUsed;

  const GoalRecord({
    required this.command,
    required this.outcome,
    required this.success,
    required this.timestamp,
    this.appUsed,
  });

  Map<String, dynamic> toJson() => {
    'command': command,
    'outcome': outcome,
    'success': success,
    'timestamp': timestamp,
    'app_used': appUsed,
  };

  factory GoalRecord.fromJson(Map<String, dynamic> json) => GoalRecord(
    command: json['command'] as String,
    outcome: json['outcome'] as String,
    success: json['success'] as bool,
    timestamp: json['timestamp'] as int,
    appUsed: json['app_used'] as String?,
  );
}

/// Manages automation memory on the Desktop side.
///
/// Mirrors Android's AutomationChatMemory with SharedPreferences persistence.
/// Provides context summaries for prompt injection and cross-device sync.
class AutomationMemoryService {
  static const _prefsKey = 'automation_goal_history';
  static const _maxGoalHistory = 10;
  static const _maxContextChars = 500;

  final List<GoalRecord> _goalHistory = [];
  final List<Map<String, String>> _sessionTurns = [];

  AutomationMemoryService();

  /// Initialize by loading persisted history.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_prefsKey);
    if (json != null) {
      try {
        final list = jsonDecode(json) as List;
        _goalHistory.addAll(
          list.map((e) => GoalRecord.fromJson(e as Map<String, dynamic>)),
        );
      } catch (_) {
        // Corrupted data, start fresh
      }
    }
  }

  void recordGoalStart(String command) {
    _sessionTurns.add({'role': 'user', 'content': 'Goal: $command'});
  }

  void recordGoalOutcome(String command, String outcome, bool success, {String? appUsed}) {
    final status = success ? '✓ Completed' : '✗ Failed';
    _sessionTurns.add({'role': 'agent', 'content': '$status: $outcome'});

    _goalHistory.add(GoalRecord(
      command: command,
      outcome: outcome,
      success: success,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      appUsed: appUsed,
    ));

    while (_goalHistory.length > _maxGoalHistory) {
      _goalHistory.removeAt(0);
    }

    _persistHistory();
  }

  void recordAgentTurn(String intent, String action) {
    _sessionTurns.add({'role': 'user', 'content': 'Sub-task: $intent'});
    _sessionTurns.add({'role': 'agent', 'content': 'Result: $action'});
  }

  /// Builds a concise context summary for LLM prompt injection.
  String? buildContextSummary() {
    if (_goalHistory.isEmpty) return null;

    final recent = _goalHistory.length > 3
        ? _goalHistory.sublist(_goalHistory.length - 3)
        : _goalHistory;

    final parts = <String>[];
    for (int i = 0; i < recent.length; i++) {
      final r = recent[i];
      final status = r.success ? 'completed' : 'failed: ${r.outcome}';
      final appInfo = r.appUsed != null ? ' on ${r.appUsed}' : '';
      final prefix = i == recent.length - 1
          ? 'Most recent'
          : (i == recent.length - 2 ? 'Before that' : 'Earlier');
      parts.add('$prefix: "${r.command}"$appInfo ($status)');
    }

    var summary = parts.join('. ');
    if (summary.length > _maxContextChars) {
      summary = '${summary.substring(0, _maxContextChars - 3)}...';
    }
    return summary.isEmpty ? null : summary;
  }

  void clearSession() => _sessionTurns.clear();

  void clearAll() {
    _sessionTurns.clear();
    _goalHistory.clear();
    _persistHistory();
  }

  Future<void> _persistHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_goalHistory.map((r) => r.toJson()).toList());
      await prefs.setString(_prefsKey, json);
    } catch (_) {
      // Best-effort persistence
    }
  }
}
