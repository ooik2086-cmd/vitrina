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
  'Өлшемі сай келеді. Табанының ұзындығын тауар бетінен қараңыз.',
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

/// The server's contact rule for public text (backend/vitrina_api/social.py CONTACT_RE); keep the two the same.
/// Words are bounded by letters of any alphabet, as the server's are.
final _contact = RegExp(
    r'(\+?\d[\d\s\-()]{8,}\d)|(https?://|www\.)|((?<![\p{L}\p{N}_])(whats\s?app|telegram|t\.me|ватсап|телеграм)(?![\p{L}\p{N}_]))',
    caseSensitive: false,
    unicode: true);

bool looksLikeContact(String text) => _contact.hasMatch(text);
