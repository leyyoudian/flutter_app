import 'package:app_gif/device_asset_delete.dart';
import 'package:app_gif/main.dart' show HistoryEntry;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('device asset id validation', () {
    test('accepts only exact Uxxx IDs', () {
      expect(isUserDeviceAssetId('U006'), isTrue);
      expect(isUserDeviceAssetId('U999'), isTrue);

      for (final id in <String?>[
        null,
        '',
        'F006',
        'U06',
        'U1000',
        'u006',
        'U00/',
        '../U006',
      ]) {
        expect(isUserDeviceAssetId(id), isFalse, reason: '$id');
      }
    });
  });

  group('pending device deletion', () {
    const oldDeletion = PendingDeviceDeletion(
      deviceKey: 'P4-AAAAAAAAAAAA',
      deviceAssetId: 'U006',
      crc32: 0x11111111,
      createdAt: 100,
    );

    test('operation identity includes device, slot, and content crc', () {
      expect(oldDeletion.operationKey, 'P4-AAAAAAAAAAAA|U006|11111111');
      expect(oldDeletion.matchesDevice('P4-AAAAAAAAAAAA'), isTrue);
      expect(oldDeletion.matchesDevice('P4-BBBBBBBBBBBB'), isFalse);

      const reusedSlot = PendingDeviceDeletion(
        deviceKey: 'P4-AAAAAAAAAAAA',
        deviceAssetId: 'U006',
        crc32: 0x22222222,
        createdAt: 200,
      );
      expect(reusedSlot.operationKey, isNot(oldDeletion.operationKey));
    });

    test('round trips through persisted maps', () {
      final restored = PendingDeviceDeletion.fromMap(oldDeletion.toMap());

      expect(restored.deviceKey, oldDeletion.deviceKey);
      expect(restored.deviceAssetId, oldDeletion.deviceAssetId);
      expect(restored.crc32, oldDeletion.crc32);
      expect(restored.createdAt, oldDeletion.createdAt);
    });

    test('rejects malformed persisted device asset ids', () {
      expect(
        () => PendingDeviceDeletion.fromMap(<String, Object?>{
          'deviceKey': 'P4-AAAAAAAAAAAA',
          'deviceAssetId': 'F001',
          'crc32': 1,
          'createdAt': 2,
        }),
        throwsFormatException,
      );
    });

    test('coalesces exact duplicate operations and keeps fifo order', () {
      const second = PendingDeviceDeletion(
        deviceKey: 'P4-AAAAAAAAAAAA',
        deviceAssetId: 'U007',
        crc32: 0x33333333,
        createdAt: 300,
      );
      final result = coalescePendingDeviceDeletions(<PendingDeviceDeletion>[
        second,
        oldDeletion,
        oldDeletion.copyWith(createdAt: 400),
      ]);

      expect(result.map((item) => item.operationKey), <String>[
        oldDeletion.operationKey,
        second.operationKey,
      ]);
      expect(result.first.createdAt, 100);
    });

    test('filters synchronization by stable physical device key', () {
      const otherDevice = PendingDeviceDeletion(
        deviceKey: 'P4-BBBBBBBBBBBB',
        deviceAssetId: 'U006',
        crc32: 0x11111111,
        createdAt: 200,
      );
      const legacy = PendingDeviceDeletion(
        deviceKey: null,
        deviceAssetId: 'U008',
        crc32: 0x44444444,
        createdAt: 300,
      );

      final result = pendingDeletionsForDevice(<PendingDeviceDeletion>[
        oldDeletion,
        otherDevice,
        legacy,
      ], 'P4-AAAAAAAAAAAA');

      expect(result, <PendingDeviceDeletion>[oldDeletion]);
    });
  });

  test('history persists the physical device key with the user slot', () {
    final entry = HistoryEntry.fromMap(<String, Object?>{
      'assetPath': '/tmp/a.eb4',
      'name': 'A',
      'crc32': 0x12345678,
      'createdAt': 1,
      'deviceId': 'U006',
      'deviceKey': 'P4-AAAAAAAAAAAA',
    });

    expect(entry.deviceId, 'U006');
    expect(entry.deviceKey, 'P4-AAAAAAAAAAAA');
    expect(entry.toMap()['deviceKey'], 'P4-AAAAAAAAAAAA');
  });

  group('device protocol responses', () {
    test('classifies terminal delete responses', () {
      expect(
        parseDeviceAssetDeleteResponse('OK DELETED U006'),
        DeviceAssetDeleteOutcome.deleted,
      );
      expect(
        parseDeviceAssetDeleteResponse('OK MISSING U006'),
        DeviceAssetDeleteOutcome.missing,
      );
      expect(
        parseDeviceAssetDeleteResponse('OK STALE U006'),
        DeviceAssetDeleteOutcome.stale,
      );
    });

    test('retains retryable failures and rejects permanent failures', () {
      expect(
        parseDeviceAssetDeleteResponse('ERR BUSY'),
        DeviceAssetDeleteOutcome.retry,
      );
      expect(
        parseDeviceAssetDeleteResponse(''),
        DeviceAssetDeleteOutcome.retry,
      );
      expect(
        parseDeviceAssetDeleteResponse('ERR FORBIDDEN'),
        DeviceAssetDeleteOutcome.rejected,
      );
      expect(
        parseDeviceAssetDeleteResponse('ERR INVALID'),
        DeviceAssetDeleteOutcome.rejected,
      );
      expect(
        DeviceAssetDeleteOutcome.values.where(
          isTerminalDeviceAssetDeleteOutcome,
        ),
        <DeviceAssetDeleteOutcome>[
          DeviceAssetDeleteOutcome.deleted,
          DeviceAssetDeleteOutcome.missing,
          DeviceAssetDeleteOutcome.stale,
          DeviceAssetDeleteOutcome.rejected,
        ],
      );
    });

    test('classifies status responses for legacy binding', () {
      expect(
        parseDeviceAssetStatusResponse('OK MATCH U006'),
        DeviceAssetStatus.match,
      );
      expect(
        parseDeviceAssetStatusResponse('OK MISSING U006'),
        DeviceAssetStatus.missing,
      );
      expect(
        parseDeviceAssetStatusResponse('OK STALE U006'),
        DeviceAssetStatus.stale,
      );
      expect(
        parseDeviceAssetStatusResponse('ERR BUSY'),
        DeviceAssetStatus.retry,
      );
    });
  });
}
