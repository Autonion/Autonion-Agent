import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/config/platform_config.dart';
import '../../../core/services/logging_service.dart';
import '../../browser_automation/services/browser_launcher_service.dart';
import '../../clipboard/services/clipboard_sync_service.dart';
import '../../triggers/services/trigger_rule_service.dart';
import '../services/device_info_service.dart';
import '../services/discovery_service.dart';
import '../services/websocket_service.dart';
import '../../../core/di/service_locator.dart';
import '../../desktop_automation/providers/desktop_automation_provider.dart';
import '../../desktop_automation/services/desktop_agent_service.dart';
import '../../ai/models/ai_message.dart';
import '../../ai/providers/ai_provider_notifier.dart';
import '../../ai/models/ai_provider_type.dart';

/// Orchestrates all connection-related services and exposes reactive state.
///
/// This replaces the old main.dart monolith — services are started/stopped
/// from here and UI reads state from this provider.
class ConnectionProvider extends ChangeNotifier {
  final Set<String> _processedTransactions = {};

  /// Pending completers for extension responses, keyed by transaction ID.
  final Map<String, Completer<Map<String, dynamic>>> _pendingDomSnapshots = {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingStepResults = {};

  /// Track completed transactions to prevent duplicate 'completed' broadcasts.
  final Set<String> _completedTransactions = {};
  final LoggingService _log;
  final WebSocketService _ws;
  final DiscoveryService _discovery;
  final DeviceInfoService _deviceInfo;
  final BrowserLauncherService _browser;
  final ClipboardSyncService _clipboard;
  final TriggerRuleService _triggers;

  bool _isRunning = false;
  int? _port;
  StreamSubscription? _commandSub;
  StreamSubscription<String>? _clipboardSub;

  bool get isRunning => _isRunning;
  int? get port => _port;
  DeviceInfoService get deviceInfo => _deviceInfo;
  WebSocketService get ws => _ws;
  BrowserLauncherService get browser => _browser;

  ConnectionProvider({
    required LoggingService loggingService,
    required WebSocketService webSocketService,
    required DiscoveryService discoveryService,
    required DeviceInfoService deviceInfoService,
    required BrowserLauncherService browserLauncherService,
    required ClipboardSyncService clipboardSyncService,
    required TriggerRuleService triggerRuleService,
  }) : _log = loggingService,
       _ws = webSocketService,
       _discovery = discoveryService,
       _deviceInfo = deviceInfoService,
       _browser = browserLauncherService,
       _clipboard = clipboardSyncService,
       _triggers = triggerRuleService;

  /// Wire all inter-service dependencies and start everything.
  Future<void> startServices() async {
    if (_isRunning) return;
    _log.info('APP', 'Starting services...');

    try {
      // Wire logging into subordinate services
      _ws.setLoggingService(_log);
      _discovery.setLoggingService(_log);
      _browser.setLoggingService(_log);
      _clipboard.setLoggingService(_log);
      _clipboard.setWebSocketService(_ws);
      _clipboard.setDeviceInfoService(_deviceInfo);
      _triggers.setLoggingService(_log);
      _triggers.setWebSocketService(_ws);

      // Detect browsers (desktop only)
      if (PlatformConfig.isDesktop) {
        await _browser.detectBrowsers();
      }

      // 1. Start WebSocket Server
      _port = await _ws.startServer();
      _log.info('APP', 'WebSocket Server started on port $_port');

      // 2. Start mDNS Advertising
      await _discovery.startAdvertising(_port!);
      _log.info('APP', 'mDNS Advertising started');

      // 3. Listen for commands
      _commandSub = _ws.commandStream.listen(_executeCommand);

      // 4. Start clipboard polling
      _clipboard.startPolling();

      // 5. Start trigger rule listening
      _triggers.startListening();

      _isRunning = true;
      notifyListeners();
    } catch (e) {
      _log.error('APP', 'Error starting services: $e');
    }
  }

  Future<void> stopServices() async {
    if (!_isRunning) return;
    _log.info('APP', 'Stopping services...');

    try {
      _clipboard.stopPolling();
    } catch (e) {
      _log.error('APP', 'Error stopping clipboard: $e');
    }
    try {
      await _discovery.stopAdvertising();
    } catch (e) {
      _log.error('APP', 'Error stopping discovery: $e');
    }
    try {
      await _ws.stopServer();
    } catch (e) {
      _log.error('APP', 'Error stopping websocket server: $e');
    }
    try {
      await _commandSub?.cancel();
    } catch (e) {
      _log.error('APP', 'Error canceling command sub: $e');
    }
    try {
      await _clipboardSub?.cancel();
    } catch (e) {
      _log.error('APP', 'Error canceling clipboard sub: $e');
    }

    _isRunning = false;
    _port = null;
    notifyListeners();
    _log.info('APP', 'Services stopped');
  }

  /// Route incoming WebSocket commands.
  Future<void> _executeCommand(Map<String, dynamic> command) async {
    // Structured key press commands — check BEFORE prompt to avoid
    // routing type:'key_press' commands (that also carry 'prompt') to LLM.
    if (command['type'] == 'key_press') {
      await _handleStructuredKeyPress(command);
      return;
    }

    // Scheduled/recurring actions — also check before generic prompt
    if (command['type'] == 'schedule') {
      await _handleScheduleCommand(command);
      return;
    }

    if (command['type'] == 'kill_switch') {
      _handleKillSwitch(command);
      return;
    }

    // Natural language prompts → forward to LLM
    if (command.containsKey('prompt')) {
      await _handlePrompt(command);
      return;
    }

    // Schedule cancellation
    if (command['type'] == 'schedule_cancel') {
      _handleScheduleCancel(command);
      return;
    }

    String? action = command['action'];
    Map<String, dynamic>? payload;

    if (command.containsKey('type')) {
      final type = command['type'] as String;
      payload = command['payload'] as Map<String, dynamic>?;

      if (type == 'open_url') {
        action = 'open_url';
      } else if (type == 'clipboard.text_copied') {
        await _handleClipboardSync(payload);
        return;
      } else if (type == 'clipboard.image_copied') {
        await _handleImageClipboardSync(payload);
        return;
      } else if (type == 'register_triggers') {
        _triggers.handleRegisterTriggers(payload ?? {});
        return;
      } else if (command['source'] == 'extension') {
        _handleExtensionMessage(command);
        return;
      }
    }

    final urlString = payload?['url'] ?? command['url'];
    switch (action) {
      case 'open_url':
        if (urlString != null) {
          final uri = Uri.parse(urlString);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri);
            _log.info('CMD', 'Launched $urlString');
          } else {
            _log.warn('CMD', 'Could not launch $urlString');
          }
        }
        break;
      default:
        if (command.containsKey('source') && command['source'] == 'extension') {
          _handleExtensionMessage(command);
        } else {
          _log.debug('CMD', 'Unknown command: $action / ${command['type']}');
        }
    }
  }

  Future<void> _handlePrompt(Map<String, dynamic> command) async {
    final prompt = command['prompt']?.toString() ?? '';
    final transactionId = command['transactionId']?.toString() ?? '';

    // Deduplication: skip if this transaction was already processed
    if (transactionId.isNotEmpty &&
        _processedTransactions.contains(transactionId)) {
      _log.debug('CMD', 'Skipping duplicate prompt (txn=$transactionId)');
      return;
    }
    if (transactionId.isNotEmpty) {
      _processedTransactions.add(transactionId);
      // Prevent memory leak: cap at 100 entries
      if (_processedTransactions.length > 100) {
        _processedTransactions.remove(_processedTransactions.first);
      }
    }

    _log.info('CMD', 'Received prompt: "$prompt" (txn=$transactionId)');

    // Send immediate acknowledgment back to Android
    _sendPromptResponse(transactionId, 'started', 'Processing command...');

    // Auto-start Ollama if needed
    final aiNotifier = getIt<AiProviderNotifier>();
    if (aiNotifier.config.providerType == AiProviderType.ollama) {
      final isAvailable = await aiNotifier.activeService.isAvailable();
      if (!isAvailable) {
        _sendPromptResponse(transactionId, 'in_progress', 'Starting local AI service (Ollama)...');
        await aiNotifier.ensureOllamaRunning();
      }
    }

    // ── Step 1: Classify prompt (browser vs desktop) ──
    bool isBrowserRelated = command['target'] == 'browser';

    // ── Step 1a: Keyword pre-classification (fast, no LLM cost) ──
    if (!isBrowserRelated) {
      final pLower = prompt.toLowerCase();
      // Media keywords — these are almost always web tasks
      const mediaKeywords = ['play ', 'watch ', 'stream ', 'listen to '];
      const webKeywords = [
        'youtube',
        'browser',
        'website',
        'http',
        '.com',
        '.org',
        '.net',
        'amazon',
        'search the web',
        'google',
        'spotify',
        'netflix',
        'search for',
        'search online',
        'look up',
        'find online',
        'twitter',
        'reddit',
        'instagram',
        'facebook',
        'tiktok',
        'open website',
        'go to site',
        'navigate to',
      ];
      // Desktop context words — if present alongside media keywords,
      // the task is local (e.g. "play the presentation", "play this file")
      const desktopContextWords = [
        'presentation',
        'slideshow',
        'powerpoint',
        'pptx',
        'ppt',
        'file',
        'folder',
        'document',
        'pdf',
        'excel',
        'word',
        'local',
        'vlc',
        'media player',
        'winamp',
        'foobar',
        'desktop',
        'disk',
        'drive',
        'c:',
        'd:',
        'e:',
        'notepad',
        'calculator',
        'explorer',
        'terminal',
      ];
      // Check media keywords (prefix match to catch "play X", "watch Y")
      for (final kw in mediaKeywords) {
        if (pLower.startsWith(kw) || pLower.contains(' $kw')) {
          // Only treat as browser if no desktop/local context is present
          final hasDesktopContext = desktopContextWords.any(
            (dw) => pLower.contains(dw),
          );
          if (!hasDesktopContext) {
            isBrowserRelated = true;
            _log.info(
              'CMD',
              'Pre-classified as BROWSER (media keyword: "$kw")',
            );
            break;
          } else {
            _log.info(
              'CMD',
              'Skipped browser pre-classification — desktop context detected for "$kw"',
            );
          }
        }
      }
      // Check web keywords
      if (!isBrowserRelated) {
        for (final kw in webKeywords) {
          if (pLower.contains(kw)) {
            isBrowserRelated = true;
            _log.info('CMD', 'Pre-classified as BROWSER (web keyword: "$kw")');
            break;
          }
        }
      }
    }

    // ── Step 1b: LLM classification (only if keywords didn't match) ──
    if (!isBrowserRelated) {
      try {
        final aiNotifier = getIt<AiProviderNotifier>();
        final aiService = aiNotifier.activeService;
        _log.info('CMD', 'Classifying prompt via LLM...');
        final classifyResponse = await aiService.chat([
          AiMessage(
            role: AiMessageRole.user,
            content:
                'Classify this user prompt into one word: "browser" or "desktop".\n'
                '- browser: tasks involving websites, web search, online content, streaming videos/music/songs from the internet, shopping, social media, looking things up online\n'
                '- desktop: tasks involving local files, presentations, slideshows, system settings, installed apps, folders, screenshots, opening local programs\n\n'
                'Examples:\n'
                '  "play one piece intro" → browser\n'
                '  "play lofi music" → browser\n'
                '  "search for python tutorials" → browser\n'
                '  "open Notepad" → desktop\n'
                '  "take a screenshot" → desktop\n'
                '  "play the presentation" → desktop\n'
                '  "play the slideshow" → desktop\n'
                '  "open the powerpoint" → desktop\n'
                '  "open my document" → desktop\n\n'
                'Prompt: "$prompt"\n\nReply with ONLY one word.',
          ),
        ]);
        final classification =
            classifyResponse.content?.trim().toLowerCase() ?? '';
        isBrowserRelated = classification.contains('browser');
        _log.info(
          'CMD',
          'LLM classified as: ${isBrowserRelated ? "BROWSER" : "DESKTOP"} (raw: $classification)',
        );
      } catch (e) {
        _log.warn(
          'CMD',
          'LLM classification failed, defaulting to desktop: $e',
        );
      }
    }

    if (isBrowserRelated) {
      if (!_ws.hasExtensionClient) {
        _log.info('CMD', 'Extension not connected — launching browser...');
        _sendPromptResponse(
          transactionId,
          'in_progress',
          'Launching browser...',
        );
        final launched = await _ensureBrowserRunning();
        if (!launched) {
          _log.error(
            'CMD',
            'Could not launch browser or extension did not connect',
          );
          _sendPromptResponse(
            transactionId,
            'failed',
            'Could not launch browser or extension did not connect.',
          );
          return;
        }
      }

      final aiNotifier = getIt<AiProviderNotifier>();
      if (aiNotifier.config.providerType == AiProviderType.webBased) {
        _ws.broadcastEvent({
          'type': 'execute_prompt',
          'payload': command,
          'target': 'extension',
        });
        _log.info(
          'CMD',
          'Forwarded prompt to Browser Extension for Web LLM planning',
        );
        _sendPromptResponse(
          transactionId,
          'in_progress',
          'Sent to Browser Extension...',
        );
      } else {
        // ── Agentic DOM-aware loop ──
        await _handleBrowserPromptAgentic(prompt, transactionId, aiNotifier);
      }
    } else {
      // It's a localized OS desktop task
      _log.info(
        'CMD',
        'Classified as DESKTOP task. Routing to Desktop Agent...',
      );
      _sendPromptResponse(
        transactionId,
        'in_progress',
        'Running on Desktop Agent...',
      );
      try {
        final desktopProvider = getIt<DesktopAutomationProvider>();
        await desktopProvider.runGoal(
          prompt,
          onProgress: (msg) {
            _sendPromptResponse(transactionId, 'in_progress', msg);
          },
        );
        // Check if the agent actually succeeded
        if (desktopProvider.hasError) {
          _sendPromptResponse(
            transactionId,
            'failed',
            desktopProvider.lastError ?? 'Desktop task failed.',
          );
        } else {
          _sendPromptResponse(
            transactionId,
            'completed',
            'Desktop task completed successfully.',
          );
        }
      } on NeedsBrowserException catch (e) {
        // Desktop Agent determined this is actually a web task — re-route
        _log.info('CMD', 'Desktop Agent re-routing to browser: ${e.message}');
        _sendPromptResponse(
          transactionId,
          'in_progress',
          'Re-routing to browser...',
        );

        if (!_ws.hasExtensionClient) {
          final launched = await _ensureBrowserRunning();
          if (!launched) {
            _sendPromptResponse(
              transactionId,
              'failed',
              'Could not launch browser with extension.',
            );
            return;
          }
        }

        final aiNotifier = getIt<AiProviderNotifier>();
        await _handleBrowserPromptAgentic(prompt, transactionId, aiNotifier);
      } catch (e) {
        _log.error('CMD', 'Failed to route to Desktop Agent: $e');
        _sendPromptResponse(transactionId, 'failed', 'Desktop Agent error: $e');
      }
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  AGENTIC DOM-AWARE BROWSER LOOP
  // ═══════════════════════════════════════════════════════════

  Future<void> _handleBrowserPromptAgentic(
    String prompt,
    String transactionId,
    AiProviderNotifier aiNotifier,
  ) async {
    _log.info('CMD', 'Starting agentic browser loop for: "$prompt"');

    // ── Pre-check: Is the AI provider reachable? ──
    if (aiNotifier.config.providerType == AiProviderType.ollama) {
      final isAvailable = await aiNotifier.activeService.isAvailable();
      if (!isAvailable) {
        _log.warn(
          'CMD',
          'Ollama is not reachable — checking for web AI fallback',
        );

        // Fallback: forward to browser extension's web-based AI (ChatGPT/Gemini)
        if (_ws.hasExtensionClient) {
          _log.info('CMD', 'Falling back to Browser Extension web AI planning');
          _sendPromptResponse(
            transactionId,
            'in_progress',
            'Ollama unavailable — using browser AI instead...',
          );
          _ws.broadcastEvent({
            'type': 'execute_prompt',
            'payload': {
              'prompt': prompt,
              'transactionId': transactionId,
              'target': 'browser',
            },
            'target': 'extension',
          });
          return;
        }

        // No fallback available — show setup guide
        _sendPromptResponse(
          transactionId,
          'failed',
          'Ollama is not running on this PC.\n\n'
              'To fix this:\n'
              '1. Install Ollama from ollama.com\n'
              '2. Open a terminal and run: ollama serve\n'
              '3. Pull a model: ollama pull qwen3\n\n'
              'Then try your command again.',
        );
        return;
      }
    }

    _sendPromptResponse(
      transactionId,
      'in_progress',
      'Planning browser actions...',
    );

    final aiService = aiNotifier.activeService;
    const maxSteps = 8;
    final List<Map<String, dynamic>> actionHistory = [];

    try {
      // ── Initial step: ask LLM for the first action (likely open_url) ──
      final initialResponse = await aiService.chat(
        [
          AiMessage(
            role: AiMessageRole.system,
            content: _agenticSystemPrompt(),
          ),
          AiMessage(
            role: AiMessageRole.user,
            content:
                'User goal: "$prompt"\n\nNo page is currently open. Decide the first action.',
          ),
        ],
        jsonSchema: {
          "type": "object",
          "properties": {
            "thought": {"type": "string"},
            "action": {"type": "object"},
            "done": {"type": "boolean"},
          },
        },
      );

      if (!initialResponse.success || initialResponse.content == null) {
        throw Exception('AI returned empty response for initial step');
      }

      var stepData = _extractJson(initialResponse.content!);
      if (stepData == null) throw Exception('Failed to parse initial AI step');

      for (int i = 0; i < maxSteps; i++) {
        // Check if LLM says we're done
        if (stepData!['done'] == true) {
          _log.info(
            'CMD',
            'Agentic loop: LLM reports goal achieved after $i steps',
          );
          _sendPromptResponse(
            transactionId,
            'completed',
            'Browser task completed successfully.',
          );
          _completedTransactions.add(transactionId);
          return;
        }

        final action = stepData['action'] as Map<String, dynamic>?;
        if (action == null) {
          _log.warn(
            'CMD',
            'Agentic loop: LLM returned no action, assuming done',
          );
          break;
        }

        final thought = stepData['thought']?.toString() ?? '';
        _log.info('CMD', 'Step ${i + 1}: ${action['action']} — $thought');
        _sendPromptResponse(
          transactionId,
          'in_progress',
          'Step ${i + 1}: ${action['action']}',
        );

        // ── Send single step to extension and wait for result ──
        final stepCompleter = Completer<Map<String, dynamic>>();
        _pendingStepResults[transactionId] = stepCompleter;

        _ws.sendToExtension({
          'type': 'execute_single_step',
          'payload': {
            'transaction_id': transactionId,
            'step': action,
            'step_index': i,
          },
        });

        // Wait for step result (up to 30s)
        Map<String, dynamic> stepResult;
        try {
          stepResult = await stepCompleter.future.timeout(
            const Duration(seconds: 45),
          );
        } catch (_) {
          _log.warn('CMD', 'Agentic loop: Step ${i + 1} timed out');
          _sendPromptResponse(
            transactionId,
            'failed',
            'Step ${i + 1} timed out.',
          );
          return;
        } finally {
          _pendingStepResults.remove(transactionId);
        }

        if (stepResult['status'] == 'error') {
          _log.warn('CMD', 'Step ${i + 1} failed: ${stepResult['message']}');
          // Don't fail immediately — let LLM decide recovery
        }

        // Record action history
        actionHistory.add({
          'step': i + 1,
          'action': action,
          'result': stepResult['status'],
          'error': stepResult['message'],
        });

        // ── Build DOM context for LLM ──
        final snapshot = stepResult['snapshot'] as Map<String, dynamic>?;
        String domContext = 'No DOM snapshot available.';
        if (snapshot != null) {
          final elements = snapshot['elements'] as List<dynamic>? ?? [];
          final domLines = elements.take(60).map((e) {
            final parts = <String>['id=${e['id']}', 'tag=${e['tag']}'];
            if (e['text'] != null && e['text'].toString().isNotEmpty)
              parts.add('text="${e['text']}"');
            if (e['ariaLabel'] != null) parts.add('aria="${e['ariaLabel']}"');
            if (e['placeholder'] != null)
              parts.add('placeholder="${e['placeholder']}"');
            if (e['role'] != null) parts.add('role=${e['role']}');
            if (e['href'] != null) parts.add('href="${e['href']}"');
            return parts.join(', ');
          }).toList();
          domContext =
              'Current page: ${snapshot['url']}\nTitle: ${snapshot['title']}\n\nInteractive elements (${elements.length} total, showing first ${domLines.length}):\n${domLines.join('\n')}';
        }

        // ── Ask LLM for next action ──
        final historyText = actionHistory
            .map(
              (h) =>
                  'Step ${h['step']}: ${(h['action'] as Map)['action']} → ${h['result']}',
            )
            .join('\n');

        final nextResponse = await aiService.chat(
          [
            AiMessage(
              role: AiMessageRole.system,
              content: _agenticSystemPrompt(),
            ),
            AiMessage(
              role: AiMessageRole.user,
              content:
                  'User goal: "$prompt"\n\n'
                  'Action history:\n$historyText\n\n'
                  '$domContext\n\n'
                  'Decide the NEXT single action, or set done=true if the goal is achieved.',
            ),
          ],
          jsonSchema: {
            "type": "object",
            "properties": {
              "thought": {"type": "string"},
              "action": {"type": "object"},
              "done": {"type": "boolean"},
            },
          },
        );

        if (!nextResponse.success || nextResponse.content == null) {
          _log.warn('CMD', 'Agentic loop: AI returned empty at step ${i + 2}');
          break;
        }

        stepData = _extractJson(nextResponse.content!);
        if (stepData == null) {
          // Log the raw response for debugging
          final rawPreview = nextResponse.content!.length > 300
              ? nextResponse.content!.substring(0, 300)
              : nextResponse.content!;
          _log.warn(
            'CMD',
            'Agentic loop: Failed to parse AI response at step ${i + 2}. Raw: $rawPreview',
          );

          // Retry: ask AI to reformat as valid JSON
          _log.info('CMD', 'Retrying with JSON correction prompt...');
          final retryResponse = await aiService.chat(
            [
              AiMessage(
                role: AiMessageRole.user,
                content:
                    'Your previous response was not valid JSON. Here it is:\n\n'
                    '${nextResponse.content}\n\n'
                    'Please reformat your answer as a single valid JSON object with these fields:\n'
                    '{"thought": "your reasoning", "action": {"action": "action_name", ...params}, "done": false}\n'
                    'Or if the goal is achieved: {"thought": "...", "done": true}\n'
                    'Output ONLY the JSON, nothing else.',
              ),
            ],
            jsonSchema: {
              "type": "object",
              "properties": {
                "thought": {"type": "string"},
                "action": {"type": "object"},
                "done": {"type": "boolean"},
              },
            },
          );

          if (retryResponse.success && retryResponse.content != null) {
            stepData = _extractJson(retryResponse.content!);
            if (stepData != null) {
              _log.info('CMD', 'JSON retry succeeded — continuing loop');
              continue;
            }
          }
          _log.warn('CMD', 'JSON retry also failed — ending loop');
          break;
        }
      }

      // If loop ends without explicit done, send completion
      if (!_completedTransactions.contains(transactionId)) {
        _sendPromptResponse(
          transactionId,
          'completed',
          'Browser task completed (${actionHistory.length} steps).',
        );
        _completedTransactions.add(transactionId);
      }
    } catch (e) {
      _log.error('CMD', 'Agentic loop failed: $e');
      // Detect Ollama-specific connection errors
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('connection refused') ||
          errorStr.contains('socketexception') ||
          errorStr.contains('ollama')) {
        _sendPromptResponse(
          transactionId,
          'failed',
          'Ollama server is not reachable.\n\n'
              'Make sure Ollama is running:\n'
              '1. Open a terminal and run: ollama serve\n'
              '2. Then try your command again.',
        );
      } else {
        _sendPromptResponse(
          transactionId,
          'failed',
          'Browser automation failed: $e',
        );
      }
    }
  }

  String _agenticSystemPrompt() {
    return '''You are a browser automation agent. Given the user's goal, the current page DOM, and action history, decide the NEXT SINGLE action to perform.

Return JSON only with this exact schema:
{
  "thought": "brief reasoning about what to do next",
  "action": {
    "action": "ACTION_NAME",
    "params": { ... }
  },
  "done": false
}

Set "done": true and action to null when the user's goal is fully achieved.

Available actions:
- "open_url": params { "url": "https://..." }
- "click_element": params { "target_id": "el_X" } — use the element id from the DOM snapshot
- "type_into": params { "target_id": "el_X", "text": "text to type", "pressEnter": true/false }
- "press_key": params { "key": "Enter|Tab|Escape|ArrowDown" }
- "wait": params { "ms": 2000 }
- "scroll_to": params { "target_id": "el_X" }
- "play_media": params {} — clicks the video/audio play button and starts playback. Use this after landing on a video page.

RULES:
- Use target_id (e.g. "el_5") to reference elements from the DOM snapshot
- Only output ONE action per response
- After typing into a search box, use press_key with Enter to submit
- After navigating to search results, prioritize clicking the first relevant result. For YouTube, look for elements with tag 'ytd-video-renderer' or links containing '/watch'.
- MEDIA PLAYBACK: When the goal involves playing a video, song, or media:
  1. Navigate to the site, search, and click the result to reach the video page.
  2. Once on the video/watch page, use the "play_media" action to start playback.
  3. After play_media, set done=true on the NEXT step.
  4. Do NOT set done=true until you have used play_media on the video page.
- Maximum 8 steps total
- Output ONLY the JSON, nothing else.''';
  }

  /// Extract JSON from potentially messy LLM output.
  Map<String, dynamic>? _extractJson(String raw) {
    final trimmed = raw.trim();
    try {
      final objStart = trimmed.indexOf('{');
      final objEnd = trimmed.lastIndexOf('}');
      if (objStart != -1 && objEnd > objStart) {
        return jsonDecode(trimmed.substring(objStart, objEnd + 1))
            as Map<String, dynamic>;
      }
    } catch (_) {}
    try {
      final cleaned = trimmed
          .replaceAll('```json', '')
          .replaceAll('```', '')
          .trim();
      return jsonDecode(cleaned) as Map<String, dynamic>;
    } catch (_) {}
    return null;
  }

  void _handleExtensionMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    final transactionId = message['transaction_id']?.toString() ?? '';

    switch (type) {
      case 'execution_status':
        // Only log step-level updates, don't flood Android with every status
        final status = message['status']?.toString() ?? '';
        _log.info('EXT', '$status: ${message['message'] ?? ''}');
        if (transactionId.isNotEmpty && status == 'step') {
          _sendPromptResponse(
            transactionId,
            'in_progress',
            message['message']?.toString() ?? 'Executing...',
          );
        }
        break;
      case 'execution_result':
        // One-shot fallback path completion
        _log.info(
          'EXT',
          'Complete: ${message['status']} (${message['steps_executed']} steps)',
        );
        if (transactionId.isNotEmpty &&
            !_completedTransactions.contains(transactionId)) {
          final isSuccess =
              message['status'] == 'success' ||
              message['status'] == 'completed';
          _completedTransactions.add(transactionId);
          _sendPromptResponse(
            transactionId,
            isSuccess ? 'completed' : 'failed',
            isSuccess
                ? 'Browser task completed successfully.'
                : 'Browser task failed: ${message['error'] ?? 'Unknown error'}',
          );
        }
        break;
      case 'dom_snapshot':
        _log.info(
          'EXT',
          'DOM snapshot received (${message['snapshot']?['elementCount'] ?? 0} elements)',
        );
        if (transactionId.isNotEmpty &&
            _pendingDomSnapshots.containsKey(transactionId)) {
          _pendingDomSnapshots[transactionId]!.complete(message);
        }
        break;
      case 'step_result':
        _log.info(
          'EXT',
          'Step result: ${message['status']} (action=${message['action']})',
        );
        if (transactionId.isNotEmpty &&
            _pendingStepResults.containsKey(transactionId)) {
          _pendingStepResults[transactionId]!.complete(message);
        }
        break;
      case 'kill_switch_ack':
        _log.info('EXT', 'Kill switch acknowledged');
        break;
      case 'rule_triggered':
        _triggers.handleRuleTriggered(message);
        break;
      case 'log':
        final logMsg =
            message['message']?.toString() ?? message['data']?.toString() ?? '';
        _log.info('EXT', 'Log: $logMsg');
        break;
      default:
        _log.debug('EXT', 'Message: $type ${message.keys.join(', ')}');
    }
  }

  Future<void> _handleClipboardSync(Map<String, dynamic>? payload) async {
    final text = payload?['text'] as String?;
    if (text == null || text.isEmpty) return;
    await _clipboard.writeFromRemote(text);
  }

  /// Handle image clipboard sync from Android → Desktop.
  Future<void> _handleImageClipboardSync(Map<String, dynamic>? payload) async {
    final base64Data = payload?['image_base64'] as String?;
    final mimeType = payload?['mime_type'] as String? ?? 'image/png';
    if (base64Data == null || base64Data.isEmpty) return;

    try {
      final bytes = base64Decode(base64Data);
      final extension = mimeType.contains('jpeg') || mimeType.contains('jpg')
          ? 'jpg'
          : 'png';
      final tempDir = Directory.systemTemp;
      final tempFile = File(
        '${tempDir.path}/autonion_clipboard_sync.$extension',
      );
      await tempFile.writeAsBytes(bytes);
      _log.info(
        'Clipboard',
        'Received image from Android: ${bytes.length ~/ 1024}KB ($mimeType)',
      );

      // Copy image to system clipboard using platform-native approach
      if (Platform.isWindows) {
        // PowerShell: Load image and set to clipboard
        final escapedPath = tempFile.path.replaceAll('\\', '\\\\');
        final psScript =
            "Add-Type -AssemblyName System.Windows.Forms; "
            "\$img = [System.Drawing.Image]::FromFile('$escapedPath'); "
            "[System.Windows.Forms.Clipboard]::SetImage(\$img)";
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          psScript,
        ]);
        if (result.exitCode == 0) {
          _log.info('Clipboard', 'Image synced to Windows clipboard');
        } else {
          _log.warn(
            'Clipboard',
            'PowerShell clipboard failed: ${result.stderr}',
          );
        }
      } else if (Platform.isMacOS) {
        // macOS: use osascript
        await Process.run('osascript', [
          '-e',
          'set the clipboard to (read (POSIX file "${tempFile.path}") as TIFF picture)',
        ]);
        _log.info('Clipboard', 'Image synced to macOS clipboard');
      } else if (Platform.isLinux) {
        // Linux: use xclip
        await Process.run('xclip', [
          '-selection',
          'clipboard',
          '-t',
          mimeType,
          '-i',
          tempFile.path,
        ]);
        _log.info('Clipboard', 'Image synced to Linux clipboard');
      }
    } catch (e) {
      _log.error('Clipboard', 'Failed to sync image clipboard: $e');
    }
  }

  Future<bool> _ensureBrowserRunning() async {
    final launched = await _browser.launchBrowser();
    if (!launched) return false;
    if (_ws.hasExtensionClient) return true;

    _log.info('CMD', 'Waiting for extension to connect (up to 15s)...');
    try {
      await _ws.extensionConnectionStream
          .where((c) => c)
          .first
          .timeout(const Duration(seconds: 15));
      _log.info('CMD', 'Extension connected after browser launch!');
      return true;
    } catch (_) {
      _log.warn('CMD', 'Extension did not connect within 15 seconds');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  TWO-WAY COMMUNICATION — Send responses back to Android
  // ═══════════════════════════════════════════════════════════

  /// Send a response back to the Android client for a given transaction.
  void _sendPromptResponse(
    String transactionId,
    String status,
    String message, {
    Map<String, String>? data,
  }) {
    if (transactionId.isEmpty) return;
    _ws.broadcastEvent({
      'type': 'prompt_response',
      'transactionId': transactionId,
      'status': status,
      'message': message,
      if (data != null) 'data': data,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  // ═══════════════════════════════════════════════════════════
  //  STRUCTURED COMMAND HANDLERS (skip LLM)
  // ═══════════════════════════════════════════════════════════

  /// Handle a structured key press command directly (no LLM needed).
  /// Supports both single keys and multi-key combos via the 'keys' array.
  Future<void> _handleStructuredKeyPress(Map<String, dynamic> command) async {
    final transactionId = command['transactionId']?.toString() ?? '';

    // Prefer the 'keys' array; fall back to splitting the legacy 'keyName'
    List<String> keys;
    if (command['keys'] is List && (command['keys'] as List).isNotEmpty) {
      keys = (command['keys'] as List).map((k) => k.toString().toLowerCase()).toList();
    } else {
      final keyName = command['keyName']?.toString() ?? '';
      keys = keyName.contains('+')
          ? keyName.split('+').map((k) => k.trim().toLowerCase()).toList()
          : [keyName.toLowerCase()];
    }

    // Map user-friendly names to pyautogui key names
    keys = keys.map((k) {
      switch (k) {
        case 'up arrow': return 'up';
        case 'down arrow': return 'down';
        case 'left arrow': return 'left';
        case 'right arrow': return 'right';
        case 'return': return 'enter';
        case 'page_up': return 'pageup';
        case 'page_down': return 'pagedown';
        case 'caps_lock': return 'capslock';
        case 'print_screen': return 'printscreen';
        case 'num_lock': return 'numlock';
        case 'scroll_lock': return 'scrolllock';
        default: return k;
      }
    }).toList();

    final keyLabel = keys.join('+');
    _log.info('CMD', 'Structured key_press: $keyLabel (${keys.length} keys)');

    try {
      final desktopProvider = getIt<DesktopAutomationProvider>();
      await desktopProvider.bridge.sendCommand('execute_action', {
        'type': 'hotkey',
        'keys': keys,
      });
      _sendPromptResponse(transactionId, 'completed', 'Pressed key: $keyLabel');
    } catch (e) {
      _log.error('CMD', 'Key press failed: $e');
      _sendPromptResponse(transactionId, 'failed', 'Key press failed: $e');
    }
  }

  /// Active scheduled timers, keyed by transaction ID.
  final Map<String, Timer> _scheduledTimers = {};

  /// Handle a scheduled/recurring action command.
  Future<void> _handleScheduleCommand(Map<String, dynamic> command) async {
    final transactionId = command['transactionId']?.toString() ?? '';
    final intervalMs = command['intervalMs'] as int? ?? 60000;
    final action = command['action'] as Map<String, dynamic>?;
    final repeatCount = command['repeatCount'] as int?;
    final keyName = action?['keyName']?.toString() ?? 'unknown';

    _log.info(
      'CMD',
      'Scheduling: $keyName every ${intervalMs}ms'
          '${repeatCount != null ? ' ($repeatCount times)' : ''}',
    );

    _sendPromptResponse(
      transactionId,
      'scheduled',
      'Timer started: pressing $keyName every ${intervalMs ~/ 1000}s',
    );

    int count = 0;
    _scheduledTimers[transactionId] = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (timer) {
        count++;
        _log.info('CMD', 'Scheduled tick #$count: $keyName');

        try {
          final desktopProvider = getIt<DesktopAutomationProvider>();
          desktopProvider.bridge.sendCommand('execute_action', {
            'type': 'hotkey',
            'keys': [keyName],
          });
        } catch (e) {
          _log.error('CMD', 'Scheduled key press failed: $e');
        }

        _sendPromptResponse(
          transactionId,
          'in_progress',
          'Tick #$count: pressed $keyName',
        );

        if (repeatCount != null && count >= repeatCount) {
          timer.cancel();
          _scheduledTimers.remove(transactionId);
          _sendPromptResponse(
            transactionId,
            'completed',
            'Scheduled task completed ($count iterations)',
          );
        }
      },
    );
  }

  /// Handle schedule cancellation.
  void _handleScheduleCancel(Map<String, dynamic> command) {
    final transactionId = command['transactionId']?.toString() ?? '';
    final timer = _scheduledTimers.remove(transactionId);
    if (timer != null) {
      timer.cancel();
      _sendPromptResponse(
        transactionId,
        'cancelled',
        'Scheduled task stopped.',
      );
      _log.info('CMD', 'Cancelled scheduled task: $transactionId');
    }
  }

  void _handleKillSwitch(Map<String, dynamic> command) {
    _log.info('CMD', 'Received global kill_switch');
    // Stop local desktop agent
    try {
      final desktopProvider = getIt<DesktopAutomationProvider>();
      desktopProvider.stop();
    } catch (e) {
      _log.error('CMD', 'Failed to stop DesktopAutomationProvider: $e');
    }

    // Forward to extension
    _ws.sendToExtension({'type': 'kill_switch'});

    // Optional: send response back to Android
    final transactionId = command['transactionId']?.toString();
    if (transactionId != null && transactionId.isNotEmpty) {
      _sendPromptResponse(
        transactionId,
        'cancelled',
        'Automation stopped by user.',
      );
    }
  }

  @override
  void dispose() {
    stopServices();
    super.dispose();
  }
}
