import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

import '../../features/desktop_automation/models/desktop_flow_models.dart';
import '../../features/desktop_automation/providers/flow_builder_provider.dart';
import '../theme/app_colors.dart';

/// Displays all saved flows in a card grid with create, run, edit, delete actions.
class FlowListPanel extends StatelessWidget {
  const FlowListPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<FlowBuilderProvider>(
      builder: (context, provider, _) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ─────────────────────────────────
              _buildHeader(context, provider),
              const SizedBox(height: 24),
              // ── Flow Grid ──────────────────────────────
              Expanded(
                child: provider.flows.isEmpty
                    ? _buildEmptyState(context, provider)
                    : _buildFlowGrid(context, provider),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, FlowBuilderProvider provider) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: AppColors.accentGradient,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.account_tree_rounded,
            color: Colors.white,
            size: 24,
          ),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Automation Flows',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '${provider.flows.length} flow${provider.flows.length == 1 ? '' : 's'}',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const Spacer(),
        // Import Flow button
        OutlinedButton.icon(
          onPressed: () => provider.importFlow(),
          icon: const Icon(Icons.file_download_outlined, size: 18),
          label: const Text('Import'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
            side: const BorderSide(color: AppColors.border),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _CreateFlowButton(provider: provider),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context, FlowBuilderProvider provider) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.account_tree_outlined,
              color: AppColors.textMuted,
              size: 48,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'No flows yet',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Create your first automation flow to get started',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          _CreateFlowButton(provider: provider),
        ],
      ),
    )
        .animate()
        .fadeIn(duration: 400.ms)
        .slideY(begin: 0.1, end: 0, duration: 400.ms);
  }

  Widget _buildFlowGrid(BuildContext context, FlowBuilderProvider provider) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 360,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 1.4,
      ),
      itemCount: provider.flows.length,
      itemBuilder: (context, index) {
        final flow = provider.flows[index];
        return _FlowCard(flow: flow, provider: provider)
            .animate()
            .fadeIn(
              duration: 300.ms,
              delay: Duration(milliseconds: 50 * index),
            )
            .slideY(begin: 0.1, end: 0, duration: 300.ms);
      },
    );
  }
}

class _CreateFlowButton extends StatelessWidget {
  final FlowBuilderProvider provider;

  const _CreateFlowButton({required this.provider});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => _showCreateDialog(context),
      icon: const Icon(Icons.add, size: 18),
      label: const Text('New Flow'),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        title: const Text(
          'Create New Flow',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: const TextStyle(color: AppColors.textPrimary),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  final name = nameCtrl.text.trim();
                  if (name.isNotEmpty) {
                    provider.newFlow(name, description: descCtrl.text.trim());
                    Navigator.pop(ctx);
                  }
                },
                decoration: InputDecoration(
                  labelText: 'Flow Name',
                  labelStyle: const TextStyle(color: AppColors.textSecondary),
                  hintText: 'e.g. Open Notepad and Type Hello',
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
              const SizedBox(height: 12),
              TextField(
                controller: descCtrl,
                style: const TextStyle(color: AppColors.textPrimary),
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Description (optional)',
                  labelStyle: const TextStyle(color: AppColors.textSecondary),
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
              final name = nameCtrl.text.trim();
              if (name.isNotEmpty) {
                provider.newFlow(name, description: descCtrl.text.trim());
                Navigator.pop(ctx);
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
            ),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

class _FlowCard extends StatelessWidget {
  final DesktopFlow flow;
  final FlowBuilderProvider provider;

  const _FlowCard({required this.flow, required this.provider});

  @override
  Widget build(BuildContext context) {
    final nodeCount = flow.nodes.length;
    final triggerLabel = flow.trigger.summary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => provider.openFlow(flow.id),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.account_tree_rounded,
                      color: AppColors.accent,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      flow.name,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _buildPopupMenu(context),
                ],
              ),

              if (flow.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  flow.description,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],

              const Spacer(),

              // Metadata row
              Row(
                children: [
                  _chip(Icons.blur_circular, '$nodeCount nodes'),
                  const SizedBox(width: 8),
                  _chip(Icons.bolt, triggerLabel),
                ],
              ),

              const SizedBox(height: 10),

              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 32,
                      child: OutlinedButton.icon(
                        onPressed: () => provider.openFlow(flow.id),
                        icon: const Icon(Icons.edit, size: 14),
                        label: const Text('Edit', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                          side: const BorderSide(color: AppColors.border),
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 32,
                      child: FilledButton.icon(
                        onPressed: () async {
                          provider.openFlow(flow.id);
                          // Small delay to ensure flow is loaded before running
                          await Future.delayed(
                            const Duration(milliseconds: 100),
                          );
                          provider.runFlow();
                        },
                        icon: const Icon(Icons.play_arrow, size: 14),
                        label: const Text('Run', style: TextStyle(fontSize: 12)),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.success.withValues(alpha: 0.2),
                          foregroundColor: AppColors.success,
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: AppColors.textMuted),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPopupMenu(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(
        Icons.more_vert,
        color: AppColors.textMuted,
        size: 18,
      ),
      color: AppColors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.border),
      ),
      onSelected: (value) async {
        switch (value) {
          case 'export':
            await provider.exportFlow(flow.id);
            break;
          case 'duplicate':
            await provider.duplicateFlow(flow.id);
            break;
          case 'delete':
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: AppColors.border),
                ),
                title: const Text(
                  'Delete Flow',
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                content: Text(
                  'Are you sure you want to delete "${flow.name}"?',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.error,
                    ),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await provider.deleteFlow(flow.id);
            }
            break;
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'export',
          child: Row(
            children: [
              Icon(Icons.file_upload_outlined, size: 16, color: AppColors.textSecondary),
              SizedBox(width: 8),
              Text(
                'Export',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'duplicate',
          child: Row(
            children: [
              Icon(Icons.copy, size: 16, color: AppColors.textSecondary),
              SizedBox(width: 8),
              Text(
                'Duplicate',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 16, color: AppColors.error),
              SizedBox(width: 8),
              Text(
                'Delete',
                style: TextStyle(color: AppColors.error, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
