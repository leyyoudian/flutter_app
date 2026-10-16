import 'package:app_gif/app_language.dart';
import 'package:app_gif/calibration.dart';
import 'package:app_gif/fly_bird.dart';
import 'package:app_gif/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('esp_baji/native');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LanguageSettings.current.value = AppLanguage.chinese);
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  testWidgets('settings opens device status and a separate game card library', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-0')));
    await tester.pumpAndSettle();
    expect(find.text('TF 卡'), findsNothing);
    expect(find.text('S3 / 旧版 Wi-Fi 连接'), findsNothing);
    expect(find.text('P4 使用蓝牙连接，上传文件时再连接设备热点'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-device-status')));
    await tester.pumpAndSettle();
    expect(find.text('TF 卡'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-games')));
    await tester.tap(find.byKey(const ValueKey('settings-games')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('game-card-flappy-bird')), findsOneWidget);
    expect(find.text('Flappy Bird'), findsOneWidget);
  });

  testWidgets(
    'minimal game controller keeps flap and stop without status or restart',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'ensureGameBluetooth') return {'connected': true};
        if (call.method == 'sendGameControl') return true;
        return null;
      });
      await tester.pumpWidget(const MaterialApp(home: FlyBirdPage()));
      await tester.pumpAndSettle();
      expect(find.text('Flappy Bird'), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth_connected_rounded), findsNothing);
      expect(find.textContaining('P4'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('game-start')));
      await tester.pumpAndSettle();
      expect(find.text('重新开始'), findsNothing);
      expect(find.textContaining('看设备屏幕'), findsNothing);
      expect(find.text('碰撞后再点一次即可重新开始'), findsOneWidget);
      final hint = tester.getRect(find.text('碰撞后再点一次即可重新开始'));
      final pad = tester.getRect(find.byKey(const ValueKey('game-touchpad')));
      expect(hint.bottom, closeTo(pad.bottom - 20, 1));
      await tester.tap(find.byKey(const ValueKey('game-touchpad')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('game-stop')), findsOneWidget);
    },
  );

  testWidgets(
    'alignment keeps dial and step controls without slider or offline note',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AlignmentPage(
            connected: false,
            enter: () async =>
                const CalibrationSnapshot(angleTenths: 0, active: false),
            preview: (_) async {},
            save: (_) async {},
            cancel: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      expect(find.textContaining('离线预览'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('alignment-plus-step')));
      await tester.pumpAndSettle();
      expect(find.text('0.1°'), findsWidgets);
    },
  );

  testWidgets('language change updates navigation and localized input hints', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();
    LanguageSettings.current.value = AppLanguage.english;
    await tester.pumpAndSettle();
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.text('Home'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('find-animation')));
    await tester.pumpAndSettle();
    final search = tester.widget<TextField>(find.byType(TextField));
    expect(search.decoration?.hintText, 'Search by name or ID');
      for (final language in [AppLanguage.traditionalChinese, AppLanguage.japanese, AppLanguage.russian]) {
        LanguageSettings.current.value = language;
        await tester.pumpAndSettle();
        expect(find.byTooltip(tr('设置')), findsOneWidget);
        expect(tester.widget<TextField>(find.byType(TextField)).decoration?.hintText, tr('搜索名称或编号'));
        expect(tester.takeException(), isNull);
      }
  });
}
