/// Kazakh and Russian interface text.
///
/// Kazakh is written in the code and serves as the key; ru.dart holds the Russian for each phrase.
/// A phrase missing from ru.dart shows in Kazakh rather than as a blank or a key.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ru.dart';

const languages = {'kk': 'Қазақша', 'ru': 'Русский'};

final appLanguage = ValueNotifier<String>('kk');

const _prefsKey = 'vitrina_lang';

/// Saved choice, else the device language when it is Russian, else Kazakh.
Future<void> restoreLanguage(String deviceLanguage) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString(_prefsKey);
  appLanguage.value = saved ?? (deviceLanguage == 'ru' ? 'ru' : 'kk');
}

Future<void> setLanguage(String code) async {
  appLanguage.value = code;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefsKey, code);
}

String tr(String kk) => appLanguage.value == 'ru' ? (ru[kk] ?? kk) : kk;

/// For phrases with values in them: trf('Өлшем {0} см', [size]).
String trf(String kk, List<Object?> args) {
  var text = tr(kk);
  for (var i = 0; i < args.length; i++) {
    text = text.replaceAll('{$i}', '${args[i]}');
  }
  return text;
}
