import 'dart:io';
import 'package:flutter/foundation.dart';
import 'logging_service.dart';

/// Represents a browser that can be launched
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

/// Service to detect, select, and launch browsers on Windows.
class BrowserLauncherService extends ChangeNotifier {
  LoggingService? _loggingService;

  // Common Windows browser paths
  static final List<Map<String, String>> _browserPaths = [
    {
      'name': 'Google Chrome',
      'path': r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    },
    {
      'name': 'Google Chrome (x86)',
      'path': r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    },
    {
      'name': 'Microsoft Edge',
      'path': r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    },
    {
      'name': 'Microsoft Edge',
      'path': r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    },
    {
      'name': 'Brave',
      'path': r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
    },
    {
      'name': 'Brave (x86)',
      'path': r'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe',
    },
  ];

  List<BrowserInfo> _detectedBrowsers = [];
  BrowserInfo? _selectedBrowser;

  List<BrowserInfo> get detectedBrowsers => _detectedBrowsers;
  BrowserInfo? get selectedBrowser => _selectedBrowser;

  void setLoggingService(LoggingService loggingService) {
    _loggingService = loggingService;
  }

  void _log(String message) {
    final logMsg = '[Browser] $message';
    print(logMsg);
    _loggingService?.log(logMsg);
  }

  /// Detect which browsers are installed on this system.
  Future<void> detectBrowsers() async {
    final detected = <String, BrowserInfo>{}; // name -> first found path

    for (final entry in _browserPaths) {
      final name = entry['name']!;
      final path = entry['path']!;

      // Skip if we already found this browser (e.g. Chrome found in Program Files)
      if (detected.containsKey(name)) continue;

      if (await File(path).exists()) {
        detected[name] = BrowserInfo(
          name: name,
          executablePath: path,
          isInstalled: true,
        );
        _log('Detected: $name at $path');
      }
    }

    _detectedBrowsers = detected.values.toList();

    // Auto-select the first detected browser if none selected
    if (_selectedBrowser == null && _detectedBrowsers.isNotEmpty) {
      _selectedBrowser = _detectedBrowsers.first;
      _log('Auto-selected: ${_selectedBrowser!.name}');
    }

    notifyListeners();
  }

  /// Set the selected browser by name.
  void selectBrowser(String name) {
    final browser = _detectedBrowsers.firstWhere(
      (b) => b.name == name,
      orElse: () => _detectedBrowsers.first,
    );
    _selectedBrowser = browser;
    _log('Selected browser: ${browser.name}');
    notifyListeners();
  }

  /// Launch the selected browser. Returns true if launched successfully.
  Future<bool> launchBrowser() async {
    if (_selectedBrowser == null) {
      _log('No browser selected, cannot launch');
      return false;
    }

    final browser = _selectedBrowser!;
    _log('Launching ${browser.name}...');

    try {
      await Process.start(
        browser.executablePath,
        [], // No args — just open the browser, extension auto-connects
        mode: ProcessStartMode.detached,
      );
      _log('${browser.name} launched successfully');
      return true;
    } catch (e) {
      _log('Failed to launch ${browser.name}: $e');
      return false;
    }
  }
}
