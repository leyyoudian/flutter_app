import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app_gif/game_catalog.dart';

void main() {
  test(
    'withdrawn games leave the catalog and remove only owned cache files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dotloop-game-withdraw',
      );
      final directory = Directory('${root.path}/games/demo');
      await directory.create(recursive: true);
      final oldPackage = File('${directory.path}/${'a' * 64}.json');
      final oldCover = File('${directory.path}/${'b' * 64}.png');
      final marker = File('${directory.path}/keep.txt');
      await oldPackage.writeAsString('old');
      await oldCover.writeAsString('old');
      await marker.writeAsString('keep');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.write(
          jsonEncode({'schema': 1, 'revision': 4, 'items': []}),
        );
        await request.response.close();
      });
      try {
        expect(
          await GameCatalog.sync([
            Uri.parse('http://127.0.0.1:${server.port}'),
          ], root),
          isEmpty,
        );
        expect(await oldPackage.exists(), isFalse);
        expect(await oldCover.exists(), isFalse);
        expect(await marker.readAsString(), 'keep');
        expect(await GameCatalog.sync([], root), isEmpty);
      } finally {
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'verified remote package stays available offline; corrupt files are never installed',
    () async {
      final root = await Directory.systemTemp.createTemp('dotloop-game-test');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final pack = utf8.encode('{"schema":1,"script":"function init() end"}');
      final image = <int>[137, 80, 78, 71, 13, 10, 26, 10];
      final meta = <String, dynamic>{
        'id': 'pingpong',
        'title': 'Ping Pong',
        'revision': 1,
        'abi': 'lua54-v1',
        'hardware': 'esp32p4',
        'inputProfile': 'swing_v1',
        'url': '/downloads/games/pingpong.json',
        'size': pack.length,
        'sha256': sha256.convert(pack).toString(),
        'cover': {
          'url': '/downloads/games/pingpong.png',
          'size': image.length,
          'sha256': sha256.convert(image).toString(),
        },
      };
      var corrupt = false;
      server.listen((request) async {
        if (request.uri.path == '/api/game-catalog') {
          request.response.write(
            jsonEncode({
              'schema': 1,
              'revision': 1,
              'items': [meta],
            }),
          );
        } else if (request.uri.path.endsWith('.json')) {
          request.response.add(corrupt ? <int>[1, 2, 3] : pack);
        } else {
          request.response.add(image);
        }
        await request.response.close();
      });
      final base = Uri.parse('http://127.0.0.1:${server.port}');
      try {
        final games = await GameCatalog.sync([base], root);
        expect(games.single.id, 'pingpong');
        expect(await GameCatalog.matches(games.single.package, meta), isTrue);
        corrupt = true;
        await games.single.package.delete();
        final fallback = await GameCatalog.sync([base], root);
        expect(fallback, isEmpty);
        expect(await games.single.package.exists(), isFalse);
        corrupt = false;
        await GameCatalog.sync([base], root);
        await server.close(force: true);
        final offline = await GameCatalog.sync([], root);
        expect(offline.single.hash, meta['sha256']);
      } finally {
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'catalog rejects traversal, unknown ABI, non-integer versions and external URLs',
    () {
      final good = <String, dynamic>{
        'id': 'pingpong',
        'title': 'Ping Pong',
        'revision': 1,
        'abi': 'lua54-v1',
        'hardware': 'esp32p4',
        'inputProfile': 'swing_v1',
        'url': '/downloads/games/pingpong.json',
        'size': 10,
        'sha256': 'a' * 64,
        'cover': {
          'url': '/downloads/games/pingpong.png',
          'size': 10,
          'sha256': 'b' * 64,
        },
      };
      expect(() => DownloadableGame.validate(good), returnsNormally);
      for (final bad in [
        {'id': '../escape'},
        {'abi': 'unknown'},
        {'revision': 1.5},
        {'url': 'http://example.com/a.json'},
        {'size': 131073},
      ]) {
        expect(
          () => DownloadableGame.validate({...good, ...bad}),
          throwsFormatException,
        );
      }
    },
  );
}
