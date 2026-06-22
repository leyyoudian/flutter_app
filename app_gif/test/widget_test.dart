import 'package:app_gif/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the badge GIF workspace', (tester) async {
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();

    expect(find.text('ESP-BAJI'), findsOneWidget);
    expect(find.byIcon(Icons.perm_media), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
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
}
