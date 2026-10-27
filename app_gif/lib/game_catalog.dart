import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

class DownloadableGame {
  DownloadableGame(this.metadata, this.directory);
  final Map<String, dynamic> metadata;
  final Directory directory;
  String get id => metadata['id'] as String;
  String get title => metadata['title'] as String;
  int get revision => metadata['revision'] as int;
  String get hash => metadata['sha256'] as String;
  File get package => File('${directory.path}/$hash.json');
  File get cover =>
      File('${directory.path}/${metadata['cover']['sha256']}.png');

  static void validate(Map<String, dynamic> m) {
    if (m['id'] is! String ||
        !RegExp(r'^[a-z0-9_]{1,24}$').hasMatch(m['id']) ||
        m['title'] is! String ||
        (m['title'] as String).isEmpty ||
        (m['title'] as String).length > 64 ||
        m['revision'] is! int ||
        m['revision'] < 1 ||
        m['revision'] > 2147483647 ||
        m['abi'] != 'lua54-v1' ||
        m['hardware'] != 'esp32p4' ||
        m['inputProfile'] != 'swing_v1') {
      throw const FormatException('游戏目录格式无效');
    }
    validateFile(m, 131072);
    if (m['cover'] is! Map<String, dynamic>) {
      throw const FormatException('游戏封面无效');
    }
    validateFile(m['cover'], 512000);
  }

  static void validateFile(Map<String, dynamic> m, int limit) {
    if (m['size'] is! int ||
        m['size'] < 1 ||
        m['size'] > limit ||
        m['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(m['sha256']) ||
        m['url'] is! String ||
        !RegExp(
          r'^/downloads/games/[a-z0-9_-]+\.(json|png)$',
        ).hasMatch(m['url'])) {
      throw const FormatException('游戏文件信息无效');
    }
  }
}

class GameCatalog {
  static Future<List<int>> _read(Uri uri, int limit) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) throw const HttpException('游戏下载失败');
      final bytes = <int>[];
      await for (final part in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(part);
        if (bytes.length > limit) throw const FormatException('游戏文件过大');
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> matches(File file, Map<String, dynamic> meta) async =>
      await file.exists() &&
      await file.length() == meta['size'] &&
      (await sha256.bind(file.openRead()).first).toString() == meta['sha256'];

  static Future<void> _download(
    Uri base,
    Map<String, dynamic> meta,
    File target,
  ) async {
    if (await matches(target, meta)) return;
    final uri = base.resolve(meta['url'] as String);
    if (uri.origin != base.origin) throw const FormatException('游戏下载地址无效');
    final bytes = await _read(uri, meta['size'] as int);
    if (bytes.length != meta['size'] ||
        sha256.convert(bytes).toString() != meta['sha256']) {
      throw const FormatException('游戏文件校验失败');
    }
    final temp = File('${target.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
  }

  static List<DownloadableGame> _parse(String json, Directory root) {
    final catalog = jsonDecode(json) as Map<String, dynamic>;
    if (catalog['schema'] != 1 ||
        catalog['items'] is! List ||
        (catalog['items'] as List).length > 100) {
      throw const FormatException('游戏目录格式无效');
    }
    final seen = <String>{};
    return (catalog['items'] as List).map((raw) {
      final m = Map<String, dynamic>.from(raw as Map);
      DownloadableGame.validate(m);
      if (!seen.add(m['id'] as String)) throw const FormatException('游戏编号重复');
      return DownloadableGame(m, Directory('${root.path}/games/${m['id']}'));
    }).toList();
  }

  static Future<List<DownloadableGame>> sync(
    List<Uri> bases,
    Directory root,
  ) async {
    final saved = File('${root.path}/games/catalog.json');
    Object? lastError;
    for (final base in bases) {
      try {
        final raw = utf8.decode(
          await _read(
            base.resolve('/api/game-catalog?hardware=esp32p4'),
            262144,
          ),
        );
        final games = _parse(raw, root);
        for (final game in games) {
          await game.directory.create(recursive: true);
          await _download(base, game.metadata, game.package);
          await _download(base, game.metadata['cover'], game.cover);
        }
        await saved.parent.create(recursive: true);
        final temp = File('${saved.path}.part');
        await temp.writeAsString(raw, flush: true);
        if (await saved.exists()) await saved.delete();
        await temp.rename(saved.path);
        await _cleanCache(saved.parent, games);
        return games;
      } catch (error) {
        lastError = error;
      }
    }
    if (await saved.exists()) {
      final games = _parse(await saved.readAsString(), root);
      final complete = <DownloadableGame>[];
      for (final game in games) {
        if (await matches(game.package, game.metadata) &&
            await matches(game.cover, game.metadata['cover'])) {
          complete.add(game);
        }
      }
      return complete;
    }
    throw lastError ?? const HttpException('游戏目录暂不可用');
  }

  static Future<void> _cleanCache(
    Directory root,
    List<DownloadableGame> games,
  ) async {
    final keep = {
      for (final game in games) ...[
        game.package.absolute.uri.normalizePath().toString(),
        game.cover.absolute.uri.normalizePath().toString(),
      ],
    };
    try {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is! Directory ||
            !RegExp(r'^[a-z0-9_]{1,24}$').hasMatch(
              entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
            )) {
          continue;
        }
        await for (final file in entry.list(followLinks: false)) {
          if (file is File &&
              RegExp(
                r'^[a-f0-9]{64}\.(json|png)(\.part)?$',
              ).hasMatch(file.uri.pathSegments.last) &&
              !keep.contains(file.absolute.uri.normalizePath().toString())) {
            await file.delete();
          }
        }
        if (await entry.list(followLinks: false).isEmpty) await entry.delete();
      }
    } on FileSystemException {
      // A cleanup failure must not replace a successful catalog with stale entries.
    }
  }
}
