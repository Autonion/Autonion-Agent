import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:nsd/nsd.dart';
import '../../../core/services/logging_service.dart';
import 'device_info_service.dart';

/// Handles mDNS service advertising so Android devices can discover us on LAN.
class DiscoveryService {
  final DeviceInfoService _deviceInfoService;
  Registration? _registration;
  LoggingService? _loggingService;

  DiscoveryService(this._deviceInfoService);

  void setLoggingService(LoggingService loggingService) {
    _loggingService = loggingService;
  }

  void _log(String message) {
    _loggingService?.info('mDNS', message);
  }

  Future<String?> _getLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (e) {
      _log('Error fetching LAN IP: $e');
    }
    return null;
  }

  Future<void> startAdvertising(int port) async {
    if (_registration != null) return;

    const String serviceType = '_myautomation._tcp';

    try {
      final txtData = _deviceInfoService.toJson().map(
        (key, value) =>
            MapEntry(key, Uint8List.fromList(utf8.encode(value.toString()))),
      );

      final lanIp = await _getLanIp();
      if (lanIp != null) {
        txtData['host'] = Uint8List.fromList(utf8.encode(lanIp));
        txtData['ws_port'] = Uint8List.fromList(utf8.encode(port.toString()));
        txtData['ws_path'] = Uint8List.fromList(utf8.encode('/automation'));
        _log('Advertising with IP: $lanIp, port: $port');
      } else {
        _log('WARNING: Could not determine LAN IP');
      }

      _registration = await register(
        Service(
          name: _deviceInfoService.deviceName.replaceAll(
            RegExp(r'[^a-zA-Z0-9]'),
            '-',
          ),
          type: serviceType,
          port: port,
          txt: txtData,
        ),
      );
      _log('Advertising started: $serviceType on port $port');
    } catch (e) {
      _log('Error starting advertising: $e');
    }
  }

  Future<void> stopAdvertising() async {
    if (_registration != null) {
      await unregister(_registration!);
      _registration = null;
      _log('Advertising stopped');
    }
  }
}
