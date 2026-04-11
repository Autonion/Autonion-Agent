import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';

/// Placeholder screen for AI provider selection (Phase 4+).
class AiSettingsScreen extends StatelessWidget {
  const AiSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AI Settings',
              style: Theme.of(context).textTheme.displayMedium)
              .animate().fadeIn(duration: 400.ms).slideX(begin: -0.05),
          const SizedBox(height: 8),
          Text('Configure your AI provider for automation',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 28),

          // ── Provider Cards ──────────────────────
          _ProviderCard(
            title: 'Ollama (Local)',
            subtitle: 'Run AI models locally — no internet required',
            icon: Icons.computer,
            color: AppColors.success,
            isSelected: false,
            comingSoon: true,
          ).animate().fadeIn(duration: 500.ms, delay: 100.ms),
          const SizedBox(height: 12),

          _ProviderCard(
            title: 'API Key (Cloud)',
            subtitle: 'Use OpenAI, Gemini, or any compatible API',
            icon: Icons.cloud_outlined,
            color: AppColors.primary,
            isSelected: false,
            comingSoon: true,
          ).animate().fadeIn(duration: 500.ms, delay: 200.ms),
          const SizedBox(height: 12),

          _ProviderCard(
            title: 'Web-Based (Legacy)',
            subtitle: 'Use ChatGPT/Gemini websites via browser extension',
            icon: Icons.public,
            color: AppColors.warning,
            isSelected: true,
            comingSoon: false,
          ).animate().fadeIn(duration: 500.ms, delay: 300.ms),
        ],
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final bool isSelected;
  final bool comingSoon;

  const _ProviderCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.isSelected,
    required this.comingSoon,
  });

  @override
  Widget build(BuildContext context) {
    return GlassmorphicCard(
      borderColor: isSelected ? color.withAlpha(120) : null,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title,
                        style: Theme.of(context).textTheme.titleMedium),
                    if (comingSoon) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withAlpha(30),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('Coming Soon',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: AppColors.accent)),
                      ),
                    ],
                    if (isSelected && !comingSoon) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: color.withAlpha(30),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('Active',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: color)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (!comingSoon && isSelected)
            Icon(Icons.check_circle, color: color, size: 24),
        ],
      ),
    );
  }
}
