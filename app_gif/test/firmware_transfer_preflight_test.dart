import 'package:app_gif/firmware_update.dart';
import 'package:app_gif/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/old-ota');
  testWidgets(
    '0.2.8 unsupported stop reaches OTA upload on both platforms',
    (tester) async {
      LanguageSettings.current.value = AppLanguage.chinese;
      final calls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'downloadFirmware') {
          return {'assetPath': '/cache/verified.bin'};
        }
        if (call.method == 'gameCommand') {
          throw PlatformException(
            code: 'game_rejected',
            message: '设备拒绝指令：GB:93:ERR:106',
          );
        }
        if (call.method == 'uploadFirmware') {
          expect((call.arguments as Map)['deviceId'], 'P4-AABBCCDDEEFF');
          return {'success': true};
        }
        return null;
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final manifest = FirmwareManifest.fromMap({
        'hardware': 'esp32p4-2.8',
        'version': '0.2.9',
        'url': 'http://server/firmware.bin',
        'size': 2049648,
        'sha256': 'a' * 64,
      }, 'esp32p4-2.8');
      await tester.pumpWidget(
        MaterialApp(
          home: FirmwareUpdatePage(
            hardware: 'esp32p4-2.8',
            currentVersion: '0.2.8',
            backendBases: [Uri.parse('http://server')],
            initialManifest: manifest,
            channel: channel,
            setBusy: (_) {},
            deviceIdentity: () async => 'P4-AABBCCDDEEFF',
            prepareTransfer: () => prepareFirmwareTransfer(
              stopGame: () =>
                  channel.invokeMethod<void>('gameCommand', {'action': 'stop'}),
              cancelCalibration: () =>
                  channel.invokeMethod<void>('cancelCalibration'),
              connectTransfer: () async {
                calls.add('verifiedHotspot');
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载并更新'));
      await tester.pumpAndSettle();
      expect(calls, [
        'downloadFirmware',
        'gameCommand',
        'cancelCalibration',
        'verifiedHotspot',
        'uploadFirmware',
        'leaveDeviceAccessPoint',
      ]);
      expect(find.text('更新完成，请重新连接设备'), findsOneWidget);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final message in ['106', '设备拒绝指令：GB:93:ERR:106']) {
    test(
      'OTA continues when old firmware rejects optional stop: $message',
      () async {
        final calls = <String>[];
        final ready = await prepareFirmwareTransfer(
          stopGame: () async {
            calls.add('stop');
            throw PlatformException(code: 'game_rejected', message: message);
          },
          cancelCalibration: () async => calls.add('cancelCalibration'),
          connectTransfer: () async {
            calls.add('verifiedTransfer');
            return true;
          },
        );
        expect(ready, isTrue);
        expect(calls, ['stop', 'cancelCalibration', 'verifiedTransfer']);
      },
    );
  }

  test(
    'normal firmware still stops game before calibration and hotspot',
    () async {
      final calls = <String>[];
      final ready = await prepareFirmwareTransfer(
        stopGame: () async => calls.add('stop'),
        cancelCalibration: () async => calls.add('calibration'),
        connectTransfer: () async {
          calls.add('hotspot');
          return false;
        },
      );
      expect(ready, isFalse);
      expect(calls, ['stop', 'calibration', 'hotspot']);
    },
  );

  for (final error in [
    PlatformException(code: 'game_rejected', message: '103'),
    PlatformException(code: 'bluetooth_disconnected', message: '106'),
    PlatformException(code: 'game_rejected', message: 'GB:93:ERR:1060'),
    PlatformException(code: 'game_rejected', message: 'GB:93:ERR:107'),
  ]) {
    test('OTA retains failures for ${error.code}/${error.message}', () async {
      var connected = false;
      await expectLater(
        prepareFirmwareTransfer(
          stopGame: () async => throw error,
          cancelCalibration: () async {},
          connectTransfer: () async {
            connected = true;
            return true;
          },
        ),
        throwsA(same(error)),
      );
      expect(connected, isFalse);
    });
  }

  test('calibration rejection still blocks transfer', () async {
    final error = PlatformException(code: 'control_rejected', message: '106');
    await expectLater(
      prepareFirmwareTransfer(
        stopGame: () async =>
            throw PlatformException(code: 'game_rejected', message: '106'),
        cancelCalibration: () async => throw error,
        connectTransfer: () async => true,
      ),
      throwsA(same(error)),
    );
  });
}
