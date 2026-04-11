import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';

/// Placeholder screen for Desktop Automation controls (Phase 4+).
class AutomationScreen extends StatelessWidget {
  const AutomationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Desktop Automation',
              style: Theme.of(context).textTheme.displayMedium)
              .animate().fadeIn(duration: 400.ms).slideX(begin: -0.05),
          const SizedBox(height: 8),
          Text(
            'AI-powered desktop automation using accessibility tree',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 32),
          GlassmorphicCard(
            child: Column(
              children: [
                const Icon(Icons.construction,
                    size: 48, color: AppColors.accent),
                const SizedBox(height: 16),
                Text('Coming Soon',
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  'Desktop automation will allow the AI agent to interact with '
                  'any desktop application using the Windows UI Automation tree, '
                  'mouse/keyboard simulation, and optional screenshot analysis.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _FeatureChip(label: 'Accessibility Tree', icon: Icons.account_tree),
                    _FeatureChip(label: 'Mouse & Keyboard', icon: Icons.mouse),
                    _FeatureChip(label: 'Screenshot OCR', icon: Icons.screenshot),
                    _FeatureChip(label: 'Agentic Loop', icon: Icons.loop),
                  ],
                ),
              ],
            ),
          ).animate().fadeIn(duration: 600.ms, delay: 200.ms).scale(begin: const Offset(0.95, 0.95)),
        ],
      ),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _FeatureChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16, color: AppColors.secondary),
      label: Text(label, style: Theme.of(context).textTheme.bodySmall),
      backgroundColor: AppColors.surfaceVariant,
      side: const BorderSide(color: AppColors.border),
    );
  }
}
