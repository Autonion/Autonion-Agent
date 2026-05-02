/// 3-tier hybrid task decomposer for desktop automation.
///
/// Same strategy as Android's TaskDecomposer:
///   - Tier 1: Regex splitting at conjunctions (~0ms)
///   - Tier 2: Verb-boundary detection (~5ms)
///   - Tier 3: LLM fallback (only if the AI provider is available)
class SubGoal {
  final int stepNumber;
  final String description;
  final bool dependsOnPrevious;

  const SubGoal({
    required this.stepNumber,
    required this.description,
    this.dependsOnPrevious = true,
  });

  @override
  String toString() => 'SubGoal($stepNumber: $description)';
}

class TaskDecomposerService {
  static const _conjunctionPatterns = [
    r'\s+and\s+then\s+',
    r'\s+and\s+after\s+that\s+',
    r'\s+after\s+that\s+',
    r'\s+then\s+',
    r'\s+next\s+',
    r',\s+then\s+',
    r',\s+and\s+',
    r',\s*(?=[a-z])',
  ];

  static const _actionVerbs = {
    'open', 'launch', 'start',
    'search', 'find', 'look',
    'go', 'navigate', 'switch',
    'click', 'tap', 'press', 'select',
    'type', 'write', 'enter', 'input',
    'delete', 'remove', 'clear',
    'play', 'pause', 'stop', 'resume',
    'close', 'exit', 'quit',
    'save', 'download', 'upload',
    'send', 'share', 'forward',
    'scroll', 'swipe',
    'enable', 'disable', 'turn', 'toggle',
    'copy', 'paste', 'cut',
  };

  static const _nonBoundaryPredecessors = {
    'to', 'and', 'or', 'the', 'a', 'an', 'then',
    'it', 'this', 'that', 'my', 'your', 'its',
  };

  /// Decomposes a raw command into ordered, atomic sub-goals.
  ///
  /// For simple commands, returns a 1-item list.
  /// For compound commands, returns N ordered sub-goals.
  List<SubGoal> decompose(String rawCommand) {
    final command = rawCommand.trim();
    if (command.isEmpty) return [SubGoal(stepNumber: 1, description: command)];

    // Tier 1: Regex conjunction splitting
    final regexResult = _splitByConjunctions(command);
    if (regexResult.length > 1) {
      final allValid = regexResult.every(_hasActionVerb);
      if (allValid) {
        return regexResult.asMap().entries.map((e) =>
          SubGoal(stepNumber: e.key + 1, description: e.value.trim()),
        ).toList();
      }
    }

    // Tier 2: Verb-boundary detection
    final verbResult = _splitByVerbBoundaries(command);
    if (verbResult.length > 1) {
      return verbResult.asMap().entries.map((e) =>
        SubGoal(stepNumber: e.key + 1, description: e.value.trim()),
      ).toList();
    }

    // No decomposition needed (or Tier 3 LLM would be used on Android side)
    return [SubGoal(stepNumber: 1, description: command)];
  }

  List<String> _splitByConjunctions(String command) {
    for (final pattern in _conjunctionPatterns) {
      final regex = RegExp(pattern, caseSensitive: false);
      final parts = command.split(regex).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (parts.length > 1) return parts;
    }
    return [command];
  }

  List<String> _splitByVerbBoundaries(String command) {
    final words = command.split(RegExp(r'\s+'));
    if (words.length < 3) return [command];

    final boundaries = [0];
    for (int i = 1; i < words.length; i++) {
      final word = words[i].toLowerCase().replaceAll(RegExp(r'[,\.!?]$'), '');
      if (_actionVerbs.contains(word)) {
        final prev = words[i - 1].toLowerCase().replaceAll(RegExp(r'[,\.!?]$'), '');
        if (!_nonBoundaryPredecessors.contains(prev)) {
          boundaries.add(i);
        }
      }
    }

    if (boundaries.length <= 1) return [command];

    final fragments = <String>[];
    for (int j = 0; j < boundaries.length; j++) {
      final start = boundaries[j];
      final end = j + 1 < boundaries.length ? boundaries[j + 1] : words.length;
      final fragment = words.sublist(start, end).join(' ').trim();
      if (fragment.isNotEmpty) fragments.add(fragment);
    }
    return fragments;
  }

  bool _hasActionVerb(String text) {
    return text.toLowerCase().split(RegExp(r'\s+')).any((word) =>
      _actionVerbs.contains(word.replaceAll(RegExp(r'[,\.!?]$'), '')),
    );
  }
}
