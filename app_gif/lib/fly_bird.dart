import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_language.dart';
import 'reference_ui.dart';

/// The P4 renders the game; this page is only its Bluetooth controller.
class FlyBirdPage extends StatefulWidget {
  const FlyBirdPage({super.key, this.retainConnection = false});
  final bool retainConnection;
  @override
  State<FlyBirdPage> createState() => _FlyBirdPageState();
}

class _FlyBirdPageState extends State<FlyBirdPage> {
  static const _channel = MethodChannel('esp_baji/native');
  bool _connected = false, _busy = true, _running = false, _flapPending = false;
  bool _starting = false;
  Future<void>? _flapOperation;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  String _message(Object error) => error is PlatformException
      ? error.message ?? '蓝牙连接失败，请重试'
      : error is MissingPluginException
      ? '当前安装版本不支持蓝牙控制，请安装最新版本'
      : '蓝牙连接失败，请重试';

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'ensureGameBluetooth',
      );
      if (result?['connected'] != true) throw StateError('Bluetooth not ready');
      if (!mounted) return;
      setState(() {
        _connected = true;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _connected = false;
          _error = _message(error);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _send(String action) async {
    try {
      final accepted = await _channel.invokeMethod<bool>('sendGameControl', {
        'action': action,
      });
      if (accepted != true) {
        if (mounted) setState(() => _error = '设备未接受指令，请检查 SD 卡游戏文件或重新连接蓝牙');
        return false;
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _message(error);
          if (error is PlatformException &&
              error.code == 'bluetooth_disconnected') {
            _connected = false;
            _running = false;
          }
        });
      }
      return false;
    }
  }

  Future<void> _start() async {
    if (_busy || !_connected) return;
    setState(() {
      _busy = true;
      _starting = true;
      _error = null;
    });
    final accepted = await _send('start');
    if (mounted) {
      setState(() {
        _busy = false;
        _starting = false;
        _running = accepted;
      });
    }
    if (accepted) unawaited(HapticFeedback.mediumImpact());
  }

  Future<void> _flap() async {
    if (!_running || _busy || _flapPending) return;
    _flapPending = true;
    unawaited(HapticFeedback.lightImpact());
    _flapOperation = _send('flap').then((_) {});
    try {
      await _flapOperation;
    } finally {
      _flapPending = false;
      _flapOperation = null;
    }
  }

  Future<bool> _stop() async {
    if (!_running) return true;
    if (_busy) return false;
    setState(() => _busy = true);
    await _flapOperation;
    final accepted = !_connected || await _send('stop');
    if (mounted) {
      setState(() {
        _busy = false;
        if (accepted) _running = false;
      });
    }
    return accepted;
  }

  Future<void> _back() async {
    if (_starting) return;
    if (await _stop() && mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    // Closing BLE also cancels a start that was still loading when an external
    // route change removed this page; the firmware releases game ownership.
    unawaited(
      _channel
          .invokeMethod<dynamic>(
            widget.retainConnection
                ? 'sendGameControl'
                : 'releaseGameBluetooth',
            widget.retainConnection ? {'action': 'stop'} : null,
          )
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running && !_starting,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_back());
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      appBar: referenceDetailAppBar('Flappy Bird', onBack: _back),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            children: [
              if (_error != null)
                Padding(
                  key: const ValueKey('game-connection-error'),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: AppText(
                    _error!,
                    style: const TextStyle(
                      color: Color(0xffff8e8e),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              if (!_connected && !_busy)
                TextButton(onPressed: _connect, child: const AppText('重新连接')),
              Expanded(child: _running ? _touchpad() : _welcome()),
              const SizedBox(height: 18),
              if (_running)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('game-stop'),
                    onPressed: _busy ? null : _stop,
                    icon: const Icon(Icons.stop_rounded, size: 20),
                    label: const AppText('结束游戏'),
                    style: _buttonStyle().copyWith(
                      backgroundColor: const WidgetStatePropertyAll(
                        Color(0xff352022),
                      ),
                      foregroundColor: const WidgetStatePropertyAll(
                        Color(0xffffb4b4),
                      ),
                    ),
                  ),
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('game-start'),
                    onPressed: _connected && !_busy ? _start : null,
                    style: _buttonStyle().copyWith(
                      backgroundColor: const WidgetStatePropertyAll(
                        Colors.white,
                      ),
                      foregroundColor: const WidgetStatePropertyAll(
                        Colors.black,
                      ),
                    ),
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const AppText('开始游戏'),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  ButtonStyle _buttonStyle() => OutlinedButton.styleFrom(
    minimumSize: const Size(0, 54),
    foregroundColor: Colors.white,
    side: const BorderSide(color: Color(0xff333333)),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  );

  Widget _welcome() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/fly_bird/bird0_1.png',
          width: 90,
          filterQuality: FilterQuality.none,
        ),
      ],
    ),
  );

  Widget _touchpad() => GestureDetector(
    key: const ValueKey('game-touchpad'),
    behavior: HitTestBehavior.opaque,
    onTapDown: (_) => unawaited(_flap()),
    child: Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xff171717),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xff242424),
                  ),
                  child: const Icon(
                    Icons.touch_app_outlined,
                    size: 48,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 28),
                const AppText(
                  '轻点起飞',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: AppText(
              '碰撞后再点一次即可重新开始',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: referenceMuted,
                height: 1.7,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class GamesPage extends StatelessWidget {
  const GamesPage({super.key, required this.onFlyBird});
  final VoidCallback onFlyBird;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: referenceDetailAppBar('游戏'),
    body: GridView.extent(
      maxCrossAxisExtent: 220,
      padding: const EdgeInsets.all(20),
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      children: [
        Card(
          color: const Color(0xff202020),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('game-card-flappy-bird'),
            onTap: onFlyBird,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/fly_bird/bird0_1.png',
                  width: 64,
                  filterQuality: FilterQuality.none,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Flappy Bird',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
