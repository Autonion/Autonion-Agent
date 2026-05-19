import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/config/app_config.dart';
import '../../core/config/platform_config.dart';
import '../../core/di/service_locator.dart';
import '../../features/system/services/startup_service.dart';
import '../../features/system/services/update_service.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';

/// General settings: startup, system tray, about.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _launchAtStartup = false;
  bool _minimizeToTray = true;

  @override
  void initState() {
    super.initState();
    if (PlatformConfig.isDesktop && getIt.isRegistered<StartupService>()) {
      _launchAtStartup = getIt<StartupService>().isEnabled;
    }
  }

  @override
  Widget build(BuildContext context) {
    final updateService = getIt<UpdateService>();

    return ListenableBuilder(
      listenable: updateService,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Settings',
                style: Theme.of(context).textTheme.displayMedium,
              ).animate().fadeIn(duration: 400.ms).slideX(begin: -0.05),
              const SizedBox(height: 8),
              Text(
                'Configure app behavior and preferences',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── System ──────────────────────────────
              if (PlatformConfig.isDesktop) ...[
                Text('System', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                GlassmorphicCard(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 20),
                  child: Column(
                    children: [
                      _SettingsTile(
                        icon: Icons.rocket_launch_outlined,
                        title: 'Launch at Startup',
                        subtitle: 'Start Autonion when you log in',
                        trailing: Switch(
                          value: _launchAtStartup,
                          onChanged: (v) async {
                            setState(() => _launchAtStartup = v);
                            if (getIt.isRegistered<StartupService>()) {
                              await getIt<StartupService>().setEnabled(v);
                            }
                          },
                        ),
                      ),
                      const Divider(),
                      _SettingsTile(
                        icon: Icons.minimize,
                        title: 'Minimize to Tray',
                        subtitle: 'Keep running in system tray when closed',
                        trailing: Switch(
                          value: _minimizeToTray,
                          onChanged: (v) => setState(() => _minimizeToTray = v),
                        ),
                      ),
                    ],
                  ),
                ).animate().fadeIn(duration: 500.ms, delay: 100.ms),
                const SizedBox(height: 24),
              ],

              // ── About ───────────────────────────────
              Text('About', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              GlassmorphicCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.asset(
                            'assets/icons/tray_icon.png',
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppConfig.appName,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                'v${AppConfig.appVersion}',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        // ── Check for Updates button ────────
                        if (updateService.isChecking)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: () => updateService.checkForUpdate(),
                            icon: Icon(
                              updateService.updateAvailable
                                  ? Icons.system_update
                                  : Icons.refresh,
                              size: 16,
                            ),
                            label: Text(
                              updateService.updateAvailable
                                  ? 'v${updateService.latestVersion} Available'
                                  : 'Check for Updates',
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: updateService.updateAvailable
                                  ? AppColors.success
                                  : AppColors.textSecondary,
                              side: BorderSide(
                                color: updateService.updateAvailable
                                    ? AppColors.success.withAlpha(120)
                                    : AppColors.border,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              textStyle: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                    // ── Update available info ──────────────
                    if (updateService.updateAvailable) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.success.withAlpha(20),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppColors.success.withAlpha(60),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.celebration,
                              color: AppColors.success,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'New version v${updateService.latestVersion} is available!',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppColors.success,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                final url = updateService.releaseUrl;
                                if (url != null) {
                                  launchUrl(
                                    Uri.parse(url),
                                    mode: LaunchMode.externalApplication,
                                  );
                                }
                              },
                              child: const Text('Download'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Cross-device AI-powered automation agent. '
                      'Bridges Android, browser extensions, and desktop '
                      'for unified automation workflows.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(duration: 500.ms, delay: 200.ms),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primary, size: 22),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}
