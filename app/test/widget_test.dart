import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/labels.dart';
import 'package:vitrina/screens/chat_screen.dart';
import 'package:vitrina/screens/listing_editor_screen.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/manage_listing_screen.dart';
import 'package:vitrina/screens/spin_capture_screen.dart';
import 'package:vitrina/session.dart';
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
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(SessionScope(
        session: Session(api), child: MaterialApp(home: ManageListingScreen(listing: Listing.fromJson(own)))));
    expect(find.text('Сатылымда'), findsOneWidget);
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
              context: context,
              isScrollControlled: true,
              builder: (_) => const FilterSheet(initial: CatalogFilter())),
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
}
