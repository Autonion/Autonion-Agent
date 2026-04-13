import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/di/service_locator.dart';
import '../../features/desktop_automation/models/automation_tier.dart';
import '../../features/desktop_automation/providers/desktop_automation_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';

class AutomationScreen extends StatefulWidget {
  const AutomationScreen({super.key});

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  final _automationProvider = getIt<DesktopAutomationProvider>();
  final _goalCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _automationProvider.addListener(_onUpdate);
  }

  @override
  void dispose() {
    _automationProvider.removeListener(_onUpdate);
    _goalCtrl.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = _automationProvider.isRunning;
    final isReady = _automationProvider.isBridgeReady;
    final statusText = _automationProvider.statusText;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Desktop Automation',
                  style: Theme.of(context).textTheme.displayMedium)
                  .animate().fadeIn(duration: 400.ms).slideX(begin: -0.05),
              
              // Status Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isRunning 
                      ? AppColors.primary.withAlpha(40) 
                      : (isReady ? AppColors.success.withAlpha(40) : AppColors.error.withAlpha(40)),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isRunning 
                      ? AppColors.primary.withAlpha(100) 
                      : (isReady ? AppColors.success.withAlpha(100) : AppColors.error.withAlpha(100)),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isRunning) ...[
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      statusText,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: isRunning 
                          ? AppColors.primary 
                          : (isReady ? AppColors.success : AppColors.error),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(delay: 200.ms),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'AI-powered autonomous agent for Windows',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 32),

          // ── Action Panel ─────────────────────────────
          GlassmorphicCard(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('What do you want to do?', 
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _goalCtrl,
                    maxLines: 3,
                    enabled: !isRunning,
                    decoration: const InputDecoration(
                      hintText: 'e.g. Open Notepad, type "Hello World", and save it as hello.txt on the desktop...',
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Tier Selection
                      DropdownButtonHideUnderline(
                        child: DropdownButton<AutomationTier>(
                          value: _automationProvider.tier,
                          dropdownColor: AppColors.surfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                          items: AutomationTier.values.map((tier) {
                            return DropdownMenuItem(
                              value: tier,
                              child: Text(tier.displayName),
                            );
                          }).toList(),
                          onChanged: isRunning ? null : (tier) {
                            if (tier != null) {
                              _automationProvider.setTier(tier);
                            }
                          },
                        ),
                      ),
                      
                      // Run/Stop Button
                      if (isRunning)
                        ElevatedButton.icon(
                          onPressed: () => _automationProvider.stop(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.error.withOpacity(0.2),
                            foregroundColor: AppColors.error,
                          ),
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop Agent'),
                        )
                      else
                        ElevatedButton.icon(
                          onPressed: () {
                            if (_goalCtrl.text.trim().isEmpty) return;
                            _automationProvider.runGoal(_goalCtrl.text.trim());
                          },
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Run Task'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ).animate().fadeIn(duration: 600.ms, delay: 100.ms).slideY(begin: 0.05),

          const SizedBox(height: 24),
          
          if (!isReady)
            Center(
              child: ElevatedButton.icon(
                onPressed: () => _automationProvider.initBridge(),
                icon: const Icon(Icons.build),
                label: const Text('Initialize Python Bridge'),
              ),
            ),

        ],
      ),
    );
  }
}
