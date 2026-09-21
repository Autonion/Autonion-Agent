import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../core/services/logging_service.dart';

class PythonBridgeException implements Exception {
  final String message;
  PythonBridgeException(this.message);
  @override
  String toString() => 'PythonBridgeException: $message';
}

/// Manages the Python desktop agent process, venv setup, and communication.
class PythonBridgeService {
  final LoggingService _log;

  Process? _process;
  int _requestId = 0;
  final Map<int, Completer<dynamic>> _pendingRequests = {};

  Future<void>? _initialization;
  Future<void>? _stopping;
  bool _ready = false;
  int _generation = 0;
  bool get isReady => _ready;
  final Future<Process> Function()? processFactory;
  final Duration commandTimeout;

  PythonBridgeService({
    required LoggingService log,
    this.processFactory,
    this.commandTimeout = const Duration(seconds: 30),
  }) : _log = log;

  /// Ensures python is available, venv is setup, deps are installed, and agent is running.
  Future<void> init() {
    if (isReady) return Future.value();
    return _initialization ??= _initialize().whenComplete(
      () => _initialization = null,
    );
  }

  Future<void> _initialize() async {
    final generation = _generation;
    await _stopping;
    _log.info('PythonBridge', 'Initializing Python bridge...');

    try {
      final process = processFactory != null
          ? await processFactory!()
          : await _spawnAgent(await _setupVenvAndDependencies());
      if (generation != _generation) {
        process.kill();
        await process.exitCode;
        throw PythonBridgeException('Initialization cancelled');
      }
      _attachAgent(process);
      final response = await _sendCommand('ping');
      if (response != 'pong' ||
          generation != _generation ||
          !identical(_process, process)) {
        throw PythonBridgeException('Agent handshake did not complete');
      }
      _ready = true;
      _log.info('PythonBridge', 'Pong received; agent ready.');
    } catch (e) {
      await stop();
      _log.error('PythonBridge', 'Failed to init Python bridge: $e');
      rethrow;
    }
  }

  /// Sends a command to the python agent and waits for a response.
  Future<dynamic> sendCommand(
    String action, [
    Map<String, dynamic>? payload,
  ]) async {
    if (!isReady) {
      await init();
    }
    return _sendCommand(action, payload);
  }

  Future<dynamic> _sendCommand(
    String action, [
    Map<String, dynamic>? payload,
  ]) async {
    final id = ++_requestId;
    final completer = Completer<dynamic>();
    // A stop/exit may arrive while stdin.flush is still pending.
    completer.future.ignore();
    _pendingRequests[id] = completer;

    final command = {
      'id': id,
      'action': action,
      if (payload != null) 'payload': payload,
    };

    final jsonStr = jsonEncode(command);

    try {
      _process!.stdin.writeln(jsonStr);
      await _process!.stdin.flush();
    } catch (e) {
      _pendingRequests.remove(id);
      throw PythonBridgeException('Failed to write to agent: $e');
    }

    final timeout =
        (action == 'select_screen_region' || action == 'select_ui_element')
        ? const Duration(minutes: 5)
        : commandTimeout;

    return completer.future.timeout(
      timeout,
      onTimeout: () async {
        _pendingRequests.remove(id);
        // The Python worker processes commands sequentially. Terminating it
        // prevents timed-out work from executing after a later task starts.
        await stop();
        throw PythonBridgeException('Command timed out ($action)');
      },
    );
  }

  Future<void> stop() async {
    _generation++;
    _ready = false;
    _failPending('Python agent stopped');
    final process = _process;
    _process = null;
    if (process != null) {
      _log.info('PythonBridge', 'Stopping Python agent...');
      process.kill();
      final stopping = process.exitCode.then<void>((_) {});
      _stopping = stopping;
      await stopping;
      if (identical(_stopping, stopping)) _stopping = null;
    }
  }

  void _failPending(String message) {
    final pending = _pendingRequests.values.toList();
    _pendingRequests.clear();
    for (final request in pending) {
      if (!request.isCompleted) {
        request.completeError(PythonBridgeException(message));
      }
    }
  }

  // ── Internal Setup ───────────────────────────────────────

  Future<String> _setupVenvAndDependencies() async {
    // 1. Find python
    final systemPython = await _findSystemPython();
    if (systemPython == null) {
      throw PythonBridgeException('Python 3 is not installed or not in PATH.');
    }

    // 2. Setup Venv directory (in AppData)
    final appDir = await getApplicationSupportDirectory();
    final venvPath = p.join(appDir.path, 'autonion_venv');
    final venvPythonExe = Platform.isWindows
        ? p.join(venvPath, 'Scripts', 'python.exe')
        : p.join(venvPath, 'bin', 'python');

    if (!File(venvPythonExe).existsSync()) {
      _log.info('PythonBridge', 'Creating virtual environment at $venvPath...');
      final result = await Process.run(systemPython, ['-m', 'venv', venvPath]);
      if (result.exitCode != 0) {
        throw PythonBridgeException('Failed to create venv: ${result.stderr}');
      }
    }

    // An existing environment should not access the network or upgrade its
    // packages on every startup/recovery.
    final check = await Process.run(venvPythonExe, [
      '-c',
      'import uiautomation, pyautogui, mss, PIL, pyperclip, cv2, numpy',
    ]);
    if (check.exitCode == 0) return venvPythonExe;

    // 3. Install missing dependencies
    _log.info('PythonBridge', 'Ensuring dependencies are installed...');
    final pipResult = await Process.run(venvPythonExe, [
      '-m',
      'pip',
      'install',
      'uiautomation',
      'pyautogui',
      'mss',
      'Pillow',
      'pyperclip',
      'opencv-python',
      'numpy',
    ]);

    if (pipResult.exitCode != 0) {
      final stderr = pipResult.stderr.toString();
      _log.error('PythonBridge', 'Pip install output: $stderr');
      throw PythonBridgeException(
        'Python dependencies could not be installed.',
      );
    }

    return venvPythonExe;
  }

  Future<String?> _findSystemPython() async {
    final commands = Platform.isWindows
        ? ['python', 'py', 'python3']
        : ['python3', 'python'];
    for (final cmd in commands) {
      try {
        final result = await Process.run(cmd, ['--version']);
        if (result.exitCode == 0) return cmd;
      } catch (_) {}
    }
    return null;
  }

  Future<Process> _spawnAgent(String pythonExe) async {
    // Find the python script. It is inside `python/desktop_agent.py`.
    // We use the executable's directory so it works when installed or launched via shortcut.
    final exeDir = p.dirname(Platform.resolvedExecutable);

    // In dev (flutter run), the exe is deep in build/windows/..., so we fallback to Directory.current if not found.
    String scriptPath = p.join(exeDir, 'python', 'desktop_agent.py');
    if (!File(scriptPath).existsSync()) {
      scriptPath = p.join(Directory.current.path, 'python', 'desktop_agent.py');
    }

    if (!File(scriptPath).existsSync()) {
      throw PythonBridgeException('desktop_agent.py not found at $scriptPath');
    }

    _log.info('PythonBridge', 'Spawning agent process...');
    return Process.start(pythonExe, [scriptPath]);
  }

  void _attachAgent(Process process) {
    _process = process;

    // Handle stdout (JSON responses)
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          try {
            final Map<String, dynamic> response = jsonDecode(line);
            final id = response['id'] as int?;
            if (id != null && _pendingRequests.containsKey(id)) {
              final completer = _pendingRequests.remove(id)!;
              if (response['success'] == true) {
                completer.complete(response['data']);
              } else {
                completer.completeError(
                  PythonBridgeException(
                    response['error'] as String? ?? 'Unknown error',
                  ),
                );
              }
            }
          } catch (e) {
            _log.error(
              'PythonBridge',
              'Failed to parse agent stdout: $line (Error: $e)',
            );
          }
        });

    // Handle stderr (Agent logs)
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _log.debug('PythonAgent', line);
        });

    // Handle exit
    process.exitCode.then((code) {
      _log.warn('PythonBridge', 'Agent process exited with code $code');
      if (identical(_process, process)) {
        _process = null;
        _ready = false;
        _failPending('Python agent exited with code $code');
      }
    });
  }
}
