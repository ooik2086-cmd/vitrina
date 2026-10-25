/// A seller's ready answers for the chat, remembered on the phone. Until the seller edits them, the defaults are
/// shown in the interface language.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'en.dart';
import 'i18n.dart';
import 'ru.dart';

const _prefsKey = 'vitrina_quick_replies';
const maxQuickReplies = 10;
const maxQuickReplyLength = 300;

const _defaults = [
  'Сәлеметсіз бе! Иә, бар.',
  'Өлшемі сай келеді. Ішкі табанының ұзындығын тауар бетінен қараңыз.',
];
// Only while online payment works: they speak of money paid in the app and held by VITRINA.
const _paidDefaults = [
  'Төлем түскен күні жіберемін.',
  'Ақшаңыз VITRINA-да сақталады: сіз тауарды алғаныңызды растағанда не тексеру мерзімі өткенде ғана маған өтеді.',
];

/// Null while the seller has not changed the list.
final quickReplies = ValueNotifier<List<String>?>(null);

/// The seller's own answers, or the defaults; [payments] is whether online payment is on now.
List<String> currentQuickReplies({bool payments = true}) =>
    quickReplies.value ??
    [
      for (final d in [..._defaults, if (payments) ..._paidDefaults]) tr(d)
    ];

Future<void> restoreQuickReplies() async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
    quickReplies.value = raw == null ? null : [for (final s in jsonDecode(raw) as List) s as String];
  } catch (_) {
    quickReplies.value = null; // a damaged entry falls back to the defaults
  }
}

Future<void> saveQuickReplies(List<String> items) async {
  final clean = [
    for (final s in items)
      if (s.trim().isNotEmpty)
        s.trim().length > maxQuickReplyLength ? s.trim().substring(0, maxQuickReplyLength) : s.trim()
  ].take(maxQuickReplies).toList();
  quickReplies.value = clean;
  await (await SharedPreferences.getInstance()).setString(_prefsKey, jsonEncode(clean));
}

/// What a public answer to a buyer's question can take from the ready answers. Not the defaults about money held in
/// the app, in any language: an answer stays on the listing whatever happens to online payment later. Not one with
/// a phone, link or messenger either, which the server refuses there.
List<String> publicQuickReplies() => [
      for (final t in currentQuickReplies(payments: false))
        if (!_paidDefaults.any((d) => t == d || t == ru[d] || t == en[d]) && !looksLikeContact(t)) t
    ];

/// The server's contact rule for public text (backend/vitrina_api/social.py, looks_like_contact); both sides' tests
/// read the same cases from contracts/contact_cases.json. Words are bounded by letters of any alphabet, as the
/// server's are, and a messenger's name counts with any ending (ватсапқа, инстада).
final _link = RegExp(
    r'(https?://|www\.)'
    r'|(?<![\p{L}\p{N}_])(whats\s?app?|wats?app|telegram|instagram|viber|ватсап|вотсап|вацап|вотцап|уатсап|телеграм'
    r'|телег[аеиуы](?!й)|инстаграм|вайбер|директ(?!ор|ив))'
    r'|(?<![\p{L}\p{N}_])(тг|tg)\s*[:@]'
    r'|(?<![\p{L}\p{N}_])(t\.me|wa\.me|insta(?!ll|nt|nce|x))'
    r'|(?<![\p{L}\p{N}_])инст[аеуыо](?!лл|нц|кс)'
    r'|[\p{L}\p{N}_.+\-]{1,64}@([\p{L}\p{N}_\-]+\.[a-z]{2,}|(gmail|mail|yandex|inbox|bk|list|icloud|outlook|hotmail)(?![\p{L}\p{N}_]))'
    r'|(?<![\p{L}\p{N}_@.])@[a-z0-9_.]{3,}'
    r'|(?<![\p{L}\p{N}_@.\-])[a-z0-9\-]{2,}\.(kz|ru|com|net|org|me|cc|ee|io|su|uz|kg|link|site|shop|store|online)'
    r'(?![\p{L}\p{N}_])',
    caseSensitive: false,
    unicode: true);

/// A run of digits and separators that may hold a phone number.
final _run = RegExp(r'\+?\(?[0-9][0-9\s\-().,]*[0-9]');
final _token = RegExp(r'[0-9]{1,2}[.,]5(?![0-9])|[0-9]+'); // 38.5 is one size

/// The digits of a phone number written with any separators (see the server's _PHONE_RE).
final _phone = RegExp(r'^(7[0-9]{9}|[78][0-9]{10}|99[0-9]{10})$');
const _latinLook = {
  'а': 'a', 'е': 'e', 'о': 'o', 'р': 'p', 'с': 'c', 'х': 'x', 'у': 'y', 'к': 'k', 'м': 'm', 'т': 't', 'в': 'b', //
  'і': 'i', 'İ': 'i', 'ı': 'i',
};
const _cyrillicLook = {
  'a': 'а', 'e': 'е', 'o': 'о', 'p': 'р', 'c': 'с', 'x': 'х', 'y': 'у', 'k': 'к', 'm': 'м', 't': 'т', 'A': 'А', //
  'B': 'В', 'E': 'Е', 'K': 'К', 'M': 'М', 'H': 'Н', 'O': 'О', 'P': 'Р', 'C': 'С', 'T': 'Т', 'X': 'Х', 'Y': 'У',
};
final _zero = RegExp(r'(?<=[0-9])[OoОо](?=[0-9])'); // 8 7O1: a letter O between digits
final _invisible = RegExp('[\u00ad\u180e\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]');

/// Shoe sizes going up, 36 37 38 or 7 7.5 8: a list of them is not a phone number.
bool _sizes(List<String> tokens) {
  final values = [for (final t in tokens) double.parse(t.replaceAll(',', '.'))];
  if (values.length < 2 || values.any((v) => v > 60)) return false;
  for (var k = 1; k < values.length; k++) {
    if (values[k - 1] >= values[k]) return false;
  }
  return true;
}

bool _hasPhone(String run) {
  final tokens = [for (final m in _token.allMatches(run)) m.group(0)!];
  for (var i = 0; i < tokens.length; i++) {
    var digits = '';
    for (var j = i; j < tokens.length; j++) {
      digits += tokens[j].replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.length > 15) break;
      final values = tokens.sublist(i, j + 1);
      if (digits.length < 10 || _sizes(values)) continue;
      // Prices: 75 000 80 000, 7 000 10 000 12 000 (every other group 000), as the server reads them.
      final prices = values.length > 1 && [for (var k = 1; k < values.length; k += 2) values[k]].every((v) => v == '000');
      if ((i == 0 && run.startsWith('+')) || _phone.hasMatch(digits) && !prices) return true;
    }
  }
  return false;
}

bool looksLikeContact(String text) {
  text = String.fromCharCodes([
    for (final c in text.replaceAll(_invisible, '').runes) c >= 0xFF01 && c <= 0xFF5E ? c - 0xFEE0 : c
  ]).replaceAll(_zero, '0');
  if (_link.hasMatch(text)) return true;
  for (final look in [_latinLook, _cyrillicLook]) {
    if (_link.hasMatch(text.split('').map((c) => look[c] ?? c).join())) return true;
  }
  return _run.allMatches(text).any((m) => _hasPhone(m.group(0)!));
}
