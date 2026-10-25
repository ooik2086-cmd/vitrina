/// The buyer's own foot length (the size guide measures heel to longest toe), remembered on the phone so the catalog
/// and product pages fit it from the start.
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

/// How much longer than the foot an insole is when the shoe fits: room for the toes.
const toeRoom = 0.5;

/// Whether an insole of [insole] cm fits a foot of [foot] cm: no shorter, at most a centimetre longer. The server's
/// size filter (saved_search_routes.fits_foot) keeps the same window.
bool fitsFoot(double insole, double foot) => insole >= foot - 1e-9 && insole <= foot + 2 * toeRoom + 1e-9;

/// The available size for a foot of [cm], picked for the buyer: its insole (as the seller measured it) is no shorter
/// than the foot and at most a centimetre longer, as close as there is to [toeRoom] longer. A shoe too small pinches
/// and comes back, so a shorter insole is never picked; none in reach picks nothing, and the buyer chooses.
ShoeSize? bestFit(List<ShoeSize> sizes, String? cm) {
  final want = cm == null ? null : _cm(cm);
  if (want == null) return null;
  ShoeSize? best;
  double bestGap = toeRoom + 1e-9;
  for (final s in sizes) {
    final have = _cm(s.insoleCm);
    if (!s.available || have == null || !fitsFoot(have, want)) continue;
    final gap = (have - want - toeRoom).abs();
    if (gap <= bestGap) {
      best = s;
      bestGap = gap;
    }
  }
  return best;
}
