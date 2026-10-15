import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'iOS persists every selectable language and exposes shared P4 controls',
    () {
      final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      for (final language in [
        'system',
        'chinese',
        'english',
        'traditionalChinese',
        'japanese',
        'russian',
      ]) {
        expect(source, contains('"$language"'));
      }
      for (final method in [
        'loadLanguage',
        'saveLanguage',
        'ensureDeviceBluetooth',
        'deviceBluetoothState',
        'deviceBluetoothCommand',
        'sendGameControl',
        'joinDeviceAccessPoint',
        'leaveDeviceAccessPoint',
      ]) {
        expect(source, contains('"$method"'));
      }
      expect(
        source,
        contains('UserDefaults.standard.set(language, forKey: "app_language")'),
      );
      expect(
        source,
        contains(
          'write(action: "DC:\\(command)", isDevice: true, result: result)',
        ),
      );
    },
  );

  test('iOS permission prompts have all five packaged language resources', () {
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    for (final locale in ['en', 'zh-Hans', 'zh-Hant', 'ja', 'ru']) {
      final file = File('ios/Runner/$locale.lproj/InfoPlist.strings');
      expect(file.existsSync(), isTrue, reason: locale);
      final strings = file.readAsStringSync();
      for (final key in [
        'NSBluetoothAlwaysUsageDescription',
        'NSBluetoothPeripheralUsageDescription',
        'NSLocalNetworkUsageDescription',
        'NSPhotoLibraryUsageDescription',
      ]) {
        expect(strings, contains('"$key" = "'), reason: '$locale/$key');
      }
      expect(project, contains('$locale.lproj/InfoPlist.strings'));
    }
    expect(project, contains('InfoPlist.strings in Resources'));
  });

  test('all iOS configurations reference the hotspot entitlement', () {
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(
      RegExp(
        'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;',
      ).allMatches(project),
      hasLength(3),
    );
    final entitlements = File(
      'ios/Runner/Runner.entitlements',
    ).readAsStringSync();
    expect(
      entitlements,
      contains('com.apple.developer.networking.HotspotConfiguration'),
    );
  });
}
