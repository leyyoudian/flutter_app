import 'dart:io';

import 'package:app_gif/main.dart';
import 'package:app_gif/reference_ui.dart';
import 'package:app_gif/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => LanguageSettings.current.value = AppLanguage.chinese);
  testWidgets(
    'home keeps text navigation and its large preview fixed above the grid',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const BadgeApp());
      await tester.pumpAndSettle();
      expect(find.text('首页'), findsWidgets);
      expect(find.byTooltip('设置'), findsOneWidget);
      expect(find.text('DotLoop'), findsNothing);
      expect(
        find.byKey(const ValueKey('video-home-preview-card')),
        findsNothing,
      );
      final navigationRect = tester.getRect(
        find.byKey(const ValueKey('video-top-nav')),
      );
      final previewRect = tester.getRect(find.byKey(const ValueKey('fixed-home-preview')));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('video-top-nav'))),
        navigationRect,
      );
      expect(tester.getRect(find.byKey(const ValueKey('fixed-home-preview'))), previewRect);
      expect(find.byKey(const ValueKey('preview-filter-frost')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      expect(find.text('设置与隐私'), findsOneWidget);
    },
  );

  testWidgets('playback mode cannot send another toggle while updating', (
    tester,
  ) async {
    var commands = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReferenceLoopPage(
            enabled: true,
            updating: true,
            factoryCount: 23,
            onChanged: (_) => commands++,
            onBack: () {},
          ),
        ),
      ),
    );
    expect(find.byType(Switch), findsNothing);
    expect(find.textContaining('保留完整的入场与退场动画'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(commands, 0);
  });
  testWidgets('shows the badge GIF workspace', (tester) async {
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();

    expect(find.text('ESP-BAJI'), findsNothing);
    expect(find.byKey(const ValueKey('nav-4')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('find-animation')), findsOneWidget);
    expect(find.text('导入'), findsNothing);
  });

  testWidgets(
    'my library opens the import sheet and can close without picking media',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const BadgeApp());
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的库'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('add-material')),
        200,
      );
      await tester.tap(find.byKey(const ValueKey('add-material')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('video-upload-sheet')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('maker-name')), '我的视频');
      await tester.tap(find.byKey(const ValueKey('close-maker')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('video-upload-sheet')), findsNothing);
      expect(find.byKey(const ValueKey('find-animation')), findsOneWidget);
    },
  );

  testWidgets('uses plain colored connection text without page crossfade', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-0')));
    await tester.pumpAndSettle();

    expect(find.text('连接设备'), findsOneWidget);
    expect(find.text('已下载'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-alignment')), findsNothing);
    expect(find.byType(AnimatedSwitcher), findsNothing);
  });

  testWidgets('keeps video navigation at the top and search at the bottom', (
    tester,
  ) async {
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationDestination), findsNothing);
    expect(find.byKey(const ValueKey('floating-bottom-nav')), findsNothing);
    final nav = tester.getRect(find.byKey(const ValueKey('video-top-nav')));
    final search = tester.getRect(find.byKey(const ValueKey('find-animation')));
    expect(nav.bottom, lessThan(search.top));
    await tester.tap(find.byKey(const ValueKey('find-animation')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('privacy policy link is on device page but not home page', (
    tester,
  ) async {
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();

    expect(find.text('隐私政策'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('nav-0')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('privacy-policy-link')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.byKey(const ValueKey('privacy-policy-link')), findsOneWidget);
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
      'fps': 25,
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
    expect(source, contains('WidgetsBindingObserver'));
    expect(source, contains('AppLifecycleState.resumed'));
    expect(source, contains('_appActive'));
    expect(source, contains('_previewActive'));
    expect(
      source,
      contains('bool get _previewActive => _appActive && !_preparing;'),
    );
    expect(
      source,
      isNot(
        contains(
          'bool get _previewActive => _appActive && !_preparing && !_uploading;',
        ),
      ),
    );
    expect(source, contains('previewActive && _pageIndex == 1'));
    expect(source, contains('previewActive && _pageIndex == 2'));
    expect(source, isNot(contains('DevicePreview(')));
    expect(source, contains('await controller.pause()'));
    expect(source, contains('void activate()'));
    expect(source, contains(r"key: ValueKey('maker-video-${selected.uri}')"));
    expect(
      source,
      isNot(contains(r"key: ValueKey('dial-asset-video-${asset!.sourceUri}')")),
    );
    expect(
      source,
      isNot(contains(r"key: ValueKey('history-video-${entry.assetPath}')")),
    );
    expect(
      source,
      contains('child = StaticMaterialPreview('),
    );
    expect(source, contains('_PreviewDial('));
    expect(source, contains('active: active'));
    expect(source, contains('active: widget.active && !widget.preparing'));
    expect(source, contains('active: active'));
    expect(source, isNot(contains('active: active && !uploading')));
    expect(source, isNot(contains('asset?.assetPath != entry.assetPath')));
    expect(source, isNot(contains('uri: entry.sourceUri!')));
  });

  test('animated image previews stay visible while upload disables taps', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(
      source,
      matches(RegExp(r'onTap:\s*uploading\s*\?\s*null\s*:\s*\(\) => onHistoryTap\(entry\)')),
    );
    expect(source, contains('active: active'));
    expect(source, isNot(contains('active: active && !uploading')));
    expect(
      source,
      contains('child = StaticMaterialPreview('),
    );
    expect(
      source,
      contains('if (active && _hasPreviewPath(selected?.animatedPreviewPath))'),
    );
  });

  test('history previews hide missing files instead of showing error icons', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('errorBuilder: _blackPreviewFallback'));
    expect(source, contains('bool _previewFileExists'));
    expect(source, contains("'deleteAssetFiles'"));
    expect(source, contains('_deleteNativeAssetFiles'));
    expect(
      source,
      isNot(
        contains(
          'bool _hasPreviewPath(String? path) => path != null && path.isNotEmpty;',
        ),
      ),
    );
  });

  test('privacy policy is public and opened through native url launcher', () {
    final source = File('lib/main.dart').readAsStringSync();
    final privacy = File('../docs/privacy.html').readAsStringSync();

    expect(
      source,
      contains('https://leyyoudian.github.io/flutter_app/privacy.html'),
    );
    expect(source, contains("'openUrl'"));
    expect(source, contains('privacy-policy-link'));
    expect(privacy, contains('ESP Baji Privacy Policy'));
    expect(privacy, contains('本应用不会收集、出售或分享个人信息'));
    expect(privacy, contains('href="mailto:3280035093@qq.com">3280035093@qq.com</a>'));
    expect(source, contains("static const _contactEmail = '3280035093@qq.com'"));
  });

  test('support page is public for App Store Connect metadata', () {
    final support = File('../docs/support.html').readAsStringSync();

    expect(support, contains('ESP Baji Support'));
    expect(support, contains('href="mailto:3280035093@qq.com">3280035093@qq.com</a>'));
    expect(support, contains('隐私政策'));
  });
}
