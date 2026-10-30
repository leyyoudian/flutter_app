import 'dart:io';

import 'package:app_gif/app_language.dart';
import 'package:app_gif/transcode_policy.dart';
import 'package:app_gif/main.dart';
import 'package:app_gif/reference_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

class _FactoryBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      key == 'assets/factory_previews/manifest.json'
      ? SynchronousFuture(
          File('assets/factory_previews/manifest.json').readAsStringSync(),
        )
      : rootBundle.loadString(key, cache: cache);
}

void main() {
  const native = MethodChannel('esp_baji/native');
  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  testWidgets(
    'home preview has a ten pixel inset and a static factory image',
    (tester) async {
      LanguageSettings.current.value = AppLanguage.chinese;
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        DefaultAssetBundle(bundle: _FactoryBundle(), child: const BadgeApp()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('fixed-home-preview'));
      expect(find.text('我的库'), findsOneWidget);
      expect(find.text('背包'), findsOneWidget);
      expect(find.text('出厂素材'), findsNothing);
      final bounds = tester.getRect(preview);
      final circle = tester.getRect(
        find.descendant(of: preview, matching: find.byType(ClipOval)),
      );
      expect(circle.top - bounds.top, closeTo(10, .01));
      expect(bounds.bottom - circle.bottom, closeTo(10, .01));
      expect(
        find.descendant(
          of: preview,
          matching: find.byType(StaticMaterialPreview),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: preview, matching: find.byType(VideoPlayer)),
        findsNothing,
      );
    },
    variant: platforms,
  );

  testWidgets(
    'selected user video uses its static thumbnail instead of a decoder',
    (tester) async {
      LanguageSettings.current.value = AppLanguage.chinese;
      final directory = Directory.systemTemp.createTempSync('dotloop-static-');
      final thumbnail = File('${directory.path}/preview.gif')
        ..writeAsBytesSync(
          File('test/fixtures/static_preview.gif').readAsBytesSync(),
        );
      addTearDown(() => directory.deleteSync(recursive: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        if (call.method == 'loadHistory') {
          return [
            {
              'assetPath': '${directory.path}/sample.ebaj',
              'previewPath': thumbnail.path,
              'animatedPreviewPath': thumbnail.path,
              'sourceUri': 'file:///sample.mp4',
              'mime': 'video/mp4',
              'name': '自己的视频',
              'reviewStatus': 'approved',
              'packageSize': 1024,
              'frameCount': 30,
            },
          ];
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          null,
        ),
      );
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const BadgeApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的库'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          ValueKey(
            historyEntryIdentity(
              assetPath: '${directory.path}/sample.ebaj',
              reviewId: null,
              createdAt: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('fixed-home-preview'));
      final staticImage = tester.widget<StaticMaterialPreview>(
        find.descendant(
          of: preview,
          matching: find.byType(StaticMaterialPreview),
        ),
      );
      expect((staticImage.image as FileImage).file.path, thumbnail.path);
      expect(
        find.descendant(of: preview, matching: find.byType(VideoPlayer)),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.descendant(
          of: preview,
          matching: find.byType(StaticMaterialPreview),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    variant: platforms,
  );

  testWidgets('saved covers keep their framing in both library and home', (
    tester,
  ) async {
    LanguageSettings.current.value = AppLanguage.chinese;
    final directory = Directory.systemTemp.createTempSync('dotloop-framing-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cases = [
      // Native PNG thumbnails predate the persisted crop-applied flag.
      ('legacy', 'png', false, 1.8, .2, -.15, 1.0),
      ('cover', 'png', true, .5, -.1, .2, 1.0),
      // An original GIF still needs the saved transform exactly once.
      ('original', 'gif', false, 1.6, -.2, .1, 1.6),
    ];
    final history = <Map<String, Object?>>[];
    for (final c in cases) {
      final file = File('${directory.path}/${c.$1}.${c.$2}')
        ..writeAsBytesSync(
          File('test/fixtures/static_preview.gif').readAsBytesSync(),
        );
      history.add({
        'assetPath': '${directory.path}/${c.$1}.ebaj',
        'previewPath': file.path,
        'previewCropApplied': c.$3,
        'mime': 'image/gif',
        'name': c.$1,
        'reviewStatus': 'approved',
        'packageSize': 1024,
        'frameCount': 30,
        'cropScale': c.$4,
        'cropOffsetX': c.$5,
        'cropOffsetY': c.$6,
      });
    }
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      native,
      (call) async => call.method == 'loadHistory' ? history : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        native,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的库'));
    await tester.pumpAndSettle();

    void expectFraming(Finder parent, double scale, double dx, double dy) {
      final image = tester.getRect(
        find.descendant(
          of: parent,
          matching: find.byType(StaticMaterialPreview),
        ),
      );
      final frame = tester.getRect(
        find.descendant(of: parent, matching: find.byType(ClipOval)),
      );
      expect(image.width / frame.width, closeTo(scale, .001));
      expect(image.height / frame.height, closeTo(scale, .001));
      expect(image.center.dx - frame.center.dx, closeTo(dx * frame.width, .01));
      expect(
        image.center.dy - frame.center.dy,
        closeTo(dy * frame.height, .01),
      );
    }

    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final tile = find.byKey(
        ValueKey(
          historyEntryIdentity(
            assetPath: history[i]['assetPath'] as String,
            reviewId: null,
            createdAt: 0,
          ),
        ),
      );
      final rendered = c.$2 == 'png';
      expectFraming(tile, c.$7, rendered ? 0 : c.$5, rendered ? 0 : c.$6);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expectFraming(
        find.byKey(const ValueKey('fixed-home-preview')),
        c.$7,
        rendered ? 0 : c.$5,
        rendered ? 0 : c.$6,
      );
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }, variant: platforms);
}
