import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceInfoService {
  static const String _deviceIdKey = 'device_id';
  final DeviceInfoPlugin _deviceInfoPlugin = DeviceInfoPlugin();
  
  String? _deviceId;
  String? _deviceName;
  String? _platform;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString(_deviceIdKey);
    
    if (_deviceId == null) {
      _deviceId = const Uuid().v4();
      await prefs.setString(_deviceIdKey, _deviceId!);
    }

    if (Platform.isAndroid) {
      _platform = 'android';
      final androidInfo = await _deviceInfoPlugin.androidInfo;
      _deviceName = androidInfo.model;
    } else if (Platform.isIOS) {
      _platform = 'ios';
      final iosInfo = await _deviceInfoPlugin.iosInfo;
      _deviceName = iosInfo.name;
    } else if (Platform.isLinux) {
      _platform = 'linux';
      final linuxInfo = await _deviceInfoPlugin.linuxInfo;
      _deviceName = linuxInfo.name;
    } else if (Platform.isMacOS) {
      _platform = 'macos';
      final macOsInfo = await _deviceInfoPlugin.macOsInfo;
      _deviceName = macOsInfo.computerName;
    } else if (Platform.isWindows) {
      _platform = 'windows';
      final windowsInfo = await _deviceInfoPlugin.windowsInfo;
      _deviceName = windowsInfo.computerName;
    } else {
      _platform = 'unknown';
      _deviceName = 'Unknown Device';
    }
  }

  String get deviceId => _deviceId ?? 'unknown-id';
  String get deviceName => _deviceName ?? 'Unknown Device';
  String get platform => _platform ?? 'unknown';

  Map<String, dynamic> toJson() {
    return {
      'device_id': deviceId,
      'device_name': deviceName,
      'platform': platform,
      // Add capabilities if needed
      'capabilities': ['open_url', 'clipboard'], // Example capabilities
    };
  }
}
