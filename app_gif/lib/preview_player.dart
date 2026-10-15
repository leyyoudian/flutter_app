import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class FactoryVideoPreview extends StatefulWidget {
  const FactoryVideoPreview({
    super.key,
    required this.currentVideo,
    this.nextVideo,
    required this.active,
    this.looping = false,
    this.onDone,
  });

  final String currentVideo;
  final String? nextVideo;
  final bool active;
  final bool looping;
  final VoidCallback? onDone;

  @override
  State<FactoryVideoPreview> createState() => _FactoryVideoPreviewState();
}

class _FactoryVideoPreviewState extends State<FactoryVideoPreview> {
  _PreviewVideo? _active;
  _PreviewVideo? _pending;
  _PreviewVideo? _retiring;
  bool _syncing = false;
  bool _dirty = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant FactoryVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentVideo == widget.currentVideo &&
        oldWidget.nextVideo == widget.nextVideo &&
        oldWidget.active == widget.active &&
        oldWidget.looping == widget.looping) {
      return;
    }
    if (oldWidget.currentVideo != widget.currentVideo ||
        oldWidget.looping != widget.looping) {
      _done = false;
    }
    // Cancel obsolete warmup before initialization finishes. Its decoder must
    // be released before another one is created.
    final needed = _active?.path == widget.currentVideo
        ? widget.nextVideo
        : widget.currentVideo;
    final pending = _pending;
    if (pending != null && (!widget.active || pending.path != needed)) {
      unawaited(pending.release());
    }
    _schedule();
  }

  void _schedule() {
    _dirty = true;
    if (!_syncing) unawaited(_reconcile());
  }

  Future<void> _dropPending() async {
    final pending = _pending;
    if (pending == null) return;
    await pending.release();
    if (identical(_pending, pending)) _pending = null;
  }

  Future<_PreviewVideo?> _prepare(String path) async {
    if (_pending?.path != path || _pending?.released == true) {
      await _dropPending();
      if (!mounted || !widget.active) return null;
      final needed = _active?.path == widget.currentVideo
          ? widget.nextVideo
          : widget.currentVideo;
      if (path != needed) return null;
      _pending = _PreviewVideo(path);
    }
    final pending = _pending!;
    if (!await pending.ready) {
      await _dropPending();
      return null;
    }
    return pending;
  }

  Future<void> _reconcile() async {
    _syncing = true;
    try {
      do {
        _dirty = false;
        if (!widget.active) {
          await _dropPending();
          await _syncPlayback();
          continue;
        }
        final path = widget.currentVideo;
        if (_active?.path != path) {
          final video = await _prepare(path);
          if (!mounted) return;
          if (video == null) continue;
          if (!widget.active || widget.currentVideo != path || video.released) {
            _dirty = true;
            continue;
          }
          await _adopt(video);
          if (!mounted) return;
        }
        await _syncPlayback();
        if (!mounted) return;
        // Selection may change across any native operation above.
        if (_active?.path != widget.currentVideo || !widget.active) {
          _dirty = true;
          continue;
        }
        final next = widget.nextVideo;
        if (next == null || next == _active?.path) {
          await _dropPending();
        } else {
          await _prepare(next);
        }
      } while (mounted && _dirty);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _adopt(_PreviewVideo video) async {
    final old = _active;
    old?.controller.removeListener(_onUpdate);
    if (old != null) {
      unawaited(old.controller.pause().catchError((_) {}));
    }
    _active = video;
    _pending = null;
    _retiring = old;
    _done = false;
    video.controller.addListener(_onUpdate);
    setState(() {});
    await _syncPlayback();
    // Keep the previous texture until Flutter attaches the replacement, then
    // release it before warming another video: at most two decoders exist.
    await WidgetsBinding.instance.endOfFrame;
    await old?.release();
    if (identical(_retiring, old)) _retiring = null;
  }

  Future<void> _syncPlayback() async {
    final video = _active;
    if (video == null || video.released) return;
    final c = video.controller;
    try {
      await c.setLooping(widget.looping);
      if (!mounted || video.released) return;
      if (widget.active) {
        if (!c.value.isPlaying && (!_done || widget.looping)) await c.play();
      } else {
        await c.pause();
      }
    } catch (_) {
      // Native codecs may reject a handle concurrently released on unmount.
    }
  }

  void _onUpdate() {
    if (widget.looping) return;
    final video = _active;
    if (_done ||
        !widget.active ||
        video == null ||
        video.path != widget.currentVideo ||
        video.released) {
      return;
    }
    final value = video.controller.value;
    if (value.isInitialized &&
        value.duration > Duration.zero &&
        (value.isCompleted || value.position >= value.duration)) {
      _done = true;
      widget.onDone?.call();
    }
  }

  @override
  void deactivate() {
    final c = _active?.controller;
    if (c != null && c.value.isInitialized) unawaited(c.pause());
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _schedule();
  }

  @override
  void dispose() {
    _active?.controller.removeListener(_onUpdate);
    unawaited(_active?.release());
    unawaited(_pending?.release());
    unawaited(_retiring?.release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _active?.controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.expand();
    return RepaintBoundary(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: c.value.size.width,
          height: c.value.size.height,
          child: VideoPlayer(c),
        ),
      ),
    );
  }
}

/// Owns one native decoder, including initialization and cancellation.
/// video_player's initialize future can remain pending after disposal cancels
/// its event subscription, so release must also unblock readiness explicitly.
class _PreviewVideo {
  _PreviewVideo(this.path) : controller = _factoryVideoController(path) {
    ready = Future.any([_initialize(), _cancelled.future]);
  }

  final String path;
  final VideoPlayerController controller;
  final _cancelled = Completer<bool>();
  late final Future<bool> ready;
  Future<void>? _disposal;
  bool get released => _disposal != null;

  Future<bool> _initialize() async {
    try {
      await controller.initialize();
      if (released) return false;
      await controller.setVolume(0);
      return !released;
    } catch (_) {
      return false;
    }
  }

  Future<void> release() {
    if (_disposal != null) return _disposal!;
    _cancelled.complete(false);
    return _disposal = controller.dispose().catchError((_) {});
  }
}

VideoPlayerController _factoryVideoController(String path) {
  if (path.startsWith('file://') ||
      path.startsWith('/') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) {
    return VideoPlayerController.file(
      (path.startsWith('file://')
          ? File(Uri.parse(path).toFilePath())
          : File(path)),
    );
  }
  return VideoPlayerController.asset(path);
}
