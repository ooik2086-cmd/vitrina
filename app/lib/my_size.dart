/// The buyer's own insole length, remembered on the phone so the catalog and product pages fit it from the start.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

final mySize = ValueNotifier<String?>(null);

const _prefsKey = 'vitrina_size_cm';

Future<void> restoreMySize() async {
  final prefs = await SharedPreferences.getInstance();
  mySize.value = prefs.getString(_prefsKey);
}

/// Null forgets the size.
Future<void> setMySize(String? cm) async {
  mySize.value = cm;
  final prefs = await SharedPreferences.getInstance();
  if (cm == null) {
    await prefs.remove(_prefsKey);
  } else {
    await prefs.setString(_prefsKey, cm);
  }
}

double? _cm(String text) => double.tryParse(text.replaceAll(',', '.'));

/// The available size closest to [cm], within the same ±0,5 cm the catalog filter uses.
ShoeSize? bestFit(List<ShoeSize> sizes, String? cm) {
  final want = cm == null ? null : _cm(cm);
  if (want == null) return null;
  ShoeSize? best;
  double bestGap = 0.5 + 1e-9;
  for (final s in sizes) {
    final have = _cm(s.insoleCm);
    if (!s.available || have == null) continue;
    final gap = (have - want).abs();
    if (gap <= bestGap) {
      best = s;
      bestGap = gap;
    }
  }
  return best;
}
