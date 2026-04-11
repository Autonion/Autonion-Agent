import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/config/platform_config.dart';
import '../../core/di/service_locator.dart';
import '../../core/models/log_entry.dart';
import '../../core/services/logging_service.dart';
import '../../features/connection/providers/connection_provider.dart';
import '../../features/connection/services/websocket_service.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/status_indicator.dart';

/// Main dashboard — overview of connection state, devices, and quick actions.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final conn = getIt<ConnectionProvider>();
    final ws = getIt<WebSocketService>();
    final log = getIt<LoggingService>();

    return ListenableBuilder(
      listenable: Listenable.merge([conn, ws, log]),
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────
              Text('Dashboard',
                  style: Theme.of(context).textTheme.displayMedium)
                  .animate().fadeIn(duration: 400.ms).slideX(begin: -0.05),
              const SizedBox(height: 8),
              Text(
                'Autonion Agent on ${PlatformConfig.platformName}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
              const SizedBox(height: 28),

              // ── Status Cards Row ────────────────────
              Row(
                children: [
                  Expanded(child: _StatusCard(conn: conn, ws: ws)),
                  const SizedBox(width: 16),
                  Expanded(child: _ConnectionStatsCard(ws: ws)),
                  const SizedBox(width: 16),
                  Expanded(child: _PlatformCard()),
                ],
              ).animate().fadeIn(duration: 500.ms, delay: 100.ms),
              const SizedBox(height: 20),

              // ── Network Info ────────────────────────
              _NetworkInfoCard(conn: conn)
                  .animate().fadeIn(duration: 500.ms, delay: 200.ms),
              const SizedBox(height: 20),

              // ── Quick Actions ───────────────────────
              Text('Quick Actions',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _ActionChip(
                    icon: conn.isRunning
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                    label: conn.isRunning ? 'Stop Services' : 'Start Services',
                    color: conn.isRunning ? AppColors.error : AppColors.success,
                    onTap: () {
                      if (conn.isRunning) {
                        conn.stopServices();
                      } else {
                        conn.startServices();
                      }
                    },
                  ),
                  _ActionChip(
                    icon: Icons.delete_sweep_outlined,
                    label: 'Clear Logs',
                    color: AppColors.textSecondary,
                    onTap: () => log.clearLogs(),
                  ),
                ],
              ).animate().fadeIn(duration: 500.ms, delay: 300.ms),

              const SizedBox(height: 24),

              // ── Recent Logs ─────────────────────────
              Text('Recent Logs',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              _RecentLogsCard(log: log)
                  .animate().fadeIn(duration: 500.ms, delay: 400.ms),
            ],
          ),
        );
      },
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final ConnectionProvider conn;
  final WebSocketService ws;
  const _StatusCard({required this.conn, required this.ws});

  @override
  Widget build(BuildContext context) {
    return GlassmorphicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusIndicator(isOnline: conn.isRunning),
              const SizedBox(width: 10),
              Text(
                conn.isRunning ? 'Online' : 'Offline',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: conn.isRunning
                        ? AppColors.success
                        : AppColors.error),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Server Status',
              style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(
            conn.isRunning
                ? 'Port ${conn.port ?? "..."}'
                : 'Not running',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ConnectionStatsCard extends StatelessWidget {
  final WebSocketService ws;
  const _ConnectionStatsCard({required this.ws});

  @override
  Widget build(BuildContext context) {
    return GlassmorphicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.devices, color: AppColors.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '${ws.connectedClients}',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: AppColors.primary,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Connected Clients',
              style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.extension,
                  size: 14,
                  color: ws.hasExtensionClient
                      ? AppColors.success
                      : AppColors.textMuted),
              const SizedBox(width: 4),
              Text(
                ws.hasExtensionClient ? 'Extension ✓' : 'No Extension',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: ws.hasExtensionClient
                          ? AppColors.success
                          : AppColors.textMuted,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlatformCard extends StatelessWidget {
  const _PlatformCard();

  @override
  Widget build(BuildContext context) {
    return GlassmorphicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_platformIcon, color: AppColors.accent, size: 20),
              const SizedBox(width: 8),
              Text(PlatformConfig.platformName,
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 12),
          Text('Platform', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(
            PlatformConfig.isDesktop ? 'Full features' : 'Connection only',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  IconData get _platformIcon {
    if (Platform.isWindows) return Icons.desktop_windows;
    if (Platform.isMacOS) return Icons.laptop_mac;
    if (Platform.isLinux) return Icons.computer;
    return Icons.device_unknown;
  }
}

class _NetworkInfoCard extends StatelessWidget {
  final ConnectionProvider conn;
  const _NetworkInfoCard({required this.conn});

  @override
  Widget build(BuildContext context) {
    return GlassmorphicCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Network', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          FutureBuilder<List<NetworkInterface>>(
            future: NetworkInterface.list(type: InternetAddressType.IPv4),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return Text('Fetching...',
                    style: Theme.of(context).textTheme.bodySmall);
              }
              return Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  for (var iface in snapshot.data!)
                    for (var addr in iface.addresses)
                      if (!addr.isLoopback)
                        Chip(
                          avatar: const Icon(Icons.lan, size: 16,
                              color: AppColors.secondary),
                          label: Text('${iface.name}: ${addr.address}',
                              style: Theme.of(context).textTheme.bodySmall),
                          backgroundColor: AppColors.surfaceVariant,
                          side: const BorderSide(color: AppColors.border),
                        ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: color.withAlpha(80)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentLogsCard extends StatelessWidget {
  final LoggingService log;
  const _RecentLogsCard({required this.log});

  @override
  Widget build(BuildContext context) {
    final recentEntries = log.entries.length > 8
        ? log.entries.sublist(log.entries.length - 8)
        : log.entries;

    return GlassmorphicCard(
      padding: const EdgeInsets.all(16),
      child: recentEntries.isEmpty
          ? Text('No logs yet',
              style: Theme.of(context).textTheme.bodySmall)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: recentEntries.reversed.map((entry) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      _logLevelDot(entry.level),
                      const SizedBox(width: 8),
                      Text(entry.timeString,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: AppColors.textMuted,
                                  fontFamily: 'monospace',
                                  fontSize: 11)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.message,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontFamily: 'monospace', fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _logLevelDot(LogLevel level) {
    Color c;
    switch (level) {
      case LogLevel.error:
        c = AppColors.error;
        break;
      case LogLevel.warning:
        c = AppColors.warning;
        break;
      case LogLevel.debug:
        c = AppColors.textMuted;
        break;
      default:
        c = AppColors.primary;
    }
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
    );
  }
}
