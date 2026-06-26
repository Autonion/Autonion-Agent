import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

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

        return Column(
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
        .where((t) =>
            t != DesktopFlowNodeType.start && t != DesktopFlowNodeType.done)
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
                    // Add node at a reasonable position
                    final r = math.Random();
                    final x = 250.0 + r.nextDouble() * 300;
                    final y = 150.0 + r.nextDouble() * 300;
                    provider.addNode(type, x, y);
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
      child: Container(
        color: AppColors.background,
        child: InteractiveViewer(
          transformationController: _transformCtrl,
          boundaryMargin: const EdgeInsets.all(2000),
          minScale: 0.3,
          maxScale: 3.0,
          child: SizedBox(
            width: 4000,
            height: 4000,
            child: CustomPaint(
              painter: _GridPainter(),
              child: Stack(
                children: [
                  // ── Edges (drawn behind nodes) ──
                  CustomPaint(
                    painter: _EdgePainter(
                      nodes: flow.nodes,
                      edges: flow.edges,
                      executingNodeId: provider.executingNodeId,
                    ),
                    size: const Size(4000, 4000),
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
    );
  }

  Widget _buildNodeWidget(FlowBuilderProvider provider, DesktopFlowNode node) {
    final isSelected = provider.selectedNodeId == node.id;
    final isExecuting = provider.executingNodeId == node.id;
    final isConnecting = provider.connectingFromNodeId != null;

    return Positioned(
      left: node.x,
      top: node.y,
      child: GestureDetector(
        onTap: () {
          if (isConnecting) {
            provider.completeConnection(node.id);
          } else {
            provider.selectNode(node.id);
          }
        },
        onPanStart: (details) {
          _draggingNodeId = node.id;
        },
        onPanUpdate: (details) {
          if (_draggingNodeId == node.id) {
            // Account for canvas scale
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
          onConnect: () => provider.startConnecting(node.id),
          onDelete: node.nodeType != DesktopFlowNodeType.start &&
                  node.nodeType != DesktopFlowNodeType.done
              ? () => provider.removeNode(node.id)
              : null,
        ),
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
            _configField(
              'Label',
              node.label,
              (val) {
                node.label = val;
                provider.updateNode(node);
              },
            ),

            // Type-specific fields
            ..._buildTypeSpecificFields(provider, node),
          ],
        ),
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
        widgets.add(_buildTargetSection(provider, node));
        widgets.add(const SizedBox(height: 12));
        widgets.add(
          _configField(
            'Text to type',
            node.text ?? '',
            (val) {
              node.text = val;
              provider.updateNode(node);
            },
            maxLines: 3,
          ),
        );
        break;

      case DesktopFlowNodeType.keyboard:
      case DesktopFlowNodeType.hotkey:
        widgets.add(_buildKeyboardSection(provider, node));
        break;

      case DesktopFlowNodeType.launchApp:
        widgets.add(
          _configField(
            'Application name',
            node.appName ?? '',
            (val) {
              node.appName = val;
              provider.updateNode(node);
            },
            hintText: 'e.g. notepad, calculator, chrome',
          ),
        );
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

      case DesktopFlowNodeType.repeat:
        widgets.add(
          _configField(
            'Repeat count',
            (node.repeatCount ?? 3).toString(),
            (val) {
              node.repeatCount = int.tryParse(val) ?? 3;
              provider.updateNode(node);
            },
            isNumber: true,
          ),
        );
        break;

      case DesktopFlowNodeType.conditional:
        widgets.add(_buildTargetSection(provider, node));
        widgets.add(const SizedBox(height: 8));
        widgets.add(const Text(
          'The flow branches based on whether the target element exists on screen.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ));
        break;

      default:
        break;
    }

    return widgets;
  }

  Widget _buildTargetSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    final target = node.target;
    final mode = target?.mode ?? UITargetMode.coordinate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Text(
          'TARGET',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),

        // Target mode selector
        SegmentedButton<UITargetMode>(
          segments: UITargetMode.values.map((m) {
            return ButtonSegment(
              value: m,
              label: Text(
                m.displayName,
                style: const TextStyle(fontSize: 11),
              ),
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
            textStyle: WidgetStateProperty.all(
              const TextStyle(fontSize: 11),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Mode-specific fields
        if (mode == UITargetMode.coordinate) ...[
          Row(
            children: [
              Expanded(
                child: _configField(
                  'X',
                  (target?.x ?? 0).toInt().toString(),
                  (val) {
                    node.target = UITargetSelector.coordinate(
                      double.tryParse(val) ?? 0,
                      target?.y ?? 0,
                    );
                    provider.updateNode(node);
                  },
                  isNumber: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _configField(
                  'Y',
                  (target?.y ?? 0).toInt().toString(),
                  (val) {
                    node.target = UITargetSelector.coordinate(
                      target?.x ?? 0,
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
          _configField(
            'Name (contains)',
            target?.name ?? '',
            (val) {
              node.target = UITargetSelector.fromAttributes(
                name: val.isNotEmpty ? val : null,
                role: target?.role,
                automationId: target?.automationId,
                className: target?.className,
                controlType: target?.controlType,
              );
              provider.updateNode(node);
            },
            hintText: 'e.g. Save, OK, File',
          ),
          _configField(
            'Role',
            target?.role ?? '',
            (val) {
              node.target = UITargetSelector.fromAttributes(
                name: target?.name,
                role: val.isNotEmpty ? val : null,
                automationId: target?.automationId,
                className: target?.className,
                controlType: target?.controlType,
              );
              provider.updateNode(node);
            },
            hintText: 'e.g. Button, TextBox, MenuItem',
          ),
          _configField(
            'Automation ID',
            target?.automationId ?? '',
            (val) {
              node.target = UITargetSelector.fromAttributes(
                name: target?.name,
                role: target?.role,
                automationId: val.isNotEmpty ? val : null,
                className: target?.className,
                controlType: target?.controlType,
              );
              provider.updateNode(node);
            },
          ),
          _configField(
            'Class Name',
            target?.className ?? '',
            (val) {
              node.target = UITargetSelector.fromAttributes(
                name: target?.name,
                role: target?.role,
                automationId: target?.automationId,
                className: val.isNotEmpty ? val : null,
                controlType: target?.controlType,
              );
              provider.updateNode(node);
            },
          ),
        ],
      ],
    );
  }

  Widget _buildKeyboardSection(
    FlowBuilderProvider provider,
    DesktopFlowNode node,
  ) {
    final config = node.keyboardConfig ??
        const KeyboardNodeConfig(keys: []);

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
            _quickKeyButton(
              'Alt+Tab',
              ['alt', 'tab'],
              provider,
              node,
              config,
            ),
            _quickKeyButton(
              'Alt+F4',
              ['alt', 'f4'],
              provider,
              node,
              config,
            ),
            _quickKeyButton(
              'Win+D',
              ['win', 'd'],
              provider,
              node,
              config,
            ),
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
          ),
          items: KeyboardActionType.values.map((a) {
            return DropdownMenuItem(
              value: a,
              child: Text(a.displayName),
            );
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
        _configField(
          'Repeat count',
          config.repeatCount.toString(),
          (val) {
            node.keyboardConfig = KeyboardNodeConfig(
              keys: config.keys,
              action: config.action,
              holdDurationMs: config.holdDurationMs,
              repeatCount: int.tryParse(val) ?? 1,
              delayBetweenMs: config.delayBetweenMs,
            );
            provider.updateNode(node);
          },
          isNumber: true,
        ),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
                      labelStyle:
                          const TextStyle(color: AppColors.textSecondary),
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
                      labelStyle:
                          const TextStyle(color: AppColors.textSecondary),
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
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.primary),
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
      child: TextFormField(
        initialValue: initialValue,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
        maxLines: maxLines,
        keyboardType: isNumber ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: AppColors.textSecondary),
          hintText: hintText,
          hintStyle: const TextStyle(color: AppColors.textMuted),
          filled: true,
          fillColor: AppColors.surfaceVariant,
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
            borderSide: const BorderSide(color: AppColors.primary),
          ),
        ),
        onChanged: onChanged,
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
      case DesktopFlowNodeType.repeat:
        return Icons.loop;
      case DesktopFlowNodeType.conditional:
        return Icons.call_split;
      case DesktopFlowNodeType.done:
        return Icons.check_circle;
    }
  }
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
                Icon(
                  _icon,
                  size: 16,
                  color: _color,
                ),
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
  final VoidCallback onConnect;
  final VoidCallback? onDelete;

  const _NodeCard({
    required this.node,
    required this.isSelected,
    required this.isExecuting,
    required this.isConnecting,
    required this.onConnect,
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
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 10,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Connect button
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: onConnect,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceVariant,
                  border: Border.all(color: AppColors.border),
                ),
                child: const Icon(
                  Icons.arrow_forward,
                  size: 10,
                  color: AppColors.textMuted,
                ),
              ),
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
      case DesktopFlowNodeType.repeat:
        return Icons.loop;
      case DesktopFlowNodeType.conditional:
        return Icons.call_split;
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
        return AppColors.primaryLight;
      case DesktopFlowNodeType.repeat:
      case DesktopFlowNodeType.conditional:
        return AppColors.error;
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

  _EdgePainter({
    required this.nodes,
    required this.edges,
    this.executingNodeId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in edges) {
      final fromNode = _findNode(edge.fromNodeId);
      final toNode = _findNode(edge.toNodeId);
      if (fromNode == null || toNode == null) continue;

      // Calculate connection points (right side of from, left side of to)
      const nodeWidth = 170.0;
      const nodeHeight = 70.0;

      final from = Offset(
        fromNode.x + nodeWidth,
        fromNode.y + nodeHeight / 2,
      );
      final to = Offset(toNode.x, toNode.y + nodeHeight / 2);

      // Determine color
      Color edgeColor = AppColors.textMuted.withValues(alpha: 0.4);
      if (executingNodeId != null) {
        if (edge.toNodeId == executingNodeId) {
          edgeColor = AppColors.warning;
        }
      }

      final paint = Paint()
        ..color = edgeColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;

      // Draw Bézier curve
      final dx = (to.dx - from.dx).abs() * 0.5;
      final path = Path()
        ..moveTo(from.dx, from.dy)
        ..cubicTo(
          from.dx + dx,
          from.dy,
          to.dx - dx,
          to.dy,
          to.dx,
          to.dy,
        );

      canvas.drawPath(path, paint);

      // Draw arrowhead
      final arrowPaint = Paint()
        ..color = edgeColor
        ..style = PaintingStyle.fill;

      final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
      const arrowSize = 8.0;

      final arrowPath = Path()
        ..moveTo(to.dx, to.dy)
        ..lineTo(
          to.dx - arrowSize * math.cos(angle - 0.5),
          to.dy - arrowSize * math.sin(angle - 0.5),
        )
        ..lineTo(
          to.dx - arrowSize * math.cos(angle + 0.5),
          to.dy - arrowSize * math.sin(angle + 0.5),
        )
        ..close();

      canvas.drawPath(arrowPath, arrowPaint);

      // Draw edge label if present
      if (edge.label != null && edge.label!.isNotEmpty) {
        final midX = (from.dx + to.dx) / 2;
        final midY = (from.dy + to.dy) / 2;
        final textPainter = TextPainter(
          text: TextSpan(
            text: edge.label,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        textPainter.paint(
          canvas,
          Offset(midX - textPainter.width / 2, midY - textPainter.height - 4),
        );
      }
    }
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
