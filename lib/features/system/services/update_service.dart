import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../../core/config/app_config.dart';
import '../../../core/services/logging_service.dart';

/// Checks GitHub Releases for newer versions of Autonion Agent.
class UpdateService extends ChangeNotifier {
  static const String _owner = 'Autonion';
  static const String _repo = 'Autonion-Agent';
  static const String _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  LoggingService? _log;

  bool _updateAvailable = false;
  String? _latestVersion;
  String? _releaseUrl;
  String? _releaseNotes;
  bool _dismissed = false;
  bool _checking = false;

  bool get updateAvailable => _updateAvailable && !_dismissed;
  String? get latestVersion => _latestVersion;
  String? get releaseUrl => _releaseUrl;
  String? get releaseNotes => _releaseNotes;
  bool get isChecking => _checking;

  void setLoggingService(LoggingService service) => _log = service;

  /// Dismiss the update banner for this session.
  void dismiss() {
    _dismissed = true;
    notifyListeners();
  }

  /// Check GitHub for the latest release.
  Future<void> checkForUpdate() async {
    if (_checking) return;
    _checking = true;
    notifyListeners();

    try {
      _log?.info('Update', 'Checking for updates...');

      final response = await http
          .get(
            Uri.parse(_apiUrl),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tagName = data['tag_name'] as String? ?? '';
        final htmlUrl = data['html_url'] as String? ?? '';
        final body = data['body'] as String? ?? '';

        // Strip leading 'v' if present (e.g. "v2.1.0" → "2.1.0")
        final remoteVersion =
            tagName.startsWith('v') ? tagName.substring(1) : tagName;

        final currentVersion = AppConfig.appVersion;

        if (_isNewer(remoteVersion, currentVersion)) {
          _updateAvailable = true;
          _latestVersion = remoteVersion;
          _releaseUrl = htmlUrl;
          _releaseNotes = body;
          _dismissed = false;
          _log?.info(
            'Update',
            'New version available: $remoteVersion (current: $currentVersion)',
          );
        } else {
          _updateAvailable = false;
          _log?.info('Update', 'App is up to date ($currentVersion)');
        }
      } else if (response.statusCode == 404) {
        _log?.info('Update', 'No releases found');
      } else {
        _log?.warn(
          'Update',
          'GitHub API returned ${response.statusCode}',
        );
      }
    } catch (e) {
      // Don't crash the app for a failed update check
      _log?.warn('Update', 'Update check failed: $e');
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// Compare semver strings. Returns true if [remote] > [current].
  bool _isNewer(String remote, String current) {
    try {
      final remoteParts = remote.split('.').map(int.parse).toList();
      final currentParts = current.split('.').map(int.parse).toList();

      // Pad to equal length
      while (remoteParts.length < 3) {
        remoteParts.add(0);
      }
      while (currentParts.length < 3) {
        currentParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (remoteParts[i] > currentParts[i]) return true;
        if (remoteParts[i] < currentParts[i]) return false;
      }
      return false; // equal
    } catch (_) {
      return false; // can't parse, assume no update
    }
  }
}
