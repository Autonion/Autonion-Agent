import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/desktop_automation/models/desktop_flow_models.dart';
import '../../features/desktop_automation/providers/flow_builder_provider.dart';
import '../theme/app_colors.dart';

/// Production-grade visual flow builder with infinite canvas, draggable nodes,
/// edge drawing, node palette, and configuration panel.
class FlowBuilderScreen extends StatefulWidget {
  const FlowBuilderScreen({super.key});

  @override
  State<FlowBuilderScreen> createState() => _FlowBuilderScreenState();
}

class _FlowBuilderScreenState extends State<FlowBuilderScreen> {
  final TransformationController _transformCtrl = TransformationController();
  String? _draggingNodeId;

  static const double _canvasSize = 20000.0;

  // ── Edge connection drag state ──
  Offset? _pendingEdgeStart; // Canvas-space start of rubber-band
  Offset? _pendingEdgeEnd; // Canvas-space end of rubber-band (follows cursor)
  String? _pendingEdgeLabel; // "success" or "failure"

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<FlowBuilderProvider>(
      builder: (context, provider, _) {
        final flow = provider.currentFlow;
        if (flow == null) return const SizedBox.shrink();

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.delete ||
                    event.logicalKey == LogicalKeyboardKey.backspace)) {
              final selectedId = provider.selectedNodeId;
              if (selectedId != null) {
                final selectedNode = provider.selectedNode;
                if (selectedNode != null &&
                    selectedNode.nodeType != DesktopFlowNodeType.start &&
                    selectedNode.nodeType != DesktopFlowNodeType.done) {
                  provider.removeNode(selectedId);
                  return KeyEventResult.handled;
                }
              }
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            children: [
              // ── Toolbar ──────────────────────────────
              _buildToolbar(provider, flow),
              // ── Main content ─────────────────────────
              Expanded(
                child: Row(
                  children: [
                    // ── Node Palette (left) ────────────
                    _buildNodePalette(provider),
                    // ── Canvas (center) ────────────────
                    Expanded(child: _buildCanvas(provider, flow)),
                    // ── Config Panel (right) ───────────
                    if (provider.selectedNode != null)
                      _buildConfigPanel(provider),
                  ],
                ),
              ),
              // ── Execution Log ────────────────────────
              if (provider.progressLog.isNotEmpty || provider.isExecuting)
                _buildExecutionLog(provider),
            ],
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════
  //  TOOLBAR
  // ═══════════════════════════════════════════════════════

  Widget _buildToolbar(FlowBuilderProvider provider, DesktopFlow flow) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          // Back button
          IconButton(
            onPressed: provider.closeBuilder,
            icon: const Icon(Icons.arrow_back, color: AppColors.textSecondary),
            tooltip: 'Back to list',
          ),
          const SizedBox(width: 8),
          // Flow name
          Expanded(
            child: Row(
              children: [
                const Icon(
                  Icons.account_tree_rounded,
                  color: AppColors.accent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  flow.name,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (provider.isDirty)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Text(
                      '●',
                      style: TextStyle(color: AppColors.warning, fontSize: 10),
                    ),
                  ),
              ],
            ),
          ),
          // Trigger indicator
          _buildTriggerChip(flow.trigger),
          const SizedBox(width: 12),
          // Save button
          _toolbarButton(
            icon: Icons.save_outlined,
            label: 'Save',
            onPressed: provider.isDirty ? () => provider.saveFlow() : null,
          ),
          const SizedBox(width: 8),
          // Run / Stop button
          provider.isExecuting
              ? _toolbarButton(
                  icon: Icons.stop,
                  label: 'Stop',
                  color: AppColors.error,
                  onPressed: provider.stopFlow,
                )
              : _toolbarButton(
                  icon: Icons.play_arrow,
                  label: 'Run',
                  color: AppColors.success,
                  onPressed: () => provider.runFlow(),
                ),
        ],
      ),
    );
  }

  Widget _buildTriggerChip(FlowTrigger trigger) {
    return InkWell(
      onTap: () => _showTriggerDialog(context),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _triggerIcon(trigger.type),
              size: 14,
              color: AppColors.secondary,
            ),
            const SizedBox(width: 6),
            Text(
              trigger.summary,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _triggerIcon(FlowTriggerType type) {
    switch (type) {
      case FlowTriggerType.manual:
        return Icons.touch_app;
      case FlowTriggerType.hotkey:
        return Icons.keyboard;
      case FlowTriggerType.elementAppear:
        return Icons.visibility;
      case FlowTriggerType.scheduled:
        return Icons.schedule;
    }
  }

  Widget _toolbarButton({
    required IconData icon,
    required String label,
    Color? color,
    VoidCallback? onPressed,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: TextButton.styleFrom(
        foregroundColor: onPressed == null
            ? AppColors.textMuted
            : (color ?? AppColors.textSecondary),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  //  NODE PALETTE (left sidebar)
  // ═══════════════════════════════════════════════════════

  Widget _buildNodePalette(FlowBuilderProvider provider) {
    // Exclude start and done — they are auto-placed
    final types = DesktopFlowNodeType.values
        .where(
          (t) =>
              t != DesktopFlowNodeType.start &&
              t != DesktopFlowNodeType.done &&
              t != DesktopFlowNodeType.hotkey,
        )
        .toList();

    return Container(
      width: 180,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Text(
              'NODES',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: types.length,
              itemBuilder: (context, index) {
                final type = types[index];
                return _PaletteItem(
                  type: type,
                  onTap: () {
                    final sceneCenter = _transformCtrl.toScene(
                      const Offset(520, 280),
                    );
                    final r = math.Random();
                    provider.addNode(
                      type,
                      sceneCenter.dx + r.nextDouble() * 80,
                      sceneCenter.dy + r.nextDouble() * 80,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  //  CANVAS
  // ═══════════════════════════════════════════════════════

  Widget _buildCanvas(FlowBuilderProvider provider, DesktopFlow flow) {
    return GestureDetector(
      onTap: () {
        // Deselect when tapping canvas
        provider.selectNode(null);
        provider.cancelConnection();
      },
      child: ClipRect(
        child: Container(
          color: AppColors.background,
          child: InteractiveViewer(
            transformationController: _transformCtrl,
            boundaryMargin: const EdgeInsets.all(100000),
            constrained: false,
            clipBehavior: Clip.hardEdge,
            minScale: 0.3,
            maxScale: 3.0,
            child: SizedBox(
              width: _canvasSize,
              height: _canvasSize,
              child: CustomPaint(
                painter: _GridPainter(),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // ── Edges (drawn behind nodes) ──
                    CustomPaint(
                      painter: _EdgePainter(
                        nodes: flow.nodes,
                        edges: flow.edges,
                        executingNodeId: provider.executingNodeId,
                        pendingEdgeStart: _pendingEdgeStart,
                        pendingEdgeEnd: _pendingEdgeEnd,
                        pendingEdgeLabel: _pendingEdgeLabel,
                      ),
                      size: const Size(_canvasSize, _canvasSize),
                    ),
                    // ── Edge cut targets (between edges and nodes) ──
                    ...flow.edges.map(
                      (edge) => _buildEdgeCutTarget(provider, flow, edge),
                    ),
                    // ── Nodes ──
                    ...flow.nodes.map(
                      (node) => _buildNodeWidget(provider, node),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Node dimensions (must match _NodeCard / _EdgePainter)
  static const double _nodeWidth = 170.0;
  static const double _nodeHeight = 80.0; // approximate min height

  Widget _buildNodeWidget(FlowBuilderProvider provider, DesktopFlowNode node) {
    final isSelected = provider.selectedNodeId == node.id;
    final isExecuting = provider.executingNodeId == node.id;
    final isConnecting = provider.connectingFromNodeId != null;
    final isConnectionSource = provider.connectingFromNodeId == node.id;

    return Positioned(
      left: node.x,
      top: node.y,
      child: SizedBox(
        width: _nodeWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Input port (top-center) ──
            if (node.nodeType != DesktopFlowNodeType.start)
              GestureDetector(
                onTap: () {
                  if (isConnecting) {
                    provider.completeConnection(node.id);
                    setState(() {
                      _pendingEdgeStart = null;
                      _pendingEdgeEnd = null;
                      _pendingEdgeLabel = null;
                    });
                  }
                },
                child: _PortDot(
                  color: isConnecting && !isConnectionSource
                      ? AppColors.secondary
                      : AppColors.textMuted,
                  isInput: true,
                  pulsing: isConnecting && !isConnectionSource,
                ),
              )
            else
              const SizedBox(height: 12),

            // ── The node card body (draggable) ──
            GestureDetector(
              onTap: () {
                if (isConnecting) {
                  provider.completeConnection(node.id);
                  setState(() {
                    _pendingEdgeStart = null;
                    _pendingEdgeEnd = null;
                    _pendingEdgeLabel = null;
                  });
                } else {
                  provider.selectNode(node.id);
                }
              },
              onPanStart: (details) {
                _draggingNodeId = node.id;
              },
              onPanUpdate: (details) {
                if (_draggingNodeId == node.id) {
                  final scale = _transformCtrl.value.getMaxScaleOnAxis();
                  provider.moveNode(
                    node.id,
                    node.x + details.delta.dx / scale,
                    node.y + details.delta.dy / scale,
                  );
                }
              },
              onPanEnd: (_) => _draggingNodeId = null,
              child: _NodeCard(
                node: node,
                isSelected: isSelected,
                isExecuting: isExecuting,
                isConnecting: isConnecting,
                onDelete:
                    node.nodeType != DesktopFlowNodeType.start &&
                        node.nodeType != DesktopFlowNodeType.done
                    ? () => provider.removeNode(node.id)
                    : null,
              ),
            ),

            if (node.nodeType != DesktopFlowNodeType.done)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildOutputPort(
                    provider: provider,
                    node: node,
                    label: node.nodeType == DesktopFlowNodeType.conditional
                        ? 'true'
                        : 'success',
                    color: AppColors.success,
                    isConnectionSource: isConnectionSource,
                    portOffsetX: _nodeWidth / 2 - 16,
                  ),
                  const SizedBox(width: 8),
                  _buildOutputPort(
                    provider: provider,
                    node: node,
                    label: node.nodeType == DesktopFlowNodeType.conditional
                        ? 'false'
                        : 'failure',
                    color: AppColors.error,
                    isConnectionSource: isConnectionSource,
                    portOffsetX: _nodeWidth / 2 + 16,
                  ),
                ],
              )
            else
              const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// Build a single output port with drag-to-connect behavior.
  Widget _buildOutputPort({
    required FlowBuilderProvider provider,
    required DesktopFlowNode node,
    required String label,
    required Color color,
    required bool isConnectionSource,
    required double portOffsetX,
  }) {
    return GestureDetector(
      onPanStart: (_) {
        provider.startConnecting(node.id, label: label);
        setState(() {
          _pendingEdgeStart = Offset(
            node.x + portOffsetX,
            node.y + _nodeHeight + 14,
          );
          _pendingEdgeEnd = _pendingEdgeStart;
          _pendingEdgeLabel = label;
        });
      },
      onPanUpdate: (details) {
        if (_pendingEdgeEnd != null) {
          final scale = _transformCtrl.value.getMaxScaleOnAxis();
          setState(() {
            _pendingEdgeEnd = Offset(
              _pendingEdgeEnd!.dx + details.delta.dx / scale,
              _pendingEdgeEnd!.dy + details.delta.dy / scale,
            );
          });
        }
      },
      onPanEnd: (_) {
        if (_pendingEdgeEnd != null && provider.connectingFromNodeId != null) {
          final flow = provider.currentFlow;
          if (flow != null) {
            for (final target in flow.nodes) {
              if (target.id == node.id) continue;
              final targetRect = Rect.fromLTWH(
                target.x - 20,
                target.y - 20,
                _nodeWidth + 40,
                _nodeHeight + 40,
              );
              if (targetRect.contains(_pendingEdgeEnd!)) {
                provider.completeConnection(target.id);
                break;
              }
            }
          }
        }
        provider.cancelConnection();
        setState(() {
          _pendingEdgeStart = null;
          _pendingEdgeEnd = null;
          _pendingEdgeLabel = null;
        });
      },
      child: Tooltip(
        message: '$label — drag to connect',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PortDot(
              color: isConnectionSource && provider.connectingEdgeLabel == label
                  ? color
                  : color.withValues(alpha: 0.5),
              isInput: false,
              pulsing: false,
            ),
            Text(
              _portSymbol(label),
              style: TextStyle(
                fontSize: 8,
                color: color.withValues(alpha: 0.7),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  bool _isFailureLabel(String? label) {
    return label == 'failure' || label == 'false';
  }

  String _portSymbol(String label) {
    switch (label) {
      case 'success':
      case 'true':
        return String.fromCharCode(0x2713);
      case 'failure':
      case 'false':
        return String.fromCharCode(0x2717);
      default:
        return '-';
    }
  }

  //  EDGE CUT TARGETS
  // ═══════════════════════════════════════════════════════

  Widget _buildEdgeCutTarget(
    FlowBuilderProvider provider,
    DesktopFlow flow,
    DesktopFlowEdge edge,
  ) {
    final fromNode = flow.findNode(edge.fromNodeId);
    final toNode = flow.findNode(edge.toNodeId);
    if (fromNode == null || toNode == null) return const SizedBox.shrink();

    // Calculate midpoint (same logic as EdgePainter)
    const nodeWidth = 170.0;
    const nodeHeight = 80.0;
    final portOffsetX = _isFailureLabel(edge.label)
        ? nodeWidth / 2 + 16
        : nodeWidth / 2 - 16;

    final fromX = fromNode.x + portOffsetX;
    final fromY = fromNode.y + nodeHeight + 14;
    final toX = toNode.x + nodeWidth / 2;
    final toY = toNode.y;

    final midX = (fromX + toX) / 2;
    final midY = (fromY + toY) / 2;

    final edgeColor = _isFailureLabel(edge.label)
        ? AppColors.error
        : AppColors.success;

    return Positioned(
      left: midX - 14,
      top: midY - 14,
      child: _EdgeCutButton(
        color: edgeColor,
        onCut: () => provider.removeEdge(edge.id),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  //  CONFIG PANEL (right sidebar)
  // ═══════════════════════════════════════════════════════

  Widget _buildConfigPanel(FlowBuilderProvider provider) {
    final node = provider.selectedNode!;

    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      Icon(
                        _nodeIcon(node.nodeType),
                        color: AppColors.accent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          node.nodeType.displayName,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: AppColors.divider),
                  const SizedBox(height: 12),

                  // Label
                  _configField('Label', node.label, (val) {
                    node.label = val;
                    provider.updateNode(node);
                  }),

                  // Type-specific fields
                  ..._buildTypeSpecificFields(provider, node),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildTypeSpecificFields(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    final widgets = <Widget>[];

    switch (node.nodeType) {
      case DesktopFlowNodeType.click:
      case DesktopFlowNodeType.doubleClick:
      case DesktopFlowNodeType.rightClick:
        widgets.add(_buildTargetSection(provider, node));
        break;

      case DesktopFlowNodeType.typeText:
        widgets.add(_buildTypeTextSection(provider, node));
        break;

      case DesktopFlowNodeType.keyboard:
      case DesktopFlowNodeType.hotkey:
        widgets.add(_buildKeyboardSection(provider, node));
        break;

      case DesktopFlowNodeType.launchApp:
        widgets.add(_buildLaunchAppSection(provider, node));
        break;

      case DesktopFlowNodeType.delay:
        widgets.add(
          _configField(
            'Delay (milliseconds)',
            (node.delayMs ?? 1000).toString(),
            (val) {
              node.delayMs = int.tryParse(val) ?? 1000;
              provider.updateNode(node);
            },
            isNumber: true,
          ),
        );
        break;

      case DesktopFlowNodeType.scroll:
        widgets.add(_buildScrollSection(provider, node));
        break;

      case DesktopFlowNodeType.swipe:
        widgets.add(_buildSwipeSection(provider, node));
        break;

      case DesktopFlowNodeType.repeat:
        widgets.add(
          _configField('Repeat count', (node.repeatCount ?? 3).toString(), (
            val,
          ) {
            node.repeatCount = int.tryParse(val) ?? 3;
            provider.updateNode(node);
          }, isNumber: true),
        );
        break;

      case DesktopFlowNodeType.conditional:
        widgets.add(_buildConditionalSection(provider, node));
        break;

      case DesktopFlowNodeType.visualTrigger:
        widgets.add(_buildVisualTriggerSection(provider, node));
        break;

      case DesktopFlowNodeType.uiDetect:
        widgets.add(_buildUIDetectSection(provider, node));
        break;

      case DesktopFlowNodeType.unlock:
        widgets.add(_buildUnlockSection(provider, node));
        break;

      case DesktopFlowNodeType.dataIterator:
        widgets.add(_buildDataIteratorSection(provider, node));
        break;

      default:
        break;
    }

    return widgets;
  }

  Widget _buildTypeTextSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          value: node.autoDetectInput,
          contentPadding: EdgeInsets.zero,
          activeColor: AppColors.primary,
          title: const Text(
            'Auto detect input field',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
          ),
          onChanged: (value) {
            node.autoDetectInput = value;
            provider.updateNode(node);
          },
        ),
        _buildTargetSection(
          provider,
          node,
          title: node.autoDetectInput ? 'LIMIT / FALLBACK AREA' : 'TARGET',
        ),
        const SizedBox(height: 12),
        _configField('Text to type', node.text ?? '', (val) {
          node.text = val;
          provider.updateNode(node);
        }, maxLines: 3),
      ],
    );
  }

  Widget _buildLaunchAppSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _configField(
                'Application name',
                node.appName ?? '',
                (val) {
                  node.appName = val;
                  node.appPath = null;
                  provider.updateNode(node);
                },
                hintText: 'e.g. notepad, calculator, chrome',
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: IconButton.filledTonal(
                onPressed: () => _showAppPicker(provider, node),
                icon: const Icon(Icons.apps, size: 18),
                tooltip: 'Select installed app',
              ),
            ),
          ],
        ),
        if ((node.appPath ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              node.appPath!,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _buildConditionalSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    final operator =
        node.conditionOperator ?? node.conditionAttribute ?? 'element_exists';
    final needsValue = <String>{
      'name_contains',
      'name_equals',
      'value_contains',
      'value_equals',
      'role_equals',
      'class_contains',
    }.contains(operator);

    // Resolve edge routing
    final flow = provider.currentFlow;
    String? trueTarget;
    String? falseTarget;
    if (flow != null) {
      for (final edge in flow.outgoingEdges(node.id)) {
        final label = edge.label?.toLowerCase();
        final targetNode = flow.findNode(edge.toNodeId);
        final targetName = targetNode?.label ?? 'Unknown';
        if (label == 'true' || label == 'success') {
          trueTarget = targetName;
        } else if (label == 'false' || label == 'failure') {
          falseTarget = targetName;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDropdown<String>(
          label: 'Condition',
          value: operator,
          items: const [
            DropdownMenuItem(
              value: 'element_exists',
              child: Text('Target exists'),
            ),
            DropdownMenuItem(
              value: 'element_missing',
              child: Text('Target missing'),
            ),
            DropdownMenuItem(
              value: 'name_contains',
              child: Text('Name contains'),
            ),
            DropdownMenuItem(value: 'name_equals', child: Text('Name equals')),
            DropdownMenuItem(
              value: 'value_contains',
              child: Text('Value contains'),
            ),
            DropdownMenuItem(
              value: 'value_equals',
              child: Text('Value equals'),
            ),
            DropdownMenuItem(value: 'role_equals', child: Text('Role equals')),
            DropdownMenuItem(
              value: 'class_contains',
              child: Text('Class contains'),
            ),
            DropdownMenuItem(value: 'enabled', child: Text('Enabled')),
            DropdownMenuItem(value: 'focused', child: Text('Focused')),
          ],
          onChanged: (value) {
            if (value == null) return;
            node.conditionOperator = value;
            node.conditionAttribute = value;
            provider.updateNode(node);
          },
        ),
        if (needsValue)
          _configField('Compare value', node.conditionValue ?? '', (val) {
            node.conditionValue = val;
            provider.updateNode(node);
          }),
        _buildTargetSection(provider, node),

        // Edge routing summary
        const SizedBox(height: 16),
        const Divider(color: AppColors.divider),
        const SizedBox(height: 8),
        const Text(
          'EDGE ROUTING',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        _buildEdgeRoutingRow(
          icon: Icons.check_circle_outline,
          label: 'True',
          target: trueTarget,
          color: AppColors.success,
        ),
        const SizedBox(height: 4),
        _buildEdgeRoutingRow(
          icon: Icons.cancel_outlined,
          label: 'False',
          target: falseTarget,
          color: AppColors.error,
        ),
        const SizedBox(height: 4),
        Text(
          'Connect edges from the True/False output ports below the node.',
          style: TextStyle(
            color: AppColors.textMuted.withValues(alpha: 0.7),
            fontSize: 10,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Widget _buildEdgeRoutingRow({
    required IconData icon,
    required String label,
    required String? target,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          '$label → ',
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        Expanded(
          child: Text(
            target ?? '(not connected)',
            style: TextStyle(
              color: target != null
                  ? AppColors.textPrimary
                  : AppColors.textMuted,
              fontSize: 12,
              fontStyle: target == null ? FontStyle.italic : FontStyle.normal,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════
  //  VISUAL TRIGGER CONFIG
  // ═══════════════════════════════════════════════════════

  Widget _buildVisualTriggerSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Capture template button
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _captureTemplateRegion(provider, node),
            icon: const Icon(Icons.crop, size: 16),
            label: const Text('Capture Template Region'),
          ),
        ),
        const SizedBox(height: 8),

        // Template preview
        if (node.templateImagePath != null &&
            node.templateImagePath!.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: 88,
                    width: double.infinity,
                    child: Image.file(
                      File(node.templateImagePath!),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => const Icon(
                        Icons.broken_image_outlined,
                        size: 32,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  node.templateImagePath!.split('/').last.split('\\').last,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.border,
                style: BorderStyle.solid,
              ),
            ),
            child: const Text(
              'No template captured yet.\nClick "Capture Template Region" to take a screenshot and select a region.',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ),

        const SizedBox(height: 12),

        // Threshold slider
        const Text(
          'Match Threshold',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: node.matchThreshold ?? 0.8,
                min: 0.5,
                max: 1.0,
                divisions: 10,
                activeColor: AppColors.primary,
                onChanged: (val) {
                  node.matchThreshold = val;
                  provider.updateNode(node);
                },
              ),
            ),
            Text(
              '${((node.matchThreshold ?? 0.8) * 100).toInt()}%',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // Action on match
        _buildDropdown<String>(
          label: 'On Match',
          value: node.visualAction ?? 'click',
          items: const [
            DropdownMenuItem(value: 'click', child: Text('Click at match')),
            DropdownMenuItem(
              value: 'double_click',
              child: Text('Double-click at match'),
            ),
            DropdownMenuItem(
              value: 'right_click',
              child: Text('Right-click at match'),
            ),
            DropdownMenuItem(value: 'wait', child: Text('Wait for match')),
            DropdownMenuItem(
              value: 'assert_exists',
              child: Text('Assert exists'),
            ),
          ],
          onChanged: (value) {
            if (value == null) return;
            node.visualAction = value;
            provider.updateNode(node);
          },
        ),
      ],
    );
  }

  Future<void> _captureTemplateRegion(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) async {
    try {
      final selection = await _selectScreenRegionOverlay(
        provider,
        requireArea: true,
      );
      if (selection == null || !mounted) return;
      if (!selection.target.hasArea) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Draw a region for the visual template'),
          ),
        );
        return;
      }

      final templateBytes = await _cropTemplatePng(
        selection.capture.imageBytes,
        selection.target,
      );
      final templatePath = await provider.saveVisualTemplate(
        node.id,
        templateBytes,
      );

      node.templateImagePath = templatePath;
      node.matchThreshold ??= 0.8;
      node.visualAction ??= 'click';
      node.searchRegionX = null;
      node.searchRegionY = null;
      node.searchRegionWidth = null;
      node.searchRegionHeight = null;
      provider.updateNode(node);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Visual trigger template captured')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Template capture failed: $e')));
    }
  }

  Future<_OverlayRegionSelection?> _selectScreenRegionOverlay(
    FlowBuilderProvider provider, {
    required bool requireArea,
  }) async {
    try {
      await windowManager.hide();
    } catch (_) {}

    try {
      final result = await provider.selectScreenRegion(
        requireArea: requireArea,
      );
      if (result == null) return null;

      final encoded = result['screenshotBase64'] as String?;
      if (encoded == null || encoded.isEmpty) {
        throw StateError('Screenshot unavailable');
      }

      final capture = _ScreenCapture(
        imageBytes: base64Decode(encoded),
        imageWidth:
            _asInt(result['imageWidthFull']) ??
            _asInt(result['screenWidth']) ??
            0,
        imageHeight:
            _asInt(result['imageHeightFull']) ??
            _asInt(result['screenHeight']) ??
            0,
        screenLeft: _asInt(result['screenLeft']) ?? 0,
        screenTop: _asInt(result['screenTop']) ?? 0,
        screenWidth: _asInt(result['screenWidth']) ?? 0,
        screenHeight: _asInt(result['screenHeight']) ?? 0,
      );
      final target = _ScreenTargetSelection(
        x: _asDouble(result['x']) ?? 0,
        y: _asDouble(result['y']) ?? 0,
        width: _asDouble(result['width']) ?? 0,
        height: _asDouble(result['height']) ?? 0,
        imageX: _asDouble(result['imageX']) ?? 0,
        imageY: _asDouble(result['imageY']) ?? 0,
        imageWidth: _asDouble(result['imageWidth']) ?? 0,
        imageHeight: _asDouble(result['imageHeight']) ?? 0,
      );
      return _OverlayRegionSelection(capture: capture, target: target);
    } finally {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  Future<Uint8List> _cropTemplatePng(
    Uint8List imageBytes,
    _ScreenTargetSelection selection,
  ) async {
    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;

    final left = selection.imageX.floor().clamp(0, image.width - 1).toInt();
    final top = selection.imageY.floor().clamp(0, image.height - 1).toInt();
    final right = (selection.imageX + selection.imageWidth)
        .ceil()
        .clamp(left + 1, image.width)
        .toInt();
    final bottom = (selection.imageY + selection.imageHeight)
        .ceil()
        .clamp(top + 1, image.height)
        .toInt();
    final width = math.max(1, right - left);
    final height = math.max(1, bottom - top);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final src = Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
    final dst = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    canvas.drawImageRect(image, src, dst, Paint());

    final picture = recorder.endRecording();
    final cropped = await picture.toImage(width, height);
    final bytes = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw StateError('Failed to encode template image');
    }
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  }

  // ═══════════════════════════════════════════════════════
  //  UI ATTRIBUTE CONFIG
  // ═══════════════════════════════════════════════════════

  Widget _buildUIDetectSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    final target = node.target;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Pick Element button ─────────────────────────
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => _selectUIElement(provider, node),
            icon: const Icon(Icons.ads_click, size: 18),
            label: const Text('Pick Element from Screen'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),

        const SizedBox(height: 10),

        // ── Selected element summary card ───────────────
        if (target != null &&
            target.mode == UITargetMode.uiaAttribute &&
            ((target.name ?? '').isNotEmpty ||
                (target.role ?? '').isNotEmpty ||
                (target.automationId ?? '').isNotEmpty))
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      size: 14,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'SELECTED ELEMENT',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if ((target.name ?? '').isNotEmpty)
                  _attributeRow('Name', target.name!),
                if ((target.role ?? '').isNotEmpty)
                  _attributeRow('Role', target.role!),
                if ((target.automationId ?? '').isNotEmpty)
                  _attributeRow('AutomationId', target.automationId!),
                if ((target.className ?? '').isNotEmpty)
                  _attributeRow('ClassName', target.className!),
              ],
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: const Text(
              'No element selected yet.\nClick "Pick Element from Screen" to choose a UI element.',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ),

        const SizedBox(height: 12),

        // ── Manual attribute editing ────────────────────
        const Text(
          'ATTRIBUTES (EDITABLE)',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),

        _configField('Name (contains)', target?.name ?? '', (val) {
          node.target = UITargetSelector.fromAttributes(
            name: val.isNotEmpty ? val : null,
            role: target?.role,
            automationId: target?.automationId,
            className: target?.className,
            controlType: target?.controlType,
            hintX: target?.hintX,
            hintY: target?.hintY,
            hintWidth: target?.hintWidth,
            hintHeight: target?.hintHeight,
            hintValue: target?.hintValue,
          );
          provider.updateNode(node);
        }, hintText: 'e.g. Save, OK, File'),

        _configField('Role', target?.role ?? '', (val) {
          node.target = UITargetSelector.fromAttributes(
            name: target?.name,
            role: val.isNotEmpty ? val : null,
            automationId: target?.automationId,
            className: target?.className,
            controlType: target?.controlType,
            hintX: target?.hintX,
            hintY: target?.hintY,
            hintWidth: target?.hintWidth,
            hintHeight: target?.hintHeight,
            hintValue: target?.hintValue,
          );
          provider.updateNode(node);
        }, hintText: 'e.g. Button, TextBox, MenuItem'),

        _configField('Automation ID', target?.automationId ?? '', (val) {
          node.target = UITargetSelector.fromAttributes(
            name: target?.name,
            role: target?.role,
            automationId: val.isNotEmpty ? val : null,
            className: target?.className,
            controlType: target?.controlType,
            hintX: target?.hintX,
            hintY: target?.hintY,
            hintWidth: target?.hintWidth,
            hintHeight: target?.hintHeight,
            hintValue: target?.hintValue,
          );
          provider.updateNode(node);
        }),

        _configField('Class Name', target?.className ?? '', (val) {
          node.target = UITargetSelector.fromAttributes(
            name: target?.name,
            role: target?.role,
            automationId: target?.automationId,
            className: val.isNotEmpty ? val : null,
            controlType: target?.controlType,
            hintX: target?.hintX,
            hintY: target?.hintY,
            hintWidth: target?.hintWidth,
            hintHeight: target?.hintHeight,
            hintValue: target?.hintValue,
          );
          provider.updateNode(node);
        }),

        const SizedBox(height: 12),

        // ── Action dropdown ─────────────────────────────
        _buildDropdown<String>(
          label: 'Action',
          value: node.detectAction ?? 'click_first',
          items: const [
            DropdownMenuItem(
              value: 'click_first',
              child: Text('Click first match'),
            ),
            DropdownMenuItem(value: 'count', child: Text('Count matches')),
            DropdownMenuItem(
              value: 'extract_text',
              child: Text('Extract text'),
            ),
            DropdownMenuItem(
              value: 'wait_until_visible',
              child: Text('Wait until visible'),
            ),
          ],
          onChanged: (value) {
            if (value == null) return;
            node.detectAction = value;
            provider.updateNode(node);
          },
        ),

        const SizedBox(height: 8),

        // ── Output key ──────────────────────────────────
        _configField(
          'Output context key',
          node.detectOutputKey ?? 'detected_element',
          (val) {
            node.detectOutputKey = val;
            provider.updateNode(node);
          },
        ),
      ],
    );
  }

  /// Helper to display a label/value row in the selected element summary.
  Widget _attributeRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  //  UNLOCK NODE CONFIG
  // ═══════════════════════════════════════════════════════

  Widget _buildUnlockSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),

        // Security indicator
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: node.hasUnlockPassword
                ? const Color(0xFF8b5cf6).withValues(alpha: 0.08)
                : AppColors.warning.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: node.hasUnlockPassword
                  ? const Color(0xFF8b5cf6).withValues(alpha: 0.4)
                  : AppColors.warning.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              Icon(
                node.hasUnlockPassword ? Icons.lock : Icons.warning_amber,
                size: 16,
                color: node.hasUnlockPassword
                    ? const Color(0xFF8b5cf6)
                    : AppColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.hasUnlockPassword
                      ? 'Password saved securely (DPAPI)'
                      : 'No password saved yet',
                  style: TextStyle(
                    color: node.hasUnlockPassword
                        ? const Color(0xFF8b5cf6)
                        : AppColors.warning,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Password input
        _UnlockPasswordField(
          hasPassword: node.hasUnlockPassword,
          onSave: (password) async {
            await provider.saveUnlockPassword(node.id, password);
          },
          onClear: () async {
            await provider.deleteUnlockPassword(node.id);
          },
        ),

        const SizedBox(height: 10),

        // Security note
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text(
            '\u{1f512} Your password is stored using Windows DPAPI '
            'encryption and never saved in the flow file.',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════
  //  DATA ITERATOR NODE CONFIG
  // ═══════════════════════════════════════════════════════

  Widget _buildDataIteratorSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    final target = node.containerTarget;
    final config = node.dataIteratorConfig ?? const DataIteratorConfig();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),

        // ── Pick Container button ──
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => _selectContainerElement(provider, node),
            icon: const Icon(Icons.ads_click, size: 18),
            label: Text(
              target != null
                  ? 'Re-pick Container Element'
                  : 'Pick Container Element',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF06b6d4),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),

        const SizedBox(height: 10),

        // ── Container element summary ──
        if (target != null &&
            ((target.name ?? '').isNotEmpty ||
                (target.role ?? '').isNotEmpty ||
                (target.automationId ?? '').isNotEmpty))
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: const Color(0xFF06b6d4).withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      size: 14,
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'CONTAINER ELEMENT',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if ((target.name ?? '').isNotEmpty)
                  _attributeRow('Name', target.name!),
                if ((target.role ?? '').isNotEmpty)
                  _attributeRow('Role', target.role!),
                if ((target.automationId ?? '').isNotEmpty)
                  _attributeRow('ID', target.automationId!),
                if ((target.className ?? '').isNotEmpty)
                  _attributeRow('Class', target.className!),
              ],
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: const Text(
              'No container selected yet.\nPick a list, grid, or table element from the screen.',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ),

        const SizedBox(height: 12),

        // ── Direction dropdown ──
        _buildDropdown<String>(
          label: 'Iteration Direction',
          value: config.direction.name,
          items: IterationDirection.values
              .map((d) => DropdownMenuItem(
                    value: d.name,
                    child: Text(d.displayName),
                  ))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            final dir = IterationDirection.values.firstWhere(
              (d) => d.name == value,
              orElse: () => IterationDirection.vertical,
            );
            node.dataIteratorConfig = DataIteratorConfig(
              direction: dir,
              contextVariableName: config.contextVariableName,
              delayBetweenMs: config.delayBetweenMs,
              clickEachItem: config.clickEachItem,
            );
            provider.updateNode(node);
          },
        ),

        // ── Delay between iterations ──
        _configField(
          'Delay between items (ms)',
          config.delayBetweenMs.toString(),
          (val) {
            node.dataIteratorConfig = DataIteratorConfig(
              direction: config.direction,
              contextVariableName: config.contextVariableName,
              delayBetweenMs: int.tryParse(val) ?? 500,
              clickEachItem: config.clickEachItem,
            );
            provider.updateNode(node);
          },
          isNumber: true,
        ),

        // ── Click each item toggle ──
        SwitchListTile(
          value: config.clickEachItem,
          contentPadding: EdgeInsets.zero,
          activeColor: const Color(0xFF06b6d4),
          title: const Text(
            'Click each item before body',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
          ),
          subtitle: const Text(
            'Clicks the child element to select/focus it',
            style: TextStyle(color: AppColors.textMuted, fontSize: 10),
          ),
          onChanged: (value) {
            node.dataIteratorConfig = DataIteratorConfig(
              direction: config.direction,
              contextVariableName: config.contextVariableName,
              delayBetweenMs: config.delayBetweenMs,
              clickEachItem: value,
            );
            provider.updateNode(node);
          },
        ),

        const SizedBox(height: 8),

        // ── Context variables info ──
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF06b6d4).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: const Color(0xFF06b6d4).withValues(alpha: 0.25),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CONTEXT VARIABLES',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              _variableRow('{{${config.contextVariableName}}}',
                  "Current item's text"),
              _variableRow('{{current_index}}', 'Iteration index (0-based)'),
              _variableRow('{{total_items}}', 'Total number of items'),
              const SizedBox(height: 6),
              const Text(
                'Use these in a Type Text node to insert per-item data.',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // ── Variable name field ──
        _configField(
          'Variable name',
          config.contextVariableName,
          (val) {
            node.dataIteratorConfig = DataIteratorConfig(
              direction: config.direction,
              contextVariableName: val.isNotEmpty ? val : 'current_item',
              delayBetweenMs: config.delayBetweenMs,
              clickEachItem: config.clickEachItem,
            );
            provider.updateNode(node);
          },
        ),
      ],
    );
  }

  Widget _variableRow(String variable, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF06b6d4).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              variable,
              style: const TextStyle(
                color: Color(0xFF06b6d4),
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pick a container element for the Data Iterator node.
  /// Reuses the existing UI element picker mechanism.
  Future<void> _selectContainerElement(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) async {
    try {
      await windowManager.hide();
    } catch (_) {}

    try {
      final result = await provider.selectUIElement();
      if (result == null || !mounted) return;

      final element = result['element'];
      if (element is! Map) return;

      final el = element.map((k, v) => MapEntry(k.toString(), v));

      node.containerTarget = UITargetSelector(
        mode: UITargetMode.uiaAttribute,
        name: el['name'] as String?,
        role: el['role'] as String?,
        automationId: el['automationId'] as String?,
        className: el['className'] as String?,
        stableId: el['stableId'] as String?,
      );
      provider.updateNode(node);

      if (!mounted) return;
      final elName =
          el['name'] as String? ?? el['role'] as String? ?? 'container';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Container selected: $elName')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Container selection failed: $e')),
      );
    } finally {
      try {
        await windowManager.show();
      } catch (_) {}
    }
  }


  Widget _buildTargetSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node, {
    String title = 'TARGET',
  }) {
    final target = node.target;
    final mode = target?.mode ?? UITargetMode.coordinate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          title,
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _selectTargetOnScreen(provider, node),
            icon: const Icon(Icons.control_camera, size: 16),
            label: const Text('Select on screen'),
          ),
        ),
        const SizedBox(height: 10),

        // Target mode selector
        SegmentedButton<UITargetMode>(
          segments: UITargetMode.values.map((m) {
            return ButtonSegment(
              value: m,
              label: Text(m.displayName, style: const TextStyle(fontSize: 11)),
            );
          }).toList(),
          selected: {mode},
          onSelectionChanged: (selection) {
            final newMode = selection.first;
            node.target = UITargetSelector(mode: newMode);
            provider.updateNode(node);
          },
          style: ButtonStyle(
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return AppColors.primary;
              }
              return AppColors.textSecondary;
            }),
            textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
          ),
        ),

        const SizedBox(height: 12),

        // Mode-specific fields
        if (mode == UITargetMode.coordinate) ...[
          Row(
            children: [
              Expanded(
                child: _configField('X', (target?.x ?? 0).toInt().toString(), (
                  val,
                ) {
                  node.target = UITargetSelector.region(
                    double.tryParse(val) ?? 0,
                    target?.y ?? 0,
                    target?.width ?? 0,
                    target?.height ?? 0,
                  );
                  provider.updateNode(node);
                }, isNumber: true),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _configField('Y', (target?.y ?? 0).toInt().toString(), (
                  val,
                ) {
                  node.target = UITargetSelector.region(
                    target?.x ?? 0,
                    double.tryParse(val) ?? 0,
                    target?.width ?? 0,
                    target?.height ?? 0,
                  );
                  provider.updateNode(node);
                }, isNumber: true),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: _configField(
                  'W',
                  (target?.width ?? 0).toInt().toString(),
                  (val) {
                    node.target = UITargetSelector.region(
                      target?.x ?? 0,
                      target?.y ?? 0,
                      double.tryParse(val) ?? 0,
                      target?.height ?? 0,
                    );
                    provider.updateNode(node);
                  },
                  isNumber: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _configField(
                  'H',
                  (target?.height ?? 0).toInt().toString(),
                  (val) {
                    node.target = UITargetSelector.region(
                      target?.x ?? 0,
                      target?.y ?? 0,
                      target?.width ?? 0,
                      double.tryParse(val) ?? 0,
                    );
                    provider.updateNode(node);
                  },
                  isNumber: true,
                ),
              ),
            ],
          ),
        ] else if (mode == UITargetMode.stableId) ...[
          _configField(
            'Stable Element ID',
            target?.stableId ?? '',
            (val) {
              node.target = UITargetSelector.fromStableId(val);
              provider.updateNode(node);
            },
            hintText: 'e.g. btn_save_document',
          ),
        ] else if (mode == UITargetMode.uiaAttribute) ...[
          _configField('Name (contains)', target?.name ?? '', (val) {
            node.target = UITargetSelector.fromAttributes(
              name: val.isNotEmpty ? val : null,
              role: target?.role,
              automationId: target?.automationId,
              className: target?.className,
              controlType: target?.controlType,
              hintX: target?.hintX,
              hintY: target?.hintY,
              hintWidth: target?.hintWidth,
              hintHeight: target?.hintHeight,
              hintValue: target?.hintValue,
            );
            provider.updateNode(node);
          }, hintText: 'e.g. Save, OK, File'),
          _configField('Role', target?.role ?? '', (val) {
            node.target = UITargetSelector.fromAttributes(
              name: target?.name,
              role: val.isNotEmpty ? val : null,
              automationId: target?.automationId,
              className: target?.className,
              controlType: target?.controlType,
              hintX: target?.hintX,
              hintY: target?.hintY,
              hintWidth: target?.hintWidth,
              hintHeight: target?.hintHeight,
              hintValue: target?.hintValue,
            );
            provider.updateNode(node);
          }, hintText: 'e.g. Button, TextBox, MenuItem'),
          _configField('Automation ID', target?.automationId ?? '', (val) {
            node.target = UITargetSelector.fromAttributes(
              name: target?.name,
              role: target?.role,
              automationId: val.isNotEmpty ? val : null,
              className: target?.className,
              controlType: target?.controlType,
              hintX: target?.hintX,
              hintY: target?.hintY,
              hintWidth: target?.hintWidth,
              hintHeight: target?.hintHeight,
              hintValue: target?.hintValue,
            );
            provider.updateNode(node);
          }),
          _configField('Class Name', target?.className ?? '', (val) {
            node.target = UITargetSelector.fromAttributes(
              name: target?.name,
              role: target?.role,
              automationId: target?.automationId,
              className: val.isNotEmpty ? val : null,
              controlType: target?.controlType,
              hintX: target?.hintX,
              hintY: target?.hintY,
              hintWidth: target?.hintWidth,
              hintHeight: target?.hintHeight,
              hintValue: target?.hintValue,
            );
            provider.updateNode(node);
          }),
        ],
      ],
    );
  }

  Widget _buildKeyboardSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    final config = node.keyboardConfig ?? const KeyboardNodeConfig(keys: []);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Text(
          'KEYBOARD',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),

        // Key combo input
        _configField(
          'Keys (comma separated)',
          config.keys.join(', '),
          (val) {
            final keys = val
                .split(',')
                .map((k) => k.trim().toLowerCase())
                .where((k) => k.isNotEmpty)
                .toList();
            node.keyboardConfig = KeyboardNodeConfig(
              keys: keys,
              action: config.action,
              holdDurationMs: config.holdDurationMs,
              repeatCount: config.repeatCount,
              delayBetweenMs: config.delayBetweenMs,
            );
            provider.updateNode(node);
          },
          hintText: 'e.g. ctrl, s  or  f5  or  alt, tab',
        ),

        const SizedBox(height: 8),

        // Quick key buttons
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _quickKeyButton('Ctrl+C', ['ctrl', 'c'], provider, node, config),
            _quickKeyButton('Ctrl+V', ['ctrl', 'v'], provider, node, config),
            _quickKeyButton('Ctrl+S', ['ctrl', 's'], provider, node, config),
            _quickKeyButton('Ctrl+Z', ['ctrl', 'z'], provider, node, config),
            _quickKeyButton('Ctrl+A', ['ctrl', 'a'], provider, node, config),
            _quickKeyButton('Enter', ['enter'], provider, node, config),
            _quickKeyButton('Esc', ['escape'], provider, node, config),
            _quickKeyButton('Tab', ['tab'], provider, node, config),
            _quickKeyButton('F5', ['f5'], provider, node, config),
            _quickKeyButton('Alt+Tab', ['alt', 'tab'], provider, node, config),
            _quickKeyButton('Alt+F4', ['alt', 'f4'], provider, node, config),
            _quickKeyButton('Win+D', ['win', 'd'], provider, node, config),
          ],
        ),

        const SizedBox(height: 12),

        // Action type
        DropdownButtonFormField<KeyboardActionType>(
          value: config.action,
          dropdownColor: AppColors.surfaceElevated,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
          decoration: InputDecoration(
            labelText: 'Action',
            labelStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.surfaceVariant,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.border),
            ),
          ),
          items: KeyboardActionType.values.map((a) {
            return DropdownMenuItem(value: a, child: Text(a.displayName));
          }).toList(),
          onChanged: (val) {
            if (val == null) return;
            node.keyboardConfig = KeyboardNodeConfig(
              keys: config.keys,
              action: val,
              holdDurationMs: config.holdDurationMs,
              repeatCount: config.repeatCount,
              delayBetweenMs: config.delayBetweenMs,
            );
            provider.updateNode(node);
          },
        ),

        const SizedBox(height: 8),

        // Repeat count
        _configField('Repeat count', config.repeatCount.toString(), (val) {
          node.keyboardConfig = KeyboardNodeConfig(
            keys: config.keys,
            action: config.action,
            holdDurationMs: config.holdDurationMs,
            repeatCount: int.tryParse(val) ?? 1,
            delayBetweenMs: config.delayBetweenMs,
          );
          provider.updateNode(node);
        }, isNumber: true),
      ],
    );
  }

  Widget _quickKeyButton(
    String label,
    List<String> keys,
    FlowBuilderProvider provider,
    DesktopFlowNode node,
    KeyboardNodeConfig config,
  ) {
    final isActive = _listsEqual(config.keys, keys);
    return InkWell(
      onTap: () {
        node.keyboardConfig = KeyboardNodeConfig(
          keys: keys,
          action: config.action,
          holdDurationMs: config.holdDurationMs,
          repeatCount: config.repeatCount,
          delayBetweenMs: config.delayBetweenMs,
        );
        provider.updateNode(node);
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isActive
              ? AppColors.primary.withValues(alpha: 0.2)
              : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? AppColors.primary : AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Widget _buildScrollSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    return Column(
      children: [
        DropdownButtonFormField<String>(
          value: node.scrollDirection ?? 'down',
          dropdownColor: AppColors.surfaceElevated,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
          decoration: InputDecoration(
            labelText: 'Direction',
            labelStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.surfaceVariant,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.border),
            ),
          ),
          items: const [
            DropdownMenuItem(value: 'up', child: Text('Up')),
            DropdownMenuItem(value: 'down', child: Text('Down')),
          ],
          onChanged: (val) {
            node.scrollDirection = val ?? 'down';
            provider.updateNode(node);
          },
        ),
        const SizedBox(height: 8),
        _configField(
          'Amount (scroll clicks)',
          (node.scrollAmount ?? 3).toString(),
          (val) {
            node.scrollAmount = int.tryParse(val) ?? 3;
            provider.updateNode(node);
          },
          isNumber: true,
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════
  //  SWIPE CONFIG SECTION
  // ═══════════════════════════════════════════════════════

  Widget _buildSwipeSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    final hasEndpoints = node.swipeStartX != null &&
        node.swipeStartY != null &&
        node.swipeEndX != null &&
        node.swipeEndY != null;

    return Column(
      children: [
        // ── Pick on Screen button ──
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.my_location, size: 16),
            label: Text(
              hasEndpoints ? 'Re-pick Swipe on Screen' : 'Pick Swipe on Screen',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => _pickSwipeOnScreen(provider, node),
          ),
        ),

        // ── Picked coordinates summary ──
        if (hasEndpoints) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFF22c55e),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Start: (${node.swipeStartX}, ${node.swipeStartY})',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFFef4444),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'End: (${node.swipeEndX}, ${node.swipeEndY})',
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                InkWell(
                  onTap: () {
                    node.swipeStartX = null;
                    node.swipeStartY = null;
                    node.swipeEndX = null;
                    node.swipeEndY = null;
                    provider.updateNode(node);
                  },
                  child: const Text(
                    'Clear \u2715',
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        // ── Fallback: manual direction/distance (when no endpoints) ──
        if (!hasEndpoints) ...[
          const SizedBox(height: 10),
          const Text(
            'Or configure manually:',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: node.swipeDirection ?? 'down',
            dropdownColor: AppColors.surfaceElevated,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              labelText: 'Direction',
              labelStyle: const TextStyle(color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.surfaceVariant,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppColors.border),
              ),
            ),
            items: const [
              DropdownMenuItem(value: 'up', child: Text('Up')),
              DropdownMenuItem(value: 'down', child: Text('Down')),
              DropdownMenuItem(value: 'left', child: Text('Left')),
              DropdownMenuItem(value: 'right', child: Text('Right')),
            ],
            onChanged: (val) {
              node.swipeDirection = val ?? 'down';
              provider.updateNode(node);
            },
          ),
          const SizedBox(height: 8),
          _configField(
            'Distance (pixels)',
            (node.swipeDistance ?? 300).toString(),
            (val) {
              node.swipeDistance = int.tryParse(val) ?? 300;
              provider.updateNode(node);
            },
            isNumber: true,
          ),
        ],

        // ── Duration (always shown) ──
        const SizedBox(height: 8),
        _configField(
          'Duration (ms)',
          (node.swipeDuration ?? 350).toString(),
          (val) {
            node.swipeDuration = int.tryParse(val) ?? 350;
            provider.updateNode(node);
          },
          isNumber: true,
        ),
      ],
    );
  }

  /// Opens the swipe point picker overlay and saves coordinates to the node.
  Future<void> _pickSwipeOnScreen(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) async {
    try {
      await windowManager.hide();
    } catch (_) {}

    try {
      final result = await provider.selectSwipePoints();
      if (result == null || !mounted) return;

      node.swipeStartX = (result['startX'] as num?)?.toInt();
      node.swipeStartY = (result['startY'] as num?)?.toInt();
      node.swipeEndX = (result['endX'] as num?)?.toInt();
      node.swipeEndY = (result['endY'] as num?)?.toInt();
      provider.updateNode(node);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Swipe pick failed: $e')),
      );
    } finally {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════════════════
  Future<void> _selectTargetOnScreen(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) async {
    try {
      final selection = await _selectScreenRegionOverlay(
        provider,
        requireArea: false,
      );
      if (selection == null || !mounted) return;
      final target = selection.target;
      node.target = target.hasArea
          ? UITargetSelector.region(
              target.x,
              target.y,
              target.width,
              target.height,
            )
          : UITargetSelector.coordinate(target.x, target.y);
      provider.updateNode(node);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Target capture failed: $e')));
    }
  }

  /// Opens the interactive UI element picker (bounding-box overlay or list
  /// fallback) and populates the node's [UITargetSelector] with the
  /// selected element's UIA attributes.
  Future<void> _selectUIElement(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) async {
    try {
      await windowManager.hide();
    } catch (_) {}

    try {
      final result = await provider.selectUIElement();
      if (result == null || !mounted) return;

      final element = result['element'];
      if (element is! Map) return;

      final el = element.map((k, v) => MapEntry(k.toString(), v));

      // Extract bounding box for spatial disambiguation hints
      final bb = el['boundingBox'] as Map?;
      final bbX = (bb?['x'] as num?)?.toDouble() ?? 0;
      final bbY = (bb?['y'] as num?)?.toDouble() ?? 0;
      final bbW = (bb?['width'] as num?)?.toDouble() ?? 0;
      final bbH = (bb?['height'] as num?)?.toDouble() ?? 0;

      node.target = UITargetSelector.fromAttributes(
        name: el['name'] as String?,
        role: el['role'] as String?,
        automationId: el['automationId'] as String?,
        className: el['className'] as String?,
        hintX: bbX + bbW / 2,   // center X
        hintY: bbY + bbH / 2,   // center Y
        hintWidth: bbW,
        hintHeight: bbH,
        hintValue: el['value'] as String?,
      );
      provider.updateNode(node);

      if (!mounted) return;
      final elName = el['name'] as String? ?? el['role'] as String? ?? 'element';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Selected: $elName')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Element selection failed: $e')),
      );
    } finally {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
  }

  Future<void> _showAppPicker(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) async {
    await provider.loadAvailableApps();
    if (!mounted) return;

    final searchCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final query = searchCtrl.text.trim().toLowerCase();
          final apps = provider.availableApps
              .where((app) {
                if (query.isEmpty) return true;
                return app.name.toLowerCase().contains(query) ||
                    app.path.toLowerCase().contains(query);
              })
              .take(250)
              .toList();

          return AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: AppColors.border),
            ),
            title: const Text(
              'Select App',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            content: SizedBox(
              width: 520,
              height: 520,
              child: Column(
                children: [
                  TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: _inputDecoration(
                      label: 'Search apps',
                      hintText: 'Type app name',
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  if (provider.appLoadError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        provider.appLoadError!,
                        style: const TextStyle(
                          color: AppColors.error,
                          fontSize: 12,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  Expanded(
                    child: apps.isEmpty
                        ? const Center(
                            child: Text(
                              'No apps found',
                              style: TextStyle(color: AppColors.textMuted),
                            ),
                          )
                        : ListView.separated(
                            itemCount: apps.length,
                            separatorBuilder: (_, __) => const Divider(
                              color: AppColors.divider,
                              height: 1,
                            ),
                            itemBuilder: (context, index) {
                              final app = apps[index];
                              return ListTile(
                                dense: true,
                                leading: const Icon(
                                  Icons.apps,
                                  color: AppColors.success,
                                ),
                                title: Text(
                                  app.name,
                                  style: const TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 13,
                                  ),
                                ),
                                subtitle: Text(
                                  app.path,
                                  style: const TextStyle(
                                    color: AppColors.textMuted,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () {
                                  node.appName = app.name;
                                  node.appPath = app.path;
                                  provider.updateNode(node);
                                  Navigator.pop(ctx);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await provider.loadAvailableApps(force: true);
                  setDialogState(() {});
                },
                child: const Text('Refresh'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
    searchCtrl.dispose();
  }

  //  EXECUTION LOG
  // ═══════════════════════════════════════════════════════

  Widget _buildExecutionLog(FlowBuilderProvider provider) {
    return Container(
      height: 120,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Text(
                  'EXECUTION LOG',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                if (provider.lastResult != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: provider.lastResult!.success
                          ? AppColors.success.withValues(alpha: 0.15)
                          : AppColors.error.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      provider.lastResult!.success
                          ? '✓ Completed (${provider.lastResult!.elapsed.inMilliseconds}ms)'
                          : '✗ Failed: ${provider.lastResult!.errorMessage}',
                      style: TextStyle(
                        color: provider.lastResult!.success
                            ? AppColors.success
                            : AppColors.error,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: provider.progressLog.length,
              itemBuilder: (context, index) {
                final prog = provider.progressLog[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${prog.currentStep}/${prog.totalSteps}  ${prog.message}',
                    style: TextStyle(
                      color: prog.status == 'failed'
                          ? AppColors.error
                          : prog.status == 'completed'
                          ? AppColors.success
                          : AppColors.textSecondary,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  //  TRIGGER DIALOG
  // ═══════════════════════════════════════════════════════

  void _showTriggerDialog(BuildContext context) {
    final provider = Provider.of<FlowBuilderProvider>(context, listen: false);
    final flow = provider.currentFlow;
    if (flow == null) return;

    var trigger = flow.trigger;
    final hotkeyCtrl = TextEditingController(text: trigger.hotkeyCombo ?? '');
    final intervalCtrl = TextEditingController(
      text: (trigger.scheduleIntervalMs ?? 60000).toString(),
    );

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.border),
          ),
          title: const Text(
            'Flow Trigger',
            style: TextStyle(color: AppColors.textPrimary),
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...FlowTriggerType.values.map((type) {
                  return RadioListTile<FlowTriggerType>(
                    title: Text(
                      type.displayName,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                    value: type,
                    groupValue: trigger.type,
                    activeColor: AppColors.primary,
                    onChanged: (val) {
                      setDialogState(() {
                        trigger = trigger.copyWith(type: val);
                      });
                    },
                  );
                }),
                if (trigger.type == FlowTriggerType.hotkey) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: hotkeyCtrl,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'Hotkey combo',
                      labelStyle: const TextStyle(
                        color: AppColors.textSecondary,
                      ),
                      hintText: 'e.g. ctrl+shift+f1',
                      hintStyle: const TextStyle(color: AppColors.textMuted),
                      filled: true,
                      fillColor: AppColors.surfaceVariant,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.primary),
                      ),
                    ),
                  ),
                ],
                if (trigger.type == FlowTriggerType.scheduled) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: intervalCtrl,
                    style: const TextStyle(color: AppColors.textPrimary),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Interval (milliseconds)',
                      labelStyle: const TextStyle(
                        color: AppColors.textSecondary,
                      ),
                      filled: true,
                      fillColor: AppColors.surfaceVariant,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.primary),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            FilledButton(
              onPressed: () {
                final finalTrigger = FlowTrigger(
                  type: trigger.type,
                  hotkeyCombo: hotkeyCtrl.text.trim().isNotEmpty
                      ? hotkeyCtrl.text.trim()
                      : null,
                  scheduleIntervalMs: int.tryParse(intervalCtrl.text),
                  enabled: true,
                );
                provider.updateFlowTrigger(finalTrigger);
                Navigator.pop(ctx);
              },
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════

  Widget _configField(
    String label,
    String initialValue,
    void Function(String) onChanged, {
    String? hintText,
    bool isNumber = false,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _ConfigTextField(
        label: label,
        initialValue: initialValue,
        onChanged: onChanged,
        hintText: hintText,
        isNumber: isNumber,
        maxLines: maxLines,
      ),
    );
  }

  Widget _buildDropdown<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<T>(
        value: value,
        dropdownColor: AppColors.surfaceElevated,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
        decoration: _inputDecoration(label: label),
        items: items,
        onChanged: onChanged,
      ),
    );
  }

  InputDecoration _inputDecoration({required String label, String? hintText}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: AppColors.textSecondary),
      hintText: hintText,
      hintStyle: const TextStyle(color: AppColors.textMuted),
      filled: true,
      fillColor: AppColors.surfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.primary),
      ),
    );
  }

  IconData _nodeIcon(DesktopFlowNodeType type) {
    switch (type) {
      case DesktopFlowNodeType.start:
        return Icons.play_circle;
      case DesktopFlowNodeType.click:
        return Icons.mouse;
      case DesktopFlowNodeType.doubleClick:
        return Icons.ads_click;
      case DesktopFlowNodeType.rightClick:
        return Icons.touch_app;
      case DesktopFlowNodeType.typeText:
        return Icons.text_fields;
      case DesktopFlowNodeType.keyboard:
        return Icons.keyboard;
      case DesktopFlowNodeType.hotkey:
        return Icons.keyboard_alt;
      case DesktopFlowNodeType.launchApp:
        return Icons.launch;
      case DesktopFlowNodeType.delay:
        return Icons.timer;
      case DesktopFlowNodeType.screenshot:
        return Icons.screenshot_monitor;
      case DesktopFlowNodeType.scroll:
        return Icons.swap_vert;
      case DesktopFlowNodeType.swipe:
        return Icons.swipe;
      case DesktopFlowNodeType.repeat:
        return Icons.loop;
      case DesktopFlowNodeType.conditional:
        return Icons.call_split;
      case DesktopFlowNodeType.visualTrigger:
        return Icons.image_search;
      case DesktopFlowNodeType.uiDetect:
        return Icons.find_in_page;
      case DesktopFlowNodeType.unlock:
        return Icons.lock_open;
      case DesktopFlowNodeType.dataIterator:
        return Icons.playlist_play;
      case DesktopFlowNodeType.done:
        return Icons.check_circle;
    }
  }
}

class _ConfigTextField extends StatefulWidget {
  final String label;
  final String initialValue;
  final ValueChanged<String> onChanged;
  final String? hintText;
  final bool isNumber;
  final int maxLines;

  const _ConfigTextField({
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.hintText,
    this.isNumber = false,
    this.maxLines = 1,
  });

  @override
  State<_ConfigTextField> createState() => _ConfigTextFieldState();
}

class _ConfigTextFieldState extends State<_ConfigTextField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _ConfigTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialValue != _controller.text && !_focusNode.hasFocus) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _controller,
      focusNode: _focusNode,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
      maxLines: widget.maxLines,
      keyboardType: widget.isNumber ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: widget.label,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintText: widget.hintText,
        hintStyle: const TextStyle(color: AppColors.textMuted),
        filled: true,
        fillColor: AppColors.surfaceVariant,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.primary),
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}

class _ScreenCapture {
  final Uint8List imageBytes;
  final int imageWidth;
  final int imageHeight;
  final int screenLeft;
  final int screenTop;
  final int screenWidth;
  final int screenHeight;

  const _ScreenCapture({
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.screenLeft,
    required this.screenTop,
    required this.screenWidth,
    required this.screenHeight,
  });
}

class _OverlayRegionSelection {
  final _ScreenCapture capture;
  final _ScreenTargetSelection target;

  const _OverlayRegionSelection({required this.capture, required this.target});
}

class _ScreenTargetSelection {
  final double x;
  final double y;
  final double width;
  final double height;
  final double imageX;
  final double imageY;
  final double imageWidth;
  final double imageHeight;

  const _ScreenTargetSelection({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.imageX,
    required this.imageY,
    required this.imageWidth,
    required this.imageHeight,
  });

  bool get hasArea => width > 3 && height > 3;
}

// ═══════════════════════════════════════════════════════════════════
//  PALETTE ITEM
// ═══════════════════════════════════════════════════════════════════

class _PaletteItem extends StatelessWidget {
  final DesktopFlowNodeType type;
  final VoidCallback onTap;

  const _PaletteItem({required this.type, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(_icon, size: 16, color: _color),
                const SizedBox(width: 10),
                Text(
                  type.displayName,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData get _icon {
    switch (type) {
      case DesktopFlowNodeType.click:
        return Icons.mouse;
      case DesktopFlowNodeType.doubleClick:
        return Icons.ads_click;
      case DesktopFlowNodeType.rightClick:
        return Icons.touch_app;
      case DesktopFlowNodeType.typeText:
        return Icons.text_fields;
      case DesktopFlowNodeType.keyboard:
        return Icons.keyboard;
      case DesktopFlowNodeType.hotkey:
        return Icons.keyboard_alt;
      case DesktopFlowNodeType.launchApp:
        return Icons.launch;
      case DesktopFlowNodeType.delay:
        return Icons.timer;
      case DesktopFlowNodeType.screenshot:
        return Icons.screenshot_monitor;
      case DesktopFlowNodeType.scroll:
        return Icons.swap_vert;
      case DesktopFlowNodeType.repeat:
        return Icons.loop;
      case DesktopFlowNodeType.conditional:
        return Icons.call_split;
      case DesktopFlowNodeType.visualTrigger:
        return Icons.image_search;
      case DesktopFlowNodeType.uiDetect:
        return Icons.find_in_page;
      default:
        return Icons.circle;
    }
  }

  Color get _color {
    switch (type) {
      case DesktopFlowNodeType.click:
      case DesktopFlowNodeType.doubleClick:
      case DesktopFlowNodeType.rightClick:
        return AppColors.primary;
      case DesktopFlowNodeType.typeText:
        return AppColors.secondary;
      case DesktopFlowNodeType.keyboard:
      case DesktopFlowNodeType.hotkey:
        return AppColors.accent;
      case DesktopFlowNodeType.launchApp:
        return AppColors.success;
      case DesktopFlowNodeType.delay:
      case DesktopFlowNodeType.screenshot:
        return AppColors.warning;
      case DesktopFlowNodeType.scroll:
        return AppColors.primaryLight;
      case DesktopFlowNodeType.repeat:
      case DesktopFlowNodeType.conditional:
        return AppColors.error;
      case DesktopFlowNodeType.visualTrigger:
        return AppColors.secondary;
      case DesktopFlowNodeType.uiDetect:
        return AppColors.accent;
      case DesktopFlowNodeType.unlock:
        return const Color(0xFF8b5cf6); // Purple — security/lock
      case DesktopFlowNodeType.dataIterator:
        return const Color(0xFF06b6d4); // Cyan — iteration/loop
      default:
        return AppColors.textMuted;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  NODE CARD WIDGET
// ═══════════════════════════════════════════════════════════════════

class _NodeCard extends StatelessWidget {
  final DesktopFlowNode node;
  final bool isSelected;
  final bool isExecuting;
  final bool isConnecting;
  final VoidCallback? onDelete;

  const _NodeCard({
    required this.node,
    required this.isSelected,
    required this.isExecuting,
    required this.isConnecting,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    Color borderColor = AppColors.border;
    if (isExecuting) {
      borderColor = AppColors.warning;
    } else if (isSelected) {
      borderColor = AppColors.primary;
    } else if (isConnecting) {
      borderColor = AppColors.secondary.withValues(alpha: 0.5);
    }

    return Container(
      width: 170,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isExecuting
            ? AppColors.warning.withValues(alpha: 0.08)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: _nodeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(_nodeIcon, size: 14, color: _nodeColor),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  node.label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onDelete != null)
                InkWell(
                  onTap: onDelete,
                  child: const Icon(
                    Icons.close,
                    size: 14,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),

          // Config summary
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              node.configSummary,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  IconData get _nodeIcon {
    switch (node.nodeType) {
      case DesktopFlowNodeType.start:
        return Icons.play_circle;
      case DesktopFlowNodeType.click:
        return Icons.mouse;
      case DesktopFlowNodeType.doubleClick:
        return Icons.ads_click;
      case DesktopFlowNodeType.rightClick:
        return Icons.touch_app;
      case DesktopFlowNodeType.typeText:
        return Icons.text_fields;
      case DesktopFlowNodeType.keyboard:
        return Icons.keyboard;
      case DesktopFlowNodeType.hotkey:
        return Icons.keyboard_alt;
      case DesktopFlowNodeType.launchApp:
        return Icons.launch;
      case DesktopFlowNodeType.delay:
        return Icons.timer;
      case DesktopFlowNodeType.screenshot:
        return Icons.screenshot_monitor;
      case DesktopFlowNodeType.scroll:
        return Icons.swap_vert;
      case DesktopFlowNodeType.swipe:
        return Icons.swipe;
      case DesktopFlowNodeType.repeat:
        return Icons.loop;
      case DesktopFlowNodeType.conditional:
        return Icons.call_split;
      case DesktopFlowNodeType.visualTrigger:
        return Icons.image_search;
      case DesktopFlowNodeType.uiDetect:
        return Icons.find_in_page;
      case DesktopFlowNodeType.unlock:
        return Icons.lock_open;
      case DesktopFlowNodeType.dataIterator:
        return Icons.playlist_play;
      case DesktopFlowNodeType.done:
        return Icons.check_circle;
    }
  }

  Color get _nodeColor {
    switch (node.nodeType) {
      case DesktopFlowNodeType.start:
        return AppColors.success;
      case DesktopFlowNodeType.click:
      case DesktopFlowNodeType.doubleClick:
      case DesktopFlowNodeType.rightClick:
        return AppColors.primary;
      case DesktopFlowNodeType.typeText:
        return AppColors.secondary;
      case DesktopFlowNodeType.keyboard:
      case DesktopFlowNodeType.hotkey:
        return AppColors.accent;
      case DesktopFlowNodeType.launchApp:
        return AppColors.success;
      case DesktopFlowNodeType.delay:
      case DesktopFlowNodeType.screenshot:
        return AppColors.warning;
      case DesktopFlowNodeType.scroll:
      case DesktopFlowNodeType.swipe:
        return AppColors.primaryLight;
      case DesktopFlowNodeType.repeat:
      case DesktopFlowNodeType.conditional:
        return AppColors.error;
      case DesktopFlowNodeType.visualTrigger:
        return AppColors.secondary;
      case DesktopFlowNodeType.uiDetect:
        return AppColors.accent;
      case DesktopFlowNodeType.unlock:
        return const Color(0xFF8b5cf6);
      case DesktopFlowNodeType.dataIterator:
        return const Color(0xFF06b6d4);
      case DesktopFlowNodeType.done:
        return AppColors.success;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  GRID PAINTER
// ═══════════════════════════════════════════════════════════════════

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.border.withValues(alpha: 0.3)
      ..strokeWidth = 0.5;

    const gridSize = 40.0;

    for (double x = 0; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ═══════════════════════════════════════════════════════════════════
//  EDGE PAINTER
// ═══════════════════════════════════════════════════════════════════

class _EdgePainter extends CustomPainter {
  final List<DesktopFlowNode> nodes;
  final List<DesktopFlowEdge> edges;
  final String? executingNodeId;
  final Offset? pendingEdgeStart;
  final Offset? pendingEdgeEnd;
  final String? pendingEdgeLabel;

  _EdgePainter({
    required this.nodes,
    required this.edges,
    this.executingNodeId,
    this.pendingEdgeStart,
    this.pendingEdgeEnd,
    this.pendingEdgeLabel,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const nodeWidth = 170.0;
    const nodeHeight = 80.0;
    // Port X offsets (must match _buildOutputPort portOffsetX)
    const successPortOffsetX = nodeWidth / 2 - 16;
    const failurePortOffsetX = nodeWidth / 2 + 16;

    for (final edge in edges) {
      final fromNode = _findNode(edge.fromNodeId);
      final toNode = _findNode(edge.toNodeId);
      if (fromNode == null || toNode == null) continue;

      // Choose start X based on edge label
      final portOffsetX = _isFailureLabel(edge.label)
          ? failurePortOffsetX
          : successPortOffsetX;

      final from = Offset(
        fromNode.x + portOffsetX,
        fromNode.y + nodeHeight + 14,
      );
      final to = Offset(
        toNode.x + nodeWidth / 2,
        toNode.y, // above input port
      );

      // Color by label
      Color edgeColor;
      if (executingNodeId != null && edge.toNodeId == executingNodeId) {
        edgeColor = AppColors.warning;
      } else if (_isFailureLabel(edge.label)) {
        edgeColor = AppColors.error.withValues(alpha: 0.7);
      } else {
        edgeColor = AppColors.success.withValues(alpha: 0.7);
      }

      _drawBezierEdge(canvas, from, to, edgeColor);

      // Draw label on the midpoint
      if (edge.label != null && edge.label!.isNotEmpty) {
        final midX = (from.dx + to.dx) / 2;
        final midY = (from.dy + to.dy) / 2;
        final textPainter = TextPainter(
          text: TextSpan(
            text: _edgeSymbol(edge.label),
            style: TextStyle(
              color: edgeColor,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // Draw a small background pill
        final bgRect = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(midX, midY),
            width: textPainter.width + 8,
            height: textPainter.height + 4,
          ),
          const Radius.circular(4),
        );
        canvas.drawRRect(
          bgRect,
          Paint()..color = AppColors.surface.withValues(alpha: 0.9),
        );
        textPainter.paint(
          canvas,
          Offset(midX - textPainter.width / 2, midY - textPainter.height / 2),
        );
      }
    }

    // Draw rubber-band (pending) edge
    if (pendingEdgeStart != null && pendingEdgeEnd != null) {
      final rubberColor = _isFailureLabel(pendingEdgeLabel)
          ? AppColors.error.withValues(alpha: 0.6)
          : AppColors.success.withValues(alpha: 0.6);
      _drawBezierEdge(
        canvas,
        pendingEdgeStart!,
        pendingEdgeEnd!,
        rubberColor,
        isDashed: true,
      );
    }
  }

  void _drawBezierEdge(
    Canvas canvas,
    Offset from,
    Offset to,
    Color color, {
    bool isDashed = false,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // Vertical Bézier — control points offset vertically
    final dy = (to.dy - from.dy).abs() * 0.5;
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..cubicTo(from.dx, from.dy + dy, to.dx, to.dy - dy, to.dx, to.dy);

    canvas.drawPath(path, paint);

    // Arrowhead
    final arrowPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    const arrowSize = 8.0;
    final arrowPath = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(to.dx - arrowSize * 0.5, to.dy - arrowSize)
      ..lineTo(to.dx + arrowSize * 0.5, to.dy - arrowSize)
      ..close();

    canvas.drawPath(arrowPath, arrowPaint);
  }

  bool _isFailureLabel(String? label) {
    return label == 'failure' || label == 'false';
  }

  String _edgeSymbol(String? label) {
    if (label == 'success' || label == 'true') {
      return '${String.fromCharCode(0x2713)} True';
    }
    if (label == 'failure' || label == 'false') {
      return '${String.fromCharCode(0x2717)} False';
    }
    return '';
  }

  DesktopFlowNode? _findNode(String id) {
    try {
      return nodes.firstWhere((n) => n.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) => true;
}

// ═════════════════════════════════════════════════════════════════
//  PORT DOT (input/output connection point)
// ═════════════════════════════════════════════════════════════════

class _PortDot extends StatelessWidget {
  final Color color;
  final bool isInput;
  final bool pulsing;

  const _PortDot({
    required this.color,
    required this.isInput,
    required this.pulsing,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isInput ? 'Drop here to connect' : 'Drag to connect',
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.2),
            border: Border.all(color: color, width: 2),
            boxShadow: pulsing
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════
//  EDGE CUT BUTTON (hover-reveal scissors at edge midpoint)
// ═════════════════════════════════════════════════════════════════

class _EdgeCutButton extends StatefulWidget {
  final Color color;
  final VoidCallback onCut;

  const _EdgeCutButton({required this.color, required this.onCut});

  @override
  State<_EdgeCutButton> createState() => _EdgeCutButtonState();
}

class _EdgeCutButtonState extends State<_EdgeCutButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onCut,
        child: AnimatedOpacity(
          opacity: _hovered ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.color.withValues(alpha: 0.6),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 4,
                ),
              ],
            ),
            child: Icon(Icons.content_cut, size: 14, color: widget.color),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  UNLOCK PASSWORD FIELD WIDGET
// ═══════════════════════════════════════════════════════════════════

/// A self-contained password input widget for the Unlock node config panel.
///
/// Shows an obscured text field with Save / Clear buttons.
/// The password is never displayed after saving — only the indicator changes.
class _UnlockPasswordField extends StatefulWidget {
  final bool hasPassword;
  final Future<void> Function(String password) onSave;
  final Future<void> Function() onClear;

  const _UnlockPasswordField({
    required this.hasPassword,
    required this.onSave,
    required this.onClear,
  });

  @override
  State<_UnlockPasswordField> createState() => _UnlockPasswordFieldState();
}

class _UnlockPasswordFieldState extends State<_UnlockPasswordField> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _saving = false;

  @override
  void dispose() {
    // Clear sensitive text from memory
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'PASSWORD',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _controller,
          obscureText: _obscure,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
          decoration: InputDecoration(
            hintText: widget.hasPassword
                ? 'Enter new password to update'
                : 'Enter your Windows password',
            hintStyle: TextStyle(
              color: AppColors.textMuted.withValues(alpha: 0.6),
              fontSize: 12,
            ),
            filled: true,
            fillColor: AppColors.background,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: Color(0xFF8b5cf6), width: 1.5),
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility_off : Icons.visibility,
                size: 18,
                color: AppColors.textMuted,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: _saving || _controller.text.isEmpty
                    ? null
                    : () async {
                        setState(() => _saving = true);
                        try {
                          await widget.onSave(_controller.text);
                          _controller.clear();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Password saved securely'),
                              ),
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _saving = false);
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8b5cf6),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Save Password'),
              ),
            ),
            if (widget.hasPassword) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  await widget.onClear();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Password cleared')),
                    );
                  }
                },
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.error,
                ),
                child: const Text('Clear'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
