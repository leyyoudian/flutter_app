import 'package:app_gif/transcode_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the actual frame rate returned by the server', () {
    expect(resolveServerTranscodeFps(30), 30);
    expect(resolveServerTranscodeFps(59.94), 60);
    expect(resolveServerTranscodeFps(80), 80);
  });

  test('falls back to 60 fps for missing or invalid server metadata', () {
    expect(resolveServerTranscodeFps(null), 60);
    expect(resolveServerTranscodeFps(0), 60);
    expect(resolveServerTranscodeFps(120), 60);
  });

  test('server-transcoded history matches by stable review id', () {
    expect(
      uploadMatchesHistory(
        historyAssetPath: '',
        historyReviewId: 'review-123',
        uploadedAssetPath: '/cache/review-123.eb4',
        uploadedReviewId: 'review-123',
      ),
      isTrue,
    );
    expect(
      uploadMatchesHistory(
        historyAssetPath: '',
        historyReviewId: 'review-123',
        uploadedAssetPath: '',
        uploadedReviewId: 'review-456',
      ),
      isFalse,
    );
  });

  test('history identity never aliases different empty-path assets', () {
    expect(
      historyEntriesMatch(
        leftAssetPath: '',
        leftReviewId: 'review-123',
        leftCreatedAt: 100,
        rightAssetPath: '',
        rightReviewId: 'review-456',
        rightCreatedAt: 101,
      ),
      isFalse,
    );
    expect(
      historyEntriesMatch(
        leftAssetPath: '',
        leftReviewId: null,
        leftCreatedAt: 100,
        rightAssetPath: '',
        rightReviewId: null,
        rightCreatedAt: 100,
      ),
      isTrue,
    );
  });

  test('local history still matches by package path', () {
    expect(
      uploadMatchesHistory(
        historyAssetPath: '/local/a.eb4',
        historyReviewId: null,
        uploadedAssetPath: '/local/a.eb4',
        uploadedReviewId: null,
      ),
      isTrue,
    );
    expect(
      uploadMatchesHistory(
        historyAssetPath: '/local/a.eb4',
        historyReviewId: null,
        uploadedAssetPath: '/local/b.eb4',
        uploadedReviewId: null,
      ),
      isFalse,
    );
  });

  test('device switch response requests upload only for NEED_UPLOAD maps', () {
    expect(
      switchResultNeedsUpload({'needsUpload': true, 'id': 'U001'}),
      isTrue,
    );
    expect(switchResultNeedsUpload({'needsUpload': false}), isFalse);
    expect(switchResultNeedsUpload(true), isFalse);
    expect(switchResultNeedsUpload(null), isFalse);
  });
}
