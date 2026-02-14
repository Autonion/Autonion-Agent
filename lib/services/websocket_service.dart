import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:shelf/shelf.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'logging_service.dart';

class WebSocketService {
  HttpServer? _server;
  final List<WebSocketChannel> _clients = [];
  final StreamController<Map<String, dynamic>> _commandController = StreamController.broadcast();
  final StreamController<bool> _extensionConnectionController = StreamController.broadcast();
  LoggingService? _loggingService;
  bool _extensionConnected = false;
  WebSocketChannel? _extensionClient; // Track the specific extension client

  Stream<Map<String, dynamic>> get commandStream => _commandController.stream;
  /// Stream that emits true when the extension connects.
  Stream<bool> get extensionConnectionStream => _extensionConnectionController.stream;
  int get connectedClients => _clients.length;
  bool get hasExtensionClient => _extensionConnected;

  void setLoggingService(LoggingService loggingService) {
    _loggingService = loggingService;
  }

  void _log(String message) {
    final logMsg = '[WS] $message';
    print(logMsg);
    _loggingService?.log(logMsg);
  }

  // Function to broadcast events to all connected controllers (usually just one)
  void broadcastEvent(Map<String, dynamic> event) {
    final payload = jsonEncode(event);
    _log('Broadcasting to ${_clients.length} client(s): ${event['type'] ?? 'unknown'}');
    for (final client in _clients) {
      try {
        client.sink.add(payload);
      } catch (e) {
        _log('Error sending to client: $e');
      }
    }
  }

  Future<int> startServer() async {
    var wsHandler = webSocketHandler((WebSocketChannel webSocket, String? protocol) {
      _clients.add(webSocket);
      _log('Client connected! Total clients: ${_clients.length} (protocol: $protocol)');

      // Send connection acknowledgment immediately
      try {
        final ack = jsonEncode({
          'type': 'connection_ack',
          'status': 'connected',
          'agent': 'autonion',
          'timestamp': DateTime.now().toIso8601String(),
          'server_info': {
            'port': _server?.port,
            'clients': _clients.length,
          },
        });
        webSocket.sink.add(ack);
        _log('Sent connection_ack to new client');
      } catch (e) {
        _log('Error sending ack: $e');
      }

      webSocket.stream.listen((message) {
        _log('Received raw: $message');
        try {
          final data = jsonDecode(message);
          if (data is Map<String, dynamic>) {
            // Handle ping/pong for connection testing
            if (data['type'] == 'ping') {
              _log('Received ping, sending pong');
              try {
                webSocket.sink.add(jsonEncode({
                  'type': 'pong',
                  'timestamp': DateTime.now().toIso8601String(),
                }));
              } catch (e) {
                _log('Error sending pong: $e');
              }
              return;
            }
            // Track extension connection — identify THIS specific client
            if (data['source'] == 'extension' && !_extensionConnected) {
              _extensionConnected = true;
              _extensionClient = webSocket;
              _extensionConnectionController.add(true);
              _log('Extension client identified and tracked');
            }

            _commandController.add(data);
            _log('Command dispatched: ${data['type'] ?? data['action'] ?? 'unknown'}');
          } else {
            _log('Received non-map data, ignoring: ${data.runtimeType}');
          }
        } catch (e) {
          _log('Error decoding message: $e');
        }
      }, onDone: () {
        _clients.remove(webSocket);
        _log('Client disconnected. Remaining: ${_clients.length}');
        _onClientDisconnected(webSocket);
      }, onError: (error) {
        _clients.remove(webSocket);
        _log('Client error: $error. Remaining: ${_clients.length}');
        _onClientDisconnected(webSocket);
      });
    });

    // Handler to check paths
    Future<Response> handler(Request request) async {
      _log('HTTP request: ${request.method} /${request.url.path}');
      if (request.url.path == 'automation') {
        return await wsHandler(request);
      }
      // Return helpful message for wrong path
      final serverPort = _server?.port ?? '?';
      return Response.ok(
        'Autonion Agent is running.\n'
        'WebSocket endpoint: ws://<IP>:$serverPort/automation\n'
        'You requested: /${request.url.path}\n',
        headers: {'Content-Type': 'text/plain'},
      );
    }

    // Listen on any interface, port 4545 (Fixed for Firewall reliability)
    const int port = 4545;
    try {
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    } catch (e) {
      _log('Port $port busy, falling back to 0 (dynamic)');
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0);
    }

    // Log all available IPs for diagnostics
    _log('Server listening on 0.0.0.0:${_server!.port}');
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback) {
            _log('Reachable at: ws://${addr.address}:${_server!.port}/automation');
          }
        }
      }
    } catch (e) {
      _log('Could not list network interfaces: $e');
    }

    return _server!.port;
  }

  /// Check if the disconnected client was the extension client.
  void _onClientDisconnected(WebSocketChannel client) {
    if (_extensionConnected && identical(client, _extensionClient)) {
      _extensionConnected = false;
      _extensionClient = null;
      _extensionConnectionController.add(false);
      _log('Extension client disconnected — browser likely closed');
    }
  }

  Future<void> stopServer() async {
    _log('Stopping server (${_clients.length} clients connected)');
    for (final client in _clients) {
      try {
        client.sink.close();
      } catch (_) {}
    }
    _clients.clear();
    _extensionConnected = false;
    await _server?.close(force: true);
    _server = null;
    _log('Server stopped');
  }
}
