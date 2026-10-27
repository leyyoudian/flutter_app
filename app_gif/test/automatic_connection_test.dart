import 'package:app_gif/app_language.dart';
import 'package:app_gif/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const native = MethodChannel('esp_baji/native');
  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });
  late List<MethodCall> calls;
  late bool connected;
  late bool fail;
  late bool permissionRequests;

  setUp(() {
    calls = [];
    connected = false;
    fail = false;
    permissionRequests = false;
    LanguageSettings.current.value = AppLanguage.chinese;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
          calls.add(call);
          if (call.method == 'connectionState') return {'connected': false};
          if (call.method == 'ensureDeviceBluetooth') {
            permissionRequests =
                (call.arguments as Map)['requestPermissions'] == true;
            if (fail) {
              throw PlatformException(
                code: 'bluetooth_off',
                message: '请先打开手机蓝牙',
              );
            }
            connected = true;
            return {
              'connected': true,
              'address': 'test-device',
              'status': 'hardware=esp32p4 dc=1 sd=1 version=0.2.6',
            };
          }
          if (call.method == 'deviceBluetoothState') {
            return {
              'connected': connected,
              'address': 'test-device',
              'status': 'hardware=esp32p4 dc=1 sd=1 version=0.2.6',
            };
          }
          if (call.method == 'deviceBluetoothCommand') return 'OK';
          if (call.method == 'releaseGameBluetooth') connected = false;
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  testWidgets(
    'opening connects once through the common BLE path on either platform',
    (tester) async {
      await tester.pumpWidget(const BadgeApp());
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'ensureDeviceBluetooth'),
        hasLength(1),
      );
      expect(connected, isTrue);
      expect(permissionRequests, isTrue);
      await tester.pump(const Duration(seconds: 25));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'ensureDeviceBluetooth'),
        hasLength(1),
      );
      await tester.pumpWidget(const SizedBox());
    },
    variant: platforms,
  );

  testWidgets(
    'absent device stays quiet and retries are throttled without repeated permission requests',
    (tester) async {
      fail = true;
      await tester.pumpWidget(const BadgeApp());
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'ensureDeviceBluetooth'),
        hasLength(1),
      );
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'ensureDeviceBluetooth'),
        hasLength(1),
      );
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'ensureDeviceBluetooth').length,
        greaterThan(1),
      );
      expect(permissionRequests, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'manual disconnect stays disconnected until the user reconnects',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const BadgeApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('断开设备'));
      await tester.pumpAndSettle();
      expect(connected, isFalse);
      await tester.pump(const Duration(seconds: 40));
      await tester.pumpAndSettle();
      expect(connected, isFalse);
      expect(
        calls.where((c) => c.method == 'ensureDeviceBluetooth'),
        hasLength(1),
      );
      await tester.tap(find.text('连接设备'));
      await tester.pumpAndSettle();
      expect(connected, isTrue);
      expect(
        calls.where((c) => c.method == 'ensureDeviceBluetooth'),
        hasLength(2),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('background pauses automatic connection, resume retries once', (
    tester,
  ) async {
    fail = true;
    await tester.pumpWidget(const BadgeApp());
    await tester.pumpAndSettle();
    final count = calls
        .where((c) => c.method == 'ensureDeviceBluetooth')
        .length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 40));
    expect(
      calls.where((c) => c.method == 'ensureDeviceBluetooth'),
      hasLength(count),
    );
    fail = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(connected, isTrue);
    expect(
      calls.where((c) => c.method == 'ensureDeviceBluetooth'),
      hasLength(count + 1),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
