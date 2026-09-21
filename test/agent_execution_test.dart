import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:autonion_cross_device/core/services/logging_service.dart';
import 'package:autonion_cross_device/features/ai/models/ai_message.dart';
import 'package:autonion_cross_device/features/ai/models/ai_response.dart';
import 'package:autonion_cross_device/features/ai/providers/ai_provider_notifier.dart';
import 'package:autonion_cross_device/features/ai/services/ai_service.dart';
import 'package:autonion_cross_device/features/desktop_automation/models/automation_tier.dart';
import 'package:autonion_cross_device/features/desktop_automation/models/desktop_action.dart';
import 'package:autonion_cross_device/features/desktop_automation/models/screen_state.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/task_intent.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/agent_run.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/desktop_agent_service.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/accessibility_tree_service.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/input_simulation_service.dart';
import 'package:autonion_cross_device/features/desktop_automation/services/python_bridge_service.dart';
import 'package:autonion_cross_device/features/browser_automation/services/browser_step.dart';

class ScriptedAi extends AiService {
  final List<String> replies;
  int calls = 0;
  final requests = <List<AiMessage>>[];
  ScriptedAi(this.replies);
  @override
  String get providerName => 'test';
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<AiResponse> chat(
    List<AiMessage> messages, {
    Map<String, dynamic>? jsonSchema,
  }) async {
    requests.add(messages);
    return AiResponse.success(replies[calls++]);
  }
}

class TestAiProvider extends AiProviderNotifier {
  final AiService service;
  int starts = 0;
  TestAiProvider(this.service) : super(log: LoggingService());
  @override
  AiService get activeService => service;
  @override
  Future<bool> ensureOllamaRunning() async {
    starts++;
    return true;
  }
}

class TestInput extends InputSimulationService {
  final List<String> opened = [];
  int dispatched = 0;
  bool failLaunch = false;
  bool verifiedScreenshot = false;
  TestInput(PythonBridgeService bridge)
    : super(log: LoggingService(), bridge: bridge);
  @override
  Future<Map<String, dynamic>> openApp(String name) async {
    opened.add(name);
    if (failLaunch) throw PythonBridgeException('Native app not found');
    return {
      'status': 'verified',
      'window': {'hwnd': 10},
      'identity': 'test',
    };
  }

  @override
  Future<Map<String, dynamic>> execute(DesktopAction action) async {
    dispatched++;
    if (action.type == 'take_screenshot' && verifiedScreenshot) {
      return {
        'status': 'executed',
        'verified': true,
        'filepath': 'test-screenshot.png',
      };
    }
    return {'status': 'executed'};
  }
}

class TestObservation extends AccessibilityTreeService {
  int observations = 0;
  TestObservation(PythonBridgeService bridge)
    : super(log: LoggingService(), bridge: bridge);
  @override
  Future<ScreenState> getScreenState(
    AutomationTier tier, {
    bool preferLastLaunchedApp = false,
    String? preferredAppName,
    String? preferredAppPath,
  }) async {
    observations++;
    return ScreenState.fromJson({
      'screenWidth': 1920,
      'screenHeight': 1080,
      'activeWindowTitle': 'Editor',
      'elementTreeHash': 'unchanged',
      'elements': [
        {
          'id': 'node_0',
          'name': 'Editor',
          'role': 'textbox',
          'type': 'edit',
          'boundingBox': <String, dynamic>{},
        },
      ],
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'native launch and negated website remain desktop through corrections',
    () {
      final first = TaskIntent.resolve('open chatgpt app');
      expect(first.appName, 'chatgpt');
      expect(first.allowsBrowser, isFalse);
      final correction = TaskIntent.resolve(
        'I asked to open the app not the website',
        previous: first,
      );
      expect(correction.goal, 'Open the installed chatgpt application.');
      expect(correction.allowsBrowser, isFalse);
      expect(
        TaskIntent.resolve('the chatgpt app', previous: correction).appName,
        'chatgpt',
      );
      expect(
        TaskIntent.resolve('open Spotify desktop app').surface,
        TaskSurface.desktop,
      );
      expect(
        TaskIntent.resolve('open Google Chrome').surface,
        TaskSurface.desktop,
      );
    },
  );
  test(
    'file, mixed, and explicit browser requests do not use native shortcut',
    () {
      for (final goal in [
        'open my document',
        'open C:\\work\\report.pdf',
        'open Paint and draw a line',
        'open https://chatgpt.com',
      ]) {
        expect(TaskIntent.launchAppName(goal), isNull, reason: goal);
      }
      expect(
        TaskIntent.resolve(
          'search for a local file',
          target: 'desktop',
        ).allowsBrowser,
        isFalse,
      );
      expect(
        TaskIntent.resolve('open the ChatGPT website').surface,
        TaskSurface.browser,
      );
      expect(
        TaskIntent.resolve('open chatgpt', target: 'browser').surface,
        TaskSurface.browser,
      );
    },
  );
  test('unrelated request does not inherit a previous native target', () {
    final first = TaskIntent.resolve('open ChatGPT app');
    expect(
      TaskIntent.resolve('take a screenshot', previous: first).appName,
      isNull,
    );
    final compound = 'actually open Paint and draw a line';
    expect(TaskIntent.resolve(compound, previous: first).goal, compound);
    final website = TaskIntent.resolve('open the ChatGPT website');
    expect(
      TaskIntent.resolve(
        'I asked to open the app not the website',
        previous: website,
      ).appName,
      'ChatGPT',
    );
  });
  test(
    'cancellation is permanent for the old run; late results are discarded',
    () async {
      final old = AgentRun('old', 'phone');
      final pending = Completer<int>();
      final outcome = expectLater(
        old.wait(pending.future),
        throwsA(isA<AgentCancelledException>()),
      );
      old.cancel();
      final next = AgentRun('next', 'phone');
      await outcome;
      pending.complete(1);
      expect(old.isCancelled, isTrue);
      expect(await next.wait(Future.value(2)), 2);
    },
  );
  test('native launch bypasses UI observation and the model', () async {
    final bridge = PythonBridgeService(log: LoggingService());
    final ai = TestAiProvider(ScriptedAi([]));
    final input = TestInput(bridge);
    final observation = TestObservation(bridge);
    final agent = DesktopAgentService(
      log: LoggingService(),
      aiProvider: ai,
      a11y: observation,
      input: input,
    );
    await agent.runTask('open ChatGPT app', allowBrowser: false);
    expect(input.opened, ['ChatGPT']);
    expect(ai.starts, 0);
    expect(observation.observations, 0);
    expect(agent.status, AgentStatus.complete);
    input.failLaunch = true;
    await agent.runTask('open Missing app');
    expect(agent.status, AgentStatus.error);
    expect(input.dispatched, 0);
  });
  test('a screenshot is complete only when its file was verified', () async {
    final bridge = PythonBridgeService(log: LoggingService());
    final ai = TestAiProvider(ScriptedAi([]));
    final input = TestInput(bridge);
    final agent = DesktopAgentService(
      log: LoggingService(),
      aiProvider: ai,
      a11y: TestObservation(bridge),
      input: input,
    );
    await agent.runTask('take a screenshot');
    expect(agent.status, AgentStatus.error);
    input.verifiedScreenshot = true;
    await agent.runTask('take a screenshot');
    expect(agent.status, AgentStatus.complete);
    expect(
      agent.actionHistory.single['result']['filepath'],
      'test-screenshot.png',
    );
    expect(ai.starts, 0);
  });
  test(
    'a done proposal is rejected when independent observation verification fails',
    () async {
      final bridge = PythonBridgeService(log: LoggingService());
      final ai = ScriptedAi([
        '{"action":{"type":"done"}}',
        '{"achieved":false,"evidence":"Document is unsaved"}',
      ]);
      final agent = DesktopAgentService(
        log: LoggingService(),
        aiProvider: TestAiProvider(ai),
        a11y: TestObservation(bridge),
        input: TestInput(bridge),
      );
      await agent.runTask('save this document');
      expect(agent.status, AgentStatus.error);
      expect(ai.calls, 2);
    },
  );
  test('repeated unchanged actions fail instead of auto-completing', () async {
    final bridge = PythonBridgeService(log: LoggingService());
    final action = jsonEncode({
      'action': {
        'type': 'hotkey',
        'keys': ['enter'],
      },
    });
    final ai = ScriptedAi([action, action, action]);
    final agent = DesktopAgentService(
      log: LoggingService(),
      aiProvider: TestAiProvider(ai),
      a11y: TestObservation(bridge),
      input: TestInput(bridge),
    );
    await agent.runTask('confirm this dialog');
    expect(agent.status, AgentStatus.error);
    expect(agent.lastError, contains('progress'));
  });
  test(
    'browser actions are validated and only ineffective repetition is stopped',
    () {
      expect(
        validateBrowserAction({'action': 'invented', 'params': {}}),
        isNotNull,
      );
      expect(
        validateBrowserAction({
          'action': 'open_url',
          'params': {'url': 'javascript:alert(1)'},
        }),
        isNotNull,
      );
      final click = {
        'action': 'click_element',
        'params': {'target_id': 'el_1'},
      };
      expect(validateBrowserAction(click), isNull);
      final guard = BrowserProgressGuard();
      expect(guard.stalled(click, 'before', 'after'), isFalse);
      expect(guard.stalled(click, 'after', 'after'), isFalse);
      expect(guard.stalled(click, 'after', 'after'), isTrue);
    },
  );
  test(
    'desktop uses its run-specific model and keeps device context separate',
    () async {
      final bridge = PythonBridgeService(log: LoggingService());
      final configured = ScriptedAi([]);
      final reasoning = ScriptedAi([
        '{"action":{"type":"done"}}',
        '{"achieved":true,"evidence":"The document title has no unsaved marker"}',
        '{"action":{"type":"done"}}',
        '{"achieved":true,"evidence":"The document title has no unsaved marker"}',
      ]);
      final observations = TestObservation(bridge);
      final agent = DesktopAgentService(
        log: LoggingService(),
        aiProvider: TestAiProvider(configured),
        a11y: observations,
        input: TestInput(bridge),
      );
      await agent.runTask(
        'save this document',
        run: AgentRun('a', 'phone-a'),
        conversationContext: 'Private conversation for phone A',
        resolveAi: () async => reasoning,
      );
      await agent.runTask(
        'save this document',
        run: AgentRun('b', 'phone-b'),
        resolveAi: () async => reasoning,
      );
      expect(agent.status, AgentStatus.complete);
      expect(configured.calls, 0);
      expect(
        observations.observations,
        4,
      ); // New observation after each done proposal.
      expect(
        reasoning.requests[0].last.content,
        contains('Private conversation'),
      );
      expect(
        reasoning.requests[2].last.content,
        isNot(contains('Private conversation')),
      );
    },
  );
}
