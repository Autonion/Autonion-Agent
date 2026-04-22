import '../../../core/services/logging_service.dart';
import '../models/ai_message.dart';
import '../models/ai_response.dart';
import 'ai_service.dart';

/// Legacy AI service wrapping the browser extension approach.
///
/// This delegates work to the Autonion browser extension which opens
/// ChatGPT / Gemini websites and interacts with them via DOM injection.
/// It is kept for backward compatibility but is the least efficient option.
class WebAiService extends AiService {
  final LoggingService _log;

  WebAiService({required LoggingService log}) : _log = log;

  @override
  String get providerName => 'Web-Based (Legacy)';

  @override
  Future<AiResponse> chat(
    List<AiMessage> messages, {
    Map<String, dynamic>? jsonSchema,
  }) async {
    // The web-based mode doesn't support direct chat.
    // It works through the extension bridge → browser page flow.
    // This method is a stub — the actual flow is driven by the
    // WebSocket connection to the browser extension.
    _log.warn(
      'WebAiService',
      'WebAiService.chat() called — this mode works via browser extension, not direct API',
    );
    return AiResponse.failure(
      'Web-based mode works through the browser extension. '
      'Switch to Ollama or API Key for direct AI access.',
    );
  }

  @override
  Future<bool> isAvailable() async {
    // Available if the extension bridge has connected clients.
    // For now, always return true since it relies on external state.
    return true;
  }
}
