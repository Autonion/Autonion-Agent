import 'ai_provider_type.dart';

/// Configuration for a specific AI provider.
class AiConfig {
  final AiProviderType providerType;

  // ── Ollama ─────────────────────────────────────
  final String ollamaHost;
  final int ollamaPort;
  final String ollamaModel;

  // ── API Key ────────────────────────────────────
  final String? apiKey;
  final String apiEndpoint;
  final String apiModel;

  const AiConfig({
    required this.providerType,
    this.ollamaHost = 'localhost',
    this.ollamaPort = 11434,
    this.ollamaModel = 'llama3.2:latest',
    this.apiKey,
    this.apiEndpoint = 'https://api.openai.com/v1/chat/completions',
    this.apiModel = 'gpt-4o-mini',
  });

  /// Ollama base URL.
  String get ollamaBaseUrl => 'http://$ollamaHost:$ollamaPort';

  AiConfig copyWith({
    AiProviderType? providerType,
    String? ollamaHost,
    int? ollamaPort,
    String? ollamaModel,
    String? apiKey,
    String? apiEndpoint,
    String? apiModel,
  }) {
    return AiConfig(
      providerType: providerType ?? this.providerType,
      ollamaHost: ollamaHost ?? this.ollamaHost,
      ollamaPort: ollamaPort ?? this.ollamaPort,
      ollamaModel: ollamaModel ?? this.ollamaModel,
      apiKey: apiKey ?? this.apiKey,
      apiEndpoint: apiEndpoint ?? this.apiEndpoint,
      apiModel: apiModel ?? this.apiModel,
    );
  }

  Map<String, dynamic> toJson() => {
        'providerType': providerType.storageName,
        'ollamaHost': ollamaHost,
        'ollamaPort': ollamaPort,
        'ollamaModel': ollamaModel,
        'apiEndpoint': apiEndpoint,
        'apiModel': apiModel,
        // API key is NOT serialised — stored securely separately
      };

  factory AiConfig.fromJson(Map<String, dynamic> json) {
    final typeName = json['providerType'] as String? ?? 'webBased';
    final type = AiProviderType.values.firstWhere(
      (e) => e.storageName == typeName,
      orElse: () => AiProviderType.webBased,
    );
    return AiConfig(
      providerType: type,
      ollamaHost: json['ollamaHost'] as String? ?? 'localhost',
      ollamaPort: json['ollamaPort'] as int? ?? 11434,
      ollamaModel: json['ollamaModel'] as String? ?? 'llama3.2:latest',
      apiEndpoint: json['apiEndpoint'] as String? ??
          'https://api.openai.com/v1/chat/completions',
      apiModel: json['apiModel'] as String? ?? 'gpt-4o-mini',
    );
  }
}
