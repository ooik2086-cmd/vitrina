import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/labels.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/session.dart';
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
                'id': 5, 'status': 'CREATED', 'listing_id': 1, 'size_id': 1, 'buyer_id': 2, 'seller_id': 3,
                'item_price_tiyn': 100, 'delivery_price_tiyn': 0, 'total_tiyn': 100, 'tracking_number': null,
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
        home: SizedBox(width: 300, height: 300, child: SpinViewer(frameUrls: urls, pixelsPerFrame: 10))));
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
    await tester.tap(find.text('42 · 27,0 см'));
    await tester.pump();
    expect(find.textContaining('Тапсырыс беру'), findsOneWidget);
  });
}
