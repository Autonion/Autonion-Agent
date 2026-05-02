import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/logging_service.dart';
import '../models/ai_config.dart';
import '../models/ai_provider_type.dart';
import '../services/ai_service.dart';
import '../services/ollama_service.dart';
import '../services/api_key_service.dart';
import '../services/web_ai_service.dart';

/// Manages the active AI provider, configuration, and availability state.
class AiProviderNotifier extends ChangeNotifier {
  static const _configKey = 'ai_config';
  static const _apiKeyStorageKey = 'ai_api_key';
  static const _legacyApiKeyKey = 'ai_api_key'; // SharedPreferences key (legacy)

  final LoggingService _log;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  AiConfig _config = const AiConfig(providerType: AiProviderType.ollama);
  AiConfig get config => _config;

  bool _ollamaAvailable = false;
  bool get ollamaAvailable => _ollamaAvailable;

  List<String> _ollamaModels = [];
  List<String> get ollamaModels => _ollamaModels;

  List<String> _apiModels = [];
  List<String> get apiModels => _apiModels;

  bool _testing = false;
  bool get testing => _testing;

  String? _testResult;
  String? get testResult => _testResult;

  // ── Provider instances ──
  late final OllamaService _ollamaService;
  late final ApiKeyService _apiKeyService;
  late final WebAiService _webAiService;

  AiProviderNotifier({required LoggingService log}) : _log = log {
    _ollamaService = OllamaService(log: log, config: _config);
    _apiKeyService = ApiKeyService(log: log, config: _config);
    _webAiService = WebAiService(log: log);
  }

  /// Returns the currently active AI service.
  AiService get activeService {
    switch (_config.providerType) {
      case AiProviderType.ollama:
        return _ollamaService;
      case AiProviderType.apiKey:
        return _apiKeyService;
      case AiProviderType.webBased:
        return _webAiService;
    }
  }

  /// Load configuration from disk.
  Future<void> loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_configKey);
      if (jsonStr != null) {
        _config = AiConfig.fromJson(
          jsonDecode(jsonStr) as Map<String, dynamic>,
        );
      }

      // Load API key from secure storage
      String? apiKey = await _secureStorage.read(key: _apiKeyStorageKey);

      // One-time migration: move plaintext key from SharedPreferences → secure storage
      if (apiKey == null) {
        final legacyKey = prefs.getString(_legacyApiKeyKey);
        if (legacyKey != null && legacyKey.isNotEmpty) {
          _log.info('AiProvider', 'Migrating API key from plaintext to secure storage...');
          await _secureStorage.write(key: _apiKeyStorageKey, value: legacyKey);
          await prefs.remove(_legacyApiKeyKey);
          apiKey = legacyKey;
        }
      }

      if (apiKey != null) {
        _config = _config.copyWith(apiKey: apiKey);
      }

      _ollamaService.updateConfig(_config);
      _apiKeyService.updateConfig(_config, apiKey: apiKey);
      notifyListeners();

      // Auto-detect Ollama availability
      _checkOllamaAvailability();
      // Auto-fetch API models if configured
      refreshApiModels();
    } catch (e) {
      _log.error('AiProvider', 'Failed to load AI config: $e');
    }
  }

  /// Save configuration to disk.
  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_configKey, jsonEncode(_config.toJson()));

      // API key stored in encrypted secure storage
      if (_config.apiKey != null && _config.apiKey!.isNotEmpty) {
        await _secureStorage.write(key: _apiKeyStorageKey, value: _config.apiKey!);
      }
    } catch (e) {
      _log.error('AiProvider', 'Failed to save AI config: $e');
    }
  }

  /// Switch the active provider.
  Future<void> setProvider(AiProviderType type) async {
    _config = _config.copyWith(providerType: type);
    _ollamaService.updateConfig(_config);
    _apiKeyService.updateConfig(_config);
    await _saveConfig();
    _testResult = null;
    if (type == AiProviderType.apiKey) {
      refreshApiModels();
    }
    notifyListeners();
  }

  /// Update Ollama settings.
  Future<void> updateOllamaConfig({
    String? host,
    int? port,
    String? model,
  }) async {
    _config = _config.copyWith(
      ollamaHost: host,
      ollamaPort: port,
      ollamaModel: model,
    );
    _ollamaService.updateConfig(_config);
    await _saveConfig();
    notifyListeners();
  }

  /// Update API Key settings.
  Future<void> updateApiKeyConfig({
    String? apiKey,
    String? endpoint,
    String? model,
  }) async {
    _config = _config.copyWith(
      apiKey: apiKey,
      apiEndpoint: endpoint,
      apiModel: model,
    );
    _apiKeyService.updateConfig(_config, apiKey: apiKey);
    await _saveConfig();
    notifyListeners();
  }

  /// Check Ollama availability and refresh models.
  Future<void> _checkOllamaAvailability() async {
    _ollamaAvailable = await _ollamaService.isAvailable();
    if (_ollamaAvailable) {
      _ollamaModels = await _ollamaService.listModels();
      _log.info(
        'AiProvider',
        'Ollama available — ${_ollamaModels.length} models found',
      );
    } else {
      _ollamaModels = [];
    }
    notifyListeners();
  }

  /// Manually refresh Ollama models.
  Future<void> refreshOllamaModels() async {
    await _checkOllamaAvailability();
  }

  /// Manually refresh API models.
  Future<void> refreshApiModels() async {
    _apiModels = await _apiKeyService.listModels();
    notifyListeners();
  }

  /// Update Ollama models directory path.
  Future<void> updateOllamaModelsPath(String? path) async {
    _config = _config.copyWith(ollamaModelsPath: path ?? '');
    await _saveConfig();
    notifyListeners();
  }

  /// Ensures Ollama is running if it is the selected provider.
  /// Launches the Ollama desktop app so it uses the user's configured
  /// models directory and settings.
  Future<bool> ensureOllamaRunning() async {
    if (_config.providerType != AiProviderType.ollama) return true;

    if (await _ollamaService.isAvailable()) {
      return true;
    }

    _log.info('AiProvider', 'Ollama is offline. Attempting to start automatically...');
    try {
      if (Platform.isWindows) {
        // Launch the Ollama app exe — preserves user's model path config
        final userProfile = Platform.environment['LOCALAPPDATA'] ?? '';
        final ollamaExe = '$userProfile\\Programs\\Ollama\\Ollama.exe';
        if (await File(ollamaExe).exists()) {
          _log.info('AiProvider', 'Launching Ollama app: $ollamaExe');
          Process.start(ollamaExe, [], mode: ProcessStartMode.detached);
        } else {
          // Fallback: try via PATH (e.g. user installed elsewhere)
          _log.info('AiProvider', 'Ollama exe not found at default path, trying PATH...');
          Process.start('ollama', ['serve'], runInShell: true, mode: ProcessStartMode.detached);
        }
      } else if (Platform.isMacOS) {
        Process.start('open', ['-a', 'Ollama']);
      } else if (Platform.isLinux) {
        Process.start('ollama', ['serve'], runInShell: true, mode: ProcessStartMode.detached);
      }
      
      // Poll for availability (up to 20 seconds — app startup can be slow)
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(seconds: 1));
        if (await _ollamaService.isAvailable()) {
          _log.info('AiProvider', 'Ollama started successfully.');
          await _checkOllamaAvailability();
          return true;
        }
      }
      _log.warn('AiProvider', 'Ollama did not become available within 20s.');
    } catch (e) {
      _log.error('AiProvider', 'Failed to start Ollama: $e');
    }
    
    return false;
  }

  /// Test the active provider — for Ollama, also verifies the model exists.
  Future<void> testConnection() async {
    _testing = true;
    _testResult = null;
    notifyListeners();

    try {
      final available = await activeService.isAvailable();
      if (!available) {
        _testResult = '❌ Provider not reachable';
      } else if (_config.providerType == AiProviderType.ollama) {
        // Verify the configured model actually exists
        final models = await _ollamaService.listModels();
        final configuredModel = _config.ollamaModel;
        final modelExists = models.any((m) =>
          m == configuredModel || m.startsWith('$configuredModel:'));
        if (models.isEmpty) {
          _testResult = '⚠️ Ollama is running but no models found.\n'
              'Check your Models Directory setting or pull a model.';
        } else if (!modelExists) {
          _testResult = '⚠️ Ollama is running but model "$configuredModel" not found.\n'
              'Available: ${models.take(5).join(", ")}';
        } else {
          _testResult = '✅ Connected — ${activeService.providerName}';
        }
      } else {
        _testResult = '✅ Connected — ${activeService.providerName}';
      }
    } catch (e) {
      _testResult = '❌ Error: $e';
    }

    _testing = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _ollamaService.dispose();
    _apiKeyService.dispose();
    _webAiService.dispose();
    super.dispose();
  }
}
