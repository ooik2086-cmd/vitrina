// Whole-app review, stage 105: the Medium findings no group took.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/my_size.dart';
import 'package:vitrina/screens/blocked_screen.dart';
import 'package:vitrina/screens/compare_screen.dart';
import 'package:vitrina/screens/image_search_screen.dart';
import 'package:vitrina/screens/profile_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/filter_sheet.dart';

import 'widget_test.dart' show jsonResponse, listingJson;

Session _signedIn(MockClient client) => Session(Api(base: 'http://x/api/v1', client: client)..token = 't')
  ..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  testWidgets('a price typed «20.000» is twenty thousand, letters are not taken', (tester) async {
    CatalogFilter? picked;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async => picked = await Navigator.of(context).push<CatalogFilter>(
                    MaterialPageRoute(builder: (_) => const Scaffold(body: FilterSheet(initial: CatalogFilter())))),
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('min-price')), '20.000');
    await tester.enterText(find.byKey(const Key('max-price')), '30 000');
    expect(tester.widget<TextField>(find.byKey(const Key('min-price'))).controller!.text, '20000');
    await tester.ensureVisible(find.byKey(const Key('apply-filter')));
    await tester.tap(find.byKey(const Key('apply-filter')));
    await tester.pumpAndSettle();
    expect(picked!.minPriceTiyn, 2000000);
    expect(picked!.maxPriceTiyn, 3000000);
  });

  testWidgets('unblocking asks first and says it is done', (tester) async {
    var deletes = 0;
    final session = _signedIn(MockClient((req) async {
      if (req.method == 'DELETE') {
        deletes++;
        return jsonResponse({});
      }
      return jsonResponse({
        'items': [
          {'user_id': 4, 'name': 'Айгүл', 'since': '2026-10-01T10:00:00Z'}
        ]
      });
    }));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: BlockedScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unblock-4')));
    await tester.pumpAndSettle();
    expect(find.textContaining('бұғаттан шығарылсын ба?'), findsOneWidget);
    await tester.tap(find.text('Болдырмау'));
    await tester.pumpAndSettle();
    expect(deletes, 0);
    await tester.tap(find.byKey(const Key('unblock-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(deletes, 1);
    expect(find.text('Бұғаттан шығарылды'), findsOneWidget);
  });

  testWidgets('becoming a seller waits for two letters and keeps what was typed when refused', (tester) async {
    var calls = 0;
    final answer = Completer<void>();
    final session = _signedIn(MockClient((req) async {
      if (req.url.path.endsWith('/me/seller')) {
        calls++;
        await answer.future;
        return jsonResponse({'detail': 'invalid'}, 422);
      }
      return jsonResponse({'items': []});
    }));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ProfileScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сатушы болу'));
    await tester.pumpAndSettle();
    FilledButton button() => tester.widget<FilledButton>(find.byKey(const Key('seller-on')));
    expect(button().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('seller-shop')), 'Айгүл дүкені');
    await tester.enterText(find.byKey(const Key('seller-city')), 'А');
    await tester.pump();
    expect(button().onPressed, isNull, reason: 'one letter is not a city');
    await tester.enterText(find.byKey(const Key('seller-city')), 'Алматы');
    await tester.pump();
    await tester.tap(find.byKey(const Key('seller-on')));
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(const Key('seller-close'))).onPressed, isNull,
        reason: 'closing now would turn seller mode on without a word');
    answer.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const Key('seller-error')), findsOneWidget);
    expect(find.text('Айгүл дүкені'), findsOneWidget, reason: 'the dialog stays, with the words in it');
  });

  testWidgets('search by photo asks only for pairs in the buyer\'s size, and says so', (tester) async {
    mySize.value = '26,5';
    addTearDown(() => mySize.value = null);
    Uri? asked;
    final session = _signedIn(MockClient((req) async {
      asked = req.url;
      return jsonResponse({'items': []});
    }));
    await tester.pumpWidget(SessionScope(
        session: session, child: MaterialApp(home: ImageSearchScreen(bytes: base64Decode(_png), filename: 'q.png'))));
    await tester.pumpAndSettle();
    expect(asked!.queryParameters['size_cm'], '26,5');
    expect(find.textContaining('26,5 см аяққа келетін тауарлар'), findsOneWidget);
    expect(find.text('26,5 см аяққа келетін ұқсас тауар табылмады.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('all-sizes')));
    await tester.pumpAndSettle();
    expect(asked!.queryParameters.containsKey('size_cm'), isFalse);
    expect(mySize.value, '26,5', reason: 'the saved size stays');
    expect(find.text('Ұқсас тауар табылмады.'), findsOneWidget);
  });

  testWidgets('compare names a pair that is gone and never calls it the cheapest', (tester) async {
    Listing make(int id, int price, {String status = 'published'}) => Listing.fromJson({
          ...listingJson(),
          'id': id,
          'title': 'Shoe $id',
          'status': status,
          'price_tiyn': price,
          'delivery_price_tiyn': 0,
        });
    final sold = make(1, 1000000, status: 'sold'), a = make(2, 4500000), b = make(3, 4700000);
    expect(cheapestIds([sold, a, b]), {2});
    await tester.pumpWidget(MaterialApp(home: CompareScreen(items: [sold, a, b])));
    expect(find.byKey(const Key('compare-gone-1')), findsOneWidget);
    expect(find.byKey(const Key('compare-cheapest-1')), findsNothing);
  });
}
