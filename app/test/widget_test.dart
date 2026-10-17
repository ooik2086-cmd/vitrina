import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/i18n.dart';
import 'package:vitrina/labels.dart';
import 'package:vitrina/my_size.dart';
import 'package:vitrina/screens/catalog_screen.dart';
import 'package:vitrina/screens/chat_screen.dart';
import 'package:vitrina/screens/earnings_screen.dart';
import 'package:vitrina/screens/image_search_screen.dart';
import 'package:vitrina/screens/listing_editor_screen.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/screens/shop_screen.dart';
import 'package:vitrina/screens/spin_capture_screen.dart';
import 'package:vitrina/ru.dart';
import 'package:vitrina/session.dart';
import 'package:vitrina/widgets/common.dart';
import 'package:vitrina/widgets/filter_sheet.dart';
import 'package:vitrina/widgets/spin_viewer.dart';

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

void main() {
  test('every Kazakh phrase passed to tr() has a Russian translation', () {
    final call = RegExp(r"\btrf?\('((?:[^'\\]|\\.)*)'");
    final missing = <String>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      for (final m in call.allMatches(f.readAsStringSync())) {
        final key = m.group(1)!.replaceAll(r'\n', '\n').replaceAll(r"\'", "'");
        if (!ru.containsKey(key)) missing.add(key);
      }
    }
    expect(missing, isEmpty);
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
    await tester.tap(find.text('Русский'));
    await tester.pumpAndSettle();
    expect(find.text('Сначала дешевле'), findsOneWidget);
    expect(find.text('Арзанырақ'), findsNothing);
    expect((await SharedPreferences.getInstance()).getString('vitrina_lang'), 'ru');
    expect(ApiException(409, 'out_of_stock', 'Бұл өлшем таусылды.', null, 'Этот размер закончился.').message,
        'Этот размер закончился.');
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
        api.createOrder(1, 1, 'k'),
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
    final order = await api.createOrder(1, 1, 'abc');
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

    await tester.enterText(find.widgetWithText(TextFormField, 'Атауы'), 'Qadam Runner');
    await tester.enterText(find.widgetWithText(TextFormField, 'Түсі'), 'ақ');
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
    expect(find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage
        && (w.image as NetworkImage).url == 'http://x/media/3/sole.jpg'), findsOneWidget);
    expect(find.byKey(const Key('chat-photo')), findsOneWidget);
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
    await tester.enterText(find.byKey(const Key('price')), '40000');
    await tester.tap(find.byTooltip('Көбейту'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(sent!['price_tiyn'], 4000000);
    expect(sent!['sizes'], [
      {'id': 1, 'quantity': 3}
    ]);
    expect(find.text('Сақталды'), findsOneWidget);
  });

  testWidgets('seller starts a promo video and the card follows it until it is ready', (tester) async {
    final calls = <String>[];
    var polls = 0;
    Map<String, dynamic> withPromo(String? state) =>
        {...listingJson(), 'promo': {'state': state, 'url': state == 'ready' ? 'http://x/media/3/v.mp4' : null}};
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

  test('catalog filter builds the query and counts what differs from default', () {
    const f = CatalogFilter(
        sort: 'price_asc', conditions: {'new_with_box', 'new_no_box'}, minPriceTiyn: 1000000, maxPriceTiyn: null);
    expect(f.active, 3);
    expect(f.query, {'sort': 'price_asc', 'condition': 'new_with_box,new_no_box', 'min_price_tiyn': '1000000'});
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
    await tester.tap(find.byKey(const Key('apply-filter')));
    await tester.pumpAndSettle();
    expect(result!.minPriceTiyn, 2000000);
    expect(result!.maxPriceTiyn, 5000000);
    expect(result!.sort, 'price_asc');
  });

  testWidgets('earnings shows owed, held and commission from the ledger', (tester) async {
    final api = Api(
        base: 'http://x/api/v1',
        client: MockClient((_) async => http.Response(
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
}
