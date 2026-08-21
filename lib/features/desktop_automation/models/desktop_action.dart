/// Represents an intended action returned by the LLM.
class DesktopAction {
  final String type; // click, type, scroll, hotkey, drag, wait, done
  final int? targetIndex; // The numeric index matching the UIElement ID
  final String? targetStableId; // Stable UIA-derived ID when available
  final int? endTargetIndex; // Optional destination element for drag actions
  final String?
  endTargetStableId; // Optional stable destination for drag actions
  final double? x; // Optional absolute screen x coordinate
  final double? y; // Optional absolute screen y coordinate
  final double? endX; // Optional absolute drag destination x coordinate
  final double? endY; // Optional absolute drag destination y coordinate
  final List<Map<String, double>>? path; // Optional drag path points
  final String? text; // Text to type
  final String? appName; // Application display name for launch actions
  final String? appPath; // Shortcut/executable path for launch actions
  final String? direction; // up/down for scroll
  final int? amount; // Scroll amount or wheel clicks
  final List<String>? keys; // Array of keys for hotkey
  final int? durationMs; // Duration for drag/move-like actions
  final String? button; // left/right/middle
  final String? coordinateSpace; // screen or screenshot
  final bool replace; // If true, select-all before typing to replace existing text

  const DesktopAction({
    required this.type,
    this.targetIndex,
    this.targetStableId,
    this.endTargetIndex,
    this.endTargetStableId,
    this.x,
    this.y,
    this.endX,
    this.endY,
    this.path,
    this.text,
    this.appName,
    this.appPath,
    this.direction,
    this.amount,
    this.keys,
    this.durationMs,
    this.button,
    this.coordinateSpace,
    this.replace = false,
  });

  factory DesktopAction.fromJson(Map<String, dynamic> json) {
    return DesktopAction(
      type: json['type'] as String? ?? 'wait',
      targetIndex: json['targetIndex'] as int?,
      targetStableId:
          (json['targetStableId'] as String?) ?? (json['stableId'] as String?),
      endTargetIndex: json['endTargetIndex'] as int?,
      endTargetStableId: json['endTargetStableId'] as String?,
      x: _asDouble(json['x']),
      y: _asDouble(json['y']),
      endX: _asDouble(json['endX']),
      endY: _asDouble(json['endY']),
      path: _asPath(json['path']),
      text: json['text'] as String?,
      appName: json['appName'] as String?,
      appPath: json['appPath'] as String?,
      direction: json['direction'] as String?,
      amount: json['amount'] as int?,
      keys: (json['keys'] as List?)?.cast<String>(),
      durationMs: json['durationMs'] as int?,
      button: json['button'] as String?,
      coordinateSpace: json['coordinateSpace'] as String?,
      replace: json['replace'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'targetIndex': targetIndex,
    'targetStableId': targetStableId,
    'endTargetIndex': endTargetIndex,
    'endTargetStableId': endTargetStableId,
    'x': x,
    'y': y,
    'endX': endX,
    'endY': endY,
    'path': path,
    'text': text,
    'appName': appName,
    'appPath': appPath,
    'direction': direction,
    'amount': amount,
    'keys': keys,
    'durationMs': durationMs,
    'button': button,
    'coordinateSpace': coordinateSpace,
    'replace': replace,
  };

  static double? _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return null;
  }

  static List<Map<String, double>>? _asPath(dynamic value) {
    if (value is! List) return null;

    final points = <Map<String, double>>[];
    for (final point in value) {
      double? x;
      double? y;
      if (point is Map) {
        x = _asDouble(point['x']);
        y = _asDouble(point['y']);
      } else if (point is List && point.length >= 2) {
        x = _asDouble(point[0]);
        y = _asDouble(point[1]);
      }
      if (x == null || y == null) return null;
      points.add({'x': x, 'y': y});
    }

    return points.isEmpty ? null : points;
  }
}
