bool isUserDeviceAssetId(String? value) {
  return value != null && RegExp(r'^U\d{3}$').hasMatch(value);
}

String crc32Hex(int value) {
  return (value & 0xffffffff).toRadixString(16).padLeft(8, '0');
}

enum DeviceAssetDeleteOutcome { deleted, missing, stale, retry, rejected }

enum DeviceAssetStatus { match, missing, stale, retry, rejected }

bool isTerminalDeviceAssetDeleteOutcome(DeviceAssetDeleteOutcome outcome) {
  return outcome != DeviceAssetDeleteOutcome.retry;
}

class PendingDeviceDeletion {
  const PendingDeviceDeletion({
    required this.deviceKey,
    required this.deviceAssetId,
    required this.crc32,
    required this.createdAt,
  });

  factory PendingDeviceDeletion.fromMap(Map<String, dynamic> map) {
    final deviceAssetId = map['deviceAssetId'] as String?;
    final crc32 = (map['crc32'] as num?)?.toInt();
    final createdAt = (map['createdAt'] as num?)?.toInt();
    if (!isUserDeviceAssetId(deviceAssetId) ||
        crc32 == null ||
        createdAt == null) {
      throw const FormatException('invalid pending device deletion');
    }
    final rawDeviceKey = map['deviceKey'];
    if (rawDeviceKey != null && rawDeviceKey is! String) {
      throw const FormatException('invalid pending deletion device key');
    }
    return PendingDeviceDeletion(
      deviceKey: rawDeviceKey as String?,
      deviceAssetId: deviceAssetId!,
      crc32: crc32,
      createdAt: createdAt,
    );
  }

  final String? deviceKey;
  final String deviceAssetId;
  final int crc32;
  final int createdAt;

  String get operationKey =>
      '${deviceKey ?? 'legacy'}|$deviceAssetId|${crc32Hex(crc32)}';

  bool matchesDevice(String value) => deviceKey == value;

  PendingDeviceDeletion copyWith({String? deviceKey, int? createdAt}) {
    return PendingDeviceDeletion(
      deviceKey: deviceKey ?? this.deviceKey,
      deviceAssetId: deviceAssetId,
      crc32: crc32,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'deviceKey': deviceKey,
      'deviceAssetId': deviceAssetId,
      'crc32': crc32,
      'createdAt': createdAt,
    };
  }
}

List<PendingDeviceDeletion> coalescePendingDeviceDeletions(
  Iterable<PendingDeviceDeletion> deletions,
) {
  final byOperation = <String, PendingDeviceDeletion>{};
  for (final deletion in deletions) {
    final existing = byOperation[deletion.operationKey];
    if (existing == null || deletion.createdAt < existing.createdAt) {
      byOperation[deletion.operationKey] = deletion;
    }
  }
  final result = byOperation.values.toList();
  result.sort((left, right) => left.createdAt.compareTo(right.createdAt));
  return result;
}

List<PendingDeviceDeletion> pendingDeletionsForDevice(
  Iterable<PendingDeviceDeletion> deletions,
  String deviceKey,
) {
  return deletions.where((item) => item.matchesDevice(deviceKey)).toList();
}

DeviceAssetDeleteOutcome parseDeviceAssetDeleteResponse(String response) {
  final normalized = response.trim();
  if (normalized.startsWith('OK DELETED ')) {
    return DeviceAssetDeleteOutcome.deleted;
  }
  if (normalized.startsWith('OK MISSING ')) {
    return DeviceAssetDeleteOutcome.missing;
  }
  if (normalized.startsWith('OK STALE ')) {
    return DeviceAssetDeleteOutcome.stale;
  }
  if (normalized == 'ERR FORBIDDEN' || normalized == 'ERR INVALID') {
    return DeviceAssetDeleteOutcome.rejected;
  }
  return DeviceAssetDeleteOutcome.retry;
}

DeviceAssetStatus parseDeviceAssetStatusResponse(String response) {
  final normalized = response.trim();
  if (normalized.startsWith('OK MATCH ')) {
    return DeviceAssetStatus.match;
  }
  if (normalized.startsWith('OK MISSING ')) {
    return DeviceAssetStatus.missing;
  }
  if (normalized.startsWith('OK STALE ')) {
    return DeviceAssetStatus.stale;
  }
  if (normalized == 'ERR FORBIDDEN' || normalized == 'ERR INVALID') {
    return DeviceAssetStatus.rejected;
  }
  return DeviceAssetStatus.retry;
}
