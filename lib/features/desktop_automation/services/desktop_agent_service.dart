import 'dart:convert';
import '../../../core/services/logging_service.dart';
import '../../ai/providers/ai_provider_notifier.dart';
import '../../ai/models/ai_message.dart';
import '../../ai/models/ai_response.dart';
import '../models/automation_tier.dart';
import '../models/desktop_action.dart';
import '../models/screen_state.dart';
import '../models/ui_element.dart';
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

  /// The action history from the most recent task execution.
  /// Each entry contains 'step', 'thought', 'action' (as a Map), and 'result'.
  List<Map<String, dynamic>> get actionHistory => List.unmodifiable(_history);

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
    String? conversationContext,
  }) async {
    if (_status == AgentStatus.running) return;

    _status = AgentStatus.running;
    _stopRequested = false;
    _lastError = null;
    _history.clear();

    // Inject Android conversation context into memory so the LLM
    // can resolve references like "it", "the same one", etc.
    if (conversationContext != null) {
      _memory.setConversationContext(conversationContext);
    }

    // Decompose compound commands FIRST — before any deterministic shortcuts.
    // This prevents shortcuts like the screenshot shortcut from swallowing
    // compound prompts (e.g., "open paint and draw a line, then screenshot it").
    final subGoals = _decomposer.decompose(goal);
    _memory.recordGoalStart(goal);

    _log.info(
      'DesktopAgent',
      'Starting task: "$goal" [Tier: ${tier.name}] (${subGoals.length} sub-goals)',
    );

    if (subGoals.length <= 1) {
      // Single goal — try deterministic shortcuts first
      if (await _tryRunDeterministicScreenshotCommand(goal, onProgress)) {
        final success = _status != AgentStatus.error;
        if (success) _status = AgentStatus.complete;
        _memory.recordGoalOutcome(
          goal,
          success
              ? 'completed screenshot shortcut'
              : 'screenshot shortcut failed',
          success,
        );
        return;
      }

      // No shortcut matched — run the agentic loop
      await _runScreenLoop(goal, tier: tier, onProgress: onProgress);
      final success = _status == AgentStatus.complete;
      _memory.recordGoalOutcome(
        goal,
        success ? 'completed' : 'failed',
        success,
      );
      return;
    }

    // Multi-step: execute sub-goals sequentially.
    // IMPORTANT: We no longer clear _history between sub-goals.
    // Instead, we insert a boundary marker so the LLM knows a sub-goal
    // completed, but retains full context of what happened before.
    final completedSubGoals = <SubGoal>[];
    for (final subGoal in subGoals) {
      if (_stopRequested) break;

      _log.info(
        'DesktopAgent',
        '── Sub-goal ${subGoal.stepNumber}/${subGoals.length}: ${subGoal.description} ──',
      );
      onProgress?.call(
        'Step ${subGoal.stepNumber}/${subGoals.length}: ${subGoal.description}',
      );

      // Insert a boundary marker instead of clearing history
      if (completedSubGoals.isNotEmpty) {
        _history.add({
          'type': 'sub_goal_boundary',
          'completed_step': completedSubGoals.last.stepNumber,
          'completed_description': completedSubGoals.last.description,
          'next_step': subGoal.stepNumber,
          'total_steps': subGoals.length,
          'result': {'status': 'boundary_marker'},
        });
      }

      // For screenshot sub-goals, use the deterministic shortcut directly.
      // Screenshots produce no visible UI confirmation, so the agentic loop
      // would spin forever waiting for evidence that never comes.
      if (_isScreenshotGoal(subGoal.description)) {
        _log.info(
          'DesktopAgent',
          'Screenshot sub-goal detected — using deterministic shortcut.',
        );
        final shortcutHandled = await _tryRunDeterministicScreenshotCommand(
          subGoal.description,
          onProgress,
        );
        if (shortcutHandled) {
          _status = (_status == AgentStatus.error)
              ? AgentStatus.error
              : AgentStatus.complete;
        } else {
          // Shortcut didn't match (unlikely) — fall back to agentic loop
          await _runScreenLoop(
            subGoal.description,
            tier: tier,
            onProgress: onProgress,
            fullGoalContext: goal,
            completedSubGoals: completedSubGoals,
          );
        }
      } else {
        await _runScreenLoop(
          subGoal.description,
          tier: tier,
          onProgress: onProgress,
          fullGoalContext: goal,
          completedSubGoals: completedSubGoals,
        );
      }

      if (_status != AgentStatus.complete) {
        _memory.recordGoalOutcome(
          goal,
          'failed at step ${subGoal.stepNumber}',
          false,
        );
        return;
      }

      completedSubGoals.add(subGoal);
      _memory.recordAgentTurn(subGoal.description, 'completed');
      _status = AgentStatus.running; // Reset for next sub-goal
      await Future.delayed(const Duration(milliseconds: 500));
    }

    _status = AgentStatus.complete;
    _memory.recordGoalOutcome(goal, 'completed all steps', true);
  }

  /// Returns true if a sub-goal description is primarily about taking a screenshot.
  bool _isScreenshotGoal(String description) {
    final lower = description.toLowerCase();
    return lower.contains('screenshot') ||
        lower.contains('screen shot') ||
        lower.contains('snip') ||
        lower.contains('snipping') ||
        lower.contains('win+shift+s') ||
        lower.contains('win shift s') ||
        lower.contains('printscreen') ||
        lower.contains('print screen');
  }

  /// The core screen interaction loop for a single goal/sub-goal.
  Future<void> _runScreenLoop(
    String goal, {
    AutomationTier tier = AutomationTier.accessibilityOnly,
    void Function(String)? onProgress,
    String? fullGoalContext,
    List<SubGoal>? completedSubGoals,
  }) async {
    int steps = 0;
    const maxSteps = 25;
    const maxAiRetries = 3;
    String? lastObservationSignature;
    // Track repeated identical actions for stale-loop detection.
    // If the LLM emits the same action type N times in a row with an
    // unchanged screen, the action likely succeeded but has no visible
    // confirmation (e.g., screenshot hotkey). Auto-complete to avoid
    // burning through 25 steps pointlessly.
    String? lastActionFingerprint;
    int consecutiveRepeats = 0;
    const maxConsecutiveRepeats = 2; // auto-complete after 2 identical actions
    final observationTier =
        tier == AutomationTier.accessibilityOnly && _needsVisualFeedback(goal)
        ? AutomationTier.treeWithThumbnail
        : tier;

    try {
      while (steps < maxSteps && !_stopRequested) {
        steps++;
        _log.info('DesktopAgent', '--- Step $steps ---');

        // 1. Observe Screen
        final screenState = await _a11y.getScreenState(observationTier);
        if (screenState.elements.isEmpty) {
          _log.warn(
            'DesktopAgent',
            'No UI elements found. Proceeding with empty UI state...',
          );
        }

        final currentObservationSignature = screenState.compactSignature;
        if (_history.isNotEmpty && lastObservationSignature != null) {
          final last = _history.last;
          final existingResult = last['result'];
          final result = existingResult is Map<String, dynamic>
              ? Map<String, dynamic>.from(existingResult)
              : <String, dynamic>{};
          final previousAction = last['action'];
          final previousActionType = previousAction is Map
              ? previousAction['type']?.toString()
              : null;
          final pixelOnlyAction = {
            'click',
            'double_click',
            'right_click',
            'drag',
          }.contains(previousActionType);
          final cannotVerifyPixels =
              pixelOnlyAction && screenState.screenshotHash == null;
          final screenChanged =
              currentObservationSignature != lastObservationSignature;
          result['screenChangedAfterAction'] = cannotVerifyPixels
              ? null
              : screenChanged;
          result['nextObservationSignature'] = currentObservationSignature;
          if (cannotVerifyPixels) {
            result['observationNote'] =
                'Pixel-level screen changes cannot be verified because screenshots are disabled; do not repeat the same canvas drag unless the user-visible goal is clearly incomplete.';
          } else if (!screenChanged) {
            result['observationNote'] =
                'The next observation looked unchanged; avoid repeating the same action unless waiting is intentional.';
          }
          last['result'] = result;
        }

        // 2. Build Prompt
        final systemPrompt = DesktopPromptFormatter.systemInstruction;
        final userPrompt = DesktopPromptFormatter.buildUserPrompt(
          goal,
          screenState,
          _history,
          conversationContext: _memory.buildContextSummary(),
          fullGoalContext: fullGoalContext,
          completedSubGoals: completedSubGoals,
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
          "additionalProperties": false,
          "properties": {
            "thought": {"type": "string"},
            "action": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "type": {
                  "type": "string",
                  "enum": [
                    "click",
                    "double_click",
                    "right_click",
                    "type",
                    "scroll",
                    "drag",
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
                "endTargetIndex": {
                  "type": ["integer", "null"],
                },
                "endTargetStableId": {
                  "type": ["string", "null"],
                },
                "x": {
                  "type": ["number", "null"],
                },
                "y": {
                  "type": ["number", "null"],
                },
                "endX": {
                  "type": ["number", "null"],
                },
                "endY": {
                  "type": ["number", "null"],
                },
                "path": {
                  "type": ["array", "null"],
                  "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                      "x": {"type": "number"},
                      "y": {"type": "number"},
                    },
                    "required": ["x", "y"],
                  },
                },
                "text": {
                  "type": ["string", "null"],
                },
                "direction": {
                  "type": ["string", "null"],
                },
                "amount": {
                  "type": ["integer", "null"],
                },
                "keys": {
                  "type": ["array", "null"],
                  "items": {"type": "string"},
                },
                "durationMs": {
                  "type": ["integer", "null"],
                },
                "button": {
                  "type": ["string", "null"],
                },
                "replace": {
                  "type": ["boolean", "null"],
                },
              },
              "required": [
                "type",
                "targetIndex",
                "targetStableId",
                "endTargetIndex",
                "endTargetStableId",
                "x",
                "y",
                "endX",
                "endY",
                "path",
                "text",
                "direction",
                "amount",
                "keys",
                "durationMs",
                "button",
                "replace",
              ],
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
          final isRateLimit =
              errorMsg.contains('429') ||
              errorMsg.toLowerCase().contains('rate') ||
              errorMsg.toLowerCase().contains('temporarily');
          final isEmpty =
              !response.success ||
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
          'action': _actionForHistory(action, screenState),
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

        final validationError = _validateAction(action, screenState);
        if (validationError != null) {
          _log.warn(
            'DesktopAgent',
            'Rejected invalid action: $validationError',
          );
          _history.last['result'] = {
            'status': 'rejected',
            'error': validationError,
          };
          onProgress?.call('Action rejected: $validationError');
          lastObservationSignature = currentObservationSignature;
          await Future.delayed(const Duration(milliseconds: 200));
          continue;
        }

        try {
          final result = await _input.execute(action);
          _history.last['result'] = {'status': 'executed', ...result};
        } catch (e) {
          _log.error('DesktopAgent', 'Action execution failed: $e');
          _history.last['result'] = {
            'status': 'failed',
            'error': _firstLine(e.toString()),
          };
          onProgress?.call(
            '⚠️ Action failed: ${_firstLine(e.toString())} — continuing...',
          );
          // Don't crash the whole loop — the LLM will re-observe the screen
          // and try a different approach on the next step
        }

        // ── Stale-loop detection ──────────────────────────────
        // Build a fingerprint from the action type + key fields so we
        // can detect when the LLM keeps emitting the exact same action.
        final fingerprint = _actionFingerprint(action);
        final screenUnchanged =
            currentObservationSignature == lastObservationSignature;
        if (fingerprint == lastActionFingerprint && screenUnchanged) {
          consecutiveRepeats++;
          if (consecutiveRepeats >= maxConsecutiveRepeats) {
            _log.info(
              'DesktopAgent',
              'Detected $consecutiveRepeats consecutive identical actions '
                  'with unchanged screen — auto-completing sub-goal.',
            );
            onProgress?.call(
              '✅ Action appears successful (no further changes detected).',
            );
            _status = AgentStatus.complete;
            return;
          }
        } else {
          consecutiveRepeats = 0;
        }
        lastActionFingerprint = fingerprint;

        lastObservationSignature = currentObservationSignature;

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

  String? _validateAction(DesktopAction action, ScreenState state) {
    const allowed = {
      'click',
      'double_click',
      'right_click',
      'type',
      'scroll',
      'drag',
      'hotkey',
      'wait',
      'needs_browser',
      'done',
    };

    if (!allowed.contains(action.type)) {
      return 'Unsupported action type "${action.type}".';
    }

    switch (action.type) {
      case 'click':
      case 'double_click':
      case 'right_click':
        return _validateStartPoint(action, state);
      case 'type':
        if (action.text == null) return 'Type action requires text.';
        return _hasAnyStartPoint(action)
            ? _validateStartPoint(action, state)
            : null;
      case 'scroll':
        final direction = action.direction?.toLowerCase();
        if (direction == null ||
            !{'up', 'down', 'left', 'right'}.contains(direction)) {
          return 'Scroll action requires direction up, down, left, or right.';
        }
        return null;
      case 'drag':
        if (action.path != null) return _validatePath(action, state);
        final startError = _validateStartPoint(action, state);
        if (startError != null) return 'Drag start invalid: $startError';
        return _validateEndPoint(action, state);
      case 'hotkey':
        if (action.keys == null || action.keys!.isEmpty) {
          return 'Hotkey action requires at least one key.';
        }
        return null;
      default:
        return null;
    }
  }

  String? _validateStartPoint(DesktopAction action, ScreenState state) {
    if (!_hasAnyStartPoint(action)) {
      return 'Action requires targetStableId, targetIndex, or x/y coordinates.';
    }
    if (action.targetStableId != null &&
        !_hasStableId(state, action.targetStableId!)) {
      return 'targetStableId "${action.targetStableId}" is not in the current UI elements.';
    }
    if (action.targetIndex != null &&
        !_hasTargetIndex(state, action.targetIndex!)) {
      return 'targetIndex ${action.targetIndex} is not in the current UI elements.';
    }
    if ((action.x == null) != (action.y == null)) {
      return 'Both x and y coordinates are required together.';
    }
    if (action.x != null &&
        !_isCoordinateInScreen(action.x!, action.y!, state)) {
      return 'Coordinates (${action.x}, ${action.y}) are outside the visible screen.';
    }
    return null;
  }

  String? _validatePath(DesktopAction action, ScreenState state) {
    final path = action.path;
    if (path == null || path.length < 2) {
      return 'Drag path requires at least two points.';
    }
    for (final point in path) {
      final x = point['x'];
      final y = point['y'];
      if (x == null || y == null) {
        return 'Every drag path point requires x and y.';
      }
      if (!_isCoordinateInScreen(x, y, state)) {
        return 'Drag path point ($x, $y) is outside the visible screen.';
      }
    }
    return null;
  }

  String? _validateEndPoint(DesktopAction action, ScreenState state) {
    final hasEndElement =
        action.endTargetStableId != null || action.endTargetIndex != null;
    final hasEndCoords = action.endX != null || action.endY != null;
    if (!hasEndElement && !hasEndCoords) {
      return 'Drag requires endTargetStableId, endTargetIndex, or endX/endY coordinates.';
    }
    if (action.endTargetStableId != null &&
        !_hasStableId(state, action.endTargetStableId!)) {
      return 'endTargetStableId "${action.endTargetStableId}" is not in the current UI elements.';
    }
    if (action.endTargetIndex != null &&
        !_hasTargetIndex(state, action.endTargetIndex!)) {
      return 'endTargetIndex ${action.endTargetIndex} is not in the current UI elements.';
    }
    if ((action.endX == null) != (action.endY == null)) {
      return 'Both endX and endY coordinates are required together.';
    }
    if (action.endX != null &&
        !_isCoordinateInScreen(action.endX!, action.endY!, state)) {
      return 'Drag end coordinates (${action.endX}, ${action.endY}) are outside the visible screen.';
    }
    return null;
  }

  bool _hasAnyStartPoint(DesktopAction action) {
    return action.targetStableId != null ||
        action.targetIndex != null ||
        (action.x != null && action.y != null);
  }

  Map<String, dynamic> _actionForHistory(
    DesktopAction action,
    ScreenState state,
  ) {
    final map = action.toJson();
    _addTargetSnapshot(map, action, state, end: false);
    _addTargetSnapshot(map, action, state, end: true);
    return map;
  }

  void _addTargetSnapshot(
    Map<String, dynamic> map,
    DesktopAction action,
    ScreenState state, {
    required bool end,
  }) {
    final element = _findActionElement(action, state, end: end);
    if (element == null) return;

    final bbox = element.boundingBox;
    final left = _boxDouble(bbox, 'x');
    final top = _boxDouble(bbox, 'y');
    final width = _boxDouble(bbox, 'width');
    final height = _boxDouble(bbox, 'height');
    final centerX = left + width / 2;
    final centerY = top + height / 2;
    final prefix = end ? 'endTarget' : 'target';

    if (end) {
      map['endX'] ??= centerX;
      map['endY'] ??= centerY;
    } else {
      map['x'] ??= centerX;
      map['y'] ??= centerY;
    }

    map['${prefix}Name'] = element.name;
    map['${prefix}Role'] = element.role;
    map['${prefix}ControlType'] = element.type;
    map['${prefix}AutomationId'] = element.automationId;
    map['${prefix}ClassName'] = element.className;
    map['${prefix}HintX'] = centerX;
    map['${prefix}HintY'] = centerY;
    map['${prefix}HintWidth'] = width;
    map['${prefix}HintHeight'] = height;
    map['${prefix}HintValue'] = element.value;
  }

  UIElement? _findActionElement(
    DesktopAction action,
    ScreenState state, {
    required bool end,
  }) {
    final stableId = end ? action.endTargetStableId : action.targetStableId;
    if (stableId != null && stableId.isNotEmpty) {
      for (final element in state.elements) {
        if (element.stableId == stableId) return element;
      }
    }

    final targetIndex = end ? action.endTargetIndex : action.targetIndex;
    if (targetIndex != null) {
      final nodeId = 'node_$targetIndex';
      for (final element in state.elements) {
        if (element.id == nodeId) return element;
      }
    }

    final x = end ? action.endX : action.x;
    final y = end ? action.endY : action.y;
    if (x == null || y == null) return null;
    for (final element in state.elements) {
      if (_elementContainsPoint(element, x, y)) return element;
    }
    return null;
  }

  bool _elementContainsPoint(UIElement element, double x, double y) {
    final bbox = element.boundingBox;
    final left = _boxDouble(bbox, 'x');
    final top = _boxDouble(bbox, 'y');
    final width = _boxDouble(bbox, 'width');
    final height = _boxDouble(bbox, 'height');
    return x >= left && x <= left + width && y >= top && y <= top + height;
  }

  double _boxDouble(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool _hasStableId(ScreenState state, String stableId) {
    return state.elements.any((e) => e.stableId == stableId);
  }

  bool _hasTargetIndex(ScreenState state, int index) {
    return state.elements.any((e) => e.id == 'node_$index');
  }

  bool _isCoordinateInScreen(double x, double y, ScreenState state) {
    final left = state.screenLeft.toDouble();
    final top = state.screenTop.toDouble();
    final right = left + state.screenWidth;
    final bottom = top + state.screenHeight;
    return x >= left && y >= top && x <= right && y <= bottom;
  }

  bool _needsVisualFeedback(String goal) {
    final normalized = goal.toLowerCase();
    const visualTerms = {
      'paint',
      'canvas',
      'draw',
      'sketch',
      'drag',
      'drop',
      'slider',
      'resize',
      'crop',
      'screenshot',
      'screen shot',
      'select area',
      'freehand',
    };
    return visualTerms.any(normalized.contains);
  }

  Future<bool> _tryRunDeterministicScreenshotCommand(
    String goal,
    void Function(String)? onProgress,
  ) async {
    final normalized = goal.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final mentionsScreenshot =
        normalized.contains('screenshot') ||
        normalized.contains('screen shot') ||
        normalized.contains('snip') ||
        normalized.contains('snipping') ||
        normalized.contains('win+shift+s') ||
        normalized.contains('won+shift+s') ||
        normalized.contains('win shift s') ||
        normalized.contains('won shift s') ||
        normalized.contains('windows+shift+s') ||
        normalized.contains('windows shift s');

    if (!mentionsScreenshot) return false;

    // Safety net: reject if the prompt clearly contains other action verbs,
    // which signals it is a compound command even if the decomposer returned
    // a single sub-goal (e.g., edge cases it couldn't split).
    const nonScreenshotVerbs = {
      'open',
      'launch',
      'start',
      'create',
      'make',
      'draw',
      'write',
      'type',
      'enter',
      'compose',
      'search',
      'find',
      'navigate',
      'go',
      'click',
      'tap',
      'press',
      'select',
      'play',
      'pause',
      'close',
      'save',
      'download',
      'send',
      'share',
      'copy',
      'paste',
      'delete',
      'rename',
      'move',
      'scroll',
      'drag',
      'enable',
      'disable',
      'set',
    };
    final words = normalized.split(RegExp(r'[\s,\.;!?]+'));
    final hasOtherVerbs = words.any((w) => nonScreenshotVerbs.contains(w));
    if (hasOtherVerbs) {
      _log.info(
        'DesktopAgent',
        'Screenshot shortcut skipped — prompt contains other action verbs, deferring to agentic loop.',
      );
      return false;
    }

    final wantsSnippingShortcut =
        normalized.contains('win+shift+s') ||
        normalized.contains('won+shift+s') ||
        normalized.contains('win shift s') ||
        normalized.contains('won shift s') ||
        normalized.contains('windows+shift+s') ||
        normalized.contains('windows shift s') ||
        normalized.contains('snip') ||
        normalized.contains('snipping') ||
        normalized.contains('select area') ||
        normalized.contains('drag');

    final wantsDragSelection =
        normalized.contains('drag') ||
        normalized.contains('select area') ||
        normalized.contains('top start') ||
        normalized.contains('top corner') ||
        normalized.contains('bottom end') ||
        normalized.contains('bottom corner');

    try {
      if (!wantsSnippingShortcut) {
        onProgress?.call('Taking a full-screen screenshot to clipboard.');
        await _input.execute(
          const DesktopAction(type: 'hotkey', keys: ['printscreen']),
        );
        return true;
      }

      final screenState = await _a11y.getScreenState(
        AutomationTier.accessibilityOnly,
      );
      final left = screenState.screenLeft.toDouble();
      final top = screenState.screenTop.toDouble();
      final right = left + screenState.screenWidth - 1;
      final bottom = top + screenState.screenHeight - 1;

      onProgress?.call('Opening Windows snipping overlay.');
      await _input.execute(
        const DesktopAction(type: 'hotkey', keys: ['win', 'shift', 's']),
      );
      await Future.delayed(const Duration(milliseconds: 900));

      if (wantsDragSelection) {
        final inset = 12.0;
        onProgress?.call('Selecting the requested screenshot area.');
        await _input.execute(
          DesktopAction(
            type: 'drag',
            x: left + inset,
            y: top + inset,
            endX: right - inset,
            endY: bottom - inset,
            durationMs: 900,
            button: 'left',
          ),
        );
      }

      return true;
    } catch (e) {
      final errMsg = _firstLine(e.toString());
      _log.error('DesktopAgent', 'Deterministic screenshot command failed: $e');
      onProgress?.call('Screenshot shortcut failed: $errMsg');
      _status = AgentStatus.error;
      _lastError = errMsg;
      return true;
    }
  }

  /// Builds a compact fingerprint string for a [DesktopAction] to detect
  /// repeated identical actions in the stale-loop detector.
  String _actionFingerprint(DesktopAction action) {
    final parts = <String>[action.type];
    if (action.keys != null) parts.add('keys=${action.keys!.join('+')}');
    if (action.targetStableId != null)
      parts.add('sid=${action.targetStableId}');
    if (action.targetIndex != null) parts.add('idx=${action.targetIndex}');
    if (action.x != null && action.y != null)
      parts.add('xy=${action.x},${action.y}');
    if (action.text != null) parts.add('text=${action.text}');
    if (action.direction != null) parts.add('dir=${action.direction}');
    return parts.join('|');
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
      _log.warn(
        'DesktopAgent',
        'JSON repair failed: $e. Using regex fallback.',
      );
      // Last resort: try to extract action type with regex
      return _regexFallback(raw);
    }
  }

  /// Regex fallback: extract what we can from raw truncated text.
  Map<String, dynamic> _regexFallback(String raw) {
    final thoughtMatch = RegExp(
      r'"thought"\s*:\s*"([^"]*(?:\\.[^"]*)*)"',
    ).firstMatch(raw);
    final typeMatch = RegExp(r'"type"\s*:\s*"(\w+)"').firstMatch(raw);
    final textMatch = RegExp(
      r'"text"\s*:\s*"((?:[^"\\]|\\.)*)"',
    ).firstMatch(raw);
    final indexMatch = RegExp(r'"targetIndex"\s*:\s*(\d+)').firstMatch(raw);
    final stableIdMatch = RegExp(
      r'"targetStableId"\s*:\s*"([^"]+)"',
    ).firstMatch(raw);
    final endIndexMatch = RegExp(
      r'"endTargetIndex"\s*:\s*(\d+)',
    ).firstMatch(raw);
    final endStableIdMatch = RegExp(
      r'"endTargetStableId"\s*:\s*"([^"]+)"',
    ).firstMatch(raw);
    final directionMatch = RegExp(r'"direction"\s*:\s*"(\w+)"').firstMatch(raw);
    final xMatch = RegExp(r'"x"\s*:\s*(-?\d+(?:\.\d+)?)').firstMatch(raw);
    final yMatch = RegExp(r'"y"\s*:\s*(-?\d+(?:\.\d+)?)').firstMatch(raw);
    final endXMatch = RegExp(r'"endX"\s*:\s*(-?\d+(?:\.\d+)?)').firstMatch(raw);
    final endYMatch = RegExp(r'"endY"\s*:\s*(-?\d+(?:\.\d+)?)').firstMatch(raw);
    final amountMatch = RegExp(r'"amount"\s*:\s*(\d+)').firstMatch(raw);
    final durationMatch = RegExp(r'"durationMs"\s*:\s*(\d+)').firstMatch(raw);
    // Extract keys array values
    final keysMatch = RegExp(r'"keys"\s*:\s*\[(.*?)\]').firstMatch(raw);

    final action = <String, dynamic>{};
    if (typeMatch != null) action['type'] = typeMatch.group(1);
    if (textMatch != null)
      action['text'] = textMatch.group(1)!.replaceAll(r'\"', '"');
    if (indexMatch != null)
      action['targetIndex'] = int.tryParse(indexMatch.group(1)!);
    if (stableIdMatch != null)
      action['targetStableId'] = stableIdMatch.group(1);
    if (endIndexMatch != null)
      action['endTargetIndex'] = int.tryParse(endIndexMatch.group(1)!);
    if (endStableIdMatch != null)
      action['endTargetStableId'] = endStableIdMatch.group(1);
    if (directionMatch != null) action['direction'] = directionMatch.group(1);
    if (xMatch != null) action['x'] = double.tryParse(xMatch.group(1)!);
    if (yMatch != null) action['y'] = double.tryParse(yMatch.group(1)!);
    if (endXMatch != null)
      action['endX'] = double.tryParse(endXMatch.group(1)!);
    if (endYMatch != null)
      action['endY'] = double.tryParse(endYMatch.group(1)!);
    if (amountMatch != null)
      action['amount'] = int.tryParse(amountMatch.group(1)!);
    if (durationMatch != null)
      action['durationMs'] = int.tryParse(durationMatch.group(1)!);
    if (keysMatch != null) {
      final keysStr = keysMatch.group(1)!;
      action['keys'] = RegExp(
        r'"(\w+)"',
      ).allMatches(keysStr).map((m) => m.group(1)!).toList();
    }

    return {
      'thought': thoughtMatch?.group(1) ?? '(could not parse)',
      if (action.isNotEmpty) 'action': action,
    };
  }
}
