/// Configures how the AI sees the desktop screen based on hardware capability.
enum AutomationTier {
  /// Sends ONLY the accessibility tree as JSON text (fastest, cheapest).
  accessibilityOnly,

  /// Sends the tree + a downscaled/grey screenshot (balanced).
  treeWithThumbnail,

  /// Sends the tree + full resolution screenshot (most accurate, highest resource usage).
  treeWithFullScreenshot,
}

extension AutomationTierX on AutomationTier {
  String get displayName {
    switch (this) {
      case AutomationTier.accessibilityOnly:
        return 'Accessibility Text Only';
      case AutomationTier.treeWithThumbnail:
        return 'Tree + Thumbnail';
      case AutomationTier.treeWithFullScreenshot:
        return 'Tree + Full Screenshot';
    }
  }

  String get description {
    switch (this) {
      case AutomationTier.accessibilityOnly:
        return 'Best for local LLMs and limited hardware. No images sent.';
      case AutomationTier.treeWithThumbnail:
        return 'Balanced setting. Sends a low-res image for context.';
      case AutomationTier.treeWithFullScreenshot:
        return 'Best for powerful cloud APIs (like GPT-4V). Maximum accuracy.';
    }
  }
}
