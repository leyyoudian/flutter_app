import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android and iOS expose the local calibration protocol', () {
    final android = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    for (final source in <String>[android, ios]) {
      expect(source, contains('enterCalibration'));
      expect(source, contains('previewCalibration'));
      expect(source, contains('saveCalibration'));
      expect(source, contains('cancelCalibration'));
      expect(source, contains('/calibration'));
      expect(source, contains('angle_tenths'));
    }
  });
}
