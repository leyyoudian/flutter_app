import 'dart:async';
import 'package:flutter/services.dart';

/// Transport-independent control contract. Bulk bytes never use this queue.
class DeviceControl {
  DeviceControl(this.send);
  final Future<String> Function(String command) send;
  Future<void> _tail = Future<void>.value();
  static const methods = {
    'switchToAsset',
    'getRandomMode',
    'setRandomMode',
    'setBrightness',
    'getBrightness',
    'enterCalibration',
    'calibrationStatus',
    'previewCalibration',
    'saveCalibration',
    'cancelCalibration',
    'getDeviceIdentity',
    'statDeviceAsset',
    'deleteDeviceAsset',
    'startTransferAccessPoint',
  };

  Future<Object?> invoke(
    String method, [
    Map<dynamic, dynamic> args = const {},
  ]) {
    final operation = _tail.then((_) => _invoke(method, args));
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Never _invalid() =>
      throw PlatformException(code: 'bad_control', message: '设备指令参数无效');
  Future<Object?> _invoke(String method, Map<dynamic, dynamic> args) async {
    String? id;
    String? crc;
    if (method == 'switchToAsset' ||
        method == 'statDeviceAsset' ||
        method == 'deleteDeviceAsset') {
      id = args['id']?.toString();
      crc = args['crc32']?.toString();
      if (id == 'NEWID' && method == 'switchToAsset') {
        final reply = (await send('SWITCH NEWID')).trim();
        final match = RegExp(r'^OK (U[0-9]{3})$').firstMatch(reply);
        if (match == null) {
          throw PlatformException(code: 'control_rejected', message: reply);
        }
        return match.group(1)!;
      }
      if (id == null || !RegExp(r'^[FSU][0-9]{3}$').hasMatch(id)) {
        _invalid();
      }
      if (id.startsWith('U')) {
        if (crc == null || !RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(crc)) {
          _invalid();
        }
      } else if (method != 'switchToAsset' || crc != null) {
        _invalid();
      }
    }
    final command = switch (method) {
      'switchToAsset' => 'SWITCH $id${crc == null ? '' : ' $crc'}',
      'statDeviceAsset' => 'STAT $id $crc',
      'deleteDeviceAsset' => 'DELETE $id $crc',
      'getDeviceIdentity' => 'IDENTITY',
      'startTransferAccessPoint' => 'AP',
      'getRandomMode' => 'RANDOM GET',
      'getBrightness' => 'BRIGHT GET',
      'setRandomMode' => 'RANDOM ${args['enabled'] == true ? 'ON' : 'OFF'}',
      'setBrightness' =>
        'BRIGHT ${(args['value'] as num).round().clamp(0, 100)}',
      'enterCalibration' => 'CAL enter',
      'calibrationStatus' => 'CAL status',
      'previewCalibration' => 'CAL preview ${args['angleTenths']}',
      'saveCalibration' => 'CAL save ${args['angleTenths']}',
      'cancelCalibration' => 'CAL cancel',
      _ => _invalid(),
    };
    final reply = (await send(command)).trim();
    if (reply.startsWith('NEED_UPLOAD ') && method == 'switchToAsset') {
      return {'needsUpload': true, 'id': id};
    }
    if (!reply.startsWith('OK')) {
      throw PlatformException(code: 'control_rejected', message: reply);
    }
    if (method == 'getBrightness') {
      final match = RegExp(r'^OK BRIGHT (\d{1,3})$').firstMatch(reply);
      if (match == null) _invalid();
      final value = int.parse(match.group(1)!);
      if (value > 100) _invalid();
      return value;
    }
    if (method == 'getRandomMode' || method == 'setRandomMode') {
      if (!RegExp(r'^OK RANDOM [01]$').hasMatch(reply)) _invalid();
      return reply.endsWith('1');
    }
    if (method == 'enterCalibration' || method == 'calibrationStatus') {
      final match = RegExp(r'^OK CAL (-?[0-9]+) ([01])$').firstMatch(reply);
      if (match == null) _invalid();
      return {
        'angleTenths': int.parse(match.group(1)!),
        'active': match.group(2) == '1',
      };
    }
    if (method == 'getDeviceIdentity') {
      if (!reply.startsWith('OK DEVICE ')) _invalid();
      return reply.substring(10);
    }
    if (method == 'statDeviceAsset' || method == 'deleteDeviceAsset') {
      return reply;
    }
    if (method == 'startTransferAccessPoint') return reply;
    if (method == 'switchToAsset') return true;
    return null;
  }
}
