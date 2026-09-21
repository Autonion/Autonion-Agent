enum TaskSurface { desktop, browser }

/// Constraints come from the user's words/transport, never from a tool result.
class TaskIntent {
  final String goal;
  final TaskSurface? surface;
  final String? appName;
  final bool isCorrection;

  const TaskIntent({
    required this.goal,
    this.surface,
    this.appName,
    this.isCorrection = false,
  });

  bool get allowsBrowser => surface != TaskSurface.desktop;

  static TaskIntent resolve(
    String request, {
    String? target,
    TaskIntent? previous,
  }) {
    final text = request.trim();
    final lower = text.toLowerCase();
    final noBrowser = RegExp(
      r"\b(?:not|never|without|instead of|rather than|don't|do not)\s+(?:open\s+|use\s+|opening\s+|using\s+)?(?:the\s+|a\s+)?(?:website|web\s*(?:site|app)|browser)\b",
    ).hasMatch(lower);
    final noNative = RegExp(
      r'\b(?:not|instead of|rather than)\s+(?:the\s+)?(?:(?:desktop|native|installed|windows)\s+)?app\b',
    ).hasMatch(lower);
    final correction =
        noBrowser ||
        noNative ||
        RegExp(
          r'^(?:i (?:asked|meant)|no[, ]|actually\b|the .+ app[.!]?$)',
        ).hasMatch(lower);
    final explicitlyNative =
        noBrowser ||
        RegExp(
          r'\b(?:installed|native|desktop|windows)\s+(?:\w+\s+){0,3}(?:app|application|program)\b',
        ).hasMatch(lower);
    final explicitlyWeb =
        !noBrowser &&
        (noNative ||
            RegExp(
              r'\b(?:website|web app|web version|in (?:the |my )?browser)\b|https?://',
            ).hasMatch(lower));

    var app = launchAppName(text);
    if (explicitlyWeb && app == null) {
      app = launchAppName(
        text.replaceFirst(
          RegExp(
            r'\s+(?:website|web version)(?:\s+in the browser)?[.!]?$',
            caseSensitive: false,
          ),
          '',
        ),
      );
    }
    // A correction such as "the app, not the website" refers to the last
    // resolved entity. Never carry an entity over to an unrelated new request.
    final refersToPreviousApp = RegExp(
      r"^(?:(?:i (?:asked|meant) (?:you )?to|no,?|actually)\s+)?(?:(?:open|launch|use)\s+)?(?:the|that|same)\s+(?:app|application|website)(?:[, ]+(?:not|instead of|rather than)\s+(?:the\s+)?(?:app|application|website|browser))?[.!]?$",
      caseSensitive: false,
    ).hasMatch(text);
    if (correction &&
        refersToPreviousApp &&
        app == null &&
        previous?.appName != null) {
      app = previous!.appName;
    }
    final surface = noBrowser || explicitlyNative
        ? TaskSurface.desktop
        : explicitlyWeb
        ? TaskSurface.browser
        : target == 'desktop'
        ? TaskSurface.desktop
        : target == 'browser'
        ? TaskSurface.browser
        : app != null
        ? TaskSurface.desktop
        : null;
    final goal = correction && app != null
        ? (surface == TaskSurface.browser
              ? 'Open the $app website in the browser.'
              : 'Open the installed $app application.')
        : text;
    return TaskIntent(
      goal: goal,
      surface: surface,
      appName: app,
      isCorrection: correction,
    );
  }

  /// Only a single app-opening request can bypass the general agent loop.
  static String? launchAppName(String request) {
    var text = request.trim().replaceAll(RegExp(r'[.!]+$'), '');
    text = text.replaceFirst(RegExp(r'^please\s+', caseSensitive: false), '');
    text = text.replaceFirst(
      RegExp(r'^i (?:asked|meant) (?:you )?to\s+', caseSensitive: false),
      '',
    );
    text = text
        .split(
          RegExp(
            r"[, ]+(?:not|instead of|rather than|don't|do not)\b",
            caseSensitive: false,
          ),
        )
        .first;
    final verb = RegExp(
      r'^(?:open|launch|start|focus|switch to)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    final fragment = RegExp(
      r'^(?:the\s+)?(.+?)\s+(?:app|application)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (verb == null && fragment == null) return null;
    var name = (verb?.group(1) ?? fragment!.group(1)!).trim();
    name = name.replaceFirst(
      RegExp(
        r'^(?:the\s+)?(?:(?:installed|native|desktop|windows)\s+)*',
        caseSensitive: false,
      ),
      '',
    );
    name = name
        .replaceFirst(
          RegExp(
            r'\s+(?:(?:desktop|windows|native)\s+)?(?:app|application|program)$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    if (name.isEmpty ||
        RegExp(
          r'[/\\:]|\.(?:com|org|net|exe|txt|pdf|docx?|xlsx?|pptx?)\b|\b(?:app|application|program|website|web|file|folder|document|presentation|slideshow|report|my|this|that|it|and|then|with|in|on)\b',
          caseSensitive: false,
        ).hasMatch(name)) {
      return null;
    }
    return name;
  }
}
