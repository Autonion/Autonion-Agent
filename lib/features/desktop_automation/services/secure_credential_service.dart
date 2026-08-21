import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/services/logging_service.dart';

/// Manages sensitive credentials for flow nodes using platform-level
/// secure storage (Windows DPAPI, macOS Keychain, Linux libsecret).
///
/// Passwords are stored per-node so that deleting a node also deletes
/// its credential.  The actual credential is **never** persisted in
/// the flow JSON — only a `hasUnlockPassword` boolean flag lives there.
class SecureCredentialService {
  static const _keyPrefix = 'flow_unlock_';
  final LoggingService _log;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  SecureCredentialService({required LoggingService log}) : _log = log;

  /// Save or overwrite the unlock password for a node.
  Future<void> saveUnlockPassword(String nodeId, String password) async {
    await _storage.write(key: '$_keyPrefix$nodeId', value: password);
    _log.info('SecureCredential', 'Saved unlock password for node $nodeId');
  }

  /// Retrieve the unlock password for a node. Returns null if not set.
  Future<String?> getUnlockPassword(String nodeId) async {
    return _storage.read(key: '$_keyPrefix$nodeId');
  }

  /// Delete the unlock password for a node.
  Future<void> deleteUnlockPassword(String nodeId) async {
    await _storage.delete(key: '$_keyPrefix$nodeId');
    _log.info('SecureCredential', 'Deleted unlock password for node $nodeId');
  }

  /// Check whether a password is stored for a node.
  Future<bool> hasUnlockPassword(String nodeId) async {
    final value = await _storage.read(key: '$_keyPrefix$nodeId');
    return value != null && value.isNotEmpty;
  }
}
