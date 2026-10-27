import 'dart:convert';
import 'dart:io';

import 'package:app_gif/factory_device_install.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a short mirror burst must not displace a healthy primary', () async {
    final servers = <HttpServer>[];
    final cache = await Directory.systemTemp.createTemp('factory-burst-');
    addTearDown(() async {
      for (final server in servers) {
        await server.close(force: true);
      }
      await cache.delete(recursive: true);
    });
    final payload = List<int>.generate(1024 * 1024, (i) => i % 251);
    for (var index = 0; index < 2; index++) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(server);
      final primary = index == 0;
      server.listen((req) async {
        try {
          if (req.uri.path == '/api/factory-catalog') {
            req.response.write(
              jsonEncode({
                'items': [
                  {
                    'id': 'F024',
                    'type': 'loop',
                    'revision': 1,
                    'deviceFiles': [
                      {
                        'path': 'factory_loop/F024.eb5',
                        'url': '/payload',
                        'hardware': 'esp32p4',
                        'size': payload.length,
                        'sha256': sha256.convert(payload).toString(),
                      },
                    ],
                  },
                ],
              }),
            );
          } else {
            req.response.contentLength = payload.length;
            if (primary) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
              req.response.add(payload);
            } else {
              req.response.add(payload.sublist(0, 192 * 1024));
              await req.response.flush();
              await Future<void>.delayed(const Duration(seconds: 1));
              req.response.add(payload.sublist(192 * 1024));
            }
          }
          await req.response.close();
        } on HttpException {
          /* Losing probe disconnected. */
        } on SocketException {
          /* Test teardown disconnected. */
        }
      });
    }
    final watch = Stopwatch()..start();
    await FactoryDeviceInstall.prepare(
      id: 'F024',
      backendBases: servers
          .map((s) => Uri.parse('http://127.0.0.1:${s.port}'))
          .toList(),
      cacheRoot: cache,
      onProgress: (_) {},
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 800)));
  });

  test(
    'a fast corrupt mirror cannot replace verified animation data',
    () async {
      final servers = <HttpServer>[];
      final cache = await Directory.systemTemp.createTemp('factory-integrity-');
      addTearDown(() async {
        for (final server in servers) {
          await server.close(force: true);
        }
        await cache.delete(recursive: true);
      });
      final payload = List<int>.generate(256 * 1024, (i) => i % 251);
      for (var index = 0; index < 2; index++) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(server);
        final good = index == 0;
        server.listen((req) async {
          try {
            if (req.uri.path == '/api/factory-catalog') {
              req.response.write(
                jsonEncode({
                  'items': [
                    {
                      'id': 'F024',
                      'type': 'loop',
                      'revision': 1,
                      'deviceFiles': [
                        {
                          'path': 'factory_loop/F024.eb5',
                          'url': '/payload',
                          'hardware': 'esp32p4',
                          'size': payload.length,
                          'sha256': sha256.convert(payload).toString(),
                        },
                      ],
                    },
                  ],
                }),
              );
            } else {
              req.response.contentLength = payload.length;
              if (good) {
                await Future<void>.delayed(const Duration(milliseconds: 800));
              }
              req.response.add(
                good ? payload : List<int>.filled(payload.length, 0),
              );
            }
            await req.response.close();
          } on HttpException {
            /* Losing probe disconnected. */
          } on SocketException {
            /* Test teardown disconnected. */
          }
        });
      }
      final result = await FactoryDeviceInstall.prepare(
        id: 'F024',
        backendBases: servers
            .map((s) => Uri.parse('http://127.0.0.1:${s.port}'))
            .toList(),
        cacheRoot: cache,
        onProgress: (_) {},
      );
      final bytes = await File(result['assetPath'] as String).readAsBytes();
      final manifestSize =
          bytes[4] | bytes[5] << 8 | bytes[6] << 16 | bytes[7] << 24;
      expect(bytes.sublist(8 + manifestSize), payload);
      expect(sha256.convert(bytes).toString(), result['sha256']);
    },
  );

  test('slow successful primary does not block a fast verified mirror', () async {
    final servers = <HttpServer>[];
    final cache = await Directory.systemTemp.createTemp('factory-route-');
    addTearDown(() async {
      for (final server in servers) {
        await server.close(force: true);
      }
      await cache.delete(recursive: true);
    });
    final payload = List<int>.generate(320 * 1024, (i) => i % 251);
    var slowRequests = 0, fastRequests = 0;
    for (var index = 0; index < 2; index++) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(server);
      final slow = index == 0;
      server.listen((req) async {
        try {
          if (req.uri.path == '/api/factory-catalog') {
            req.response.write(
              jsonEncode({
                'items': [
                  {
                    'id': 'F024',
                    'type': 'loop',
                    'revision': 1,
                    'deviceFiles': [
                      {
                        'path': 'factory_loop/F024.eb5',
                        'url': '/payload',
                        'hardware': 'esp32p4',
                        'size': payload.length,
                        'sha256': sha256.convert(payload).toString(),
                      },
                    ],
                  },
                ],
              }),
            );
          } else {
            if (slow) {
              slowRequests++;
            } else {
              fastRequests++;
            }
            req.response.contentLength = payload.length;
            if (slow) {
              req.response.add(payload.sublist(0, 1024));
              await req.response.flush();
              await Future<void>.delayed(const Duration(seconds: 2));
              req.response.add(payload.sublist(1024));
            } else {
              req.response.add(payload);
            }
          }
          await req.response.close();
        } on HttpException {
          /* Losing probe disconnected. */
        } on SocketException {
          /* Test teardown disconnected. */
        }
      });
    }
    final watch = Stopwatch()..start();
    final result = await FactoryDeviceInstall.prepare(
      id: 'F024',
      backendBases: servers
          .map((s) => Uri.parse('http://127.0.0.1:${s.port}'))
          .toList(),
      cacheRoot: cache,
      onProgress: (_) {},
    );
    expect(
      watch.elapsed,
      lessThan(const Duration(milliseconds: 1400)),
      reason:
          'A 200 response from a slow primary must not prevent mirror selection',
    );
    expect(fastRequests, 1);
    final bytes = await File(result['assetPath'] as String).readAsBytes();
    expect(sha256.convert(bytes).toString(), result['sha256']);
    final previousSlow = slowRequests;
    final previousFast = fastRequests;
    await FactoryDeviceInstall.prepare(
      id: 'F024',
      backendBases: servers
          .map((s) => Uri.parse('http://127.0.0.1:${s.port}'))
          .toList(),
      cacheRoot: cache,
      onProgress: (_) {},
    );
    expect(slowRequests, previousSlow);
    expect(
      fastRequests,
      previousFast,
      reason: 'Verified cache must not run speed probes',
    );
  });
}
