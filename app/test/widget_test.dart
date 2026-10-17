import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vitrina/api.dart';
import 'package:vitrina/labels.dart';
import 'package:vitrina/screens/listing_editor_screen.dart';
import 'package:vitrina/screens/listing_screen.dart';
import 'package:vitrina/screens/spin_capture_screen.dart';
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
        home: SizedBox(width: 300, height: 300, child: SpinViewer(frameUrls: urls, pixelsPerFrame: 10, introSpin: false))));
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
    final api = Api(base: 'http://x/api/v1', client: MockClient((_) async {
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
}
