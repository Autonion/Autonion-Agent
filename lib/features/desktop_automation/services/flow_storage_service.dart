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

    final home = Platform.environment['USERPROFILE'] ??
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
}
