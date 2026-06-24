import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS runner exposes the badge native method channel', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final podfile = File('ios/Podfile').readAsStringSync();
    final codemagic = File('../codemagic.yaml').readAsStringSync();

    expect(source, contains('FlutterMethodChannel('));
    expect(source, contains('name: BadgeConstants.channel'));
    expect(source, contains('PHPickerViewControllerDelegate'));
    expect(source, contains('PHPickerConfiguration'));
    expect(source, contains('.any(of: [.images, .videos])'));
    expect(source, contains('NSItemProvider'));
    expect(source, isNot(contains('UIDocumentPickerViewController')));
    expect(source, contains('case "pickMedia"'));
    expect(source, contains('case "warmVideoAnimatedPreview"'));
    expect(source, contains('case "prepareAsset"'));
    expect(source, contains('case "uploadAsset"'));
    expect(source, contains('case "loadHistory"'));
    expect(source, contains('case "saveHistory"'));
    expect(source, contains('case "deleteAssetFiles"'));
    expect(source, contains('case "openUrl"'));
    expect(source, contains('UIApplication.shared.open'));
    expect(source, contains('private func assetRootDirectory'));
    expect(source, contains('private func deleteAssetFiles'));
    expect(source, contains('AVAssetImageGenerator'));
    expect(source, contains('CGImageDestinationCreateWithData'));
    expect(source, contains('AVAssetReader'));
    expect(source, contains('CVPixelBuffer'));
    expect(source, contains('NWConnection'));
    expect(source, contains('magic: UInt32 = 0x344a4142'));
    expect(source, contains('version = 4'));
    expect(source, contains('codecIndexedKey = 0x10'));
    expect(source, contains('codecIndexedTile = 0x11'));
    expect(source, contains('codecIndexedRepeat = 0x12'));
    expect(source, contains('videoPreviewGifSize = 192'));
    expect(source, contains('videoPreviewGifFps = 30'));
    expect(source, contains('qualityStreamBytesPerSecond = 4 * 1024 * 1024'));
    expect(plist, contains('NSLocalNetworkUsageDescription'));
    expect(plist, contains('NSAppTransportSecurity'));
    expect(plist, contains('CFBundleDisplayName'));
    expect(plist, isNot(contains('<string>App Gif</string>')));
    expect(plist, isNot(contains('<string>app_gif</string>')));
    expect(project, contains('PRODUCT_BUNDLE_IDENTIFIER = com.leyyoudian.espbaji;'));
    expect(project, isNot(contains('PRODUCT_BUNDLE_IDENTIFIER = com.example.appGif;')));
    expect(codemagic, contains('ios_app_store'));
    expect(codemagic, contains('app-store-ipa'));
    expect(codemagic, contains('flutter build ipa --release'));
    expect(podfile, contains("platform :ios, '14.0'"));
    expect(podfile, contains('flutter_install_all_ios_pods'));
    expect(codemagic, contains('working_directory: app_gif'));
    expect(codemagic, contains('flutter build ios --release --no-codesign'));
    expect(codemagic, contains('Runner-release-adhoc.ipa'));
    expect(codemagic, contains('/usr/bin/codesign --force --deep --sign -'));
    expect(codemagic, contains(r'/usr/bin/otool -l "$APP_PATH/Runner"'));
    expect(codemagic, contains('Payload/Runner.app/Runner'));
    expect(codemagic, contains('Runner.debug.dylib'));
    expect(codemagic, contains('build/ios/ipa/Runner-release-adhoc.ipa'));
    expect(codemagic, isNot(contains('flutter build ios --debug --no-codesign')));
    expect(codemagic, isNot(contains('build/ios/iphoneos/*.app')));
  });

  test('iOS RGB332 palette helper calls are defined', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final definitions = RegExp(
      r'func\s+(rgb332[A-Za-z0-9_]*)\s*\(',
    ).allMatches(source).map((match) => match.group(1)!).toSet();
    final calls = RegExp(
      r'\b(rgb332[A-Za-z0-9_]*)\s*\(',
    ).allMatches(source).map((match) => match.group(1)!).toSet();

    expect(calls.difference(definitions), isEmpty);
  });

  test('iOS native rendering matches Android crop direction and RGB byte order', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(source, contains('+ crop.offsetY * Double(height)'));
    expect(source, contains('+ crop.offsetY * Double(streamSize)'));
    expect(source, isNot(contains('- crop.offsetY * Double(height)')));
    expect(source, isNot(contains('- crop.offsetY * Double(streamSize)')));
    expect(
      RegExp(r'byteOrder32Big').allMatches(source).length,
      greaterThanOrEqualTo(5),
    );
  });

  test('iOS video animated previews use asset reader instead of image generator frame seeking', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final previewStart = source.indexOf(
      '  private func buildVideoAnimatedPreview(url: URL, crop: CropTransform, warmPreviewPath: String?) throws -> Data {',
    );
    final previewEnd = source.indexOf(
      '  private func buildVideoPreviewFrames',
      previewStart,
    );
    expect(previewStart, isNot(-1));
    expect(previewEnd, isNot(-1));
    final previewSource = source.substring(previewStart, previewEnd);

    expect(previewSource, contains('buildVideoPreviewFrames(url: url, crop: crop)'));
    expect(source, contains('AVAssetReaderVideoCompositionOutput'));
    expect(source, contains('CMSampleBufferGetImageBuffer'));
    expect(source, contains('quantizePixelBufferToGifIndexed'));
    expect(source, contains('"assetPreviewReady"'));
    expect(source, contains('scheduleVideoAnimatedPreview'));
    expect(previewSource, isNot(contains('AVAssetImageGenerator')));
    expect(previewSource, isNot(contains('copyCGImage')));
  });
}
