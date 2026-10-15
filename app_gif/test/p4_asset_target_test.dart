import 'dart:io';
import 'dart:typed_data';

import 'package:app_gif/main.dart';
import 'package:app_gif/p4_asset_target.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cache probe distinguishes real JPEG frames from old indexed packages',
    () async {
      final directory = await Directory.systemTemp.createTemp('p4-cache-test');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/test.ebaj');
      final bytes = Uint8List(64);
      final header = ByteData.sublistView(bytes);
      header.setUint32(0, 0x344a4142, Endian.little);
      header.setUint16(4, 4, Endian.little);
      header.setUint32(16, 44, Endian.little);
      header.setUint32(24, bytes.length, Endian.little);
      bytes[54] = 0x20;
      await file.writeAsBytes(bytes);
      expect(await hasP4JpegPackage(file.path), isTrue);
      bytes[54] = 0x10;
      await file.writeAsBytes(bytes);
      expect(await hasP4JpegPackage(file.path), isFalse);
      await file.writeAsBytes(bytes.sublist(0, 20));
      expect(await hasP4JpegPackage(file.path), isFalse);
    },
  );

  Future<Map<dynamic, dynamic>?> rebuild({
    String hardware = 'esp32s3',
    String? source = 'content://saved/original.mp4',
    required Future<Map<dynamic, dynamic>?> Function(Map<String, Object?>)
    transcode,
  }) => rebuildLegacyP4Asset(
    assetId: 'legacy-id',
    sourceUri: source,
    name: 'My clip',
    cropScale: 1.5,
    cropOffsetX: 0.2,
    cropOffsetY: -0.3,
    metadata: (id) async {
      expect(id, 'legacy-id');
      return {'hardware': hardware};
    },
    transcode: transcode,
  );

  test('existing P4 server package is reused without transcoding', () async {
    expect(
      await rebuild(
        hardware: 'esp32p4',
        transcode: (_) async {
          fail('A matching package must not be regenerated');
        },
      ),
      isNull,
    );
  });

  test(
    'old S3 package is genuinely rebuilt with original source and crop',
    () async {
      final result = await rebuild(
        transcode: (arguments) async {
          expect(arguments, {
            'uri': 'content://saved/original.mp4',
            'name': 'My clip',
            'hardware': 'esp32p4',
            'maxFps': 80,
            'cropScale': 1.5,
            'cropOffsetX': 0.2,
            'cropOffsetY': -0.3,
            'deviceTransfer': true,
          });
          return {
            'reviewId': 'new-p4-id',
            'reviewStatus': 'approved',
            'fps': 30,
          };
        },
      );
      expect(result?['reviewId'], 'new-p4-id');
    },
  );

  test(
    'missing original asks for source instead of relabeling S3 bytes',
    () async {
      await expectLater(
        rebuild(
          source: null,
          transcode: (_) async {
            fail('A missing source must not be submitted');
          },
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'asset_source_missing',
          ),
        ),
      );
    },
  );

  test(
    'an incomplete replacement cannot overwrite a working history entry',
    () async {
      await expectLater(
        rebuild(
          transcode: (_) async => {
            'reviewId': 'new-id',
            'reviewStatus': 'pending',
          },
        ),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test(
    'replacement clears old device file identity and preserves source and crop',
    () {
      final entry = HistoryEntry.fromMap({
        'assetPath': '/old/s3.ebaj',
        'reviewId': 'old-id',
        'deviceId': 'U001',
        'deviceKey': 'P4-ABC',
        'sourceUri': 'content://saved/original.mp4',
        'cropScale': 1.5,
        'cropOffsetX': 0.2,
        'cropOffsetY': -0.3,
        'createdAt': 123,
      });
      final replacement = entry.copyWith(
        assetPath: '',
        reviewId: 'new-p4-id',
        clearDeviceIdentity: true,
        packageSize: 0,
        frameCount: 0,
        crc32: 0,
      );
      expect(replacement.deviceId, isNull);
      expect(replacement.deviceKey, isNull);
      expect(replacement.sourceUri, entry.sourceUri);
      expect(replacement.cropScale, 1.5);
      expect(replacement.cropOffsetY, -0.3);
      expect(replacement.createdAt, 123);
      expect(replacement.reviewId, 'new-p4-id');
      expect(replacement.assetPath, isEmpty);
    },
  );
}
