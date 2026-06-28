import 'dart:async';

import '../../../core/services/logging_service.dart';
import '../models/desktop_flow_models.dart';
import 'input_simulation_service.dart';
import 'accessibility_tree_service.dart';
import '../models/automation_tier.dart';
import '../models/desktop_action.dart';
import '../models/ui_element.dart';

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
            currentNode = _resolveSuccessBranch(currentNode, flow) ?? nextNodes.first;
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

  /// Resolve click coordinates from a UITargetSelector.
  /// For UIA modes, queries the accessibility tree and uses the element center.
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
        if (target.stableId == null) {
          throw FlowExecutionException('Stable ID not set');
        }
        await _a11y.getScreenState(AutomationTier.accessibilityOnly);
        return {'targetStableId': target.stableId};

      case UITargetMode.uiaAttribute:
        return await _findElementByAttributes(target);
    }
  }

  /// Search the accessibility tree for an element matching UIA attributes.
  Future<Map<String, dynamic>> _findElementByAttributes(
    UITargetSelector target,
  ) async {
    final screenState = await _a11y.getScreenState(
      AutomationTier.accessibilityOnly,
    );
    final element = _findElementInList(screenState.elements, target);
    if (element == null) {
      throw FlowExecutionException(
        'Element not found matching: ${target.summary}',
      );
    }
    return _targetParamsForElement(element);
  }

  Future<UIElement?> _findCurrentElement(
    UITargetSelector? target, {
    bool requireEditable = false,
  }) async {
    final screenState = await _a11y.getScreenState(
      AutomationTier.accessibilityOnly,
    );
    if (target == null) {
      return _bestElement(screenState.elements, requireEditable: requireEditable);
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

    return _bestElement(candidates, requireEditable: requireEditable);
  }

  UIElement? _bestElement(
    List<UIElement> elements, {
    bool requireEditable = false,
  }) {
    final candidates = elements.where((element) {
      if (element.isOffscreen || !element.isEnabled) return false;
      if (requireEditable && !_isEditableElement(element)) return false;
      return !requireEditable || element.isKeyboardFocusable || element.isFocused;
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
    if (element.stableId != null && element.stableId!.isNotEmpty) {
      return {'targetStableId': element.stableId};
    }
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
      await Future.delayed(const Duration(milliseconds: 150));
    }

    await _input.execute(DesktopAction(
      type: 'type',
      text: node.text ?? '',
    ));
  }

  Future<void> _clickTarget(Map<String, dynamic> targetParams) {
    return _input.execute(DesktopAction(
      type: 'click',
      x: targetParams['x'] as double?,
      y: targetParams['y'] as double?,
      targetStableId: targetParams['targetStableId'] as String?,
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
    final appPath = node.appPath;
    if (app.isEmpty && (appPath == null || appPath.isEmpty)) {
      throw FlowExecutionException('No app specified');
    }

    try {
      await _input.execute(DesktopAction(
        type: 'launch_app',
        appName: app,
        appPath: appPath,
      ));
    } catch (e) {
      if (appPath == null || appPath.isEmpty || app.isEmpty) rethrow;
      _log.warn(
        'FlowExec',
        'Direct app launch failed, falling back to search: $e',
      );
      await _input.execute(DesktopAction(
        type: 'launch_app',
        appName: app,
      ));
    }

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
    final operator = node.conditionOperator ?? node.conditionAttribute ?? 'element_exists';
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
            (element.value ?? '').toLowerCase().contains(_conditionNeedle(node));
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
}

/// Thrown when a flow execution step fails.
class FlowExecutionException implements Exception {
  final String message;
  const FlowExecutionException(this.message);
  @override
  String toString() => 'FlowExecutionException: $message';
}
