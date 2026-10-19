// Every main screen on a small phone with large text, against the demo data and the app's own font: nothing may
// run off the screen or past its box (Flutter reports that as an overflow).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/shop_screen.dart';

import 'support/screens.dart';

/// The narrowest common phone with the largest text Android offers and with text a step below it, and a usual
/// phone with text a size up.
const setups = [
  ('kk', Size(320, 640), 2.0),
  ('ru', Size(320, 640), 2.0),
  ('ru', Size(320, 640), 1.5),
  ('kk', Size(360, 640), 1.3),
];

void main() {
  testWidgets('with large text the buy button goes under the total and the hint gives the shoe its room',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts(tester);
    appLanguage.value = 'kk';
    final client = await tester.runAsync(() => DemoClient.load());
    final session = Session(Api(base: 'http://demo/api/v1', client: client!))..api.token = demoToken;
    Future<void> show(double scale) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await tester.pumpWidget(SessionScope(
          session: session,
          child: MaterialApp(theme: buildTheme(Brightness.light), home: const ListingScreen(listingId: 1))));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await show(1);
    expect(tester.getCenter(find.byKey(const Key('buy'))).dy,
        closeTo(tester.getCenter(find.byKey(const Key('total'))).dy, 20));
    expect(find.byKey(const Key('showcase-hint')), findsOneWidget);
    await show(2);
    expect(tester.getTopLeft(find.byKey(const Key('buy'))).dy,
        greaterThan(tester.getBottomLeft(find.byKey(const Key('total'))).dy));
    expect(find.byKey(const Key('showcase-hint')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('at the usual text size the shop\'s follow button keeps to the end of its row', (tester) async {
    final errors =
        await visit(tester, 'kk', const Size(400, 800), 1, () => const ShopScreen(sellerId: 1), check: (tester) async {
      final follow = find.byKey(const Key('follow')).evaluate().isEmpty ? 'unfollow' : 'follow';
      expect(tester.getTopRight(find.byKey(Key(follow))).dx, greaterThan(400 - 40));
    });
    expect(errors, isEmpty);
  });

  for (final (lang, size, scale) in setups) {
    for (final e in screens.entries) {
      testWidgets('${e.key} fits at ${size.width.round()} wide, text ×$scale ($lang)', (tester) async {
        expect(await visit(tester, lang, size, scale, e.value), isEmpty);
      });
    }
    for (final e in sheets.entries) {
      testWidgets('the ${e.key} sheet fits at ${size.width.round()} wide, text ×$scale ($lang)', (tester) async {
        expect(await visit(tester, lang, size, scale, () => const SizedBox(), sheet: e.value()), isEmpty);
      });
    }
  }
}
