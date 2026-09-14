import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart';
import '../../../core/services/logging_service.dart';
import 'device_info_service.dart';

/// Advertising failure is visible and retried; late registrations are disposed after stop.
class DiscoveryService extends ChangeNotifier {
  final DeviceInfoService _deviceInfoService;
  final Future<Registration> Function(Service) _register;
  final Future<void> Function(Registration) _unregister;
  final Duration retryDelay;
  Registration? _registration;
  LoggingService? _loggingService;
  Timer? _retry;
  Timer? _networkCheck;
  int? _port;
  int _generation = 0;
  int _attempt = 0;
  int _failures = 0;
  bool _disposed = false;
  String? _networkSignature;
  String? lastError;

  DiscoveryService(
    this._deviceInfoService, {
    Future<Registration> Function(Service)? registerService,
    Future<void> Function(Registration)? unregisterService,
    this.retryDelay = const Duration(seconds: 2),
  }) : _register = registerService ?? register,
       _unregister = unregisterService ?? unregister;

  bool get isAdvertising => _registration != null;
  void setLoggingService(LoggingService loggingService) {
    _loggingService = loggingService;
  }

  void _log(String message) {
    _loggingService?.info('mDNS', message);
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<List<String>> _addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return interfaces
        .expand((i) => i.addresses)
        .where((a) => !a.isLoopback)
        .map((a) => a.address)
        .toList()
      ..sort();
  }

  Future<void> startAdvertising(int port) async {
    if (_port == port) return;
    _port = port;
    final epoch = ++_generation;
    _attempt++;
    _retry?.cancel();
    _retry = null;
    _networkCheck?.cancel();
    _networkCheck = null;
    final previous = _registration;
    _registration = null;
    if (previous != null) {
      try {
        await _unregister(previous).timeout(const Duration(seconds: 10));
      } catch (e) {
        _log('Could not replace advertising: $e');
      }
    }
    if (epoch != _generation || _port == null) return;
    await _advertise(epoch);
    if (_port == null || epoch != _generation) return;
    _networkCheck = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        final signature = (await _addresses()).join(',');
        if (epoch != _generation ||
            _registration == null ||
            signature == _networkSignature)
          return;
        await startAdvertisingOnChangedNetwork(port, epoch);
      } catch (e) {
        _log('Network check failed: $e');
      }
    });
  }

  Future<void> startAdvertisingOnChangedNetwork(int port, int epoch) async {
    if (epoch != _generation) return;
    _port = null;
    await startAdvertising(port);
  }

  Future<void> _advertise(int epoch) async {
    final port = _port;
    if (port == null || epoch != _generation || _registration != null) return;
    final attempt = ++_attempt;
    try {
      final addresses = await _addresses();
      if (epoch != _generation || attempt != _attempt) return;
      final txt = _deviceInfoService.toJson().map(
        (key, value) =>
            MapEntry(key, Uint8List.fromList(utf8.encode('$value'))),
      );
      if (addresses.isNotEmpty)
        txt['host'] = Uint8List.fromList(utf8.encode(addresses.first));
      txt['ws_port'] = Uint8List.fromList(utf8.encode('$port'));
      txt['ws_path'] = Uint8List.fromList(utf8.encode('/automation'));
      final registration = _register(
        Service(
          name: _deviceInfoService.deviceName.replaceAll(
            RegExp(r'[^a-zA-Z0-9]'),
            '-',
          ),
          type: '_myautomation._tcp',
          port: port,
          txt: txt,
        ),
      );
      // The native API cannot always cancel an in-flight register; clean up a late result.
      unawaited(
        registration
            .then((value) async {
              if (epoch != _generation || attempt != _attempt)
                await _unregister(value);
            })
            .catchError((Object e) {
              _log('Registration cleanup: $e');
            }),
      );
      final value = await registration.timeout(const Duration(seconds: 10));
      if (epoch != _generation || attempt != _attempt) return;
      _registration = value;
      _networkSignature = addresses.join(',');
      _failures = 0;
      lastError = null;
      _log('Advertising on port $port');
      notifyListeners();
    } catch (e) {
      if (epoch != _generation || attempt != _attempt) return;
      _attempt++; // Makes a timed-out registration's eventual result obsolete.
      lastError = '$e';
      _log('Advertising failed; retrying: $e');
      notifyListeners();
      final delay = Duration(
        milliseconds: (retryDelay.inMilliseconds * (1 << _failures.clamp(0, 4)))
            .clamp(1, 30000),
      );
      _failures++;
      _retry?.cancel();
      _retry = Timer(delay, () {
        unawaited(_advertise(epoch));
      });
    }
  }

  Future<void> stopAdvertising() async {
    _port = null;
    _generation++;
    _attempt++;
    _retry?.cancel();
    _retry = null;
    _networkCheck?.cancel();
    _networkCheck = null;
    final registration = _registration;
    _registration = null;
    lastError = null;
    notifyListeners();
    if (registration != null) {
      try {
        await _unregister(registration).timeout(const Duration(seconds: 10));
      } catch (e) {
        _log('Could not unregister advertising: $e');
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stopAdvertising());
    super.dispose();
  }
}
