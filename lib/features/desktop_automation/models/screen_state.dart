import 'ui_element.dart';

/// Represents a snapshot of the current desktop screen state.
class ScreenState {
  final List<UIElement> elements;
  final String? screenshotBase64;
  final String? screenshotError;
  final String? screenshotHash;
  final int? screenshotWidth;
  final int? screenshotHeight;
  final String? screenshotSource;
  final String? elementTreeHash;
  final String? activeWindowTitle;
  final String? activeWindowClassName;
  final int? activeWindowProcessId;
  final int? mouseX;
  final int? mouseY;
  final int screenLeft;
  final int screenTop;
  final int screenWidth;
  final int screenHeight;

  const ScreenState({
    required this.elements,
    this.screenshotBase64,
    this.screenshotError,
    this.screenshotHash,
    this.screenshotWidth,
    this.screenshotHeight,
    this.screenshotSource,
    this.elementTreeHash,
    this.activeWindowTitle,
    this.activeWindowClassName,
    this.activeWindowProcessId,
    this.mouseX,
    this.mouseY,
    this.screenLeft = 0,
    this.screenTop = 0,
    required this.screenWidth,
    required this.screenHeight,
  });

  factory ScreenState.fromJson(Map<String, dynamic> json) {
    final elems = json['elements'] as List<dynamic>? ?? [];
    return ScreenState(
      elements: elems
          .map((e) => UIElement.fromJson(e as Map<String, dynamic>))
          .toList(),
      screenshotBase64: json['screenshotBase64'] as String?,
      screenshotError: json['screenshotError'] as String?,
      screenshotHash: json['screenshotHash'] as String?,
      screenshotWidth: json['screenshotWidth'] as int?,
      screenshotHeight: json['screenshotHeight'] as int?,
      screenshotSource: json['screenshotSource'] as String?,
      elementTreeHash: json['elementTreeHash'] as String?,
      activeWindowTitle: json['activeWindowTitle'] as String?,
      activeWindowClassName: json['activeWindowClassName'] as String?,
      activeWindowProcessId: json['activeWindowProcessId'] as int?,
      mouseX: json['mouseX'] as int?,
      mouseY: json['mouseY'] as int?,
      screenLeft: json['screenLeft'] as int? ?? 0,
      screenTop: json['screenTop'] as int? ?? 0,
      screenWidth: json['screenWidth'] as int? ?? 1920,
      screenHeight: json['screenHeight'] as int? ?? 1080,
    );
  }

  String get compactSignature {
    final tree = elementTreeHash ?? elements.length.toString();
    final shot = screenshotHash ?? 'no-shot';
    final title = activeWindowTitle ?? '';
    return '$title|$tree|$shot';
  }

  Map<String, dynamic> toPromptMetadata() => {
    'screenWidth': screenWidth,
    'screenHeight': screenHeight,
    'screenLeft': screenLeft,
    'screenTop': screenTop,
    'activeWindowTitle': activeWindowTitle,
    'activeWindowClassName': activeWindowClassName,
    'activeWindowProcessId': activeWindowProcessId,
    'mouse': {'x': mouseX, 'y': mouseY},
    'elementCount': elements.length,
    'elementTreeHash': elementTreeHash,
    'screenshot': {
      'available': screenshotBase64 != null,
      'source': screenshotSource,
      'width': screenshotWidth,
      'height': screenshotHeight,
      'hash': screenshotHash,
      'error': screenshotError,
    },
  };
}
