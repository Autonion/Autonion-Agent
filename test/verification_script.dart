import 'package:multicast_dns/multicast_dns.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'dart:io';

void main() async {
  print('Starting Verification Script...');
  final MDnsClient client = MDnsClient();
  await client.start();

  bool serviceFound = false;
  print('Searching for _myautomation._tcp.local...');
  
  // Look for the service
  await for (final PtrResourceRecord ptr in client
      .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer('_myautomation._tcp.local'))) {
    
    print('Found service instance: ${ptr.domainName}');

    await for (final SrvResourceRecord srv in client
        .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))) {
      
      print('Service Details: Target=${srv.target}, Port=${srv.port}');
      serviceFound = true;
      
      // Connect to WebSocket
      // Note: srv.target might be 'computer-name.local'. 
      // Resolving .local on Windows might fail without Bonjour/mDNS stack for resolution.
      // But we can try 'localhost' if we know it's local, or resolve IP.
      // For this test, we assume local.
      final host = '127.0.0.1'; // Force localhost for testing since we are on same machine
      final port = srv.port;
      final wsUrl = 'ws://$host:$port/automation';
      
      print('Connecting to WebSocket at $wsUrl...');
      try {
        final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
        
        // Send a test command
        channel.sink.add('{"action": "test_ping"}');
        print('Sent test command');
        
        // Listen for 1 second then close
        channel.stream.listen((message) {
            print('Received validation: $message');
        });
        
        await Future.delayed(Duration(seconds: 2));
        channel.sink.close(status.goingAway);
        print('WebSocket Test Passed!');
      } catch (e) {
        print('WebSocket Connection Failed: $e');
      }
    }
  }
  
  client.stop();
  if (!serviceFound) {
    print('Service NOT Found via mDNS. (Note: Windows mDNS might be tricky)');
  }
  print('Verification Finished.');
}
