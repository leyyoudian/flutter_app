import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final bluetooth = source.substring(
    source.indexOf('private final class GameBluetoothController'),
    source.indexOf('private final class EbajEncoder'),
  );

  test('iOS lost game acknowledgement releases the unusable BLE session', () {
    expect(bluetooth, contains('self?.fail("设备未确认游戏指令，请重新连接")'));
    expect(
      bluetooth,
      contains('commandError(message, code: "bluetooth_disconnected")'),
    );
    expect(bluetooth, isNot(contains('self?.commandError("设备未确认游戏指令，请重试")')));
  });

  test('iOS notices lost notifications after the initial BLE connection', () {
    final notification = bluetooth.substring(
      bluetooth.indexOf(
        'func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor',
      ),
      bluetooth.indexOf('func send(action:'),
    );
    expect(notification, isNot(contains('connectResult != nil else')));
    expect(notification, contains('if connectResult != nil'));
    expect(notification, contains('characteristic.isNotifying'));
    expect(bluetooth, contains('fail("蓝牙响应读取失败，请重新连接")'));
  });

  test('iOS firmware download and upload keep transfer activity alive', () {
    expect(
      'runFirmwareOperation(result: result, transfer: true)'.allMatches(source),
      hasLength(2),
    );
    final operations = source.substring(
      source.indexOf('private func runFirmwareOperation('),
      source.indexOf('private func verifyFirmware('),
    );
    expect(operations, contains('if transfer'));
    expect(operations, contains('beginUploadBackgroundTask()'));
    expect(operations, contains('endUploadBackgroundTask()'));
    expect(source, contains('UIApplication.shared.isIdleTimerDisabled = true'));
    expect(
      source,
      contains(
        'UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled',
      ),
    );
  });

  test('Codemagic executes production BLE and firmware protocol fixtures', () {
    expect(File('tool/test_ios_reliability.py').existsSync(), isTrue);
    expect(
      File('codemagic.yaml').readAsStringSync(),
      contains('python3 tool/test_ios_reliability.py'),
    );
  });
}
