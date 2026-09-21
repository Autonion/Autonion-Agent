import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import '../../../core/config/app_config.dart';
import '../../../core/services/logging_service.dart';

enum UpdateStatus { idle, checking, upToDate, available, noRelease, error }

/// Checks public GitHub Releases; installation remains user initiated.
class UpdateService extends ChangeNotifier {
  static const releasesUrl =
      'https://github.com/Autonion/Autonion-Agent/releases';
  static final _apiUri = Uri.parse(
    'https://api.github.com/repos/Autonion/Autonion-Agent/releases/latest',
  );
  static const _checkInterval = Duration(hours: 6);

  UpdateService({
    http.Client? client,
    String currentVersion = AppConfig.appVersion,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _currentVersion = currentVersion,
       _now = now ?? DateTime.now;

  final http.Client _client;
  final String _currentVersion;
  final DateTime Function() _now;
  LoggingService? _log;
  Timer? _timer;
  bool _automaticChecks = false;
  bool _disposed = false;
  int _failures = 0;
  DateTime? _retryNotBefore;
  UpdateStatus _status = UpdateStatus.idle;
  String? _latestVersion;
  String? _releaseUrl;
  String? _releaseNotes;
  String? _dismissedVersion;
  String? _error;
  DateTime? _lastCheckedAt;

  UpdateStatus get status => _status;
  bool get hasUpdate => _latestVersion != null;
  bool get updateAvailable => hasUpdate && _dismissedVersion != _latestVersion;
  String? get latestVersion => _latestVersion;
  String? get releaseUrl => _releaseUrl;
  String? get releaseNotes => _releaseNotes;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  bool get isChecking => _status == UpdateStatus.checking;

  String get statusMessage => switch (_status) {
    UpdateStatus.idle => 'Updates are checked automatically.',
    UpdateStatus.checking => 'Checking for updates…',
    UpdateStatus.upToDate => 'You’re up to date (v$_currentVersion).',
    UpdateStatus.available => 'Version v$_latestVersion is available.',
    UpdateStatus.noRelease => 'No stable release is available on GitHub yet.',
    UpdateStatus.error => _error!,
  };

  void setLoggingService(LoggingService service) => _log = service;

  /// Check at startup and periodically, including while running in the tray.
  void startAutomaticChecks() {
    if (_automaticChecks || _disposed) return;
    _automaticChecks = true;
    unawaited(checkForUpdate(manual: false));
  }

  /// Hide this version's banner for this session, but keep it in Settings.
  void dismiss() {
    _dismissedVersion = _latestVersion;
    notifyListeners();
  }

  Future<void> checkForUpdate({bool manual = true}) async {
    if (_disposed || isChecking) return;
    if (_retryNotBefore != null && _now().isBefore(_retryNotBefore!)) {
      _scheduleNextCheck();
      return;
    }
    _timer?.cancel();
    _retryNotBefore = null;
    _status = UpdateStatus.checking;
    _error = null;
    notifyListeners();

    try {
      _log?.info('Update', 'Checking for updates...');
      final response = await _client
          .get(
            _apiUri,
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Autonion-Agent/$_currentVersion',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (_disposed) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final remoteText = (data['tag_name'] as String).trim().replaceFirst(
          RegExp(r'^[vV]'),
          '',
        );
        final remote = _version(remoteText);
        final current = _version(_currentVersion);

        if (data['draft'] == true ||
            data['prerelease'] == true ||
            remote.isPreRelease) {
          _clearRelease();
          _status = UpdateStatus.noRelease;
        } else if (remote > current) {
          final uri = Uri.tryParse(data['html_url'] as String? ?? '');
          if (uri == null ||
              uri.scheme != 'https' ||
              uri.host != 'github.com' ||
              uri.userInfo.isNotEmpty ||
              uri.port != 443 ||
              !uri.path.startsWith('/Autonion/Autonion-Agent/releases/')) {
            throw const FormatException('Invalid GitHub release URL');
          }
          final notes = data['body'] as String? ?? '';
          _latestVersion = remoteText;
          _releaseUrl = uri.toString();
          _releaseNotes = notes;
          if (manual) _dismissedVersion = null;
          _status = UpdateStatus.available;
        } else {
          _clearRelease();
          _status = UpdateStatus.upToDate;
        }
        _failures = 0;
        _log?.info('Update', statusMessage);
      } else if (response.statusCode == 404) {
        _clearRelease();
        _status = UpdateStatus.noRelease;
        _failures = 0;
        _log?.info('Update', statusMessage);
      } else if (response.statusCode == 403 || response.statusCode == 429) {
        _recordFailure(
          'GitHub temporarily limited update checks. Try again later.',
        );
        final now = _now();
        var retryAt = now.add(_retryDelay);
        final seconds = int.tryParse(response.headers['retry-after'] ?? '');
        final reset = int.tryParse(response.headers['x-ratelimit-reset'] ?? '');
        for (final candidate in [
          if (seconds != null) now.add(Duration(seconds: seconds)),
          if (reset != null && response.headers['x-ratelimit-remaining'] == '0')
            DateTime.fromMillisecondsSinceEpoch(reset * 1000),
        ]) {
          if (candidate.isAfter(retryAt)) retryAt = candidate;
        }
        _retryNotBefore = retryAt;
      } else {
        _recordFailure(
          'Could not check for updates (GitHub ${response.statusCode}). Try again later.',
        );
      }
    } on TimeoutException {
      if (!_disposed) {
        _recordFailure(
          'The update check timed out. Check your internet connection and try again.',
        );
      }
    } on http.ClientException {
      if (!_disposed) {
        _recordFailure(
          'Could not reach GitHub. Check your internet connection and try again.',
        );
      }
    } catch (error) {
      if (!_disposed) {
        _recordFailure(
          'Could not read the GitHub release information. Try again later.',
        );
        _log?.warn('Update', 'Invalid release response: $error');
      }
    } finally {
      if (!_disposed) {
        _lastCheckedAt = _now();
        _scheduleNextCheck();
        notifyListeners();
      }
    }
  }

  // Validate the full version, then ignore build metadata for SemVer precedence.
  static Version _version(String text) {
    final parsed = Version.parse(text);
    return Version(
      parsed.major,
      parsed.minor,
      parsed.patch,
      pre: parsed.isPreRelease ? parsed.preRelease.join('.') : null,
    );
  }

  void _clearRelease() {
    _latestVersion = null;
    _releaseUrl = null;
    _releaseNotes = null;
  }

  void _recordFailure(String message) {
    _status = UpdateStatus.error;
    _error = message;
    if (_failures < 5) _failures++;
    _log?.warn('Update', message);
  }

  Duration get _retryDelay =>
      Duration(minutes: _failures >= 5 ? 60 : 5 * (1 << (_failures - 1)));

  void _scheduleNextCheck() {
    if (!_automaticChecks || _disposed) return;
    _timer?.cancel();
    final delay = _retryNotBefore != null
        ? _retryNotBefore!.difference(_now())
        : _status == UpdateStatus.error
        ? _retryDelay
        : _checkInterval;
    _timer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(checkForUpdate(manual: false)),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _client.close();
    super.dispose();
  }
}
