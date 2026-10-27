import 'dart:convert';

import 'package:app_gif/app_language.dart';
import 'package:app_gif/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _MakerVideoPlatform extends VideoPlayerPlatform {
  int creates = 0;
  int plays = 0;
  int pauses = 0;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async =>
      ++creates;
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 5),
      size: const Size(480, 480),
    ),
  );
  @override
  Future<void> play(int playerId) async {
    ++plays;
  }

  @override
  Future<void> pause(int playerId) async {
    ++pauses;
  }

  @override
  Future<void> dispose(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });
  const native = MethodChannel('esp_baji/native');
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );

  setUp(() {
    LanguageSettings.current.value = AppLanguage.chinese;
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
  });

  Future<void> openVideoMaker(
    WidgetTester tester,
    List<MethodCall> calls, {
    int coverSaveFailures = 0,
    String mime = 'video/mp4',
  }) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'loadHistory':
        case 'loadPendingDeviceDeletes':
          return <dynamic>[];
        case 'pickMedia':
          return {
            'uri': mime == 'image/gif'
                ? 'file:///sample.gif'
                : 'file:///sample.mp4',
            'name': mime == 'image/gif' ? 'sample.gif' : 'sample.mp4',
            'mime': mime,
            'size': 1024,
            'durationMs': 5000,
          };
        case 'videoFramePreview':
          return {'previewBytes': Uint8List.fromList(png)};
        case 'saveMaterialCover':
          if (coverSaveFailures-- > 0) {
            throw PlatformException(
              code: 'cover_save_failed',
              message: '封面保存失败',
            );
          }
          return '/app/material_covers/selected.png';
        case 'transcodeOnServer':
          return {
            'reviewId': 'review-1',
            'reviewStatus': 'approved',
            'fps': 30,
          };
        default:
          return null;
      }
    });

    await tester.binding.setSurfaceSize(const Size(400, 1000));
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
    await tester.tap(find.byKey(const ValueKey('maker-pick')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'video maker starts blank and supports zooming out and frame selection',
    (tester) async {
      final calls = <MethodCall>[];
      await openVideoMaker(tester, calls);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final nameField = tester.widget<TextField>(
        find.byKey(const ValueKey('maker-name')),
      );
      expect(nameField.controller!.text, isEmpty);

      final zoomSlider = tester.widget<Slider>(
        find.byKey(const ValueKey('maker-zoom-slider')),
      );
      expect(zoomSlider.min, .5);
      expect(zoomSlider.max, 4);

      expect(
        find.byKey(const ValueKey('maker-cover-frame-slider')),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('maker-cover-mode')),
      );
      await tester.tap(find.byKey(const ValueKey('maker-cover-mode')));
      await tester.pumpAndSettle();
      final coverButton = tester.widget<TextButton>(
        find.byKey(const ValueKey('maker-cover-mode')),
      );
      expect(
        coverButton.style!.side!.resolve({})!.color,
        const Color(0xff66cc88),
      );

      final coverSlider = tester.widget<Slider>(
        find.byKey(const ValueKey('maker-cover-frame-slider')),
      );
      coverSlider.onChanged!(.65);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();

      final framePreview = calls.lastWhere(
        (call) => call.method == 'videoFramePreview',
      );
      final args = framePreview.arguments as Map;
      expect(args['coverFrame'], .65);
      expect(args['cropScale'], 1);

      expect(find.byKey(const ValueKey('maker-cover-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('maker-cover-mode')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('maker-cover-frame-slider')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('maker-cover-preview')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('maker-cover-mode')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('maker-cover-frame-slider')),
            )
            .value,
        .65,
      );
    },
    variant: platforms,
  );

  testWidgets(
    'GIF supports the same cover toggle, time selection and saved cover as video',
    (tester) async {
      final calls = <MethodCall>[];
      await openVideoMaker(tester, calls, mime: 'image/gif');
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final mode = find.byKey(const ValueKey('maker-cover-mode'));
      expect(mode, findsOneWidget);
      await tester.ensureVisible(mode);
      await tester.tap(mode);
      await tester.pumpAndSettle();
      tester
          .widget<Slider>(
            find.byKey(const ValueKey('maker-cover-frame-slider')),
          )
          .onChanged!(.8);
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('maker-cover-preview')), findsOneWidget);
      final preview =
          calls.lastWhere((c) => c.method == 'videoFramePreview').arguments
              as Map;
      expect(preview['uri'], 'file:///sample.gif');
      expect(preview['coverFrame'], .8);
      await tester.tap(mode);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('maker-cover-frame-slider')),
        findsNothing,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('maker-save')));
      await tester.tap(find.byKey(const ValueKey('maker-save')));
      await tester.pumpAndSettle();
      final savedPreview =
          calls.lastWhere((c) => c.method == 'videoFramePreview').arguments
              as Map;
      expect(savedPreview['coverFrame'], .8);
      final entry =
          (calls.lastWhere((c) => c.method == 'saveHistory').arguments as List)
                  .single
              as Map;
      expect(entry['previewPath'], '/app/material_covers/selected.png');
      expect(entry['previewCropApplied'], isTrue);
      expect(
        calls.where((c) => c.method == 'warmVideoAnimatedPreview'),
        isEmpty,
      );
      expect(calls.where((c) => c.method == 'uploadAsset'), isEmpty);
    },
    variant: platforms,
  );

  testWidgets(
    'cover mode pauses the existing preview and resumes it without another player',
    (tester) async {
      final previous = VideoPlayerPlatform.instance;
      final platform = _MakerVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        VideoPlayerPlatform.instance = previous;
        await tester.binding.setSurfaceSize(null);
      });
      await openVideoMaker(tester, <MethodCall>[]);
      expect(platform.creates, 1);
      final played = platform.plays;
      final paused = platform.pauses;
      await tester.ensureVisible(
        find.byKey(const ValueKey('maker-cover-mode')),
      );
      await tester.tap(find.byKey(const ValueKey('maker-cover-mode')));
      await tester.pumpAndSettle();
      expect(platform.pauses, greaterThan(paused));
      expect(platform.plays, played);
      expect(find.byKey(const ValueKey('maker-cover-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('maker-cover-mode')));
      await tester.pumpAndSettle();
      expect(platform.plays, greaterThan(played));
      expect(platform.creates, 1);
    },
    variant: platforms,
  );

  testWidgets(
    'video maker saves selected frame and generates a name only when blank',
    (tester) async {
      final calls = <MethodCall>[];
      await openVideoMaker(tester, calls);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.ensureVisible(
        find.byKey(const ValueKey('maker-cover-mode')),
      );
      await tester.tap(find.byKey(const ValueKey('maker-cover-mode')));
      await tester.pumpAndSettle();
      final coverSlider = tester.widget<Slider>(
        find.byKey(const ValueKey('maker-cover-frame-slider')),
      );
      coverSlider.onChanged!(.4);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('maker-name')), '   ');
      await tester.ensureVisible(find.byKey(const ValueKey('maker-save')));
      await tester.tap(find.byKey(const ValueKey('maker-save')));
      await tester.pumpAndSettle();

      final transcode = calls.singleWhere(
        (call) => call.method == 'transcodeOnServer',
      );
      final generatedName = (transcode.arguments as Map)['name'] as String;
      expect(generatedName, matches(RegExp(r'^动画_\d{8}_\d{6}_\d{3}$')));

      expect(calls.any((call) => call.method == 'saveMaterialCover'), isTrue);
      final history = calls.lastWhere((call) => call.method == 'saveHistory');
      final entry = (history.arguments as List).single as Map;
      expect(entry['previewPath'], '/app/material_covers/selected.png');
      expect(entry['previewCropApplied'], isTrue);
      expect(
        HistoryEntry.fromMap(
          Map<String, dynamic>.from(entry),
        ).toMap()['previewCropApplied'],
        isTrue,
      );
    },
    variant: platforms,
  );

  testWidgets(
    'picking the same source again clears the entered display name',
    (tester) async {
      final calls = <MethodCall>[];
      await openVideoMaker(tester, calls);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.enterText(find.byKey(const ValueKey('maker-name')), '旧名字');
      await tester.ensureVisible(find.text('更换素材'));
      await tester.tap(find.text('更换素材'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('maker-name')))
            .controller!
            .text,
        isEmpty,
      );
    },
    variant: platforms,
  );

  testWidgets(
    'custom name and zoom out are passed to the existing transcode flow',
    (tester) async {
      final calls = <MethodCall>[];
      await openVideoMaker(tester, calls);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.enterText(
        find.byKey(const ValueKey('maker-name')),
        '  我的动画  ',
      );
      tester
          .widget<Slider>(find.byKey(const ValueKey('maker-zoom-slider')))
          .onChanged!(.5);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('maker-save')));
      await tester.tap(find.byKey(const ValueKey('maker-save')));
      await tester.pumpAndSettle();
      final arguments =
          calls.singleWhere((c) => c.method == 'transcodeOnServer').arguments
              as Map;
      expect(arguments['name'], '我的动画');
      expect(arguments['cropScale'], .5);
      final preview =
          calls.lastWhere((c) => c.method == 'videoFramePreview').arguments
              as Map;
      expect(preview['cropScale'], .5);
      expect(calls.where((c) => c.method == 'uploadAsset'), isEmpty);
    },
    variant: platforms,
  );

  testWidgets(
    'cover save failure does not report success and can be retried',
    (tester) async {
      final calls = <MethodCall>[];
      await openVideoMaker(tester, calls, coverSaveFailures: 1);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.ensureVisible(find.byKey(const ValueKey('maker-save')));
      await tester.tap(find.byKey(const ValueKey('maker-save')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'saveHistory'), isEmpty);
      expect(find.text('封面保存失败'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('maker-save')));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'saveHistory'), hasLength(1));
    },
    variant: platforms,
  );

  testWidgets(
    'version tapping keeps the cancelled creator tools unavailable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const BadgeApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      final version = find.byKey(const ValueKey('app-version'));
      await tester.ensureVisible(version);
      for (var i = 0; i < 12; ++i) {
        await tester.tap(version);
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byKey(const ValueKey('creator-tools-entry')), findsNothing);
      expect(find.text('个人创作工具'), findsNothing);
    },
    variant: platforms,
  );
}
