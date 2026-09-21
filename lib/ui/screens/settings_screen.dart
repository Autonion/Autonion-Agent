import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import '../../core/config/app_config.dart';
import '../../core/config/platform_config.dart';
import '../../core/di/service_locator.dart';
import '../../features/connection/providers/connection_provider.dart';
import '../../features/desktop_automation/services/unlock_admin_service.dart';
import '../../features/system/services/startup_service.dart';
import '../../features/system/services/update_service.dart';
import '../../features/system/services/window_manager_service.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/update_release_button.dart';

/// General settings: startup, system tray, about.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _launchAtStartup = true;
  bool _minimizeToTray = true;

  @override
  void initState() {
    super.initState();
    if (PlatformConfig.isDesktop) {
      if (getIt.isRegistered<StartupService>()) {
        _launchAtStartup = getIt<StartupService>().isEnabled;
      }
      if (getIt.isRegistered<WindowManagerService>()) {
        _minimizeToTray = getIt<WindowManagerService>().minimizeToTray;
      }
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
                          onChanged: (v) async {
                            setState(() => _minimizeToTray = v);
                            if (getIt.isRegistered<WindowManagerService>()) {
                              await getIt<WindowManagerService>().setMinimizeToTray(v);
                            }
                          },
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
                              updateService.hasUpdate
                                  ? Icons.system_update
                                  : Icons.refresh,
                              size: 16,
                            ),
                            label: Text(
                              updateService.hasUpdate
                                  ? 'v${updateService.latestVersion} Available'
                                  : 'Check for Updates',
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: updateService.hasUpdate
                                  ? AppColors.success
                                  : AppColors.textSecondary,
                              side: BorderSide(
                                color: updateService.hasUpdate
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
                    const SizedBox(height: 12),
                    Text(
                      updateService.statusMessage,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: updateService.status == UpdateStatus.error
                            ? AppColors.warning
                            : AppColors.textSecondary,
                      ),
                    ),
                    if (updateService.lastCheckedAt != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Last checked: ${DateFormat('MMM d, HH:mm').format(updateService.lastCheckedAt!.toLocal())}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                    // ── Update available info ──────────────
                    if (updateService.hasUpdate) ...[
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
                                'Download the installer from GitHub, then run it to update.',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppColors.success,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            UpdateReleaseButton(url: updateService.releaseUrl),
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

              // ── Maintenance / Uninstall ─────────────
              if (PlatformConfig.isDesktop) ...[
                const SizedBox(height: 24),
                Text(
                  'Maintenance',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                GlassmorphicCard(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 20,
                  ),
                  child: _SettingsTile(
                    icon: Icons.delete_forever_outlined,
                    title: 'Uninstall Autonion Agent',
                    subtitle:
                        'Remove background services, firewall rules, and app data',
                    trailing: ElevatedButton(
                      onPressed: () => _showUninstallDialog(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.error.withValues(
                          alpha: 0.15,
                        ),
                        foregroundColor: AppColors.error,
                        elevation: 0,
                        side: BorderSide(
                          color: AppColors.error.withValues(alpha: 0.4),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('Uninstall'),
                    ),
                  ),
                ).animate().fadeIn(duration: 500.ms, delay: 300.ms),
              ],
            ],
          ),
        );
      },
    );
  }

  void _showUninstallDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: AppColors.error.withValues(alpha: 0.3),
          ),
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.error.withValues(alpha: 0.12),
              ),
              child: const Icon(
                Icons.delete_forever_rounded,
                color: AppColors.error,
                size: 38,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Uninstall Autonion Agent?',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'This will stop all running connections, clean up the background unlock service, remove firewall rules, and launch the uninstaller.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      side: const BorderSide(color: AppColors.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      if (getIt.isRegistered<StartupService>()) {
                        await getIt<StartupService>().setEnabled(false);
                      }
                      if (getIt.isRegistered<ConnectionProvider>()) {
                        await getIt<ConnectionProvider>().stopServices();
                      }
                      if (getIt.isRegistered<UnlockAdminService>()) {
                        final admin = getIt<UnlockAdminService>();
                        await admin.launchAppUninstaller();
                      }
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Uninstall'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.error,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
