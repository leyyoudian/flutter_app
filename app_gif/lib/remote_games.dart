import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_language.dart';
import 'game_catalog.dart';
import 'swing_game.dart';

const _channel = MethodChannel('esp_baji/native');

class RemoteGamesPage extends StatefulWidget {
  const RemoteGamesPage({
    super.key,
    required this.backendBases,
    required this.onFlyBird,
  });
  final List<Uri> backendBases;
  final VoidCallback onFlyBird;
  @override
  State<RemoteGamesPage> createState() => _RemoteGamesPageState();
}

class _RemoteGamesPageState extends State<RemoteGamesPage> {
  List<DownloadableGame> _games = [];
  final Set<String> _installed = {};
  bool _loading = true, _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final root = await _channel.invokeMethod<String>('factoryCacheRoot');
      if (root == null) throw StateError('Cache unavailable');
      final games = await GameCatalog.sync(
        widget.backendBases,
        Directory(root),
      );
      if (!mounted) return;
      setState(() => _games = games);
      // Inventory belongs to this physical board, never a previous connection.
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'ensureGameBluetooth',
      );
      if (info?['status']?.toString().contains('lua=1') == true) {
        for (final game in games) {
          final reply = await _device('GINFO ${game.id}');
          if (reply == 'OK GAME ${game.id} ${game.revision} ${game.hash}') {
            _installed.add(game.id);
          }
        }
      }
    } catch (error) {
      if (_games.isEmpty) _error = _message(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _message(Object error) => error is PlatformException
      ? error.message ?? error.code
      : error.toString();
  Future<String> _device(String command) async =>
      (await _channel.invokeMethod<String>('deviceBluetoothCommand', {
        'command': command,
      }))?.trim() ??
      '';

  Future<bool> _prepareTransfer() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('连接设备传输热点'),
        content: const AppText(
          '素材已准备好。接下来设备会开启 DotLoop Wi-Fi，允许系统连接后即可传输。传输期间没有互联网是正常的，蓝牙控制仍保持连接。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const AppText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const AppText('连接并传输'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    try {
      final identity = await _device('IDENTITY');
      final match = RegExp(
        r'^OK DEVICE (P4-[A-Fa-f0-9]{12})$',
      ).firstMatch(identity);
      if (match == null) throw const FormatException('设备身份无效');
      await _device('AP');
      if (await _channel.invokeMethod<bool>('joinDeviceAccessPoint') != true) {
        throw const FormatException('连接设备热点失败');
      }
      if (await _channel.invokeMethod<String>('getDeviceIdentity') !=
          match[1]) {
        throw const FormatException('热点不是当前蓝牙设备，已停止传输');
      }
      return true;
    } catch (error) {
      await _channel.invokeMethod<dynamic>('leaveDeviceAccessPoint');
      rethrow;
    }
  }

  Future<void> _open(DownloadableGame game) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'ensureGameBluetooth',
      );
      if (info?['status']?.toString().contains('lua=1') != true) {
        throw PlatformException(
          code: 'firmware_required',
          message: tr('请先升级设备固件以支持下载游戏'),
        );
      }
      final expected = 'OK GAME ${game.id} ${game.revision} ${game.hash}';
      final inventory = await _device('GINFO ${game.id}');
      if (inventory != expected) {
        _installed.remove(game.id);
        if (!await GameCatalog.matches(game.package, game.metadata)) {
          throw const FormatException('游戏文件校验失败');
        }
        if (!await _prepareTransfer()) return;
        try {
          final key = await _channel.invokeMethod<String>('getDeviceIdentity');
          await _channel.invokeMethod<dynamic>('installGamePackage', {
            'id': game.id,
            'assetPath': game.package.path,
            'sha256': game.hash,
            'deviceKey': key,
          });
        } finally {
          await _channel.invokeMethod<dynamic>('leaveDeviceAccessPoint');
        }
        if (await _device('GINFO ${game.id}') != expected) {
          throw PlatformException(
            code: 'install_unknown',
            message: tr('安装结果未确认，请重新点选检查'),
          );
        }
      }
      _installed.add(game.id);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SwingGamePage(id: game.id, title: game.title),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const AppText('游戏')),
      body: RefreshIndicator(
        onRefresh: () async {
          if (_busy) return;
          setState(() {
            _loading = true;
            _error = null;
            _installed.clear();
          });
          await _load();
        },
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            Wrap(
              spacing: 16,
              runSpacing: 20,
              children: [
                _card(
                  title: 'Flappy Bird',
                  key: const ValueKey('game-card-flappy-bird'),
                  onTap: _busy ? null : widget.onFlyBird,
                  background: const Color(0xff202020),
                  child: Center(
                    child: Image.asset(
                      'assets/fly_bird/bird0_1.png',
                      width: 64,
                      filterQuality: FilterQuality.none,
                    ),
                  ),
                ),
                for (final game in _games)
                  _card(
                    title: game.title,
                    onTap: _busy ? null : () => _open(game),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(game.cover, fit: BoxFit.cover),
                        if (!_installed.contains(game.id))
                          const ColoredBox(color: Color(0x88000000)),
                      ],
                    ),
                  ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    ),
  );
  Widget _card({
    required String title,
    Key? key,
    Color background = const Color(0xff192b3d),
    required Widget child,
    required VoidCallback? onTap,
  }) {
    final width = (MediaQuery.sizeOf(context).width - 56) / 2;
    return SizedBox(
      width: width,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: AspectRatio(
                aspectRatio: 1,
                child: ColoredBox(color: background, child: child),
              ),
            ),
            const SizedBox(height: 10),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
