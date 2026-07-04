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

    expect(source, contains("static const _appVersion = '1.0.8';"));
    expect(pubspec, contains('version: 1.0.8+8'));
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

    expect(source, contains('final String? reviewId;'));
    expect(source, contains('final String reviewStatus;'));
    expect(source, contains("'reviewId': reviewId"));
    expect(source, contains("'reviewStatus': reviewStatus"));
    expect(
      source,
      contains("reviewStatus: (map['reviewStatus'] as String?) ?? 'local'"),
    );
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
