import 'package:uuid/uuid.dart';

// ═══════════════════════════════════════════════════════════════════
//  ENUMS
// ═══════════════════════════════════════════════════════════════════

/// All node types supported in the Desktop flow graph.
///
/// `keyboard` is for key combos / shortcuts (Ctrl+C, F5, etc.).
/// `typeText` is for typing string input into fields.
enum DesktopFlowNodeType {
  start,
  click,
  doubleClick,
  rightClick,
  typeText,
  keyboard,
  hotkey, // Legacy compat — alias for keyboard
  launchApp,
  delay,
  screenshot,
  scroll,
  swipe,
  repeat,
  conditional,
  visualTrigger,
  uiDetect,
  unlock,
  dataIterator,
  done;

  String get displayName {
    switch (this) {
      case DesktopFlowNodeType.start:
        return 'Start';
      case DesktopFlowNodeType.click:
        return 'Click';
      case DesktopFlowNodeType.doubleClick:
        return 'Double Click';
      case DesktopFlowNodeType.rightClick:
        return 'Right Click';
      case DesktopFlowNodeType.typeText:
        return 'Type Text';
      case DesktopFlowNodeType.keyboard:
        return 'Keyboard';
      case DesktopFlowNodeType.hotkey:
        return 'Keyboard';
      case DesktopFlowNodeType.launchApp:
        return 'Launch App';
      case DesktopFlowNodeType.delay:
        return 'Delay';
      case DesktopFlowNodeType.screenshot:
        return 'Screenshot';
      case DesktopFlowNodeType.scroll:
        return 'Scroll';
      case DesktopFlowNodeType.repeat:
        return 'Repeat';
      case DesktopFlowNodeType.conditional:
        return 'Conditional';
      case DesktopFlowNodeType.visualTrigger:
        return 'Visual Trigger';
      case DesktopFlowNodeType.uiDetect:
        return 'UI Attribute';
      case DesktopFlowNodeType.swipe:
        return 'Swipe';
      case DesktopFlowNodeType.unlock:
        return 'Unlock';
      case DesktopFlowNodeType.dataIterator:
        return 'Data Iterator';
      case DesktopFlowNodeType.done:
        return 'Done';
    }
  }

  String get icon {
    switch (this) {
      case DesktopFlowNodeType.start:
        return 'play_circle';
      case DesktopFlowNodeType.click:
        return 'mouse';
      case DesktopFlowNodeType.doubleClick:
        return 'ads_click';
      case DesktopFlowNodeType.rightClick:
        return 'touch_app';
      case DesktopFlowNodeType.typeText:
        return 'text_fields';
      case DesktopFlowNodeType.keyboard:
        return 'keyboard';
      case DesktopFlowNodeType.hotkey:
        return 'keyboard_alt';
      case DesktopFlowNodeType.launchApp:
        return 'launch';
      case DesktopFlowNodeType.delay:
        return 'timer';
      case DesktopFlowNodeType.screenshot:
        return 'screenshot_monitor';
      case DesktopFlowNodeType.scroll:
        return 'swap_vert';
      case DesktopFlowNodeType.repeat:
        return 'loop';
      case DesktopFlowNodeType.conditional:
        return 'call_split';
      case DesktopFlowNodeType.visualTrigger:
        return 'image_search';
      case DesktopFlowNodeType.uiDetect:
        return 'find_in_page';
      case DesktopFlowNodeType.swipe:
        return 'swipe';
      case DesktopFlowNodeType.unlock:
        return 'lock_open';
      case DesktopFlowNodeType.dataIterator:
        return 'playlist_play';
      case DesktopFlowNodeType.done:
        return 'check_circle';
    }
  }
}

/// How a keyboard node should execute its keys.
enum KeyboardActionType {
  /// Press and release immediately (e.g. Ctrl+S, F5).
  press,

  /// Hold the key(s) down for [holdDurationMs] milliseconds.
  hold,

  /// Release previously held key(s).
  release,

  /// Type a sequence of keys one by one (for macro-like key sequences).
  typeSequence;

  String get displayName {
    switch (this) {
      case KeyboardActionType.press:
        return 'Press & Release';
      case KeyboardActionType.hold:
        return 'Hold';
      case KeyboardActionType.release:
        return 'Release';
      case KeyboardActionType.typeSequence:
        return 'Type Sequence';
    }
  }
}

/// How a node targets a UI element on screen.
enum UITargetMode {
  /// Click at absolute screen coordinates.
  coordinate,

  /// Match by UIA attributes (automationId, className, name, role).
  uiaAttribute,

  /// Match by the stable ID derived from the accessibility tree.
  stableId;

  String get displayName {
    switch (this) {
      case UITargetMode.coordinate:
        return 'Screen Coordinates';
      case UITargetMode.uiaAttribute:
        return 'UI Attribute Match';
      case UITargetMode.stableId:
        return 'Stable Element ID';
    }
  }
}

/// What triggers a flow to start executing.
enum FlowTriggerType {
  /// User manually clicks "Run" in the Flow Builder UI.
  manual,

  /// A registered global hotkey fires the flow.
  hotkey,

  /// A UI element matching the selector appears on screen.
  elementAppear,

  /// Timed/recurring execution.
  scheduled;

  String get displayName {
    switch (this) {
      case FlowTriggerType.manual:
        return 'Manual';
      case FlowTriggerType.hotkey:
        return 'Hotkey';
      case FlowTriggerType.elementAppear:
        return 'Element Appears';
      case FlowTriggerType.scheduled:
        return 'Scheduled';
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  UI TARGET SELECTOR
// ═══════════════════════════════════════════════════════════════════

/// Describes how a node locates a UI element — by coordinate, UIA
/// attribute match, or stable element ID.
///
/// Used by Click, DoubleClick, RightClick, TypeText, and Conditional nodes
/// to target specific on-screen elements.
class UITargetSelector {
  final UITargetMode mode;

  // ── Coordinate mode ──
  final double? x;
  final double? y;
  final double? width;
  final double? height;

  // ── StableId mode ──
  final String? stableId;

  // ── UIA Attribute mode ──
  final String? automationId;
  final String? className;
  final String? name;
  final String? role;
  final String? controlType;

  // ── UIA Attribute mode — disambiguation hints ──
  // Saved from the originally-picked element to disambiguate
  // when multiple elements share the same attributes.
  final double? hintX;      // Center X of originally-picked element
  final double? hintY;      // Center Y of originally-picked element
  final double? hintWidth;  // Width of originally-picked element
  final double? hintHeight; // Height of originally-picked element
  final String? hintValue;  // Text/value of originally-picked element

  const UITargetSelector({
    required this.mode,
    this.x,
    this.y,
    this.width,
    this.height,
    this.stableId,
    this.automationId,
    this.className,
    this.name,
    this.role,
    this.controlType,
    this.hintX,
    this.hintY,
    this.hintWidth,
    this.hintHeight,
    this.hintValue,
  });

  /// A coordinate-based target.
  factory UITargetSelector.coordinate(double x, double y) =>
      UITargetSelector(mode: UITargetMode.coordinate, x: x, y: y);

  /// A coordinate-based target region.
  factory UITargetSelector.region(
    double x,
    double y,
    double width,
    double height,
  ) => UITargetSelector(
    mode: UITargetMode.coordinate,
    x: x,
    y: y,
    width: width,
    height: height,
  );

  /// A stable-ID-based target.
  factory UITargetSelector.fromStableId(String stableId) =>
      UITargetSelector(mode: UITargetMode.stableId, stableId: stableId);

  /// A UIA-attribute-based target.
  factory UITargetSelector.fromAttributes({
    String? automationId,
    String? className,
    String? name,
    String? role,
    String? controlType,
    double? hintX,
    double? hintY,
    double? hintWidth,
    double? hintHeight,
    String? hintValue,
  }) => UITargetSelector(
    mode: UITargetMode.uiaAttribute,
    automationId: automationId,
    className: className,
    name: name,
    role: role,
    controlType: controlType,
    hintX: hintX,
    hintY: hintY,
    hintWidth: hintWidth,
    hintHeight: hintHeight,
    hintValue: hintValue,
  );

  factory UITargetSelector.fromJson(Map<String, dynamic> json) {
    return UITargetSelector(
      mode: UITargetMode.values.firstWhere(
        (m) => m.name == json['mode'],
        orElse: () => UITargetMode.coordinate,
      ),
      x: _asDouble(json['x']),
      y: _asDouble(json['y']),
      width: _asDouble(json['width']),
      height: _asDouble(json['height']),
      stableId: json['stableId'] as String?,
      automationId: json['automationId'] as String?,
      className: json['className'] as String?,
      name: json['name'] as String?,
      role: json['role'] as String?,
      controlType: json['controlType'] as String?,
      hintX: _asDouble(json['hintX']),
      hintY: _asDouble(json['hintY']),
      hintWidth: _asDouble(json['hintWidth']),
      hintHeight: _asDouble(json['hintHeight']),
      hintValue: json['hintValue'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (stableId != null) 'stableId': stableId,
    if (automationId != null) 'automationId': automationId,
    if (className != null) 'className': className,
    if (name != null) 'name': name,
    if (role != null) 'role': role,
    if (controlType != null) 'controlType': controlType,
    if (hintX != null) 'hintX': hintX,
    if (hintY != null) 'hintY': hintY,
    if (hintWidth != null) 'hintWidth': hintWidth,
    if (hintHeight != null) 'hintHeight': hintHeight,
    if (hintValue != null) 'hintValue': hintValue,
  };

  /// User-readable summary for display in node cards.
  String get summary {
    switch (mode) {
      case UITargetMode.coordinate:
        if ((width ?? 0) > 0 && (height ?? 0) > 0) {
          return 'Area (${x?.toInt()}, ${y?.toInt()}) ${width!.toInt()}x${height!.toInt()}';
        }
        return 'Point (${x?.toInt()}, ${y?.toInt()})';
      case UITargetMode.stableId:
        return stableId ?? '—';
      case UITargetMode.uiaAttribute:
        final parts = <String>[];
        if (name != null && name!.isNotEmpty) parts.add('name="$name"');
        if (role != null && role!.isNotEmpty) parts.add('role=$role');
        if (automationId != null && automationId!.isNotEmpty) {
          parts.add('autoId="$automationId"');
        }
        if (className != null && className!.isNotEmpty) {
          parts.add('class=$className');
        }
        return parts.isEmpty ? '(no attributes set)' : parts.join(', ');
    }
  }

  static double? _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return null;
  }

  bool get hasRegion => (width ?? 0) > 0 && (height ?? 0) > 0;

  /// Whether at least one UIA attribute is set for matching.
  bool get hasAnyAttribute =>
      (name != null && name!.isNotEmpty) ||
      (role != null && role!.isNotEmpty) ||
      (automationId != null && automationId!.isNotEmpty) ||
      (className != null && className!.isNotEmpty) ||
      (controlType != null && controlType!.isNotEmpty);

  /// Whether disambiguation hint position data is available.
  bool get hasHint => hintX != null && hintY != null;

  double? get centerX => x == null ? null : x! + ((width ?? 0) / 2);
  double? get centerY => y == null ? null : y! + ((height ?? 0) / 2);
}

// -------------------------------------------------------------------
//  KEYBOARD NODE CONFIG
// ═══════════════════════════════════════════════════════════════════

/// Configuration for a `keyboard` node.
///
/// Separate from `typeText` which is for typing string input. This is
/// for key combos/shortcuts: Ctrl+S, Ctrl+Shift+P, F5, Alt+Tab, etc.
class KeyboardNodeConfig {
  /// The keys to press. Examples: `['ctrl', 's']`, `['f5']`, `['alt', 'tab']`.
  final List<String> keys;

  /// How to execute the keys.
  final KeyboardActionType action;

  /// For [KeyboardActionType.hold] — how long to hold in ms.
  final int? holdDurationMs;

  /// Press the combo N times. Defaults to 1.
  final int repeatCount;

  /// Delay between repeated presses in ms. Defaults to 100.
  final int delayBetweenMs;

  const KeyboardNodeConfig({
    required this.keys,
    this.action = KeyboardActionType.press,
    this.holdDurationMs,
    this.repeatCount = 1,
    this.delayBetweenMs = 100,
  });

  factory KeyboardNodeConfig.fromJson(Map<String, dynamic> json) {
    return KeyboardNodeConfig(
      keys:
          (json['keys'] as List<dynamic>?)?.map((k) => k.toString()).toList() ??
          [],
      action: KeyboardActionType.values.firstWhere(
        (a) => a.name == json['action'],
        orElse: () => KeyboardActionType.press,
      ),
      holdDurationMs: json['holdDurationMs'] as int?,
      repeatCount: json['repeatCount'] as int? ?? 1,
      delayBetweenMs: json['delayBetweenMs'] as int? ?? 100,
    );
  }

  Map<String, dynamic> toJson() => {
    'keys': keys,
    'action': action.name,
    if (holdDurationMs != null) 'holdDurationMs': holdDurationMs,
    'repeatCount': repeatCount,
    'delayBetweenMs': delayBetweenMs,
  };

  /// User-readable summary, e.g. "Ctrl+S" or "F5 ×3".
  String get summary {
    final combo = keys.map((k) => _prettyKey(k)).join('+');
    if (repeatCount > 1) return '$combo ×$repeatCount';
    return combo;
  }

  static String _prettyKey(String key) {
    switch (key.toLowerCase()) {
      case 'ctrl':
      case 'control':
        return 'Ctrl';
      case 'alt':
        return 'Alt';
      case 'shift':
        return 'Shift';
      case 'win':
      case 'super':
        return 'Win';
      case 'enter':
      case 'return':
        return 'Enter';
      case 'esc':
      case 'escape':
        return 'Esc';
      case 'tab':
        return 'Tab';
      case 'space':
        return 'Space';
      case 'backspace':
        return 'Backspace';
      case 'delete':
        return 'Del';
      default:
        return key.length == 1 ? key.toUpperCase() : key;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  DATA ITERATOR CONFIG
// ═══════════════════════════════════════════════════════════════════

/// How to order child elements when iterating a container.
enum IterationDirection {
  /// Sort children by Y coordinate (top → bottom).
  vertical,

  /// Sort children by X coordinate (left → right).
  horizontal,

  /// Use the accessibility tree's native order.
  auto;

  String get displayName {
    switch (this) {
      case IterationDirection.vertical:
        return 'Vertical (Top → Bottom)';
      case IterationDirection.horizontal:
        return 'Horizontal (Left → Right)';
      case IterationDirection.auto:
        return 'Auto (Tree Order)';
    }
  }
}

/// How the iterator turns container children into logical items.
enum DataIteratorItemMode {
  /// Infer visual item groups when the container exposes card subparts.
  auto,

  /// Always group nearby child elements into repeated visual cards/rows.
  visualGroups,

  /// Use the UIA container's direct children exactly as reported.
  directChildren;

  String get displayName {
    switch (this) {
      case DataIteratorItemMode.auto:
        return 'Auto visual items';
      case DataIteratorItemMode.visualGroups:
        return 'Visual groups';
      case DataIteratorItemMode.directChildren:
        return 'Direct children';
    }
  }
}

/// Configuration for a `dataIterator` node.
///
/// Defines how to iterate through child elements of a UIA container
/// (list, grid, table, etc.) discovered via the accessibility tree.
class DataIteratorConfig {
  /// How to sort/order the discovered child elements.
  final IterationDirection direction;

  /// How to detect logical items within the selected container.
  final DataIteratorItemMode itemMode;

  /// Name of the context variable holding the current item's text.
  /// Downstream nodes can reference this via `{{current_item}}`.
  final String contextVariableName;

  /// Delay between iterations in milliseconds.
  final int delayBetweenMs;

  /// Whether to click each child element before running the body sub-flow.
  final bool clickEachItem;

  /// If true, a body-node failure skips to the next item instead of
  /// aborting the entire iteration.
  final bool continueOnError;

  /// Optional filter: only iterate children whose UIA role matches.
  /// E.g. "50006" for Image, "50007" for ListItem, "50020" for Text.
  final String? childRoleFilter;

  /// Optional filter: only iterate children whose UIA className matches.
  /// E.g. "Image", "ListViewItem", "TextBlock".
  final String? childClassNameFilter;

  const DataIteratorConfig({
    this.direction = IterationDirection.vertical,
    this.itemMode = DataIteratorItemMode.auto,
    this.contextVariableName = 'current_item',
    this.delayBetweenMs = 500,
    this.clickEachItem = true,
    this.continueOnError = true,
    this.childRoleFilter,
    this.childClassNameFilter,
  });

  factory DataIteratorConfig.fromJson(Map<String, dynamic> json) {
    return DataIteratorConfig(
      direction: IterationDirection.values.firstWhere(
        (d) => d.name == json['direction'],
        orElse: () => IterationDirection.vertical,
      ),
      itemMode: DataIteratorItemMode.values.firstWhere(
        (m) => m.name == json['itemMode'],
        orElse: () => DataIteratorItemMode.auto,
      ),
      contextVariableName:
          json['contextVariableName'] as String? ?? 'current_item',
      delayBetweenMs: json['delayBetweenMs'] as int? ?? 500,
      clickEachItem: json['clickEachItem'] as bool? ?? true,
      continueOnError: json['continueOnError'] as bool? ?? true,
      childRoleFilter: json['childRoleFilter'] as String?,
      childClassNameFilter: json['childClassNameFilter'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'direction': direction.name,
    'itemMode': itemMode.name,
    'contextVariableName': contextVariableName,
    'delayBetweenMs': delayBetweenMs,
    'clickEachItem': clickEachItem,
    'continueOnError': continueOnError,
    if (childRoleFilter != null && childRoleFilter!.isNotEmpty)
      'childRoleFilter': childRoleFilter,
    if (childClassNameFilter != null && childClassNameFilter!.isNotEmpty)
      'childClassNameFilter': childClassNameFilter,
  };

  /// User-readable summary, e.g. "Vertical, click each, 500ms".
  String get summary {
    final parts = <String>[direction.displayName, itemMode.displayName];
    if (clickEachItem) parts.add('click each');
    parts.add('${delayBetweenMs}ms');
    if (!continueOnError) parts.add('stop on error');
    if (childRoleFilter != null && childRoleFilter!.isNotEmpty) {
      parts.add('role=$childRoleFilter');
    }
    if (childClassNameFilter != null && childClassNameFilter!.isNotEmpty) {
      parts.add('class=$childClassNameFilter');
    }
    return parts.join(', ');
  }
}

// ═══════════════════════════════════════════════════════════════════
//  FLOW TRIGGER
// ═══════════════════════════════════════════════════════════════════

/// Defines what triggers a flow to start executing.
///
/// Attached to a [DesktopFlow] — each flow can have one trigger.
/// Visual trigger configuration is done in the Flow Builder UI.
class FlowTrigger {
  /// What kind of trigger.
  final FlowTriggerType type;

  /// For [FlowTriggerType.hotkey] — the combo string, e.g. "ctrl+shift+f1".
  /// Registered as a global OS hotkey via the Python bridge.
  final String? hotkeyCombo;

  /// For [FlowTriggerType.elementAppear] — the element to watch for.
  final UITargetSelector? elementMatch;

  /// For [FlowTriggerType.scheduled] — interval in milliseconds.
  final int? scheduleIntervalMs;

  /// Whether this trigger is currently active.
  final bool enabled;

  const FlowTrigger({
    required this.type,
    this.hotkeyCombo,
    this.elementMatch,
    this.scheduleIntervalMs,
    this.enabled = true,
  });

  /// Default: manual trigger.
  const FlowTrigger.manual()
    : type = FlowTriggerType.manual,
      hotkeyCombo = null,
      elementMatch = null,
      scheduleIntervalMs = null,
      enabled = true;

  factory FlowTrigger.fromJson(Map<String, dynamic> json) {
    return FlowTrigger(
      type: FlowTriggerType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => FlowTriggerType.manual,
      ),
      hotkeyCombo: json['hotkeyCombo'] as String?,
      elementMatch: json['elementMatch'] != null
          ? UITargetSelector.fromJson(
              json['elementMatch'] as Map<String, dynamic>,
            )
          : null,
      scheduleIntervalMs: json['scheduleIntervalMs'] as int?,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type.name,
    if (hotkeyCombo != null) 'hotkeyCombo': hotkeyCombo,
    if (elementMatch != null) 'elementMatch': elementMatch!.toJson(),
    if (scheduleIntervalMs != null) 'scheduleIntervalMs': scheduleIntervalMs,
    'enabled': enabled,
  };

  /// User-readable summary for the UI.
  String get summary {
    switch (type) {
      case FlowTriggerType.manual:
        return 'Manual';
      case FlowTriggerType.hotkey:
        return hotkeyCombo ?? 'No hotkey set';
      case FlowTriggerType.elementAppear:
        return 'When: ${elementMatch?.summary ?? "element appears"}';
      case FlowTriggerType.scheduled:
        if (scheduleIntervalMs == null) return 'No interval set';
        final secs = scheduleIntervalMs! / 1000;
        if (secs >= 60) return 'Every ${(secs / 60).toStringAsFixed(0)}m';
        return 'Every ${secs.toStringAsFixed(0)}s';
    }
  }

  FlowTrigger copyWith({
    FlowTriggerType? type,
    String? hotkeyCombo,
    UITargetSelector? elementMatch,
    int? scheduleIntervalMs,
    bool? enabled,
  }) {
    return FlowTrigger(
      type: type ?? this.type,
      hotkeyCombo: hotkeyCombo ?? this.hotkeyCombo,
      elementMatch: elementMatch ?? this.elementMatch,
      scheduleIntervalMs: scheduleIntervalMs ?? this.scheduleIntervalMs,
      enabled: enabled ?? this.enabled,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  FLOW NODE
// ═══════════════════════════════════════════════════════════════════

/// A single node in a Desktop flow graph.
///
/// Each node has a type, label, canvas position, and type-specific
/// configuration stored in [config].
class DesktopFlowNode {
  final String id;
  final DesktopFlowNodeType nodeType;
  String label;

  /// Position on the flow builder canvas.
  double x;
  double y;

  /// Optional: edge to follow when this node fails.
  String? onFailureEdgeId;

  // ── Type-specific configuration ──

  /// For click / doubleClick / rightClick / typeText / conditional:
  /// how to locate the target element.
  UITargetSelector? target;

  /// For typeText: the text to type.
  String? text;

  /// For typeText: first try to focus an editable UIA field automatically.
  bool autoDetectInput;

  /// For keyboard / hotkey nodes.
  KeyboardNodeConfig? keyboardConfig;

  /// For launchApp: the application name or path.
  String? appName;
  String? appPath;

  /// For delay: wait duration in milliseconds.
  int? delayMs;

  /// For scroll: direction ("up" or "down") and amount.
  String? scrollDirection;
  int? scrollAmount;

  /// For swipe: direction, distance (px), duration (ms), and optional start/end.
  String? swipeDirection;
  int? swipeDistance;
  int? swipeDuration;
  int? swipeStartX;
  int? swipeStartY;
  int? swipeEndX;
  int? swipeEndY;

  /// For repeat: number of iterations.
  int? repeatCount;

  /// For conditional: the attribute/value to check.
  /// If the configured condition is true, follow the "true" edge;
  /// otherwise follow the "false" edge.
  String? conditionOperator;
  String? conditionAttribute;
  String? conditionValue;

  /// For visualTrigger: path to the template image cropped from screenshot.
  String? templateImagePath;

  /// For visualTrigger: confidence threshold for template matching (0.0-1.0).
  double? matchThreshold;

  /// For visualTrigger: optional search region on screen.
  int? searchRegionX;
  int? searchRegionY;
  int? searchRegionWidth;
  int? searchRegionHeight;

  /// For visualTrigger: action to take on match (click, wait, assert_exists).
  String? visualAction;

  /// For uiDetect: action (click_first, count, extract_text, wait_until_visible).
  String? detectAction;

  /// For uiDetect: context key to store results for downstream nodes.
  String? detectOutputKey;

  /// For unlock: whether a password has been saved in secure storage.
  /// The actual password is NEVER stored in the flow JSON.
  bool hasUnlockPassword;

  /// For unlock: method used to unlock ('password', 'pin'). Future-proof.
  String? unlockMethod;

  /// For dataIterator: the container element (list/grid/table) to iterate.
  UITargetSelector? containerTarget;

  /// For dataIterator: iteration configuration.
  DataIteratorConfig? dataIteratorConfig;

  /// Optional settle delay in milliseconds, applied after this node finishes
  /// before the next node starts executing. If null, uses the default (200ms).
  int? settleDelayMs;

  DesktopFlowNode({
    String? id,
    required this.nodeType,
    required this.label,
    this.x = 0,
    this.y = 0,
    this.onFailureEdgeId,
    this.target,
    this.text,
    this.autoDetectInput = true,
    this.keyboardConfig,
    this.appName,
    this.appPath,
    this.delayMs,
    this.scrollDirection,
    this.scrollAmount,
    this.swipeDirection,
    this.swipeDistance,
    this.swipeDuration,
    this.swipeStartX,
    this.swipeStartY,
    this.swipeEndX,
    this.swipeEndY,
    this.repeatCount,
    this.conditionOperator,
    this.conditionAttribute,
    this.conditionValue,
    this.templateImagePath,
    this.matchThreshold,
    this.searchRegionX,
    this.searchRegionY,
    this.searchRegionWidth,
    this.searchRegionHeight,
    this.visualAction,
    this.detectAction,
    this.detectOutputKey,
    this.hasUnlockPassword = false,
    this.unlockMethod,
    this.containerTarget,
    this.dataIteratorConfig,
    this.settleDelayMs,
  }) : id = id ?? const Uuid().v4();

  factory DesktopFlowNode.fromJson(Map<String, dynamic> json) {
    return DesktopFlowNode(
      id: json['id'] as String,
      nodeType: DesktopFlowNodeType.values.firstWhere(
        (t) => t.name == json['nodeType'],
        orElse: () => DesktopFlowNodeType.done,
      ),
      label: json['label'] as String? ?? '',
      x: _asDouble(json['x']) ?? 0,
      y: _asDouble(json['y']) ?? 0,
      onFailureEdgeId: json['onFailureEdgeId'] as String?,
      target: json['target'] != null
          ? UITargetSelector.fromJson(json['target'] as Map<String, dynamic>)
          : null,
      text: json['text'] as String?,
      autoDetectInput: json['autoDetectInput'] as bool? ?? true,
      keyboardConfig: json['keyboardConfig'] != null
          ? KeyboardNodeConfig.fromJson(
              json['keyboardConfig'] as Map<String, dynamic>,
            )
          : null,
      appName: json['appName'] as String?,
      appPath: json['appPath'] as String?,
      delayMs: json['delayMs'] as int?,
      scrollDirection: json['scrollDirection'] as String?,
      scrollAmount: json['scrollAmount'] as int?,
      swipeDirection: json['swipeDirection'] as String?,
      swipeDistance: json['swipeDistance'] as int?,
      swipeDuration: json['swipeDuration'] as int?,
      swipeStartX: json['swipeStartX'] as int?,
      swipeStartY: json['swipeStartY'] as int?,
      swipeEndX: json['swipeEndX'] as int?,
      swipeEndY: json['swipeEndY'] as int?,
      repeatCount: json['repeatCount'] as int?,
      conditionOperator: json['conditionOperator'] as String?,
      conditionAttribute: json['conditionAttribute'] as String?,
      conditionValue: json['conditionValue'] as String?,
      templateImagePath: json['templateImagePath'] as String?,
      matchThreshold: _asDouble(json['matchThreshold']),
      searchRegionX: json['searchRegionX'] as int?,
      searchRegionY: json['searchRegionY'] as int?,
      searchRegionWidth: json['searchRegionWidth'] as int?,
      searchRegionHeight: json['searchRegionHeight'] as int?,
      visualAction: json['visualAction'] as String?,
      detectAction: json['detectAction'] as String?,
      detectOutputKey: json['detectOutputKey'] as String?,
      hasUnlockPassword: json['hasUnlockPassword'] as bool? ?? false,
      unlockMethod: json['unlockMethod'] as String?,
      containerTarget: json['containerTarget'] != null
          ? UITargetSelector.fromJson(
              json['containerTarget'] as Map<String, dynamic>)
          : null,
      dataIteratorConfig: json['dataIteratorConfig'] != null
          ? DataIteratorConfig.fromJson(
              json['dataIteratorConfig'] as Map<String, dynamic>)
          : null,
      settleDelayMs: json['settleDelayMs'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'nodeType': nodeType.name,
    'label': label,
    'x': x,
    'y': y,
    if (onFailureEdgeId != null) 'onFailureEdgeId': onFailureEdgeId,
    if (target != null) 'target': target!.toJson(),
    if (text != null) 'text': text,
    if (!autoDetectInput) 'autoDetectInput': autoDetectInput,
    if (keyboardConfig != null) 'keyboardConfig': keyboardConfig!.toJson(),
    if (appName != null) 'appName': appName,
    if (appPath != null) 'appPath': appPath,
    if (delayMs != null) 'delayMs': delayMs,
    if (scrollDirection != null) 'scrollDirection': scrollDirection,
    if (scrollAmount != null) 'scrollAmount': scrollAmount,
    if (swipeDirection != null) 'swipeDirection': swipeDirection,
    if (swipeDistance != null) 'swipeDistance': swipeDistance,
    if (swipeDuration != null) 'swipeDuration': swipeDuration,
    if (swipeStartX != null) 'swipeStartX': swipeStartX,
    if (swipeStartY != null) 'swipeStartY': swipeStartY,
    if (swipeEndX != null) 'swipeEndX': swipeEndX,
    if (swipeEndY != null) 'swipeEndY': swipeEndY,
    if (repeatCount != null) 'repeatCount': repeatCount,
    if (conditionOperator != null) 'conditionOperator': conditionOperator,
    if (conditionAttribute != null) 'conditionAttribute': conditionAttribute,
    if (conditionValue != null) 'conditionValue': conditionValue,
    if (templateImagePath != null) 'templateImagePath': templateImagePath,
    if (matchThreshold != null) 'matchThreshold': matchThreshold,
    if (searchRegionX != null) 'searchRegionX': searchRegionX,
    if (searchRegionY != null) 'searchRegionY': searchRegionY,
    if (searchRegionWidth != null) 'searchRegionWidth': searchRegionWidth,
    if (searchRegionHeight != null) 'searchRegionHeight': searchRegionHeight,
    if (visualAction != null) 'visualAction': visualAction,
    if (detectAction != null) 'detectAction': detectAction,
    if (detectOutputKey != null) 'detectOutputKey': detectOutputKey,
    if (hasUnlockPassword) 'hasUnlockPassword': hasUnlockPassword,
    if (unlockMethod != null) 'unlockMethod': unlockMethod,
    if (containerTarget != null) 'containerTarget': containerTarget!.toJson(),
    if (dataIteratorConfig != null)
      'dataIteratorConfig': dataIteratorConfig!.toJson(),
    if (settleDelayMs != null) 'settleDelayMs': settleDelayMs,
  };

  /// Short summary shown on the node card in the builder UI.
  String get configSummary {
    switch (nodeType) {
      case DesktopFlowNodeType.start:
        return 'Entry point';
      case DesktopFlowNodeType.click:
      case DesktopFlowNodeType.doubleClick:
      case DesktopFlowNodeType.rightClick:
        return target?.summary ?? 'No target';
      case DesktopFlowNodeType.typeText:
        if (text == null || text!.isEmpty) return 'No text set';
        final prefix = autoDetectInput ? 'Auto: ' : '';
        final value = text!.length > 24
            ? '${text!.substring(0, 24)}...'
            : text!;
        return '$prefix$value';
      case DesktopFlowNodeType.keyboard:
      case DesktopFlowNodeType.hotkey:
        return keyboardConfig?.summary ?? 'No keys set';
      case DesktopFlowNodeType.launchApp:
        return appName ?? 'No app set';
      case DesktopFlowNodeType.delay:
        if (delayMs == null) return 'No delay set';
        return delayMs! >= 1000
            ? '${(delayMs! / 1000).toStringAsFixed(1)}s'
            : '${delayMs}ms';
      case DesktopFlowNodeType.screenshot:
        return 'Capture screen';
      case DesktopFlowNodeType.scroll:
        return '${scrollDirection ?? "down"} ×${scrollAmount ?? 3}';
      case DesktopFlowNodeType.swipe:
        if (swipeEndX != null && swipeEndY != null) {
          return '(${swipeStartX ?? 0},${swipeStartY ?? 0}) \u2192 ($swipeEndX,$swipeEndY)';
        }
        return '${swipeDirection ?? "down"} ${swipeDistance ?? 300}px';
      case DesktopFlowNodeType.repeat:
        return '${repeatCount ?? 1} iterations';
      case DesktopFlowNodeType.conditional:
        return _conditionSummary;
      case DesktopFlowNodeType.visualTrigger:
        if (templateImagePath == null || templateImagePath!.isEmpty) {
          return 'No template set';
        }
        return '${visualAction ?? "click"} @ ${((matchThreshold ?? 0.8) * 100).toInt()}%';
      case DesktopFlowNodeType.uiDetect:
        final action = detectAction ?? 'click_first';
        final targetDesc = target?.summary ?? 'No target';
        return '$action: $targetDesc';
      case DesktopFlowNodeType.unlock:
        return hasUnlockPassword ? '🔒 Password saved' : '⚠ No password';
      case DesktopFlowNodeType.dataIterator:
        if (containerTarget == null) return 'No container set';
        return dataIteratorConfig?.summary ?? 'Configured';
      case DesktopFlowNodeType.done:
        return 'End';
    }
  }

  DesktopFlowNode copyWith({
    String? id,
    DesktopFlowNodeType? nodeType,
    String? label,
    double? x,
    double? y,
    String? onFailureEdgeId,
    UITargetSelector? target,
    String? text,
    bool? autoDetectInput,
    KeyboardNodeConfig? keyboardConfig,
    String? appName,
    String? appPath,
    int? delayMs,
    String? scrollDirection,
    int? scrollAmount,
    String? swipeDirection,
    int? swipeDistance,
    int? swipeDuration,
    int? swipeStartX,
    int? swipeStartY,
    int? swipeEndX,
    int? swipeEndY,
    int? repeatCount,
    String? conditionOperator,
    String? conditionAttribute,
    String? conditionValue,
    String? templateImagePath,
    double? matchThreshold,
    int? searchRegionX,
    int? searchRegionY,
    int? searchRegionWidth,
    int? searchRegionHeight,
    String? visualAction,
    String? detectAction,
    String? detectOutputKey,
    bool? hasUnlockPassword,
    String? unlockMethod,
    UITargetSelector? containerTarget,
    DataIteratorConfig? dataIteratorConfig,
    int? settleDelayMs,
  }) {
    return DesktopFlowNode(
      id: id ?? this.id,
      nodeType: nodeType ?? this.nodeType,
      label: label ?? this.label,
      x: x ?? this.x,
      y: y ?? this.y,
      onFailureEdgeId: onFailureEdgeId ?? this.onFailureEdgeId,
      target: target ?? this.target,
      text: text ?? this.text,
      autoDetectInput: autoDetectInput ?? this.autoDetectInput,
      keyboardConfig: keyboardConfig ?? this.keyboardConfig,
      appName: appName ?? this.appName,
      appPath: appPath ?? this.appPath,
      delayMs: delayMs ?? this.delayMs,
      scrollDirection: scrollDirection ?? this.scrollDirection,
      scrollAmount: scrollAmount ?? this.scrollAmount,
      swipeDirection: swipeDirection ?? this.swipeDirection,
      swipeDistance: swipeDistance ?? this.swipeDistance,
      swipeDuration: swipeDuration ?? this.swipeDuration,
      swipeStartX: swipeStartX ?? this.swipeStartX,
      swipeStartY: swipeStartY ?? this.swipeStartY,
      swipeEndX: swipeEndX ?? this.swipeEndX,
      swipeEndY: swipeEndY ?? this.swipeEndY,
      repeatCount: repeatCount ?? this.repeatCount,
      conditionOperator: conditionOperator ?? this.conditionOperator,
      conditionAttribute: conditionAttribute ?? this.conditionAttribute,
      conditionValue: conditionValue ?? this.conditionValue,
      templateImagePath: templateImagePath ?? this.templateImagePath,
      matchThreshold: matchThreshold ?? this.matchThreshold,
      searchRegionX: searchRegionX ?? this.searchRegionX,
      searchRegionY: searchRegionY ?? this.searchRegionY,
      searchRegionWidth: searchRegionWidth ?? this.searchRegionWidth,
      searchRegionHeight: searchRegionHeight ?? this.searchRegionHeight,
      visualAction: visualAction ?? this.visualAction,
      detectAction: detectAction ?? this.detectAction,
      detectOutputKey: detectOutputKey ?? this.detectOutputKey,
      hasUnlockPassword: hasUnlockPassword ?? this.hasUnlockPassword,
      unlockMethod: unlockMethod ?? this.unlockMethod,
      containerTarget: containerTarget ?? this.containerTarget,
      dataIteratorConfig: dataIteratorConfig ?? this.dataIteratorConfig,
      settleDelayMs: settleDelayMs ?? this.settleDelayMs,
    );
  }

  static double? _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return null;
  }

  String get _conditionSummary {
    switch (conditionOperator ?? conditionAttribute ?? 'element_exists') {
      case 'element_missing':
        return 'If target is missing';
      case 'name_contains':
        return 'If name contains "${conditionValue ?? ''}"';
      case 'name_equals':
        return 'If name = "${conditionValue ?? ''}"';
      case 'value_contains':
        return 'If value contains "${conditionValue ?? ''}"';
      case 'value_equals':
        return 'If value = "${conditionValue ?? ''}"';
      case 'role_equals':
        return 'If role = "${conditionValue ?? ''}"';
      case 'class_contains':
        return 'If class contains "${conditionValue ?? ''}"';
      case 'enabled':
        return 'If target is enabled';
      case 'focused':
        return 'If target is focused';
      case 'element_exists':
      default:
        return 'If target exists';
    }
  }
}

// -------------------------------------------------------------------
//  FLOW EDGE
// ═══════════════════════════════════════════════════════════════════

/// A directed edge connecting two nodes in the flow graph.
class DesktopFlowEdge {
  final String id;
  final String fromNodeId;
  final String toNodeId;

  /// Optional label for conditional branches (e.g. "true", "false").
  String? label;

  DesktopFlowEdge({
    required this.id,
    required this.fromNodeId,
    required this.toNodeId,
    this.label,
  });

  factory DesktopFlowEdge.create({
    required String fromNodeId,
    required String toNodeId,
    String? label,
  }) {
    return DesktopFlowEdge(
      id: const Uuid().v4(),
      fromNodeId: fromNodeId,
      toNodeId: toNodeId,
      label: label,
    );
  }

  factory DesktopFlowEdge.fromJson(Map<String, dynamic> json) {
    return DesktopFlowEdge(
      id: json['id'] as String,
      fromNodeId: json['fromNodeId'] as String,
      toNodeId: json['toNodeId'] as String,
      label: json['label'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromNodeId': fromNodeId,
    'toNodeId': toNodeId,
    if (label != null) 'label': label,
  };
}

// ═══════════════════════════════════════════════════════════════════
//  DESKTOP FLOW (top-level container)
// ═══════════════════════════════════════════════════════════════════

/// Top-level flow container — the full graph that gets saved to disk,
/// executed by the engine, and synced to Android.
///
/// Parallels Android's `FlowGraph` but uses Desktop-native action types.
class DesktopFlow {
  final String id;
  String name;
  String description;
  final int version;
  final List<DesktopFlowNode> nodes;
  final List<DesktopFlowEdge> edges;
  final DateTime createdAt;
  DateTime updatedAt;
  List<String> tags;

  /// What triggers this flow to start. Defaults to manual.
  FlowTrigger trigger;

  DesktopFlow({
    String? id,
    required this.name,
    this.description = '',
    this.version = 1,
    List<DesktopFlowNode>? nodes,
    List<DesktopFlowEdge>? edges,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<String>? tags,
    FlowTrigger? trigger,
  }) : id = id ?? const Uuid().v4(),
       nodes = nodes ?? [],
       edges = edges ?? [],
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       tags = tags ?? [],
       trigger = trigger ?? const FlowTrigger.manual();

  /// Create a new flow with a Start and Done node already placed.
  factory DesktopFlow.empty(String name, {String description = ''}) {
    final startNode = DesktopFlowNode(
      nodeType: DesktopFlowNodeType.start,
      label: 'Start',
      x: 9900,
      y: 10000,
    );
    final doneNode = DesktopFlowNode(
      nodeType: DesktopFlowNodeType.done,
      label: 'Done',
      x: 10400,
      y: 10000,
    );

    return DesktopFlow(
      name: name,
      description: description,
      nodes: [startNode, doneNode],
      edges: [],
    );
  }

  factory DesktopFlow.fromJson(Map<String, dynamic> json) {
    return DesktopFlow(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Untitled',
      description: json['description'] as String? ?? '',
      version: json['version'] as int? ?? 1,
      nodes:
          (json['nodes'] as List<dynamic>?)
              ?.map((n) => DesktopFlowNode.fromJson(n as Map<String, dynamic>))
              .toList() ??
          [],
      edges:
          (json['edges'] as List<dynamic>?)
              ?.map((e) => DesktopFlowEdge.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : DateTime.now(),
      tags:
          (json['tags'] as List<dynamic>?)?.map((t) => t.toString()).toList() ??
          [],
      trigger: json['trigger'] != null
          ? FlowTrigger.fromJson(json['trigger'] as Map<String, dynamic>)
          : const FlowTrigger.manual(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'version': version,
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'edges': edges.map((e) => e.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'tags': tags,
    'trigger': trigger.toJson(),
  };

  /// Find the start node (there should be exactly one).
  DesktopFlowNode? get startNode {
    try {
      return nodes.firstWhere((n) => n.nodeType == DesktopFlowNodeType.start);
    } catch (_) {
      return null;
    }
  }

  /// Get all outgoing edges from a given node.
  List<DesktopFlowEdge> outgoingEdges(String nodeId) {
    return edges.where((e) => e.fromNodeId == nodeId).toList();
  }

  /// Get the next node(s) after a given node.
  List<DesktopFlowNode> nextNodes(String nodeId) {
    final outEdges = outgoingEdges(nodeId);
    return outEdges
        .map((e) {
          try {
            return nodes.firstWhere((n) => n.id == e.toNodeId);
          } catch (_) {
            return null;
          }
        })
        .whereType<DesktopFlowNode>()
        .toList();
  }

  /// Find a node by its ID.
  DesktopFlowNode? findNode(String nodeId) {
    try {
      return nodes.firstWhere((n) => n.id == nodeId);
    } catch (_) {
      return null;
    }
  }

  /// Find an edge by its ID.
  DesktopFlowEdge? findEdge(String edgeId) {
    try {
      return edges.firstWhere((e) => e.id == edgeId);
    } catch (_) {
      return null;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  FLOW MANIFEST (lightweight, for sync & listing)
// ═══════════════════════════════════════════════════════════════════

/// Lightweight summary of a flow, used for listing in the UI
/// and syncing to Android without sending the full graph.
class FlowManifest {
  final String id;
  final String name;
  final String description;
  final int nodeCount;
  final String target; // "desktop"
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> tags;
  final FlowTriggerType triggerType;

  const FlowManifest({
    required this.id,
    required this.name,
    this.description = '',
    required this.nodeCount,
    this.target = 'desktop',
    required this.createdAt,
    required this.updatedAt,
    this.tags = const [],
    this.triggerType = FlowTriggerType.manual,
  });

  /// Create a manifest from a full [DesktopFlow].
  factory FlowManifest.fromFlow(DesktopFlow flow) {
    return FlowManifest(
      id: flow.id,
      name: flow.name,
      description: flow.description,
      nodeCount: flow.nodes.length,
      createdAt: flow.createdAt,
      updatedAt: flow.updatedAt,
      tags: flow.tags,
      triggerType: flow.trigger.type,
    );
  }

  factory FlowManifest.fromJson(Map<String, dynamic> json) {
    return FlowManifest(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Untitled',
      description: json['description'] as String? ?? '',
      nodeCount: json['nodeCount'] as int? ?? 0,
      target: json['target'] as String? ?? 'desktop',
      createdAt: json['createdAt'] is String
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
      updatedAt: json['updatedAt'] is String
          ? DateTime.parse(json['updatedAt'] as String)
          : DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int),
      tags:
          (json['tags'] as List<dynamic>?)?.map((t) => t.toString()).toList() ??
          [],
      triggerType: FlowTriggerType.values.firstWhere(
        (t) => t.name == json['triggerType'],
        orElse: () => FlowTriggerType.manual,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'nodeCount': nodeCount,
    'target': target,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'tags': tags,
    'triggerType': triggerType.name,
  };
}
