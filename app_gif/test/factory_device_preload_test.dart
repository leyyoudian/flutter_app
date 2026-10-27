import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_gif/factory_device_install.dart';
import 'package:app_gif/factory_device_preload.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory cache;
  late HttpServer server;
  late Map<String, dynamic> item;
  late List<Uri> bases;
  late FactoryDevicePreload preload;
  late int downloads;
  var revision = 1;
  var busy = false;
  var stall = false;
  late Completer<void> requested;
  final payload = List<int>.generate(1024, (i) => i % 251);

  Future<void> saveCatalog() =>
      File('${cache.path}/factory_catalog_install.json').writeAsString(
        jsonEncode({
          'items': [item],
        }),
      );

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('factory-preload-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    bases = [Uri.parse('http://127.0.0.1:${server.port}')];
    downloads = 0;
    revision = 1;
    busy = false;
    stall = false;
    requested = Completer<void>();
    item = {
      'id': 'F024',
      'revision': revision,
      'type': 'loop',
      'deviceFiles': [
        {
          'path': 'factory_loop/F024.eb5',
          'url': '/payload',
          'hardware': 'esp32p4',
          'size': payload.length,
          'sha256': sha256.convert(payload).toString(),
        },
      ],
    };
    server.listen((request) async {
      try {
        if (request.uri.path == '/api/factory-catalog') {
          request.response.write(
            jsonEncode({
              'items': [item],
            }),
          );
        } else {
          downloads++;
          if (!requested.isCompleted) requested.complete();
          if (stall) {
            await request.response.flush();
            return; // Deliberately leave the response open until cancellation.
          }
          request.response.add(payload);
        }
        await request.response.close();
      } on SocketException {
        // An interrupted background request is expected to close the socket.
      } on HttpException {
        // An interrupted background request is expected to close the socket.
      }
    });
    preload = FactoryDevicePreload(
      cacheRoot: cache,
      backendBases: bases,
      canRun: () => !busy,
    );
    await saveCatalog();
  });

  tearDown(() async {
    await preload.pause();
    await server.close(force: true);
    await cache.delete(recursive: true);
  });

  test(
    'catalog preloads without a tap; installation reuses exact verified files',
    () async {
      await preload.start();
      expect(downloads, 1);
      final package = await FactoryDeviceInstall.prepare(
        id: 'F024',
        backendBases: bases,
        cacheRoot: cache,
        onProgress: (_) {},
      );
      expect(downloads, 1);
      expect(await File(package['assetPath'] as String).exists(), isTrue);
    },
  );

  test(
    'staged package is verified offline and a corrupt package is rejected',
    () async {
      await preload.start();
      final package = await FactoryDeviceInstall.readPrepared(
        id: 'F024',
        cacheRoot: cache,
      );
      expect(package, isNotNull);
      expect(downloads, 1);
      await File(package!['assetPath'] as String).writeAsBytes([0]);
      expect(
        await FactoryDeviceInstall.readPrepared(id: 'F024', cacheRoot: cache),
        isNull,
      );
      expect(downloads, 1);
    },
  );

  test(
    'staged packages survive an iOS application container path change',
    () async {
      await preload.start();
      final receipt = File('${cache.path}/device/F024/1/prepared.json');
      final record =
          jsonDecode(await receipt.readAsString()) as Map<String, dynamic>;
      record['assetPath'] =
          '/var/mobile/Containers/Data/Application/OLD/Library/Application Support/badge_assets/factory_catalog/device/F024/1/install.dlf';
      await receipt.writeAsString(jsonEncode(record));
      final prepared = await FactoryDeviceInstall.readPrepared(
        id: 'F024',
        cacheRoot: cache,
      );
      expect(prepared, isNotNull);
      expect(prepared!['assetPath'], '${cache.path}/device/F024/1/install.dlf');
      expect(downloads, 1);
    },
  );

  test(
    'confirmed install clears only device payload and prevents redownload across restart',
    () async {
      await preload.start();
      final package = await FactoryDeviceInstall.prepare(
        id: 'F024',
        backendBases: bases,
        cacheRoot: cache,
        onProgress: (_) {},
      );
      final preview = File('${cache.path}/cover.png');
      await preview.writeAsBytes([1, 2, 3]);
      await preload.installed(package);
      expect(await File(package['assetPath'] as String).exists(), isFalse);
      expect(
        await cache
            .list(recursive: true)
            .where((f) => f.path.endsWith('.eb5'))
            .length,
        0,
      );
      expect(await preview.exists(), isTrue);
      preload = FactoryDevicePreload(
        cacheRoot: cache,
        backendBases: bases,
        canRun: () => !busy,
      );
      await preload.start();
      expect(downloads, 1);
      // A device reporting missing data still uses the foreground repair path.
      await FactoryDeviceInstall.prepare(
        id: 'F024',
        backendBases: bases,
        cacheRoot: cache,
        onProgress: (_) {},
      );
      expect(downloads, 2);
    },
  );

  test(
    'delivery receipt is scoped to device and exact package revision',
    () async {
      await preload.start();
      final package = await FactoryDeviceInstall.prepare(
        id: 'F024',
        backendBases: bases,
        cacheRoot: cache,
        onProgress: (_) {},
      );
      final key = package['cacheKey'] as String;
      await preload.installed(package, deviceKey: 'P4-DEVICE-A');

      expect(
        await preload.deliveredToDevice('F024', key, 'P4-DEVICE-A'),
        isTrue,
      );
      expect(
        await preload.deliveredToDevice('F024', key, 'P4-DEVICE-B'),
        isFalse,
      );
      expect(
        await preload.deliveredToDevice('F024', '0' * 64, 'P4-DEVICE-A'),
        isFalse,
      );
    },
  );

  test(
    'a new revision is automatically staged after the prior revision was consumed',
    () async {
      await preload.start();
      final package = await FactoryDeviceInstall.prepare(
        id: 'F024',
        backendBases: bases,
        cacheRoot: cache,
        onProgress: (_) {},
      );
      await preload.installed(package);
      item['revision'] = 2;
      await saveCatalog();
      await preload.start();
      expect(downloads, 2);
      expect(
        await File('${cache.path}/device/F024/2/install.dlf').exists(),
        isTrue,
      );
    },
  );

  test(
    'pausing cancels a stalled response before foreground transfer',
    () async {
      stall = true;
      final work = preload.start();
      await requested.future.timeout(const Duration(seconds: 3));
      final watch = Stopwatch()..start();
      busy = true;
      await preload.pause().timeout(const Duration(seconds: 2));
      await work;
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(
        await File('${cache.path}/device/F024/1/install.dlf').exists(),
        isFalse,
      );
      stall = false;
      busy = false;
      await preload.start();
      expect(
        await File('${cache.path}/device/F024/1/install.dlf').exists(),
        isTrue,
      );
    },
  );

  test(
    'no background network runs during transfer and a failed install retains its cache',
    () async {
      busy = true;
      await preload.start();
      expect(downloads, 0);
      busy = false;
      await preload.start();
      // No installation acknowledgement is provided; retry must keep these files.
      await preload.start();
      expect(downloads, 1);
      expect(
        await File('${cache.path}/device/F024/1/install.dlf').exists(),
        isTrue,
      );
    },
  );
}
