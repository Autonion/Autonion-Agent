import 'dart:convert';
import 'package:flutter/foundation.dart';
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

  final LoggingService _log;

  AiConfig _config = const AiConfig(providerType: AiProviderType.ollama);
  AiConfig get config => _config;

  bool _ollamaAvailable = false;
  bool get ollamaAvailable => _ollamaAvailable;

  List<String> _ollamaModels = [];
  List<String> get ollamaModels => _ollamaModels;

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
        _config = AiConfig.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
      }

      // Load API key separately
      final apiKey = prefs.getString(_apiKeyStorageKey);
      if (apiKey != null) {
        _config = _config.copyWith(apiKey: apiKey);
      }

      _ollamaService.updateConfig(_config);
      _apiKeyService.updateConfig(_config, apiKey: apiKey);
      notifyListeners();

      // Auto-detect Ollama availability
      _checkOllamaAvailability();
    } catch (e) {
      _log.error('AiProvider', 'Failed to load AI config: $e');
    }
  }

  /// Save configuration to disk.
  Future<void> _saveConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_configKey, jsonEncode(_config.toJson()));

      // API key stored separately
      if (_config.apiKey != null) {
        await prefs.setString(_apiKeyStorageKey, _config.apiKey!);
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
      _log.info('AiProvider', 'Ollama available — ${_ollamaModels.length} models found');
    } else {
      _ollamaModels = [];
    }
    notifyListeners();
  }

  /// Manually refresh Ollama models.
  Future<void> refreshOllamaModels() async {
    await _checkOllamaAvailability();
  }

  /// Test the active provider with a simple ping message.
  Future<void> testConnection() async {
    _testing = true;
    _testResult = null;
    notifyListeners();

    try {
      final available = await activeService.isAvailable();
      if (!available) {
        _testResult = '❌ Provider not reachable';
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
