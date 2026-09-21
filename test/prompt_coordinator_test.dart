import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:autonion_cross_device/core/di/service_locator.dart';
import 'package:autonion_cross_device/core/services/logging_service.dart';
import 'package:autonion_cross_device/features/ai/providers/ai_provider_notifier.dart';
import 'package:autonion_cross_device/features/connection/providers/connection_provider.dart';
import 'package:autonion_cross_device/features/connection/services/websocket_service.dart';
import 'package:autonion_cross_device/features/connection/services/paired_device_service.dart';
import 'package:autonion_cross_device/features/connection/services/device_info_service.dart';
import 'package:autonion_cross_device/features/connection/services/discovery_service.dart';
import 'package:autonion_cross_device/features/triggers/services/trigger_rule_service.dart';
import 'package:autonion_cross_device/features/desktop_automation/providers/desktop_automation_provider.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/desktop_agent_service.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/python_bridge_service.dart';
import 'agent_execution_test.dart'
    show TestAiProvider, ScriptedAi, TestInput, TestObservation;
import 'connection_recovery_test.dart' show QuietBrowser, QuietClipboard, until;

class TestSocket implements WebSocketChannel {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ReadyBridge extends PythonBridgeService {
  ReadyBridge() : super(log: LoggingService());
  @override
  bool get isReady => true;
  @override
  Future<void> init() async {}
  @override
  Future<void> stop() async {}
}

class GatedInput extends TestInput {
  Completer<void>? gate;
  GatedInput(super.bridge);
  @override
  Future<Map<String, dynamic>> openApp(String name) async {
    final blocked = gate;
    gate = null;
    final result = await super.openApp(name);
    if (blocked != null) await blocked.future;
    return result;
  }
}

class QuietDiscovery extends DiscoveryService {
  QuietDiscovery() : super(DeviceInfoService());
  @override
  Future<void> startAdvertising(int port) async {}
  @override
  Future<void> stopAdvertising() async {}
}

class CoordinatorSocket extends WebSocketService {
  final commands = StreamController<WebSocketClientCommand>.broadcast();
  final replies = <WebSocketChannel, List<Map<String, dynamic>>>{};
  final extensionMessages = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic>)? onExtension;
  @override
  Stream<WebSocketClientCommand> get commandStream => commands.stream;
  @override
  bool get hasExtensionClient => true;
  @override
  Future<int> startServer() async => 12345;
  @override
  Future<void> stopServer() async {}
  @override
  void sendToClient(WebSocketChannel client, Map<String, dynamic> event) {
    replies.putIfAbsent(client, () => []).add(event);
  }

  @override
  void sendToExtension(Map<String, dynamic> event) {
    extensionMessages.add(event);
    onExtension?.call(event);
  }

  void receive(ConnectedClient session, Map<String, dynamic> message) {
    commands.add(WebSocketClientCommand(session.socket, message, session));
  }

  List<Map<String, dynamic>> outcomes(ConnectedClient session, String id) =>
      (replies[session.socket] ?? [])
          .where(
            (r) =>
                r['transactionId'] == id &&
                {'completed', 'failed', 'cancelled'}.contains(r['status']),
          )
          .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoordinatorSocket ws;
  late GatedInput input;
  late ConnectionProvider provider;
  late ScriptedAi ai;
  late TestAiProvider notifier;
  late ConnectedClient a, b, extension;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await getIt.reset();
    ws = CoordinatorSocket();
    final bridge = ReadyBridge();
    input = GatedInput(bridge);
    ai = ScriptedAi([]);
    notifier = TestAiProvider(ai);
    getIt.registerSingleton<AiProviderNotifier>(notifier);
    getIt.registerSingleton<DesktopAutomationProvider>(
      DesktopAutomationProvider(
        log: LoggingService(),
        bridge: bridge,
        agent: DesktopAgentService(
          log: LoggingService(),
          aiProvider: notifier,
          a11y: TestObservation(bridge),
          input: input,
        ),
      ),
    );
    ConnectedClient client(String owner) => ConnectedClient(
      socket: TestSocket(),
      isLoopback: true,
      remoteIp: '127.0.0.1',
    )..markAuthenticated(deviceId: owner, deviceName: owner);
    a = client('a');
    b = client('b');
    extension = client('extension')..markAsExtension();
    provider = ConnectionProvider(
      loggingService: LoggingService(),
      webSocketService: ws,
      discoveryService: QuietDiscovery(),
      deviceInfoService: DeviceInfoService(),
      browserLauncherService: QuietBrowser(),
      clipboardSyncService: QuietClipboard(),
      triggerRuleService: TriggerRuleService(),
      pairedDeviceService: PairedDeviceService(log: LoggingService()),
    );
    await provider.startServices();
  });
  tearDown(() async {
    await provider.stopServices();
    await ws.commands.close();
    provider.dispose();
    await getIt.reset();
  });

  test(
    'same request id is scoped to its device and replay does not execute twice',
    () async {
      ws.receive(a, {'prompt': 'open ChatGPT app', 'transactionId': 'same'});
      await until(() => ws.outcomes(a, 'same').isNotEmpty);
      ws.receive(b, {'prompt': 'open Paint app', 'transactionId': 'same'});
      await until(() => ws.outcomes(b, 'same').isNotEmpty);
      ws.receive(a, {'prompt': 'open ChatGPT app', 'transactionId': 'same'});
      await until(() => ws.outcomes(a, 'same').length == 2);
      expect(input.opened, ['ChatGPT', 'Paint']);
      expect(ws.outcomes(a, 'same').map((e) => e['status']), [
        'completed',
        'completed',
      ]);
      expect(notifier.starts, 0);
    },
  );

  test(
    'correction cancels old launch, runs next goal, and discards late success',
    () async {
      final gate = Completer<void>();
      input.gate = gate;
      ws.receive(a, {'prompt': 'open ChatGPT app', 'transactionId': 'old'});
      await until(() => input.opened.length == 1);
      final oldRun = ws.extensionMessages.length;
      ws.receive(a, {
        'prompt': 'I asked to open the app not the website',
        'transactionId': 'new',
      });
      await until(() => ws.outcomes(a, 'new').isNotEmpty);
      expect(ws.outcomes(a, 'old').single['status'], 'cancelled');
      expect(ws.outcomes(a, 'new').single['status'], 'completed');
      expect(input.opened, ['ChatGPT', 'ChatGPT']);
      expect(
        ws.extensionMessages
            .skip(oldRun)
            .any((m) => m['type'] == 'cancel_agent_run'),
        isTrue,
      );
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ws.outcomes(a, 'old').length, 1);
    },
  );

  test('stopping services cancels both running and queued requests', () async {
    final gate = Completer<void>();
    input.gate = gate;
    ws.receive(a, {'prompt': 'open ChatGPT app', 'transactionId': 'running'});
    await until(() => input.opened.length == 1);
    ws.receive(b, {'prompt': 'open Paint app', 'transactionId': 'queued'});
    await until(() => (ws.replies[b.socket] ?? []).isNotEmpty);
    await provider.stopServices();
    await until(
      () =>
          ws.outcomes(a, 'running').isNotEmpty &&
          ws.outcomes(b, 'queued').isNotEmpty,
    );
    gate.complete();
    expect(input.opened, ['ChatGPT']);
    expect(ws.outcomes(a, 'running').single['status'], 'cancelled');
    expect(ws.outcomes(b, 'queued').single['status'], 'cancelled');
  });

  test(
    'browser requires fresh observations and matching step replies before completion',
    () async {
      ai.replies.addAll([
        '{"action":{"action":"click_element","params":{"target_id":"el_1"}},"done":false}',
        '{"action":null,"done":true}',
        '{"achieved":true,"evidence":"Requested document is open"}',
      ]);
      final captures = <String>[];
      ws.onExtension = (message) {
        final p = message['payload'] as Map?;
        if (message['type'] == 'capture_dom') {
          captures.add(p!['transaction_id'] as String);
          ws.receive(extension, {
            'type': 'dom_snapshot',
            'source': 'extension',
            'transaction_id': p['transaction_id'],
            'status': 'success',
            'tab_id': 7,
            'snapshot': {
              'snapshotId': 's${captures.length}',
              'url': 'https://example.test',
              'readyState': 'complete',
              'text': 'Requested document is open',
              'elements': [],
            },
          });
        } else if (message['type'] == 'execute_single_step') {
          expect(p!['snapshot_id'], 's1');
          expect(p['tab_id'], 7);
          // Neither a legacy completion nor a stale step error may settle this run.
          ws.receive(extension, {
            'type': 'execution_result',
            'source': 'extension',
            'transaction_id': p['run_id'],
            'status': 'success',
          });
          ws.receive(extension, {
            'type': 'step_result',
            'source': 'extension',
            'transaction_id': p['run_id'],
            'step_index': -1,
            'status': 'cancelled',
          });
          ws.receive(extension, {
            'type': 'step_result',
            'source': 'extension',
            'transaction_id': p['run_id'],
            'step_index': p['step_index'],
            'status': 'executed',
            'tab_id': 7,
          });
        }
      };
      ws.receive(a, {
        'prompt': 'open the example website',
        'transactionId': 'browser',
      });
      await until(() => ws.outcomes(a, 'browser').isNotEmpty);
      expect(ws.outcomes(a, 'browser').single['status'], 'completed');
      expect(ai.calls, 3);
      expect(captures.toSet().length, 3);
    },
  );
}
