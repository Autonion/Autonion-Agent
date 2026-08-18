import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/di/service_locator.dart';
import '../../features/connection/providers/connection_provider.dart';
import '../theme/app_colors.dart';
import 'glassmorphic_card.dart';

/// Modal overlay that pops up on the Desktop screen when an unknown phone
/// attempts to pair, displaying the 6-digit PIN and countdown timer.
class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key});

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  Timer? _ticker;
  int _secondsLeft = 120;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  void _startCountdown() {
    final conn = getIt<ConnectionProvider>();
    final pairing = conn.activePairing;
    if (pairing != null) {
      final elapsed = DateTime.now().difference(pairing.createdAt).inSeconds;
      _secondsLeft = (120 - elapsed).clamp(0, 120);
    }

    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      final currentPairing = getIt<ConnectionProvider>().activePairing;
      if (currentPairing == null) {
        timer.cancel();
        return;
      }
      final elapsed =
          DateTime.now().difference(currentPairing.createdAt).inSeconds;
      final remaining = (120 - elapsed).clamp(0, 120);
      setState(() {
        _secondsLeft = remaining;
      });
      if (remaining <= 0) {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conn = getIt<ConnectionProvider>();
    final pairing = conn.activePairing;

    if (pairing == null) {
      return const SizedBox.shrink();
    }

    // Format PIN into "123 456" for readability
    final pin = pairing.pin;
    final formattedPin = pin.length == 6
        ? '${pin.substring(0, 3)} ${pin.substring(3)}'
        : pin;

    return Container(
      color: Colors.black.withAlpha(160),
      alignment: Alignment.center,
      child: GlassmorphicCard(
        borderRadius: 24,
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon Header
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primary.withAlpha(50),
                      AppColors.accent.withAlpha(30),
                    ],
                  ),
                  border: Border.all(
                    color: AppColors.primary.withAlpha(120),
                    width: 2,
                  ),
                ),
                child: const Icon(
                  Icons.phonelink_lock_rounded,
                  color: AppColors.primary,
                  size: 32,
                ),
              ).animate().scale(duration: 400.ms, curve: Curves.easeOutBack),
              const SizedBox(height: 18),

              // Title
              Text(
                'Pairing Request',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
              ),
              const SizedBox(height: 8),

              // Device details
              Text(
                '${pairing.deviceName} (${pairing.remoteIp}) wants to connect to this agent.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
              const SizedBox(height: 24),

              // PIN Container
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withAlpha(180),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppColors.primary.withAlpha(100),
                    width: 1.5,
                  ),
                ),
                child: Text(
                  formattedPin,
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 8,
                    color: AppColors.primary,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(height: 14),

              Text(
                'Enter this 6-digit PIN on your phone to approve.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
              const SizedBox(height: 16),

              // Countdown Indicator
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: 16,
                    color: _secondsLeft < 30
                        ? AppColors.error
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Expires in ${_secondsLeft}s',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _secondsLeft < 30
                          ? AppColors.error
                          : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Decline Button
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    conn.cancelActivePairing();
                  },
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Decline Request'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error.withAlpha(120)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ).animate().scale(begin: const Offset(0.9, 0.9), duration: 250.ms).fadeIn(),
    );
  }
}
