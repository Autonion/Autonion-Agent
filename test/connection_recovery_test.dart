import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// The storage package exposes its platform test double through this interface.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nsd/nsd.dart';
import 'package:autonion_cross_device/core/services/logging_service.dart';
import 'package:autonion_cross_device/features/connection/models/paired_device.dart';
import 'package:autonion_cross_device/features/connection/services/paired_device_service.dart';
import 'package:autonion_cross_device/features/connection/services/websocket_service.dart';
import 'package:autonion_cross_device/features/connection/services/device_info_service.dart';
import 'package:autonion_cross_device/features/connection/services/discovery_service.dart';
import 'package:autonion_cross_device/features/connection/providers/connection_provider.dart';
import 'package:autonion_cross_device/features/browser_automation/services/browser_launcher_service.dart';
import 'package:autonion_cross_device/features/clipboard/services/clipboard_sync_service.dart';
import 'package:autonion_cross_device/features/triggers/services/trigger_rule_service.dart';

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition did not become true');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

PairedDevice phone(String id) => PairedDevice(
  id: id,
  name: 'Google Pixel 8',
  secret: 'secret-$id',
  pairedAt: DateTime.now(),
  lastSeen: DateTime.now(),
);

class QuietBrowser extends BrowserLauncherService {
  @override
  Future<void> detectBrowsers() async {}
}

class QuietClipboard extends ClipboardSyncService {
  @override
  void startPolling() {}
  @override
  void stopPolling() {}
}

class DelayedDiscovery extends DiscoveryService {
  final gate = Completer<void>();
  DelayedDiscovery(super.info);
  @override
  Future<void> startAdvertising(int port) => gate.future;
  @override
  Future<void> stopAdvertising() async {}
}

class DelayedStorage extends TestFlutterSecureStoragePlatform {
  DelayedStorage() : super({});
  Completer<void>? nextWrite;
  bool writeStarted = false;
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    final gate = nextWrite;
    nextWrite = null;
    if (gate != null) {
      writeStarted = true;
      await gate.future;
    }
    await super.write(key: key, value: value, options: options);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'same model phones keep independent pairings, including after reload',
    () async {
      final service = PairedDeviceService(log: LoggingService());
      await service.pairDevice(phone('a'));
      await service.pairDevice(phone('b'));
      final reloaded = PairedDeviceService(log: LoggingService());
      expect(await reloaded.isDevicePaired('a', 'secret-a'), isTrue);
      expect(await reloaded.isDevicePaired('b', 'secret-b'), isTrue);
      await reloaded.revokeDevice('a');
      expect(await reloaded.isDevicePaired('a', 'secret-a'), isFalse);
      expect(await reloaded.isDevicePaired('b', 'secret-b'), isTrue);
      service.dispose();
      reloaded.dispose();
    },
  );

  test(
    'revocation replaces a snapshot already in flight to the helper',
    () async {
      final snapshots = <List<String>>[];
      final inFlight = Completer<bool>();
      final service = PairedDeviceService(
        log: LoggingService(),
        syncTrust: (devices) async {
          snapshots.add(devices.map((d) => d.id).toList());
          if (devices.isNotEmpty) return inFlight.future;
          return true;
        },
      );
      await service.init();
      await service.pairDevice(phone('a'));
      await until(() => snapshots.any((s) => s.contains('a')));
      final revoked = service.revokeDevice('a');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      inFlight.complete(true);
      await revoked;
      expect(snapshots.last, isEmpty);
      expect(await service.isDevicePaired('a', 'secret-a'), isFalse);
      service.dispose();
    },
  );

  test(
    'a delayed last-seen save cannot restore a revoked device after restart',
    () async {
      final storage = DelayedStorage();
      FlutterSecureStoragePlatform.instance = storage;
      final service = PairedDeviceService(log: LoggingService());
      await service.pairDevice(phone('a'));
      final gate = Completer<void>();
      storage.nextWrite = gate;
      final updating = service.updateLastSeen('a', '192.0.2.1');
      await until(() => storage.writeStarted);
      final revoking = service.revokeDevice('a');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.complete();
      await Future.wait([updating, revoking]);
      final reloaded = PairedDeviceService(log: LoggingService());
      expect(await reloaded.isDevicePaired('a', 'secret-a'), isFalse);
      service.dispose();
      reloaded.dispose();
    },
  );

  test(
    'a fresh authenticated socket retires the old socket exactly once',
    () async {
      final ws = WebSocketService();
      final commands = <WebSocketClientCommand>[];
      final sub = ws.commandStream.listen(commands.add);
      final port = await ws.startServer();
      final a = await WebSocket.connect('ws://127.0.0.1:$port/automation');
      final aSub = a.listen((_) {});
      a.add(jsonEncode({'type': 'client_info'}));
      await until(() => commands.length == 1);
      ws.markClientAuthenticated(
        commands[0].client,
        deviceId: 'a',
        deviceName: 'Phone',
      );
      final b = await WebSocket.connect('ws://127.0.0.1:$port/automation');
      final bSub = b.listen((_) {});
      b.add(jsonEncode({'type': 'client_info'}));
      await until(() => commands.length == 2);
      ws.markClientAuthenticated(
        commands[1].client,
        deviceId: 'a',
        deviceName: 'Phone',
      );
      expect(ws.authenticatedClientsCount, 1);
      await a.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ws.getSessionByDeviceId('a')?.socket, same(commands[1].client));
      await b.close();
      await aSub.cancel();
      await bSub.cancel();
      await ws.stopServer();
      await sub.cancel();
      ws.dispose();
    },
  );

  test('concurrent server starts share one listener', () async {
    final ws = WebSocketService();
    final ports = await Future.wait([ws.startServer(), ws.startServer()]);
    expect(ports[0], ports[1]);
    await ws.stopServer();
    expect(ws.isRunning, isFalse);
    ws.dispose();
  });

  test(
    'startup consumes identity while advertising is still pending',
    () async {
      final log = LoggingService();
      final ws = WebSocketService();
      final paired = PairedDeviceService(log: log);
      await paired.pairDevice(phone('a'));
      final info = DeviceInfoService();
      final discovery = DelayedDiscovery(info);
      final clipboard = QuietClipboard();
      final browser = QuietBrowser();
      final triggers = TriggerRuleService();
      final provider = ConnectionProvider(
        loggingService: log,
        webSocketService: ws,
        discoveryService: discovery,
        deviceInfoService: info,
        browserLauncherService: browser,
        clipboardSyncService: clipboard,
        triggerRuleService: triggers,
        pairedDeviceService: paired,
      );
      final starting = provider.startServices();
      await until(() => ws.activePort != null);
      final client = await WebSocket.connect(
        'ws://127.0.0.1:${ws.activePort}/automation',
      );
      final auth = client.first.timeout(const Duration(seconds: 3));
      client.add(
        jsonEncode({
          'type': 'client_info',
          'version': '1.1.3',
          'deviceId': 'a',
          'deviceSecret': 'secret-a',
        }),
      );
      expect(jsonDecode(await auth)['status'], 'authenticated');
      expect(discovery.gate.isCompleted, isFalse);
      discovery.gate.complete();
      await starting;
      await client.close();
      await provider.stopServices();
      provider.dispose();
      ws.dispose();
      discovery.dispose();
      paired.dispose();
      clipboard.dispose();
      browser.dispose();
      triggers.dispose();
    },
  );

  test('advertising retries a failed native registration', () async {
    var attempts = 0;
    final service = DiscoveryService(
      DeviceInfoService(),
      retryDelay: const Duration(milliseconds: 10),
      registerService: (service) async {
        if (++attempts == 1) throw StateError('transient failure');
        return Registration('ok', service);
      },
      unregisterService: (_) async {},
    );
    await service.startAdvertising(4545);
    expect(service.lastError, isNotNull);
    await until(() => service.isAdvertising);
    expect(attempts, 2);
    expect(service.lastError, isNull);
    await service.stopAdvertising();
    service.dispose();
  });

  test('stop removes a registration that completes late', () async {
    final pending = Completer<Registration>();
    var entered = false;
    final removed = <String>[];
    final service = DiscoveryService(
      DeviceInfoService(),
      registerService: (_) {
        entered = true;
        return pending.future;
      },
      unregisterService: (r) async {
        removed.add(r.id);
      },
    );
    final start = service.startAdvertising(4545);
    await until(() => entered);
    await service.stopAdvertising();
    pending.complete(
      Registration('late', Service(type: '_myautomation._tcp', port: 4545)),
    );
    await start;
    await until(() => removed.contains('late'));
    expect(service.isAdvertising, isFalse);
    service.dispose();
  });

  test('an immediate stop cannot resurrect advertising', () async {
    var registrations = 0;
    final service = DiscoveryService(
      DeviceInfoService(),
      registerService: (s) async {
        registrations++;
        return Registration('id', s);
      },
      unregisterService: (_) async {},
    );
    final starting = service.startAdvertising(4545);
    await service.stopAdvertising();
    await starting;
    expect(service.isAdvertising, isFalse);
    expect(registrations, 0);
    service.dispose();
  });
}
