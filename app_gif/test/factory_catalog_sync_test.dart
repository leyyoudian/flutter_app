import 'package:flutter_test/flutter_test.dart';
import 'package:app_gif/factory_catalog_sync.dart';

void main() {
  test('merge keeps protected baseline and adds loop factory item', () {
    final merged = FactoryCatalogSync.mergeCatalogForTest(
      builtIn: [
        {
          'id': 'F001',
          'name': 'F001',
          'type': 'split',
          'protected': true,
          'previewAsset': 'assets/factory_previews/F001.png',
          'firstVideo': 'assets/factory_previews/F001_first.mp4',
        },
      ],
      remote: {
        'schemaVersion': 1,
        'catalogRevision': 2,
        'items': [
          {
            'id': 'F022',
            'title': 'F022',
            'type': 'loop',
            'protected': false,
            'revision': 1,
            'appFiles': {
              'thumbnail': {'localPath': '/tmp/F022.png'},
              'loopVideo': {'localPath': '/tmp/F022_loop.mp4'},
            },
          },
        ],
      },
      installed: const {},
    );

    expect(merged.map((item) => item['id']), containsAll(['F001', 'F022']));
    final f022 = merged.singleWhere((item) => item['id'] == 'F022');
    expect(f022['type'], 'loop');
    expect(f022['loopVideo'], '/tmp/F022_loop.mp4');
  });

  test(
    'merge removes nonprotected downloaded items absent from remote catalog',
    () {
      final merged = FactoryCatalogSync.mergeCatalogForTest(
        builtIn: const [],
        remote: {
          'schemaVersion': 1,
          'catalogRevision': 3,
          'items': <Map<String, Object?>>[],
        },
        installed: {
          'items': [
            {
              'id': 'F022',
              'type': 'loop',
              'protected': false,
              'previewAsset': '/tmp/F022.png',
              'loopVideo': '/tmp/F022_loop.mp4',
            },
          ],
        },
      );

      expect(merged.any((item) => item['id'] == 'F022'), isFalse);
    },
  );
}
