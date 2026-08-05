import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class FactoryCatalogSync {
  const FactoryCatalogSync._();

  static const installFileName = 'factory_catalog_install.json';

  static List<Map<String, dynamic>> mergeCatalogForTest({
    required List<Map<String, dynamic>> builtIn,
    required Map<String, dynamic> remote,
    required Map<String, dynamic> installed,
  }) {
    return _mergeCatalogs(
      builtIn: builtIn,
      remote: remote,
      installed: installed,
    );
  }

  static Future<List<Map<String, dynamic>>> syncOnce({
    required Uri backendBase,
    required Directory cacheRoot,
    required List<Map<String, dynamic>> builtIn,
  }) async {
    final installFile = File(
      '${cacheRoot.path}${Platform.pathSeparator}$installFileName',
    );
    final installed = await _readJsonFile(installFile);
    Map<String, dynamic>? remote;
    try {
      remote = await _fetchJson(backendBase.resolve('/api/factory-catalog'));
      remote = await _downloadAppFiles(
        backendBase: backendBase,
        cacheRoot: cacheRoot,
        remote: remote,
      );
      await _deleteRemovedInstalledFiles(cacheRoot, installed, remote);
      await installFile.parent.create(recursive: true);
      await installFile.writeAsString(json.encode(remote), flush: true);
    } catch (_) {
      remote = installed.isEmpty ? null : installed;
    }
    return _mergeCatalogs(
      builtIn: builtIn,
      remote: remote ?? <String, dynamic>{},
      installed: installed,
    );
  }

  static List<Map<String, dynamic>> _mergeCatalogs({
    required List<Map<String, dynamic>> builtIn,
    required Map<String, dynamic> remote,
    required Map<String, dynamic> installed,
  }) {
    final result = <String, Map<String, dynamic>>{};
    for (final item in builtIn) {
      final id = _readString(item['id']);
      if (id.isEmpty) continue;
      result[id] = Map<String, dynamic>.from(item)
        ..putIfAbsent('protected', () => _isProtectedBaseline(id));
    }

    final installedItems = installed['items'];
    if (installedItems is List) {
      for (final raw in installedItems) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final id = _readString(item['id']);
        if (id.isEmpty || _isProtectedBaseline(id)) continue;
        result[id] = _normalizeAnimationMap(item);
      }
    }

    final remoteItems = remote['items'];
    if (remoteItems is List) {
      final remoteIds = <String>{};
      for (final raw in remoteItems) {
        if (raw is! Map) continue;
        final item = Map<String, dynamic>.from(raw);
        final id = _readString(item['id']);
        if (id.isEmpty) continue;
        remoteIds.add(id);
        result[id] = _catalogItemToAnimationMap(item);
      }
      result.removeWhere((id, item) {
        final protected = item['protected'] == true || _isProtectedBaseline(id);
        return !protected && !remoteIds.contains(id);
      });
    }

    final items = result.values.toList();
    items.sort(
      (a, b) => _factorySortKey(
        _readString(a['id']),
      ).compareTo(_factorySortKey(_readString(b['id']))),
    );
    return items;
  }

  static Map<String, dynamic> _catalogItemToAnimationMap(
    Map<String, dynamic> item,
  ) {
    final id = _readString(item['id']);
    final appFiles = item['appFiles'] is Map
        ? Map<String, dynamic>.from(item['appFiles'] as Map)
        : <String, dynamic>{};
    final thumbnail = appFiles['thumbnail'] is Map
        ? Map<String, dynamic>.from(appFiles['thumbnail'] as Map)
        : <String, dynamic>{};
    final firstVideo = appFiles['firstVideo'] is Map
        ? Map<String, dynamic>.from(appFiles['firstVideo'] as Map)
        : <String, dynamic>{};
    final secondVideo = appFiles['secondVideo'] is Map
        ? Map<String, dynamic>.from(appFiles['secondVideo'] as Map)
        : <String, dynamic>{};
    final loopVideo = appFiles['loopVideo'] is Map
        ? Map<String, dynamic>.from(appFiles['loopVideo'] as Map)
        : <String, dynamic>{};
    return _normalizeAnimationMap({
      'id': id,
      'name': _readString(item['title']).isEmpty
          ? id
          : _readString(item['title']),
      'type': _readString(item['type']).isEmpty
          ? 'split'
          : _readString(item['type']),
      'protected': item['protected'] == true || _isProtectedBaseline(id),
      'revision': item['revision'],
      'previewAsset': _readString(thumbnail['localPath']),
      'firstVideo': _readString(firstVideo['localPath']),
      'secondVideo': _readString(secondVideo['localPath']),
      'loopVideo': _readString(loopVideo['localPath']),
      'transitions': item['transitions'] ?? <String, String>{},
    });
  }

  static Map<String, dynamic> _normalizeAnimationMap(
    Map<String, dynamic> item,
  ) {
    final id = _readString(item['id']);
    final type = _readString(item['type']).isEmpty
        ? 'split'
        : _readString(item['type']);
    return {
      'id': id,
      'name': _readString(item['name']).isEmpty
          ? id
          : _readString(item['name']),
      'type': type,
      'protected': item['protected'] == true || _isProtectedBaseline(id),
      'previewAsset': _readString(item['previewAsset']),
      if (_readString(item['firstVideo']).isNotEmpty)
        'firstVideo': _readString(item['firstVideo']),
      if (_readString(item['secondVideo']).isNotEmpty)
        'secondVideo': _readString(item['secondVideo']),
      if (_readString(item['loopVideo']).isNotEmpty)
        'loopVideo': _readString(item['loopVideo']),
      'transitions': item['transitions'] is Map
          ? Map<String, dynamic>.from(item['transitions'] as Map)
          : <String, dynamic>{},
    };
  }

  static Future<Map<String, dynamic>> _fetchJson(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(text, uri: uri);
      }
      final decoded = json.decode(text);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> _downloadAppFiles({
    required Uri backendBase,
    required Directory cacheRoot,
    required Map<String, dynamic> remote,
  }) async {
    final items = remote['items'];
    if (items is! List) return remote;
    final nextItems = <Map<String, dynamic>>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final id = _readString(item['id']);
      final revision = _readString(item['revision']).isEmpty
          ? '0'
          : _readString(item['revision']);
      final appFiles = item['appFiles'] is Map
          ? Map<String, dynamic>.from(item['appFiles'] as Map)
          : <String, dynamic>{};
      final nextAppFiles = <String, dynamic>{};
      for (final entry in appFiles.entries) {
        if (entry.value is! Map) continue;
        final fileMeta = Map<String, dynamic>.from(entry.value as Map);
        final urlText = _readString(fileMeta['url']);
        final sha = _readString(fileMeta['sha256']);
        final size = (fileMeta['size'] as num?)?.toInt() ?? 0;
        if (urlText.isEmpty || sha.length != 64 || size <= 0) continue;
        final uri = backendBase.resolve(urlText);
        final fileName = uri.pathSegments.isEmpty
            ? '${entry.key}.bin'
            : uri.pathSegments.last;
        final local = File(
          '${cacheRoot.path}${Platform.pathSeparator}factory${Platform.pathSeparator}$id${Platform.pathSeparator}$revision${Platform.pathSeparator}$fileName',
        );
        if (!await _fileMatches(local, size, sha)) {
          await _downloadVerified(uri, local, size, sha);
        }
        nextAppFiles[entry.key] = {...fileMeta, 'localPath': local.path};
      }
      nextItems.add({...item, 'appFiles': nextAppFiles});
    }
    return {...remote, 'items': nextItems};
  }

  static Future<void> _downloadVerified(
    Uri uri,
    File target,
    int expectedSize,
    String expectedSha,
  ) async {
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('download failed', uri: uri);
      }
      final sink = tmp.openWrite();
      var total = 0;
      await for (final chunk in response) {
        total += chunk.length;
        sink.add(chunk);
      }
      await sink.close();
      if (total != expectedSize ||
          !await _fileMatches(tmp, expectedSize, expectedSha)) {
        try {
          await tmp.delete();
        } on FileSystemException {
          // Best effort cleanup; verification failure is reported below.
        }
        throw const FileSystemException('factory file verification failed');
      }
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(target.path);
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _fileMatches(
    File file,
    int expectedSize,
    String expectedSha,
  ) async {
    if (!await file.exists()) return false;
    final stat = await file.stat();
    if (stat.size != expectedSize) return false;
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString().toLowerCase() ==
        expectedSha.toLowerCase();
  }

  static Future<Map<String, dynamic>> _readJsonFile(File file) async {
    try {
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = json.decode(await file.readAsString());
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<void> _deleteRemovedInstalledFiles(
    Directory cacheRoot,
    Map<String, dynamic> installed,
    Map<String, dynamic> remote,
  ) async {
    final remoteIds = <String>{};
    final remoteItems = remote['items'];
    if (remoteItems is List) {
      for (final item in remoteItems) {
        if (item is Map) remoteIds.add(_readString(item['id']));
      }
    }
    final installedItems = installed['items'];
    if (installedItems is! List) return;
    for (final raw in installedItems) {
      if (raw is! Map) continue;
      final id = _readString(raw['id']);
      if (id.isEmpty || _isProtectedBaseline(id) || remoteIds.contains(id)) {
        continue;
      }
      final dir = Directory(
        '${cacheRoot.path}${Platform.pathSeparator}factory${Platform.pathSeparator}$id',
      );
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }

  static bool _isProtectedBaseline(String id) {
    final match = RegExp(r'^F(\d{3})$').firstMatch(id);
    if (match == null) return false;
    final number = int.tryParse(match.group(1) ?? '') ?? 0;
    return number >= 1 && number <= 21;
  }

  static int _factorySortKey(String id) {
    final match = RegExp(r'^F(\d{3})$').firstMatch(id);
    return int.tryParse(match?.group(1) ?? '') ?? 9999;
  }

  static String _readString(Object? value) =>
      value == null ? '' : value.toString();
}
