import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../core/services/logging_service.dart';

/// Represents a browser that can be launched.
class BrowserInfo {
  final String name;
  final String executablePath;
  final bool isInstalled;

  const BrowserInfo({
    required this.name,
    required this.executablePath,
    required this.isInstalled,
  });
}

/// Detects, selects, and launches browsers on the host OS.
class BrowserLauncherService extends ChangeNotifier {
  LoggingService? _loggingService;

  static final List<Map<String, String>> _browserPaths = [
    {'name': 'Google Chrome', 'path': r'C:\Program Files\Google\Chrome\Application\chrome.exe'},
    {'name': 'Google Chrome (x86)', 'path': r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'},
    {'name': 'Microsoft Edge', 'path': r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'},
    {'name': 'Microsoft Edge', 'path': r'C:\Program Files\Microsoft\Edge\Application\msedge.exe'},
    {'name': 'Brave', 'path': r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'},
    {'name': 'Brave (x86)', 'path': r'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe'},
  ];

  List<BrowserInfo> _detectedBrowsers = [];
  BrowserInfo? _selectedBrowser;

  List<BrowserInfo> get detectedBrowsers => _detectedBrowsers;
  BrowserInfo? get selectedBrowser => _selectedBrowser;

  void setLoggingService(LoggingService loggingService) {
    _loggingService = loggingService;
  }

  void _log(String message) {
    _loggingService?.info('Browser', message);
  }

  Future<void> detectBrowsers() async {
    final detected = <String, BrowserInfo>{};

    for (final entry in _browserPaths) {
      final name = entry['name']!;
      final path = entry['path']!;
      if (detected.containsKey(name)) continue;

      if (await File(path).exists()) {
        detected[name] = BrowserInfo(
          name: name,
          executablePath: path,
          isInstalled: true,
        );
        _log('Detected: $name');
      }
    }

    _detectedBrowsers = detected.values.toList();

    if (_selectedBrowser == null && _detectedBrowsers.isNotEmpty) {
      _selectedBrowser = _detectedBrowsers.first;
      _log('Auto-selected: ${_selectedBrowser!.name}');
    }

    notifyListeners();
  }

  void selectBrowser(String name) {
    final browser = _detectedBrowsers.firstWhere(
      (b) => b.name == name,
      orElse: () => _detectedBrowsers.first,
    );
    _selectedBrowser = browser;
    _log('Selected: ${browser.name}');
    notifyListeners();
  }

  Future<bool> launchBrowser() async {
    if (_selectedBrowser == null) {
      _log('No browser selected');
      return false;
    }
    final browser = _selectedBrowser!;
    _log('Launching ${browser.name}...');
    try {
      await Process.start(browser.executablePath, ['--profile-directory=Default'],
          mode: ProcessStartMode.detached);
      _log('${browser.name} launched');
      return true;
    } catch (e) {
      _log('Failed to launch ${browser.name}: $e');
      return false;
    }
  }
}
