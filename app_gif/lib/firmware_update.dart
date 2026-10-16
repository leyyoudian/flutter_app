import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend_failover.dart';
import 'app_language.dart';

/// Firmware releases use board-specific channels; a P4 chip alone is not enough.
class FirmwareManifest {
  FirmwareManifest.fromMap(Map<dynamic, dynamic> map, String target)
    : hardware = map['hardware']?.toString() ?? '',
      version = map['version']?.toString() ?? '',
      url = Uri.tryParse(map['url']?.toString() ?? ''),
      size = (map['size'] as num?)?.toInt() ?? 0,
      sha256 = map['sha256']?.toString().toLowerCase() ?? '',
      notes = map['notes']?.toString() ?? '' {
    if (hardware != target ||
        !RegExp(r'^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$').hasMatch(version) ||
        version.length > 31 ||
        url == null ||
        !const {'http', 'https'}.contains(url!.scheme) ||
        url!.host.isEmpty ||
        size < 288 ||
        size > 3 * 1024 * 1024 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('固件清单不完整或与设备型号不匹配');
    }
  }

  final String hardware;
  final String version;
  final Uri? url;
  final int size;
  final String sha256;
  final String notes;

  Map<String, Object> toMap() => {
    'hardware': hardware,
    'version': version,
    'url': url.toString(),
    'size': size,
    'sha256': sha256,
  };
}

bool firmwareIsOlder(String latest, String current) {
  final left = latest
      .split(RegExp(r'[.+-]'))
      .take(3)
      .map(int.tryParse)
      .toList();
  final right = current
      .split(RegExp(r'[.+-]'))
      .take(3)
      .map(int.tryParse)
      .toList();
  for (var i = 0; i < 3; i++) {
    final a = i < left.length ? left[i] ?? 0 : 0;
    final b = i < right.length ? right[i] ?? 0 : 0;
    if (a != b) return a < b;
  }
  return false;
}

Future<FirmwareManifest> checkFirmwareManifest({
  required String hardware,
  required List<Uri> backendBases,
  MethodChannel channel = const MethodChannel('esp_baji/native'),
}) async {
  return withBackendFailover<FirmwareManifest>(
    backendBases,
    (base) async {
      final map = await channel.invokeMapMethod<dynamic, dynamic>(
        'checkFirmwareUpdate',
        {'hardware': hardware, 'backendBase': base.toString()},
      );
      if (map == null) throw const FormatException('服务器没有返回固件清单');
      return FirmwareManifest.fromMap(map, hardware);
    },
    shouldRetry: (error) =>
        isRetryableBackendError(error) ||
        error is PlatformException && error.code == 'firmware_unavailable',
  );
}

class FirmwareUpdatePage extends StatefulWidget {
  const FirmwareUpdatePage({
    super.key,
    required this.hardware,
    required this.currentVersion,
    required this.backendBases,
    required this.prepareTransfer,
    required this.setBusy,
    required this.deviceIdentity,
    this.initialManifest,
    this.onManifest,
    this.channel = const MethodChannel('esp_baji/native'),
  });

  final String hardware;
  final String currentVersion;
  final List<Uri> backendBases;
  final Future<bool> Function() prepareTransfer;
  final void Function(bool) setBusy;
  final Future<String?> Function() deviceIdentity;
  final MethodChannel channel;
  final FirmwareManifest? initialManifest;
  final ValueChanged<FirmwareManifest>? onManifest;

  @override
  State<FirmwareUpdatePage> createState() => _FirmwareUpdatePageState();
}

class _FirmwareUpdatePageState extends State<FirmwareUpdatePage> {
  FirmwareManifest? _manifest;
  bool _checking = true;
  bool _updating = false;
  bool _sent = false;
  String _message = '正在检查固件版本…';

  @override
  void initState() {
    super.initState();
    final initial = widget.initialManifest;
    if (initial != null && initial.hardware == widget.hardware) {
      _manifest = initial;
      _checking = false;
      _message = _versionMessage(initial);
    } else {
      unawaited(_check());
    }
  }

  String _versionMessage(FirmwareManifest manifest) =>
      firmwareIsOlder(manifest.version, widget.currentVersion)
      ? '服务器版本较旧，已禁止降级'
      : !firmwareIsOlder(widget.currentVersion, manifest.version)
      ? '当前已是最新版本，也可重新安装以修复固件'
      : '发现新版本 ${manifest.version}';

  String _error(Object error) => error is PlatformException
      ? error.message ?? error.code
      : error.toString();

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = '正在检查固件版本…';
    });
    try {
      final manifest = await checkFirmwareManifest(
        hardware: widget.hardware,
        backendBases: widget.backendBases,
        channel: widget.channel,
      );
      if (!mounted) return;
      setState(() {
        _manifest = manifest;
        _message = _versionMessage(manifest);
      });
      widget.onManifest?.call(manifest);
    } catch (error) {
      if (mounted) setState(() => _message = _error(error));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _update() async {
    final manifest = _manifest;
    if (manifest == null || _updating) return;
    setState(() {
      _updating = true;
      _message = '正在下载固件并校验…';
    });
    widget.setBusy(true);
    try {
      final identity = await widget.deviceIdentity();
      if (identity == null || identity.isEmpty) {
        throw PlatformException(
          code: 'device_disconnected',
          message: '请重新连接设备',
        );
      }
      final download = await widget.channel.invokeMethod<Map<dynamic, dynamic>>(
        'downloadFirmware',
        manifest.toMap(),
      );
      final path = download?['assetPath'] as String?;
      if (path == null) throw const FormatException('固件下载未完成');
      if (!mounted) return;
      setState(() => _message = '固件已校验，准备连接设备热点');
      if (!await widget.prepareTransfer()) return;
      if (!mounted) return;
      setState(() => _message = '正在写入固件，请保持设备供电和手机连接…');
      final result = await widget.channel.invokeMethod<Map<dynamic, dynamic>>(
        'uploadFirmware',
        {...manifest.toMap(), 'assetPath': path, 'deviceId': identity},
      );
      if (result?['success'] != true) {
        throw const FormatException('设备未确认更新结果');
      }
      if (mounted) {
        setState(() {
          _sent = true;
          _message = '固件校验通过，设备正在重启。重启后重新连接即可查看实际固件版本。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          if (error is PlatformException &&
              error.code == 'firmware_result_unknown') {
            _sent = true;
          }
          _message = _error(error);
        });
      }
    } finally {
      try {
        await widget.channel.invokeMethod<void>('leaveDeviceAccessPoint');
      } catch (_) {
        /* Device may already have rebooted. */
      }
      widget.setBusy(false);
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = _manifest;
    return PopScope(
      canPop: !_updating,
      child: Scaffold(
        appBar: AppBar(title: const AppText('设备固件更新')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText('设备型号：${widget.hardware}'),
              const SizedBox(height: 12),
              AppText('当前固件：${widget.currentVersion}'),
              if (manifest != null) ...[
                const SizedBox(height: 12),
                AppText(
                  '服务器固件：${manifest.version} · ${(manifest.size / 1048576).toStringAsFixed(2)} MB',
                ),
                if (manifest.notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: AppText(manifest.notes),
                  ),
              ],
              const SizedBox(height: 24),
              if (_checking || _updating) const LinearProgressIndicator(),
              const SizedBox(height: 16),
              AppText(_message, key: const Key('firmware-update-message')),
              const SizedBox(height: 24),
              if (!_checking && !_updating && !_sent)
                FilledButton(
                  onPressed: manifest == null
                      ? _check
                      : firmwareIsOlder(manifest.version, widget.currentVersion)
                      ? null
                      : _update,
                  child: AppText(
                    manifest == null
                        ? '重新检查'
                        : manifest.version == widget.currentVersion
                        ? '重新安装固件'
                        : '下载并更新',
                  ),
                ),
              const SizedBox(height: 20),
              const AppText('固件先下载到手机，再通过设备热点传输。更新期间请保持设备供电。'),
            ],
          ),
        ),
      ),
    );
  }
}
