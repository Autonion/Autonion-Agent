import 'dart:convert';
import '../../../core/services/logging_service.dart';
import '../../ai/providers/ai_provider_notifier.dart';
import '../../ai/models/ai_message.dart';
import '../models/automation_tier.dart';
import '../models/desktop_action.dart';
import '../ml/desktop_prompt_formatter.dart';
import 'accessibility_tree_service.dart';
import 'input_simulation_service.dart';

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

  AgentStatus _status = AgentStatus.idle;
  AgentStatus get status => _status;

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
    _history.clear();

    _log.info('DesktopAgent', 'Starting task: "$goal" [Tier: ${tier.name}]');

    int steps = 0;
    const maxSteps = 15;

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
        );

        final messages = [
          AiMessage(role: AiMessageRole.system, content: systemPrompt),
          // We could add history here, but keeping it simple for v1
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

        // 3. Ask LLM
        final aiService = _aiProvider.activeService;
        final response = await aiService.chat(messages, jsonSchema: schema);

        if (!response.success ||
            response.content == null ||
            response.content!.isEmpty) {
          throw Exception('AI Error: ${response.error ?? "Empty response"}');
        }

        // 4. Parse JSON
        String rawJson = response.content!.trim();
        final jsonStart = rawJson.indexOf('{');
        final jsonEnd = rawJson.lastIndexOf('}');
        if (jsonStart != -1 && jsonEnd != -1 && jsonEnd >= jsonStart) {
          rawJson = rawJson.substring(jsonStart, jsonEnd + 1);
        } else {
          // Fallback if no {} found
          if (rawJson.startsWith('```json')) {
            rawJson = rawJson.substring(7, rawJson.length - 3);
          } else if (rawJson.startsWith('```')) {
            rawJson = rawJson.substring(3, rawJson.length - 3);
          }
        }

        final parsed = jsonDecode(rawJson) as Map<String, dynamic>;
        _log.info('DesktopAgent', 'Thought: ${parsed["thought"]}');
        onProgress?.call('Thought: ${parsed["thought"]}');

        final actionMap = parsed["action"] as Map<String, dynamic>;
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

        await _input.execute(action);

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
        _status = AgentStatus.error;
      }
    } catch (e) {
      _log.error('DesktopAgent', 'Agent failed: $e');
      _status = AgentStatus.error;
    }
  }
}
