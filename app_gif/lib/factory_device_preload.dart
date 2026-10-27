import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'factory_catalog_sync.dart';
import 'factory_device_install.dart';

/// Stages device files while the App is idle and has Internet access. It never
/// opens the device hotspot or installs anything without a foreground request.
class FactoryDevicePreload {
  FactoryDevicePreload({
    required this.cacheRoot,
    required this.backendBases,
    required this.canRun,
    this.onDiagnostic,
  });

  final Directory cacheRoot;
  final List<Uri> backendBases;
  final bool Function() canRun;
  final void Function(String message)? onDiagnostic;
  final Set<String> _ready = {};
  Future<void>? _running;
  FactoryInstallCancellation? _cancellation;
  DateTime? _retryAfter;
  static const _maxStagedBytes = 192 * 1024 * 1024;

  File get _ledger => File('${cacheRoot.path}/factory_device_delivered.json');

  Future<void> start() {
    if (!canRun() ||
        (_retryAfter != null && DateTime.now().isBefore(_retryAfter!))) {
      return Future<void>.value();
    }
    return _running ??= _run().whenComplete(() => _running = null);
  }

  Future<void> pause() async {
    _cancellation?.cancel();
    await _running;
  }

  Future<Map<String, dynamic>> _read(File file) async {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _run() async {
    final cancellation = FactoryInstallCancellation();
    _cancellation = cancellation;
    final guard = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!canRun()) cancellation.cancel();
    });
    try {
      final catalog = await _read(
        File('${cacheRoot.path}/${FactoryCatalogSync.installFileName}'),
      );
      final delivered = await _read(_ledger);
      final items = catalog['items'];
      if (items is! List) return;
      for (final raw in items) {
        if (!canRun()) break;
        cancellation.check();
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final id = item['id'];
        final files = item['deviceFiles'];
        if (id is! String ||
            FactoryCatalogSync.retiredIds.contains(id) ||
            files is! List ||
            files.isEmpty) {
          continue;
        }
        try {
          FactoryDeviceInstall.validateFiles(
            id,
            item['type']?.toString() ?? 'split',
            files.cast<Map<String, dynamic>>(),
          );
          final key = FactoryDeviceInstall.catalogKey(item);
          if (delivered[id] == key || _ready.contains('$id:$key')) continue;
          final bytes = files.fold<int>(
            0,
            (sum, f) => sum + (f['size'] as int),
          );
          if (await _stagedBytes() + bytes * 2 > _maxStagedBytes) {
            onDiagnostic?.call('FACTORY PRELOAD cache budget reached');
            break;
          }
          final package =
              await FactoryDeviceInstall.readPrepared(
                id: id,
                cacheRoot: cacheRoot,
              ) ??
              await FactoryDeviceInstall.prepare(
                id: id,
                backendBases: backendBases,
                cacheRoot: cacheRoot,
                onProgress: (_) {},
                onDiagnostic: onDiagnostic,
                cancellation: cancellation,
              );
          _ready.add('$id:${package['cacheKey']}');
          onDiagnostic?.call('FACTORY PRELOAD $id ready');
        } on FactoryInstallCancelled {
          break;
        } catch (error) {
          _retryAfter = DateTime.now().add(const Duration(minutes: 1));
          onDiagnostic?.call(
            'FACTORY PRELOAD $id deferred ${error.runtimeType}',
          );
        }
      }
    } on FactoryInstallCancelled {
      // Foreground work has priority; no user-facing background error.
    } catch (error) {
      onDiagnostic?.call('FACTORY PRELOAD deferred ${error.runtimeType}');
    } finally {
      guard.cancel();
      if (identical(_cancellation, cancellation)) _cancellation = null;
    }
  }

  Future<int> _stagedBytes() async {
    final device = Directory('${cacheRoot.path}/device');
    if (!await device.exists()) return 0;
    var total = 0;
    await for (final entry in device.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  /// Call only after the expected device acknowledges this exact install. A
  /// durable record prevents a future catalog refresh from downloading it again.
  Future<bool> deliveredToDevice(
    String id,
    String cacheKey,
    String deviceKey,
  ) async {
    if (deviceKey.isEmpty) return false;
    final delivered = await _read(_ledger);
    return delivered['$id@$deviceKey'] == cacheKey;
  }

  Future<void> installed(
    Map<String, dynamic> package, {
    String? deviceKey,
  }) async {
    await pause();
    final id = package['id'];
    final revision = package['revision'];
    final key = package['cacheKey'];
    if (id is! String ||
        !RegExp(r'^[FS][0-9]{3}$').hasMatch(id) ||
        revision is! int ||
        revision < 1 ||
        key is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(key)) {
      throw const FormatException('素材缓存记录无效');
    }
    final folder = Directory('${cacheRoot.path}/device/$id/$revision').absolute;
    final expected = File('${folder.path}/install.dlf').absolute.path;
    if (File(package['assetPath'] as String).absolute.path != expected) {
      throw const FormatException('素材缓存路径无效');
    }
    final delivered = await _read(_ledger);
    delivered[id] = key;
    if (deviceKey != null && deviceKey.isNotEmpty) {
      delivered['$id@$deviceKey'] = key;
    }
    final temp = File('${_ledger.path}.tmp');
    await temp.writeAsString(jsonEncode(delivered), flush: true);
    await temp.rename(_ledger.path);
    _ready.removeWhere((entry) => entry.startsWith('$id:'));
    if (await FileSystemEntity.type(folder.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (name == 'install.dlf' ||
            name == 'prepared.json' ||
            name == 'prepared.json.tmp' ||
            RegExp(r'^\d+-[a-f0-9]{64}\.eb5(?:\.part)?$').hasMatch(name)) {
          await entry.delete();
        }
      }
    }
    onDiagnostic?.call('FACTORY PRELOAD $id installed; device files released');
  }
}
