import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../../core/config/app_config.dart';
import '../../../core/services/logging_service.dart';

/// Manages the WebSocket server that bridges Android, browser extension,
/// and (in the future) desktop automation clients.
class WebSocketService extends ChangeNotifier {
  HttpServer? _server;
  final List<WebSocketChannel> _clients = [];
  final StreamController<Map<String, dynamic>> _commandController =
      StreamController.broadcast();
  final StreamController<bool> _extensionConnectionController =
      StreamController.broadcast();
  LoggingService? _loggingService;
  bool _extensionConnected = false;
  WebSocketChannel? _extensionClient;

  Stream<Map<String, dynamic>> get commandStream => _commandController.stream;
  Stream<bool> get extensionConnectionStream =>
      _extensionConnectionController.stream;
  int get connectedClients => _clients.length;
  bool get hasExtensionClient => _extensionConnected;
  int? get activePort => _server?.port;
  bool get isRunning => _server != null;

  void setLoggingService(LoggingService loggingService) {
    _loggingService = loggingService;
  }

  void _log(String message) {
    _loggingService?.info('WS', message);
  }

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

  /// Send event only to the extension client.
  void sendToExtension(Map<String, dynamic> event) {
    if (_extensionClient == null) {
      _log('No extension client connected');
      return;
    }
    try {
      _extensionClient!.sink.add(jsonEncode(event));
    } catch (e) {
      _log('Error sending to extension: $e');
    }
  }

  Future<int> startServer() async {
    var wsHandler = webSocketHandler(
        (WebSocketChannel webSocket, String? protocol) {
      _clients.add(webSocket);
      _log('Client connected! Total clients: ${_clients.length}');
      notifyListeners();

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
      } catch (e) {
        _log('Error sending ack: $e');
      }

      webSocket.stream.listen((message) {
        try {
          final data = jsonDecode(message);
          if (data is Map<String, dynamic>) {
            if (data['type'] == 'ping') {
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
            if (data['source'] == 'extension' && !_extensionConnected) {
              _extensionConnected = true;
              _extensionClient = webSocket;
              _extensionConnectionController.add(true);
              _log('Extension client identified and tracked');
              notifyListeners();
            }
            _commandController.add(data);
          }
        } catch (e) {
          _log('Error decoding message: $e');
        }
      }, onDone: () {
        _clients.remove(webSocket);
        _onClientDisconnected(webSocket);
        notifyListeners();
      }, onError: (error) {
        _clients.remove(webSocket);
        _onClientDisconnected(webSocket);
        notifyListeners();
      });
    });

    Future<Response> handler(Request request) async {
      if (request.url.path == 'automation') {
        return await wsHandler(request);
      }
      final serverPort = _server?.port ?? '?';
      return Response.ok(
        'Autonion Agent is running.\n'
        'WebSocket endpoint: ws://<IP>:$serverPort${AppConfig.webSocketPath}\n',
        headers: {'Content-Type': 'text/plain'},
      );
    }

    try {
      _server = await shelf_io.serve(
          handler, InternetAddress.anyIPv4, AppConfig.defaultWebSocketPort);
    } catch (e) {
      _log('Port ${AppConfig.defaultWebSocketPort} busy, falling back to dynamic');
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0);
    }

    _log('Server listening on 0.0.0.0:${_server!.port}');

    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          if (!addr.isLoopback) {
            _log('Reachable at: ws://${addr.address}:${_server!.port}${AppConfig.webSocketPath}');
          }
        }
      }
    } catch (_) {}

    notifyListeners();
    return _server!.port;
  }

  void _onClientDisconnected(WebSocketChannel client) {
    if (_extensionConnected && identical(client, _extensionClient)) {
      _extensionConnected = false;
      _extensionClient = null;
      _extensionConnectionController.add(false);
      _log('Extension client disconnected');
    }
    _log('Client disconnected. Remaining: ${_clients.length}');
  }

  Future<void> stopServer() async {
    for (final client in _clients) {
      try {
        client.sink.close();
      } catch (_) {}
    }
    _clients.clear();
    _extensionConnected = false;
    _extensionClient = null;
    await _server?.close(force: true);
    _server = null;
    _log('Server stopped');
    notifyListeners();
  }

  @override
  void dispose() {
    stopServer();
    _commandController.close();
    _extensionConnectionController.close();
    super.dispose();
  }
}
