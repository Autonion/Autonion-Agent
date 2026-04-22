/// Defines how an element is located and acted upon on the screen.
class UIElement {
  final String id; // Unique ID (e.g. "node_12")
  final String name; // Text or label
  final String role; // Button, TextBox, etc.
  final String type; // The specific UIA ControlType
  final Map<String, dynamic> boundingBox; // {x, y, width, height}
  final bool isClickable;
  final bool isKeyboardFocusable;
  final String? value;

  const UIElement({
    required this.id,
    required this.name,
    required this.role,
    required this.type,
    required this.boundingBox,
    this.isClickable = false,
    this.isKeyboardFocusable = false,
    this.value,
  });

  factory UIElement.fromJson(Map<String, dynamic> json) {
    return UIElement(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? 'unknown',
      type: json['type'] as String? ?? '',
      boundingBox: json['boundingBox'] as Map<String, dynamic>? ?? {},
      isClickable: json['isClickable'] as bool? ?? false,
      isKeyboardFocusable: json['isKeyboardFocusable'] as bool? ?? false,
      value: json['value'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'role': role,
    'type': type,
    'boundingBox': boundingBox,
    'isClickable': isClickable,
    'isKeyboardFocusable': isKeyboardFocusable,
    'value': value,
  };

  /// Used for prompting the LLM simply
  Map<String, dynamic> toPromptJson() {
    final map = <String, dynamic>{
      'index': int.parse(id.replaceAll(RegExp(r'[^0-9]'), '')),
      'role': role,
      'name': name,
    };
    if (value != null && value!.isNotEmpty) map['value'] = value;
    return map;
  }
}
