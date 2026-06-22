import 'dart:io';

import 'package:app_gif/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the badge GIF workspace', (tester) async {
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();

    expect(find.text('ESP-BAJI'), findsNothing);
    expect(find.byIcon(Icons.grid_view_rounded), findsWidgets);
    expect(find.byIcon(Icons.add_photo_alternate_outlined), findsOneWidget);
    expect(find.text('导入'), findsNothing);
  });

  testWidgets('uses plain colored connection text without page crossfade', (
    tester,
  ) async {
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();

    final status = tester.widget<Text>(find.text('未连接'));
    expect(status.style?.color, const Color(0xffff5b5b));
    expect(find.byType(AnimatedSwitcher), findsNothing);
  });

  test('keeps animated preview paths in asset history', () {
    final selected = SelectedMedia.fromMap({
      'uri': 'content://asset.gif',
      'name': 'asset.gif',
      'size': 1024,
      'mime': 'image/gif',
      'previewBytes': null,
      'animatedPreviewPath': 'cache/asset.gif',
    });

    final prepared = PreparedAsset.fromMap({
      'assetPath': 'cache/asset.ebaj',
      'previewPath': 'cache/asset.png',
      'animatedPreviewPath': selected.animatedPreviewPath,
      'name': selected.name,
      'packageSize': 2048,
      'frameCount': 24,
      'fps': 30,
      'crc32': 1234,
    });
    final history = HistoryEntry.fromAsset(prepared);

    expect(selected.animatedPreviewPath, 'cache/asset.gif');
    expect(prepared.animatedPreviewPath, 'cache/asset.gif');
    expect(history.animatedPreviewPath, 'cache/asset.gif');
    expect(history.toMap()['animatedPreviewPath'], 'cache/asset.gif');
  });

  test('media import stores warmed animated preview paths', () {
    final selected = SelectedMedia.fromMap({
      'uri': 'content://asset.mp4',
      'name': 'asset.mp4',
      'size': 1024,
      'mime': 'video/mp4',
      'previewBytes': null,
      'animatedPreviewPath': null,
    });
    final warmed = selected.copyWith(animatedPreviewPath: 'cache/warm.gif');

    expect(selected.animatedPreviewPath, isNull);
    expect(warmed.animatedPreviewPath, 'cache/warm.gif');
  });

  test(
    'video preview warmup is requested after media import and reused on save',
    () {
      final source = File('lib/main.dart').readAsStringSync();

      expect(source, contains("'warmVideoAnimatedPreview'"));
      expect(source, contains('_warmSelectedVideoPreview'));
      expect(source, contains('animatedPreviewPath: warmPreviewPath'));
      expect(
        source,
        contains(
          "'warmPreviewPath': _isDefaultCrop ? media.animatedPreviewPath : null",
        ),
      );
      expect(source, contains("case 'videoPreviewReady':"));
      expect(source, contains("event['uri'] == _media?.uri"));
    },
  );

  test('video previews avoid concurrent decoders on the home page', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('required this.active'));
    expect(source, contains('final bool active;'));
    expect(source, contains('oldWidget.active != widget.active'));
    expect(source, contains('await controller.pause()'));
    expect(source, contains('void activate()'));
    expect(source, contains(r"key: ValueKey('maker-video-${selected.uri}')"));
    expect(
      source,
      contains(r"key: ValueKey('dial-asset-video-${asset!.sourceUri}')"),
    );
    expect(
      source,
      isNot(contains(r"key: ValueKey('history-video-${entry.assetPath}')")),
    );
    expect(source, contains('if (_hasPreviewPath(entry.animatedPreviewPath))'));
    expect(source, contains('_PreviewDial('));
    expect(source, contains('active: active'));
    expect(source, contains('active: active && !preparing'));
    expect(source, isNot(contains('asset?.assetPath != entry.assetPath')));
    expect(source, isNot(contains('active: active && !uploading')));
    expect(source, isNot(contains('uri: entry.sourceUri!')));
  });
}
