import 'dart:async';

import 'package:app_gif/calibration.dart';
import 'package:app_gif/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const native = MethodChannel('esp_baji/native');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LanguageSettings.current.value = AppLanguage.chinese;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      native,
      (_) async => false,
    );
  });
  tearDown(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null),
  );
  test('alignment angle wraps to one physical revolution', () {
    expect(normalizeAngleTenths(0), 0);
    expect(normalizeAngleTenths(1800), 1800);
    expect(normalizeAngleTenths(1801), -1799);
    expect(normalizeAngleTenths(-1801), 1799);
    expect(normalizeAngleTenths(7212), 12);
  });

  test('calibration snapshot reads the device response', () {
    final snapshot = CalibrationSnapshot.fromMap(<String, Object?>{
      'angleTenths': -1465,
      'active': true,
    });

    expect(snapshot.angleTenths, -1465);
    expect(snapshot.active, isTrue);
  });

  testWidgets('offline alignment remains interactive without device writes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 950));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deviceCalls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AlignmentPage(
          connected: false,
          enter: () async {
            deviceCalls.add('enter');
            return const CalibrationSnapshot(angleTenths: 0, active: true);
          },
          preview: (_) async => deviceCalls.add('preview'),
          save: (_) async => deviceCalls.add('save'),
          cancel: () async => deviceCalls.add('cancel'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('alignment-dial')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('alignment-plus-step')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('0.1°'), findsWidgets);
    final save = tester.widget<FilledButton>(
      find.byKey(const ValueKey('alignment-save')),
    );
    expect(save.onPressed, isNull);
    expect(deviceCalls, isEmpty);
  });

  testWidgets('alignment page previews steps and saves the selected angle', (
    tester,
  ) async {
    final previews = <int>[];
    int? saved;
    var cancelled = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AlignmentPage(
          connected: true,
          enter: () async =>
              const CalibrationSnapshot(angleTenths: 0, active: true),
          preview: (value) async => previews.add(value),
          save: (value) async => saved = value,
          cancel: () async => cancelled = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('安装角度校正'), findsOneWidget);
    expect(find.text('0.0°'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('alignment-plus-step')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(previews, contains(1));
    expect(find.text('0.1°'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('alignment-save')));
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(cancelled, isFalse);
  });

  testWidgets('leaving alignment without saving restores the device value', (
    tester,
  ) async {
    var cancelled = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: AlignmentPage(
          connected: true,
          enter: () async =>
              const CalibrationSnapshot(angleTenths: 100, active: true),
          preview: (_) async {},
          save: (_) async {},
          cancel: () async => cancelled = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('alignment-back')));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
  });

  testWidgets('preview requests coalesce and save waits for the last preview', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 950));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final firstPreview = Completer<void>();
    final calls = <String>[];
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AlignmentPage(
          connected: true,
          enter: () async =>
              const CalibrationSnapshot(angleTenths: 0, active: true),
          preview: (angle) async {
            calls.add('preview:$angle');
            if (angle == 1) await firstPreview.future;
          },
          save: (angle) async => calls.add('save:$angle'),
          cancel: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final step = find.byKey(const ValueKey('alignment-plus-step'));
    await tester.tap(step);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(step);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(step);
    await tester.pump(const Duration(milliseconds: 80));
    expect(calls, ['preview:1']);
    await tester.pumpAndSettle();
    expect(haptics, contains('HapticFeedbackType.heavyImpact'));
    firstPreview.complete();
    await tester.pumpAndSettle();
    expect(calls, ['preview:1', 'preview:3']);
    await tester.tap(find.byKey(const ValueKey('alignment-save')));
    await tester.pumpAndSettle();
    expect(calls.last, 'save:3');
  });

  testWidgets('dial accepts taps away from the pointer and page stays fixed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: AlignmentPage(
          connected: false,
          enter: () async =>
              const CalibrationSnapshot(angleTenths: 0, active: true),
          preview: (_) async {},
          save: (_) async {},
          cancel: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Scrollable), findsNothing);
    final dial = find.byKey(const ValueKey('alignment-dial'));
    final bounds = tester.getRect(dial);
    await tester.tapAt(bounds.center + Offset(bounds.width * .35, 0));
    await tester.pumpAndSettle();
    expect(find.text('90.0°'), findsWidgets);
    final save = tester.getRect(find.byKey(const ValueKey('alignment-save')));
    await tester.dragFrom(Offset(24, bounds.top - 8), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(tester.getRect(dial), bounds);
    expect(tester.getRect(find.byKey(const ValueKey('alignment-save'))), save);
    expect(tester.takeException(), isNull);
  });
}
