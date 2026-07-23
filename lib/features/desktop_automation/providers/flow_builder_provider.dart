import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/logging_service.dart';
import '../models/automation_tier.dart';
import '../models/desktop_flow_models.dart';
import '../models/screen_state.dart';
import '../models/system_app_info.dart';
import '../services/accessibility_tree_service.dart';
import '../services/flow_execution_service.dart';
import '../services/flow_storage_service.dart';
import '../services/python_bridge_service.dart';
import '../services/secure_credential_service.dart';

/// State management for the flow builder canvas and flow list.
///
/// Manages the current flow being edited, node/edge CRUD,
/// canvas state (pan/zoom), execution, and persistence.
class FlowBuilderProvider extends ChangeNotifier {
  final FlowStorageService _storage;
  final FlowExecutionService _execution;
  final AccessibilityTreeService _a11y;
  final PythonBridgeService _bridge;
  final LoggingService _log;
  final SecureCredentialService _credentials;

  FlowBuilderProvider({
    required FlowStorageService storage,
    required FlowExecutionService execution,
    required AccessibilityTreeService a11y,
    required PythonBridgeService bridge,
    required LoggingService log,
    required SecureCredentialService credentials,
  }) : _storage = storage,
       _execution = execution,
       _a11y = a11y,
       _bridge = bridge,
       _log = log,
       _credentials = credentials;

  // ── State ──────────────────────────────────────────────

  /// All saved flows for the list view.
  List<DesktopFlow> _flows = [];
  List<DesktopFlow> get flows => _flows;

  /// The flow currently open in the builder.
  DesktopFlow? _currentFlow;
  DesktopFlow? get currentFlow => _currentFlow;

  /// Currently selected node ID.
  String? _selectedNodeId;
  String? get selectedNodeId => _selectedNodeId;

  /// Node being connected from (output port → waiting for target click).
  String? _connectingFromNodeId;
  String? get connectingFromNodeId => _connectingFromNodeId;

  /// Whether a flow is currently executing.
  bool get isExecuting => _execution.isRunning;

  /// The node currently being executed (for highlighting).
  String? _executingNodeId;
  String? get executingNodeId => _executingNodeId;

  /// Execution progress messages.
  final List<FlowStepProgress> _progressLog = [];
  List<FlowStepProgress> get progressLog => List.unmodifiable(_progressLog);

  /// Last execution result.
  FlowExecutionResult? _lastResult;
  FlowExecutionResult? get lastResult => _lastResult;

  /// Cached installed apps for Launch App nodes.
  List<SystemAppInfo> _availableApps = [];
  List<SystemAppInfo> get availableApps => List.unmodifiable(_availableApps);

  bool _isLoadingApps = false;
  bool get isLoadingApps => _isLoadingApps;

  String? _appLoadError;
  String? get appLoadError => _appLoadError;

  /// Whether the builder panel is showing (vs the list).
  bool _isBuilderOpen = false;
  bool get isBuilderOpen => _isBuilderOpen;

  /// Whether changes have been made since last save.
  bool _isDirty = false;
  bool get isDirty => _isDirty;

  // ── Loading ─────────────────────────────────────────────

  /// Load all saved flows from disk.
  Future<void> loadFlows() async {
    _flows = await _storage.listFlows();
    notifyListeners();
  }

  /// Open the builder with an existing flow.
  Future<void> openFlow(String id) async {
    final flow = await _storage.loadFlow(id);
    if (flow != null) {
      // Auto-migrate old Data Iterator edges: success → body
      _migrateDataIteratorEdges(flow);
      _currentFlow = flow;
      _selectedNodeId = null;
      _connectingFromNodeId = null;
      _isBuilderOpen = true;
      _isDirty = false;
      _progressLog.clear();
      _lastResult = null;
      notifyListeners();
    }
  }

  /// Migrate old flows: for Data Iterator nodes, rename 'success' edges
  /// to 'body' if there's no explicit 'body' edge already.
  void _migrateDataIteratorEdges(DesktopFlow flow) {
    bool migrated = false;
    for (final node in flow.nodes) {
      if (node.nodeType != DesktopFlowNodeType.dataIterator) continue;

      final outgoing = flow.outgoingEdges(node.id).toList();
      final hasBody = outgoing.any(
        (e) => e.label?.toLowerCase() == 'body',
      );
      if (hasBody) continue; // already migrated

      for (final edge in outgoing) {
        if (edge.label?.toLowerCase() == 'success') {
          edge.label = 'body';
          migrated = true;
          break; // only rename the first success edge
        }
      }
    }
    if (migrated) {
      // Save the migrated flow silently
      _storage.saveFlow(flow);
    }
  }

  /// Create a new empty flow and open it in the builder.
  void newFlow(String name, {String description = ''}) {
    _currentFlow = DesktopFlow.empty(name, description: description);
    _selectedNodeId = null;
    _connectingFromNodeId = null;
    _isBuilderOpen = true;
    _isDirty = true;
    _progressLog.clear();
    _lastResult = null;
    notifyListeners();
  }

  /// Close the builder and return to the list.
  void closeBuilder() {
    _isBuilderOpen = false;
    _selectedNodeId = null;
    _connectingFromNodeId = null;
    notifyListeners();
  }

  // ── Node CRUD ──────────────────────────────────────────

  /// Add a new node at the given canvas position.
  void addNode(DesktopFlowNodeType type, double x, double y) {
    if (_currentFlow == null) return;

    final node = DesktopFlowNode(
      nodeType: type,
      label: type.displayName,
      x: x,
      y: y,
    );

    // Set default configs for certain types
    if (type == DesktopFlowNodeType.keyboard ||
        type == DesktopFlowNodeType.hotkey) {
      node.keyboardConfig = const KeyboardNodeConfig(keys: []);
    } else if (type == DesktopFlowNodeType.typeText) {
      node.autoDetectInput = true;
    } else if (type == DesktopFlowNodeType.conditional) {
      node.conditionOperator = 'element_exists';
    } else if (type == DesktopFlowNodeType.delay) {
      node.delayMs = 1000;
    } else if (type == DesktopFlowNodeType.scroll) {
      node.scrollDirection = 'down';
      node.scrollAmount = 3;
    } else if (type == DesktopFlowNodeType.repeat) {
      node.repeatCount = 3;
    } else if (type == DesktopFlowNodeType.visualTrigger) {
      node.matchThreshold = 0.8;
      node.visualAction = 'click';
    } else if (type == DesktopFlowNodeType.uiDetect) {
      node.detectAction = 'click_first';
      node.detectOutputKey = 'detected_element';
      node.target = const UITargetSelector(mode: UITargetMode.uiaAttribute);
    } else if (type == DesktopFlowNodeType.unlock) {
      node.unlockMethod = 'password';
    } else if (type == DesktopFlowNodeType.dataIterator) {
      node.dataIteratorConfig = const DataIteratorConfig();
    }

    _currentFlow!.nodes.add(node);
    _selectedNodeId = node.id;
    _isDirty = true;
    notifyListeners();
  }

  /// Remove a node and all its connected edges.
  void removeNode(String nodeId) {
    if (_currentFlow == null) return;

    // Clean up secure credentials for unlock nodes
    final node = _currentFlow!.findNode(nodeId);
    if (node != null && node.nodeType == DesktopFlowNodeType.unlock) {
      _credentials.deleteUnlockPassword(nodeId);
    }

    _currentFlow!.nodes.removeWhere((n) => n.id == nodeId);
    _currentFlow!.edges.removeWhere(
      (e) => e.fromNodeId == nodeId || e.toNodeId == nodeId,
    );

    if (_selectedNodeId == nodeId) _selectedNodeId = null;
    _isDirty = true;
    notifyListeners();
  }

  /// Update a node's properties.
  void updateNode(DesktopFlowNode updatedNode) {
    if (_currentFlow == null) return;

    final idx = _currentFlow!.nodes.indexWhere((n) => n.id == updatedNode.id);
    if (idx != -1) {
      _currentFlow!.nodes[idx] = updatedNode;
      _isDirty = true;
      notifyListeners();
    }
  }

  /// Move a node to a new canvas position.
  void moveNode(String nodeId, double x, double y) {
    if (_currentFlow == null) return;

    final node = _currentFlow!.findNode(nodeId);
    if (node != null) {
      // Clamp to keep nodes within the visible canvas area.
      // Prevents dragging into negative coords where the grid isn't drawn
      // and hit-testing fails (nodes become stuck).
      node.x = x.clamp(0.0, 19800.0); // canvasSize(20000) - nodeWidth(~170)
      node.y = y.clamp(0.0, 19900.0); // canvasSize(20000) - nodeHeight(~80)
      _isDirty = true;
      notifyListeners();
    }
  }

  // ── Edge CRUD ──────────────────────────────────────────

  /// The label for the pending connection ("success" or "failure").
  String? _connectingEdgeLabel;
  String? get connectingEdgeLabel => _connectingEdgeLabel;

  /// Begin connecting from a node's output port.
  void startConnecting(String nodeId, {String? label}) {
    _connectingFromNodeId = nodeId;
    _connectingEdgeLabel = label;
    notifyListeners();
  }

  /// Complete the connection to a target node.
  void completeConnection(String toNodeId) {
    if (_currentFlow == null || _connectingFromNodeId == null) return;
    if (_connectingFromNodeId == toNodeId) {
      // Can't connect to self
      _connectingFromNodeId = null;
      _connectingEdgeLabel = null;
      notifyListeners();
      return;
    }

    // Check for duplicate edge with same label
    final exists = _currentFlow!.edges.any(
      (e) =>
          e.fromNodeId == _connectingFromNodeId &&
          e.toNodeId == toNodeId &&
          e.label == _connectingEdgeLabel,
    );

    if (!exists) {
      if (_connectingEdgeLabel != null) {
        _currentFlow!.edges.removeWhere(
          (e) =>
              e.fromNodeId == _connectingFromNodeId &&
              e.label == _connectingEdgeLabel,
        );
      }

      final edge = DesktopFlowEdge.create(
        fromNodeId: _connectingFromNodeId!,
        toNodeId: toNodeId,
        label: _connectingEdgeLabel,
      );
      _currentFlow!.edges.add(edge);
      _isDirty = true;
    }

    _connectingFromNodeId = null;
    _connectingEdgeLabel = null;
    notifyListeners();
  }

  /// Cancel an in-progress connection.
  void cancelConnection() {
    _connectingFromNodeId = null;
    _connectingEdgeLabel = null;
    notifyListeners();
  }

  /// Remove an edge by ID.
  void removeEdge(String edgeId) {
    if (_currentFlow == null) return;
    _currentFlow!.edges.removeWhere((e) => e.id == edgeId);
    _isDirty = true;
    notifyListeners();
  }

  /// Update the label on an existing edge (for conditional true/false editing).
  void updateEdgeLabel(String edgeId, String? newLabel) {
    if (_currentFlow == null) return;
    final edge = _currentFlow!.findEdge(edgeId);
    if (edge != null) {
      edge.label = newLabel;
      _isDirty = true;
      notifyListeners();
    }
  }

  // ── Selection ──────────────────────────────────────────

  /// Select a node (opens config panel).
  void selectNode(String? nodeId) {
    _selectedNodeId = nodeId;
    notifyListeners();
  }

  /// Get the currently selected node.
  DesktopFlowNode? get selectedNode {
    if (_selectedNodeId == null || _currentFlow == null) return null;
    return _currentFlow!.findNode(_selectedNodeId!);
  }

  // -- Desktop helpers --------------------------------------

  Future<ScreenState> captureTargetScreen() {
    return _a11y.getScreenState(AutomationTier.treeWithFullScreenshot);
  }

  Future<Map<String, dynamic>?> selectScreenRegion({
    required bool requireArea,
  }) async {
    final response = await _bridge.sendCommand('select_screen_region', {
      'requireArea': requireArea,
    });
    if (response is! Map) return null;
    final result = response.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    if (result['cancelled'] == true) return null;
    return result;
  }

  /// Opens the interactive UI element picker overlay.
  ///
  /// The Python bridge shows a fullscreen overlay with bounding boxes
  /// around clickable elements. If screenshots are blocked, it falls
  /// back to a searchable list dialog. Returns the selected element's
  /// UIA attributes, or `null` if cancelled.
  Future<Map<String, dynamic>?> selectUIElement() async {
    final response = await _bridge.sendCommand('select_ui_element');
    if (response is! Map) return null;
    final result = response.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    if (result['cancelled'] == true) return null;
    return result;
  }

  /// Opens a fullscreen overlay where the user clicks to place start and end
  /// swipe markers.  Returns {startX, startY, endX, endY} in screen coords,
  /// or `null` if cancelled.
  Future<Map<String, dynamic>?> selectSwipePoints() async {
    final response = await _bridge.sendCommand('select_swipe_points');
    if (response is! Map) return null;
    final result = response.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    if (result['cancelled'] == true) return null;
    return result;
  }

  Future<String> saveVisualTemplate(String nodeId, Uint8List pngBytes) async {
    final flow = _currentFlow;
    if (flow == null) {
      throw StateError('No flow is open');
    }

    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    final dir = Directory(
      p.join(home, '.autonion', 'visual_templates', flow.id),
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final safeNodeId = nodeId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final file = File(p.join(dir.path, '$safeNodeId.png'));
    await file.writeAsBytes(pngBytes, flush: true);
    _log.info('FlowBuilder', 'Saved visual template: ${file.path}');
    return file.path;
  }

  Future<void> loadAvailableApps({bool force = false}) async {
    if (_isLoadingApps) return;
    if (!force && _availableApps.isNotEmpty) return;

    _isLoadingApps = true;
    _appLoadError = null;
    notifyListeners();

    try {
      final response = await _bridge.sendCommand('list_apps');
      final rawApps = response is List
          ? response
          : response is Map
          ? response['apps'] as List<dynamic>? ?? const []
          : const [];

      _availableApps =
          rawApps
              .whereType<Map>()
              .map(
                (raw) => SystemAppInfo.fromJson(
                  raw.map((key, value) => MapEntry(key.toString(), value)),
                ),
              )
              .where(
                (app) =>
                    app.name.trim().isNotEmpty && app.path.trim().isNotEmpty,
              )
              .toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
    } catch (e) {
      _appLoadError = e.toString();
      _log.error('FlowBuilder', 'Failed to load installed apps: $e');
    } finally {
      _isLoadingApps = false;
      notifyListeners();
    }
  }

  // ── Flow Metadata ──────────────────────────────────────

  /// Update the flow's name.
  void updateFlowName(String name) {
    if (_currentFlow == null) return;
    _currentFlow!.name = name;
    _isDirty = true;
    notifyListeners();
  }

  /// Update the flow's description.
  void updateFlowDescription(String description) {
    if (_currentFlow == null) return;
    _currentFlow!.description = description;
    _isDirty = true;
    notifyListeners();
  }

  /// Update the flow's trigger.
  void updateFlowTrigger(FlowTrigger trigger) {
    if (_currentFlow == null) return;
    _currentFlow!.trigger = trigger;
    _isDirty = true;
    notifyListeners();
  }

  // ── Persistence ────────────────────────────────────────

  /// Save the current flow to disk.
  Future<void> saveFlow() async {
    if (_currentFlow == null) return;
    await _storage.saveFlow(_currentFlow!);
    _isDirty = false;
    await loadFlows(); // Refresh the list
    notifyListeners();
    _log.info('FlowBuilder', 'Flow saved: "${_currentFlow!.name}"');
  }

  /// Delete a flow by ID.
  Future<void> deleteFlow(String id) async {
    await _storage.deleteFlow(id);
    if (_currentFlow?.id == id) {
      _currentFlow = null;
      _isBuilderOpen = false;
    }
    await loadFlows();
    notifyListeners();
  }

  /// Duplicate a flow.
  Future<void> duplicateFlow(String id) async {
    await _storage.duplicateFlow(id);
    await loadFlows();
    notifyListeners();
  }

  /// Export a flow to a user-chosen file.
  Future<bool> exportFlow(String id) async {
    final flow = _flows.firstWhere(
      (f) => f.id == id,
      orElse: () => DesktopFlow(name: ''),
    );
    if (flow.name.isEmpty) return false;

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Flow',
      fileName: '${flow.name}.autonion.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result == null) return false; // User cancelled

    final success = await _storage.exportFlowToFile(id, result);
    if (success) {
      _log.info('FlowBuilder', 'Flow exported: "${flow.name}" → $result');
    }
    return success;
  }

  /// Import a flow from a user-chosen JSON file.
  Future<bool> importFlow() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import Flow',
      type: FileType.custom,
      allowedExtensions: ['json'],
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) return false;

    final filePath = result.files.single.path;
    if (filePath == null) return false;

    final flow = await _storage.importFlowFromFile(filePath);
    if (flow != null) {
      await loadFlows();
      notifyListeners();
      _log.info('FlowBuilder', 'Flow imported: "${flow.name}" from $filePath');
      return true;
    }
    return false;
  }

  /// Export the currently-open flow in the builder.
  Future<bool> exportCurrentFlow() async {
    if (_currentFlow == null) return false;

    // Save first to ensure we export the latest state
    if (_isDirty) await saveFlow();

    return exportFlow(_currentFlow!.id);
  }

  // ── Execution ──────────────────────────────────────────

  /// Run the current flow.
  Future<void> runFlow() async {
    if (_currentFlow == null || _execution.isRunning) return;

    _progressLog.clear();
    _lastResult = null;
    _executingNodeId = null;
    notifyListeners();

    _lastResult = await _execution.executeFlow(
      _currentFlow!,
      onProgress: (progress) {
        _progressLog.add(progress);
        _executingNodeId = progress.nodeId;
        notifyListeners();
      },
    );

    _executingNodeId = null;
    notifyListeners();
  }

  /// Run a saved flow by ID (used by WebSocket trigger).
  Future<FlowExecutionResult> runFlowById(
    String id, {
    void Function(FlowStepProgress)? onProgress,
  }) async {
    final flow = await _storage.loadFlow(id);
    if (flow == null) {
      return const FlowExecutionResult(
        success: false,
        stepsExecuted: 0,
        errorMessage: 'Flow not found',
        elapsed: Duration.zero,
      );
    }

    return _execution.executeFlow(flow, onProgress: onProgress);
  }

  /// Stop the currently running flow.
  void stopFlow() {
    _execution.stopFlow();
    _executingNodeId = null;
    notifyListeners();
  }

  // ── Unlock credential delegates ──────────────────────────

  /// Save an unlock password for a node to secure storage.
  Future<void> saveUnlockPassword(String nodeId, String password) async {
    await _credentials.saveUnlockPassword(nodeId, password);

    // Update the node's flag so the UI shows the 🔒 indicator
    final node = _currentFlow?.findNode(nodeId);
    if (node != null) {
      node.hasUnlockPassword = true;
      _isDirty = true;
      notifyListeners();
    }
  }

  /// Delete the unlock password for a node.
  Future<void> deleteUnlockPassword(String nodeId) async {
    await _credentials.deleteUnlockPassword(nodeId);

    final node = _currentFlow?.findNode(nodeId);
    if (node != null) {
      node.hasUnlockPassword = false;
      _isDirty = true;
      notifyListeners();
    }
  }

  /// Check if an unlock password exists for a node.
  Future<bool> hasUnlockPassword(String nodeId) async {
    return _credentials.hasUnlockPassword(nodeId);
  }
}
