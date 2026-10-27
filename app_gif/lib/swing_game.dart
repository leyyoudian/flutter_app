import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_language.dart';
import 'interaction_feedback.dart';

class SwingGamePage extends StatefulWidget {
  const SwingGamePage({super.key, required this.id, required this.title});
  final String id, title;
  @override
  State<SwingGamePage> createState() => _SwingGamePageState();
}

class _SwingGamePageState extends State<SwingGamePage>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('esp_baji/native');
  Timer? _timer;
  Future<void>? _inputOperation;
  int _session = 0, _seq = 0, _swing = 0, _failures = 0;
  double _x = 0, _y = 0, _roll = 0;
  bool _pose2 = false;
  bool _busy = true,
      _paused = false,
      _closing = false,
      _motion = false,
      _touching = false,
      _background = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  String _message(Object error) => error is PlatformException
      ? error.message ?? error.code
      : error.toString();
  Future<String> _device(String command) async =>
      (await _channel.invokeMethod<String>('deviceBluetoothCommand', {
        'command': command,
      }))?.trim() ??
      '';
  Future<void> _start() async {
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'ensureGameBluetooth',
      );
      _pose2 = RegExp(
        r'(^|\s)pose=2($|\s)',
      ).hasMatch(info?['status']?.toString() ?? '');
      final response = await _device('GRUN ${widget.id}');
      final match = RegExp(
        r'^OK RUN [a-z0-9_]+ ([0-9]+)$',
      ).firstMatch(response);
      if (match == null) throw StateError('Game start was not confirmed');
      _session = int.parse(match[1]!);
      if (!mounted || _closing || _background) {
        await _channel.invokeMethod<dynamic>('gameCommand', {'action': 'stop'});
        return;
      }
      await _sensors();
      _beginInput();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sensors() async {
    try {
      _motion = await _channel.invokeMethod<bool>('startSwingMotion') ?? false;
    } on MissingPluginException {
      _motion = false;
    }
  }

  void _beginInput() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
  }

  void _tick() {
    if (_inputOperation != null || _paused || _closing || _session == 0) return;
    _inputOperation = _input().whenComplete(() => _inputOperation = null);
  }

  Future<void> _input() async {
    try {
      if (_motion) {
        final sample = await _channel.invokeMapMethod<String, dynamic>(
          'readSwingMotion',
        );
        if (!_touching) {
          _x = (sample?['x'] as num? ?? 0).toDouble().clamp(-1, 1);
          _y = (sample?['y'] as num? ?? 0).toDouble().clamp(-1, 1);
          _roll = (sample?['roll'] as num? ?? 0).toDouble().clamp(-1, 1);
        }
        final pulse = (sample?['swing'] as num? ?? 0).toInt();
        if (pulse != 0) _swing = pulse;
      }
      if (_paused || _closing) return;
      final pulse = _swing;
      _swing = 0;
      final response = await _device(
        'GI $_session,${++_seq},${(_x * 1000).round()},$pulse${_pose2 ? ',${(_y * 1000).round()},${(_roll * 1000).round()}' : ''}',
      );
      if (response != 'OK INPUT') throw StateError('Input was not confirmed');
      _failures = 0;
      if (pulse != 0) unawaited(strongInteractionFeedback());
      if (mounted) setState(() {});
    } catch (error) {
      if (++_failures >= 3) {
        _timer?.cancel();
        _paused = true;
        await _stopSensors();
        // The board also pauses independently after 1.5 s without input.
        if (mounted) setState(() => _error = _message(error));
      }
    }
  }

  Future<void> _stopSensors() async {
    try {
      await _channel.invokeMethod<dynamic>('stopSwingMotion');
    } on MissingPluginException {
      /* Touch remains supported. */
    }
  }

  Future<void> _pause() async {
    _paused = true;
    _timer?.cancel();
    _swing = 0;
    if (mounted) setState(() {});
    await _inputOperation;
    await _stopSensors();
    try {
      await _channel.invokeMethod<dynamic>('gameCommand', {'action': 'pause'});
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _resume() async {
    if (_busy || _background) return;
    setState(() => _busy = true);
    try {
      await _channel.invokeMethod<dynamic>('gameCommand', {'action': 'resume'});
      await _sensors();
      _swing = 0;
      _paused = false;
      _error = null;
      _failures = 0;
      _beginInput();
    } catch (error) {
      _error = _message(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = state != AppLifecycleState.resumed;
    if (_background && _session != 0) unawaited(_pause());
  }

  Future<void> _back() async {
    if (_closing || _busy) return;
    _closing = true;
    _timer?.cancel();
    await _inputOperation;
    await _stopSensors();
    try {
      await _channel.invokeMethod<dynamic>('gameCommand', {'action': 'stop'});
    } catch (error) {
      _closing = false;
      _paused = true;
      if (mounted) setState(() => _error = _message(error));
      return;
    }
    if (mounted) {
      setState(() => _session = 0);
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _closing = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopSensors());
    if (_session != 0) {
      unawaited(
        _channel
            .invokeMethod<dynamic>('gameCommand', {'action': 'stop'})
            .catchError((Object _) => null),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _session == 0 && !_busy,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_back());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(
          onPressed: _back,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
            if (_busy) const CircularProgressIndicator(),
            AppText(
              _motion ? '以当前握姿归中，转向和前后俯仰移动球拍，向前挥手机击球' : '在触控区二维移动球拍，点击挥拍或发球',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 30),
            LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                onPanStart: (details) {
                  _touching = true;
                  setState(() {
                    _x =
                        (details.localPosition.dx / constraints.maxWidth * 2 -
                                1)
                            .clamp(-1, 1);
                    _y = (details.localPosition.dy / 240 * 2 - 1).clamp(-1, 1);
                  });
                },
                onPanUpdate: (details) {
                  setState(() {
                    _x =
                        (details.localPosition.dx / constraints.maxWidth * 2 -
                                1)
                            .clamp(-1, 1);
                    _y = (details.localPosition.dy / 240 * 2 - 1).clamp(-1, 1);
                  });
                },
                onPanEnd: (_) => _touching = false,
                onPanCancel: () => _touching = false,
                onTap: () {
                  if (!_paused && !_busy) _swing = 650;
                },
                child: Container(
                  height: 240,
                  decoration: BoxDecoration(
                    color: const Color(0xff152530),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _PaddleGuide(_x, _pose2 ? _y : 0, _roll),
                        ),
                      ),
                      const Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: EdgeInsets.all(14),
                          child: AppText(
                            '挥拍 / 发球',
                            style: TextStyle(color: Colors.white60),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          try {
                            await _channel.invokeMethod<dynamic>(
                              'calibrateSwingMotion',
                            );
                          } on MissingPluginException {
                            /* Touch mode. */
                          }
                        },
                  child: const AppText('校准握持位置'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _paused ? _resume() : _pause(),
                  child: AppText(_paused ? '继续' : '暂停'),
                ),
              ],
            ),
            const Spacer(),
          ],
        ),
      ),
    ),
  );
}

class _PaddleGuide extends CustomPainter {
  _PaddleGuide(this.x, this.y, this.roll);
  final double x, y, roll;
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0xff35505d)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 2, 16),
      Offset(size.width / 2, size.height - 40),
      line,
    );
    canvas.drawLine(
      Offset(16, size.height / 2),
      Offset(size.width - 16, size.height / 2),
      line,
    );
    canvas.save();
    canvas.translate(size.width / 2 + x * (size.width / 2 - 40), 108 + y * 65);
    canvas.rotate(roll * .7);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-6, 18, 12, 40),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xffe1ae6f),
    );
    canvas.drawOval(
      const Rect.fromLTWH(-28, -28, 56, 62),
      Paint()..color = const Color(0xff101b20),
    );
    canvas.drawOval(
      const Rect.fromLTWH(-25, -25, 50, 56),
      Paint()..color = const Color(0xffed5479),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PaddleGuide old) =>
      old.x != x || old.y != y || old.roll != roll;
}
