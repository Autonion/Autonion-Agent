/// The type of client connected over WebSocket.
enum ClientType { android, extension, unknown }

/// Represents a connected client device.
class ConnectedDevice {
  final String id;
  final ClientType type;
  final String? name;
  final String? platform;
  final DateTime connectedAt;

  const ConnectedDevice({
    required this.id,
    required this.type,
    this.name,
    this.platform,
    required this.connectedAt,
  });

  String get displayName => name ?? 'Unknown Device';

  String get typeLabel {
    switch (type) {
      case ClientType.android:
        return 'Android';
      case ClientType.extension:
        return 'Browser Extension';
      case ClientType.unknown:
        return 'Unknown';
    }
  }
}
