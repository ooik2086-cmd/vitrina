// Whole-app review, group 2: the main things a buyer and a seller do, each with what used to go wrong.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/screens/earnings_screen.dart';
import 'package:vitrina/screens/favorites_screen.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/notifications_screen.dart';
import 'package:vitrina/screens/promo_codes_screen.dart';
import 'package:vitrina/screens/shop_screen.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/common.dart';

import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/widgets/delivery_sheet.dart';

import 'widget_test.dart' show jsonResponse, listingJson, offerJson, testDelivery;

Map<String, dynamic> _earnings() => {'held_tiyn': 0, 'payable_tiyn': 500000, 'fees_tiyn': 0, 'items': []};

Map<String, dynamic> _payouts() => {
      'payable_tiyn': 500000,
      'min_tiyn': 100000,
      'has_account': true,
      'iban_masked': 'KZ86 •••• 0100',
      'ready_at': null,
      'open': false,
      'items': [],
    };

Session _seller(MockClient client) => Session(Api(base: 'http://x/api/v1', client: client)..token = 't')
  ..update(Me.fromJson({'id': 3, 'phone': '+77010000003', 'is_seller': true}));

void main() {
  testWidgets('a listing already in favourites shows a full heart, and a tap says what happened', (tester) async {
    final calls = <String>[];
    final client = MockClient((req) async {
      if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
      if (req.url.path.endsWith('/favorites/7')) {
        calls.add(req.method);
        return http.Response('', 204);
      }
      return jsonResponse({...listingJson(), 'favorite': true});
    });
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = Session(Api(base: 'http://x/api/v1', client: client)..token = 't')
      ..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    await tester.tap(find.byIcon(Icons.favorite));
    await tester.pumpAndSettle();
    expect(calls, ['DELETE']);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.text('Таңдаулыдан алынды.'), findsOneWidget);
  });

  testWidgets('favourites reload when a heart changes elsewhere', (tester) async {
    var reads = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.method == 'GET' && req.url.path == '/api/v1/favorites') {
            reads++;
            return jsonResponse({
              'items': reads == 1 ? [] : [listingJson()],
              'next_before': null
            });
          }
          return http.Response('', 204);
        }))
      ..token = 't';
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: FavoritesScreen())));
    await tester.pumpAndSettle();
    expect(find.textContaining('Таңдаулы тауар әлі жоқ'), findsOneWidget);
    await api.setFavorite(7, true);
    await api.setFavorite(7, false);
    await api.setFavorite(7, true);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(reads, 2, reason: 'three taps, one reload');
    expect(find.text('Nike Air Force 1'), findsOneWidget);
  });

  testWidgets('a refused camera says so instead of doing nothing', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    }))));
    final XFile? photo =
        await takePhoto(context, () async => throw PlatformException(code: 'camera_access_denied'), camera: true);
    await tester.pump();
    expect(photo, isNull);
    expect(find.textContaining('Камераға рұқсат берілмеді'), findsOneWidget);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    // Not a refused permission: no wrong advice to change the phone's settings.
    await takePhoto(context, () async => throw PlatformException(code: 'invalid_image'), camera: true);
    await tester.pump();
    expect(find.text('Фотоны ашу мүмкін болмады. Қайта көріңіз.'), findsOneWidget);
  });

  testWidgets('the promo sheet checks its numbers and shows a server refusal inside itself', (tester) async {
    final bodies = <Object?>[];
    final session = _seller(MockClient((req) async {
      bodies.add(jsonDecode(req.body));
      return jsonResponse({'code': 'promo_taken', 'message_kk': 'Бұл код бос емес.'}, 409);
    }));
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: Scaffold(body: PromoCodeSheet()))));
    await tester.enterText(find.byKey(const Key('promo-new-code')), 'QADAM10');
    await tester.enterText(find.byKey(const Key('promo-new-value')), '1x0');
    expect(find.text('10'), findsOneWidget); // only digits are typed in
    await tester.enterText(find.byKey(const Key('promo-new-max-uses')), '0');
    await tester.tap(find.byKey(const Key('promo-save')));
    await tester.pumpAndSettle();
    expect(find.text('1-ден 100 000-ға дейін'), findsOneWidget);
    expect(bodies, isEmpty);
    await tester.enterText(find.byKey(const Key('promo-new-max-uses')), '20');
    await tester.tap(find.byKey(const Key('promo-save')));
    await tester.pumpAndSettle();
    expect(bodies, [
      {'code': 'QADAM10', 'percent': 10, 'max_uses': 20}
    ]);
    expect(find.byKey(const Key('promo-error')), findsOneWidget);
    expect(find.text('Бұл код бос емес.'), findsOneWidget);
  });

  testWidgets('a payouts load that fails is said as a failure with a retry, not as "not offered"', (tester) async {
    var fail = true;
    final session = _seller(MockClient((req) async {
      if (req.url.path.endsWith('/me/payouts')) {
        return fail ? http.Response('<html>Bad Gateway</html>', 502) : jsonResponse(_payouts());
      }
      return jsonResponse(_earnings());
    }));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: EarningsScreen())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payouts-failed')), findsOneWidget);
    expect(find.textContaining('Төлем серіктесі қосылғанда'), findsNothing);
    fail = false;
    await tester.tap(find.descendant(of: find.byKey(const Key('payouts-retry')), matching: find.byType(TextButton)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payouts-failed')), findsNothing);
    expect(find.byKey(const Key('payout')), findsOneWidget);
  });

  testWidgets('notes about payouts and about a seller\'s own listing open the right page', (tester) async {
    final asked = <String>[];
    final session = _seller(MockClient((req) async {
      asked.add(req.url.path);
      if (req.url.path.endsWith('/me/payouts')) return jsonResponse(_payouts());
      if (req.url.path == '/api/v1/listings/7') {
        return jsonResponse({
          ...listingJson(),
          'status': 'hidden',
          'seller': {'id': 3, 'shop_name': 'Qadam Store'}
        });
      }
      if (req.url.path.startsWith('/api/v1/listings/7/')) return jsonResponse({'items': []});
      return jsonResponse(_earnings());
    }));
    late BuildContext context;
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(home: Scaffold(body: Builder(builder: (c) {
          context = c;
          return const SizedBox();
        })))));
    openNotice(context, 'payout');
    await tester.pumpAndSettle();
    expect(find.byType(EarningsScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(EarningsScreen))).pop();
    await tester.pumpAndSettle();

    for (final kind in ['moderation', 'listing_hidden', 'authenticity']) {
      asked.clear();
      openNotice(context, kind, listingId: 7);
      await tester.pumpAndSettle();
      expect(asked.first, '/api/v1/listings/7', reason: kind);
      expect(find.byType(ListingScreen), findsNothing, reason: kind); // the seller's own page, not the shop one
      expect(find.byType(ManageListingScreen), findsOneWidget, reason: kind);
      Navigator.of(tester.element(find.byType(ManageListingScreen))).pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a shop with more than 50 listings shows the rest as you scroll', (tester) async {
    final offsets = <String?>[];
    final session = _seller(MockClient((req) async {
      if (req.url.path == '/api/v1/listings') {
        final offset = req.url.queryParameters['offset'];
        offsets.add(offset);
        final from = offset == null ? 0 : int.parse(offset);
        final n = from == 0 ? 50 : 3;
        return jsonResponse({
          'items': [
            for (var i = 0; i < n; i++) {...listingJson(), 'id': 100 + from + i, 'title': 'Тауар ${from + i}'}
          ]
        });
      }
      return jsonResponse({
        'id': 3,
        'shop_name': 'Sneaker Lab',
        'city': 'Алматы',
        'since': '2026-01-10',
        'completed_sales': 4,
        'listings': 53,
        'rating': null,
        'reviews': 0,
        'away_until': null,
        'reply_time': null,
        'ship_time': null,
        'followers': 0,
        'following': false,
      });
    }));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ShopScreen(sellerId: 3))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Тауар 52'), 600, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(offsets, [null, '50']);
    expect(find.text('Тауар 52'), findsOneWidget);
  });

  testWidgets('a code typed but not applied is checked on «order», and a refused one is cleared in one tap',
      (tester) async {
    final checked = <String>[];
    final session = _seller(MockClient((req) async {
      final code = req.url.queryParameters['code']!;
      checked.add(code);
      if (code == 'BAD1') return jsonResponse({'code': 'promo_invalid', 'message_kk': 'Промокод жарамсыз.'}, 404);
      return jsonResponse({'code': code, 'discount_tiyn': 100000, 'item_price_tiyn': 900000, 'total_tiyn': 1050000});
    }));
    Checkout? result;
    await tester.pumpWidget(SessionScope(
        session: session,
        child: MaterialApp(home: Scaffold(body: Builder(builder: (context) {
          return TextButton(
              onPressed: () async => result = await showModalBottomSheet<Checkout>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const DeliverySheet(
                      listingId: 7,
                      itemPriceTiyn: 1000000,
                      deliveryPriceTiyn: 150000,
                      initial: Checkout(testDelivery))),
              child: const Text('open'));
        })))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('promo-open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('promo-code')), 'BAD1');
    await tester.ensureVisible(find.byKey(const Key('delivery-continue')));
    await tester.tap(find.byKey(const Key('delivery-continue')));
    await tester.pumpAndSettle();
    expect(checked, ['BAD1']);
    expect(result, isNull, reason: 'a refused code stops the order and says why');
    expect(find.text('Промокод жарамсыз.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('promo-clear')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('promo-code')), 'QADAM10');
    await tester.tap(find.byKey(const Key('delivery-continue')));
    await tester.pumpAndSettle();
    expect(checked, ['BAD1', 'QADAM10']);
    expect(result?.promoCode, 'QADAM10');
  });

  testWidgets('signing in from «buy» with an offer for another size stops and selects that size', (tester) async {
    final orders = <http.Request>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          if (req.url.path == '/api/v1/app-config') return jsonResponse({'payments': true});
          if (req.url.path == '/api/v1/offers') {
            return jsonResponse({
              'items': [
                {...offerJson(status: 'pending'), 'size_id': 3, 'size_label': '41'}
              ],
              'next_before': null
            });
          }
          if (req.url.path == '/api/v1/orders') orders.add(req);
          return jsonResponse({
            ...listingJson(),
            'sizes': [
              {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': true},
              {'id': 3, 'label': '41', 'insole_cm': '26,5', 'available': true},
            ],
          });
        }));
    final session = Session(api);
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('size-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('buy')));
    await tester.pumpAndSettle();
    // Signed in on the login page, then back.
    api.token = 't';
    session.update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(DeliverySheet), findsNothing, reason: 'nothing is ordered in a size she did not pick');
    expect(find.textContaining('41 өлшеміне ұсыныс бар'), findsOneWidget);
    expect(orders, isEmpty);
  });
}
