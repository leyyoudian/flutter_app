import 'package:app_gif/app_language.dart';
import 'package:app_gif/app_translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('esp_baji/native');
  test('system locale selects Traditional Chinese, Japanese and Russian', () {
    expect(
      LanguageSettings.resolve(const Locale('zh', 'HK')),
      AppLanguage.traditionalChinese,
    );
    expect(
      LanguageSettings.resolve(const Locale('zh', 'TW')),
      AppLanguage.traditionalChinese,
    );
    expect(
      LanguageSettings.resolve(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ),
      AppLanguage.traditionalChinese,
    );
    expect(
      LanguageSettings.resolve(const Locale('zh', 'CN')),
      AppLanguage.chinese,
    );
    expect(LanguageSettings.resolve(const Locale('ja')), AppLanguage.japanese);
    expect(LanguageSettings.resolve(const Locale('ru')), AppLanguage.russian);
    expect(LanguageSettings.resolve(const Locale('de')), AppLanguage.english);
  });
  test('every translation has all four language variants', () {
    for (final entry in appTranslations.entries) {
      expect(entry.value, hasLength(4), reason: entry.key);
      expect(
        entry.value.every((text) => text.isNotEmpty),
        isTrue,
        reason: entry.key,
      );
    }
  });
  tearDown(() {
    LanguageSettings.current.value = AppLanguage.chinese;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('all requested languages translate settings and dynamic prompts', () {
    for (final name in ['traditionalChinese', 'japanese', 'russian']) {
      final matches = AppLanguage.values.where((v) => v.name == name);
      expect(matches, hasLength(1), reason: name);
      LanguageSettings.current.value = matches.single;
      expect(tr('设备状态'), isNot('设备状态'));
      expect(tr('发现新版本 0.2.5'), isNot(contains('发现新版本')));
      expect(tr('发现新版本 0.2.5'), contains('0.2.5'));
    }
    LanguageSettings.current.value = AppLanguage.english;
    expect(tr('当前固件：0.2.5'), 'Current firmware: 0.2.5');
    expect(tr('切换失败: timeout'), 'Switch failed: timeout');
  });

  test('language preference survives a fresh load', () async {
    String? saved;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'saveLanguage') {
        saved = (call.arguments as Map)['language'];
      }
      if (call.method == 'loadLanguage') return saved;
      return null;
    });
    final language = AppLanguage.values.firstWhere(
      (v) => v.name == 'japanese',
      orElse: () => AppLanguage.english,
    );
    await LanguageSettings.select(language);
    LanguageSettings.current.value = AppLanguage.system;
    await LanguageSettings.load();
    expect(LanguageSettings.current.value.name, 'japanese');
  });

  testWidgets('existing text rebuilds immediately after a language switch', (
    tester,
  ) async {
    LanguageSettings.current.value = AppLanguage.chinese;
    await tester.pumpWidget(const MaterialApp(home: AppText('设备状态')));
    expect(find.text('设备状态'), findsOneWidget);
    LanguageSettings.current.value = AppLanguage.english;
    await tester.pump();
    expect(find.text('Device status'), findsOneWidget);
    expect(find.text('设备状态'), findsNothing);
  });
}
