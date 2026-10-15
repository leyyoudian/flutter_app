import 'package:app_gif/main.dart';
import 'package:app_gif/device_asset_delete.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unresolved deletions of reused slots retain each review identity', () {
    PendingDeviceDeletion pending(String review) => PendingDeviceDeletion(
      deviceKey: 'p4-key',
      deviceAssetId: 'U006',
      crc32: 0,
      createdAt: 42,
      reviewId: review,
      needsPackageIdentity: true,
    );
    final result = coalescePendingDeviceDeletions([
      pending('review-a'),
      pending('review-b'),
      pending('review-a'),
    ]);
    expect(result.length, 2);
    expect(result.map((item) => item.reviewId), ['review-a', 'review-b']);
  });
  test(
    'downloaded identity replaces placeholders without losing review/device',
    () {
      final old = HistoryEntry.fromMap({
        'assetPath': '',
        'mime': 'video/mp4',
        'name': 'clip',
        'packageSize': 0,
        'frameCount': 0,
        'fps': 60,
        'crc32': 0,
        'createdAt': 42,
        'reviewId': 'review-a',
        'reviewStatus': 'approved',
        'deviceId': 'U006',
        'deviceKey': 'p4-key',
      });
      final repaired = old.copyWith(
        assetPath: '/exact.eb4',
        packageSize: 512,
        frameCount: 20,
        fps: 60,
        crc32: 0x1234abcd,
      );
      expect(repaired.crc32, 0x1234abcd);
      expect(repaired.assetPath, '/exact.eb4');
      expect(repaired.deviceId, 'U006');
      expect(repaired.reviewId, 'review-a');
      expect(repaired.createdAt, 42);
    },
  );
  test(
    'offline legacy deletion preserves unresolved package identity durably',
    () {
      const deletion = PendingDeviceDeletion(
        deviceKey: 'p4-key',
        deviceAssetId: 'U006',
        crc32: 0,
        createdAt: 42,
        reviewId: 'review-a',
        name: 'clip',
        needsPackageIdentity: true,
      );
      final restored = PendingDeviceDeletion.fromMap(deletion.toMap());
      expect(restored.needsPackageIdentity, true);
      expect(restored.reviewId, 'review-a');
      final repaired = restored.copyWith(
        crc32: 0x1234abcd,
        needsPackageIdentity: false,
      );
      expect(repaired.crc32, 0x1234abcd);
      expect(repaired.needsPackageIdentity, false);
    },
  );
}
