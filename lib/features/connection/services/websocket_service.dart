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

/// Tracks metadata and authentication state for a connected WebSocket client.
class ConnectedClient {
  final WebSocketChannel socket;
  final bool isLoopback;
  final String remoteIp;

  bool _isAuthenticated = false;
  bool _isExtension = false;
  bool _isPairingPending = false;
  Timer? _authTimeoutTimer;
  String? _deviceId;
  String? _deviceName;
  int _failedPinAttempts = 0;

  ConnectedClient({
    required this.socket,
    required this.isLoopback,
    required this.remoteIp,
  });

  bool get isAuthenticated => _isAuthenticated;
  bool get isExtension => _isExtension;
  bool get isPairingPending => _isPairingPending;
  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;
  int get failedPinAttempts => _failedPinAttempts;

  void markAuthenticated({required String deviceId, required String deviceName}) {
    _isAuthenticated = true;
    _isPairingPending = false;
    _authTimeoutTimer?.cancel();
    _deviceId = deviceId;
    _deviceName = deviceName;
    _failedPinAttempts = 0;
  }

  void markPairingPending() {
    _isPairingPending = true;
    _authTimeoutTimer?.cancel();
  }

  void startAuthTimeout(Duration duration, void Function() onTimeout) {
    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = Timer(duration, onTimeout);
  }

  void cancelAuthTimeout() {
    _authTimeoutTimer?.cancel();
  }

  void markAsExtension() {
    _isExtension = true;
    _isAuthenticated = true;
    _authTimeoutTimer?.cancel();
  }

  int incrementFailedPinAttempts() {
    _failedPinAttempts++;
    return _failedPinAttempts;
  }
}

/// Container for an incoming command from a specific client.
class WebSocketClientCommand {
  final WebSocketChannel client;
  final Map<String, dynamic> data;
  final ConnectedClient session;

  WebSocketClientCommand(this.client, this.data, this.session);
}

/// Manages the WebSocket server with loopback-verified extension access,
/// default-deny quarantine for unauthenticated LAN clients, and pairing support.
class WebSocketService extends ChangeNotifier {
  HttpServer? _server;
  final List<ConnectedClient> _sessions = [];
  final StreamController<WebSocketClientCommand> _commandController =
      StreamController.broadcast();
  final StreamController<bool> _extensionConnectionController =
      StreamController.broadcast();
  LoggingService? _loggingService;
  bool _extensionConnected = false;
  WebSocketChannel? _extensionClient;

  Stream<WebSocketClientCommand> get commandStream => _commandController.stream;
  Stream<bool> get extensionConnectionStream =>
      _extensionConnectionController.stream;

  int get connectedClients => _sessions.length;
  int get authenticatedClientsCount =>
      _sessions.where((s) => s.isAuthenticated && !s.isExtension).length;
  bool get hasExtensionClient => _extensionConnected;
  int? get activePort => _server?.port;
  bool get isRunning => _server != null;

  void setLoggingService(LoggingService loggingService) {
    _loggingService = loggingService;
  }

  void _log(String message) {
    _loggingService?.info('WS', message);
  }

  ConnectedClient? getClientSession(WebSocketChannel client) {
    try {
      return _sessions.firstWhere((s) => identical(s.socket, client));
    } catch (_) {
      return null;
    }
  }

  ConnectedClient? getSessionByDeviceId(String deviceId) {
    try {
      return _sessions.firstWhere((s) => s.deviceId == deviceId);
    } catch (_) {
      return null;
    }
  }

  void markClientAuthenticated(
    WebSocketChannel client, {
    required String deviceId,
    required String deviceName,
  }) {
    final session = getClientSession(client);
    if (session != null) {
      session.markAuthenticated(deviceId: deviceId, deviceName: deviceName);
      _log('Client authenticated: $deviceName ($deviceId) from ${session.remoteIp}');
      notifyListeners();
    }
  }

  int recordFailedPinAttempt(WebSocketChannel client) {
    final session = getClientSession(client);
    if (session == null) return 0;

    final attempts = session.incrementFailedPinAttempts();
    _log('Failed PIN attempt #$attempts from ${session.remoteIp}');
    if (attempts >= 3) {
      _log('Max PIN attempts reached, disconnecting ${session.remoteIp}');
      disconnectClient(
        client,
        code: 4003,
        reason: 'Too many failed pairing attempts',
      );
    }
    return attempts;
  }

  void disconnectClientByDeviceId(
    String deviceId, {
    int code = 4001,
    String reason = 'Pairing revoked',
  }) {
    final matching = _sessions.where((s) => s.deviceId == deviceId).toList();
    for (final session in matching) {
      _log('Severing connection for revoked device: $deviceId (${session.remoteIp})');
      disconnectClient(session.socket, code: code, reason: reason);
    }
  }

  void disconnectClient(
    WebSocketChannel client, {
    int code = 1000,
    String reason = 'Disconnected',
  }) {
    try {
      client.sink.close(code, reason);
    } catch (e) {
      _log('Error closing socket: $e');
    }
  }

  void sendToClient(WebSocketChannel client, Map<String, dynamic> event) {
    try {
      client.sink.add(jsonEncode(event));
    } catch (e) {
      _log('Error sending to client: $e');
    }
  }

  /// Broadcasts only to authenticated clients.
  void broadcastEvent(Map<String, dynamic> event) {
    final payload = jsonEncode(event);
    final authenticatedSessions =
        _sessions.where((s) => s.isAuthenticated).toList();

    _log(
      'Broadcasting to ${authenticatedSessions.length} authenticated client(s): ${event['type'] ?? 'unknown'}',
    );
    for (final session in authenticatedSessions) {
      try {
        session.socket.sink.add(payload);
      } catch (e) {
        _log('Error sending to client: $e');
      }
    }
  }

  /// Send event only to the verified extension client.
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
    // Top-level request handler captures connection metadata per request
    Future<Response> handler(Request request) async {
      if (request.url.path == 'automation') {
        final connInfo =
            request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
        final isLoopback = connInfo?.remoteAddress.isLoopback ?? false;
        final remoteIp = connInfo?.remoteAddress.address ?? 'unknown';

        final perRequestWsHandler = webSocketHandler((
          WebSocketChannel webSocket,
          String? protocol,
        ) {
          _handleNewConnection(
            webSocket,
            isLoopback: isLoopback,
            remoteIp: remoteIp,
          );
        });

        return await perRequestWsHandler(request);
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
        handler,
        InternetAddress.anyIPv4,
        AppConfig.defaultWebSocketPort,
      );
    } catch (e) {
      _log(
        'Port ${AppConfig.defaultWebSocketPort} busy, falling back to dynamic',
      );
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0);
    }

    _log('Server listening on 0.0.0.0:${_server!.port}');

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          if (!addr.isLoopback) {
            _log(
              'Reachable at: ws://${addr.address}:${_server!.port}${AppConfig.webSocketPath}',
            );
          }
        }
      }
    } catch (_) {}

    notifyListeners();
    return _server!.port;
  }

  void _handleNewConnection(
    WebSocketChannel webSocket, {
    required bool isLoopback,
    required String remoteIp,
  }) {
    final session = ConnectedClient(
      socket: webSocket,
      isLoopback: isLoopback,
      remoteIp: remoteIp,
    );
    _sessions.add(session);
    _log('Client connected from $remoteIp (loopback=$isLoopback)! Total sockets: ${_sessions.length}');
    notifyListeners();

    // Enforce 10s authentication window for LAN sockets
    if (!isLoopback) {
      session.startAuthTimeout(const Duration(seconds: 10), () {
        if (!session.isAuthenticated && !session.isPairingPending) {
          _log('Quarantine: Disconnecting unauthenticated socket from $remoteIp (auth timeout)');
          disconnectClient(
            webSocket,
            code: 4008,
            reason: 'Authentication timeout (no valid client_info received)',
          );
        }
      });
    }

    webSocket.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message);
          if (data is Map<String, dynamic>) {
            final type = data['type'] as String?;

            // 1. Keep-alive pings are always answered
            if (type == 'ping') {
              try {
                webSocket.sink.add(
                  jsonEncode({
                    'type': 'pong',
                    'timestamp': DateTime.now().toIso8601String(),
                  }),
                );
              } catch (e) {
                _log('Error sending pong: $e');
              }
              return;
            }

            // 2. Loopback-only browser extension auto-detection
            if (session.isLoopback &&
                data['source'] == 'extension' &&
                !_extensionConnected) {
              session.markAsExtension();
              _extensionConnected = true;
              _extensionClient = webSocket;
              _extensionConnectionController.add(true);
              _log('Extension client verified on loopback ($remoteIp) and tracked');
              notifyListeners();
            }

            // 3. Strict Default-Deny Allowlist for unauthenticated sockets
            const allowedUnauthTypes = {'client_info', 'pairing_submit'};
            if (!session.isAuthenticated && !allowedUnauthTypes.contains(type)) {
              _log('Quarantine: dropped unauthenticated "$type" from $remoteIp');
              return;
            }

            // 4. Forward allowed/authenticated commands
            _commandController.add(
              WebSocketClientCommand(webSocket, data, session),
            );
          }
        } catch (e) {
          _log('Error decoding message: $e');
        }
      },
      onDone: () {
        session.cancelAuthTimeout();
        _sessions.remove(session);
        _onClientDisconnected(webSocket);
        notifyListeners();
      },
      onError: (error) {
        session.cancelAuthTimeout();
        _sessions.remove(session);
        _onClientDisconnected(webSocket);
        notifyListeners();
      },
    );
  }

  void _onClientDisconnected(WebSocketChannel client) {
    if (_extensionConnected && identical(client, _extensionClient)) {
      _extensionConnected = false;
      _extensionClient = null;
      _extensionConnectionController.add(false);
      _log('Extension client disconnected');
    }
    _log('Client disconnected. Remaining sockets: ${_sessions.length}');
  }

  Future<void> stopServer() async {
    try {
      await _server?.close(force: true);
    } catch (e) {
      _log('Error closing server: $e');
    }
    _server = null;

    final snapshot = List.of(_sessions);
    _sessions.clear();
    for (final session in snapshot) {
      try {
        session.socket.sink.close();
      } catch (_) {}
    }

    _extensionConnected = false;
    _extensionClient = null;
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
