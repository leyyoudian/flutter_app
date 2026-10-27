import 'dart:io';

import 'package:app_gif/app_language.dart';
import 'package:app_gif/factory_packs.dart';
import 'package:app_gif/main.dart';
import 'package:app_gif/reference_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _PackBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);

  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      key == 'assets/factory_previews/manifest.json'
      ? SynchronousFuture(File(key).readAsStringSync())
      : rootBundle.loadString(key, cache: cache);
}

void main() {
  test(
    'Sharingan contains the ten backpack animations and Faceit contains 8 through 18',
    () {
      expect(factoryPacks.map((pack) => pack.name), ['Sharingan', 'Faceit']);
      expect(
        factoryPacks.first.materialIds,
        List.generate(
          10,
          (index) => 'S${(index + 1).toString().padLeft(3, '0')}',
        ),
      );
      expect(
        factoryPacks.last.materialIds,
        List.generate(
          11,
          (index) => 'F${(index + 8).toString().padLeft(3, '0')}',
        ),
      );
    },
  );

  testWidgets('pack names stay English in all app languages', (tester) async {
    addTearDown(() => LanguageSettings.current.value = AppLanguage.system);
    for (final language in AppLanguage.values.where(
      (value) => value != AppLanguage.system,
    )) {
      LanguageSettings.current.value = language;
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(language),
          home: Scaffold(
            body: FactoryPackBrowser(
              availableIds: const {},
              materialBuilder: (_, _) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sharingan'), findsOneWidget);
      expect(find.text('Faceit'), findsOneWidget);
      expect(find.byKey(const ValueKey('custom-pack-add')), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  testWidgets(
    'backpack shows two English covers and expands only the selected group',
    (tester) async {
      LanguageSettings.current.value = AppLanguage.chinese;
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        DefaultAssetBundle(bundle: _PackBundle(), child: const BadgeApp()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr('背包')));
      await tester.pumpAndSettle();
      expect(find.text('Sharingan'), findsOneWidget);
      expect(find.text('Faceit'), findsOneWidget);
      expect(find.byKey(const ValueKey('fac_F008')), findsNothing);
      await tester.tap(find.text('Faceit'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fac_F008')), findsOneWidget);
      expect(find.byKey(const ValueKey('fac_F009')), findsOneWidget);
      expect(find.byKey(const ValueKey('fac_F003')), findsNothing);
      expect(find.byKey(const ValueKey('fac_F019')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('fac_F008')));
      await tester.pumpAndSettle();
      final preview = tester.widget<StaticMaterialPreview>(
        find.descendant(
          of: find.byKey(const ValueKey('fixed-home-preview')),
          matching: find.byType(StaticMaterialPreview),
        ),
      );
      expect(
        (preview.image as AssetImage).assetName,
        'assets/factory_previews/F008.png',
      );
      await tester.tap(find.text('Faceit'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fac_F008')), findsNothing);
      await tester.tap(find.text('Sharingan'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fac_S001')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('fac_S010')),
        360,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('fac_S008')), findsOneWidget);
      expect(find.byKey(const ValueKey('fac_S009')), findsOneWidget);
      expect(find.byKey(const ValueKey('fac_S010')), findsOneWidget);
      expect(find.byKey(const ValueKey('fac_F008')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('fac_S010')));
      await tester.pumpAndSettle();
      final sharinganPreview = tester.widget<StaticMaterialPreview>(
        find.descendant(
          of: find.byKey(const ValueKey('fixed-home-preview')),
          matching: find.byType(StaticMaterialPreview),
        ),
      );
      expect(
        (sharinganPreview.image as AssetImage).assetName,
        'assets/sharingan/S010.png',
      );
    },
    variant: platforms,
  );
}
