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
    expect(source, contains('VIDEO_PREVIEW_GIF_FPS = 25'));
    expect(source, contains('warmVideoAnimatedPreview'));
    expect(source, contains('warmPreviewPath'));
    expect(source, contains('private fun persistentAssetDirectory'));
    expect(source, contains('persistentAssetDirectory("ebaj")'));
    expect(source, contains('persistentAssetDirectory("media_preview")'));
    expect(source, contains('repairHistoryItem'));
    expect(source, contains('deleteAssetFiles'));
    expect(source, contains('"deleteAssetFiles"'));
    expect(source, contains('buildVideoAnimatedPreview(uri, crop, null)'));
    expect(source, contains('contentResolver.takePersistableUriPermission'));
    expect(source, contains('"openUrl"'));
    expect(source, contains('Intent.ACTION_VIEW'));
    expect(source, isNot(contains('File(cacheDir, "ebaj")')));
    expect(source, isNot(contains('File(cacheDir, "media_preview")')));
    expect(source, contains('reusableWarmPreviewBytes(warmPreviewPath)'));
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

  test('video package encoding uses sequential decode instead of random frame seek', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(source, contains('import android.media.MediaExtractor'));
    expect(source, contains('import android.media.MediaCodec'));
    expect(source, contains('private fun decodeVideoFramesSequentially'));
    expect(source, contains('decodeVideoFramesSequentially(context, uri, targetFrameTimesUs'));
    expect(
      source,
      isNot(contains('private fun encodeVideoFrames(\n            context: Context,\n            uri: Uri,\n            delayMs: Int,\n            streamSize: Int,\n            crop: CropTransform,\n        ): List<EncodedFrame> {\n            val retriever = createRetriever(context, uri)')),
    );
  });

  test('video save returns before animated preview generation finishes', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(source, contains('scheduleVideoAnimatedPreview'));
    expect(source, contains('"assetPreviewReady"'));
    expect(source, contains('sendEncodePrepareProgress'));
    expect(source, contains('progress * PREPARE_PROGRESS_PACKING'));
    expect(source, contains('sendPrepareProgress(PREPARE_PROGRESS_WRITING)'));
    expect(source, contains('sendPrepareProgress(PREPARE_PROGRESS_DONE)'));
    expect(
      source,
      isNot(
        contains(
          'buildVideoAnimatedPreview(uri, crop, warmPreviewPath)?.let { preview ->',
        ),
      ),
    );
  });

  test('video animated previews use sequential decode at full preview fps', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();
    final previewStart = source.indexOf(
      '        fun buildVideoAnimatedPreview(\n            context: Context,',
    );
    final previewEnd = source.indexOf(
      '        private fun decodeVideoPreviewFramesSequentially',
      previewStart,
    );
    expect(previewStart, isNot(-1));
    expect(previewEnd, isNot(-1));
    final previewSource = source.substring(previewStart, previewEnd);

    expect(
      previewSource,
      contains(
        'decodeVideoPreviewFramesSequentially(context, uri, targetFrameTimesUs, crop)',
      ),
    );
    expect(source, contains('private fun quantizeYuvImageToGifIndexed'));
    expect(previewSource, contains('encodeIndexedGif(frames, VIDEO_PREVIEW_GIF_SIZE, VIDEO_PREVIEW_GIF_SIZE, delayMs)'));
    expect(
      previewSource,
      isNot(contains('getFrameAtTime')),
    );
    expect(
      previewSource,
      isNot(
        contains('decodeVideoFramesSequentially(context, uri, targetFrameTimesUs'),
      ),
    );
  });
}
