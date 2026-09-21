import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/di/service_locator.dart';
import '../../features/system/services/update_service.dart';
import '../theme/app_colors.dart';
import 'update_release_button.dart';

/// A banner that slides in at the top of the app when a new version
/// is available on GitHub Releases.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final updateService = getIt<UpdateService>();

    return ListenableBuilder(
      listenable: updateService,
      builder: (context, _) {
        if (!updateService.updateAvailable) {
          return const SizedBox.shrink();
        }

        return Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1A3A5C), Color(0xFF0D2240)],
                ),
                border: Border(
                  bottom: BorderSide(color: AppColors.primary, width: 1),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(40),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.system_update_outlined,
                      color: AppColors.primary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Update Available — v${updateService.latestVersion}',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Download the installer from GitHub, then run it to update.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  UpdateReleaseButton(
                    url: updateService.releaseUrl,
                    filled: true,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => updateService.dismiss(),
                    icon: const Icon(Icons.close, size: 18),
                    color: AppColors.textSecondary,
                    tooltip: 'Dismiss',
                    splashRadius: 16,
                  ),
                ],
              ),
            )
            .animate()
            .slideY(begin: -1, duration: 400.ms, curve: Curves.easeOut)
            .fadeIn();
      },
    );
  }
}
