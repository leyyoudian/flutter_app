import 'package:flutter_test/flutter_test.dart';

import 'package:app_gif/backend_failover.dart';

void main() {
  test(
    'production backend candidates prefer new server and retain fallback',
    () {
      final candidates = backendBaseCandidates();

      expect(candidates.map((item) => item.toString()), <String>[
        'http://47.108.204.22',
        'http://60.205.122.153',
      ]);
    },
  );

  test('dart define override is tried before production candidates', () {
    final candidates = backendBaseCandidates(
      overrideBase: 'http://127.0.0.1:8787/',
    );

    expect(candidates.first.toString(), 'http://127.0.0.1:8787');
    expect(candidates.toSet().length, candidates.length);
  });

  test('backend operation falls back after retryable failure', () async {
    final visited = <String>[];
    final result = await withBackendFailover<String>(
      backendBaseCandidates(),
      (base) async {
        visited.add(base.host);
        if (base.host == '47.108.204.22') {
          throw const BackendRequestException('offline', retryable: true);
        }
        return 'ok';
      },
      shouldRetry: (error) =>
          error is BackendRequestException && error.retryable,
    );

    expect(result, 'ok');
    expect(visited, <String>['47.108.204.22', '60.205.122.153']);
  });

  test('backend operation does not retry a non-retryable response', () async {
    var attempts = 0;
    await expectLater(
      withBackendFailover<void>(
        backendBaseCandidates(),
        (_) async {
          attempts += 1;
          throw const BackendRequestException('bad request');
        },
        shouldRetry: (error) =>
            error is BackendRequestException && error.retryable,
      ),
      throwsA(isA<BackendRequestException>()),
    );
    expect(attempts, 1);
  });
}
