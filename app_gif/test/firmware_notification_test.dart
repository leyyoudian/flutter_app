import 'dart:async';

import 'package:app_gif/app_language.dart';
import 'package:app_gif/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('esp_baji/native');
  const dot = ValueKey('settings-firmware-update-dot');
  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });
  late List<String> calls;
  late String deviceVersion;
  late String serverVersion;
  late String hardware;
  late bool connected;
  late Future<Map<String, dynamic>> Function() check;

  Map<String, dynamic> release() => {
    'hardware': 'esp32p4-2.8',
    'version': serverVersion,
    'url': 'http://server/firmware.bin',
    'size': 1000,
    'sha256': List.filled(64, 'a').join(),
  };

  setUp(() {
    LanguageSettings.current.value = AppLanguage.chinese;
    calls = [];
    deviceVersion = '0.2.1';
    serverVersion = '0.2.2';
    hardware = 'esp32p4';
    connected = true;
    check = () async => release();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      switch (call.method) {
        case 'ensureDeviceBluetooth':
        case 'deviceBluetoothState':
          return {
            'connected': connected,
            'address': 'P4-test',
            'status': 'hardware=$hardware version=$deviceVersion dc=1 sd=1',
          };
        case 'checkFirmwareUpdate':
          expect((call.arguments as Map)['hardware'], 'esp32p4-2.8');
          return check();
        case 'deviceBluetoothCommand':
          final command = (call.arguments as Map)['command'];
          return switch (command) {
            'BRIGHT GET' => 'OK BRIGHT 70',
            'RANDOM GET' => 'OK RANDOM 0',
            'CAL status' => 'OK CAL 0 0',
            _ => 'ERR UNKNOWN',
          };
        default:
          return null;
      }
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> connect(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();
    expect(calls.where((call) => call == 'checkFirmwareUpdate'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('nav-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接设备'));
    await tester.pumpAndSettle();
  }

  Future<void> settings(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('nav-4')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'connecting checks automatically and a newer firmware shows a persistent dot',
    (tester) async {
      await connect(tester);
      expect(
        calls.where((call) => call == 'checkFirmwareUpdate'),
        hasLength(1),
      );
      await settings(tester);
      expect(find.byKey(dot), findsOneWidget);
      expect(find.text('设备版本'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-device-version')));
      await tester.pumpAndSettle();
      expect(find.textContaining('发现新版本 0.2.2'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byKey(dot), findsOneWidget);
      expect(
        calls.where((call) => call == 'checkFirmwareUpdate'),
        hasLength(1),
      );
      expect(calls, isNot(contains('downloadFirmware')));
      expect(calls, isNot(contains('uploadFirmware')));
    },
    variant: platforms,
  );

  testWidgets('current or older server firmware never shows a dot', (
    tester,
  ) async {
    for (final version in ['0.2.1', '0.1.9', '0.2.0']) {
      serverVersion = version;
      await connect(tester);
      await settings(tester);
      expect(find.byKey(dot), findsNothing, reason: version);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      calls.clear();
    }
  });

  testWidgets(
    'opening the update page uses the automatically checked release',
    (tester) async {
      await connect(tester);
      await settings(tester);
      await tester.tap(find.byKey(const ValueKey('settings-device-version')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看固件更新'));
      await tester.pumpAndSettle();
      expect(find.text('下载并更新'), findsOneWidget);
      expect(find.text('发现新版本 0.2.2'), findsOneWidget);
      expect(
        calls.where((call) => call == 'checkFirmwareUpdate'),
        hasLength(1),
      );
      expect(calls, isNot(contains('downloadFirmware')));
    },
  );

  testWidgets('settings and resume share a pending background check', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    check = () => pending.future;
    await connect(tester);
    await settings(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls.where((call) => call == 'checkFirmwareUpdate'), hasLength(1));
    pending.complete(release());
    await tester.pumpAndSettle();
    expect(find.byKey(dot), findsOneWidget);
  });

  testWidgets(
    'unrecognized hardware or device version skips background checks',
    (tester) async {
      for (final status in [
        ('esp32p4-unknown', '0.2.1'),
        ('esp32p4', 'unknown'),
      ]) {
        hardware = status.$1;
        deviceVersion = status.$2;
        await connect(tester);
        await settings(tester);
        expect(calls.where((call) => call == 'checkFirmwareUpdate'), isEmpty);
        expect(find.byKey(dot), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        calls.clear();
      }
    },
  );

  testWidgets('wrong-board server release never creates an update dot', (
    tester,
  ) async {
    check = () async => {...release(), 'hardware': 'esp32p4-2.5'};
    await connect(tester);
    await settings(tester);
    expect(find.byKey(dot), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('refresh failure retains a previously confirmed update', (
    tester,
  ) async {
    await connect(tester);
    await settings(tester);
    expect(find.byKey(dot), findsOneWidget);
    check = () async => throw PlatformException(code: 'network_unavailable');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(dot), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('disconnect discards an in-flight result from the old session', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    check = () => pending.future;
    await connect(tester);
    expect(calls, contains('checkFirmwareUpdate'));
    await tester.tap(find.text('断开设备'));
    await tester.pumpAndSettle();
    pending.complete(release());
    await tester.pumpAndSettle();
    await settings(tester);
    expect(find.byKey(dot), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline check is quiet and returning to the app retries', (
    tester,
  ) async {
    check = () async => throw PlatformException(code: 'network_unavailable');
    await connect(tester);
    await settings(tester);
    expect(find.byKey(dot), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    check = () async => release();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(dot), findsOneWidget);
    expect(calls, isNot(contains('downloadFirmware')));
  });

  testWidgets('a fresh device version clears the update dot after reconnect', (
    tester,
  ) async {
    await connect(tester);
    await settings(tester);
    expect(find.byKey(dot), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('断开设备'));
    await tester.pumpAndSettle();
    deviceVersion = serverVersion;
    await tester.tap(find.text('连接设备'));
    await tester.pumpAndSettle();
    await settings(tester);
    expect(find.byKey(dot), findsNothing);
  });
}
