import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../../../core/services/logging_service.dart';

// ── Win32 constants ─────────────────────────────────────────
const int _kGenericRead = 0x80000000;
const int _kGenericWrite = 0x40000000;
const int _kOpenExisting = 3;
const int _kFileAttributeNormal = 0x00000080;
const int _kPipeBufferSize = 65536;

// ── Win32 FFI bindings (kernel32.dll) ───────────────────────
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

typedef _WaitNamedPipeW_C = Int32 Function(
    Pointer<Utf16> lpNamedPipeName, Uint32 nTimeOut);
typedef _WaitNamedPipeW_Dart = int Function(
    Pointer<Utf16> lpNamedPipeName, int nTimeOut);
final _WaitNamedPipeW =
    _kernel32.lookupFunction<_WaitNamedPipeW_C, _WaitNamedPipeW_Dart>(
        'WaitNamedPipeW');

typedef _CreateFileW_C = IntPtr Function(
    Pointer<Utf16> lpFileName,
    Uint32 dwDesiredAccess,
    Uint32 dwShareMode,
    Pointer<Void> lpSecurityAttributes,
    Uint32 dwCreationDisposition,
    Uint32 dwFlagsAndAttributes,
    IntPtr hTemplateFile);
typedef _CreateFileW_Dart = int Function(
    Pointer<Utf16> lpFileName,
    int dwDesiredAccess,
    int dwShareMode,
    Pointer<Void> lpSecurityAttributes,
    int dwCreationDisposition,
    int dwFlagsAndAttributes,
    int hTemplateFile);
final _CreateFileW =
    _kernel32.lookupFunction<_CreateFileW_C, _CreateFileW_Dart>('CreateFileW');

typedef _WriteFile_C = Int32 Function(IntPtr hFile, Pointer<Uint8> lpBuffer,
    Uint32 nBytes, Pointer<Uint32> lpBytesWritten, Pointer<Void> lpOverlapped);
typedef _WriteFile_Dart = int Function(int hFile, Pointer<Uint8> lpBuffer,
    int nBytes, Pointer<Uint32> lpBytesWritten, Pointer<Void> lpOverlapped);
final _WriteFile =
    _kernel32.lookupFunction<_WriteFile_C, _WriteFile_Dart>('WriteFile');

typedef _ReadFile_C = Int32 Function(IntPtr hFile, Pointer<Uint8> lpBuffer,
    Uint32 nBytes, Pointer<Uint32> lpBytesRead, Pointer<Void> lpOverlapped);
typedef _ReadFile_Dart = int Function(int hFile, Pointer<Uint8> lpBuffer,
    int nBytes, Pointer<Uint32> lpBytesRead, Pointer<Void> lpOverlapped);
final _ReadFile =
    _kernel32.lookupFunction<_ReadFile_C, _ReadFile_Dart>('ReadFile');

typedef _CloseHandle_C = Int32 Function(IntPtr hObject);
typedef _CloseHandle_Dart = int Function(int hObject);
final _CloseHandle =
    _kernel32.lookupFunction<_CloseHandle_C, _CloseHandle_Dart>('CloseHandle');


/// Low-level service to send JSON requests to the AutonionUnlockHelper
/// Windows service via its named pipe, bypassing the Python bridge.
///
/// All pipe I/O is blocking and runs inside [Isolate.run] so the Flutter
/// event loop is never blocked.
class UnlockServicePipe {
  static const _tag = 'UnlockServicePipe';
  static const _pipeName = r'\\.\pipe\AutonionUnlockHelper';
  static const _pipeTimeoutMs = 5000;

  final LoggingService _log;

  UnlockServicePipe({required LoggingService log}) : _log = log;

  // ── Public API ──────────────────────────────────────────────

  /// Check whether the named pipe is currently accepting connections.
  Future<bool> isServiceAvailable() async {
    try {
      return await Isolate.run(_checkPipeAvailable);
    } catch (_) {
      return false;
    }
  }

  /// Provision the device identity so the native service's mDNS
  /// advertisement uses the correct device name.
  Future<bool> provisionIdentity({
    required String deviceId,
    required String deviceName,
  }) async {
    try {
      final result = await _sendControl({
        'action': 'storePreloginIdentity',
        'requestId': _makeRequestId(),
        'deviceId': deviceId,
        'deviceName': deviceName,
      });
      _log.info(_tag, 'Identity provisioned: $deviceName ($deviceId)');
      return result;
    } catch (e) {
      _log.warn(_tag, 'Identity provisioning failed: $e');
      return false;
    }
  }

  /// Provision an unlock credential so the native service can serve it
  /// to Android and execute the unlock before any user logs in.
  Future<bool> provisionUnlockCredential({
    required String flowId,
    required String flowName,
    required String nodeId,
    required String password,
  }) async {
    try {
      final passwordB64 = base64Encode(utf8.encode(password));
      final result = await _sendControl({
        'action': 'storePreloginCredential',
        'requestId': _makeRequestId(),
        'flowId': flowId,
        'nodeId': nodeId,
        'flowName': flowName,
        'passwordB64': passwordB64,
      });
      _log.info(_tag, 'Provisioned unlock credential for flow "$flowName"');
      return result;
    } catch (e) {
      _log.warn(_tag, 'Unlock credential provisioning failed: $e');
      return false;
    }
  }

  /// Delete a previously provisioned unlock credential.
  Future<bool> deleteUnlockCredential({required String flowId}) async {
    try {
      final result = await _sendControl({
        'action': 'deletePreloginCredential',
        'requestId': _makeRequestId(),
        'flowId': flowId,
      });
      _log.info(_tag, 'Deleted unlock credential for flow $flowId');
      return result;
    } catch (e) {
      _log.warn(_tag, 'Unlock credential deletion failed: $e');
      return false;
    }
  }

  // ── Internal ────────────────────────────────────────────────

  static int _requestCounter = 0;
  static String _makeRequestId() =>
      'dart_${DateTime.now().millisecondsSinceEpoch}_${++_requestCounter}';

  /// Send a control request and return true on success.
  Future<bool> _sendControl(Map<String, dynamic> payload) async {
    final requestJson = jsonEncode(payload);
    final responseJson = await Isolate.run(() => _pipeRoundTrip(requestJson));
    if (responseJson == null) {
      throw Exception('Named pipe is not available');
    }

    final response = jsonDecode(responseJson) as Map<String, dynamic>;
    if (response['success'] == true) return true;

    final error = response['error'] ?? 'Unknown service error';
    throw Exception(error);
  }

  // ── Static helpers that run inside the isolate ──────────────

  static bool _checkPipeAvailable() {
    final namePtr = _pipeName.toNativeUtf16();
    try {
      return _WaitNamedPipeW(namePtr, 1000) != 0;
    } finally {
      calloc.free(namePtr);
    }
  }

  /// Blocking round-trip: open pipe, write request, read response, close.
  /// Returns the response JSON string or null if the pipe is unreachable.
  static String? _pipeRoundTrip(String requestJson) {
    final namePtr = _pipeName.toNativeUtf16();

    // 1. Wait for pipe availability
    if (_WaitNamedPipeW(namePtr, _pipeTimeoutMs) == 0) {
      calloc.free(namePtr);
      return null;
    }

    // 2. Open pipe
    final handle = _CreateFileW(
      namePtr,
      _kGenericRead | _kGenericWrite,
      0,
      nullptr,
      _kOpenExisting,
      _kFileAttributeNormal,
      0,
    );
    calloc.free(namePtr);

    if (handle == -1 || handle == 0) return null;

    try {
      // 3. Write request
      final requestBytes = utf8.encode(requestJson);
      final writeBuf = calloc<Uint8>(requestBytes.length);
      for (var i = 0; i < requestBytes.length; i++) {
        writeBuf[i] = requestBytes[i];
      }
      final bytesWritten = calloc<Uint32>();
      final writeOk = _WriteFile(
        handle,
        writeBuf,
        requestBytes.length,
        bytesWritten,
        nullptr,
      );
      calloc.free(writeBuf);
      calloc.free(bytesWritten);

      if (writeOk == 0) return null;

      // 4. Read response
      final readBuf = calloc<Uint8>(_kPipeBufferSize);
      final bytesRead = calloc<Uint32>();
      final readOk = _ReadFile(
        handle,
        readBuf,
        _kPipeBufferSize,
        bytesRead,
        nullptr,
      );

      String? result;
      if (readOk != 0 && bytesRead.value > 0) {
        final responseBytes = Uint8List(bytesRead.value);
        for (var i = 0; i < bytesRead.value; i++) {
          responseBytes[i] = readBuf[i];
        }
        result = utf8.decode(responseBytes);
      }

      calloc.free(readBuf);
      calloc.free(bytesRead);
      return result;
    } finally {
      _CloseHandle(handle);
    }
  }
}
