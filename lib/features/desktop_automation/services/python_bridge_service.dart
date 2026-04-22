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

  bool _isInitializing = false;
  bool get isReady => _process != null;

  PythonBridgeService({required LoggingService log}) : _log = log;

  /// Ensures python is available, venv is setup, deps are installed, and agent is running.
  Future<void> init() async {
    if (_process != null) return;
    if (_isInitializing) {
      _log.info('PythonBridge', 'Initialization already in progress...');
      return;
    }

    _isInitializing = true;
    _log.info('PythonBridge', 'Initializing Python bridge...');

    try {
      final pythonExe = await _setupVenvAndDependencies();
      await _startAgent(pythonExe);
    } catch (e) {
      _log.error('PythonBridge', 'Failed to init Python bridge: $e');
      rethrow;
    } finally {
      _isInitializing = false;
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

    final id = ++_requestId;
    final completer = Completer<dynamic>();
    _pendingRequests[id] = completer;

    final command = {
      'id': id,
      'action': action,
      if (payload != null) 'payload': payload,
    };

    final jsonStr = jsonEncode(command);

    try {
      _process!.stdin.writeln(jsonStr);
      _process!.stdin.flush();
    } catch (e) {
      _pendingRequests.remove(id);
      throw PythonBridgeException('Failed to write to agent: $e');
    }

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw PythonBridgeException('Command timed out ($action)');
      },
    );
  }

  Future<void> stop() async {
    if (_process != null) {
      _log.info('PythonBridge', 'Stopping Python agent...');
      _process!.kill();
      _process = null;
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

    // 3. Install dependencies
    _log.info('PythonBridge', 'Ensuring dependencies are installed...');
    final pipResult = await Process.run(venvPythonExe, [
      '-m',
      'pip',
      'install',
      '--upgrade',
      'uiautomation',
      'pyautogui',
      'mss',
      'Pillow',
    ]);

    if (pipResult.exitCode != 0) {
      final stderr = pipResult.stderr.toString();
      _log.error('PythonBridge', 'Pip install output: $stderr');
      // We don't throw because sometimes warnings cause non-zero exits,
      // instead we will fail at runtime if imports fail.
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

  Future<void> _startAgent(String pythonExe) async {
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
    _process = await Process.start(pythonExe, [scriptPath]);

    // Handle stdout (JSON responses)
    _process!.stdout
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
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          _log.debug('PythonAgent', line);
        });

    // Handle exit
    _process!.exitCode.then((code) {
      _log.warn('PythonBridge', 'Agent process exited with code $code');
      _process = null;
    });

    // Ping test
    _log.info('PythonBridge', 'Pinging agent...');
    final response = await sendCommand('ping');
    if (response == 'pong' ||
        (response is Map &&
            (response['status'] == 'pong' || response['data'] == 'pong'))) {
      _log.info('PythonBridge', 'Pong received.');
    } else {
      _log.warn('PythonBridge', 'Unexpected ping response: $response');
    }
  }
}
