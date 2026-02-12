import 'package:url_launcher/url_launcher.dart';

class CommandExecutor {
  Future<void> execute(Map<String, dynamic> command) async {
    // Android client sends: { "type": "...", "payload": { ... } }
    // Original design: { "action": "...", ... }
    
    String? action = command['action'];
    Map<String, dynamic>? payload;

    if (command.containsKey('type')) {
      final type = command['type'] as String;
      payload = command['payload'] as Map<String, dynamic>?;
      
      // Map event types to actions if needed, or handle directly
      if (type == 'open_url') {
        action = 'open_url';
        // Payload might contain 'url'
      } else if (type == 'clipboard.text_copied') {
        // Just log for now, or maybe this is an event FROM Android?
        print('CommandExecutor: Received clipboard event: $payload');
        return;
      }
    }

    // Fallback for flat structure or standard action
    final urlString = payload?['url'] ?? command['url'];

    switch (action) {
      case 'open_url':
        if (urlString != null) {
          final uri = Uri.parse(urlString);
          if (await canLaunchUrl(uri)) {
             await launchUrl(uri);
             print('CommandExecutor: Launched $urlString');
          } else {
            print('CommandExecutor: Could not launch $urlString');
          }
        }
        break;
      // Add other commands here
      default:
        print('CommandExecutor: Unknown action $action or type ${command['type']}');
    }
  }
}
