import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'main screen starts factory catalog sync and supports file previews',
    () {
      final source = File('lib/main.dart').readAsStringSync();

      expect(source, contains("import 'factory_catalog_sync.dart';"));
      expect(source, contains("FactoryCatalogSync.syncOnce"));
      expect(source, contains("'factoryCacheRoot'"));
      expect(source, contains('Image.file('));
      expect(source, contains('VideoPlayerController.file'));
      expect(source, contains('anim.isLoop'));
      expect(source, contains('selectedFactory?.isLoop == true'));
      expect(source, contains('looping: selectedFactory?.isLoop == true'));
      expect(source, contains('await c.setLooping(widget.looping)'));
      expect(source, contains('if (widget.looping) return;'));
    },
  );

  test('native platforms expose factory cache root', () {
    final android = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(android, contains('"factoryCacheRoot"'));
    expect(android, contains('persistentAssetDirectory("factory_catalog")'));
    expect(ios, contains('case "factoryCacheRoot"'));
    expect(ios, contains('cacheDirectory("factory_catalog")'));
  });
}
