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

  /// Cross-device conversation context from Android.
  /// Set when a prompt arrives with prior conversation history.
  String? _androidConversationContext;

  /// Structured conversation history from Android (user/assistant turns).
  List<Map<String, String>>? _androidConversationHistory;

  AutomationMemoryService();

  /// Set the conversation summary from Android for cross-device awareness.
  void setConversationContext(String? context) {
    _androidConversationContext = context;
  }

  /// Set the structured conversation history from Android.
  void setConversationHistory(List<Map<String, String>>? history) {
    _androidConversationHistory = history;
  }

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
  ///
  /// Combines Android conversation context (cross-device awareness)
  /// with local goal history so the LLM has full context.
  String? buildContextSummary() {
    final parts = <String>[];

    // 1. Android conversation context (cross-device awareness)
    if (_androidConversationContext != null &&
        _androidConversationContext!.isNotEmpty) {
      parts.add('CONVERSATION CONTEXT FROM MOBILE:\n$_androidConversationContext');
    }

    // 1b. Structured conversation history (richer than summary)
    if (_androidConversationHistory != null &&
        _androidConversationHistory!.isNotEmpty) {
      final historyLines = _androidConversationHistory!
          .map((turn) => '${turn['role']}: ${turn['content']}')
          .join('\n');
      // Only add if we didn't already add the summary above
      if (_androidConversationContext == null ||
          _androidConversationContext!.isEmpty) {
        parts.add('CONVERSATION HISTORY FROM MOBILE:\n$historyLines');
      }
    }

    // 2. Local goal history
    if (_goalHistory.isNotEmpty) {
      final recent = _goalHistory.length > 3
          ? _goalHistory.sublist(_goalHistory.length - 3)
          : _goalHistory;

      final goalParts = <String>[];
      for (int i = 0; i < recent.length; i++) {
        final r = recent[i];
        final status = r.success ? 'completed' : 'failed: ${r.outcome}';
        final appInfo = r.appUsed != null ? ' on ${r.appUsed}' : '';
        final prefix = i == recent.length - 1
            ? 'Most recent'
            : (i == recent.length - 2 ? 'Before that' : 'Earlier');
        goalParts.add('$prefix: "${r.command}"$appInfo ($status)');
      }
      parts.add(goalParts.join('. '));
    }

    if (parts.isEmpty) return null;

    var summary = parts.join('\n\n');
    // Allow more context chars to accommodate conversation history
    const maxChars = 1200;
    if (summary.length > maxChars) {
      summary = '${summary.substring(0, maxChars - 3)}...';
    }
    return summary;
  }

  void clearSession() => _sessionTurns.clear();

  void clearAll() {
    _sessionTurns.clear();
    _goalHistory.clear();
    _androidConversationContext = null;
    _androidConversationHistory = null;
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
