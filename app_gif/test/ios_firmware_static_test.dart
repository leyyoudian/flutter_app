import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  test('iOS exposes firmware relay methods and validates board manifest', () {
    for (final method in [
      'checkFirmwareUpdate',
      'downloadFirmware',
      'uploadFirmware',
    ]) {
      expect(source, contains('case "$method":'));
    }
    expect(source, contains('import CryptoKit'));
    expect(source, contains('hardware == "esp32p4-2.8"'));
    expect(source, contains('3 * 1024 * 1024'));
    expect(source, contains('firmware_unavailable'));
    expect(source, contains('firmware_unsupported'));
  });

  test('iOS checks app descriptor and identity before posting firmware', () {
    expect(source, contains('field(48, 32)'));
    expect(source, contains('field(80, 32)'));
    expect(source, contains('esp32-p4c5-dotloop'));
    expect(source, contains('"/ota/status"'));
    expect(source, contains('"/ota/upload"'));
    for (final header in [
      'Content-Length',
      'X-OTA-Hardware',
      'X-OTA-Version',
      'X-OTA-SHA256',
    ]) {
      expect(source, contains('forHTTPHeaderField: "$header"'));
    }
    expect(source, contains('status["deviceId"] as? String == deviceId'));
    expect(source, contains('reply["version"] as? String == manifest.version'));
  });

  test(
    'iOS streams bounded downloads and validates server hashes and lengths',
    () {
      expect(source, contains('URLSessionDataDelegate'));
      expect(source, contains('received + data.count <= maximumBytes'));
      expect(source, contains('x-asset-sha256'));
      expect(source, contains('hasher.update(data: data)'));
      expect(source, contains('expectedSize == received'));
      expect(source, contains('DotLoopBackendUnavailable'));
    },
  );

  test('iOS restricts high frame rates to P4 JPEG packages', () {
    expect(source, contains('let jpeg = table[10] == 0x20'));
    expect(
      source,
      contains('jpeg && hardware != nil && hardware != "esp32p4"'),
    );
    expect(
      source,
      contains('let minimumFps = jpeg ? 1 : BadgeConstants.minDeviceFps'),
    );
    expect(
      source,
      contains('let maximumFps = jpeg ? 80 : BadgeConstants.maxDeviceFps'),
    );
    expect(
      source,
      contains('localPackageMetadata(fileURL: target, hardware: hardware)'),
    );
  });

  test('iOS preserves actual server moderation status', () {
    expect(
      source,
      contains('"reviewStatus": job["reviewStatus"] as? String ?? "pending"'),
    );
  });
}
