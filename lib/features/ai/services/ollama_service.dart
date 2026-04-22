import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../../core/services/logging_service.dart';
import '../models/ai_config.dart';
import '../models/ai_message.dart';
import '../models/ai_response.dart';
import 'ai_service.dart';

/// AI service connecting to a local Ollama instance via REST API.
///
/// Default: http://localhost:11434/api/chat
/// Supports vision models (images sent as base64 in messages).
class OllamaService extends AiService {
  final LoggingService _log;
  AiConfig _config;

  OllamaService({required LoggingService log, required AiConfig config})
    : _log = log,
      _config = config;

  void updateConfig(AiConfig config) => _config = config;

  @override
  String get providerName => 'Ollama (${_config.ollamaModel})';

  @override
  Future<AiResponse> chat(
    List<AiMessage> messages, {
    Map<String, dynamic>? jsonSchema,
  }) async {
    final url = Uri.parse('${_config.ollamaBaseUrl}/api/chat');
    final body = <String, dynamic>{
      'model': _config.ollamaModel,
      'messages': messages.map((m) => m.toOllamaJson()).toList(),
      'stream': false,
      'options': {'temperature': 0.1, 'num_predict': 512},
    };

    // Structured JSON output via Ollama's `format` parameter
    if (jsonSchema != null) {
      body['format'] = jsonSchema;
    }

    final stopwatch = Stopwatch()..start();
    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 120));

      stopwatch.stop();

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final message = json['message'] as Map<String, dynamic>?;
        final content = message?['content'] as String? ?? '';
        final evalCount = json['eval_count'] as int?;
        final promptEvalCount = json['prompt_eval_count'] as int?;

        _log.info(
          'OllamaService',
          'Ollama response in ${stopwatch.elapsedMilliseconds}ms '
              '(prompt=$promptEvalCount, eval=$evalCount)',
        );

        return AiResponse.success(
          content,
          promptTokens: promptEvalCount,
          completionTokens: evalCount,
          latency: stopwatch.elapsed,
        );
      } else {
        final errorMsg =
            'Ollama error ${response.statusCode}: ${response.body}';
        _log.error('OllamaService', errorMsg);
        return AiResponse.failure(errorMsg);
      }
    } catch (e) {
      stopwatch.stop();
      final errorMsg = 'Ollama connection failed: $e';
      _log.error('OllamaService', errorMsg);
      return AiResponse.failure(errorMsg);
    }
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final url = Uri.parse('${_config.ollamaBaseUrl}/api/tags');
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<String>> listModels() async {
    try {
      final url = Uri.parse('${_config.ollamaBaseUrl}/api/tags');
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final models =
            (json['models'] as List<dynamic>?)
                ?.map((m) => (m as Map<String, dynamic>)['name'] as String)
                .toList() ??
            [];
        return models;
      }
    } catch (e) {
      _log.error('OllamaService', 'Failed to list Ollama models: $e');
    }
    return [];
  }
}
