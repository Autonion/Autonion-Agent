import 'dart:convert';
import '../../../core/services/logging_service.dart';
import '../../ai/providers/ai_provider_notifier.dart';
import '../../ai/models/ai_message.dart';
import '../../ai/models/ai_response.dart';
import '../models/automation_tier.dart';
import '../models/desktop_action.dart';
import '../ml/desktop_prompt_formatter.dart';
import 'accessibility_tree_service.dart';
import 'automation_memory_service.dart';
import 'input_simulation_service.dart';
import 'task_decomposer_service.dart';

enum AgentStatus { idle, running, error, complete }

/// Thrown when the Desktop Agent determines a task needs the browser extension.
class NeedsBrowserException implements Exception {
  final String message;
  NeedsBrowserException([this.message = 'Task requires browser extension']);
  @override
  String toString() => 'NeedsBrowserException: $message';
}

/// Orchestrates the Agentic Loop for desktop automation.
class DesktopAgentService {
  final LoggingService _log;
  final AiProviderNotifier _aiProvider;
  final AccessibilityTreeService _a11y;
  final InputSimulationService _input;
  final TaskDecomposerService _decomposer = TaskDecomposerService();
  final AutomationMemoryService _memory = AutomationMemoryService();

  AgentStatus _status = AgentStatus.idle;
  AgentStatus get status => _status;

  /// Last error message for user-facing display.
  String? _lastError;
  String? get lastError => _lastError;

  final List<Map<String, dynamic>> _history = [];
  bool _stopRequested = false;

  DesktopAgentService({
    required LoggingService log,
    required AiProviderNotifier aiProvider,
    required AccessibilityTreeService a11y,
    required InputSimulationService input,
  }) : _log = log,
       _aiProvider = aiProvider,
       _a11y = a11y,
       _input = input;

  void stop() {
    if (_status == AgentStatus.running) {
      _stopRequested = true;
      _log.info('DesktopAgent', 'Stop requested by user.');
    }
  }

  Future<void> runTask(
    String goal, {
    AutomationTier tier = AutomationTier.accessibilityOnly,
    void Function(String)? onProgress,
  }) async {
    if (_status == AgentStatus.running) return;

    _status = AgentStatus.running;
    _stopRequested = false;
    _lastError = null;
    _history.clear();

    // Decompose compound commands
    final subGoals = _decomposer.decompose(goal);
    _memory.recordGoalStart(goal);

    _log.info('DesktopAgent', 'Starting task: "$goal" [Tier: ${tier.name}] (${subGoals.length} sub-goals)');

    if (subGoals.length <= 1) {
      // Simple command — run directly
      await _runScreenLoop(goal, tier: tier, onProgress: onProgress);
      final success = _status == AgentStatus.complete;
      _memory.recordGoalOutcome(goal, success ? 'completed' : 'failed', success);
      return;
    }

    // Multi-step: execute sub-goals sequentially
    for (final subGoal in subGoals) {
      if (_stopRequested) break;

      _log.info('DesktopAgent', '── Sub-goal ${subGoal.stepNumber}/${subGoals.length}: ${subGoal.description} ──');
      onProgress?.call('Step ${subGoal.stepNumber}/${subGoals.length}: ${subGoal.description}');
      _history.clear();

      await _runScreenLoop(subGoal.description, tier: tier, onProgress: onProgress);

      if (_status != AgentStatus.complete) {
        _memory.recordGoalOutcome(goal, 'failed at step ${subGoal.stepNumber}', false);
        return;
      }

      _memory.recordAgentTurn(subGoal.description, 'completed');
      _status = AgentStatus.running; // Reset for next sub-goal
      await Future.delayed(const Duration(milliseconds: 500));
    }

    _status = AgentStatus.complete;
    _memory.recordGoalOutcome(goal, 'completed all steps', true);
  }

  /// The core screen interaction loop for a single goal/sub-goal.
  Future<void> _runScreenLoop(
    String goal, {
    AutomationTier tier = AutomationTier.accessibilityOnly,
    void Function(String)? onProgress,
  }) async {
    int steps = 0;
    const maxSteps = 15;
    const maxAiRetries = 3;

    try {
      while (steps < maxSteps && !_stopRequested) {
        steps++;
        _log.info('DesktopAgent', '--- Step $steps ---');

        // 1. Observe Screen
        final screenState = await _a11y.getScreenState(tier);
        if (screenState.elements.isEmpty) {
          _log.warn(
            'DesktopAgent',
            'No UI elements found. Proceeding with empty UI state...',
          );
        }

        // 2. Build Prompt
        final systemPrompt = DesktopPromptFormatter.systemInstruction;
        final userPrompt = DesktopPromptFormatter.buildUserPrompt(
          goal,
          screenState,
          _history,
          conversationContext: _memory.buildContextSummary(),
        );

        final messages = [
          AiMessage(role: AiMessageRole.system, content: systemPrompt),
          AiMessage(
            role: AiMessageRole.user,
            content: userPrompt,
            base64Image: screenState.screenshotBase64,
          ),
        ];

        // Schema for structured JSON output
        final schema = {
          "type": "object",
          "properties": {
            "thought": {"type": "string"},
            "action": {
              "type": "object",
              "properties": {
                "type": {
                  "type": "string",
                  "enum": [
                    "click",
                    "type",
                    "scroll",
                    "hotkey",
                    "wait",
                    "needs_browser",
                    "done",
                  ],
                },
                "targetIndex": {
                  "type": ["integer", "null"],
                },
                "targetStableId": {
                  "type": ["string", "null"],
                },
                "text": {
                  "type": ["string", "null"],
                },
                "direction": {
                  "type": ["string", "null"],
                },
                "keys": {
                  "type": ["array", "null"],
                  "items": {"type": "string"},
                },
              },
              "required": ["type"],
            },
          },
          "required": ["thought", "action"],
        };

        // 3. Ask LLM (with retry for transient failures)
        final aiService = _aiProvider.activeService;
        AiResponse? response;
        bool gotValidResponse = false;

        for (int retry = 0; retry <= maxAiRetries; retry++) {
          response = await aiService.chat(messages, jsonSchema: schema);

          if (response.success &&
              response.content != null &&
              response.content!.isNotEmpty) {
            gotValidResponse = true;
            break;
          }

          // Determine if this is a retryable error
          final errorMsg = response.error ?? 'Empty response';
          final isRateLimit = errorMsg.contains('429') ||
              errorMsg.toLowerCase().contains('rate') ||
              errorMsg.toLowerCase().contains('temporarily');
          final isEmpty = !response.success ||
              response.content == null ||
              response.content!.isEmpty;

          if (retry < maxAiRetries && (isRateLimit || isEmpty)) {
            final waitSec = (retry + 1) * 2; // 2s, 4s, 6s
            _log.warn(
              'DesktopAgent',
              '${isRateLimit ? "Rate limited" : "Empty response"} '
              '— retrying in ${waitSec}s (${retry + 1}/$maxAiRetries)...',
            );
            onProgress?.call(
              '⚠️ ${isRateLimit ? "API rate limited" : "Empty AI response"} '
              '— retrying in ${waitSec}s...',
            );
            await Future.delayed(Duration(seconds: waitSec));
          } else if (retry >= maxAiRetries) {
            final userMsg = isRateLimit
                ? '❌ API rate limited after $maxAiRetries retries. Try again later or switch model.'
                : '❌ AI returned empty response after $maxAiRetries retries. Check your API key/model.';
            _log.error('DesktopAgent', 'AI failure after retries: $errorMsg');
            onProgress?.call(userMsg);
            _status = AgentStatus.error;
            _lastError = userMsg;
            return;
          } else {
            // Non-retryable error (e.g. auth failure, bad request)
            final userMsg = '❌ AI error: $errorMsg';
            _log.error('DesktopAgent', userMsg);
            onProgress?.call(userMsg);
            _status = AgentStatus.error;
            _lastError = userMsg;
            return;
          }
        }

        if (!gotValidResponse || response == null) {
          onProgress?.call('❌ AI service unavailable.');
          _status = AgentStatus.error;
          _lastError = 'AI service unavailable after retries.';
          return;
        }

        // 4. Parse JSON (with truncation recovery)
        String rawJson = response.content!.trim();
        final jsonStart = rawJson.indexOf('{');
        final jsonEnd = rawJson.lastIndexOf('}');
        if (jsonStart != -1 && jsonEnd != -1 && jsonEnd >= jsonStart) {
          rawJson = rawJson.substring(jsonStart, jsonEnd + 1);
        } else if (jsonStart != -1) {
          // Truncated JSON — no closing brace found
          rawJson = rawJson.substring(jsonStart);
        } else {
          if (rawJson.startsWith('```json')) {
            rawJson = rawJson.substring(7, rawJson.length - 3);
          } else if (rawJson.startsWith('```')) {
            rawJson = rawJson.substring(3, rawJson.length - 3);
          }
        }

        Map<String, dynamic> parsed;
        try {
          parsed = jsonDecode(rawJson) as Map<String, dynamic>;
        } catch (_) {
          // Attempt to repair truncated JSON by closing open braces
          parsed = _tryRepairJson(rawJson);
        }

        final thought = parsed['thought']?.toString() ?? '(truncated)';
        _log.info('DesktopAgent', 'Thought: $thought');
        onProgress?.call('Thought: $thought');

        Map<String, dynamic>? actionMap;
        if (parsed.containsKey('action') && parsed['action'] is Map) {
          actionMap = parsed['action'] as Map<String, dynamic>;
        }

        // If action is missing (truncated before action block), retry step
        if (actionMap == null || !actionMap.containsKey('type')) {
          _log.warn(
            'DesktopAgent',
            'Response truncated before action — retrying step...',
          );
          onProgress?.call('⚠️ AI response was truncated — retrying...');
          steps--; // Don't count this as a real step
          continue;
        }

        final action = DesktopAction.fromJson(actionMap);

        _history.add({
          'step': steps,
          'thought': parsed['thought'],
          'action': actionMap,
        });

        // 5. Execute Action
        if (action.type == 'done') {
          _log.info('DesktopAgent', 'Task completed successfully by Agent.');
          _status = AgentStatus.complete;
          _lastError = null;
          return;
        }

        if (action.type == 'needs_browser') {
          _log.info(
            'DesktopAgent',
            'Agent determined task needs browser. Re-routing...',
          );
          _status = AgentStatus.idle;
          throw NeedsBrowserException(
            parsed['thought']?.toString() ?? 'Task requires web access',
          );
        }

        try {
          await _input.execute(action);
        } catch (e) {
          _log.error('DesktopAgent', 'Action execution failed: $e');
          onProgress?.call('⚠️ Action failed: ${_firstLine(e.toString())} — continuing...');
          // Don't crash the whole loop — the LLM will re-observe the screen
          // and try a different approach on the next step
        }

        // Wait a bit for UI to settle
        await Future.delayed(const Duration(milliseconds: 500));
      }

      if (_stopRequested) {
        _log.warn('DesktopAgent', 'Task aborted by user.');
        _status = AgentStatus.idle;
      } else {
        _log.warn(
          'DesktopAgent',
          'Task reached max steps ($maxSteps) without completing.',
        );
        onProgress?.call('⚠️ Task reached max steps without completing.');
        _status = AgentStatus.error;
        _lastError = 'Task did not complete within $maxSteps steps.';
      }
    } on NeedsBrowserException {
      rethrow; // Let connection_provider handle re-routing
    } catch (e) {
      _log.error('DesktopAgent', 'Agent failed: $e');
      final errMsg = _firstLine(e.toString());
      onProgress?.call('❌ Agent error: $errMsg');
      _status = AgentStatus.error;
      _lastError = errMsg;
    }
  }

  /// Returns the first line of a potentially multi-line string.
  String _firstLine(String s) {
    final idx = s.indexOf('\n');
    return idx >= 0 ? s.substring(0, idx) : s;
  }

  /// Attempts to repair truncated JSON by closing unclosed braces/brackets.
  Map<String, dynamic> _tryRepairJson(String raw) {
    _log.warn('DesktopAgent', 'Attempting to repair truncated JSON...');

    // Count unclosed braces/brackets
    int openBraces = 0;
    int openBrackets = 0;
    bool inString = false;
    bool escaped = false;

    for (int i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == '\\') {
        escaped = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '{') openBraces++;
      if (c == '}') openBraces--;
      if (c == '[') openBrackets++;
      if (c == ']') openBrackets--;
    }

    // If we're inside a string, close it first
    String repaired = raw;
    if (inString) repaired += '"';

    // Close any open brackets then braces
    for (int i = 0; i < openBrackets; i++) {
      repaired += ']';
    }
    for (int i = 0; i < openBraces; i++) {
      repaired += '}';
    }

    try {
      final result = jsonDecode(repaired) as Map<String, dynamic>;
      _log.info('DesktopAgent', 'JSON repair successful.');
      return result;
    } catch (e) {
      _log.warn('DesktopAgent', 'JSON repair failed: $e. Using regex fallback.');
      // Last resort: try to extract action type with regex
      return _regexFallback(raw);
    }
  }

  /// Regex fallback: extract what we can from raw truncated text.
  Map<String, dynamic> _regexFallback(String raw) {
    final thoughtMatch = RegExp(r'"thought"\s*:\s*"([^"]*(?:\\.[^"]*)*)"').firstMatch(raw);
    final typeMatch = RegExp(r'"type"\s*:\s*"(\w+)"').firstMatch(raw);
    final textMatch = RegExp(r'"text"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(raw);
    final indexMatch = RegExp(r'"targetIndex"\s*:\s*(\d+)').firstMatch(raw);
    final directionMatch = RegExp(r'"direction"\s*:\s*"(\w+)"').firstMatch(raw);
    // Extract keys array values
    final keysMatch = RegExp(r'"keys"\s*:\s*\[(.*?)\]').firstMatch(raw);

    final action = <String, dynamic>{};
    if (typeMatch != null) action['type'] = typeMatch.group(1);
    if (textMatch != null) action['text'] = textMatch.group(1)!.replaceAll(r'\"', '"');
    if (indexMatch != null) action['targetIndex'] = int.tryParse(indexMatch.group(1)!);
    if (directionMatch != null) action['direction'] = directionMatch.group(1);
    if (keysMatch != null) {
      final keysStr = keysMatch.group(1)!;
      action['keys'] = RegExp(r'"(\w+)"').allMatches(keysStr).map((m) => m.group(1)!).toList();
    }

    return {
      'thought': thoughtMatch?.group(1) ?? '(could not parse)',
      if (action.isNotEmpty) 'action': action,
    };
  }
}
