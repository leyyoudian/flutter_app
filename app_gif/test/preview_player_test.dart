import 'dart:async';

import 'package:app_gif/preview_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
// The fake exercises real controller initialization, playback and disposal.
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final paths = <int, String>{};
  final live = <int>{};
  final played = <int>[];
  final disposed = <int>[];
  final heldDisposals = <int, Completer<void>>{};
  int maxLive = 0;
  int _nextId = 0;

  @override
  Future<void> init() async {}

  int id(String path) => paths.entries.lastWhere((e) => e.value == path).key;
  void ready(String path) => streams[id(path)]!.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 10),
      size: const Size(480, 480),
    ),
  );

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    streams[id] = StreamController<VideoEvent>();
    paths[id] = options.dataSource.asset ?? options.dataSource.uri!;
    live.add(id);
    if (live.length > maxLive) maxLive = live.length;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await heldDisposals[playerId]?.future;
    live.remove(playerId);
  }

  @override
  Future<void> play(int playerId) async => played.add(playerId);
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildView(int playerId) => Texture(textureId: playerId);
}

Widget _preview(
  String current, {
  String? next,
  bool active = true,
  VoidCallback? onDone,
}) => MaterialApp(
  home: SizedBox(
    width: 284,
    height: 284,
    child: FactoryVideoPreview(
      currentVideo: current,
      nextVideo: next,
      active: active,
      onDone: onDone,
    ),
  ),
);

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

void main() {
  late _VideoPlatform platform;
  setUp(() {
    platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  testWidgets('switch into an initializing preload reuses its decoder', (
    tester,
  ) async {
    await tester.pumpWidget(_preview('A', next: 'B'));
    platform.ready('A');
    await _flush(tester);
    final pending = platform.id('B');
    await tester.pumpWidget(_preview('B', next: 'C'));
    await _flush(tester);
    expect(platform.paths.values.where((p) => p == 'B'), hasLength(1));
    platform.ready('B');
    await _flush(tester);
    expect(
      tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller.playerId,
      pending,
    );
    expect(platform.maxLive, lessThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(platform.live, isEmpty);
  });

  testWidgets('rapid selection discards stale loads and keeps two decoders', (
    tester,
  ) async {
    await tester.pumpWidget(_preview('A', next: 'B'));
    platform.ready('A');
    await _flush(tester);
    await tester.pumpWidget(_preview('C', next: 'D'));
    await _flush(tester);
    platform.ready('C');
    await _flush(tester);
    expect(
      tester
          .widget<VideoPlayer>(find.byType(VideoPlayer))
          .controller
          .dataSource,
      'C',
    );
    expect(platform.maxLive, lessThanOrEqualTo(2));
    expect(platform.disposed, contains(platform.id('B')));
    expect(platform.played, isNot(contains(platform.id('B'))));
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(platform.live, isEmpty);
  });

  testWidgets('unmount releases controllers still initializing', (
    tester,
  ) async {
    await tester.pumpWidget(_preview('A', next: 'B'));
    await _flush(tester);
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(platform.live, isEmpty);
  });

  testWidgets('unrelated rebuild does not replay a completed entrance', (
    tester,
  ) async {
    await tester.pumpWidget(_preview('A'));
    platform.ready('A');
    await _flush(tester);
    final controller = tester
        .widget<VideoPlayer>(find.byType(VideoPlayer))
        .controller;
    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 10),
      isCompleted: true,
      isPlaying: false,
    );
    final playCount = platform.played.length;
    await tester.pumpWidget(_preview('A', onDone: () {}));
    await _flush(tester);
    expect(platform.played.length, playCount);
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
  });

  testWidgets('latest selection wins while native disposal is pending', (
    tester,
  ) async {
    await tester.pumpWidget(_preview('A', next: 'B'));
    platform.ready('A');
    await _flush(tester);
    final gate = Completer<void>();
    platform.heldDisposals[platform.id('B')] = gate;
    await tester.pumpWidget(_preview('C', next: 'D'));
    await _flush(tester);
    expect(platform.paths.values, isNot(contains('C')));
    await tester.pumpWidget(_preview('E', next: 'F'));
    gate.complete();
    await _flush(tester);
    expect(platform.paths.values, isNot(contains('C')));
    platform.ready('E');
    await _flush(tester);
    expect(
      tester
          .widget<VideoPlayer>(find.byType(VideoPlayer))
          .controller
          .dataSource,
      'E',
    );
    expect(platform.maxLive, lessThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(platform.live, isEmpty);
  });

  testWidgets(
    'inactive preview cancels warmup and resumes its current player',
    (tester) async {
      await tester.pumpWidget(_preview('A', next: 'B'));
      platform.ready('A');
      await _flush(tester);
      await tester.pumpWidget(_preview('A', next: 'B', active: false));
      await _flush(tester);
      expect(platform.live, {platform.id('A')});
      expect(
        tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller
            .value
            .isPlaying,
        isFalse,
      );
      await tester.pumpWidget(_preview('A', next: 'B'));
      await _flush(tester);
      expect(platform.paths.values.where((p) => p == 'A'), hasLength(1));
      expect(
        tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller
            .value
            .isPlaying,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await _flush(tester);
    },
  );

  testWidgets('completion keeps final frames and ignores the outgoing player', (
    tester,
  ) async {
    var completed = 0;
    await tester.pumpWidget(_preview('A', onDone: () => completed++));
    platform.ready('A');
    await _flush(tester);
    final controller = tester
        .widget<VideoPlayer>(find.byType(VideoPlayer))
        .controller;
    controller.value = controller.value.copyWith(
      position: const Duration(milliseconds: 9950),
    );
    expect(completed, 0);
    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 10),
    );
    expect(completed, 1);
    await tester.pumpWidget(_preview('B', onDone: () => completed++));
    controller.value = controller.value.copyWith(isCompleted: true);
    expect(completed, 1);
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
  });

  testWidgets(
    'failed preload keeps current frame and allows a later selection',
    (tester) async {
      await tester.pumpWidget(_preview('A', next: 'B'));
      platform.ready('A');
      await _flush(tester);
      platform.streams[platform.id('B')]!.addError(
        PlatformException(code: 'codec', message: 'unsupported video'),
      );
      await _flush(tester);
      expect(
        tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller
            .dataSource,
        'A',
      );
      await tester.pumpWidget(_preview('C'));
      await _flush(tester);
      platform.ready('C');
      await _flush(tester);
      expect(
        tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller
            .dataSource,
        'C',
      );
      expect(platform.maxLive, lessThanOrEqualTo(2));
      await tester.pumpWidget(const SizedBox());
      await _flush(tester);
    },
  );
}
