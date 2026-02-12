import 'websocket_service.dart';

class EventEmitter {
  final WebSocketService _webSocketService;

  EventEmitter(this._webSocketService);

  // Example method to simulate or trigger an event
  void sendEvent(String type, Map<String, dynamic> payload) {
    final event = {
      'type': type,
      'payload': payload,
      'timestamp': DateTime.now().toIso8601String(),
    };
    _webSocketService.broadcastEvent(event);
    print('EventEmitter: Sent $type - $payload');
  }

  // Set up listeners for platform events if applicable
  // e.g., clipboard listener could go here
}
