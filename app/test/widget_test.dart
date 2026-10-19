import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/appearance.dart';
import 'package:vitrina/colors.dart';
import 'package:vitrina/demo.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/theme.dart';
import 'package:vitrina/labels.dart';
import 'package:vitrina/my_size.dart';
import 'package:vitrina/quick_replies.dart';
import 'package:vitrina/recent.dart';
import 'package:vitrina/screens/analytics_screen.dart';
import 'package:vitrina/screens/catalog_screen.dart';
import 'package:vitrina/screens/chat_screen.dart';
import 'package:vitrina/screens/compare_screen.dart';
import 'package:vitrina/screens/earnings_screen.dart';
import 'package:vitrina/screens/image_search_screen.dart';
import 'package:vitrina/screens/listing_editor_screen.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/login_screen.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/widgets/listing_contents.dart';
import 'package:vitrina/screens/my_listings_screen.dart';
import 'package:vitrina/screens/notification_settings_screen.dart';
import 'package:vitrina/screens/onboarding_screen.dart';
import 'package:vitrina/screens/offers_screen.dart';
import 'package:vitrina/screens/order_screen.dart';
import 'package:vitrina/listing_quality.dart';
import 'package:vitrina/screens/help_screen.dart';
import 'package:vitrina/main.dart';
import 'package:vitrina/widgets/todo_card.dart';
import 'package:vitrina/widgets/delivery_eta.dart';
import 'package:vitrina/screens/orders_screen.dart';
import 'package:vitrina/screens/profile_screen.dart';
import 'package:vitrina/screens/saved_searches_screen.dart';
import 'package:vitrina/screens/seller_reviews_screen.dart';
import 'package:vitrina/screens/shop_screen.dart';
import 'package:vitrina/screens/spin_capture_screen.dart';
import 'package:vitrina/widgets/shop_sale.dart';
import 'package:vitrina/en.dart';
import 'package:vitrina/ru.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/delivery_sheet.dart';
import 'package:vitrina/widgets/questions.dart';
import 'package:vitrina/widgets/size_guide.dart';
import 'package:vitrina/widgets/card_turn.dart';
import 'package:vitrina/widgets/filter_sheet.dart';
import 'package:vitrina/widgets/spin_viewer.dart';
import 'package:vitrina/widgets/studio.dart';

Map<String, dynamic> listingJson({List<Map<String, dynamic>>? media}) => {
      'id': 7,
      'status': 'published',
      'title': 'Nike Air Force 1',
      'category': 'sneakers',
      'brand': 'Nike',
      'model_name': 'AF1',
      'color': 'ақ',
      'price_tiyn': 4500000,
      'delivery_price_tiyn': 150000,
      'segment': null,
      'condition': 'used_good',
      'authenticity': 'unverified',
      'defects': 'Сол жақ тұмсығында сызат',
      'description': null,
      'showcase_style': 'clean',
      'sizes': [
        {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': true},
        {'id': 2, 'label': '43', 'insole_cm': '27,5', 'available': false},
      ],
      'media': media ?? [],
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы'},
    };

Map<String, dynamic> offerJson({String status = 'pending', int amount = 4000000, int? counter}) => {
      'id': 11,
      'listing_id': 7,
      'listing_title': 'Nike Air Force 1',
      'listing_cover': null,
      'list_price_tiyn': 4500000,
      'size_id': 1,
      'size_label': '42',
      'amount_tiyn': amount,
      'counter_tiyn': counter,
      'price_tiyn': counter ?? amount,
      'status': status,
      'expires_at': '2026-10-18T10:00:00+00:00',
    };

const testDelivery =
    Delivery(recipientName: 'Айгерім', recipientPhone: '+77010000002', city: 'Алматы', address: 'Абай 10, 25');

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('every Kazakh phrase passed to tr() has a Russian and an English translation', () {
    final call = RegExp(r"\btrf?\('((?:[^'\\]|\\.)*)'");
    final missing = <String>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      for (final m in call.allMatches(f.readAsStringSync())) {
        final key = m.group(1)!.replaceAll(r'\n', '\n').replaceAll(r"\'", "'");
        if (!ru.containsKey(key)) missing.add('ru: $key');
        if (!en.containsKey(key)) missing.add('en: $key');
      }
    }
    expect(missing, isEmpty);
    // The tables are kept in step, so a phrase translated into one language is never left out of the other.
    expect(en.keys.toSet().difference(ru.keys.toSet()), isEmpty);
    expect(ru.keys.toSet().difference(en.keys.toSet()), isEmpty);
    for (final e in en.entries) {
      for (final p in RegExp(r'\{\d\}').allMatches(e.key)) {
        expect(e.value, contains(p.group(0)), reason: e.key);
      }
    }
  });

  testWidgets('switching to Russian rebuilds the screen and server errors follow', (tester) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => appLanguage.value = 'kk');
    await tester.pumpWidget(ValueListenableBuilder<String>(
      valueListenable: appLanguage,
      builder: (_, lang, __) => MaterialApp(
        key: ValueKey(lang),
        home: Scaffold(body: ListView(children: const [LanguageSwitch(), FilterSheet(initial: CatalogFilter())])),
      ),
    ));
    expect(find.text('Арзанырақ'), findsOneWidget);
    await tester.tap(find.text('РУС'));
    await tester.pumpAndSettle();
    expect(find.text('Сначала дешевле'), findsOneWidget);
    expect(find.text('Арзанырақ'), findsNothing);
    expect((await SharedPreferences.getInstance()).getString('vitrina_lang'), 'ru');
    expect(ApiException(409, 'out_of_stock', 'Бұл өлшем таусылды.', null, 'Этот размер закончился.').message,
        'Этот размер закончился.');
    await tester.tap(find.text('ENG'));
    await tester.pumpAndSettle();
    expect(find.text('Price: low to high'), findsOneWidget);
    expect(
        ApiException(409, 'out_of_stock', 'Бұл өлшем таусылды.', null, 'Этот размер закончился.',
                'This size is out of stock.')
            .message,
        'This size is out of stock.');
  });

  test('tenge formatting keeps integer tiyn', () {
    expect(formatTenge(4500000), '45 000 ₸');
    expect(formatTenge(123), '1,23 ₸');
    expect(formatTenge(100000000), '1 000 000 ₸');
  });

  test('api errors carry the Kazakh message', () async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((_) async => http.Response(
            jsonEncode({'code': 'out_of_stock', 'message_kk': 'Бұл өлшем таусылды.', 'message_ru': '…'}), 409,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    await expectLater(
        api.createOrder(1, 1, 'k', delivery: testDelivery),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'out_of_stock')
            .having((e) => e.messageKk, 'message', 'Бұл өлшем таусылды.')));
  });

  test('chat photo goes as multipart with its caption', () async {
    late http.BaseRequest seen;
    String? body;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient.streaming((req, stream) async {
          seen = req;
          body = await stream.bytesToString();
          return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode({
                'id': 4,
                'sender_id': 2,
                'body': 'Табаны',
                'photo_url': 'http://x/media/2/a.jpg',
                'contact_warning': false,
                'created_at': '2026-10-17T10:00:00Z'
              }))),
              201,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }))
      ..token = 't';
    final m = await api.sendChatPhoto(9, [1, 2, 3], 'a.jpg', caption: 'Табаны');
    expect(seen.url.path, '/api/v1/conversations/9/photos');
    expect(seen.headers['Authorization'], 'Bearer t');
    expect(body, contains('name="caption"'));
    expect(m.photoUrl, 'http://x/media/2/a.jpg');
  });

  test('saved size picks the closest available size within half a centimetre', () async {
    SharedPreferences.setMockInitialValues({});
    final sizes = [
      for (final s in (listingJson()['sizes'] as List)) ShoeSize.fromJson(s as Map<String, dynamic>),
    ]; // 42 = 27,0 cm available; 43 = 27,5 cm sold out
    expect(bestFit(sizes, '27')?.label, '42');
    expect(bestFit(sizes, '27,5')?.label, '42'); // 43 fits better but is sold out
    expect(bestFit(sizes, '28,5'), isNull);
    expect(bestFit(sizes, null), isNull);
    await setMySize('26,5');
    await restoreMySize();
    expect(mySize.value, '26,5');
    expect((await SharedPreferences.getInstance()).getString('vitrina_size_cm'), '26,5');
    await setMySize(null);
    expect(mySize.value, isNull);
  });

  test('share link points at the public listing page, not the API', () {
    expect(listingShareUrl(7, base: 'https://vitrina.kz/api/v1'), 'https://vitrina.kz/l/7');
    expect(listingShareUrl(7, base: 'http://10.0.2.2:8000/api/v1/'), 'http://10.0.2.2:8000/l/7');
    expect(shopShareUrl(3, base: 'https://vitrina.kz/api/v1'), 'https://vitrina.kz/s/3');
  });

  test('suggestions come back field by field and empty when nothing looks alike', () async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          final url = (jsonDecode(req.body) as Map)['photo_url'];
          final known = url == 'http://x/media/1/a.jpg';
          return http.Response(
              jsonEncode({
                'category': known ? 'sneakers' : null,
                'brand': known ? 'Nike' : null,
                'model_name': null,
                'based_on': known ? 2 : 0,
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    final s = await api.suggestDetails('http://x/media/1/a.jpg');
    expect((s.brand, s.modelName, s.category, s.isEmpty), ('Nike', null, 'sneakers', false));
    expect((await api.suggestDetails('http://x/media/1/b.jpg')).isEmpty, isTrue);
  });

  test('recently viewed keeps the newest first, without repeats, up to the limit', () async {
    SharedPreferences.setMockInitialValues({});
    await forgetRecent();
    for (var i = 1; i <= recentLimit + 3; i++) {
      await rememberViewed(Listing.fromJson({...listingJson(), 'id': i, 'title': 'Shoe $i'}));
    }
    await rememberViewed(Listing.fromJson({...listingJson(), 'id': 5, 'title': 'Shoe 5'}));
    expect(recentlyViewed.value.length, recentLimit);
    expect(recentlyViewed.value.first.id, 5);
    expect(recentlyViewed.value.where((r) => r.id == 5).length, 1);
    recentlyViewed.value = const [];
    await restoreRecent(); // survives an app restart
    expect(recentlyViewed.value.first.title, 'Shoe 5');
    await forgetRecent();
    expect(recentlyViewed.value, isEmpty);
  });

  test('order creation sends the idempotency key', () async {
    String? key;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          key = req.headers['Idempotency-Key'];
          return http.Response(
              jsonEncode({
                'id': 5,
                'status': 'CREATED',
                'listing_id': 1,
                'size_id': 1,
                'buyer_id': 2,
                'seller_id': 3,
                'item_price_tiyn': 100,
                'delivery_price_tiyn': 0,
                'total_tiyn': 100,
                'tracking_number': null,
                'delivered_at': null,
              }),
              201);
        }));
    final order = await api.createOrder(1, 1, 'abc', delivery: testDelivery);
    expect(key, 'abc');
    expect(order.status, 'CREATED');
  });

  testWidgets('spin viewer steps through real frames on drag', (tester) async {
    final urls = [for (var i = 0; i < 12; i++) 'http://x/f$i.jpg'];
    await tester.pumpWidget(MaterialApp(
        home: SizedBox(
            width: 300, height: 300, child: SpinViewer(frameUrls: urls, pixelsPerFrame: 10, introSpin: false))));
    Image current() => tester.widget<Image>(find.byType(Image));
    expect((current().image as NetworkImage).url, urls[0]);
    await tester.drag(find.byType(SpinViewer), const Offset(-35, 0));
    await tester.pump();
    final after = (current().image as NetworkImage).url;
    expect(after, isNot(urls[0]));
    expect(urls, contains(after));
  });

  testWidgets('product page sums up how the size fits, and the verdict needs a clear lead', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          return jsonResponse({
            ...listingJson(),
            'size_fit': {'answers': 5, 'small': 3, 'true': 2, 'large': 0},
          });
        }));
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    expect(find.text('Кішілеу келеді'), findsOneWidget);
    expect(find.text('Жарты өлшем үлкенін алыңыз'), findsOneWidget);
    expect(find.text('5 сатып алушы'), findsOneWidget);
    SizeFit fit(int s, int t, int l) => SizeFit.fromJson({'answers': s + t + l, 'small': s, 'true': t, 'large': l});
    expect(fit(1, 8, 1).verdict, 'true');
    expect(fit(4, 2, 4).verdict, 'true'); // split both ways: no advice beats wrong advice
    expect(fit(0, 3, 2).verdict, 'large');
  });

  testWidgets('product page shows real demand only when the server sends it', (tester) async {
    Map<String, dynamic>? popularity = {'sold_30d': 2, 'favorites': 5};
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          return jsonResponse({...listingJson(), 'popularity': popularity});
        }));
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    expect(find.text('30 күнде 2 жұп сатып алынды · 5 адам таңдаулыға қосты'), findsOneWidget);
    popularity = null;
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingScreen(listingId: 8))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('popularity')), findsNothing);
  });

  testWidgets('tapping a sold-out size asks to hear when it is back, and again turns it off', (tester) async {
    final calls = <String>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path == '/api/v1/listings/7/sizes/2/alert') {
            calls.add(req.method);
            return jsonResponse({'size_id': 2, 'alert': req.method == 'PUT'});
          }
          if (req.url.path == '/api/v1/offers') return jsonResponse({'items': [], 'waiting': 0});
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          return jsonResponse(listingJson());
        }))
      ..token = 'tok';
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
    await tester.tap(find.text('43'));
    await tester.pumpAndSettle();
    expect(find.text('43 өлшемі қайта шыққанда хабарлаймыз.'), findsOneWidget);
    expect(find.byIcon(Icons.notifications_active), findsOneWidget);
    expect(find.text('Тапсырыс беру'), findsNothing); // a sold-out size is never selected for ordering
    await tester.tap(find.text('43'));
    await tester.pumpAndSettle();
    expect(calls, ['PUT', 'DELETE']);
    expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
  });

  testWidgets('product page keeps segment, condition and authenticity apart and shows defects', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((_) async => http.Response(jsonEncode(listingJson()), 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
      session: Session(api),
      child: const MaterialApp(home: ListingScreen(listingId: 7)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Баға деңгейі'), findsOneWidget);
    expect(find.text('Деректер әлі аз'), findsOneWidget); // no invented segment while data is thin
    expect(find.text('Киілген, жақсы'), findsOneWidget);
    expect(find.text('Тексерілмеген'), findsOneWidget);
    expect(find.textContaining('сызат'), findsOneWidget);
    expect(find.text('Өлшемді таңдаңыз'), findsOneWidget);
    await tester.tap(find.text('42'));
    await tester.pump();
    expect(find.text('Тапсырыс беру'), findsOneWidget);
  });

  testWidgets('buyer follows a shop from its page', (tester) async {
    final calls = <String>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path == '/api/v1/sellers/3/follow') {
            calls.add(req.method);
            final on = req.method == 'PUT';
            return jsonResponse({'following': on, 'followers': on ? 13 : 12});
          }
          if (req.url.path == '/api/v1/sellers/3') {
            return jsonResponse({
              'id': 3,
              'shop_name': 'Sneaker Lab',
              'city': 'Алматы',
              'since': '2026-01-10',
              'completed_sales': 4,
              'listings': 0,
              'rating': 4.8,
              'reviews': 5,
              'away_until': null,
              'reply_time': {'minutes': 40, 'bucket': 'hour'},
              'ship_time': {'hours': 20, 'orders': 4, 'bucket': 'day'},
              'followers': 12,
              'following': false,
            });
          }
          return jsonResponse({'items': [], 'next_cursor': null});
        }))
      ..token = 'tok';
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ShopScreen(sellerId: 3))));
    await tester.pumpAndSettle();
    expect(find.text('12 жазылушы'), findsOneWidget);
    expect(find.text('Әдетте бір сағат ішінде жауап береді'), findsOneWidget);
    expect(find.text('Әдетте төлемнен кейін бір күнде жібереді'), findsOneWidget);
    await tester.tap(find.byKey(const Key('follow')));
    await tester.pumpAndSettle();
    expect(find.text('13 жазылушы'), findsOneWidget);
    expect(find.byKey(const Key('unfollow')), findsOneWidget);
    await tester.tap(find.byKey(const Key('unfollow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('follow')), findsOneWidget);
    expect(calls, ['PUT', 'DELETE']);
  });

  testWidgets('buyer offers a price from the product page and sees it waiting', (tester) async {
    Map<String, dynamic>? sent;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path == '/api/v1/offers') return jsonResponse({'items': [], 'waiting': 0});
          if (req.url.path == '/api/v1/listings/7/offers') {
            sent = jsonDecode(req.body) as Map<String, dynamic>;
            return jsonResponse(offerJson(amount: sent!['amount_tiyn'] as int), 201);
          }
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          return jsonResponse(listingJson());
        }))
      ..token = 'tok';
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    expect(find.text('Баға ұсыну үшін өлшемді таңдаңыз'), findsOneWidget);
    await tester.tap(find.text('42'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('make-offer')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('offer-amount')), '20000');
    await tester.tap(find.byKey(const Key('offer-send')));
    await tester.pump();
    expect(find.textContaining('Кемінде'), findsOneWidget); // under half the price never leaves the phone
    expect(sent, isNull);
    await tester.tap(find.byKey(const Key('offer-10')));
    await tester.tap(find.byKey(const Key('offer-send')));
    await tester.pumpAndSettle();
    expect(sent, {'size_id': 1, 'amount_tiyn': 4050000});
    expect(find.byKey(const Key('offer-card')), findsOneWidget);
    expect(find.textContaining('Сіздің ұсынысыңыз'), findsOneWidget);
    expect(find.byKey(const Key('make-offer')), findsNothing);
  });

  testWidgets('an accepted offer orders at the agreed price', (tester) async {
    Map<String, dynamic>? ordered;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path == '/api/v1/offers') {
            return jsonResponse({
              'items': [offerJson(status: 'accepted')],
              'waiting': 0
            });
          }
          if (req.url.path == '/api/v1/orders') {
            ordered = jsonDecode(req.body) as Map<String, dynamic>;
            return jsonResponse({'code': 'offer_not_active', 'message_kk': 'Мерзімі өтті', 'message_ru': 'Истёк'}, 409);
          }
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          return jsonResponse(listingJson());
        }))
      ..token = 'tok';
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    expect(find.textContaining('бағасы қабылданды'), findsOneWidget);
    await tester.tap(find.text('42'));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('total'))).data, formatTenge(4000000 + 150000));
    await tester.tap(find.text('Келісілген бағамен алу'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('promo-open')), findsNothing); // no promo code on top of an agreed price
    await tester.tap(find.byKey(const Key('delivery-continue')));
    await tester.pump();
    expect(find.text('Аты-жөнін жазыңыз'), findsOneWidget); // nothing leaves the phone without an address
    await tester.enterText(find.byKey(const Key('delivery-name')), 'Айгерім Сапарова');
    await tester.enterText(find.byKey(const Key('delivery-phone')), '8 (701) 000-00-02');
    await tester.enterText(find.byKey(const Key('delivery-city')), 'Алматы');
    await tester.enterText(find.byKey(const Key('delivery-address')), 'Абай даңғылы 10, 25');
    await tester.tap(find.byKey(const Key('delivery-continue')));
    await tester.pumpAndSettle();
    expect(ordered, {
      'listing_id': 7,
      'size_id': 1,
      'delivery': {
        'recipient_name': 'Айгерім Сапарова',
        'recipient_phone': '+77010000002',
        'city': 'Алматы',
        'address': 'Абай даңғылы 10, 25',
      },
      'offer_id': 11,
    });
  });

  test('seller listing filter: status, low stock and text across title, brand and model', () {
    Listing make(String status, int qty, {String title = 'Nike Air Force 1'}) => Listing.fromJson({
          ...listingJson(),
          'status': status,
          'title': title,
          'sizes': [
            {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': qty > 0, 'quantity': qty},
          ],
        });
    final onSale = make('published', 3), last = make('published', 1), sold = make('sold', 0);
    final other = make('published', 4, title: 'Жеңіл кроссовка');
    expect([onSale, last, sold, other].where((l) => listingMatches(l, status: 'low', query: '')), [last]);
    expect([onSale, last, sold].where((l) => listingMatches(l, status: 'sold', query: '')), [sold]);
    expect(listingMatches(other, status: 'all', query: 'af1'), isTrue); // the model name, not the title
    expect(listingMatches(other, status: 'all', query: 'adidas'), isFalse);
    expect(listingMatches(onSale, status: 'all', query: 'AIR'), isTrue);
  });

  testWidgets('compare marks the cheapest total and checks the buyer\'s size', (tester) async {
    mySize.value = '27,0';
    addTearDown(() => mySize.value = null);
    Listing make(int id, int price, int delivery, String cm) => Listing.fromJson({
          ...listingJson(),
          'id': id,
          'title': 'Shoe $id',
          'price_tiyn': price,
          'delivery_price_tiyn': delivery,
          'sizes': [
            {'id': id, 'label': 'EU $id', 'insole_cm': cm, 'available': true},
          ],
        });
    final a = make(1, 4500000, 150000, '27,0'), b = make(2, 4400000, 300000, '28,5'), c = make(3, 4650000, 0, '27,0');
    expect(cheapestIds([a, b, c]), {1, 3});
    expect(cheapestIds([a]), isEmpty);
    await tester.pumpWidget(MaterialApp(home: CompareScreen(items: [a, b, c])));
    expect(find.byKey(const Key('compare-cheapest-1')), findsOneWidget);
    expect(find.byKey(const Key('compare-total-3')), findsNothing); // only the first two start picked
    await tester.tap(find.byKey(const Key('compare-pick-3')));
    await tester.pump();
    expect(find.byKey(const Key('compare-cheapest-3')), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Жоқ'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('EU 1'), findsOneWidget);
    expect(find.text('Жоқ'), findsOneWidget); // b has nothing within half a centimetre of 27,0
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('compare-pick-2')));
    await tester.tap(find.byKey(const Key('compare-pick-1')));
    await tester.pump();
    expect(find.text('Салыстыру үшін кемінде екі тауар таңдаңыз.'), findsOneWidget);
  });

  testWidgets('intro shows once: three pages, then it is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await restoreOnboarded();
    expect(onboarded.value, isFalse);
    addTearDown(() => onboarded.value = true);
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<bool>(
      valueListenable: onboarded,
      builder: (_, done, __) => done ? const Text('home') : const OnboardingScreen(),
    )));
    expect(find.text('Аяқкиімді 360° айналдырып көріңіз'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Ақшаңыз қорғалған'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding-size')), findsOneWidget);
    expect(find.text('Бастау'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool('vitrina_onboarded'), isTrue);
    onboarded.value = false;
    await restoreOnboarded();
    expect(onboarded.value, isTrue);
  });

  testWidgets('theme choice applies at once and is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({'vitrina_theme': 'dark'});
    await restoreThemeMode();
    expect(themeMode.value, ThemeMode.dark);
    addTearDown(() => themeMode.value = ThemeMode.system);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: ThemeSwitch()))));
    await tester.tap(find.byIcon(Icons.light_mode_outlined));
    await tester.pump();
    expect(themeMode.value, ThemeMode.light);
    expect((await SharedPreferences.getInstance()).getString('vitrina_theme'), 'light');
  });

  testWidgets('shop sale previews the cut, sends the percent, and offers to end a running sale', (tester) async {
    final sent = <String>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          sent.add('${req.method} ${req.url.path} ${req.body}');
          return jsonResponse({'changed': 2});
        }));
    final onSale = Listing.fromJson({...listingJson(), 'id': 8, 'was_price_tiyn': 5000000});
    final items = [Listing.fromJson(listingJson()), onSale];
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) =>
                        TextButton(onPressed: () => showShopSale(context, items), child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Мысалы: ${formatTenge(4500000)} → ${formatTenge(3825000)}'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sale-20')));
    await tester.pump();
    expect(find.text('Барлығына −20%'), findsOneWidget);
    expect(find.text('Жеңілдікті аяқтау (1 тауар)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sale-start')));
    await tester.pumpAndSettle();
    expect(sent, ['POST /api/v1/me/shop-sale {"percent":20}']);
    expect(find.text('Жеңілдік 2 тауарға қосылды.'), findsOneWidget);
    expect(salePrice(1299000, 15), 1104200);
  });

  testWidgets('order page opens the chat with the other side, and says when that is blocked', (tester) async {
    final posts = <String>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.method == 'POST') {
            posts.add(req.url.path);
            return jsonResponse({
              'code': 'blocked',
              'message_kk': 'Бұл пайдаланушымен байланысу мүмкін емес.',
            }, 403);
          }
          return jsonResponse({
            'id': 5,
            'status': 'PAID',
            'listing_id': 7,
            'buyer_id': 2,
            'seller_id': 1,
            'total_tiyn': 4650000,
            'history': [],
          });
        }));
    final session = Session(api)..update(Me.fromJson({'id': 1, 'phone': '+77010000001', 'is_seller': true}));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrderScreen(orderId: 5))));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Сатып алушыға жазу'), findsOneWidget);
    await tester.tap(find.byKey(const Key('order-chat')));
    await tester.pumpAndSettle();
    expect(posts, ['/api/v1/orders/5/conversation']);
    expect(find.text('Бұл пайдаланушымен байланысу мүмкін емес.'), findsOneWidget);
  });

  testWidgets('orders show which ones wait on you and filter to them', (tester) async {
    Map<String, dynamic> order(int id, String status) => {
          'id': id,
          'status': status,
          'listing_id': 7,
          'buyer_id': 2,
          'seller_id': 1,
          'total_tiyn': 4650000,
          'listing_title': 'Shoe $id',
        };
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => jsonResponse({
              'items': [order(1, 'PAYMENT_PENDING'), order(2, 'SHIPPED'), order(3, 'COMPLETED')]
            })))
      ..token = 't';
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrdersScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Сізді күтеді 1'), findsOneWidget);
    expect(find.text('Белсенді 2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('orders-buyer-mine')));
    await tester.pumpAndSettle();
    expect(find.text('Shoe 1'), findsOneWidget);
    expect(find.text('Shoe 2'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('orders-buyer-done'))); // the chip strip scrolls sideways
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('orders-buyer-done')));
    await tester.pumpAndSettle();
    expect(find.text('Shoe 3'), findsOneWidget);
    expect(find.text('Shoe 1'), findsNothing);
  });

  test('demo answers from recorded data, filters the catalog, and refuses real-money actions', () async {
    final api = Api(base: 'http://demo/api/v1', client: await DemoClient.load())..token = demoToken;
    final me = await api.me();
    expect(me.isSeller, isTrue);
    final all = await api.search();
    expect(all, isNotEmpty);
    final sale = await api.search(sale: true);
    expect(sale.every((l) => l.wasPriceTiyn != null), isTrue);
    expect(sale.length, lessThan(all.length));
    final cheap = await api.search(filter: const CatalogFilter(sort: 'price_asc'));
    expect(cheap.first.priceTiyn, all.map((l) => l.priceTiyn).reduce((a, b) => a < b ? a : b));
    expect((await api.listing(all.first.id)).id, all.first.id);
    await api.setFavorite(all.last.id, true);
    expect((await api.favorites()).first.id, all.last.id);
    await expectLater(api.startPayment(1), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'demo')));
    final black = await api.search(filter: const CatalogFilter(colors: {'қара'}));
    expect(black, isNotEmpty);
    expect(black.every((l) => l.color == 'қара' || l.color == 'қара-ақ'), isTrue); // black-and-white is black too
    expect(black.length, lessThan(all.length));
  });

  test('the demo offers each colour as the server would: closest condition, the same order on every colour', () async {
    final api = Api(base: 'http://demo/api/v1', client: await DemoClient.load())..token = demoToken;
    final blue = await api.listing(3); // Runner 01, new without box
    // Black: the new boxed pair (1), not the cheaper worn one (2); the rejected pair (5) and another shop's (6) never.
    expect([for (final c in blue.colors) (c.id, c.current)], [(3, true), (1, false), (4, false)]);
    final black = await api.listing(1);
    expect([for (final c in black.colors) c.color], [for (final c in blue.colors) c.color]); // swatches keep places
    expect(black.colors.singleWhere((c) => c.current).id, 1);
  });

  test('order summary lists the price with its promo and says it is not a fiscal receipt', () {
    final o = OrderInfo.fromJson({
      'id': 1006,
      'status': 'PAID',
      'listing_id': 2,
      'buyer_id': 2,
      'seller_id': 1,
      'item_price_tiyn': 1341000,
      'delivery_price_tiyn': 0,
      'total_tiyn': 1341000,
      'tracking_number': null,
      'promo_code': 'QADAM10',
      'promo_discount_tiyn': 149000,
      'listing_title': 'Жеңіл кроссовка',
      'size_label': '42',
      'size_cm': '27,0',
      'seller_name': 'Qadam Store',
      'created_at': '2026-10-17T06:00:00+00:00',
    });
    final text = orderSummaryText(o);
    expect(text, contains('тапсырыс №1006'));
    expect(text, contains('Тауар: ${formatTenge(1490000)}'));
    expect(text, contains('Промокод QADAM10: −${formatTenge(149000)}'));
    expect(text, contains('Жеткізу: тегін'));
    expect(text, contains('Жиыны: ${formatTenge(1341000)}'));
    expect(text, contains('Сатушы: Qadam Store'));
    expect(text, endsWith('Бұл фискалдық чек емес.'));
  });

  testWidgets('help screen explains the clocks with the numbers the server uses', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HelpScreen()));
    expect(find.text('Ақшам қалай қорғалады?'), findsOneWidget);
    expect(find.textContaining('«Алдым, бәрі дұрыс»'), findsOneWidget); // first topic starts open
    await tester.tap(find.text('Тапсырыс қалай жүреді?'));
    await tester.pumpAndSettle();
    expect(find.textContaining('$payWithinMinutes минут'), findsOneWidget);
    expect(find.textContaining('$sellerAnswersWithinHours сағат'), findsOneWidget);
    expect(payWithinMinutes, 30); // backend/vitrina_api/services.py UNPAID_CREATED_TTL
    expect(sellerAnswersWithinHours, 48); // SELLER_ANSWER_TTL
    expect(buyerChecksWithinDays, 5); // config.py confirm_window
  });

  testWidgets('to-do card lists only what waits and opens where it is done', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => http.Response(
            jsonEncode(req.url.path.endsWith('/me/todo')
                ? {'to_pay': 0, 'to_confirm': 1, 'offers_answered': 0, 'questions': 2}
                : {'items': []}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'})))
      ..token = 't';
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: TodoCard()))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('todo-to_confirm')), findsOneWidget);
    expect(find.byKey(const Key('todo-questions')), findsOneWidget);
    expect(find.byKey(const Key('todo-to_pay')), findsNothing); // zero is not shown
    expect(find.text('2'), findsOneWidget);
  });

  test('listing quality counts what the page has and puts the biggest gap first', () {
    final bare = listingQuality(Listing.fromJson(listingJson()));
    // No 360°, no extra angles, no description, not proven; brand, model, defects and stock are there.
    expect(bare.score, 100 - 25 - 15 - 15 - 15);
    expect(bare.tips.first.points, 25);
    expect(bare.verdict, 'Толықтыруға болады');
    Map<String, dynamic> m(String angle) =>
        {'original_url': 'https://x/$angle.jpg', 'processed_url': null, 'angle': angle};
    final full = listingQuality(Listing.fromJson({
      ...listingJson(media: [
        for (var i = 0; i < 12; i++) m('frame'),
        for (final a in ['front', 'outer', 'inner', 'back', 'sole', 'top', 'detail', 'label']) m(a),
      ]),
      'description':
          'Түпнұсқа, бір маусым киілді. Материалы былғары, өлшемі дәл келеді. Кішірейіп қалғандықтан сатамын.',
      'authenticity': 'documented',
    }));
    expect(full.score, 100);
    expect(full.tips, isEmpty);
    expect(full.verdict, 'Өте жақсы');
  });

  test('order deadline speaks to whoever can still act on it', () {
    OrderInfo order(String status, String? deadline) => OrderInfo.fromJson({
          'id': 7,
          'status': status,
          'listing_id': 2,
          'buyer_id': 2,
          'seller_id': 1,
          'total_tiyn': 100,
          'deadline': deadline,
        });
    final at = DateTime.utc(2026, 10, 17, 9, 30).toIso8601String();
    expect(orderDeadlineText(order('PAYMENT_PENDING', at), 2), contains('төлемесеңіз'));
    expect(orderDeadlineText(order('PAYMENT_PENDING', at), 1), isNull); // the seller has nothing to do yet
    expect(orderDeadlineText(order('PAID', at), 2), contains('ақша сізге өзі қайтарылады'));
    expect(orderDeadlineText(order('PAID', at), 1), contains('қабылдаңыз немесе бас тартыңыз'));
    expect(orderDeadlineText(order('SHIPPED', null), 2), isNull);
  });

  testWidgets('size guide converts and remembers the picked size', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await setMySize(null);
    addTearDown(() => setMySize(null)); // other tests expect no remembered size
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? picked;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async => picked = await showSizeGuide(context), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('size-row-27'));
    expect(find.descendant(of: row, matching: find.text('42')), findsOneWidget); // EU
    expect(find.descendant(of: row, matching: find.text('8,5')), findsOneWidget); // US men
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(picked, '27');
    expect(mySize.value, '27');
  });

  testWidgets('a promo code shows the new price and goes with the order', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          expect(req.url.path, '/api/v1/listings/7/promo');
          if (req.url.queryParameters['code'] != 'QADAM10') {
            return jsonResponse({'code': 'promo_not_found', 'message_kk': 'Мұндай промокод жоқ.'}, 404);
          }
          return jsonResponse(
              {'code': 'QADAM10', 'discount_tiyn': 450000, 'item_price_tiyn': 4050000, 'total_tiyn': 4200000});
        }))
      ..token = 'tok';
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Checkout? result;
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () async => result = await showModalBottomSheet<Checkout>(
                        context: context, isScrollControlled: true, builder: (_) => const DeliverySheet(listingId: 7)),
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('promo-open')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('promo-code')), 'nope');
    await tester.tap(find.byKey(const Key('promo-apply')));
    await tester.pumpAndSettle();
    expect(find.text('Мұндай промокод жоқ.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('promo-code')), 'QADAM10');
    await tester.tap(find.byKey(const Key('promo-apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('promo-applied')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('promo-applied')), matching: find.textContaining(formatTenge(4200000))),
        findsOneWidget);
    // The button says what the order will cost, promo included.
    expect(find.text('Тапсырысты рәсімдеу · ${formatTenge(4200000)}'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('delivery-name')), 'Айгерім Сапарова');
    await tester.enterText(find.byKey(const Key('delivery-phone')), '+7 701 000 00 02');
    await tester.enterText(find.byKey(const Key('delivery-city')), 'Алматы');
    await tester.enterText(find.byKey(const Key('delivery-address')), 'Абай даңғылы 10, 25');
    await tester.tap(find.byKey(const Key('delivery-continue')));
    await tester.pumpAndSettle();
    expect(result?.promoCode, 'QADAM10');
    expect(result?.delivery.recipientPhone, '+77010000002');
  });

  testWidgets('seller answers a question and the answer shows under it', (tester) async {
    String? answered;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.method == 'POST') {
            expect(req.url.path, '/api/v1/questions/5/answer');
            answered = (jsonDecode(req.body) as Map)['text'] as String;
            return jsonResponse({
              'id': 5,
              'text': 'Қорабы бар ма?',
              'answer': answered,
              'asked_at': '2026-10-17T10:00:00Z',
              'mine': false
            });
          }
          expect(req.url.path, '/api/v1/listings/7/questions');
          return jsonResponse({
            'items': [
              {
                'id': 5,
                'text': 'Қорабы бар ма?',
                'answer': answered,
                'asked_at': '2026-10-17T10:00:00Z',
                'answered_at': null,
                'mine': false
              }
            ],
            'unanswered': answered == null ? 1 : 0,
          });
        }))
      ..token = 'tok';
    await tester.pumpWidget(SessionScope(
        session: Session(api), child: const MaterialApp(home: QuestionsScreen(listingId: 7, seller: true))));
    await tester.pumpAndSettle();
    expect(find.text('Қорабы бар ма?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('answer-5')));
    await tester.pumpAndSettle();
    FilledButton send() => tester.widget<FilledButton>(find.byKey(const Key('question-send')));
    expect(send().onPressed, isNull); // nothing to send yet
    await tester.enterText(find.byKey(const Key('question-text')), 'Иә, түпнұсқа қорабымен');
    await tester.pump();
    await tester.tap(find.byKey(const Key('question-send')));
    await tester.pumpAndSettle();
    expect(answered, 'Иә, түпнұсқа қорабымен');
    expect(find.text('Иә, түпнұсқа қорабымен'), findsOneWidget);
    expect(find.byKey(const Key('answer-5')), findsNothing);
  });

  testWidgets('seller answers an offer with their own price', (tester) async {
    final calls = <String>[];
    var status = 'pending';
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}${req.body.isEmpty ? '' : ' ${req.body}'}');
          if (req.method == 'POST') {
            status = 'countered';
            return jsonResponse(offerJson(status: status, counter: 4300000));
          }
          expect(req.url.queryParameters['role'], 'seller');
          return jsonResponse({
            'items': [offerJson(status: status, counter: status == 'countered' ? 4300000 : null)],
            'waiting': 1
          });
        }))
      ..token = 'tok';
    await tester.pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: OffersScreen())));
    await tester.pumpAndSettle();
    expect(find.text('−11%'), findsOneWidget);
    expect(find.text('Жауап күтуде'), findsOneWidget);
    await tester.tap(find.byKey(const Key('counter-11')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('counter-amount')), '43000');
    await tester.tap(find.byKey(const Key('counter-send')));
    await tester.pumpAndSettle();
    expect(calls, contains('POST /api/v1/offers/11/counter {"amount_tiyn":4300000}'));
    expect(find.text('Сатушы баға ұсынды'), findsOneWidget);
    expect(find.byKey(const Key('accept-11')), findsNothing); // now it is the buyer's turn
  });

  test('saved search sends the catalog filters and reads back as one line', () {
    final body = SavedSearch.body(
        q: '  nike ',
        category: 'sneakers',
        sizeCm: '26,5',
        filter: const CatalogFilter(conditions: {'used_good', 'new_with_box'}, maxPriceTiyn: 5000000));
    expect(body, {
      'q': 'nike',
      'category': 'sneakers',
      'size_cm': '26,5',
      'condition': 'new_with_box,used_good',
      'max_price_tiyn': 5000000,
    });
    final saved = SavedSearch.fromJson({'id': 1, ...body});
    expect(saved.asBody, body);
    expect(savedSearchLabel(saved), startsWith('«nike» · Кроссовкалар · 26,5 см · ${formatTenge(5000000)} дейін'));
  });

  test('a saved search keeps its colours in one order and names them in the interface language', () {
    final body = SavedSearch.body(filter: const CatalogFilter(colors: {'қара', 'ақ'}));
    expect(body, {'color': 'ақ,қара'});
    final saved = SavedSearch.fromJson({'id': 1, 'color': 'ақ,қара,мраморный'});
    expect(saved.colors, {'ақ', 'қара', 'мраморный'});
    expect(saved.asBody, {'color': 'ақ,мраморный,қара'}); // sorted as the server sorts
    expect(savedSearchLabel(saved), 'ақ, қара, мраморный');
    expect(const CatalogFilter(colors: {'қара', 'көк'}).query, {'color': 'көк,қара'});
    expect(const CatalogFilter(colors: {'қара', 'көк'}).active, 1);
  });

  testWidgets('catalog saves the current search and opens a saved one', (tester) async {
    final calls = <String>[];
    final asked = <Map<String, String>>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}${req.body.isEmpty ? '' : ' ${req.body}'}');
          if (req.url.path == '/api/v1/listings') asked.add(req.url.queryParameters);
          switch (req.url.path) {
            case '/api/v1/saved-searches' when req.method == 'POST':
              return jsonResponse({'id': 4, ...jsonDecode(req.body) as Map<String, dynamic>}, 201);
            case '/api/v1/saved-searches':
              return jsonResponse({
                'items': [
                  {
                    'id': 9,
                    'q': 'adidas',
                    'category': null,
                    'size_cm': null,
                    'condition': null,
                    'min_price_tiyn': null,
                    'max_price_tiyn': null,
                    'color': 'ақ,қара',
                  }
                ]
              });
            case '/api/v1/notifications':
              return jsonResponse({'unread': 0, 'items': []});
            default:
              return jsonResponse({'items': []});
          }
        }))
      ..token = 'tok';
    mySize.value = null;
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: MaterialApp(home: Scaffold(body: const CatalogScreen()))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-search')), findsNothing); // nothing to follow yet
    await tester.enterText(find.byType(TextField), 'nike');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-search')));
    await tester.pumpAndSettle();
    expect(calls, contains('POST /api/v1/saved-searches {"q":"nike"}'));
    expect(find.byKey(const Key('search-saved')), findsOneWidget);
    await tester.tap(find.byKey(const Key('saved-searches')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('«adidas» · ақ, қара'));
    await tester.pumpAndSettle();
    expect(calls.last, startsWith('GET /api/v1/listings'));
    expect(asked.last['color'], 'ақ,қара');
    expect(find.text('adidas'), findsOneWidget); // the query box shows the saved search
    expect(find.byKey(const Key('search-saved')), findsOneWidget);
    // The colours show next to the filter button, and its cross drops them and nothing else.
    expect(find.descendant(of: find.byKey(const Key('colors-on')), matching: find.text('ақ, қара')), findsOneWidget);
    await tester.tap(find.byTooltip('Түсті алып тастау'));
    await tester.pumpAndSettle();
    expect((asked.last['color'], asked.last['q']), (null, 'adidas'));
    expect(find.byKey(const Key('colors-on')), findsNothing);
    expect(find.byKey(const Key('save-search')), findsOneWidget); // no longer the saved search
  });

  testWidgets('reviews show the buyer photos and open one large', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => jsonResponse({
              'items': [
                {
                  'id': 1,
                  'order_id': 5,
                  'rating': 5,
                  'text': 'Суреттегідей',
                  'seller_reply': null,
                  'photos': ['http://x/media/2/a.jpg', 'http://x/media/2/b.jpg'],
                  'buyer_name': 'Аян',
                  'created_at': '2026-10-17T05:00:00+00:00',
                }
              ]
            })));
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: const MaterialApp(home: SellerReviewsScreen(sellerId: 3, shopName: 'Qadam Store'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-photo-http://x/media/2/a.jpg')), findsOneWidget);
    expect(find.byKey(const Key('review-photo-http://x/media/2/b.jpg')), findsOneWidget);
    await tester.tap(find.byKey(const Key('review-photo-http://x/media/2/a.jpg')));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('a cut price shows the old one crossed out with the percent', (tester) async {
    final l = Listing.fromJson({...listingJson(), 'price_tiyn': 3600000, 'was_price_tiyn': 4500000});
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SizedBox(width: 220, height: 400, child: ListingTile(listing: l)))));
    expect(find.text('−20%'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('was-price'))).data, formatTenge(4500000));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(width: 220, height: 400, child: ListingTile(listing: Listing.fromJson(listingJson()))))));
    expect(find.byKey(const Key('was-price')), findsNothing);
  });

  testWidgets('a seller on holiday cannot be ordered from or offered to', (tester) async {
    final json = {
      ...listingJson(),
      'seller': {'id': 3, 'shop_name': 'Qadam Store', 'city': 'Алматы', 'away_until': '2026-10-24'},
    };
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path == '/api/v1/offers') return jsonResponse({'items': [], 'waiting': 0});
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          return jsonResponse(json);
        }))
      ..token = 'tok';
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('seller-away')), findsOneWidget);
    await tester.tap(find.text('42'));
    await tester.pump();
    expect(find.byKey(const Key('make-offer')), findsNothing);
    final button =
        tester.widget<FilledButton>(find.ancestor(of: find.text('25.10 бастап'), matching: find.byType(FilledButton)));
    expect(button.onPressed, isNull);
  });

  test('photo upload is multipart with the token and returns the stored url', () async {
    late http.BaseRequest seen;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient.streaming((req, body) async {
          seen = req;
          final bytes = await body.toBytes();
          expect(String.fromCharCodes(bytes), contains('filename="a.jpg"'));
          return http.StreamedResponse(Stream.value(utf8.encode('{"url":"http://x/media/1/abc.jpg"}')), 201);
        }))
      ..token = 'tok';
    expect(await api.uploadPhoto([1, 2, 3], 'a.jpg'), 'http://x/media/1/abc.jpg');
    expect(seen.url.path, '/api/v1/media');
    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(seen.headers['Content-Type'], startsWith('multipart/form-data'));
  });

  test('spin progress ring repaints only when the count changes', () {
    final a = SpinProgressPainter(captured: 3, target: spinTargetFrames);
    expect(a.shouldRepaint(SpinProgressPainter(captured: 3, target: spinTargetFrames)), isFalse);
    expect(a.shouldRepaint(SpinProgressPainter(captured: 4, target: spinTargetFrames)), isTrue);
  });

  testWidgets('listing editor will not save without required fields and photos', (tester) async {
    var calls = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 500);
        }));
    tester.view.physicalSize = const Size(500, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingEditorScreen())));
    for (final label in requiredAngles.values) {
      expect(find.text('$label *'), findsOneWidget);
    }
    await tester.tap(find.text('Жариялау'));
    await tester.pump();
    expect(find.text('Толтырыңыз'), findsWidgets);
    expect(find.text('Бағаны енгізіңіз'), findsOneWidget);
    expect(find.text('Түсін таңдаңыз'), findsOneWidget); // the colour is picked, not left out

    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'Qadam Runner');
    await tester.tap(find.byKey(const Key('color-ақ')));
    await tester.enterText(find.widgetWithText(TextFormField, 'Бағасы'), '34900');
    await tester.enterText(find.widgetWithText(TextFormField, 'Өлшем'), '42');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ұлтарақ, см'), '27');
    await tester.tap(find.text('Жариялау'));
    await tester.pump();
    expect(find.textContaining('Фото жетіспейді'), findsOneWidget);
    expect(calls, 0); // nothing was sent

    // Defect description becomes required for worn shoes.
    await tester.tap(find.text('Жаңа, қорабымен'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Киілген, жақсы').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Ақаулары'), findsOneWidget);
  });

  testWidgets('the colour is picked from a list, or typed when it is not on it', (tester) async {
    final color = TextEditingController();
    final form = GlobalKey<FormState>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: Form(key: form, child: ColorField(controller: color))))));
    expect(form.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('Түсін таңдаңыз'), findsOneWidget);
    await tester.tap(find.byKey(const Key('color-қою көк')));
    await tester.pump();
    expect(color.text, 'қою көк');
    expect(find.text('Түсін таңдаңыз'), findsNothing); // the message goes once a colour is picked
    // Picked: only the pick shows, so the list does not push the form away.
    expect(find.byKey(const Key('color-қара')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('color-picked')), matching: find.text('қою көк')), findsOneWidget);
    expect(form.currentState!.validate(), isTrue);
    // Not on the list: typed by hand, and kept while the seller looks at a listed colour.
    await tester.tap(find.byKey(const Key('color-change')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('color-other')));
    await tester.tap(find.byKey(const Key('color-other')));
    await tester.pump();
    expect(color.text, isEmpty); // the listed colour does not linger in the typing field
    await tester.enterText(find.byKey(const Key('color-other-text')), 'м');
    expect(form.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('Түсін жазыңыз'), findsNWidgets(2)); // the label, and the message under the field it is about
    await tester.enterText(find.byKey(const Key('color-other-text')), 'мәрмәр');
    expect(color.text, 'мәрмәр');
    await tester.tap(find.byKey(const Key('color-ақ')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('color-change')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('color-other')));
    await tester.tap(find.byKey(const Key('color-other')));
    await tester.pump();
    expect(color.text, 'мәрмәр');
  });

  testWidgets('a colour typed before the list opens as typed, ready to change', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: ColorField(controller: TextEditingController(text: 'бордо с ақ'))))));
    expect(
        find.descendant(of: find.byKey(const Key('color-picked')), matching: find.text('бордо с ақ')), findsOneWidget);
    await tester.tap(find.byKey(const Key('color-change')));
    await tester.pump();
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('color-other'))).selected, isTrue);
    expect(find.widgetWithText(TextField, 'бордо с ақ'), findsOneWidget);
  });

  test('listed colours show in the interface language, typed ones as typed', () {
    addTearDown(() => appLanguage.value = 'kk');
    appLanguage.value = 'ru';
    expect(colorName('қою көк'), 'темно-синий');
    expect(colorName('қара-ақ'), 'черно-белый');
    expect(colorName('мраморный'), 'мраморный');
    appLanguage.value = 'en';
    expect(colorName('қара'), 'black');
  });

  testWidgets('chat shows both sides and warns only the reader about contact details', (tester) async {
    final conv = {
      'id': 9,
      'listing_id': 7,
      'listing_title': 'Кроссовка',
      'listing_cover': null,
      'price_tiyn': 2490000,
      'role': 'buyer',
      'other_name': 'Qadam Store',
      'last_message': null,
      'unread': 0,
    };
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => http.Response(
            jsonEncode({
              'conversation': conv,
              'items': [
                {
                  'id': 1,
                  'sender_id': 2,
                  'body': '42 бар ма?',
                  'contact_warning': false,
                  'created_at': '2026-10-17T10:00:00Z'
                },
                {
                  'id': 2,
                  'sender_id': 3,
                  'body': 'Бар, +7 701 123 45 67',
                  'contact_warning': true,
                  'created_at': '2026-10-17T10:01:00Z'
                },
                {
                  'id': 3,
                  'sender_id': 3,
                  'body': '',
                  'photo_url': 'http://x/media/3/sole.jpg',
                  'contact_warning': false,
                  'created_at': '2026-10-17T10:02:00Z'
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    final session = Session(api)
      ..me = Me.fromJson({
        'id': 2,
        'phone': '+77010000002',
        'display_name': null,
        'city': null,
        'is_seller': false,
        'shop_name': null
      });
    await tester.pumpWidget(SessionScope(
        session: session,
        child: const MaterialApp(home: ChatScreen(conversationId: 9, pollEvery: Duration(hours: 1)))));
    await tester.pumpAndSettle();
    expect(find.text('Qadam Store'), findsOneWidget);
    expect(find.text('42 бар ма?'), findsOneWidget);
    expect(find.text('Бар, +7 701 123 45 67'), findsOneWidget);
    expect(find.textContaining('Төлемді тек VITRINA арқылы'), findsOneWidget);
    expect(
        find.byWidgetPredicate((w) =>
            w is Image && w.image is NetworkImage && (w.image as NetworkImage).url == 'http://x/media/3/sole.jpg'),
        findsOneWidget);
    expect(find.byKey(const Key('chat-photo')), findsOneWidget);
    expect(find.byKey(const Key('quick-replies')), findsNothing); // ready answers are the seller's
    await tester.pumpWidget(const SizedBox()); // stop polling
  });

  testWidgets('blocking from the chat menu asks first, then closes the chat', (tester) async {
    final calls = <String>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}');
          if (req.method == 'POST') return jsonResponse({'blocked': true});
          return jsonResponse({
            'conversation': {
              'id': 9,
              'listing_id': 7,
              'listing_title': 'Кроссовка',
              'listing_cover': null,
              'price_tiyn': 2490000,
              'role': 'buyer',
              'other_name': 'Qadam Store',
              'last_message': null,
              'unread': 0,
            },
            'items': [],
          });
        }));
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: MaterialApp(
            home: Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const ChatScreen(conversationId: 9, pollEvery: Duration(hours: 1)))),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('block-user')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.startsWith('POST')), isEmpty); // nothing happens before the confirmation
    await tester.tap(find.byKey(const Key('confirm-block')));
    await tester.pumpAndSettle();
    expect(calls, contains('POST /api/v1/conversations/9/block'));
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.text('Qadam Store: бұғатталды.'), findsOneWidget);
  });

  testWidgets('seller puts a ready answer in the field and can edit the list', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await restoreQuickReplies();
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => jsonResponse({
              'conversation': {
                'id': 9,
                'listing_id': 7,
                'listing_title': 'Кроссовка',
                'listing_cover': null,
                'price_tiyn': 2490000,
                'role': 'seller',
                'other_name': 'Айгерім',
                'last_message': null,
                'unread': 0,
              },
              'items': [],
            })));
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: const MaterialApp(home: ChatScreen(conversationId: 9, pollEvery: Duration(hours: 1)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сәлеметсіз бе! Иә, бар.'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Сәлеметсіз бе! Иә, бар.');
    await tester.tap(find.byKey(const Key('edit-quick-replies')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-quick-reply')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('quick-reply-4')), 'Бүгін 18:00-ге дейін жіберемін');
    await tester.tap(find.byKey(const Key('save-quick-replies')));
    await tester.pumpAndSettle();
    expect(currentQuickReplies().last, 'Бүгін 18:00-ге дейін жіберемін');
    final saved = (await SharedPreferences.getInstance()).getString('vitrina_quick_replies')!;
    expect((jsonDecode(saved) as List).length, 5);
    await tester.pumpWidget(const SizedBox()); // stop polling
  });

  testWidgets('seller changes price and stock and the edit is sent as one patch', (tester) async {
    Map<String, dynamic>? sent;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          expect(req.method, 'PATCH');
          expect(req.url.path, '/api/v1/listings/7');
          sent = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(jsonEncode({...listingJson(), 'price_tiyn': 4000000}), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    final own = listingJson();
    own['sizes'] = [
      {'id': 1, 'label': '42', 'insole_cm': '27,0', 'available': true, 'quantity': 2},
    ];
    own['stats'] = {'views': 15, 'favorites': 4, 'chats': 3, 'orders': 1, 'sold': 0};
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api), child: MaterialApp(home: ManageListingScreen(listing: Listing.fromJson(own)))));
    expect(find.text('Сатылымда'), findsOneWidget);
    expect(find.text('15'), findsOneWidget);
    expect(find.text('қаралым'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.byKey(const Key('listing-quality')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await tester.ensureVisible(find.byTooltip('Көбейту'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Көбейту'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent!['price_tiyn'], 4000000);
    expect(sent!['sizes'], [
      {'id': 1, 'quantity': 3}
    ]);
    expect(sent!.containsKey('title'), isFalse); // name fields left alone are not sent
    expect(find.text('Сақталды'), findsOneWidget);
  });

  testWidgets('authenticity card shows the staff answer and hides editing once checked', (tester) async {
    Map<String, Object?> state = {'authenticity': 'unverified', 'note': 'Чекте модель көрінбейді', 'proofs': []};
    final api = Api(base: 'http://x/api/v1', client: MockClient((req) async => jsonResponse(state)));
    Future<void> show() async {
      await tester.pumpWidget(SessionScope(
          session: Session(api),
          child: MaterialApp(home: Scaffold(body: AuthenticityCard(key: UniqueKey(), listingId: 7)))));
      await tester.pumpAndSettle();
    }

    await show();
    expect(find.text('Қызметкер: Чекте модель көрінбейді'), findsOneWidget);
    expect(find.byKey(const Key('add-proof')), findsOneWidget);
    state = {
      'authenticity': 'documented',
      'note': null,
      'proofs': [
        {'id': 1, 'url': 'http://x/r.jpg'},
      ],
    };
    await show();
    expect(find.text('Тексерілді: тауарда «Құжаты бар» белгісі тұр.'), findsOneWidget);
    expect(find.byKey(const Key('add-proof')), findsNothing);
  });

  testWidgets('a sent-back listing shows the staff note and resends for checking', (tester) async {
    String? posted;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          posted = '${req.method} ${req.url.path}';
          return http.Response(
              jsonEncode({
                ...listingJson(),
                'status': 'moderation',
                'moderation': {
                  'flags': ['contacts'],
                  'reasons': ['Байланыс тек VITRINA чатында.'],
                  'note': null
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    final own = {
      ...listingJson(),
      'status': 'rejected',
      'moderation': {
        'flags': ['contacts'],
        'reasons': ['Байланыс тек VITRINA чатында.'],
        'reasons_ru': ['Связь только в чате VITRINA.'],
        'note': 'Телефонды алып тастаңыз',
      },
    };
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api), child: MaterialApp(home: ManageListingScreen(listing: Listing.fromJson(own)))));
    expect(find.text('Тауар қайтарылды'), findsOneWidget);
    expect(find.text('Қызметкердің жазбасы: Телефонды алып тастаңыз'), findsOneWidget);
    expect(find.text('Байланыс тек VITRINA чатында.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('publish')));
    await tester.pumpAndSettle();
    expect(posted, 'POST /api/v1/listings/7/publish');
    expect(find.text('Тауар тексерілуде'), findsOneWidget);
    expect(find.text('Тексеруге жіберілді'), findsOneWidget);
    expect(find.byKey(const Key('publish')), findsNothing);
  });

  testWidgets('seller starts a promo video and the card follows it until it is ready', (tester) async {
    final calls = <String>[];
    var polls = 0;
    Map<String, dynamic> withPromo(String? state) => {
          ...listingJson(),
          'promo': {'state': state, 'url': state == 'ready' ? 'http://x/media/3/v.mp4' : null}
        };
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          calls.add('${req.method} ${req.url.path} ${req.body}');
          final body = req.method == 'POST' ? withPromo('rendering') : withPromo(++polls < 2 ? 'rendering' : 'ready');
          return http.Response(jsonEncode(body), req.method == 'POST' ? 202 : 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    Listing current = Listing.fromJson(withPromo(null));
    await tester.pumpWidget(SessionScope(
      session: Session(api),
      child: MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PromoCard(
              listing: current,
              pollEvery: const Duration(milliseconds: 10),
              onChanged: (l) => setState(() => current = l),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('make-promo')));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byKey(const Key('open-promo')), findsOneWidget);
    expect(calls.first, 'POST /api/v1/listings/7/promo {"lang":"kk"}');
    expect(calls.skip(1).every((c) => c.startsWith('GET /api/v1/listings/7')), isTrue);
  });

  testWidgets('analytics shows totals and a tapped day', (tester) async {
    final days = [
      for (var i = 0; i < 14; i++)
        {
          'date': '2026-10-${(4 + i).toString().padLeft(2, '0')}',
          'views': i == 10 ? 9 : 2,
          'orders': i == 10 ? 1 : 0,
          'sold_tiyn': 0
        }
    ];
    String? asked;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          asked = req.url.queryParameters['days'];
          return http.Response(
              jsonEncode({
                'days': days,
                'totals': {'views': 35, 'orders': 1, 'sold_tiyn': 4500000, 'conversion': 0.0286},
                'top': [
                  {'id': 7, 'title': 'Nike Air Force 1', 'status': 'published', 'views': 20, 'orders': 1}
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: AnalyticsScreen())));
    await tester.pumpAndSettle();
    expect(asked, '14');
    expect(find.text('35'), findsOneWidget);
    expect(find.text('2,9%'), findsOneWidget);
    expect(find.text(formatTenge(4500000)), findsOneWidget);
    expect(find.text('Nike Air Force 1'), findsOneWidget);
    expect(find.text('17.10: 2 қаралым, 0 тапсырыс'), findsOneWidget); // the latest active day by default
    final chart = tester.getRect(find.byType(CustomPaint).last);
    await tester.tapAt(Offset(chart.left + chart.width * (10.5 / 14), chart.center.dy));
    await tester.pump();
    expect(find.text('14.10: 9 қаралым, 1 тапсырыс'), findsOneWidget);
  });

  test('catalog filter builds the query and counts what differs from default', () {
    const f = CatalogFilter(
        sort: 'price_asc', conditions: {'new_with_box', 'new_no_box'}, minPriceTiyn: 1000000, maxPriceTiyn: null);
    expect(f.active, 3);
    expect(f.query, {'sort': 'price_asc', 'condition': 'new_with_box,new_no_box', 'min_price_tiyn': '1000000'});
    expect(const CatalogFilter(city: 'Шымкент').query, {'city': 'Шымкент'});
    expect(const CatalogFilter(city: 'Шымкент').active, 1);
    expect(const CatalogFilter().query, isEmpty);
  });

  testWidgets('filter sheet swaps a reversed price range', (tester) async {
    CatalogFilter? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showModalBottomSheet<CatalogFilter>(
              context: context, isScrollControlled: true, builder: (_) => const FilterSheet(initial: CatalogFilter())),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('min-price')), '50000');
    await tester.enterText(find.byKey(const Key('max-price')), '20000');
    await tester.tap(find.text('Арзанырақ'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('apply-filter')));
    await tester.tap(find.byKey(const Key('apply-filter')));
    await tester.pumpAndSettle();
    expect(result!.minPriceTiyn, 2000000);
    expect(result!.maxPriceTiyn, 5000000);
    expect(result!.sort, 'price_asc');
    expect(result!.city, isNull);
  });

  testWidgets('filter sheet narrows the catalog to one seller city', (tester) async {
    CatalogFilter? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showModalBottomSheet<CatalogFilter>(
              context: context, isScrollControlled: true, builder: (_) => const FilterSheet(initial: CatalogFilter())),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('filter-city')));
    await tester.tap(find.byKey(const Key('filter-city')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Шымкент').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('apply-filter')));
    await tester.tap(find.byKey(const Key('apply-filter')));
    await tester.pumpAndSettle();
    expect(result!.city, 'Шымкент');
  });

  testWidgets('filter sheet picks colours and shows the ones already picked', (tester) async {
    CatalogFilter? result;
    var initial = const CatalogFilter();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showModalBottomSheet<CatalogFilter>(
              context: context, isScrollControlled: true, builder: (_) => FilterSheet(initial: initial)),
          child: const Text('open'),
        ),
      ),
    ));
    Future<void> tap(String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tap('filter-color-қара');
    await tap('filter-color-көк');
    await tap('apply-filter');
    expect(result!.colors, {'қара', 'көк'});
    initial = result!;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    FilterChip chip(String name) => tester.widget<FilterChip>(find.byKey(Key('filter-color-$name')));
    expect([chip('қара').selected, chip('көк').selected, chip('ақ').selected], [true, true, false]);
    await tap('filter-color-қара');
    await tap('apply-filter');
    expect(result!.colors, {'көк'});
    // A colour not on the list, from a saved search, has a chip too, so it can be dropped.
    initial = const CatalogFilter(colors: {'мраморный'});
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(chip('мраморный').selected, isTrue);
    await tap('filter-color-мраморный');
    await tap('apply-filter');
    expect(result!.colors, isEmpty);
  });

  testWidgets('a picked filter chip has light text on its dark fill', (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
            body: Column(children: [
          FilterChip(label: const Text('on'), selected: true, onSelected: (_) {}),
          FilterChip(label: const Text('off'), selected: false, onSelected: (_) {}),
        ]))));
    final scheme = Theme.of(tester.element(find.text('on'))).colorScheme;
    Color? ink(String text) => tester.renderObject<RenderParagraph>(find.text(text)).text.style?.color;
    expect(ink('on'), scheme.onPrimary);
    expect(ink('off'), scheme.onSurface);
  });

  test('packing slip comes back as PDF bytes, or as the server\'s error', () async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => req.url.path == '/api/v1/orders/5/slip.pdf'
            ? http.Response.bytes([37, 80, 68, 70], 200, headers: {'content-type': 'application/pdf'})
            : jsonResponse({'code': 'invalid_status', 'message_kk': 'Бұл күйде мүмкін емес.'}, 409)))
      ..token = 'tok';
    expect(await api.packingSlip(5), [37, 80, 68, 70]);
    expect(api.packingSlip(6), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_status')));
  });

  test('sales export asks for the chosen period and hands back the file, or the server\'s error', () async {
    Uri? asked;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          asked = req.url;
          expect(req.headers['Authorization'], 'Bearer tok');
          return http.Response.bytes(utf8.encode('\ufeffТапсырыс;Күні\r\n'), 200);
        }))
      ..token = 'tok';
    final bytes = await api.salesCsv(days: 30);
    expect(asked?.path, '/api/v1/me/sales.csv');
    expect(asked?.queryParameters, {'days': '30'});
    expect(bytes.take(3), [0xEF, 0xBB, 0xBF]); // the BOM Excel needs is passed through untouched
    expect(utf8.decode(bytes), startsWith('Тапсырыс'));
    final refused = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async =>
            jsonResponse({'code': 'seller_required', 'message_kk': 'Алдымен сатушы режимін қосыңыз.'}, 403)));
    expect(refused.salesCsv(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'seller_required')));
  });

  testWidgets('earnings shows owed, held and commission from the ledger', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => req.url.path.endsWith('/me/payouts')
            ? jsonResponse({'code': 'not_found'}, 404) // without payouts the money view still shows
            : http.Response(
                jsonEncode({
                  'held_tiyn': 3440000,
                  'payable_tiyn': 2840500,
                  'fees_tiyn': 149500,
                  'items': [
                    {
                      'order_id': 2,
                      'kind': 'completion',
                      'at': '2026-10-17T00:45:00+00:00',
                      'listing_title': 'Жеңіл жүгіру кроссовкасы',
                      'net_tiyn': 2840500,
                      'fee_tiyn': 149500,
                    }
                  ],
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'})));
    await tester.pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: EarningsScreen())));
    await tester.pumpAndSettle();
    expect(find.text(formatTenge(2840500)), findsNWidgets(2));
    expect(find.text(formatTenge(3440000)), findsOneWidget);
    expect(find.text(formatTenge(149500)), findsOneWidget);
    expect(find.textContaining('Сатылды'), findsOneWidget);
  });

  testWidgets('a seller adds a bank account, then pays out what is owed', (tester) async {
    final calls = <String>[];
    var payouts = <Map<String, dynamic>>[];
    var hasAccount = false;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          final path = req.url.path.replaceFirst('/api/v1', '');
          calls.add('${req.method} $path');
          if (path == '/me/earnings') {
            return jsonResponse({'held_tiyn': 0, 'payable_tiyn': 2840500, 'fees_tiyn': 0, 'items': []});
          }
          if (path == '/me/payout-account' && req.method == 'GET') return jsonResponse({'account': null});
          if (path == '/me/payout-account') {
            final b = jsonDecode(req.body) as Map;
            if (!(b['iban'] as String).startsWith('KZ')) {
              return jsonResponse({'code': 'invalid_iban', 'message_kk': 'IBAN қате.'}, 422);
            }
            hasAccount = true;
            return jsonResponse({
              'account': {
                'holder_name': b['holder_name'],
                'iban': b['iban'],
                'iban_masked': 'KZ86 •••• 0100',
                'tax_id': b['tax_id']
              }
            });
          }
          if (path == '/me/payouts' && req.method == 'POST') {
            payouts = [
              {
                'id': 7,
                'amount_tiyn': 2840500,
                'status': 'requested',
                'iban_masked': 'KZ86 •••• 0100',
                'created_at': '2026-10-20T09:00:00+00:00',
                'bank_ref': null,
                'reason': null
              }
            ];
            return jsonResponse(payouts.first, 201);
          }
          return jsonResponse({
            'payable_tiyn': payouts.isEmpty ? 2840500 : 0,
            'min_tiyn': 100000,
            'has_account': hasAccount,
            'open': payouts.isNotEmpty,
            'items': payouts,
          });
        }));
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: EarningsScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Банк шотын қосу'), findsOneWidget);
    // No account yet: paying out asks for one first, and a wrong IBAN is said in the sheet.
    await tester.tap(find.byKey(const Key('payout')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('payout-holder')), 'Qadam Store ЖК');
    await tester.enterText(find.byKey(const Key('payout-iban')), 'RU00');
    await tester.enterText(find.byKey(const Key('payout-tax')), '900101300125');
    await tester.tap(find.byKey(const Key('payout-save')));
    await tester.pumpAndSettle();
    expect(find.text('IBAN қате.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('payout-iban')), 'KZ86125KZT5004100100');
    await tester.tap(find.byKey(const Key('payout-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payout-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('payout-confirm')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'POST /me/payouts'), hasLength(1));
    expect(find.text('Шығару сұрауыңыз қаралуда.'), findsOneWidget);
    expect(find.byKey(const Key('payout-7')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('payout'))).onPressed, isNull);
  });

  testWidgets('the product page says about when it arrives, and another city can be picked', (tester) async {
    pickedDeliveryCity.value = null;
    final asked = <String?>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          final city = req.url.queryParameters['city'];
          asked.add(city);
          final e = city == null
              ? null
              : {'city': city, 'from_city': 'Алматы', 'earliest': '2026-10-30', 'latest': '2026-11-01'};
          return jsonResponse({
            'estimate': e,
            'cities': ['Алматы', 'Астана']
          });
        }));
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: DeliveryEta(listingId: 5)))));
    await tester.pumpAndSettle();
    expect(find.text('Қашан жететінін білу үшін қалаңызды таңдаңыз'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delivery-eta')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('eta-city-Астана')));
    await tester.pumpAndSettle();
    expect(asked, [null, 'Астана']);
    expect(find.textContaining('шамамен 30 қаз – 1 қар'), findsOneWidget);
    expect(pickedDeliveryCity.value, 'Астана');
    expect(dateRange(DateTime(2026, 10, 20), DateTime(2026, 10, 22)), '20–22 қаз');
  });

  testWidgets('a buyer sees in the chat that the seller is away', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => jsonResponse({
              'conversation': {
                'id': 9,
                'listing_id': 7,
                'listing_title': 'Кроссовка',
                'listing_cover': null,
                'price_tiyn': 2490000,
                'role': 'buyer',
                'other_name': 'Qadam Store',
                'last_message': null,
                'unread': 0,
                'seller_away_until': '2026-10-25',
              },
              'items': [],
            })));
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: const MaterialApp(home: ChatScreen(conversationId: 9, pollEvery: Duration(hours: 1)))));
    await tester.pumpAndSettle();
    expect(find.text('Сатушы 25.10 дейін демалыста, жауабы кешігуі мүмкін.'), findsOneWidget);
  });

  for (final lang in ['kk', 'ru', 'en']) {
    for (final (width, scale) in [(360.0, 1.0), (412.0, 1.0), (412.0, 1.3), (360.0, 1.15), (412.0, 1.6)]) {
      testWidgets('every tab label stays on one line in $lang at ${width.toInt()} dp and text x$scale', (tester) async {
        // The real font: the test font draws every letter as a square, far wider than Inter.
        await tester.runAsync(() async {
          final inter = FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
          await inter.load();
        });
        SharedPreferences.setMockInitialValues({});
        final was = appLanguage.value;
        appLanguage.value = lang;
        addTearDown(() => appLanguage.value = was);
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final api =
            Api(base: 'http://x/api/v1', client: MockClient((req) async => jsonResponse({'items': [], 'unread': 0})))
              ..token = 'tok';
        final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': true}));
        await tester.pumpWidget(SessionScope(
            session: session,
            child: MaterialApp(
                theme: buildTheme(Brightness.light),
                home: MediaQuery(
                    data: MediaQueryData(size: Size(width, 760), textScaler: TextScaler.linear(scale)),
                    child: const HomeShell()))));
        await tester.pump();
        // The labels shown (with large text only the chosen tab's is): each one line high.
        final labels = find.descendant(of: find.byType(NavigationBar), matching: find.byType(Text)).hitTestable();
        final shown = [for (final e in labels.evaluate()) (e.renderObject! as RenderParagraph)];
        expect(shown, isNotEmpty);
        for (final p in shown) {
          final line = p.getFullHeightForCaret(const TextPosition(offset: 0));
          expect(p.size.height, lessThan(line * 1.5), reason: p.text.toPlainText());
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox()); // stops the polling timer
      });
    }
  }

  testWidgets('chat and orders tabs show what waits on the person', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => req.url.path.endsWith('/me/todo')
            ? jsonResponse({'unread_messages': 3, 'to_pay': 1, 'to_confirm': 0, 'to_ship': 1, 'offers_answered': 2})
            : jsonResponse({'items': [], 'unread': 0})))
      ..token = 'tok';
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': true}));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: HomeShell())));
    await tester.pump();
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('tab-chat')), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tab-orders')), matching: find.text('2')), findsOneWidget);
    expect(ordersWaiting({'to_accept': 2, 'returns': 1, 'unread_messages': 9}), 3);
    await tester.pumpWidget(const SizedBox()); // stops the polling timer
  });

  testWidgets('typing in search suggests models on sale, and a picked search is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await restoreRecentSearches();
    final searched = <String?>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path == '/api/v1/search/suggest') {
            return jsonResponse({
              'items': [
                {'text': 'Nike', 'kind': 'brand', 'count': 3},
                {'text': 'Nike Air Force 1', 'kind': 'model', 'count': 2},
              ]
            });
          }
          searched.add(req.url.queryParameters['q']);
          return jsonResponse({'items': []});
        }));
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: CatalogScreen()))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-field')));
    await tester.enterText(find.byKey(const Key('search-field')), 'най');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Nike Air Force 1'), findsOneWidget);
    expect(find.text('2 тауар'), findsOneWidget);
    await tester.tap(find.text('Nike Air Force 1'));
    await tester.pumpAndSettle();
    expect(searched.last, 'Nike Air Force 1');
    expect(find.byKey(const Key('suggestions')), findsNothing);
    expect(recentSearches.value, ['Nike Air Force 1']);
    await tester.enterText(find.byKey(const Key('search-field')), '');
    await tester.tap(find.byKey(const Key('search-field')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recent-searches')), findsOneWidget);
  });

  testWidgets('an empty search offers the nearest spelling, and a tap searches it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await restoreRecentSearches();
    final searched = <String?>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          final q = req.url.queryParameters['q'];
          if (req.url.path != '/api/v1/listings') return jsonResponse({'items': []});
          searched.add(q);
          return jsonResponse(q == 'nkie' ? {'items': [], 'did_you_mean': 'Nike'} : {'items': []});
        }));
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: CatalogScreen()))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-field')), 'nkie');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('«Nike» деп іздейсіз бе?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('did-you-mean')));
    await tester.pumpAndSettle();
    expect(searched.last, 'Nike');
    expect(find.byKey(const Key('did-you-mean')), findsNothing);
  });

  testWidgets('deleting the account asks first, then signs out', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = <String>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          // The profile's to-do card reads its counts on open; only what the dialog does matters here.
          if (!req.url.path.endsWith('/me/todo')) calls.add('${req.method} ${req.url.path}');
          return jsonResponse({'deleted': true});
        }))
      ..token = 'tok';
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ProfileScreen())));
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();
    expect(find.text('Аккаунтты жою керек пе?'), findsOneWidget);
    await tester.tap(find.text('Жабу'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty); // closing the dialog changes nothing
    await tester.tap(find.byKey(const Key('delete-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(calls, ['DELETE /api/v1/me']);
    expect(session.signedIn, isFalse);
  });

  testWidgets('a similar listing starts from the details of another, without its photos', (tester) async {
    final api = Api(base: 'http://x/api/v1', client: MockClient((_) async => jsonResponse({})));
    final template = Listing.fromJson({...listingJson(), 'model_name': 'Air Force 1', 'price_tiyn': 4500000});
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: MaterialApp(home: ListingEditorScreen(template: template))));
    await tester.pumpAndSettle();
    expect(find.text('Ұқсас тауар'), findsOneWidget);
    expect(find.byKey(const Key('template-note')), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Nike Air Force 1'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '45000'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '43'), findsOneWidget); // every size row came along
    expect(find.byType(Image), findsNothing); // photos are of another pair
  });

  testWidgets('catalog loads the next page when scrolled near the end', (tester) async {
    final offsets = <String?>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          offsets.add(req.url.queryParameters['offset']);
          final start = int.parse(req.url.queryParameters['offset'] ?? '0');
          final count = start == 0 ? 20 : 5;
          return http.Response(
              jsonEncode({
                'items': [
                  for (var i = 0; i < count; i++) {...listingJson(), 'id': start + i, 'title': 'Тауар ${start + i}'}
                ]
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: CatalogScreen()))));
    await tester.pumpAndSettle();
    expect(offsets, [null]);
    await tester.scrollUntilVisible(find.text('Тауар 24'), 400, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(offsets, [null, '20']);
    expect(find.text('Тауар 24'), findsOneWidget);
  });

  testWidgets('shop shows platform-counted sales and only that seller\'s items', (tester) async {
    String? sellerQuery;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          final body = req.url.path.endsWith('/sellers/3')
              ? {
                  'id': 3,
                  'shop_name': 'Qadam Store',
                  'city': 'Алматы',
                  'since': '2026-10-16',
                  'completed_sales': 12,
                  'listings': 1,
                  'rating': 4.8,
                  'reviews': 9,
                  'about': 'Жөнелту 1 күнде.',
                }
              : (() {
                  sellerQuery = req.url.queryParameters['seller_id'];
                  return {
                    'items': [listingJson()]
                  };
                })();
          return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ShopScreen(sellerId: 3))));
    await tester.pumpAndSettle();
    expect(sellerQuery, '3');
    expect(find.text('Qadam Store'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('9 пікір'), findsOneWidget);
    expect(find.textContaining('қаз 2026'), findsOneWidget);
    expect(find.text('Nike Air Force 1'), findsOneWidget);
    expect(find.text('Жөнелту 1 күнде.'), findsOneWidget);
  });

  testWidgets('seller writes the shop page note and the profile shows it', (tester) async {
    Object? sent;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          sent = jsonDecode(req.body);
          return http.Response(
              jsonEncode({
                'id': 1,
                'phone': '+77010000001',
                'is_seller': true,
                'shop_name': 'Qadam Store',
                'shop_about': (sent as Map)['text'],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    final session = Session(api)
      ..update(Me.fromJson({'id': 1, 'phone': '+77010000001', 'is_seller': true, 'shop_name': 'Qadam Store'}));
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: Scaffold(body: ShopAboutTile()))));
    expect(find.text('Жазылмаған: жөнелту, қайтару, жұмыс уақыты'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shop-about-tile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('shop-about-field')), '  Қайтару 3 күн ішінде. ');
    await tester.tap(find.byKey(const Key('shop-about-save')));
    await tester.pumpAndSettle();
    expect(sent, {'text': 'Қайтару 3 күн ішінде.'});
    expect(find.text('Қайтару 3 күн ішінде.'), findsOneWidget);
  });

  testWidgets('turning an optional alert off saves it, and a failed save puts the switch back', (tester) async {
    final sent = <Map<String, dynamic>>[];
    var on = {'price_drop': true, 'saved_search': true, 'followed_shop': true, 'back_in_stock': true};
    var fail = false;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          expect(req.url.path, '/api/v1/me/notification-settings');
          if (req.method == 'PUT') {
            if (fail) return jsonResponse({'detail': 'down'}, 500);
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            sent.add(body);
            on = {...on, ...body.cast<String, bool>()};
          }
          return jsonResponse({
            'items': [
              for (final e in on.entries) {'kind': e.key, 'on': e.value}
            ]
          });
        }));
    await tester
        .pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: NotificationSettingsScreen())));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNWidgets(4));
    bool value(String kind) => tester.widget<SwitchListTile>(find.byKey(Key('alert-$kind'))).value;
    await tester.tap(find.byKey(const Key('alert-price_drop')));
    await tester.pumpAndSettle();
    expect(sent, [
      {'price_drop': false}
    ]);
    expect(value('price_drop'), isFalse);
    fail = true;
    await tester.tap(find.byKey(const Key('alert-saved_search')));
    await tester.pumpAndSettle();
    expect(value('saved_search'), isTrue);
  });

  testWidgets('report sheet needs a reason, and text for "other"', (tester) async {
    Map<String, dynamic>? sent;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          expect(req.url.path, '/api/v1/listings/7/report');
          sent = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response('{"reported": true}', 201);
        }));
    await tester.pumpWidget(
        SessionScope(session: Session(api), child: const MaterialApp(home: Scaffold(body: ReportSheet(listingId: 7)))));
    FilledButton send() => tester.widget<FilledButton>(find.byKey(const Key('send-report')));
    expect(send().onPressed, isNull);
    await tester.tap(find.text('Басқа себеп'));
    await tester.pump();
    expect(send().onPressed, isNull);
    await tester.tap(find.text('Телефон не сілтеме жазылған'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-report')));
    await tester.pumpAndSettle();
    expect(sent, {'reason': 'contact_details'});
  });

  testWidgets('search by photo uploads the picture and lists look-alikes in order', (tester) async {
    String? path;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient.streaming((req, body) async {
          path = req.url.path;
          return http.StreamedResponse(
              Stream.value(utf8.encode(jsonEncode({
                'items': [
                  {...listingJson(), 'id': 1, 'title': 'Ең ұқсас', 'similarity': 0.91},
                  {...listingJson(), 'id': 2, 'title': 'Екінші', 'similarity': 0.6},
                ]
              }))),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==');
    await tester.pumpWidget(SessionScope(
        session: Session(api), child: MaterialApp(home: ImageSearchScreen(bytes: png, filename: 'q.png'))));
    await tester.pumpAndSettle();
    expect(path, '/api/v1/search/image');
    expect(tester.getTopLeft(find.text('Ең ұқсас')).dx, lessThan(tester.getTopLeft(find.text('Екінші')).dx));
  });

  test('a dropped connection and a bare 500 become a message for people, never a raw exception', () async {
    final dropped =
        Api(base: 'http://x/api/v1', client: MockClient((req) async => throw http.ClientException('reset', req.url)));
    await expectLater(dropped.order(1), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'network')));
    final html =
        Api(base: 'http://x/api/v1', client: MockClient((_) async => http.Response('Internal Server Error', 500)));
    await expectLater(
        html.order(1),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 500)
            .having((e) => e.message, 'message', 'Сервер уақытша жауап бермей тұр. Біраз кейін қайталап көріңіз.')));
    // The server's own JSON for a 500 keeps its words, in the interface language.
    final json = Api(
        base: 'http://x/api/v1',
        client: MockClient((_) async => jsonResponse({
              'code': 'unavailable',
              'message_kk': 'Қызмет уақытша қолжетімсіз.',
              'message_ru': 'Сервис временно недоступен.',
              'message_en': 'The service is temporarily unavailable.',
            }, 500)));
    await expectLater(
        json.order(1),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'unavailable')
            .having((e) => e.message, 'message', 'Қызмет уақытша қолжетімсіз.')));
    appLanguage.value = 'ru';
    addTearDown(() => appLanguage.value = 'kk');
    expect(ApiException.local(0, 'network', 'Байланыс жоқ. Интернетті тексеріп, қайталап көріңіз.').message,
        'Нет связи. Проверьте интернет и попробуйте ещё раз.');
  });

  testWidgets('a list that timed out says so in words and loads on retry', (tester) async {
    var calls = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) {
          calls++;
          if (calls == 1) return Completer<http.Response>().future; // hangs until the app gives up
          return Future.value(jsonResponse({
            'items': [
              {
                'id': 1,
                'status': 'PAID',
                'listing_id': 7,
                'buyer_id': 2,
                'seller_id': 1,
                'total_tiyn': 1,
                'listing_title': 'Shoe 1'
              }
            ]
          }));
        }))
      ..token = 't';
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrdersScreen())));
    await tester.pump(Api.timeout - const Duration(seconds: 1));
    expect(find.byType(CircularProgressIndicator), findsOneWidget); // still waiting
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Байланыс жоқ. Интернетті тексеріп, қайталап көріңіз.'), findsOneWidget);
    expect(find.textContaining('TimeoutException'), findsNothing);
    await tester.tap(find.byKey(const Key('retry')));
    await tester.pumpAndSettle();
    expect(find.text('Shoe 1'), findsOneWidget);
    expect(calls, 2);
  });

  Map<String, dynamic> orderJson(String status, {String? deadline}) => {
        'id': 5,
        'status': status,
        'listing_id': 7,
        'buyer_id': 2,
        'seller_id': 1,
        'total_tiyn': 4650000,
        'history': [],
        'deadline': deadline,
      };

  Future<List<http.Request>> pumpOrder(WidgetTester tester, String status, {required int meId}) async {
    final posts = <http.Request>[];
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.method == 'POST') posts.add(req);
          return jsonResponse(orderJson(status));
        }))
      ..token = 't';
    final session = Session(api)
      ..update(Me.fromJson({'id': meId, 'phone': '+7701000000$meId', 'is_seller': meId == 1}));
    tester.view.physicalSize = const Size(500, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrderScreen(orderId: 5))));
    await tester.pumpAndSettle();
    return posts;
  }

  testWidgets('order page shows a retry when the first load fails, and the order after it', (tester) async {
    var calls = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (++calls == 1) return http.Response('<html>Bad Gateway</html>', 502);
          return jsonResponse(orderJson('PAID'));
        }))
      ..token = 't';
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrderScreen(orderId: 5))));
    await tester.pumpAndSettle();
    expect(find.text('Сервер уақытша жауап бермей тұр. Біраз кейін қайталап көріңіз.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('order-total')), findsOneWidget);
    expect(find.byKey(const Key('retry')), findsNothing);
  });

  testWidgets('an order shows the photos it was placed on, whatever the listing shows now', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => jsonResponse({
              ...orderJson('PAID'),
              'listing_photos': [
                {'url': 'https://cdn/a.jpg', 'angle': 'front'},
                {'url': 'https://cdn/b.jpg', 'angle': 'outer'},
                for (var i = 0; i < 8; i++) {'url': 'https://cdn/f$i.jpg', 'angle': 'frame'},
              ],
            })))
      ..token = 't';
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    await tester.pumpWidget(SessionScope(session: session, child: const MaterialApp(home: OrderScreen(orderId: 5))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('ordered-photos')), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Тапсырыс берген кездегі фото'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('ordered-photos')), matching: find.byType(ClipRRect)),
        findsNWidgets(2));
    expect(find.text('360° көрініс: 8 кадр'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ordered-spin')));
    await tester.pump();
    expect(find.byType(SpinViewer), findsOneWidget);
  });

  testWidgets('confirming receipt asks first and says where the money goes', (tester) async {
    final posts = await pumpOrder(tester, 'DELIVERED_PENDING_CONFIRMATION', meId: 2);
    await tester.tap(find.text('Алдым, бәрі дұрыс'));
    await tester.pumpAndSettle();
    expect(find.text('Бәрі дұрыс па?'), findsOneWidget);
    expect(find.textContaining('ақша комиссия шегеріліп сатушыға өтеді'), findsOneWidget);
    await tester.tap(find.text('Жабу'));
    await tester.pumpAndSettle();
    expect(posts, isEmpty); // closing the dialog changes nothing
    await tester.tap(find.text('Алдым, бәрі дұрыс'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect([for (final r in posts) r.url.path], ['/api/v1/orders/5/confirm']);
    expect(find.text('Рақмет! Тапсырыс аяқталды.'), findsOneWidget);
  });

  testWidgets('cancelling a paid order asks first and promises the refund', (tester) async {
    final posts = await pumpOrder(tester, 'PAID', meId: 2);
    await tester.tap(find.text('Бас тарту, ақшаны қайтару'));
    await tester.pumpAndSettle();
    expect(find.text('Тапсырыстан бас тарту керек пе?'), findsOneWidget);
    expect(find.text('Ақша сізге толық қайтарылады, тапсырыс жабылады.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect([for (final r in posts) r.url.path], ['/api/v1/orders/5/cancel']);
  });

  testWidgets('a buyer marks a shipped parcel received after a confirmation', (tester) async {
    final posts = await pumpOrder(tester, 'SHIPPED', meId: 2);
    expect(find.text('Дау ашу'), findsOneWidget);
    await tester.tap(find.text('Тауарды алдым'));
    await tester.pumpAndSettle();
    expect(find.text('Сәлемдеме қолыңызға тиді ме?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect([for (final r in posts) r.url.path], ['/api/v1/orders/5/received']);
  });

  testWidgets('on a return the seller can contest it with a reason, and the buyer can take it to support',
      (tester) async {
    final posts = await pumpOrder(tester, 'RETURN_REQUESTED', meId: 1);
    expect(find.text('Қайтаруды мақұлдау'), findsOneWidget);
    expect(find.text('Бас тарту'), findsNothing); // declining is only for orders not yet shipped
    await tester.tap(find.text('Қайтаруға келіспеу'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('action-reason')), 'Табаны киілген, сатқанда жаңа болды');
    await tester.tap(find.text('Жіберу'));
    await tester.pumpAndSettle();
    expect([for (final r in posts) r.url.path], ['/api/v1/orders/5/dispute']);
    expect(jsonDecode(posts.single.body), {'reason': 'Табаны киілген, сатқанда жаңа болды'});

    await tester.pumpWidget(const SizedBox());
    await pumpOrder(tester, 'RETURN_REQUESTED', meId: 2);
    expect(find.text('Дау ашу'), findsOneWidget);
    expect(find.text('Қайтаруға келіспеу'), findsNothing);
  });

  testWidgets('a seller cannot decline once the pair has shipped', (tester) async {
    await pumpOrder(tester, 'SHIPPED', meId: 1);
    expect(find.text('Бас тарту'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await pumpOrder(tester, 'PREPARING', meId: 1);
    expect(find.text('Бас тарту'), findsOneWidget);
  });

  testWidgets('a new unpaid order puts paying first, with the total on the button', (tester) async {
    final posts = await pumpOrder(tester, 'CREATED', meId: 2);
    expect(find.byKey(const Key('pay-now')), findsOneWidget);
    expect(find.text('Енді төлеңіз'), findsOneWidget);
    expect(find.text('Төлеу'), findsNothing); // one pay button, not two
    await tester.tap(find.byKey(const Key('pay')));
    await tester.pumpAndSettle();
    expect([for (final r in posts) r.url.path], ['/api/v1/orders/5/pay']);
  });

  test('every running clock is told to each side in its own words', () {
    const at = '2026-10-20T09:30:00';
    for (final status in [
      'SELLER_ACCEPTED',
      'PREPARING',
      'SHIPPED',
      'IN_TRANSIT',
      'RETURN_REQUESTED',
      'DELIVERED_PENDING_CONFIRMATION'
    ]) {
      final o = OrderInfo.fromJson(orderJson(status, deadline: at));
      final buyer = orderDeadlineText(o, 2);
      final seller = orderDeadlineText(o, 1);
      expect(buyer, isNotNull, reason: status);
      expect(seller, isNotNull, reason: status);
      expect(buyer, isNot(seller), reason: status);
      expect(buyer, contains('20.10, 09:30'), reason: status);
    }
    String text(String status, int me) => orderDeadlineText(OrderInfo.fromJson(orderJson(status, deadline: at)), me)!;
    expect(text('PREPARING', 2), contains('толық қайтарылады'));
    expect(text('PREPARING', 1), contains('жіберіп'));
    expect(text('SHIPPED', 2), contains('«Тауарды алдым»'));
    expect(text('IN_TRANSIT', 1), contains('қолдау қызметі'));
    expect(text('RETURN_REQUESTED', 1), contains('мақұлдаңыз'));
    expect(text('DELIVERED_PENDING_CONFIRMATION', 2), contains('ақша сатушыға өтеді'));
    expect(text('DELIVERED_PENDING_CONFIRMATION', 1), contains('сізге өтеді'));
    expect(orderDeadlineText(OrderInfo.fromJson(orderJson('COMPLETED', deadline: at)), 2), isNull);
  });

  testWidgets('leaving the listing editor with unsaved work asks first', (tester) async {
    tester.view.physicalSize = const Size(500, 3000); // the whole form is built, title field included
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = Api(base: 'http://x/api/v1', client: MockClient((_) async => jsonResponse({})));
    await tester.pumpWidget(SessionScope(
        session: Session(api),
        child: MaterialApp(
            home: Builder(
                builder: (context) => TextButton(
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ListingEditorScreen())),
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Nothing typed yet: back simply leaves.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ListingEditorScreen), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'Qadam Runner');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Сақтамай шығу керек пе?'), findsOneWidget);
    await tester.tap(find.text('Қалу'));
    await tester.pumpAndSettle();
    expect(find.byType(ListingEditorScreen), findsOneWidget);
    expect(find.text('Qadam Runner'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard')));
    await tester.pumpAndSettle();
    expect(find.byType(ListingEditorScreen), findsNothing);
  });

  testWidgets('listing editor checks title length and insole centimetres on the spot', (tester) async {
    final api = Api(base: 'http://x/api/v1', client: MockClient((_) async => jsonResponse({})));
    tester.view.physicalSize = const Size(500, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: ListingEditorScreen())));
    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'AF');
    await tester.enterText(find.widgetWithText(TextFormField, 'Ұлтарақ, см'), '5');
    await tester.tap(find.text('Жариялау'));
    await tester.pump();
    expect(find.text('Атауы кемінде 3 таңбадан тұрсын'), findsOneWidget);
    expect(find.text('8–35 см аралығында болуы керек'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Ұлтарақ, см'), 'жиырма');
    await tester.tap(find.text('Жариялау'));
    await tester.pump();
    expect(find.text('Санмен жазыңыз, мысалы 27,5'), findsOneWidget);
    expect(insoleCheck('27,5'), isNull);
    expect(insoleCheck('27.5'), isNull);
    expect(insoleCheck('36'), isNotNull);
  });

  testWidgets('a chat that could not load says why and opens on retry', (tester) async {
    var calls = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (++calls == 1) throw http.ClientException('no route', req.url);
          return jsonResponse({
            'conversation': {
              'id': 9,
              'listing_id': 7,
              'listing_title': 'Кроссовка',
              'listing_cover': null,
              'price_tiyn': 2490000,
              'role': 'buyer',
              'other_name': 'Qadam Store',
              'last_message': null,
              'unread': 0,
            },
            'items': [
              {
                'id': 1,
                'sender_id': 3,
                'body': 'Сәлем!',
                'contact_warning': false,
                'created_at': '2026-10-17T10:00:00Z'
              }
            ],
          });
        }))
      ..token = 't';
    final session = Session(api)..update(Me.fromJson({'id': 2, 'phone': '+77010000002', 'is_seller': false}));
    await tester.pumpWidget(SessionScope(
        session: session,
        child: const MaterialApp(home: ChatScreen(conversationId: 9, pollEvery: Duration(hours: 1)))));
    await tester.pump();
    await tester.pump();
    expect(find.text('Байланыс жоқ. Интернетті тексеріп, қайталап көріңіз.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Сәлем!'), findsOneWidget);
  });

  testWidgets('the seller sees their own listing without a buy button to press', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          if (req.url.path == '/api/v1/offers') return jsonResponse({'items': [], 'waiting': 0});
          if (req.url.path.endsWith('/similar')) return jsonResponse({'items': []});
          if (req.url.path.endsWith('/questions')) return jsonResponse({'items': []});
          return jsonResponse(listingJson());
        }))
      ..token = 'tok';
    final session = Session(api)..update(Me.fromJson({'id': 3, 'phone': '+77010000003', 'is_seller': true}));
    tester.view.physicalSize = const Size(400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(SessionScope(session: session, child: const MaterialApp(home: ListingScreen(listingId: 7))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('42'));
    await tester.pump();
    final buy = tester.widget<FilledButton>(find.byKey(const Key('buy')));
    expect(buy.onPressed, isNull);
    expect(find.text('Бұл сіздің тауарыңыз'), findsOneWidget);
  });

  testWidgets('catalog tiles never run into each other at the largest text size', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final items = [
      for (var i = 0; i < 4; i++)
        Listing.fromJson({...listingJson(), 'id': i + 1, 'title': 'Nike Air Force 1 Low White Triple Edition $i'})
    ];
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(2)),
            child: Scaffold(body: ListingGrid(items: items)))));
    await tester.pump();
    expect(tester.takeException(), isNull); // no RenderFlex overflow
  });

  group('editing what a listing shows', () {
    Future<List<Map<String, dynamic>>> show(WidgetTester tester, Map<String, dynamic> listing,
        {bool manage = false}) async {
      final sent = <Map<String, dynamic>>[];
      final api = Api(
          base: 'http://x/api/v1',
          client: MockClient((req) async {
            expect((req.method, req.url.path), ('PATCH', '/api/v1/listings/7'));
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            sent.add(body);
            return jsonResponse({...listing, if (body['title'] != null) 'title': body['title']});
          }));
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(SessionScope(
          session: Session(api),
          child: MaterialApp(
              home: manage
                  ? ManageListingScreen(listing: Listing.fromJson(listing))
                  : Scaffold(
                      body: SingleChildScrollView(
                          child: ListingContentsCard(listing: Listing.fromJson(listing), onChanged: (_) {}))))));
      return sent;
    }

    final photos = [
      {'original_url': 'https://cdn/a.jpg', 'processed_url': null, 'angle': 'front'},
      {'original_url': 'https://cdn/b.jpg', 'processed_url': null, 'angle': 'outer'},
    ];

    testWidgets('one Save sends only the name fields the seller changed', (tester) async {
      final sent = await show(
          tester, {...listingJson(media: photos), 'ever_on_sale': true, 'condition': 'used_excellent'},
          manage: true);
      expect(tester.widget<TextFormField>(find.byKey(const Key('edit-brand'))).enabled, isFalse);
      expect(find.text('Санаты'), findsNothing);
      expect(find.byKey(const Key('save-name')), findsNothing);
      await tester.enterText(find.byKey(const Key('edit-title')), 'x');
      await tester.ensureVisible(find.byKey(const Key('save')));
      await tester.tap(find.byKey(const Key('save')));
      await tester.pump();
      expect(find.text('Атауы кемінде 3 әріп болсын'), findsOneWidget);
      expect(sent, isEmpty);
      await tester.enterText(find.byKey(const Key('edit-title')), 'Nike Air Force 1 ақ');
      await tester.tap(find.byKey(const Key('save')));
      await tester.pumpAndSettle();
      expect(sent.single['title'], 'Nike Air Force 1 ақ');
      for (final k in ['brand', 'model_name', 'color', 'category', 'condition']) {
        expect(sent.single.containsKey(k), isFalse, reason: k);
      }
      // After sale the condition can only be marked worse. (Mid-screen: the colour chips push it to where the
      // "saved" note covers the bottom.)
      await Scrollable.ensureVisible(tester.element(find.byKey(const Key('edit-condition'))), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit-condition')));
      await tester.pumpAndSettle();
      expect(find.text('Жаңа, қорабымен'), findsNothing);
      expect(find.text('Ақауы бар'), findsOneWidget);
    });

    testWidgets('an added size is checked and saved at once; photos buyers saw cannot be removed', (tester) async {
      final sent = await show(tester, {...listingJson(media: photos), 'ever_on_sale': true});
      expect(find.byKey(const Key('remove-photo-0')), findsNothing);
      expect(find.byKey(const Key('add-spin')), findsOneWidget);
      await tester.tap(find.byKey(const Key('add-size')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('size-label')), 'EU 44');
      await tester.enterText(find.byKey(const Key('size-cm')), '40');
      await tester.tap(find.byKey(const Key('size-add')));
      await tester.pump();
      expect(sent, isEmpty); // 40 cm is not a shoe
      await tester.enterText(find.byKey(const Key('size-cm')), '28.5');
      await tester.tap(find.byKey(const Key('size-add')));
      await tester.pumpAndSettle();
      expect(sent.last['add_sizes'], [
        {'label': 'EU 44', 'insole_cm': '28.5', 'quantity': 1}
      ]);
    });

    testWidgets('a draft can drop a photo after confirming which one', (tester) async {
      final sent = await show(tester, {...listingJson(media: photos), 'status': 'draft'});
      expect(find.byTooltip('Өшіру: Алдынан'), findsOneWidget);
      await tester.tap(find.byKey(const Key('remove-photo-0')));
      await tester.pumpAndSettle();
      expect(find.text('«Алдынан» фотосын өшіру керек пе?'), findsOneWidget);
      await tester.tap(find.text('Болдырмау'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      await tester.tap(find.byKey(const Key('remove-photo-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(sent.single['photos'], [
        {'url': 'https://cdn/b.jpg', 'angle': 'outer'}
      ]);
    });

    testWidgets('the angle picker marks angles that already have a photo', (tester) async {
      await show(tester, listingJson(media: photos));
      await tester.tap(find.byKey(const Key('add-photo')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const Key('angle-front')), matching: find.byIcon(Icons.check_circle)),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('angle-sole')), matching: find.byIcon(Icons.check_circle)),
          findsNothing);
      await tester.tap(find.byKey(const Key('angle-sole')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source-camera')), findsOneWidget);
      expect(find.byKey(const Key('source-gallery')), findsOneWidget);
    });

    testWidgets('after sale a photo can be replaced while the page keeps four, and the 360° view removed',
        (tester) async {
      final five = [
        for (final (i, a) in ['front', 'outer', 'inner', 'back', 'sole'].indexed)
          {'original_url': 'https://cdn/p$i.jpg', 'processed_url': null, 'angle': a},
      ];
      final frames = [
        for (var i = 0; i < 8; i++) {'original_url': 'https://cdn/f$i.jpg', 'processed_url': null, 'angle': 'frame'}
      ];
      final sent = await show(tester, {
        ...listingJson(media: [...five, ...frames]),
        'ever_on_sale': true
      });
      expect(find.byKey(const Key('remove-photo-0')), findsNothing); // the front stays: buyers judge by it
      tester.view.physicalSize = const Size(800, 2400);
      await tester.pump();
      expect(find.byKey(const Key('remove-photo-4')), findsOneWidget); // an extra one may go
      await tester.tap(find.byKey(const Key('remove-spin')));
      await tester.pumpAndSettle();
      expect(find.text('360° көріністі өшіру керек пе?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect((sent.single['photos'] as List).length, 5);
      expect((sent.single['photos'] as List).any((p) => (p as Map)['angle'] == 'frame'), isFalse);
    });

    testWidgets('a listing with a 360° view offers no second one', (tester) async {
      final frames = [
        for (var i = 0; i < 8; i++) {'original_url': 'https://cdn/f$i.jpg', 'processed_url': null, 'angle': 'frame'}
      ];
      await show(tester, listingJson(media: [...photos, ...frames]));
      expect(find.byKey(const Key('add-spin')), findsNothing);
      expect(find.text('360° көрініс: 8 кадр'), findsOneWidget);
    });

    testWidgets('with a 360° view the seller is asked for the missing top, sole and close-up, one tap each',
        (tester) async {
      final frames = [
        for (var i = 0; i < 8; i++) {'original_url': 'https://cdn/f$i.jpg', 'processed_url': null, 'angle': 'frame'}
      ];
      await show(
          tester,
          listingJson(media: [
            ...photos,
            {'original_url': 'https://cdn/s.jpg', 'processed_url': null, 'angle': 'sole'},
            ...frames
          ]));
      expect(find.byKey(const Key('stop-top')), findsOneWidget);
      expect(find.byKey(const Key('stop-sole')), findsNothing); // already there
      expect(find.byKey(const Key('stop-detail')), findsOneWidget);
      await tester.tap(find.byKey(const Key('stop-top')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source-camera')), findsOneWidget); // straight to the camera, no angle question
      expect(find.byKey(const Key('angle-top')), findsNothing);
    });

    testWidgets('without a 360° view there is nothing to ask for', (tester) async {
      await show(tester, listingJson(media: photos));
      expect(find.byKey(const Key('stop-top')), findsNothing);
    });
  });

  testWidgets('a new code can be asked for only after the countdown', (tester) async {
    var asked = 0;
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async {
          expect(req.url.path, '/api/v1/auth/otp');
          asked++;
          return jsonResponse({'sent': true, 'resend_after': 3, 'dev_code': '123456'});
        }));
    await tester.pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: LoginScreen())));
    await tester.enterText(find.byType(TextField).first, '+77010000001');
    await tester.tap(find.text('Код алу'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Жаңа код: 3 сек кейін'), findsOneWidget);
    expect(find.text('Код +77010000001 нөміріне жіберілді'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const Key('resend-code'))).onPressed, isNull);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Кодты қайта жіберу'), findsOneWidget);
    await tester.tap(find.byKey(const Key('resend-code')));
    await tester.pump();
    expect(asked, 2);
    await tester.pump();
    expect(find.text('Жаңа код жіберілді. Бұрынғы код та жарамды.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the timer
  });

  testWidgets('on a wide window list rows stay a readable width, but the catalog grid uses it all', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => switch (req.url.path) {
              '/api/v1/me/notification-settings' => jsonResponse({
                  'items': [
                    {'kind': 'price_drop', 'on': true}
                  ]
                }),
              '/api/v1/saved-searches' => jsonResponse({
                  'items': [
                    {
                      'id': 9,
                      'q': 'adidas',
                      'category': null,
                      'size_cm': null,
                      'condition': null,
                      'min_price_tiyn': null,
                      'max_price_tiyn': null
                    }
                  ]
                }),
              _ => jsonResponse({
                  'items': [
                    for (var i = 0; i < 8; i++) {...listingJson(), 'id': i + 1}
                  ]
                }),
            }))
      ..token = 'tok';
    Future<void> show(Widget screen) async {
      await tester.pumpWidget(SessionScope(session: Session(api), child: MaterialApp(home: screen)));
      await tester.pumpAndSettle();
    }

    await show(const NotificationSettingsScreen());
    final alert = tester.getRect(find.byKey(const Key('alert-price_drop')));
    expect(alert.width, lessThanOrEqualTo(maxContentWidth));
    expect(alert.center.dx, moreOrLessEquals(600)); // centred, not stuck to one side

    await show(const SavedSearchesScreen());
    expect(tester.getSize(find.byKey(const Key('saved-9'))).width, lessThanOrEqualTo(maxContentWidth));

    mySize.value = null;
    await show(const Scaffold(body: CatalogScreen()));
    expect(tester.getSize(find.byKey(const Key('search-field'))).width, lessThanOrEqualTo(maxContentWidth));
    // The grid is not capped: a wide window gets more columns instead.
    final columns = {
      for (final e in find.text('Nike Air Force 1').evaluate())
        tester.getTopLeft(find.byElementPredicate((x) => x == e)).dx
    };
    expect(columns.length, greaterThan(3));
    expect(tester.getTopRight(find.text('Nike Air Force 1').last).dx, greaterThan(maxContentWidth));
  });

  for (final (width, scale) in [(320.0, 2.0), (320.0, 1.0), (360.0, 1.3), (412.0, 1.0)]) {
    testWidgets('the catalog search field leaves room to type at ${width.toInt()} dp and text x$scale', (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = Api(
          base: 'http://x/api/v1',
          client: MockClient((req) async => req.url.path == '/api/v1/notifications'
              ? jsonResponse({'unread': 3, 'items': []})
              : jsonResponse({'items': []})))
        ..token = 'tok'; // signed in: the header also carries the saved-search and bell buttons
      mySize.value = '27,5'; // the longest size label
      addTearDown(() => mySize.value = null);
      final recent = recentSearches.value;
      recentSearches.value = ['Nike Air Force 1', 'Adidas Samba']; // the hints under the field take room too
      addTearDown(() => recentSearches.value = recent);
      await tester.pumpWidget(SessionScope(
          session: Session(api),
          child: MaterialApp(
              home: MediaQuery(
                  data: MediaQueryData(size: Size(width, 640), textScaler: TextScaler.linear(scale)),
                  child: const Scaffold(body: CatalogScreen())))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull); // no RenderFlex overflow
      final field = tester.getRect(find.byKey(const Key('search-field')));
      expect(field.right, lessThanOrEqualTo(width));
      final typing = tester
          .getSize(find.descendant(of: find.byKey(const Key('search-field')), matching: find.byType(EditableText)));
      expect(typing.width, greaterThanOrEqualTo(min(100 * scale, 170)), reason: 'room left for the typed words');
      expect(find.text('27,5 см'), findsOneWidget);
    });
  }

  testWidgets('after the hourly limit the code button waits it out in minutes', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((req) async => http.Response(
            jsonEncode({'code': 'rate_limited', 'message_kk': 'Тым көп сұрау.', 'detail': '1500'}), 429,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    await tester.pumpWidget(SessionScope(session: Session(api), child: const MaterialApp(home: LoginScreen())));
    await tester.enterText(find.byType(TextField).first, '+77010000001');
    await tester.tap(find.text('Код алу'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Жаңа код: 25 мин кейін'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.pumpWidget(const SizedBox()); // stops the timer
  });

  group('the catalog card turns the shoe', () {
    Map<String, dynamic> frame(int i, {bool cut = true, bool thumb = true}) => {
          'original_url': 'https://cdn/f$i.jpg',
          'processed_url': cut ? 'https://cdn/f$i.webp' : null,
          'thumb_url': thumb ? 'https://cdn/t$i.webp' : null,
          'angle': 'frame',
        };
    Listing listing(List<Map<String, dynamic>> frames, {int id = 7}) => Listing.fromJson({
          ...listingJson(media: [
            {'original_url': 'https://cdn/side.jpg', 'processed_url': 'https://cdn/side.webp', 'angle': 'side'},
            ...frames,
          ]),
          'id': id,
        });
    final failing = <String>{};
    ui.Image? picture;
    setUp(() => CardTurn.network = (url) => _TestFrame(url, picture!, failing));
    tearDown(() {
      CardTurn.network = NetworkImage.new;
      failing.clear();
    });

    /// The frame on the card, or null when the cover shows.
    String? shown(WidgetTester tester) {
      final found = find.byKey(const Key('card-turn-frame'));
      if (found.evaluate().isEmpty) return null;
      expect(find.byType(CoverPhoto), findsNothing); // never the cover and a frame together
      final image = tester.widget<Image>(found).image as ResizeImage;
      return (image.imageProvider as _TestFrame).url;
    }

    Future<void> pumpTile(WidgetTester tester, Listing l, {bool turns = true}) async {
      picture ??= await tester.runAsync(() => createTestImage(width: 4, height: 3));
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ListView(children: [
        Center(child: SizedBox(width: 200, child: ListingTile(listing: l, turns: turns))),
        const SizedBox(height: 2000),
      ]))));
    }

    Future<TestGesture> hold(WidgetTester tester, double frames, {int of = 12}) async {
      final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('card-turn'))));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(Offset(-200 * 1.5 / of * frames / 10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      return g;
    }

    test('through at most 24 frames of one turn, from the cover, and only when it turns as the listing page does', () {
      expect(CardTurn.framesOf(listing([for (var i = 0; i < 7; i++) frame(i)])), isEmpty);
      final many = CardTurn.framesOf(listing([for (var i = 0; i < 100; i++) frame(i)]));
      expect(many.length, CardTurn.maxFrames);
      expect(many.first.originalUrl, 'https://cdn/f0.jpg');
      expect(many.last.originalUrl, 'https://cdn/f95.jpg'); // spread over the whole turn
      // A turn ends where its first frame comes round again.
      expect(CardTurn.framesOf(listing([for (var i = 0; i < 10; i++) frame(i), frame(0), frame(11)])).length, 10);
      // When the cover is a frame of the turn, the turn starts there.
      final fromCover = Listing.fromJson(listingJson(media: [
        {'original_url': 'https://cdn/f4.jpg', 'processed_url': 'https://cdn/f4.webp', 'angle': 'side'},
        for (var i = 0; i < 12; i++) frame(i),
      ]));
      expect([for (final m in CardTurn.framesOf(fromCover).take(2)) m.originalUrl],
          ['https://cdn/f4.jpg', 'https://cdn/f5.jpg']);
      // No small copy of a frame, or cut-outs for only some frames: the card does not turn.
      expect(CardTurn.framesOf(listing([for (var i = 0; i < 11; i++) frame(i), frame(11, thumb: false)])), isEmpty);
      expect(CardTurn.framesOf(listing([for (var i = 0; i < 11; i++) frame(i), frame(11, cut: false)])), isEmpty);
      expect(CardTurn.framesOf(listing([for (var i = 0; i < 12; i++) frame(i, cut: false)])).length, 12);
    });

    testWidgets('a sideways drag turns it, and on release it turns back to the cover', (tester) async {
      await pumpTile(tester, listing([for (var i = 0; i < 12; i++) frame(i)]));
      expect(shown(tester), isNull);
      expect(find.byType(CoverPhoto), findsOneWidget);
      final g = await hold(tester, 3.5);
      expect(shown(tester), 'https://cdn/t3.webp');
      await g.up();
      await tester.pump(const Duration(milliseconds: 60));
      expect(shown(tester), isNotNull); // turning back
      await tester.pumpAndSettle();
      expect(shown(tester), isNull);
      expect(find.byType(CoverPhoto), findsOneWidget);
    });

    testWidgets('dragging the other way goes round past the start to the end of the turn', (tester) async {
      await pumpTile(tester, listing([for (var i = 0; i < 12; i++) frame(i)]));
      final g = await hold(tester, -1.5);
      expect(shown(tester), 'https://cdn/t10.webp');
      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a scroll does not turn it', (tester) async {
      await pumpTile(tester, listing([for (var i = 0; i < 12; i++) frame(i)]));
      final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('card-turn'))));
      await g.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(shown(tester), isNull);
      await g.up();
    });

    testWidgets('a frame that fails to load keeps the last good one', (tester) async {
      failing.add('https://cdn/t2.webp');
      await pumpTile(tester, listing([for (var i = 0; i < 12; i++) frame(i)]));
      final g = await hold(tester, 1.5);
      expect(shown(tester), 'https://cdn/t1.webp');
      await g.moveBy(const Offset(-25, 0));
      await tester.pump();
      await tester.pump();
      expect(find.byType(CoverPhoto), findsNothing); // not the cover in the middle of the turn
      // The shoe last decoded is still drawn.
      expect(tester.widgetList<RawImage>(find.byType(RawImage)).where((r) => r.image != null), isNotEmpty);
      await g.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a card that becomes another shoe or gets new photos starts again from its cover', (tester) async {
      await pumpTile(tester, listing([for (var i = 0; i < 12; i++) frame(i)]));
      final g = await hold(tester, 2.5);
      expect(shown(tester), 'https://cdn/t2.webp');
      // The same listing with reshot frames, while the finger is still down.
      await pumpTile(
          tester,
          listing([
            for (var i = 0; i < 12; i++) {...frame(i), 'thumb_url': 'https://cdn/new$i.webp'}
          ]));
      expect(shown(tester), isNull);
      await g.moveBy(const Offset(-30, 0)); // no crash: the drag belonged to the old photos
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      final again = await hold(tester, 1.5);
      expect(shown(tester), 'https://cdn/new1.webp');
      await again.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('with reduced motion it shows the cover as soon as the finger lifts', (tester) async {
      picture ??= await tester.runAsync(() => createTestImage(width: 4, height: 3));
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Scaffold(
                  body: Center(
                      child: SizedBox(
                          width: 200,
                          child: ListingTile(listing: listing([for (var i = 0; i < 12; i++) frame(i)]))))))));
      final g = await hold(tester, 3.5);
      expect(shown(tester), isNotNull);
      await g.up();
      await tester.pump();
      expect(shown(tester), isNull);
    });

    testWidgets('screen readers get a plain card, not a scrollable', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpTile(tester, listing([for (var i = 0; i < 12; i++) frame(i)]));
      final actions = <SemanticsAction>{};
      void visit(SemanticsNode n) {
        final data = n.getSemanticsData();
        for (final a in [SemanticsAction.scrollLeft, SemanticsAction.scrollRight]) {
          if (data.hasAction(a)) actions.add(a);
        }
        n.visitChildren((c) {
          visit(c);
          return true;
        });
      }

      visit(tester.getSemantics(find.byType(ListingTile)));
      expect(actions, isEmpty);
      semantics.dispose();
    });

    testWidgets('in a sideways list the drag scrolls the list instead', (tester) async {
      await pumpTile(tester, listing([for (var i = 0; i < 12; i++) frame(i)]), turns: false);
      expect(find.byKey(const Key('card-turn')), findsNothing);
    });
  });
}

/// A frame that is decoded at once, or fails, without the network.
class _TestFrame extends ImageProvider<_TestFrame> {
  const _TestFrame(this.url, this.picture, this.failing);
  final String url;
  final ui.Image picture;
  final Set<String> failing;

  @override
  Future<_TestFrame> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_TestFrame key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(failing.contains(url)
          ? Future.error(StateError('no $url'))
          : SynchronousFuture(ImageInfo(image: picture.clone())));

  @override
  bool operator ==(Object other) => other is _TestFrame && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
