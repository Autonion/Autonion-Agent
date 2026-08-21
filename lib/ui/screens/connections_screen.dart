import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import '../../core/di/service_locator.dart';
import '../../features/browser_automation/services/browser_launcher_service.dart';
import '../../features/connection/models/paired_device.dart';
import '../../features/connection/providers/connection_provider.dart';
import '../../features/connection/services/websocket_service.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/status_indicator.dart';

/// Shows connected devices, paired companions, and browser/extension status.
class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final conn = getIt<ConnectionProvider>();
    final ws = getIt<WebSocketService>();
    final browser = getIt<BrowserLauncherService>();

    return ListenableBuilder(
      listenable: Listenable.merge([conn, ws, browser, conn.pairedDevices]),
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
                'Manage connected devices, trusted companions, and browser extension',
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

              // ── Paired Devices ──────────────────────
              _PairedDevicesCard(
                conn: conn,
              ).animate().fadeIn(duration: 500.ms, delay: 150.ms),
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
              ).animate().fadeIn(duration: 500.ms, delay: 250.ms),
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
    final pendingCount = ws.connectedClients - ws.authenticatedClientsCount;

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
            _infoRow(context, 'Trusted Clients', '${ws.authenticatedClientsCount}'),
            if (pendingCount > 0)
              _infoRow(context, 'Pending Sockets', '$pendingCount'),
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

class _PairedDevicesCard extends StatelessWidget {
  final ConnectionProvider conn;
  const _PairedDevicesCard({required this.conn});

  @override
  Widget build(BuildContext context) {
    final pairedDevices = conn.pairedDevices.pairedDevices;
    final allowPairings = conn.pairedDevices.allowNewPairings;

    return GlassmorphicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.phonelink_lock_rounded,
                color: AppColors.accent,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Paired Companion Devices',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      allowPairings
                          ? 'Allowing new device pairings'
                          : 'New pairings blocked',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: allowPairings
                                ? AppColors.success
                                : AppColors.warning,
                            fontSize: 11,
                          ),
                    ),
                  ],
                ),
              ),
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: allowPairings,
                  onChanged: (val) {
                    conn.pairedDevices.setAllowNewPairings(val);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (pairedDevices.isEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withAlpha(10)),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.devices_other_rounded,
                    size: 32,
                    color: AppColors.textSecondary.withAlpha(120),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No paired companion devices',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'When a phone connects on LAN, a PIN pairing prompt will appear.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
          ] else ...[
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: pairedDevices.length,
              separatorBuilder: (_, __) => const Divider(height: 12),
              itemBuilder: (context, index) {
                final device = pairedDevices[index];
                return _PairedDeviceTile(
                  device: device,
                  onRevoke: () => _confirmRevoke(context, device),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  void _confirmRevoke(BuildContext context, PairedDevice device) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceElevated,
        title: const Text('Unpair Device?'),
        content: Text(
          'Are you sure you want to revoke access for "${device.name}"? '
          'This device will immediately be disconnected and will require a new PIN to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              conn.revokeDevice(device.id);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
  }
}

class _PairedDeviceTile extends StatelessWidget {
  final PairedDevice device;
  final VoidCallback onRevoke;

  const _PairedDeviceTile({
    required this.device,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('MMM d, yyyy');
    final pairedDateStr = dateFormat.format(device.pairedAt);
    final lastSeenStr = _formatLastSeen(device.lastSeen);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(25),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.phone_android_rounded,
              color: AppColors.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Paired: $pairedDateStr • Last seen: $lastSeenStr${device.lastIp != null ? " (${device.lastIp})" : ""}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            color: AppColors.error.withAlpha(180),
            tooltip: 'Revoke device',
            onPressed: onRevoke,
          ),
        ],
      ),
    );
  }

  String _formatLastSeen(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('MMM d').format(dt);
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
