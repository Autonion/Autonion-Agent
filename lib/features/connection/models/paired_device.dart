import 'dart:convert';

/// Represents a trusted mobile companion device paired with this desktop agent.
class PairedDevice {
  final String id;
  final String name;
  final String secret;
  final DateTime pairedAt;
  final DateTime lastSeen;
  final String? lastIp;

  const PairedDevice({
    required this.id,
    required this.name,
    required this.secret,
    required this.pairedAt,
    required this.lastSeen,
    this.lastIp,
  });

  PairedDevice copyWith({
    String? id,
    String? name,
    String? secret,
    DateTime? pairedAt,
    DateTime? lastSeen,
    String? lastIp,
  }) {
    return PairedDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      secret: secret ?? this.secret,
      pairedAt: pairedAt ?? this.pairedAt,
      lastSeen: lastSeen ?? this.lastSeen,
      lastIp: lastIp ?? this.lastIp,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'secret': secret,
      'paired_at': pairedAt.toIso8601String(),
      'last_seen': lastSeen.toIso8601String(),
      'last_ip': lastIp,
    };
  }

  factory PairedDevice.fromMap(Map<String, dynamic> map) {
    return PairedDevice(
      id: map['id'] as String,
      name: map['name'] as String? ?? 'Companion Device',
      secret: map['secret'] as String? ?? '',
      pairedAt: map['paired_at'] != null
          ? DateTime.tryParse(map['paired_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      lastSeen: map['last_seen'] != null
          ? DateTime.tryParse(map['last_seen'] as String) ?? DateTime.now()
          : DateTime.now(),
      lastIp: map['last_ip'] as String?,
    );
  }

  String toJson() => jsonEncode(toMap());

  factory PairedDevice.fromJson(String source) =>
      PairedDevice.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
