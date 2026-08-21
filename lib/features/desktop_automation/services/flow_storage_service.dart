import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/services/logging_service.dart';
import '../models/desktop_flow_models.dart';

/// File-based persistence for Desktop flows.
///
/// Each flow is stored as a JSON file at `~/.autonion/flows/<id>.json`.
/// The service handles CRUD operations and provides lightweight manifests
/// for listing/syncing without loading full flow graphs.
class FlowStorageService {
  final LoggingService _log;
  late final Directory _flowsDir;
  bool _initialized = false;

  FlowStorageService({required LoggingService log}) : _log = log;

  /// Ensure the flows directory exists. Called lazily on first operation.
  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    _flowsDir = Directory(p.join(home, '.autonion', 'flows'));

    if (!await _flowsDir.exists()) {
      await _flowsDir.create(recursive: true);
      _log.info('FlowStorage', 'Created flows directory: ${_flowsDir.path}');
    }
    _initialized = true;
  }

  /// Path for a given flow ID.
  String _flowPath(String id) => p.join(_flowsDir.path, '$id.json');

  /// Save a flow to disk. Updates `updatedAt` timestamp.
  Future<void> saveFlow(DesktopFlow flow) async {
    await _ensureInitialized();
    flow.updatedAt = DateTime.now();
    final file = File(_flowPath(flow.id));
    final json = const JsonEncoder.withIndent('  ').convert(flow.toJson());
    await file.writeAsString(json);
    _log.info('FlowStorage', 'Saved flow: "${flow.name}" (${flow.id})');
  }

  /// Load a single flow by ID. Returns null if not found.
  Future<DesktopFlow?> loadFlow(String id) async {
    await _ensureInitialized();
    final file = File(_flowPath(id));
    if (!await file.exists()) {
      _log.warn('FlowStorage', 'Flow not found: $id');
      return null;
    }

    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return DesktopFlow.fromJson(json);
    } catch (e) {
      _log.error('FlowStorage', 'Failed to load flow $id: $e');
      return null;
    }
  }

  /// List all saved flows (full objects).
  Future<List<DesktopFlow>> listFlows() async {
    await _ensureInitialized();
    final flows = <DesktopFlow>[];

    if (!await _flowsDir.exists()) return flows;

    await for (final entity in _flowsDir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          flows.add(DesktopFlow.fromJson(json));
        } catch (e) {
          _log.warn(
            'FlowStorage',
            'Skipping corrupt flow file: ${entity.path}: $e',
          );
        }
      }
    }

    // Sort by most recently updated first
    flows.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return flows;
  }

  /// Delete a flow by ID. Returns true if deleted, false if not found.
  Future<bool> deleteFlow(String id) async {
    await _ensureInitialized();
    final file = File(_flowPath(id));
    if (await file.exists()) {
      await file.delete();
      _log.info('FlowStorage', 'Deleted flow: $id');
      return true;
    }
    _log.warn('FlowStorage', 'Cannot delete — flow not found: $id');
    return false;
  }

  /// Check if a flow exists on disk.
  Future<bool> flowExists(String id) async {
    await _ensureInitialized();
    return File(_flowPath(id)).exists();
  }

  /// Return lightweight manifests for all flows (for sync to Android).
  Future<List<FlowManifest>> listFlowManifests() async {
    final flows = await listFlows();
    return flows.map((f) => FlowManifest.fromFlow(f)).toList();
  }

  /// Duplicate an existing flow with a new ID and name.
  Future<DesktopFlow?> duplicateFlow(String id, {String? newName}) async {
    final original = await loadFlow(id);
    if (original == null) return null;

    final duplicate = DesktopFlow(
      name: newName ?? '${original.name} (Copy)',
      description: original.description,
      version: original.version,
      nodes: original.nodes
          .map((n) => DesktopFlowNode.fromJson(n.toJson()))
          .toList(),
      edges: original.edges
          .map((e) => DesktopFlowEdge.fromJson(e.toJson()))
          .toList(),
      tags: List<String>.from(original.tags),
      trigger: FlowTrigger.fromJson(original.trigger.toJson()),
    );

    await saveFlow(duplicate);
    _log.info(
      'FlowStorage',
      'Duplicated flow "${original.name}" → "${duplicate.name}"',
    );
    return duplicate;
  }

  /// Export a flow to a file at the given path.
  Future<bool> exportFlowToFile(String id, String filePath) async {
    final flow = await loadFlow(id);
    if (flow == null) {
      _log.warn('FlowStorage', 'Cannot export — flow not found: $id');
      return false;
    }

    try {
      final json = const JsonEncoder.withIndent('  ').convert(flow.toJson());
      final file = File(filePath);
      await file.writeAsString(json);
      _log.info('FlowStorage', 'Exported flow "${flow.name}" to: $filePath');
      return true;
    } catch (e) {
      _log.error('FlowStorage', 'Failed to export flow: $e');
      return false;
    }
  }

  /// Import a flow from a JSON file. Assigns a new ID to avoid collisions.
  Future<DesktopFlow?> importFlowFromFile(String filePath) async {
    await _ensureInitialized();

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _log.warn('FlowStorage', 'Import file not found: $filePath');
        return null;
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final imported = DesktopFlow.fromJson(json);

      // Assign a new ID to avoid collisions with existing flows
      final newFlow = DesktopFlow(
        name: imported.name,
        description: imported.description,
        version: imported.version,
        nodes: imported.nodes
            .map((n) => DesktopFlowNode.fromJson(n.toJson()))
            .toList(),
        edges: imported.edges
            .map((e) => DesktopFlowEdge.fromJson(e.toJson()))
            .toList(),
        tags: List<String>.from(imported.tags),
        trigger: FlowTrigger.fromJson(imported.trigger.toJson()),
      );

      await saveFlow(newFlow);
      _log.info(
        'FlowStorage',
        'Imported flow "${newFlow.name}" from: $filePath',
      );
      return newFlow;
    } catch (e) {
      _log.error('FlowStorage', 'Failed to import flow: $e');
      return null;
    }
  }

  /// Create a flow from AI action history (cross-device "Save as Flow").
  ///
  /// Converts a list of action maps (from DesktopAgentService._history)
  /// into a proper DesktopFlow with auto-layout and edge wiring.
  Future<DesktopFlow?> createFlowFromActionHistory(
    String flowName,
    List<Map<String, dynamic>> actionHistory,
  ) async {
    await _ensureInitialized();

    try {
      final nodes = <DesktopFlowNode>[];
      final edges = <DesktopFlowEdge>[];

      // ── Start node ──
      const startX = 9900.0;
      const startY = 10000.0;
      const hSpacing = 250.0;

      final startNode = DesktopFlowNode(
        nodeType: DesktopFlowNodeType.start,
        label: 'Start',
        x: startX,
        y: startY,
      );
      nodes.add(startNode);

      // ── Pre-process: merge common AI action patterns ──
      // The AI uses hotkey+type+hotkey sequences to launch apps and
      // type+hotkey sequences to enter commands. These are fragile as
      // individual flow nodes — merge them into purpose-built node types.
      final mergedActions = _preprocessActionHistory(actionHistory);

      String previousNodeId = startNode.id;
      int actionIndex = 0;

      for (final entry in mergedActions) {
        final actionMap = entry['action'] as Map<String, dynamic>?;
        if (actionMap == null) continue;

        final type =
            (actionMap['type'] ?? actionMap['action'])?.toString() ?? '';
        if (type == 'done' ||
            type == 'needs_browser' ||
            type == 'wait' && actionMap['durationMs'] == null) {
          continue; // Skip non-actionable entries
        }

        final thought =
            entry['thought']?.toString() ?? actionMap['thought']?.toString();
        final node = _actionToFlowNode(
          actionMap,
          type,
          thought,
          actionIndex,
          startX,
          startY,
          hSpacing,
        );
        if (node == null) continue;

        nodes.add(node);
        edges.add(
          DesktopFlowEdge.create(fromNodeId: previousNodeId, toNodeId: node.id),
        );
        previousNodeId = node.id;
        actionIndex++;
      }

      // ── Done node ──
      final doneNode = DesktopFlowNode(
        nodeType: DesktopFlowNodeType.done,
        label: 'Done',
        x: startX + (actionIndex + 1) * hSpacing,
        y: startY,
      );
      nodes.add(doneNode);
      edges.add(
        DesktopFlowEdge.create(
          fromNodeId: previousNodeId,
          toNodeId: doneNode.id,
        ),
      );

      final flow = DesktopFlow(
        name: flowName,
        description: 'Generated from AI prompt execution',
        nodes: nodes,
        edges: edges,
        tags: ['ai-generated'],
      );

      await saveFlow(flow);
      _log.info(
        'FlowStorage',
        'Created flow "$flowName" from ${actionHistory.length} AI actions '
        '(${mergedActions.length} after merge → $actionIndex flow nodes)',
      );
      return flow;
    } catch (e) {
      _log.error('FlowStorage', 'Failed to create flow from actions: $e');
      return null;
    }
  }

  /// Convert a single action map into a DesktopFlowNode.
  DesktopFlowNode? _actionToFlowNode(
    Map<String, dynamic> actionMap,
    String type,
    String? thought,
    int index,
    double startX,
    double startY,
    double hSpacing,
  ) {
    final x = startX + (index + 1) * hSpacing;
    final y = startY;
    final settleDelayMs = _settleDelayForAction(type, actionMap);

    switch (type) {
      case 'click':
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.click,
          label: thought ?? 'Click',
          x: x,
          y: y,
          target: _targetFromAction(actionMap),
          settleDelayMs: settleDelayMs,
        );
      case 'double_click':
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.doubleClick,
          label: thought ?? 'Double Click',
          x: x,
          y: y,
          target: _targetFromAction(actionMap),
          settleDelayMs: settleDelayMs,
        );
      case 'right_click':
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.rightClick,
          label: thought ?? 'Right Click',
          x: x,
          y: y,
          target: _targetFromAction(actionMap),
          settleDelayMs: settleDelayMs,
        );
      case 'type':
        final typeTarget = _targetFromAction(actionMap);
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.typeText,
          label: thought ?? 'Type Text',
          x: x,
          y: y,
          text: actionMap['text']?.toString(),
          target: typeTarget,
          // When the AI typed without a target, it typed into whatever was
          // focused (e.g. a terminal/CMD window). Disable auto-detect to
          // preserve that behaviour — UIA auto-detection would scan for
          // standard edit controls and potentially click an unrelated field.
          autoDetectInput: typeTarget != null,
          postAction: _nonEmpty(actionMap['_postAction']),
          settleDelayMs: settleDelayMs,
        );
      case 'drag':
        final startDragX = _asInt(actionMap['x']);
        final startDragY = _asInt(actionMap['y']);
        final endDragX = _asInt(actionMap['endX']);
        final endDragY = _asInt(actionMap['endY']);
        if (startDragX == null ||
            startDragY == null ||
            endDragX == null ||
            endDragY == null) {
          return null;
        }
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.swipe,
          label: thought ?? 'Drag',
          x: x,
          y: y,
          swipeStartX: startDragX,
          swipeStartY: startDragY,
          swipeEndX: endDragX,
          swipeEndY: endDragY,
          swipeDuration: _asInt(actionMap['durationMs']) ?? 500,
          settleDelayMs: settleDelayMs,
        );
      case 'scroll':
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.scroll,
          label: thought ?? 'Scroll',
          x: x,
          y: y,
          scrollDirection: actionMap['direction']?.toString() ?? 'down',
          scrollAmount: _asInt(actionMap['amount']) ?? 3,
          settleDelayMs: settleDelayMs,
        );
      case 'hotkey':
        final keys =
            (actionMap['keys'] as List<dynamic>?)
                ?.map((k) => k.toString())
                .where((k) => k.isNotEmpty)
                .toList() ??
            [];
        if (keys.isEmpty) return null;
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.keyboard,
          label: thought ?? 'Keyboard: ${keys.join('+')}',
          x: x,
          y: y,
          keyboardConfig: KeyboardNodeConfig(keys: keys),
          settleDelayMs: settleDelayMs,
        );
      case 'wait':
        final delayMs = _asInt(actionMap['durationMs']) ?? 1000;
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.delay,
          label: thought ?? 'Wait',
          x: x,
          y: y,
          delayMs: delayMs < 250 ? 250 : delayMs,
          settleDelayMs: settleDelayMs,
        );
      case 'launch_app':
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.launchApp,
          label: thought ?? 'Launch App',
          x: x,
          y: y,
          appName: _nonEmpty(actionMap['appName']),
          appPath: _nonEmpty(actionMap['appPath']),
          settleDelayMs: settleDelayMs,
        );
      case 'take_screenshot':
        return DesktopFlowNode(
          nodeType: DesktopFlowNodeType.screenshot,
          label: thought ?? 'Screenshot',
          x: x,
          y: y,
          settleDelayMs: settleDelayMs,
        );
      default:
        _log.warn('FlowStorage', 'Skipping unsupported AI action: $type');
        return null;
    }
  }

  int _settleDelayForAction(String type, Map<String, dynamic> actionMap) {
    switch (type) {
      case 'launch_app':
        return 2500;
      case 'hotkey':
        final keys =
            (actionMap['keys'] as List<dynamic>?)
                ?.map((k) => k.toString().toLowerCase())
                .toList() ??
            [];
        if (keys.contains('enter') || keys.contains('return')) return 1800;
        if (keys.contains('win') || keys.contains('super')) return 700;
        return 500;
      case 'click':
      case 'double_click':
      case 'right_click':
      case 'drag':
        return 700;
      case 'type':
      case 'scroll':
      case 'take_screenshot':
        return 500;
      default:
        return 200;
    }
  }

  /// Build a UITargetSelector from an action's recorded target snapshot.
  ///
  /// AI execution resolves target ids against a live accessibility snapshot.
  /// A saved flow needs more durable data, so prefer recorded UIA attributes
  /// with spatial hints, then coordinates, and only then the ephemeral id.
  UITargetSelector? _targetFromAction(Map<String, dynamic> actionMap) {
    final xVal = _asDouble(actionMap['x']);
    final yVal = _asDouble(actionMap['y']);
    final name = _nonEmpty(actionMap['targetName']);
    final automationId = _nonEmpty(actionMap['targetAutomationId']);
    final className = _nonEmpty(actionMap['targetClassName']);
    final role = _nonEmpty(actionMap['targetRole']);
    final controlType = _nonEmpty(actionMap['targetControlType']);
    final hintValue = _nonEmpty(actionMap['targetHintValue']);

    if (name != null || automationId != null || className != null) {
      return UITargetSelector.fromAttributes(
        automationId: automationId,
        className: className,
        name: name,
        role: role,
        controlType: controlType,
        hintX: _asDouble(actionMap['targetHintX']) ?? xVal,
        hintY: _asDouble(actionMap['targetHintY']) ?? yVal,
        hintWidth: _asDouble(actionMap['targetHintWidth']),
        hintHeight: _asDouble(actionMap['targetHintHeight']),
        hintValue: hintValue,
      );
    }

    if (xVal != null && yVal != null) {
      return UITargetSelector.coordinate(xVal, yVal);
    }

    final stableId = _nonEmpty(actionMap['targetStableId']);
    if (stableId != null) {
      return UITargetSelector.fromStableId(stableId);
    }

    return null;
  }

  static double? _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _nonEmpty(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text == 'null') return null;
    return text;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  AI ACTION HISTORY PRE-PROCESSING
  // ═══════════════════════════════════════════════════════════════════

  /// Pre-process the raw AI action history to detect and merge common
  /// multi-step patterns into single, more robust flow nodes.
  ///
  /// Patterns detected:
  /// 1. **App Launch**: hotkey(['win']) → type(name) → hotkey(['enter'])
  ///    Merged into a single `launch_app` action.
  /// 2. **Type-then-Enter/Tab**: type(text) → hotkey(['enter'/'tab'])
  ///    Merged into a single `type` action with `_postAction` metadata.
  List<Map<String, dynamic>> _preprocessActionHistory(
    List<Map<String, dynamic>> raw,
  ) {
    // First, extract only actionable entries (with an action map and valid type).
    final actionable = <Map<String, dynamic>>[];
    for (final entry in raw) {
      final actionMap = entry['action'] as Map<String, dynamic>?;
      if (actionMap == null) continue;
      final type =
          (actionMap['type'] ?? actionMap['action'])?.toString() ?? '';
      if (type.isEmpty) continue;
      // Skip rejected actions — they never actually executed.
      final result = entry['result'];
      if (result is Map && result['status'] == 'rejected') continue;
      actionable.add(entry);
    }

    final merged = <Map<String, dynamic>>[];
    int i = 0;

    while (i < actionable.length) {
      final entry = actionable[i];
      final actionMap = entry['action'] as Map<String, dynamic>;
      final type =
          (actionMap['type'] ?? actionMap['action'])?.toString() ?? '';

      // ── Pattern 1: App Launch ──
      // hotkey(['win']) → type(appName) → hotkey(['enter'])
      if (type == 'hotkey' &&
          _isWinKeyOnly(actionMap) &&
          i + 2 < actionable.length) {
        final next = actionable[i + 1];
        final nextAction = next['action'] as Map<String, dynamic>;
        final nextType =
            (nextAction['type'] ?? nextAction['action'])?.toString() ?? '';

        if (nextType == 'type') {
          final afterNext = actionable[i + 2];
          final afterAction = afterNext['action'] as Map<String, dynamic>;
          final afterType =
              (afterAction['type'] ?? afterAction['action'])?.toString() ?? '';

          if (afterType == 'hotkey' && _isEnterOnly(afterAction)) {
            // Merge all three into a launch_app action.
            final appName = nextAction['text']?.toString() ?? '';
            _log.info(
              'FlowStorage',
              'Merging Win→Type→Enter into launch_app: "$appName"',
            );
            merged.add({
              'thought': 'Launch $appName',
              'action': <String, dynamic>{
                'type': 'launch_app',
                'appName': appName,
              },
            });
            i += 3; // Skip all three entries
            continue;
          }
        }
      }

      // ── Pattern 2: Type-then-Enter/Tab ──
      // type(text) → hotkey(['enter']) or hotkey(['tab'])
      if (type == 'type' && i + 1 < actionable.length) {
        final next = actionable[i + 1];
        final nextAction = next['action'] as Map<String, dynamic>;
        final nextType =
            (nextAction['type'] ?? nextAction['action'])?.toString() ?? '';

        if (nextType == 'hotkey') {
          final postKey = _singlePostActionKey(nextAction);
          if (postKey != null) {
            // Merge type + hotkey into a single type with _postAction.
            final mergedAction = Map<String, dynamic>.from(actionMap);
            mergedAction['_postAction'] = postKey;
            _log.info(
              'FlowStorage',
              'Merging Type+Hotkey($postKey) into typeText with postAction',
            );
            merged.add({
              'thought': entry['thought'],
              'action': mergedAction,
            });
            i += 2; // Skip both entries
            continue;
          }
        }
      }

      // No pattern matched — keep the entry as-is.
      merged.add(entry);
      i++;
    }

    return merged;
  }

  /// True if the hotkey action is Win key only (opening Start menu).
  bool _isWinKeyOnly(Map<String, dynamic> actionMap) {
    final keys = (actionMap['keys'] as List<dynamic>?)
        ?.map((k) => k.toString().toLowerCase())
        .where((k) => k.isNotEmpty)
        .toList();
    if (keys == null || keys.length != 1) return false;
    return keys.first == 'win' || keys.first == 'super';
  }

  /// True if the hotkey action is Enter only.
  bool _isEnterOnly(Map<String, dynamic> actionMap) {
    final keys = (actionMap['keys'] as List<dynamic>?)
        ?.map((k) => k.toString().toLowerCase())
        .where((k) => k.isNotEmpty)
        .toList();
    if (keys == null || keys.length != 1) return false;
    return keys.first == 'enter' || keys.first == 'return';
  }

  /// If the hotkey is a single post-action key (enter or tab), return it.
  /// Returns null for multi-key combos or non-post-action keys.
  String? _singlePostActionKey(Map<String, dynamic> actionMap) {
    final keys = (actionMap['keys'] as List<dynamic>?)
        ?.map((k) => k.toString().toLowerCase())
        .where((k) => k.isNotEmpty)
        .toList();
    if (keys == null || keys.length != 1) return null;
    final key = keys.first;
    if (key == 'enter' || key == 'return') return 'enter';
    if (key == 'tab') return 'tab';
    return null;
  }
}
