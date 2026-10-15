import 'package:app_gif/reference_ui.dart';
import 'package:app_gif/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;

class _PreviewCompleter extends ImageStreamCompleter {
  final listeners = <ImageStreamListener>[];
  ImageInfo? delivered;
  @override
  void addListener(ImageStreamListener listener) => listeners.add(listener);
  @override
  void removeListener(ImageStreamListener listener) =>
      listeners.remove(listener);
  void emit(ui.Image image) {
    for (final listener in List<ImageStreamListener>.of(listeners)) {
      delivered = ImageInfo(image: image.clone());
      listener.onImage(delivered!, false);
    }
  }
}

class _PreviewProvider extends ImageProvider<_PreviewProvider> {
  final completer = _PreviewCompleter();
  @override
  Future<_PreviewProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    _PreviewProvider key,
    ImageErrorListener handleError,
  ) {
    stream.setCompleter(completer);
  }
}

void main() {
  testWidgets('glass material tabs expose and update their selected state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final previousLanguage = LanguageSettings.current.value;
    LanguageSettings.current.value = AppLanguage.chinese;
    addTearDown(() => LanguageSettings.current.value = previousLanguage);
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, update) => Center(
            child: ReferenceSegmentedBar(
              labels: const ['我的素材', '出厂素材', '全部素材'],
              selectedIndex: selected,
              onSelected: (value) => update(() => selected = value),
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .getSemantics(find.text('我的素材'))
          .hasFlag(ui.SemanticsFlag.isSelected),
      isTrue,
    );
    await tester.tap(find.text('出厂素材'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(
      tester
          .getSemantics(find.text('出厂素材'))
          .hasFlag(ui.SemanticsFlag.isSelected),
      isTrue,
    );
    expect(
      tester
          .getSemantics(find.text('我的素材'))
          .hasFlag(ui.SemanticsFlag.isSelected),
      isFalse,
    );
    semantics.dispose();
  });
  testWidgets('static preview detaches after frame zero and owns its image', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.red, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(4, 4));
    picture.dispose();
    final provider = _PreviewProvider();
    await tester.pumpWidget(
      MaterialApp(home: StaticMaterialPreview(image: provider)),
    );
    expect(provider.completer.listeners.length, 1);
    provider.completer.emit(image!);
    await tester.pump();
    expect(provider.completer.listeners, isEmpty);
    final raw = tester.widget<RawImage>(find.byType(RawImage));
    expect(identical(raw.image, provider.completer.delivered!.image), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(provider.completer.delivered!.image.debugDisposed, isTrue);
    image.dispose();
  });
  testWidgets('material cards clip content to a circle inside the card', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 140,
            child: ReferenceMaterialTile(
              selected: false,
              onTap: () {},
              child: const ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    );
    final tile = find.byType(ReferenceMaterialTile);
    expect(
      find.descendant(of: tile, matching: find.byType(ClipOval)),
      findsOneWidget,
    );
    expect(
      tester.getSize(
        find.descendant(of: tile, matching: find.byType(ClipOval)),
      ),
      const Size(132, 132),
    );
  });
  testWidgets(
    'device housing keeps a circular screen with or without preview',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 160,
              child: ReferenceDeviceDisplay(child: Text('preview')),
            ),
          ),
        ),
      );
      expect(find.text('preview'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('preview'),
          matching: find.byType(ClipOval),
        ),
        findsOneWidget,
      );
    },
  );
}
