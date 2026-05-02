import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/di/service_locator.dart';
import '../../features/ai/models/ai_provider_type.dart';
import '../../features/ai/providers/ai_provider_notifier.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  final _aiProvider = getIt<AiProviderNotifier>();

  final _ollamaHostCtrl = TextEditingController();
  final _ollamaPortCtrl = TextEditingController();
  final _ollamaModelCtrl = TextEditingController();
  final _ollamaModelsPathCtrl = TextEditingController();

  final _apiKeyCtrl = TextEditingController();
  final _apiEndpointCtrl = TextEditingController();
  final _apiModelCtrl = TextEditingController();

  // _testConnectionFuture unused warning fixed by removing it and not storing the future

  @override
  void initState() {
    super.initState();
    _aiProvider.addListener(_onProviderUpdate);
    _populateControllers();
  }

  @override
  void dispose() {
    _aiProvider.removeListener(_onProviderUpdate);
    _ollamaHostCtrl.dispose();
    _ollamaPortCtrl.dispose();
    _ollamaModelCtrl.dispose();
    _ollamaModelsPathCtrl.dispose();
    _apiKeyCtrl.dispose();
    _apiEndpointCtrl.dispose();
    _apiModelCtrl.dispose();
    super.dispose();
  }

  void _onProviderUpdate() {
    if (mounted) setState(() {});
  }

  void _populateControllers() {
    final config = _aiProvider.config;
    _ollamaHostCtrl.text = config.ollamaHost;
    _ollamaPortCtrl.text = config.ollamaPort.toString();
    _ollamaModelCtrl.text = config.ollamaModel;
    _ollamaModelsPathCtrl.text = config.ollamaModelsPath ?? '';

    _apiKeyCtrl.text = config.apiKey ?? '';
    _apiEndpointCtrl.text = config.apiEndpoint;
    _apiModelCtrl.text = config.apiModel;
  }

  void _saveOllama() {
    _aiProvider.updateOllamaConfig(
      host: _ollamaHostCtrl.text.trim(),
      port: int.tryParse(_ollamaPortCtrl.text.trim()) ?? 11434,
      model: _ollamaModelCtrl.text.trim(),
    );
  }

  void _saveApiKey() {
    _aiProvider.updateApiKeyConfig(
      apiKey: _apiKeyCtrl.text.trim(),
      endpoint: _apiEndpointCtrl.text.trim(),
      model: _apiModelCtrl.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentType = _aiProvider.config.providerType;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AI Settings',
            style: Theme.of(context).textTheme.displayMedium,
          ).animate().fadeIn(duration: 400.ms).slideX(begin: -0.05),
          const SizedBox(height: 8),
          Text(
            'Configure your AI provider for automation',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 28),

          // ── Provider Cards ──────────────────────
          _buildProviderCard(
            AiProviderType.ollama,
            Icons.computer,
            AppColors.success,
          ).animate().fadeIn(duration: 500.ms, delay: 100.ms),
          const SizedBox(height: 12),

          _buildProviderCard(
            AiProviderType.apiKey,
            Icons.cloud_outlined,
            AppColors.primary,
          ).animate().fadeIn(duration: 500.ms, delay: 200.ms),
          const SizedBox(height: 12),

          _buildProviderCard(
            AiProviderType.webBased,
            Icons.public,
            AppColors.warning,
          ).animate().fadeIn(duration: 500.ms, delay: 300.ms),

          const SizedBox(height: 32),

          // ── Config Panels ───────────────────────
          if (currentType == AiProviderType.ollama)
            _buildOllamaConfig()
          else if (currentType == AiProviderType.apiKey)
            _buildApiKeyConfig()
          else if (currentType == AiProviderType.webBased)
            GlassmorphicCard(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Web-Based mode delegates requests to the Autonion browser extension, which interacts with ChatGPT or Gemini DOM. No extra configuration required.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),

          const SizedBox(height: 32),

          // ── Test Connection ─────────────────────
          if (currentType != AiProviderType.webBased)
            _buildTestConnectionPanel(),
        ],
      ),
    );
  }

  Widget _buildProviderCard(AiProviderType type, IconData icon, Color color) {
    final isSelected = _aiProvider.config.providerType == type;

    return InkWell(
      onTap: () {
        _aiProvider.setProvider(type);
        _populateControllers();
      },
      borderRadius: BorderRadius.circular(16),
      child: GlassmorphicCard(
        borderColor: isSelected ? color.withAlpha(120) : null,
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withAlpha(30),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        type.displayName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (isSelected) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: color.withAlpha(30),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'Active',
                            style: Theme.of(
                              context,
                            ).textTheme.labelSmall?.copyWith(color: color),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    type.description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check_circle, color: color, size: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildOllamaConfig() {
    return GlassmorphicCard(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ollama Configuration',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _ollamaHostCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Host (e.g. localhost)',
                    ),
                    onChanged: (_) => _saveOllama(),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _ollamaPortCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Port (e.g. 11434)',
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (_) => _saveOllama(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _ollamaModelCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Model (e.g. llama3.2:latest)',
                    ),
                    onChanged: (_) => _saveOllama(),
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  tooltip: 'Refresh Models',
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    await _aiProvider.refreshOllamaModels();
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),

            if (_aiProvider.ollamaModels.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Available Models:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _aiProvider.ollamaModels
                    .map(
                      (model) => ActionChip(
                        label: Text(model),
                        onPressed: () {
                          _ollamaModelCtrl.text = model;
                          _saveOllama();
                        },
                      ),
                    )
                    .toList(),
              ),
            ],

            const SizedBox(height: 16),
            _buildOllamaStatusRow(),

            const Divider(height: 32),

            TextFormField(
              controller: _ollamaModelsPathCtrl,
              decoration: const InputDecoration(
                labelText: 'Models Directory (optional)',
                hintText: r'e.g. D:\Ollama\Models',
                helperText: 'Set this if your Ollama models are stored in a custom location',
              ),
              onChanged: (val) {
                _aiProvider.updateOllamaModelsPath(val.trim());
              },
            ),
          ],
        ),
      ),
    ).animate().fadeIn();
  }

  Widget _buildApiKeyConfig() {
    return GlassmorphicCard(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'API Configuration',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _apiKeyCtrl,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'sk-...',
              ),
              obscureText: true,
              onChanged: (_) => _saveApiKey(),
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _apiEndpointCtrl,
              decoration: const InputDecoration(
                labelText: 'API Endpoint (OpenAI format)',
              ),
              onChanged: (_) => _saveApiKey(),
            ),
            const SizedBox(height: 16),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _apiModelCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Model Name',
                      hintText: 'gpt-4o-mini, gemini-1.5-pro, etc.',
                    ),
                    onChanged: (_) => _saveApiKey(),
                  ),
                ),
                if (_apiEndpointCtrl.text.toLowerCase().contains('ollama.com')) ...[
                  const SizedBox(width: 16),
                  IconButton(
                    tooltip: 'Refresh Models',
                    icon: const Icon(Icons.refresh),
                    onPressed: () async {
                      await _aiProvider.refreshApiModels();
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ],
            ),

            if (_apiEndpointCtrl.text.toLowerCase().contains('ollama.com') && _aiProvider.apiModels.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Available Models:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _aiProvider.apiModels
                    .map(
                      (model) => ActionChip(
                        label: Text(model),
                        onPressed: () {
                          _apiModelCtrl.text = model;
                          _saveApiKey();
                        },
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    ).animate().fadeIn();
  }

  Widget _buildTestConnectionPanel() {
    return Row(
      children: [
        ElevatedButton.icon(
          onPressed: _aiProvider.testing
              ? null
              : () {
                  _aiProvider.testConnection();
                },
          icon: _aiProvider.testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_ping),
          label: const Text('Test Connection'),
        ),
        const SizedBox(width: 16),
        if (_aiProvider.testResult != null)
          Expanded(
            child: Text(
              _aiProvider.testResult!,
              style: TextStyle(
                color: _aiProvider.testResult!.contains('✅')
                    ? AppColors.success
                    : _aiProvider.testResult!.contains('⚠️')
                        ? AppColors.warning
                        : AppColors.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildOllamaStatusRow() {
    final available = _aiProvider.ollamaAvailable;
    final models = _aiProvider.ollamaModels;
    final hasModels = models.isNotEmpty;

    if (!available) {
      return Row(
        children: [
          const Icon(Icons.error, color: AppColors.error, size: 16),
          const SizedBox(width: 8),
          Text(
            'Ollama not reachable',
            style: TextStyle(color: AppColors.error, fontSize: 12),
          ),
        ],
      );
    }

    if (!hasModels) {
      return Row(
        children: [
          const Icon(Icons.warning_amber, color: AppColors.warning, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Ollama is running but no models found — check Models Directory below',
              style: TextStyle(color: AppColors.warning, fontSize: 12),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        const Icon(Icons.check_circle, color: AppColors.success, size: 16),
        const SizedBox(width: 8),
        Text(
          'Ollama reachable — ${models.length} model(s) found',
          style: TextStyle(color: AppColors.success, fontSize: 12),
        ),
      ],
    );
  }
}
