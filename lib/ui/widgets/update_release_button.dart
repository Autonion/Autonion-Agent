import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../features/system/services/update_service.dart';

/// Opens the release notes and installer assets in the user's browser.
class UpdateReleaseButton extends StatelessWidget {
  const UpdateReleaseButton({
    super.key,
    required this.url,
    this.filled = false,
  });

  final String? url;
  final bool filled;

  Future<void> _open(BuildContext context) async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url!),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Report platform errors and missing browser handlers in the same way.
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open your browser. Visit ${UpdateService.releasesUrl} to download the update.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = url == null ? null : () => _open(context);
    return filled
        ? FilledButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('View release'),
          )
        : TextButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('View release'),
          );
  }
}
