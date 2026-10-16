import 'package:flutter/services.dart';

/// Strong feedback shared by angle adjustment and game controls.
Future<void> strongInteractionFeedback() async {
  try {
    final handled = await const MethodChannel(
      'esp_baji/native',
    ).invokeMethod<bool>('interactionHaptic');
    if (handled == true) return;
  } on MissingPluginException {
    // Older hosts use the system effect.
  } on PlatformException {
    // Feedback failures must not interrupt controls.
  }
  await HapticFeedback.heavyImpact();
}
