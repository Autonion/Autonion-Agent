import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/di/service_locator.dart';
import '../../core/models/log_entry.dart';
import '../../core/services/logging_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// Full-screen log viewer with filtering and search.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  LogLevel? _filterLevel;
  String _searchQuery = '';
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final log = getIt<LoggingService>();

    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        List<LogEntry> entries = log.entries;

        // Filter by level
        if (_filterLevel != null) {
          entries = entries.where((e) => e.level == _filterLevel).toList();
        }
        // Filter by search
        if (_searchQuery.isNotEmpty) {
          entries = entries
              .where(
                (e) => e.message.toLowerCase().contains(
                  _searchQuery.toLowerCase(),
                ),
              )
              .toList();
        }

        // Auto-scroll to bottom
        if (_autoScroll && entries.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.jumpTo(
                _scrollController.position.maxScrollExtent,
              );
            }
          });
        }

        return Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Logs',
                      style: Theme.of(context).textTheme.displayMedium,
                    ).animate().fadeIn(duration: 400.ms),
                  ),
                  // Clear button
                  IconButton(
                    onPressed: () => log.clearLogs(),
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                    tooltip: 'Clear Logs',
                    color: AppColors.textSecondary,
                  ),
                  // Auto-scroll toggle
                  IconButton(
                    onPressed: () => setState(() => _autoScroll = !_autoScroll),
                    icon: Icon(
                      _autoScroll
                          ? Icons.vertical_align_bottom
                          : Icons.vertical_align_center,
                      size: 20,
                    ),
                    tooltip: _autoScroll ? 'Auto-scroll ON' : 'Auto-scroll OFF',
                    color: _autoScroll
                        ? AppColors.primary
                        : AppColors.textSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Filters & Search ────────────────────
              Row(
                children: [
                  // Search
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: TextField(
                        onChanged: (v) => setState(() => _searchQuery = v),
                        decoration: InputDecoration(
                          hintText: 'Search logs...',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 0,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Level filter chips
                  ...[
                    null,
                    LogLevel.error,
                    LogLevel.warning,
                    LogLevel.info,
                  ].map(
                    (level) => Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: FilterChip(
                        label: Text(
                          level?.name.toUpperCase() ?? 'ALL',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: _filterLevel == level
                                    ? Colors.white
                                    : AppColors.textSecondary,
                              ),
                        ),
                        selected: _filterLevel == level,
                        selectedColor: AppColors.primary,
                        backgroundColor: AppColors.surfaceVariant,
                        side: BorderSide(
                          color: _filterLevel == level
                              ? AppColors.primary
                              : AppColors.border,
                        ),
                        onSelected: (_) => setState(() => _filterLevel = level),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Log Console ─────────────────────────
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: entries.isEmpty
                      ? Center(
                          child: Text(
                            'No logs to display',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: AppColors.textMuted),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 1.5,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _levelIndicator(entry.level),
                                  const SizedBox(width: 8),
                                  Text(
                                    entry.timeString,
                                    style: AppTypography.mono.copyWith(
                                      color: AppColors.textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.surfaceVariant,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      entry.source,
                                      style: AppTypography.mono.copyWith(
                                        color: AppColors.secondary,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      entry.message,
                                      style: AppTypography.mono.copyWith(
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),

              // ── Footer ─────────────────────────────
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${entries.length} entries${_filterLevel != null ? ' (filtered)' : ''}',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _levelIndicator(LogLevel level) {
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
      margin: const EdgeInsets.only(top: 5),
      decoration: BoxDecoration(shape: BoxShape.circle, color: c),
    );
  }
}
