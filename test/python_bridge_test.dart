import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:autonion_cross_device/core/services/logging_service.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/python_bridge_service.dart';

class FakeAgentProcess implements Process {
  final input = StreamController<List<int>>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final exited = Completer<int>();
  final commands = <Map<String, dynamic>>[];
  late final IOSink sink;
  bool killed = false;
  bool autoPong;
  FakeAgentProcess({this.autoPong = true}) {
    sink = IOSink(input.sink);
    input.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        final command = jsonDecode(line) as Map<String, dynamic>;
        commands.add(command);
        if (autoPong && command['action'] == 'ping') {
          reply(command['id'], 'pong');
        }
      },
    );
  }
  void reply(int id, dynamic value) => output.add(
    utf8.encode('${jsonEncode({'id': id, 'success': true, 'data': value})}\n'),
  );
  @override
  IOSink get stdin => sink;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 42;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!exited.isCompleted) exited.complete(0);
    return true;
  }

  Future<void> dispose() async {
    kill();
    await sink.close();
    await output.close();
    await errors.close();
  }
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition did not become true');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  test(
    'concurrent initialization waits on one process and a completed handshake',
    () async {
      final process = FakeAgentProcess(autoPong: false);
      var starts = 0;
      final bridge = PythonBridgeService(
        log: LoggingService(),
        processFactory: () async {
          starts++;
          return process;
        },
      );
      final first = bridge.init();
      final second = bridge.init();
      expect(identical(first, second), isTrue);
      await until(() => process.commands.isNotEmpty);
      expect(bridge.isReady, isFalse);
      expect(starts, 1);
      process.reply(process.commands.first['id'], 'pong');
      await Future.wait([first, second]);
      expect(bridge.isReady, isTrue);
      await bridge.stop();
      await process.dispose();
    },
  );
  test(
    'observation timeout terminates worker and allows a fresh worker',
    () async {
      final first = FakeAgentProcess();
      final second = FakeAgentProcess();
      var starts = 0;
      final bridge = PythonBridgeService(
        log: LoggingService(),
        commandTimeout: const Duration(milliseconds: 50),
        processFactory: () async => ++starts == 1 ? first : second,
      );
      await bridge.init();
      await expectLater(
        bridge.sendCommand('get_screen_state'),
        throwsA(isA<PythonBridgeException>()),
      );
      expect(first.killed, isTrue);
      expect(bridge.isReady, isFalse);
      await bridge.init();
      expect(starts, 2);
      expect(bridge.isReady, isTrue);
      await bridge.stop();
      await first.dispose();
      await second.dispose();
    },
  );
  test(
    'worker exit fails pending work without waiting for the command timeout',
    () async {
      final process = FakeAgentProcess();
      final bridge = PythonBridgeService(
        log: LoggingService(),
        processFactory: () async => process,
      );
      await bridge.init();
      final outcome = expectLater(
        bridge.sendCommand('open_app'),
        throwsA(isA<PythonBridgeException>()),
      );
      await until(() => process.commands.length == 2);
      process.kill();
      await outcome.timeout(const Duration(seconds: 1));
      expect(bridge.isReady, isFalse);
      await process.dispose();
    },
  );
  test('stop during startup cannot publish a late ready state', () async {
    final process = FakeAgentProcess(autoPong: false);
    final bridge = PythonBridgeService(
      log: LoggingService(),
      processFactory: () async => process,
    );
    final outcome = expectLater(
      bridge.init(),
      throwsA(isA<PythonBridgeException>()),
    );
    await until(() => process.commands.isNotEmpty);
    await bridge.stop();
    await outcome;
    expect(bridge.isReady, isFalse);
    await process.dispose();
  });
}
