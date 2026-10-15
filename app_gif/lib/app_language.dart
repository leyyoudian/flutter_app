import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_translations.dart';

enum AppLanguage {
  system,
  chinese,
  english,
  traditionalChinese,
  japanese,
  russian,
}

class LanguageSettings {
  static final current = ValueNotifier<AppLanguage>(AppLanguage.system);
  static const _channel = MethodChannel('esp_baji/native');
  static int _revision = 0;
  static AppLanguage resolve(Locale locale) => switch (locale.languageCode) {
    'zh' =>
      locale.scriptCode == 'Hant' ||
              const {'TW', 'HK', 'MO'}.contains(locale.countryCode)
          ? AppLanguage.traditionalChinese
          : AppLanguage.chinese,
    'ja' => AppLanguage.japanese,
    'ru' => AppLanguage.russian,
    _ => AppLanguage.english,
  };
  static AppLanguage get effective => current.value == AppLanguage.system
      ? resolve(PlatformDispatcher.instance.locale)
      : current.value;
  static bool get english => effective == AppLanguage.english;
  static Locale localeFor(AppLanguage language) => switch (language) {
    AppLanguage.chinese => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
      countryCode: 'CN',
    ),
    AppLanguage.traditionalChinese => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'TW',
    ),
    AppLanguage.japanese => const Locale('ja'),
    AppLanguage.russian => const Locale('ru'),
    _ => const Locale('en'),
  };
  static String label(AppLanguage language) => switch (language) {
    AppLanguage.system => tr('跟随系统'),
    AppLanguage.chinese => '简体中文',
    AppLanguage.english => 'English',
    AppLanguage.traditionalChinese => '繁體中文',
    AppLanguage.japanese => '日本語',
    AppLanguage.russian => 'Русский',
  };
  static Future<void> load() async {
    final revision = _revision;
    try {
      final saved = await _channel.invokeMethod<String>('loadLanguage');
      if (revision != _revision) return;
      current.value = AppLanguage.values.firstWhere(
        (v) => v.name == saved,
        orElse: () => AppLanguage.system,
      );
    } on PlatformException {
      /* Older native bridge uses the system language. */
    } on MissingPluginException {
      /* Widget tests do not have a native bridge. */
    }
  }

  static Future<void> select(AppLanguage language) async {
    ++_revision;
    await _channel.invokeMethod<void>('saveLanguage', {
      'language': language.name,
    });
    current.value = language;
  }
}

// Longest phrase wins; inserted values are retained and translated output is not rescanned.
final _phrases = RegExp(
  (appTranslations.keys.toList()..sort((a, b) => b.length.compareTo(a.length)))
      .map(RegExp.escape)
      .join('|'),
);
String tr(String text) {
  final language = LanguageSettings.effective;
  if (language == AppLanguage.chinese) return text;
  final index = switch (language) {
    AppLanguage.traditionalChinese => 1,
    AppLanguage.japanese => 2,
    AppLanguage.russian => 3,
    _ => 0,
  };
  final exact = appTranslations[text];
  if (exact != null) return exact[index];
  return text.replaceAllMapped(
    _phrases,
    (match) => appTranslations[match.group(0)]![index],
  );
}

class AppText extends StatelessWidget {
  const AppText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.semanticsLabel,
    this.translate = true,
  });
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final String? semanticsLabel;
  final bool translate;
  @override
  Widget build(BuildContext context) {
    Localizations.maybeLocaleOf(context);
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: LanguageSettings.current,
      builder: (context, language, child) => Text(
        translate ? tr(data) : data,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        softWrap: softWrap,
        semanticsLabel: semanticsLabel,
      ),
    );
  }
}
