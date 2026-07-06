import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('factory manifest maps only F006 and F007 mutual third-half previews', () {
    final manifest = jsonDecode(
      File('assets/factory_previews/manifest.json').readAsStringSync(),
    ) as List<dynamic>;
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
      expect(entry['transitions'], isEmpty, reason: '$id should use normal transitions');
    }
  });

  test('app preview relies on transition map instead of one-way skip', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('current?.transitions.containsKey(anim.id)'));
    expect(source, contains('current?.exitVideo(anim.id)'));
    expect(source, isNot(contains('skipExit')));
    expect(source, isNot(contains("_activeFactoryId == 'F006' && anim.id == 'F007'")));
  });

  test('esp32 switch uses target-named third-half for F006/F007 mutual switches only', () {
    final source = latin1.decode(File(
      '../ESP32-S3-LCD-2.8C-Test/main/Badge/BadgeAnimMgr.c',
    ).readAsBytesSync());

    expect(source, contains('is_factory_six_seven_pair'));
    expect(
      source,
      contains('snprintf(third_path, sizeof(third_path), BADGE_ANIM_FOLDER_THIRD "/%s.eb4", new_id);'),
    );
    expect(source, isNot(contains('F006->F007: skipping exit')));
    expect(source, isNot(contains('/sdcard/third_half/%s_%s.eb4')));
  });
}
