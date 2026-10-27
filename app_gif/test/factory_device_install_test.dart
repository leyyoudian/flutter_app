import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_gif/factory_device_install.dart';

void main() {
  test('loop install accepts its matching one-time entrance clip', () {
    final pair = ['factory_loop', 'loop_intro']
        .map(
          (directory) => {
            'path': '$directory/F022.eb5',
            'hardware': 'esp32p4',
            'size': 128,
            'sha256': 'a' * 64,
          },
        )
        .toList();

    expect(
      () => FactoryDeviceInstall.validateFiles('F022', 'loop', pair),
      returnsNormally,
    );
    expect(
      () => FactoryDeviceInstall.validateFiles('F022', 'loop', [pair.last]),
      throwsFormatException,
    );
    expect(
      () => FactoryDeviceInstall.validateFiles('F022', 'loop', [
        ...pair,
        {...pair.last, 'path': 'loop_intro/F023.eb5'},
      ]),
      throwsFormatException,
    );
  });

  test(
    'missing-device installation downloads exact files, validates and reuses cache',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cache = await Directory.systemTemp.createTemp('factory-install-');
      addTearDown(() async {
        await server.close(force: true);
        await cache.delete(recursive: true);
      });
      final payload = List<int>.generate(128, (i) => i);
      var downloads = 0;
      var corrupt = false;
      final files = ['first_half', 'second_half', 'third_half']
          .map(
            (dir) => {
              'path': '$dir/S003.eb5',
              'url': '/$dir',
              'hardware': 'esp32p4',
              'size': payload.length,
              'sha256': sha256.convert(payload).toString(),
            },
          )
          .toList();
      server.listen((req) async {
        if (req.uri.path == '/api/factory-catalog') {
          req.response.write(
            jsonEncode({
              'items': [
                {
                  'id': 'S003',
                  'type': 'split',
                  'revision': 2,
                  'deviceFiles': files,
                },
              ],
            }),
          );
        } else {
          downloads++;
          req.response.add(
            corrupt ? List<int>.filled(payload.length, 0) : payload,
          );
        }
        await req.response.close();
      });
      for (var pass = 0; pass < 2; pass++) {
        final result = await FactoryDeviceInstall.prepare(
          id: 'S003',
          backendBases: [Uri.parse('http://127.0.0.1:${server.port}')],
          cacheRoot: cache,
          onProgress: (_) {},
        );
        final bytes = await File(result['assetPath'] as String).readAsBytes();
        final view = ByteData.sublistView(bytes);
        expect(view.getUint32(0, Endian.little), 0x31464c44);
        final length = view.getUint32(4, Endian.little);
        final manifest = jsonDecode(utf8.decode(bytes.sublist(8, 8 + length)));
        expect(manifest['files'], hasLength(3));
        expect(bytes.sublist(8 + length), [...payload, ...payload, ...payload]);
        expect(result['sha256'], sha256.convert(bytes).toString());
      }
      expect(downloads, 3);
      corrupt = true;
      final corruptCache = Directory('${cache.path}/corrupt');
      await expectLater(
        FactoryDeviceInstall.prepare(
          id: 'S003',
          backendBases: [Uri.parse('http://127.0.0.1:${server.port}')],
          cacheRoot: corruptCache,
          onProgress: (_) {},
        ),
        throwsFormatException,
      );
      expect(
        await File('${corruptCache.path}/device/S003/2/install.dlf').exists(),
        isFalse,
      );
      final invalid = files.map((x) => Map<String, dynamic>.from(x)).toList();
      invalid[0]['path'] = '../S003.eb5';
      expect(
        () => FactoryDeviceInstall.validateFiles('S003', 'split', invalid),
        throwsFormatException,
      );
      expect(
        () => FactoryDeviceInstall.validateFiles(
          'S003',
          'split',
          files.sublist(0, 2),
        ),
        throwsFormatException,
      );
      invalid[0] = {...files[0], 'hardware': 'esp32s3'};
      expect(
        () => FactoryDeviceInstall.validateFiles('S003', 'split', invalid),
        throwsFormatException,
      );
    },
  );
}
