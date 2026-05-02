/// Defines how an element is located and acted upon on the screen.
class UIElement {
  final String id; // Unique ID (e.g. "node_12")
  final String? stableId; // Stable UIA-derived ID across observations
  final String name; // Text or label
  final String role; // Button, TextBox, etc.
  final String type; // The specific UIA ControlType
  final String? automationId;
  final String? className;
  final String? frameworkId;
  final int? processId;
  final String? hierarchyPath;
  final Map<String, dynamic> boundingBox; // {x, y, width, height}
  final bool isClickable;
  final bool isKeyboardFocusable;
  final bool isEnabled;
  final bool isFocused;
  final bool isOffscreen;
  final String? value;

  const UIElement({
    required this.id,
    this.stableId,
    required this.name,
    required this.role,
    required this.type,
    this.automationId,
    this.className,
    this.frameworkId,
    this.processId,
    this.hierarchyPath,
    required this.boundingBox,
    this.isClickable = false,
    this.isKeyboardFocusable = false,
    this.isEnabled = true,
    this.isFocused = false,
    this.isOffscreen = false,
    this.value,
  });

  factory UIElement.fromJson(Map<String, dynamic> json) {
    return UIElement(
      id: json['id'] as String,
      stableId: json['stableId'] as String?,
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? 'unknown',
      type: json['type'] as String? ?? '',
      automationId: json['automationId'] as String?,
      className: json['className'] as String?,
      frameworkId: json['frameworkId'] as String?,
      processId: json['processId'] as int?,
      hierarchyPath: json['hierarchyPath'] as String?,
      boundingBox: json['boundingBox'] as Map<String, dynamic>? ?? {},
      isClickable: json['isClickable'] as bool? ?? false,
      isKeyboardFocusable: json['isKeyboardFocusable'] as bool? ?? false,
      isEnabled: json['isEnabled'] as bool? ?? true,
      isFocused: json['isFocused'] as bool? ?? false,
      isOffscreen: json['isOffscreen'] as bool? ?? false,
      value: json['value'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'stableId': stableId,
    'name': name,
    'role': role,
    'type': type,
    'automationId': automationId,
    'className': className,
    'frameworkId': frameworkId,
    'processId': processId,
    'hierarchyPath': hierarchyPath,
    'boundingBox': boundingBox,
    'isClickable': isClickable,
    'isKeyboardFocusable': isKeyboardFocusable,
    'isEnabled': isEnabled,
    'isFocused': isFocused,
    'isOffscreen': isOffscreen,
    'value': value,
  };

  /// Used for prompting the LLM simply
  Map<String, dynamic> toPromptJson() {
    final map = <String, dynamic>{
      'index': int.parse(id.replaceAll(RegExp(r'[^0-9]'), '')),
      if (stableId != null) 'stableId': stableId,
      'role': role,
      'name': name,
      'type': type,
      if (automationId != null && automationId!.isNotEmpty) 'automationId': automationId,
      if (className != null && className!.isNotEmpty) 'className': className,
      if (hierarchyPath != null) 'path': hierarchyPath,
      'bounds': boundingBox,
      'clickable': isClickable,
      'focusable': isKeyboardFocusable,
      'enabled': isEnabled,
      'focused': isFocused,
    };
    if (value != null && value!.isNotEmpty) map['value'] = value;
    return map;
  }
}
