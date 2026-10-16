import 'package:app_gif/interaction_feedback.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('esp_baji/native');
  final fallback = <Object?>[];
  setUp(() {
    fallback.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          fallback.add(call.arguments);
        }
        return null;
      },
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  test(
    'strong platform feedback is requested once with no duplicate system pulse',
    () async {
      var calls = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        expect(call.method, 'interactionHaptic');
        calls++;
        return true;
      });
      await strongInteractionFeedback();
      expect(calls, 1);
      expect(fallback, isEmpty);
    },
  );
  test(
    'older bridge and failed platform effect use heavy system feedback',
    () async {
      for (final error in [
        MissingPluginException(),
        PlatformException(code: 'unavailable'),
      ]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          native,
          (_) async => throw error,
        );
        await strongInteractionFeedback();
      }
      expect(fallback, [
        'HapticFeedbackType.heavyImpact',
        'HapticFeedbackType.heavyImpact',
      ]);
    },
  );
}
