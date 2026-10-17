/// A seller's ready answers for the chat, remembered on the phone. Until the seller edits them, the defaults are
/// shown in the interface language.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n.dart';

const _prefsKey = 'vitrina_quick_replies';
const maxQuickReplies = 10;
const maxQuickReplyLength = 300;

const _defaults = [
  'Сәлеметсіз бе! Иә, бар.',
  'Өлшемі сай келеді. Табанының ұзындығын тауар бетінен қараңыз.',
  'Төлем түскен күні жіберемін.',
  'Ақшаңыз VITRINA-да қорғалады: тауарды алып, растағаннан кейін ғана маған өтеді.',
];

/// Null while the seller has not changed the list.
final quickReplies = ValueNotifier<List<String>?>(null);

List<String> currentQuickReplies() => quickReplies.value ?? [for (final d in _defaults) tr(d)];

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
