const int p4MaxTranscodeFps = 80;
const int p4FallbackTranscodeFps = 60;

int resolveServerTranscodeFps(Object? value) {
  if (value is num) {
    final fps = value.round();
    if (fps >= 1 && fps <= p4MaxTranscodeFps) {
      return fps;
    }
  }
  return p4FallbackTranscodeFps;
}

bool uploadMatchesHistory({
  required String historyAssetPath,
  required String? historyReviewId,
  required String uploadedAssetPath,
  required String? uploadedReviewId,
}) {
  if (historyReviewId != null &&
      uploadedReviewId != null &&
      historyReviewId == uploadedReviewId) {
    return true;
  }
  return historyAssetPath.isNotEmpty &&
      uploadedAssetPath.isNotEmpty &&
      historyAssetPath == uploadedAssetPath;
}

String historyEntryIdentity({
  required String assetPath,
  required String? reviewId,
  required int createdAt,
}) {
  if (reviewId != null && reviewId.isNotEmpty) {
    return 'review:$reviewId';
  }
  if (assetPath.isNotEmpty) {
    return 'asset:$assetPath';
  }
  return 'created:$createdAt';
}

bool historyEntriesMatch({
  required String leftAssetPath,
  required String? leftReviewId,
  required int leftCreatedAt,
  required String rightAssetPath,
  required String? rightReviewId,
  required int rightCreatedAt,
}) {
  return historyEntryIdentity(
        assetPath: leftAssetPath,
        reviewId: leftReviewId,
        createdAt: leftCreatedAt,
      ) ==
      historyEntryIdentity(
        assetPath: rightAssetPath,
        reviewId: rightReviewId,
        createdAt: rightCreatedAt,
      );
}

bool switchResultNeedsUpload(Object? result) {
  return result is Map && result['needsUpload'] == true;
}
