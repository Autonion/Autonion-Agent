import 'dart:async';

import '../../../core/services/logging_service.dart';
import '../models/desktop_flow_models.dart';
import 'input_simulation_service.dart';
import 'accessibility_tree_service.dart';
import '../models/automation_tier.dart';
import '../models/desktop_action.dart';

// ═══════════════════════════════════════════════════════════════════
//  PROGRESS & RESULT MODELS
// ═══════════════════════════════════════════════════════════════════

/// Reports step-by-step progress during flow execution.
class FlowStepProgress {
  final String flowId;
  final String status; // started, step_executing, step_completed, completed, failed
  final String message;
  final int currentStep;
  final int totalSteps;
  final String? nodeLabel;
  final String? nodeId;

  const FlowStepProgress({
    required this.flowId,
    required this.status,
    required this.message,
    required this.currentStep,
    required this.totalSteps,
    this.nodeLabel,
    this.nodeId,
  });

  Map<String, dynamic> toJson() => {
    'flowId': flowId,
    'status': status,
    'message': message,
    'currentStep': currentStep,
    'totalSteps': totalSteps,
    if (nodeLabel != null) 'nodeLabel': nodeLabel,
    if (nodeId != null) 'nodeId': nodeId,
  };
}

/// Final result after a flow completes (or fails).
class FlowExecutionResult {
  final bool success;
  final int stepsExecuted;
  final String? errorMessage;
  final Duration elapsed;

  const FlowExecutionResult({
    required this.success,
    required this.stepsExecuted,
    this.errorMessage,
    required this.elapsed,
  });
}

// ═══════════════════════════════════════════════════════════════════
//  FLOW EXECUTION SERVICE
// ═══════════════════════════════════════════════════════════════════

/// Executes a [DesktopFlow] step-by-step using the existing
/// [InputSimulationService] and [AccessibilityTreeService].
///
/// Traverses the flow graph from the Start node, following edges.
/// At each node, executes the mapped action, waits for a configurable
/// settle time, then follows the success edge. On failure, follows
/// the failure edge (if defined) or stops.
class FlowExecutionService {
  final InputSimulationService _input;
  final AccessibilityTreeService _a11y;
  final LoggingService _log;

  bool _isRunning = false;
  bool _stopRequested = false;
  String? _currentFlowId;

  bool get isRunning => _isRunning;
  String? get currentFlowId => _currentFlowId;

  FlowExecutionService({
    required InputSimulationService input,
    required AccessibilityTreeService a11y,
    required LoggingService log,
  })  : _input = input,
        _a11y = a11y,
        _log = log;

  /// Execute a flow, reporting progress via callback.
  Future<FlowExecutionResult> executeFlow(
    DesktopFlow flow, {
    void Function(FlowStepProgress)? onProgress,
  }) async {
    if (_isRunning) {
      return const FlowExecutionResult(
        success: false,
        stepsExecuted: 0,
        errorMessage: 'Another flow is already running',
        elapsed: Duration.zero,
      );
    }

    _isRunning = true;
    _stopRequested = false;
    _currentFlowId = flow.id;

    final stopwatch = Stopwatch()..start();
    int stepsExecuted = 0;

    // Count executable nodes (exclude start and done)
    final executableNodes = flow.nodes.where(
      (n) =>
          n.nodeType != DesktopFlowNodeType.start &&
          n.nodeType != DesktopFlowNodeType.done,
    );
    final totalSteps = executableNodes.length;

    _log.info('FlowExec', 'Starting flow: "${flow.name}" ($totalSteps steps)');

    onProgress?.call(FlowStepProgress(
      flowId: flow.id,
      status: 'started',
      message: 'Starting flow: ${flow.name}',
      currentStep: 0,
      totalSteps: totalSteps,
    ));

    try {
      // Find the start node
      final startNode = flow.startNode;
      if (startNode == null) {
        throw FlowExecutionException('Flow has no Start node');
      }

      // Begin graph traversal from start node
      var currentNode = startNode;

      while (!_stopRequested) {
        // If this is a terminal node, we're done
        if (currentNode.nodeType == DesktopFlowNodeType.done) {
          _log.info('FlowExec', 'Reached Done node — flow complete');
          break;
        }

        // Execute the node (skip Start — it's just an entry point)
        if (currentNode.nodeType != DesktopFlowNodeType.start) {
          stepsExecuted++;

          onProgress?.call(FlowStepProgress(
            flowId: flow.id,
            status: 'step_executing',
            message: '${currentNode.label}: ${currentNode.configSummary}',
            currentStep: stepsExecuted,
            totalSteps: totalSteps,
            nodeLabel: currentNode.label,
            nodeId: currentNode.id,
          ));

          try {
            await _executeNode(currentNode, flow);

            onProgress?.call(FlowStepProgress(
              flowId: flow.id,
              status: 'step_completed',
              message: '${currentNode.label} completed',
              currentStep: stepsExecuted,
              totalSteps: totalSteps,
              nodeLabel: currentNode.label,
              nodeId: currentNode.id,
            ));
          } catch (e) {
            _log.error(
              'FlowExec',
              'Node "${currentNode.label}" failed: $e',
            );

            // Check for failure edge
            if (currentNode.onFailureEdgeId != null) {
              final failEdge = flow.findEdge(currentNode.onFailureEdgeId!);
              if (failEdge != null) {
                final failTarget = flow.findNode(failEdge.toNodeId);
                if (failTarget != null) {
                  _log.info(
                    'FlowExec',
                    'Following failure edge to: ${failTarget.label}',
                  );
                  currentNode = failTarget;
                  continue;
                }
              }
            }

            // No failure edge — stop
            throw FlowExecutionException(
              'Node "${currentNode.label}" failed: $e',
            );
          }
        }

        // Follow the outgoing edge(s) to the next node
        final nextNodes = flow.nextNodes(currentNode.id);
        if (nextNodes.isEmpty) {
          _log.info('FlowExec', 'No outgoing edges — flow complete');
          break;
        }

        // For conditional nodes, pick the right branch
        if (currentNode.nodeType == DesktopFlowNodeType.conditional) {
          currentNode = await _resolveConditionalBranch(
            currentNode,
            flow,
          );
        } else {
          // For repeat nodes, handle looping
          if (currentNode.nodeType == DesktopFlowNodeType.repeat) {
            final repeatTarget = nextNodes.first;
            final count = currentNode.repeatCount ?? 1;
            for (int i = 0; i < count && !_stopRequested; i++) {
              _log.info('FlowExec', 'Repeat iteration ${i + 1}/$count');
              // Re-execute the downstream chain from repeatTarget
              // For now, just execute the next node N times
              await _executeNode(repeatTarget, flow);
            }
            // After repeat, follow edges from the repeat node
            // Skip the first (which was the repeat body)
            if (nextNodes.length > 1) {
              currentNode = nextNodes[1];
            } else {
              break;
            }
          } else {
            // Standard: follow the first outgoing edge
            currentNode = nextNodes.first;
          }
        }

        // Small settle time between nodes
        await Future.delayed(const Duration(milliseconds: 200));
      }

      stopwatch.stop();

      if (_stopRequested) {
        _log.info('FlowExec', 'Flow stopped by user after $stepsExecuted steps');
        onProgress?.call(FlowStepProgress(
          flowId: flow.id,
          status: 'failed',
          message: 'Flow stopped by user',
          currentStep: stepsExecuted,
          totalSteps: totalSteps,
        ));
        return FlowExecutionResult(
          success: false,
          stepsExecuted: stepsExecuted,
          errorMessage: 'Stopped by user',
          elapsed: stopwatch.elapsed,
        );
      }

      _log.info(
        'FlowExec',
        'Flow "${flow.name}" completed successfully ($stepsExecuted steps, ${stopwatch.elapsed.inMilliseconds}ms)',
      );

      onProgress?.call(FlowStepProgress(
        flowId: flow.id,
        status: 'completed',
        message: 'Flow completed successfully',
        currentStep: stepsExecuted,
        totalSteps: totalSteps,
      ));

      return FlowExecutionResult(
        success: true,
        stepsExecuted: stepsExecuted,
        elapsed: stopwatch.elapsed,
      );
    } on FlowExecutionException catch (e) {
      stopwatch.stop();
      onProgress?.call(FlowStepProgress(
        flowId: flow.id,
        status: 'failed',
        message: e.message,
        currentStep: stepsExecuted,
        totalSteps: totalSteps,
      ));
      return FlowExecutionResult(
        success: false,
        stepsExecuted: stepsExecuted,
        errorMessage: e.message,
        elapsed: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      _log.error('FlowExec', 'Unexpected error: $e');
      onProgress?.call(FlowStepProgress(
        flowId: flow.id,
        status: 'failed',
        message: 'Unexpected error: $e',
        currentStep: stepsExecuted,
        totalSteps: totalSteps,
      ));
      return FlowExecutionResult(
        success: false,
        stepsExecuted: stepsExecuted,
        errorMessage: '$e',
        elapsed: stopwatch.elapsed,
      );
    } finally {
      _isRunning = false;
      _currentFlowId = null;
    }
  }

  /// Stop the currently running flow.
  void stopFlow() {
    if (_isRunning) {
      _stopRequested = true;
      _log.info('FlowExec', 'Stop requested for flow: $_currentFlowId');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  NODE EXECUTION
  // ═══════════════════════════════════════════════════════════════

  /// Execute a single node by mapping its type to an InputSimulationService call.
  Future<void> _executeNode(DesktopFlowNode node, DesktopFlow flow) async {
    _log.info(
      'FlowExec',
      'Executing: ${node.nodeType.displayName} — "${node.label}"',
    );

    switch (node.nodeType) {
      case DesktopFlowNodeType.start:
      case DesktopFlowNodeType.done:
        // No-op — these are structural nodes
        break;

      case DesktopFlowNodeType.click:
        await _executeClickAction(node, 'click');
        break;

      case DesktopFlowNodeType.doubleClick:
        await _executeClickAction(node, 'double_click');
        break;

      case DesktopFlowNodeType.rightClick:
        await _executeClickAction(node, 'right_click');
        break;

      case DesktopFlowNodeType.typeText:
        await _executeTypeText(node);
        break;

      case DesktopFlowNodeType.keyboard:
      case DesktopFlowNodeType.hotkey:
        await _executeKeyboard(node);
        break;

      case DesktopFlowNodeType.launchApp:
        await _executeLaunchApp(node);
        break;

      case DesktopFlowNodeType.delay:
        await _executeDelay(node);
        break;

      case DesktopFlowNodeType.screenshot:
        await _executeScreenshot();
        break;

      case DesktopFlowNodeType.scroll:
        await _executeScroll(node);
        break;

      case DesktopFlowNodeType.repeat:
        // Repeat logic is handled in the traversal loop
        break;

      case DesktopFlowNodeType.conditional:
        // Conditional branching is handled in the traversal loop
        break;
    }
  }

  /// Resolve click coordinates from a UITargetSelector.
  /// For UIA attribute mode, queries the accessibility tree to find
  /// the element and extracts its bounding box center.
  Future<Map<String, dynamic>> _resolveTarget(UITargetSelector? target) async {
    if (target == null) {
      throw FlowExecutionException('No target specified for action');
    }

    switch (target.mode) {
      case UITargetMode.coordinate:
        if (target.x == null || target.y == null) {
          throw FlowExecutionException('Coordinates not set');
        }
        return {'x': target.x, 'y': target.y};

      case UITargetMode.stableId:
        if (target.stableId == null) {
          throw FlowExecutionException('Stable ID not set');
        }
        return {'targetStableId': target.stableId};

      case UITargetMode.uiaAttribute:
        // Query the accessibility tree for a matching element
        return await _findElementByAttributes(target);
    }
  }

  /// Search the accessibility tree for an element matching UIA attributes.
  Future<Map<String, dynamic>> _findElementByAttributes(
    UITargetSelector target,
  ) async {
    // Get current screen state from the accessibility tree
    final screenState = await _a11y.getScreenState(AutomationTier.accessibilityOnly);

    // Search elements for a match
    for (final element in screenState.elements) {
      bool matches = true;

      if (target.automationId != null && target.automationId!.isNotEmpty) {
        if (element.automationId != target.automationId) matches = false;
      }
      if (target.className != null && target.className!.isNotEmpty) {
        if (element.className != target.className) matches = false;
      }
      if (target.name != null && target.name!.isNotEmpty) {
        if (!element.name.toLowerCase().contains(
              target.name!.toLowerCase(),
            )) {
          matches = false;
        }
      }
      if (target.role != null && target.role!.isNotEmpty) {
        if (element.role.toLowerCase() != target.role!.toLowerCase()) {
          matches = false;
        }
      }
      if (target.controlType != null && target.controlType!.isNotEmpty) {
        if (element.type.toLowerCase() != target.controlType!.toLowerCase()) {
          matches = false;
        }
      }

      if (matches) {
        // Found it — use the bounding box center or stableId
        if (element.stableId != null) {
          return {'targetStableId': element.stableId};
        }
        final bbox = element.boundingBox;
        final cx = (bbox['x'] as num? ?? 0) + (bbox['width'] as num? ?? 0) / 2;
        final cy =
            (bbox['y'] as num? ?? 0) + (bbox['height'] as num? ?? 0) / 2;
        return {'x': cx, 'y': cy};
      }
    }

    throw FlowExecutionException(
      'Element not found matching: ${target.summary}',
    );
  }

  Future<void> _executeClickAction(DesktopFlowNode node, String clickType) async {
    final targetParams = await _resolveTarget(node.target);
    await _input.execute(DesktopAction(
      type: clickType == 'double_click' ? 'click' : clickType,
      x: targetParams['x'] as double?,
      y: targetParams['y'] as double?,
      targetStableId: targetParams['targetStableId'] as String?,
      button: clickType == 'right_click' ? 'right' : 'left',
    ));
    // For double-click, click twice quickly
    if (clickType == 'double_click') {
      await Future.delayed(const Duration(milliseconds: 50));
      await _input.execute(DesktopAction(
        type: 'click',
        x: targetParams['x'] as double?,
        y: targetParams['y'] as double?,
        targetStableId: targetParams['targetStableId'] as String?,
        button: 'left',
      ));
    }
  }

  Future<void> _executeTypeText(DesktopFlowNode node) async {
    // If there's a target, click it first to focus
    if (node.target != null) {
      final targetParams = await _resolveTarget(node.target);
      await _input.execute(DesktopAction(
        type: 'click',
        x: targetParams['x'] as double?,
        y: targetParams['y'] as double?,
        targetStableId: targetParams['targetStableId'] as String?,
      ));
      await Future.delayed(const Duration(milliseconds: 150));
    }

    await _input.execute(DesktopAction(
      type: 'type',
      text: node.text ?? '',
    ));
  }

  Future<void> _executeKeyboard(DesktopFlowNode node) async {
    final config = node.keyboardConfig;
    if (config == null || config.keys.isEmpty) {
      throw FlowExecutionException('No keys configured for keyboard node');
    }

    for (int i = 0; i < config.repeatCount; i++) {
      if (_stopRequested) break;

      switch (config.action) {
        case KeyboardActionType.press:
          await _input.execute(DesktopAction(
            type: 'hotkey',
            keys: config.keys,
          ));
          break;

        case KeyboardActionType.hold:
          // Hold is a press with extended duration
          await _input.execute(DesktopAction(
            type: 'hotkey',
            keys: config.keys,
            durationMs: config.holdDurationMs ?? 500,
          ));
          break;

        case KeyboardActionType.release:
          // Release previously held keys
          await _input.execute(DesktopAction(
            type: 'hotkey',
            keys: config.keys,
          ));
          break;

        case KeyboardActionType.typeSequence:
          // Type each key as an individual keystroke
          for (final key in config.keys) {
            if (_stopRequested) break;
            await _input.execute(DesktopAction(
              type: 'hotkey',
              keys: [key],
            ));
            await Future.delayed(const Duration(milliseconds: 50));
          }
          break;
      }

      // Delay between repetitions
      if (i < config.repeatCount - 1) {
        await Future.delayed(
          Duration(milliseconds: config.delayBetweenMs),
        );
      }
    }
  }

  Future<void> _executeLaunchApp(DesktopFlowNode node) async {
    final app = node.appName ?? '';
    if (app.isEmpty) {
      throw FlowExecutionException('No app name specified');
    }

    // Press Win to open Start Menu
    await _input.execute(const DesktopAction(
      type: 'hotkey',
      keys: ['win'],
    ));
    await Future.delayed(const Duration(milliseconds: 600));

    // Type the app name
    await _input.execute(DesktopAction(
      type: 'type',
      text: app,
    ));
    await Future.delayed(const Duration(milliseconds: 800));

    // Press Enter to launch
    await _input.execute(const DesktopAction(
      type: 'hotkey',
      keys: ['enter'],
    ));
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<void> _executeDelay(DesktopFlowNode node) async {
    final ms = node.delayMs ?? 1000;
    _log.info('FlowExec', 'Waiting ${ms}ms...');
    await Future.delayed(Duration(milliseconds: ms));
  }

  Future<void> _executeScreenshot() async {
    await _input.execute(const DesktopAction(
      type: 'hotkey',
      keys: ['printscreen'],
    ));
  }

  Future<void> _executeScroll(DesktopFlowNode node) async {
    await _input.execute(DesktopAction(
      type: 'scroll',
      direction: node.scrollDirection ?? 'down',
      amount: node.scrollAmount ?? 3,
    ));
  }

  /// For conditional nodes, check if the target element exists
  /// and return the appropriate branch node.
  Future<DesktopFlowNode> _resolveConditionalBranch(
    DesktopFlowNode condNode,
    DesktopFlow flow,
  ) async {
    final outEdges = flow.outgoingEdges(condNode.id);

    bool conditionMet = false;
    try {
      if (condNode.target != null) {
        await _resolveTarget(condNode.target);
        conditionMet = true; // Element exists
      }
    } catch (_) {
      conditionMet = false; // Element not found
    }

    // Find the "true" or "false" labeled edge, or fall back to order
    DesktopFlowEdge? trueEdge;
    DesktopFlowEdge? falseEdge;

    for (final edge in outEdges) {
      if (edge.label?.toLowerCase() == 'true') {
        trueEdge = edge;
      } else if (edge.label?.toLowerCase() == 'false') {
        falseEdge = edge;
      }
    }

    // Fall back: first edge = true, second = false
    trueEdge ??= outEdges.isNotEmpty ? outEdges.first : null;
    falseEdge ??= outEdges.length > 1 ? outEdges[1] : null;

    final targetEdge = conditionMet ? trueEdge : falseEdge;
    if (targetEdge == null) {
      throw FlowExecutionException(
        'Conditional node "${condNode.label}" has no ${conditionMet ? "true" : "false"} branch',
      );
    }

    final targetNode = flow.findNode(targetEdge.toNodeId);
    if (targetNode == null) {
      throw FlowExecutionException(
        'Conditional branch target node not found: ${targetEdge.toNodeId}',
      );
    }

    _log.info(
      'FlowExec',
      'Conditional "${condNode.label}": ${conditionMet ? "TRUE" : "FALSE"} → ${targetNode.label}',
    );

    return targetNode;
  }
}

/// Thrown when a flow execution step fails.
class FlowExecutionException implements Exception {
  final String message;
  const FlowExecutionException(this.message);
  @override
  String toString() => 'FlowExecutionException: $message';
}
