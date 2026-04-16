/// Represents an intended action returned by the LLM.
class DesktopAction {
  final String type; // click, type, scroll, hotkey, wait, done
  final int? targetIndex; // The numeric index matching the UIElement ID
  final String? text; // Text to type
  final String? direction; // up/down for scroll
  final List<String>? keys; // Array of keys for hotkey

  const DesktopAction({
    required this.type,
    this.targetIndex,
    this.text,
    this.direction,
    this.keys,
  });

  factory DesktopAction.fromJson(Map<String, dynamic> json) {
    return DesktopAction(
      type: json['type'] as String? ?? 'wait',
      targetIndex: json['targetIndex'] as int?,
      text: json['text'] as String?,
      direction: json['direction'] as String?,
      keys: (json['keys'] as List?)?.cast<String>(),
    );
  }
}
