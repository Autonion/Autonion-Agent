import '../models/ai_message.dart';
import '../models/ai_response.dart';

/// Abstract interface for all AI providers.
///
/// Each provider (Ollama, API Key, Web-Based) implements this interface
/// so the agentic loop can be provider-agnostic.
abstract class AiService {
  /// Display name of this provider.
  String get providerName;

  /// Send a chat conversation and get a response.
  Future<AiResponse> chat(
    List<AiMessage> messages, {
    Map<String, dynamic>? jsonSchema,
  });

  /// Check whether this provider is currently reachable.
  Future<bool> isAvailable();

  /// List available models (for Ollama/API providers).
  /// Returns empty list if not applicable.
  Future<List<String>> listModels() async => [];

  /// Dispose any resources held by the service.
  void dispose() {}
}
