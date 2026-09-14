import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/logging_service.dart';
import '../models/paired_device.dart';

/// Manages persisted trusted companion devices and pairing settings.
class PairedDeviceService extends ChangeNotifier {
  static const String _storageKey = 'autonion_paired_devices_v1';
  static const String _allowPairingsPrefKey = 'autonion_allow_new_pairings';

  final LoggingService _log;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  List<PairedDevice> _pairedDevices = [];
  bool _allowNewPairings = true;
  bool _isInitialized = false;

  final Future<bool> Function(List<PairedDevice>)? syncTrust;
  Future<void> _trustQueue = Future.value();
  Future<void> _saveQueue = Future.value();
  Timer? _trustRetry;
  bool _trustDirty = true;
  int _trustRevision = 0;
  bool _disposed = false;

  PairedDeviceService({required LoggingService log, this.syncTrust})
    : _log = log;

  Future<void> _syncTrust() {
    if (syncTrust == null) return Future.value();
    _trustDirty = true;
    _trustRevision++;
    return _trustQueue = _trustQueue.then((_) async {
      if (!_trustDirty || _disposed) return;
      final revision = _trustRevision;
      try {
        final saved = await syncTrust!(List.of(_pairedDevices));
        _trustDirty = !saved || revision != _trustRevision;
      } catch (e) {
        _trustDirty = true;
        _log.warn('Auth', 'Unlock helper trust synchronization failed: $e');
      }
      _trustRetry?.cancel();
      if (_trustDirty && !_disposed)
        _trustRetry = Timer(const Duration(seconds: 30), () {
          unawaited(_syncTrust());
        });
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _trustRetry?.cancel();
    super.dispose();
  }

  bool get allowNewPairings => _allowNewPairings;
  List<PairedDevice> get pairedDevices => List.unmodifiable(_pairedDevices);
  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _allowNewPairings = prefs.getBool(_allowPairingsPrefKey) ?? true;

      final rawJson = await _storage.read(key: _storageKey);
      if (rawJson != null && rawJson.isNotEmpty) {
        final List<dynamic> list = jsonDecode(rawJson);
        _pairedDevices = list
            .map((item) => PairedDevice.fromMap(item as Map<String, dynamic>))
            .toList();
        _log.info('Auth', 'Loaded ${_pairedDevices.length} paired device(s)');
      }
    } catch (e) {
      _log.error('Auth', 'Error initializing PairedDeviceService: $e');
      _pairedDevices = [];
    }
    _isInitialized = true;
    unawaited(_syncTrust());
    notifyListeners();
  }

  Future<void> _save() {
    final snapshot = jsonEncode(_pairedDevices.map((d) => d.toMap()).toList());
    // A delayed last-seen write must not restore a subsequently revoked pairing.
    return _saveQueue = _saveQueue.then((_) async {
      try {
        await _storage.write(key: _storageKey, value: snapshot);
      } catch (e) {
        _log.error('Auth', 'Failed to save paired devices: $e');
      }
    });
  }

  Future<bool> setAllowNewPairings(bool value) async {
    _allowNewPairings = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_allowPairingsPrefKey, value);
    } catch (e) {
      _log.error('Auth', 'Failed to persist allowNewPairings setting: $e');
    }
    notifyListeners();
    return _allowNewPairings;
  }

  Future<List<PairedDevice>> getPairedDevices() async {
    if (!_isInitialized) await init();
    return List.unmodifiable(_pairedDevices);
  }

  PairedDevice? getDeviceById(String deviceId) {
    try {
      return _pairedDevices.firstWhere((d) => d.id == deviceId);
    } catch (_) {
      return null;
    }
  }

  Future<bool> isDevicePaired(String deviceId, String secret) async {
    if (!_isInitialized) await init();
    if (deviceId.isEmpty || secret.isEmpty) return false;

    final device = getDeviceById(deviceId);
    if (device == null) return false;

    // Direct constant-time string comparison for secret matching
    return _secureCompare(device.secret, secret);
  }

  Future<void> pairDevice(PairedDevice device) async {
    if (!_isInitialized) await init();

    final existingIndex = _pairedDevices.indexWhere((d) => d.id == device.id);
    if (existingIndex >= 0) {
      _pairedDevices[existingIndex] = device;
      _log.info(
        'Auth',
        'Updated pairing for device ${device.name} (${device.id})',
      );
    } else {
      // Display names are not identities: multiple phones can share a model name.
      _pairedDevices.add(device);
      _log.info('Auth', 'Paired new device: ${device.name} (${device.id})');
    }

    await _save();
    unawaited(_syncTrust());
    notifyListeners();
  }

  Future<void> revokeDevice(String deviceId) async {
    if (!_isInitialized) await init();

    final countBefore = _pairedDevices.length;
    _pairedDevices.removeWhere((d) => d.id == deviceId);
    if (_pairedDevices.length < countBefore) {
      _log.info('Auth', 'Revoked pairing for device $deviceId');
      await _save();
      await _syncTrust();
      notifyListeners();
    }
  }

  Future<void> updateLastSeen(String deviceId, String? ip) async {
    if (!_isInitialized) await init();

    final index = _pairedDevices.indexWhere((d) => d.id == deviceId);
    if (index >= 0) {
      final existing = _pairedDevices[index];
      _pairedDevices[index] = existing.copyWith(
        lastSeen: DateTime.now(),
        lastIp: ip ?? existing.lastIp,
      );
      await _save();
      notifyListeners();
    }
  }

  bool _secureCompare(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }
}
