import 'package:app_gif/reference_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

class _ThumbProbe extends RoundSliderThumbShape {
  double? paintedValue;
  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    paintedValue = value;
  }
}

void main() {
  testWidgets(
    'brightness changes pulse with throttling and unchanged values stay quiet',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
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
          home: ReferenceBrightnessPage(
            initialValue: 70,
            connected: true,
            onChanged: (_) {},
          ),
        ),
      );
      void change(double value) =>
          tester.widget<Slider>(find.byType(Slider)).onChanged!(value);
      change(71);
      await tester.pump();
      change(71.2);
      await tester.pump();
      expect(
        calls.where((c) => c.method == 'HapticFeedback.vibrate'),
        hasLength(1),
      );
      change(72);
      await tester.pump();
      expect(
        calls.where((c) => c.method == 'HapticFeedback.vibrate'),
        hasLength(1),
      );
      await tester.pump(const Duration(milliseconds: 85));
      change(73);
      await tester.pump();
      expect(
        calls.where((c) => c.method == 'HapticFeedback.vibrate'),
        hasLength(2),
      );
    },
  );
  testWidgets(
    'brightness thumb reaches the new value in the same frame in both directions',
    (tester) async {
      final probe = _ThumbProbe();
      final sent = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(sliderTheme: SliderThemeData(thumbShape: probe)),
          home: ReferenceBrightnessPage(
            initialValue: 70,
            connected: true,
            onChanged: sent.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final value in [20.25, 84.75, 0.0, 100.0]) {
        tester.widget<Slider>(find.byType(Slider)).onChanged!(value);
        await tester.pump();
        expect(probe.paintedValue, closeTo(value / 100, .0001));
        expect(sent.last, value.round());
      }
    },
  );
}
