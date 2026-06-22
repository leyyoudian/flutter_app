import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native encoder emits complete stable 20fps EBAJ4 indexed stream packages', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(source, contains('MAGIC = 0x344a4142'));
    expect(source, contains('VERSION = 4'));
    expect(source, contains('TARGET_FPS = 20'));
    expect(source, contains('CODEC_INDEXED_KEY'));
    expect(source, contains('CODEC_INDEXED_TILE'));
    expect(source, contains('CODEC_INDEXED_REPEAT'));
    expect(source, contains('selectStreamResolution'));
    expect(source, contains('sampleStreamResolution'));
    expect(source, contains('encodeAtResolution(context, uri, mime, fps, selectedStreamSize)'));
    expect(source, contains('rgb332Palette'));
    expect(source, contains('quantizeToIndexed'));
    expect(source, contains('orderedDither'));
    expect(source, contains('sharpenForIndexed'));
    expect(source, contains('PixelScratch'));
    expect(source, contains('QUALITY_STREAM_BYTES_PER_SECOND'));
    expect(source, contains('uploadAssetOverTcp'));
    expect(source, contains('BADGE_UPLOAD_TCP_PORT'));
    expect(source, isNot(contains('if (projectedSize > maxPackageBytes)')));
    expect(source, isNot(contains('STREAM_RESOLUTIONS.map')));
    expect(source, isNot(contains('PRELOAD_ASSET_BUDGET_BYTES')));
    expect(source, isNot(contains('CODEC_RAW')));
    expect(source, isNot(contains('CODEC_TILE_RAW')));
  });
}
