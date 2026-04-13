/// The type of AI provider used for automation.
enum AiProviderType {
  /// Local Ollama instance — runs on user's machine, no internet needed.
  ollama,

  /// Cloud API with user-provided key (OpenAI, Gemini, Anthropic, Groq, etc.)
  apiKey,

  /// Legacy: delegates to browser extension which uses ChatGPT/Gemini websites.
  webBased,
}

extension AiProviderTypeX on AiProviderType {
  String get displayName {
    switch (this) {
      case AiProviderType.ollama:
        return 'Ollama (Local)';
      case AiProviderType.apiKey:
        return 'API Key (Cloud)';
      case AiProviderType.webBased:
        return 'Web-Based (Legacy)';
    }
  }

  String get description {
    switch (this) {
      case AiProviderType.ollama:
        return 'Run AI models locally — no internet required';
      case AiProviderType.apiKey:
        return 'Use OpenAI, Gemini, or any compatible API';
      case AiProviderType.webBased:
        return 'Use ChatGPT/Gemini websites via browser extension';
    }
  }

  String get storageName => name;
}
