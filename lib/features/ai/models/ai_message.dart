/// Role of a chat message.
enum AiMessageRole { system, user, assistant }

/// A single chat message for the AI conversation.
class AiMessage {
  final AiMessageRole role;
  final String content;
  final String? base64Image; // For vision-capable models

  const AiMessage({
    required this.role,
    required this.content,
    this.base64Image,
  });

  Map<String, dynamic> toOpenAiJson() {
    if (base64Image != null) {
      return {
        'role': role.name,
        'content': [
          {'type': 'text', 'text': content},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,$base64Image'},
          },
        ],
      };
    }
    return {'role': role.name, 'content': content};
  }

  Map<String, dynamic> toOllamaJson() {
    final msg = <String, dynamic>{'role': role.name, 'content': content};
    if (base64Image != null) {
      msg['images'] = [base64Image];
    }
    return msg;
  }
}
