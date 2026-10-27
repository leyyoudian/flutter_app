import 'package:flutter_test/flutter_test.dart';
import 'package:app_gif/factory_catalog_sync.dart';
import 'package:app_gif/factory_preview_quality.dart';
import 'package:app_gif/main.dart';
import 'package:app_gif/device_control.dart';
import 'package:app_gif/factory_device_install.dart';
import 'dart:convert';
import 'dart:io';

void main() {
  test(
    'production catalog keeps every bundled device animation switchable',
    () async {
      final builtIn =
          (jsonDecode(
                    File(
                      'assets/factory_previews/manifest.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .cast<Map<String, dynamic>>();
      final catalog =
          jsonDecode(
                File(
                  'test/fixtures/factory_catalog_revision4.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final merged = FactoryCatalogSync.mergeCatalogForTest(
        builtIn: builtIn,
        remote: catalog,
        installed: catalog,
      );
      final sent = <String>[];
      final control = DeviceControl((command) async {
        sent.add(command);
        return 'OK';
      });
      for (final item in merged) {
        final animation = FactoryAnimation.fromMap(item);
        expect(animation.supportsDeviceSwitch, isTrue, reason: animation.id);
        if (animation.supportsDeviceSwitch) {
          await control.invoke('switchToAsset', {'id': animation.id});
        }
      }
      expect(sent.length, merged.length);
    },
  );

  test('retired F003 cannot return from old remote or installed catalogs', () {
    final merged = FactoryCatalogSync.mergeCatalogForTest(
      builtIn: [
        {'id': 'F003'},
        {
          'id': 'S003',
          'deviceFiles': [
            {'path': 'first_half/S003.eb5'},
          ],
        },
      ],
      remote: {
        'items': [
          {'id': 'F003', 'protected': true},
          {
            'id': 'S003',
            'deviceFiles': [
              {'path': 'first_half/S003.eb5'},
            ],
          },
        ],
      },
      installed: {
        'items': [
          {'id': 'F003', 'protected': true},
        ],
      },
    );
    expect(merged.map((x) => x['id']), ['S003']);
  });

  test(
    'future App-only F024 is not mistaken for a bundled device animation',
    () {
      final merged = FactoryCatalogSync.mergeCatalogForTest(
        builtIn: [],
        remote: {
          'items': [
            {'id': 'F024', 'deviceFiles': []},
            {'id': 'S003', 'deviceFiles': []},
          ],
        },
        installed: {},
      );
      for (final item in merged) {
        expect(FactoryAnimation.fromMap(item).supportsDeviceSwitch, isFalse);
      }
    },
  );

  test('normalized loop keeps its revision and device package identity', () {
    final item = {
      'id': 'F022',
      'name': 'Loop 22',
      'type': 'loop',
      'revision': 3,
      'deviceFiles': [
        {'path': 'factory_loop/F022.eb5', 'size': 42, 'sha256': 'a' * 64},
        {'path': 'loop_intro/F022.eb5', 'size': 24, 'sha256': 'b' * 64},
      ],
    };
    final normalized = FactoryCatalogSync.mergeCatalogForTest(
      builtIn: const [],
      remote: {
        'items': [item],
      },
      installed: const {},
    ).single;
    final animation = FactoryAnimation.fromMap(normalized);

    expect(normalized['revision'], 3);
    expect(animation.devicePackageKey, FactoryDeviceInstall.catalogKey(item));
  });

  test('F022/F023 remote thumbnail changes cannot replace pinned covers', () {
    for (final id in ['F022', 'F023']) {
      final merged = FactoryCatalogSync.mergeCatalogForTest(
        builtIn: [
          {
            'id': id,
            'type': 'loop',
            'previewAsset': 'assets/factory_previews/$id.png',
          },
        ],
        remote: {
          'items': [
            {
              'id': id,
              'type': 'loop',
              'appFiles': {
                'thumbnail': {'localPath': '/cache/$id-new-cover.png'},
              },
            },
          ],
        },
        installed: const {},
      ).single;

      expect(merged['previewAsset'], 'assets/factory_previews/$id.png');
    }
  });

  Map<String, dynamic> mergePreview(Map<String, Object> metadata) {
    return FactoryCatalogSync.mergeCatalogForTest(
      builtIn: const [],
      remote: {
        'items': [
          {
            'id': 'F022',
            'type': 'loop',
            'appFiles': {'loopVideo': metadata},
          },
        ],
      },
      installed: const {},
    ).single;
  }

  test('known old server preview uses its upgraded bundled animation', () {
    final known = upgradedFactoryPreviewAssets.entries.singleWhere(
      (entry) => entry.value == 'assets/factory_previews/F022_loop.mp4',
    );
    final merged = mergePreview({
      'sha256': known.key.toUpperCase(),
      'localPath': '/cache/old480.mp4',
    });
    expect(merged['loopVideo'], known.value);
    final withoutLocalFile = mergePreview({'sha256': known.key});
    expect(withoutLocalFile['loopVideo'], known.value);
  });

  test('unknown future server preview retains its downloaded revision', () {
    final merged = mergePreview({
      'sha256': 'f' * 64,
      'localPath': '/cache/new-revision.mp4',
    });
    expect(merged['loopVideo'], '/cache/new-revision.mp4');
  });

  test('server preview without a hash retains legacy merge behavior', () {
    final merged = mergePreview({'localPath': '/cache/legacy.mp4'});
    expect(merged['loopVideo'], '/cache/legacy.mp4');
  });

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

  test('remote baseline without app files preserves built-in previews', () {
    final merged = FactoryCatalogSync.mergeCatalogForTest(
      builtIn: [
        {
          'id': 'F006',
          'name': 'F006',
          'type': 'split',
          'previewAsset': 'assets/factory_previews/F006.png',
          'firstVideo': 'assets/factory_previews/F006_first.mp4',
          'secondVideo': 'assets/factory_previews/F006_second.mp4',
          'transitions': {'F007': 'assets/factory_previews/F007_third.mp4'},
        },
      ],
      remote: {
        'items': [
          {
            'id': 'F006',
            'title': 'F006',
            'type': 'split',
            'protected': true,
            'appFiles': <String, dynamic>{},
          },
        ],
      },
      installed: const {},
    );

    final f006 = merged.singleWhere((item) => item['id'] == 'F006');
    expect(f006['previewAsset'], 'assets/factory_previews/F006.png');
    expect(f006['firstVideo'], 'assets/factory_previews/F006_first.mp4');
    expect(f006['secondVideo'], 'assets/factory_previews/F006_second.mp4');
    expect(f006['transitions'], {
      'F007': 'assets/factory_previews/F007_third.mp4',
    });
  });
}
