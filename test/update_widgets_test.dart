import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:autonion_cross_device/core/di/service_locator.dart';
import 'package:autonion_cross_device/features/system/services/update_service.dart';
import 'package:autonion_cross_device/ui/screens/settings_screen.dart';
import 'package:autonion_cross_device/ui/widgets/update_banner.dart';
import 'package:autonion_cross_device/ui/widgets/update_release_button.dart';

void main() {
  tearDown(() async => getIt.reset());

  UpdateService register(http.Response response) {
    final service = UpdateService(client: MockClient((_) async => response));
    getIt.registerSingleton<UpdateService>(
      service,
      dispose: (value) => value.dispose(),
    );
    return service;
  }

  testWidgets('Settings shows the manual check result and last check time', (
    tester,
  ) async {
    register(http.Response(jsonEncode({'tag_name': 'v2.0.5'}), 200));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SettingsScreen())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for Updates'));
    await tester.pumpAndSettle();
    expect(find.textContaining('You’re up to date'), findsOneWidget);
    expect(find.textContaining('Last checked:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings reports a failed check', (tester) async {
    register(http.Response('{}', 500));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SettingsScreen())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for Updates'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not check for updates'), findsOneWidget);
  });

  testWidgets(
    'dismissed updates remain accessible in Settings at narrow desktop size',
    (tester) async {
      tester.view.physicalSize = const Size(700, 550);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = register(
        http.Response(
          jsonEncode({
            'tag_name': 'v2.0.7',
            'html_url': '${UpdateService.releasesUrl}/tag/v2.0.7',
          }),
          200,
        ),
      );
      await service.checkForUpdate();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                UpdateBanner(),
                Expanded(child: SettingsScreen()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('View release'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('View release'), findsOneWidget);
      expect(find.text('v2.0.7 Available'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final throws in [false, true]) {
    testWidgets(
      'browser launch ${throws ? 'exception' : 'failure'} is visible',
      (tester) async {
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (throws) throw PlatformException(code: 'no_browser');
            return false;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: UpdateReleaseButton(
                url: '${UpdateService.releasesUrl}/tag/v2.0.7',
              ),
            ),
          ),
        );
        await tester.tap(find.text('View release'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not open your browser'),
          findsOneWidget,
        );
      },
    );
  }
}
