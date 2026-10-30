import 'dart:convert';
import 'dart:io';

import 'package:app_gif/main.dart';
import 'package:flutter_test/flutter_test.dart';

import 'repository_firmware.dart';

void main() {
  test(
    'factory manifest maps only F006 and F007 mutual third-half previews',
    () {
      final manifest =
          jsonDecode(
                File(
                  'assets/factory_previews/manifest.json',
                ).readAsStringSync(),
              )
              as List<dynamic>;
      final byId = {
        for (final item in manifest.cast<Map<String, dynamic>>())
          item['id'] as String: item,
      };

      expect(byId['F006']?['transitions'], {
        'F007': 'assets/factory_previews/F007_third.mp4',
      });
      expect(byId['F007']?['transitions'], {
        'F006': 'assets/factory_previews/F006_third.mp4',
      });

      for (final entry in manifest.cast<Map<String, dynamic>>()) {
        final id = entry['id'] as String;
        if (id == 'F006' || id == 'F007') continue;
        expect(
          entry['transitions'],
          isEmpty,
          reason: '$id should use normal transitions',
        );
      }
    },
  );

  test('app preview relies on transition map instead of one-way skip', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('current?.transitions.containsKey(anim.id)'));
    expect(source, contains('current?.exitVideo(anim.id)'));
    expect(source, isNot(contains('skipExit')));
    expect(
      source,
      isNot(contains("_activeFactoryId == 'F006' && anim.id == 'F007'")),
    );
  });

  test('Sharingan baseline contains normal and linked entrance videos', () {
    final manifest =
        jsonDecode(
              File('assets/factory_previews/manifest.json').readAsStringSync(),
            )
            as List<dynamic>;
    final sharingan = manifest
        .cast<Map<String, dynamic>>()
        .where((item) => (item['id'] as String).startsWith('S'))
        .toList();

    expect(sharingan, hasLength(10));
    for (final item in sharingan) {
      expect(item['firstVideo'], isA<String>());
      expect(item['secondVideo'], isA<String>());
      expect(item['transitionVideo'], isA<String>());
      expect(item['protected'], isTrue);
    }
  });

  test('App-only factory previews never dispatch a device switch', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('anim.supportsDeviceSwitch'));
    expect(source, contains("已切换预览（手机素材）"));

    final sharingan = FactoryAnimation.fromMap(const {
      'id': 'S003',
      'name': 'Sharingan 3',
      'previewAsset': 'preview.png',
      'deviceFiles': <dynamic>[],
    });
    expect(sharingan.supportsDeviceSwitch, isFalse);

    final sharinganDeviceAsset = FactoryAnimation.fromMap(const {
      'id': 'S003',
      'name': 'Sharingan 3',
      'previewAsset': 'preview.png',
      'deviceFiles': <dynamic>[
        {'hardware': 'esp32p4'},
      ],
    });
    expect(sharinganDeviceAsset.supportsDeviceSwitch, isTrue);

    final remoteDeviceAsset = FactoryAnimation.fromMap(const {
      'id': 'F024',
      'name': 'F024',
      'previewAsset': 'preview.png',
      'deviceFiles': <dynamic>[
        {'hardware': 'esp32p4'},
      ],
    });
    expect(remoteDeviceAsset.supportsDeviceSwitch, isTrue);
  });

  test(
    'P4 switch resolves target-named third-half for F006/F007 mutual switches',
    () {
      final source = latin1.decode(
        repositoryFirmwareFile('main/Badge/BadgeAnimMgr.c').readAsBytesSync(),
      );

      expect(source, contains('is_factory_six_seven_pair'));
      expect(
        source,
        anyOf(
          contains('resolve_asset_path(BADGE_ANIM_FOLDER_THIRD, new_id,'),
          contains(
            'snprintf(third_path, sizeof(third_path), BADGE_ANIM_FOLDER_THIRD "/%s.eb4", new_id);',
          ),
        ),
      );
      expect(source, isNot(contains('F006->F007: skipping exit')));
      expect(source, isNot(contains('/sdcard/third_half/%s_%s.eb4')));
    },
  );
}
