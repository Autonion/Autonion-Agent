import 'dart:convert';

String? validateBrowserAction(Map<String, dynamic> action) {
  final name = action['action'];
  final params = action['params'];
  if (params is! Map) return 'Action parameters must be an object.';
  const targets = {'click_element', 'type_into', 'scroll_to'};
  if (targets.contains(name)) {
    if (params['target_id'] is! String ||
        !RegExp(r'^el_\d+$').hasMatch(params['target_id'] as String)) {
      return 'Action requires an element ID from the current snapshot.';
    }
    if (name == 'type_into' && params['text'] is! String) {
      return 'type_into requires text.';
    }
    if (name == 'type_into' &&
        params['pressEnter'] != null &&
        params['pressEnter'] is! bool) {
      return 'pressEnter must be a boolean.';
    }
    return null;
  }
  switch (name) {
    case 'open_url':
      final url = params['url'] is String
          ? Uri.tryParse(params['url'] as String)
          : null;
      return url != null &&
              {'http', 'https'}.contains(url.scheme) &&
              url.host.isNotEmpty
          ? null
          : 'open_url requires an HTTP(S) URL.';
    case 'press_key':
      return {
            'Enter',
            'Tab',
            'Escape',
            'ArrowDown',
            'ArrowUp',
            'ArrowLeft',
            'ArrowRight',
          }.contains(params['key'])
          ? null
          : 'Unsupported browser key.';
    case 'wait':
      final ms = params['ms'];
      return ms is int && ms >= 0 && ms <= 5000
          ? null
          : 'wait must be between 0 and 5000 ms.';
    case 'play_media':
      return null;
    default:
      return 'Unsupported browser action: $name';
  }
}

String browserStateSignature(Map<String, dynamic>? snapshot) => jsonEncode({
  'url': snapshot?['url'],
  'title': snapshot?['title'],
  'text': snapshot?['text'],
  'elements': snapshot?['elements'],
});

class BrowserProgressGuard {
  String? _lastAction;
  int _repeats = 0;
  bool stalled(Map<String, dynamic> action, String before, String after) {
    final fingerprint = jsonEncode(action);
    if (action['action'] != 'wait' && before == after) {
      _repeats = _lastAction == fingerprint ? _repeats + 1 : 1;
    } else {
      _repeats = 0;
    }
    _lastAction = fingerprint;
    return _repeats >= 2;
  }
}
