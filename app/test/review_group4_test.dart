// Whole-app review, group 4: a usual phone, large text, the keyboard, and a weak line.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/labels.dart' show formatTenge;
import 'package:vitrina/main.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/offers_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/theme.dart';
import 'package:vitrina/widgets/common.dart' show ListingTile;

import 'support/screens.dart' show loadFonts;
import 'widget_test.dart' show jsonResponse, listingJson, offerJson;

void main() {
  tearDown(() => appLanguage.value = 'kk');

  for (final (lang, scale, width) in [
    ('ru', 1.5, 360.0),
    ('kk', 1.5, 360.0),
    ('ru', 1.3, 360.0),
    ('kk', 2.0, 360.0),
    ('ru', 1.0, 320.0), // a small phone, or a larger display size
    ('ru', 0.85, 360.0), // small text
  ]) {
    testWidgets('text ×$scale ($lang, $width wide): every tab of the bottom bar keeps its name', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await loadFonts(tester);
      appLanguage.value = lang;
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final session =
          Session(Api(base: 'http://x/api/v1', client: MockClient((req) async => jsonResponse({'items': []}))));
      await tester.pumpWidget(SessionScope(
          session: session, child: MaterialApp(theme: buildTheme(Brightness.light), home: const HomeShell())));
      await tester.pump();
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysShow);
      // About the usual size at least: the bar stops growing its words at ×1.3, so they are measured that way.
      final label = tester.renderObject<RenderParagraph>(find
          .descendant(of: find.byType(NavigationBar), matching: find.byWidgetPredicate((w) => w is RichText))
          .first);
      final px = label.textScaler.scale(label.text.style?.fontSize ?? 12);
      expect(px, greaterThanOrEqualTo(12 * 0.8 - 0.01));
      await tester.pumpWidget(const SizedBox()); // stops the polling timer
    });
  }

  testWidgets('the keyboard, the text size or the profile read again does not fetch the listing page again',
      (tester) async {
    var reads = 0;
    final session = Session(Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path == '/api/v1/listings/7') reads++;
          if (req.url.path == '/api/v1/offers') return jsonResponse({'items': [], 'next_before': null});
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          if (req.url.path == '/api/v1/listings/7') return jsonResponse(listingJson());
          return jsonResponse({'items': []});
        })));
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    expect(reads, 1);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final bottom in [100.0, 200.0, 300.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: bottom);
      await tester.pump();
    }
    tester.platformDispatcher.textScaleFactorTestValue = 1.3; // the text size changed in the phone's settings
    await tester.pump();
    session.update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false})); // the profile read again
    await tester.pump();
    await tester.pumpAndSettle();
    expect(reads, 1, reason: 'each change fetched the page, its offers and payments again');
  });

  testWidgets('signing out takes the person\'s offer off the page and loads it again', (tester) async {
    var reads = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path == '/api/v1/offers') {
            return jsonResponse({
              'items': [offerJson(status: 'accepted')],
              'next_before': null
            });
          }
          if (req.url.path == '/api/v1/listings/7') reads++;
          if (req.url.path == '/api/v1/listings/7') return jsonResponse(listingJson());
          return jsonResponse({'items': []});
        }))
      ..token = 't';
    SharedPreferences.setMockInitialValues({});
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    expect(find.textContaining(formatTenge(4000000)), findsWidgets, reason: 'the agreed price');
    await tester.runAsync(() => session.signOut(server: false));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.textContaining(formatTenge(4000000)), findsNothing, reason: 'not the next person\'s price');
  });

  testWidgets('a tile tapped twice opens one page', (tester) async {
    final session = Session(Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async =>
            req.url.path == '/api/v1/listings/7' ? jsonResponse(listingJson()) : jsonResponse({'items': []}))));
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: Scaffold(
                body:
                    SizedBox(width: 220, height: 400, child: ListingTile(listing: Listing.fromJson(listingJson())))))));
    // The page opening covers the tile at once, so the second tap of a double tap lands on it, not on the tile.
    await tester.tap(find.byType(ListingTile));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.byType(ListingTile), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(ListingScreen, skipOffstage: false), findsOneWidget); // a second would sit under it
    Navigator.of(tester.element(find.byType(ListingScreen))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListingTile));
    await tester.pumpAndSettle();
    expect(find.byType(ListingScreen), findsOneWidget, reason: 'back on the list, it opens again');
  });

  testWidgets('the seller\'s own price window fits with text ×2 and the keyboard up', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = Session(Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => jsonResponse({
              'items': [offerJson()],
              'next_before': null,
            })))
      ..token = 't')
      ..update(Me.fromJson({'id': 3, 'phone': '+77010000003', 'is_seller': true}));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OffersScreen(seller: true))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('counter-11')));
    await tester.tap(find.byKey(const Key('counter-11')));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(360, 640); // a usual phone, the keyboard up for the price
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('counter-amount')), findsOneWidget);
  });
}
