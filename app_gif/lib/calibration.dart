import 'app_language.dart';
import 'reference_ui.dart';
import 'interaction_feedback.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

int normalizeAngleTenths(int value) {
  var normalized = value % 3600;
  if (normalized > 1800) {
    normalized -= 3600;
  } else if (normalized < -1800) {
    normalized += 3600;
  }
  return normalized;
}

class CalibrationSnapshot {
  const CalibrationSnapshot({required this.angleTenths, required this.active});

  factory CalibrationSnapshot.fromMap(Map<Object?, Object?> map) {
    final rawAngle = map['angleTenths'];
    return CalibrationSnapshot(
      angleTenths: normalizeAngleTenths(
        rawAngle is num ? rawAngle.round() : int.tryParse('$rawAngle') ?? 0,
      ),
      active: map['active'] == true,
    );
  }

  final int angleTenths;
  final bool active;
}

typedef EnterCalibration = Future<CalibrationSnapshot> Function();
typedef UpdateCalibration = Future<void> Function(int angleTenths);
typedef CancelCalibration = Future<void> Function();

class AlignmentPage extends StatefulWidget {
  const AlignmentPage({
    super.key,
    required this.connected,
    required this.enter,
    required this.preview,
    required this.save,
    required this.cancel,
  });

  final bool connected;
  final EnterCalibration enter;
  final UpdateCalibration preview;
  final UpdateCalibration save;
  final CancelCalibration cancel;

  @override
  State<AlignmentPage> createState() => _AlignmentPageState();
}

class _AlignmentPageState extends State<AlignmentPage> {
  Timer? _previewTimer;
  Future<void>? _previewInFlight;
  int? _queuedPreview;
  DateTime _lastHaptic = DateTime.fromMillisecondsSinceEpoch(0);
  int _angleTenths = 0;
  bool _loading = true;
  bool _saving = false;
  bool _entered = false;
  bool _completed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_enter());
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    if (_entered && !_completed) {
      unawaited(widget.cancel());
    }
    super.dispose();
  }

  Future<void> _enter() async {
    if (!widget.connected) {
      setState(() {
        _loading = false;
        _error = null;
        _entered = false;
      });
      return;
    }
    try {
      final snapshot = await widget.enter();
      if (!mounted) {
        await widget.cancel();
        return;
      }
      setState(() {
        _angleTenths = snapshot.angleTenths;
        _entered = true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  void _setAngle(int value) {
    if (_loading || _saving || _error != null) return;
    final normalized = normalizeAngleTenths(value);
    if (normalized == _angleTenths) return;
    final now = DateTime.now();
    if (now.difference(_lastHaptic).inMilliseconds >= 80) {
      _lastHaptic = now;
      unawaited(strongInteractionFeedback());
    }
    setState(() => _angleTenths = normalized);
    if (!_entered) return; // Offline wheel is a preview, never a device write.
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 55), () {
      unawaited(_sendPreview(normalized));
    });
  }

  Future<void> _sendPreview(int value) async {
    _queuedPreview = value;
    if (_previewInFlight != null) return;
    final operation = _drainPreviews();
    _previewInFlight = operation;
    await operation;
    _previewInFlight = null;
  }

  Future<void> _drainPreviews() async {
    while (_queuedPreview != null && !_completed) {
      final value = _queuedPreview!;
      _queuedPreview = null;
      try {
        await widget.preview(value);
      } catch (error) {
        if (mounted) setState(() => _error = '$error');
      }
    }
  }

  Future<void> _save() async {
    if (_loading || _saving || !_entered) return;
    _previewTimer?.cancel();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _queuedPreview = null;
      await _previewInFlight;
      await widget.save(_angleTenths);
      unawaited(HapticFeedback.mediumImpact());
      _completed = true;
      if (mounted) {
        setState(() => _saving = false);
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$error';
      });
    }
  }

  Future<bool> _leave() async {
    _previewTimer?.cancel();
    _queuedPreview = null;
    await _previewInFlight;
    if (_entered && !_completed) {
      _completed = true;
      await widget.cancel();
    }
    return true;
  }

  String get _angleLabel => '${(_angleTenths / 10).toStringAsFixed(1)}°';

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: _completed || !_entered,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _leave();
        if (context.mounted) Navigator.of(context).pop(result);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: referenceDetailAppBar(
          '安装角度校正',
          backKey: const ValueKey('alignment-back'),
          onBack: () async {
            await _leave();
            if (context.mounted) Navigator.of(context).maybePop();
          },
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) => FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: constraints.maxWidth,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppText(
                        '设备',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.64),
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xff202020),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.06),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  const AppText(
                                    '角度校正',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const Spacer(),
                                  AppText(
                                    _angleLabel,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              if (_loading)
                                const SizedBox.square(
                                  dimension: 260,
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              else
                                KeyedSubtree(
                                  key: const ValueKey('alignment-dial'),
                                  child: _AlignmentDial(
                                    angleTenths: _angleTenths,
                                    enabled: _error == null && !_saving,
                                    onChanged: _setAngle,
                                  ),
                                ),
                              const SizedBox(height: 20),
                              Row(
                                children: [
                                  Expanded(
                                    child: _StepButton(
                                      key: const ValueKey(
                                        'alignment-minus-step',
                                      ),
                                      icon: Icons.arrow_back_rounded,
                                      label: '0.1°',
                                      onPressed: _loading || _saving
                                          ? null
                                          : () => _setAngle(_angleTenths - 1),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _StepButton(
                                      key: const ValueKey('alignment-reset'),
                                      icon: Icons.refresh_rounded,
                                      label: '归零',
                                      onPressed: _loading || _saving
                                          ? null
                                          : () => _setAngle(0),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _StepButton(
                                      key: const ValueKey(
                                        'alignment-plus-step',
                                      ),
                                      icon: Icons.arrow_forward_rounded,
                                      label: '0.1°',
                                      iconAfter: true,
                                      onPressed: _loading || _saving
                                          ? null
                                          : () => _setAngle(_angleTenths + 1),
                                    ),
                                  ),
                                ],
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: 14),
                                AppText(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Color(0xffff6b6b),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 52,
                        child: FilledButton.icon(
                          key: const ValueKey('alignment-save'),
                          onPressed:
                              _loading || _saving || _error != null || !_entered
                              ? null
                              : _save,
                          icon: _saving
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.check_rounded),
                          label: AppText(_saving ? '保存中' : '保存校正'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.iconAfter = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool iconAfter;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Icon(icon, size: 20),
      const SizedBox(width: 5),
      Flexible(
        child: AppText(
          label,
          maxLines: 1,
          overflow: TextOverflow.fade,
          softWrap: false,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    ];
    return SizedBox(
      height: 54,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xff111111),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xff111111),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: iconAfter ? children.reversed.toList() : children,
        ),
      ),
    );
  }
}

class _AlignmentDial extends StatelessWidget {
  const _AlignmentDial({
    required this.angleTenths,
    required this.enabled,
    required this.onChanged,
  });

  final int angleTenths;
  final bool enabled;
  final ValueChanged<int> onChanged;

  void _update(Offset localPosition, Size size) {
    if (!enabled) return;
    final center = Offset(size.width / 2, size.height / 2);
    final delta = localPosition - center;
    if (delta.distance < 12) return;
    final radians = math.atan2(delta.dx, -delta.dy);
    onChanged(normalizeAngleTenths((radians * 1800 / math.pi).round()));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(280.0, constraints.maxWidth);
        final size = Size.square(side);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _update(details.localPosition, size),
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (details) => _update(details.localPosition, size),
          onPanUpdate: (details) => _update(details.localPosition, size),
          child: SizedBox.square(
            dimension: side,
            child: CustomPaint(
              painter: _AlignmentDialPainter(angleTenths),
              child: Center(
                child: AppText(
                  '${(angleTenths / 10).toStringAsFixed(1)}°',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AlignmentDialPainter extends CustomPainter {
  const _AlignmentDialPainter(this.angleTenths);

  final int angleTenths;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) * 0.43;
    final tickPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2;
    for (var index = 0; index < 120; index++) {
      final angle = index * math.pi * 2 / 120 - math.pi / 2;
      final major = index % 10 == 0;
      tickPaint.color = Colors.white.withValues(alpha: major ? 0.34 : 0.11);
      final outer = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      final inner =
          center +
          Offset(math.cos(angle), math.sin(angle)) *
              (radius - (major ? 11 : 6));
      canvas.drawLine(inner, outer, tickPaint);
    }

    final angle = angleTenths * math.pi / 1800 - math.pi / 2;
    final handEnd =
        center + Offset(math.cos(angle), math.sin(angle)) * (radius * 0.58);
    final handPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, handEnd, handPaint);
    canvas.drawCircle(handEnd, 7, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _AlignmentDialPainter oldDelegate) =>
      oldDelegate.angleTenths != angleTenths;
}
