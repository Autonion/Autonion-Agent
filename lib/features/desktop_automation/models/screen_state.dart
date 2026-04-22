import 'ui_element.dart';

/// Represents a snapshot of the current desktop screen state.
class ScreenState {
  final List<UIElement> elements;
  final String? screenshotBase64;
  final int screenWidth;
  final int screenHeight;

  const ScreenState({
    required this.elements,
    this.screenshotBase64,
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
      screenWidth: json['screenWidth'] as int? ?? 1920,
      screenHeight: json['screenHeight'] as int? ?? 1080,
    );
  }
}
