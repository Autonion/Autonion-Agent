import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/di/service_locator.dart';
import '../../features/desktop_automation/services/flow_execution_service.dart';
import '../../features/desktop_automation/services/python_bridge_service.dart';
import '../theme/app_colors.dart';

/// Switches the Autonion window between its normal full-size app shell and
/// a compact always-on-top overlay while a flow is executing.
///
/// The overlay is a small bar (260×80) in the top-right corner with a stop
/// button. It stays above other windows and hides the title bar while compact
/// so the overlay is close to the requested size.
///
/// Transitions are serialized via a [Completer] so that a rapid
/// enter→restore sequence (e.g. a flow that completes in <100ms) cannot
/// corrupt window state. A minimum display time of [_minOverlayDuration]
/// ensures the overlay is always visible long enough for the user to see
/// and interact with the stop button.
class FlowRunOverlay extends StatefulWidget {
  final Widget child;

  const FlowRunOverlay({super.key, required this.child});

  @override
  State<FlowRunOverlay> createState() => _FlowRunOverlayState();
}

class _FlowRunOverlayState extends State<FlowRunOverlay> {
  // Compact bar — as small as Windows allows.
  // NOTE: Windows enforces a minimum size that includes frame decorations.
  // Keeping this small ensures the overlay is as compact as possible.
  static const _overlaySize = Size(240, 56);
  static const _normalMinSize = Size(800, 550);

  /// Minimum time the overlay stays visible before auto-restoring.
  /// Kept short so fast-failing flows don't leave the app stuck.
  static const _minOverlayDuration = Duration(milliseconds: 800);

  late final FlowExecutionService _execution;
  late final PythonBridgeService _bridge;
  Rect? _savedBounds;
  bool _savedMaximized = false;
  bool _overlayMode = false;
  int? _savedForegroundHwnd;

  /// When overlay mode was entered. Used to enforce [_minOverlayDuration].
  DateTime? _overlayEnteredAt;

  /// Serializes enter/restore transitions so they never overlap.
  /// When non-null, a transition is in progress — callers must await
  /// the future before starting a new one.
  Completer<void>? _transitionLock;

  @override
  void initState() {
    super.initState();
    _execution = getIt<FlowExecutionService>();
    _bridge = getIt<PythonBridgeService>();
    _execution.addListener(_onExecutionChanged);
    unawaited(_syncWindowMode());
  }

  @override
  void dispose() {
    _execution.removeListener(_onExecutionChanged);
    if (_overlayMode) unawaited(_restoreWindow());
    super.dispose();
  }

  /// Listener callback — schedules a sync but never awaits it inline
  /// (ChangeNotifier listeners must be synchronous).
  void _onExecutionChanged() {
    unawaited(_syncWindowMode());
  }

  /// Determines whether we need to enter or leave overlay mode and
  /// serializes the transition through [_transitionLock].
  Future<void> _syncWindowMode() async {
    // Wait for any in-progress transition to finish first
    if (_transitionLock != null) {
      await _transitionLock!.future;
    }

    if (!mounted) return;

    if (_execution.isRunning && !_overlayMode) {
      await _enterOverlayMode();
    } else if (!_execution.isRunning && _overlayMode) {
      await _restoreWindow();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _enterOverlayMode() async {
    final lock = Completer<void>();
    _transitionLock = lock;

    try {
      await _captureForegroundHwnd();

      _savedMaximized = await windowManager.isMaximized();
      _savedBounds = await windowManager.getBounds();

      if (_savedMaximized) {
        await windowManager.unmaximize();
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }

      // 1. Hide native chrome so the compact overlay does not look like a full app window.
      await windowManager.setTitle('Autonion Agent');
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 2. Drop the minimum size FIRST so setSize can actually shrink.
      await windowManager.setMinimumSize(_overlaySize);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 3. Shrink the window.
      await windowManager.setSize(_overlaySize);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 4. Configure overlay behavior.
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(false);

      // 5. Position top-right, nudged 16px from edges
      await windowManager.setAlignment(Alignment.topRight);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final pos = await windowManager.getPosition();
      await windowManager.setPosition(Offset(pos.dx - 16, pos.dy + 16));

      // 6. Show without taking focus
      await windowManager.show(inactive: true);
      _overlayMode = true;
      _overlayEnteredAt = DateTime.now();

      // 7. Return focus to the target app
      await _restoreForegroundWindow();
    } finally {
      lock.complete();
      _transitionLock = null;
      if (mounted) {
        setState(() {});
        // Re-check in case the flow finished during our transition
        unawaited(Future<void>.delayed(Duration.zero, _syncWindowMode));
      }
    }
  }

  Future<void> _captureForegroundHwnd() async {
    try {
      final result = await _bridge.sendCommand('get_foreground_hwnd', {});
      if (result is Map) {
        final rawHwnd = result['hwnd'];
        final hwnd = rawHwnd is int
            ? rawHwnd
            : rawHwnd is num
            ? rawHwnd.toInt()
            : null;
        final ownHwnd = await windowManager.getId();
        _savedForegroundHwnd = hwnd != null && hwnd != ownHwnd ? hwnd : null;
      }
    } catch (_) {
      _savedForegroundHwnd = null;
    }
  }

  Future<void> _restoreForegroundWindow() async {
    final hwnd = _savedForegroundHwnd;
    if (hwnd == null || hwnd == 0) return;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await _bridge.sendCommand('focus_window', {'hwnd': hwnd});
    } catch (_) {}
  }

  Future<void> _restoreWindow() async {
    // Enforce minimum overlay display time so the user can see it
    // and the enter transition has fully settled.
    if (_overlayEnteredAt != null) {
      final elapsed = DateTime.now().difference(_overlayEnteredAt!);
      if (elapsed < _minOverlayDuration) {
        final remaining = _minOverlayDuration - elapsed;
        await Future<void>.delayed(remaining);
      }
    }

    // If we're no longer in overlay mode (e.g. dispose already restored),
    // or another transition snuck in, bail out.
    if (!_overlayMode) return;

    final lock = Completer<void>();
    _transitionLock = lock;

    try {
      // CRITICAL: Reset alwaysOnTop FIRST so the overlay stops blocking.
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setResizable(true);
      await windowManager.setTitle('Autonion Agent');
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);

      // Restore minimum size BEFORE restoring bounds
      await windowManager.setMinimumSize(_normalMinSize);

      final bounds = _savedBounds;
      if (bounds != null) {
        await windowManager.setBounds(bounds);
      } else {
        await windowManager.setSize(const Size(1100, 750));
        await windowManager.center();
      }
      if (_savedMaximized) {
        await windowManager.maximize();
      }

      // Always show + keep in taskbar so the user can access the app
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();

      _overlayMode = false;
      _savedBounds = null;
      _overlayEnteredAt = null;
    } catch (_) {
      // Safety net: fully reset window state so the user isn't stuck.
      try {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setResizable(true);
        await windowManager.setSkipTaskbar(false);
        await windowManager.setTitle('Autonion Agent');
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.setMinimumSize(_normalMinSize);
        await windowManager.setSize(const Size(1100, 750));
        await windowManager.show();
        await windowManager.center();
      } catch (_) {}

      _overlayMode = false;
      _savedBounds = null;
      _overlayEnteredAt = null;
    } finally {
      lock.complete();
      _transitionLock = null;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _execution,
      builder: (context, _) {
        if (_execution.isRunning || _overlayMode) {
          return _FlowOverlayBar();
        }
        return widget.child;
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  COMPACT OVERLAY BAR
// ═══════════════════════════════════════════════════════════════════

class _FlowOverlayBar extends StatelessWidget {
  // Non-const so AnimatedBuilder rebuilds on every notification.
  _FlowOverlayBar(); // ignore: prefer_const_constructors_in_immutables

  @override
  Widget build(BuildContext context) {
    final execution = getIt<FlowExecutionService>();

    return AnimatedBuilder(
      animation: execution,
      builder: (context, _) {
        final progress = execution.currentProgress;
        final isStopping = execution.stopRequested;
        final stepLabel = progress == null || progress.totalSteps == 0
            ? 'Running'
            : '${progress.currentStep}/${progress.totalSteps}';

        return Scaffold(
          backgroundColor: AppColors.background,
          body: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                // Status icon
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: AppColors.warning,
                    size: 16,
                  ),
                ),
                const SizedBox(width: 6),
                // Step counter
                Expanded(
                  child: Text(
                    stepLabel,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                // Stop button
                SizedBox(
                  height: 26,
                  child: FilledButton.icon(
                    onPressed: isStopping ? null : execution.stopFlow,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.error,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.error.withValues(
                        alpha: 0.35,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    icon: Icon(
                      isStopping
                          ? Icons.hourglass_top_rounded
                          : Icons.stop_rounded,
                      size: 14,
                    ),
                    label: Text(
                      isStopping ? '...' : 'Stop',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
