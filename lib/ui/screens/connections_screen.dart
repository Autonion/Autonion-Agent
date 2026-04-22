import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/di/service_locator.dart';
import '../../features/browser_automation/services/browser_launcher_service.dart';
import '../../features/connection/providers/connection_provider.dart';
import '../../features/connection/services/websocket_service.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/status_indicator.dart';

/// Shows connected devices and browser/extension status.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final conn = getIt<ConnectionProvider>();
    final ws = getIt<WebSocketService>();
    final browser = getIt<BrowserLauncherService>();

    return ListenableBuilder(
      listenable: Listenable.merge([conn, ws, browser]),
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connections',
                style: Theme.of(context).textTheme.displayMedium,
              ).animate().fadeIn(duration: 400.ms).slideX(begin: -0.05),
              const SizedBox(height: 8),
              Text(
                'Manage connected devices and browser extension',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 28),

              // ── WebSocket Server Status ─────────────
              _ServerStatusCard(
                conn: conn,
                ws: ws,
              ).animate().fadeIn(duration: 500.ms, delay: 100.ms),
              const SizedBox(height: 16),

              // ── Browser Selector ────────────────────
              _BrowserSelectorCard(
                browser: browser,
                ws: ws,
              ).animate().fadeIn(duration: 500.ms, delay: 200.ms),
              const SizedBox(height: 16),

              // ── Device Info ─────────────────────────
              _DeviceInfoCard(
                conn: conn,
              ).animate().fadeIn(duration: 500.ms, delay: 300.ms),
            ],
          ),
        );
      },
    );
  }
}

class _ServerStatusCard extends StatelessWidget {
  final ConnectionProvider conn;
  final WebSocketService ws;
  const _ServerStatusCard({required this.conn, required this.ws});

  @override
  Widget build(BuildContext context) {
    return GlassmorphicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.dns_outlined,
                color: AppColors.primary,
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                'WebSocket Server',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              StatusIndicator(isOnline: conn.isRunning),
              const SizedBox(width: 8),
              Text(
                conn.isRunning ? 'Running' : 'Stopped',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: conn.isRunning ? AppColors.success : AppColors.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (conn.isRunning) ...[
            _infoRow(context, 'Port', '${conn.port}'),
            _infoRow(context, 'Clients', '${ws.connectedClients}'),
            _infoRow(
              context,
              'Extension',
              ws.hasExtensionClient ? 'Connected' : 'Not Connected',
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: () {
                  if (conn.isRunning) {
                    conn.stopServices();
                  } else {
                    conn.startServices();
                  }
                },
                icon: Icon(
                  conn.isRunning
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline,
                  size: 18,
                ),
                label: Text(
                  conn.isRunning ? 'Stop Services' : 'Start Services',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: conn.isRunning
                      ? AppColors.error
                      : AppColors.success,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _BrowserSelectorCard extends StatelessWidget {
  final BrowserLauncherService browser;
  final WebSocketService ws;
  const _BrowserSelectorCard({required this.browser, required this.ws});

  @override
  Widget build(BuildContext context) {
    return GlassmorphicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.public, color: AppColors.secondary, size: 22),
              const SizedBox(width: 10),
              Text('Browser', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Icon(
                Icons.extension,
                size: 16,
                color: ws.hasExtensionClient
                    ? AppColors.success
                    : AppColors.warning,
              ),
              const SizedBox(width: 6),
              Text(
                ws.hasExtensionClient ? 'Extension Connected' : 'Waiting',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: ws.hasExtensionClient
                      ? AppColors.success
                      : AppColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (browser.detectedBrowsers.isEmpty)
            Text(
              'No browsers detected',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.error),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: browser.selectedBrowser?.name,
              decoration: const InputDecoration(
                labelText: 'Select Browser',
                prefixIcon: Icon(Icons.web, size: 20),
              ),
              items: browser.detectedBrowsers
                  .map(
                    (b) => DropdownMenuItem(value: b.name, child: Text(b.name)),
                  )
                  .toList(),
              onChanged: (name) {
                if (name != null) browser.selectBrowser(name);
              },
            ),
        ],
      ),
    );
  }
}

class _DeviceInfoCard extends StatelessWidget {
  final ConnectionProvider conn;
  const _DeviceInfoCard({required this.conn});

  @override
  Widget build(BuildContext context) {
    final info = conn.deviceInfo;
    return GlassmorphicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.perm_device_information,
                color: AppColors.accent,
                size: 22,
              ),
              const SizedBox(width: 10),
              Text(
                'This Device',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _infoRow(context, 'Name', info.deviceName),
          _infoRow(context, 'ID', '${info.deviceId.substring(0, 8)}...'),
          _infoRow(context, 'Platform', info.platform),
        ],
      ),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}
