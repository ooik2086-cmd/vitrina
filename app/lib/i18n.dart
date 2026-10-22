/// Kazakh, Russian and English interface text.
///
/// Kazakh is written in the code and serves as the key; ru.dart and en.dart hold the other languages for each
/// phrase. A phrase missing from them shows in Kazakh rather than as a blank or a key.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'en.dart';
import 'ru.dart';

const languages = {'kk': 'Қазақша', 'ru': 'Русский', 'en': 'English'};

/// For the language switch, where three full names do not fit beside a title on a phone.
const languageShort = {'kk': 'ҚАЗ', 'ru': 'РУС', 'en': 'ENG'};

const _tables = {'ru': ru, 'en': en};

final appLanguage = ValueNotifier<String>('kk');

const _prefsKey = 'vitrina_lang';

/// Saved choice, else the device language when it is Russian or English, else Kazakh.
Future<void> restoreLanguage(String deviceLanguage) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString(_prefsKey);
  appLanguage.value = saved ?? (languages.containsKey(deviceLanguage) ? deviceLanguage : 'kk');
}

Future<void> setLanguage(String code) async {
  appLanguage.value = code;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefsKey, code);
}

String tr(String kk) => _tables[appLanguage.value]?[kk] ?? kk;

/// A person's name as the server sends it: its stand-ins for a missing name follow the interface language.
/// Matched by their exact words, which the server already sends to installed apps; someone who took one of these
/// words as a name sees it translated, which says the same.
String personName(String name) => const {'Сатушы', 'Сатып алушы', 'Пайдаланушы'}.contains(name) ? tr(name) : name;

/// Picks the server's own text for the interface language, falling back to Russian, then Kazakh.
String pick(String kk, String? ru, String? en) => switch (appLanguage.value) {
      'en' => en ?? ru ?? kk,
      'ru' => ru ?? kk,
      _ => kk,
    };

/// For phrases with values in them: trf('Өлшем {0} см', [size]).
String trf(String kk, List<Object?> args) {
  var text = tr(kk);
  for (var i = 0; i < args.length; i++) {
    text = text.replaceAll('{$i}', '${args[i]}');
  }
  return text;
}

/// A star rating as people here write it: "4,8" (English keeps "4.8").
String ratingText(double r) {
  final s = r.toStringAsFixed(1);
  return appLanguage.value == 'en' ? s : s.replaceAll('.', ',');
}
