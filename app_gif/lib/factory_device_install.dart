import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum FactoryInstallStage { downloading, verifying, packaging, ready }

class FactoryInstallCancelled implements Exception {}

/// Cancels owned HTTP requests before a foreground device transfer starts.
class FactoryInstallCancellation {
  bool _cancelled = false;
  final Set<HttpClient> _clients = {};

  void check() {
    if (_cancelled) throw FactoryInstallCancelled();
  }

  void attach(HttpClient client) {
    check();
    _clients.add(client);
  }

  void detach(HttpClient client) => _clients.remove(client);

  void cancel() {
    _cancelled = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }
}

/// Phone-side preparation happens while internet is still available, before
/// joining the device hotspot. Only the chosen item's device payload is read.
class FactoryDeviceInstall {
  static const maxBytes = 64 * 1024 * 1024;

  static Future<Map<String, dynamic>> prepare({
    required String id,
    required List<Uri> backendBases,
    required Directory cacheRoot,
    required void Function(double progress) onProgress,
    void Function(FactoryInstallStage stage)? onStage,
    void Function(String message)? onDiagnostic,
    FactoryInstallCancellation? cancellation,
  }) async {
    if (!RegExp(r'^[FS][0-9]{3}$').hasMatch(id)) {
      throw const FormatException('素材编号无效');
    }
    Object? lastError;
    final watch = Stopwatch()..start();
    void trace(String message) => onDiagnostic?.call(
      'FACTORY $id ${watch.elapsedMilliseconds}ms $message',
    );
    trace('prepare start');
    for (final base in backendBases) {
      cancellation?.check();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        cancellation?.attach(client);
        final request = await client.getUrl(
          base.resolve('/api/factory-catalog?hardware=esp32p4'),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 25),
        );
        if (response.statusCode != 200) throw const HttpException('素材目录下载失败');
        final catalogBytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 25),
        )) {
          cancellation?.check();
          catalogBytes.addAll(chunk);
          if (catalogBytes.length > 256 * 1024) {
            throw const FormatException('素材目录过大');
          }
        }
        final text = utf8.decode(catalogBytes);
        final catalog = jsonDecode(text) as Map<String, dynamic>;
        final item = (catalog['items'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere((x) => x['id'] == id);
        final files = (item['deviceFiles'] as List)
            .cast<Map<String, dynamic>>();
        validateFiles(id, item['type']?.toString() ?? 'split', files);
        final total = files.fold<int>(
          0,
          (sum, x) => sum + (x['size'] as num).toInt(),
        );
        final revision = item['revision'];
        if (revision is! int || revision < 1) {
          throw const FormatException('素材版本无效');
        }
        final folder = Directory('${cacheRoot.path}/device/$id/$revision');
        await folder.create(recursive: true);
        final localFiles = <File>[];
        var completed = 0;
        String? preferredOrigin;
        for (var index = 0; index < files.length; index++) {
          cancellation?.check();
          final meta = files[index];
          final size = (meta['size'] as num).toInt();
          final hash = meta['sha256'].toString().toLowerCase();
          final local = File('${folder.path}/$index-$hash.eb5');
          onStage?.call(FactoryInstallStage.verifying);
          if (!await _matches(local, size, hash)) {
            final uri = base.resolve(meta['url'].toString());
            if (uri.origin != base.origin) {
              throw const FormatException('素材下载地址无效');
            }
            onStage?.call(FactoryInstallStage.downloading);
            final temp = File('${local.path}.part');
            final origins = <String>{};
            final sources = [base, ...backendBases]
                .where((b) => origins.add(b.origin))
                .take(3)
                .map(
                  (b) => b.resolve(
                    uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
                  ),
                )
                .toList();
            preferredOrigin = await _downloadPayload(
              sources,
              temp,
              size,
              hash,
              preferredOrigin,
              (received) => onProgress((completed + received) / total),
              () => onStage?.call(FactoryInstallStage.verifying),
              trace,
              cancellation,
            );
            if (await local.exists()) await local.delete();
            await temp.rename(local.path);
            trace('file=${index + 1} downloaded bytes=$size');
          } else {
            trace('file=${index + 1} cache verified bytes=$size');
          }
          localFiles.add(local);
          completed += size;
          onProgress(completed / total);
        }
        final manifest = utf8.encode(
          jsonEncode({
            'schemaVersion': 1,
            'hardware': 'esp32p4',
            'id': id,
            'revision': revision,
            'type': item['type'],
            'files': files
                .map(
                  (x) => {
                    'path': x['path'],
                    'size': x['size'],
                    'sha256': x['sha256'],
                  },
                )
                .toList(),
          }),
        );
        final header = ByteData(8)
          ..setUint32(0, 0x31464c44, Endian.little)
          ..setUint32(4, manifest.length, Endian.little);
        final package = File('${folder.path}/install.dlf');
        onStage?.call(FactoryInstallStage.packaging);
        cancellation?.check();
        trace('packaging bytes=$total');
        final sink = package.openWrite();
        try {
          sink.add(header.buffer.asUint8List());
          sink.add(manifest);
          for (final local in localFiles) {
            cancellation?.check();
            await sink.addStream(local.openRead());
          }
        } finally {
          await sink.close();
        }
        final packageHash = (await sha256.bind(package.openRead()).first)
            .toString();
        cancellation?.check();
        final result = <String, dynamic>{
          'assetPath': package.path,
          'id': id,
          'revision': revision,
          'size': await package.length(),
          'sha256': packageHash,
          'cacheKey': catalogKey(item),
        };
        final receipt = File('${folder.path}/prepared.json.tmp');
        await receipt.writeAsString(jsonEncode(result), flush: true);
        cancellation?.check();
        await receipt.rename('${folder.path}/prepared.json');
        onStage?.call(FactoryInstallStage.ready);
        trace('ready bytes=${await package.length()}');
        return result;
      } catch (error) {
        cancellation?.check();
        lastError = error;
        trace('catalog origin=${base.origin} failed ${error.runtimeType}');
      } finally {
        cancellation?.detach(client);
        client.close(force: true);
      }
    }
    throw lastError ?? const HttpException('无法下载设备素材');
  }

  /// Reads a staged package without a public network request. The current local
  /// catalog fingerprint and the complete package hash must both still match.
  static Future<Map<String, dynamic>?> readPrepared({
    required String id,
    required Directory cacheRoot,
  }) async {
    try {
      if (!RegExp(r'^[FS][0-9]{3}$').hasMatch(id)) return null;
      final catalog =
          jsonDecode(
                await File(
                  '${cacheRoot.path}/factory_catalog_install.json',
                ).readAsString(),
              )
              as Map;
      final item = (catalog['items'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((x) => x['id'] == id);
      validateFiles(
        id,
        item['type']?.toString() ?? 'split',
        (item['deviceFiles'] as List).cast<Map<String, dynamic>>(),
      );
      final revision = item['revision'];
      if (revision is! int || revision < 1) return null;
      final folder = '${cacheRoot.path}/device/$id/$revision';
      final result = Map<String, dynamic>.from(
        jsonDecode(await File('$folder/prepared.json').readAsString()) as Map,
      );
      final package = File('$folder/install.dlf');
      if (result['id'] != id ||
          result['revision'] != revision ||
          result['cacheKey'] != catalogKey(item) ||
          result['size'] is! int ||
          (result['size'] as int) > maxBytes + 4096 ||
          result['sha256'] is! String ||
          !await _matches(
            package,
            result['size'] as int,
            result['sha256'] as String,
          )) {
        return null;
      }
      // iOS can relocate an App's data container during an update. Always use
      // the fixed path under the current cache root, then verify its full hash.
      // Never open the absolute path persisted by an earlier installation.
      return {...result, 'assetPath': package.path};
    } catch (_) {
      return null;
    }
  }

  static String catalogKey(Map<String, dynamic> item) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'revision': item['revision'],
            'files': (item['deviceFiles'] as List)
                .map(
                  (file) => {
                    'path': file['path'],
                    'size': file['size'],
                    'sha256': file['sha256'],
                  },
                )
                .toList(),
          }),
        ),
      )
      .toString();

  // Observe the first 512 KiB, not just HTTP header latency: the slow primary
  // can return 200 promptly while transferring the body at only ~64 KiB/s.
  // The winning response continues from its buffered prefix; losing clients
  // are closed. Reuse the winner for the remaining files in this package.
  static Future<String> _downloadPayload(
    List<Uri> sources,
    File target,
    int size,
    String hash,
    String? preferred,
    void Function(int bytes) onBytes,
    void Function() onVerify,
    void Function(String message) trace,
    FactoryInstallCancellation? cancellation,
  ) async {
    final remaining = List<Uri>.of(sources);
    if (preferred != null) {
      remaining.sort(
        (a, b) => (a.origin == preferred ? 0 : 1).compareTo(
          b.origin == preferred ? 0 : 1,
        ),
      );
    }
    Object? lastError;
    while (remaining.isNotEmpty) {
      cancellation?.check();
      _PayloadProbe? selected;
      try {
        if (preferred != null && remaining.first.origin == preferred) {
          selected = _PayloadProbe(remaining.first, size, cancellation);
          await selected.start();
        } else {
          selected = await _racePayloads(remaining, size, cancellation);
        }
        trace('route=${selected.uri.origin} prefix=${selected.received}');
        final sink = target.openWrite();
        final digest = _FactoryDigestSink();
        final hashing = sha256.startChunkedConversion(digest);
        var received = 0;
        final progressWatch = Stopwatch()..start();
        var lastProgressMs = -100;
        void consume(List<int> chunk) {
          cancellation?.check();
          received += chunk.length;
          if (received > size) throw const FormatException('素材大小不符');
          hashing.add(chunk);
          sink.add(chunk);
          if (progressWatch.elapsedMilliseconds - lastProgressMs >= 100 ||
              received == size) {
            lastProgressMs = progressWatch.elapsedMilliseconds;
            onBytes(received);
          }
        }

        try {
          for (final chunk in selected.prefix) {
            consume(chunk);
          }
          while (await selected.iterator!.moveNext()) {
            consume(selected.iterator!.current);
          }
        } finally {
          hashing.close();
          await sink.close();
        }
        onVerify();
        if (received != size || digest.value.toString() != hash) {
          throw const FormatException('素材校验失败，请重试');
        }
        return selected.uri.origin;
      } catch (error) {
        cancellation?.check();
        if (error is FileSystemException) rethrow;
        lastError = error;
        if (selected == null) rethrow; // All probes failed; no viable source.
        trace('route=${selected.uri.origin} rejected ${error.runtimeType}');
        remaining.removeWhere((u) => u.origin == selected!.uri.origin);
        preferred = null;
      } finally {
        selected?.dispose();
      }
    }
    throw lastError ?? const HttpException('设备素材下载失败');
  }

  static Future<_PayloadProbe> _racePayloads(
    List<Uri> sources,
    int size,
    FactoryInstallCancellation? cancellation,
  ) {
    final result = Completer<_PayloadProbe>();
    final probes = sources
        .map((u) => _PayloadProbe(u, size, cancellation))
        .toList();
    var pending = probes.length;
    final started = <_PayloadProbe>{};
    Timer? hedge;
    late void Function(_PayloadProbe) startProbe;
    void startAlternates() {
      if (result.isCompleted) return;
      for (final probe in probes.skip(1)) {
        startProbe(probe);
      }
    }

    startProbe = (probe) {
      if (!started.add(probe)) return;
      unawaited(
        probe
            .start()
            .then<void>((_) {
              if (result.isCompleted) {
                probe.dispose();
                return;
              }
              hedge?.cancel();
              result.complete(probe);
              for (final other in probes) {
                if (other != probe) other.dispose();
              }
            })
            .catchError((Object error, StackTrace stack) {
              probe.dispose();
              if (--pending == 0 && !result.isCompleted) {
                hedge?.cancel();
                result.completeError(error, stack);
              } else if (probe == probes.first) {
                startAlternates();
              }
            }),
      );
    };
    // Healthy primaries often finish the observation window before this hedge
    // starts. Avoid mistaking a mirror's small initial burst for sustained speed.
    hedge = Timer(const Duration(milliseconds: 500), startAlternates);
    startProbe(probes.first);
    return result.future;
  }

  static void validateFiles(
    String id,
    String type,
    List<Map<String, dynamic>> files,
  ) {
    if (!RegExp(r'^[FS][0-9]{3}$').hasMatch(id) ||
        (type != 'split' && type != 'loop')) {
      throw const FormatException('素材类型或编号无效');
    }
    if (files.isEmpty) throw const FormatException('服务器尚未提供这项动画的设备文件');
    if (files.length > 4) throw const FormatException('素材文件数量无效');
    final paths = <String>{};
    var total = 0;
    for (final file in files) {
      final path = file['path'];
      if (path is! String ||
          !RegExp(
            '^(first_half|second_half|third_half|factory_loop|loop_intro)/$id\\.eb5\$',
          ).hasMatch(path) ||
          !paths.add(path) ||
          file['size'] is! int ||
          (file['size'] as int) < 44 ||
          (file['size'] as int) > 32 * 1024 * 1024 ||
          !RegExp(
            r'^[0-9a-fA-F]{64}$',
          ).hasMatch(file['sha256']?.toString() ?? '') ||
          file['hardware'] != 'esp32p4') {
        throw const FormatException('设备素材清单无效');
      }
      total += file['size'] as int;
    }
    if (total > maxBytes ||
        (type == 'loop'
            ? !paths.contains('factory_loop/$id.eb5') ||
                  paths.length > 2 ||
                  (paths.length == 2 && !paths.contains('loop_intro/$id.eb5'))
            : !paths.contains('first_half/$id.eb5') ||
                  !paths.contains('second_half/$id.eb5') ||
                  paths.contains('factory_loop/$id.eb5')) ||
        (id.startsWith('S') &&
            (paths.length != 3 || !paths.contains('third_half/$id.eb5')))) {
      throw const FormatException('设备素材不完整或过大');
    }
  }

  static Future<bool> _matches(File file, int size, String hash) async =>
      await file.exists() &&
      await file.length() == size &&
      (await sha256.bind(file.openRead()).first).toString() == hash;
}

class _FactoryDigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

class _PayloadProbe {
  _PayloadProbe(this.uri, this.size, this.cancellation);
  final Uri uri;
  final int size;
  final FactoryInstallCancellation? cancellation;
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  StreamIterator<List<int>>? iterator;
  final prefix = <List<int>>[];
  int received = 0;
  bool disposed = false;

  Future<void> start() async {
    cancellation?.attach(client);
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw HttpException('设备素材下载失败 (${response.statusCode})', uri: uri);
    }
    iterator = StreamIterator(response.timeout(const Duration(seconds: 30)));
    while (received < 512 * 1024 && await iterator!.moveNext()) {
      cancellation?.check();
      if (disposed) throw const HttpException('下载探测已结束');
      final chunk = Uint8List.fromList(iterator!.current);
      received += chunk.length;
      if (received > size) throw const FormatException('素材大小不符');
      prefix.add(chunk);
    }
    if (received < 512 * 1024 && received != size) {
      throw const FormatException('素材大小不符');
    }
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    cancellation?.detach(client);
    client.close(force: true);
    final active = iterator;
    if (active != null) unawaited(active.cancel().catchError((Object _) {}));
  }
}
