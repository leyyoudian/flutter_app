import 'dart:async';
import 'package:app_gif/app_language.dart';
import 'package:app_gif/fly_bird.dart';
import 'package:app_gif/main.dart';
import 'package:app_gif/reference_ui.dart';
import 'package:app_gif/calibration.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('esp_baji/native');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  testWidgets(
    'connection and start waits show a label and three bouncing black dots',
    (tester) async {
      final connection = Completer<Map<String, dynamic>>();
      final start = Completer<bool>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'ensureGameBluetooth') return connection.future;
        if (call.method == 'sendGameControl') return start.future;
        return null;
      });
      await tester.pumpWidget(const MaterialApp(home: FlyBirdPage()));
      expect(find.text(tr('启动中')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('game-start')))
            .onPressed,
        isNull,
      );
      final dot = find.byKey(const ValueKey('game-starting-dot-0'));
      final before = tester.widget<Transform>(dot).transform.storage[13];
      for (var index = 0; index < 3; index++) {
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: find.byKey(ValueKey('game-starting-dot-$index')),
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as BoxDecoration;
        expect(decoration.color, Colors.black);
        expect(decoration.shape, BoxShape.circle);
      }
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.widget<Transform>(dot).transform.storage[13],
        lessThan(before),
      );
      connection.complete({'connected': true});
      await tester.pumpAndSettle();
      expect(find.text(tr('开始游戏')), findsOneWidget);
      expect(dot, findsNothing);
      await tester.tap(find.byKey(const ValueKey('game-start')));
      await tester.pump();
      expect(find.text(tr('启动中')), findsOneWidget);
      expect(dot, findsOneWidget);
      start.complete(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('game-touchpad')), findsOneWidget);
      expect(find.text(tr('启动中')), findsNothing);
    },
  );

  testWidgets('game connects Bluetooth then sends real start, flap and stop', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'ensureGameBluetooth') {
        return {
          'connected': true,
          'name': 'DotLoop',
          'address': '38:44:BE:0F:67:2A',
        };
      }
      if (call.method == 'sendGameControl') return true;
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: FlyBirdPage()));
    await tester.pumpAndSettle();
    expect(calls.map((c) => c.method), contains('ensureGameBluetooth'));
    await tester.tap(find.byKey(const ValueKey('game-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('game-touchpad')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('game-stop')));
    await tester.pumpAndSettle();
    expect(
      calls
          .where((c) => c.method == 'sendGameControl')
          .map((c) => (c.arguments as Map)['action']),
      ['start', 'flap', 'stop'],
    );
    expect(find.byKey(const ValueKey('game-start')), findsOneWidget);
  });

  testWidgets('missing Bluetooth plugin never claims the game has started', (
    tester,
  ) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw MissingPluginException(),
    );
    await tester.pumpWidget(const MaterialApp(home: FlyBirdPage()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('game-touchpad')), findsNothing);
    expect(find.byKey(const ValueKey('game-connection-error')), findsOneWidget);
    expect(find.text(tr('开始游戏')), findsOneWidget);
    expect(find.text(tr('重新连接')), findsOneWidget);
    expect(find.text(tr('启动中')), findsNothing);
  });

  testWidgets('rejected start stays idle and shows a useful error', (
    tester,
  ) async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'ensureGameBluetooth') return {'connected': true};
      if (call.method == 'sendGameControl') return false;
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: FlyBirdPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('game-start')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('game-touchpad')), findsNothing);
    expect(find.byKey(const ValueKey('game-connection-error')), findsOneWidget);
  });

  testWidgets('home always has a factory cover before video playback', (
    tester,
  ) async {
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();
    final preview = find.byKey(const ValueKey('fixed-home-preview'));
    expect(
      find.descendant(
        of: preview,
        matching: find.byKey(const ValueKey('factory-preview-fallback')),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'back cannot abandon a pending game start and dispose releases BLE',
    (tester) async {
      final start = Completer<bool>();
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'ensureGameBluetooth') return {'connected': true};
        if (call.method == 'sendGameControl') return start.future;
        return null;
      });
      await tester.pumpWidget(const MaterialApp(home: FlyBirdPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('game-start')));
      await tester.pump();
      expect(
        tester
            .widget<PopScope>(
              find.byWidgetPredicate((widget) => widget is PopScope),
            )
            .canPop,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(calls.map((c) => c.method), contains('releaseGameBluetooth'));
      start.complete(true);
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'lost Bluetooth during play returns to a reconnectable idle page',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'ensureGameBluetooth') return {'connected': true};
        if (call.method == 'sendGameControl') {
          if ((call.arguments as Map)['action'] == 'flap') {
            throw PlatformException(
              code: 'bluetooth_disconnected',
              message: 'Device disconnected',
            );
          }
          return true;
        }
        return null;
      });
      await tester.pumpWidget(const MaterialApp(home: FlyBirdPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('game-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('game-touchpad')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('game-touchpad')), findsNothing);
      expect(find.byKey(const ValueKey('game-start')), findsOneWidget);
      expect(
        tester
            .widget<PopScope>(
              find.byWidgetPredicate((widget) => widget is PopScope),
            )
            .canPop,
        isTrue,
      );
    },
  );

  for (final failedAction in ['start', 'stop']) {
    testWidgets('lost $failedAction ACK allows reconnect and leaving game', (
      tester,
    ) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'ensureGameBluetooth') return {'connected': true};
        if (call.method == 'sendGameControl') {
          if ((call.arguments as Map)['action'] == failedAction) {
            throw PlatformException(
              code: 'bluetooth_disconnected',
              message: 'Device did not confirm. Reconnect.',
            );
          }
          return true;
        }
        return null;
      });
      await tester.pumpWidget(const MaterialApp(home: FlyBirdPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('game-start')));
      await tester.pumpAndSettle();
      if (failedAction == 'stop') {
        await tester.tap(find.byKey(const ValueKey('game-stop')));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('game-touchpad')), findsNothing);
      expect(find.text(tr('重新连接')), findsOneWidget);
      expect(
        tester
            .widget<PopScope>(find.byWidgetPredicate((w) => w is PopScope))
            .canPop,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'brightness, playback and alignment use the same compact back style',
    (tester) async {
      final pages = <Widget>[
        ReferenceBrightnessPage(
          initialValue: 70,
          connected: true,
          onChanged: (_) {},
        ),
        ReferenceLoopPage(
          enabled: false,
          updating: false,
          factoryCount: 23,
          onChanged: (_) {},
          onBack: () {},
        ),
        AlignmentPage(
          connected: false,
          enter: () async =>
              const CalibrationSnapshot(angleTenths: 0, active: false),
          preview: (_) async {},
          save: (_) async {},
          cancel: () async {},
        ),
      ];
      for (final page in pages) {
        await tester.pumpWidget(MaterialApp(home: page));
        await tester.pumpAndSettle();
        final appBar = tester.widget<AppBar>(find.byType(AppBar));
        expect(appBar.toolbarHeight ?? kToolbarHeight, kToolbarHeight);
        expect(appBar.leading, isA<BackButton>());
        expect(
          find
              .byType(IconButton)
              .evaluate()
              .where((e) => (e.widget as IconButton).isSelected == true),
          isEmpty,
        );
      }
    },
  );
}
