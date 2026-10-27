import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_gif/startup_logo_splash.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'launch logos have sufficient pixels for high density displays',
    () async {
      for (final path in [
        'assets/brand/dotloop_app_icon.png',
        'android/app/src/main/res/drawable/splash_logo.png',
        'ios/Runner/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.png',
      ]) {
        final codec = await ui.instantiateImageCodec(
          await File(path).readAsBytes(),
        );
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThanOrEqualTo(624), reason: path);
        expect(frame.image.height, greaterThanOrEqualTo(624), reason: path);
        frame.image.dispose();
        codec.dispose();
      }
    },
  );

  test('Android and iOS native launch screens use the logo on black', () async {
    final androidLegacy = await File(
      'android/app/src/main/res/drawable/launch_background.xml',
    ).readAsString();
    final androidModern = await File(
      'android/app/src/main/res/values-v31/styles.xml',
    ).readAsString();
    final iosLaunch = await File(
      'ios/Runner/Base.lproj/LaunchScreen.storyboard',
    ).readAsString();
    final logoSet = await File(
      'ios/Runner/Assets.xcassets/LaunchLogo.imageset/Contents.json',
    ).readAsString();

    expect(androidLegacy, contains('@android:color/black'));
    expect(androidLegacy, contains('@drawable/splash_logo'));
    expect(androidModern, contains('android:windowSplashScreenBackground'));
    expect(androidModern, contains('android:windowSplashScreenAnimatedIcon'));
    expect(iosLaunch, contains('image="LaunchLogo"'));
    expect(iosLaunch, contains('red="0" green="0" blue="0"'));
    expect(logoSet, contains('LaunchLogo.png'));
  });

  testWidgets(
    'plays the app icon over pure black and reveals the existing page',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: StartupLogoSplash(child: Scaffold(body: Text('Home page'))),
        ),
      );

      expect(find.byKey(const ValueKey('startup-app-logo')), findsOneWidget);
      expect(find.text('Home page'), findsOneWidget);
      expect(
        tester
            .widget<ColoredBox>(
              find.byKey(const ValueKey('startup-splash-surface')),
            )
            .color,
        Colors.black,
      );

      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();

      expect(find.byKey(const ValueKey('startup-app-logo')), findsNothing);
      expect(find.text('Home page'), findsOneWidget);
    },
  );
}
