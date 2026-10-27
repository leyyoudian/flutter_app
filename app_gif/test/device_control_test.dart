import 'dart:async';
import 'package:app_gif/device_control.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'BLE switches every factory family and preserves protected operations',
    () async {
      final sent = <String>[];
      final control = DeviceControl((command) async {
        sent.add(command);
        return 'OK';
      });
      for (final id in [
        'F001',
        'F022',
        'F023',
        ...List.generate(10, (i) => 'S${(i + 1).toString().padLeft(3, '0')}'),
      ]) {
        expect(await control.invoke('switchToAsset', {'id': id}), true);
        expect(sent.last, 'SWITCH $id');
      }
      final count = sent.length;
      for (final id in ['S003', 'F003']) {
        for (final method in ['statDeviceAsset', 'deleteDeviceAsset']) {
          await expectLater(
            control.invoke(method, {'id': id, 'crc32': '1234abcd'}),
            throwsA(isA<PlatformException>()),
          );
        }
        await expectLater(
          control.invoke('switchToAsset', {'id': id, 'crc32': '1234abcd'}),
          throwsA(isA<PlatformException>()),
        );
      }
      for (final id in ['S01', 'S0003', 'S003\nAP', 'X003', 'U003']) {
        await expectLater(
          control.invoke('switchToAsset', {'id': id}),
          throwsA(isA<PlatformException>()),
        );
      }
      expect(sent.length, count);
    },
  );
  test(
    'brightness read validates the device value and preserves zero',
    () async {
      for (final value in [0, 17, 100]) {
        final control = DeviceControl((command) async {
          expect(command, 'BRIGHT GET');
          return 'OK BRIGHT $value';
        });
        expect(await control.invoke('getBrightness'), value);
      }
      for (final reply in [
        'OK',
        'OK BRIGHT -1',
        'OK BRIGHT 101',
        'ERR UNKNOWN',
      ]) {
        await expectLater(
          DeviceControl((_) async => reply).invoke('getBrightness'),
          throwsA(isA<PlatformException>()),
        );
      }
    },
  );
  test(
    'allocated device id must come from a valid acknowledged reply',
    () async {
      final invalid = DeviceControl((_) async => 'ERR BUSY');
      await expectLater(
        invalid.invoke('switchToAsset', {'id': 'NEWID'}),
        throwsA(isA<PlatformException>()),
      );
      final valid = DeviceControl((_) async => 'OK U007');
      expect(await valid.invoke('switchToAsset', {'id': 'NEWID'}), 'U007');
    },
  );
  test('BLE switch preserves CRC identity and NEED_UPLOAD result', () async {
    final sent = <String>[];
    final control = DeviceControl((command) async {
      sent.add(command);
      return 'NEED_UPLOAD U006';
    });
    final result = await control.invoke('switchToAsset', {
      'id': 'U006',
      'crc32': '1234abcd',
    });
    expect(sent, ['SWITCH U006 1234abcd']);
    expect(result, {'needsUpload': true, 'id': 'U006'});
    await expectLater(
      control.invoke('switchToAsset', {'id': 'U006'}),
      throwsA(isA<PlatformException>()),
    );
  });
  test(
    'control commands serialize and recover after a failed request',
    () async {
      final gate = Completer<String>();
      final sent = <String>[];
      final control = DeviceControl((command) async {
        sent.add(command);
        if (sent.length == 1) return gate.future;
        return 'OK RANDOM 1';
      });
      final first = control.invoke('getRandomMode');
      final failed = expectLater(first, throwsA(isA<PlatformException>()));
      final second = control.invoke('getRandomMode');
      await Future<void>.delayed(Duration.zero);
      expect(sent, ['RANDOM GET']);
      gate.completeError(PlatformException(code: 'timeout'));
      await failed;
      expect(await second, true);
      expect(sent.length, 2);
    },
  );
  test(
    'BLE calibration parses saved angle and factory deletion is forbidden',
    () async {
      final sent = <String>[];
      final control = DeviceControl((command) async {
        sent.add(command);
        return 'OK CAL -1465 1';
      });
      expect(await control.invoke('enterCalibration'), {
        'angleTenths': -1465,
        'active': true,
      });
      await expectLater(
        control.invoke('deleteDeviceAsset', {
          'id': 'F001',
          'crc32': '1234abcd',
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(sent, ['CAL enter']);
    },
  );
}
