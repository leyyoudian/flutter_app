import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app exposes reviewer demo mode and simulates device workflows', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('_demoMode'));
    expect(source, contains('_enterDemoMode'));
    expect(source, contains('_exitDemoMode'));
    expect(source, contains('演示模式'));
    expect(source, contains('审核演示'));
    expect(source, contains('_simulateDemoUpload'));
    expect(source, contains('_simulateDemoScan'));
    expect(source, contains('Demo ESP-BAJI'));
  });

  test('app has backend version checks and moderation upload gating', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('ESP_BAJI_API_BASE'));
    expect(source, contains("defaultValue: 'http://60.205.122.153'"));
    expect(source, contains('_checkRemoteVersion'));
    expect(source, contains('/api/version'));
    expect(source, contains("final storeUrl = _readNullableString(manifest['storeUrl']);"));
    expect(source, contains('_showUpdateSnack'));
    expect(source, contains("'openUrl'"));
    expect(source, contains('_submitAssetForReview'));
    expect(source, contains('_guessMimeFromPath'));
    expect(source, contains('_preferredReviewPreviewPath'));
    expect(source, contains("'previewMime': _guessMimeFromPath(reviewPreviewPath)"));
    expect(source, contains('/api/assets'));
    expect(source, contains("reviewStatus: 'pending'"));
    expect(source, contains("reviewStatus: 'approved'"));
    expect(source, contains('_ensureAssetApproved'));
    expect(
      source.indexOf('_ensureAssetApproved(asset)'),
      lessThan(source.indexOf("'uploadAsset'")),
    );
  });

  test('app package version is aligned with local update manifest', () {
    final source = File('lib/main.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(source, contains("static const _appVersion = '1.0.14';"));
    expect(pubspec, contains('version: 1.0.14+16'));
  });

  test('firmware project version is aligned with OTA release version', () {
    final cmake = File('../ESP32-S3-LCD-2.8C-Test/CMakeLists.txt').readAsStringSync();
    final mainCmake = File('../ESP32-S3-LCD-2.8C-Test/main/CMakeLists.txt').readAsStringSync();

    expect(cmake, contains('set(PROJECT_VER "0.1.33")'));
    expect(
      mainCmake,
      contains(r'target_compile_definitions(${COMPONENT_LIB} PRIVATE BADGE_FW_VERSION=\"${PROJECT_VER}\")'),
    );
  });

  test('maker save submits review before storing history and shows policy hint', () {
    final source = File('lib/main.dart').readAsStringSync();
    final saveStart = source.indexOf('Future<void> _saveMakerAsset()');
    final submitAtSave = source.indexOf('_submitAssetForReview(asset)', saveStart);
    final insertHistory = source.indexOf('_history.insert(0, entry)', saveStart);

    expect(source, contains('素材需审核，请勿上传非法素材'));
    expect(submitAtSave, greaterThan(saveStart));
    expect(insertHistory, greaterThan(submitAtSave));
    expect(source, contains('素材已保存，已提交审核'));
  });

  test('video review waits for animated preview before moderation upload', () {
    final source = File('lib/main.dart').readAsStringSync();
    final saveStart = source.indexOf('Future<void> _saveMakerAsset()');
    final waitForPreview = source.indexOf(
      '_withReviewPreviewReady(asset)',
      saveStart,
    );
    final submitAtSave = source.indexOf('_submitAssetForReview(asset)', saveStart);

    expect(source, contains('Map<String, Completer<String?>>'));
    expect(source, contains('Future<PreparedAsset> _withReviewPreviewReady'));
    expect(source, contains('const Duration(seconds: 6)'));
    expect(waitForPreview, greaterThan(saveStart));
    expect(waitForPreview, lessThan(submitAtSave));
  });

  test('asset history persists review metadata', () {
    final source = File('lib/main.dart').readAsStringSync();
    final androidNative = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(source, contains('final String? reviewId;'));
    expect(source, contains('final String reviewStatus;'));
    expect(source, contains("'reviewId': reviewId"));
    expect(source, contains("'reviewStatus': reviewStatus"));
    expect(
      source,
      contains("reviewStatus: (map['reviewStatus'] as String?) ?? 'local'"),
    );
    expect(androidNative, contains('"reviewId" to item.optString("reviewId", null)'));
    expect(androidNative, contains('"reviewStatus" to item.optString("reviewStatus", "local")'));
    expect(androidNative, contains('item.put("reviewId", reviewId)'));
    expect(androidNative, contains('item.put("reviewStatus", reviewStatus ?: "local")'));
  });

  test('firmware holds single-frame assets instead of loop-rendering them', () {
    final display = File('../ESP32-S3-LCD-2.8C-Test/main/Badge/BadgeDisplay.c').readAsStringSync();

    expect(display, contains('BADGE_PLAYER_YIELD_EVERY_FRAMES'));
    expect(display, contains('BADGE_STATIC_FRAME_HOLD_POLL_MS'));
    expect(display, contains('badge_player_yield_if_needed'));
    expect(display, contains('vTaskDelay(pdMS_TO_TICKS(1))'));
    expect(display, contains('asset->header.frame_count == 1'));
    expect(display, contains('single-frame asset rendered once; holding framebuffer'));
    expect(display, isNot(contains('esp_freertos_hooks.h')));
    expect(display, isNot(contains('esp_register_freertos_idle_hook')));
    expect(display, isNot(contains('static_hold_prevent_waiti')));
  });

  test('history grid visually distinguishes unreviewed and rejected assets', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('_reviewOverlayColor'));
    expect(source, contains('_reviewStatusLabel'));
    expect(source, contains("return '违规';"));
    expect(source, contains("return '未审核';"));
    expect(source, contains("entry.reviewStatus == 'approved'"));
    expect(source, contains('Colors.redAccent.withValues'));
  });

  test('pending review statuses refresh while the app stays open', () {
    final source = File('lib/main.dart').readAsStringSync();
    final timerStart = source.indexOf('void _restartConnectionTimer()');
    final timerEnd = source.indexOf('Future<void> _handleNativeCall', timerStart);

    expect(timerStart, isNot(-1));
    expect(timerEnd, isNot(-1));
    final timerSource = source.substring(timerStart, timerEnd);
    final reviewRefresh = timerSource.indexOf('_refreshHistoryReviewStatuses()');
    final connectionRefresh = timerSource.indexOf('_refreshConnectionState()');

    expect(source, contains('bool _reviewRefreshInFlight = false;'));
    expect(source, contains('bool get _hasPendingReviewStatuses'));
    expect(reviewRefresh, isNot(-1));
    expect(connectionRefresh, isNot(-1));
    expect(reviewRefresh, lessThan(connectionRefresh));
  });

  test('local server skeleton exposes required deployment APIs', () {
    final app = File('../server/src/app.js').readAsStringSync();
    final server = File('../server/src/server.js').readAsStringSync();
    final package = File('../server/package.json').readAsStringSync();

    expect(package, contains('"test"'));
    expect(server, contains("process.env.HOST || '0.0.0.0'"));
    expect(app, contains('/api/version'));
    expect(app, contains('/api/assets'));
    expect(app, contains('/api/admin/assets'));
    expect(app, contains('/api/ota/manifest'));
    expect(app, contains('X-Admin-Token'));
    expect(app, contains('buildPreviewHtml'));
    expect(app, contains('<video class="asset-thumb" controls'));
  });
}
