/// Listings this person opened lately, kept on the phone only, newest first.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

class RecentItem {
  const RecentItem({required this.id, required this.title, required this.priceTiyn, this.coverUrl});
  RecentItem.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        title = j['title'] as String,
        priceTiyn = j['price_tiyn'] as int,
        coverUrl = j['cover'] as String?;
  final int id;
  final String title;
  final int priceTiyn;
  final String? coverUrl;
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'price_tiyn': priceTiyn, 'cover': coverUrl};
}

const recentLimit = 12;
const _prefsKey = 'vitrina_recent';

final recentlyViewed = ValueNotifier<List<RecentItem>>(const []);

Future<void> restoreRecent() async {
  final raw = (await SharedPreferences.getInstance()).getString(_prefsKey);
  if (raw == null) return;
  try {
    recentlyViewed.value = [for (final j in jsonDecode(raw) as List) RecentItem.fromJson(j as Map<String, dynamic>)];
  } catch (_) {
    recentlyViewed.value = const []; // an old or damaged entry is not worth an error
  }
}

Future<void> rememberViewed(Listing l) async {
  final item = RecentItem(id: l.id, title: l.title, priceTiyn: l.priceTiyn, coverUrl: l.coverUrl);
  final list = [item, ...recentlyViewed.value.where((r) => r.id != l.id)].take(recentLimit).toList();
  recentlyViewed.value = list;
  await (await SharedPreferences.getInstance()).setString(_prefsKey, jsonEncode([for (final r in list) r.toJson()]));
}

Future<void> forgetRecent() async {
  recentlyViewed.value = const [];
  await (await SharedPreferences.getInstance()).remove(_prefsKey);
}
