// What the app does when the server answers that someone else got there first: another buyer took the last pair, the
// review was already kept, the offer was answered on another phone, a pair sold while the seller edited the stock.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/screens/offers_screen.dart';
import 'package:vitrina/screens/order_screen.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/session.dart';

import 'support/press.dart';
import 'support/screens.dart';

http.Response _conflict(String code) => http.Response(
    jsonEncode({'code': code, 'message_kk': 'Қақтығыс: $code', 'message_ru': code, 'message_en': code}), 409,
    headers: {'content-type': 'application/json; charset=utf-8'});

/// [screen] signed in on the demo data; [answer] may answer a request in its place. Returns every request asked.
Future<List<String>> _open(WidgetTester tester, Widget screen, http.Response? Function(http.BaseRequest req) answer,
    {Map<String, Object?> Function(String path, Map<String, Object?> json)? edit}) async {
  tester.view.physicalSize = const Size(360, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await loadFonts(tester);
  final demo = (await tester.runAsync(() => DemoClient.load()))!;
  final asked = <String>[];
  final client = MockClient.streaming((req, body) async {
    asked.add('${req.method} ${req.url.path.replaceFirst('/api/v1', '')}');
    final own = answer(req);
    if (own != null) return http.StreamedResponse(Stream.value(own.bodyBytes), own.statusCode, headers: own.headers);
    final res = await demo.send(req);
    if (edit == null || req.method != 'GET') return res;
    final json = jsonDecode(await res.stream.bytesToString());
    final changed = json is Map<String, Object?> ? edit(req.url.path.replaceFirst('/api/v1', ''), json) : json;
    return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(changed))), res.statusCode, headers: res.headers);
  });
  final session = Session(Api(base: 'http://demo/api/v1', client: client))..api.token = demoToken;
  session.update((await tester.runAsync(() => session.api.me()))!);
  await tester.pumpWidget(SessionScope(session: session, child: MaterialApp(home: screen)));
  await settle(tester);
  return asked;
}

void main() {
  testWidgets('the last pair taken by another buyer meanwhile: the listing is shown again as it is now',
      (tester) async {
    final asked = await _open(tester, const ListingScreen(listingId: 1),
        (req) => req.method == 'POST' && req.url.path.endsWith('/orders') ? _conflict('out_of_stock') : null);
    await tester.scrollUntilVisible(find.text('42'), 300,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);
    Scrollable.ensureVisible(tester.element(find.text('42').first), alignment: 0.4);
    await tester.pump();
    await tester.tap(find.text('42').first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('buy')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('delivery-name')), 'Аза Сапар');
    await tester.enterText(find.byKey(const Key('delivery-phone')), '+7 701 000 00 00');
    await tester.enterText(find.byKey(const Key('delivery-city')), 'Алматы');
    await tester.enterText(find.byKey(const Key('delivery-address')), 'Абай даңғылы 10');
    await tester.ensureVisible(find.byKey(const Key('delivery-continue')));
    await tester.pump();
    final before = asked.where((r) => r == 'GET /listings/1').length;
    await tester.tap(find.byKey(const Key('delivery-continue')));
    await settle(tester);
    expect(asked, contains('POST /orders'));
    expect(find.text('Қақтығыс: out_of_stock'), findsOneWidget);
    expect(asked.where((r) => r == 'GET /listings/1').length, before + 1, reason: 'the sizes left are shown');
    expect(find.byType(OrderScreen), findsNothing);
  });

  testWidgets('a review already kept: the form gives way to the thanks', (tester) async {
    await _open(tester, const OrderScreen(orderId: 2),
        (req) => req.method == 'POST' && req.url.path.endsWith('/review') ? _conflict('already_reviewed') : null);
    final star = find.byIcon(Icons.star_outline_rounded);
    await tester.scrollUntilVisible(find.text('Пікір қалдыру'), 300,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);
    await tester.ensureVisible(star.last);
    await tester.pump();
    await tester.tap(star.last);
    await tester.pump();
    await tester.ensureVisible(find.text('Пікір қалдыру'));
    await tester.pump();
    await tester.tap(find.text('Пікір қалдыру'));
    await settle(tester);
    expect(find.text('Пікір қалдыру'), findsNothing);
    expect(find.text('Пікіріңіз үшін рақмет!'), findsOneWidget);
  });

  testWidgets('an offer answered on another phone: the list is asked again', (tester) async {
    final asked = await _open(
        tester,
        const OffersScreen(seller: false), // the seller's price is the buyer's to answer
        (req) => req.method == 'POST' && req.url.path.contains('/offers/') ? _conflict('invalid_status') : null);
    final before = asked.where((r) => r == 'GET /offers').length;
    await tester.tap(find.text('Бас тарту').first);
    await settle(tester);
    expect(find.text('Қақтығыс: invalid_status'), findsOneWidget);
    expect(asked.where((r) => r == 'GET /offers').length, before + 1);
  });

  testWidgets('a pair sold while the seller edits the stock: Save shows the count left instead of putting it back',
      (tester) async {
    var sold = false;
    final sent = <Map<String, Object?>>[];
    // The seller's own listing: every size with 2 pairs, the first down to 1 once a buyer took one.
    Map<String, Object?> own(Map<String, Object?> l) => {
          ...l,
          'sizes': [
            for (final (i, s) in (l['sizes'] as List).cast<Map<String, Object?>>().indexed)
              {...s, 'quantity': sold && i == 0 ? 1 : 2}
          ]
        };
    final json = (jsonDecode(File('demo/api.json').readAsStringSync()) as Map)['GET /listings/1'] as Map;
    final listing = Listing.fromJson(own(json.cast<String, Object?>()));
    final asked = await _open(tester, ManageListingScreen(listing: listing), (req) {
      if (req.method != 'PATCH') return null;
      sent.add((jsonDecode((req as http.Request).body) as Map).cast<String, Object?>());
      if (sent.length == 1) return _conflict('stock_changed');
      return http.Response(jsonEncode(own(json.cast<String, Object?>())), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }, edit: (path, json) => path == '/listings/1' ? own(json) : json);
    final first = listing.sizes.first.id;
    await tester.scrollUntilVisible(find.text('Қалдық'), 300,
        scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical).first);
    await tester.ensureVisible(find.byTooltip('Көбейту').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Көбейту').first);
    await tester.pump();
    sold = true; // a buyer takes a pair before Save
    Future<void> save() async {
      await tester.tap(find.byKey(const Key('save')));
      await settle(tester);
    }

    await save();
    expect(
        sent.single['sizes'],
        [
          {'id': first, 'quantity': 3, 'was': 2}
        ],
        reason: 'only the size changed, with the count it was changed from');
    expect(asked, contains('GET /listings/1'));
    expect(find.text('Қақтығыс: stock_changed'), findsOneWidget);
    expect(find.descendant(of: find.widgetWithText(ListTile, listing.sizes.first.label), matching: find.text('1')),
        findsOneWidget,
        reason: 'the count left is shown');
    await save();
    expect(sent.last.containsKey('sizes'), isFalse, reason: 'the screen now holds the count left, 1, not 3');
  });
}
