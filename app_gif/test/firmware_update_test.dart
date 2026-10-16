import 'package:app_gif/firmware_update.dart';
import 'package:app_gif/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> release() => {
  'hardware': 'esp32p4-2.8',
  'version': '0.2.2',
  'url': 'http://47.108.204.22/downloads/firmware/p4.bin',
  'size': 1869040,
  'sha256': List.filled(64, 'a').join(),
};

void main() {
  setUp(() => LanguageSettings.current.value = AppLanguage.chinese);
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/firmware');

  test(
    'rejects another board, missing checksum, unbounded image and unsafe URL',
    () {
      for (final override in [
        {'hardware': 'esp32s3'},
        {'hardware': 'esp32p4-2.5'},
        {'sha256': ''},
        {'sha256': 'bad'},
        {'size': 0},
        {'size': 4 * 1024 * 1024},
        {'url': 'file:///tmp/fw.bin'},
        {'version': 'not-a-version'},
      ]) {
        expect(
          () => FirmwareManifest.fromMap({
            ...release(),
            ...override,
          }, 'esp32p4-2.8'),
          throwsFormatException,
        );
      }
      expect(
        FirmwareManifest.fromMap(release(), 'esp32p4-2.8').version,
        '0.2.2',
      );
      expect(firmwareIsOlder('0.2.2', '0.2.3'), isTrue);
      expect(firmwareIsOlder('0.2.10', '0.2.3'), isFalse);
    },
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'lost update acknowledgement requires reconnect before another flash',
    (tester) async {
      var uploads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'checkFirmwareUpdate') return release();
            if (call.method == 'downloadFirmware') {
              return {'assetPath': '/cache/firmware.bin'};
            }
            if (call.method == 'uploadFirmware') {
              uploads++;
              throw PlatformException(
                code: 'firmware_result_unknown',
                message: '固件已传送，请重新连接并查看实际固件版本',
              );
            }
            return null;
          });
      await tester.pumpWidget(
        MaterialApp(
          home: FirmwareUpdatePage(
            hardware: 'esp32p4-2.8',
            currentVersion: '0.2.1',
            backendBases: [Uri.parse('http://server')],
            channel: channel,
            deviceIdentity: () async => 'P4-123456789ABC',
            setBusy: (_) {},
            prepareTransfer: () async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载并更新'));
      await tester.pumpAndSettle();
      expect(find.textContaining('重新连接并查看实际固件版本'), findsOneWidget);
      expect(find.text('下载并更新'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(uploads, 1);
    },
  );

  testWidgets(
    'downloads and verifies before AP join then sends identity and releases busy',
    (tester) async {
      final events = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            events.add(call.method);
            switch (call.method) {
              case 'checkFirmwareUpdate':
                return release();
              case 'downloadFirmware':
                return {'assetPath': '/cache/firmware.bin'};
              case 'uploadFirmware':
                expect((call.arguments as Map)['deviceId'], 'P4-123456789ABC');
                expect((call.arguments as Map)['sha256'], release()['sha256']);
                return {'success': true, 'version': '0.2.2'};
            }
            return null;
          });
      await tester.pumpWidget(
        MaterialApp(
          home: FirmwareUpdatePage(
            hardware: 'esp32p4-2.8',
            currentVersion: '0.2.1',
            backendBases: [Uri.parse('http://server')],
            channel: channel,
            deviceIdentity: () async => 'P4-123456789ABC',
            setBusy: (busy) => events.add('busy:$busy'),
            prepareTransfer: () async {
              events.add('AP');
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载并更新'));
      await tester.pumpAndSettle();
      expect(events, [
        'checkFirmwareUpdate',
        'busy:true',
        'downloadFirmware',
        'AP',
        'uploadFirmware',
        'leaveDeviceAccessPoint',
        'busy:false',
      ]);
      expect(find.text('更新完成，请重新连接设备'), findsOneWidget);
    },
  );

  testWidgets('failed integrity download never opens AP or uploads', (
    tester,
  ) async {
    final events = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          events.add(call.method);
          if (call.method == 'checkFirmwareUpdate') return release();
          if (call.method == 'downloadFirmware') {
            throw PlatformException(
              code: 'firmware_invalid',
              message: 'SHA256 校验失败',
            );
          }
          return null;
        });
    await tester.pumpWidget(
      MaterialApp(
        home: FirmwareUpdatePage(
          hardware: 'esp32p4-2.8',
          currentVersion: '0.2.1',
          backendBases: [Uri.parse('http://server')],
          channel: channel,
          deviceIdentity: () async => 'P4-123456789ABC',
          setBusy: (_) {},
          prepareTransfer: () async {
            events.add('AP');
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载并更新'));
    await tester.pumpAndSettle();
    expect(events, [
      'checkFirmwareUpdate',
      'downloadFirmware',
      'leaveDeviceAccessPoint',
    ]);
    expect(find.text('SHA256 校验失败'), findsOneWidget);
  });
}
