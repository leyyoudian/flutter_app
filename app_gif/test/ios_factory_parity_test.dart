import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'iOS installation uses streamed progress without claiming device acceptance',
    () {
      final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final install = source.substring(
        source.indexOf('private func factoryInstallRequest('),
        source.indexOf('private func uploadAsset('),
      );
      expect(install, contains('RelayInstallProgress'));
      expect(install, contains('onUploadProgress:'));
      expect(install, contains('"type": "uploadProgress"'));
      expect(install, contains('session.uploadTask(with: request, fromFile:'));
      expect(source, contains('private struct RelayInstallProgress'));
      expect(source, contains('0.45 + 0.5 *'));
    },
  );

  test(
    'both iOS workflows run current shared regressions and native installation fixtures',
    () {
      for (final file in ['../codemagic.yaml', 'codemagic.yaml']) {
        final source = File(file).readAsStringSync();
        expect(
          'python3 tool/test_ios_factory_transfer.py'.allMatches(source),
          hasLength(2),
        );
        expect(
          'python3 tool/test_ios_media_cover.py'.allMatches(source),
          hasLength(2),
        );
        expect(
          RegExp(r'^\s+flutter test\s*$', multiLine: true).allMatches(source),
          hasLength(2),
        );
      }
    },
  );
}
