import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../../core/services/logging_service.dart';
import '../models/ai_config.dart';
import '../models/ai_message.dart';
import '../models/ai_response.dart';
import 'ai_service.dart';

/// AI service using any OpenAI-compatible REST API.
///
/// Supports: OpenAI, Google Gemini API, Anthropic (via proxy),
///           Groq, Together, or any OpenAI-compatible endpoint.
class ApiKeyService extends AiService {
  final LoggingService _log;
  AiConfig _config;
  String? _apiKey;

  ApiKeyService({
    required LoggingService log,
    required AiConfig config,
    String? apiKey,
  })  : _log = log,
        _config = config,
        _apiKey = apiKey ?? config.apiKey;

  void updateConfig(AiConfig config, {String? apiKey}) {
    _config = config;
    if (apiKey != null) _apiKey = apiKey;
  }

  @override
  String get providerName => 'API (${_config.apiModel})';

  @override
  Future<AiResponse> chat(
    List<AiMessage> messages, {
    Map<String, dynamic>? jsonSchema,
  }) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      return AiResponse.failure('API key not configured');
    }

    final url = Uri.parse(_config.apiEndpoint);
    final body = <String, dynamic>{
      'model': _config.apiModel,
      'messages': messages.map((m) => m.toOpenAiJson()).toList(),
      'temperature': 0.1,
      'max_tokens': 512,
    };

    if (jsonSchema != null) {
      body['response_format'] = {
        'type': 'json_schema',
        'json_schema': {
          'name': 'action_response',
          'schema': jsonSchema,
          'strict': true,
        },
      };
    }

    final stopwatch = Stopwatch()..start();
    try {
      final response = await http
          .post(url,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $_apiKey',
              },
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 60));

      stopwatch.stop();

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final choices = json['choices'] as List<dynamic>?;
        final content = (choices?.first as Map<String, dynamic>?)?['message']
                ?['content'] as String? ?? '';
        final usage = json['usage'] as Map<String, dynamic>?;
        final promptTokens = usage?['prompt_tokens'] as int?;
        final completionTokens = usage?['completion_tokens'] as int?;

        _log.info('ApiKeyService', 'API response in ${stopwatch.elapsedMilliseconds}ms '
            '(prompt=$promptTokens, completion=$completionTokens)');

        return AiResponse.success(
          content,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          latency: stopwatch.elapsed,
        );
      } else {
        final errorMsg =
            'API error ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}';
        _log.error('ApiKeyService', errorMsg);
        return AiResponse.failure(errorMsg);
      }
    } catch (e) {
      stopwatch.stop();
      final errorMsg = 'API connection failed: $e';
      _log.error('ApiKeyService', errorMsg);
      return AiResponse.failure(errorMsg);
    }
  }

  @override
  Future<bool> isAvailable() async {
    if (_apiKey == null || _apiKey!.isEmpty) return false;

    // We can't easily validate all API providers with a "ping".
    // If we have a key configured, assume available.
    return true;
  }
}
