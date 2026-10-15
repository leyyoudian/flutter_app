import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

Future<bool> hasP4JpegPackage(String path) async {
  if (path.isEmpty) return false;
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final bytes = await file.read(44);
    if (bytes.length != 44) return false;
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(0, Endian.little) != 0x344a4142 ||
        header.getUint16(4, Endian.little) != 4 ||
        header.getUint32(24, Endian.little) != await file.length()) {
      return false;
    }
    final table = header.getUint32(16, Endian.little);
    if (table < 44 || table + 16 > await file.length()) return false;
    await file.setPosition(table + 10);
    final codec = await file.read(1);
    return codec.length == 1 && codec.first == 0x20;
  } on FileSystemException {
    return false;
  } finally {
    await file?.close();
  }
}

/// A legacy server ID identifies an encoded package, not its original media.
/// Rebuild from the saved source and crop instead of changing its hardware tag.
Future<Map<dynamic, dynamic>?> rebuildLegacyP4Asset({
  required String assetId,
  required String? sourceUri,
  required String name,
  required double cropScale,
  required double cropOffsetX,
  required double cropOffsetY,
  required Future<Map<String, dynamic>?> Function(String) metadata,
  required Future<Map<dynamic, dynamic>?> Function(Map<String, Object?>)
  transcode,
}) async {
  final existing = await metadata(assetId);
  final hardware = existing?['hardware']?.toString().toLowerCase() ?? '';
  if (hardware.startsWith('esp32p4')) return null;
  if (existing == null || hardware.isEmpty) {
    throw PlatformException(
      code: 'package_invalid',
      message: '无法确认素材型号，请重新导入原素材',
    );
  }
  if (sourceUri == null || sourceUri.isEmpty) {
    throw PlatformException(
      code: 'asset_source_missing',
      message: '这是旧 S3 素材，缺少原文件，请重新选择原素材生成 P4 版本',
    );
  }
  final rebuilt = await transcode({
    'uri': sourceUri,
    'name': name,
    'hardware': 'esp32p4',
    'maxFps': 80,
    'cropScale': cropScale,
    'cropOffsetX': cropOffsetX,
    'cropOffsetY': cropOffsetY,
    'deviceTransfer': true,
  });
  if (rebuilt == null ||
      rebuilt['reviewId'] is! String ||
      (rebuilt['reviewId'] as String).isEmpty ||
      rebuilt['reviewStatus'] != 'approved') {
    throw PlatformException(
      code: 'transcode_failed',
      message: 'P4 素材转换未完成，请稍后重试',
    );
  }
  return rebuilt;
}
