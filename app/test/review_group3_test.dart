// Whole-app review, group 3: words and states a plain buyer or seller can follow.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/labels.dart';
import 'package:vitrina/screens/chat_screen.dart';
import 'package:vitrina/screens/help_screen.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/screens/offers_screen.dart';
import 'package:vitrina/screens/profile_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/common.dart' show LanguageSwitch;

import 'widget_test.dart' show jsonResponse, listingJson, offerJson;

Session _signedIn(MockClient client, {bool seller = false}) =>
    Session(Api(base: 'http://x/api/v1', client: client)..token = 't')
      ..update(Me.fromJson({'id': seller ? 3 : 2, 'phone': '+7701000000${seller ? 3 : 2}', 'is_seller': seller}));

void main() {
  testWidgets('a countered offer shows the seller\'s price big, and «agree» names it', (tester) async {
    final session = _signedIn(MockClient((req) async => jsonResponse({
          'items': [
            {...offerJson(status: 'countered', amount: 4000000, counter: 4300000)}
          ],
          'next_before': null,
        })));
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OffersScreen(seller: false))));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('offer-price-11'))).data, formatTenge(4300000));
    expect(find.text(trfKk('Сіз {0} ұсындыңыз', formatTenge(4000000))), findsOneWidget);
    expect(find.text('Келісемін · ${formatTenge(4300000)}'), findsOneWidget);
  });

  testWidgets('on a usual phone at large text the buyer\'s «agree» shows the whole price', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = _signedIn(MockClient((req) async => jsonResponse({
          'items': [
            {...offerJson(status: 'countered', amount: 11000000, counter: 12500000)}
          ],
          'next_before': null,
        })));
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
            home: const OffersScreen(seller: false))));
    await tester.pumpAndSettle();
    final label = find.descendant(of: find.byKey(const Key('accept-11')), matching: find.byType(RichText));
    expect((tester.renderObject(label) as RenderParagraph).didExceedMaxLines, isFalse);
    expect(find.text('Келісемін · ${formatTenge(12500000)}'), findsOneWidget);
  });

  testWidgets('an accepted offer says until when to order and opens the listing to do it', (tester) async {
    final session = _signedIn(MockClient((req) async {
      if (req.url.path == '/api/v1/offers') {
        return jsonResponse({
          'items': [offerJson(status: 'accepted')],
          'next_before': null
        });
      }
      if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
      return jsonResponse(listingJson());
    }));
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OffersScreen(seller: false))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Тапсырысты 18.10'), findsOneWidget);
    await tester.tap(find.byKey(const Key('offer-order-11')));
    await tester.pumpAndSettle();
    expect(find.byType(ListingScreen), findsOneWidget);
  });

  testWidgets('a chat still loading shows a circle, not «no messages»', (tester) async {
    final answer = Completer<http.Response>();
    final session = _signedIn(MockClient((req) => answer.future));
    await tester.pumpWidget(SessionScope(
        session: session,
        child: const MaterialApp(home: ChatScreen(conversationId: 9, pollEvery: Duration(hours: 1)))));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Хабарлама әлі жоқ.'), findsNothing);
    answer.complete(jsonResponse({'code': 'not_found'}, 404));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('signed out, «how it works» opens, and Help shows where to write to support', (tester) async {
    final session = Session(Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => jsonResponse({'payments': true, 'support': 'help@vitrina.kz'}))));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ProfileScreen())));
    await tester.pumpAndSettle();
    // The language bar under the page used to grow over it: «Кіру» took no taps.
    expect(tester.getRect(find.byType(LanguageSwitch)).top, greaterThan(tester.getRect(find.text('Кіру')).bottom));
    await tester.tap(find.byKey(const Key('help-signed-out')));
    await tester.pumpAndSettle();
    expect(find.byType(HelpScreen), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('support')), 300);
    expect(find.text('help@vitrina.kz'), findsOneWidget);
  });

  testWidgets('no support contact from the server: no made-up one is shown', (tester) async {
    final session =
        Session(Api(base: 'http://x/api/v1', client: MockClient((req) async => jsonResponse({'payments': true}))));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: HelpScreen())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support')), findsNothing);
  });

  testWidgets('a draft: putting it on sale is the main button, and it can be deleted after asking', (tester) async {
    final calls = <String>[];
    final session = _signedIn(MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.method == 'DELETE') return http.Response('', 204);
      return jsonResponse({'items': []});
    }), seller: true);
    final draft = {
      ...listingJson(),
      'status': 'draft',
      'ever_on_sale': false,
      'sizes': [
        {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': true, 'quantity': 2},
      ],
    };
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bool? result;
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () async => result = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(builder: (_) => ManageListingScreen(listing: Listing.fromJson(draft)))),
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(FilledButton), matching: find.text('Сатылымға шығару')), findsOneWidget);
    expect(find.descendant(of: find.byType(OutlinedButton), matching: find.text('Сақтау')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('delete-draft')), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('delete-draft')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.startsWith('DELETE')), isEmpty, reason: 'asked first');
    await tester.tap(find.text('Өшіру').last);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.startsWith('DELETE')), ['DELETE /api/v1/listings/7']);
    expect(result, isTrue, reason: 'the list it came from reloads');
  });

  testWidgets('a price typed with tiyn is not read as a hundred times more', (tester) async {
    final calls = <String>[];
    final session = _signedIn(MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      return jsonResponse({'items': []});
    }), seller: true);
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: ManageListingScreen(
                listing: Listing.fromJson({...listingJson(), 'status': 'published', 'ever_on_sale': true})))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('price')), '1500,00');
    await tester.pump();
    expect(tester.widget<TextFormField>(find.byKey(const Key('price'))).controller!.text, '1500,00');
    await tester.tap(find.text('Сақтау'));
    await tester.pumpAndSettle();
    expect(find.text('Тиынсыз, бүтін теңгемен жазыңыз'), findsOneWidget);
    expect(calls.where((c) => c.startsWith('PATCH')), isEmpty);
  });

  testWidgets('a draft that was on sale once (given back by a moderator) has no delete', (tester) async {
    final session = _signedIn(MockClient((req) async => jsonResponse({'items': []})), seller: true);
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: ManageListingScreen(
                listing: Listing.fromJson({...listingJson(), 'status': 'draft', 'ever_on_sale': true})))));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-draft')), findsNothing);
    expect(find.text('Сатылымға шығару'), findsOneWidget, reason: 'the page is a draft page: only delete is missing');
  });

  testWidgets('a listing once on sale has no delete, and a hidden one leads to support', (tester) async {
    final session = _signedIn(MockClient((req) async {
      if (req.url.path == '/api/v1/app-config') return jsonResponse({'payments': true, 'support': '+7 700 000 00 00'});
      return jsonResponse({'items': []});
    }), seller: true);
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(
            home: ManageListingScreen(
                listing: Listing.fromJson({...listingJson(), 'status': 'hidden', 'ever_on_sale': true})))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-draft')), findsNothing);
    expect(find.byKey(const Key('support')), findsOneWidget);
  });
}

/// The Kazakh line as the app writes it, with one value put in.
String trfKk(String template, String value) => template.replaceFirst('{0}', value);
