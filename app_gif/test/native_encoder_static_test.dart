import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native encoder emits complete cropped EBAJ4 indexed stream packages', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(source, contains('MAGIC = 0x344a4142'));
    expect(source, contains('VERSION = 4'));
    expect(source, contains('frameDelayMs(fps'));
    expect(source, contains('CropTransform'));
    expect(source, contains('cropScale'));
    expect(source, contains('CODEC_INDEXED_KEY'));
    expect(source, contains('CODEC_INDEXED_TILE'));
    expect(source, contains('CODEC_INDEXED_REPEAT'));
    expect(source, contains('selectStreamResolution'));
    expect(source, contains('sampleStreamResolution'));
    expect(
      source,
      contains(
        'encodeAtResolution(context, uri, mime, fps, delayMs, selectedStreamSize, crop)',
      ),
    );
    expect(source, contains('rgb332Palette'));
    expect(source, contains('quantizeToIndexed'));
    expect(source, contains('orderedDither'));
    expect(source, contains('sharpenForIndexed'));
    expect(source, contains('PixelScratch'));
    expect(source, contains('QUALITY_STREAM_BYTES_PER_SECOND'));
    expect(source, contains('uploadAssetOverTcp'));
    expect(source, contains('BADGE_UPLOAD_TCP_PORT'));
    expect(source, contains('buildVideoAnimatedPreview'));
    expect(source, contains('encodeIndexedGif'));
    expect(source, contains('gifLzwEncodeLiteral'));
    expect(source, contains('VIDEO_PREVIEW_GIF_SIZE = 192'));
    expect(source, contains('VIDEO_PREVIEW_GIF_FPS = 30'));
    expect(source, contains('warmVideoAnimatedPreview'));
    expect(source, contains('warmPreviewPath'));
    expect(
      source,
      contains('buildVideoAnimatedPreview(uri, crop, warmPreviewPath)'),
    );
    expect(source, contains('quantizeBitmapToGifIndexed'));
    expect(source, contains('sharpenForIndexed(red) + orderedDither(x, y, 3)'));
    expect(
      source,
      contains(
        'val totalFrames = max(1, ((durationMs + delayMs - 1) / delayMs).toInt())',
      ),
    );
    expect(source, isNot(contains('VIDEO_PREVIEW_GIF_DURATION_MS')));
    expect(source, isNot(contains('VIDEO_PREVIEW_GIF_MAX_FRAMES')));
    expect(
      source,
      contains(
        r'File(directory, "$stem.gif").also { it.writeBytes(preview) }.absolutePath',
      ),
    );
    expect(source, isNot(contains('if (projectedSize > maxPackageBytes)')));
    expect(source, isNot(contains('STREAM_RESOLUTIONS.map')));
    expect(source, isNot(contains('PRELOAD_ASSET_BUDGET_BYTES')));
    expect(source, isNot(contains('CODEC_RAW')));
    expect(source, isNot(contains('CODEC_TILE_RAW')));
  });
}
