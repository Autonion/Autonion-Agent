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

  /// When true, the executor should preserve action history from prior
  /// sub-goals instead of clearing it. This gives the LLM continuity.
  final bool preserveHistory;

  const SubGoal({
    required this.stepNumber,
    required this.description,
    this.dependsOnPrevious = true,
    this.preserveHistory = true,
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
    r'\s+finally\s+',
    r';\s*',
    r',\s+then\s+',
    r',\s+and\s+',
    r',\s*(?=[a-z])',
  ];

  static const _actionVerbs = {
    'open', 'launch', 'start', 'run',
    'create', 'make', 'compose',
    'search', 'find', 'look', 'check',
    'go', 'navigate', 'switch',
    'click', 'tap', 'press', 'select', 'choose', 'pick',
    'type', 'write', 'enter', 'input',
    'delete', 'remove', 'clear', 'rename',
    'play', 'pause', 'stop', 'resume', 'record',
    'close', 'exit', 'quit', 'maximize', 'minimize', 'restore', 'resize',
    'save', 'download', 'upload',
    'send', 'share', 'forward', 'attach',
    'scroll', 'swipe', 'drag', 'drop',
    'enable', 'disable', 'turn', 'toggle', 'set', 'change',
    'copy', 'paste', 'cut', 'move',
    'take', 'capture', 'snap', 'grab',
    'show', 'hide', 'pin', 'lock', 'unlock',
    'undo', 'redo', 'refresh', 'zoom',
    'mute', 'unmute', 'use', 'put', 'draw',
  };

  static const _nonBoundaryPredecessors = {
    'to', 'and', 'or', 'the', 'a', 'an', 'then',
    'it', 'this', 'that', 'my', 'your', 'its',
    'via', 'using', 'with', 'from', 'into', 'in',
  };

  /// Words that indicate the following clause is a relative/subordinate clause
  /// and should NOT be treated as a new sub-goal boundary.
  static const _relativePrefixes = {
    'that', 'which', 'who', 'whom', 'whose', 'where', 'when',
    'what', 'how', 'if', 'whether', 'because', 'since', 'until',
    'while', 'before', 'after', 'unless', 'although',
  };

  /// Pronouns and references that indicate the sub-goal depends on a
  /// previous step's result (e.g., "type hello in **it**").
  static const _contextualReferences = {
    'it', 'its', 'them', 'there', 'here', 'that', 'this',
    'the same', 'above', 'below',
  };

  /// Decomposes a raw command into ordered, atomic sub-goals.
  ///
  /// For simple commands, returns a 1-item list.
  /// For compound commands, returns N ordered sub-goals.
  List<SubGoal> decompose(String rawCommand) {
    final command = rawCommand.trim();
    if (command.isEmpty) {
      return [SubGoal(stepNumber: 1, description: command)];
    }

    // Tier 1: Regex conjunction splitting
    final regexResult = _splitByConjunctions(command);
    if (regexResult.length > 1) {
      final allValid = regexResult.every(_hasActionVerb);
      if (allValid) {
        return _buildSubGoals(regexResult, command);
      }
    }

    // Tier 2: Verb-boundary detection
    final verbResult = _splitByVerbBoundaries(command);
    if (verbResult.length > 1) {
      return _buildSubGoals(verbResult, command);
    }

    // No decomposition needed (or Tier 3 LLM would be used on Android side)
    return [SubGoal(stepNumber: 1, description: command)];
  }

  /// Build SubGoal objects with dependency detection.
  List<SubGoal> _buildSubGoals(List<String> fragments, String originalGoal) {
    return fragments.asMap().entries.map((e) {
      final idx = e.key;
      final desc = e.value.trim();
      final dependsOnPrev = idx > 0 && _hasContextualReference(desc);
      return SubGoal(
        stepNumber: idx + 1,
        description: desc,
        dependsOnPrevious: idx > 0,
        // Always preserve history so sub-goals have continuity
        preserveHistory: true,
      );
    }).toList();
  }

  /// Check if a fragment references something from a prior step.
  bool _hasContextualReference(String text) {
    final lower = text.toLowerCase();
    return _contextualReferences.any((ref) {
      // Match whole word only (e.g., "it" not "item")
      return RegExp('\\b$ref\\b', caseSensitive: false).hasMatch(lower);
    });
  }

  List<String> _splitByConjunctions(String command) {
    final protected = _protectQuotedText(command);
    for (final pattern in _conjunctionPatterns) {
      final regex = RegExp(pattern, caseSensitive: false);
      final parts = protected.text
          .split(regex)
          .map(protected.restore)
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.length > 1) {
        // Validate: reject splits that created fragments starting with
        // relative clause words (e.g., "open the file" + "that I downloaded")
        final hasInvalidFragment = parts.skip(1).any((frag) {
          final firstWord = frag.split(RegExp(r'\s+')).first.toLowerCase()
              .replaceAll(RegExp(r'[,\.!?]$'), '');
          return _relativePrefixes.contains(firstWord);
        });
        if (hasInvalidFragment) continue; // Skip this pattern, try the next
        return parts;
      }
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
          // Guard: don't split if the preceding word is a relative pronoun
          // (e.g., "the file that **open**ed" — though rare in commands)
          if (!_relativePrefixes.contains(prev)) {
            boundaries.add(i);
          }
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

    // Reject splits where a fragment starts with a relative clause word
    final hasInvalidFragment = fragments.skip(1).any((frag) {
      final firstWord = frag.split(RegExp(r'\s+')).first.toLowerCase()
          .replaceAll(RegExp(r'[,\.!?]$'), '');
      return _relativePrefixes.contains(firstWord);
    });
    if (hasInvalidFragment) return [command];

    return fragments;
  }

  bool _hasActionVerb(String text) {
    return text.toLowerCase().split(RegExp(r'\s+')).any((word) =>
      _actionVerbs.contains(word.replaceAll(RegExp(r'[,\.!?]$'), '')),
    );
  }

  _ProtectedText _protectQuotedText(String text) {
    final spans = <String>[];
    final buffer = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final quote = text[i];
      if (quote != '"' && quote != "'") {
        buffer.write(quote);
        i++;
        continue;
      }

      final start = i;
      i++;
      while (i < text.length && text[i] != quote) {
        i++;
      }
      if (i < text.length) i++;

      final token = '__QUOTE_${spans.length}__';
      spans.add(text.substring(start, i));
      buffer.write(token);
    }

    return _ProtectedText(buffer.toString(), spans);
  }
}

class _ProtectedText {
  final String text;
  final List<String> spans;

  const _ProtectedText(this.text, this.spans);

  String restore(String value) {
    var restored = value;
    for (var i = 0; i < spans.length; i++) {
      restored = restored.replaceAll('__QUOTE_${i}__', spans[i]);
    }
    return restored;
  }
}
