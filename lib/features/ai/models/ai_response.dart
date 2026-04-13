/// Unified response from any AI provider.
class AiResponse {
  final bool success;
  final String? content;
  final String? error;
  final int? promptTokens;
  final int? completionTokens;
  final Duration? latency;

  const AiResponse({
    required this.success,
    this.content,
    this.error,
    this.promptTokens,
    this.completionTokens,
    this.latency,
  });

  factory AiResponse.success(String content,
      {int? promptTokens, int? completionTokens, Duration? latency}) {
    return AiResponse(
      success: true,
      content: content,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      latency: latency,
    );
  }

  factory AiResponse.failure(String error) {
    return AiResponse(success: false, error: error);
  }

  int? get totalTokens =>
      (promptTokens != null && completionTokens != null)
          ? promptTokens! + completionTokens!
          : null;
}
