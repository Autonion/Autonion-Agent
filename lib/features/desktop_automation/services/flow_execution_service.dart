import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/services/logging_service.dart';
import '../models/desktop_flow_models.dart';
import 'input_simulation_service.dart';
import 'accessibility_tree_service.dart';
import 'python_bridge_service.dart';
import 'secure_credential_service.dart';
import '../models/automation_tier.dart';
import '../models/desktop_action.dart';
import '../models/screen_state.dart';
import '../models/ui_element.dart';

// ═══════════════════════════════════════════════════════════════════
//  PROGRESS & RESULT MODELS
// ═══════════════════════════════════════════════════════════════════

/// Reports step-by-step progress during flow execution.
class FlowStepProgress {
  final String flowId;
  final String
  status; // started, step_executing, step_completed, completed, failed
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
class FlowExecutionService extends ChangeNotifier {
  final InputSimulationService _input;
  final AccessibilityTreeService _a11y;
  final PythonBridgeService _bridge;
  final LoggingService _log;
  final SecureCredentialService _credentials;

  static const _targetResolveTimeout = Duration(seconds: 30);
  static const _targetResolvePollInterval = Duration(milliseconds: 300);

  bool _isRunning = false;
  bool _stopRequested = false;
  String? _currentFlowId;
  FlowStepProgress? _currentProgress;

  /// Context variables populated during data iterator execution.
  /// Keys like 'current_item', 'current_index', 'total_items' are set
  /// per-iteration and can be referenced in downstream nodes via
  /// the `{{variable_name}}` syntax.
  final Map<String, String> _executionContext = {};

  bool _preferLastLaunchedApp = false;
  String? _activeLaunchedAppName;
  String? _activeLaunchedAppPath;

  bool get isRunning => _isRunning;
  bool get stopRequested => _stopRequested;
  String? get currentFlowId => _currentFlowId;
  FlowStepProgress? get currentProgress => _currentProgress;

  FlowExecutionService({
    required InputSimulationService input,
    required AccessibilityTreeService a11y,
    required PythonBridgeService bridge,
    required LoggingService log,
    required SecureCredentialService credentials,
  }) : _input = input,
       _a11y = a11y,
       _bridge = bridge,
       _log = log,
       _credentials = credentials;

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
    _currentProgress = null;
    _executionContext.clear();
    _preferLastLaunchedApp = false;
    _activeLaunchedAppName = null;
    _activeLaunchedAppPath = null;

    final stopwatch = Stopwatch()..start();
    int stepsExecuted = 0;

    void emitProgress(FlowStepProgress progress) {
      _currentProgress = progress;
      onProgress?.call(progress);
      notifyListeners();
    }

    // Count executable nodes (exclude start and done)
    final executableNodes = flow.nodes.where(
      (n) =>
          n.nodeType != DesktopFlowNodeType.start &&
          n.nodeType != DesktopFlowNodeType.done,
    );
    final totalSteps = executableNodes.length;

    _log.info('FlowExec', 'Starting flow: "${flow.name}" ($totalSteps steps)');

    emitProgress(
      FlowStepProgress(
        flowId: flow.id,
        status: 'started',
        message: 'Starting flow: ${flow.name}',
        currentStep: 0,
        totalSteps: totalSteps,
      ),
    );

    try {
      // Find the start node
      final startNode = flow.startNode;
      if (startNode == null) {
        throw FlowExecutionException('Flow has no Start node');
      }

      // Begin graph traversal from start node
      var currentNode = startNode;

      while (!_stopRequested) {
        final stepNode = currentNode;

        // If this is a terminal node, we're done
        if (currentNode.nodeType == DesktopFlowNodeType.done) {
          _log.info('FlowExec', 'Reached Done node — flow complete');
          break;
        }

        // Execute the node (skip Start — it's just an entry point)
        // Also skip node types whose execution is handled directly below
        // in the traversal logic (dataIterator, conditional, repeat).
        final isTraversalHandled =
            currentNode.nodeType == DesktopFlowNodeType.dataIterator ||
            currentNode.nodeType == DesktopFlowNodeType.conditional ||
            currentNode.nodeType == DesktopFlowNodeType.repeat;

        if (currentNode.nodeType != DesktopFlowNodeType.start) {
          stepsExecuted++;

          emitProgress(
            FlowStepProgress(
              flowId: flow.id,
              status: 'step_executing',
              message: '${currentNode.label}: ${currentNode.configSummary}',
              currentStep: stepsExecuted,
              totalSteps: totalSteps,
              nodeLabel: currentNode.label,
              nodeId: currentNode.id,
            ),
          );

          if (!isTraversalHandled) {
            try {
              await _executeNode(currentNode, flow);

              emitProgress(
                FlowStepProgress(
                  flowId: flow.id,
                  status: 'step_completed',
                  message: '${currentNode.label} completed',
                  currentStep: stepsExecuted,
                  totalSteps: totalSteps,
                  nodeLabel: currentNode.label,
                  nodeId: currentNode.id,
                ),
              );
            } catch (e) {
              _log.error('FlowExec', 'Node "${currentNode.label}" failed: $e');

              final failureTarget = _resolveFailureBranch(currentNode, flow);
              if (failureTarget != null) {
                _log.info(
                  'FlowExec',
                  'Following failure edge to: ${failureTarget.label}',
                );
                currentNode = failureTarget;
                continue;
              }

              // No failure edge - stop
              throw FlowExecutionException(
                'Node "${currentNode.label}" failed: $e',
              );
            }
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
          currentNode = await _resolveConditionalBranch(currentNode, flow);
        } else if (currentNode.nodeType == DesktopFlowNodeType.dataIterator) {
          // Data Iterator is disabled (Coming Soon) — skip gracefully.
          _log.info(
            'FlowExec',
            'Data Iterator "${currentNode.label}" skipped — feature coming in future updates.',
          );

          // Follow the "done" edge if present, otherwise fall through to
          // the default success-edge resolution below.
          DesktopFlowNode? doneTarget;
          for (final edge in flow.outgoingEdges(currentNode.id)) {
            if (edge.label?.toLowerCase() == 'done') {
              doneTarget = flow.findNode(edge.toNodeId);
              break;
            }
          }
          if (doneTarget != null) {
            currentNode = doneTarget;
          } else {
            // No done edge — try normal success edge
            final next = _resolveSuccessBranch(currentNode, flow);
            if (next == null) break;
            currentNode = next;
          }
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
            currentNode =
                _resolveSuccessBranch(currentNode, flow) ?? nextNodes.first;
          }
        }

        // Per-node settle delay (defaults to 200ms if not configured)
        final settleMs = stepNode.settleDelayMs ?? 200;
        if (settleMs > 0) {
          await _delayInterruptibly(Duration(milliseconds: settleMs));
        }
      }

      stopwatch.stop();

      if (_stopRequested) {
        _log.info(
          'FlowExec',
          'Flow stopped by user after $stepsExecuted steps',
        );
        emitProgress(
          FlowStepProgress(
            flowId: flow.id,
            status: 'failed',
            message: 'Flow stopped by user',
            currentStep: stepsExecuted,
            totalSteps: totalSteps,
          ),
        );
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

      emitProgress(
        FlowStepProgress(
          flowId: flow.id,
          status: 'completed',
          message: 'Flow completed successfully',
          currentStep: stepsExecuted,
          totalSteps: totalSteps,
        ),
      );

      return FlowExecutionResult(
        success: true,
        stepsExecuted: stepsExecuted,
        elapsed: stopwatch.elapsed,
      );
    } on FlowExecutionException catch (e) {
      stopwatch.stop();
      emitProgress(
        FlowStepProgress(
          flowId: flow.id,
          status: 'failed',
          message: e.message,
          currentStep: stepsExecuted,
          totalSteps: totalSteps,
        ),
      );
      return FlowExecutionResult(
        success: false,
        stepsExecuted: stepsExecuted,
        errorMessage: e.message,
        elapsed: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      _log.error('FlowExec', 'Unexpected error: $e');
      emitProgress(
        FlowStepProgress(
          flowId: flow.id,
          status: 'failed',
          message: 'Unexpected error: $e',
          currentStep: stepsExecuted,
          totalSteps: totalSteps,
        ),
      );
      return FlowExecutionResult(
        success: false,
        stepsExecuted: stepsExecuted,
        errorMessage: '$e',
        elapsed: stopwatch.elapsed,
      );
    } finally {
      _isRunning = false;
      _stopRequested = false;
      _currentFlowId = null;
      _preferLastLaunchedApp = false;
      _activeLaunchedAppName = null;
      _activeLaunchedAppPath = null;
      notifyListeners();
    }
  }

  /// Stop the currently running flow.
  void stopFlow() {
    if (_isRunning) {
      _stopRequested = true;
      _log.info('FlowExec', 'Stop requested for flow: $_currentFlowId');
      notifyListeners();
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

      case DesktopFlowNodeType.swipe:
        await _executeSwipe(node);
        break;

      case DesktopFlowNodeType.repeat:
        // Repeat logic is handled in the traversal loop
        break;

      case DesktopFlowNodeType.conditional:
        // Conditional branching is handled in the traversal loop
        break;

      case DesktopFlowNodeType.visualTrigger:
        await _executeVisualTrigger(node);
        break;

      case DesktopFlowNodeType.uiDetect:
        await _executeUIDetect(node);
        break;

      case DesktopFlowNodeType.unlock:
        await _executeUnlock(node);
        break;

      case DesktopFlowNodeType.dataIterator:
        // Data iterator traversal is handled in the main loop;
        // the actual iteration is triggered from there.
        break;
    }
  }

  DesktopFlowNode? _resolveSuccessBranch(
    DesktopFlowNode node,
    DesktopFlow flow,
  ) {
    return _resolveLabeledBranch(node, flow, const ['success', 'true']) ??
        _resolveUnlabeledBranch(node, flow);
  }

  DesktopFlowNode? _resolveFailureBranch(
    DesktopFlowNode node,
    DesktopFlow flow,
  ) {
    if (node.onFailureEdgeId != null) {
      final explicitEdge = flow.findEdge(node.onFailureEdgeId!);
      final explicitTarget = explicitEdge == null
          ? null
          : flow.findNode(explicitEdge.toNodeId);
      if (explicitTarget != null) return explicitTarget;
    }
    return _resolveLabeledBranch(node, flow, const ['failure', 'false']);
  }

  DesktopFlowNode? _resolveLabeledBranch(
    DesktopFlowNode node,
    DesktopFlow flow,
    List<String> labels,
  ) {
    for (final edge in flow.outgoingEdges(node.id)) {
      final label = edge.label?.toLowerCase();
      if (label != null && labels.contains(label)) {
        final target = flow.findNode(edge.toNodeId);
        if (target != null) return target;
      }
    }
    return null;
  }

  DesktopFlowNode? _resolveUnlabeledBranch(
    DesktopFlowNode node,
    DesktopFlow flow,
  ) {
    for (final edge in flow.outgoingEdges(node.id)) {
      if (edge.label == null || edge.label!.isEmpty) {
        final target = flow.findNode(edge.toNodeId);
        if (target != null) return target;
      }
    }
    return null;
  }

  Future<ScreenState> _getFlowScreenState(AutomationTier tier) {
    return _a11y.getScreenState(
      tier,
      preferLastLaunchedApp: _preferLastLaunchedApp,
      preferredAppName: _activeLaunchedAppName,
      preferredAppPath: _activeLaunchedAppPath,
    );
  }

  /// Resolve a target from the current screen state.
  ///
  /// Saved flows can run faster than target apps become interactive. For
  /// element-based targets, wait until the current accessibility tree contains
  /// the target and then click its current center point. This avoids replaying
  /// stale stable IDs from a previous AI observation/cache.
  Future<Map<String, dynamic>> _resolveTarget(UITargetSelector? target) async {
    if (target == null) {
      throw FlowExecutionException('No target specified for action');
    }

    switch (target.mode) {
      case UITargetMode.coordinate:
        final x = target.centerX ?? target.x;
        final y = target.centerY ?? target.y;
        if (x == null || y == null) {
          throw FlowExecutionException('Coordinates not set');
        }
        return {'x': x, 'y': y};

      case UITargetMode.stableId:
      case UITargetMode.uiaAttribute:
        final element = await _waitForTargetElement(target);
        return _targetParamsForElement(element);
    }
  }

  Future<UIElement> _waitForTargetElement(
    UITargetSelector target, {
    Duration timeout = _targetResolveTimeout,
    bool requireEditable = false,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var loggedWaiting = false;

    while (!_stopRequested) {
      final screenState = await _getFlowScreenState(
        AutomationTier.accessibilityOnly,
      );
      final element = _findElementInList(
        screenState.elements,
        target,
        requireEditable: requireEditable,
      );
      if (element != null) {
        if (loggedWaiting) {
          _log.info('FlowExec', 'Target ready: ${target.summary}');
        }
        return element;
      }

      if (!loggedWaiting) {
        _log.info('FlowExec', 'Waiting for target: ${target.summary}');
        loggedWaiting = true;
      }
      if (DateTime.now().isAfter(deadline)) break;
      await _delayInterruptibly(_targetResolvePollInterval);
    }

    if (_stopRequested) {
      throw FlowExecutionException('Target resolution stopped');
    }
    throw FlowExecutionException(
      'Target did not become available within ${timeout.inSeconds}s: ${target.summary}',
    );
  }

  Future<UIElement?> _findCurrentElement(
    UITargetSelector? target, {
    bool requireEditable = false,
  }) async {
    final screenState = await _getFlowScreenState(
      AutomationTier.accessibilityOnly,
    );
    if (target == null) {
      return _bestElement(
        screenState.elements,
        requireEditable: requireEditable,
      );
    }
    return _findElementInList(
      screenState.elements,
      target,
      requireEditable: requireEditable,
    );
  }

  UIElement? _findElementInList(
    List<UIElement> elements,
    UITargetSelector target, {
    bool requireEditable = false,
  }) {
    final candidates = elements.where((element) {
      if (element.isOffscreen || !element.isEnabled) return false;
      if (_isSystemSurfaceElement(element)) return false;
      if (requireEditable && !_isEditableElement(element)) return false;

      switch (target.mode) {
        case UITargetMode.stableId:
          return target.stableId != null && element.stableId == target.stableId;
        case UITargetMode.uiaAttribute:
          return _matchesAttributes(element, target);
        case UITargetMode.coordinate:
          return _matchesCoordinateTarget(element, target);
      }
    }).toList();

    if (candidates.isEmpty) return null;
    if (target.mode == UITargetMode.uiaAttribute) {
      return _pickBestMatch(candidates, target);
    }
    return _bestElement(candidates, requireEditable: requireEditable);
  }

  UIElement? _bestElement(
    List<UIElement> elements, {
    bool requireEditable = false,
  }) {
    final candidates = elements.where((element) {
      if (element.isOffscreen || !element.isEnabled) return false;
      if (_isSystemSurfaceElement(element)) return false;
      if (requireEditable && !_isEditableElement(element)) return false;
      return !requireEditable ||
          element.isKeyboardFocusable ||
          element.isFocused;
    }).toList();

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      if (a.isFocused != b.isFocused) return a.isFocused ? -1 : 1;
      final aEditable = _isEditableElement(a);
      final bEditable = _isEditableElement(b);
      if (aEditable != bEditable) return aEditable ? -1 : 1;
      return _elementArea(a).compareTo(_elementArea(b));
    });
    return candidates.first;
  }

  bool _isSystemSurfaceElement(UIElement element) {
    if (element.isSystemSurface) return true;

    final classes = <String>{
      (element.windowClassName ?? '').toLowerCase(),
      (element.className ?? '').toLowerCase(),
    };
    const blockedClasses = <String>{
      'shell_traywnd',
      'shell_secondarytraywnd',
      'notifyiconoverflowwindow',
      'tasklistthumbnailwnd',
      'taskswitcherwnd',
      'multitaskingviewframe',
      'foregroundstaging',
      'progman',
      'workerw',
    };
    if (classes.any(blockedClasses.contains)) return true;

    final title = (element.windowTitle ?? '').trim().toLowerCase();
    const blockedTitles = <String>{
      'start',
      'search',
      'task view',
      'notification center',
      'quick settings',
      'program manager',
    };
    return blockedTitles.contains(title);
  }

  bool _matchesAttributes(UIElement element, UITargetSelector target) {
    if (target.automationId != null && target.automationId!.isNotEmpty) {
      if (element.automationId != target.automationId) return false;
    }
    if (target.className != null && target.className!.isNotEmpty) {
      if (element.className != target.className) return false;
    }
    if (target.name != null && target.name!.isNotEmpty) {
      if (!element.name.toLowerCase().contains(target.name!.toLowerCase())) {
        return false;
      }
    }
    if (target.role != null && target.role!.isNotEmpty) {
      if (element.role.toLowerCase() != target.role!.toLowerCase()) {
        return false;
      }
    }
    if (target.controlType != null && target.controlType!.isNotEmpty) {
      if (element.type.toLowerCase() != target.controlType!.toLowerCase()) {
        return false;
      }
    }
    return true;
  }

  bool _matchesCoordinateTarget(UIElement element, UITargetSelector target) {
    if (target.x == null || target.y == null) return false;
    if (target.hasRegion) {
      return _elementIntersectsRect(
        element,
        target.x!,
        target.y!,
        target.width!,
        target.height!,
      );
    }
    return _elementContainsPoint(element, target.x!, target.y!);
  }

  Map<String, dynamic> _targetParamsForElement(UIElement element) {
    final bbox = element.boundingBox;
    final cx = _asDouble(bbox['x']) + _asDouble(bbox['width']) / 2;
    final cy = _asDouble(bbox['y']) + _asDouble(bbox['height']) / 2;
    return {'x': cx, 'y': cy};
  }

  bool _isEditableElement(UIElement element) {
    final role = element.role.toLowerCase();
    final type = element.type.toLowerCase();
    final className = (element.className ?? '').toLowerCase();
    return role.contains('edit') ||
        role.contains('text') ||
        role.contains('combo') ||
        type.contains('edit') ||
        type.contains('combobox') ||
        type.contains('document') ||
        className.contains('edit') ||
        element.isFocused;
  }

  bool _elementContainsPoint(UIElement element, double x, double y) {
    final bbox = element.boundingBox;
    final left = _asDouble(bbox['x']);
    final top = _asDouble(bbox['y']);
    final width = _asDouble(bbox['width']);
    final height = _asDouble(bbox['height']);
    return x >= left && x <= left + width && y >= top && y <= top + height;
  }

  bool _elementIntersectsRect(
    UIElement element,
    double x,
    double y,
    double width,
    double height,
  ) {
    final bbox = element.boundingBox;
    final left = _asDouble(bbox['x']);
    final top = _asDouble(bbox['y']);
    final right = left + _asDouble(bbox['width']);
    final bottom = top + _asDouble(bbox['height']);
    final targetRight = x + width;
    final targetBottom = y + height;
    return left < targetRight && right > x && top < targetBottom && bottom > y;
  }

  double _elementArea(UIElement element) {
    final bbox = element.boundingBox;
    return _asDouble(bbox['width']) * _asDouble(bbox['height']);
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> _delayInterruptibly(Duration duration) async {
    final end = DateTime.now().add(duration);
    while (!_stopRequested) {
      final remaining = end.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final slice = remaining > const Duration(milliseconds: 100)
          ? const Duration(milliseconds: 100)
          : remaining;
      await Future.delayed(slice);
    }
  }

  Future<void> _executeClickAction(
    DesktopFlowNode node,
    String clickType,
  ) async {
    final targetParams = await _resolveTarget(node.target);
    await _input.execute(
      DesktopAction(
        type: clickType == 'double_click' ? 'click' : clickType,
        x: targetParams['x'] as double?,
        y: targetParams['y'] as double?,
        targetStableId: targetParams['targetStableId'] as String?,
        coordinateSpace: 'screen',
        button: clickType == 'right_click' ? 'right' : 'left',
      ),
    );
    // For double-click, click twice quickly
    if (clickType == 'double_click') {
      await _delayInterruptibly(const Duration(milliseconds: 50));
      await _input.execute(
        DesktopAction(
          type: 'click',
          x: targetParams['x'] as double?,
          y: targetParams['y'] as double?,
          targetStableId: targetParams['targetStableId'] as String?,
          coordinateSpace: 'screen',
          button: 'left',
        ),
      );
    }
  }

  Future<void> _executeTypeText(DesktopFlowNode node) async {
    var focused = false;

    if (node.autoDetectInput) {
      final editable = await _findCurrentElement(
        node.target,
        requireEditable: true,
      );
      if (editable != null) {
        await _clickTarget(_targetParamsForElement(editable));
        focused = true;
      }
    }

    if (!focused && node.target != null) {
      final targetParams = await _resolveTarget(node.target);
      await _clickTarget(targetParams);
      focused = true;
    }

    if (focused) {
      await _delayInterruptibly(const Duration(milliseconds: 150));
    }

    // Apply context variable substitution (e.g. {{current_item}})
    final rawText = node.text ?? '';
    final resolvedText = _substituteContextVariables(rawText);

    await _input.execute(DesktopAction(type: 'type', text: resolvedText));

    // Post-action: send a key press after typing (e.g. Enter to submit)
    final postAction = node.postAction;
    if (postAction != null && postAction != 'none' && postAction.isNotEmpty) {
      await _delayInterruptibly(const Duration(milliseconds: 100));
      _log.info('FlowExec', 'TypeText: post-action "$postAction"');
      await _input.execute(DesktopAction(type: 'hotkey', keys: [postAction]));
    }
  }

  /// Replace `{{key}}` placeholders in [text] with values from
  /// the current execution context.
  String _substituteContextVariables(String text) {
    if (_executionContext.isEmpty || !text.contains('{{')) return text;
    var result = text;
    for (final entry in _executionContext.entries) {
      result = result.replaceAll('{{${entry.key}}}', entry.value);
    }
    return result;
  }

  Future<void> _clickTarget(Map<String, dynamic> targetParams) {
    return _input.execute(
      DesktopAction(
        type: 'click',
        x: targetParams['x'] as double?,
        y: targetParams['y'] as double?,
        targetStableId: targetParams['targetStableId'] as String?,
        coordinateSpace: 'screen',
      ),
    );
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
          await _input.execute(
            DesktopAction(type: 'hotkey', keys: config.keys),
          );
          break;

        case KeyboardActionType.hold:
          // Hold is a press with extended duration
          await _input.execute(
            DesktopAction(
              type: 'hotkey',
              keys: config.keys,
              durationMs: config.holdDurationMs ?? 500,
            ),
          );
          break;

        case KeyboardActionType.release:
          // Release previously held keys
          await _input.execute(
            DesktopAction(type: 'hotkey', keys: config.keys),
          );
          break;

        case KeyboardActionType.typeSequence:
          // Type each key as an individual keystroke
          for (final key in config.keys) {
            if (_stopRequested) break;
            await _input.execute(DesktopAction(type: 'hotkey', keys: [key]));
            await _delayInterruptibly(const Duration(milliseconds: 50));
          }
          break;
      }

      // Delay between repetitions
      if (i < config.repeatCount - 1) {
        await _delayInterruptibly(
          Duration(milliseconds: config.delayBetweenMs),
        );
      }
    }
  }

  Future<void> _executeLaunchApp(DesktopFlowNode node) async {
    final app = node.appName ?? '';
    final appPath = node.appPath;
    if (app.isEmpty && (appPath == null || appPath.isEmpty)) {
      throw FlowExecutionException('No app specified');
    }

    try {
      await _input.execute(
        DesktopAction(type: 'launch_app', appName: app, appPath: appPath),
      );
    } catch (e) {
      if (appPath == null || appPath.isEmpty || app.isEmpty) rethrow;
      _log.warn(
        'FlowExec',
        'Direct app launch failed, falling back to search: $e',
      );
      await _input.execute(DesktopAction(type: 'launch_app', appName: app));
    }

    _preferLastLaunchedApp = true;
    _activeLaunchedAppName = app.isNotEmpty ? app : null;
    _activeLaunchedAppPath = appPath;
    _log.info(
      'FlowExec',
      'Launch App: UIA scan scope set to ${app.isNotEmpty ? app : appPath}',
    );

    await _delayInterruptibly(const Duration(milliseconds: 500));
  }

  Future<void> _executeDelay(DesktopFlowNode node) async {
    final ms = node.delayMs ?? 1000;
    _log.info('FlowExec', 'Waiting ${ms}ms...');
    await _delayInterruptibly(Duration(milliseconds: ms));
  }

  Future<void> _executeScreenshot() async {
    await _input.execute(const DesktopAction(type: 'take_screenshot'));
    _log.info('FlowExec', 'Screenshot captured via Python bridge');
  }

  Future<void> _executeScroll(DesktopFlowNode node) async {
    await _input.execute(
      DesktopAction(
        type: 'scroll',
        direction: node.scrollDirection ?? 'down',
        amount: node.scrollAmount ?? 3,
      ),
    );
  }

  Future<void> _executeSwipe(DesktopFlowNode node) async {
    final duration = node.swipeDuration ?? 350;
    // Default start: screen center (960, 540 for 1920x1080)
    final startX = node.swipeStartX?.toDouble() ?? 960;
    final startY = node.swipeStartY?.toDouble() ?? 540;

    double endX;
    double endY;

    // Prefer explicit endpoints (from the screen picker) over direction+distance.
    if (node.swipeEndX != null && node.swipeEndY != null) {
      endX = node.swipeEndX!.toDouble();
      endY = node.swipeEndY!.toDouble();
    } else {
      final dir = node.swipeDirection ?? 'down';
      final dist = (node.swipeDistance ?? 300).toDouble();
      endX = startX;
      endY = startY;
      switch (dir) {
        case 'up':
          endY = startY - dist;
          break;
        case 'down':
          endY = startY + dist;
          break;
        case 'left':
          endX = startX - dist;
          break;
        case 'right':
          endX = startX + dist;
          break;
      }
    }

    _log.info(
      'FlowExec',
      'Swipe: (${startX.toInt()}, ${startY.toInt()}) -> '
          '(${endX.toInt()}, ${endY.toInt()}) ${duration}ms',
    );

    await _input.execute(
      DesktopAction(
        type: 'drag',
        x: startX,
        y: startY,
        endX: endX,
        endY: endY,
        durationMs: duration,
        coordinateSpace: 'screen',
      ),
    );
  }

  /// For conditional nodes, evaluate the configured condition and return
  /// the branch target connected to true/false.
  Future<DesktopFlowNode> _resolveConditionalBranch(
    DesktopFlowNode condNode,
    DesktopFlow flow,
  ) async {
    final outEdges = flow.outgoingEdges(condNode.id);
    final conditionMet = await _evaluateCondition(condNode);

    DesktopFlowEdge? trueEdge;
    DesktopFlowEdge? falseEdge;
    for (final edge in outEdges) {
      final label = edge.label?.toLowerCase();
      if (label == 'true' || label == 'success') trueEdge = edge;
      if (label == 'false' || label == 'failure') falseEdge = edge;
    }

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
      'Conditional "${condNode.label}": ${conditionMet ? "TRUE" : "FALSE"} -> ${targetNode.label}',
    );

    return targetNode;
  }

  Future<bool> _evaluateCondition(DesktopFlowNode node) async {
    final operator =
        node.conditionOperator ?? node.conditionAttribute ?? 'element_exists';
    final element = await _findCurrentElement(node.target);

    switch (operator) {
      case 'element_exists':
        return element != null;
      case 'element_missing':
        return element == null;
      case 'name_contains':
        return element != null &&
            element.name.toLowerCase().contains(_conditionNeedle(node));
      case 'name_equals':
        return element != null &&
            element.name.toLowerCase() == _conditionNeedle(node);
      case 'value_contains':
        return element != null &&
            (element.value ?? '').toLowerCase().contains(
              _conditionNeedle(node),
            );
      case 'value_equals':
        return element != null &&
            (element.value ?? '').toLowerCase() == _conditionNeedle(node);
      case 'role_equals':
        return element != null &&
            element.role.toLowerCase() == _conditionNeedle(node);
      case 'class_contains':
        return element != null &&
            (element.className ?? '').toLowerCase().contains(
              _conditionNeedle(node),
            );
      case 'enabled':
        return element?.isEnabled ?? false;
      case 'focused':
        return element?.isFocused ?? false;
      default:
        return element != null;
    }
  }

  String _conditionNeedle(DesktopFlowNode node) {
    return (node.conditionValue ?? '').trim().toLowerCase();
  }

  // ═══════════════════════════════════════════════════════
  //  VISUAL TRIGGER EXECUTION
  // ═══════════════════════════════════════════════════════

  /// Execute a visual trigger node by waiting for the template to appear.
  Future<void> _executeVisualTrigger(DesktopFlowNode node) async {
    final templatePath = node.templateImagePath;
    if (templatePath == null || templatePath.isEmpty) {
      throw FlowExecutionException(
        'Visual Trigger: No template image configured',
      );
    }

    final threshold = node.matchThreshold ?? 0.8;
    final action = node.visualAction ?? 'click';
    final searchRegion = _visualSearchRegion(node);

    _log.info(
      'FlowExec',
      'Visual Trigger: waiting for "$templatePath" @ ${(threshold * 100).toInt()}%',
    );

    const timeout = Duration(seconds: 30);
    const pollInterval = Duration(milliseconds: 500);
    final started = DateTime.now();
    Map<String, dynamic>? match;
    var bestConfidence = 0.0;

    while (!_stopRequested && DateTime.now().difference(started) < timeout) {
      final rawResult = await _bridge.sendCommand('template_match', {
        'templatePath': templatePath,
        'threshold': threshold,
        if (searchRegion != null) 'searchRegion': searchRegion,
      });

      final result = rawResult is Map
          ? rawResult.map((key, value) => MapEntry(key.toString(), value))
          : <String, dynamic>{};
      final confidence = (result['confidence'] as num?)?.toDouble() ?? 0.0;
      if (confidence > bestConfidence) bestConfidence = confidence;

      if (result['found'] as bool? ?? false) {
        match = result;
        break;
      }

      await _delayInterruptibly(pollInterval);
    }

    if (_stopRequested) {
      throw const FlowExecutionException('Visual Trigger: stopped');
    }
    if (match == null) {
      throw FlowExecutionException(
        'Visual Trigger: Template not found within ${timeout.inSeconds}s (best ${(bestConfidence * 100).toInt()}%)',
      );
    }

    final matchX = (match['x'] as num?)?.toDouble();
    final matchY = (match['y'] as num?)?.toDouble();
    final confidence = (match['confidence'] as num?)?.toDouble() ?? 0.0;

    _log.info(
      'FlowExec',
      'Visual Trigger: Found at ($matchX, $matchY) confidence=${(confidence * 100).toInt()}%',
    );

    switch (action) {
      case 'click':
      case 'double_click':
      case 'right_click':
        if (matchX == null || matchY == null) {
          throw FlowExecutionException(
            'Visual Trigger: Match coordinates unavailable',
          );
        }
        await _input.execute(
          DesktopAction(
            type: action,
            x: matchX,
            y: matchY,
            button: action == 'right_click' ? 'right' : 'left',
            coordinateSpace: 'screen',
          ),
        );
        break;
      case 'wait':
        _log.info('FlowExec', 'Visual Trigger: Wait satisfied');
        break;
      case 'assert_exists':
        _log.info('FlowExec', 'Visual Trigger: Assert passed');
        break;
      default:
        throw FlowExecutionException(
          'Visual Trigger: Unsupported action "$action"',
        );
    }
  }

  Map<String, dynamic>? _visualSearchRegion(DesktopFlowNode node) {
    if (node.searchRegionX == null ||
        node.searchRegionY == null ||
        node.searchRegionWidth == null ||
        node.searchRegionHeight == null) {
      return null;
    }
    return {
      'x': node.searchRegionX,
      'y': node.searchRegionY,
      'width': node.searchRegionWidth,
      'height': node.searchRegionHeight,
    };
  }

  // ═══════════════════════════════════════════════════════
  //  UI DETECT EXECUTION
  // ═══════════════════════════════════════════════════════

  /// Execute a UI detect node — find elements by accessibility attributes.
  Future<void> _executeUIDetect(DesktopFlowNode node) async {
    final action = node.detectAction ?? 'click_first';

    _log.info(
      'FlowExec',
      'UI Detect: action=$action target=${node.target?.summary ?? "none"}',
    );

    // Guard: fail early if no attributes are configured
    if (node.target == null ||
        (node.target!.mode == UITargetMode.uiaAttribute &&
            !node.target!.hasAnyAttribute)) {
      throw FlowExecutionException(
        'UI Detect: No target attributes configured. '
        'Please pick an element or set attributes (name, role, automationId, className) first.',
      );
    }

    // For actions that need a match (click_first, extract_text), poll
    // until the element appears — just like _waitForTargetElement does
    // for regular click nodes. This handles timing issues where the
    // previous node's action hasn't settled in the accessibility tree yet.
    final needsMatch = action == 'click_first' || action == 'extract_text';
    final deadline = DateTime.now().add(
      needsMatch ? _targetResolveTimeout : Duration.zero,
    );
    var loggedWaiting = false;
    List<UIElement> matches = [];

    do {
      final screenState = await _getFlowScreenState(
        AutomationTier.accessibilityOnly,
      );

      // Find matching elements
      matches = <UIElement>[];
      if (node.target != null) {
        for (final element in screenState.elements) {
          if (element.isOffscreen || !element.isEnabled) continue;
          if (_isSystemSurfaceElement(element)) continue;
          if (_elementMatchesTarget(element, node.target!)) {
            matches.add(element);
          }
        }
      }

      if (matches.isNotEmpty || !needsMatch) break;

      // Still no match — log once and retry
      if (!loggedWaiting) {
        _log.info('FlowExec', 'UI Detect: Waiting for ${node.target?.summary}');
        loggedWaiting = true;
      }
      if (DateTime.now().isAfter(deadline) || _stopRequested) break;
      await _delayInterruptibly(_targetResolvePollInterval);
    } while (true);

    _log.info(
      'FlowExec',
      'UI Detect: Found ${matches.length} matching elements',
    );

    switch (action) {
      case 'click_first':
        if (matches.isEmpty) {
          throw FlowExecutionException(
            'UI Detect: No matching element found for ${node.target?.summary}',
          );
        }
        final element = _pickBestMatch(matches, node.target!);
        final params = _targetParamsForElement(element);
        _log.info(
          'FlowExec',
          'UI Detect: Clicking best match at '
              '(${params['x']?.toStringAsFixed(0) ?? params['targetStableId']}'
              '${params['y'] != null ? ', ${params['y']!.toStringAsFixed(0)}' : ''})'
              ' from ${matches.length} candidates',
        );
        await _input.execute(
          DesktopAction(
            type: 'click',
            x: params['x'] as double?,
            y: params['y'] as double?,
            targetStableId: params['targetStableId'] as String?,
            coordinateSpace: 'screen',
          ),
        );
        break;

      case 'count':
        _log.info('FlowExec', 'UI Detect: Count = ${matches.length}');
        // Store in context for downstream conditional nodes
        break;

      case 'extract_text':
        if (matches.isEmpty) {
          throw FlowExecutionException(
            'UI Detect: No matching element found for text extraction',
          );
        }
        final textElement = _pickBestMatch(matches, node.target!);
        final text = textElement.name;
        _log.info('FlowExec', 'UI Detect: Extracted text = "$text"');
        break;

      case 'wait_until_visible':
        // Poll for the element to appear (up to 10 seconds)
        const maxWait = Duration(seconds: 10);
        final start = DateTime.now();
        while (DateTime.now().difference(start) < maxWait && !_stopRequested) {
          final state = await _getFlowScreenState(
            AutomationTier.accessibilityOnly,
          );
          final found = state.elements.any(
            (e) =>
                !e.isOffscreen &&
                e.isEnabled &&
                _elementMatchesTarget(e, node.target!),
          );
          if (found) {
            _log.info('FlowExec', 'UI Detect: Element became visible');
            return;
          }
          await _delayInterruptibly(const Duration(milliseconds: 500));
        }
        throw FlowExecutionException(
          'UI Detect: Element did not appear within timeout',
        );

      default:
        _log.info('FlowExec', 'UI Detect: Unknown action "$action"');
    }
  }

  /// Pick the best match from attribute-matched elements using
  /// spatial proximity, size similarity, and text matching.
  UIElement _pickBestMatch(List<UIElement> matches, UITargetSelector target) {
    if (matches.length == 1 || !target.hasHint) return matches.first;

    UIElement? best;
    double bestScore = double.infinity; // lower = better

    for (final el in matches) {
      double score = 0;
      final bb = el.boundingBox;
      final elW = _asDouble(bb['width']);
      final elH = _asDouble(bb['height']);
      final cx = _asDouble(bb['x']) + elW / 2;
      final cy = _asDouble(bb['y']) + elH / 2;

      // 1. Spatial proximity (primary signal — Euclidean distance)
      if (target.hintX != null && target.hintY != null) {
        final dx = cx - target.hintX!;
        final dy = cy - target.hintY!;
        score += sqrt(dx * dx + dy * dy);
      }

      // 2. Size similarity penalty (amplified to differentiate same-area elements)
      if (target.hintWidth != null && target.hintHeight != null) {
        final wRatio =
            (elW - target.hintWidth!).abs() / max(target.hintWidth!, 1.0);
        final hRatio =
            (elH - target.hintHeight!).abs() / max(target.hintHeight!, 1.0);
        score += (wRatio + hRatio) * 50;
      }

      // 3. Text/value match bonus (subtract to reward matches)
      if (target.hintValue != null && target.hintValue!.isNotEmpty) {
        if ((el.value != null && el.value == target.hintValue) ||
            el.name == target.hintValue) {
          score -= 100; // strong bonus for exact text match
        }
      }

      if (best == null || score < bestScore) {
        best = el;
        bestScore = score;
      }
    }

    _log.info(
      'FlowExec',
      'UI Detect: Best match score=${bestScore.toStringAsFixed(1)} at (${_asDouble(best!.boundingBox['x']).toStringAsFixed(0)}, ${_asDouble(best.boundingBox['y']).toStringAsFixed(0)}) hint=(${target.hintX?.toStringAsFixed(0) ?? '?'}, ${target.hintY?.toStringAsFixed(0) ?? '?'})',
    );

    return best;
  }

  /// Check if a UI element matches a target selector.
  bool _elementMatchesTarget(UIElement element, UITargetSelector target) {
    switch (target.mode) {
      case UITargetMode.coordinate:
        return true; // Coordinate mode doesn't filter by attributes
      case UITargetMode.stableId:
        return target.stableId != null && element.stableId == target.stableId;
      case UITargetMode.uiaAttribute:
        // If no attributes are set, match nothing (safety net)
        if (!target.hasAnyAttribute) return false;
        if (target.name != null && target.name!.isNotEmpty) {
          if (!element.name.toLowerCase().contains(
            target.name!.toLowerCase(),
          )) {
            return false;
          }
        }
        if (target.role != null && target.role!.isNotEmpty) {
          if (element.role.toLowerCase() != target.role!.toLowerCase()) {
            return false;
          }
        }
        if (target.automationId != null && target.automationId!.isNotEmpty) {
          if (element.automationId != target.automationId) {
            return false;
          }
        }
        if (target.className != null && target.className!.isNotEmpty) {
          if (element.className?.toLowerCase() !=
              target.className!.toLowerCase()) {
            return false;
          }
        }
        return true;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  UNLOCK NODE
  // ═══════════════════════════════════════════════════════════════

  Future<void> _executeUnlock(DesktopFlowNode node) async {
    final password = await _credentials.getUnlockPassword(node.id);
    if (password == null || password.isEmpty) {
      throw FlowExecutionException(
        'No unlock password configured for node "${node.label}"',
      );
    }

    _log.info('FlowExec', 'Sending unlock command to desktop agent');

    // sendCommand returns response['data'] on success, throws
    // PythonBridgeException on failure — no need to check 'success' key.
    await _bridge.sendCommand('unlock_desktop', {'password': password});

    _log.info('FlowExec', 'Unlock command completed');
  }

  // ═══════════════════════════════════════════════════════════════
  //  DATA ITERATOR NODE
  // ═══════════════════════════════════════════════════════════════

  /// Executes the Data Iterator node: enumerates children of a container
  /// element and runs a sub-flow for each child.
  ///
  /// The sub-flow is found by following the "body" edge from this node.
  /// After all iterations, follows the "done"/"success" edge.
  Future<void> executeDataIterator(
    DesktopFlowNode node,
    DesktopFlow flow, {
    void Function(FlowStepProgress)? onProgress,
  }) async {
    final config = node.dataIteratorConfig ?? const DataIteratorConfig();
    final containerTarget = node.containerTarget;

    void emitProgress(FlowStepProgress progress) {
      _currentProgress = progress;
      onProgress?.call(progress);
      notifyListeners();
    }

    if (containerTarget == null) {
      throw FlowExecutionException(
        'No container element configured for Data Iterator "${node.label}"',
      );
    }

    _log.info(
      'FlowExec',
      'Data Iterator: enumerating children of container '
          '(class=${containerTarget.className ?? "?"}, '
          'autoId=${containerTarget.automationId ?? "?"}, '
          'role=${containerTarget.role ?? "?"}, '
          'name=${containerTarget.name ?? "?"})...',
    );

    // Build payload from the container target's UIA attributes
    final payload = <String, dynamic>{
      'sortBy': config.direction.name,
      'itemMode': config.itemMode.name,
    };
    if (containerTarget.stableId != null) {
      payload['stableId'] = containerTarget.stableId;
    }
    if (containerTarget.automationId != null) {
      payload['automationId'] = containerTarget.automationId;
    }
    if (containerTarget.className != null) {
      payload['className'] = containerTarget.className;
    }
    if (containerTarget.name != null) {
      payload['name'] = containerTarget.name;
    }
    if (containerTarget.role != null) {
      payload['role'] = containerTarget.role;
    }

    // Child filters — only iterate children matching these criteria
    if (config.childRoleFilter != null && config.childRoleFilter!.isNotEmpty) {
      payload['childRoleFilter'] = config.childRoleFilter;
    }
    if (config.childClassNameFilter != null &&
        config.childClassNameFilter!.isNotEmpty) {
      payload['childClassNameFilter'] = config.childClassNameFilter;
    }

    // Ask Python agent to enumerate children
    // sendCommand returns response['data'] on success, throws on failure.
    final result = await _bridge.sendCommand('enumerate_children', payload);

    // result IS the data payload directly (not wrapped in success/data)
    final data = result as Map<String, dynamic>? ?? {};
    final children = (data['children'] as List<dynamic>?) ?? [];
    final totalItems = children.length;

    if (totalItems == 0) {
      final suitability = data['containerSuitability'] as String? ?? 'unknown';
      final hint = suitability == 'pane' || suitability == 'unknown'
          ? ' The selected element is a "${suitability.toUpperCase()}" — '
                'try picking a List, Grid, or Tree element instead.'
          : '';
      _log.info(
        'FlowExec',
        'Data Iterator: no children found in container '
            '(class=${containerTarget.className ?? "?"}, '
            'role=${containerTarget.role ?? "?"}, '
            'suitability=$suitability).$hint',
      );
      return;
    }

    final unfilteredCount = data['unfilteredCount'] as int?;
    final directChildCount = data['directChildCount'] as int?;
    final itemModeUsed = data['itemModeUsed'] as String?;

    if (itemModeUsed == 'visualGroups' &&
        directChildCount != null &&
        directChildCount != totalItems) {
      _log.info(
        'FlowExec',
        'Data Iterator: found $totalItems visual items '
            '(grouped from $directChildCount child elements)',
      );
    } else if (unfilteredCount != null && unfilteredCount != totalItems) {
      _log.info(
        'FlowExec',
        'Data Iterator: found $totalItems children (filtered from $unfilteredCount)',
      );
    } else {
      _log.info('FlowExec', 'Data Iterator: found $totalItems children');
    }

    // Find the "body" sub-flow target
    DesktopFlowNode? bodyTarget;
    for (final edge in flow.outgoingEdges(node.id)) {
      final label = edge.label?.toLowerCase();
      if (label == 'body') {
        bodyTarget = flow.findNode(edge.toNodeId);
        break;
      }
    }

    // Fallback: use success edge as body if no explicit "body" edge
    bodyTarget ??= _resolveSuccessBranch(node, flow);

    if (bodyTarget == null) {
      _log.info('FlowExec', 'Data Iterator: no body sub-flow connected');
      return;
    }

    // Iterate through each child
    for (int i = 0; i < totalItems; i++) {
      if (_stopRequested) break;

      final child = children[i] as Map<String, dynamic>;
      final childName = child['name'] as String? ?? '';
      final childValue = child['value'] as String? ?? '';
      final centerX = (child['centerX'] as num?)?.toDouble() ?? 0;
      final centerY = (child['centerY'] as num?)?.toDouble() ?? 0;

      // Set context variables for this iteration
      _executionContext[config.contextVariableName] = childName.isNotEmpty
          ? childName
          : childValue;
      _executionContext['current_index'] = i.toString();
      _executionContext['total_items'] = totalItems.toString();

      _log.info(
        'FlowExec',
        'Data Iterator: item ${i + 1}/$totalItems — '
            '"${_executionContext[config.contextVariableName]}"',
      );

      emitProgress(
        FlowStepProgress(
          flowId: flow.id,
          status: 'iterator_step',
          message:
              'Iterating item ${i + 1}/$totalItems: '
              '${_executionContext[config.contextVariableName]}',
          currentStep: i + 1,
          totalSteps: totalItems,
          nodeLabel: node.label,
          nodeId: node.id,
        ),
      );

      // Click on the child element if configured
      try {
        if (config.clickEachItem && centerX > 0 && centerY > 0) {
          await _input.execute(
            DesktopAction(
              type: 'click',
              x: centerX,
              y: centerY,
              coordinateSpace: 'screen',
            ),
          );
          await _delayInterruptibly(const Duration(milliseconds: 200));
        }

        // Execute the body sub-flow chain
        DesktopFlowNode? current = bodyTarget;
        while (current != null && !_stopRequested) {
          if (current.nodeType == DesktopFlowNodeType.done) break;
          // Stop if we loop back to the iterator itself
          if (current.id == node.id) break;

          await _executeNode(current, flow);
          await _delayInterruptibly(const Duration(milliseconds: 100));

          // Follow the success edge of each body node
          current = _resolveSuccessBranch(current, flow);
        }
      } catch (e) {
        if (config.continueOnError) {
          _log.warn(
            'FlowExec',
            'Data Iterator: item ${i + 1}/$totalItems failed — $e '
                '(continuing to next item)',
          );
        } else {
          rethrow;
        }
      }

      // Delay between iterations
      if (i < totalItems - 1 && config.delayBetweenMs > 0) {
        await _delayInterruptibly(
          Duration(milliseconds: config.delayBetweenMs),
        );
      }
    }

    // Clear context variables after iteration completes
    _executionContext.remove(config.contextVariableName);
    _executionContext.remove('current_index');
    _executionContext.remove('total_items');

    _log.info('FlowExec', 'Data Iterator: completed all $totalItems items');
  }
}

/// Thrown when a flow execution step fails.
class FlowExecutionException implements Exception {
  final String message;
  const FlowExecutionException(this.message);
  @override
  String toString() => 'FlowExecutionException: $message';
}
