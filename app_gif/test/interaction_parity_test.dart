import 'dart:io';

import 'package:app_gif/app_language.dart';
import 'package:app_gif/calibration.dart';
import 'package:app_gif/fly_bird.dart';
import 'package:app_gif/main.dart';
import 'package:app_gif/reference_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('esp_baji/native');
  final haptics = <String>[];
  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  setUp(() {
    LanguageSettings.current.value = AppLanguage.chinese;
    haptics.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String);
        }
        return null;
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      if (call.method == 'ensureGameBluetooth') return {'connected': true};
      if (call.method == 'sendGameControl') return true;
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  testWidgets(
    'iOS and Android use the same Material theme and navigation feedback',
    (tester) async {
      await tester.pumpWidget(const BadgeApp());
      await tester.pumpAndSettle();
      final context = tester.element(find.byKey(const ValueKey('nav-4')));
      expect(Theme.of(context).platform, TargetPlatform.android);
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      expect(find.text('设置与隐私'), findsOneWidget);
      expect(haptics, contains('HapticFeedbackType.selectionClick'));
      expect(tester.takeException(), isNull);
    },
    variant: platforms,
  );

  testWidgets('playback switch remains Material on both platforms', (
    tester,
  ) async {
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => ReferenceLoopPage(
            enabled: enabled,
            updating: false,
            factoryCount: 23,
            onChanged: (value) => setState(() => enabled = value),
            onBack: () {},
          ),
        ),
      ),
    );
    expect(find.byType(CupertinoSwitch), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  }, variant: platforms);

  testWidgets(
    'import and server save preserve P4 transfer intent on both platforms',
    (tester) async {
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'pickMedia':
            return {
              'uri': 'file:///sample.png',
              'name': 'sample.png',
              'mime': 'image/png',
              'size': 512,
            };
          case 'transcodeOnServer':
            return {
              'reviewId': 'p4-import',
              'reviewStatus': 'approved',
              'fps': 80,
            };
          case 'loadHistory':
          case 'loadPendingDeviceDeletes':
            return <dynamic>[];
          default:
            return null;
        }
      });
      await tester.binding.setSurfaceSize(const Size(400, 1000));
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
      await tester.tap(find.byKey(const ValueKey('maker-pick')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('maker-name')),
        'P4 sample',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('maker-save')));
      await tester.tap(find.byKey(const ValueKey('maker-save')));
      await tester.pumpAndSettle();
      final transcode =
          calls
                  .singleWhere((call) => call.method == 'transcodeOnServer')
                  .arguments
              as Map;
      expect(transcode['hardware'], 'esp32p4');
      expect(transcode['deviceTransfer'], isTrue);
      expect(transcode['maxFps'], 80);
      expect(transcode['name'], 'P4 sample');
      final history =
          calls.lastWhere((call) => call.method == 'saveHistory').arguments
              as List;
      expect((history.single as Map)['reviewId'], 'p4-import');
      expect((history.single as Map)['reviewStatus'], 'approved');
      expect(tester.takeException(), isNull);
    },
    variant: platforms,
  );

  testWidgets(
    'angle steps give strong feedback and save gives success feedback',
    (tester) async {
      var saved = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AlignmentPage(
                      connected: true,
                      enter: () async => const CalibrationSnapshot(
                        angleTenths: 0,
                        active: true,
                      ),
                      preview: (_) async {},
                      save: (value) async => saved = value,
                      cancel: () async {},
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alignment-plus-step')));
      await tester.pumpAndSettle();
      expect(haptics, contains('HapticFeedbackType.heavyImpact'));
      await tester.tap(find.byKey(const ValueKey('alignment-save')));
      await tester.pumpAndSettle();
      expect(saved, 1);
      expect(haptics, contains('HapticFeedbackType.mediumImpact'));
      expect(find.text('open'), findsOneWidget);
    },
    variant: platforms,
  );

  testWidgets('game starts and flaps with the same haptic sequence', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: FlyBirdPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('game-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('game-touchpad')));
    await tester.pumpAndSettle();
    expect(haptics, [
      'HapticFeedbackType.heavyImpact',
      'HapticFeedbackType.heavyImpact',
    ]);
    expect(find.text('Flappy Bird'), findsOneWidget);
    expect(find.text('重新开始'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, variant: platforms);

  test(
    'iOS preserves device transfer intent and bounds optional preview waiting',
    () {
      final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      expect(
        source,
        contains('deviceTransfer: args["deviceTransfer"] as? Bool ?? false'),
      );
      expect(source, contains('"deviceTransfer": deviceTransfer'));
      expect(
        source,
        contains('requestTimeout: BadgeConstants.previewRequestTimeout'),
      );
      expect(
        source,
        contains('resourceTimeout: BadgeConstants.previewResourceTimeout'),
      );
      expect(
        source,
        contains('configuration.timeoutIntervalForResource = resourceTimeout'),
      );
      expect(
        source,
        contains('let deadline = Date().addingTimeInterval(10 * 60)'),
      );
      expect(source, contains('Thread.sleep(forTimeInterval: 0.25)'));
      expect(source, contains('BadgeConstants.maxVideoInputBytes'));
    },
  );
}
