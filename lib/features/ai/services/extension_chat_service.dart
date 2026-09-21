import '../models/ai_message.dart';
import '../models/ai_response.dart';
import 'ai_service.dart';

/// Uses the configured browser chatbot for reasoning only. Actions still pass
/// through the same observed, validated execution loop as API-backed models.
class ExtensionChatService extends AiService {
  final Future<String> Function(List<AiMessage>, Map<String, dynamic>?) request;
  ExtensionChatService(this.request);
  @override
  String get providerName => 'Browser chatbot';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<AiResponse> chat(
    List<AiMessage> messages, {
    Map<String, dynamic>? jsonSchema,
  }) async {
    if (messages.any((message) => message.base64Image != null)) {
      return AiResponse.failure(
        'The browser chatbot bridge supports text observations only. Select an image-capable API model for visual desktop tasks.',
      );
    }
    return AiResponse.success(await request(messages, jsonSchema));
  }
}
