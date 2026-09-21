import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:autonion_cross_device/features/system/services/update_service.dart';

http.Response release(String tag, {Map<String, Object?> extra = const {}}) =>
    http.Response(
      jsonEncode({
        'tag_name': tag,
        'html_url': '${UpdateService.releasesUrl}/tag/$tag',
        'body': 'Changes in this release',
        'prerelease': false,
        'draft': false,
        ...extra,
      }),
      200,
    );

void main() {
  test(
    'detects a newer stable release with metadata and exposes release details',
    () async {
      final service = UpdateService(
        currentVersion: '2.0.6+1',
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://api.github.com/repos/Autonion/Autonion-Agent/releases/latest',
          );
          expect(request.headers['Accept'], 'application/vnd.github+json');
          expect(request.headers['Authorization'], isNull);
          return release('v2.0.7+1');
        }),
      );
      addTearDown(service.dispose);
      await service.checkForUpdate();
      expect(service.status, UpdateStatus.available);
      expect(service.updateAvailable, isTrue);
      expect(service.latestVersion, '2.0.7+1');
      expect(service.releaseUrl, '${UpdateService.releasesUrl}/tag/v2.0.7+1');
      expect(service.releaseNotes, 'Changes in this release');
      expect(service.lastCheckedAt, isNotNull);
    },
  );

  for (final tag in ['v2.0.5', '2.0.6', 'v2.0.6+99']) {
    test('$tag does not offer a downgrade or metadata-only update', () async {
      final service = UpdateService(
        currentVersion: '2.0.6+1',
        client: MockClient((_) async => release(tag)),
      );
      addTearDown(service.dispose);
      await service.checkForUpdate();
      expect(service.status, UpdateStatus.upToDate);
      expect(service.hasUpdate, isFalse);
      expect(service.statusMessage, contains('up to date'));
    });
  }

  for (final tag in ['v2.0.10', 'V2.1.0', '3.0.0']) {
    test('$tag is correctly ordered above 2.0.6', () async {
      final service = UpdateService(
        currentVersion: '2.0.6',
        client: MockClient((_) async => release(tag)),
      );
      addTearDown(service.dispose);
      await service.checkForUpdate();
      expect(service.status, UpdateStatus.available);
    });
  }

  test(
    'a stable release upgrades an installed prerelease of the same version',
    () async {
      final service = UpdateService(
        currentVersion: '2.0.7-beta.2',
        client: MockClient((_) async => release('v2.0.7')),
      );
      addTearDown(service.dispose);
      await service.checkForUpdate();
      expect(service.hasUpdate, isTrue);
    },
  );

  test('drafts and prereleases are never offered to stable users', () async {
    for (final response in [
      release('v3.0.0-beta.1'),
      release('v3.0.0', extra: {'draft': true}),
      release('v3.0.0', extra: {'prerelease': true}),
    ]) {
      final service = UpdateService(client: MockClient((_) async => response));
      await service.checkForUpdate();
      expect(service.hasUpdate, isFalse);
      expect(service.status, UpdateStatus.noRelease);
      service.dispose();
    }
  });

  test(
    'invalid versions and responses report errors, never up to date',
    () async {
      for (final response in [
        release('release-2.0.7'),
        release(''),
        http.Response('<html>error</html>', 200),
        http.Response('{}', 200),
        release('v2.0.7', extra: {'body': 42}),
      ]) {
        final service = UpdateService(
          client: MockClient((_) async => response),
        );
        await service.checkForUpdate();
        expect(service.status, UpdateStatus.error);
        expect(service.isChecking, isFalse);
        expect(service.hasUpdate, isFalse);
        expect(service.statusMessage, contains('Could not read'));
        service.dispose();
      }
    },
  );

  test(
    'missing and unexpected release URLs cannot become update actions',
    () async {
      for (final url in [
        '',
        'http://github.com/Autonion/Autonion-Agent/releases/tag/v2.0.7',
        'https://example.com/setup.exe',
        'https://github.com/other/repo/releases/tag/v2.0.7',
      ]) {
        final service = UpdateService(
          client: MockClient(
            (_) async => release('v2.0.7', extra: {'html_url': url}),
          ),
        );
        await service.checkForUpdate();
        expect(service.status, UpdateStatus.error);
        expect(service.hasUpdate, isFalse);
        service.dispose();
      }
    },
  );

  test(
    '404 clears an obsolete release and has a distinct user-visible result',
    () async {
      var response = release('v2.0.7');
      final service = UpdateService(client: MockClient((_) async => response));
      addTearDown(service.dispose);
      await service.checkForUpdate();
      response = http.Response('{}', 404);
      await service.checkForUpdate();
      expect(service.status, UpdateStatus.noRelease);
      expect(service.hasUpdate, isFalse);
      expect(service.releaseUrl, isNull);
      expect(service.releaseNotes, isNull);
    },
  );

  test(
    'failure preserves a previously discovered release while explaining the error',
    () async {
      var response = release('v2.0.7');
      final service = UpdateService(client: MockClient((_) async => response));
      addTearDown(service.dispose);
      await service.checkForUpdate();
      response = http.Response('{}', 500);
      await service.checkForUpdate();
      expect(service.status, UpdateStatus.error);
      expect(service.hasUpdate, isTrue);
      expect(service.statusMessage, contains('500'));
    },
  );

  test(
    'dismissal survives automatic checks, but not new releases or a manual check',
    () async {
      var tag = 'v2.0.7';
      final service = UpdateService(
        client: MockClient((_) async => release(tag)),
      );
      addTearDown(service.dispose);
      await service.checkForUpdate();
      service.dismiss();
      expect(service.hasUpdate, isTrue);
      expect(service.updateAvailable, isFalse);
      await service.checkForUpdate(manual: false);
      expect(service.updateAvailable, isFalse);
      tag = 'v2.0.8';
      await service.checkForUpdate(manual: false);
      expect(service.updateAvailable, isTrue);
      service.dismiss();
      await service.checkForUpdate();
      expect(service.updateAvailable, isTrue);
    },
  );

  test('simultaneous checks use one request', () async {
    final gate = Completer<http.Response>();
    var calls = 0;
    final service = UpdateService(
      client: MockClient((_) {
        calls++;
        return gate.future;
      }),
    );
    addTearDown(service.dispose);
    final pending = service.checkForUpdate();
    await Future<void>.delayed(Duration.zero);
    await service.checkForUpdate();
    expect(calls, 1);
    expect(service.isChecking, isTrue);
    gate.complete(release('v2.0.7'));
    await pending;
    expect(service.isChecking, isFalse);
  });

  test(
    'startup failure retries after five minutes, then checks every six hours',
    () {
      fakeAsync((time) {
        var calls = 0;
        final service = UpdateService(
          client: MockClient((_) async {
            calls++;
            if (calls == 1) throw http.ClientException('Offline');
            return release('v2.0.7');
          }),
        );
        service.startAutomaticChecks();
        service.startAutomaticChecks();
        time.flushMicrotasks();
        expect(calls, 1);
        expect(service.statusMessage, contains('internet connection'));
        time.elapse(const Duration(minutes: 4));
        expect(calls, 1);
        time.elapse(const Duration(minutes: 1));
        expect(calls, 2);
        expect(service.status, UpdateStatus.available);
        time.elapse(const Duration(hours: 6));
        expect(calls, 3);
        service.dispose();
        time.elapse(const Duration(days: 1));
        expect(calls, 3);
      });
    },
  );

  test('repeated failures back off instead of polling every five minutes', () {
    fakeAsync((time) {
      var calls = 0;
      final service = UpdateService(
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 503);
        }),
      );
      service.startAutomaticChecks();
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 5));
      expect(calls, 2);
      time.elapse(const Duration(minutes: 9));
      expect(calls, 2);
      time.elapse(const Duration(minutes: 1));
      expect(calls, 3);
      service.dispose();
    });
  });

  test(
    'GitHub cooldown blocks manual and automatic requests until the later header',
    () {
      fakeAsync((time) {
        final clock = time.getClock(DateTime.utc(2026, 9, 21));
        var calls = 0;
        final service = UpdateService(
          now: clock.now,
          client: MockClient((_) async {
            calls++;
            return calls == 1
                ? http.Response(
                    '{}',
                    403,
                    headers: {
                      'retry-after': '600',
                      'x-ratelimit-remaining': '0',
                      'x-ratelimit-reset':
                          '${clock.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}',
                    },
                  )
                : release('v2.0.7');
          }),
        );
        service.startAutomaticChecks();
        time.flushMicrotasks();
        service.checkForUpdate();
        time.flushMicrotasks();
        expect(calls, 1);
        expect(service.statusMessage, contains('limited'));
        time.elapse(const Duration(minutes: 59));
        expect(calls, 1);
        time.elapse(const Duration(minutes: 1));
        expect(calls, 2);
        expect(service.status, UpdateStatus.available);
        service.dispose();
      });
    },
  );

  test('hung requests time out and can be retried', () {
    fakeAsync((time) {
      final service = UpdateService(
        client: MockClient((_) => Completer<http.Response>().future),
      );
      service.checkForUpdate();
      time.elapse(const Duration(seconds: 10));
      expect(service.isChecking, isFalse);
      expect(service.statusMessage, contains('timed out'));
      service.dispose();
    });
  });

  test(
    'disposing during a request prevents notifications and timer rescheduling',
    () async {
      final gate = Completer<http.Response>();
      final service = UpdateService(client: MockClient((_) => gate.future));
      var notifications = 0;
      service.addListener(() => notifications++);
      final pending = service.checkForUpdate();
      service.dispose();
      gate.complete(release('v2.0.7'));
      await pending;
      expect(notifications, 1);
    },
  );
}
